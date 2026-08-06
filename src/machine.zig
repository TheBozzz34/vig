const std = @import("std");
const bytecode = @import("vig_bytecode");
const constants = @import("constants.zig");
const foreign = @import("foreign.zig");
const utils = @import("utils.zig");

const container = bytecode.container;
const verify = bytecode.verify;
const Io = std.Io;

/// What the VM must remember about one active call.
///
/// A `call` makes one of these. An `enter` in the called function then fills in the
/// two counts and the base of its storage. A function without locals never calls
/// `enter`, so its frame stays at zero slots and costs no memory.
const CallFrame = struct {
    /// The code offset to continue at when the function returns.
    return_ip: usize,
    /// The stack pointer at the moment of the call, above the arguments. `ret`
    /// returns the stack to this height, less the arguments that `enter` consumed.
    /// Therefore a function that leaves a value behind cannot corrupt its caller.
    operand_base: usize,
    /// The address of slot 0 of the frame. This is meaningful only after `enter`.
    frame_base: usize = 0,
    /// The value to restore `frame_pointer` to on return.
    saved_frame_pointer: usize,
    /// Whether the function called `enter`.
    ///
    /// This decides whether `ret` returns the operand stack to the height it had
    /// before the call. Only a function that declared its arguments can have them
    /// counted, and without that count the VM does not know how many values the
    /// function took. Truncating then would put back values that the function
    /// consumed, which is worse than leaving the stack alone. Therefore a function
    /// that declares a frame gets the convention enforced, and one that does not
    /// keeps its own stack in order, as every VIG program did before frames existed.
    entered: bool = false,
    /// The arguments and the locals that `enter` asked for.
    arguments: u16 = 0,
    locals: u16 = 0,

    /// The number of slots that the frame has.
    fn slots(self: CallFrame) usize {
        return @as(usize, self.arguments) + self.locals;
    }
};

/// The value that fills an unused entry of the call stack.
const empty_frame: CallFrame = .{
    .return_ip = 0,
    .operand_base = 0,
    .saved_frame_pointer = 0,
};

/// The width of one frame slot. A slot holds an i32, which is what the operand stack
/// holds. A wider C type needs more than one slot, and the compiler decides that.
const slot_size = 4;

