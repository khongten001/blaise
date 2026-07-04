{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.scheduler;

{ E2E tests for L1 of the fiber runtime (docs/async-networking-design.adoc,
  [#scheduler]): the single-worker scheduler in
  stdlib/src/main/pascal/async.fibers.pas — SpawnFiber/RunScheduler/
  FiberYield/FiberSleep over the timer heap, plus the root exception frame
  and cancellation at the suspension point.

  BACKEND POSTURE: async.fibers pulls in the inline-asm context leaf, so all
  tests run on the NATIVE backend only (the QBE-rejection guard test lives in
  cp.test.e2e.fibers). }

interface

uses
  SysUtils, blaise.testing, cp.test.e2e.base;

type
  TSchedulerE2ETests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    { Slice 2 — scheduler core: run queue, yield, timers, drain. }
    procedure TestScheduler_YieldRoundRobin_Deterministic;
    procedure TestScheduler_SleepOrdering_TimersFireInDeadlineOrder;
    procedure TestScheduler_FiberSpawnsFibers;
    procedure TestScheduler_Smoke10kFibers_DrainsToCompletion;
  end;

implementation

const
  LE = #10;

  { Three fibers yield in a loop: the FIFO run queue must interleave them
    deterministically (spawn order, round-robin), RunScheduler must return
    once all are done, and the handles must read fsDone. }
  SrcYieldRoundRobin =
    '''
    program schedyield;
    uses async.fibers;
    var
      T0, T1, T2: TFiberTask;
    procedure Worker(AArg: Pointer);
    var
      I: Integer;
    begin
      for I := 0 to 2 do
      begin
        WriteLn('F', Integer(AArg), ':', I);
        FiberYield();
      end;
    end;
    begin
      T0 := SpawnFiber(@Worker, Pointer(0));
      T1 := SpawnFiber(@Worker, Pointer(1));
      T2 := SpawnFiber(@Worker, Pointer(2));
      RunScheduler();
      if (T0.State = fsDone) and (T1.State = fsDone) and (T2.State = fsDone) then
        WriteLn('ALLDONE');
      WriteLn('LIVE=', SchedulerLiveCount());
    end.
    ''';

  { Three fibers sleep 30/10/20 ms: the timer heap must wake them in
    deadline order (10, 20, 30), not spawn order. }
  SrcSleepOrdering =
    '''
    program schedsleep;
    uses async.fibers;
    procedure Sleeper(AArg: Pointer);
    begin
      FiberSleep(Int64(AArg));
      WriteLn('S', Int64(AArg));
    end;
    var
      A, B, C: TFiberTask;
    begin
      A := SpawnFiber(@Sleeper, Pointer(30));
      B := SpawnFiber(@Sleeper, Pointer(10));
      C := SpawnFiber(@Sleeper, Pointer(20));
      RunScheduler();
      WriteLn('M');
    end.
    ''';

  { A running fiber spawns two children mid-run; they join the run queue
    behind it and the scheduler drains all three. }
  SrcFiberSpawnsFibers =
    '''
    program schedspawn;
    uses async.fibers;
    var
      C1, C2: TFiberTask;
    procedure Child(AArg: Pointer);
    begin
      WriteLn('C', Integer(AArg));
    end;
    procedure Parent(AArg: Pointer);
    begin
      WriteLn('P:start');
      C1 := SpawnFiber(@Child, Pointer(1));
      C2 := SpawnFiber(@Child, Pointer(2));
      FiberYield();
      WriteLn('P:end');
    end;
    var
      P: TFiberTask;
    begin
      P := SpawnFiber(@Parent, nil);
      RunScheduler();
      WriteLn('M');
    end.
    ''';

  { Bounded single-worker smoke (the design's 100k joint stress is the P2
    gate re-run; this is the L1-scoped 10k form): 10k fibers on small
    stacks each yield once and bump a counter; the scheduler must drain to
    completion and return. }
  SrcSmoke10k =
    '''
    program schedsmoke;
    uses async.fibers;
    var
      Counter: Integer;
    procedure Work(AArg: Pointer);
    begin
      FiberYield();
      Counter := Counter + 1;
    end;
    var
      I: Integer;
      T: TFiberTask;
    begin
      Counter := 0;
      for I := 0 to 9999 do
        T := SpawnFiber(@Work, nil, 8192);
      RunScheduler();
      WriteLn('COUNT=', Counter);
      WriteLn('LIVE=', SchedulerLiveCount());
    end.
    ''';

procedure TSchedulerE2ETests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-scheduler')
end;

procedure TSchedulerE2ETests.TestScheduler_YieldRoundRobin_Deterministic;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRTLRunsOnOne(beNative, 'sched-yield', SrcYieldRoundRobin,
    'F0:0' + LE + 'F1:0' + LE + 'F2:0' + LE +
    'F0:1' + LE + 'F1:1' + LE + 'F2:1' + LE +
    'F0:2' + LE + 'F1:2' + LE + 'F2:2' + LE +
    'ALLDONE' + LE + 'LIVE=0' + LE, 0)
end;

procedure TSchedulerE2ETests.TestScheduler_SleepOrdering_TimersFireInDeadlineOrder;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRTLRunsOnOne(beNative, 'sched-sleep', SrcSleepOrdering,
    'S10' + LE + 'S20' + LE + 'S30' + LE + 'M' + LE, 0)
end;

procedure TSchedulerE2ETests.TestScheduler_FiberSpawnsFibers;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRTLRunsOnOne(beNative, 'sched-spawn', SrcFiberSpawnsFibers,
    'P:start' + LE + 'C1' + LE + 'C2' + LE + 'P:end' + LE + 'M' + LE, 0)
end;

procedure TSchedulerE2ETests.TestScheduler_Smoke10kFibers_DrainsToCompletion;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRTLRunsOnOne(beNative, 'sched-smoke', SrcSmoke10k,
    'COUNT=10000' + LE + 'LIVE=0' + LE, 0)
end;

initialization
  RegisterTest(TSchedulerE2ETests);

end.
