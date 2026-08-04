const std = @import("std");
const libffi = @import("build/libffi.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi = libffi.build(b, target, optimize);

    // The VM shares the opcodes, the container format and the verifier with the
    // assembler. This build does not make them again.
    const bytecode = b.dependency("vig_bytecode", .{
        .target = target,
        .optimize = optimize,
    }).module("vig_bytecode");

    const exe = b.addExecutable(.{
        .name = "vig",
        .root_module = b.createModule(.{
            // `b.createModule` makes a new module, the same as `b.addModule`.
            // But `b.createModule` does not make the module available to a user
            // of this package. Therefore this module does not need a name.
            .root_source_file = b.path("src/main.zig"),
            // The root module of an executable or a library must give the target
            // and the optimization level. A definition can also set a constant
            // target, for example the target for the firmware of an embedded
            // device.
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vig_bytecode", .module = bytecode }},
        }),
    });
    libffi.link(exe.root_module, ffi);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    // A test executable collects the `test` blocks from its own root file only.
    // Therefore each source file that has tests needs an entry here. With
    // `main.zig` as the only root, the build ran no test and gave no message.
    const test_roots = [_][]const u8{
        "src/main.zig",
        "src/machine.zig",
        "src/utils.zig",
        "src/foreign.zig",
    };

    // A top-level step that runs all the tests. The run steps are independent.
    // Therefore they run in parallel.
    const test_step = b.step("test", "Run tests");

    for (test_roots) |root| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "vig_bytecode", .module = bytecode }},
            }),
        });
        libffi.link(tests.root_module, ffi);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