/// The virtual machine.
///
/// This structure holds the guest memory, the stacks and the verifier scratch
/// inline, so it is far larger than a machine register and it grows with
/// `constants.memory_size`.
pub const VM = struct {
    // The guest address space: one array of bytes. Every instruction that touches
    // guest data addresses this array by byte, and a label, a pointer and the
    // operand of `load` all mean the same kind of number.
    memory: [constants.memory_size]u8,

    // The evaluation stack.
    stack: [constants.stack_size]i32,

    // The call stack for the `call` and `ret` instructions.
    call_stack: [constants.call_stack_size]CallFrame,
    csp: usize,

    // The lowest address that a frame uses. Frame memory grows down from the end of
    // guest memory, and the program image sits at the start of it. Therefore the two
    // grow towards each other, and one comparison finds the collision.
    //
    // This value is the end of memory when no function has a frame.
    frame_pointer: usize = 0,

    foreign_imports: [bytecode.foreign.max_imports]?foreign.Import,
    foreign_import_count: usize,

    // The number of bytes of executable instructions at the start of the memory.
    // Execution and each jump target must stay inside this length.
    code_len: usize = 0,

    // The number of bytes in the complete program image: the code region, then the
    // static-data region, then the zero-filled region that the header declares. An
    // address from the program must stay inside this length.
    //
    // The zero-filled region is part of the image but not part of the file.
    // Therefore a program can declare a large array, and the file stays small.
    program_len: usize = 0,

    // The destination for the output of `print` and `print_string`. This writer
    // is the stdout of the guest program.
    output: *Io.Writer,

    // The source for `read_i32`. Like output, this is injected so a caller can
    // connect stdin while a test supplies deterministic in-memory input.
    input: *Io.Reader,

    // The location at which the verifier refused the last program. The VM holds
    // this value and writes no message.
    verification_failure: ?verify.Failure = null,

    // The registers.
    ip: usize = 0, // the instruction pointer
    sp: usize = 0, // the stack pointer

    // Working space for the bytecode verifier: one mark for each byte of the code
    // region. The verifier needs `verify.scratchSize(code_len)` marks, and the
    // code region is never larger than the memory of the VM.
    //
    // This buffer is a field and not a local of `verifyImage`, because a local
    // puts it on the call stack. At the present `memory_size` that costs 4 KiB,
    // which a stack absorbs; at the size that a C program needs it does not. The
    // cost of the field is one byte of memory for each byte of guest memory, and
    // the VM pays it once rather than on each load.
    verify_scratch: [constants.memory_size]verify.Mark,

    // Set the state of the VM to its initial values.
    pub fn reset(self: *VM) void {
        self.clearForeignImports();
        @memset(&self.stack, 0);
        @memset(&self.memory, 0);
        @memset(&self.call_stack, empty_frame);
        // The marks belong to the program that made them. `call_indirect` reads them
        // while a program runs, so a mark that an earlier program left would answer
        // for code that is no longer there.
        @memset(&self.verify_scratch, .unknown);

        self.code_len = 0;
        self.program_len = 0;
        self.verification_failure = null;
        self.ip = 0;
        self.sp = 0;
        self.csp = 0;
        // No function has a frame, so frame memory has used nothing. It grows down
        // from the end of memory as each `enter` runs.
        self.frame_pointer = self.memory.len;
    }

    pub fn deinit(self: *VM) void {
        self.clearForeignImports();
    }

    // Give a VM its default values, in the storage that the caller supplies. The
    // streams must stay in existence longer than the VM. `reset` does not change
    pub fn init(self: *VM, input: *Io.Reader, output: *Io.Writer) void {
        self.* = .{
            .memory = @splat(0),
            .stack = @splat(0),
            .call_stack = @splat(empty_frame),
            .csp = 0,
            .frame_pointer = constants.memory_size,
            .foreign_imports = @splat(null),
            .foreign_import_count = 0,
            .code_len = 0,
            .program_len = 0,
            .verification_failure = null,
            .input = input,
            .output = output,
            .sp = 0,
            .ip = 0,
            .verify_scratch = @splat(.unknown),
        };
    }

    // Load a program into the memory of the VM. The file can be a current container
    // or bare code with no header. `container.parse` finds which form the file has.
    pub fn loadProgram(self: *VM, program: []const u8) !void {
        self.reset();
        errdefer self.clearForeignImports();

        const image = try container.parse(program);

        // A version 1 container and a version 2 container are refused. In each one
        // the operand of `load` and of `store` is an index into a segment of i32
        // slots, and that operand is now a byte address in this memory. The
        // instruction did not change, so nothing in the file says which meaning it
        // has. A VM that ran such a file would compute a wrong answer and report
        // nothing. Therefore it must refuse the file instead.
        if (!image.kind.isExecutable()) return error.ObsoleteProgramFormat;

        if (image.imageLen() > self.memory.len) return error.ProgramTooLarge;

        // Only a container keeps the code apart from the static data. The verifier
        // needs this split to read the instructions and to decode no string. Bare
        // code runs with the checks in `run` on each instruction.
        if (image.kind.separatesData()) try self.verifyImage(image);

        try self.loadForeignImports(image);

        // The file holds the code and the static data. The zero-filled region needs
        // no copy, because `reset` has already cleared the whole of memory.
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
                // The same six values read as unsigned. `eq` and `ne` need no such
                // pair, because equal bits are equal whatever they mean.
                .lt_u => try utils.binaryComparison(self, utils.comparisons.lt_u),
                .lte_u => try utils.binaryComparison(self, utils.comparisons.lte_u),
                .gt_u => try utils.binaryComparison(self, utils.comparisons.gt_u),
                .gte_u => try utils.binaryComparison(self, utils.comparisons.gte_u),
                // Unsigned division needs no overflow case. The signed form traps on
                // the one pair that has no result, and that pair is `minInt / -1`,
                // which unsigned values cannot express.
                .div_u => {
                    if (self.sp < 2) return error.StackUnderflow;
                    const a: u32 = @bitCast(self.stack[self.sp - 2]);
                    const b: u32 = @bitCast(self.stack[self.sp - 1]);
                    if (b == 0) return error.DivisionByZero;

                    self.sp -= 1;
                    self.stack[self.sp - 1] = @bitCast(a / b);
                },
                .mod_u => {
                    if (self.sp < 2) return error.StackUnderflow;
                    const a: u32 = @bitCast(self.stack[self.sp - 2]);
                    const b: u32 = @bitCast(self.stack[self.sp - 1]);
                    if (b == 0) return error.DivisionByZero;

                    self.sp -= 1;
                    self.stack[self.sp - 1] = @bitCast(a % b);
                },
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
                    const address = try self.operandAddress(try utils.readU32(self), .read);

                    if (self.sp >= self.stack.len) {
                        return error.StackOverflow;
                    }

                    self.stack[self.sp] = self.readMemory(i32, address);
                    self.sp += 1;
                },
                .store => {
                    const address = try self.operandAddress(try utils.readU32(self), .write);

                    if (self.sp == 0) {
                        return error.StackUnderflow;
                    }

                    self.sp -= 1;
                    self.writeMemory(u32, address, @bitCast(self.stack[self.sp]));
                },
                .call => {
                    const target = try utils.readU32(self);

                    if (target >= self.code_len) {
                        return error.SegmentFault;
                    }

                    if (self.csp >= self.call_stack.len) {
                        return error.CallStackOverflow;
                    }

                    // The frame has no storage yet. An `enter` in the called
                    // function gives it some. A function that needs none never calls
                    // `enter`, and its frame stays at zero slots.
                    self.call_stack[self.csp] = .{
                        .return_ip = self.ip,
                        .operand_base = self.sp,
                        .saved_frame_pointer = self.frame_pointer,
                    };
                    self.csp += 1;
                    self.ip = target;
                },
                .call_indirect => {
                    if (self.sp == 0) return error.StackUnderflow;

                    self.sp -= 1;
                    const value = self.stack[self.sp];
                    // The target is an address in the code region, so it is a
                    // positive number below the end of that region. A negative one
                    // has no unsigned equivalent, exactly as for a data address.
                    if (value < 0) return error.SegmentFault;
                    const target: u32 = @intCast(value);
                    if (target >= self.code_len) return error.SegmentFault;

                    // A direct call has a verified target, because the verifier read
                    // the operand before the run. This target was on the stack, so no
                    // read of the code could find it. Therefore the check happens
                    // here, the first time a call goes to this address.
                    try self.verifyCallTarget(target);

                    if (self.csp >= self.call_stack.len) return error.CallStackOverflow;

                    // The target is off the stack, so `operand_base` is the height
                    // above the arguments, as it is for a direct call.
                    self.call_stack[self.csp] = .{
                        .return_ip = self.ip,
                        .operand_base = self.sp,
                        .saved_frame_pointer = self.frame_pointer,
                    };
                    self.csp += 1;
                    self.ip = target;
                },
                .enter => {
                    const shape = try utils.readFrameShape(self);
                    try self.enterFrame(shape);
                },
                .ret => try self.returnFromCall(false),
                .ret_val => try self.returnFromCall(true),
                .load_local => {
                    const index = try utils.readU16(self);
                    const address = try self.localAddress(index);

                    if (self.sp >= self.stack.len) return error.StackOverflow;
                    self.stack[self.sp] = self.readMemory(i32, address);
                    self.sp += 1;
                },
                .store_local => {
                    const index = try utils.readU16(self);
                    const address = try self.localAddress(index);

                    if (self.sp == 0) return error.StackUnderflow;
                    self.sp -= 1;
                    self.writeMemory(u32, address, @bitCast(self.stack[self.sp]));
                },
                .local_addr => {
                    const index = try utils.readU16(self);
                    const address = try self.localAddress(index);

                    if (self.sp >= self.stack.len) return error.StackOverflow;
                    // A frame is inside guest memory, so the address of a local is an
                    // ordinary address. Therefore a pointer to a local is the same
                    // kind of value as a pointer to a global.
                    self.stack[self.sp] = @intCast(address);
                    self.sp += 1;
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
                // The address comes from the stack, and not from the operand of
                // `load`. Therefore the program can calculate an address while it
                // runs. Each of these two is now the same instruction as its
                // 32-bit byte-addressed form, and the older name is kept so a
                // program that used it needs no change.
                .load_at => try self.loadFrom(i32),
                .store_at => try self.storeTo(u32),
                .@"and" => {
                    if (self.sp < 2) return error.StackUnderflow;
                    self.sp -= 1;
                    self.stack[self.sp - 1] &= self.stack[self.sp];
                },
                .@"or" => {
                    if (self.sp < 2) return error.StackUnderflow;
                    self.sp -= 1;
                    self.stack[self.sp - 1] |= self.stack[self.sp];
                },
                .xor => {
                    if (self.sp < 2) return error.StackUnderflow;
                    self.sp -= 1;
                    self.stack[self.sp - 1] ^= self.stack[self.sp];
                },
                .not => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.stack[self.sp - 1] = ~self.stack[self.sp - 1];
                },
                .shl => {
                    if (self.sp < 2) return error.StackUnderflow;
                    const value: u32 = @bitCast(self.stack[self.sp - 2]);
                    const count: u5 = @truncate(@as(u32, @bitCast(self.stack[self.sp - 1])));
                    self.sp -= 1;
                    self.stack[self.sp - 1] = @bitCast(value << count);
                },
                .shr_u => {
                    if (self.sp < 2) return error.StackUnderflow;
                    const value: u32 = @bitCast(self.stack[self.sp - 2]);
                    const count: u5 = @truncate(@as(u32, @bitCast(self.stack[self.sp - 1])));
                    self.sp -= 1;
                    self.stack[self.sp - 1] = @bitCast(value >> count);
                },
                // The arithmetic shift. The value keeps its type, so `>>` fills the
                // vacated bits with the sign bit rather than with zeros. That is the
                // difference between this instruction and `shr_u`.
                .shr_s => {
                    if (self.sp < 2) return error.StackUnderflow;
                    const value = self.stack[self.sp - 2];
                    const count: u5 = @truncate(@as(u32, @bitCast(self.stack[self.sp - 1])));
                    self.sp -= 1;
                    self.stack[self.sp - 1] = value >> count;
                },
                .rotl => {
                    if (self.sp < 2) return error.StackUnderflow;
                    const value: u32 = @bitCast(self.stack[self.sp - 2]);
                    const count: u5 = @truncate(@as(u32, @bitCast(self.stack[self.sp - 1])));
                    self.sp -= 1;
                    self.stack[self.sp - 1] = @bitCast(std.math.rotl(u32, value, count));
                },
                // The wrapping arithmetic. Each one gives the low 32 bits of the
                // result and never traps, which is what unsigned arithmetic in C is
                // defined to do.
                .add_wrap => {
                    if (self.sp < 2) return error.StackUnderflow;
                    self.sp -= 1;
                    self.stack[self.sp - 1] +%= self.stack[self.sp];
                },
                .sub_wrap => {
                    if (self.sp < 2) return error.StackUnderflow;
                    self.sp -= 1;
                    self.stack[self.sp - 1] -%= self.stack[self.sp];
                },
                .mul_wrap => {
                    if (self.sp < 2) return error.StackUnderflow;
                    self.sp -= 1;
                    self.stack[self.sp - 1] *%= self.stack[self.sp];
                },
                .read_i32 => {
                    // Do not consume input when there is nowhere to put the
                    // result.
                    if (self.sp >= self.stack.len) return error.StackOverflow;
                    self.stack[self.sp] = try self.readI32();
                    self.sp += 1;
                },
                .read_byte => {
                    // EOF is data for this instruction rather than a trap, so
                    // a program can loop until it sees -1.
                    if (self.sp >= self.stack.len) return error.StackOverflow;
                    try self.output.flush();
                    self.stack[self.sp] = self.input.takeByte() catch |err| switch (err) {
                        error.EndOfStream => -1,
                        error.ReadFailed => return error.InputReadFailed,
                    };
                    self.sp += 1;
                },
                .print_hex => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const bits: u32 = @bitCast(self.stack[self.sp - 1]);
                    try self.output.print("{x:0>8}\n", .{bits});
                },
                .write_byte => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const byte: u8 = @truncate(@as(u32, @bitCast(self.stack[self.sp - 1])));
                    try self.output.writeAll(&[_]u8{byte});
                    self.sp -= 1;
                },

                // Byte-addressed access to guest memory. The type gives the width
                // of the access and, for a narrow load, whether the value keeps
                // its sign.
                .load8_u => try self.loadFrom(u8),
                .load8_s => try self.loadFrom(i8),
                .load16_u => try self.loadFrom(u16),
                .load16_s => try self.loadFrom(i16),
                .load32 => try self.loadFrom(i32),
                .store8 => try self.storeTo(u8),
                .store16 => try self.storeTo(u16),
                .store32 => try self.storeTo(u32),
            }
        }
    }

    // Read one whitespace-delimited signed decimal integer. Output is flushed
    // first so an interactive prompt is visible before the VM blocks on stdin.
    fn readI32(self: *VM) !i32 {
        try self.output.flush();

        var byte: u8 = undefined;
        while (true) {
            byte = self.input.peekByte() catch |err| return switch (err) {
                error.EndOfStream => error.EndOfInput,
                error.ReadFailed => error.InputReadFailed,
            };
            if (!std.ascii.isWhitespace(byte)) break;
            _ = self.input.takeByte() catch unreachable;
        }

        const negative = byte == '-';
        if (negative or byte == '+') {
            _ = self.input.takeByte() catch unreachable;
            byte = self.input.peekByte() catch |err| return switch (err) {
                error.EndOfStream => error.InvalidInput,
                error.ReadFailed => error.InputReadFailed,
            };
        }
        if (!std.ascii.isDigit(byte)) return error.InvalidInput;

        const limit: u32 = if (negative) 2147483648 else 2147483647;
        var magnitude: u32 = 0;
        while (true) {
            byte = self.input.peekByte() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.InputReadFailed,
            };
            if (!std.ascii.isDigit(byte)) {
                if (!std.ascii.isWhitespace(byte)) return error.InvalidInput;
                break;
            }

            const digit: u32 = byte - '0';
            if (magnitude > (limit - digit) / 10) return error.IntegerOverflow;
            magnitude = magnitude * 10 + digit;
            _ = self.input.takeByte() catch unreachable;
        }

        if (!negative) return @intCast(magnitude);
        if (magnitude == 2147483648) return std.math.minInt(i32);
        return -@as(i32, @intCast(magnitude));
    }

    // Guest memory ------------------------------------------------------------
    //
    // Each read and each write of guest data goes through this section. No
    // instruction in `run` reaches `self.memory` on its own.
    //
    // There is one address space. It is `memory`, and every address is a byte offset
    // into it. A label, a pointer, the operand of `load` and an address that a
    // program calculated are all the same kind of number. Therefore a program can
    // take the address of a global and use it, and that is what makes a pointer, an
    // array and a structure possible.

    // The first address that a guest pointer cannot use. A pointer names a byte of
    // the program image: the code, then the static data, then the zero-filled
    // region. A program can therefore build a string in that region and print it.
    //
    // The limit is the image and not the whole of memory. Memory above the image
    // starts as zeros, so every address in it would look like the end of a string,
    // and `UnterminatedGuestString` would stop meaning anything.
    fn guestPointerLimit(self: *const VM) usize {
        return self.program_len;
    }

    // Call frames -------------------------------------------------------------
    //
    // A frame is storage in guest memory that belongs to one active call. Frame
    // memory grows down from the end of memory while the program image sits at the
    // start, so the two grow towards each other and a collision means the program
    // has run out of room.
    //
    // A frame holds the arguments first and then the locals, so slot 0 is the first
    // argument. `enter` takes the arguments off the operand stack and copies them in.
    // Therefore an argument and a local are the same kind of thing once a function is
    // running, and `local_addr` gives the address of either. A C parameter is an
    // lvalue, and that is what this arrangement buys.

    /// Give the running function its storage.
    fn enterFrame(self: *VM, shape: bytecode.encode.FrameShape) !void {
        // A frame belongs to a call. The entry point of a program is not called, so a
        // function with locals is reached with `call` and the entry point is a stub
        // that calls it. This is what a C runtime does with `main`.
        if (self.csp == 0) return error.EnterOutsideCall;

        const frame = &self.call_stack[self.csp - 1];
        // One `enter` for each call. A second one would lose the first frame.
        if (frame.entered) return error.FrameAlreadyEntered;

        const arguments: usize = shape.arguments;
        if (self.sp < arguments) return error.StackUnderflow;

        const size = @as(usize, shape.slots()) * slot_size;
        // Frame memory grows down. Therefore it runs out when it reaches the image.
        if (size > self.frame_pointer or self.frame_pointer - size < self.program_len) {
            return error.FrameMemoryExhausted;
        }
        const base = self.frame_pointer - size;

        // The arguments are on the operand stack, the first one deepest. Copy them
        // into the frame in that order, so slot 0 is the first argument.
        self.sp -= arguments;
        for (0..arguments) |index| {
            self.writeMemory(u32, base + index * slot_size, @bitCast(self.stack[self.sp + index]));
        }

        // A local starts at zero. The bytes of this frame may hold what an earlier
        // call left there, so they need clearing and cannot be assumed to be zero.
        const locals_start = base + arguments * slot_size;
        @memset(self.memory[locals_start .. base + size], 0);

        frame.entered = true;
        frame.frame_base = base;
        frame.arguments = shape.arguments;
        frame.locals = shape.locals;
        self.frame_pointer = base;
    }

    /// Return to the caller. `with_value` keeps the top of the operand stack.
    fn returnFromCall(self: *VM, with_value: bool) !void {
        if (self.csp == 0) return error.CallStackUnderflow;

        const value = if (with_value) blk: {
            if (self.sp == 0) return error.StackUnderflow;
            break :blk self.stack[self.sp - 1];
        } else undefined;

        self.csp -= 1;
        const frame = self.call_stack[self.csp];

        // Return the operand stack to the height it had before the call, less the
        // arguments that `enter` took. Therefore a function that leaves values behind
        // cannot corrupt its caller, and the caller needs no knowledge of what the
        // function did with its stack.
        //
        // A function that declared no frame keeps its own stack in order. See the
        // `entered` field.
        if (frame.entered) {
            self.sp = frame.operand_base - frame.arguments;
            if (with_value) {
                if (self.sp >= self.stack.len) return error.StackOverflow;
                self.stack[self.sp] = value;
                self.sp += 1;
            }
        }

        self.frame_pointer = frame.saved_frame_pointer;
        self.ip = frame.return_ip;
    }

    /// The address of one slot of the frame of the running function.
    fn localAddress(self: *const VM, index: u16) !usize {
        if (self.csp == 0) return error.NoActiveFrame;

        const frame = self.call_stack[self.csp - 1];
        if (index >= frame.slots()) return error.LocalOutOfRange;
        return frame.frame_base + @as(usize, index) * slot_size;
    }

    // Byte-addressed access ---------------------------------------------------
    //
    // Every instruction that touches guest data arrives here. `load` and `store`
    // bring an address from their operand, and the rest bring one from the stack.
    // The width of the access comes from the instruction.

    /// Whether an access reads guest memory or writes it.
    const Access = enum { read, write };

    /// The first address that a program can write.
    ///
    /// The code region is read-only while a program runs. The verifier reads that
    /// region once, before any of it runs, and decides that each reachable byte
    /// decodes and that each branch lands on an instruction. A store into the
    /// region would make that decision worthless, because the bytes it checked are
    /// not the bytes that would run. One comparison for each store keeps the
    /// result of the verifier true for the whole run.
    fn writableBase(self: *const VM) usize {
        return self.code_len;
    }

    /// Check a byte address from the stack for an access of `width` bytes.
    ///
    /// A negative value has no unsigned equivalent, so it faults rather than
    /// becoming a large positive address. The width is part of the check: an
    /// address one byte inside memory is not a place to put four bytes.
    ///
    /// An unaligned address is permitted. A C compiler can then lay a structure out
    /// without a rule from the VM about where each field may sit, and the cost here
    /// is nothing, because the read and the write below do not need alignment.
    fn memoryAddress(self: *const VM, value: i32, width: usize, access: Access) !usize {
        if (value < 0) return error.SegmentFault;
        return self.checkAccess(@intCast(value), width, access);
    }

    /// The same check for the address in the operand of `load` or of `store`.
    ///
    /// The encoding of that operand is unsigned, so it needs no test of its sign. But
    /// the rest of the check must be the one that an address from the stack gets. If
    /// the two differed, then `store 4` and `push 4` with `store_at` could reach
    /// different bytes, and the one address space would not be one after all.
    fn operandAddress(self: *const VM, address: u32, access: Access) !usize {
        return self.checkAccess(@as(usize, address), 4, access);
    }

    /// The bound and the write floor, for an access of `width` bytes at `address`.
    fn checkAccess(self: *const VM, address: usize, width: usize, access: Access) !usize {
        // Written as a subtraction so it cannot overflow, whatever the width.
        if (width > self.memory.len or address > self.memory.len - width) {
            return error.SegmentFault;
        }
        if (access == .write and address < self.writableBase()) {
            return error.WriteToCodeRegion;
        }
        return address;
    }

    fn readMemory(self: *const VM, comptime T: type, address: usize) T {
        return std.mem.readInt(T, self.memory[address..][0..@sizeOf(T)], .little);
    }

    fn writeMemory(self: *VM, comptime T: type, address: usize, value: T) void {
        std.mem.writeInt(T, self.memory[address..][0..@sizeOf(T)], value, .little);
    }

    // Replace the address on the stack with the value at that address. A signed `T`
    // extends its sign into the upper bits of the stack slot and an unsigned `T`
    // does not, which is the whole reason the narrow loads come in pairs.
    fn loadFrom(self: *VM, comptime T: type) !void {
        if (self.sp == 0) return error.StackUnderflow;

        const address = try self.memoryAddress(self.stack[self.sp - 1], @sizeOf(T), .read);
        self.stack[self.sp - 1] = self.readMemory(T, address);
    }

    // Take a value and an address off the stack, and write the low bits of that
    // value. `T` is unsigned for every width, because a store keeps the bits and
    // does not ask what they mean.
    fn storeTo(self: *VM, comptime T: type) !void {
        if (self.sp < 2) return error.StackUnderflow;

        const address = try self.memoryAddress(self.stack[self.sp - 1], @sizeOf(T), .write);
        const bits: u32 = @bitCast(self.stack[self.sp - 2]);

        self.sp -= 2;
        self.writeMemory(T, address, @truncate(bits));
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

    /// The checks that the verifier makes for this program, in the form it takes
    /// them.
    ///
    /// A verification during a run must ask for exactly what the verification at load
    /// time asked for. Otherwise a program could reach through an indirect call what
    /// a direct call to the same address was refused. Therefore both callers take
    /// their options from here.
    ///
    /// `code` is the code region in guest memory rather than the slice of the
    /// container, because the container is gone once the program is loaded. The two
    /// hold the same bytes: the region is read-only for the whole run.
    fn verifyOptions(code: []const u8, entry_point: u32, import_count: u8) verify.Options {
        return .{
            .code = code,
            .entry_point = entry_point,
            .import_count = import_count,
            // The VM knows the size of its memory and the length of the code.
            // Therefore an address in a `load` or a `store` operand, and a `store`
            // that would write an instruction, are both found before any of the
            // program runs.
            .memory_size = constants.memory_size,
            .code_len = @intCast(code.len),
        };
    }

    // Make sure that the code region is safe to execute before the VM runs any of
    // it. The vig-bytecode verifier gives the list of the checks.
    fn verifyImage(self: *VM, image: container.Image) !void {
        // One mark for each code byte. The VM has already checked the image
        // against the size of the VM memory, so `verify_scratch` is large enough.
        std.debug.assert(image.code.len <= self.verify_scratch.len);

        var failure: verify.Failure = undefined;
        const options = verifyOptions(
            image.code,
            image.header.entry_point,
            image.header.import_count,
        );
        verify.verify(options, &self.verify_scratch, &failure) catch |err| {
            self.verification_failure = failure;
            return err;
        };
    }

    /// Verify the function that an indirect call names.
    ///
    /// The walk at load time starts at the entry point and follows what it reads, so
    /// it never reaches a function that only a pointer names. This is where such a
    /// function is checked, and the marks from load time say whether an earlier call
    /// already checked it. The code cannot change while the program runs, so the
    /// answer is the one that a check before the run would have given.
    fn verifyCallTarget(self: *VM, target: u32) !void {
        // The common case: an address that some path already decoded. The verifier
        // answers this from one mark, but the call is not free, and an indirect call
        // is an instruction in a loop as often as any other.
        if (self.verify_scratch[target] == .boundary) return;

        var failure: verify.Failure = undefined;
        const options = verifyOptions(
            self.memory[0..self.code_len],
            // The entry point is not read by `verifyFrom`, which starts at `target`.
            0,
            @intCast(self.foreign_import_count),
        );
        verify.verifyFrom(options, &self.verify_scratch, target, &failure) catch |err| {
            // The failure names the instruction that the verifier refused, which is
            // inside the function and not the address that was called. A caller that
            // reports both tells the whole story.
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

        // Flush before before the foreign call

        try self.output.flush();

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
        if (offset >= self.guestPointerLimit()) return error.InvalidGuestPointer;
        if (require_terminator) _ = try self.guestCString(value);
        return @intFromPtr(self.memory[offset..].ptr);
    }

    fn guestCString(self: *VM, value: i32) ![]const u8 {
        if (value <= 0) return error.InvalidGuestPointer;
        const offset: usize = @intCast(value);
        const limit = self.guestPointerLimit();
        if (offset >= limit) return error.InvalidGuestPointer;

        const bytes = self.memory[offset..limit];
        const terminator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.UnterminatedGuestString;
        return bytes[0..terminator];
    }
};

// Test harness ---------------------------------------------------------------

// A VM and the buffer that collects the output of its program. Therefore a test
// can check what the program printed.
//
// The VM is behind a pointer. A VM inside this structure would travel through the
// return value of `init`, which copies the whole of the guest memory.
const Harness = struct {
    input: Io.Reader,
    collected: Io.Writer.Allocating,
    vm: *VM,

    fn init() Harness {
        return initWithInput("");
    }

    fn initWithInput(input: []const u8) Harness {
        const vm = std.testing.allocator.create(VM) catch @panic("OOM");
        // `start` sets the stream pointers after the harness has its final
        // address. A pointer taken here becomes invalid when this function gives
        // a copy of the harness to the caller.
        vm.init(undefined, undefined);

        return .{
            .input = .fixed(input),
            .collected = .init(std.testing.allocator),
            .vm = vm,
        };
    }

    fn start(self: *Harness) void {
        self.vm.input = &self.input;
        self.vm.output = &self.collected.writer;
    }

    fn deinit(self: *Harness) void {
        self.vm.deinit();
        std.testing.allocator.destroy(self.vm);
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

fn expectOutputWithInput(program: []const u8, input: []const u8, expected: []const u8) !void {
    var harness = Harness.initWithInput(input);
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(program);
    try harness.vm.run();
    try std.testing.expectEqualStrings(expected, harness.written());
}

fn expectInputTrap(input: []const u8, expected_error: anyerror) !void {
    var harness = Harness.initWithInput(input);
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(&[_]u8{ opByte(.read_i32), opByte(.halt) });
    try std.testing.expectError(expected_error, harness.vm.run());
    try std.testing.expectEqual(@as(usize, 0), harness.vm.sp);
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

// Run one binary instruction on two values and give the value it leaves. The
// operands are runtime values, so the program is built rather than concatenated.
fn binaryResult(code: bytecode.OpCode, a: i32, b: i32) !i32 {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    var program: [12]u8 = undefined;
    program[0..5].* = push(a);
    program[5..10].* = push(b);
    program[10] = opByte(code);
    program[11] = opByte(.halt);

    try harness.vm.loadProgram(&program);
    try harness.vm.run();

    try std.testing.expectEqual(@as(usize, 1), harness.vm.sp);
    return harness.vm.stack[0];
}

fn expectBinaryTrap(code: bytecode.OpCode, a: i32, b: i32, expected_error: anyerror) !void {
    try std.testing.expectError(expected_error, binaryResult(code, a, b));
}

// Load `code` as a container and run it. The program must trap.
//
// A container is verified when it loads and bare code is not, so a test that depends
// on the marks of the verifier must give the code this form. That is also the form
// the assembler produces.
fn expectContainerTrap(code: []const u8, expected_error: anyerror) !void {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const program = try buildContainer(.{ .code = code });
    defer std.testing.allocator.free(program);

    try harness.vm.loadProgram(program);
    try std.testing.expectError(expected_error, harness.vm.run());
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
    const vm = harness.vm;

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
    const vm = harness.vm;

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
    const vm = harness.vm;

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

test "bare code still loads" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    // Code with no header, as in the first VIG programs. This form carries no
    // version, so no promise about it changed, and it is the only input that reaches
    // the run-time checks of the VM.
    try vm.loadProgram(&(push(1) ++ [_]u8{ opByte(.print), opByte(.halt) }));
    try vm.run();
    try std.testing.expectEqualStrings("1\n", harness.written());
}

test "a version 1 or version 2 container is refused" {
    // Each of these is a numbered format in which the operand of `load` and of
    // `store` is an index into a segment of i32 slots. That operand is a byte address
    // now. The instruction did not change, so nothing in the file says which meaning
    // it has, and a VM that ran the file would compute a wrong answer in silence.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    const legacy = "VIGF" ++ [_]u8{ 1, 0 } ++
        push(7) ++ [_]u8{ opByte(.print_string), opByte(.halt) } ++ "again\x00";
    try std.testing.expectError(error.ObsoleteProgramFormat, vm.loadProgram(legacy));

    // A version 2 header, which is four bytes shorter than the current one.
    var header: [container.header_size]u8 = undefined;
    container.writeHeader(.{
        .format_version = container.slot_addressed_version,
        .code_len = 1,
    }, &header);
    const slot_addressed = header[0..container.slot_addressed_header_size] ++ [_]u8{opByte(.halt)};
    try std.testing.expectError(error.ObsoleteProgramFormat, vm.loadProgram(slot_addressed));

    // The VM loaded no program. Therefore it can run no instruction.
    try std.testing.expectEqual(@as(usize, 0), vm.code_len);
}

test "resolves and invokes a zero-argument Windows API" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    // The import table is part of the container, so the program is built rather than
    // written out as bytes.
    const program = try buildContainer(.{
        .imports = &.{.{ .library = "kernel32.dll", .symbol = "GetCurrentProcessId" }},
        .code = &[_]u8{ opByte(.foreign_call), 0, opByte(.halt) },
    });
    defer std.testing.allocator.free(program);

    try vm.loadProgram(program);
    try vm.run();

    try std.testing.expectEqual(@as(usize, 1), vm.sp);
    try std.testing.expect(vm.stack[0] > 0);
}

test "resolves and invokes a zero-argument C library function" {
    // The twin of the test above for a system with the POSIX loader. It proves that
    // `foreign_call` reaches a real function through `dlopen` and `dlsym`, and not
    // only that `src/foreign.zig` compiles for such a system. The name of the C
    // library is particular to the system, so the test skips a system whose name it
    // does not know and a build that can load nothing.
    const library = switch (@import("builtin").os.tag) {
        .linux => if (@import("builtin").abi.isGnu()) "libc.so.6" else return error.SkipZigTest,
        .macos => "libSystem.B.dylib",
        else => return error.SkipZigTest,
    };

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    const program = try buildContainer(.{
        .imports = &.{.{ .library = library, .symbol = "getpid" }},
        .code = &[_]u8{ opByte(.foreign_call), 0, opByte(.halt) },
    });
    defer std.testing.allocator.free(program);

    try vm.loadProgram(program);
    try vm.run();

    try std.testing.expectEqual(@as(usize, 1), vm.sp);
    try std.testing.expect(vm.stack[0] > 0);
}

test "print_string prints a VIG-managed string and retains its address" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    const program = [_]u8{
        @intFromEnum(bytecode.OpCode.push),         7,                                  0,   0,   0,
        @intFromEnum(bytecode.OpCode.print_string), @intFromEnum(bytecode.OpCode.halt), 'h', 'e', 'l',
        'l',                                        'o',                                0,
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
    const vm = harness.vm;

    const program = [_]u8{ @intFromEnum(bytecode.OpCode.halt), 'x' };
    try vm.loadProgram(&program);
    try std.testing.expectError(error.InvalidGuestPointer, vm.guestCString(0));
    try std.testing.expectError(error.UnterminatedGuestString, vm.guestCString(1));
}

test "print writes program output to the injected writer" {
    try expectOutput(&(push(42) ++ [_]u8{ opByte(.print), opByte(.halt) }), "42\n");
}

test "read_i32 reads signed decimal values from runtime input" {
    const read_and_print = [_]u8{ opByte(.read_i32), opByte(.print), opByte(.pop) };
    const program = read_and_print ++ read_and_print ++ read_and_print ++
        read_and_print ++ read_and_print ++ [_]u8{opByte(.halt)};

    try expectOutputWithInput(
        &program,
        " \t+42\n-17 0 2147483647 -2147483648",
        "42\n-17\n0\n2147483647\n-2147483648\n",
    );
}

test "read_i32 distinguishes end, malformed input, and overflow" {
    try expectInputTrap("", error.EndOfInput);
    try expectInputTrap("  \r\n\t", error.EndOfInput);
    try expectInputTrap("+", error.InvalidInput);
    try expectInputTrap("nope", error.InvalidInput);
    try expectInputTrap("12x", error.InvalidInput);
    try expectInputTrap("2147483648", error.IntegerOverflow);
    try expectInputTrap("-2147483649", error.IntegerOverflow);
}

test "read_byte returns raw bytes and uses -1 for end of input" {
    const read_and_print = [_]u8{ opByte(.read_byte), opByte(.print), opByte(.pop) };
    const program = read_and_print ++ read_and_print ++ read_and_print ++
        read_and_print ++ read_and_print ++ [_]u8{opByte(.halt)};

    try expectOutputWithInput(&program, "A\n\xff", "65\n10\n255\n-1\n-1\n");
}

test "print_hex prints all 32 bits and retains the value" {
    const program =
        push(0) ++ [_]u8{ opByte(.print_hex), opByte(.pop) } ++
        push(0x1234abcd) ++ [_]u8{ opByte(.print_hex), opByte(.pop) } ++
        push(-1) ++ [_]u8{ opByte(.print_hex), opByte(.print), opByte(.halt) };

    try expectOutput(&program, "00000000\n1234abcd\nffffffff\n-1\n");
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

test "bitwise, shift, rotate, and wrapping operations use 32-bit patterns" {
    const program =
        push(0b1100) ++ push(0b1010) ++ [_]u8{ opByte(.@"and"), opByte(.print), opByte(.pop) } ++
        push(0b1100) ++ push(0b1010) ++ [_]u8{ opByte(.@"or"), opByte(.print), opByte(.pop) } ++
        push(0b1100) ++ push(0b1010) ++ [_]u8{ opByte(.xor), opByte(.print), opByte(.pop) } ++
        push(0) ++ [_]u8{ opByte(.not), opByte(.print), opByte(.pop) } ++
        push(1) ++ push(33) ++ [_]u8{ opByte(.shl), opByte(.print), opByte(.pop) } ++
        push(-1) ++ push(1) ++ [_]u8{ opByte(.shr_u), opByte(.print), opByte(.pop) } ++
        push(0x40000001) ++ push(1) ++ [_]u8{ opByte(.rotl), opByte(.print), opByte(.pop) } ++
        push(std.math.maxInt(i32)) ++ push(1) ++ [_]u8{ opByte(.add_wrap), opByte(.print), opByte(.halt) };

    try expectOutput(&program, "8\n14\n6\n-1\n2\n2147483647\n-2147483646\n-2147483648\n");
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

test "load and store move a value through guest memory" {
    // The operand is a byte address. It is above the code, because a store must not
    // write an instruction.
    const program = push(99) ++ withAddress(.store, 300) ++
        withAddress(.load, 300) ++ [_]u8{ opByte(.print), opByte(.halt) };
    try expectOutput(&program, "99\n");
}

test "load_at and store_at address memory at runtime" {
    // Put 77 at address 400 with a calculated address (200 + 200). Then read it in
    // the same way.
    const program = push(77) ++ push(200) ++ push(200) ++ [_]u8{opByte(.add)} ++
        [_]u8{opByte(.store_at)} ++
        push(400) ++ [_]u8{ opByte(.load_at), opByte(.print), opByte(.halt) };
    try expectOutput(&program, "77\n");
}

test "store_at consumes both the value and the address" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    // The address is above the code, because a store must not write an instruction.
    const program = push(5) ++ push(100) ++ [_]u8{ opByte(.store_at), opByte(.halt) };
    try harness.vm.loadProgram(&program);
    try harness.vm.run();

    try std.testing.expectEqual(@as(usize, 0), harness.vm.sp);
    try std.testing.expectEqual(@as(i32, 5), harness.vm.readMemory(i32, 100));
}

test "a loop walks an array through calculated byte addresses" {
    // Put 10, 20 and 30 in an array of three i32 values. Then add them in a loop
    // that calculates each address.
    //
    // The stride is four bytes and not one slot, which is what a C compiler emits
    // for an `int` array. Every address is above the code, because a store must not
    // write an instruction.
    const array: u32 = 1000;
    const total: u32 = 2000;
    const cursor: u32 = 2004;

    var program = std.ArrayList(u8).empty;
    defer program.deinit(std.testing.allocator);

    inline for (.{ 10, 20, 30 }, 0..) |value, index| {
        try program.appendSlice(std.testing.allocator, &push(value));
        try program.appendSlice(std.testing.allocator, &withAddress(.store, array + index * 4));
    }

    try program.appendSlice(std.testing.allocator, &push(0));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, total));
    try program.appendSlice(std.testing.allocator, &push(@intCast(array)));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, cursor));

    const loop_start: u32 = @intCast(program.items.len);
    // total = total + the four bytes at cursor
    try program.appendSlice(std.testing.allocator, &withAddress(.load, total));
    try program.appendSlice(std.testing.allocator, &withAddress(.load, cursor));
    try program.append(std.testing.allocator, opByte(.load32));
    try program.append(std.testing.allocator, opByte(.add));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, total));
    // cursor = cursor + 4
    try program.appendSlice(std.testing.allocator, &withAddress(.load, cursor));
    try program.appendSlice(std.testing.allocator, &push(4));
    try program.append(std.testing.allocator, opByte(.add));
    try program.appendSlice(std.testing.allocator, &withAddress(.store, cursor));
    // Continue the loop until the cursor passes the last element.
    try program.appendSlice(std.testing.allocator, &withAddress(.load, cursor));
    try program.appendSlice(std.testing.allocator, &push(@intCast(array + 12)));
    try program.append(std.testing.allocator, opByte(.ne));
    try program.appendSlice(std.testing.allocator, &withAddress(.jmp_not_zero, loop_start));

    try program.appendSlice(std.testing.allocator, &withAddress(.load, total));
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

