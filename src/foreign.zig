const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("vig_bytecode");
const ffi = @import("ffi");

// The foreign function interface for VIG. This is a small implementation. It
// makes only a call that has integer arguments and pointer arguments. Such a call
// is sufficient for a simple system library function.
//
// A foreign call needs three things from the operating system: a way to load a
// library, a way to find a symbol inside it, and the calling convention of the
// target. Windows gives the first two as `LoadLibraryA` and `GetProcAddress`, and
// a system with the POSIX loader gives them as `dlopen` and `dlsym`. libffi holds
// the third one for each of those targets. Therefore this module has one
// namespace for each loader, and a third one that refuses every declaration on a
// system that has neither.
//
// The rest of the VM needs none of the three. Therefore a program that declares
// no `extern` behaves the same on every system, including a system that has no
// loader here.

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
///
/// A name is on this list when the system has a loader below and libffi has a
/// calling convention for it. The value says nothing about a library *name*: a
/// name in a container goes to the loader of the running system as it stands, so
/// a program that names `kernel32.dll` still fails on Linux. It then fails with
/// `error.ForeignLibraryNotFound`, and not with `error.ForeignCallsUnsupported`.
pub const supported = switch (builtin.os.tag) {
    .windows => true,
    // The systems whose libc holds the POSIX loader. `std.c.RTLD` is `void` for a
    // system that the standard library has no `dlopen` mode for, and `posix` does
    // not compile for such a system. Therefore this list holds only names that
    // have a mode. The test at the end of this file states that invariant.
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

// The implementation for this system.
//
// The choice is at comptime, so the declarations of one system are never analysed
// on another. This matters more than it appears to: an `extern "kernel32"`
// declaration inside a function that any code path can reach makes the whole
// executable depend on that library, and the VM then does not link for a
// different system at all. A test of `builtin.os.tag` inside each function is not
// sufficient, because `close` has no error to give and its body is always
// analysed. Therefore the split is a namespace.
//
// The same rule holds for `posix`. Its functions come from libc, and the type of
// the mode that `dlopen` takes exists for some systems only.
const backend = switch (builtin.os.tag) {
    .windows => windows,
    else => if (supported) posix else unsupported,
};

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
        try checkDeclaration(library_name, symbol_name, arg_types);

        var library_z: NameBuffer = undefined;
        var symbol_z: NameBuffer = undefined;

        // Load the library and find the address of the symbol.
        const library = LoadLibraryA(terminate(&library_z, library_name)) orelse
            return error.ForeignLibraryNotFound;
        errdefer _ = FreeLibrary(library);

        const address = GetProcAddress(library, terminate(&symbol_z, symbol_name)) orelse {
            std.debug.print("Foreign symbol not found: {s}!{s}\n", .{ library_name, symbol_name });
            return error.ForeignSymbolNotFound;
        };

        return resolved(library, address, arg_types);
    }

    fn close(import: *Import) void {
        _ = FreeLibrary(import.library);
    }

    // Only the loader is particular to Windows. The call itself is the shared one.
    const invoke = call;
};

// A system whose libc holds the POSIX loader. `dlopen` and `dlsym` take the place
// of `LoadLibraryA` and `GetProcAddress`.
//
// The library name goes to `dlopen` as the program wrote it. This namespace makes
// no name from a shorter one, because the answer is different on each system
// (`libc.so.6` against `libSystem.B.dylib`, and a version suffix that only the
// author of the program knows). A guess here would refuse a name that the loader
// itself accepts.
const posix = struct {
    fn resolve(library_name: []const u8, symbol_name: []const u8, arg_types: []const ArgType) !Import {
        try checkDeclaration(library_name, symbol_name, arg_types);

        var library_z: NameBuffer = undefined;
        var symbol_z: NameBuffer = undefined;

        // `NOW` binds the symbols of the library at load time. Therefore a library
        // that is itself incomplete gives an error here, and not a fault in the
        // middle of a later call. The mode is not `GLOBAL`: an import must not
        // change what a later load in the same process can see.
        const library = std.c.dlopen(terminate(&library_z, library_name), .{ .NOW = true }) orelse
            return error.ForeignLibraryNotFound;
        errdefer _ = std.c.dlclose(library);

        // A data symbol can legitimately hold the address zero, but a function
        // cannot. Therefore a null answer here is a symbol that the library does
        // not have, the same as it is for `GetProcAddress`.
        const address = std.c.dlsym(library, terminate(&symbol_z, symbol_name)) orelse {
            std.debug.print("Foreign symbol not found: {s}!{s}: {s}\n", .{
                library_name,
                symbol_name,
                lastError(),
            });
            return error.ForeignSymbolNotFound;
        };

        return resolved(library, address, arg_types);
    }

    fn close(import: *Import) void {
        _ = std.c.dlclose(import.library);
    }

    const invoke = call;

    // The reason that the loader gives for the last failure. `dlerror` clears the
    // reason as it reads it, so each caller reads it once only.
    fn lastError() []const u8 {
        const reason = std.c.dlerror() orelse return "no reason from the loader";
        return std.mem.span(reason);
    }
};

