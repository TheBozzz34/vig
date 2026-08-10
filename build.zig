const std = @import("std");
const libffi = @import("build/libffi.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ffi = libffi.build(b, target, optimize);

    // Counting instructions costs time in the loop that runs them, so it is a
    // build option and not a flag: a VM that anyone ships must not pay for it.
    // `zig build install -Doptimize=ReleaseFast -Dstats` gives the one to measure
    // with, and `vig --stats <program>` then writes the report.
    const stats = b.option(
        bool,
        "stats",
        "Count the instructions a program runs and report them per opcode",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "stats", stats);
    const build_options_module = build_options.createModule();

    // The VM shares the opcodes, the container format and the verifier with the
    // assembler. This build does not make them again.
    const bytecode_package = b.dependency("vig_bytecode", .{
        .target = target,
        .optimize = optimize,
    });
    const bytecode = bytecode_package.module("vig_bytecode");

    // The assembler, for the tests only. `vig.exe` runs a program that vigasm
    // made before; it does not assemble one. Therefore this module goes to the
    // test roots that need it and not to the executable.
    const assembler_package = b.dependency("vig_assembler", .{
        .target = target,
        .optimize = optimize,
    });
    const assembler = assembler_package.module("vig_assembler");

    // The example programs live in the assembler package, next to the assembler
    // that reads them. A test assembles each one and runs it, and the build graph
    // is what knows where that package landed. Therefore the directory arrives as
    // a generated option and not as a relative path written into a test.
    //
    // `addOptionPath` takes one file and hashes it, so it cannot carry a
    // directory. The build root of the dependency gives the same answer, and the
    // test opens the files itself.
    const assembler_root = packageRoot(b, assembler_package);
    const examples_dir = b.pathJoin(&.{ assembler_root, "examples" });
    const example_options = b.addOptions();
    example_options.addOption([]const u8, "examples_dir", examples_dir);
    const example_options_module = example_options.createModule();

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
            .imports = &.{
                .{ .name = "vig_bytecode", .module = bytecode },
                .{ .name = "build_options", .module = build_options_module },
            },
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
    //
    // Only a test that assembles a program needs the assembler, and only the
    // corpus test needs to find the example directory. Therefore each root takes
    // the modules that it uses and no others.
    const TestRoot = struct {
        path: []const u8,
        needs_assembler: bool = false,
        needs_examples: bool = false,
    };
    const test_roots = [_]TestRoot{
        .{ .path = "src/main.zig" },
        .{ .path = "src/machine.zig" },
        .{ .path = "src/utils.zig" },
        .{ .path = "src/foreign.zig" },
        .{ .path = "src/toolchain_tests.zig", .needs_assembler = true },
        .{ .path = "src/example_tests.zig", .needs_assembler = true, .needs_examples = true },
    };

    // A top-level step that runs all the tests. The run steps are independent.
    // Therefore they run in parallel.
    const test_step = b.step("test", "Run tests");

    for (test_roots) |root| {
        var imports: std.ArrayList(std.Build.Module.Import) = .empty;
        imports.append(b.allocator, .{ .name = "vig_bytecode", .module = bytecode }) catch @panic("OOM");
        imports.append(b.allocator, .{ .name = "build_options", .module = build_options_module }) catch @panic("OOM");
        if (root.needs_assembler) {
            imports.append(b.allocator, .{ .name = "vig_assembler", .module = assembler }) catch @panic("OOM");
        }
        if (root.needs_examples) {
            imports.append(
                b.allocator,
                .{ .name = "example_options", .module = example_options_module },
            ) catch @panic("OOM");
        }

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root.path),
                .target = target,
                .optimize = optimize,
                .imports = imports.items,
            }),
        });
        libffi.link(tests.root_module, ffi);

        const run_tests = b.addRunArtifact(tests);
        // This root reads the example programs and their recorded output at run
        // time. Those files are not inputs that the build graph knows about.
        // Therefore a change to one of them does not make the test binary
        // different, and a cached result would hide the change.
        if (root.needs_examples) run_tests.has_side_effects = true;
        test_step.dependOn(&run_tests.step);
    }

    // One command that tests the three packages together. `zig build test` runs
    // the tests of this package only. The shared bytecode package holds the
    // instruction set and the container format, so a change there can break the
    // assembler while this build stays green. Therefore a change that touches the
    // instruction set needs this step and not the one above.
    const test_all_step = b.step("test-all", "Run the tests of this package and of each dependency");
    test_all_step.dependOn(test_step);
    for ([_][]const u8{ packageRoot(b, bytecode_package), assembler_root }) |package_root| {
        const run_package_tests = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
        run_package_tests.setCwd(.{ .cwd_relative = package_root });
        // The result of another build is not something this build graph can
        // track. Therefore it must run every time.
        run_package_tests.has_side_effects = true;
        test_all_step.dependOn(&run_package_tests.step);
    }
}

/// The directory that holds the `build.zig` of a dependency. The tests need it to
/// reach files that a module does not export, and `test-all` needs it to run the
/// suite of that package.
fn packageRoot(b: *std.Build, package: *std.Build.Dependency) []const u8 {
    const root = package.builder.root;
    return b.pathJoin(&.{ root.root_dir.path orelse ".", root.sub_path });
}
