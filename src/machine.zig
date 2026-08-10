const std = @import("std");
const bytecode = @import("vig_bytecode");
const constants = @import("constants.zig");
const foreign = @import("foreign.zig");
const utils = @import("utils.zig");

const container = bytecode.container;
const verify = bytecode.verify;
const Io = std.Io;

/// Whether this build counts the instructions it runs. See the `stats` option in
/// `build.zig`: the count costs time in the loop that runs them, so a VM that
/// anyone ships is built without it and the counters below compile to nothing.
const count_instructions = @import("build_options").stats;

/// How many times each opcode ran, and how many instructions in total.
///
/// This is what says where a program spends itself, in the terms the interpreter
/// works in: an opcode near the top of the report is a handler worth making
/// faster, and one absent from it is a handler no measurement will notice. The
/// structure is empty in a build that does not count, so a VM that does not
/// measure carries no space for it either.
pub const Stats = if (count_instructions) struct {
    total: u64 = 0,
    per_opcode: [256]u64 = @splat(0),

    fn record(self: *Stats, op: bytecode.OpCode) void {
        self.total += 1;
        self.per_opcode[@intFromEnum(op)] += 1;
    }

    /// Write the report: the totals, then each opcode that ran, most first.
    pub fn write(self: *const Stats, writer: *Io.Writer, elapsed_ns: u64) !void {
        const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
        try writer.print("instructions: {d}\n", .{self.total});
        try writer.print("seconds: {d:.6}\n", .{seconds});
        if (seconds > 0) {
            const rate = @as(f64, @floatFromInt(self.total)) / seconds / 1_000_000.0;
            try writer.print("Minst/s: {d:.1}\n", .{rate});
            const each = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(@max(self.total, 1)));
            try writer.print("ns/instruction: {d:.2}\n", .{each});
        }

        // Sorted by count, because the question this answers is which handler to
        // look at first and the answer is the top of the list.
        var order: [256]u8 = undefined;
        for (&order, 0..) |*slot, index| slot.* = @intCast(index);
        const Sort = struct {
            counts: *const [256]u64,
            fn greater(context: @This(), a: u8, b: u8) bool {
                return context.counts[a] > context.counts[b];
            }
        };
        std.mem.sort(u8, &order, Sort{ .counts = &self.per_opcode }, Sort.greater);

        try writer.writeAll("\n     count   share  opcode\n");
        for (order) |byte| {
            const count = self.per_opcode[byte];
            if (count == 0) continue;
            const share = 100.0 * @as(f64, @floatFromInt(count)) /
                @as(f64, @floatFromInt(@max(self.total, 1)));
            const name = if (bytecode.OpCode.fromByte(byte)) |op|
                op.mnemonic()
            else |_|
                "?";
            try writer.print("{d:>10}  {d:>5.1}%  {s}\n", .{ count, share, name });
        }
    }
} else struct {
    fn record(self: *Stats, op: bytecode.OpCode) void {
        _ = self;
        _ = op;
    }

    /// Nothing to report, so that a caller needs no test for which build this is.
    /// `--stats` is refused before it reaches here.
    pub fn write(self: *const Stats, writer: *Io.Writer, elapsed_ns: u64) !void {
        _ = self;
        _ = writer;
        _ = elapsed_ns;
    }
};

const ExecutionAbi = enum { vig32, vig64 };

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

/// The sizes that a VM is built with. See `constants.Config`.
pub const Config = constants.Config;

