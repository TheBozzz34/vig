const std = @import("std");
const constants = @import("constants.zig");
const foreign = @import("foreign.zig");
const utils = @import("utils.zig");

const Io = std.Io;

pub const VM = struct {
    // memory and stack, arrays of bytes and ints
    memory: [constants.memory_size]u8,
    stack: [constants.stack_size]i32,

    // data segment for load and store ops
    data: [constants.data_size]i32,

    // data segment for call and return ops
    call_stack: [constants.call_stack_size]usize,
    csp: usize,

    foreign_imports: [constants.max_foreign_imports]?foreign.Import,
    foreign_import_count: usize,

    // Number of bytes occupied by the currently loaded program. Memory after this point is not executable code.
    program_len: usize = 0,

    // Where `print` and `print_string` send program output. Host diagnostics
    // still go to std.log; this is the guest program's own stdout, so it stays
    // separable from the VM's own chatter and can be captured in tests.
    output: *Io.Writer,

    // Pointers/Registers
    ip: usize = 0, // Instruction Pointer
    sp: usize = 0, // Stack Pointer

    // reset vm state
    pub fn reset(self: *VM) void {
        self.clearForeignImports();
        @memset(&self.stack, 0);
        @memset(&self.data, 0);
        @memset(&self.call_stack, 0);

        self.program_len = 0;
        self.ip = 0;
        self.sp = 0;
        self.csp = 0;
    }

    pub fn deinit(self: *VM) void {
        self.clearForeignImports();
    }

    // initialize the VM with default values. `output` receives program output
    // and must outlive the VM; `reset` deliberately leaves it alone.
    pub fn init(output: *Io.Writer) VM {
        return .{
            .memory = @splat(0),
            .stack = @splat(0),
            .data = @splat(0),
            .call_stack = @splat(0),
            .csp = 0,
            .foreign_imports = @splat(null),
            .foreign_import_count = 0,
            .program_len = 0,
            .output = output,
            .sp = 0,
            .ip = 0,
        };
    }

    // Load a program into the VM's memory, a program is just a sequence of bytes
    pub fn loadProgram(self: *VM, program: []const u8) !void {
        self.reset();
        errdefer self.clearForeignImports();

        const code = try self.loadForeignImports(program);
        if (code.len > self.memory.len) return error.ProgramTooLarge;

        @memcpy(self.memory[0..code.len], code);
        self.program_len = code.len;
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
                    try self.output.print("{d}\n", .{self.stack[self.sp - 1]});
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
                .foreign_call => {
                    if (self.ip >= self.program_len) return error.SegmentFault;
                    const import_index = self.memory[self.ip];
                    self.ip += 1;
                    try self.callForeign(import_index);
                },
                .print_string => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const string = try self.guestCString(self.stack[self.sp - 1]);
                    try self.output.print("{s}\n", .{string});
                },
                .load_at => {
                    // Unlike `load`, the address comes from the stack, so data
                    // addresses can be computed at runtime.
                    if (self.sp == 0) return error.StackUnderflow;

                    const address = try self.dataAddress(self.stack[self.sp - 1]);
                    self.stack[self.sp - 1] = self.data[address];
                },
                .store_at => {
                    if (self.sp < 2) return error.StackUnderflow;

                    const address = try self.dataAddress(self.stack[self.sp - 1]);
                    const value = self.stack[self.sp - 2];

                    self.sp -= 2;
                    self.data[address] = value;
                },
            }
        }
    }

    // Validate a stack-supplied data-segment address. Negative values cannot be
    // folded into the unsigned range, so they fault rather than wrap.
    fn dataAddress(self: *VM, value: i32) !usize {
        if (value < 0) return error.SegmentFault;
        const address: usize = @intCast(value);
        if (address >= self.data.len) return error.SegmentFault;
        return address;
    }

    fn clearForeignImports(self: *VM) void {
        for (&self.foreign_imports) |*entry| {
            if (entry.*) |*import| foreign.close(import);
            entry.* = null;
        }
        self.foreign_import_count = 0;
    }

    fn loadForeignImports(self: *VM, program: []const u8) ![]const u8 {
        const magic = "VIGF";
        if (program.len < magic.len or !std.mem.eql(u8, program[0..magic.len], magic)) return program;
        if (program.len < 6) return error.InvalidProgramHeader;
        if (program[4] != 1) return error.UnsupportedProgramVersion;

        const import_count: usize = program[5];
        if (import_count > constants.max_foreign_imports) return error.TooManyForeignImports;

        var offset: usize = 6;
        for (0..import_count) |index| {
            if (program.len -| offset < 3) return error.InvalidProgramHeader;
            const library_len: usize = program[offset];
            const symbol_len: usize = program[offset + 1];
            const arg_count: usize = program[offset + 2];
            offset += 3;

            if (arg_count > constants.max_foreign_args or program.len -| offset < arg_count) {
                return error.InvalidProgramHeader;
            }

            var arg_types: [constants.max_foreign_args]foreign.ArgType = @splat(.u32);
            for (0..arg_count) |arg_index| {
                arg_types[arg_index] = try foreign.ArgType.fromByte(program[offset + arg_index]);
            }
            offset += arg_count;

            const names_len = library_len + symbol_len;
            if (program.len -| offset < names_len) return error.InvalidProgramHeader;
            const library_name = program[offset .. offset + library_len];
            const symbol_name = program[offset + library_len .. offset + names_len];
            offset += names_len;

            self.foreign_imports[index] = try foreign.resolve(library_name, symbol_name, arg_types[0..arg_count]);
            self.foreign_import_count += 1;
        }

        return program[offset..];
    }

    fn callForeign(self: *VM, import_index: u8) !void {
        const index: usize = import_index;
        if (index >= self.foreign_import_count) return error.InvalidForeignImport;
        const import = &(self.foreign_imports[index] orelse return error.InvalidForeignImport);
        const arg_count: usize = import.arg_count;
        if (self.sp < arg_count) return error.StackUnderflow;

        var args: [constants.max_foreign_args]usize = @splat(0);
        var arg_index = arg_count;
        while (arg_index > 0) {
            arg_index -= 1;
            self.sp -= 1;
            args[arg_index] = try self.marshalForeignArgument(import.arg_types[arg_index], self.stack[self.sp]);
        }

        if (self.sp >= self.stack.len) return error.StackOverflow;
        const result = try foreign.invoke(import, args);
        self.stack[self.sp] = @bitCast(result);
        self.sp += 1;
    }

    fn marshalForeignArgument(self: *VM, arg_type: foreign.ArgType, value: i32) !usize {
        return switch (arg_type) {
            .i32 => @bitCast(@as(isize, value)),
            .u32 => blk: {
                const bits: u32 = @bitCast(value);
                break :blk @as(usize, bits);
            },
            .ptr => try self.guestPointer(value, false),
            .cstr => try self.guestPointer(value, true),
        };
    }

    fn guestPointer(self: *VM, value: i32, require_terminator: bool) !usize {
        if (value == 0) return 0;
        if (value < 0) return error.InvalidGuestPointer;
        const offset: usize = @intCast(value);
        if (offset >= self.program_len) return error.InvalidGuestPointer;
        if (require_terminator) _ = try self.guestCString(value);
        return @intFromPtr(self.memory[offset..].ptr);
    }

    fn guestCString(self: *VM, value: i32) ![]const u8 {
        if (value <= 0) return error.InvalidGuestPointer;
        const offset: usize = @intCast(value);
        if (offset >= self.program_len) return error.InvalidGuestPointer;

        const bytes = self.memory[offset..self.program_len];
        const terminator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.UnterminatedGuestString;
        return bytes[0..terminator];
    }
};