test "the unsigned comparisons order the same bits differently" {
    // -1 is the largest value there is as unsigned and the smallest but one as
    // signed. Therefore this pair separates each instruction from its signed twin,
    // and a mistake that swapped them cannot pass.
    const expect = std.testing.expectEqual;

    try expect(@as(i32, 1), try binaryResult(.lt, -1, 1));
    try expect(@as(i32, 0), try binaryResult(.lt_u, -1, 1));
    try expect(@as(i32, 1), try binaryResult(.lt_u, 1, -1));

    try expect(@as(i32, 0), try binaryResult(.gt, -1, 1));
    try expect(@as(i32, 1), try binaryResult(.gt_u, -1, 1));

    // The forms that take equality must take it, and only it, at the boundary.
    try expect(@as(i32, 1), try binaryResult(.lte_u, -1, -1));
    try expect(@as(i32, 0), try binaryResult(.lt_u, -1, -1));
    try expect(@as(i32, 1), try binaryResult(.gte_u, -1, -1));
    try expect(@as(i32, 0), try binaryResult(.gt_u, -1, -1));

    // Zero is the smallest unsigned value, so nothing is below it.
    try expect(@as(i32, 0), try binaryResult(.lt_u, 0, 0));
    try expect(@as(i32, 1), try binaryResult(.gte_u, 0, 0));
    try expect(@as(i32, 0), try binaryResult(.lt_u, -1, 0));
}