// The pieces that both loaders share -------------------------------------------

// A name in a container has no terminator byte, and both loaders take a
// NUL-terminated string. The buffer holds the longest name that the container
// format permits, and `checkDeclaration` has already refused a longer one.
const NameBuffer = [limits.max_name_len:0]u8;

/// Copy `name` into `buffer` and terminate it.
fn terminate(buffer: *NameBuffer, name: []const u8) [*:0]const u8 {
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    return buffer[0..name.len :0].ptr;
}

/// The checks that each loader makes before it takes a declaration. A container
/// that the verifier accepted holds a declaration that passes these. Therefore a
/// failure here is a program that reached the VM by another path.
fn checkDeclaration(library_name: []const u8, symbol_name: []const u8, arg_types: []const ArgType) !void {
    if (library_name.len == 0 or symbol_name.len == 0) return error.InvalidForeignImport;
    if (library_name.len > limits.max_name_len or symbol_name.len > limits.max_name_len) {
        return error.InvalidForeignImport;
    }
    if (arg_types.len > limits.max_args) return error.InvalidForeignImport;
}

/// The import for a library handle and a symbol address that a loader found. The
/// slots past `arg_count` hold `.u32`, and `invoke` reads none of them.
fn resolved(library: *anyopaque, address: *const anyopaque, arg_types: []const ArgType) Import {
    var types: [limits.max_args]ArgType = @splat(.u32);
    @memcpy(types[0..arg_types.len], arg_types);

    return .{
        .library = library,
        .address = address,
        .arg_count = @intCast(arg_types.len),
        .arg_types = types,
    };
}

// The calling convention for a call on this system, which is the third of the
// three things that a foreign call needs.
//
// `FFI_WIN64` is the convention of the x64 Windows ABI. Every other system takes
// the default convention of its target, which libffi defines in the `ffitarget.h`
// of that architecture: `FFI_UNIX64` for x86-64, `FFI_SYSV` for AArch64 and for
// 32-bit ARM. Therefore a new architecture needs no change here.
const abi = if (builtin.os.tag == .windows) ffi.FFI_WIN64 else ffi.FFI_DEFAULT_ABI;

// Call a foreign function with libffi. Both loaders share this function: an
// address is an address once a loader has found it, and only the convention above
// is particular to the system. This function holds the storage for the arguments.
// Therefore each ffi value pointer points to an object that has exactly the size
// and the form of its `ffi_type`.
fn call(import: *const Import, args: [limits.max_args]usize) !u32 {
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
        abi,
        import.arg_count,
        &ffi.ffi_type_uint32,
        &types,
    );
    if (status != ffi.FFI_OK) return error.ForeignCallPreparationFailed;

    var result: u32 = 0;
    // A loader gives the address of a symbol as an untyped pointer, which has the
    // alignment one. A function pointer has the alignment of an instruction, and
    // that is four on AArch64 and on 32-bit ARM. Therefore the cast to the type
    // that `ffi_call` takes needs the assertion, and the assertion holds: the
    // address is the entry point of a function that the loader itself placed.
    ffi.ffi_call(
        &cif,
        @ptrCast(@alignCast(import.address)),
        &result,
        &value_pointers,
    );
    return result;
}

