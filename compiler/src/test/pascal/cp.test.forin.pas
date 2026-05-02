{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

unit cp.test.forin;

{$mode objfpc}{$H+}

{ Tests for for..in loop with class-based enumerators (GetEnumerator protocol). }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TForInTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    procedure AnalyseExpectError(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_ForIn_IsTForInStmt;
    procedure TestParse_ForIn_VarName;
    procedure TestParse_ForIn_CollExprIsIdent;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_ForIn_Valid_OK;
    procedure TestSemantic_ForIn_NoGetEnumerator_RaisesError;
    procedure TestSemantic_ForIn_MoveNextNotBoolean_RaisesError;
    procedure TestSemantic_ForIn_NoCurrent_RaisesError;
    procedure TestSemantic_ForIn_VarTypeMismatch_RaisesError;
    procedure TestSemantic_ForIn_CollNotClass_RaisesError;

    { ------------------------------------------------------------------ }
    { Codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_ForIn_HasForInCondLabel;
    procedure TestCodegen_ForIn_HasForInBodyLabel;
    procedure TestCodegen_ForIn_HasForInEndLabel;
    procedure TestCodegen_ForIn_CallsGetEnumerator;
    procedure TestCodegen_ForIn_CallsMoveNext;
    procedure TestCodegen_ForIn_CallsGetCurrent;
    procedure TestCodegen_ForIn_JnzOnMoveNextResult;
    procedure TestCodegen_ForIn_JumpsBackToCond;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TForInTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Result := P.Parse;
  finally
    P.Free; L.Free;
  end;
end;

function TForInTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try
    A.Analyse(Result);
  finally
    A.Free;
  end;
end;

function TForInTests.GenIR(const ASrc: string): string;
var Prog: TProgram; CG: TCodeGenQBE;
begin
  Prog := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create;
    try
      CG.Generate(Prog);
      Result := CG.GetOutput;
    finally
      CG.Free;
    end;
  finally
    Prog.Free;
  end;
end;

procedure TForInTests.AnalyseExpectError(const ASrc: string);
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

{ ------------------------------------------------------------------ }
{ Shared source — minimal enumerator+collection pair                  }
{ ------------------------------------------------------------------ }

const
  SrcEnumTypes =
    'type'                                                    + LineEnding +
    '  TMyEnum = class'                                       + LineEnding +
    '    FCurrent: Integer;'                                  + LineEnding +
    '    function MoveNext: Boolean;'                         + LineEnding +
    '    function GetCurrent: Integer;'                       + LineEnding +
    '    property Current: Integer read GetCurrent;'          + LineEnding +
    '  end;'                                                  + LineEnding +
    '  TMyCol = class'                                        + LineEnding +
    '    function GetEnumerator: TMyEnum;'                    + LineEnding +
    '  end;';

  SrcForIn =
    'program P;'                                              + LineEnding +
    SrcEnumTypes                                              + LineEnding +
    'var'                                                     + LineEnding +
    '  Col: TMyCol;'                                          + LineEnding +
    '  X:   Integer;'                                         + LineEnding +
    'begin'                                                   + LineEnding +
    '  for X in Col do'                                       + LineEnding +
    '    X := X + 1'                                          + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestParse_ForIn_IsTForInStmt;
var Prog: TProgram;
begin
  Prog := ParseSrc(SrcForIn);
  try
    AssertTrue('stmt is TForInStmt',
      Prog.Block.Stmts[0] is TForInStmt);
  finally
    Prog.Free;
  end;
end;

procedure TForInTests.TestParse_ForIn_VarName;
var Prog: TProgram; FS: TForInStmt;
begin
  Prog := ParseSrc(SrcForIn);
  try
    FS := TForInStmt(Prog.Block.Stmts[0]);
    AssertEquals('loop var is X', 'X', FS.VarName);
  finally
    Prog.Free;
  end;
end;

procedure TForInTests.TestParse_ForIn_CollExprIsIdent;
var Prog: TProgram; FS: TForInStmt;
begin
  Prog := ParseSrc(SrcForIn);
  try
    FS := TForInStmt(Prog.Block.Stmts[0]);
    AssertTrue('collection is TIdentExpr', FS.CollExpr is TIdentExpr);
    AssertEquals('collection name is Col', 'Col',
      TIdentExpr(FS.CollExpr).Name);
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                       }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestSemantic_ForIn_Valid_OK;
begin
  AnalyseSrc(SrcForIn).Free;
end;

procedure TForInTests.TestSemantic_ForIn_NoGetEnumerator_RaisesError;
begin
  AnalyseExpectError(
    'program P;'                                              + LineEnding +
    'type'                                                    + LineEnding +
    '  TBadCol = class'                                       + LineEnding +
    '    FCount: Integer;'                                    + LineEnding +
    '  end;'                                                  + LineEnding +
    'var'                                                     + LineEnding +
    '  Col: TBadCol;'                                         + LineEnding +
    '  X:   Integer;'                                         + LineEnding +
    'begin'                                                   + LineEnding +
    '  for X in Col do'                                       + LineEnding +
    '    X := X + 1'                                          + LineEnding +
    'end.');
end;

procedure TForInTests.TestSemantic_ForIn_MoveNextNotBoolean_RaisesError;
begin
  AnalyseExpectError(
    'program P;'                                              + LineEnding +
    'type'                                                    + LineEnding +
    '  TBadEnum = class'                                      + LineEnding +
    '    function MoveNext: Integer;'                         + LineEnding +
    '    function GetCurrent: Integer;'                       + LineEnding +
    '    property Current: Integer read GetCurrent;'          + LineEnding +
    '  end;'                                                  + LineEnding +
    '  TBadCol = class'                                       + LineEnding +
    '    function GetEnumerator: TBadEnum;'                   + LineEnding +
    '  end;'                                                  + LineEnding +
    'var'                                                     + LineEnding +
    '  Col: TBadCol;'                                         + LineEnding +
    '  X:   Integer;'                                         + LineEnding +
    'begin'                                                   + LineEnding +
    '  for X in Col do'                                       + LineEnding +
    '    X := X + 1'                                          + LineEnding +
    'end.');
end;

procedure TForInTests.TestSemantic_ForIn_NoCurrent_RaisesError;
begin
  AnalyseExpectError(
    'program P;'                                              + LineEnding +
    'type'                                                    + LineEnding +
    '  TBadEnum = class'                                      + LineEnding +
    '    function MoveNext: Boolean;'                         + LineEnding +
    '  end;'                                                  + LineEnding +
    '  TBadCol = class'                                       + LineEnding +
    '    function GetEnumerator: TBadEnum;'                   + LineEnding +
    '  end;'                                                  + LineEnding +
    'var'                                                     + LineEnding +
    '  Col: TBadCol;'                                         + LineEnding +
    '  X:   Integer;'                                         + LineEnding +
    'begin'                                                   + LineEnding +
    '  for X in Col do'                                       + LineEnding +
    '    X := X + 1'                                          + LineEnding +
    'end.');
end;

procedure TForInTests.TestSemantic_ForIn_VarTypeMismatch_RaisesError;
begin
  AnalyseExpectError(
    'program P;'                                              + LineEnding +
    SrcEnumTypes                                              + LineEnding +
    'var'                                                     + LineEnding +
    '  Col: TMyCol;'                                          + LineEnding +
    '  X:   string;'                                          + LineEnding +
    'begin'                                                   + LineEnding +
    '  for X in Col do'                                       + LineEnding +
    '    X := X'                                              + LineEnding +
    'end.');
end;

procedure TForInTests.TestSemantic_ForIn_CollNotClass_RaisesError;
begin
  AnalyseExpectError(
    'program P;'                                              + LineEnding +
    'var'                                                     + LineEnding +
    '  X: Integer;'                                           + LineEnding +
    'begin'                                                   + LineEnding +
    '  for X in X do'                                         + LineEnding +
    '    X := X + 1'                                          + LineEnding +
    'end.');
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                        }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestCodegen_ForIn_HasForInCondLabel;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('forin_cond label present', Pos('forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_HasForInBodyLabel;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('forin_body label present', Pos('forin_body', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_HasForInEndLabel;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('forin_end label present', Pos('forin_end', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_CallsGetEnumerator;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('GetEnumerator called in IR',
    Pos('TMyCol_GetEnumerator', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_CallsMoveNext;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('MoveNext called in IR', Pos('TMyEnum_MoveNext', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_CallsGetCurrent;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('GetCurrent called in IR', Pos('TMyEnum_GetCurrent', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_JnzOnMoveNextResult;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('jnz on MoveNext result', Pos('jnz', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_JumpsBackToCond;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('jmp back to forin_cond', Pos('jmp @forin_cond', IR) > 0);
end;

initialization
  RegisterTest(TForInTests);

end.