test "unsigned division reads the same bits as unsigned values" {
    const expect = std.testing.expectEqual;

    // -1 is 0xffffffff. Halved as unsigned it is 0x7fffffff, and the signed answer
    // for the same two values is 0.
    try expect(@as(i32, 0x7fffffff), try binaryResult(.div_u, -1, 2));
    try expect(@as(i32, 0), try binaryResult(.div, -1, 2));
    try expect(@as(i32, 1), try binaryResult(.mod_u, -1, 2));

    try expect(@as(i32, 3), try binaryResult(.div_u, 7, 2));
    try expect(@as(i32, 1), try binaryResult(.mod_u, 7, 2));

    // The pair that the signed instructions trap on has an unsigned answer:
    // 0x80000000 / 0xffffffff is 0, because the divisor is the larger number.
    try expectBinaryTrap(.div, std.math.minInt(i32), -1, error.IntegerOverflow);
    try expect(@as(i32, 0), try binaryResult(.div_u, std.math.minInt(i32), -1));
    try expect(@as(i32, std.math.minInt(i32)), try binaryResult(.mod_u, std.math.minInt(i32), -1));

    // Division by zero has no answer either way.
    try expectBinaryTrap(.div_u, 1, 0, error.DivisionByZero);
    try expectBinaryTrap(.mod_u, 1, 0, error.DivisionByZero);
}

