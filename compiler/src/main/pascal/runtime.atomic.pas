{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.atomic;

// Atomic 32-bit add/sub primitives used by ARC reference counting.
//
// Inline-assembler port of runtime/src/main/asm/blaise_atomic_x86_64.s — the
// bodies are now `asm … end` routines in this Pascal unit so the RTL builds
// with Blaise's own internal assembler and needs no hand-written .s file
// (docs/inline-asm-design.adoc, §"Migration of the .s files").
//
// Each returns the PREVIOUS value at Ptr (xadd semantics).  System V AMD64:
// arg1 Ptr -> %rdi, arg2 Delta -> %esi; the 32-bit result is returned in %eax.
// `nostackframe` lets the asm body own the frame so the registers hold the
// raw incoming arguments.

interface

{ Ptr addresses a 32-bit integer.  Typed as Pointer (not a `PInteger` alias) so
  this unit does not export a type name that collides with the same alias in
  other RTL units when they are compiled together (e.g. blaise_arc's PInteger).
  The body reads/writes through %rdi regardless of the Pascal pointer type. }
function _AtomicAddInt32(Ptr: Pointer; Delta: Integer): Integer;
function _AtomicSubInt32(Ptr: Pointer; Delta: Integer): Integer;

implementation

{ return *Ptr (old); *Ptr += Delta — atomically. }
function _AtomicAddInt32(Ptr: Pointer; Delta: Integer): Integer;
  assembler; nostackframe;
asm
    movl %esi, %eax
    lock xaddl %eax, (%rdi)
    ret
end;

{ return *Ptr (old); *Ptr -= Delta — atomically (xadd of the negated delta). }
function _AtomicSubInt32(Ptr: Pointer; Delta: Integer): Integer;
  assembler; nostackframe;
asm
    negl %esi
    movl %esi, %eax
    lock xaddl %eax, (%rdi)
    ret
end;

end.
