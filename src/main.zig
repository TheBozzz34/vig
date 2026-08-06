const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const machine = @import("machine.zig");
const utils = @import("utils.zig");

pub fn main(init: std.process.Init) !void {
    std.log.info("Starting VIG", .{});

    // Use this allocator for data that stays for the full life of the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Read the command-line arguments.
    const args = try init.minimal.args.toSlice(arena);

    // The output of the program goes to stdout. Therefore a user can send it to
    // a pipe or to a file. The `std.log` diagnostic messages go to stderr.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    // Runtime input comes from stdin. A separate buffer lets `read_i32` consume
    // input incrementally from a terminal, pipe, or redirected file.
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(init.io, &stdin_buffer);

    // The VM holds the guest memory and the verifier scratch inline, so it is too
    // large for the stack of this function. The arena lives as long as the process.
    const vm = try arena.create(machine.VM);
    vm.init(&stdin.interface, &stdout.interface);
    defer vm.deinit();
    std.log.info("VM initialized successfully.", .{});

    if (args.len > 2) {
        std.log.err("Usage: vig [program-file]", .{});
        return error.InvalidArguments;
    }

    if (args.len == 2) {
        const path = args[1];
        std.log.info("Loading program from file: {s}", .{path});
        utils.loadProgramFromFile(vm, init.io, init.gpa, path) catch |err| {
            if (vm.verification_failure) |failure| {
                std.log.err(
                    "Program rejected by the bytecode verifier at code offset {d}: {s}",
                    .{ failure.offset, @errorName(failure.reason) },
                );
            } else if (err == error.ForeignCallsUnsupported) {
                // The program is correct; this build of VIG cannot run it. Say
                // which of the two it is, because the error name on its own reads
                // like a fault in the program.
                std.log.err(
                    "This program declares a foreign import, and this system has no library loader that VIG can use.",
                    .{},
                );
            } else if (err == error.ForeignLibraryNotFound) {
                // The system has a loader and the loader refused the name. The
                // usual reason is a program written for a different system, because
                // the name goes to the loader as the program wrote it.
                std.log.err(
                    "This program declares a foreign import that {s} cannot load. A library name is particular to one system.",
                    .{@tagName(builtin.os.tag)},
                );
            } else {
                std.log.err("Failed to load program: {s}", .{@errorName(err)});
            }
            return err;
        };
    } else {
        std.log.info("No program file supplied. Exiting.", .{});
        return;
    }

    std.log.info(
        "Loaded {d} program bytes: {d} of code, {d} of static data.",
        .{ vm.program_len, vm.code_len, vm.program_len - vm.code_len },
    );
    std.log.info("============= VM OUTPUT =============", .{});

    vm.run() catch |err| {
        // Flush the output first. Then the output of the program comes before
        // the error message on stderr.
        stdout.interface.flush() catch {};

        // An indirect call verifies the function it names, so a run can end with an
        // error from the verifier. That failure holds the offset of the instruction
        // inside the function, which the name of the error does not give.
        if (vm.verification_failure) |failure| {
            std.log.err(
                "VM execution failed at code offset {d}: {s}",
                .{ failure.offset, @errorName(failure.reason) },
            );
        } else {
            std.log.err("VM execution failed: {s}", .{@errorName(err)});
        }
        return err;
    };
    try stdout.interface.flush();

    std.log.info("============= END OF OUTPUT =============", .{});
    std.log.info("VM execution completed successfully.", .{});
}
