const constants = @import("constants.zig");

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
