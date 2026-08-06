# Foreign functions

VIG can call a small subset of the native library functions declared by a VIGasm
`extern` statement. The assembler stores those declarations in the import table of
the `VIGF` container; the VM resolves each symbol when it loads the program, then
uses libffi to prepare and perform each call. The argument types, the limits below,
and the import-table encoding are defined in [vig-bytecode](../vig-bytecode).

A `foreign_call` whose index does not name a declared import is rejected when the
program is verified, before it runs.

## Platform support

Foreign calls need three things from the operating system: a way to load a
library, a way to find a symbol inside it, and the calling convention of the
target. `src/foreign.zig` selects one namespace at compile time:

| System | Load | Find symbol | Convention |
| --- | --- | --- | --- |
| Windows | `LoadLibraryA` | `GetProcAddress` | `FFI_WIN64` |
| Linux, macOS, FreeBSD, NetBSD, OpenBSD, DragonFly, illumos | `dlopen` | `dlsym` | `FFI_DEFAULT_ABI` for the target |
| any other | — | — | — |

`FFI_DEFAULT_ABI` is what libffi defines in the `ffitarget.h` of the
architecture: `FFI_UNIX64` for x86-64, `FFI_SYSV` for AArch64 and 32-bit ARM.
Therefore a new architecture needs no change in the VM. `foreign.supported` says
whether the running build has a loader, and a system that has none refuses each
declaration with `error.ForeignCallsUnsupported`.

The POSIX namespace opens a library with `RTLD_NOW` and without `RTLD_GLOBAL`:
a library whose own symbols are incomplete then fails at load time rather than
part-way through a call, and an import does not change what a later load in the
same process can see.

The rest of the VM needs none of those three things, so **the VM itself builds and
runs on every one of those systems**, and a program that declares no `extern`
behaves identically on all of them.

### A library name is not portable

The name in the `extern` declaration goes to the loader of the running system as
it stands. The VM makes no name from a shorter one, because the answer differs
per system — `libc.so.6` against `libSystem.B.dylib`, with a version suffix that
only the author of the program knows.

So a program that names `kernel32.dll` still fails on Linux. It fails with
`error.ForeignLibraryNotFound` rather than `error.ForeignCallsUnsupported`, and it
fails when the program loads rather than part-way through a run. Making one
program that calls into whichever system runs it is a job for the assembler or for
the program, not for the loader here.

A static build is a second limit: a statically linked musl executable has no
dynamic loader, so `dlopen` finds nothing even though the build reports support.

The VM builds the pinned official libffi source release from `build.zig.zon` and
generates Zig bindings from its C header; no system libffi installation or
`pkg-config` setup is needed. That build lives in
[build/libffi.zig](build/libffi.zig), which holds the pinned version as a single
constant and derives the three config-header fields libffi wants from it.

The current foreign-call ABI is intentionally small:

- At most four `i32`, `u32`, `ptr`, or `cstr` arguments.
- A 32-bit integer result, pushed on the VIG stack.
- Integer and pointer calls only, in the default convention of the target. See
  Platform support above.

`ptr` and `cstr` values are byte addresses in guest memory, not native addresses.
The VM translates one into a host address for the call, so a foreign function never
sees a VIG address and a VIG program never sees a host one. A zero value is passed
as `NULL`.

The two differ in what they may name:

- **`ptr` may name any byte of guest memory**, including one in a call frame.
  Therefore a program can pass the address of a local, and a foreign function can
  write into it — which is what an output parameter is. The bound is the memory
  itself, so no address outside it can be handed to a native function.
- **`cstr` must name a byte of the program image** — the code, the static data, then
  the zero-filled region — and the string must have its terminator inside that image.
  A string is read to its terminator, and memory above the image starts as zeros, so
  every address there would look like the end of a string and an unterminated one
  would stop being an error. `asciiz` and `reserve` both produce addresses that
  qualify.

Calls that use callbacks, structs, floating-point values, more than four
arguments, or 64-bit results are deliberately outside this first version.

See the VIGasm opcode reference for syntax and examples.
