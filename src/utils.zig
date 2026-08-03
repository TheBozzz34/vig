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
        5 => constants.OpCode.dup,
        6 => constants.OpCode.pop,
        7 => constants.OpCode.swap,
        8 => constants.OpCode.mul,
        9 => constants.OpCode.div,
        10 => constants.OpCode.mod,
        11 => constants.OpCode.eq,
        12 => constants.OpCode.ne,
        13 => constants.OpCode.lt,
        14 => constants.OpCode.lte,
        15 => constants.OpCode.gt,
        16 => constants.OpCode.gte,
        17 => constants.OpCode.jmp,
        18 => constants.OpCode.jmp_zero,
        19 => constants.OpCode.jmp_not_zero,
        20 => constants.OpCode.load,
        21 => constants.OpCode.store,
        22 => constants.OpCode.call,
        23 => constants.OpCode.ret,
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

pub fn binaryComparison(
    self: *machine.VM,
    comptime compare: fn (i32, i32) bool,
) !void {
    if (self.sp < 2) return error.StackUnderflow;

    const b = self.stack[self.sp - 1];
    const a = self.stack[self.sp - 2];

    self.sp -= 1;
    self.stack[self.sp - 1] = if (compare(a, b)) 1 else 0;
}

pub const comparisons = struct {
    pub fn eq(a: i32, b: i32) bool {
        return a == b;
    }

    pub fn ne(a: i32, b: i32) bool {
        return a != b;
    }

    pub fn lt(a: i32, b: i32) bool {
        return a < b;
    }

    pub fn lte(a: i32, b: i32) bool {
        return a <= b;
    }

    pub fn gt(a: i32, b: i32) bool {
        return a > b;
    }

    pub fn gte(a: i32, b: i32) bool {
        return a >= b;
    }
};

pub fn readU32(self: *machine.VM) !u32 {
    if (self.ip > self.program_len or self.program_len - self.ip < 4) {
        return error.SegmentFault;
    }

    const value = std.mem.readInt(
        u32,
        self.memory[self.ip..][0..4],
        .little,
    );

    self.ip += 4;
    return value;
}
