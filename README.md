# VIG

VIG is a simple stack based virtual machine written in zig. It has a small set of instructions, and includes a simple assembler.
Programs can be written in a simplified assembly language, assembled via vigasm, and run directly with vig.exe

## Output streams

`print` and `print_string` write to **stdout**. The VM's own diagnostics — the
startup banners and any execution error — go to **stderr**, so program output can
be redirected on its own:

```powershell
vig.exe program.vig > output.txt
```

Program output is buffered and flushed when execution ends, including when a
program traps, so anything printed before a trap is not lost.

## Tests

```powershell
zig build test
```

Each source file with `test` blocks is registered as its own test root in
`build.zig`, because a Zig test executable only collects tests from its own root
file.