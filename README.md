# VIG

VIG is a simple stack based virtual machine written in zig. It has a small set of instructions, and includes a simple assembler.
Programs can be written in a simplified assembly language, assembled via vigasm, and run directly with vig.exe

The instruction set, container format, and the bytecode verifier live in
[vig-bytecode](https://github.com/TheBozzz34/vig-bytecode)

## Loading a program

A program file a has this structure: a header recording the code length, the
static-data length, the entry point, the import-table length, and a format
version and flags, followed by the import table, the code, and the static data.
The [format is documented in vig-bytecode](https://github.com/TheBozzz34/vig-bytecode#container-formatt).

The VM copies the code and the static data into memory as one image, with the data
immediately after the code, then starts at the container's entry point. Only the
code region is executable: execution stops at its end and every jump and call
target must fall inside it. Addresses a program pushes may reach the whole image,
which is how `print_string` and `cstr` foreign arguments reach static data.

Before any of a program runs, it is verified, every reachable instruction must
decode, every branch must land on an instruction boundary, and control must not
fall off the end of the code. A rejected program reports the code offset that
failed and does not execute at all.

A function that only a `call_indirect` names is not reachable from the entry point,
so the walk at load time does not find it. Such a function is verified the first
time a call goes to it, and the result is kept. The code region cannot change while
a program runs, so the answer is the one a check before the run would have given.

## Memory

The guest address space defaults to **1 MiB** and `--memory` changes it:

```bash
vig --memory 16M program.vig
```

The size takes a `K` or `M` suffix. The ceiling is 2 GiB, because a guest pointer is
a value on the operand stack and the stack holds an `i32`: no program can name a byte
above that however large the memory is.

The memory, the operand stack, the call stack and the verifier scratch all come from
an allocator, so the size is a property of the program being run and not of this
build. One `vig` runs a hand-written example in a few kilobytes and a compiled
program in as much as it needs.

The verifier scratch is one mark per byte of **code**, not per byte of memory. It
was the second of those, which cost one byte of host memory for every byte of guest
memory whatever the program held: at 1 MiB of memory, `md5.vigas` needs 2,333 marks
rather than 1,048,576.

## Reading a program

`vig --disasm program.vig` writes the program as a listing instead of running it:
the offset, the bytes and the instruction on each line, then the static data. A
trap names a code offset, and this is how that offset becomes an instruction.

```
$ vig --disasm table.vig
; 44 bytes of code, 11 of static data, 0 zero-filled
        ; entry point
0000  01 15 00 00 00  push 21
0005  01 30 00 00 00  push 48
000a  2c              load32
000b  3e              call_indirect
000c  04              print
000d  00              halt
```

The program does not have to load: a listing of a program the verifier refuses is
exactly what a person needs to see.

## Runtime I/O

`print` and `print_string` write to **stdout**. The VM's own diagnostics go to **stderr**, so program output can
be redirected on its own:

```powershell
vig.exe program.vig > output.txt
```

Program output is buffered and flushed when execution ends, including when a
program traps, so anything printed before a trap is not lost.

`read_i32` reads a whitespace-delimited signed decimal integer from **stdin**
and pushes it onto the data stack. Input can be typed interactively or supplied
through a pipe or redirected file:

```powershell
"20" | vig.exe double.vig
vig.exe program.vig < input.txt
```

Before waiting for input, the VM flushes stdout so a prompt printed by the
program is visible.

`read_byte` reads raw bytes from stdin and pushes `0` through `255`, or `-1` at
EOF. This permits byte-oriented programs to process streams whose length is not
known in advance. `print_hex` prints the raw bits of the top stack value as eight
lowercase hexadecimal digits and retains the value.

## Supported systems

The VM builds and runs on Windows, Linux and macOS. Every instruction behaves the
same on all of them.

Foreign calls work on Windows and on a system with the POSIX loader.
`src/foreign.zig` chooses its implementation at compile time: `LoadLibraryA` and
`GetProcAddress` on Windows, `dlopen` and `dlsym` elsewhere, and libffi supplies
the calling convention of the target for both. A system that has neither loader
refuses a program that declares an `extern` when it loads, with a message that says
so; a program that declares none is unaffected.

A library *name* is still particular to the system, because the name in the
program goes to the loader as it stands. A program that names `kernel32.dll` runs
on Windows only, and one that names `libc.so.6` runs on Linux only, even though
both systems can make the call.
[FOREIGN_FUNCTIONS.md](FOREIGN_FUNCTIONS.md) has the details.

## Foreign calls

See [FOREIGN_FUNCTIONS.md](FOREIGN_FUNCTIONS.md). The libffi build lives in
[build/libffi.zig](build/libffi.zig)

## Tests

```powershell
zig build test
```

Each source file with `test` blocks is registered as its own test root in
`build.zig`, because a Zig test executable only collects tests from its own root
file. The shared package has its own suite:

```powershell
cd ..\vig-bytecode; zig build test
```
