"""Target-aware configuration helpers for the vendored libffi build."""

def _configure_libffi_impl(ctx):
    ctx.actions.expand_template(
        template = ctx.file.ffi_template,
        output = ctx.outputs.ffi_h,
        substitutions = {
            "@FFI_EXEC_TRAMPOLINE_TABLE@": "0",
            "@FFI_VERSION_NUMBER@": "30502",
            "@FFI_VERSION_STRING@": "3.5.2",
            "@HAVE_LONG_DOUBLE@": "1",
            "@TARGET@": ctx.attr.target,
            "@VERSION@": "3.5.2",
        },
    )
    ctx.actions.expand_template(
        template = ctx.file.fficonfig_template,
        output = ctx.outputs.fficonfig_h,
        substitutions = {
            "@PLATFORM_DEFINES@": ctx.attr.platform_defines,
        },
    )
    return DefaultInfo(files = depset([ctx.outputs.ffi_h, ctx.outputs.fficonfig_h]))

configure_libffi = rule(
    implementation = _configure_libffi_impl,
    attrs = {
        "ffi_template": attr.label(allow_single_file = True, mandatory = True),
        "fficonfig_template": attr.label(allow_single_file = True, mandatory = True),
        "ffi_h": attr.output(mandatory = True),
        "fficonfig_h": attr.output(mandatory = True),
        "target": attr.string(mandatory = True),
        "platform_defines": attr.string(),
    },
)

def _copy_file_impl(ctx):
    ctx.actions.symlink(
        output = ctx.outputs.out,
        target_file = ctx.file.src,
    )
    return DefaultInfo(files = depset([ctx.outputs.out]))

copy_file = rule(
    implementation = _copy_file_impl,
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True),
        "out": attr.output(mandatory = True),
    },
)

