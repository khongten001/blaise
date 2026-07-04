{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.callalign;

{ E2E tests for call-site stack alignment (SysV: %rsp must be 16-byte
  aligned at every call instruction).

  The native backend stages call arguments with pushq; when an argument is
  itself a call, the already-pushed outer arguments stay pinned while the
  inner call's whole subtree executes.  An odd pinned slot count leaves
  %rsp = 8 (mod 16) at every call in that subtree.  Blaise-generated code
  tolerates that, so the bug is latent until a glibc callee uses movaps on
  its aligned locals — pthread_create (via __pthread_getattr_default_np ->
  pthread_attr_copy) SIGSEGVs.  These tests spawn a thread inside an
  odd-pinned nested-call argument so a misaligned subtree crashes the
  native arm; the QBE arm was never affected and must keep passing.

  See also cp.test.nativealign.pas for the asm-level mechanism tests. }

interface

uses
  classes, blaise.testing, cp.test.e2e.base;

type
  [Threaded]
  TE2ECallAlignTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    { The shape that found the bug: F(a, G(...)) with ONE pinned slot and a
      pthread_create inside G's subtree. }
    procedure TestRun_OddPinnedArg_ThreadSpawnInSubtree;
    { Two nesting levels with mixed even/odd pinned counts. }
    procedure TestRun_TwoLevelNested_OddPinnedThreadSpawn;
    { Odd pinned count around a float-arg call (slot-staged, not pushed). }
    procedure TestRun_OddPinned_FloatArgCall_ThreadSpawn;
    { Odd pinned count around a >6-arg call (SysV stack arguments) whose
      last argument spawns a thread. }
    procedure TestRun_OverflowArgs_OddPinned_ThreadSpawn;
  end;

implementation

procedure TE2ECallAlignTests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-callalign');
end;

const
  LE = #10;

  { Shared preamble: a worker thread and a function that spawns + joins it,
    returning 7. }
  ThreadPreamble =
    '''
    uses Classes;
    type
      TW = class(TThread)
      protected
        procedure Execute; override;
      end;
    procedure TW.Execute;
    begin
    end;
    function SpawnJoin: Integer;
    var T: TW;
    begin
      T := TW.Create(True);
      T.Start();
      T.WaitFor();
      Result := 7
    end;
    ''';

  SrcOddPinned =
    'program P;' + LE + ThreadPreamble +
    '''
    function Add2(A, B: Integer): Integer; begin Result := A + B end;
    var X: Integer;
    begin
      X := Add2(1, SpawnJoin());
      WriteLn(X)
    end.
    ''';

  SrcTwoLevel =
    'program P;' + LE + ThreadPreamble +
    '''
    function Add2(A, B: Integer): Integer; begin Result := A + B end;
    function Add3(A, B, C: Integer): Integer; begin Result := A + B + C end;
    var X: Integer;
    begin
      X := Add3(1, 2, Add2(3, SpawnJoin()));
      WriteLn(X)
    end.
    ''';

  SrcFloatArg =
    'program P;' + LE + ThreadPreamble +
    '''
    function FAdd(D: Double; I: Integer): Integer;
    begin
      Result := Trunc(D) + I
    end;
    function Add2(A, B: Integer): Integer; begin Result := A + B end;
    var X: Integer;
    begin
      X := Add2(1, FAdd(2.0, SpawnJoin()));
      WriteLn(X)
    end.
    ''';

  SrcOverflowArgs =
    'program P;' + LE + ThreadPreamble +
    '''
    function Sum8(A, B, C, D, E, F, G, H: Integer): Integer;
    begin
      Result := A + B + C + D + E + F + G + H
    end;
    function Add2(A, B: Integer): Integer; begin Result := A + B end;
    var X: Integer;
    begin
      X := Add2(1, Sum8(1, 2, 3, 4, 5, 6, 7, SpawnJoin()));
      WriteLn(X)
    end.
    ''';

procedure TE2ECallAlignTests.TestRun_OddPinnedArg_ThreadSpawnInSubtree;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRTLRunsOnAll(SrcOddPinned, '8' + LE, 0)
end;

procedure TE2ECallAlignTests.TestRun_TwoLevelNested_OddPinnedThreadSpawn;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRTLRunsOnAll(SrcTwoLevel, '13' + LE, 0)
end;

procedure TE2ECallAlignTests.TestRun_OddPinned_FloatArgCall_ThreadSpawn;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRTLRunsOnAll(SrcFloatArg, '10' + LE, 0)
end;

procedure TE2ECallAlignTests.TestRun_OverflowArgs_OddPinned_ThreadSpawn;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRTLRunsOnAll(SrcOverflowArgs, '36' + LE, 0)
end;

initialization
  RegisterTest(TE2ECallAlignTests);

end.
