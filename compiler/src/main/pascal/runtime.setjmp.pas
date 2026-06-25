{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.setjmp;

// setjmp/longjmp for the exception runtime (try/except, try/finally).
//
// Inline-assembler port of runtime/src/main/asm/blaise_setjmp_x86_64.s — the
// bodies move into `asm … end` routines so the RTL needs no hand-written .s
// (docs/inline-asm-design.adoc, §"Migration of the .s files").
//
// The jmp_buf is a 64-byte block: callee-saved regs rbx/rbp/r12..r15 at
// 0/8/16..40, the caller's RSP at 48, and the return address at 56.
//
// System V AMD64 arg registers: Buf -> %rdi, Val -> %esi.  Both routines own
// their frame (`nostackframe`); _blaise_setjmp captures the return address off
// the stack and _blaise_longjmp restores RSP and jumps through the saved
// return address, so a compiler-generated prologue must not intervene.

interface

function  _blaise_setjmp(Buf: Pointer): Integer;
procedure _blaise_longjmp(Buf: Pointer; Val: Integer);

implementation

{ Save the machine context into Buf; returns 0 on the direct call. }
function _blaise_setjmp(Buf: Pointer): Integer; assembler; nostackframe;
asm
    mov  %rbx,    (%rdi)
    mov  %rbp,   8(%rdi)
    mov  %r12,  16(%rdi)
    mov  %r13,  24(%rdi)
    mov  %r14,  32(%rdi)
    mov  %r15,  40(%rdi)
    lea  8(%rsp), %rax
    mov  %rax,  48(%rdi)
    mov  (%rsp), %rax
    mov  %rax,  56(%rdi)
    xor  %eax, %eax
    ret
end;

{ Restore the context saved in Buf and resume there, returning Val (or 1 if
  Val is 0, mirroring C longjmp). }
procedure _blaise_longjmp(Buf: Pointer; Val: Integer); assembler; nostackframe;
asm
    mov  %esi, %eax
    test %eax, %eax
    jnz  .Llj_nonzero
    inc  %eax
.Llj_nonzero:
    mov    (%rdi), %rbx
    mov   8(%rdi), %rbp
    mov  16(%rdi), %r12
    mov  24(%rdi), %r13
    mov  32(%rdi), %r14
    mov  40(%rdi), %r15
    mov  48(%rdi), %rsp
    jmp *56(%rdi)
end;

end.
