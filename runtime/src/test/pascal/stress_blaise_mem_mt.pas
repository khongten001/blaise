{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Standalone long-running pthread allocator stress — the P2 gate stress
  from concurrent-allocator-design.adoc §The pthread stress, sharing its
  engine with the bounded suite test (memstresscore / test_blaise_mem_mt).

  Usage:
    stress_blaise_mem_mt [threads [iterations]]
  Defaults: 8 threads, 200000 iterations per thread.

  Exit code 0 = clean run (no integrity failures, no allocation failures,
  terminal drain balanced); 1 = failure (details on stdout).

  Build:
    blaise --source runtime/src/test/pascal/stress_blaise_mem_mt.pas \
           --unit-path compiler/src/main/pascal \
           --unit-path runtime/src/test/pascal \
           --output /tmp/stress_mem_mt
}

program stress_blaise_mem_mt;

uses
  memstresscore, runtime.str;

var
  Threads: Integer;
  Iters: Integer;
  Bad: Int64;
  Failed: Boolean;
begin
  Threads := 8;
  Iters := 200000;
  if ParamCount() >= 1 then
    Threads := _StrToInt(ParamStr(1));
  if ParamCount() >= 2 then
    Iters := _StrToInt(ParamStr(2));

  WriteLn('stress: threads=' + IntToStr(Threads)
          + ' iters=' + IntToStr(Iters));
  Bad := RunMemStress(Threads, Iters);

  WriteLn('alloc total : ' + IntToStr(StressAllocTotal()));
  WriteLn('free total  : ' + IntToStr(StressFreeTotal()));
  WriteLn('alloc fails : ' + IntToStr(StressAllocFails()));
  WriteLn('bad blocks  : ' + IntToStr(StressBadCount()));

  Failed := False;
  if Bad <> 0 then
  begin
    WriteLn('FAIL: integrity failures (or thread-create failure)');
    Failed := True;
  end;
  if StressAllocFails() <> 0 then
  begin
    WriteLn('FAIL: allocation failures');
    Failed := True;
  end;
  if StressAllocTotal() <> StressFreeTotal() then
  begin
    WriteLn('FAIL: terminal drain does not balance');
    Failed := True;
  end;
  if StressAllocTotal() = 0 then
  begin
    WriteLn('FAIL: no allocations performed');
    Failed := True;
  end;

  if Failed then
  begin
    WriteLn('STRESS_FAIL');
    Halt(1);
  end;
  WriteLn('STRESS_OK');
end.
