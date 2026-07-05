{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit async.sync;

// L1 of the fiber runtime (docs/async-networking-design.adoc, [#scheduler],
// "Fiber-aware synchronisation"): primitives that PARK the fiber, not the OS
// thread.  A raw pthread_mutex held across a fiber suspension would block the
// whole worker (and every other fiber on it) — a deadlock-class bug.  These
// objects instead suspend the fiber via the scheduler's park/resume seam
// (async.fibers FiberParkCurrent / FiberResume) and never hold an OS lock
// across a suspension.
//
//   * TFiberMutex      — mutual exclusion between fibers.
//   * TFiberEvent      — a one-to-many signal (manual- or auto-reset).
//   * TFiberWaitGroup  — join on a dynamic set of fibers (Add/Done/Wait).
//   * TChannel<T>      — a Go-style bounded/unbounded hand-off channel.
//
// Each object uses a BRIEF, non-suspending pthread_mutex to protect its own
// state + waiter list; the design explicitly permits that ("brief,
// non-suspending critical sections may still use a raw pthread mutex").  The
// waiter list stores TFiberTask handles; parking a fiber records the current
// task under the lock, then releases the lock, then parks — a waker pops a
// waiter under the lock and resumes it.  The park/resume handshake in
// async.fibers closes the lost-wakeup window.
//
// NATIVE BACKEND ONLY (async.fibers pulls in the inline-asm context leaf).

interface

uses
  SysUtils, generics.collections, async.fibers;

type
  { An intrusive-free FIFO of parked fibers, guarded by the owning object's
    lock.  Small wrapper over TList so waiters pop in wake order. }
  TWaiterQueue = class
  private
    FItems: TList<TFiberTask>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(ATask: TFiberTask);
    function Pop: TFiberTask;      { nil when empty }
    function Count: Integer;
  end;

  { Fiber-aware mutual exclusion.  Lock parks the fiber when the mutex is held;
    Unlock resumes the next waiter.  NOT recursive. }
  TFiberMutex = class
  private
    FMtx: array[0..5] of Int64;   { pthread_mutex_t buffer (state guard) }
    FHeld: Boolean;
    FWaiters: TWaiterQueue;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Lock;
    procedure Unlock;
  end;

  { Fiber-aware event.  Wait parks until Signal.  With auto-reset, Signal wakes
    exactly one waiter and the event stays unset; otherwise Signal wakes all
    current waiters and latches set (Wait then returns immediately until
    Reset). }
  TFiberEvent = class
  private
    FMtx: array[0..5] of Int64;
    FSet: Boolean;
    FAutoReset: Boolean;
    FWaiters: TWaiterQueue;
  public
    constructor Create(AAutoReset: Boolean = False);
    destructor Destroy; override;
    procedure Wait;
    procedure Signal;
    procedure Reset;
  end;

  { Fiber-aware wait group (Go sync.WaitGroup / a latch).  Add raises the
    counter, Done lowers it, Wait parks until it reaches zero. }
  TFiberWaitGroup = class
  private
    FMtx: array[0..5] of Int64;
    FCount: Integer;
    FWaiters: TWaiterQueue;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(ADelta: Integer);
    procedure Done;
    procedure Wait;
  end;

  { Go-style channel of T.  Capacity 0 or more: Send parks when the buffer is
    full (bounded backpressure), Recv parks when it is empty.  A capacity of
    -1 means unbounded (Send never parks).  Fiber-to-fiber hand-off. }
  TChannel<T> = class
  private
    FMtx: array[0..5] of Int64;
    FBuf: TQueue<T>;
    FCap: Integer;                { >= 0 bounded, < 0 unbounded }
    FClosed: Boolean;
    FSenders: TWaiterQueue;       { parked because full }
    FReceivers: TWaiterQueue;     { parked because empty }
  public
    constructor Create(ACapacity: Integer = 0);
    destructor Destroy; override;
    { Send AValue, parking while the channel is full.  Returns False if the
      channel is closed. }
    function Send(const AValue: T): Boolean;
    { Receive into AValue, parking while empty.  Returns False if the channel
      is closed AND drained. }
    function Recv(out AValue: T): Boolean;
    { Close the channel: wakes all parked senders/receivers.  Further Sends
      fail; Recv drains the buffer then fails. }
    procedure Close;
    function Count: Integer;
  end;

implementation

uses
  runtime.thread;

{ --- TWaiterQueue --------------------------------------------------------- }

constructor TWaiterQueue.Create;
begin
  Self.FItems := TList<TFiberTask>.Create();
end;

destructor TWaiterQueue.Destroy;
begin
  Self.FItems.Free();
  inherited Destroy();
end;

procedure TWaiterQueue.Push(ATask: TFiberTask);
begin
  Self.FItems.Add(ATask);
end;

function TWaiterQueue.Pop: TFiberTask;
begin
  if Self.FItems.Count = 0 then
    Exit(nil);
  Result := Self.FItems[0];
  Self.FItems.Delete(0);
end;

function TWaiterQueue.Count: Integer;
begin
  Result := Self.FItems.Count;
end;

{ --- TFiberMutex ---------------------------------------------------------- }

constructor TFiberMutex.Create;
begin
  pthread_mutex_init(@Self.FMtx[0], nil);
  Self.FHeld := False;
  Self.FWaiters := TWaiterQueue.Create();
end;

destructor TFiberMutex.Destroy;
begin
  pthread_mutex_destroy(@Self.FMtx[0]);
  Self.FWaiters.Free();
  inherited Destroy();
end;

procedure TFiberMutex.Lock;
var
  T: TFiberTask;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  if not Self.FHeld then
  begin
    Self.FHeld := True;
    pthread_mutex_unlock(@Self.FMtx[0]);
    Exit;
  end;
  { Held: park behind the current holder.  Record the task, release the guard,
    then park.  A future Unlock pops and resumes us. }
  T := CurrentFiberTask();
  if T = nil then
  begin
    { Off-scheduler: spin-yield on the guard is not possible; treat as an
      uncontended acquire (single-threaded caller).  This path is not the
      intended use — mutexes are for fiber code. }
    Self.FHeld := True;
    pthread_mutex_unlock(@Self.FMtx[0]);
    Exit;
  end;
  Self.FWaiters.Push(T);
  pthread_mutex_unlock(@Self.FMtx[0]);
  FiberParkCurrent();
  { Resumed by Unlock, which handed the lock to us (FHeld stays True). }
end;

procedure TFiberMutex.Unlock;
var
  Next: TFiberTask;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  Next := Self.FWaiters.Pop();
  if Next = nil then
  begin
    Self.FHeld := False;
    pthread_mutex_unlock(@Self.FMtx[0]);
    Exit;
  end;
  { Hand ownership directly to the next waiter (FHeld stays True). }
  pthread_mutex_unlock(@Self.FMtx[0]);
  FiberResume(Next);
end;

{ --- TFiberEvent ---------------------------------------------------------- }

constructor TFiberEvent.Create(AAutoReset: Boolean);
begin
  pthread_mutex_init(@Self.FMtx[0], nil);
  Self.FSet := False;
  Self.FAutoReset := AAutoReset;
  Self.FWaiters := TWaiterQueue.Create();
end;

destructor TFiberEvent.Destroy;
begin
  pthread_mutex_destroy(@Self.FMtx[0]);
  Self.FWaiters.Free();
  inherited Destroy();
end;

procedure TFiberEvent.Wait;
var
  T: TFiberTask;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  if Self.FSet then
  begin
    { Auto-reset consumes the signal; manual-reset stays latched. }
    if Self.FAutoReset then
      Self.FSet := False;
    pthread_mutex_unlock(@Self.FMtx[0]);
    Exit;
  end;
  T := CurrentFiberTask();
  if T = nil then
  begin
    pthread_mutex_unlock(@Self.FMtx[0]);
    Exit;                     { off-scheduler: nothing to park }
  end;
  Self.FWaiters.Push(T);
  pthread_mutex_unlock(@Self.FMtx[0]);
  FiberParkCurrent();
end;

procedure TFiberEvent.Signal;
var
  Next: TFiberTask;
  Woken: TList<TFiberTask>;
  I: Integer;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  if Self.FAutoReset then
  begin
    { Wake exactly one; if none waiting, latch the signal for the next Wait. }
    Next := Self.FWaiters.Pop();
    if Next = nil then
      Self.FSet := True;
    pthread_mutex_unlock(@Self.FMtx[0]);
    if Next <> nil then
      FiberResume(Next);
    Exit;
  end;
  { Manual-reset: latch set and wake every current waiter. }
  Self.FSet := True;
  Woken := TList<TFiberTask>.Create();
  try
    Next := Self.FWaiters.Pop();
    while Next <> nil do
    begin
      Woken.Add(Next);
      Next := Self.FWaiters.Pop();
    end;
    pthread_mutex_unlock(@Self.FMtx[0]);
    for I := 0 to Woken.Count - 1 do
      FiberResume(Woken[I]);
  finally
    Woken.Free();
  end;
end;

procedure TFiberEvent.Reset;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  Self.FSet := False;
  pthread_mutex_unlock(@Self.FMtx[0]);
end;

{ --- TFiberWaitGroup ------------------------------------------------------ }

constructor TFiberWaitGroup.Create;
begin
  pthread_mutex_init(@Self.FMtx[0], nil);
  Self.FCount := 0;
  Self.FWaiters := TWaiterQueue.Create();
end;

destructor TFiberWaitGroup.Destroy;
begin
  pthread_mutex_destroy(@Self.FMtx[0]);
  Self.FWaiters.Free();
  inherited Destroy();
end;

procedure TFiberWaitGroup.Add(ADelta: Integer);
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  Self.FCount := Self.FCount + ADelta;
  pthread_mutex_unlock(@Self.FMtx[0]);
end;

procedure TFiberWaitGroup.Done;
var
  Next: TFiberTask;
  Woken: TList<TFiberTask>;
  I: Integer;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  Self.FCount := Self.FCount - 1;
  if Self.FCount > 0 then
  begin
    pthread_mutex_unlock(@Self.FMtx[0]);
    Exit;
  end;
  { Reached zero: wake all waiters. }
  Woken := TList<TFiberTask>.Create();
  try
    Next := Self.FWaiters.Pop();
    while Next <> nil do
    begin
      Woken.Add(Next);
      Next := Self.FWaiters.Pop();
    end;
    pthread_mutex_unlock(@Self.FMtx[0]);
    for I := 0 to Woken.Count - 1 do
      FiberResume(Woken[I]);
  finally
    Woken.Free();
  end;
end;

procedure TFiberWaitGroup.Wait;
var
  T: TFiberTask;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  if Self.FCount <= 0 then
  begin
    pthread_mutex_unlock(@Self.FMtx[0]);
    Exit;
  end;
  T := CurrentFiberTask();
  if T = nil then
  begin
    pthread_mutex_unlock(@Self.FMtx[0]);
    Exit;
  end;
  Self.FWaiters.Push(T);
  pthread_mutex_unlock(@Self.FMtx[0]);
  FiberParkCurrent();
end;

{ --- TChannel<T> ---------------------------------------------------------- }

constructor TChannel<T>.Create(ACapacity: Integer);
begin
  pthread_mutex_init(@Self.FMtx[0], nil);
  Self.FBuf := TQueue<T>.Create();
  Self.FCap := ACapacity;
  Self.FClosed := False;
  Self.FSenders := TWaiterQueue.Create();
  Self.FReceivers := TWaiterQueue.Create();
end;

destructor TChannel<T>.Destroy;
begin
  pthread_mutex_destroy(@Self.FMtx[0]);
  Self.FBuf.Free();
  Self.FSenders.Free();
  Self.FReceivers.Free();
  inherited Destroy();
end;

function TChannel<T>.Send(const AValue: T): Boolean;
var
  T2: TFiberTask;
  Rcv: TFiberTask;
begin
  while True do
  begin
    pthread_mutex_lock(@Self.FMtx[0]);
    if Self.FClosed then
    begin
      pthread_mutex_unlock(@Self.FMtx[0]);
      Exit(False);
    end;
    { Room to buffer (unbounded when FCap < 0)? }
    if (Self.FCap < 0) or (Self.FBuf.Count < Self.FCap)
       or (Self.FReceivers.Count() > 0) then
    begin
      Self.FBuf.Enqueue(AValue);
      { A parked receiver can now make progress. }
      Rcv := Self.FReceivers.Pop();
      pthread_mutex_unlock(@Self.FMtx[0]);
      if Rcv <> nil then
        FiberResume(Rcv);
      Exit(True);
    end;
    { Full and no receiver waiting: park this sender and retry on resume. }
    T2 := CurrentFiberTask();
    if T2 = nil then
    begin
      { Off-scheduler: cannot park.  Buffer anyway (degrade to unbounded) so a
        non-fiber producer does not deadlock. }
      Self.FBuf.Enqueue(AValue);
      pthread_mutex_unlock(@Self.FMtx[0]);
      Exit(True);
    end;
    Self.FSenders.Push(T2);
    pthread_mutex_unlock(@Self.FMtx[0]);
    FiberParkCurrent();
    { Loop: re-check conditions after being resumed. }
  end;
end;

function TChannel<T>.Recv(out AValue: T): Boolean;
var
  T2: TFiberTask;
  Snd: TFiberTask;
begin
  while True do
  begin
    pthread_mutex_lock(@Self.FMtx[0]);
    if Self.FBuf.Count > 0 then
    begin
      AValue := Self.FBuf.Dequeue();
      { A parked sender now has room. }
      Snd := Self.FSenders.Pop();
      pthread_mutex_unlock(@Self.FMtx[0]);
      if Snd <> nil then
        FiberResume(Snd);
      Exit(True);
    end;
    if Self.FClosed then
    begin
      pthread_mutex_unlock(@Self.FMtx[0]);
      Exit(False);          { closed and drained }
    end;
    { Empty: park this receiver and retry on resume. }
    T2 := CurrentFiberTask();
    if T2 = nil then
    begin
      pthread_mutex_unlock(@Self.FMtx[0]);
      Exit(False);          { off-scheduler: nothing to wait on }
    end;
    Self.FReceivers.Push(T2);
    pthread_mutex_unlock(@Self.FMtx[0]);
    FiberParkCurrent();
  end;
end;

procedure TChannel<T>.Close;
var
  Woken: TList<TFiberTask>;
  Next: TFiberTask;
  I: Integer;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  Self.FClosed := True;
  Woken := TList<TFiberTask>.Create();
  try
    Next := Self.FSenders.Pop();
    while Next <> nil do
    begin
      Woken.Add(Next);
      Next := Self.FSenders.Pop();
    end;
    Next := Self.FReceivers.Pop();
    while Next <> nil do
    begin
      Woken.Add(Next);
      Next := Self.FReceivers.Pop();
    end;
    pthread_mutex_unlock(@Self.FMtx[0]);
    for I := 0 to Woken.Count - 1 do
      FiberResume(Woken[I]);
  finally
    Woken.Free();
  end;
end;

function TChannel<T>.Count: Integer;
begin
  pthread_mutex_lock(@Self.FMtx[0]);
  Result := Self.FBuf.Count;
  pthread_mutex_unlock(@Self.FMtx[0]);
end;

end.
