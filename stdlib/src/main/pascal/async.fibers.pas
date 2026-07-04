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

  { Per-worker scheduler state.  L1 has exactly one worker, driven by
    RunScheduler on the calling thread; the multicore step adds N of these
    (each on its own OS thread, with a stealing deque and a shared injector
    queue) without changing the fields the loop depends on. }
  TWorker = class
  public
    RunQ: TRunQueue;
    Timers: TTimerHeap;
    SchedFib: PFiber;         { the scheduler loop's own L0 context }
    Current: TFiberTask;      { task executing on this worker; nil in the loop }
    Tasks: TList<TFiberTask>; { every spawned task; keeps handles valid }
    LiveCount: Integer;       { spawned and not yet finished }
    Running: Boolean;         { re-entrancy guard for RunScheduler }
    constructor Create;
  end;

{ Spawn AProc(AArg) as a scheduled fiber on the current worker.  The fiber
  runs when RunScheduler drives the run queue (spawning never switches).
  AStackSize is the usable stack in bytes (0 = FiberDefaultStackSize).  The
  returned handle stays valid after completion — State/FailMessage remain
  queryable until ResetScheduler. }
function SpawnFiber(AProc: TFiberProc; AArg: Pointer;
  AStackSize: Int64 = 0): TFiberTask;

{ Run the scheduler loop on the calling thread until every spawned fiber has
  finished (fsDone/fsFailed/fsCancelled).  When no fiber is ready the worker
  sleeps until the nearest timer deadline — it never busy-waits. }
procedure RunScheduler;

{ Cooperatively give up the worker: requeue the current fiber at the tail of
  the run queue and switch to the scheduler.  Off-scheduler (not inside a
  spawned fiber) it is a no-op. }
procedure FiberYield;

{ Park the current fiber in the timer heap for AMillis milliseconds; the
  scheduler runs other fibers meanwhile and requeues this one when the
  deadline fires.  Off-scheduler it degrades to a plain blocking OS sleep
  (the same blocking-fallback posture the design gives L3 fiber I/O). }
procedure FiberSleep(AMillis: Int64);

{ Request cancellation of a fiber (design [#scheduler-cancellation]).  Sets
  the task's Cancelled flag; if the fiber is parked in the timer heap it is
  woken immediately.  The fiber observes cancellation at its next (or
  current) suspension point, where EFiberCancelled is raised so cleanup runs
  through normal try/finally on its own stack.  A fiber that never suspends
  again simply runs to completion.  Cancelling a finished fiber is a no-op. }
procedure FiberCancel(ATask: TFiberTask);

{ Number of spawned fibers that have not yet finished. }
function SchedulerLiveCount: Integer;

{ Drop all task handles and the worker state so a fresh scheduling round
  starts clean.  Only legal when the scheduler is not running and no fiber
  is still live. }
procedure ResetScheduler;

{ Current CLOCK_MONOTONIC time in nanoseconds (the timer-heap key space). }
function MonotonicNowNs: Int64;

implementation

{ Linux-shaped libc bindings (same posture as the context unit's mmap set). }
function _libc_clock_gettime(AClockId: Integer; ATs: Pointer): Integer;
  external name 'clock_gettime';
function _libc_nanosleep(AReq, ARem: Pointer): Integer;
  external name 'nanosleep';

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

{ ---------------------------------------------------------------------------
  The worker and the scheduler loop
  --------------------------------------------------------------------------- }

constructor TWorker.Create;
begin
  Self.RunQ := TRunQueue.Create();
  Self.Timers := TTimerHeap.Create();
  Self.Tasks := TList<TFiberTask>.Create();
end;

var
  GWorker: TWorker;

function NeedWorker: TWorker;
begin
  if GWorker = nil then
    GWorker := TWorker.Create();
  Result := GWorker;
end;

{ Blocking OS sleep (nanosleep).  An early EINTR return is harmless: the
  scheduler loop re-derives the remaining wait from the timer heap. }
procedure OsSleepNs(ANs: Int64);
var
  Ts: TTimeSpec;
begin
  if ANs <= 0 then
    Exit;
  Ts.Sec := ANs div Int64(1000000000);
  Ts.NSec := ANs mod Int64(1000000000);
  _libc_nanosleep(@Ts, nil);
end;

{ Entry wrapper every spawned fiber runs — the ROOT EXCEPTION FRAME.  A
  fresh fiber starts with an empty exception chain (P1), so before this
  frame existed an unhandled raise on a fiber aborted the whole process;
  now it unwinds to here, is recorded on the task handle, and the
  scheduler carries on with the other fibers.  An unhandled
  EFiberCancelled is the normal end of a cancelled fiber and is recorded
  as fsCancelled rather than a failure.  The current task is read from
  the worker — the scheduler sets Current before switching in. }
procedure SchedFiberEntry(AArg: Pointer);
var
  T: TFiberTask;
begin
  T := GWorker.Current;
  try
    T.Proc(T.Arg);
    T.State := fsDone;
  except
    on E: EFiberCancelled do
    begin
      T.State := fsCancelled;
      T.FailMessage := E.Message;
    end;
    on E: Exception do
    begin
      T.State := fsFailed;
      T.FailMessage := E.Message;
    end;
    else
    begin
      T.State := fsFailed;
      T.FailMessage := 'unhandled exception (not an Exception descendant)';
    end;
  end;
end;

function SpawnFiber(AProc: TFiberProc; AArg: Pointer;
  AStackSize: Int64): TFiberTask;
var
  W: TWorker;
  T: TFiberTask;
begin
  W := NeedWorker();
  T := TFiberTask.Create();
  T.Proc := AProc;
  T.Arg := AArg;
  T.Fib := FiberSpawn(@SchedFiberEntry, nil, AStackSize);
  if T.Fib = nil then
    raise Exception.Create('SpawnFiber: cannot map a fiber stack');
  W.Tasks.Add(T);
  W.LiveCount := W.LiveCount + 1;
  W.RunQ.Push(T);
  Result := T;
end;

procedure RunScheduler;
var
  W: TWorker;
  T: TFiberTask;
  NowNs: Int64;
begin
  W := NeedWorker();
  if W.Running then
    raise Exception.Create('RunScheduler: scheduler already running');
  if W.SchedFib = nil then
  begin
    if CurrentFiber() <> nil then
      W.SchedFib := CurrentFiber()
    else
      W.SchedFib := FiberCreateMain();
  end;
  W.Running := True;
  while W.LiveCount > 0 do
  begin
    { Move every due timer to the run queue. }
    NowNs := MonotonicNowNs();
    while (W.Timers.Count > 0) and (W.Timers.PeekMin().Deadline <= NowNs) do
    begin
      T := W.Timers.PopMin();
      T.State := fsReady;
      W.RunQ.Push(T);
    end;
    T := W.RunQ.Pop();
    if T = nil then
    begin
      if W.Timers.Count = 0 then
      begin
        { No ready fiber, no timer, yet fibers are live: nothing can wake
          them on a single worker.  Unreachable through the public L1 API
          (the only park is FiberSleep); guard it loudly all the same. }
        W.Running := False;
        raise Exception.Create('RunScheduler: stalled - live fibers but ' +
          'nothing ready and no timers');
      end;
      { Never busy-wait: sleep until the nearest deadline. }
      OsSleepNs(W.Timers.PeekMin().Deadline - MonotonicNowNs());
      Continue;
    end;
    T.State := fsRunning;
    W.Current := T;
    FiberSwitch(W.SchedFib, T.Fib);
    W.Current := nil;
    if FiberIsDone(T.Fib) then
    begin
      W.LiveCount := W.LiveCount - 1;
      FiberFree(T.Fib);       { stack back to the pool }
      T.Fib := nil;
    end;
  end;
  W.Running := False;
end;

procedure FiberYield;
var
  W: TWorker;
  T: TFiberTask;
begin
  W := GWorker;
  if W = nil then
    Exit;
  T := W.Current;
  if T = nil then
    Exit;                     { off-scheduler: no-op }
  T.State := fsReady;
  W.RunQ.Push(T);
  FiberSwitch(T.Fib, W.SchedFib);
end;

procedure FiberSleep(AMillis: Int64);
var
  W: TWorker;
  T: TFiberTask;
begin
  W := GWorker;
  if W <> nil then
    T := W.Current
  else
    T := nil;
  if T = nil then
  begin
    OsSleepNs(AMillis * Int64(1000000));   { blocking fallback off-scheduler }
    Exit;
  end;
  { A suspension point observes cancellation (design: the fiber-aware call
    raises EFiberCancelled at the suspension point, so cleanup runs through
    normal try/finally) — both when already flagged on entry and when
    cancelled while parked. }
  if T.Cancelled then
    raise EFiberCancelled.Create('fiber cancelled');
  if AMillis <= 0 then
  begin
    FiberYield();
    Exit;
  end;
  T.Deadline := MonotonicNowNs() + AMillis * Int64(1000000);
  T.State := fsSleeping;
  W.Timers.Push(T);
  FiberSwitch(T.Fib, W.SchedFib);
  if T.Cancelled then
    raise EFiberCancelled.Create('fiber cancelled');
end;

procedure FiberCancel(ATask: TFiberTask);
var
  W: TWorker;
begin
  if ATask = nil then
    Exit;
  if (ATask.State = fsDone) or (ATask.State = fsFailed) or
     (ATask.State = fsCancelled) then
    Exit;
  if ATask.Cancelled then
    Exit;
  ATask.Cancelled := True;
  W := GWorker;
  if W = nil then
    Exit;
  { Wake a parked fiber immediately: pull it out of the timer heap and
    requeue it; its FiberSleep raises EFiberCancelled on resume. }
  if ATask.State = fsSleeping then
  begin
    W.Timers.Remove(ATask);
    ATask.State := fsReady;
    W.RunQ.Push(ATask);
  end;
end;

function SchedulerLiveCount: Integer;
begin
  if GWorker = nil then
    Exit(0);
  Result := GWorker.LiveCount;
end;

procedure ResetScheduler;
begin
  if GWorker = nil then
    Exit;
  if GWorker.Running then
    raise Exception.Create('ResetScheduler: scheduler is running');
  if GWorker.LiveCount > 0 then
    raise Exception.Create('ResetScheduler: fibers still live');
  GWorker := nil;   { ARC cascades: task list, queue chain, heap entries }
end;

end.
