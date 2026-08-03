const constants = @import("constants.zig");
const machine = @import("machine.zig");
const std = @import("std");

const Io = std.Io;

// int to enum conversion for OpCode
pub fn intToEnum(opcode: u8) !constants.OpCode {
    return switch (opcode) {
        0 => constants.OpCode.halt,
        1 => constants.OpCode.push,
        2 => constants.OpCode.add,
        3 => constants.OpCode.sub,
        4 => constants.OpCode.print,
        else => return error.InvalidInstruction,
    };
}

pub fn loadProgramFromFile(vm: *machine.VM, io: Io, allocator: std.mem.Allocator, path: []const u8) !void {
    // Read one byte beyond VM capacity so loadProgram can distinguish an
    // over-sized file from one that exactly fills VM memory.
    const program = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(vm.memory.len + 1));
    defer allocator.free(program);

    try vm.loadProgram(program);
}
