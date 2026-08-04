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

// Byte-addressed memory -----------------------------------------------------

test "reserve gives a label storage that a byte store can write" {
    // The whole point of the directive: the program names its storage and never
    // counts a byte of its own code. If the assembler placed `counter` at the wrong
    // address, or the VM read the address differently, the value would not come
    // back.
    try expectSourceOutput(
        \\  push 1000
        \\  push counter
        \\  store32
        \\  push counter
        \\  load32
        \\  print
        \\  halt
        \\counter:
        \\  reserve 4
    ,
        "1000\n",
    );
}

test "a byte address from a label reaches the same place as print_string" {
    // This is the property the byte-addressed instructions exist for. One number is
    // the address of the string for `print_string` and the address of its first
    // byte for `load8_u`. The two agree, which `load_at` and a data label never did.
    try expectSourceOutput(
        \\  push greeting
        \\  print_string
        \\  load8_u
        \\  print
        \\  halt
        \\greeting:
        \\  asciiz "hi"
    ,
        // "hi", then 104, which is 'h'.
        "hi\n104\n",
    );
}

test "a narrow load from source keeps or drops the sign" {
    try expectSourceOutput(
        \\  push 255
        \\  push cell
        \\  store8
        \\  push cell
        \\  load8_u
        \\  print
        \\  pop
        \\  push cell
        \\  load8_s
        \\  print
        \\  halt
        \\cell:
        \\  reserve 1
    ,
        "255\n-1\n",
    );
}

test "a byte string is built in memory and written out one byte at a time" {
    // A program writes into reserved space and reads it back. This is what the new
    // instructions make possible: a value that the program computed, in memory that
    // it chose, at an address it worked out while running.
    try expectSourceOutput(
        \\  # buffer[0] = 'O', buffer[1] = 'K'
        \\  push 79
        \\  push buffer
        \\  store8
        \\  push 75
        \\  push buffer
        \\  push 1
        \\  add
        \\  store8
        \\
        \\  # Write the two bytes back out through a calculated address.
        \\  push buffer
        \\  load8_u
        \\  write_byte
        \\  push buffer
        \\  push 1
        \\  add
        \\  load8_u
        \\  write_byte
        \\  push 10
        \\  write_byte
        \\  halt
        \\buffer:
        \\  reserve 2
    ,
        "OK\n",
    );
}

test "an array of 32-bit values is summed through calculated byte addresses" {
    // The byte-addressed form of the data-segment loop. The stride is four bytes
    // rather than one slot, which is what a C compiler emits for `int[]`.
    try expectSourceOutput(
        \\entry main
        \\main:
        \\  # numbers[i] = (i + 1) * 10, for i in 0..3
        \\  push 10
        \\  push numbers
        \\  store32
        \\  push 20
        \\  push numbers
        \\  push 4
        \\  add
        \\  store32
        \\  push 30
        \\  push numbers
        \\  push 8
        \\  add
        \\  store32
        \\
        \\  # total = 0, cursor = numbers
        \\  push 0
        \\  store 0
        \\  push numbers
        \\  store 1
        \\loop:
        \\  load 0
        \\  load 1
        \\  load32
        \\  add
        \\  store 0
        \\  load 1
        \\  push 4
        \\  add
        \\  store 1
        \\  load 1
        \\  push numbers
        \\  push 12
        \\  add
        \\  ne
        \\  jmp_not_zero loop
        \\  load 0
        \\  print
        \\  halt
        \\numbers:
        \\  reserve 12
    ,
        "60\n",
    );
}

test "a store into the code region is refused" {
    // Address 0 is the first byte of the code. A program that could write there
    // would make the work of the verifier meaningless, because the bytes it checked
    // are not the bytes that would run.
    try expectSourceTrap(
        \\  push 255
        \\  push 0
        \\  store8
        \\  halt
    ,
        error.WriteToCodeRegion,
        "",
    );
}

test "a read of the code region is allowed" {
    // Only writing is restricted. Offset 0 holds the opcode byte of `push`, which
    // is 1.
    try expectSourceOutput(
        \\  push 0
        \\  load8_u
        \\  print
        \\  halt
    ,
        "1\n",
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
