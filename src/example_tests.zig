//! The example programs, as regression tests.
//!
//! `vig-assembler/examples` holds real VIG programs: an MD5 implementation, a
//! bubble sort, an opcode test suite. Together they cover far more of the
//! instruction set than any hand-written test, and they cover it the way a
//! program uses it rather than one instruction at a time. Nothing ran them
//! before, so a change could break every one of them and the suite stayed green.
//!
//! Each test here assembles one example from source, runs it, and compares the
//! output with the text in the matching `.expected` file. The `.expected` files
//! are the contract: a change to the VM, to the assembler or to the container
//! format that moves any output at all makes a test fail and names the program.
//!
//! This corpus is what the move to byte-addressed guest memory has to be measured
//! against. `md5.vigas` in particular puts a table at a fixed data address, walks
//! it with `load_at`, and mixes that with every bitwise and rotate instruction.
//! A program of that shape is what breaks first when the meaning of an address
//! changes.

const std = @import("std");
const assembler = @import("vig_assembler");
const machine = @import("machine.zig");
const options = @import("example_options");

const Io = std.Io;

/// One example program and what it does when it runs.
const Example = struct {
    /// The base name, without the `.vigas` or `.expected` suffix.
    name: []const u8,
    /// The bytes on stdin. Most examples read nothing.
    input: []const u8 = "",
    /// The error that the program ends with, if it does not run to `halt`. The
    /// output before the trap must still match the `.expected` file.
    trap: ?anyerror = null,
};

/// The examples that a test can run anywhere and that give the same output every
/// time.
///
/// `beep`, `message_box`, `foreign_calls_positive` and `get_process_id` are not
/// here. Each one calls into a Windows library: two of them have an effect
/// outside the process, and a process id is different on each run. A test cannot
/// check any of the four.
const examples = [_]Example{
    .{ .name = "all_test_positive" },
    .{ .name = "array_sum" },
    .{ .name = "bubble_sort" },
    .{ .name = "factorial" },
    .{ .name = "load_store_call" },
    .{ .name = "print_bytes" },
    .{ .name = "print_string" },
    .{ .name = "xor" },
    .{ .name = "read_i32", .input = "21" },

    // The multiply that makes the next power comes before the test that ends the
    // loop. Therefore the program prints 2^0 through 2^30 and then traps on
    // 2^31, which an i32 cannot hold. The trap is a fault in the example and not
    // in the VM. It is recorded here so the corpus keeps the 31 lines that the
    // program does print.
    .{ .name = "powers_of_two", .trap = error.IntegerOverflow },
};

/// `md5.vigas` reads stdin and prints a digest. One program therefore gives as
/// many test cases as there are inputs, and each expected value is the digest
/// that every other MD5 implementation produces.
const md5_cases = [_]struct { input: []const u8, digest: []const u8 }{
    .{ .input = "", .digest = "d41d8cd98f00b204e9800998ecf8427e" },
    .{ .input = "a", .digest = "0cc175b9c0f1b6a831c399e269772661" },
    .{ .input = "abc", .digest = "900150983cd24fb0d6963f7d28e17f72" },
    .{ .input = "message digest", .digest = "f96b697d7cb7938d525a2f31aaf161d0" },
    .{
        .input = "The quick brown fox jumps over the lazy dog",
        .digest = "9e107d9d372bb6826bd81d3542a419d6",
    },
    // 64 bytes: exactly one MD5 block, so the padding goes into a block of its
    // own. This is the case that an implementation gets wrong.
    .{
        .input = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl",
        .digest = "a2eaf6295c32adc403865fd96a2f182b",
    },
};

// Running one example -------------------------------------------------------

