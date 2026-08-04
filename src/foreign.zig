const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("vig_bytecode");
const ffi = @import("ffi");

// The foreign function interface for VIG. This is a small implementation. It
// makes only a Windows x64 call that has integer arguments and pointer
// arguments. Such a call is sufficient for a simple Windows API function.

// The argument types and the ABI limits are part of the container format. This
// module takes them from the shared package. It does not declare them again.
const limits = bytecode.foreign;
pub const ArgType = limits.ArgType;

// A foreign import after the VM finds the addresses of its library and its
// symbol. The declaration for this import is a `bytecode.foreign.Import`.
pub const Import = struct {
    library: *anyopaque,
    address: *const anyopaque,
    arg_count: u8,
    arg_types: [limits.max_args]ArgType,
};

// The Windows API functions that load a library and find a symbol.
extern "kernel32" fn LoadLibraryA(library_name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(library: *anyopaque, symbol_name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(library: *anyopaque) callconv(.winapi) i32;

// Load the given library and find the address of the symbol. If there is no
// error, the function gives an `Import` structure.
pub fn resolve(library_name: []const u8, symbol_name: []const u8, arg_types: []const ArgType) !Import {

    // At this time, a foreign call is possible only on Windows.
    if (builtin.os.tag != .windows) return error.ForeignCallsUnsupported;

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

// Release the library.
pub fn close(import: *Import) void {
    _ = FreeLibrary(import.library);
}

const Value = extern union {
    i32: i32,
    u32: u32,
    ptr: ?*anyopaque,
};

// Call a foreign function with libffi. This function holds the storage for the
// arguments. Therefore each ffi value pointer points to an object that has
// exactly the size and the form of its `ffi_type`.
pub fn invoke(import: *const Import, args: [limits.max_args]usize) !u32 {
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
