{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.setjmp.arm64;

// setjmp/longjmp for the exception runtime — the AArch64 twin of
// runtime.setjmp (x86-64).  Selected by filename in BuildRTLUnitList for
// arm64 targets; same flat symbol names.
//
// jmp_buf layout (168 bytes used; the RTL contract reserves 512 in every
// exception frame, so there is ample headroom):
//   x19..x28  at   0..72   (callee-saved GPRs)
//   x29 (fp)  at  80
//   x30 (lr)  at  88       (doubles as the resume address)
//   sp        at  96
//   d8..d15   at 104..160  (callee-saved FP low halves)
//
// AAPCS64: Buf -> x0, Val -> w1.  Both routines own their frame
// (`nostackframe`): _blaise_setjmp must capture the CALLER's sp/lr, and
// _blaise_longjmp restores sp and returns through the saved lr, so a
// compiler-generated prologue must not intervene.

interface

function  _blaise_setjmp(Buf: Pointer): Integer;
procedure _blaise_longjmp(Buf: Pointer; Val: Integer);

implementation

{ Save the machine context into Buf; returns 0 on the direct call. }
function _blaise_setjmp(Buf: Pointer): Integer; assembler; nostackframe;
asm
    stp x19, x20, [x0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
    mov x9, sp
    str x9, [x0, #96]
    str d8, [x0, #104]
    str d9, [x0, #112]
    str d10, [x0, #120]
    str d11, [x0, #128]
    str d12, [x0, #136]
    str d13, [x0, #144]
    str d14, [x0, #152]
    str d15, [x0, #160]
    movz x0, #0
    ret
end;

{ Restore the context saved in Buf and resume there, returning Val (or 1 if
  Val is 0, mirroring C longjmp).  The final ret goes through the RESTORED
  x30 — control resumes just after the original _blaise_setjmp call. }
procedure _blaise_longjmp(Buf: Pointer; Val: Integer); assembler; nostackframe;
asm
    ldp x19, x20, [x0]
    ldp x21, x22, [x0, #16]
    ldp x23, x24, [x0, #32]
    ldp x25, x26, [x0, #48]
    ldp x27, x28, [x0, #64]
    ldp x29, x30, [x0, #80]
    ldr x9, [x0, #96]
    mov sp, x9
    ldr d8, [x0, #104]
    ldr d9, [x0, #112]
    ldr d10, [x0, #120]
    ldr d11, [x0, #128]
    ldr d12, [x0, #136]
    ldr d13, [x0, #144]
    ldr d14, [x0, #152]
    ldr d15, [x0, #160]
    mov x0, x1
    cbnz x0, .Llj_nonzero
    movz x0, #1
.Llj_nonzero:
    ret
end;

end.