// Test harness ---------------------------------------------------------------

// A VM plus the buffer its program output is collected into, so tests can
// assert on what a program actually printed.
const Harness = struct {
    collected: Io.Writer.Allocating,
    vm: VM,

    fn init() Harness {
        return .{
            .collected = .init(std.testing.allocator),
            // `vm.output` is patched in `start` once the struct has its final
            // address; taking it here would dangle after the copy is returned.
            .vm = VM.init(undefined),
        };
    }

    fn start(self: *Harness) void {
        self.vm.output = &self.collected.writer;
    }

    fn deinit(self: *Harness) void {
        self.vm.deinit();
        self.collected.deinit();
    }

    fn written(self: *Harness) []const u8 {
        return self.collected.written();
    }
};

// Assemble-free golden test: run `program` and assert on its exact output.
fn expectOutput(program: []const u8, expected: []const u8) !void {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(program);
    try harness.vm.run();
    try std.testing.expectEqualStrings(expected, harness.written());
}

// As above, but the program is expected to trap. Output printed before the trap
// is still asserted, since a trap should not discard prior side effects.
fn expectTrap(program: []const u8, expected_error: anyerror, expected_output: []const u8) !void {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(program);
    try std.testing.expectError(expected_error, harness.vm.run());
    try std.testing.expectEqualStrings(expected_output, harness.written());
}

