{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

unit cp.test.sets;

{$mode objfpc}{$H+}

{ Tests for Pascal set types — set of EnumType, set literals, in operator,
  Include/Exclude built-ins, and set arithmetic operators. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TSetTests = class(TTestCase)
  private
    function GenIR(const ASrc: string): string;
    procedure SemanticOK(const ASrc: string);
    procedure SemanticFail(const ASrc: string);
    procedure ParseOK(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { parse                                                                }
    { ------------------------------------------------------------------ }
    procedure TestParse_Set_SimpleDefinition;
    procedure TestParse_Set_EmptyLiteral;
    procedure TestParse_Set_TwoElementLiteral;
    procedure TestParse_Set_InOperator;
    procedure TestParse_Set_IncludeExclude;
    procedure TestParse_Set_ArithmeticOperators;
    procedure TestParse_Set_EqualityOperators;

    { ------------------------------------------------------------------ }
    { semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_Set_TypeRegistered;
    procedure TestSemantic_Set_VariableDecl_OK;
    procedure TestSemantic_Set_EmptyLiteralAssign_OK;
    procedure TestSemantic_Set_TwoElementLiteralAssign_OK;
    procedure TestSemantic_Set_InOperator_ResultIsBoolean;
    procedure TestSemantic_Set_Include_OK;
    procedure TestSemantic_Set_Exclude_OK;
    procedure TestSemantic_Set_Union_OK;
    procedure TestSemantic_Set_Difference_OK;
    procedure TestSemantic_Set_Intersection_OK;
    procedure TestSemantic_Set_Equality_OK;
    procedure TestSemantic_Set_BaseTypeMustBeEnum;
    procedure TestSemantic_Set_LiteralElementMustMatchBase;

    { ------------------------------------------------------------------ }
    { codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_Set_VarAllocsEmitsZero;
    procedure TestCodegen_Set_EmptyLiteralEmitsZero;
    procedure TestCodegen_Set_OneElementBitmask;
    procedure TestCodegen_Set_TwoElementBitmask;
    procedure TestCodegen_Set_InOperatorEmitsShrAndAnd;
    procedure TestCodegen_Set_IncludeEmitsShlAndOr;
    procedure TestCodegen_Set_ExcludeEmitsShlXorAnd;
    procedure TestCodegen_Set_UnionEmitsOr;
    procedure TestCodegen_Set_DifferenceEmitsXorAnd;
    procedure TestCodegen_Set_IntersectionEmitsAnd;
    procedure TestCodegen_Set_EqualityEmitsCeqw;
    procedure TestCodegen_Set_InequalityEmitsCnew;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Common source snippets                                               }
{ ------------------------------------------------------------------ }

const
  DirEnum =
    'type' + LineEnding +
    '  TDir = (dNorth, dSouth, dEast, dWest);' + LineEnding +
    '  TDirSet = set of TDir;' + LineEnding;

  { dNorth=0 → bit 0 = 1; dEast=2 → bit 2 = 4; mask = 5 }
  SrcSetTypeDecl =
    'program P;' + LineEnding +
    DirEnum +
    'begin' + LineEnding +
    'end.';

  SrcSetEmptyLiteral =
    'program P;' + LineEnding +
    DirEnum +
    'var S: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S := []' + LineEnding +
    'end.';

  SrcSetTwoElementLiteral =
    'program P;' + LineEnding +
    DirEnum +
    'var S: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S := [dNorth, dEast]' + LineEnding +   { mask = 1 + 4 = 5 }
    'end.';

  SrcSetInOperator =
    'program P;' + LineEnding +
    DirEnum +
    'var S: TDirSet; B: Boolean;' + LineEnding +
    'begin' + LineEnding +
    '  S := [dNorth, dEast];' + LineEnding +
    '  B := dNorth in S' + LineEnding +
    'end.';

  SrcSetInclude =
    'program P;' + LineEnding +
    DirEnum +
    'var S: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S := [];' + LineEnding +
    '  Include(S, dSouth)' + LineEnding +
    'end.';

  SrcSetExclude =
    'program P;' + LineEnding +
    DirEnum +
    'var S: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S := [dNorth, dSouth];' + LineEnding +
    '  Exclude(S, dNorth)' + LineEnding +
    'end.';

  SrcSetUnion =
    'program P;' + LineEnding +
    DirEnum +
    'var S1, S2, S3: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S1 := [dNorth];' + LineEnding +
    '  S2 := [dEast];' + LineEnding +
    '  S3 := S1 + S2' + LineEnding +
    'end.';

  SrcSetDifference =
    'program P;' + LineEnding +
    DirEnum +
    'var S1, S2, S3: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S1 := [dNorth, dEast];' + LineEnding +
    '  S2 := [dNorth];' + LineEnding +
    '  S3 := S1 - S2' + LineEnding +
    'end.';

  SrcSetIntersection =
    'program P;' + LineEnding +
    DirEnum +
    'var S1, S2, S3: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S1 := [dNorth, dEast];' + LineEnding +
    '  S2 := [dNorth];' + LineEnding +
    '  S3 := S1 * S2' + LineEnding +
    'end.';

  SrcSetEquality =
    'program P;' + LineEnding +
    DirEnum +
    'var S1, S2: TDirSet; B: Boolean;' + LineEnding +
    'begin' + LineEnding +
    '  S1 := [dNorth];' + LineEnding +
    '  S2 := [dNorth];' + LineEnding +
    '  B := S1 = S2' + LineEnding +
    'end.';

  SrcSetInequality =
    'program P;' + LineEnding +
    DirEnum +
    'var S1, S2: TDirSet; B: Boolean;' + LineEnding +
    'begin' + LineEnding +
    '  S1 := [dNorth];' + LineEnding +
    '  S2 := [dSouth];' + LineEnding +
    '  B := S1 <> S2' + LineEnding +
    'end.';

  SrcSetBadBaseType =
    'program P;' + LineEnding +
    'type TBad = set of Integer;' + LineEnding +
    'begin' + LineEnding +
    'end.';

  SrcSetBadLiteralElement =
    'program P;' + LineEnding +
    DirEnum +
    'type TColors = (cRed, cBlue);' + LineEnding +
    'type TColorSet = set of TColors;' + LineEnding +
    'var S: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S := [cRed]' + LineEnding +  { TColors element in TDirSet → error }
    'end.';

{ ------------------------------------------------------------------ }
{ Helpers                                                              }
{ ------------------------------------------------------------------ }

function TSetTests.GenIR(const ASrc: string): string;
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  CG:   TCodeGenQBE;
  Prog: TProgram;
begin
  Lex  := TLexer.Create(ASrc);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free; Lex.Free;
  SA   := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  CG   := TCodeGenQBE.Create;
  CG.Generate(Prog);
  Result := CG.GetOutput;
  CG.Free;
  Prog.Free;
end;

procedure TSetTests.SemanticOK(const ASrc: string);
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  Prog: TProgram;
begin
  Lex  := TLexer.Create(ASrc);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free; Lex.Free;
  SA   := TSemanticAnalyser.Create;
  try
    SA.Analyse(Prog);
  finally
    SA.Free;
    Prog.Free;
  end;
end;

procedure TSetTests.SemanticFail(const ASrc: string);
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  Prog: TProgram;
begin
  Lex  := TLexer.Create(ASrc);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free; Lex.Free;
  SA   := TSemanticAnalyser.Create;
  try
    SA.Analyse(Prog);
    Prog.Free;
    Fail('Expected ESemanticError but none was raised');
  except
    on E: ESemanticError do
    begin
      Prog.Free;
    end;
    on E: Exception do
    begin
      Prog.Free;
      raise;
    end;
  end;
  SA.Free;
end;

procedure TSetTests.ParseOK(const ASrc: string);
var
  Lex:  TLexer;
  Par:  TParser;
  Prog: TProgram;
begin
  Lex  := TLexer.Create(ASrc);
  Par  := TParser.Create(Lex);
  try
    Prog := Par.Parse;
    Prog.Free;
  finally
    Par.Free; Lex.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ parse                                                                }
{ ------------------------------------------------------------------ }

procedure TSetTests.TestParse_Set_SimpleDefinition;
begin
  ParseOK(SrcSetTypeDecl);
end;

procedure TSetTests.TestParse_Set_EmptyLiteral;
begin
  ParseOK(SrcSetEmptyLiteral);
end;

procedure TSetTests.TestParse_Set_TwoElementLiteral;
begin
  ParseOK(SrcSetTwoElementLiteral);
end;

procedure TSetTests.TestParse_Set_InOperator;
begin
  ParseOK(SrcSetInOperator);
end;

procedure TSetTests.TestParse_Set_IncludeExclude;
begin
  ParseOK(SrcSetInclude);
  ParseOK(SrcSetExclude);
end;

procedure TSetTests.TestParse_Set_ArithmeticOperators;
begin
  ParseOK(SrcSetUnion);
  ParseOK(SrcSetDifference);
  ParseOK(SrcSetIntersection);
end;

procedure TSetTests.TestParse_Set_EqualityOperators;
begin
  ParseOK(SrcSetEquality);
  ParseOK(SrcSetInequality);
end;

{ ------------------------------------------------------------------ }
{ semantic                                                             }
{ ------------------------------------------------------------------ }

procedure TSetTests.TestSemantic_Set_TypeRegistered;
begin
  SemanticOK(SrcSetTypeDecl);
end;

procedure TSetTests.TestSemantic_Set_VariableDecl_OK;
begin
  SemanticOK(SrcSetEmptyLiteral);
end;

procedure TSetTests.TestSemantic_Set_EmptyLiteralAssign_OK;
begin
  SemanticOK(SrcSetEmptyLiteral);
end;

procedure TSetTests.TestSemantic_Set_TwoElementLiteralAssign_OK;
begin
  SemanticOK(SrcSetTwoElementLiteral);
end;

procedure TSetTests.TestSemantic_Set_InOperator_ResultIsBoolean;
var
  Lex:    TLexer;
  Par:    TParser;
  SA:     TSemanticAnalyser;
  Prog:   TProgram;
  Assign: TAssignment;
begin
  Lex  := TLexer.Create(SrcSetInOperator);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free; Lex.Free;
  SA   := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  { B := dNorth in S — second stmt in main block }
  Assign := TAssignment(Prog.Block.Stmts[1]);
  AssertEquals('in operator resolves to Boolean',
    Ord(tyBoolean), Ord(Assign.Expr.ResolvedType.Kind));
  Prog.Free;
end;

procedure TSetTests.TestSemantic_Set_Include_OK;
begin
  SemanticOK(SrcSetInclude);
end;

procedure TSetTests.TestSemantic_Set_Exclude_OK;
begin
  SemanticOK(SrcSetExclude);
end;

procedure TSetTests.TestSemantic_Set_Union_OK;
begin
  SemanticOK(SrcSetUnion);
end;

procedure TSetTests.TestSemantic_Set_Difference_OK;
begin
  SemanticOK(SrcSetDifference);
end;

procedure TSetTests.TestSemantic_Set_Intersection_OK;
begin
  SemanticOK(SrcSetIntersection);
end;

procedure TSetTests.TestSemantic_Set_Equality_OK;
begin
  SemanticOK(SrcSetEquality);
  SemanticOK(SrcSetInequality);
end;

procedure TSetTests.TestSemantic_Set_BaseTypeMustBeEnum;
begin
  SemanticFail(SrcSetBadBaseType);
end;

procedure TSetTests.TestSemantic_Set_LiteralElementMustMatchBase;
begin
  SemanticFail(SrcSetBadLiteralElement);
end;

{ ------------------------------------------------------------------ }
{ codegen                                                              }
{ ------------------------------------------------------------------ }

procedure TSetTests.TestCodegen_Set_VarAllocsEmitsZero;
var
  IR: string;
begin
  IR := GenIR(SrcSetEmptyLiteral);
  { global set var emits data $S = { w 0 }; local would emit storew 0 }
  AssertTrue('set var zero-initialised in data section or stack alloc',
    (Pos('{ w 0 }', IR) > 0) or (Pos('storew 0', IR) > 0));
end;

procedure TSetTests.TestCodegen_Set_EmptyLiteralEmitsZero;
var
  IR: string;
begin
  IR := GenIR(SrcSetEmptyLiteral);
  { S := [] computes bitmask 0 via "copy 0" }
  AssertTrue('empty set literal emits copy 0', Pos('copy 0', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_OneElementBitmask;
var
  IR: string;
begin
  { [dNorth] → ordinal 0 → bit 0 → mask 1 → emits "copy 1" }
  IR := GenIR(
    'program P;' + LineEnding +
    DirEnum +
    'var S: TDirSet;' + LineEnding +
    'begin' + LineEnding +
    '  S := [dNorth]' + LineEnding +
    'end.');
  AssertTrue('single-element mask is 1', Pos('copy 1', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_TwoElementBitmask;
var
  IR: string;
begin
  { [dNorth, dEast] → ordinals 0 and 2 → mask = 1 + 4 = 5 → emits "copy 5" }
  IR := GenIR(SrcSetTwoElementLiteral);
  AssertTrue('two-element mask is 5', Pos('copy 5', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_InOperatorEmitsShrAndAnd;
var
  IR: string;
begin
  IR := GenIR(SrcSetInOperator);
  { elem in S: (S >> ord(elem)) & 1 — needs shr and and }
  AssertTrue('in operator emits shr', Pos('shr', IR) > 0);
  AssertTrue('in operator emits and', Pos(' and ', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_IncludeEmitsShlAndOr;
var
  IR: string;
begin
  IR := GenIR(SrcSetInclude);
  { Include(S, elem): S := S or (1 shl ord(elem)) }
  AssertTrue('Include emits shl', Pos('shl', IR) > 0);
  AssertTrue('Include emits or', Pos(' or ', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_ExcludeEmitsShlXorAnd;
var
  IR: string;
begin
  IR := GenIR(SrcSetExclude);
  { Exclude(S, elem): S := S and not (1 shl ord(elem)) }
  AssertTrue('Exclude emits shl', Pos('shl', IR) > 0);
  AssertTrue('Exclude emits xor', Pos('xor', IR) > 0);
  AssertTrue('Exclude emits and', Pos(' and ', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_UnionEmitsOr;
var
  IR: string;
begin
  IR := GenIR(SrcSetUnion);
  AssertTrue('union emits or', Pos(' or ', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_DifferenceEmitsXorAnd;
var
  IR: string;
begin
  IR := GenIR(SrcSetDifference);
  AssertTrue('difference emits xor', Pos('xor', IR) > 0);
  AssertTrue('difference emits and', Pos(' and ', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_IntersectionEmitsAnd;
var
  IR: string;
begin
  IR := GenIR(SrcSetIntersection);
  AssertTrue('intersection emits and', Pos(' and ', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_EqualityEmitsCeqw;
var
  IR: string;
begin
  IR := GenIR(SrcSetEquality);
  AssertTrue('set equality emits ceqw', Pos('ceqw', IR) > 0);
end;

procedure TSetTests.TestCodegen_Set_InequalityEmitsCnew;
var
  IR: string;
begin
  IR := GenIR(SrcSetInequality);
  AssertTrue('set inequality emits cnew', Pos('cnew', IR) > 0);
end;

initialization
  RegisterTest(TSetTests);

end.
