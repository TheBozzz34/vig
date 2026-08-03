const constants = @import("constants.zig");

pub const test_program = [_]u8{
    // push 10
    @intFromEnum(constants.OpCode.push),
    10,
    0,
    0,
    0,

    // push 20
    @intFromEnum(constants.OpCode.push),
    20,
    0,
    0,
    0,

    // add: 10 + 20 = 30
    @intFromEnum(constants.OpCode.add),

    // print 30
    @intFromEnum(constants.OpCode.print),

    // push 100
    @intFromEnum(constants.OpCode.push),
    100,
    0,
    0,
    0,

    // push 35
    @intFromEnum(constants.OpCode.push),
    35,
    0,
    0,
    0,

    // sub: 100 - 35 = 65
    @intFromEnum(constants.OpCode.sub),

    // print 65
    @intFromEnum(constants.OpCode.print),

    // push -20
    @intFromEnum(constants.OpCode.push),
    0xec,
    0xff,
    0xff,
    0xff,

    // push 5
    @intFromEnum(constants.OpCode.push),
    5,
    0,
    0,
    0,

    // add: -20 + 5 = -15
    @intFromEnum(constants.OpCode.add),

    // print -15
    @intFromEnum(constants.OpCode.print),

    @intFromEnum(constants.OpCode.halt),
};
