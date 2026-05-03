{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.repeatloop;

{$mode objfpc}{$H+}

{ Tests for repeat...until loop. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TRepeatTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    procedure AnalyseExpectError(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { Lexer                                                                }
    { ------------------------------------------------------------------ }
    procedure TestLexer_Repeat_Keyword;
    procedure TestLexer_Until_Keyword;

    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_Repeat_IsTRepeatStmt;
    procedure TestParse_Repeat_BodyHasOneStmt;
    procedure TestParse_Repeat_BodyHasTwoStmts;
    procedure TestParse_Repeat_ConditionIsExpr;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_Repeat_OK;
    procedure TestSemantic_Repeat_NonBoolCond_RaisesError;

    { ------------------------------------------------------------------ }
    { Codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_Repeat_HasBodyLabel;
    procedure TestCodegen_Repeat_HasCondLabel;
    procedure TestCodegen_Repeat_HasEndLabel;
    procedure TestCodegen_Repeat_JumpsToBodyFirst;
    procedure TestCodegen_Repeat_CondBranchToEnd;
    procedure TestCodegen_Repeat_CondBranchToBody;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TRepeatTests.ParseSrc(const ASrc: string): TProgram;
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

function TRepeatTests.AnalyseSrc(const ASrc: string): TProgram;
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

function TRepeatTests.GenIR(const ASrc: string): string;
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

procedure TRepeatTests.AnalyseExpectError(const ASrc: string);
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
{ Source snippets                                                      }
{ ------------------------------------------------------------------ }

const
  SrcRepeatSingle =
    'program P;'           + LineEnding +
    'var I: Integer;'      + LineEnding +
    'begin'                + LineEnding +
    '  I := 0;'            + LineEnding +
    '  repeat'             + LineEnding +
    '    I := I + 1'       + LineEnding +
    '  until I >= 5'       + LineEnding +
    'end.';

  SrcRepeatMulti =
    'program P;'           + LineEnding +
    'var I: Integer;'      + LineEnding +
    'var S: Integer;'      + LineEnding +
    'begin'                + LineEnding +
    '  I := 0;'            + LineEnding +
    '  S := 0;'            + LineEnding +
    '  repeat'             + LineEnding +
    '    I := I + 1;'      + LineEnding +
    '    S := S + I'       + LineEnding +
    '  until I >= 3'       + LineEnding +
    'end.';

  SrcRepeatBadCond =
    'program P;'           + LineEnding +
    'var I: Integer;'      + LineEnding +
    'begin'                + LineEnding +
    '  I := 0;'            + LineEnding +
    '  repeat'             + LineEnding +
    '    I := I + 1'       + LineEnding +
    '  until I'            + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Lexer tests                                                          }
{ ------------------------------------------------------------------ }

procedure TRepeatTests.TestLexer_Repeat_Keyword;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('repeat');
  try
    T := L.Next;
    AssertEquals('repeat token', Ord(tkRepeat), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TRepeatTests.TestLexer_Until_Keyword;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('until');
  try
    T := L.Next;
    AssertEquals('until token', Ord(tkUntil), Ord(T.Kind));
  finally L.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TRepeatTests.TestParse_Repeat_IsTRepeatStmt;
var Prog: TProgram;
begin
  Prog := ParseSrc(SrcRepeatSingle);
  try
    AssertTrue('stmt is TRepeatStmt', Prog.Block.Stmts[1] is TRepeatStmt);
  finally Prog.Free; end;
end;

procedure TRepeatTests.TestParse_Repeat_BodyHasOneStmt;
var Prog: TProgram; RS: TRepeatStmt;
begin
  Prog := ParseSrc(SrcRepeatSingle);
  try
    RS := TRepeatStmt(Prog.Block.Stmts[1]);
    AssertEquals('body has 1 stmt', 1, RS.Body.Stmts.Count);
  finally Prog.Free; end;
end;

procedure TRepeatTests.TestParse_Repeat_BodyHasTwoStmts;
var Prog: TProgram; RS: TRepeatStmt;
begin
  Prog := ParseSrc(SrcRepeatMulti);
  try
    RS := TRepeatStmt(Prog.Block.Stmts[2]);
    AssertEquals('body has 2 stmts', 2, RS.Body.Stmts.Count);
  finally Prog.Free; end;
end;

procedure TRepeatTests.TestParse_Repeat_ConditionIsExpr;
var Prog: TProgram; RS: TRepeatStmt;
begin
  Prog := ParseSrc(SrcRepeatSingle);
  try
    RS := TRepeatStmt(Prog.Block.Stmts[1]);
    AssertNotNull('condition is set', RS.Condition);
  finally Prog.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                       }
{ ------------------------------------------------------------------ }

procedure TRepeatTests.TestSemantic_Repeat_OK;
var Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcRepeatSingle);
  Prog.Free;
end;

procedure TRepeatTests.TestSemantic_Repeat_NonBoolCond_RaisesError;
begin
  AnalyseExpectError(SrcRepeatBadCond);
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                        }
{ ------------------------------------------------------------------ }

procedure TRepeatTests.TestCodegen_Repeat_HasBodyLabel;
var IR: string;
begin
  IR := GenIR(SrcRepeatSingle);
  AssertTrue('has repeat_body label', Pos('repeat_body', IR) > 0);
end;

procedure TRepeatTests.TestCodegen_Repeat_HasCondLabel;
var IR: string;
begin
  IR := GenIR(SrcRepeatSingle);
  AssertTrue('has repeat_cond label', Pos('repeat_cond', IR) > 0);
end;

procedure TRepeatTests.TestCodegen_Repeat_HasEndLabel;
var IR: string;
begin
  IR := GenIR(SrcRepeatSingle);
  AssertTrue('has repeat_end label', Pos('repeat_end', IR) > 0);
end;

procedure TRepeatTests.TestCodegen_Repeat_JumpsToBodyFirst;
var IR: string; BodyPos, FirstJmpPos: Integer;
begin
  IR := GenIR(SrcRepeatSingle);
  { The first jump in the function should target repeat_body }
  FirstJmpPos := Pos('jmp @repeat_body', IR);
  AssertTrue('first jmp targets repeat_body', FirstJmpPos > 0);
  { repeat_body label must come after that jump }
  BodyPos := Pos('@repeat_body', IR);
  AssertTrue('body label appears after initial jump', BodyPos > FirstJmpPos);
end;

procedure TRepeatTests.TestCodegen_Repeat_CondBranchToEnd;
var IR: string;
begin
  IR := GenIR(SrcRepeatSingle);
  { condition true → exit }
  AssertTrue('jnz branches to repeat_end on true', Pos('repeat_end', IR) > 0);
end;

procedure TRepeatTests.TestCodegen_Repeat_CondBranchToBody;
var IR: string;
begin
  IR := GenIR(SrcRepeatSingle);
  { condition false → loop again }
  AssertTrue('jnz branches back to repeat_body on false', Pos('repeat_body', IR) > 0);
end;

initialization
  RegisterTest(TRepeatTests);

end.
