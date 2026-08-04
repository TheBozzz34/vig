const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("vig_bytecode");
const ffi = @import("ffi");

// The foreign function interface for VIG. This is a small implementation. It
// makes only a Windows x64 call that has integer arguments and pointer
// arguments. Such a call is sufficient for a simple Windows API function.
//
// A foreign call needs three things from the operating system: a way to load a
// library, a way to find a symbol inside it, and the calling convention of the
// target. Only Windows supplies all three here. The rest of the VM needs none of
// them, so the VM builds and runs anywhere and a program that declares no
// `extern` behaves the same on every system.

// The argument types and the ABI limits are part of the container format. This
// module takes them from the shared package. It does not declare them again.
const limits = bytecode.foreign;
pub const ArgType = limits.ArgType;

// A foreign import after the VM finds the addresses of its library and its
// symbol. The declaration for this import is a `bytecode.foreign.Import`. The
// two addresses are opaque, so this structure needs nothing from any one system.
pub const Import = struct {
    library: *anyopaque,
    address: *const anyopaque,
    arg_count: u8,
    arg_types: [limits.max_args]ArgType,
};

/// This value is true if a program on this system can make a foreign call. A
/// caller can report the reason before it loads a program, rather than after a
/// `resolve` gives an error.
pub const supported = builtin.os.tag == .windows;

// The implementation for this system.
//
// The choice is at comptime, so the declarations of one system are never analysed
// on another. This matters more than it appears to: an `extern "kernel32"`
// declaration inside a function that any code path can reach makes the whole
// executable depend on that library, and the VM then does not link for a
// different system at all. A test of `builtin.os.tag` inside each function is not
// sufficient, because `close` has no error to give and its body is always
// analysed. Therefore the split is a namespace.
const backend = if (supported) windows else unsupported;

/// Load the given library and find the address of the symbol. If there is no
/// error, the function gives an `Import` structure.
pub fn resolve(library_name: []const u8, symbol_name: []const u8, arg_types: []const ArgType) !Import {
    return backend.resolve(library_name, symbol_name, arg_types);
}

/// Release the library.
pub fn close(import: *Import) void {
    backend.close(import);
}

/// Call the foreign function and give its result.
pub fn invoke(import: *const Import, args: [limits.max_args]usize) !u32 {
    return backend.invoke(import, args);
}

// A system that has no foreign-call support. `resolve` refuses every declaration,
// so the VM holds no import and the two other functions cannot be reached through
// a program. They exist because the VM calls them without a test of the system.
const unsupported = struct {
    fn resolve(_: []const u8, _: []const u8, _: []const ArgType) !Import {
        return error.ForeignCallsUnsupported;
    }

    fn close(_: *Import) void {}

    fn invoke(_: *const Import, _: [limits.max_args]usize) !u32 {
        return error.ForeignCallsUnsupported;
    }
};

