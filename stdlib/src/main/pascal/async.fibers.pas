{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit async.fibers;

// L1 of the fiber runtime (docs/async-networking-design.adoc, [#scheduler]):
// the single-worker scheduler and its intrinsic structures — the intrusive
// FIFO run queue and the 4-ary timer min-heap keyed by absolute monotonic
// deadline.
//
// The worker state (run queue, timer heap, current task, the scheduler's own
// L0 context) lives in a TWorker object so the multicore step (N workers,
// Chase-Lev work-stealing deques, a global injector queue) extends this
// module by adding workers rather than reworking it; at L1 there is exactly
// one worker, driven by RunScheduler on the calling thread.
//
// Per the design, the run queue link (NextReady) and the timer-heap slot
// (HeapIndex) are intrusive fields on the task itself — no per-operation
// allocation on the scheduling hot path.  The heap is 4-ary: shallower than
// a binary heap for the same size, and sift-down touches one cache line of
// children per level.
//
// NATIVE BACKEND ONLY: this unit uses async.fibers.context.x86_64, whose
// context-switch leaf is inline asm; the QBE backend rejects it with a clear
// diagnostic (the design's compile-time guard).
//
// Clock and idle-sleep bindings are Linux-shaped libc calls
// (clock_gettime/nanosleep), the same posture as the context unit's mmap
// bindings.

interface

uses
  SysUtils, generics.collections, async.fibers.context.x86_64;

type
  { Raised at a suspension point inside a fiber that has been cancelled via
    FiberCancel, so cleanup runs through normal try/finally on the fiber's
    own stack (design [#scheduler-cancellation]). }
  EFiberCancelled = class(Exception)
  end;

  { Lifecycle of a scheduled fiber.
      fsReady     — in the run queue, waiting for the worker
      fsRunning   — currently executing on the worker
      fsSleeping  — parked in the timer heap (FiberSleep)
      fsDone      — entry procedure returned normally
      fsFailed    — entry procedure left via an unhandled exception; the
                    root frame contained it (FailMessage holds the message)
      fsCancelled — unwound via an unhandled EFiberCancelled }
  TFiberState = (fsReady, fsRunning, fsSleeping, fsDone, fsFailed,
    fsCancelled);

  { Control block of one scheduled fiber.  Returned by SpawnFiber as the
    fiber's handle; remains valid (queryable) after the fiber completes,
    until ResetScheduler.  NextReady and HeapIndex are the intrusive run-
    queue link and timer-heap slot. }
  TFiberTask = class
  public
    Fib: PFiber;             { L0 control block; nil once the fiber is done }
    Proc: TFiberProc;
    Arg: Pointer;
    State: TFiberState;
    NextReady: TFiberTask;   { intrusive FIFO link (run queue) }
    Deadline: Int64;         { absolute CLOCK_MONOTONIC ns, when fsSleeping }
    HeapIndex: Integer;      { slot in the timer heap; -1 when not queued }
    Cancelled: Boolean;
    FailMessage: string;     { set by the root frame on fsFailed/fsCancelled }
    constructor Create;
  end;

  { Intrusive FIFO run queue: the single worker pushes woken/spawned tasks at
    the tail and pops at the head.  The multicore step replaces this with a
    Chase-Lev deque per worker; the interface (Push/Pop) is the part the
    scheduler loop depends on. }
  TRunQueue = class
  private
    FHead: TFiberTask;
    FTail: TFiberTask;
    FCount: Integer;
  public
    procedure Push(ATask: TFiberTask);
    function Pop: TFiberTask;
    property Count: Integer read FCount;
  end;

  { 4-ary min-heap over TFiberTask.Deadline (absolute monotonic ns).  Serves
    FiberSleep now, I/O deadlines and scope timeouts later.  Remove supports
    cancellation of a sleeping fiber in O(depth) via the intrusive
    HeapIndex. }
  TTimerHeap = class
  private
    FItems: TList<TFiberTask>;
    procedure SiftUp(AIdx: Integer);
    procedure SiftDown(AIdx: Integer);
    function GetCount: Integer;
  public
    constructor Create;
    procedure Push(ATask: TFiberTask);
    function PeekMin: TFiberTask;
    function PopMin: TFiberTask;
    procedure Remove(ATask: TFiberTask);
    property Count: Integer read GetCount;
  end;

{ Current CLOCK_MONOTONIC time in nanoseconds (the timer-heap key space). }
function MonotonicNowNs: Int64;

implementation

{ Linux-shaped libc bindings (same posture as the context unit's mmap set). }
function _libc_clock_gettime(AClockId: Integer; ATs: Pointer): Integer;
  external name 'clock_gettime';

const
  CLOCK_MONOTONIC = 1;

type
  TTimeSpec = record
    Sec: Int64;
    NSec: Int64;
  end;

function MonotonicNowNs: Int64;
var
  Ts: TTimeSpec;
begin
  Ts.Sec := 0;
  Ts.NSec := 0;
  _libc_clock_gettime(CLOCK_MONOTONIC, @Ts);
  Result := Ts.Sec * Int64(1000000000) + Ts.NSec;
end;

{ ---------------------------------------------------------------------------
  TFiberTask
  --------------------------------------------------------------------------- }

constructor TFiberTask.Create;
begin
  Self.HeapIndex := -1;
  Self.State := fsReady;
end;

{ ---------------------------------------------------------------------------
  TRunQueue — intrusive FIFO
  --------------------------------------------------------------------------- }

procedure TRunQueue.Push(ATask: TFiberTask);
begin
  ATask.NextReady := nil;
  if Self.FTail = nil then
  begin
    Self.FHead := ATask;
    Self.FTail := ATask;
  end
  else
  begin
    Self.FTail.NextReady := ATask;
    Self.FTail := ATask;
  end;
  Self.FCount := Self.FCount + 1;
end;

function TRunQueue.Pop: TFiberTask;
var
  T: TFiberTask;
begin
  T := Self.FHead;
  if T = nil then
    Exit(nil);
  Self.FHead := T.NextReady;
  if Self.FHead = nil then
    Self.FTail := nil;
  T.NextReady := nil;
  Self.FCount := Self.FCount - 1;
  Result := T;
end;

{ ---------------------------------------------------------------------------
  TTimerHeap — 4-ary min-heap keyed by Deadline
  --------------------------------------------------------------------------- }

constructor TTimerHeap.Create;
begin
  Self.FItems := TList<TFiberTask>.Create();
end;

function TTimerHeap.GetCount: Integer;
begin
  Result := Self.FItems.Count;
end;

procedure TTimerHeap.SiftUp(AIdx: Integer);
var
  Item: TFiberTask;
  Parent: TFiberTask;
  ParentIdx: Integer;
begin
  Item := Self.FItems[AIdx];
  while AIdx > 0 do
  begin
    ParentIdx := (AIdx - 1) div 4;
    Parent := Self.FItems[ParentIdx];
    if Parent.Deadline <= Item.Deadline then
      Break;
    Self.FItems[AIdx] := Parent;
    Parent.HeapIndex := AIdx;
    AIdx := ParentIdx;
  end;
  Self.FItems[AIdx] := Item;
  Item.HeapIndex := AIdx;
end;

procedure TTimerHeap.SiftDown(AIdx: Integer);
var
  Item: TFiberTask;
  Child: TFiberTask;
  N, First, Best, I: Integer;
begin
  Item := Self.FItems[AIdx];
  N := Self.FItems.Count;
  while True do
  begin
    First := AIdx * 4 + 1;
    if First >= N then
      Break;
    Best := First;
    I := First + 1;
    while (I < N) and (I <= First + 3) do
    begin
      if Self.FItems[I].Deadline < Self.FItems[Best].Deadline then
        Best := I;
      I := I + 1;
    end;
    Child := Self.FItems[Best];
    if Item.Deadline <= Child.Deadline then
      Break;
    Self.FItems[AIdx] := Child;
    Child.HeapIndex := AIdx;
    AIdx := Best;
  end;
  Self.FItems[AIdx] := Item;
  Item.HeapIndex := AIdx;
end;

procedure TTimerHeap.Push(ATask: TFiberTask);
begin
  Self.FItems.Add(ATask);
  ATask.HeapIndex := Self.FItems.Count - 1;
  Self.SiftUp(Self.FItems.Count - 1);
end;

function TTimerHeap.PeekMin: TFiberTask;
begin
  if Self.FItems.Count = 0 then
    Exit(nil);
  Result := Self.FItems[0];
end;

function TTimerHeap.PopMin: TFiberTask;
begin
  Result := Self.PeekMin();
  if Result <> nil then
    Self.Remove(Result);
end;

procedure TTimerHeap.Remove(ATask: TFiberTask);
var
  Idx, LastIdx: Integer;
  Last: TFiberTask;
begin
  Idx := ATask.HeapIndex;
  if Idx < 0 then
    Exit;
  LastIdx := Self.FItems.Count - 1;
  Last := Self.FItems[LastIdx];
  Self.FItems.Delete(LastIdx);
  ATask.HeapIndex := -1;
  if Idx <= LastIdx - 1 then
  begin
    Self.FItems[Idx] := Last;
    Last.HeapIndex := Idx;
    Self.SiftDown(Idx);
    Self.SiftUp(Idx);
  end;
end;

end.