fn opByte(code: constants.OpCode) u8 {
    return @intFromEnum(code);
}

// Encode `push value` so test programs stay readable.
fn push(value: i32) [5]u8 {
    var bytes: [5]u8 = undefined;
    bytes[0] = opByte(.push);
    std.mem.writeInt(i32, bytes[1..5], value, .little);
    return bytes;
}

// Encode an instruction taking a 4-byte address/target operand.
fn withAddress(code: constants.OpCode, address: u32) [5]u8 {
    var bytes: [5]u8 = undefined;
    bytes[0] = opByte(code);
    std.mem.writeInt(u32, bytes[1..5], address, .little);
    return bytes;
}

// Tests ----------------------------------------------------------------------

test "execution stops at the loaded program boundary" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

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

test "resolves and invokes a zero-argument Windows API" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

    const program = "VIGF" ++ [_]u8{ 1, 1, 12, 19, 0 } ++
        "kernel32.dllGetCurrentProcessId" ++ [_]u8{
            @intFromEnum(constants.OpCode.foreign_call), 0,
            @intFromEnum(constants.OpCode.halt),
        };
    try vm.loadProgram(program);
    try vm.run();

    try std.testing.expectEqual(@as(usize, 1), vm.sp);
    try std.testing.expect(vm.stack[0] > 0);
}

test "print_string prints a VIG-managed string and retains its address" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

    const program = [_]u8{
        @intFromEnum(constants.OpCode.push), 7, 0, 0, 0,
        @intFromEnum(constants.OpCode.print_string),
        @intFromEnum(constants.OpCode.halt),
        'h', 'e', 'l', 'l', 'o', 0,
    };
    try vm.loadProgram(&program);
    try vm.run();

    try std.testing.expectEqual(@as(usize, 1), vm.sp);
    try std.testing.expectEqual(@as(i32, 7), vm.stack[0]);
    try std.testing.expectEqualStrings("hello\n", harness.written());
}

test "guest strings must be non-null and NUL-terminated within the program" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

    const program = [_]u8{ @intFromEnum(constants.OpCode.halt), 'x' };
    try vm.loadProgram(&program);
    try std.testing.expectError(error.InvalidGuestPointer, vm.guestCString(0));
    try std.testing.expectError(error.UnterminatedGuestString, vm.guestCString(1));
}

test "print writes program output to the injected writer" {
    try expectOutput(&(push(42) ++ [_]u8{ opByte(.print), opByte(.halt) }), "42\n");
}