const Harness = struct {
    input: Io.Reader,
    collected: Io.Writer.Allocating,
    vm: machine.VM,

    fn init(input: []const u8) Harness {
        return .{
            .input = .fixed(input),
            .collected = .init(std.testing.allocator),
            .vm = machine.VM.init(undefined, undefined),
        };
    }

    fn start(self: *Harness) void {
        self.vm.input = &self.input;
        self.vm.output = &self.collected.writer;
    }

    fn deinit(self: *Harness) void {
        self.vm.deinit();
        self.collected.deinit();
    }
};

fn exampleFile(allocator: std.mem.Allocator, name: []const u8, extension: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, extension });
    defer allocator.free(file_name);

    const path = try std.fs.path.join(allocator, &.{ options.examples_dir, file_name });
    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
}

/// Assemble the example, run it, and give the output that the program produced.
/// The caller frees the result.
fn runExample(allocator: std.mem.Allocator, example: Example) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try exampleFile(arena, example.name, ".vigas");
    const program = try assembler.assemble(arena, source, null);

    var harness = Harness.init(example.input);
    defer harness.deinit();
    harness.start();

    try harness.vm.loadProgram(program);
    if (example.trap) |expected_error| {
        try std.testing.expectError(expected_error, harness.vm.run());
    } else {
        try harness.vm.run();
    }

    return allocator.dupe(u8, harness.collected.written());
}

/// The output of an example, with the line endings made uniform. A `.expected`
/// file that a Windows editor saved has CRLF endings, and the VM always writes
/// LF. A test must fail for a difference in the output of a program and not for
/// a difference in how a file was saved.
fn normalize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, text, "\r\n", "\n");
    const result = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, text, "\r\n", "\n", result);
    return result;
}

// Tests ----------------------------------------------------------------------

test "each example program still produces its recorded output" {
    const allocator = std.testing.allocator;

    for (examples) |example| {
        const actual = try runExample(allocator, example);
        defer allocator.free(actual);

        const recorded = try exampleFile(allocator, example.name, ".expected");
        defer allocator.free(recorded);
        const expected = try normalize(allocator, recorded);
        defer allocator.free(expected);

        // The name of the program goes to stderr before the comparison. Without
        // it, a failure in this loop names only the line of the comparison and
        // the reader cannot tell which of the examples broke.
        std.testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("example that failed: {s}.vigas\n", .{example.name});
            return err;
        };
    }
}

test "the MD5 example agrees with the reference digest for every input" {
    const allocator = std.testing.allocator;

    for (md5_cases) |case| {
        const actual = try runExample(allocator, .{ .name = "md5", .input = case.input });
        defer allocator.free(actual);

        // The program prints the digest as four lines of eight hexadecimal
        // digits. Joining them gives the usual 32-character form.
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(allocator);
        var lines = std.mem.tokenizeScalar(u8, actual, '\n');
        while (lines.next()) |line| try joined.appendSlice(allocator, line);

        std.testing.expectEqualStrings(case.digest, joined.items) catch |err| {
            std.debug.print("md5 input that failed: \"{s}\"\n", .{case.input});
            return err;
        };
    }
}

test "every example in the assembler package is either tested or excluded on purpose" {
    // A new example must not join the directory and then be tested by nothing.
    // This test lists the four programs that a test cannot check and fails for
    // any other name that no case above covers.
    const untestable = [_][]const u8{
        "beep", // makes a sound through a Windows library
        "message_box", // opens a dialog and waits for a person
        "get_process_id", // a different value on each run
        "foreign_calls_positive", // calls into Windows libraries
    };

    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, options.examples_dir, .{ .iterate = true });
    defer directory.close(std.testing.io);

    var missing: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".vigas")) continue;
        const name = entry.name[0 .. entry.name.len - ".vigas".len];

        if (std.mem.eql(u8, name, "md5")) continue;
        for (untestable) |excluded| {
            if (std.mem.eql(u8, name, excluded)) break;
        } else {
            for (examples) |example| {
                if (std.mem.eql(u8, name, example.name)) break;
            } else {
                std.debug.print("example covered by no test: {s}.vigas\n", .{name});
                missing += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}
