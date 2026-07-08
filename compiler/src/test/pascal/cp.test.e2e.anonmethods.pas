{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.anonmethods;

{ E2E tests for anonymous-method capture (Phase 2 of
  docs/anonymous-methods-design.adoc): compile -> run on every backend
  (QBE + native), asserting stdout/exit code.  Covers the behaviour the
  IR-level tests in cp.test.anonmethods.pas cannot see: shared-environment
  mutation, escape past the creating frame, the by-reference loop-capture
  semantics, captured-parameter snapshots, and exception flow through a
  closure body. }

interface

uses
  classes, blaise.testing, cp.test.e2e.base;

type
  [Threaded]
  TE2EAnonMethodTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestRun_CaptureLocal_ReadInClosure;
    procedure TestRun_ClosureWrite_VisibleInEnclosing;
    procedure TestRun_TwoClosures_ShareOneEnv;
    procedure TestRun_Escape_GlobalClosure_OutlivesFrame;
    procedure TestRun_LoopCapture_SharesEnv_ByReference;
    procedure TestRun_CapturedParam_InitialValueCopied;
    procedure TestRun_FunctionLiteral_CapturesAccumulator;
    procedure TestRun_CapturedString_Concat;
    procedure TestRun_RaiseThroughFinally_InClosureBody;
    { Phase 3 }
    procedure TestRun_MethodLiteral_CapturesLocalAndSelf;
    procedure TestRun_MethodLiteral_ExplicitSelfCall;
    procedure TestRun_MethodLiteral_EscapesMethodFrame;
    procedure TestRun_MethodPtrCoercion_DispatchesWithReceiver;
    procedure TestRun_MethodPtrCoercion_VirtualDispatch;
    { Phase 4 — block-scoped var + per-iteration capture }
    procedure TestRun_BlockVar_BasicScopeAndInit;
    procedure TestRun_BlockVar_InitRunsPerIteration;
    procedure TestRun_BlockVar_LoopSnapshotIdiom_012;
    procedure TestRun_LoopCapture_RoutineVar_Still333;
    { Phase 5 }
    procedure TestRun_WeakSelf_ReadsNilAfterReceiverDies;
    procedure TestRun_WeakSelf_WorksWhileReceiverAlive;
  end;

implementation

procedure TE2EAnonMethodTests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-anonmethods')
end;

procedure TE2EAnonMethodTests.TestRun_CaptureLocal_ReadInClosure;
const Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  procedure Run;
  var
    Outer: Integer;
    V: TProc;
  begin
    Outer := 41;
    V := procedure
    begin
      WriteLn(Outer + 1)
    end;
    V()
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_ClosureWrite_VisibleInEnclosing;
const Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  procedure Run;
  var
    Total: Integer;
    V: TProc;
  begin
    Total := 10;
    V := procedure
    begin
      Total := Total + 32
    end;
    V();
    WriteLn(Total)
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_TwoClosures_ShareOneEnv;
const
  { Both literals in one frame capture the same 'Total' — by-reference
    semantics require ONE shared environment, so the second closure sees
    the first one's write. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  procedure Run;
  var
    Total: Integer;
    Inc10: TProc;
    Show: TProc;
  begin
    Total := 32;
    Inc10 := procedure
    begin
      Total := Total + 10
    end;
    Show := procedure
    begin
      WriteLn(Total)
    end;
    Inc10();
    Show()
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_Escape_GlobalClosure_OutlivesFrame;
const
  { The closure is stored in a global and invoked AFTER Make has returned:
    the captured local must live on in the heap env, not the dead frame. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  var
    G: TProc;
  procedure Make;
  var
    Secret: Integer;
  begin
    Secret := 42;
    G := procedure
    begin
      WriteLn(Secret)
    end
  end;
  begin
    Make();
    G()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_LoopCapture_SharesEnv_ByReference;
const
  { The documented Delphi-compatible trap: one env per FRAME, so all three
    closures share the same 'I' and print its post-loop value 3.  Phase 4
    (block-scoped environments) adds the fresh-binding idiom. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  procedure Run;
  var
    A: TProc;
    B: TProc;
    C: TProc;
    I: Integer;
  begin
    for I := 0 to 2 do
    begin
      if I = 0 then A := procedure begin WriteLn(I) end;
      if I = 1 then B := procedure begin WriteLn(I) end;
      if I = 2 then C := procedure begin WriteLn(I) end
    end;
    A();
    B();
    C()
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '3' + LineEnding + '3' + LineEnding + '3' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_CapturedParam_InitialValueCopied;
const
  { A captured VALUE parameter: its incoming value must be copied into the
    env field at frame entry before any closure runs. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  procedure Run(Base: Integer);
  var
    V: TProc;
  begin
    V := procedure
    begin
      Base := Base + 2;
      WriteLn(Base)
    end;
    V()
  end;
  begin
    Run(40)
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_FunctionLiteral_CapturesAccumulator;
const Src =
  '''
  program P;
  type
    TStep = reference to function(AInc: Integer): Integer;
  procedure Run;
  var
    Acc: Integer;
    Step: TStep;
  begin
    Acc := 0;
    Step := function(AInc: Integer): Integer
    begin
      Acc := Acc + AInc;
      Result := Acc
    end;
    WriteLn(Step(20));
    WriteLn(Step(22))
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '20' + LineEnding + '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_CapturedString_Concat;
const
  { A captured ARC-managed string: env field must go through the string
    retain/release store path, and the env cleanup must release it. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  procedure Run;
  var
    Prefix: string;
    V: TProc;
  begin
    Prefix := 'item-';
    V := procedure
    begin
      Prefix := Prefix + '42';
      WriteLn(Prefix)
    end;
    V()
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, 'item-42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_RaiseThroughFinally_InClosureBody;
const
  { A raise inside the closure body must run the body's finally block and
    propagate to the invoker's except handler (design doc, Closures and
    exceptions). }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
    Exception = class
    private
      FMessage: string;
    public
      constructor Create(AMsg: string);
      property Message: string read FMessage;
    end;
  constructor Exception.Create(AMsg: string);
  begin
    FMessage := AMsg;
  end;
  procedure Run;
  var
    Flag: Integer;
    V: TProc;
  begin
    Flag := 0;
    V := procedure
    begin
      try
        raise Exception.Create('boom')
      finally
        Flag := Flag + 1
      end
    end;
    try
      V()
    except
      on E: Exception do WriteLn('caught ', E.Message)
    end;
    WriteLn(Flag)
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, 'caught boom' + LineEnding + '1' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_MethodLiteral_CapturesLocalAndSelf;
const
  { A literal inside an instance method: implicit member access (FCount)
    goes through the captured Self; the method local Step is env-promoted. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
    TCounter = class
      FCount: Integer;
      procedure Bump;
    end;
  procedure TCounter.Bump;
  var
    Step: Integer;
    V: TProc;
  begin
    Step := 40;
    V := procedure
    begin
      FCount := FCount + Step + 2
    end;
    V()
  end;
  var C: TCounter;
  begin
    C := TCounter.Create();
    C.Bump();
    WriteLn(C.FCount)
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_MethodLiteral_ExplicitSelfCall;
const
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
    TGreeter = class
      FName: string;
      procedure Say;
      procedure Run;
    end;
  procedure TGreeter.Say;
  begin
    WriteLn('hello ', FName)
  end;
  procedure TGreeter.Run;
  var
    V: TProc;
  begin
    V := procedure
    begin
      Self.Say()
    end;
    V()
  end;
  var G: TGreeter;
  begin
    G := TGreeter.Create();
    G.FName := 'world';
    G.Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, 'hello world' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_MethodLiteral_EscapesMethodFrame;
const
  { The closure escapes the method frame via a global; the env's strong Self
    reference keeps the receiver alive and members readable after Wire
    returned. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
    TBox = class
      FValue: Integer;
      procedure Wire;
    end;
  var
    G: TProc;
  procedure TBox.Wire;
  begin
    G := procedure
    begin
      WriteLn(FValue)
    end
  end;
  var B: TBox;
  begin
    B := TBox.Create();
    B.FValue := 42;
    B.Wire();
    G()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_MethodPtrCoercion_DispatchesWithReceiver;
const
  Src =
  '''
  program P;
  type
    TShow = reference to procedure(AValue: Integer);
    TScaler = class
      FFactor: Integer;
      procedure Show(AValue: Integer);
    end;
  procedure TScaler.Show(AValue: Integer);
  begin
    WriteLn(AValue * FFactor)
  end;
  var
    S: TScaler;
    V: TShow;
  begin
    S := TScaler.Create();
    S.FFactor := 2;
    V := @S.Show;
    V(21)
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_MethodPtrCoercion_VirtualDispatch;
const
  { @Obj.M on a virtual method must capture the DYNAMIC override, matching a
    direct Obj.M() call (same rule as method-pointer assignment). }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
    TBase = class
      procedure Speak; virtual;
    end;
    TLoud = class(TBase)
      procedure Speak; override;
    end;
  procedure TBase.Speak;
  begin
    WriteLn('base')
  end;
  procedure TLoud.Speak;
  begin
    WriteLn('LOUD')
  end;
  var
    B: TBase;
    V: TProc;
  begin
    B := TLoud.Create();
    V := @B.Speak;
    V()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, 'LOUD' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_BlockVar_BasicScopeAndInit;
const
  Src =
  '''
  program P;
  procedure Run;
  begin
    begin
      var X: Integer := 40;
      X := X + 2;
      WriteLn(X)
    end
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_BlockVar_InitRunsPerIteration;
const
  { The declaration statement re-initialises on every execution — each
    iteration starts from 10, so the accumulating += prints 11 three times. }
  Src =
  '''
  program P;
  procedure Run;
  var
    I: Integer;
  begin
    for I := 0 to 2 do
    begin
      var Acc: Integer := 10;
      Acc := Acc + 1;
      WriteLn(Acc)
    end
  end;
  begin
    Run()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '11' + LineEnding + '11' + LineEnding + '11' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_BlockVar_LoopSnapshotIdiom_012;
const
  { THE Phase-4 headline (design doc, Capture): a block-scoped var inside
    the loop body is a fresh binding per iteration — each closure gets its
    own environment, so the stored closures print 0, 1, 2. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  var
    A: TProc;
    B: TProc;
    C: TProc;
  procedure Run;
  var
    I: Integer;
  begin
    for I := 0 to 2 do
    begin
      var Snapshot: Integer := I;
      if I = 0 then A := procedure begin WriteLn(Snapshot) end;
      if I = 1 then B := procedure begin WriteLn(Snapshot) end;
      if I = 2 then C := procedure begin WriteLn(Snapshot) end
    end
  end;
  begin
    Run();
    A();
    B();
    C()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '0' + LineEnding + '1' + LineEnding + '2' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_LoopCapture_RoutineVar_Still333;
const
  { Capturing the ROUTINE-level loop variable still shares one env — the
    documented Delphi-compatible behaviour is unchanged by Phase 4. }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
  var
    A: TProc;
    B: TProc;
  procedure Run;
  var
    I: Integer;
  begin
    for I := 0 to 2 do
    begin
      if I = 0 then A := procedure begin WriteLn(I) end;
      if I = 1 then B := procedure begin WriteLn(I) end
    end
  end;
  begin
    Run();
    A();
    B()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '3' + LineEnding + '3' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_WeakSelf_ReadsNilAfterReceiverDies;
const
  { [Weak Self]: the env's Self slot is registered in the weak table and
    auto-nil'd when the receiver dies — the closure observes nil instead of
    a dangling pointer (same contract as a [Weak] field). }
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
    TBox = class
      FValue: Integer;
      procedure Wire;
    end;
  var
    G: TProc;
  procedure TBox.Wire;
  begin
    G := procedure [Weak Self]
    begin
      if Self = nil then
        WriteLn('gone')
      else
        WriteLn(FValue)
    end
  end;
  procedure Run;
  var
    B: TBox;
  begin
    B := TBox.Create();
    B.FValue := 42;
    B.Wire();
    G()
  end;
  begin
    Run();
    G()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '42' + LineEnding + 'gone' + LineEnding, 0);
end;

procedure TE2EAnonMethodTests.TestRun_WeakSelf_WorksWhileReceiverAlive;
const
  Src =
  '''
  program P;
  type
    TProc = reference to procedure;
    TCounter = class
      FCount: Integer;
      procedure Wire;
    end;
  var
    G: TProc;
    C: TCounter;
  procedure TCounter.Wire;
  begin
    G := procedure [Weak Self]
    begin
      FCount := FCount + 21;
      WriteLn(FCount)
    end
  end;
  begin
    C := TCounter.Create();
    C.Wire();
    G();
    G()
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '21' + LineEnding + '42' + LineEnding, 0);
end;

initialization
  RegisterTest(TE2EAnonMethodTests);

end.
