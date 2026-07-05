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
  SysUtils, generics.collections, async.fibers.context.x86_64,
  async.deque;

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
    fsCancelled, fsBlocked);

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
    { Park handshake word (async.sync park/resume): PK_RUNNING/PK_PARKING/
      PK_PARKED/PK_NOTIFIED.  POINTER-WIDTH (Int64) because the atomic CAS on it
      goes through _AtomicCASPtr, which operates on a full 64-bit word — a
      32-bit field would let the adjacent field's bytes into the comparison and
      the CAS would never match (a real bug that caused a hot-spin livelock). }
    ParkState: Int64;
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
    { Raw heap-array access (unordered) — used by the multicore worker loop to
      scan for cancelled sleepers.  0 <= AIdx < Count. }
    function HeapItem(AIdx: Integer): TFiberTask;
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

    { --- multicore fields (L1 multicore; single-worker path ignores them) --- }
    Id: Integer;              { index into GWorkers }
    Deque: TWorkStealDeque;   { per-worker Chase-Lev run queue (owner = this) }
    Handoff: TFiberTask;      { LIFO hand-off slot for a just-woken fiber }
    ParkWord: Integer;        { futex word: 0 = may sleep, 1 = wake pending }
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

{ ------------------------------------------------------------------------- }
{ L1 MULTICORE (docs/async-networking-design.adoc, [#scheduler])            }
{ ------------------------------------------------------------------------- }

{ Run the scheduler across ANumWorkers OS threads until every spawned fiber
  has finished.  ANumWorkers <= 0 defaults to GetCPUCount.  Worker 0 runs on
  the calling thread; workers 1..N-1 each get their own pthread.

  Scheduling per worker follows the design: LIFO hand-off slot -> local
  Chase-Lev deque (PopBottom) -> steal from a random peer -> global injector
  queue.  Idle workers PARK on a futex (never busy-wait) and are woken when a
  task is handed to them or spawned into the injector.

  Fibers spawned with SpawnFiber from inside a worker land on that worker's
  local deque; spawns from outside any worker go to the global injector.

  The leak tracker is a lockless global table and is SUSPENDED for the whole
  run (N>1), then restored — running it under concurrent create/release would
  corrupt it (design <<rtl-prerequisites>>).  Existing single-worker
  RunScheduler is unchanged and does not touch the tracker. }
procedure RunSchedulerMC(ANumWorkers: Integer = 0);

{ True while a multicore run is active (RunSchedulerMC is on the stack). }
function SchedulerIsMulticore: Boolean;

{ ------------------------------------------------------------------------- }
{ Park / resume — the primitive the fiber-aware sync objects build on        }
{ ------------------------------------------------------------------------- }

{ The task currently running on this worker (nil off any scheduler).  A
  fiber-aware sync primitive records this before parking so a waker can
  resume it. }
function CurrentFiberTask: TFiberTask;

{ Park the CURRENT fiber: mark it fsBlocked and switch to the scheduler
  WITHOUT enqueuing it anywhere.  It stays off every run queue until a
  matching FiberResume.  The caller (a sync primitive) must have already
  recorded the current task (CurrentFiberTask) on its wait list under its own
  lock, so a concurrent FiberResume can find it.  Off-scheduler it is a
  no-op (returns immediately) — callers must handle the non-fiber path
  themselves (e.g. a blocking OS wait).  Observes cancellation on resume:
  raises EFiberCancelled if the task was cancelled while parked. }
procedure FiberParkCurrent;

{ Make a parked (fsBlocked) fiber runnable again: push it to a run queue and
  wake a worker.  Safe to call from any worker thread or the main thread.  A
  task that is not fsBlocked is ignored (idempotent against double-resume). }
procedure FiberResume(ATask: TFiberTask);

implementation

uses
  runtime.atomic, runtime.thread;

{ Linux-shaped libc bindings (same posture as the context unit's mmap set). }
function _libc_clock_gettime(AClockId: Integer; ATs: Pointer): Integer;
  external name 'clock_gettime';
function _libc_nanosleep(AReq, ARem: Pointer): Integer;
  external name 'nanosleep';

{ Raw Linux futex(2) via libc's syscall(3) — the park/wake primitive for idle
  workers.  We use the private-futex ops.  syscall returns 0 / a wake count on
  success or -1 (with errno) on error; the scheduler ignores the result (a
  spurious wake just re-checks the run queues). }
function _libc_syscall6(ANum: Int64; A1, A2, A3, A4, A5, A6: Int64): Int64;
  external name 'syscall';

{ Exception-state and leak-tracker hooks from the RTL. }
function _LeakTrackerSuspend: Boolean; external name '_LeakTrackerSuspend';
procedure _LeakTrackerResume(APrev: Boolean);
  external name '_LeakTrackerResume';

const
  SYS_futex = 202;             { x86-64 }
  FUTEX_WAIT_PRIVATE = 128;    { FUTEX_WAIT | FUTEX_PRIVATE_FLAG }
  FUTEX_WAKE_PRIVATE = 129;    { FUTEX_WAKE | FUTEX_PRIVATE_FLAG }

const
  CLOCK_MONOTONIC = 1;

{ Park handshake states (async.sync park/resume).  A cross-thread waker must
  never enqueue a task while its fiber is still executing on its own stack
  (between committing to park and the FiberSwitch that saves the context) —
  that is two threads on one stack.  The four states serialise ownership of the
  wake:
    PK_RUNNING(0)  — not parking.
    PK_PARKING(1)  — the fiber set fsBlocked and is switching away; its context
                     is NOT yet safely saved.
    PK_PARKED(2)   — the owning worker confirmed the switch completed; the task
                     is off every run queue and safe to enqueue.
    PK_NOTIFIED(3) — a waker fired; whoever owns the transition enqueues it. }
  PK_RUNNING  = 0;
  PK_PARKING  = 1;
  PK_PARKED   = 2;
  PK_NOTIFIED = 3;

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
  Self.ParkState := 0;
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

function TTimerHeap.HeapItem(AIdx: Integer): TFiberTask;
begin
  Result := Self.FItems[AIdx];
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
  Self.Id := 0;
  Self.Deque := nil;         { created lazily by the multicore path }
  Self.Handoff := nil;
  Self.ParkWord := 0;
end;

type
  TWorkerArray = array of TWorker;

var
  GWorker: TWorker;         { the single-worker (RunScheduler) worker }

  { --- multicore global state (see the MULTICORE section below) --- }
  GMulticore: Boolean;
  GWorkers: TWorkerArray;
  GNumWorkers: Integer;
  GGlobalLive: Integer;        { atomic: fibers spawned and not yet finished }
  GStop: Integer;              { atomic: 1 tells every worker to exit }
  GInjectorHead: TFiberTask;   { global injector FIFO head (TFiberTask.NextReady) }
  GInjectorTail: TFiberTask;   { global injector FIFO tail }
  GInjectorMtx: array[0..5] of Int64;  { guards the injector FIFO }
  GAllTasks: TList<TFiberTask>;{ keeps every handle alive; guarded by GTaskMtx }
  GTaskMtx: array[0..5] of Int64;   { pthread_mutex_t buffer }
  GCancelGen: Integer;         { atomic: bumped on every FiberCancel }

threadvar
  { The worker whose scheduler loop is running on THIS OS thread.  Set by each
    multicore worker thread at start-up; nil off any worker thread.  The single
    -worker RunScheduler path leaves this nil and uses GWorker directly. }
  GTLWorker: TWorker;

{ The worker the fiber-facing calls (SpawnFiber/FiberYield/FiberSleep/
  FiberCancel) act on: this thread's multicore worker if any, else the single
  -worker GWorker. }
function CurrentWorker: TWorker;
begin
  if GTLWorker <> nil then
    Result := GTLWorker
  else
    Result := GWorker;
end;

function NeedWorker: TWorker;
begin
  if GTLWorker <> nil then
    Exit(GTLWorker);
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
{ Forward declarations for the multicore helpers used by the fiber-facing
  calls above their definitions in the MULTICORE section below. }
procedure McRegisterTask(AW: TWorker; ATask: TFiberTask); forward;
procedure McSubmitReady(AW: TWorker; ATask: TFiberTask); forward;
procedure McRequestCancelWake(ATask: TFiberTask); forward;

procedure SchedFiberEntry(AArg: Pointer);
var
  T: TFiberTask;
begin
  T := CurrentWorker().Current;
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
  T := TFiberTask.Create();
  T.Proc := AProc;
  T.Arg := AArg;
  T.Fib := FiberSpawn(@SchedFiberEntry, nil, AStackSize);
  if T.Fib = nil then
    raise Exception.Create('SpawnFiber: cannot map a fiber stack');

  if GMulticore then
  begin
    { Multicore: the task belongs to the whole run, not one worker.  Keep the
      handle alive on the owning worker's Tasks list (the spawning worker, or
      worker 0 for an off-worker spawn), bump the global live count, and hand
      the ready task to the current worker's deque or the global injector. }
    W := GTLWorker;
    McRegisterTask(W, T);
    McSubmitReady(W, T);
    Exit(T);
  end;

  W := NeedWorker();
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
    end
    else if T.State = fsBlocked then
    begin
      { The fiber parked on a sync primitive.  Settle the handshake: if a
        resume fired during the switch (PK_NOTIFIED), re-enqueue; else it stays
        cleanly parked (PK_PARKED) until a later FiberResume. }
      if _AtomicCASPtr(@T.ParkState, Pointer(PK_PARKING), Pointer(PK_PARKED)) then
        { cleanly parked, off queue }
      else
      begin
        T.ParkState := PK_RUNNING;
        T.State := fsReady;
        W.RunQ.Push(T);
      end;
    end;
  end;
  W.Running := False;
end;

procedure FiberYield;
var
  W: TWorker;
  T: TFiberTask;
begin
  W := CurrentWorker();
  if W = nil then
    Exit;
  T := W.Current;
  if T = nil then
    Exit;                     { off-scheduler: no-op }
  T.State := fsReady;
  if GMulticore then
    { CRITICAL: do NOT enqueue the task here.  In multicore mode a thief could
      steal it and start resuming its context on ANOTHER worker before this
      FiberSwitch has finished saving the context off this stack — two threads
      on one fiber stack.  Instead switch to the scheduler and let the OWNING
      worker re-enqueue it (McWorkerLoop, after the switch returns) once the
      context is safely saved. }
    FiberSwitch(T.Fib, W.SchedFib)
  else
  begin
    { Single worker: no thief, so the original in-line enqueue is safe. }
    W.RunQ.Push(T);
    FiberSwitch(T.Fib, W.SchedFib);
  end;
end;

function CurrentFiberTask: TFiberTask;
var
  W: TWorker;
begin
  W := CurrentWorker();
  if W = nil then
    Exit(nil);
  Result := W.Current;
end;

{ Enqueue a runnable task onto a run queue and wake a worker (multicore) or the
  single worker's FIFO.  Used by FiberResume and, in multicore, from any
  thread. }
procedure ScheduleRunnable(ATask: TFiberTask);
begin
  ATask.State := fsReady;
  if GMulticore then
  begin
    { From any thread: the injector is the only run queue safe to push to from
      a non-owning thread.  Wake ONE worker to drain it; the finite park cap in
      the loop makes any missed wake self-heal within a cap, so a single wake
      is enough for both liveness and low overhead. }
    InjectorPush(ATask);
    WakeWorker(GWorkers[0]);
  end
  else if GWorker <> nil then
    GWorker.RunQ.Push(ATask);
end;

procedure FiberParkCurrent;
var
  W: TWorker;
  T: TFiberTask;
begin
  W := CurrentWorker();
  if W = nil then
    Exit;                     { off-scheduler: caller handles the blocking path }
  T := W.Current;
  if T = nil then
    Exit;

  { Commit to parking.  If a waker already published NOTIFIED (raced in between
    the caller registering on its wait list and here), do NOT park — reset and
    carry on. }
  if not _AtomicCASPtr(@T.ParkState, Pointer(PK_RUNNING), Pointer(PK_PARKING)) then
  begin
    T.ParkState := PK_RUNNING;
    if T.Cancelled then
      raise EFiberCancelled.Create('fiber cancelled');
    Exit;
  end;

  T.State := fsBlocked;
  FiberSwitch(T.Fib, W.SchedFib);
  { Resumed on some worker: reset for the next park. }
  T.ParkState := PK_RUNNING;
  if T.Cancelled then
    raise EFiberCancelled.Create('fiber cancelled');
end;

{ Called by the OWNING worker's loop immediately after a fiber's FiberSwitch
  returned with the fiber left fsBlocked.  The context is now saved off the
  fiber stack, so it is finally safe to make the task stealable.  Publish
  PK_PARKED; if a waker beat us to PK_NOTIFIED, enqueue the task right here.
  Returns True if the task was (re)made runnable and should NOT stay parked. }
function McSettlePark(AW: TWorker; ATask: TFiberTask): Boolean;
begin
  if _AtomicCASPtr(@ATask.ParkState, Pointer(PK_PARKING), Pointer(PK_PARKED)) then
    Exit(False);              { cleanly parked, still off-queue }
  { A waker published PK_NOTIFIED while we were switching: take ownership of the
    wake and enqueue on THIS worker's deque (context is saved; we are owner). }
  ATask.ParkState := PK_RUNNING;
  ATask.State := fsReady;
  AW.Deque.PushBottom(Pointer(ATask));
  Result := True;
end;

procedure FiberResume(ATask: TFiberTask);
begin
  if ATask = nil then
    Exit;
  while True do
  begin
    { PARKED -> RUNNING + enqueue: the fiber is stably parked off every queue;
      we own the wake and schedule it. }
    if _AtomicCASPtr(@ATask.ParkState, Pointer(PK_PARKED), Pointer(PK_RUNNING)) then
    begin
      ScheduleRunnable(ATask);
      Exit;
    end;
    { PARKING -> NOTIFIED: the fiber is mid-switch; its owning worker will see
      NOTIFIED in McSettlePark and enqueue it.  We are done. }
    if _AtomicCASPtr(@ATask.ParkState, Pointer(PK_PARKING), Pointer(PK_NOTIFIED)) then
      Exit;
    { RUNNING -> NOTIFIED: the fiber has not parked yet; it will see NOTIFIED in
      FiberParkCurrent and skip the park entirely. }
    if _AtomicCASPtr(@ATask.ParkState, Pointer(PK_RUNNING), Pointer(PK_NOTIFIED)) then
      Exit;
    { Already NOTIFIED (a concurrent resume won): idempotent, nothing to do. }
    if _AtomicAddInt64(@ATask.ParkState, 0) = PK_NOTIFIED then
      Exit;
    { Otherwise the state changed under us (e.g. PARKING just became PARKED);
      loop and retry. }
  end;
end;

procedure FiberSleep(AMillis: Int64);
var
  W: TWorker;
  T: TFiberTask;
begin
  W := CurrentWorker();
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

  { A fiber parked on a sync primitive (fsBlocked) must be woken so it observes
    the cancellation at its suspension point.  FiberResume is thread-safe and
    idempotent via the park handshake. }
  if ATask.State = fsBlocked then
  begin
    FiberResume(ATask);
    if not GMulticore then
      Exit;
  end;

  if GMulticore then
  begin
    { A sleeping fiber lives in ITS OWNING worker's timer heap, which only
      that worker may mutate.  Rather than reach across threads into the heap,
      flag the task (done above, observed at the suspension point) and wake
      every worker so the owner re-derives its timer wait and, on the next
      loop pass, its due-timer sweep will not fire this one early — instead
      the cancel is observed when the fiber is next scheduled.  To make it
      prompt, publish a global cancel-generation bump and wake all workers;
      the owning worker's loop pulls a flagged sleeper out of its own heap.
      (Correctness does not depend on promptness: a never-resuming sleeper is
      pulled when its own deadline fires or the run winds down.) }
    McRequestCancelWake(ATask);
    Exit;
  end;

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
  if GMulticore then
    Exit(_AtomicAddInt32(@GGlobalLive, 0));
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

{ ===========================================================================
  L1 MULTICORE — N worker OS threads, work-stealing deques, global injector
  =========================================================================== }

{ --- futex park / wake ----------------------------------------------------- }

procedure FutexWait(AAddr: Pointer; AExpected: Integer; ATimeoutNs: Int64);
var
  Ts: TTimeSpec;
  TsPtr: Pointer;
begin
  { A finite timeout is ALWAYS used: FUTEX_WAIT with a NULL timeout blocks
    forever, so a single lost wake would hang the worker.  A non-positive
    request is coerced to a short bound (the caller already handles the
    "due now" case; this is a belt-and-braces floor). }
  if ATimeoutNs <= 0 then
    ATimeoutNs := Int64(1000000);   { 1 ms floor }
  Ts.Sec := ATimeoutNs div Int64(1000000000);
  Ts.NSec := ATimeoutNs mod Int64(1000000000);
  TsPtr := @Ts;
  _libc_syscall6(SYS_futex, Int64(PtrUInt(AAddr)),
    Int64(FUTEX_WAIT_PRIVATE), Int64(AExpected),
    Int64(PtrUInt(TsPtr)), 0, 0);
end;

procedure FutexWake(AAddr: Pointer; ACount: Integer);
begin
  _libc_syscall6(SYS_futex, Int64(PtrUInt(AAddr)),
    Int64(FUTEX_WAKE_PRIVATE), Int64(ACount), 0, 0, 0);
end;

{ Wake one specific worker: publish a pending-wake on its park word and futex
  -wake it.  Idempotent — a worker already awake just sees ParkWord = 1 and
  clears it before its next park. }
procedure WakeWorker(AW: TWorker);
begin
  if AW = nil then Exit;
  _AtomicAddInt32(@AW.ParkWord, 0);    { fence }
  AW.ParkWord := 1;
  FutexWake(@AW.ParkWord, 1);
end;

procedure WakeAllWorkers;
var
  I: Integer;
begin
  for I := 0 to GNumWorkers - 1 do
    WakeWorker(GWorkers[I]);
end;

{ --- global injector (Treiber stack) --------------------------------------- }

{ The global injector is a mutex-protected FIFO, not a lock-free Treiber stack:
  it is off the hot path (only off-worker spawns and cross-thread resumes push
  here), and a lock-free stack is ABA-prone when the SAME task is recycled
  through it (resume -> run -> re-park -> resume), which manifested as lost
  tasks and hot-spin livelocks.  A short critical section is correct and cheap
  here. }
procedure InjectorPush(ATask: TFiberTask);
begin
  pthread_mutex_lock(@GInjectorMtx[0]);
  ATask.NextReady := nil;
  if GInjectorTail = nil then
    GInjectorHead := ATask
  else
    GInjectorTail.NextReady := ATask;
  GInjectorTail := ATask;
  pthread_mutex_unlock(@GInjectorMtx[0]);
end;

function InjectorPop: TFiberTask;
var
  T: TFiberTask;
begin
  pthread_mutex_lock(@GInjectorMtx[0]);
  T := GInjectorHead;
  if T <> nil then
  begin
    GInjectorHead := T.NextReady;
    if GInjectorHead = nil then
      GInjectorTail := nil;
    T.NextReady := nil;
  end;
  pthread_mutex_unlock(@GInjectorMtx[0]);
  Result := T;
end;

{ --- task registration + ready submission ---------------------------------- }

{ Record a freshly spawned task so its handle stays alive and count it in the
  global live total.  Thread-safe (multiple workers spawn concurrently). }
procedure McRegisterTask(AW: TWorker; ATask: TFiberTask);
begin
  pthread_mutex_lock(@GTaskMtx[0]);
  GAllTasks.Add(ATask);
  pthread_mutex_unlock(@GTaskMtx[0]);
  _AtomicAddInt32(@GGlobalLive, 1);
end;

{ Hand a ready task to a run queue: the spawning worker's own deque (hot in
  its cache) when on a worker, else the global injector plus a wake. }
procedure McSubmitReady(AW: TWorker; ATask: TFiberTask);
begin
  ATask.State := fsReady;
  if AW <> nil then
    AW.Deque.PushBottom(Pointer(ATask))
  else
  begin
    InjectorPush(ATask);
    WakeWorker(GWorkers[0]);
  end;
end;

{ Cross-thread cancel: the flag is already set on the task; bump the cancel
  generation and wake every worker so the owning worker rescans its own timer
  heap and pulls the flagged sleeper (see McSweepCancelled). }
procedure McRequestCancelWake(ATask: TFiberTask);
begin
  _AtomicAddInt32(@GCancelGen, 1);
  WakeAllWorkers();
end;

{ --- per-worker scheduling loop -------------------------------------------- }

{ Move every timer whose deadline has passed onto the worker's own deque.
  Owner-only. }
procedure McDrainDueTimers(AW: TWorker; ANowNs: Int64);
var
  T: TFiberTask;
begin
  while (AW.Timers.Count > 0) and (AW.Timers.PeekMin().Deadline <= ANowNs) do
  begin
    T := AW.Timers.PopMin();
    T.State := fsReady;
    AW.Deque.PushBottom(Pointer(T));
  end;
end;

{ Pull any cancelled sleeper out of this worker's own timer heap and make it
  ready, so its FiberSleep resumes and raises EFiberCancelled promptly rather
  than waiting for a possibly-distant deadline.  Owner-only; O(heap) but only
  runs when the cancel generation advanced. }
procedure McSweepCancelled(AW: TWorker);
var
  I: Integer;
  Victims: TList<TFiberTask>;
  T: TFiberTask;
begin
  if AW.Timers.Count = 0 then Exit;
  Victims := TList<TFiberTask>.Create();
  try
    { Snapshot the heap contents into Victims first, then Remove/requeue the
      cancelled ones (mutating the heap while iterating it is unsafe). }
    for I := 0 to AW.Timers.Count - 1 do
    begin
      T := AW.Timers.HeapItem(I);
      if T.Cancelled then
        Victims.Add(T);
    end;
    for I := 0 to Victims.Count - 1 do
    begin
      T := Victims[I];
      AW.Timers.Remove(T);
      T.State := fsReady;
      AW.Deque.PushBottom(Pointer(T));
    end;
  finally
    Victims.Free();
  end;
end;

{ Take the next ready task for worker AW, or nil if none is available right
  now: LIFO hand-off slot -> local deque -> steal from a random peer ->
  global injector. }
function McTakeNext(AW: TWorker): TFiberTask;
var
  T: TFiberTask;
  Tries, Victim: Integer;
begin
  { 1. LIFO hand-off slot (the just-woken fiber, kept hot on the waker). }
  if AW.Handoff <> nil then
  begin
    T := AW.Handoff;
    AW.Handoff := nil;
    Exit(T);
  end;
  { 2. Local deque. }
  T := TFiberTask(AW.Deque.PopBottom());
  if T <> nil then
    Exit(T);
  { 3. Steal from a random peer (a few attempts). }
  if GNumWorkers > 1 then
  begin
    Tries := 0;
    while Tries < GNumWorkers * 2 do
    begin
      { Round-robin victim starting from the next worker. }
      Victim := (AW.Id + 1 + Tries) mod GNumWorkers;
      if (Victim <> AW.Id) and (GWorkers[Victim].Deque <> nil) then
      begin
        T := TFiberTask(GWorkers[Victim].Deque.Steal());
        if T <> nil then
          Exit(T);
      end;
      Tries := Tries + 1;
    end;
  end;
  { 4. Global injector. }
  T := InjectorPop();
  Result := T;
end;

{ The scheduler loop each worker OS thread runs. }
procedure McWorkerLoop(AW: TWorker);
var
  T: TFiberTask;
  NowNs, WaitNs: Int64;
  LastCancelGen, Gen: Integer;
begin
  GTLWorker := AW;
  AW.SchedFib := FiberCreateMain();
  LastCancelGen := 0;
  while _AtomicAddInt32(@GStop, 0) = 0 do
  begin
    NowNs := MonotonicNowNs();
    McDrainDueTimers(AW, NowNs);

    { Rescan for cancelled sleepers only when a cancel happened. }
    Gen := _AtomicAddInt32(@GCancelGen, 0);
    if Gen <> LastCancelGen then
    begin
      LastCancelGen := Gen;
      McSweepCancelled(AW);
    end;

    T := McTakeNext(AW);
    if T = nil then
    begin
      { Nothing ready.  Bound the park by the nearest local timer deadline so
        our own sleepers fire on time, and ALWAYS by a finite safety cap so a
        (theoretically) lost wake self-heals within one cap rather than
        hanging.  A zero/negative wait means there is due work now — do not
        park, just re-loop. }
      if _AtomicAddInt32(@GStop, 0) <> 0 then
        Break;
      if AW.Timers.Count > 0 then
        WaitNs := AW.Timers.PeekMin().Deadline - MonotonicNowNs()
      else
        WaitNs := Int64(10) * Int64(1000000);    { 10 ms safety cap }
      if WaitNs > Int64(10) * Int64(1000000) then
        WaitNs := Int64(10) * Int64(1000000);    { cap all parks at 10 ms }
      if WaitNs <= 0 then
      begin
        AW.ParkWord := 0;
        Continue;                { due timer now: re-loop without parking }
      end;
      { Consume any pending wake without sleeping; else futex-wait on 0. }
      if AW.ParkWord <> 0 then
        AW.ParkWord := 0
      else
        FutexWait(@AW.ParkWord, 0, WaitNs);
      AW.ParkWord := 0;
      Continue;
    end;

    T.State := fsRunning;
    AW.Current := T;
    FiberSwitch(AW.SchedFib, T.Fib);
    AW.Current := nil;
    if FiberIsDone(T.Fib) then
    begin
      FiberFree(T.Fib);
      T.Fib := nil;
      if _AtomicSubInt32(@GGlobalLive, 1) = 1 then
      begin
        { That was the last live fiber (Sub returns the PREVIOUS value). }
        GStop := 1;
        _AtomicAddInt32(@GStop, 0);   { fence the publish }
        WakeAllWorkers();
      end;
    end
    else if T.State = fsReady then
      { The fiber yielded (FiberYield).  The context is now safely saved off
        the fiber's stack, so it is safe to make it stealable: re-enqueue it on
        THIS worker's deque.  (fsSleeping is handled by the timer heap; the
        fiber parked itself there before switching.) }
      AW.Deque.PushBottom(Pointer(T))
    else if T.State = fsBlocked then
      { The fiber parked on a sync primitive (FiberParkCurrent).  Settle the
        park handshake now that the context is saved: either it stays off-queue
        (cleanly parked) or, if a waker fired during the switch, it is
        re-enqueued here. }
      McSettlePark(AW, T);
  end;
end;

{ pthread entry trampoline: %rdi = the TWorker, cast from Pointer. }
procedure McThreadEntry(Arg: Pointer);
begin
  McWorkerLoop(TWorker(Arg));
end;

function SchedulerIsMulticore: Boolean;
begin
  Result := GMulticore;
end;

procedure RunSchedulerMC(ANumWorkers: Integer);
var
  N, I: Integer;
  Threads: array of Int64;
  W: TWorker;
  PrevLeak: Boolean;
  PendingLive: Integer;
begin
  if GMulticore then
    raise Exception.Create('RunSchedulerMC: already running');

  N := ANumWorkers;
  if N <= 0 then
    N := GetCPUCount();
  if N < 1 then
    N := 1;

  { Carry over any fibers already spawned on the single-worker GWorker (the
    common pattern: spawn from the main thread, then RunSchedulerMC).  Their
    handles and the ready tasks move into the multicore world. }
  GAllTasks := TList<TFiberTask>.Create();
  GInjectorHead := nil;
  GInjectorTail := nil;
  pthread_mutex_init(@GInjectorMtx[0], nil);
  GGlobalLive := 0;
  GStop := 0;
  GCancelGen := 0;
  GNumWorkers := N;
  SetLength(GWorkers, N);
  for I := 0 to N - 1 do
  begin
    W := TWorker.Create();
    W.Id := I;
    W.Deque := TWorkStealDeque.Create();
    GWorkers[I] := W;
  end;

  { Suspend the lockless leak tracker for the duration of the parallel run. }
  PrevLeak := _LeakTrackerSuspend();

  GMulticore := True;

  { Migrate pre-spawned single-worker tasks into the injector. }
  PendingLive := 0;
  if GWorker <> nil then
  begin
    while GWorker.Tasks.Count > 0 do
    begin
      W := nil;  { unused }
      GAllTasks.Add(GWorker.Tasks[0]);
      InjectorPush(GWorker.Tasks[0]);
      GWorker.Tasks.Delete(0);
      PendingLive := PendingLive + 1;
    end;
    GGlobalLive := PendingLive;
    GWorker.LiveCount := 0;
    GWorker := nil;
  end;

  pthread_mutex_init(@GTaskMtx[0], nil);

  { Launch workers 1..N-1 on their own threads; worker 0 runs on this thread. }
  SetLength(Threads, N);
  for I := 1 to N - 1 do
  begin
    Threads[I] := 0;
    pthread_create(@Threads[I], nil, Pointer(@McThreadEntry), Pointer(GWorkers[I]));
  end;

  { If nothing is live, there is no work; still drive worker 0 once so it exits
    cleanly. }
  if GGlobalLive = 0 then
  begin
    GStop := 1;
    WakeAllWorkers();
  end;

  McWorkerLoop(GWorkers[0]);
  GTLWorker := nil;

  { Join the peers. }
  for I := 1 to N - 1 do
    pthread_join(Threads[I], nil);

  pthread_mutex_destroy(@GTaskMtx[0]);
  pthread_mutex_destroy(@GInjectorMtx[0]);

  { Tear down.  All fibers are finished (GGlobalLive = 0). }
  GMulticore := False;
  _LeakTrackerResume(PrevLeak);

  for I := 0 to N - 1 do
  begin
    GWorkers[I].Deque.Free();
    GWorkers[I].Deque := nil;
  end;
  SetLength(GWorkers, 0);
  GNumWorkers := 0;
  GAllTasks := nil;   { ARC cascades the handles }
end;

end.
