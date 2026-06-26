{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.start.static.linux;

// Freestanding `_start` for a static, libc-free Linux ET_EXEC (the --static
// kernel-leaf swap; docs/linux-syscall-migration.adoc).
//
// The libc-backed runtime.start calls __libc_start_main, which only exists when
// linking libc.  This variant is the drop-in replacement linked instead when a
// program is built --static: it sets up argc/argv from the raw process stack and
// jumps straight to `main` (which the backend emits to call _SetArgs/_BlaiseInit,
// run the body, and `exit`).
//
// On entry the kernel hands us the initial process stack (System V AMD64,
// "Initial Process Stack"):
//   (%rsp)              = argc
//   8(%rsp)             = argv[0] … argv[argc-1], then a NULL,
//   8+(argc+1)*8(%rsp)  = envp[0] … then a NULL, then auxv.
// So envp = &argv[argc+1] = %rsp + (argc+2)*8.  We capture it into the global
// `environ` (which getenv/execvp read) before calling main.
//
// main expects C-`main(argc, argv)` register layout: argc in %edi, argv in %rsi.

interface

procedure _start;

implementation

procedure _start; assembler; nostackframe;
asm
    endbr64
    xor  %ebp, %ebp            { clear frame pointer — outermost frame }
    movq (%rsp), %rdi          { %rdi = argc }
    leaq 8(%rsp), %rsi         { %rsi = &argv[0] }
    leaq 16(%rsp,%rdi,8), %rax { environ = &argv[argc+1] = %rsp+16+argc*8 }
    movq %rax, environ(%rip)
    andq $0xfffffffffffffff0, %rsp   { 16-byte align before the call }
    call main
    xorl %edi, %edi           { main terminates via exit; guard with exit_group(0) }
    movq $231, %rax           { SYS_exit_group }
    syscall
    hlt
end;

end.
