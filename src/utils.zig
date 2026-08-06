const bytecode = @import("vig_bytecode");
const constants = @import("constants.zig");
const machine = @import("machine.zig");
const std = @import("std");

const Io = std.Io;

/// The largest program file that a tool here reads. A container holds the header and
/// the import table as well as the image, so the file can be larger than the memory
/// of the VM.
pub const max_program_file_size = constants.max_program_file_size;

pub fn loadProgramFromFile(vm: *machine.VM, io: Io, allocator: std.mem.Allocator, path: []const u8) !void {
    // The VM removes the container header and the import table before the code
    // goes into VM memory. Permit the largest correct container and a full memory
    // image. Read one more byte. Then a file that is too large is different from
    // a file of the exact size.
    const program = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(constants.max_program_file_size + 1),
    );
    defer allocator.free(program);

    try vm.loadProgram(program);
}

test "file loader permits a full memory image behind a container header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A code region of `halt` instructions with the size of the VM memory.
    const code: [constants.memory_size]u8 = @splat(@intFromEnum(bytecode.OpCode.halt));
    const layout: bytecode.container.Layout = .{ .code = &code };

    const program = try std.testing.allocator.alloc(
        u8,
        try bytecode.container.encodedSize(layout),
    );
    defer std.testing.allocator.free(program);
    _ = try bytecode.container.write(layout, program);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "full-size.vig",
        .data = program,
    });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/full-size.vig",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    // The VM is too large for the stack of a test function, so it goes on the heap.
    const vm = try std.testing.allocator.create(machine.VM);
    defer std.testing.allocator.destroy(vm);
    vm.init(undefined, undefined);
    defer vm.deinit();
    try loadProgramFromFile(vm, std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqual(constants.memory_size, vm.program_len);
    try std.testing.expectEqual(constants.memory_size, vm.code_len);
}

// Compare two integers. Put the result on the stack.
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
// The comparison functions for the VM.
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

    // The unsigned forms. The stack holds an i32 and the bits are the same either
    // way, so these read the same two values as a different type. That is the whole
    // difference between `int` and `unsigned int` at a comparison, and it is why
    // `eq` and `ne` need no unsigned form: equal bits are equal bits.
    pub fn lt_u(a: i32, b: i32) bool {
        return unsigned(a) < unsigned(b);
    }

    pub fn lte_u(a: i32, b: i32) bool {
        return unsigned(a) <= unsigned(b);
    }

    pub fn gt_u(a: i32, b: i32) bool {
        return unsigned(a) > unsigned(b);
    }

    pub fn gte_u(a: i32, b: i32) bool {
        return unsigned(a) >= unsigned(b);
    }

    fn unsigned(value: i32) u32 {
        return @bitCast(value);
    }
};

// Read an unsigned 32-bit operand from the code region at the instruction
// pointer. An operand must be inside the code region.
pub fn readU32(self: *machine.VM) !u32 {
    if (self.ip > self.code_len or self.code_len - self.ip < 4) {
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

// Read an unsigned 16-bit operand. The frame instructions index a slot, and a frame
// never has enough slots to need a wider operand.
pub fn readU16(self: *machine.VM) !u16 {
    if (self.ip > self.code_len or self.code_len - self.ip < 2) {
        return error.SegmentFault;
    }

    const value = std.mem.readInt(u16, self.memory[self.ip..][0..2], .little);
    self.ip += 2;
    return value;
}

// Read the operand of `enter`: the arguments of a function and then its locals.
pub fn readFrameShape(self: *machine.VM) !bytecode.encode.FrameShape {
    const arguments = try readU16(self);
    const locals = try readU16(self);
    return .{ .arguments = arguments, .locals = locals };
}
