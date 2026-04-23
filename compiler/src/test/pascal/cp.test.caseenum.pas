{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

unit cp.test.caseenum;

{$mode objfpc}{$H+}

{ Tests for case statements and enum types — required for self-hosting.
  The compiler source uses both throughout (TTokenKind, TTypeKind, etc.). }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TCaseEnumTests = class(TTestCase)
  private
    function GenIR(const ASrc: string): string;
    procedure SemanticOK(const ASrc: string);
    procedure ParseOK(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { case — parse                                                         }
    { ------------------------------------------------------------------ }
    procedure TestParse_Case_SimpleInteger;
    procedure TestParse_Case_WithElse;
    procedure TestParse_Case_MultipleValuesPerBranch;

    { ------------------------------------------------------------------ }
    { case — semantic                                                      }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_Case_IntegerSelector_OK;
    procedure TestSemantic_Case_MultipleValues_OK;

    { ------------------------------------------------------------------ }
    { case — codegen                                                       }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_Case_EmitsComparisons;
    procedure TestCodegen_Case_ElseBranch;

    { ------------------------------------------------------------------ }
    { enum — parse                                                         }
    { ------------------------------------------------------------------ }
    procedure TestParse_Enum_SimpleDefinition;
    procedure TestParse_Enum_ThreeMembers;

    { ------------------------------------------------------------------ }
    { enum — semantic                                                      }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_Enum_MembersResolveAsConstants;
    procedure TestSemantic_Enum_VariableAssignment_OK;
    procedure TestSemantic_Enum_CompareMembers_OK;

    { ------------------------------------------------------------------ }
    { enum — codegen                                                       }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_Enum_MemberEmitsIntegerCopy;
    procedure TestCodegen_Enum_AssignEmitsStore;

    { ------------------------------------------------------------------ }
    { enum + case integration                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_Enum_In_Case_Compiles;
  end;

implementation

const
  SrcCaseSimple =
    'program P;'                                  + LineEnding +
    'var N: Integer;'                             + LineEnding +
    'begin'                                       + LineEnding +
    '  N := 2;'                                   + LineEnding +
    '  case N of'                                 + LineEnding +
    '    1: WriteLn(1);'                          + LineEnding +
    '    2: WriteLn(2);'                          + LineEnding +
    '    3: WriteLn(3)'                           + LineEnding +
    '  end'                                       + LineEnding +
    'end.';

  SrcCaseWithElse =
    'program P;'                                  + LineEnding +
    'var N: Integer;'                             + LineEnding +
    'begin'                                       + LineEnding +
    '  N := 5;'                                   + LineEnding +
    '  case N of'                                 + LineEnding +
    '    1: WriteLn(1);'                          + LineEnding +
    '    2: WriteLn(2)'                           + LineEnding +
    '  else'                                      + LineEnding +
    '    WriteLn(99)'                             + LineEnding +
    '  end'                                       + LineEnding +
    'end.';

  SrcCaseMultiValue =
    'program P;'                                  + LineEnding +
    'var N: Integer;'                             + LineEnding +
    'begin'                                       + LineEnding +
    '  N := 3;'                                   + LineEnding +
    '  case N of'                                 + LineEnding +
    '    1, 2: WriteLn(12);'                      + LineEnding +
    '    3, 4: WriteLn(34)'                       + LineEnding +
    '  end'                                       + LineEnding +
    'end.';

  SrcEnumSimple =
    'program P;'                                  + LineEnding +
    'type'                                        + LineEnding +
    '  TDir = (dNorth, dSouth, dEast, dWest);'   + LineEnding +
    'begin'                                       + LineEnding +
    'end.';

  SrcEnumAssign =
    'program P;'                                  + LineEnding +
    'type'                                        + LineEnding +
    '  TDir = (dNorth, dSouth, dEast, dWest);'   + LineEnding +
    'var D: TDir;'                                + LineEnding +
    'begin'                                       + LineEnding +
    '  D := dSouth'                               + LineEnding +
    'end.';

  SrcEnumCompare =
    'program P;'                                  + LineEnding +
    'type'                                        + LineEnding +
    '  TDir = (dNorth, dSouth);'                  + LineEnding +
    'var'                                         + LineEnding +
    '  D: TDir;'                                  + LineEnding +
    '  B: Boolean;'                               + LineEnding +
    'begin'                                       + LineEnding +
    '  D := dNorth;'                              + LineEnding +
    '  B := (D = dNorth)'                         + LineEnding +
    'end.';

  SrcEnumInCase =
    'program P;'                                  + LineEnding +
    'type'                                        + LineEnding +
    '  TState = (sIdle, sRunning, sDone);'        + LineEnding +
    'var'                                         + LineEnding +
    '  S: TState;'                                + LineEnding +
    '  N: Integer;'                               + LineEnding +
    'begin'                                       + LineEnding +
    '  S := sRunning;'                            + LineEnding +
    '  case S of'                                 + LineEnding +
    '    sIdle:    N := 0;'                       + LineEnding +
    '    sRunning: N := 1;'                       + LineEnding +
    '    sDone:    N := 2'                        + LineEnding +
    '  end'                                       + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Helpers                                                              }
{ ------------------------------------------------------------------ }

function TCaseEnumTests.GenIR(const ASrc: string): string;
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

procedure TCaseEnumTests.SemanticOK(const ASrc: string);
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

procedure TCaseEnumTests.ParseOK(const ASrc: string);
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
{ case — parse                                                         }
{ ------------------------------------------------------------------ }

procedure TCaseEnumTests.TestParse_Case_SimpleInteger;
begin
  ParseOK(SrcCaseSimple);
end;

procedure TCaseEnumTests.TestParse_Case_WithElse;
begin
  ParseOK(SrcCaseWithElse);
end;

procedure TCaseEnumTests.TestParse_Case_MultipleValuesPerBranch;
begin
  ParseOK(SrcCaseMultiValue);
end;

{ ------------------------------------------------------------------ }
{ case — semantic                                                      }
{ ------------------------------------------------------------------ }

procedure TCaseEnumTests.TestSemantic_Case_IntegerSelector_OK;
begin
  SemanticOK(SrcCaseSimple);
end;

procedure TCaseEnumTests.TestSemantic_Case_MultipleValues_OK;
begin
  SemanticOK(SrcCaseMultiValue);
end;

{ ------------------------------------------------------------------ }
{ case — codegen                                                       }
{ ------------------------------------------------------------------ }

procedure TCaseEnumTests.TestCodegen_Case_EmitsComparisons;
var
  IR: string;
begin
  IR := GenIR(SrcCaseSimple);
  { Each branch needs a comparison: ceqw selector, value }
  AssertTrue('case emits ceqw comparisons', Pos('ceqw', IR) > 0);
end;

procedure TCaseEnumTests.TestCodegen_Case_ElseBranch;
var
  IR: string;
begin
  IR := GenIR(SrcCaseWithElse);
  { else branch: jmp to default label }
  AssertTrue('case+else produces IR', Length(IR) > 0);
  AssertTrue('case+else emits ceqw', Pos('ceqw', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ enum — parse                                                         }
{ ------------------------------------------------------------------ }

procedure TCaseEnumTests.TestParse_Enum_SimpleDefinition;
begin
  ParseOK(SrcEnumSimple);
end;

procedure TCaseEnumTests.TestParse_Enum_ThreeMembers;
begin
  ParseOK(SrcEnumAssign);
end;

{ ------------------------------------------------------------------ }
{ enum — semantic                                                      }
{ ------------------------------------------------------------------ }

procedure TCaseEnumTests.TestSemantic_Enum_MembersResolveAsConstants;
var
  Lex:    TLexer;
  Par:    TParser;
  SA:     TSemanticAnalyser;
  Prog:   TProgram;
  Assign: TAssignment;
begin
  Lex  := TLexer.Create(SrcEnumAssign);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free; Lex.Free;
  SA := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  { D := dSouth — the RHS should have tyEnum resolved type }
  Assign := TAssignment(Prog.Block.Stmts[0]);
  AssertEquals('dSouth resolves to enum type',
    Ord(tyEnum), Ord(Assign.Expr.ResolvedType.Kind));
  Prog.Free;
end;

procedure TCaseEnumTests.TestSemantic_Enum_VariableAssignment_OK;
begin
  SemanticOK(SrcEnumAssign);
end;

procedure TCaseEnumTests.TestSemantic_Enum_CompareMembers_OK;
begin
  SemanticOK(SrcEnumCompare);
end;

{ ------------------------------------------------------------------ }
{ enum — codegen                                                       }
{ ------------------------------------------------------------------ }

procedure TCaseEnumTests.TestCodegen_Enum_MemberEmitsIntegerCopy;
var
  IR: string;
begin
  IR := GenIR(SrcEnumAssign);
  { dSouth = ordinal 1 → should emit copy 1 }
  AssertTrue('dSouth emits copy 1', Pos('copy 1', IR) > 0);
end;

procedure TCaseEnumTests.TestCodegen_Enum_AssignEmitsStore;
var
  IR: string;
begin
  IR := GenIR(SrcEnumAssign);
  AssertTrue('enum assign emits storew', Pos('storew', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ enum + case integration                                              }
{ ------------------------------------------------------------------ }

procedure TCaseEnumTests.TestCodegen_Enum_In_Case_Compiles;
var
  IR: string;
begin
  IR := GenIR(SrcEnumInCase);
  AssertTrue('enum-in-case produces IR', Length(IR) > 0);
  AssertTrue('enum-in-case emits ceqw', Pos('ceqw', IR) > 0);
end;

initialization
  RegisterTest(TCaseEnumTests);

end.
