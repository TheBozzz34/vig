const std = @import("std");
const constants = @import("constants.zig");
const utils = @import("utils.zig");

pub const VM = struct {
    // Array-based memory and stack
    memory: []u8,
    stack: [256]i32,

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
            .sp = 0,
            .ip = 0,
        };
    }

    pub fn deinit(self: *VM, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
    }
};

pub fn run(self: *VM) !void {
    while (self.ip < self.memory.len) {
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
                if (self.ip + 4 > self.memory.len) return error.SegmentFault;
                const value = std.mem.readInt(i32, self.memory[self.ip..][0..4], .little);
                self.ip += 4;

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
        }
    }
}