test "arithmetic operates on the top two values" {
    // Each case leaves one value on the stack and prints it.
    const cases = [_]struct { code: constants.OpCode, a: i32, b: i32, expected: []const u8 }{
        .{ .code = .add, .a = 7, .b = 5, .expected = "12\n" },
        .{ .code = .sub, .a = 7, .b = 5, .expected = "2\n" },
        .{ .code = .mul, .a = 7, .b = 5, .expected = "35\n" },
        // Truncated toward zero, not floored.
        .{ .code = .div, .a = -7, .b = 2, .expected = "-3\n" },
        .{ .code = .mod, .a = -7, .b = 2, .expected = "-1\n" },
    };

    for (cases) |case| {
        const program = push(case.a) ++ push(case.b) ++
            [_]u8{ opByte(case.code), opByte(.print), opByte(.halt) };
        try expectOutput(&program, case.expected);
    }
}

test "comparisons push 1 or 0" {
    const cases = [_]struct { code: constants.OpCode, expected: []const u8 }{
        .{ .code = .eq, .expected = "0\n" },
        .{ .code = .ne, .expected = "1\n" },
        .{ .code = .lt, .expected = "1\n" },
        .{ .code = .lte, .expected = "1\n" },
        .{ .code = .gt, .expected = "0\n" },
        .{ .code = .gte, .expected = "0\n" },
    };

    for (cases) |case| {
        const program = push(3) ++ push(9) ++
            [_]u8{ opByte(case.code), opByte(.print), opByte(.halt) };
        try expectOutput(&program, case.expected);
    }
}

test "stack manipulation reorders and discards values" {
    // dup then print twice: 1 1
    try expectOutput(
        &(push(1) ++ [_]u8{ opByte(.dup), opByte(.print), opByte(.pop), opByte(.print), opByte(.halt) }),
        "1\n1\n",
    );
    // swap brings the lower value back to the top: 2 then 1
    try expectOutput(
        &(push(1) ++ push(2) ++ [_]u8{ opByte(.swap), opByte(.print), opByte(.pop), opByte(.print), opByte(.halt) }),
        "1\n2\n",
    );
}

test "conditional jumps consume their condition" {
    // jmp_zero with a zero condition skips the first print.
    const taken = push(0) ++ withAddress(.jmp_zero, 15) ++
        push(111) ++ // skipped
        push(222) ++ [_]u8{ opByte(.print), opByte(.halt) };
    try expectOutput(&taken, "222\n");

    // A non-zero condition falls through instead.
    const not_taken = push(1) ++ withAddress(.jmp_zero, 15) ++
        push(111) ++ [_]u8{ opByte(.print), opByte(.halt) };
    try expectOutput(&not_taken, "111\n");
}

test "call and ret run a subroutine and resume after it" {
    // 0: call 7   5: print   6: halt   |   7: push 5   12: ret
    const program = withAddress(.call, 7) ++
        [_]u8{ opByte(.print), opByte(.halt) } ++
        push(5) ++ [_]u8{opByte(.ret)};
    try expectOutput(&program, "5\n");
}

test "load and store move values through the data segment" {
    const program = push(99) ++ withAddress(.store, 3) ++
        withAddress(.load, 3) ++ [_]u8{ opByte(.print), opByte(.halt) };
    try expectOutput(&program, "99\n");
}

test "load_at and store_at address the data segment at runtime" {
    // data[4] = 77 via a computed address (2 + 2), then read it back the same way.
    const program = push(77) ++ push(2) ++ push(2) ++ [_]u8{opByte(.add)} ++
        [_]u8{opByte(.store_at)} ++
        push(4) ++ [_]u8{ opByte(.load_at), opByte(.print), opByte(.halt) };
    try expectOutput(&program, "77\n");
}

test "store_at consumes both the value and the address" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const program = push(5) ++ push(1) ++ [_]u8{ opByte(.store_at), opByte(.halt) };
    try harness.vm.loadProgram(&program);
    try harness.vm.run();

    try std.testing.expectEqual(@as(usize, 0), harness.vm.sp);
    try std.testing.expectEqual(@as(i32, 5), harness.vm.data[1]);
}

