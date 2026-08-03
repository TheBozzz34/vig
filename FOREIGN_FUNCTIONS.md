# Foreign functions

VIG can call a small subset of Windows x64 APIs declared by a VIGasm `extern`
statement. The assembler stores those declarations in a `VIGF` program header;
the VM resolves each DLL symbol with `LoadLibraryA` and `GetProcAddress` when it
loads the program.

The current foreign-call ABI is intentionally small:

- At most four `i32`, `u32`, `ptr`, or `cstr` arguments.
- A 32-bit integer result, pushed on the VIG stack.
- Windows x64 integer/pointer calls only.

`ptr` and `cstr` values are offsets into the loaded VIG program, not native
addresses. A zero pointer is passed as `NULL`. `cstr` must point to a
NUL-terminated string inside the loaded program. This permits static strings
without exposing arbitrary host-memory pointers.

Calls that use callbacks, structs, floating-point values, more than four
arguments, 64-bit results, or pointer output buffers are deliberately outside
this first version.

See the VIGasm opcode reference for syntax and examples.