const windows = struct {
    // The Windows API functions that load a library and find a symbol.
    extern "kernel32" fn LoadLibraryA(library_name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(library: *anyopaque, symbol_name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(library: *anyopaque) callconv(.winapi) i32;

    fn resolve(library_name: []const u8, symbol_name: []const u8, arg_types: []const ArgType) !Import {
        // Check the input parameters.
        if (library_name.len == 0 or symbol_name.len == 0) return error.InvalidForeignImport;
        if (symbol_name.len > limits.max_name_len or arg_types.len > limits.max_args) return error.InvalidForeignImport;

        if (library_name.len > limits.max_name_len) return error.InvalidForeignImport;

        var library_z: [256:0]u8 = undefined;
        @memcpy(library_z[0..library_name.len], library_name);
        library_z[library_name.len] = 0;

        // Load the library and find the address of the symbol.
        const library = LoadLibraryA(library_z[0..library_name.len :0].ptr) orelse return error.ForeignLibraryNotFound;
        errdefer _ = FreeLibrary(library);

        var symbol_z: [256:0]u8 = undefined;
        @memcpy(symbol_z[0..symbol_name.len], symbol_name);
        symbol_z[symbol_name.len] = 0;

        const address = GetProcAddress(library, symbol_z[0..symbol_name.len :0].ptr) orelse {
            std.debug.print("Foreign symbol not found: {s}!{s}\n", .{ library_name, symbol_name });
            return error.ForeignSymbolNotFound;
        };

        var types: [limits.max_args]ArgType = @splat(.u32);
        @memcpy(types[0..arg_types.len], arg_types);

        return .{
            .library = library,
            .address = address,
            .arg_count = @intCast(arg_types.len),
            .arg_types = types,
        };
    }

    fn close(import: *Import) void {
        _ = FreeLibrary(import.library);
    }

    // Call a foreign function with libffi. This function holds the storage for the
    // arguments. Therefore each ffi value pointer points to an object that has
    // exactly the size and the form of its `ffi_type`.
    fn invoke(import: *const Import, args: [limits.max_args]usize) !u32 {
        var cif: ffi.ffi_cif = undefined;
        var types: [limits.max_args][*c]ffi.ffi_type = undefined;
        var values: [limits.max_args]Value = undefined;
        var value_pointers: [limits.max_args]?*anyopaque = undefined;

        for (0..import.arg_count) |index| {
            switch (import.arg_types[index]) {
                .i32 => {
                    types[index] = &ffi.ffi_type_sint32;
                    values[index].i32 = @bitCast(@as(u32, @truncate(args[index])));
                    value_pointers[index] = &values[index].i32;
                },
                .u32 => {
                    types[index] = &ffi.ffi_type_uint32;
                    values[index].u32 = @truncate(args[index]);
                    value_pointers[index] = &values[index].u32;
                },
                .ptr, .cstr => {
                    types[index] = &ffi.ffi_type_pointer;
                    values[index].ptr = if (args[index] == 0) null else @ptrFromInt(args[index]);
                    value_pointers[index] = @ptrCast(&values[index].ptr);
                },
            }
        }

        // `FFI_WIN64` is the calling convention that the x64 Windows ABI uses. A
        // different system needs a different value here, which is one of the three
        // things that a port has to supply.
        const status = ffi.ffi_prep_cif(
            &cif,
            ffi.FFI_WIN64,
            import.arg_count,
            &ffi.ffi_type_uint32,
            &types,
        );
        if (status != ffi.FFI_OK) return error.ForeignCallPreparationFailed;

        var result: u32 = 0;
        ffi.ffi_call(
            &cif,
            @ptrCast(import.address),
            &result,
            &value_pointers,
        );
        return result;
    }
};

const Value = extern union {
    i32: i32,
    u32: u32,
    ptr: ?*anyopaque,
};

// Tests ----------------------------------------------------------------------

test "the backend for a system with no support refuses every declaration" {
    // This test names `unsupported` and not `resolve`, so it runs everywhere,
    // including where `backend` is `windows`. The path that a Linux build or a
    // macOS build takes is therefore covered by a Windows run as well. Without
    // that, only a job on another system could find a fault in it.
    var import: Import = .{
        .library = @ptrFromInt(1),
        .address = @ptrFromInt(1),
        .arg_count = 0,
        .arg_types = @splat(.u32),
    };

    try std.testing.expectError(
        error.ForeignCallsUnsupported,
        unsupported.resolve("kernel32.dll", "GetCurrentProcessId", &.{}),
    );
    try std.testing.expectError(
        error.ForeignCallsUnsupported,
        unsupported.invoke(&import, @splat(0)),
    );
    // A release must do nothing rather than fault. The VM calls it for each entry
    // when it resets, and it does not first ask whether the system has support.
    unsupported.close(&import);
}

test "the selected backend agrees with the system" {
    try std.testing.expectEqual(builtin.os.tag == .windows, supported);

    // On a system with no support the public entry point must refuse too, and not
    // only the namespace above.
    if (!supported) {
        try std.testing.expectError(
            error.ForeignCallsUnsupported,
            resolve("kernel32.dll", "GetCurrentProcessId", &.{}),
        );
    }
}