test "indirect addressing walks an array in the data segment" {
    // data[0..3] = {10, 20, 30}, then sum them with a computed-address loop.
    var program = std.ArrayList(u8).empty;
    defer program.deinit(std.testing.allocator);

    inline for (.{ 10, 20, 30 }, 0..) |value, index| {
        try program.appendSlice(std.testing.allocator, &push(value));
        try program.appendSlice(std.testing.allocator, &withAddress(.store, index));
    }

    // data[100] = running total, data[101] = cursor
    try program.appendSlice(std.testing.allocator, &push(0));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, 100));
    try program.appendSlice(std.testing.allocator, &push(0));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, 101));

    const loop_start: u32 = @intCast(program.items.len);
    // total += data[cursor]
    try program.appendSlice(std.testing.allocator, &withAddress(.load, 100));
    try program.appendSlice(std.testing.allocator, &withAddress(.load, 101));
    try program.append(std.testing.allocator, opByte(.load_at));
    try program.append(std.testing.allocator, opByte(.add));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, 100));
    // cursor += 1
    try program.appendSlice(std.testing.allocator, &withAddress(.load, 101));
    try program.appendSlice(std.testing.allocator, &push(1));
    try program.append(std.testing.allocator, opByte(.add));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, 101));
    // loop while cursor != 3
    try program.appendSlice(std.testing.allocator, &withAddress(.load, 101));
    try program.appendSlice(std.testing.allocator, &push(3));
    try program.append(std.testing.allocator, opByte(.ne));
    try program.appendSlice(std.testing.allocator, &withAddress(.jmp_not_zero, loop_start));

    try program.appendSlice(std.testing.allocator, &withAddress(.load, 100));
    try program.append(std.testing.allocator, opByte(.print));
    try program.append(std.testing.allocator, opByte(.halt));

    try expectOutput(program.items, "60\n");
}

test "traps report the failure and keep output printed before it" {
    // Division by zero, after a successful print.
    try expectTrap(
        &(push(1) ++ [_]u8{ opByte(.print), opByte(.pop) } ++ push(1) ++ push(0) ++ [_]u8{opByte(.div)}),
        error.DivisionByZero,
        "1\n",
    );
    try expectTrap(
        &(push(std.math.maxInt(i32)) ++ push(1) ++ [_]u8{opByte(.add)}),
        error.IntegerOverflow,
        "",
    );
    // minInt / -1 has no i32 representation.
    try expectTrap(
        &(push(std.math.minInt(i32)) ++ push(-1) ++ [_]u8{opByte(.div)}),
        error.IntegerOverflow,
        "",
    );
    try expectTrap(&[_]u8{ opByte(.add), opByte(.halt) }, error.StackUnderflow, "");
    try expectTrap(&[_]u8{ opByte(.ret), opByte(.halt) }, error.CallStackUnderflow, "");
    // An unmapped opcode byte is rejected rather than skipped.
    try expectTrap(&[_]u8{0xfe}, error.InvalidInstruction, "");
}

test "indirect addressing faults outside the data segment" {
    // data_size is 256, so 256 and any negative address are out of range.
    try expectTrap(&(push(256) ++ [_]u8{ opByte(.load_at), opByte(.halt) }), error.SegmentFault, "");
    try expectTrap(&(push(-1) ++ [_]u8{ opByte(.load_at), opByte(.halt) }), error.SegmentFault, "");
    try expectTrap(
        &(push(0) ++ push(-1) ++ [_]u8{ opByte(.store_at), opByte(.halt) }),
        error.SegmentFault,
        "",
    );
}

test "the data stack overflows rather than growing without bound" {
    var program = std.ArrayList(u8).empty;
    defer program.deinit(std.testing.allocator);
    for (0..constants.stack_size + 1) |_| {
        try program.appendSlice(std.testing.allocator, &push(0));
    }
    try expectTrap(program.items, error.StackOverflow, "");
}
