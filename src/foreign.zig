const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");
const ffi = @import("ffi");

// Foreign function interface for VIG. This is a minimal implementation that
// only supports Windows x64 integer/pointer calls.  This is enough to call
// simple Windows APIs

pub const ArgType = enum(u8) {
    i32 = 0,
    u32 = 1,
    ptr = 2,
    cstr = 3,

    pub fn fromByte(value: u8) !ArgType {
        return switch (value) {
            0 => .i32,
            1 => .u32,
            2 => .ptr,
            3 => .cstr,
            else => error.InvalidForeignType,
        };
    }
};

pub const Import = struct {
    library: *anyopaque,
    address: *const anyopaque,
    arg_count: u8,
    arg_types: [constants.max_foreign_args]ArgType,
};

// Neccessary Windows API functions for dynamic library loading and symbol resolution
extern "kernel32" fn LoadLibraryA(library_name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(library: *anyopaque, symbol_name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(library: *anyopaque) callconv(.winapi) i32;

// Resolve a foreign function import by loading the specified library and looking up the symbol address. Returns an Import struct on success.
pub fn resolve(library_name: []const u8, symbol_name: []const u8, arg_types: []const ArgType) !Import {

    // Foreign calls are only supported on Windows for now
    if (builtin.os.tag != .windows) return error.ForeignCallsUnsupported;

    // Validate input parameters
    if (library_name.len == 0 or symbol_name.len == 0) return error.InvalidForeignImport;
    if (symbol_name.len > 255 or arg_types.len > constants.max_foreign_args) return error.InvalidForeignImport;

    if (library_name.len > 255) return error.InvalidForeignImport;

    var library_z: [256:0]u8 = undefined;
    @memcpy(library_z[0..library_name.len], library_name);
    library_z[library_name.len] = 0;

    // Load the library and get the symbol address
    const library = LoadLibraryA(library_z[0..library_name.len :0].ptr) orelse return error.ForeignLibraryNotFound;
    errdefer _ = FreeLibrary(library);

    var symbol_z: [256:0]u8 = undefined;
    @memcpy(symbol_z[0..symbol_name.len], symbol_name);
    symbol_z[symbol_name.len] = 0;

    const address = GetProcAddress(library, symbol_z[0..symbol_name.len :0].ptr) orelse {
        std.debug.print("Foreign symbol not found: {s}!{s}\n", .{ library_name, symbol_name });
        return error.ForeignSymbolNotFound;
    };

    var types: [constants.max_foreign_args]ArgType = @splat(.u32);
    @memcpy(types[0..arg_types.len], arg_types);

    return .{
        .library = library,
        .address = address,
        .arg_count = @intCast(arg_types.len),
        .arg_types = types,
    };
}

// free loaded library
pub fn close(import: *Import) void {
    _ = FreeLibrary(import.library);
}

const Value = extern union {
    i32: i32,
    u32: u32,
    ptr: ?*anyopaque,
};

// Invoke a foreign function through libffi. Keeping the argument storage here
// ensures each ffi value pointer refers to an object with the exact size and
// representation described by its ffi_type.
pub fn invoke(import: *const Import, args: [constants.max_foreign_args]usize) !u32 {
    var cif: ffi.ffi_cif = undefined;
    var types: [constants.max_foreign_args][*c]ffi.ffi_type = undefined;
    var values: [constants.max_foreign_args]Value = undefined;
    var value_pointers: [constants.max_foreign_args]?*anyopaque = undefined;

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
