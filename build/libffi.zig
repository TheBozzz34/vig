//! This module builds libffi from the given upstream release. It also makes the
//! Zig bindings for the library. Therefore the build needs no libffi from the
//! system and no `pkg-config` setup.
//!
//! This module is not part of `build.zig`, because it is the large and complex
//! part of the build. It holds a source list for each architecture, it makes an
//! `fficonfig.h` file, and it puts the version into three fields of that
//! configuration header. Therefore the build graph of the VM stays easy to read,
//! and the version of libffi is in one position only.

const std = @import("std");

/// The upstream release for this build. `build.zig.zon` names the tarball of the
/// same version. To use a new version, change these two positions only.
pub const version = std.SemanticVersion{ .major = 3, .minor = 5, .patch = 2 };

pub const Libffi = struct {
    library: *std.Build.Step.Compile,
    bindings: *std.Build.Module,
};

/// Let `module` do `@import("ffi")` and link to the library from this build.
pub fn link(module: *std.Build.Module, libffi: Libffi) void {
    module.linkLibrary(libffi.library);
    module.addImport("ffi", libffi.bindings);
}

pub fn build(
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

    // libffi writes its version in three forms in one header. This module makes
    // all three forms from the one constant above. Therefore a change of the
    // version is always complete.
    const version_string = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
    const version_number = version.major * 10000 + version.minor * 100 + version.patch;

    const ffi_header = b.addConfigHeader(.{
        .style = .{ .autoconf_at = upstream.path("include/ffi.h.in") },
        .include_path = "ffi.h",
    }, .{
        .VERSION = version_string,
        .TARGET = target_name,
        .HAVE_LONG_DOUBLE = 1,
        .FFI_EXEC_TRAMPOLINE_TABLE = @as(i64, if (os == .macos and arch == .aarch64) 1 else 0),
        .FFI_VERSION_STRING = version_string,
        .FFI_VERSION_NUMBER = @as(i64, @intCast(version_number)),
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

    const c_flags: []const []const u8 = if (os == .windows) &.{} else &.{"-fvisibility=hidden"};
    module.addCSourceFiles(.{ .root = source, .files = &.{
        "src/prep_cif.c",
        "src/types.c",
        "src/closures.c",
        "src/tramp.c",
    }, .flags = c_flags });
    module.addCSourceFiles(.{ .root = source, .files = arch_sources, .flags = c_flags });
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
