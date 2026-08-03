const std = @import("std");
const Io = std.Io;
const machine = @import("machine.zig");
const test_program = @import("test_program.zig").test_program;

const vig = @import("vig");

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

    var vm: machine.VM = machine.VM.init(arena, 1024) catch |err| {
        std.log.err("Failed to initialize VM: {s}", .{@errorName(err)});
        return err;
    };

    defer vm.deinit(arena);

    std.log.info("VM initialized successfully.", .{});
    std.log.info("Pushing test program into VM memory", .{});

    // Load the test program into the VM's memory
    if (test_program.len > vm.memory.len) {
        std.log.err("Test program is too large for VM memory.", .{});
        return error.ProgramTooLarge;
    }
    @memcpy(vm.memory[0..test_program.len], test_program[0..]);

    std.log.info("Program copied to VM memory.", .{});
    std.log.info("Running VM", .{});

    machine.run(&vm) catch |err| {
        std.log.err("VM execution failed: {s}", .{@errorName(err)});
        return err;
    };
}
