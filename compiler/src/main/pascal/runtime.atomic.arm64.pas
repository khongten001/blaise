{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.atomic.arm64;

// Atomic primitives for ARC reference counting and the migration-safe
// allocator — the AArch64 twin of runtime.atomic (x86-64).  Selected by
// filename in BuildRTLUnitList for arm64 targets; same flat symbol names.
//
// All bodies use the LSE atomics (ldaddal/swpal/casal, acquire+release):
// every Apple Silicon CPU implements LSE, and the macOS arm64 target is the
// only consumer of this unit today.  A load/store-exclusive fallback for
// pre-8.1 cores can be added if a non-Apple arm64 target ever lands.
//
// AAPCS64: arg1 -> x0, arg2 -> x1, arg3 -> x2; results in w0/x0.
// `nostackframe` lets each asm body own the frame so the registers hold the
// raw incoming arguments.

interface

{ Ptr addresses a 32-bit integer.  Returns the PREVIOUS value (xadd
  semantics), matching the x86-64 unit. }
function _AtomicAddInt32(Ptr: Pointer; Delta: Integer): Integer;
function _AtomicSubInt32(Ptr: Pointer; Delta: Integer): Integer;

{ Pointer-width primitives for the allocator's remote-free queue.
  All operate on a 64-bit word at Ptr^. }

{ If Ptr^ = Expected, set Ptr^ := NewVal and return True; else False. }
function _AtomicCASPtr(Ptr: Pointer; Expected, NewVal: Pointer): Boolean;

{ Store NewVal into Ptr^ and return the previous value. }
function _AtomicXchgPtr(Ptr: Pointer; NewVal: Pointer): Pointer;

{ Atomic fetch-and-add of a 64-bit word; return the PREVIOUS value. }
function _AtomicAddInt64(Ptr: Pointer; Delta: Int64): Int64;

implementation

{ return *Ptr (old); *Ptr += Delta — atomically.  ldaddal is a full
  acquire+release barrier, matching x86's implicitly-locked xadd. }
function _AtomicAddInt32(Ptr: Pointer; Delta: Integer): Integer;
  assembler; nostackframe;
asm
    ldaddal w1, w2, [x0]
    mov w0, w2
    ret
end;

{ return *Ptr (old); *Ptr -= Delta — atomically (ldaddal of the negation). }
function _AtomicSubInt32(Ptr: Pointer; Delta: Integer): Integer;
  assembler; nostackframe;
asm
    neg w1, w1
    ldaddal w1, w2, [x0]
    mov w0, w2
    ret
end;

{ casal compares [x0] with x1 and stores x2 on match; x1 receives the OLD
  value either way, so success = (old = expected-as-saved). }
function _AtomicCASPtr(Ptr: Pointer; Expected, NewVal: Pointer): Boolean;
  assembler; nostackframe;
asm
    mov x9, x1
    casal x1, x2, [x0]
    cmp x1, x9
    cset x0, eq
    ret
end;

{ swpal swaps x1 into [x0] and returns the old value in x9 — a full
  barrier, so the drain's claim gets its acquire semantics for free. }
function _AtomicXchgPtr(Ptr: Pointer; NewVal: Pointer): Pointer;
  assembler; nostackframe;
asm
    swpal x1, x9, [x0]
    mov x0, x9
    ret
end;

{ 64-bit sibling of _AtomicAddInt32 — return *Ptr (old); *Ptr += Delta. }
function _AtomicAddInt64(Ptr: Pointer; Delta: Int64): Int64;
  assembler; nostackframe;
asm
    ldaddal x1, x9, [x0]
    mov x0, x9
    ret
end;

end.