test "the arithmetic shift keeps the sign that the logical shift discards" {
    const expect = std.testing.expectEqual;

    try expect(@as(i32, -4), try binaryResult(.shr_s, -8, 1));
    try expect(@as(i32, 0x7ffffffc), try binaryResult(.shr_u, -8, 1));
    try expect(@as(i32, 4), try binaryResult(.shr_s, 8, 1));

    // A negative value shifted far enough becomes -1 and stays there, because the
    // bit that fills the value is the sign bit.
    try expect(@as(i32, -1), try binaryResult(.shr_s, -1, 31));

    // The count is the low five bits, as it is for every shift here. Therefore a
    // count of 32 is a count of 0 and the value does not change.
    try expect(@as(i32, -8), try binaryResult(.shr_s, -8, 32));
}

test "the wrapping arithmetic gives the low bits where the trapping form refuses" {
    const expect = std.testing.expectEqual;
    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);

    try expectBinaryTrap(.sub, min, 1, error.IntegerOverflow);
    try expect(@as(i32, max), try binaryResult(.sub_wrap, min, 1));

    try expectBinaryTrap(.mul, max, 2, error.IntegerOverflow);
    try expect(@as(i32, -2), try binaryResult(.mul_wrap, max, 2));

    // Where the result fits, the two forms agree.
    try expect(@as(i32, 4), try binaryResult(.sub_wrap, 10, 6));
    try expect(@as(i32, 60), try binaryResult(.mul_wrap, 10, 6));

    // The unsigned reading of the wrapped result is the one a C program wants:
    // 0 - 1 is 0xffffffff.
    try expect(@as(i32, -1), try binaryResult(.sub_wrap, 0, 1));
}

