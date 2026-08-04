const std = @import("std");
const Io = std.Io;
const machine = @import("machine.zig");
const utils = @import("utils.zig");

pub fn main(init: std.process.Init) !void {
    std.log.info("Starting VIG", .{});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);

    // Program output goes to real stdout so it can be piped and redirected,
    // separately from the std.log diagnostics on stderr.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    var vm = machine.VM.init(&stdout.interface);
    defer vm.deinit();
    std.log.info("VM initialized successfully.", .{});

    if (args.len > 2) {
        std.log.err("Usage: vig [program-file]", .{});
        return error.InvalidArguments;
    }

    if (args.len == 2) {
        const path = args[1];
        std.log.info("Loading program from file: {s}", .{path});
        utils.loadProgramFromFile(&vm, init.io, init.gpa, path) catch |err| {
            if (vm.verification_failure) |failure| {
                std.log.err(
                    "Program rejected by the bytecode verifier at code offset {d}: {s}",
                    .{ failure.offset, @errorName(failure.reason) },
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
        // Flush first so partial program output precedes the error on stderr.
        stdout.interface.flush() catch {};
        std.log.err("VM execution failed: {s}", .{@errorName(err)});
        return err;
    };
    try stdout.interface.flush();

    std.log.info("============= END OF OUTPUT =============", .{});
    std.log.info("VM execution completed successfully.", .{});
}
