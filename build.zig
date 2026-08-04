const std = @import("std");

const Libffi = struct {
    library: *std.Build.Step.Compile,
    bindings: *std.Build.Module,
};

fn linkLibffi(
    module: *std.Build.Module,
    libffi: Libffi,
) void {
    module.linkLibrary(libffi.library);
    module.addImport("ffi", libffi.bindings);
}

fn buildLibffi(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Libffi {
    const upstream = b.dependency("libffi", .{});
    const source = upstream.path("");
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    const arch_dir, const target_name, const arch_sources: []const []const u8, const assembly_sources: []const []const u8 = switch (arch) {
        .x86_64 => if (os == .windows)
            .{ "src/x86", "X86_WIN64", &.{"src/x86/ffiw64.c"}, &.{"src/x86/win64.S"} }
        else
            .{ "src/x86", "X86_64", &.{ "src/x86/ffi64.c", "src/x86/ffiw64.c" }, &.{ "src/x86/unix64.S", "src/x86/win64.S" } },
        .x86 => .{ "src/x86", "X86", &.{"src/x86/ffi.c"}, &.{"src/x86/sysv.S"} },
        .aarch64 => .{ "src/aarch64", "AARCH64", &.{"src/aarch64/ffi.c"}, &.{"src/aarch64/sysv.S"} },
        .arm => .{ "src/arm", "ARM", &.{"src/arm/ffi.c"}, &.{"src/arm/sysv.S"} },
        else => @panic("libffi target architecture is not supported"),
    };

    const ffi_header = b.addConfigHeader(.{
        .style = .{ .autoconf_at = upstream.path("include/ffi.h.in") },
        .include_path = "ffi.h",
    }, .{
        .VERSION = "3.5.2",
        .TARGET = target_name,
        .HAVE_LONG_DOUBLE = 1,
        .FFI_EXEC_TRAMPOLINE_TABLE = @as(i64, if (os == .macos and arch == .aarch64) 1 else 0),
        .FFI_VERSION_STRING = "3.5.2",
        .FFI_VERSION_NUMBER = 30502,
    });

    const generated = b.addWriteFiles();
    _ = generated.add("fficonfig.h", b.fmt(
        \\#ifndef LIBFFI_CONFIG_H
        \\#define LIBFFI_CONFIG_H
        \\#define HAVE_LONG_DOUBLE 1
        \\#define STDC_HEADERS 1
        \\#define HAVE_INTTYPES_H 1
        \\#define HAVE_STDINT_H 1
        \\#define HAVE_STRING_H 1
        \\{s}{s}{s}{s}{s}{s}
        \\#ifdef HAVE_HIDDEN_VISIBILITY_ATTRIBUTE
        \\#ifdef LIBFFI_ASM
        \\#ifdef __APPLE__
        \\#define FFI_HIDDEN(name) .private_extern name
        \\#else
        \\#define FFI_HIDDEN(name) .hidden name
        \\#endif
        \\#else
        \\#define FFI_HIDDEN __attribute__ ((visibility ("hidden")))
        \\#endif
        \\#else
        \\#ifdef LIBFFI_ASM
        \\#define FFI_HIDDEN(name)
        \\#else
        \\#define FFI_HIDDEN
        \\#endif
        \\#endif
        \\#endif
        \\
    , .{
        if (os == .linux or os == .macos) "#define HAVE_ALLOCA_H 1\n" else "",
        if (os != .linux and os != .windows) "#define HAVE_HIDDEN_VISIBILITY_ATTRIBUTE 1\n" else "",
        if (os != .linux) "#define HAVE_MMAP 1\n#define HAVE_MPROTECT 1\n#define FFI_MMAP_EXEC_WRIT 1\n" else "",
        if (os == .linux) "#define HAVE_MEMFD_CREATE 1\n#define HAVE_SYS_MEMFD_H 1\n" else "",
        if (os == .linux) "#define FFI_EXEC_STATIC_TRAMP 1\n" else "",
        if (arch == .x86_64 or arch == .x86) "#define HAVE_AS_X86_PCREL 1\n" else "",
    }));

    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    module.addConfigHeader(ffi_header);
    module.addIncludePath(generated.getDirectory());
    module.addIncludePath(upstream.path("include"));
    module.addIncludePath(upstream.path(arch_dir));
    module.addCSourceFiles(.{ .root = source, .files = &.{
        "src/prep_cif.c",
        "src/types.c",
        "src/closures.c",
        "src/tramp.c",
    }, .flags = if (os == .windows) &.{} else &.{"-fvisibility=hidden"} });
    module.addCSourceFiles(.{ .root = source, .files = arch_sources, .flags = if (os == .windows) &.{} else &.{"-fvisibility=hidden"} });
    for (assembly_sources) |assembly| module.addAssemblyFile(upstream.path(assembly));

    const library = b.addLibrary(.{
        .name = "ffi",
        .root_module = module,
        .linkage = .static,
    });

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/libffi.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addConfigHeader(ffi_header);
    translate.addIncludePath(upstream.path("include"));
    translate.addIncludePath(upstream.path(arch_dir));

    return .{ .library = library, .bindings = translate.createModule() };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libffi = buildLibffi(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "vig",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
        }),
    });
    linkLibffi(exe.root_module, libffi);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    // A test executable only collects `test` blocks from its own root file, so
    // every source file holding tests needs its own entry here. Rooting only at
    // main.zig silently ran zero tests.
    const test_roots = [_][]const u8{
        "src/main.zig",
        "src/machine.zig",
        "src/utils.zig",
        "src/foreign.zig",
    };

    // A top level step for running all tests. The run steps do not depend on
    // one another, so they execute in parallel.
    const test_step = b.step("test", "Run tests");

    for (test_roots) |root| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        linkLibffi(tests.root_module, libffi);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