test "an indirect call reaches a function that no instruction names" {
    // The address is a value here, so nothing in the code region names offset 7 and
    // the walk at load time never reaches it. The function is therefore verified
    // when the call goes to it, and it runs.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const program = push(7) ++ [_]u8{ opByte(.call_indirect), opByte(.halt) } ++
        push(42) ++ [_]u8{opByte(.ret)};

    try harness.vm.loadProgram(&program);
    // Before the run the function is bytes that the verifier has not looked at.
    try std.testing.expectEqual(bytecode.verify.Mark.unknown, harness.vm.verify_scratch[7]);

    try harness.vm.run();

    try std.testing.expectEqual(@as(usize, 1), harness.vm.sp);
    try std.testing.expectEqual(@as(i32, 42), harness.vm.stack[0]);
    // The call left the marks behind, so a second call to the same address answers
    // from one byte and verifies nothing again.
    try std.testing.expectEqual(bytecode.verify.Mark.boundary, harness.vm.verify_scratch[7]);
}

test "an indirect call refuses a target that is not a whole instruction" {
    // Offset 1 is inside the `push` at offset 0, which the walk at load time marked.
    // A call there would read an operand byte as an opcode.
    try expectContainerTrap(
        &(push(1) ++ [_]u8{ opByte(.call_indirect), opByte(.halt) }),
        error.MisalignedTarget,
    );

    // A function that does not verify is refused at the call rather than run. The
    // byte at offset 7 has no instruction.
    try expectContainerTrap(
        &(push(7) ++ [_]u8{ opByte(.call_indirect), opByte(.halt), 0xfe }),
        error.UnknownOpcode,
    );

    // The same check that a direct call gets: control must not continue past the end
    // of the code region. The `push` at offset 7 falls through to offset 12, which is
    // the end.
    try expectContainerTrap(
        &(push(7) ++ [_]u8{ opByte(.call_indirect), opByte(.halt) } ++ push(1)),
        error.ExecutionRunsOffEnd,
    );
}

test "bare code has no marks, so an indirect call verifies from the target" {
    // A file with no header is not verified when it loads, so nothing says where an
    // instruction begins. An indirect call into such a program therefore decodes
    // from the address it was given and checks what that reaches, which is all a
    // program without a verified code region can offer. The run-time checks are the
    // same either way.
    //
    // Here offset 1 is inside the `push` at offset 0, and the operand byte there
    // happens to decode as another `push`. A container gives `MisalignedTarget` for
    // exactly this program; bare code cannot know.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(&(push(1) ++ [_]u8{ opByte(.call_indirect), opByte(.halt) }));
    try harness.vm.run();
}

test "an indirect call refuses an address that is not in the code region" {
    // A negative value has no unsigned equivalent, and an address past the code is
    // not an instruction. Neither is a fault in the function that was called,
    // because there is no function there.
    try expectTrap(
        &(push(-1) ++ [_]u8{ opByte(.call_indirect), opByte(.halt) }),
        error.SegmentFault,
        "",
    );
    try expectTrap(
        &(push(64) ++ [_]u8{ opByte(.call_indirect), opByte(.halt) }),
        error.SegmentFault,
        "",
    );
    // The target comes off the stack, so an empty stack has none to give.
    try expectTrap(&[_]u8{ opByte(.call_indirect), opByte(.halt) }, error.StackUnderflow, "");
}

test "a refused indirect call records where the verifier stopped" {
    // The failure names the instruction inside the function, and not the address that
    // the program called. A caller that reports both tells the whole story.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const program = push(7) ++ [_]u8{ opByte(.call_indirect), opByte(.halt) } ++
        push(1) ++ [_]u8{ opByte(.jmp), 200, 0, 0, 0 };

    try harness.vm.loadProgram(&program);
    try std.testing.expectError(error.TargetOutOfRange, harness.vm.run());

    const failure = harness.vm.verification_failure.?;
    try std.testing.expectEqual(error.TargetOutOfRange, failure.reason);
    // The `jmp` is at offset 12, after the five-byte `push` at 7.
    try std.testing.expectEqual(@as(usize, 12), failure.offset);
}

test "load_at and store_at are the 32-bit byte-addressed instructions" {
    // The two older names do exactly what `load32` and `store32` do. A program that
    // used them needs no change, and there is no second address space left for them
    // to reach. Therefore a value written with one name reads back with the other.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const program = push(0x11223344) ++ push(200) ++ [_]u8{opByte(.store_at)} ++
        push(200) ++ [_]u8{ opByte(.load32), opByte(.print_hex), opByte(.pop) } ++
        push(0x55667788) ++ push(300) ++ [_]u8{opByte(.store32)} ++
        push(300) ++ [_]u8{ opByte(.load_at), opByte(.print_hex), opByte(.halt) };

    try harness.vm.loadProgram(&program);
    try harness.vm.run();
    try std.testing.expectEqualStrings("11223344\n55667788\n", harness.written());
}

