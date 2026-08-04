const bytecode = @import("vig_bytecode");

// size of the VM's main memory
pub const memory_size = 4096;

// size of the VM's stack
pub const stack_size = 256;

// size of the VM's data segment, used for load and store ops
pub const data_size = 256;

// size of the VM's call stack, used for function calls and returns
pub const call_stack_size = 128;

// The container header and import table are stripped before code is copied into
// memory, so the largest acceptable file is larger than `memory_size`. The
// instruction set, the foreign-call limits, and the container layout itself all
// live in the shared `vig_bytecode` package.
pub const max_program_file_size = bytecode.container.maxFileSize(memory_size);
