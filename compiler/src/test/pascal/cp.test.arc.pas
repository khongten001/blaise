{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

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

    { String variable passed to WriteLn (load + _SysWriteStr) }
    procedure TestARC_WriteLn_StringVar_Works;

    { String value parameter: addref on entry, release on exit }
    procedure TestARC_StringValueParam_AddRefOnEntry;
    procedure TestARC_StringValueParam_ReleaseOnExit;

    { String var parameter: no addref, no release }
    procedure TestARC_StringVarParam_NoAddRef;
    procedure TestARC_StringVarParam_NoRelease;

    { String concatenation: calls RTL concat function }
    procedure TestARC_StringConcat_SemanticOK;
    procedure TestARC_StringConcat_CallsRTL;

    { Destroy as destructor hook: field cleanup fn invokes it }
    procedure TestARC_ClassDestroy_FieldCleanupCallsIt;
    procedure TestARC_ClassWithoutDestroy_FieldCleanupNoCall;
    procedure TestARC_GenericClass_Destroy_FieldCleanupCallsIt;
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
  AssertTrue('_SysWriteStr called', IRContains(IR, 'call $_SysWriteStr'));
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
  AssertTrue('_SysWriteStr called', IRContains(IR, 'call $_SysWriteStr'));
end;

const
  SrcValParam =
    'program P;'                  + LineEnding +
    'procedure Greet(S: string);' + LineEnding +
    'begin end;'                  + LineEnding +
    'begin end.';

  SrcVarParam =
    'program P;'                      + LineEnding +
    'procedure Greet(var S: string);' + LineEnding +
    'begin end;'                      + LineEnding +
    'begin end.';

  SrcConcat =
    'program P;'              + LineEnding +
    'var a, b, c: string;'   + LineEnding +
    'begin'                   + LineEnding +
    '  c := a + b'            + LineEnding +
    'end.';

procedure TARCTests.TestARC_StringValueParam_AddRefOnEntry;
var
  IR: string;
begin
  IR := GenIR(SrcValParam);
  AssertTrue('addref for string value param', IRContains(IR, 'call $_StringAddRef'));
end;

procedure TARCTests.TestARC_StringValueParam_ReleaseOnExit;
var
  IR: string;
begin
  IR := GenIR(SrcValParam);
  AssertTrue('release for string value param', IRContains(IR, 'call $_StringRelease'));
end;

procedure TARCTests.TestARC_StringVarParam_NoAddRef;
var
  IR: string;
begin
  IR := GenIR(SrcVarParam);
  AssertFalse('no addref for string var param', IRContains(IR, 'call $_StringAddRef'));
end;

procedure TARCTests.TestARC_StringVarParam_NoRelease;
var
  IR: string;
begin
  IR := GenIR(SrcVarParam);
  AssertFalse('no release for string var param', IRContains(IR, 'call $_StringRelease'));
end;

procedure TARCTests.TestARC_StringConcat_SemanticOK;
var
  L:  TLexer;
  P:  TParser;
  Pr: TProgram;
  A:  TSemanticAnalyser;
begin
  L  := TLexer.Create(SrcConcat);
  P  := TParser.Create(L);
  Pr := P.Parse;
  A  := TSemanticAnalyser.Create;
  try
    A.Analyse(Pr);
    AssertTrue('semantic analysis completed without error', True);
  finally
    A.Free;
    Pr.Free;
    P.Free;
    L.Free;
  end;
end;

procedure TARCTests.TestARC_StringConcat_CallsRTL;
var
  IR: string;
begin
  IR := GenIR(SrcConcat);
  AssertTrue('string concat calls RTL', IRContains(IR, '$_StringConcat'));
end;

{ ------------------------------------------------------------------ }
{ Destroy as destructor hook                                          }
{ ------------------------------------------------------------------ }

const
  SrcDestroyClass =
    'program P;'              + LineEnding +
    'type'                    + LineEnding +
    '  TBuf = class'          + LineEnding +
    '    FData: ^Integer;'    + LineEnding +
    '    procedure Destroy;'  + LineEnding +
    '  end;'                  + LineEnding +
    'procedure TBuf.Destroy;' + LineEnding +
    'begin'                   + LineEnding +
    '  FreeMem(Self.FData)'   + LineEnding +
    'end;'                    + LineEnding +
    'var B: TBuf;'            + LineEnding +
    'begin'                   + LineEnding +
    '  B := TBuf.Create'      + LineEnding +
    'end.';

  SrcNoDestroyClass =
    'program P;'            + LineEnding +
    'type'                  + LineEnding +
    '  TFoo = class'        + LineEnding +
    '    V: Integer;'       + LineEnding +
    '  end;'                + LineEnding +
    'var F: TFoo;'          + LineEnding +
    'begin'                 + LineEnding +
    '  F := TFoo.Create'    + LineEnding +
    'end.';

  SrcGenericDestroy =
    'program P;'                                           + LineEnding +
    'type'                                                 + LineEnding +
    '  TBox<T> = class'                                    + LineEnding +
    '    FData: ^T;'                                       + LineEnding +
    '    procedure Destroy;'                               + LineEnding +
    '  end;'                                               + LineEnding +
    'procedure TBox<T>.Destroy;'                           + LineEnding +
    'begin'                                                + LineEnding +
    '  FreeMem(Self.FData)'                                + LineEnding +
    'end;'                                                 + LineEnding +
    'var B: TBox<Integer>;'                                + LineEnding +
    'begin'                                                + LineEnding +
    '  B := TBox<Integer>.Create'                          + LineEnding +
    'end.';

procedure TARCTests.TestARC_ClassDestroy_FieldCleanupCallsIt;
var
  IR: string;
begin
  IR := GenIR(SrcDestroyClass);
  AssertTrue('field cleanup function calls Destroy',
    IRContains(IR, 'call $TBuf_Destroy'));
end;

procedure TARCTests.TestARC_ClassWithoutDestroy_FieldCleanupNoCall;
var
  IR: string;
begin
  IR := GenIR(SrcNoDestroyClass);
  AssertFalse('no Destroy call when method absent',
    IRContains(IR, 'call $TFoo_Destroy'));
end;

procedure TARCTests.TestARC_GenericClass_Destroy_FieldCleanupCallsIt;
var
  IR: string;
begin
  IR := GenIR(SrcGenericDestroy);
  AssertTrue('monomorphized field cleanup calls Destroy',
    IRContains(IR, 'call $TBox_Integer_Destroy'));
end;

initialization
  RegisterTest(TARCTests);

end.
