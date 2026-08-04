const std = @import("std");
const bytecode = @import("vig_bytecode");
const constants = @import("constants.zig");
const foreign = @import("foreign.zig");
const utils = @import("utils.zig");

const container = bytecode.container;
const verify = bytecode.verify;
const Io = std.Io;

pub const VM = struct {
    // The memory and the stack: an array of bytes and an array of integers.
    memory: [constants.memory_size]u8,
    stack: [constants.stack_size]i32,

    // The data segment for the `load` and `store` instructions.
    data: [constants.data_size]i32,

    // The call stack for the `call` and `ret` instructions.
    call_stack: [constants.call_stack_size]usize,
    csp: usize,

    foreign_imports: [bytecode.foreign.max_imports]?foreign.Import,
    foreign_import_count: usize,

    // The number of bytes of executable instructions at the start of the memory.
    // Execution and each jump target must stay inside this length. Therefore the
    // VM cannot execute the static data.
    code_len: usize = 0,

    // The number of bytes in the complete program image: the code region, then
    // the static-data region. An address from the program must stay inside this
    // length. Therefore `print_string` and a `cstr` argument can use the static
    // data.
    program_len: usize = 0,

    // The destination for the output of `print` and `print_string`. This writer
    // is the stdout of the guest program. The diagnostic messages of the host go
    // to `std.log`. Therefore the two are apart, and a test can collect the
    // output of the program.
    output: *Io.Writer,

    // The location at which the verifier refused the last program. The VM holds
    // this value and writes no message. Therefore the caller can write its own
    // message.
    verification_failure: ?verify.Failure = null,

    // The registers.
    ip: usize = 0, // the instruction pointer
    sp: usize = 0, // the stack pointer

    // Set the state of the VM to its initial values.
    pub fn reset(self: *VM) void {
        self.clearForeignImports();
        @memset(&self.stack, 0);
        @memset(&self.data, 0);
        @memset(&self.call_stack, 0);

        self.code_len = 0;
        self.program_len = 0;
        self.verification_failure = null;
        self.ip = 0;
        self.sp = 0;
        self.csp = 0;
    }

    pub fn deinit(self: *VM) void {
        self.clearForeignImports();
    }

    // Make a VM that has the default values. `output` receives the output of the
    // program. It must stay in existence longer than the VM. `reset` does not
    // change it.
    pub fn init(output: *Io.Writer) VM {
        return .{
            .memory = @splat(0),
            .stack = @splat(0),
            .data = @splat(0),
            .call_stack = @splat(0),
            .csp = 0,
            .foreign_imports = @splat(null),
            .foreign_import_count = 0,
            .code_len = 0,
            .program_len = 0,
            .verification_failure = null,
            .output = output,
            .sp = 0,
            .ip = 0,
        };
    }

    // Load a program into the memory of the VM. The file can be a current
    // container, a version 1 container, or bare code with no header.
    // `container.parse` finds which form the file has.
    pub fn loadProgram(self: *VM, program: []const u8) !void {
        self.reset();
        errdefer self.clearForeignImports();

        const image = try container.parse(program);
        if (image.imageLen() > self.memory.len) return error.ProgramTooLarge;

        // Only the current format keeps the code apart from the static data. The
        // verifier needs this split to read the instructions and to decode no
        // string. An older program runs with the checks in `run` on each
        // instruction.
        if (image.kind.separatesData()) try self.verifyImage(image);

        try self.loadForeignImports(image);

        @memcpy(self.memory[0..image.code.len], image.code);
        @memcpy(self.memory[image.code.len..][0..image.data.len], image.data);

        self.code_len = image.code.len;
        self.program_len = image.imageLen();
        self.ip = image.header.entry_point;
    }

    // Read each instruction in the memory. Decode it, then execute it.
    pub fn run(self: *VM) !void {
        while (self.ip < self.code_len) {
            // Read the next instruction.
            const raw_op = self.memory[self.ip];

            // Decode the instruction to an enum value.
            const op = bytecode.OpCode.fromByte(raw_op) catch {
                // This message goes directly to stderr and not to `std.log`. A
                // trap is a fault in the program and not an error in the host. A
                // test of a trap must not look like a test that failed.
                std.debug.print("Invalid OpCode 0x{x:0>2} at code offset {d}\n", .{ raw_op, self.ip });
                return error.InvalidInstruction;
            };
            self.ip += 1;

            // Select the operation for this opcode.
            switch (op) {
                .halt => return,

                .push => {
                    // Read the next 4 bytes as an i32 operand.
                    if (self.code_len - self.ip < 4) return error.SegmentFault;
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

                    // The result of minInt / -1 is too large for an i32.
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

                    if (target >= self.code_len) {
                        return error.SegmentFault;
                    }

                    self.ip = target;
                },
                .jmp_zero => {
                    const target = try utils.readU32(self);

                    if (target >= self.code_len) {
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

                    if (target >= self.code_len) {
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

                    if (target >= self.code_len) {
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
                    if (self.ip >= self.code_len) return error.SegmentFault;
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
                    // The address comes from the stack, and not from the operand
                    // of `load`. Therefore the program can calculate a data
                    // address while it runs.
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

    // Check a data-segment address from the stack. A negative value has no
    // unsigned equivalent. Therefore a negative value gives a fault. It does not
    // become a large positive value.
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

    // Find the library address and the symbol address for each declaration in
    // the import table of the container. The container reader has already checked
    // the size of the table and the import count.
    fn loadForeignImports(self: *VM, image: container.Image) !void {
        std.debug.assert(image.header.import_count <= self.foreign_imports.len);

        var iterator = image.importIterator();
        while (try iterator.next()) |import| {
            self.foreign_imports[self.foreign_import_count] = try foreign.resolve(
                import.library,
                import.symbol,
                import.argTypes(),
            );
            self.foreign_import_count += 1;
        }
    }

    // Make sure that the code region is safe to execute before the VM runs any of
    // it. The vig-bytecode verifier gives the list of the checks.
    fn verifyImage(self: *VM, image: container.Image) !void {
        // One mark for each code byte. The VM has already checked the image
        // against the size of the VM memory.
        var scratch: [constants.memory_size]verify.Mark = undefined;

        var failure: verify.Failure = undefined;
        verify.verify(.{
            .code = image.code,
            .entry_point = image.header.entry_point,
            .import_count = image.header.import_count,
            .data_slots = constants.data_size,
        }, &scratch, &failure) catch |err| {
            self.verification_failure = failure;
            return err;
        };
    }

    fn callForeign(self: *VM, import_index: u8) !void {
        const index: usize = import_index;
        if (index >= self.foreign_import_count) return error.InvalidForeignImport;
        const import = &(self.foreign_imports[index] orelse return error.InvalidForeignImport);
        const arg_count: usize = import.arg_count;
        if (self.sp < arg_count) return error.StackUnderflow;

        var args: [bytecode.foreign.max_args]usize = @splat(0);
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

    // A guest pointer is an offset into the complete program image. That image
    // includes the code and the static data. Therefore a program can give a
    // string that it declared with `asciiz`.
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

// A VM and the buffer that collects the output of its program. Therefore a test
// can check what the program printed.
const Harness = struct {
    collected: Io.Writer.Allocating,
    vm: VM,

    fn init() Harness {
        return .{
            .collected = .init(std.testing.allocator),
            // `start` sets `vm.output` after the structure has its final
            // address. A pointer from this position becomes invalid when the
            // function gives a copy of the structure to the caller.
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

// Run `program` and compare its output with the exact expected output. This test
// does not use the assembler.
fn expectOutput(program: []const u8, expected: []const u8) !void {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(program);
    try harness.vm.run();
    try std.testing.expectEqualStrings(expected, harness.written());
}

// The same as `expectOutput`, but the program must trap. The test also compares
// the output from before the trap, because a trap must not remove an earlier
// effect.
fn expectTrap(program: []const u8, expected_error: anyerror, expected_output: []const u8) !void {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(program);
    try std.testing.expectError(expected_error, harness.vm.run());
    try std.testing.expectEqualStrings(expected_output, harness.written());
}

fn opByte(code: bytecode.OpCode) u8 {
    return @intFromEnum(code);
}

// Encode `push value`. This function keeps a test program easy to read.
fn push(value: i32) [5]u8 {
    var bytes: [5]u8 = undefined;
    bytes[0] = opByte(.push);
    std.mem.writeInt(i32, bytes[1..5], value, .little);
    return bytes;
}

// Encode an instruction that has a 4-byte address operand or target operand.
fn withAddress(code: bytecode.OpCode, address: u32) [5]u8 {
    var bytes: [5]u8 = undefined;
    bytes[0] = opByte(code);
    std.mem.writeInt(u32, bytes[1..5], address, .little);
    return bytes;
}

// Make a container in the current format in memory. Then the test uses the loader
// in the same way as an assembled program.
fn buildContainer(layout: container.Layout) ![]u8 {
    const bytes = try std.testing.allocator.alloc(u8, try container.encodedSize(layout));
    errdefer std.testing.allocator.free(bytes);
    std.debug.assert(try container.write(layout, bytes) == bytes.len);
    return bytes;
}

// Tests ----------------------------------------------------------------------

test "execution stops at the loaded program boundary" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

    const program = [_]u8{
        @intFromEnum(bytecode.OpCode.push),
        1,
        0,
        0,
        0,
    };
    try vm.loadProgram(&program);

    // If `run` used the total size of the VM memory in place of `code_len`, the
    // VM would execute this byte as an unknown instruction.
    vm.memory[program.len] = 0xff;

    try vm.run();
    try std.testing.expectEqual(program.len, vm.code_len);
    try std.testing.expectEqual(program.len, vm.program_len);
    try std.testing.expectEqual(@as(usize, 1), vm.sp);
}

test "a container starts at its entry point and maps static data after the code" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

    // First a prologue that the entry point goes past, then the program itself.
    // The string is in the static-data region. Therefore its address is the length
    // of the code.
    const prologue = push(111) ++ [_]u8{opByte(.halt)};
    const greeting = 13;
    const code = prologue ++ push(greeting) ++ [_]u8{ opByte(.print_string), opByte(.halt) };
    try std.testing.expectEqual(@as(usize, greeting), code.len);

    const program = try buildContainer(.{
        .code = &code,
        .data = "hello\x00",
        .entry_point = prologue.len,
    });
    defer std.testing.allocator.free(program);

    try vm.loadProgram(program);
    try std.testing.expectEqual(@as(usize, prologue.len), vm.ip);
    try std.testing.expectEqual(@as(usize, code.len), vm.code_len);
    try std.testing.expectEqual(@as(usize, code.len + 6), vm.program_len);

    try vm.run();
    try std.testing.expectEqualStrings("hello\n", harness.written());
    // The prologue did not run. Therefore its value is not on the stack.
    try std.testing.expectEqual(@as(usize, 1), vm.sp);
    try std.testing.expectEqual(@as(i32, greeting), vm.stack[0]);
}

test "static data is never executed, whatever it decodes to" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    // A byte that is not an opcode, directly after the code region.
    const program = try buildContainer(.{ .code = &[_]u8{opByte(.halt)}, .data = &[_]u8{0xfe} });
    defer std.testing.allocator.free(program);

    try harness.vm.loadProgram(program);
    try harness.vm.run();
    try std.testing.expectEqual(@as(usize, 1), harness.vm.code_len);
    try std.testing.expectEqual(@as(usize, 2), harness.vm.program_len);
}

test "a container is verified before any of it runs" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

    // A `jmp` into the static-data region. The file is correct, but the program
    // is not.
    const code = withAddress(.jmp, 6) ++ [_]u8{opByte(.halt)};
    const program = try buildContainer(.{ .code = &code, .data = "x\x00" });
    defer std.testing.allocator.free(program);

    try std.testing.expectError(error.TargetOutOfRange, vm.loadProgram(program));
    try std.testing.expectEqual(@as(usize, 0), vm.verification_failure.?.offset);
    // The VM loaded no program. Therefore it can run no instruction.
    try std.testing.expectEqual(@as(usize, 0), vm.code_len);
    try vm.run();
    try std.testing.expectEqualStrings("", harness.written());
}

test "a program larger than VM memory is rejected" {
    const code: [constants.memory_size]u8 = @splat(opByte(.halt));
    const program = try buildContainer(.{ .code = &code, .data = "!" });
    defer std.testing.allocator.free(program);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try std.testing.expectError(error.ProgramTooLarge, harness.vm.loadProgram(program));
}

test "bare code and version 1 containers still load" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

    // Code with no header, as in the first VIG programs.
    try vm.loadProgram(&(push(1) ++ [_]u8{ opByte(.print), opByte(.halt) }));
    try vm.run();
    try std.testing.expectEqualStrings("1\n", harness.written());

    // A version 1 container has no split of the code from the data. Therefore the
    // string is in the code region at offset 7, and no verifier checks the
    // program.
    const legacy = "VIGF" ++ [_]u8{ 1, 0 } ++
        push(7) ++ [_]u8{ opByte(.print_string), opByte(.halt) } ++ "again\x00";
    try vm.loadProgram(legacy);
    try std.testing.expectEqual(@as(usize, 13), vm.code_len);
    try std.testing.expectEqual(vm.code_len, vm.program_len);
    try vm.run();
    try std.testing.expectEqualStrings("1\nagain\n", harness.written());
}

test "resolves and invokes a zero-argument Windows API" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = &harness.vm;

    const program = "VIGF" ++ [_]u8{ 1, 1, 12, 19, 0 } ++
        "kernel32.dllGetCurrentProcessId" ++ [_]u8{
            @intFromEnum(bytecode.OpCode.foreign_call), 0,
            @intFromEnum(bytecode.OpCode.halt),
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
        @intFromEnum(bytecode.OpCode.push), 7, 0, 0, 0,
        @intFromEnum(bytecode.OpCode.print_string),
        @intFromEnum(bytecode.OpCode.halt),
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

    const program = [_]u8{ @intFromEnum(bytecode.OpCode.halt), 'x' };
    try vm.loadProgram(&program);
    try std.testing.expectError(error.InvalidGuestPointer, vm.guestCString(0));
    try std.testing.expectError(error.UnterminatedGuestString, vm.guestCString(1));
}

test "print writes program output to the injected writer" {
    try expectOutput(&(push(42) ++ [_]u8{ opByte(.print), opByte(.halt) }), "42\n");
}

test "arithmetic operates on the top two values" {
    // Each case leaves one value on the stack and prints it.
    const cases = [_]struct { code: bytecode.OpCode, a: i32, b: i32, expected: []const u8 }{
        .{ .code = .add, .a = 7, .b = 5, .expected = "12\n" },
        .{ .code = .sub, .a = 7, .b = 5, .expected = "2\n" },
        .{ .code = .mul, .a = 7, .b = 5, .expected = "35\n" },
        // The division truncates toward zero. It does not round down.
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
    const cases = [_]struct { code: bytecode.OpCode, expected: []const u8 }{
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
    // `dup`, then `print` two times: 1 1
    try expectOutput(
        &(push(1) ++ [_]u8{ opByte(.dup), opByte(.print), opByte(.pop), opByte(.print), opByte(.halt) }),
        "1\n1\n",
    );
    // `swap` moves the lower value to the top. The prints then give 1, then 2.
    try expectOutput(
        &(push(1) ++ push(2) ++ [_]u8{ opByte(.swap), opByte(.print), opByte(.pop), opByte(.print), opByte(.halt) }),
        "1\n2\n",
    );
}

test "conditional jumps consume their condition" {
    // With a condition of 0, `jmp_zero` goes past the first `push`.
    const taken = push(0) ++ withAddress(.jmp_zero, 15) ++
        push(111) ++ // the VM does not run this
        push(222) ++ [_]u8{ opByte(.print), opByte(.halt) };
    try expectOutput(&taken, "222\n");

    // With a condition that is not 0, the VM continues at the next instruction.
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
    // Put 77 into data[4] with a calculated address (2 + 2). Then read it in the
    // same way.
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
    // Put 10, 20 and 30 into data[0..3]. Then add them in a loop that calculates
    // each address.
    var program = std.ArrayList(u8).empty;
    defer program.deinit(std.testing.allocator);

    inline for (.{ 10, 20, 30 }, 0..) |value, index| {
        try program.appendSlice(std.testing.allocator, &push(value));
        try program.appendSlice(std.testing.allocator, &withAddress(.store, index));
    }

    // data[100] holds the total. data[101] holds the index.
    try program.appendSlice(std.testing.allocator, &push(0));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, 100));
    try program.appendSlice(std.testing.allocator, &push(0));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, 101));

    const loop_start: u32 = @intCast(program.items.len);
    // total = total + data[index]
    try program.appendSlice(std.testing.allocator, &withAddress(.load, 100));
    try program.appendSlice(std.testing.allocator, &withAddress(.load, 101));
    try program.append(std.testing.allocator, opByte(.load_at));
    try program.append(std.testing.allocator, opByte(.add));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, 100));
    // index = index + 1
    try program.appendSlice(std.testing.allocator, &withAddress(.load, 101));
    try program.appendSlice(std.testing.allocator, &push(1));
    try program.append(std.testing.allocator, opByte(.add));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, 101));
    // Continue the loop while the index is not 3.
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
    // A division by zero, after a print that worked.
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
    // The result of minInt / -1 is too large for an i32.
    try expectTrap(
        &(push(std.math.minInt(i32)) ++ push(-1) ++ [_]u8{opByte(.div)}),
        error.IntegerOverflow,
        "",
    );
    try expectTrap(&[_]u8{ opByte(.add), opByte(.halt) }, error.StackUnderflow, "");
    try expectTrap(&[_]u8{ opByte(.ret), opByte(.halt) }, error.CallStackUnderflow, "");
    // The VM gives an error for an opcode byte that has no instruction. It does
    // not go past the byte.
    try expectTrap(&[_]u8{0xfe}, error.InvalidInstruction, "");
}

test "indirect addressing faults outside the data segment" {
    // `data_size` is 256. Therefore 256 and each negative address are outside the
    // segment.
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
