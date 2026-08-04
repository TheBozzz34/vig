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
