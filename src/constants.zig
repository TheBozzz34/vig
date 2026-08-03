// size of the VM's main memory
pub const memory_size = 4096;

// size of the VM's stack
pub const stack_size = 256;

// size of the VM's data segment, used for load and store ops
pub const data_size = 256;

// size of the VM's call stack, used for function calls and returns
pub const call_stack_size = 128;

// Foreign functions are deliberately limited to a small, predictable ABI
// surface.  This is enough for simple Windows APIs without exposing arbitrary
// host pointers or callback support to VIG programs.
pub const max_foreign_imports = 16;
pub const max_foreign_args = 4;

// All opcodes
pub const OpCode = enum(u8) {
    halt = 0,
    push = 1,
    add = 2,
    sub = 3,
    print = 4,
    dup = 5,
    pop = 6,
    swap = 7,
    mul = 8,
    div = 9,
    mod = 10,
    eq = 11,
    ne = 12,
    lt = 13,
    lte = 14,
    gt = 15,
    gte = 16,
    jmp = 17,
    jmp_zero = 18,
    jmp_not_zero = 19,
    load = 20,
    store = 21,
    call = 22,
    ret = 23,
    foreign_call = 24,
};