/// The virtual machine.
///
/// The guest memory, the two stacks and the verifier scratch come from an allocator,
/// so this structure is a handful of slices and registers whatever size the memory
/// has. A caller gives the sizes to `init` and frees them with `deinit`.
pub const VM = struct {
    // Where the memory and the stacks came from, so that `deinit` can give them
    // back and `loadProgram` can grow the verifier scratch.
    allocator: std.mem.Allocator,

    // The guest address space: one array of bytes. Every instruction that touches
    // guest data addresses this array by byte, and a label, a pointer and the
    // operand of `load` all mean the same kind of number.
    memory: []u8,

    // The evaluation stack.
    stack: []i32,
    /// VIG64 has a separate eight-byte operand stack. Keeping the VIG32 stack
    /// separate means old raw bytecode and V3 containers retain their exact
    /// signed 32-bit behaviour.
    wide_stack: []u64,
    execution_abi: ExecutionAbi = .vig32,

    // The call stack for the `call` and `ret` instructions.
    call_stack: []CallFrame,
    csp: usize,

    // The lowest address that a frame uses. Frame memory grows down from the end of
    // guest memory, and the program image sits at the start of it. Therefore the two
    // grow towards each other, and one comparison finds the collision.
    //
    // This value is the end of memory when no function has a frame.
    frame_pointer: usize = 0,

    foreign_imports: [bytecode.foreign.max_imports]?foreign.Import,
    foreign_import_count: usize,
    wide_foreign_imports: []?foreign.Vig64Import,
    wide_foreign_import_count: usize,

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

    /// What ran, in a build that counts. See `Stats`.
    stats: Stats = .{},

    // Working space for the bytecode verifier: one mark for each byte of the code
    // region.
    //
    // This buffer belongs to the VM and not to `verifyImage`, because `call_indirect`
    // reads it while a program runs: a function that only a pointer names is verified
    // at the call, and the marks are what say whether an earlier call already did it.
    //
    // It grows to the code region of the program that is loaded, and not to the size
    // of guest memory. The two were the same size once, which cost one byte of host
    // memory for each byte of guest memory whatever the program held. A program is
    // mostly data, so this is now a fraction of that.
    verify_scratch: []verify.Mark,

    // Set the state of the VM to its initial values. The memory and the stacks keep
    // the sizes that `init` gave them.
    pub fn reset(self: *VM) void {
        self.clearForeignImports();
        self.clearWideForeignImports();
        @memset(self.stack, 0);
        @memset(self.wide_stack, 0);
        @memset(self.memory, 0);
        @memset(self.call_stack, empty_frame);
        // The marks belong to the program that made them. `call_indirect` reads them
        // while a program runs, so a mark that an earlier program left would answer
        // for code that is no longer there.
        @memset(self.verify_scratch, .unknown);

        self.code_len = 0;
        self.program_len = 0;
        self.verification_failure = null;
        self.ip = 0;
        self.sp = 0;
        self.execution_abi = .vig32;
        self.csp = 0;
        // No function has a frame, so frame memory has used nothing. It grows down
        // from the end of memory as each `enter` runs.
        self.frame_pointer = self.memory.len;
    }

    /// Give back the memory and the stacks, and release every foreign library.
    pub fn deinit(self: *VM) void {
        self.clearForeignImports();
        self.clearWideForeignImports();
        self.allocator.free(self.memory);
        self.allocator.free(self.stack);
        self.allocator.free(self.wide_stack);
        self.allocator.free(self.wide_foreign_imports);
        self.allocator.free(self.call_stack);
        self.allocator.free(self.verify_scratch);
        self.* = undefined;
    }

    /// Build a VM with the sizes in `config`. The streams must stay in existence
    /// longer than the VM, and `deinit` gives the memory back.
    ///
    /// The verifier scratch starts empty. `loadProgram` grows it to the code region
    /// of the program it is given, which is the only place that knows how much of the
    /// memory is instructions.
    pub fn init(
        self: *VM,
        allocator: std.mem.Allocator,
        config: Config,
        input: *Io.Reader,
        output: *Io.Writer,
    ) !void {
        try config.check();

        const memory = try allocator.alloc(u8, config.memory_size);
        errdefer allocator.free(memory);
        const stack = try allocator.alloc(i32, config.stack_size);
        errdefer allocator.free(stack);
        const wide_stack = try allocator.alloc(u64, config.stack_size);
        errdefer allocator.free(wide_stack);
        const wide_foreign_imports = try allocator.alloc(?foreign.Vig64Import, bytecode.foreign.max_imports);
        errdefer allocator.free(wide_foreign_imports);
        const call_stack = try allocator.alloc(CallFrame, config.call_stack_size);
        errdefer allocator.free(call_stack);

        @memset(memory, 0);
        @memset(stack, 0);
        @memset(wide_stack, 0);
        @memset(wide_foreign_imports, null);
        @memset(call_stack, empty_frame);

        self.* = .{
            .allocator = allocator,
            .memory = memory,
            .stack = stack,
            .wide_stack = wide_stack,
            .execution_abi = .vig32,
            .call_stack = call_stack,
            .csp = 0,
            .frame_pointer = config.memory_size,
            .foreign_imports = @splat(null),
            .foreign_import_count = 0,
            .wide_foreign_imports = wide_foreign_imports,
            .wide_foreign_import_count = 0,
            .code_len = 0,
            .program_len = 0,
            .verification_failure = null,
            .input = input,
            .output = output,
            .sp = 0,
            .ip = 0,
            .verify_scratch = &.{},
        };
    }

    /// The largest program file that this VM can load.
    pub fn maxProgramFileSize(self: *const VM) usize {
        return constants.maxProgramFileSize(self.memory.len);
    }

    // Load a program into the memory of the VM. The file can be a current container
    // or bare code with no header. `container.parse` finds which form the file has.
    pub fn loadProgram(self: *VM, program: []const u8) !void {
        self.reset();
        errdefer self.clearForeignImports();

        if (container.isContainer(program) and program.len > 4 and program[4] == container.vig64_version) {
            return self.loadVig64Program(program);
        }

        const image = try container.parse(program);

        // A version 1 container and a version 2 container are refused. In each one
        // the operand of `load` and of `store` is an index into a segment of i32
        // slots, and that operand is now a byte address in this memory. The
        // instruction did not change, so nothing in the file says which meaning it
        // has. A VM that ran such a file would compute a wrong answer and report
        // nothing. Therefore it must refuse the file instead.
        if (!image.kind.isExecutable()) return error.ObsoleteProgramFormat;

        if (image.imageLen() > self.memory.len) return error.ProgramTooLarge;

        // The marks are for the code of this program. `reset` cleared what the last
        // one left; this gives the verifier a mark for each byte it is about to read.
        try self.growVerifyScratch(image.code.len);

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

    fn loadVig64Program(self: *VM, program: []const u8) !void {
        const image = try container.parseVig64(program);
        if (image.imageLen() > self.memory.len) return error.ProgramTooLarge;
        if (image.header.entry_point > std.math.maxInt(usize)) return error.ProgramTooLarge;

        // One mark for each byte of the code, then the same walk a VIG32
        // container gets. The marks also stay for the run: `call_indirect` reads
        // them to check a function that only a value names.
        try self.growVerifyScratch(image.code.len);
        try self.verifyVig64Image(image);

        try self.loadWideForeignImports(image);
        @memcpy(self.memory[0..image.code.len], image.code);
        @memcpy(self.memory[image.code.len..][0..image.data.len], image.data);
        self.code_len = image.code.len;
        self.program_len = @intCast(image.imageLen());
        self.ip = @intCast(image.header.entry_point);
        self.execution_abi = .vig64;
    }

    // Read each instruction in the memory. Decode it, then execute it.
    pub fn run(self: *VM) !void {
        if (self.execution_abi == .vig64) return self.runVig64();
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
            self.stats.record(op);
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
                    const target = try self.indirectTarget();

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
                // The same target, without a frame to come back to: control leaves
                // and does not return. This is what a jump table needs.
                .jmp_indirect => self.ip = try self.indirectTarget(),
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

                // Floating point. A slot holds the bits of a binary32, so each of
                // these reads the same four bytes as a different type.
                //
                // None of the arithmetic traps. IEEE-754 gives every operation an
                // answer, so a division by zero is an infinity here rather than the
                // fault that `div` reports.
                .fadd => try self.floatBinary(add),
                .fsub => try self.floatBinary(sub),
                .fmul => try self.floatBinary(mul),
                .fdiv => try self.floatBinary(div),
                .fneg => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.stack[self.sp - 1] = toSlot(-fromSlot(self.stack[self.sp - 1]));
                },
                .fsqrt => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.stack[self.sp - 1] = toSlot(@sqrt(fromSlot(self.stack[self.sp - 1])));
                },

                // Each comparison leaves an integer 0 or 1, as its integer twin
                // does, so a `jmp_not_zero` reads it the same way. A NaN answers
                // false to all of them but `fne`.
                .feq => try self.floatComparison(eq),
                .fne => try self.floatComparison(ne),
                .flt => try self.floatComparison(lt),
                .fle => try self.floatComparison(lte),
                .fgt => try self.floatComparison(gt),
                .fge => try self.floatComparison(gte),

                .f2i => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const value = try floatToInt(i32, fromSlot(self.stack[self.sp - 1]));
                    self.stack[self.sp - 1] = value;
                },
                .f2u => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const value = try floatToInt(u32, fromSlot(self.stack[self.sp - 1]));
                    self.stack[self.sp - 1] = @bitCast(value);
                },
                .i2f => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.stack[self.sp - 1] = toSlot(@floatFromInt(self.stack[self.sp - 1]));
                },
                .u2f => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const bits: u32 = @bitCast(self.stack[self.sp - 1]);
                    self.stack[self.sp - 1] = toSlot(@floatFromInt(bits));
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

                // These instructions require the VIG64 value stack and VIG64
                // container. They are listed here now so a VIG32 VM fails with
                // a defined error instead of treating their bytes as unknown.
                .push64,
                .load64,
                .store64,
                .load64_at,
                .store64_at,
                .add64,
                .sub64,
                .mul64,
                .div64,
                .mod64,
                .eq64,
                .ne64,
                .lt64,
                .lte64,
                .gt64,
                .gte64,
                .lt64_u,
                .lte64_u,
                .gt64_u,
                .gte64_u,
                .div64_u,
                .mod64_u,
                .and64,
                .or64,
                .xor64,
                .not64,
                .shl64,
                .shr64_u,
                .shr64_s,
                .rotl64,
                .add64_wrap,
                .sub64_wrap,
                .mul64_wrap,
                .dadd,
                .dsub,
                .dmul,
                .ddiv,
                .dneg,
                .dsqrt,
                .deq,
                .dne,
                .dlt,
                .dle,
                .dgt,
                .dge,
                .d2i,
                .d2u,
                .d2l,
                .d2ul,
                .i2d,
                .u2d,
                .l2d,
                .ul2d,
                .f2d,
                .d2f,
                .jmp64,
                .jmp_zero64,
                .jmp_not_zero64,
                .call64,
                .load_local32,
                .store_local32,
                => return error.UnsupportedInstruction,
            }
        }
    }

    /// Execute the VIG64 core instruction set. VIG32 instructions that a C
    /// `int` needs keep their 32-bit low-word rules on this wider stack.
    fn runVig64(self: *VM) !void {
        while (self.ip < self.code_len) {
            const op = bytecode.OpCode.fromByte(self.memory[self.ip]) catch return error.InvalidInstruction;
            self.stats.record(op);
            self.ip += 1;
            switch (op) {
                .halt => return,
                .push => {
                    if (self.code_len - self.ip < 4) return error.SegmentFault;
                    const value = std.mem.readInt(i32, self.memory[self.ip..][0..4], .little);
                    self.ip += 4;
                    try self.pushWide(@bitCast(@as(i64, value)));
                },
                .push64 => {
                    if (self.code_len - self.ip < 8) return error.SegmentFault;
                    const value = std.mem.readInt(i64, self.memory[self.ip..][0..8], .little);
                    self.ip += 8;
                    try self.pushWide(@bitCast(value));
                },
                .add => try self.wideNarrowBinary(std.math.add),
                .sub => try self.wideNarrowBinary(std.math.sub),
                .mul => try self.wideNarrowBinary(std.math.mul),
                .add_wrap => try self.wideNarrowWrap(.add),
                .sub_wrap => try self.wideNarrowWrap(.sub),
                .mul_wrap => try self.wideNarrowWrap(.mul),
                .div => try self.wideNarrowDivide(false, false),
                .mod => try self.wideNarrowDivide(false, true),
                .div_u => try self.wideNarrowDivide(true, false),
                .mod_u => try self.wideNarrowDivide(true, true),
                .eq => try self.wideNarrowCompare(.eq, false),
                .ne => try self.wideNarrowCompare(.ne, false),
                .lt => try self.wideNarrowCompare(.lt, false),
                .lte => try self.wideNarrowCompare(.lte, false),
                .gt => try self.wideNarrowCompare(.gt, false),
                .gte => try self.wideNarrowCompare(.gte, false),
                .lt_u => try self.wideNarrowCompare(.lt, true),
                .lte_u => try self.wideNarrowCompare(.lte, true),
                .gt_u => try self.wideNarrowCompare(.gt, true),
                .gte_u => try self.wideNarrowCompare(.gte, true),
                .print => {
                    if (self.sp == 0) return error.StackUnderflow;
                    try self.output.print("{d}\n", .{try self.peekNarrow()});
                },
                .print_hex => {
                    if (self.sp == 0) return error.StackUnderflow;
                    try self.output.print("{x:0>8}\n", .{@as(u32, @bitCast(try self.peekNarrow()))});
                },
                // A VIG64 string pointer is a whole 64-bit slot, so the address
                // is not narrowed first. The instruction leaves it in place, as
                // the VIG32 form does.
                .print_string => {
                    if (self.sp == 0) return error.StackUnderflow;
                    const string = try self.wideGuestCString(self.wide_stack[self.sp - 1]);
                    try self.output.print("{s}\n", .{string});
                },
                .read_i32 => {
                    // Do not consume input when there is nowhere to put the
                    // result.
                    if (self.sp >= self.wide_stack.len) return error.StackOverflow;
                    try self.pushNarrow(try self.readI32());
                },
                .read_byte => {
                    // EOF is data for this instruction rather than a trap, so
                    // a program can loop until it sees -1.
                    if (self.sp >= self.wide_stack.len) return error.StackOverflow;
                    try self.output.flush();
                    const byte = self.input.takeByte() catch |err| switch (err) {
                        error.EndOfStream => return self.pushNarrow(-1),
                        error.ReadFailed => return error.InputReadFailed,
                    };
                    try self.pushNarrow(byte);
                },
                .write_byte => {
                    const byte: u8 = @truncate(try self.popWide());
                    try self.output.writeAll(&[_]u8{byte});
                },
                .@"and" => try self.wideNarrowBits(.and_op),
                .@"or" => try self.wideNarrowBits(.or_op),
                .xor => try self.wideNarrowBits(.xor_op),
                .not => {
                    const value: u32 = @bitCast(try self.popNarrow());
                    try self.pushNarrow(@bitCast(~value));
                },
                .shl => try self.wideNarrowShift(.left),
                .shr_u => try self.wideNarrowShift(.right_unsigned),
                .shr_s => try self.wideNarrowShift(.right_signed),
                .rotl => try self.wideNarrowShift(.rotate_left),
                .jmp => try self.wideJump32(null),
                .jmp_zero => try self.wideJump32(false),
                .jmp_not_zero => try self.wideJump32(true),
                .load => {
                    if (self.code_len - self.ip < 4) return error.SegmentFault;
                    const address = std.mem.readInt(u32, self.memory[self.ip..][0..4], .little);
                    self.ip += 4;
                    const at = try self.checkAccess(address, 4, .read);
                    try self.pushNarrow(std.mem.readInt(i32, self.memory[at..][0..4], .little));
                },
                .store => {
                    if (self.code_len - self.ip < 4) return error.SegmentFault;
                    const address = std.mem.readInt(u32, self.memory[self.ip..][0..4], .little);
                    self.ip += 4;
                    const value = try self.popNarrow();
                    const at = try self.checkAccess(address, 4, .write);
                    std.mem.writeInt(i32, self.memory[at..][0..4], value, .little);
                },
                .load_at, .load32 => try self.wideLoadNarrow(),
                .store_at, .store32 => try self.wideStoreNarrow(),
                .load8_u => try self.wideLoad8(false),
                .load8_s => try self.wideLoad8(true),
                .load16_u => try self.wideLoad16(false),
                .load16_s => try self.wideLoad16(true),
                .store8 => try self.wideStore8(),
                .store16 => try self.wideStore16(),
                .pop => _ = try self.popWide(),
                .dup => {
                    if (self.sp == 0) return error.StackUnderflow;
                    try self.pushWide(self.wide_stack[self.sp - 1]);
                },
                .swap => {
                    if (self.sp < 2) return error.StackUnderflow;
                    const top = self.wide_stack[self.sp - 1];
                    self.wide_stack[self.sp - 1] = self.wide_stack[self.sp - 2];
                    self.wide_stack[self.sp - 2] = top;
                },
                .call => {
                    if (self.code_len - self.ip < 4) return error.SegmentFault;
                    const target = std.mem.readInt(u32, self.memory[self.ip..][0..4], .little);
                    self.ip += 4;
                    try self.wideCall(target);
                },
                .call64 => {
                    if (self.code_len - self.ip < 8) return error.SegmentFault;
                    const target = std.mem.readInt(u64, self.memory[self.ip..][0..8], .little);
                    self.ip += 8;
                    try self.wideCall(target);
                },
                .call_indirect => try self.wideCall(try self.wideIndirectTarget()),
                .jmp_indirect => try self.wideSetJump(try self.wideIndirectTarget()),
                .ret => try self.wideReturn(false),
                .ret_val => try self.wideReturn(true),
                .enter => {
                    if (self.code_len - self.ip < 4) return error.SegmentFault;
                    const shape: bytecode.encode.FrameShape = .{
                        .arguments = std.mem.readInt(u16, self.memory[self.ip..][0..2], .little),
                        .locals = std.mem.readInt(u16, self.memory[self.ip + 2 ..][0..2], .little),
                    };
                    self.ip += 4;
                    try self.enterWideFrame(shape);
                },
                .load_local => {
                    if (self.code_len - self.ip < 2) return error.SegmentFault;
                    const index = std.mem.readInt(u16, self.memory[self.ip..][0..2], .little);
                    self.ip += 2;
                    const at = try self.wideLocalAddress(index);
                    try self.pushWide(std.mem.readInt(u64, self.memory[at..][0..8], .little));
                },
                // The four-byte slot, which is what a C `int' local is. The sign
                // is extended so that the value means the same number as it would
                // through `local_addr` and `load32`, which is what these replace.
                .load_local32 => {
                    if (self.code_len - self.ip < 2) return error.SegmentFault;
                    const index = std.mem.readInt(u16, self.memory[self.ip..][0..2], .little);
                    self.ip += 2;
                    const at = try self.wideLocalAddress(index);
                    try self.pushNarrow(std.mem.readInt(i32, self.memory[at..][0..4], .little));
                },
                .store_local32 => {
                    if (self.code_len - self.ip < 2) return error.SegmentFault;
                    const index = std.mem.readInt(u16, self.memory[self.ip..][0..2], .little);
                    self.ip += 2;
                    const value = try self.popNarrow();
                    const at = try self.wideLocalAddress(index);
                    std.mem.writeInt(i32, self.memory[at..][0..4], value, .little);
                },
                .store_local => {
                    if (self.code_len - self.ip < 2) return error.SegmentFault;
                    const index = std.mem.readInt(u16, self.memory[self.ip..][0..2], .little);
                    self.ip += 2;
                    const value = try self.popWide();
                    const at = try self.wideLocalAddress(index);
                    std.mem.writeInt(u64, self.memory[at..][0..8], value, .little);
                },
                .local_addr => {
                    if (self.code_len - self.ip < 2) return error.SegmentFault;
                    const index = std.mem.readInt(u16, self.memory[self.ip..][0..2], .little);
                    self.ip += 2;
                    try self.pushWide(try self.wideLocalAddress(index));
                },
                .foreign_call => {
                    if (self.ip >= self.code_len) return error.SegmentFault;
                    const index = self.memory[self.ip];
                    self.ip += 1;
                    try self.callWideForeign(index);
                },
                .fadd => try self.wideFloatBinary(.add),
                .fsub => try self.wideFloatBinary(.sub),
                .fmul => try self.wideFloatBinary(.mul),
                .fdiv => try self.wideFloatBinary(.div),
                .fneg => {
                    const value: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
                    try self.pushWide(@as(u32, @bitCast(-value)));
                },
                .fsqrt => {
                    const value: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
                    try self.pushWide(@as(u32, @bitCast(@sqrt(value))));
                },
                .feq => try self.wideFloatCompare(.eq),
                .fne => try self.wideFloatCompare(.ne),
                .flt => try self.wideFloatCompare(.lt),
                .fle => try self.wideFloatCompare(.lte),
                .fgt => try self.wideFloatCompare(.gt),
                .fge => try self.wideFloatCompare(.gte),
                .f2i => {
                    const value: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
                    try self.pushNarrow(try floatToInt(i32, value));
                },
                .f2u => {
                    const value: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
                    try self.pushWide(@as(u32, @bitCast(try floatToInt(u32, value))));
                },
                .i2f => try self.wideNarrowToFloat(false),
                .u2f => try self.wideNarrowToFloat(true),
                .add64 => try self.wideSignedBinary(std.math.add),
                .sub64 => try self.wideSignedBinary(std.math.sub),
                .mul64 => try self.wideSignedBinary(std.math.mul),
                .add64_wrap => try self.wideUnsignedBinary(.add),
                .sub64_wrap => try self.wideUnsignedBinary(.sub),
                .mul64_wrap => try self.wideUnsignedBinary(.mul),
                .div64 => try self.wideSignedDivide(false),
                .mod64 => try self.wideSignedDivide(true),
                .div64_u => try self.wideUnsignedDivide(false),
                .mod64_u => try self.wideUnsignedDivide(true),
                .eq64 => try self.wideCompare(.eq),
                .ne64 => try self.wideCompare(.ne),
                .lt64 => try self.wideCompare(.lt),
                .lte64 => try self.wideCompare(.lte),
                .gt64 => try self.wideCompare(.gt),
                .gte64 => try self.wideCompare(.gte),
                .lt64_u => try self.wideUnsignedCompare(.lt),
                .lte64_u => try self.wideUnsignedCompare(.lte),
                .gt64_u => try self.wideUnsignedCompare(.gt),
                .gte64_u => try self.wideUnsignedCompare(.gte),
                .and64 => try self.wideBits(.and_op),
                .or64 => try self.wideBits(.or_op),
                .xor64 => try self.wideBits(.xor_op),
                .not64 => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.wide_stack[self.sp - 1] = ~self.wide_stack[self.sp - 1];
                },
                .shl64 => try self.wideShift(.left),
                .shr64_u => try self.wideShift(.right_unsigned),
                .shr64_s => try self.wideShift(.right_signed),
                .rotl64 => try self.wideShift(.rotate_left),
                .load64_at => try self.wideLoad64(),
                .store64_at => try self.wideStore64(),
                .load64 => {
                    if (self.code_len - self.ip < 8) return error.SegmentFault;
                    const address = std.mem.readInt(u64, self.memory[self.ip..][0..8], .little);
                    self.ip += 8;
                    const at = try self.wideMemoryAddress(address, 8, .read);
                    try self.pushWide(std.mem.readInt(u64, self.memory[at..][0..8], .little));
                },
                .store64 => {
                    if (self.code_len - self.ip < 8) return error.SegmentFault;
                    const address = std.mem.readInt(u64, self.memory[self.ip..][0..8], .little);
                    self.ip += 8;
                    const value = try self.popWide();
                    const at = try self.wideMemoryAddress(address, 8, .write);
                    std.mem.writeInt(u64, self.memory[at..][0..8], value, .little);
                },
                .dadd => try self.wideDoubleBinary(.add),
                .dsub => try self.wideDoubleBinary(.sub),
                .dmul => try self.wideDoubleBinary(.mul),
                .ddiv => try self.wideDoubleBinary(.div),
                .dneg => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.wide_stack[self.sp - 1] = @bitCast(-@as(f64, @bitCast(self.wide_stack[self.sp - 1])));
                },
                .dsqrt => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.wide_stack[self.sp - 1] = @bitCast(@sqrt(@as(f64, @bitCast(self.wide_stack[self.sp - 1]))));
                },
                .deq => try self.wideDoubleCompare(.eq),
                .dne => try self.wideDoubleCompare(.ne),
                .dlt => try self.wideDoubleCompare(.lt),
                .dle => try self.wideDoubleCompare(.lte),
                .dgt => try self.wideDoubleCompare(.gt),
                .dge => try self.wideDoubleCompare(.gte),
                .d2i => try self.wideDoubleToInteger(i32),
                .d2u => try self.wideDoubleToInteger(u32),
                .d2l => try self.wideDoubleToInteger(i64),
                .d2ul => try self.wideDoubleToInteger(u64),
                .i2d => try self.wideIntegerToDouble(i32),
                .u2d => try self.wideIntegerToDouble(u32),
                .l2d => try self.wideIntegerToDouble(i64),
                .ul2d => try self.wideIntegerToDouble(u64),
                .f2d => {
                    const value: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
                    try self.pushWide(@bitCast(@as(f64, value)));
                },
                .d2f => {
                    const value: f64 = @bitCast(try self.popWide());
                    try self.pushWide(@as(u32, @bitCast(@as(f32, @floatCast(value)))));
                },
                .jmp64 => try self.wideJump64(null),
                .jmp_zero64 => try self.wideJump64(false),
                .jmp_not_zero64 => try self.wideJump64(true),
            }
        }
        return error.SegmentFault;
    }

    fn pushWide(self: *VM, value: u64) !void {
        if (self.sp >= self.wide_stack.len) return error.StackOverflow;
        self.wide_stack[self.sp] = value;
        self.sp += 1;
    }

    fn pushNarrow(self: *VM, value: i32) !void {
        try self.pushWide(@bitCast(@as(i64, value)));
    }

    fn popNarrow(self: *VM) !i32 {
        const bits: u32 = @truncate(try self.popWide());
        return @bitCast(bits);
    }

    fn peekNarrow(self: *const VM) !i32 {
        if (self.sp == 0) return error.StackUnderflow;
        const bits: u32 = @truncate(self.wide_stack[self.sp - 1]);
        return @bitCast(bits);
    }

    fn popWide(self: *VM) !u64 {
        if (self.sp == 0) return error.StackUnderflow;
        self.sp -= 1;
        return self.wide_stack[self.sp];
    }

    fn wideSignedBinary(self: *VM, comptime operation: anytype) !void {
        const b: i64 = @bitCast(try self.popWide());
        const a: i64 = @bitCast(try self.popWide());
        const value = operation(i64, a, b) catch return error.IntegerOverflow;
        try self.pushWide(@bitCast(value));
    }

    fn wideNarrowBinary(self: *VM, comptime operation: anytype) !void {
        const b = try self.popNarrow();
        const a = try self.popNarrow();
        const value = operation(i32, a, b) catch return error.IntegerOverflow;
        try self.pushNarrow(value);
    }

    fn wideNarrowWrap(self: *VM, comptime operation: enum { add, sub, mul }) !void {
        const b: u32 = @bitCast(try self.popNarrow());
        const a: u32 = @bitCast(try self.popNarrow());
        const value: u32 = switch (operation) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
        };
        try self.pushNarrow(@bitCast(value));
    }

    fn wideNarrowDivide(self: *VM, unsigned: bool, remainder: bool) !void {
        if (unsigned) {
            const b: u32 = @bitCast(try self.popNarrow());
            const a: u32 = @bitCast(try self.popNarrow());
            if (b == 0) return error.DivisionByZero;
            try self.pushNarrow(@bitCast(if (remainder) a % b else a / b));
        } else {
            const b = try self.popNarrow();
            const a = try self.popNarrow();
            if (b == 0) return error.DivisionByZero;
            if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
            try self.pushNarrow(if (remainder) @rem(a, b) else @divTrunc(a, b));
        }
    }

    fn wideNarrowCompare(self: *VM, comptime operation: enum { eq, ne, lt, lte, gt, gte }, unsigned: bool) !void {
        const b = try self.popNarrow();
        const a = try self.popNarrow();
        const result = if (unsigned) blk: {
            const au: u32 = @bitCast(a);
            const bu: u32 = @bitCast(b);
            break :blk switch (operation) {
                .eq => au == bu,
                .ne => au != bu,
                .lt => au < bu,
                .lte => au <= bu,
                .gt => au > bu,
                .gte => au >= bu,
            };
        } else switch (operation) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .lte => a <= b,
            .gt => a > b,
            .gte => a >= b,
        };
        try self.pushWide(@intFromBool(result));
    }

    fn wideNarrowBits(self: *VM, comptime operation: enum { and_op, or_op, xor_op }) !void {
        const b: u32 = @bitCast(try self.popNarrow());
        const a: u32 = @bitCast(try self.popNarrow());
        const value = switch (operation) {
            .and_op => a & b,
            .or_op => a | b,
            .xor_op => a ^ b,
        };
        try self.pushNarrow(@bitCast(value));
    }

    fn wideNarrowShift(self: *VM, comptime operation: enum { left, right_unsigned, right_signed, rotate_left }) !void {
        const count: u5 = @truncate(try self.popWide());
        const value: u32 = @bitCast(try self.popNarrow());
        const result: u32 = switch (operation) {
            .left => value << count,
            .right_unsigned => value >> count,
            .right_signed => @bitCast(@as(i32, @bitCast(value)) >> count),
            .rotate_left => std.math.rotl(u32, value, count),
        };
        try self.pushNarrow(@bitCast(result));
    }

    fn wideJump32(self: *VM, condition: ?bool) !void {
        if (self.code_len - self.ip < 4) return error.SegmentFault;
        const target = std.mem.readInt(u32, self.memory[self.ip..][0..4], .little);
        self.ip += 4;
        if (condition) |wanted| {
            const value = try self.popWide();
            if ((value != 0) != wanted) return;
        }
        if (target >= self.code_len) return error.SegmentFault;
        self.ip = target;
    }

    fn wideJump64(self: *VM, condition: ?bool) !void {
        if (self.code_len - self.ip < 8) return error.SegmentFault;
        const target = std.mem.readInt(u64, self.memory[self.ip..][0..8], .little);
        self.ip += 8;
        if (condition) |wanted| {
            const value = try self.popWide();
            if ((value != 0) != wanted) return;
        }
        try self.wideSetJump(target);
    }

    /// Take the target of a VIG64 indirect transfer off the stack and verify the
    /// code it names.
    ///
    /// A direct `call64` or `jmp64` has a verified target already: the walk at load
    /// time read the operand. This target was a value on the stack, so no read of
    /// the code could find it, and it is checked here the first time control goes
    /// to it. See `verifyIndirectTarget`.
    fn wideIndirectTarget(self: *VM) !u64 {
        const value = try self.popWide();
        const target = std.math.cast(usize, value) orelse return error.SegmentFault;
        if (target >= self.code_len) return error.SegmentFault;
        try self.verifyIndirectTarget(target);
        return value;
    }

    fn wideSetJump(self: *VM, target: u64) !void {
        const at = std.math.cast(usize, target) orelse return error.SegmentFault;
        if (at >= self.code_len) return error.SegmentFault;
        self.ip = at;
    }

    fn wideLoadNarrow(self: *VM) !void {
        const address = try self.popWide();
        const at = try self.wideMemoryAddress(address, 4, .read);
        try self.pushNarrow(std.mem.readInt(i32, self.memory[at..][0..4], .little));
    }

    fn wideStoreNarrow(self: *VM) !void {
        const address = try self.popWide();
        const value = try self.popNarrow();
        const at = try self.wideMemoryAddress(address, 4, .write);
        std.mem.writeInt(i32, self.memory[at..][0..4], value, .little);
    }

    fn wideLoad8(self: *VM, signed: bool) !void {
        const at = try self.wideMemoryAddress(try self.popWide(), 1, .read);
        if (signed) {
            const value: i8 = @bitCast(self.memory[at]);
            try self.pushWide(@bitCast(@as(i64, value)));
        } else try self.pushWide(self.memory[at]);
    }

    fn wideLoad16(self: *VM, signed: bool) !void {
        const at = try self.wideMemoryAddress(try self.popWide(), 2, .read);
        const bits = std.mem.readInt(u16, self.memory[at..][0..2], .little);
        if (signed) try self.pushWide(@bitCast(@as(i64, @as(i16, @bitCast(bits))))) else try self.pushWide(bits);
    }

    fn wideStore8(self: *VM) !void {
        const address = try self.popWide();
        const value: u8 = @truncate(try self.popWide());
        const at = try self.wideMemoryAddress(address, 1, .write);
        self.memory[at] = value;
    }

    fn wideStore16(self: *VM) !void {
        const address = try self.popWide();
        const value: u16 = @truncate(try self.popWide());
        const at = try self.wideMemoryAddress(address, 2, .write);
        std.mem.writeInt(u16, self.memory[at..][0..2], value, .little);
    }

    fn wideUnsignedBinary(self: *VM, comptime operation: enum { add, sub, mul }) !void {
        const b = try self.popWide();
        const a = try self.popWide();
        try self.pushWide(switch (operation) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
        });
    }

    fn wideSignedDivide(self: *VM, remainder: bool) !void {
        const b: i64 = @bitCast(try self.popWide());
        const a: i64 = @bitCast(try self.popWide());
        if (b == 0) return error.DivisionByZero;
        if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
        try self.pushWide(@bitCast(if (remainder) @rem(a, b) else @divTrunc(a, b)));
    }

    fn wideUnsignedDivide(self: *VM, remainder: bool) !void {
        const b = try self.popWide();
        const a = try self.popWide();
        if (b == 0) return error.DivisionByZero;
        try self.pushWide(if (remainder) a % b else a / b);
    }

    fn wideCompare(self: *VM, comptime operation: enum { eq, ne, lt, lte, gt, gte }) !void {
        const b: i64 = @bitCast(try self.popWide());
        const a: i64 = @bitCast(try self.popWide());
        try self.pushWide(@intFromBool(switch (operation) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .lte => a <= b,
            .gt => a > b,
            .gte => a >= b,
        }));
    }

    fn wideUnsignedCompare(self: *VM, comptime operation: enum { lt, lte, gt, gte }) !void {
        const b = try self.popWide();
        const a = try self.popWide();
        try self.pushWide(@intFromBool(switch (operation) {
            .lt => a < b,
            .lte => a <= b,
            .gt => a > b,
            .gte => a >= b,
        }));
    }

    fn wideBits(self: *VM, comptime operation: enum { and_op, or_op, xor_op }) !void {
        const b = try self.popWide();
        const a = try self.popWide();
        try self.pushWide(switch (operation) {
            .and_op => a & b,
            .or_op => a | b,
            .xor_op => a ^ b,
        });
    }

    fn wideShift(self: *VM, comptime operation: enum { left, right_unsigned, right_signed, rotate_left }) !void {
        const count: u6 = @truncate(try self.popWide());
        const value = try self.popWide();
        const result: u64 = switch (operation) {
            .left => value << count,
            .right_unsigned => value >> count,
            .right_signed => @bitCast(@as(i64, @bitCast(value)) >> count),
            .rotate_left => std.math.rotl(u64, value, count),
        };
        try self.pushWide(result);
    }

    fn wideMemoryAddress(self: *const VM, address: u64, width: usize, access: Access) !usize {
        const at = std.math.cast(usize, address) orelse return error.SegmentFault;
        return self.checkAccess(at, width, access);
    }

    fn wideLoad64(self: *VM) !void {
        const address = try self.popWide();
        const at = try self.wideMemoryAddress(address, 8, .read);
        try self.pushWide(std.mem.readInt(u64, self.memory[at..][0..8], .little));
    }

    fn wideStore64(self: *VM) !void {
        const address = try self.popWide();
        const value = try self.popWide();
        const at = try self.wideMemoryAddress(address, 8, .write);
        std.mem.writeInt(u64, self.memory[at..][0..8], value, .little);
    }

    fn wideDoubleBinary(self: *VM, comptime operation: enum { add, sub, mul, div }) !void {
        const b: f64 = @bitCast(try self.popWide());
        const a: f64 = @bitCast(try self.popWide());
        const value = switch (operation) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => a / b,
        };
        try self.pushWide(@bitCast(value));
    }

    fn wideFloatBinary(self: *VM, comptime operation: enum { add, sub, mul, div }) !void {
        const b: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
        const a: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
        const value = switch (operation) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => a / b,
        };
        try self.pushWide(@as(u32, @bitCast(value)));
    }

    fn wideFloatCompare(self: *VM, comptime operation: enum { eq, ne, lt, lte, gt, gte }) !void {
        const b: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
        const a: f32 = @bitCast(@as(u32, @truncate(try self.popWide())));
        try self.pushWide(@intFromBool(switch (operation) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .lte => a <= b,
            .gt => a > b,
            .gte => a >= b,
        }));
    }

    fn wideNarrowToFloat(self: *VM, unsigned: bool) !void {
        const bits: u32 = @bitCast(try self.popNarrow());
        const value: f32 = if (unsigned) @floatFromInt(bits) else @floatFromInt(@as(i32, @bitCast(bits)));
        try self.pushWide(@as(u32, @bitCast(value)));
    }

    fn wideDoubleCompare(self: *VM, comptime operation: enum { eq, ne, lt, lte, gt, gte }) !void {
        const b: f64 = @bitCast(try self.popWide());
        const a: f64 = @bitCast(try self.popWide());
        try self.pushWide(@intFromBool(switch (operation) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .lte => a <= b,
            .gt => a > b,
            .gte => a >= b,
        }));
    }

    fn wideDoubleToInteger(self: *VM, comptime T: type) !void {
        const value: f64 = @bitCast(try self.popWide());
        const result = try doubleToInt(T, value);
        if (T == i32) try self.pushNarrow(result) else if (T == u32) try self.pushWide(result) else if (T == i64) try self.pushWide(@bitCast(result)) else try self.pushWide(result);
    }

    fn wideIntegerToDouble(self: *VM, comptime T: type) !void {
        const raw = try self.popWide();
        const input: T = if (T == i32) @as(i32, @bitCast(@as(u32, @truncate(raw)))) else if (T == u32) @truncate(raw) else @bitCast(raw);
        try self.pushWide(@bitCast(@as(f64, @floatFromInt(input))));
    }

    fn wideCall(self: *VM, target: u64) !void {
        const at = std.math.cast(usize, target) orelse return error.SegmentFault;
        if (at >= self.code_len) return error.SegmentFault;
        if (self.csp >= self.call_stack.len) return error.CallStackOverflow;
        self.call_stack[self.csp] = .{ .return_ip = self.ip, .operand_base = self.sp, .saved_frame_pointer = self.frame_pointer };
        self.csp += 1;
        self.ip = at;
    }

    fn enterWideFrame(self: *VM, shape: bytecode.encode.FrameShape) !void {
        if (self.csp == 0) return error.EnterOutsideCall;
        const frame = &self.call_stack[self.csp - 1];
        if (frame.entered) return error.FrameAlreadyEntered;
        const arguments: usize = shape.arguments;
        if (self.sp < arguments) return error.StackUnderflow;
        const size = @as(usize, shape.slots()) * 8;
        if (size > self.frame_pointer or self.frame_pointer - size < self.program_len) return error.FrameMemoryExhausted;
        const base = self.frame_pointer - size;
        self.sp -= arguments;
        for (0..arguments) |index| std.mem.writeInt(u64, self.memory[base + index * 8 ..][0..8], self.wide_stack[self.sp + index], .little);
        @memset(self.memory[base + arguments * 8 .. base + size], 0);
        frame.entered = true;
        frame.frame_base = base;
        frame.arguments = shape.arguments;
        frame.locals = shape.locals;
        self.frame_pointer = base;
    }

    fn wideReturn(self: *VM, with_value: bool) !void {
        if (self.csp == 0) return error.CallStackUnderflow;
        const value = if (with_value) try self.popWide() else 0;
        self.csp -= 1;
        const frame = self.call_stack[self.csp];
        if (frame.entered) {
            self.sp = frame.operand_base - frame.arguments;
            if (with_value) try self.pushWide(value);
        }
        self.frame_pointer = frame.saved_frame_pointer;
        self.ip = frame.return_ip;
    }

    fn wideLocalAddress(self: *const VM, index: u16) !usize {
        if (self.csp == 0) return error.NoActiveFrame;
        const frame = self.call_stack[self.csp - 1];
        if (index >= frame.slots()) return error.LocalOutOfRange;
        return frame.frame_base + @as(usize, index) * 8;
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

    // The first address that a guest *string* cannot use.
    //
    // A string is read to its terminator, so the search needs somewhere to stop. The
    // limit is the program image — the code, then the static data, then the
    // zero-filled region — and not the whole of memory, because memory above the
    // image starts as zeros: every address in it would look like the end of a string
    // and `UnterminatedGuestString` would stop meaning anything.
    //
    // A pointer that is not a string has no such limit. See `guestPointer`.
    fn guestStringLimit(self: *const VM) usize {
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

    fn clearWideForeignImports(self: *VM) void {
        for (self.wide_foreign_imports) |*entry| {
            if (entry.*) |*import| foreign.closeVig64(import);
            entry.* = null;
        }
        self.wide_foreign_import_count = 0;
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

    fn loadWideForeignImports(self: *VM, image: container.Vig64Image) !void {
        var iterator = image.importIterator();
        while (try iterator.next()) |import| {
            self.wide_foreign_imports[self.wide_foreign_import_count] = try foreign.resolveVig64(
                import.library,
                import.symbol,
                import.result,
                import.argTypes(),
            );
            self.wide_foreign_import_count += 1;
        }
    }

    fn callWideForeign(self: *VM, import_index: u8) !void {
        const index: usize = import_index;
        if (index >= self.wide_foreign_import_count) return error.InvalidForeignImport;
        const import = &(self.wide_foreign_imports[index] orelse return error.InvalidForeignImport);
        const count: usize = import.arg_count;
        if (self.sp < count) return error.StackUnderflow;
        var args: [bytecode.foreign.vig64_max_args]foreign.Vig64Value = undefined;
        var position = count;
        while (position > 0) {
            position -= 1;
            args[position] = try self.marshalWideForeignArgument(import.arg_types[position], try self.popWide());
        }
        try self.output.flush();
        const result = try foreign.invokeVig64(import, args);
        switch (import.result) {
            .void => {},
            .i32 => try self.pushNarrow(result.i32),
            .u32 => try self.pushWide(result.u32),
            .i64 => try self.pushWide(@bitCast(result.i64)),
            .u64 => try self.pushWide(result.u64),
            .guest_ptr, .host_ptr => try self.pushWide(if (result.ptr) |pointer| @intFromPtr(pointer) else 0),
            .f32 => try self.pushWide(@as(u32, @bitCast(result.f32))),
            .f64 => try self.pushWide(@bitCast(result.f64)),
        }
    }

    fn marshalWideForeignArgument(self: *VM, kind: foreign.Vig64Type, value: u64) !foreign.Vig64Value {
        return switch (kind) {
            .i32 => .{ .i32 = @bitCast(@as(u32, @truncate(value))) },
            .u32 => .{ .u32 = @truncate(value) },
            .i64 => .{ .i64 = @bitCast(value) },
            .u64 => .{ .u64 = value },
            .f32 => .{ .f32 = @bitCast(@as(u32, @truncate(value))) },
            .f64 => .{ .f64 = @bitCast(value) },
            .guest_ptr => .{ .ptr = if (value == 0) null else @ptrFromInt(try self.wideGuestPointer(value)) },
            .host_ptr => .{ .ptr = if (value == 0) null else @ptrFromInt(value) },
        };
    }

    /// The bytes of a VIG64 guest string, without its terminator. The bound is
    /// the program image, exactly as it is for a VIG32 string: see
    /// `guestStringLimit`.
    fn wideGuestCString(self: *const VM, value: u64) ![]const u8 {
        if (value == 0) return error.InvalidGuestPointer;
        const offset = std.math.cast(usize, value) orelse return error.InvalidGuestPointer;
        const limit = self.guestStringLimit();
        if (offset >= limit) return error.InvalidGuestPointer;

        const bytes = self.memory[offset..limit];
        const terminator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.UnterminatedGuestString;
        return bytes[0..terminator];
    }

    fn wideGuestPointer(self: *VM, value: u64) !usize {
        const offset = std.math.cast(usize, value) orelse return error.InvalidGuestPointer;
        if (offset >= self.memory.len) return error.InvalidGuestPointer;
        return @intFromPtr(self.memory[offset..].ptr);
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
    fn verifyOptions(self: *const VM, code: []const u8, entry_point: u64, import_count: u8) verify.Options {
        return .{
            .code = code,
            .entry_point = entry_point,
            .import_count = import_count,
            // The VM knows the size of its memory and the length of the code.
            // Therefore an address in a `load` or a `store` operand, and a `store`
            // that would write an instruction, are both found before any of the
            // program runs.
            .memory_size = self.memory.len,
            .code_len = code.len,
        };
    }

    /// Give the verifier one mark for each byte of a code region of `code_len`, and
    /// set every mark to `unknown`.
    ///
    /// The scratch is kept between programs, so a program no larger than the last one
    /// needs no allocation. It is cleared either way: `call_indirect` reads these
    /// marks while the program runs, and a mark that an earlier program left would
    /// answer for code that is no longer there.
    fn growVerifyScratch(self: *VM, code_len: usize) !void {
        if (self.verify_scratch.len < code_len) {
            self.verify_scratch = try self.allocator.realloc(self.verify_scratch, code_len);
        }
        @memset(self.verify_scratch, .unknown);
    }

    // Make sure that the code region is safe to execute before the VM runs any of
    // it. The vig-bytecode verifier gives the list of the checks.
    fn verifyImage(self: *VM, image: container.Image) !void {
        var failure: verify.Failure = undefined;
        const options = self.verifyOptions(
            image.code,
            image.header.entry_point,
            image.header.import_count,
        );
        verify.verify(options, self.verify_scratch, &failure) catch |err| {
            self.verification_failure = failure;
            return err;
        };
    }

    // The same checks for a VIG64 container. The verifier decodes the VIG64
    // instructions and follows their wide branch targets, so a VIG64 program is
    // refused before it runs for the same reasons a VIG32 one is. Skipping this
    // would leave the newer ABI the only one that runs unchecked.
    fn verifyVig64Image(self: *VM, image: container.Vig64Image) !void {
        var failure: verify.Failure = undefined;
        const options = self.verifyOptions(
            image.code,
            image.header.entry_point,
            image.header.import_count,
        );
        verify.verify(options, self.verify_scratch, &failure) catch |err| {
            self.verification_failure = failure;
            return err;
        };
    }

    // Floating point ----------------------------------------------------------
    //
    // A slot is four bytes and a binary32 is four bytes, so a float lives on the
    // operand stack with no room to spare and no tag. These two are the whole of
    // the representation: the bits go in and come out unchanged.

    fn fromSlot(slot: i32) f32 {
        return @bitCast(slot);
    }

    fn toSlot(value: f32) i32 {
        return @bitCast(value);
    }

    /// Apply a two-operand floating-point instruction. None of them can fail:
    /// IEEE-754 answers every one, so there is no error to give.
    fn floatBinary(self: *VM, comptime apply: fn (f32, f32) f32) !void {
        if (self.sp < 2) return error.StackUnderflow;

        const a = fromSlot(self.stack[self.sp - 2]);
        const b = fromSlot(self.stack[self.sp - 1]);
        self.sp -= 1;
        self.stack[self.sp - 1] = toSlot(apply(a, b));
    }

    /// The same for a comparison, which leaves the integer 1 or 0.
    fn floatComparison(self: *VM, comptime compare: fn (f32, f32) bool) !void {
        if (self.sp < 2) return error.StackUnderflow;

        const a = fromSlot(self.stack[self.sp - 2]);
        const b = fromSlot(self.stack[self.sp - 1]);
        self.sp -= 1;
        self.stack[self.sp - 1] = if (compare(a, b)) 1 else 0;
    }

    /// Take the target of an indirect transfer off the stack, check it, and give
    /// the offset to continue at.
    ///
    /// `call_indirect` and `jmp_indirect` differ in what they do afterwards and in
    /// nothing before it, so both arrive here.
    fn indirectTarget(self: *VM) !u32 {
        if (self.sp == 0) return error.StackUnderflow;

        self.sp -= 1;
        const value = self.stack[self.sp];
        // The target is an address in the code region, so it is a positive number
        // below the end of that region. A negative one has no unsigned equivalent,
        // exactly as for a data address.
        if (value < 0) return error.SegmentFault;
        const target: u32 = @intCast(value);
        if (target >= self.code_len) return error.SegmentFault;

        // A direct transfer has a verified target, because the verifier read the
        // operand before the run. This one was on the stack, so no read of the code
        // could find it. Therefore the check happens here, the first time control
        // goes to this address.
        try self.verifyIndirectTarget(target);
        return target;
    }

    /// Verify the code that an indirect transfer names.
    ///
    /// The walk at load time starts at the entry point and follows what it reads, so
    /// it never reaches code that only a value names: the body of a function that a
    /// pointer calls, or the arm of a jump table. This is where such code is
    /// checked, and the marks from load time say whether an earlier transfer already
    /// checked it. The code cannot change while the program runs, so the answer is
    /// the one that a check before the run would have given.
    fn verifyIndirectTarget(self: *VM, target: usize) !void {
        // The common case: an address that some path already decoded. The verifier
        // answers this from one mark, but the call is not free, and an indirect call
        // is an instruction in a loop as often as any other.
        if (self.verify_scratch[target] == .boundary) return;

        var failure: verify.Failure = undefined;
        const options = self.verifyOptions(
            self.memory[0..self.code_len],
            // The entry point is not read by `verifyFrom`, which starts at `target`.
            0,
            @intCast(if (self.execution_abi == .vig64) self.wide_foreign_import_count else self.foreign_import_count),
        );
        verify.verifyFrom(options, self.verify_scratch, target, &failure) catch |err| {
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
    /// The host address for a guest pointer that a foreign function will receive.
    ///
    /// A `ptr` argument may name any byte of guest memory, including one in a call
    /// frame. That is what lets a C program pass the address of a local, which is
    /// most of what a pointer argument is for. The bound is the memory itself, so a
    /// foreign function still cannot be handed an address outside it.
    ///
    /// A `cstr` argument is read to its terminator, so it keeps the tighter bound of
    /// `guestStringLimit`. A zero value is the null pointer either way.
    fn guestPointer(self: *VM, value: i32, require_terminator: bool) !usize {
        if (value == 0) return 0;
        if (value < 0) return error.InvalidGuestPointer;

        const offset: usize = @intCast(value);
        const limit = if (require_terminator) self.guestStringLimit() else self.memory.len;
        if (offset >= limit) return error.InvalidGuestPointer;

        if (require_terminator) _ = try self.guestCString(value);
        return @intFromPtr(self.memory[offset..].ptr);
    }

    fn guestCString(self: *VM, value: i32) ![]const u8 {
        if (value <= 0) return error.InvalidGuestPointer;
        const offset: usize = @intCast(value);
        const limit = self.guestStringLimit();
        if (offset >= limit) return error.InvalidGuestPointer;

        const bytes = self.memory[offset..limit];
        const terminator = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.UnterminatedGuestString;
        return bytes[0..terminator];
    }
};

/// The floating-point operations, as functions so that one instruction body can
/// take any of them. Zig's operators already follow IEEE-754: a NaN compares
/// false against everything, and a division by zero gives an infinity.
fn add(a: f32, b: f32) f32 {
    return a + b;
}

fn sub(a: f32, b: f32) f32 {
    return a - b;
}

fn mul(a: f32, b: f32) f32 {
    return a * b;
}

fn div(a: f32, b: f32) f32 {
    return a / b;
}

fn eq(a: f32, b: f32) bool {
    return a == b;
}

fn ne(a: f32, b: f32) bool {
    return a != b;
}

fn lt(a: f32, b: f32) bool {
    return a < b;
}

fn lte(a: f32, b: f32) bool {
    return a <= b;
}

fn gt(a: f32, b: f32) bool {
    return a > b;
}

fn gte(a: f32, b: f32) bool {
    return a >= b;
}

/// Truncate `value` toward zero into `T`, as a cast in C does.
///
/// A value the integer cannot hold has no answer, so this gives an error rather
/// than a number: C leaves the case undefined, and the rest of this VM reports
/// an arithmetic result it cannot represent instead of inventing one.
///
/// The bound is written as one condition that must hold, so a NaN fails it
/// without a test of its own: every comparison against a NaN is false.
fn floatToInt(comptime T: type, value: f32) !T {
    const truncated = @trunc(value);
    // The first magnitude the type cannot reach, which is a power of two and so
    // exactly representable. Comparing against the largest value it *can* reach
    // would not be: 2147483647 has no binary32 form and rounds up to the limit.
    const limit: f32 = @floatFromInt(@as(i64, std.math.maxInt(T)) + 1);
    const floor: f32 = if (std.math.minInt(T) == 0) 0.0 else -limit;

    if (!(truncated >= floor and truncated < limit)) return error.InvalidFloatConversion;
    return @intFromFloat(truncated);
}

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
        vm.init(std.testing.allocator, constants.testing, undefined, undefined) catch @panic("OOM");

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

/// The binary64 equivalent of `floatToInt`. C casts truncate toward zero and a
/// NaN or an out-of-range value has no representable VM result.
fn doubleToInt(comptime T: type, value: f64) !T {
    const truncated = @trunc(value);
    const limit: f64 = @floatFromInt(@as(i128, std.math.maxInt(T)) + 1);
    const floor: f64 = if (std.math.minInt(T) == 0) 0.0 else -limit;
    if (!(truncated >= floor and truncated < limit)) return error.InvalidFloatConversion;
    return @intFromFloat(truncated);
}

test "a VIG64 container executes wide integer arithmetic" {
    var code: [20]u8 = undefined;
    code[0] = @backingInt(bytecode.OpCode.push64);
    std.mem.writeInt(i64, code[1..9], 40, .little);
    code[9] = @backingInt(bytecode.OpCode.push64);
    std.mem.writeInt(i64, code[10..18], 2, .little);
    code[18] = @backingInt(bytecode.OpCode.add64);
    code[19] = @backingInt(bytecode.OpCode.halt);
    var program: [128]u8 = undefined;
    const size = try container.writeVig64(.{ .code = &code }, &program);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try harness.vm.loadProgram(program[0..size]);
    try harness.vm.run();
    try std.testing.expectEqual(ExecutionAbi.vig64, harness.vm.execution_abi);
    try std.testing.expectEqual(@as(usize, 1), harness.vm.sp);
    try std.testing.expectEqual(@as(u64, 42), harness.vm.wide_stack[0]);
}

test "a VIG64 container executes binary64 arithmetic" {
    var code: [20]u8 = undefined;
    code[0] = @backingInt(bytecode.OpCode.push64);
    std.mem.writeInt(u64, code[1..9], @bitCast(@as(f64, 1.5)), .little);
    code[9] = @backingInt(bytecode.OpCode.push64);
    std.mem.writeInt(u64, code[10..18], @bitCast(@as(f64, 2.0)), .little);
    code[18] = @backingInt(bytecode.OpCode.dmul);
    code[19] = @backingInt(bytecode.OpCode.halt);
    var program: [128]u8 = undefined;
    const size = try container.writeVig64(.{ .code = &code }, &program);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try harness.vm.loadProgram(program[0..size]);
    try harness.vm.run();
    try std.testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(harness.vm.wide_stack[0])));
}

test "a VIG64 container executes binary64 conversions and wide bit operations" {
    var code: [31]u8 = undefined;
    code[0] = @backingInt(bytecode.OpCode.push64);
    std.mem.writeInt(u64, code[1..9], @bitCast(@as(f64, 42.75)), .little);
    code[9] = @backingInt(bytecode.OpCode.d2l);
    code[10] = @backingInt(bytecode.OpCode.push64);
    std.mem.writeInt(u64, code[11..19], 0xf0, .little);
    code[19] = @backingInt(bytecode.OpCode.push64);
    std.mem.writeInt(u64, code[20..28], 0x0f, .little);
    code[28] = @backingInt(bytecode.OpCode.@"or");
    code[29] = @backingInt(bytecode.OpCode.or64);
    code[30] = @backingInt(bytecode.OpCode.halt);
    var program: [128]u8 = undefined;
    const size = try container.writeVig64(.{ .code = &code }, &program);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try harness.vm.loadProgram(program[0..size]);
    try harness.vm.run();
    try std.testing.expectEqual(@as(u64, 0xff), harness.vm.wide_stack[0]);
}

test "a VIG64 container invokes a typed foreign import" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const import: bytecode.foreign.Vig64Import = .{
        .library = "kernel32.dll",
        .symbol = "GetCurrentProcessId",
        .result = .u32,
    };
    const code = [_]u8{ @backingInt(bytecode.OpCode.foreign_call), 0, @backingInt(bytecode.OpCode.halt) };
    var program: [128]u8 = undefined;
    const size = try container.writeVig64(.{ .imports = &.{import}, .code = &code }, &program);
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try harness.vm.loadProgram(program[0..size]);
    try harness.vm.run();
    try std.testing.expect(harness.vm.wide_stack[0] > 0);
}

test "the 32-bit frame instructions reach four bytes of a slot and no more" {
    // `store_local32` and `load_local32` are exactly `local_addr N` followed by
    // `store32` or `load32`, in one instruction. What that means for a slot is
    // tested here rather than assumed: the whole slot is filled with ones, four
    // bytes of it are written, and then the slot is read both ways. A `load_local`
    // must see the ones still in the high half, and a `load_local32` must see the
    // four bytes it wrote, with their sign extended.
    //
    // A compiler that emitted `load_local` for a four-byte local would pass every
    // test that only reads what it wrote through the same instruction. This is the
    // one that would fail.
    var code: [42]u8 = undefined;
    code[0] = opByte(.call64);
    std.mem.writeInt(u64, code[1..9], 10, .little);
    code[9] = opByte(.halt);

    code[10] = opByte(.enter);
    std.mem.writeInt(u16, code[11..13], 0, .little); // no arguments
    std.mem.writeInt(u16, code[13..15], 1, .little); // one local

    code[15] = opByte(.push64);
    std.mem.writeInt(i64, code[16..24], -1, .little);
    code[24] = opByte(.store_local);
    std.mem.writeInt(u16, code[25..27], 0, .little);

    // A negative value, so the sign extension of the narrow load is visible.
    code[27] = opByte(.push);
    std.mem.writeInt(i32, code[28..32], -5, .little);
    code[32] = opByte(.store_local32);
    std.mem.writeInt(u16, code[33..35], 0, .little);

    code[35] = opByte(.load_local);
    std.mem.writeInt(u16, code[36..38], 0, .little);
    code[38] = opByte(.load_local32);
    std.mem.writeInt(u16, code[39..41], 0, .little);
    code[41] = opByte(.halt);

    var program: [160]u8 = undefined;
    const size = try container.writeVig64(.{ .code = &code }, &program);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try harness.vm.loadProgram(program[0..size]);
    try harness.vm.run();

    try std.testing.expectEqual(@as(usize, 2), harness.vm.sp);
    // The high half kept the ones that `store_local` put there, and the low half
    // holds what `store_local32` wrote.
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF_FFFFFFFB), harness.vm.wide_stack[0]);
    // And the narrow load extended the sign of those four bytes.
    try std.testing.expectEqual(@as(i64, -5), @as(i64, @bitCast(harness.vm.wide_stack[1])));
}

