const bytecode = @import("vig_bytecode");

/// The sizes that a VM is built with.
///
/// These were build-time constants. They are a value now, because the size a program
/// needs is a property of the program and not of the build: a hand-written example
/// runs in a few kilobytes and a compiled C program does not. A caller chooses, and
/// one `vig` runs both.
///
/// The layout of guest memory while a program runs:
///
///   [0, code_len)            the instructions. Read-only: a store below
///                            `code_len` faults, so the result of the verifier
///                            stays true for the whole run.
///   [code_len, program_len)  the static data of the program, from the container.
///   [program_len, end)       space that starts as zeros. A program reaches it
///                            with the byte-addressed instructions, and each frame
///                            takes its storage from the end of it.
///
/// `code_len` and `program_len` are on the VM, because they belong to the program
/// that is loaded and not to the size of the memory.
pub const Config = struct {
    /// The size of the byte-addressed guest address space.
    memory_size: usize = default_memory_size,
    /// The number of values that the operand stack holds. A compiler nests
    /// expressions more deeply than a person writing by hand does.
    stack_size: usize = default_stack_size,
    /// The number of calls that can be active at one time.
    call_stack_size: usize = default_call_stack_size,

    /// The largest memory that a VM can address.
    ///
    /// A guest pointer is a value on the operand stack, which holds an `i32`. A
    /// negative address is a fault, so no program can name a byte at or above this
    /// limit however large the memory is.
    pub const max_memory_size: usize = 1 << 31;

    pub fn check(self: Config) error{ MemoryTooLarge, ConfigTooSmall }!void {
        if (self.memory_size > max_memory_size) return error.MemoryTooLarge;
        // A VM with no memory can hold no program, and one with no stack can run no
        // instruction that produces a value.
        if (self.memory_size == 0 or self.stack_size == 0 or self.call_stack_size == 0) {
            return error.ConfigTooSmall;
        }
    }
};

/// One mebibyte of guest memory, which is where a compiled program starts to fit.
/// The examples need a fraction of it; the cost of the rest is one allocation.
pub const default_memory_size = 1 << 20;

pub const default_stack_size = 1024;
pub const default_call_stack_size = 256;

/// The default sizes as a value.
pub const default: Config = .{};

/// The sizes that the tests build a VM with.
///
/// A test that fills memory or overflows a stack is cheap at these sizes, and it can
/// name the number that the VM was given rather than a number of its own. The
/// defaults above would make those tests slow and say nothing more.
pub const testing: Config = .{
    .memory_size = 65536,
    .stack_size = 256,
    .call_stack_size = 128,
};

/// The largest program file that a VM with this much memory can load.
///
/// The VM removes the container header and the import table before it copies the
/// code into memory. Therefore the largest permitted file is larger than the memory
/// itself. The shared `vig_bytecode` package holds the instruction set, the
/// foreign-call limits and the container layout.
pub fn maxProgramFileSize(memory_size: usize) usize {
    return bytecode.container.maxFileSize(memory_size);
}
