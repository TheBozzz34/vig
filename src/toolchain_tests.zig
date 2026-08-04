//! Tests that use the assembler and the VM together.
//!
//! Each test in `machine.zig` writes its program as instruction bytes, and each
//! test in the assembler stops at the bytes of the container. Neither kind of
//! test can see a disagreement between the two tools: what the assembler writes
//! for a line of source, and what the VM then does with those bytes. The address
//! of a label, the operand of `store` and the value that `store_at` takes from
//! the stack must all mean the same thing in the assembler and in the VM.
//!
//! Therefore each test here starts at source text. It assembles that text, loads
//! the container into the VM, runs it and compares what the program printed. A
//! change that moves an address in one tool only makes a test here fail.

const std = @import("std");
const assembler = @import("vig_assembler");
const constants = @import("constants.zig");
const machine = @import("machine.zig");

const Io = std.Io;

// A VM and the buffer that collects the output of its program. The VM is behind a
// pointer, because it holds the guest memory inline and must not travel through
// the return value of `init`.
const Harness = struct {
    input: Io.Reader,
    collected: Io.Writer.Allocating,
    vm: *machine.VM,

    fn init(input: []const u8) Harness {
        const vm = std.testing.allocator.create(machine.VM) catch @panic("OOM");
        // `start` sets the stream pointers after the harness has its final
        // address. A pointer taken here becomes invalid when this function gives a
        // copy of the harness to the caller.
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
};

/// Assemble `source`, run the program and compare its output with `expected`.
fn expectSourceOutput(source: []const u8, expected: []const u8) !void {
    try expectSourceOutputWithInput(source, "", expected);
}

fn expectSourceOutputWithInput(source: []const u8, input: []const u8, expected: []const u8) !void {
    const program = try assembler.assemble(std.testing.allocator, source, null);
    defer std.testing.allocator.free(program);

    var harness = Harness.init(input);
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(program);
    try harness.vm.run();
    try std.testing.expectEqualStrings(expected, harness.collected.written());
}

/// The same as `expectSourceOutput`, but the program must trap. The output from
/// before the trap must survive it.
fn expectSourceTrap(source: []const u8, expected_error: anyerror, expected_output: []const u8) !void {
    const program = try assembler.assemble(std.testing.allocator, source, null);
    defer std.testing.allocator.free(program);

    var harness = Harness.init("");
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(program);
    try std.testing.expectError(expected_error, harness.vm.run());
    try std.testing.expectEqualStrings(expected_output, harness.collected.written());
}

// Tests ----------------------------------------------------------------------

test "a program from source assembles, verifies and runs" {
    try expectSourceOutput(
        \\  push 7
        \\  push 5
        \\  add
        \\  print
        \\  halt
    ,
        "12\n",
    );
}

test "the data-segment operand and the stack address name the same cell" {
    // This is the invariant that lets a program calculate an address. `store 4`
    // and `push 4` with `store_at` must reach one cell, and not two. A change to
    // one of the two forms without the other makes this test fail.
    try expectSourceOutput(
        \\  push 99
        \\  store 4         # the operand form writes the cell
        \\  push 4
        \\  load_at         # the stack form reads the same cell
        \\  print
        \\  push 123
        \\  push 4
        \\  store_at        # the stack form writes it
        \\  load 4          # the operand form reads it back
        \\  print
        \\  halt
    ,
        "99\n123\n",
    );
}

test "a data label is a byte offset into the image, not a data-segment index" {
    // One number, two meanings. `print_string` reads it as a byte offset into the
    // program image and finds the string. `load_at` reads it as an index into the
    // i32 data segment and finds an unrelated cell, which is zero.
    //
    // This test records the two address spaces that the VM has today. The move to
    // one byte-addressed guest memory is what removes the difference. Therefore
    // this test is expected to fail at that point, and its failure is the signal
    // to update it rather than a regression.
    try expectSourceOutput(
        \\  push greeting
        \\  print_string
        \\  load_at
        \\  print
        \\  halt
        \\greeting:
        \\  asciiz "hi"
    ,
        "hi\n0\n",
    );
}

test "several strings keep their addresses through the assembler and the VM" {
    // The assembler puts each string in the data region in its declaration order,
    // and the VM maps that region directly after the code. Therefore the address
    // that the assembler writes for `second` must be the address at which the VM
    // finds "bc".
    try expectSourceOutput(
        \\  push first
        \\  print_string
        \\  pop
        \\  push second
        \\  print_string
        \\  pop
        \\  halt
        \\first:
        \\  asciiz "a"
        \\second:
        \\  asciiz "bc"
    ,
        "a\nbc\n",
    );
}

test "a call and a return move through a subroutine written as source" {
    try expectSourceOutput(
        \\entry main
        \\double:
        \\  push 2
        \\  mul
        \\  ret
        \\main:
        \\  push 21
        \\  call double
        \\  print
        \\  halt
    ,
        "42\n",
    );
}

test "the entry directive skips a prologue that never runs" {
    // The `push 111` before the entry point must not run. Therefore the output is
    // the value from `main` on its own.
    try expectSourceOutput(
        \\entry main
        \\unused:
        \\  push 111
        \\  print
        \\  halt
        \\main:
        \\  push 222
        \\  print
        \\  halt
    ,
        "222\n",
    );
}

test "a loop walks an array through calculated data addresses" {
    // The source-level form of the indirect-addressing test in `machine.zig`.
    // total is at 100 and the index is at 101.
    try expectSourceOutput(
        \\  push 10
        \\  store 0
        \\  push 20
        \\  store 1
        \\  push 30
        \\  store 2
        \\  push 0
        \\  store 100
        \\  push 0
        \\  store 101
        \\loop:
        \\  load 100
        \\  load 101
        \\  load_at
        \\  add
        \\  store 100
        \\  load 101
        \\  push 1
        \\  add
        \\  store 101
        \\  load 101
        \\  push 3
        \\  ne
        \\  jmp_not_zero loop
        \\  load 100
        \\  print
        \\  halt
    ,
        "60\n",
    );
}

test "a backward jump makes a countdown loop" {
    try expectSourceOutput(
        \\  push 3
        \\  store 0
        \\loop:
        \\  load 0
        \\  print
        \\  pop
        \\  load 0
        \\  push 1
        \\  sub
        \\  store 0
        \\  load 0
        \\  jmp_not_zero loop
        \\  halt
    ,
        "3\n2\n1\n",
    );
}

test "runtime input reaches a program that came from source" {
    try expectSourceOutputWithInput(
        \\  read_i32
        \\  read_i32
        \\  add
        \\  print
        \\  halt
    ,
        "17 25",
        "42\n",
    );
}

test "a trap in an assembled program keeps the output printed before it" {
    try expectSourceTrap(
        \\  push 1
        \\  print
        \\  pop
        \\  push 1
        \\  push 0
        \\  div
        \\  print
        \\  halt
    ,
        error.DivisionByZero,
        "1\n",
    );
}

test "the assembler rejects a program before the VM can run it" {
    // Control continues past the end of the code region. The assembler runs the
    // same verifier as the VM. Therefore this program never becomes a file.
    try std.testing.expectError(
        error.ExecutionRunsOffEnd,
        assembler.assemble(std.testing.allocator, "push 1", null),
    );
}

test "the assembler and the VM agree on the bound of the data segment" {
    // The assembler runs the verifier without a segment size, so it accepts this
    // operand. The VM knows the size, so its own verification refuses the program
    // at load time. This test fails if the two stop agreeing on which addresses
    // exist, which is what changes when the data segment becomes byte-addressed.
    const source = std.fmt.comptimePrint("store {d}\nhalt", .{constants.data_size});
    const program = try assembler.assemble(std.testing.allocator, source, null);
    defer std.testing.allocator.free(program);

    var harness = Harness.init("");
    defer harness.deinit();
    harness.start();

    try std.testing.expectError(error.DataAddressOutOfRange, harness.vm.loadProgram(program));

    // The highest address that does exist assembles and loads.
    const last = std.fmt.comptimePrint("push 5\nstore {d}\nhalt", .{constants.data_size - 1});
    try expectSourceOutput(last, "");
}
