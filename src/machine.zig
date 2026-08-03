const std = @import("std");
const constants = @import("constants.zig");
const utils = @import("utils.zig");

pub const VM = struct {
    // memory and stack, arrays of bytes and ints
    memory: [constants.memory_size]u8,
    stack: [constants.stack_size]i32,

    // data segment for load and store ops
    data: [constants.data_size]i32,

    // data segment for call and return ops
    call_stack: [constants.call_stack_size]usize,
    csp: usize,

    // Number of bytes occupied by the currently loaded program. Memory after this point is not executable code.
    program_len: usize = 0,

    // Pointers/Registers
    ip: usize = 0, // Instruction Pointer
    sp: usize = 0, // Stack Pointer

    // reset vm state
    pub fn reset(self: *VM) void {
        @memset(&self.stack, 0);
        @memset(&self.data, 0);
        @memset(&self.call_stack, 0);

        self.program_len = 0;
        self.ip = 0;
        self.sp = 0;
        self.csp = 0;
    }

    // initialize the VM with default values
    pub fn init() VM {
        return .{
            .memory = @splat(0),
            .stack = @splat(0),
            .data = @splat(0),
            .call_stack = @splat(0),
            .csp = 0,
            .program_len = 0,
            .sp = 0,
            .ip = 0,
        };
    }

    // Load a program into the VM's memory, a program is just a sequence of bytes
    pub fn loadProgram(self: *VM, program: []const u8) !void {
        if (program.len > self.memory.len) {
            return error.ProgramTooLarge;
        }

        self.reset();

        @memcpy(self.memory[0..program.len], program);
        self.program_len = program.len;
    }

    // loop through instructions in memory, fetch, decode, and execute them
    pub fn run(self: *VM) !void {
        while (self.ip < self.program_len) {
            // Fetch the next instruction
            const raw_op = self.memory[self.ip];

            // Decode the instruction into an enum
            const op = utils.intToEnum(raw_op) catch {
                std.debug.print("Invalid OpCode: {x}\n", .{raw_op});
                return error.InvalidInstruction;
            };
            self.ip += 1;

            // switch on enum
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
                    const result = @addWithOverflow(a, b);

                    if (result[1] != 0) return error.IntegerOverflow;

                    self.sp -= 1;
                    self.stack[self.sp - 1] = result[0];
                },

                .sub => {
                    if (self.sp < 2) return error.StackUnderflow;

                    const b = self.stack[self.sp - 1];
                    const a = self.stack[self.sp - 2];
                    const result = @subWithOverflow(a, b);

                    if (result[1] != 0) return error.IntegerOverflow;

                    self.sp -= 1;
                    self.stack[self.sp - 1] = result[0];
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

                    if (a == std.math.minInt(i32) and b == -1) {
                        return error.IntegerOverflow;
                    }

                    self.sp -= 1;
                    self.stack[self.sp - 1] = @rem(a, b);
                },
                .eq => try utils.binaryComparison(self, utils.comparisons.eq),
                .ne => try utils.binaryComparison(self, utils.comparisons.ne),
                .lt => try utils.binaryComparison(self, utils.comparisons.lt),
                .lte => try utils.binaryComparison(self, utils.comparisons.lte),
                .gt => try utils.binaryComparison(self, utils.comparisons.gt),
                .gte => try utils.binaryComparison(self, utils.comparisons.gte),
                .jmp => {
                    const target = try utils.readU32(self);

                    if (target >= self.program_len) {
                        return error.SegmentFault;
                    }

                    self.ip = target;
                },
                .jmp_zero => {
                    const target = try utils.readU32(self);

                    if (target >= self.program_len) {
                        return error.SegmentFault;
                    }

                    if (self.sp == 0) {
                        return error.StackUnderflow;
                    }

                    self.sp -= 1;
                    const condition = self.stack[self.sp];

                    if (condition == 0) {
                        self.ip = target;
                    }
                },
                .jmp_not_zero => {
                    const target = try utils.readU32(self);

                    if (target >= self.program_len) {
                        return error.SegmentFault;
                    }

                    if (self.sp == 0) {
                        return error.StackUnderflow;
                    }

                    self.sp -= 1;
                    const condition = self.stack[self.sp];

                    if (condition != 0) {
                        self.ip = target;
                    }
                },
                .load => {
                    const raw_address = try utils.readU32(self);
                    const address: usize = @intCast(raw_address);

                    if (address >= self.data.len) {
                        return error.SegmentFault;
                    }

                    if (self.sp >= self.stack.len) {
                        return error.StackOverflow;
                    }

                    self.stack[self.sp] = self.data[address];
                    self.sp += 1;
                },
                .store => {
                    const raw_address = try utils.readU32(self);
                    const address: usize = @intCast(raw_address);

                    if (address >= self.data.len) {
                        return error.SegmentFault;
                    }

                    if (self.sp == 0) {
                        return error.StackUnderflow;
                    }

                    self.sp -= 1;
                    self.data[address] = self.stack[self.sp];
                },
                .call => {
                    const target = try utils.readU32(self);

                    if (target >= self.program_len) {
                        return error.SegmentFault;
                    }

                    if (self.csp >= self.call_stack.len) {
                        return error.CallStackOverflow;
                    }

                    self.call_stack[self.csp] = self.ip;
                    self.csp += 1;
                    self.ip = target;
                },
                .ret => {
                    if (self.csp == 0) {
                        return error.CallStackUnderflow;
                    }

                    self.csp -= 1;
                    self.ip = self.call_stack[self.csp];
                },
            }
        }
    }
};

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

    try vm.run();
    try std.testing.expectEqual(program.len, vm.program_len);
    try std.testing.expectEqual(@as(usize, 1), vm.sp);
}
