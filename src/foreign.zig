const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");

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

    const address = GetProcAddress(library, symbol_z[0..symbol_name.len :0].ptr) orelse
        return error.ForeignSymbolNotFound;

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

// invoke a forign function
pub fn invoke(import: *const Import, args: [constants.max_foreign_args]usize) usize {
    // VIG foreign calls are Windows x64 integer/pointer calls only. All of
    // these argument types occupy one ABI word, so arity is sufficient here.
    return switch (import.arg_count) {
        0 => @as(*const fn () callconv(.winapi) usize, @ptrCast(import.address))(),
        1 => @as(*const fn (usize) callconv(.winapi) usize, @ptrCast(import.address))(args[0]),
        2 => @as(*const fn (usize, usize) callconv(.winapi) usize, @ptrCast(import.address))(args[0], args[1]),
        3 => @as(*const fn (usize, usize, usize) callconv(.winapi) usize, @ptrCast(import.address))(args[0], args[1], args[2]),
        4 => @as(*const fn (usize, usize, usize, usize) callconv(.winapi) usize, @ptrCast(import.address))(args[0], args[1], args[2], args[3]),
        else => unreachable,
    };
}
