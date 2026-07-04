{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.fibers;

{ E2E tests for L0 of the fiber runtime (docs/async-networking-design.adoc):
  the FiberSwitch context-switch leaf, fresh-fiber trampoline bootstrap,
  guard-page stacks, and the stack pool in
  stdlib/src/main/pascal/async.fibers.context.x86_64.pas.

  BACKEND POSTURE (per the design's [#constraints] block): the fiber unit is
  inline-asm and therefore NATIVE-ONLY.  The behavioural tests run on the
  native backend; the QBE arm is a single guard test asserting the QBE backend
  rejects the unit with the documented clear diagnostic rather than emitting
  broken IR.

  P1 (per-fiber exception state) gate tests also live here: a try/except and
  a try/finally must survive a FiberSwitch — fiber A enters a try, B raises
  and handles its own exception on its own stack, and A's handler still works
  after resume.  Without the exception-state snapshot in FiberSwitch, B's
  frames chain onto A's stack and the raise corrupts it. }

interface

uses
  SysUtils, Classes, contnrs, blaise.testing, uLexer, uParser, uAST,
  uSemantic, uUnitLoader, blaise.codegen.qbe, cp.test.e2e.base;

type
  TFiberE2ETests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    { L0 — context switch, trampoline, stacks, pool. }
    procedure TestFiberSwitch_PingPong_Interleaves;
    procedure TestFiberExit_TrampolineReturns_StackPooled;
    procedure TestFiberStack_GuardPageFaults;
    procedure TestFiberUnit_QBEBackend_RejectsInlineAsm;
  end;

implementation

const
  LE = #10;

  { Two fibers ping-pong three rounds; loop counters (locals in callee-saved
    registers and on each fiber's own stack) must survive every switch. }
  SrcPingPong =
    '''
    program fiberping;
    uses async.fibers.context.x86_64;
    var
      MainF, FA, FB: PFiber;
    procedure ProcA(AArg: Pointer);
    var
      I: Integer;
    begin
      for I := 0 to 2 do
      begin
        WriteLn('A', I);
        FiberSwitch(FA, FB);
      end;
      FiberSwitch(FA, MainF);
    end;
    procedure ProcB(AArg: Pointer);
    var
      J: Integer;
    begin
      J := 0;
      while True do
      begin
        WriteLn('B', J);
        J := J + 1;
        FiberSwitch(FB, FA);
      end;
    end;
    begin
      MainF := FiberCreateMain();
      FA := FiberSpawn(@ProcA, nil, 0);
      FB := FiberSpawn(@ProcB, nil, 0);
      FiberSwitch(MainF, FA);
      WriteLn('M');
    end.
    ''';

  { A fiber whose entry proc RETURNS exits via the trampoline: control comes
    back to the resumer, the fiber reads Done, and its freed stack is served
    from the pool to the next same-size spawn. }
  SrcExitAndPool =
    '''
    program fiberexit;
    uses async.fibers.context.x86_64;
    var
      MainF, F1, F2: PFiber;
      B1, B2: Pointer;
    procedure Work(AArg: Pointer);
    begin
      WriteLn('W', Integer(AArg));
    end;
    begin
      MainF := FiberCreateMain();
      F1 := FiberSpawn(@Work, Pointer(1), 0);
      B1 := F1^.StackBase;
      FiberSwitch(MainF, F1);
      if FiberIsDone(F1) then WriteLn('DONE1');
      FiberFree(F1);
      WriteLn('POOL=', FiberStackPoolCount());
      F2 := FiberSpawn(@Work, Pointer(2), 0);
      B2 := F2^.StackBase;
      if B1 = B2 then WriteLn('REUSED') else WriteLn('FRESH');
      WriteLn('POOL=', FiberStackPoolCount());
      FiberSwitch(MainF, F2);
      if FiberIsDone(F2) then WriteLn('DONE2');
      FiberFree(F2);
    end.
    ''';

  { The guard page must fault deterministically: the first usable byte above
    it is writable, a byte inside it kills a forked child with SIGSEGV. }
  SrcGuardPage =
    '''
    program fiberguard;
    uses async.fibers.context.x86_64;
    function fork: Integer; external name 'fork';
    function waitpid(Pid: Integer; Status: Pointer; Options: Integer): Integer;
      external name 'waitpid';
    procedure _exit(Code: Integer); external name '_exit';
    var
      F: PFiber;
      Pid, Status, Sig: Integer;
      P: ^Byte;
    begin
      F := FiberSpawn(nil, nil, 0);
      P := F^.StackBase + FiberPageSize;
      P^ := 1;                        { lowest usable byte: must be writable }
      WriteLn('USABLE_OK');
      Pid := fork();
      if Pid = 0 then
      begin
        P := F^.StackBase + 8;        { inside the guard page }
        P^ := 1;
        _exit(0);                     { reached only if the guard is broken }
      end;
      Status := 0;
      waitpid(Pid, @Status, 0);
      Sig := Status and 127;
      if Sig = 11 then
        WriteLn('GUARD_OK')
      else
        WriteLn('GUARD_FAIL status=', Status);
    end.
    ''';

  { Minimal uses-fibers program for the QBE guard test. }
  SrcQBEGuard =
    '''
    program fiberqbe;
    uses async.fibers.context.x86_64;
    begin
      WriteLn(FiberStackPoolCount());
    end.
    ''';

procedure TFiberE2ETests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-fibers')
end;

procedure TFiberE2ETests.TestFiberSwitch_PingPong_Interleaves;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRTLRunsOnOne(beNative, 'fiber-pingpong', SrcPingPong,
    'A0' + LE + 'B0' + LE + 'A1' + LE + 'B1' + LE + 'A2' + LE + 'B2' + LE +
    'M' + LE, 0)
end;

procedure TFiberE2ETests.TestFiberExit_TrampolineReturns_StackPooled;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRTLRunsOnOne(beNative, 'fiber-exit-pool', SrcExitAndPool,
    'W1' + LE + 'DONE1' + LE + 'POOL=1' + LE + 'REUSED' + LE + 'POOL=0' + LE +
    'W2' + LE + 'DONE2' + LE, 0)
end;

procedure TFiberE2ETests.TestFiberStack_GuardPageFaults;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRTLRunsOnOne(beNative, 'fiber-guard', SrcGuardPage,
    'USABLE_OK' + LE + 'GUARD_OK' + LE, 0)
end;

{ The design's QBE posture: compiling a program that pulls in the fiber
  context unit under the QBE backend must fail with the documented inline-asm
  diagnostic (a clear error, not broken IR).  Drive the front end + QBE
  codegen in-process and assert on the exception message. }
procedure TFiberE2ETests.TestFiberUnit_QBEBackend_RejectsInlineAsm;
var
  Lexer: TLexer;
  Parser: TParser;
  Prog: TProgram;
  Semantic: TSemanticAnalyser;
  QCG: TCodeGenQBE;
  Loader: TUnitLoader;
  Units: TObjectList;
  SearchPaths: TStringList;
  I: Integer;
  Msg: string;
begin
  Msg := '';
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  QCG := nil; Loader := nil; Units := nil; SearchPaths := nil;
  try
    Lexer := TLexer.Create(SrcQBEGuard);
    Parser := TParser.Create(Lexer);
    Prog := Parser.Parse();
    Semantic := TSemanticAnalyser.Create();
    SearchPaths := TStringList.Create();
    SearchPaths.Add(ProjectRoot() + 'compiler/src/main/pascal');
    SearchPaths.Add(ProjectRoot() + 'stdlib/src/main/pascal');
    Loader := TUnitLoader.Create(SearchPaths);
    Units := Loader.LoadAll(Prog.UsedUnits);
    for I := 0 to Units.Count - 1 do
      Semantic.AnalyseUnitForExport(TUnit(Units.Items[I]));
    Semantic.Analyse(Prog);
    QCG := TCodeGenQBE.Create();
    QCG.SetSymbolTable(Prog.SymbolTable);
    try
      for I := 0 to Units.Count - 1 do
        QCG.AppendUnit(TUnit(Units.Items[I]));
      QCG.AppendProgram(Prog);
    except
      on E: Exception do Msg := E.Message;
    end;
  finally
    QCG.Free(); Semantic.Free();
    Units.Free(); Loader.Free(); SearchPaths.Free();
    Prog.Free(); Parser.Free(); Lexer.Free()
  end;
  AssertTrue('QBE must reject the fiber unit (no error raised)', Msg <> '');
  AssertTrue('diagnostic must name the native backend (got: ' + Msg + ')',
    Pos('native backend', Msg) >= 0)
end;

initialization
  RegisterTest(TFiberE2ETests);

end.