test "a calculated address is bounded, and its width is part of the bound" {
    const last: i32 = constants.memory_size - 1;

    // The widest access that still fits works.
    try expectOutput(
        &(push(last - 3) ++ [_]u8{ opByte(.load_at), opByte(.print), opByte(.halt) }),
        "0\n",
    );

    // One byte further needs four bytes and has three.
    try expectTrap(&(push(last - 2) ++ [_]u8{ opByte(.load_at), opByte(.halt) }), error.SegmentFault, "");
    try expectTrap(
        &(push(constants.memory_size) ++ [_]u8{ opByte(.load_at), opByte(.halt) }),
        error.SegmentFault,
        "",
    );
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

// A program that fills the data stack to its capacity. The instructions that
// follow it therefore have no room for a result.
fn fullStack(program: *std.ArrayList(u8)) !void {
    for (0..constants.stack_size) |_| {
        try program.appendSlice(std.testing.allocator, &push(0));
    }
}

test "every instruction that produces a value checks for stack overflow" {
    // `push` is not the only instruction that grows the stack. Each of these
    // checks the room for its result, and a missing check writes past the end of
    // the array instead of giving a trap.
    const producers = [_][]const bytecode.OpCode{
        &.{.dup},
        &.{.read_i32},
        &.{.read_byte},
        // `load` and `foreign_call` also push a result. `load` is the one with no
        // dependency on the input stream or on an import table.
    };

    for (producers) |instructions| {
        var program = std.ArrayList(u8).empty;
        defer program.deinit(std.testing.allocator);

        try fullStack(&program);
        for (instructions) |instruction| try program.append(std.testing.allocator, opByte(instruction));
        try program.append(std.testing.allocator, opByte(.halt));

        // The input is not empty, so a missing overflow check in `read_i32` or
        // `read_byte` gives a different error than a trap on the read itself.
        var harness = Harness.initWithInput("1 2 3");
        defer harness.deinit();
        harness.start();

        try harness.vm.loadProgram(program.items);
        try std.testing.expectError(error.StackOverflow, harness.vm.run());
        // The instruction refused to run. Therefore it left the stack full and
        // did not go past its capacity.
        try std.testing.expectEqual(constants.stack_size, harness.vm.sp);
    }

    // `load` reads the data segment onto the stack and needs the same check.
    var with_load = std.ArrayList(u8).empty;
    defer with_load.deinit(std.testing.allocator);
    try fullStack(&with_load);
    try with_load.appendSlice(std.testing.allocator, &withAddress(.load, 0));
    try with_load.append(std.testing.allocator, opByte(.halt));
    try expectTrap(with_load.items, error.StackOverflow, "");
}

test "recursion without an end overflows the call stack" {
    // A `call` to offset 0 is a call to itself. Each one saves a return offset, so
    // the call stack reaches its capacity and the VM traps. Without the check the
    // VM writes past the end of `call_stack`.
    //
    // The program has no header, so no verifier reads it. A verifier cannot find
    // this fault in any case: the recursion is correct control flow.
    const program = withAddress(.call, 0) ++ [_]u8{opByte(.halt)};

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(&program);
    try std.testing.expectError(error.CallStackOverflow, harness.vm.run());
    try std.testing.expectEqual(constants.call_stack_size, harness.vm.csp);
}

test "an operand that runs past the end of the code region gives a fault" {
    // The last instruction of each program needs four operand bytes and does not
    // have them. A program with no header is not verified, so the run-time check
    // is the only one that can find this.
    //
    // `push` counts the bytes itself and `jmp` uses `utils.readU32`. Therefore
    // both paths need a case.
    try expectTrap(&[_]u8{ opByte(.push), 0, 0 }, error.SegmentFault, "");
    try expectTrap(&[_]u8{ opByte(.jmp), 0, 0 }, error.SegmentFault, "");
    try expectTrap(&[_]u8{ opByte(.load), 1 }, error.SegmentFault, "");
    // An operand that is inside the program image but outside the code region is
    // still a fault. The static data is not executable, so it is not an operand
    // either.
    const image = try buildContainer(.{
        .code = &[_]u8{ opByte(.jmp), 0, 0 },
        .data = &[_]u8{ 0, 0 },
    });
    defer std.testing.allocator.free(image);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    // The verifier refuses this program before it runs, which is the stronger
    // result: the fault never becomes a trap.
    try std.testing.expectError(error.TruncatedInstruction, harness.vm.loadProgram(image));
}

test "a foreign call to an import that does not exist gives a fault" {
    // The container declares no import, so index 0 names nothing. The verifier
    // finds this in a current container. A program with no header reaches the
    // run-time check instead, and that check must exist.
    try expectTrap(
        &[_]u8{ opByte(.foreign_call), 0, opByte(.halt) },
        error.InvalidForeignImport,
        "",
    );
}

test "a load or store operand is bounded at run time and not only by the verifier" {
    // A container has its `load` and `store` operands checked at load time. Bare
    // code has no such check, so the same rules must hold while it runs.
    const past_end: u32 = constants.memory_size;

    try expectTrap(
        &(withAddress(.load, past_end) ++ [_]u8{opByte(.halt)}),
        error.SegmentFault,
        "",
    );
    // Three bytes from the end is inside memory, but its four-byte access is not.
    try expectTrap(
        &(withAddress(.load, constants.memory_size - 3) ++ [_]u8{opByte(.halt)}),
        error.SegmentFault,
        "",
    );
    try expectTrap(
        &(push(0) ++ withAddress(.store, past_end) ++ [_]u8{opByte(.halt)}),
        error.SegmentFault,
        "",
    );
    // A `store` into the code is refused while it runs, too.
    try expectTrap(
        &(push(0) ++ withAddress(.store, 0) ++ [_]u8{opByte(.halt)}),
        error.WriteToCodeRegion,
        "",
    );

    // The same programs in a container never run at all.
    const out_of_range = try buildContainer(.{
        .code = &(withAddress(.load, past_end) ++ [_]u8{opByte(.halt)}),
    });
    defer std.testing.allocator.free(out_of_range);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try std.testing.expectError(error.DataAddressOutOfRange, harness.vm.loadProgram(out_of_range));

    const into_code = try buildContainer(.{
        .code = &(push(0) ++ withAddress(.store, 0) ++ [_]u8{opByte(.halt)}),
    });
    defer std.testing.allocator.free(into_code);

    var refused = Harness.init();
    defer refused.deinit();
    refused.start();
    try std.testing.expectError(error.StoreIntoCodeRegion, refused.vm.loadProgram(into_code));
}

// Call frames ----------------------------------------------------------------

// Encode `enter arguments locals`.
fn enterFrame(arguments: u16, locals: u16) [5]u8 {
    var bytes: [5]u8 = undefined;
    bytes[0] = opByte(.enter);
    std.mem.writeInt(u16, bytes[1..3], arguments, .little);
    std.mem.writeInt(u16, bytes[3..5], locals, .little);
    return bytes;
}

// Encode an instruction that takes a frame slot index.
fn withLocal(code: bytecode.OpCode, index: u16) [3]u8 {
    var bytes: [3]u8 = undefined;
    bytes[0] = opByte(code);
    std.mem.writeInt(u16, bytes[1..3], index, .little);
    return bytes;
}

test "a frame belongs to a call" {
    // The entry point of a program is not called, so it has no frame to enter.
    try expectTrap(&(enterFrame(0, 1) ++ [_]u8{opByte(.halt)}), error.EnterOutsideCall, "");

    // The frame instructions need an active frame as well.
    for ([_]bytecode.OpCode{ .load_local, .store_local, .local_addr }) |instruction| {
        try expectTrap(
            &(push(0) ++ withLocal(instruction, 0) ++ [_]u8{opByte(.halt)}),
            error.NoActiveFrame,
            "",
        );
    }
}

test "one enter for each call" {
    // A second `enter` would lose the frame that the first one made.
    const code = withAddress(.call, 6) ++ [_]u8{opByte(.halt)} ++
        enterFrame(0, 1) ++ enterFrame(0, 1) ++ [_]u8{opByte(.ret)};
    try expectTrap(&code, error.FrameAlreadyEntered, "");
}

test "a slot outside the frame is refused" {
    // The frame has two slots, so slot 2 is not in it. Without this check a function
    // would read or write the frame of its caller.
    //
    // The call target is the length of what comes before it, and not a counted
    // number, so a change to the prologue cannot leave a stale offset behind.
    const prologue = push(0) ++ withAddress(.call, 0) ++ [_]u8{opByte(.halt)};
    const code = push(0) ++ withAddress(.call, prologue.len) ++ [_]u8{opByte(.halt)} ++
        enterFrame(1, 1) ++ withLocal(.load_local, 2) ++ [_]u8{opByte(.ret)};

    try expectTrap(&code, error.LocalOutOfRange, "");
}

test "enter needs its arguments on the stack" {
    // The function declares two arguments and the caller supplied one.
    const code = push(1) ++ withAddress(.call, 11) ++ [_]u8{opByte(.halt)} ++
        enterFrame(2, 0) ++ [_]u8{opByte(.ret)};
    try expectTrap(&code, error.StackUnderflow, "");
}

test "a frame is released when its function returns" {
    // Two calls one after the other must reuse the same memory. Without the release
    // a loop of calls would use frame memory without end.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    const prologue = withAddress(.call, 0) ++ withAddress(.call, 0) ++ [_]u8{opByte(.halt)};
    const code = withAddress(.call, prologue.len) ++ withAddress(.call, prologue.len) ++
        [_]u8{opByte(.halt)} ++
        enterFrame(0, 2) ++ [_]u8{opByte(.ret)};

    try vm.loadProgram(&code);
    try vm.run();

    // Every frame is gone, so frame memory has used nothing.
    try std.testing.expectEqual(constants.memory_size, vm.frame_pointer);
    try std.testing.expectEqual(@as(usize, 0), vm.csp);
}

test "a local starts at zero even where an earlier frame left a value" {
    // Frame memory is reused, so the bytes of a new frame can hold what an earlier
    // call wrote. `enter` must clear the locals.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    // The first call writes 7 into its local. The second call reads its own local,
    // which is at the same address, and must find zero.
    const prologue = withAddress(.call, 0) ++ withAddress(.call, 0) ++
        [_]u8{ opByte(.print), opByte(.halt) };
    const writer = enterFrame(0, 1) ++ push(7) ++ withLocal(.store_local, 0) ++
        [_]u8{opByte(.ret)};

    const writer_offset: u32 = prologue.len;
    const reader_offset: u32 = writer_offset + writer.len;

    const code = withAddress(.call, writer_offset) ++ withAddress(.call, reader_offset) ++
        [_]u8{ opByte(.print), opByte(.halt) } ++ writer ++
        enterFrame(0, 1) ++ withLocal(.load_local, 0) ++ [_]u8{opByte(.ret_val)};

    try harness.vm.loadProgram(&code);
    try harness.vm.run();
    try std.testing.expectEqualStrings("0\n", harness.written());
}

// Byte-addressed access ------------------------------------------------------

// A container whose code is `code` and whose static data is `data`, loaded and run.
// A byte-addressed test needs a real image, because the boundary between the code
// and the data is what decides which addresses a store may use.
fn runImage(harness: *Harness, code: []const u8, data: []const u8) !void {
    const image = try buildContainer(.{ .code = code, .data = data });
    defer std.testing.allocator.free(image);

    try harness.vm.loadProgram(image);
    try harness.vm.run();
}

// The address of the static data is the length of the code, and a test must put
// that address inside the code that it measures. `push` is five bytes whatever
// value it carries, so the same instructions with a zero address have the same
// length as the real ones. Therefore this function gives the data address of a
// program without a count of its bytes by hand, and a change to the program cannot
// leave a stale number behind.
fn dataBase(shape: []const u8) i32 {
    return @intCast(shape.len);
}

test "a narrow load extends the sign only in its signed form" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const shape = push(0) ++ [_]u8{ opByte(.load8_u), opByte(.print), opByte(.pop) } ++
        push(0) ++ [_]u8{ opByte(.load8_s), opByte(.print), opByte(.pop) } ++
        push(0) ++ [_]u8{ opByte(.load16_u), opByte(.print), opByte(.pop) } ++
        push(0) ++ [_]u8{ opByte(.load16_s), opByte(.print), opByte(.halt) };
    const base = dataBase(&shape);

    // The static data holds 0xff, then 0xff 0xff.
    const code = push(base) ++ [_]u8{ opByte(.load8_u), opByte(.print), opByte(.pop) } ++
        push(base) ++ [_]u8{ opByte(.load8_s), opByte(.print), opByte(.pop) } ++
        push(base + 1) ++ [_]u8{ opByte(.load16_u), opByte(.print), opByte(.pop) } ++
        push(base + 1) ++ [_]u8{ opByte(.load16_s), opByte(.print), opByte(.halt) };
    try std.testing.expectEqual(shape.len, code.len);

    try runImage(&harness, &code, &[_]u8{ 0xff, 0xff, 0xff });
    try std.testing.expectEqualStrings("255\n-1\n65535\n-1\n", harness.written());
}

