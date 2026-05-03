{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.flowjumps;

{$mode objfpc}{$H+}

{ Tests for non-local flow statements: Exit and Break. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TFlowJumpsTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    procedure AnalyseExpectError(const ASrc: string);
  published
    procedure TestLexer_Exit_Keyword;
    procedure TestLexer_Break_Keyword;
    procedure TestParse_Exit_IsExitStmt;
    procedure TestParse_Break_IsBreakStmt;
    procedure TestSemantic_Break_OutsideLoop_RaisesError;
    procedure TestSemantic_Break_InsideFor_Resolves;
    procedure TestSemantic_Break_InsideWhile_Resolves;
    procedure TestCodegen_Exit_EmitsJmpToExitLabel;
    procedure TestCodegen_Break_InFor_EmitsJmpToLoopEnd;
    procedure TestCodegen_Break_InWhile_EmitsJmpToLoopEnd;
    procedure TestCodegen_Exit_FromFunction_JumpsToFuncExit;
  end;

implementation

function TFlowJumpsTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try Result := P.Parse; finally P.Free; L.Free; end;
end;

function TFlowJumpsTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try A.Analyse(Result); finally A.Free; end;
end;

function TFlowJumpsTests.GenIR(const ASrc: string): string;
var Prog: TProgram; CG: TCodeGenQBE;
begin
  Prog := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create;
    try CG.Generate(Prog); Result := CG.GetOutput; finally CG.Free; end;
  finally Prog.Free; end;
end;

procedure TFlowJumpsTests.AnalyseExpectError(const ASrc: string);
var Prog: TProgram;
begin
  try
    Prog := AnalyseSrc(ASrc);
    Prog.Free;
    Fail('Expected ESemanticError');
  except
    on E: ESemanticError do ;
  end;
end;

const
  SrcExit =
    'program P;'                    + LineEnding +
    'var I: Integer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  I := 1;'                     + LineEnding +
    '  if I = 1 then exit;'         + LineEnding +
    '  I := 2'                      + LineEnding +
    'end.';

  SrcBreakInFor =
    'program P;'                    + LineEnding +
    'var I: Integer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  for I := 1 to 10 do'         + LineEnding +
    '  begin'                       + LineEnding +
    '    if I > 5 then break'       + LineEnding +
    '  end'                         + LineEnding +
    'end.';

  SrcBreakInWhile =
    'program P;'                    + LineEnding +
    'var I: Integer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  I := 0;'                     + LineEnding +
    '  while I < 100 do'            + LineEnding +
    '  begin'                       + LineEnding +
    '    if I = 5 then break;'      + LineEnding +
    '    I := I + 1'                + LineEnding +
    '  end'                         + LineEnding +
    'end.';

  SrcBreakOutsideLoop =
    'program P;'                    + LineEnding +
    'var I: Integer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  I := 0;'                     + LineEnding +
    '  break'                       + LineEnding +
    'end.';

  SrcExitFromFunc =
    'program P;'                              + LineEnding +
    'function Abs1(X: Integer): Integer;'     + LineEnding +
    'begin'                                   + LineEnding +
    '  if X < 0 then'                         + LineEnding +
    '  begin Result := 0 - X; exit end;'      + LineEnding +
    '  Result := X'                           + LineEnding +
    'end;'                                    + LineEnding +
    'var N: Integer;'                         + LineEnding +
    'begin'                                   + LineEnding +
    '  N := Abs1(-7)'                         + LineEnding +
    'end.';

procedure TFlowJumpsTests.TestLexer_Exit_Keyword;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('exit');
  try T := L.Next; AssertEquals(Ord(tkExit), Ord(T.Kind)); finally L.Free; end;
end;

procedure TFlowJumpsTests.TestLexer_Break_Keyword;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('break');
  try T := L.Next; AssertEquals(Ord(tkBreak), Ord(T.Kind)); finally L.Free; end;
end;

procedure TFlowJumpsTests.TestParse_Exit_IsExitStmt;
var Prog: TProgram; IfS: TIfStmt;
begin
  Prog := ParseSrc(SrcExit);
  try
    IfS := TIfStmt(Prog.Block.Stmts[1]);
    AssertTrue('then body is TExitStmt', IfS.ThenStmt is TExitStmt);
  finally Prog.Free; end;
end;

procedure TFlowJumpsTests.TestParse_Break_IsBreakStmt;
var
  Prog: TProgram;
  ForS: TForStmt;
  Cmp:  TCompoundStmt;
  IfS:  TIfStmt;
begin
  Prog := ParseSrc(SrcBreakInFor);
  try
    ForS := TForStmt(Prog.Block.Stmts[0]);
    Cmp  := TCompoundStmt(ForS.Body);
    IfS  := TIfStmt(Cmp.Stmts[0]);
    AssertTrue('then body is TBreakStmt', IfS.ThenStmt is TBreakStmt);
  finally Prog.Free; end;
end;

procedure TFlowJumpsTests.TestSemantic_Break_OutsideLoop_RaisesError;
begin
  AnalyseExpectError(SrcBreakOutsideLoop);
end;

procedure TFlowJumpsTests.TestSemantic_Break_InsideFor_Resolves;
var Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcBreakInFor);
  try AssertNotNull(Prog); finally Prog.Free; end;
end;

procedure TFlowJumpsTests.TestSemantic_Break_InsideWhile_Resolves;
var Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcBreakInWhile);
  try AssertNotNull(Prog); finally Prog.Free; end;
end;

procedure TFlowJumpsTests.TestCodegen_Exit_EmitsJmpToExitLabel;
var IR: string;
begin
  IR := GenIR(SrcExit);
  AssertTrue('emits jmp @main_exit', Pos('jmp @main_exit', IR) > 0);
  AssertTrue('has @main_exit label', Pos('@main_exit', IR) > 0);
end;

procedure TFlowJumpsTests.TestCodegen_Break_InFor_EmitsJmpToLoopEnd;
var IR: string;
begin
  IR := GenIR(SrcBreakInFor);
  AssertTrue('emits jmp @for_end', Pos('jmp @for_end', IR) > 0);
end;

procedure TFlowJumpsTests.TestCodegen_Break_InWhile_EmitsJmpToLoopEnd;
var IR: string;
begin
  IR := GenIR(SrcBreakInWhile);
  AssertTrue('emits jmp @while_end', Pos('jmp @while_end', IR) > 0);
end;

procedure TFlowJumpsTests.TestCodegen_Exit_FromFunction_JumpsToFuncExit;
var IR: string;
begin
  IR := GenIR(SrcExitFromFunc);
  AssertTrue('emits func_exit label', Pos('@func_exit', IR) > 0);
end;

initialization
  RegisterTest(TFlowJumpsTests);

end.
