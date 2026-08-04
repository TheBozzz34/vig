const bytecode = @import("vig_bytecode");

// The size of the main memory of the VM: the byte-addressed guest address space.
//
// The layout of this memory while a program runs:
//
//   [0, code_len)            the instructions. Read-only: a store below
//                            `code_len` faults, so the result of the verifier
//                            stays true for the whole run.
//   [code_len, program_len)  the static data of the program, from the container.
//   [program_len, end)       space that starts as zeros. A program reaches it
//                            with the byte-addressed instructions.
//
// `code_len` and `program_len` are on the VM, because they belong to the program
// that is loaded and not to the build.
//
// The cost of this value is paid twice: once for the memory and once for the
// verifier scratch, which needs one mark for each byte of the code region. At
// 64 KiB that is 128 KiB for a VM, which is why the VM lives behind a pointer.
// A run with this at 1 MiB also passes, so the value is a choice and not a limit.
pub const memory_size = 65536;

// The size of the stack of the VM.
pub const stack_size = 256;

// The size of the data segment of the VM. The `load` and `store` instructions
// use this segment.
//
// This segment is an array of i32 slots and it is not part of the memory above. A
// number therefore names a different place in each: `load 4` reads the fifth slot
// of this segment, and `load32` with 4 on the stack reads the four bytes at offset
// 4 of that memory. The globals move out of here and into that memory in a later
// stage, and this segment goes away with them.
pub const data_size = 4096;

// The size of the call stack of the VM. The `call` and `ret` instructions use
// this stack.
pub const call_stack_size = 128;

// The VM removes the container header and the import table before it copies the
// code into memory. Therefore the largest permitted file is larger than
// `memory_size`. The shared `vig_bytecode` package holds the instruction set, the
// foreign-call limits and the container layout.
pub const max_program_file_size = bytecode.container.maxFileSize(memory_size);