test "a byte address means the same thing as a program address" {
    // This is the property that the whole change is for. `push` of a data label
    // gives a byte offset into the program image, `print_string` reads a string at
    // that offset, and `load8_u` reads the first byte of the same string. One
    // number, one place.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const shape = push(0) ++ [_]u8{ opByte(.print_string), opByte(.load8_u), opByte(.print), opByte(.halt) };
    const code = push(dataBase(&shape)) ++
        [_]u8{ opByte(.print_string), opByte(.load8_u), opByte(.print), opByte(.halt) };
    try std.testing.expectEqual(shape.len, code.len);

    try runImage(&harness, &code, "hi\x00");
    // "hi", then 104, which is 'h'.
    try std.testing.expectEqualStrings("hi\n104\n", harness.written());
}

test "a store and a load of each width move a value through memory" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const shape = push(0) ++ push(0) ++ [_]u8{opByte(.store8)} ++
        push(0) ++ [_]u8{ opByte(.load8_u), opByte(.print), opByte(.pop) } ++
        push(0) ++ push(0) ++ [_]u8{opByte(.store32)} ++
        push(0) ++ [_]u8{ opByte(.load32), opByte(.print_hex), opByte(.halt) };
    const base = dataBase(&shape);

    // Four reserved bytes follow the code region.
    const code = push(-1) ++ push(base) ++ [_]u8{opByte(.store8)} ++
        push(base) ++ [_]u8{ opByte(.load8_u), opByte(.print), opByte(.pop) } ++
        push(0x12345678) ++ push(base) ++ [_]u8{opByte(.store32)} ++
        push(base) ++ [_]u8{ opByte(.load32), opByte(.print_hex), opByte(.halt) };
    try std.testing.expectEqual(shape.len, code.len);

    try runImage(&harness, &code, &[_]u8{ 0, 0, 0, 0 });
    // The store kept the low eight bits only, then the 32-bit store replaced all
    // four bytes.
    try std.testing.expectEqualStrings("255\n12345678\n", harness.written());
}

test "a 32-bit access needs no alignment" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const shape = push(0) ++ push(0) ++ [_]u8{opByte(.store32)} ++
        push(0) ++ [_]u8{ opByte(.load32), opByte(.print_hex), opByte(.halt) };
    const base = dataBase(&shape);
    // A VM that required alignment would fault instead of giving the value back.
    // The test is only about alignment if the address is not a multiple of four.
    try std.testing.expect(@rem(base, 4) != 0);

    const code = push(0x0a0b0c0d) ++ push(base) ++ [_]u8{opByte(.store32)} ++
        push(base) ++ [_]u8{ opByte(.load32), opByte(.print_hex), opByte(.halt) };
    try std.testing.expectEqual(shape.len, code.len);

    const zeros: [8]u8 = @splat(0);
    try runImage(&harness, &code, &zeros);
    try std.testing.expectEqualStrings("0a0b0c0d\n", harness.written());
}

test "a store cannot reach the code region" {
    // The code is read-only while a program runs. Without this rule a program could
    // change an instruction that the verifier has already checked, and the result
    // of that check would say nothing about what runs.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const code = push(0) ++ push(0) ++ [_]u8{ opByte(.store8), opByte(.halt) };
    const image = try buildContainer(.{ .code = &code, .data = &[_]u8{0} });
    defer std.testing.allocator.free(image);

    try harness.vm.loadProgram(image);
    try std.testing.expectError(error.WriteToCodeRegion, harness.vm.run());
    // The first instruction is unchanged.
    try std.testing.expectEqual(opByte(.push), harness.vm.memory[0]);
}

test "the last byte of the code region is the last one a store cannot use" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    // 12 bytes of code, then 4 bytes of data. A store at 11 is the code and a store
    // at 12 is the data.
    const code = push(7) ++ push(12) ++ [_]u8{ opByte(.store8), opByte(.halt) };
    try std.testing.expectEqual(@as(usize, 12), code.len);

    try runImage(&harness, &code, &[_]u8{ 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 12), vm.code_len);
    try std.testing.expectEqual(@as(u8, 7), vm.memory[12]);

    // The same program one byte lower is refused.
    var refused = Harness.init();
    defer refused.deinit();
    refused.start();

    const into_code = push(7) ++ push(11) ++ [_]u8{ opByte(.store8), opByte(.halt) };
    const image = try buildContainer(.{ .code = &into_code, .data = &[_]u8{ 0, 0, 0, 0 } });
    defer std.testing.allocator.free(image);

    try refused.vm.loadProgram(image);
    try std.testing.expectError(error.WriteToCodeRegion, refused.vm.run());
}

test "a load may read the code region" {
    // Only writing is restricted. A program can read its own instructions, which is
    // how it reads a static value that sits in the code region of an older
    // container.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const code = push(0) ++ [_]u8{ opByte(.load8_u), opByte(.print), opByte(.halt) };
    try runImage(&harness, &code, &[_]u8{0});
    // Offset 0 holds the opcode byte of the first `push`.
    var expected: [8]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected, "{d}\n", .{opByte(.push)}),
        harness.written(),
    );
}

test "an access must fit inside memory, and its width is part of that" {
    const last: i32 = constants.memory_size - 1;

    // The last byte of memory is a place to put one byte, so a one-byte access
    // there works. Memory starts as zeros, so that is what it reads.
    try expectOutput(
        &(push(last) ++ [_]u8{ opByte(.load8_u), opByte(.print), opByte(.halt) }),
        "0\n",
    );
    // The widest access that still fits also works.
    try expectOutput(
        &(push(last - 3) ++ [_]u8{ opByte(.load32), opByte(.print), opByte(.halt) }),
        "0\n",
    );

    // The address is inside memory in each of these and the access is not, because
    // it needs more bytes than memory has left. A check of the address on its own
    // would read past the end.
    try expectTrap(&(push(last) ++ [_]u8{ opByte(.load16_u), opByte(.halt) }), error.SegmentFault, "");
    try expectTrap(&(push(last) ++ [_]u8{ opByte(.load16_s), opByte(.halt) }), error.SegmentFault, "");
    try expectTrap(&(push(last) ++ [_]u8{ opByte(.load32), opByte(.halt) }), error.SegmentFault, "");
    try expectTrap(
        &(push(last - 2) ++ [_]u8{ opByte(.load32), opByte(.halt) }),
        error.SegmentFault,
        "",
    );
    // The first address fully outside memory.
    try expectTrap(
        &(push(constants.memory_size) ++ [_]u8{ opByte(.load8_u), opByte(.halt) }),
        error.SegmentFault,
        "",
    );

    // A negative address never becomes a large positive one.
    try expectTrap(&(push(-1) ++ [_]u8{ opByte(.load8_u), opByte(.halt) }), error.SegmentFault, "");
    try expectTrap(
        &(push(0) ++ push(-1) ++ [_]u8{ opByte(.store8), opByte(.halt) }),
        error.SegmentFault,
        "",
    );
}

test "the byte instructions check the stack before they touch memory" {
    for ([_]bytecode.OpCode{ .load8_u, .load8_s, .load16_u, .load16_s, .load32 }) |instruction| {
        try expectTrap(&[_]u8{ opByte(instruction), opByte(.halt) }, error.StackUnderflow, "");
    }
    // A store needs a value as well as an address.
    for ([_]bytecode.OpCode{ .store8, .store16, .store32 }) |instruction| {
        try expectTrap(&[_]u8{ opByte(instruction), opByte(.halt) }, error.StackUnderflow, "");
        try expectTrap(
            &(push(0) ++ [_]u8{ opByte(instruction), opByte(.halt) }),
            error.StackUnderflow,
            "",
        );
    }
}

test "a store consumes both the value and the address" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const code = push(5) ++ push(12) ++ [_]u8{ opByte(.store16), opByte(.halt) };
    try std.testing.expectEqual(@as(usize, 12), code.len);

    try runImage(&harness, &code, &[_]u8{ 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), harness.vm.sp);
    try std.testing.expectEqual(@as(u8, 5), harness.vm.memory[12]);
}

test "a global and a byte address are the same address" {
    // There was a time when this test recorded the opposite. The operand of `store`
    // was an index into a separate segment of i32 slots, and a byte store at the same
    // number reached a different place. Neither could see what the other wrote.
    //
    // Now there is one address space. `store <n>` and a byte store at `n` write the
    // same four bytes. That is what lets a program take the address of a global, and
    // therefore what makes a pointer possible.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    const global: u32 = 500;
    const code = push(99) ++ withAddress(.store, global) ++
        push(@intCast(global)) ++ [_]u8{ opByte(.load32), opByte(.print), opByte(.pop) } ++
        push(77) ++ push(@intCast(global)) ++ [_]u8{opByte(.store32)} ++
        withAddress(.load, global) ++ [_]u8{ opByte(.print), opByte(.halt) };

    try harness.vm.loadProgram(&code);
    try harness.vm.run();

    // The operand form wrote it and the byte form read it. Then the reverse.
    try std.testing.expectEqualStrings("99\n77\n", harness.written());
    try std.testing.expectEqual(@as(i32, 77), vm.readMemory(i32, global));
}

test "the operand form and the stack form reach the same bytes" {
    // `store 400` and `push 400` with `store_at` must name one place. This is the
    // invariant that lets a program calculate an address.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const program = push(11) ++ withAddress(.store, 400) ++
        push(400) ++ [_]u8{ opByte(.load_at), opByte(.print), opByte(.pop) } ++
        push(22) ++ push(400) ++ [_]u8{opByte(.store_at)} ++
        withAddress(.load, 400) ++ [_]u8{ opByte(.print), opByte(.halt) };

    try harness.vm.loadProgram(&program);
    try harness.vm.run();

    try std.testing.expectEqualStrings("11\n22\n", harness.written());
    try std.testing.expectEqual(@as(i32, 22), harness.vm.readMemory(i32, 400));
}
