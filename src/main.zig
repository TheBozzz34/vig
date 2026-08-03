const std = @import("std");
const Io = std.Io;
const machine = @import("machine.zig");
const utils = @import("utils.zig");

const vm_memory_size = 1024;

pub fn main(init: std.process.Init) !void {
    std.log.info("Starting VIG", .{});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    std.log.info("Init VM", .{});

    var vm: machine.VM = machine.VM.init(arena, vm_memory_size) catch |err| {
        std.log.err("Failed to initialize VM: {s}", .{@errorName(err)});
        return err;
    };

    defer vm.deinit(arena);

    std.log.info("VM initialized successfully.", .{});

    if (args.len > 2) {
        std.log.err("Usage: vig [program-file]", .{});
        return error.InvalidArguments;
    }

    if (args.len == 2) {
        const path = args[1];
        std.log.info("Loading program from file: {s}", .{path});
        utils.loadProgramFromFile(&vm, init.io, init.gpa, path) catch |err| {
            std.log.err("Failed to load program: {s}", .{@errorName(err)});
            return err;
        };
    } else {
        std.log.info("No program file supplied. Exiting.", .{});
        return;
    }

    std.log.info("Loaded {d} program bytes.", .{vm.program_len});
    std.log.info("Running VM", .{});

    machine.run(&vm) catch |err| {
        std.log.err("VM execution failed: {s}", .{@errorName(err)});
        return err;
    };

    std.log.info("VM execution completed successfully.", .{});
}
