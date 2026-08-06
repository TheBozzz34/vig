//! Tests that use the assembler and the VM together.
//!
//! Each test in `machine.zig` writes its program as instruction bytes, and each
//! test in the assembler stops at the bytes of the container.

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

test "the operand form and the stack address name the same bytes" {
    // This is the invariant that lets a program calculate an address. `store cell`
    // and `push cell` with `store_at` must reach one place, and not two. A change to
    // one of the two forms without the other makes this test fail.
    try expectSourceOutput(
        \\  push 99
        \\  store cell      # the operand form writes it
        \\  push cell
        \\  load_at         # the stack form reads the same bytes
        \\  print
        \\  push 123
        \\  push cell
        \\  store_at        # the stack form writes it
        \\  load cell       # the operand form reads it back
        \\  print
        \\  halt
        \\cell:
        \\  reserve 4
    ,
        "99\n123\n",
    );
}

test "the address of a global is a usable pointer" {
    // This test once recorded the opposite. A data label was a byte offset into the
    // image, and the operand of `load` was an index into a separate segment of i32
    // slots, so one number named two places.
    //
    // Now `store counter` and a byte-addressed read of `push counter` reach the same
    // four bytes. Therefore the address of a global is an ordinary value that a
    // program can compute with, and that is what a pointer is.
    try expectSourceOutput(
        \\  push 12345
        \\  store counter   # write the global by name
        \\  push counter    # take its address
        \\  load32          # read it through that address
        \\  print
        \\  halt
        \\counter:
        \\  reserve 4
    ,
        "12345\n",
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

test "a backward jump makes a countdown loop" {
    try expectSourceOutput(
        \\  push 3
        \\  store counter
        \\loop:
        \\  load counter
        \\  print
        \\  pop
        \\  load counter
        \\  push 1
        \\  sub
        \\  store counter
        \\  load counter
        \\  jmp_not_zero loop
        \\  halt
        \\counter:
        \\  reserve 4
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
        \\  store total
        \\  push numbers
        \\  store cursor
        \\loop:
        \\  load total
        \\  load cursor
        \\  load32
        \\  add
        \\  store total
        \\  load cursor
        \\  push 4
        \\  add
        \\  store cursor
        \\  load cursor
        \\  push numbers+12
        \\  ne
        \\  jmp_not_zero loop
        \\  load total
        \\  print
        \\  halt
        \\numbers:
        \\  reserve 12
        \\total:
        \\  reserve 4
        \\cursor:
        \\  reserve 4
    ,
        "60\n",
    );
}

test "a table of initialized values is summed where the assembler put it" {
    // The same loop as the test above, over a table that the source wrote out rather
    // than one the program filled in. This is what a C compiler emits for
    // `static int table[] = {10, 20, 30};`, and it is the whole path: the assembler
    // writes the bytes, the container carries them, and the VM maps them at the
    // address that the label resolved to.
    try expectSourceOutput(
        \\entry main
        \\main:
        \\  push 0
        \\  store total
        \\  push table
        \\  store cursor
        \\loop:
        \\  load total
        \\  load cursor
        \\  load32
        \\  add
        \\  store total
        \\  load cursor
        \\  push 4
        \\  add
        \\  store cursor
        \\  load cursor
        \\  push table+12
        \\  ne
        \\  jmp_not_zero loop
        \\  load total
        \\  print
        \\  halt
        \\table:
        \\  i32 10, 20, 30
        \\total:
        \\  reserve 4
        \\cursor:
        \\  reserve 4
    ,
        "60\n",
    );
}

test "a pointer in the data region reaches the string it names" {
    // `char *greeting = message;` is one value that holds an address. The program
    // reads the pointer and then the string, so both the value and what it points at
    // have to land where the assembler said they would.
    try expectSourceOutput(
        \\entry main
        \\main:
        \\  push greeting
        \\  load32
        \\  print_string
        \\  halt
        \\message:
        \\  asciiz "hi"
        \\greeting:
        \\  i32 message
    ,
        "hi\n",
    );
}

test "a narrow value keeps its bits and the load decides its sign" {
    // `i8 -1` writes one byte. What that byte means is the business of the
    // instruction that reads it, which is the difference between `signed char` and
    // `unsigned char`.
    try expectSourceOutput(
        \\entry main
        \\main:
        \\  push small
        \\  load8_s
        \\  print
        \\  pop
        \\  push small
        \\  load8_u
        \\  print
        \\  pop
        \\  push wide
        \\  load16_s
        \\  print
        \\  halt
        \\small:
        \\  i8 -1
        \\wide:
        \\  i16 -2
    ,
        "-1\n255\n-2\n",
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

// Call frames ---------------------------------------------------------------

test "a function reads its arguments from its frame" {
    try expectSourceOutput(
        \\entry start
        \\start:
        \\  push 6
        \\  call square
        \\  print
        \\  halt
        \\square:
        \\  enter 1 0
        \\  load_local 0
        \\  load_local 0
        \\  mul
        \\  ret_val
    ,
        "36\n",
    );
}

test "a local starts at zero and keeps a value across a call" {
    // This is what a global cannot do. The inner call has its own frame, so it cannot
    // reach the local of the outer one.
    try expectSourceOutput(
        \\entry start
        \\start:
        \\  call outer
        \\  print
        \\  halt
        \\outer:
        \\  enter 0 1
        \\  load_local 0      # a local starts at zero
        \\  print
        \\  pop
        \\  push 100
        \\  store_local 0
        \\  call inner        # inner has its own frame
        \\  pop
        \\  load_local 0      # still 100
        \\  ret_val
        \\inner:
        \\  enter 0 1
        \\  push 999
        \\  store_local 0     # writes inner's local, not outer's
        \\  push 0
        \\  ret_val
    ,
        "0\n100\n",
    );
}

test "recursion works with a local rather than a saved operand" {
    // `factorial.vigas` is recursive today, but only because it keeps n on the operand
    // stack across the recursive call. A frame makes the value belong to the call, and
    // that is what C needs.
    try expectSourceOutput(
        \\entry start
        \\start:
        \\  push 10
        \\  call fact
        \\  print
        \\  halt
        \\fact:
        \\  enter 1 0
        \\  load_local 0
        \\  push 2
        \\  lt
        \\  jmp_not_zero fact_base
        \\  load_local 0
        \\  load_local 0
        \\  push 1
        \\  sub
        \\  call fact
        \\  mul
        \\  ret_val
        \\fact_base:
        \\  push 1
        \\  ret_val
    ,
        "3628800\n",
    );
}

test "the address of a local is an ordinary pointer" {
    // A frame is in guest memory. Therefore a local has an address, and the byte
    // instructions reach it in the same way as they reach a global.
    try expectSourceOutput(
        \\entry start
        \\start:
        \\  call body
        \\  halt
        \\body:
        \\  enter 0 2
        \\  push 1000
        \\  store_local 0
        \\  # Read the local through its address.
        \\  local_addr 0
        \\  load32
        \\  print
        \\  pop
        \\  # Write the second local through its address, then read it as a slot.
        \\  push 55
        \\  local_addr 1
        \\  store32
        \\  load_local 1
        \\  print
        \\  pop
        \\  # A local is four bytes, so the second one is four bytes after the first.
        \\  local_addr 1
        \\  local_addr 0
        \\  sub
        \\  print
        \\  ret
    ,
        "1000\n55\n4\n",
    );
}

test "a function with no frame keeps the older calling convention" {
    // `check` takes two values off the operand stack and declares no frame. A `ret`
    // that returned the stack to its height before the call would put those two values
    // back. Therefore a function with no frame is left alone.
    try expectSourceOutput(
        \\entry start
        \\start:
        \\  push 7
        \\  push 7
        \\  call check
        \\  push 3
        \\  push 4
        \\  call check
        \\  halt
        \\check:
        \\  eq
        \\  print
        \\  pop
        \\  ret
    ,
        "1\n0\n",
    );
}

test "a recursion with no end runs out of frame memory" {
    try expectSourceTrap(
        \\entry start
        \\start:
        \\  call forever
        \\  halt
        \\forever:
        \\  enter 0 8
        \\  call forever
        \\  ret
    ,
        error.CallStackOverflow,
        "",
    );
}

test "enter outside a call is refused" {
    // The entry point is not called, so it has no frame to enter. A function with
    // locals is reached with `call`, and the entry point is a stub that calls it.
    try expectSourceTrap(
        \\  enter 0 1
        \\  halt
    ,
        error.EnterOutsideCall,
        "",
    );
}

test "the assembler and the VM divide the address checks between them" {
    // The assembler does not know the size of the memory of the VM that will run the
    // program, so it accepts this operand. The VM knows that size, so its own
    // verification refuses the program when it loads it. This test fails if the two
    // stop agreeing about which addresses exist.
    const source = std.fmt.comptimePrint("store {d}\nhalt", .{constants.memory_size});
    const program = try assembler.assemble(std.testing.allocator, source, null);
    defer std.testing.allocator.free(program);

    var harness = Harness.init("");
    defer harness.deinit();
    harness.start();

    try std.testing.expectError(error.DataAddressOutOfRange, harness.vm.loadProgram(program));

    // The assembler does know the length of the code, so it refuses a store that
    // would write an instruction without asking the VM.
    try std.testing.expectError(
        error.StoreIntoCodeRegion,
        assembler.assemble(std.testing.allocator, "push 5\nstore 0\nhalt", null),
    );

    // The highest address that a four-byte store can use does assemble and load.
    const last = std.fmt.comptimePrint("push 5\nstore {d}\nhalt", .{constants.memory_size - 4});
    try expectSourceOutput(last, "");
}
