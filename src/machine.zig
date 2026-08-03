const std = @import("std");
const constants = @import("constants.zig");
const utils = @import("utils.zig");

pub const VM = struct {
    // Array-based memory and stack
    memory: []u8,
    stack: [256]i32,

    // Number of bytes occupied by the currently loaded program. This is the
    // execution boundary; memory after this point is not executable code.
    program_len: usize = 0,

    // Pointers/Registers
    ip: usize = 0, // Instruction Pointer
    sp: usize = 0, // Stack Pointer

    pub fn init(allocator: std.mem.Allocator, memory_size: usize) !VM {
        const mem = try allocator.alloc(u8, memory_size);
        // Zero out the allocated memory to ensure a clean state
        @memset(mem, 0);
        return VM{
            .memory = mem,
            .stack = @splat(0),
            .program_len = 0,
            .sp = 0,
            .ip = 0,
        };
    }

    pub fn loadProgram(self: *VM, program: []const u8) !void {
        if (program.len > self.memory.len) return error.ProgramTooLarge;

        // Clear the old program and any stale bytes before copying the new one.
        @memset(self.memory, 0);
        @memcpy(self.memory[0..program.len], program);

        self.program_len = program.len;
        self.ip = 0;
        self.sp = 0;
        self.stack = @splat(0);
    }

    pub fn deinit(self: *VM, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
        self.memory = undefined;
        self.program_len = 0;
    }
};

pub fn run(self: *VM) !void {
    while (self.ip < self.program_len) {
        // Fetch
        const raw_op = self.memory[self.ip];

        // Decode
        const op = utils.intToEnum(raw_op) catch {
            std.debug.print("Invalid OpCode: {x}\n", .{raw_op});
            return error.InvalidInstruction;
        };
        self.ip += 1;

        // Execute
        switch (op) {
            .halt => return,

            .push => {
                // Fetch next 4 bytes as an i32 operand
                if (self.program_len - self.ip < 4) return error.SegmentFault;
                const value = std.mem.readInt(i32, self.memory[self.ip..][0..4], .little);
                self.ip += 4;

                if (self.sp >= self.stack.len) return error.StackOverflow;

                self.stack[self.sp] = value;
                self.sp += 1;
            },

            .add => {
                if (self.sp < 2) return error.StackUnderflow;
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1; // Pop b, replace a with result

                // Catch overflow explicitly using Zig primitives
                self.stack[self.sp - 1] = @addWithOverflow(a, b)[0];
            },

            .sub => {
                if (self.sp < 2) return error.StackUnderflow;
                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                self.sp -= 1;
                self.stack[self.sp - 1] = @subWithOverflow(a, b)[0];
            },

            .print => {
                if (self.sp == 0) return error.StackUnderflow;
                std.debug.print("{d}\n", .{self.stack[self.sp - 1]});
            },

            .dup => {
                if (self.sp == 0) return error.StackUnderflow;
                if (self.sp >= self.stack.len) return error.StackOverflow;

                self.stack[self.sp] = self.stack[self.sp - 1];
                self.sp += 1;
            },
            .pop => {
                if (self.sp == 0) return error.StackUnderflow;
                self.sp -= 1;
            },
            .swap => {
                if (self.sp < 2) return error.StackUnderflow;

                const a = self.stack[self.sp - 1];
                self.stack[self.sp - 1] = self.stack[self.sp - 2];
                self.stack[self.sp - 2] = a;
            },
            .mul => {
                if (self.sp < 2) return error.StackUnderflow;

                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];
                const result = @mulWithOverflow(a, b);

                if (result[1] != 0) return error.IntegerOverflow;

                self.sp -= 1;
                self.stack[self.sp - 1] = result[0];
            },
            .div => {
                if (self.sp < 2) return error.StackUnderflow;

                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];

                if (b == 0) return error.DivisionByZero;

                // minInt / -1 cannot fit in i32.
                if (a == std.math.minInt(i32) and b == -1) {
                    return error.IntegerOverflow;
                }

                self.sp -= 1;
                self.stack[self.sp - 1] = @divTrunc(a, b);
            },
            .mod => {
                if (self.sp < 2) return error.StackUnderflow;

                const b = self.stack[self.sp - 1];
                const a = self.stack[self.sp - 2];

                if (b == 0) return error.DivisionByZero;

                self.sp -= 1;
                self.stack[self.sp - 1] = @rem(a, b);
            },
            .eq => try utils.binaryComparison(self, utils.comparisons.eq),
            .ne => try utils.binaryComparison(self, utils.comparisons.ne),
            .lt => try utils.binaryComparison(self, utils.comparisons.lt),
            .lte => try utils.binaryComparison(self, utils.comparisons.lte),
            .gt => try utils.binaryComparison(self, utils.comparisons.gt),
            .gte => try utils.binaryComparison(self, utils.comparisons.gte),
        }
    }
}

test "execution stops at the loaded program boundary" {
    var vm = try VM.init(std.testing.allocator, 8);
    defer vm.deinit(std.testing.allocator);

    const program = [_]u8{
        @intFromEnum(constants.OpCode.push),
        1,
        0,
        0,
        0,
    };
    try vm.loadProgram(&program);

    // This would be executed as an invalid instruction if run used the VM's
    // total memory size instead of program_len.
    vm.memory[program.len] = 0xff;

    try run(&vm);
    try std.testing.expectEqual(program.len, vm.program_len);
    try std.testing.expectEqual(@as(usize, 1), vm.sp);
}