test "a VIG64 container is verified before it runs" {
    // `jmp64` names a target that no instruction begins at, so a path would decode
    // the operand bytes of the jump itself as an opcode. This is the check that a
    // VIG32 container has had all along, on the wide branch instead of the narrow
    // one: the verifier follows a `code_target64` the same way it follows a
    // `code_target`.
    var code: [10]u8 = undefined;
    code[0] = opByte(.jmp64);
    std.mem.writeInt(u64, code[1..9], 3, .little);
    code[9] = opByte(.halt);
    var program: [128]u8 = undefined;
    const size = try container.writeVig64(.{ .code = &code }, &program);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try std.testing.expectError(error.MisalignedTarget, harness.vm.loadProgram(program[0..size]));
    try std.testing.expectEqual(@as(usize, 0), harness.vm.verification_failure.?.offset);
}

test "a VIG64 store into the code region is refused at load time" {
    var code: [11]u8 = undefined;
    code[0] = opByte(.push64);
    std.mem.writeInt(i64, code[1..9], 7, .little);
    code[9] = opByte(.store64);
    // The operand is missing, so the instruction runs past the end of the region.
    code[10] = opByte(.halt);
    var program: [160]u8 = undefined;
    const truncated = try container.writeVig64(.{ .code = &code }, &program);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    try std.testing.expectError(error.TruncatedInstruction, harness.vm.loadProgram(program[0..truncated]));

    // A whole `store64` whose address is inside the code region would rewrite an
    // instruction, which would make the rest of the verification untrue.
    var whole: [19]u8 = undefined;
    whole[0] = opByte(.push64);
    std.mem.writeInt(i64, whole[1..9], 7, .little);
    whole[9] = opByte(.store64);
    std.mem.writeInt(u64, whole[10..18], 0, .little);
    whole[18] = opByte(.halt);
    const size = try container.writeVig64(.{ .code = &whole }, &program);
    try std.testing.expectError(error.StoreIntoCodeRegion, harness.vm.loadProgram(program[0..size]));
}

