const bytecode = @import("vig_bytecode");
const constants = @import("constants.zig");
const machine = @import("machine.zig");
const std = @import("std");

const Io = std.Io;

pub fn loadProgramFromFile(vm: *machine.VM, io: Io, allocator: std.mem.Allocator, path: []const u8) !void {
    // The container header and import table are stripped before code enters VM
    // memory. Allow the largest valid container plus a full memory image, and
    // read one extra byte so an oversized file remains distinguishable from an
    // exact fit.
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

    // A memory-sized code region of `halt` instructions.
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

    var vm = machine.VM.init(undefined);
    defer vm.deinit();
    try loadProgramFromFile(&vm, std.testing.io, std.testing.allocator, path);
    try std.testing.expectEqual(constants.memory_size, vm.program_len);
    try std.testing.expectEqual(constants.memory_size, vm.code_len);
}

// compare two integers and push the result onto the stack
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
// A collection of comparison functions for the VM
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

// Read a 32-bit unsigned integer operand from the code region at the current
// instruction pointer. Operands have to lie inside the code, not merely inside
// the loaded image: static data is not executable.
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
