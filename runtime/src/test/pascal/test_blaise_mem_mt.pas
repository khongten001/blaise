{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ punit tests for the MULTI-THREADED allocator paths — the P2 acceptance
  tests from concurrent-allocator-design.adoc §Testing strategy:

    * the cross-thread free test (small blocks: allocate on the main
      thread, free on a worker, prove the blocks return to the owning
      arena's freelists by pointer identity);
    * the large-block foreign-free path (munmap on foreign free —
      option 2 of §The large-block remote path);
    * a bounded version of the pthread ring stress (memstresscore).

  Worker threads deliberately use NO punit asserts, NO strings and NO
  I/O: punit's counters are process-global and the string runtime would
  add allocator traffic outside the experiment.  Workers record results
  into plain shared globals; the main thread asserts after pthread_join.

  Build:
    blaise --source runtime/src/test/pascal/test_blaise_mem_mt.pas \
           --unit-path compiler/src/main/pascal \
           --unit-path runtime/src/test/pascal \
           --output /tmp/test_mem_mt
    /tmp/test_mem_mt -v
}

program test_blaise_mem_mt;

uses
  punit, runtime.mem, runtime.thread, memstresscore;

type
  TThreadProc = procedure(Arg: Pointer);

const
  NPerClass = 8;
  NClasses = 8;
  TotalBlocks = 64;    { NPerClass * NClasses }
  MaxPump = 8192;

var
  { Cross-thread small-free shared state (written by main, freed by B). }
  GBlocks: array[0..63] of Pointer;
  GSizes: array[0..63] of Integer;
  GBadPattern: Int64;
  GForeignLeak: Int64;
  GPump: array[0..8191] of Pointer;

  { Cross-thread large-free shared state. }
  GLargePtr: Pointer;
  GLargeSize: Integer;
  GLargeBadPattern: Int64;
  GLargeProbeMapped: Int64;
  GLargeProbeOk: Int64;

function ClassSize(C: Integer): Integer;
begin
  Result := 16 shl C;
end;

{ ------------------------------------------------------------------ }
{ Worker: free the main thread's small blocks (every free is foreign), }
{ then prove none of them landed on THIS thread's freelists.           }
{ ------------------------------------------------------------------ }
procedure SmallFreeWorker(Arg: Pointer);
var
  I, J: Integer;
  P: PChar;
  Q: Pointer;
begin
  GBadPattern := -1;
  for I := 0 to TotalBlocks - 1 do
  begin
    { Verify the pattern the main thread wrote — cross-thread read. }
    P := PChar(GBlocks[I]);
    for J := 0 to GSizes[I] - 1 do
      if Integer(P[J]) <> ((J + I) and $FF) then
      begin
        if GBadPattern = -1 then
          GBadPattern := Int64(I) * 100000 + Int64(J);
        Break;
      end;
    _BlaiseFreeMem(GBlocks[I]);
  end;
  { Control (design §Cross-thread free test, step 5): this thread never
    freed anything locally, so an allocation here must come from its own
    fresh arena — never from the foreign-freed set. }
  GForeignLeak := 0;
  for I := 0 to NClasses - 1 do
  begin
    Q := _BlaiseGetMem(ClassSize(I));
    for J := 0 to TotalBlocks - 1 do
      if Q = GBlocks[J] then
        GForeignLeak := GForeignLeak + 1;
    _BlaiseFreeMem(Q);
  end;
end;

{ ------------------------------------------------------------------ }
{ Test: allocate on main, free on worker, drain + reuse on main.       }
{ Leak check = every foreign-freed block is recycled back to the main  }
{ thread by pointer identity (returned to the owning arena, not lost   }
{ and not stranded on the worker).                                     }
{ ------------------------------------------------------------------ }
function Test_CrossThread_SmallFree: string;
var
  I, C, J, K, Sz, PumpCount, Rc, RcJoin, PumpNilFails: Integer;
  P: PChar;
  Q: Pointer;
  H: Int64;
  Fn: TThreadProc;
  Found: array[0..63] of Boolean;
  FoundPerClass: array[0..7] of Integer;
begin
  for C := 0 to NClasses - 1 do
    for I := 0 to NPerClass - 1 do
    begin
      K := C * NPerClass + I;
      Sz := ClassSize(C);
      GSizes[K] := Sz;
      P := PChar(_BlaiseGetMem(Sz));
      AssertNotNull('alloc class ' + IntToStr(C) + ' #' + IntToStr(I),
                    Pointer(P));
      for J := 0 to Sz - 1 do
        P[J] := (J + K) and $FF;
      GBlocks[K] := Pointer(P);
    end;

  Fn := @SmallFreeWorker;
  H := 0;
  { pthread calls hoisted out of assert argument positions — see the
    stack-alignment note in punit.pas / bugs.txt. }
  Rc := pthread_create(@H, nil, Pointer(Fn), nil);
  RcJoin := pthread_join(H, nil);

  { Drain + reuse: pump allocations of each class until every freed
    pointer has been handed back to THIS thread.  The empty-freelist
    head-arena drain and the arena-exhaustion drain-all guarantee
    progress; MaxPump bounds the walk (worst case: one full arena of
    the smallest class plus pre-existing freelist entries).

    IMPORTANT: the join -> pump window and the pump itself perform NO
    punit asserts and NO string operations.  Assert messages allocate
    small blocks, and a long-lived punit allocation that captures a
    drained test block would break the pointer-identity check.  All
    assertions run after the pump. }
  for K := 0 to TotalBlocks - 1 do
    Found[K] := False;
  PumpNilFails := 0;
  for C := 0 to NClasses - 1 do
  begin
    FoundPerClass[C] := 0;
    PumpCount := 0;
    while (FoundPerClass[C] < NPerClass) and (PumpCount < MaxPump) do
    begin
      Q := _BlaiseGetMem(ClassSize(C));
      if Q = nil then
      begin
        PumpNilFails := PumpNilFails + 1;
        Break;
      end;
      GPump[PumpCount] := Q;
      PumpCount := PumpCount + 1;
      for I := 0 to NPerClass - 1 do
      begin
        K := C * NPerClass + I;
        if (not Found[K]) and (Q = GBlocks[K]) then
        begin
          Found[K] := True;
          FoundPerClass[C] := FoundPerClass[C] + 1;
        end;
      end;
    end;
    for I := 0 to PumpCount - 1 do
      _BlaiseFreeMem(GPump[I]);
  end;

  AssertEquals('pthread_create', 0, Rc);
  AssertEquals('pthread_join', 0, RcJoin);
  AssertEquals('patterns intact when read on the freeing thread',
               Int64(-1), GBadPattern);
  AssertEquals('no foreign-freed block on the worker''s freelists',
               Int64(0), GForeignLeak);
  AssertEquals('pump allocations all succeeded', 0, PumpNilFails);
  for C := 0 to NClasses - 1 do
    AssertEquals('class ' + IntToStr(C)
                 + ': all foreign-freed blocks recycled to the owner',
                 NPerClass, FoundPerClass[C]);
  Result := '';
end;

{ ------------------------------------------------------------------ }
{ Worker: free the main thread's LARGE block (foreign), then prove the }
{ block was NOT captured by this thread's large LIFO cache.  The probe }
{ is the TotalMapped header field of a subsequent smaller allocation:  }
{ a fresh mmap maps exactly PageRound(24 + size) bytes, while a cache  }
{ hit would hand back the big foreign mapping (TotalMapped large).     }
{ Address identity is deliberately NOT used — the kernel readily       }
{ reuses a just-munmapped range for the next mmap.                     }
{ ------------------------------------------------------------------ }
procedure LargeFreeWorker(Arg: Pointer);
var
  P: PChar;
  Q: Pointer;
  I: Integer;
  MappedP: ^Int64;
begin
  P := PChar(GLargePtr);
  GLargeBadPattern := -1;
  I := 0;
  while I < GLargeSize do
  begin
    if Integer(P[I]) <> ((I * 7) and $FF) then
    begin
      GLargeBadPattern := I;
      Break;
    end;
    I := I + 997;
  end;

  _BlaiseFreeMem(GLargePtr);              { FOREIGN large free }

  { Probe: allocate a much smaller large block.  8192 + 24 rounds to
    12288 mapped bytes; a buggy cache capture would return the foreign
    256 KiB mapping instead. }
  Q := _BlaiseGetMem(8192);
  GLargeProbeOk := 0;
  if Q <> nil then
    GLargeProbeOk := 1;
  MappedP := Pointer(PtrUInt(Q) - 24);
  GLargeProbeMapped := MappedP^;
  _BlaiseFreeMem(Q);                       { local free — cached here }
end;

function Test_CrossThread_LargeFree: string;
var
  P: PChar;
  I, Rc: Integer;
  H: Int64;
  Fn: TThreadProc;
  Q: PChar;
begin
  GLargeSize := 262144;
  P := PChar(_BlaiseGetMem(GLargeSize));
  AssertNotNull('large alloc on main', Pointer(P));
  I := 0;
  while I < GLargeSize do
  begin
    P[I] := (I * 7) and $FF;
    I := I + 997;
  end;
  GLargePtr := Pointer(P);

  Fn := @LargeFreeWorker;
  H := 0;
  Rc := pthread_create(@H, nil, Pointer(Fn), nil);
  AssertEquals('pthread_create', 0, Rc);
  Rc := pthread_join(H, nil);
  AssertEquals('pthread_join', 0, Rc);

  AssertEquals('pattern intact when read on the freeing thread',
               Int64(-1), GLargeBadPattern);
  AssertEquals('worker probe alloc succeeded', Int64(1), GLargeProbeOk);
  AssertEquals('foreign large free munmaps — worker cache did not '
               + 'capture the foreign mapping',
               Int64(12288), GLargeProbeMapped);

  { The owner must still be fully functional afterwards. }
  Q := PChar(_BlaiseGetMem(GLargeSize));
  AssertNotNull('main can allocate large again', Pointer(Q));
  Q[0] := 42;
  Q[GLargeSize - 1] := 43;
  AssertEquals('new large block writable (first)', 42, Integer(Q[0]));
  AssertEquals('new large block writable (last)', 43,
               Integer(Q[GLargeSize - 1]));
  _BlaiseFreeMem(Pointer(Q));
  Result := '';
end;

{ ------------------------------------------------------------------ }
{ Test: bounded pthread ring stress (suite-friendly run of the P2      }
{ stress; the standalone long run lives in stress_blaise_mem_mt.pas).  }
{ ------------------------------------------------------------------ }
function Test_Stress_Bounded: string;
var
  Bad: Int64;
begin
  Bad := RunMemStress(4, 30000);
  AssertEquals('stress integrity failures', Int64(0), Bad);
  AssertEquals('stress allocation failures', Int64(0), StressAllocFails());
  AssertTrue('stress performed allocations', StressAllocTotal() > 0);
  AssertEquals('terminal drain balances: allocated = freed',
               StressAllocTotal(), StressFreeTotal());
  Result := '';
end;

begin
  AddSuite('blaise_mem_mt', nil);
  AddTest('CrossThread_SmallFree', @Test_CrossThread_SmallFree, 'blaise_mem_mt');
  AddTest('CrossThread_LargeFree', @Test_CrossThread_LargeFree, 'blaise_mem_mt');
  AddTest('Stress_Bounded', @Test_Stress_Bounded, 'blaise_mem_mt');
  RunAllSysTests();
end.