test "a VIG64 indirect call verifies the function it reaches" {
    // `_start` calls a function that no instruction names, so the walk at load time
    // cannot reach it and the check happens at the call. The function here ends in a
    // byte that no opcode has.
    var code: [15]u8 = undefined;
    code[0] = opByte(.push64);
    std.mem.writeInt(i64, code[1..9], 10, .little);
    code[9] = opByte(.call_indirect);
    code[10] = opByte(.halt);
    code[11] = opByte(.halt);
    code[12] = opByte(.halt);
    code[13] = opByte(.halt);
    code[14] = 0xfe;
    var program: [160]u8 = undefined;
    const size = try container.writeVig64(.{ .code = &code, .entry_point = 0 }, &program);

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    // The program loads: the bad byte is not on any path the operands name.
    try harness.vm.loadProgram(program[0..size]);

    // Reaching it through a value is refused, and the target itself was fine.
    var reachable: [15]u8 = undefined;
    @memcpy(&reachable, &code);
    std.mem.writeInt(i64, reachable[1..9], 14, .little);
    const bad = try container.writeVig64(.{ .code = &reachable, .entry_point = 0 }, &program);
    try harness.vm.loadProgram(program[0..bad]);
    try std.testing.expectError(error.UnknownOpcode, harness.vm.run());
}

