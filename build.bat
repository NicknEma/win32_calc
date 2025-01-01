@echo off

del *.pdb > NUL 2> NUL
odin build . -debug -out:calc.exe -extra-linker-flags:"/opt:ref" -vet-shadowing -subsystem:windows
