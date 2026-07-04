{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ memstresscore — the pthread producer/consumer allocator stress
  (concurrent-allocator-design.adoc, §The pthread stress, part of the
  P2 GO/NO-GO gate).

  N worker threads form a ring: each thread allocates blocks across all
  small size classes plus periodic large blocks, fills them with a
  self-describing pattern (size + seed stored in the first 8 bytes),
  and hands them to the next thread through a fixed mailbox of atomic
  slots.  Each thread also drains its own inbound mailbox, verifies the
  pattern and frees the block — a free that always executes on a thread
  other than the allocator (the foreign path).  A mailbox slot that is
  still busy makes the producer free its own fresh block locally, so the
  local fast path stays exercised too.

  Shared state is touched only through runtime.atomic primitives; the
  workers use no strings, no punit and no I/O, so the only cross-thread
  machinery under test is the allocator itself.

  Used by test_blaise_mem_mt.pas (bounded, suite-friendly run) and
  stress_blaise_mem_mt.pas (standalone long-running stress). }

unit memstresscore;

interface

{ Runs the ring stress with NThreads workers (clamped to 2..16), each
  performing Iters produce/consume iterations, then performs the
  terminal drain of every mailbox.  Returns the number of integrity
  failures (0 = clean); returns -1 if a worker thread could not be
  created. }
function RunMemStress(NThreads, Iters: Integer): Int64;

{ Counters from the most recent RunMemStress call. }
function StressAllocTotal: Int64;
function StressFreeTotal: Int64;
function StressAllocFails: Int64;
function StressBadCount: Int64;

implementation

uses
  runtime.mem, runtime.atomic, runtime.thread;

const
  MAXT = 16;
  SLOTS = 64;

type
  TThreadProc = procedure(Arg: Pointer);
  TMailRow = array[0..63] of Pointer;

var
  GMail: array[0..15] of TMailRow;
  GIdx: array[0..15] of Integer;
  GNThreads: Integer;
  GIters: Integer;
  GBad: Int64;
  GAllocFail: Int64;
  GAllocTotal: Int64;
  GFreeTotal: Int64;

{ Size schedule: every small class in rotation, with a periodic large
  block (4096..36864 bytes) so the large foreign-free path is hammered
  alongside the small remote-free queue. }
function PickSize(I: Integer): Integer;
begin
  if (I mod 61) = 0 then
    Result := 4096 + (I mod 5) * 8192
  else
    Result := 16 shl (I mod 8);
end;

{ Self-describing fill: bytes 0..3 hold the size, 4..7 the seed, the
  body up to 256 bytes holds (Seed + J) mod 256, and the final byte is
  patterned too when it lies beyond the checked prefix. }
procedure FillBlock(P: PChar; Sz, Seed: Integer);
var
  IP: ^Integer;
  J, Limit: Integer;
begin
  IP := Pointer(P);
  IP^ := Sz;
  IP := Pointer(PtrUInt(P) + 4);
  IP^ := Seed;
  Limit := Sz;
  if Limit > 256 then Limit := 256;
  for J := 8 to Limit - 1 do
    P[J] := (Seed + J) and $FF;
  if Sz - 1 >= Limit then
    P[Sz - 1] := (Seed + Sz - 1) and $FF;
end;

function CheckBlock(P: PChar): Boolean;
var
  IP: ^Integer;
  Sz, Seed, J, Limit: Integer;
begin
  IP := Pointer(P);
  Sz := IP^;
  IP := Pointer(PtrUInt(P) + 4);
  Seed := IP^;
  { A corrupt size field is itself an integrity failure — and must be
    range-checked before it is used as a read bound. }
  if (Sz < 16) or (Sz > 65536) then Exit(False);
  Limit := Sz;
  if Limit > 256 then Limit := 256;
  for J := 8 to Limit - 1 do
    if Integer(P[J]) <> ((Seed + J) and $FF) then Exit(False);
  if Sz - 1 >= Limit then
    if Integer(P[Sz - 1]) <> ((Seed + Sz - 1) and $FF) then Exit(False);
  Result := True;
end;

procedure StressWorker(Arg: Pointer);
var
  IdxP: ^Integer;
  Idx, Target, I, S, Sz, Seed: Integer;
  P: PChar;
  Q: Pointer;
begin
  IdxP := Arg;
  Idx := IdxP^;
  Target := Idx + 1;
  if Target >= GNThreads then Target := 0;
  for I := 0 to GIters - 1 do
  begin
    { Consume one inbound slot: verify the pattern written by the
      producing thread, then free — a foreign free by construction. }
    S := I mod SLOTS;
    Q := _AtomicXchgPtr(@GMail[Idx][S], nil);
    if Q <> nil then
    begin
      if not CheckBlock(PChar(Q)) then
        _AtomicAddInt64(@GBad, 1);
      _BlaiseFreeMem(Q);
      _AtomicAddInt64(@GFreeTotal, 1);
    end;
    { Produce one block and hand it to the next thread in the ring. }
    Sz := PickSize(I + Idx * 7);
    P := PChar(_BlaiseGetMem(Sz));
    if P = nil then
      _AtomicAddInt64(@GAllocFail, 1)
    else
    begin
      _AtomicAddInt64(@GAllocTotal, 1);
      Seed := (Idx shl 20) + I;
      FillBlock(P, Sz, Seed);
      if not _AtomicCASPtr(@GMail[Target][S], nil, Pointer(P)) then
      begin
        { Slot still busy — free the fresh block locally instead, which
          keeps the local fast path exercised under the same load. }
        _BlaiseFreeMem(Pointer(P));
        _AtomicAddInt64(@GFreeTotal, 1);
      end;
    end;
  end;
end;

function RunMemStress(NThreads, Iters: Integer): Int64;
var
  H: array[0..15] of Int64;
  I, S, Rc: Integer;
  Fn: TThreadProc;
  Q: Pointer;
begin
  if NThreads > MAXT then NThreads := MAXT;
  if NThreads < 2 then NThreads := 2;
  GNThreads := NThreads;
  GIters := Iters;
  GBad := 0;
  GAllocFail := 0;
  GAllocTotal := 0;
  GFreeTotal := 0;
  for I := 0 to MAXT - 1 do
    for S := 0 to SLOTS - 1 do
      GMail[I][S] := nil;

  Fn := @StressWorker;
  for I := 0 to NThreads - 1 do
  begin
    GIdx[I] := I;
    H[I] := 0;
    Rc := pthread_create(@H[I], nil, Pointer(Fn), Pointer(@GIdx[I]));
    if Rc <> 0 then Exit(-1);
  end;
  for I := 0 to NThreads - 1 do
    pthread_join(H[I], nil);

  { Terminal drain: every block still in flight is verified and freed
    by the main thread.  After this, allocated = freed or the run leaked. }
  for I := 0 to NThreads - 1 do
    for S := 0 to SLOTS - 1 do
    begin
      Q := _AtomicXchgPtr(@GMail[I][S], nil);
      if Q <> nil then
      begin
        if not CheckBlock(PChar(Q)) then
          _AtomicAddInt64(@GBad, 1);
        _BlaiseFreeMem(Q);
        _AtomicAddInt64(@GFreeTotal, 1);
      end;
    end;
  Result := GBad;
end;

function StressAllocTotal: Int64;
begin
  Result := GAllocTotal;
end;

function StressFreeTotal: Int64;
begin
  Result := GFreeTotal;
end;

function StressAllocFails: Int64;
begin
  Result := GAllocFail;
end;

function StressBadCount: Int64;
begin
  Result := GBad;
end;

end.