const Value = extern union {
    i32: i32,
    u32: u32,
    ptr: ?*anyopaque,
};

// Tests ----------------------------------------------------------------------

test "the backend for a system with no support refuses every declaration" {
    // This test names `unsupported` and not `resolve`, so it runs everywhere,
    // including where `backend` is a loader. The path that a system with no loader
    // takes is therefore covered by every job. Without that, only a job on such a
    // system could find a fault in it.
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
    if (builtin.os.tag == .windows) try std.testing.expect(supported);

    if (supported) {
        // A name that no system has a library for. The declaration reaches the
        // loader of this system, which refuses it. The error must be the one for a
        // missing library, because a `resolve` that gave
        // `error.ForeignCallsUnsupported` here would mean that a system with a
        // loader selected `unsupported`.
        try std.testing.expectError(
            error.ForeignLibraryNotFound,
            resolve("vig-has-no-library-of-this-name", "no_such_symbol", &.{}),
        );
    } else {
        // On a system with no support the public entry point must refuse too, and
        // not only the namespace above.
        try std.testing.expectError(
            error.ForeignCallsUnsupported,
            resolve("kernel32.dll", "GetCurrentProcessId", &.{}),
        );
    }
}

test "a declaration with a name that no container can hold is refused" {
    // The loader never sees these. A name of the maximum length is the longest one
    // that `NameBuffer` holds, so a longer name must stop before the copy.
    const longest: [limits.max_name_len]u8 = @splat('x');
    const too_long: [limits.max_name_len + 1]u8 = @splat('x');
    const too_many: [limits.max_args + 1]ArgType = @splat(.u32);
    const most: [limits.max_args]ArgType = @splat(.u32);

    try std.testing.expectError(error.InvalidForeignImport, checkDeclaration("", "symbol", &.{}));
    try std.testing.expectError(error.InvalidForeignImport, checkDeclaration("library", "", &.{}));
    try std.testing.expectError(error.InvalidForeignImport, checkDeclaration(&too_long, "symbol", &.{}));
    try std.testing.expectError(error.InvalidForeignImport, checkDeclaration("library", &too_long, &.{}));
    try std.testing.expectError(
        error.InvalidForeignImport,
        checkDeclaration("library", "symbol", &too_many),
    );

    try checkDeclaration(&longest, &longest, &most);

    // The buffer takes a name of that length and terminates it in the sentinel
    // position rather than past the end.
    var buffer: NameBuffer = undefined;
    try std.testing.expectEqualStrings(&longest, std.mem.span(terminate(&buffer, &longest)));
}

test "every system in the support list has a loader mode" {
    // `std.c.RTLD` is `void` for a system that the standard library has no
    // `dlopen` mode for, and `posix` does not compile for such a system. This test
    // states that invariant for the system that runs it: a name added to
    // `supported` without a mode fails here rather than in a build for it.
    if (supported and builtin.os.tag != .windows) {
        try std.testing.expect(@typeInfo(std.c.RTLD) == .@"struct");
    }
}

test "the posix loader finds a symbol in the C library and calls it" {
    // The name of the C library is particular to the system, and a build with no
    // dynamic loader at all (a static musl build, for one) can load none of them.
    // Therefore this test names the two libraries it is sure of and skips the rest.
    const library = switch (builtin.os.tag) {
        .linux => if (builtin.abi.isGnu()) "libc.so.6" else return error.SkipZigTest,
        .macos => "libSystem.B.dylib",
        else => return error.SkipZigTest,
    };

    var import = try resolve(library, "getpid", &.{});
    defer close(&import);

    // `getpid` takes no argument and gives the id of this process, which is always
    // above zero. Therefore the result says that the call reached libc and came
    // back, and it needs no argument marshalling to do so.
    try std.testing.expect(try invoke(&import, @splat(0)) > 0);

    // The same library, with a symbol that it does not hold.
    try std.testing.expectError(
        error.ForeignSymbolNotFound,
        resolve(library, "vig_has_no_symbol_of_this_name", &.{}),
    );
}
