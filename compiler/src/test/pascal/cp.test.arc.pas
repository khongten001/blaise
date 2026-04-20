unit cp.test.arc;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSemantic, uCodeGenQBE;

type
  TARCTests = class(TTestCase)
  private
    function GenIR(const ASrc: string): string;
    function IRContains(const AIR, AFragment: string): Boolean;
  published
    { String variable assignment inserts retain before release }
    procedure TestARC_StringAssign_CallsRetain;
    procedure TestARC_StringAssign_CallsRelease;
    procedure TestARC_StringAssign_RetainBeforeRelease;

    { Block exit releases all string variables }
    procedure TestARC_StringVar_BlockExitRelease;
    procedure TestARC_TwoStringVars_BothReleasedAtExit;

    { Integer assignment has no ARC calls }
    procedure TestARC_IntAssign_NoRetain;
    procedure TestARC_IntAssign_NoRelease;

    { WriteLn of string literal still works }
    procedure TestARC_WriteLn_StringLit_StillWorks;

    { String variable passed to WriteLn (load + printf) }
    procedure TestARC_WriteLn_StringVar_Works;
  end;

implementation

function TARCTests.GenIR(const ASrc: string): string;
var
  L:  TLexer;
  P:  TParser;
  Pr: TProgram;
  A:  TSemanticAnalyser;
  CG: TCodeGenQBE;
begin
  L  := TLexer.Create(ASrc);
  P  := TParser.Create(L);
  Pr := P.Parse;
  A  := TSemanticAnalyser.Create;
  try
    A.Analyse(Pr);
  finally
    A.Free;
  end;
  CG := TCodeGenQBE.Create;
  try
    CG.Generate(Pr);
    Result := CG.GetOutput;
  finally
    CG.Free;
    Pr.Free;
    P.Free;
    L.Free;
  end;
end;

function TARCTests.IRContains(const AIR, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AIR) > 0;
end;

{ ------------------------------------------------------------------ }

procedure TARCTests.TestARC_StringAssign_CallsRetain;
var
  IR: string;
begin
  IR := GenIR(
    'program P;'         + LineEnding +
    'var s: string;'     + LineEnding +
    'begin'              + LineEnding +
    '  s := ''hello'''   + LineEnding +
    'end.');
  AssertTrue('retain call present', IRContains(IR, 'call $_StringAddRef'));
end;

procedure TARCTests.TestARC_StringAssign_CallsRelease;
var
  IR: string;
begin
  IR := GenIR(
    'program P;'         + LineEnding +
    'var s: string;'     + LineEnding +
    'begin'              + LineEnding +
    '  s := ''hello'''   + LineEnding +
    'end.');
  AssertTrue('release call present', IRContains(IR, 'call $_StringRelease'));
end;

procedure TARCTests.TestARC_StringAssign_RetainBeforeRelease;
var
  IR:     string;
  PosTain, PosLease: Integer;
begin
  IR := GenIR(
    'program P;'         + LineEnding +
    'var s: string;'     + LineEnding +
    'begin'              + LineEnding +
    '  s := ''hello'''   + LineEnding +
    'end.');
  PosTain  := Pos('call $_StringAddRef', IR);
  PosLease := Pos('call $_StringRelease', IR);
  AssertTrue('retain before first release', PosTain < PosLease);
end;

procedure TARCTests.TestARC_StringVar_BlockExitRelease;
var
  IR: string;
begin
  IR := GenIR(
    'program P;'         + LineEnding +
    'var s: string;'     + LineEnding +
    'begin end.');
  AssertTrue('release at block exit', IRContains(IR, 'call $_StringRelease'));
end;

procedure TARCTests.TestARC_TwoStringVars_BothReleasedAtExit;
var
  IR:    string;
  Count: Integer;
  Pos1, Pos2: Integer;
begin
  IR := GenIR(
    'program P;'            + LineEnding +
    'var a, b: string;'     + LineEnding +
    'begin end.');
  { Two string vars → two release calls at exit }
  Pos1 := Pos('call $_StringRelease', IR);
  AssertTrue('at least one release', Pos1 > 0);
  Pos2 := Pos('call $_StringRelease', IR, Pos1 + 1);
  AssertTrue('second release', Pos2 > 0);
  Count := 0;
  Pos1 := 1;
  repeat
    Pos1 := Pos('call $_StringRelease', IR, Pos1);
    if Pos1 > 0 then begin Inc(Count); Inc(Pos1); end;
  until Pos1 = 0;
  AssertTrue('at least 2 releases', Count >= 2);
end;

procedure TARCTests.TestARC_IntAssign_NoRetain;
var
  IR: string;
begin
  IR := GenIR(
    'program P;'         + LineEnding +
    'var n: Integer;'    + LineEnding +
    'begin'              + LineEnding +
    '  n := 42'          + LineEnding +
    'end.');
  AssertFalse('no retain for int', IRContains(IR, 'call $_StringAddRef'));
end;

procedure TARCTests.TestARC_IntAssign_NoRelease;
var
  IR: string;
begin
  IR := GenIR(
    'program P;'         + LineEnding +
    'var n: Integer;'    + LineEnding +
    'begin'              + LineEnding +
    '  n := 42'          + LineEnding +
    'end.');
  AssertFalse('no release for int', IRContains(IR, 'call $_StringRelease'));
end;

procedure TARCTests.TestARC_WriteLn_StringLit_StillWorks;
var
  IR: string;
begin
  IR := GenIR('program P; begin WriteLn(''Hello'') end.');
  AssertTrue('printf still called', IRContains(IR, 'call $printf'));
  AssertTrue('data section present', IRContains(IR, 'data $__s0'));
end;

procedure TARCTests.TestARC_WriteLn_StringVar_Works;
var
  IR: string;
begin
  IR := GenIR(
    'program P;'         + LineEnding +
    'var s: string;'     + LineEnding +
    'begin'              + LineEnding +
    '  s := ''world'';'  + LineEnding +
    '  WriteLn(s)'       + LineEnding +
    'end.');
  AssertTrue('printf called', IRContains(IR, 'call $printf'));
end;

initialization
  RegisterTest(TARCTests);

end.