fn opByte(code: bytecode.OpCode) u8 {
    return @backingInt(code);
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
        @backingInt(bytecode.OpCode.push),
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
    const code: [constants.testing.memory_size]u8 = @splat(opByte(.halt));
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
        @backingInt(bytecode.OpCode.push),         7,                                 0,   0,   0,
        @backingInt(bytecode.OpCode.print_string), @backingInt(bytecode.OpCode.halt), 'h', 'e', 'l',
        'l',                                       'o',                               0,
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

    const program = [_]u8{ @backingInt(bytecode.OpCode.halt), 'x' };
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
    const last: i32 = constants.testing.memory_size - 1;

    // The widest access that still fits works.
    try expectOutput(
        &(push(last - 3) ++ [_]u8{ opByte(.load_at), opByte(.print), opByte(.halt) }),
        "0\n",
    );

    // One byte further needs four bytes and has three.
    try expectTrap(&(push(last - 2) ++ [_]u8{ opByte(.load_at), opByte(.halt) }), error.SegmentFault, "");
    try expectTrap(
        &(push(constants.testing.memory_size) ++ [_]u8{ opByte(.load_at), opByte(.halt) }),
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
    for (0..constants.testing.stack_size + 1) |_| {
        try program.appendSlice(std.testing.allocator, &push(0));
    }
    try expectTrap(program.items, error.StackOverflow, "");
}

// A program that fills the data stack to its capacity. The instructions that
// follow it therefore have no room for a result.
fn fullStack(program: *std.ArrayList(u8)) !void {
    for (0..constants.testing.stack_size) |_| {
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
        try std.testing.expectEqual(constants.testing.stack_size, harness.vm.sp);
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
    try std.testing.expectEqual(constants.testing.call_stack_size, harness.vm.csp);
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
    const past_end: u32 = constants.testing.memory_size;

    try expectTrap(
        &(withAddress(.load, past_end) ++ [_]u8{opByte(.halt)}),
        error.SegmentFault,
        "",
    );
    // Three bytes from the end is inside memory, but its four-byte access is not.
    try expectTrap(
        &(withAddress(.load, constants.testing.memory_size - 3) ++ [_]u8{opByte(.halt)}),
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
    try std.testing.expectEqual(constants.testing.memory_size, vm.frame_pointer);
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
    const last: i32 = constants.testing.memory_size - 1;

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
        &(push(constants.testing.memory_size) ++ [_]u8{ opByte(.load8_u), opByte(.halt) }),
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

// The sizes of a VM --------------------------------------------------------

/// A VM with the given sizes, and the streams it needs to exist. The caller calls
/// `deinit` and `destroy`.
fn vmWith(config: Config, input: *Io.Reader, output: *Io.Writer) !*VM {
    const vm = try std.testing.allocator.create(VM);
    errdefer std.testing.allocator.destroy(vm);
    try vm.init(std.testing.allocator, config, input, output);
    return vm;
}

test "the size of a VM does not depend on the size of its memory" {
    // The memory, the stacks and the verifier scratch come from an allocator, so what
    // is left inline is the import table and a handful of slices and registers. The
    // structure held all four inline before, which cost two bytes of host memory for
    // each byte of guest memory whatever the program held.
    const imports = @sizeOf([bytecode.foreign.max_imports]?foreign.Import);
    try std.testing.expect(@sizeOf(VM) < imports + 256);
}

test "a VM takes the sizes it is given" {
    var input: Io.Reader = .fixed("");
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();

    const vm = try vmWith(
        .{ .memory_size = 4096, .stack_size = 8, .call_stack_size = 4 },
        &input,
        &collected.writer,
    );
    defer std.testing.allocator.destroy(vm);
    defer vm.deinit();

    try std.testing.expectEqual(@as(usize, 4096), vm.memory.len);
    try std.testing.expectEqual(@as(usize, 8), vm.stack.len);
    try std.testing.expectEqual(@as(usize, 4), vm.call_stack.len);
    // Frame memory grows down from the end of whatever memory the VM was given.
    try std.testing.expectEqual(@as(usize, 4096), vm.frame_pointer);

    // The limits move with the sizes. This stack holds eight values, so the ninth
    // `push` has nowhere to go, where the default stack would take it.
    var program: std.ArrayList(u8) = .empty;
    defer program.deinit(std.testing.allocator);
    for (0..9) |_| try program.appendSlice(std.testing.allocator, &push(1));
    try program.append(std.testing.allocator, opByte(.halt));

    try vm.loadProgram(program.items);
    try std.testing.expectError(error.StackOverflow, vm.run());
    try std.testing.expectEqual(@as(usize, 8), vm.sp);
}

test "an address is bounded by the memory the VM was given and not by a constant" {
    var input: Io.Reader = .fixed("");
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();

    const vm = try vmWith(.{ .memory_size = 1024 }, &input, &collected.writer);
    defer std.testing.allocator.destroy(vm);
    defer vm.deinit();

    // The last byte is inside this memory and the one after it is not. A VM with more
    // memory would take both.
    try vm.loadProgram(&(push(1023) ++ [_]u8{ opByte(.load8_u), opByte(.halt) }));
    try vm.run();

    vm.reset();
    try vm.loadProgram(&(push(1024) ++ [_]u8{ opByte(.load8_u), opByte(.halt) }));
    try std.testing.expectError(error.SegmentFault, vm.run());
}

test "a config that no VM can honour is refused" {
    var input: Io.Reader = .fixed("");
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();

    const cases = [_]struct { config: Config, reason: anyerror }{
        // A VM with no memory holds no program, and one with no stack runs no
        // instruction that produces a value.
        .{ .config = .{ .memory_size = 0 }, .reason = error.ConfigTooSmall },
        .{ .config = .{ .stack_size = 0 }, .reason = error.ConfigTooSmall },
        .{ .config = .{ .call_stack_size = 0 }, .reason = error.ConfigTooSmall },
    };

    for (cases) |case| {
        try std.testing.expectError(
            case.reason,
            vmWith(case.config, &input, &collected.writer),
        );
    }
}

test "the verifier scratch grows to the code and not to the memory" {
    var input: Io.Reader = .fixed("");
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();

    // A megabyte of memory. The scratch used to be the same size as this whatever the
    // program held, which is the cost that this refactor removes.
    const vm = try vmWith(.{ .memory_size = 1 << 20 }, &input, &collected.writer);
    defer std.testing.allocator.destroy(vm);
    defer vm.deinit();

    try std.testing.expectEqual(@as(usize, 0), vm.verify_scratch.len);

    const small = try buildContainer(.{ .code = &[_]u8{opByte(.halt)} });
    defer std.testing.allocator.free(small);
    try vm.loadProgram(small);
    try std.testing.expectEqual(@as(usize, 1), vm.verify_scratch.len);

    // A larger program grows it, and the scratch is still a fraction of the memory.
    const larger = try buildContainer(.{ .code = &(push(1) ++ [_]u8{ opByte(.pop), opByte(.halt) }) });
    defer std.testing.allocator.free(larger);
    try vm.loadProgram(larger);
    try std.testing.expectEqual(@as(usize, 7), vm.verify_scratch.len);
    try std.testing.expect(vm.verify_scratch.len < vm.memory.len / 1000);
}

test "a mark from one program does not answer for the next" {
    // The scratch is kept between programs, so a mark that an earlier program left
    // could say that an address is the start of an instruction when the bytes there
    // are now something else. `call_indirect` reads these marks while a program runs.
    var input: Io.Reader = .fixed("");
    var collected: Io.Writer.Allocating = .init(std.testing.allocator);
    defer collected.deinit();

    const vm = try vmWith(constants.testing, &input, &collected.writer);
    defer std.testing.allocator.destroy(vm);
    defer vm.deinit();

    // The first program reaches offset 7 and marks it.
    const first = try buildContainer(.{
        .code = &(push(7) ++ [_]u8{ opByte(.call_indirect), opByte(.halt) } ++
            push(1) ++ [_]u8{ opByte(.pop), opByte(.ret) }),
    });
    defer std.testing.allocator.free(first);
    try vm.loadProgram(first);
    try vm.run();
    try std.testing.expectEqual(bytecode.verify.Mark.boundary, vm.verify_scratch[7]);

    // The second program is shorter and has no instruction at offset 7 at all. The
    // marks of the first must not survive into it.
    const second = try buildContainer(.{ .code = &[_]u8{opByte(.halt)} });
    defer std.testing.allocator.free(second);
    try vm.loadProgram(second);
    try std.testing.expectEqual(bytecode.verify.Mark.boundary, vm.verify_scratch[0]);
    for (vm.verify_scratch[1..]) |mark| {
        try std.testing.expectEqual(bytecode.verify.Mark.unknown, mark);
    }
}

test "a pointer argument may name any byte of memory and a string may not" {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    // A program with a one-byte image. Everything above `program_len` is memory that
    // a frame takes its storage from, and that is where a local lives.
    try vm.loadProgram(&[_]u8{opByte(.halt)});
    const above_image: i32 = @intCast(vm.program_len + 16);

    // A `ptr` argument reaches it. Passing the address of a local is most of what a
    // pointer argument is for, and a frame is the only place a local can be.
    _ = try vm.guestPointer(above_image, false);

    // A `cstr` argument does not. A string is read to its terminator, and memory
    // above the image is zeros, so every address in it would look like the end of a
    // string and an unterminated one would stop being an error.
    try std.testing.expectError(
        error.InvalidGuestPointer,
        vm.guestPointer(above_image, true),
    );

    // Neither kind reaches past the memory itself, and a negative address has no
    // unsigned equivalent.
    try std.testing.expectError(
        error.InvalidGuestPointer,
        vm.guestPointer(@intCast(vm.memory.len), false),
    );
    try std.testing.expectError(error.InvalidGuestPointer, vm.guestPointer(-1, false));

    // The last byte of memory is inside it.
    _ = try vm.guestPointer(@intCast(vm.memory.len - 1), false);

    // Zero is the null pointer for both kinds, and not an address at all.
    try std.testing.expectEqual(@as(usize, 0), try vm.guestPointer(0, false));
    try std.testing.expectEqual(@as(usize, 0), try vm.guestPointer(0, true));
}

test "a foreign function writes into a call frame through a pointer argument" {
    // The end-to-end form of the test above: a native function is given the address
    // of a local and writes to it. This is what a C program does with `&x`, and it
    // proves that the address a `ptr` argument becomes really is the frame.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var harness = Harness.init();
    defer harness.deinit();
    harness.start();
    const vm = harness.vm;

    // `GetSystemTime` fills a SYSTEMTIME: eight 16-bit fields, and the first is the
    // year. Four frame slots hold the sixteen bytes.
    var import: bytecode.foreign.Import = .{
        .library = "kernel32.dll",
        .symbol = "GetSystemTime",
    };
    try import.addArg(.ptr);

    const main_offset = 6;
    const code = withAddress(.call, main_offset) ++ [_]u8{opByte(.halt)} ++
        enterFrame(0, 4) ++
        withLocal(.local_addr, 0) ++
        [_]u8{ opByte(.foreign_call), 0, opByte(.pop) } ++
        withLocal(.local_addr, 0) ++
        [_]u8{ opByte(.load16_u), opByte(.print), opByte(.pop), opByte(.ret) };

    const program = try buildContainer(.{ .imports = &.{import}, .code = &code });
    defer std.testing.allocator.free(program);

    try vm.loadProgram(program);
    try vm.run();

    // The year that Windows wrote into the frame. Any year past 2000 says that the
    // native function reached the right bytes; a wrong address would give zero.
    const printed = std.mem.trimEnd(u8, harness.written(), "\n");
    const year = try std.fmt.parseInt(u32, printed, 10);
    try std.testing.expect(year > 2000);
}

test "an indirect jump reaches a label that no instruction names" {
    // The arm at offset 12 is reached only through the value on the stack, so the
    // walk at load time never sees it. It is verified when the jump goes there,
    // exactly as a function body is for an indirect call.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    // 0: push 12   5   the address of the arm
    // 5: jmp_indirect  1
    // 6: push 111  5   skipped: the jump does not fall through
    // 11: halt     1
    // 12: push 42  5   the arm
    // 17: halt     1
    const program = push(12) ++ [_]u8{opByte(.jmp_indirect)} ++
        push(111) ++ [_]u8{opByte(.halt)} ++
        push(42) ++ [_]u8{opByte(.halt)};

    try harness.vm.loadProgram(&program);
    try std.testing.expectEqual(bytecode.verify.Mark.unknown, harness.vm.verify_scratch[12]);

    try harness.vm.run();

    // The arm ran and the instruction after the jump did not.
    try std.testing.expectEqual(@as(usize, 1), harness.vm.sp);
    try std.testing.expectEqual(@as(i32, 42), harness.vm.stack[0]);
    try std.testing.expectEqual(bytecode.verify.Mark.boundary, harness.vm.verify_scratch[12]);
}

test "an indirect jump saves no return offset" {
    // This is the whole difference from `call_indirect`: there is no frame to come
    // back to, so the call stack is untouched and a `ret` afterwards has nothing to
    // return to.
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    const program = push(7) ++ [_]u8{ opByte(.jmp_indirect), opByte(.halt) } ++
        [_]u8{opByte(.ret)};

    try harness.vm.loadProgram(&program);
    try std.testing.expectError(error.CallStackUnderflow, harness.vm.run());
    try std.testing.expectEqual(@as(usize, 0), harness.vm.csp);
}

test "a jump table picks its arm from memory" {
    // What the instruction exists for: one load and one jump instead of a
    // comparison for each case. The table is three addresses in the data region,
    // and the index chooses which arm runs.
    for ([_]struct { index: i32, expected: i32 }{
        .{ .index = 0, .expected = 10 },
        .{ .index = 1, .expected = 20 },
        .{ .index = 2, .expected = 30 },
    }) |case| {
        var harness = Harness.init();
        defer harness.deinit();
        harness.start();

        // `index * 4 + table`, loaded and jumped to.  Every `push` is five bytes
        // whatever it pushes, so the prologue has a fixed length and the arms that
        // follow it have fixed addresses.
        const prologue_len = 5 + 5 + 1 + 5 + 1 + 1 + 1;
        const arm_len = 5 + 1; // push, halt
        const table = prologue_len + 3 * arm_len; // the data region starts here
        const arms = [_]u32{
            prologue_len,
            prologue_len + arm_len,
            prologue_len + 2 * arm_len,
        };
        const code = push(case.index) ++ push(4) ++ [_]u8{opByte(.mul)} ++
            push(table) ++ [_]u8{ opByte(.add), opByte(.load32), opByte(.jmp_indirect) };
        try std.testing.expectEqual(@as(usize, prologue_len), code.len);

        var program: std.ArrayList(u8) = .empty;
        defer program.deinit(std.testing.allocator);
        try program.appendSlice(std.testing.allocator, &code);
        // The three arms, each a push and a halt.
        for ([_]i32{ 10, 20, 30 }) |value| {
            try program.appendSlice(std.testing.allocator, &push(value));
            try program.append(std.testing.allocator, opByte(.halt));
        }

        var data: [12]u8 = undefined;
        for (arms, 0..) |arm, i| std.mem.writeInt(u32, data[i * 4 ..][0..4], arm, .little);

        const container_bytes = try buildContainer(.{
            .code = program.items,
            .data = &data,
        });
        defer std.testing.allocator.free(container_bytes);

        try harness.vm.loadProgram(container_bytes);
        try harness.vm.run();
        try std.testing.expectEqual(case.expected, harness.vm.stack[0]);
    }
}

test "an indirect jump refuses a target that is not an instruction" {
    // The same checks an indirect call gets: the address must be inside the code
    // region and must be a whole instruction there.
    try expectContainerTrap(
        &(push(1) ++ [_]u8{ opByte(.jmp_indirect), opByte(.halt) }),
        error.MisalignedTarget,
    );
    try expectContainerTrap(
        &(push(7) ++ [_]u8{ opByte(.jmp_indirect), opByte(.halt), 0xfe }),
        error.UnknownOpcode,
    );
    try expectTrap(
        &(push(-1) ++ [_]u8{ opByte(.jmp_indirect), opByte(.halt) }),
        error.SegmentFault,
        "",
    );
    try expectTrap(
        &(push(64) ++ [_]u8{ opByte(.jmp_indirect), opByte(.halt) }),
        error.SegmentFault,
        "",
    );
    // The target comes off the stack, so an empty stack has none to give.
    try expectTrap(&[_]u8{ opByte(.jmp_indirect), opByte(.halt) }, error.StackUnderflow, "");
}

// Floating point ---------------------------------------------------------------

/// Encode `push` of the bits of a float, which is how a program names one: the
/// assembler has no float literal and the compiler emits the bit pattern.
fn pushFloat(value: f32) [5]u8 {
    return push(@bitCast(value));
}

/// Run one instruction on two floats and give back what it left.
fn floatResult(code: bytecode.OpCode, a: f32, b: f32) !f32 {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    var program: [12]u8 = undefined;
    program[0..5].* = pushFloat(a);
    program[5..10].* = pushFloat(b);
    program[10] = opByte(code);
    program[11] = opByte(.halt);

    try harness.vm.loadProgram(&program);
    try harness.vm.run();
    try std.testing.expectEqual(@as(usize, 1), harness.vm.sp);
    return @bitCast(harness.vm.stack[0]);
}

/// The bits of a float, as a program names one.
fn fbits(value: f32) i32 {
    return @bitCast(value);
}

/// The same for an instruction that takes one operand. The operand is the raw
/// slot: some of these read it as a float and some as an integer.
fn floatUnary(code: bytecode.OpCode, slot: i32) !i32 {
    var harness = Harness.init();
    defer harness.deinit();
    harness.start();

    var program: [7]u8 = undefined;
    program[0..5].* = push(slot);
    program[5] = opByte(code);
    program[6] = opByte(.halt);

    try harness.vm.loadProgram(&program);
    try harness.vm.run();
    try std.testing.expectEqual(@as(usize, 1), harness.vm.sp);
    return harness.vm.stack[0];
}

test "the floating-point arithmetic is the arithmetic of binary32" {
    const expect = std.testing.expectEqual;

    try expect(@as(f32, 3.5), try floatResult(.fadd, 1.25, 2.25));
    try expect(@as(f32, -1.0), try floatResult(.fsub, 1.25, 2.25));
    try expect(@as(f32, 2.8125), try floatResult(.fmul, 1.25, 2.25));
    try expect(@as(f32, 2.5), try floatResult(.fdiv, 5.0, 2.0));

    // A slot is 32 bits, so the arithmetic is 32 bits: adding one to sixteen
    // million and a bit changes nothing, where a double would keep it.
    try expect(@as(f32, 16777216.0), try floatResult(.fadd, 16777216.0, 1.0));

    try expect(@as(i32, @bitCast(@as(f32, -2.5))), try floatUnary(.fneg, fbits(2.5)));
    try expect(@as(i32, @bitCast(@as(f32, 3.0))), try floatUnary(.fsqrt, fbits(9.0)));

    // Negating a zero gives the other zero, which is a different bit pattern and
    // still compares equal to it.
    try expect(@as(i32, @bitCast(@as(f32, -0.0))), try floatUnary(.fneg, fbits(0.0)));
}

test "floating-point arithmetic answers where integer arithmetic traps" {
    // `div` traps on a zero divisor and `add` traps on overflow. IEEE-754 has an
    // answer for both, so these do not trap: that is the one place where the
    // floating-point instructions part company with the integer ones.
    const inf = std.math.inf(f32);

    try std.testing.expectEqual(inf, try floatResult(.fdiv, 1.0, 0.0));
    try std.testing.expectEqual(-inf, try floatResult(.fdiv, -1.0, 0.0));
    try std.testing.expect(std.math.isNan(try floatResult(.fdiv, 0.0, 0.0)));

    // An overflow gives an infinity rather than the trap that `mul` would.
    try std.testing.expectEqual(inf, try floatResult(.fmul, 3.0e38, 3.0e38));
    // And an underflow gives a zero.
    try std.testing.expectEqual(@as(f32, 0.0), try floatResult(.fmul, 1.0e-30, 1.0e-30));

    // The square root of a negative number is a NaN, not a fault.
    try std.testing.expect(std.math.isNan(@as(f32, @bitCast(try floatUnary(.fsqrt, fbits(-1.0))))));
}

test "a NaN compares false against everything, itself included" {
    const nan = std.math.nan(f32);

    for ([_]bytecode.OpCode{ .feq, .flt, .fle, .fgt, .fge }) |code| {
        try std.testing.expectEqual(@as(f32, 0.0), try floatResult(code, nan, nan));
        try std.testing.expectEqual(@as(f32, 0.0), try floatResult(code, nan, 1.0));
        try std.testing.expectEqual(@as(f32, 0.0), try floatResult(code, 1.0, nan));
    }
    // `fne` is the one that is true for a NaN, which is what C requires of `!=`.
    try std.testing.expectEqual(@as(i32, 1), @as(i32, @bitCast(try floatResult(.fne, nan, nan))));
}

test "the floating-point comparisons leave the integers a branch reads" {
    // Each pushes 1 or 0, exactly as `lt` and the rest do, so `jmp_not_zero`
    // reads the answer without knowing which kind of comparison made it.
    const cases = [_]struct { code: bytecode.OpCode, a: f32, b: f32, want: i32 }{
        .{ .code = .feq, .a = 1.5, .b = 1.5, .want = 1 },
        .{ .code = .feq, .a = 1.5, .b = 2.5, .want = 0 },
        .{ .code = .fne, .a = 1.5, .b = 2.5, .want = 1 },
        .{ .code = .flt, .a = 1.5, .b = 2.5, .want = 1 },
        .{ .code = .flt, .a = 2.5, .b = 1.5, .want = 0 },
        .{ .code = .fle, .a = 1.5, .b = 1.5, .want = 1 },
        .{ .code = .fgt, .a = 2.5, .b = 1.5, .want = 1 },
        .{ .code = .fge, .a = 1.5, .b = 1.5, .want = 1 },
        // A negative zero equals a positive one, though their bits differ.
        .{ .code = .feq, .a = 0.0, .b = -0.0, .want = 1 },
    };

    for (cases) |case| {
        const bits: i32 = @bitCast(try floatResult(case.code, case.a, case.b));
        try std.testing.expectEqual(case.want, bits);
    }
}

test "converting to an integer truncates toward zero" {
    const expect = std.testing.expectEqual;

    try expect(@as(i32, 2), try floatUnary(.f2i, fbits(2.9)));
    try expect(@as(i32, -2), try floatUnary(.f2i, fbits(-2.9)));
    try expect(@as(i32, 0), try floatUnary(.f2i, fbits(0.9)));
    try expect(@as(i32, 0), try floatUnary(.f2i, fbits(-0.9)));

    // The ends of the range are reachable, as far as the format reaches them.
    // 2147483520 is the largest binary32 below two to the thirty-first, and it
    // converts to itself; the largest `i32` has no float form at all, because 24
    // bits of significand cannot name it.
    try expect(@as(i32, 2147483520), try floatUnary(.f2i, fbits(2147483520.0)));
    try expect(@as(i32, std.math.minInt(i32)), try floatUnary(.f2i, fbits(-2147483648.0)));

    // Unsigned takes the whole positive range, and a value between minus one and
    // zero truncates to a zero it can hold.
    try expect(@as(i32, @bitCast(@as(u32, 4000000000))), try floatUnary(.f2u, fbits(4.0e9)));
    try expect(@as(i32, 0), try floatUnary(.f2u, fbits(-0.5)));
}

test "a float that no integer can hold is refused rather than guessed at" {
    // C leaves this undefined. The rest of the VM reports a result it cannot
    // represent instead of inventing one, and so does this.
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    for ([_]f32{ 2147483648.0, -2147483904.0, 1.0e30, nan, inf, -inf }) |value| {
        var program: [7]u8 = undefined;
        program[0..5].* = pushFloat(value);
        program[5] = opByte(.f2i);
        program[6] = opByte(.halt);
        try expectTrap(&program, error.InvalidFloatConversion, "");
    }

    // Unsigned refuses a negative that truncates below zero, and the same ends.
    for ([_]f32{ -1.0, 4294967296.0, nan, inf }) |value| {
        var program: [7]u8 = undefined;
        program[0..5].* = pushFloat(value);
        program[5] = opByte(.f2u);
        program[6] = opByte(.halt);
        try expectTrap(&program, error.InvalidFloatConversion, "");
    }
}

test "converting from an integer rounds to the nearest float" {
    const expect = std.testing.expectEqual;

    try expect(@as(i32, @bitCast(@as(f32, 42.0))), try floatUnary(.i2f, 42));
    try expect(@as(i32, @bitCast(@as(f32, -42.0))), try floatUnary(.i2f, -42));

    // Twenty-four bits of significand cannot keep every integer, so a large one
    // rounds. This is a property of the format and not a fault.
    try expect(@as(i32, @bitCast(@as(f32, 16777216.0))), try floatUnary(.i2f, 16777217));

    // The same bits read as unsigned are a different number.
    try expect(@as(i32, @bitCast(@as(f32, -1.0))), try floatUnary(.i2f, -1));
    try expect(@as(i32, @bitCast(@as(f32, 4294967296.0))), try floatUnary(.u2f, -1));
}

test "a float instruction with too little on the stack is refused" {
    for ([_]bytecode.OpCode{ .fadd, .fsub, .fmul, .fdiv, .feq, .flt }) |code| {
        try expectTrap(&[_]u8{ opByte(code), opByte(.halt) }, error.StackUnderflow, "");
    }
    for ([_]bytecode.OpCode{ .fneg, .fsqrt, .f2i, .f2u, .i2f, .u2f }) |code| {
        try expectTrap(&[_]u8{ opByte(code), opByte(.halt) }, error.StackUnderflow, "");
    }
}
