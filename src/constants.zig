const bytecode = @import("vig_bytecode");

// The size of the main memory of the VM.
pub const memory_size = 4096;

// The size of the stack of the VM.
pub const stack_size = 256;

// The size of the data segment of the VM. The `load` and `store` instructions
// use this segment.
pub const data_size = 256;

// The size of the call stack of the VM. The `call` and `ret` instructions use
// this stack.
pub const call_stack_size = 128;

// The VM removes the container header and the import table before it copies the
// code into memory. Therefore the largest permitted file is larger than
// `memory_size`. The shared `vig_bytecode` package holds the instruction set, the
// foreign-call limits and the container layout.
pub const max_program_file_size = bytecode.container.maxFileSize(memory_size);
