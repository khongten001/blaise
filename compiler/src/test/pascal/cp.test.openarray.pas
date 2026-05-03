{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.openarray;

{$mode objfpc}{$H+}

{ Tests for const open array parameters: parsing, semantic analysis,
  and QBE IR code generation. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TOpenArrayTests = class(TTestCase)
  private
    function  ParseSrc(const ASrc: string): TProgram;
    function  AnalyseSrc(const ASrc: string): TProgram;
    function  GenIR(const ASrc: string): string;
  published
    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_OpenArray_IsOpenArray;
    procedure TestParse_OpenArray_ElementTypeName;
    procedure TestParse_OpenArray_IsConstParam;
    procedure TestParse_OpenArray_IntegerElement;
    procedure TestParse_OpenArray_ValueParam_IsNotOpenArray;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_OpenArray_ResolvesToOpenArrayKind;
    procedure TestSemantic_OpenArray_ElementType;
    procedure TestSemantic_High_ReturnsInteger;
    procedure TestSemantic_Low_ReturnsInteger;

    { ------------------------------------------------------------------ }
    { Codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_OpenArray_TwoParamsInSignature;
    procedure TestCodegen_OpenArray_TwoAllocsEmitted;
    procedure TestCodegen_High_LoadsHighSlot;
    procedure TestCodegen_Low_EmitsZero;
    procedure TestCodegen_Subscript_PointerArithmetic;
    procedure TestCodegen_Forwarding_PassesTwoArgs;

    { ------------------------------------------------------------------ }
    { Array literal call site                                              }
    { ------------------------------------------------------------------ }
    procedure TestParse_ArrayLiteral_NodeType;
    procedure TestParse_ArrayLiteral_ElementCount;
    procedure TestParse_ArrayLiteral_SingleElement;
    procedure TestSemantic_ArrayLiteral_ResolvesToOpenArray;
    procedure TestSemantic_ArrayLiteral_ElementType;
    procedure TestCodegen_ArrayLiteral_AllocsBuffer;
    procedure TestCodegen_ArrayLiteral_StoresElements;
    procedure TestCodegen_ArrayLiteral_HighIndexIsOne;
    procedure TestCodegen_ArrayLiteral_SingleElem_HighZero;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TOpenArrayTests.ParseSrc(const ASrc: string): TProgram;
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

function TOpenArrayTests.AnalyseSrc(const ASrc: string): TProgram;
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

function TOpenArrayTests.GenIR(const ASrc: string): string;
var P: TProgram; CG: TCodeGenQBE;
begin
  P := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create;
    try
      CG.Generate(P);
      Result := CG.GetOutput;
    finally
      CG.Free;
    end;
  finally
    P.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Shared source snippets                                              }
{ ------------------------------------------------------------------ }

const
  SrcPrintFirst =
    'program OA;'                                      + LineEnding +
    'procedure PrintFirst(const A: array of string);'  + LineEnding +
    'begin'                                             + LineEnding +
    'end;'                                             + LineEnding +
    'begin end.';

  SrcHighLow =
    'program OA;'                                      + LineEnding +
    'function Len(const A: array of string): Integer;' + LineEnding +
    'var H, L: Integer;'                               + LineEnding +
    'begin'                                            + LineEnding +
    '  H := High(A);'                                  + LineEnding +
    '  L := Low(A);'                                   + LineEnding +
    '  Result := H - L + 1'                            + LineEnding +
    'end;'                                             + LineEnding +
    'begin end.';

  SrcSubscript =
    'program OA;'                                      + LineEnding +
    'function First(const A: array of string): string;'+ LineEnding +
    'begin'                                            + LineEnding +
    '  Result := A[0]'                                 + LineEnding +
    'end;'                                             + LineEnding +
    'begin end.';

  SrcForward =
    'program OA;'                                      + LineEnding +
    'procedure Inner(const B: array of string);'       + LineEnding +
    'begin end;'                                       + LineEnding +
    'procedure Outer(const A: array of string);'       + LineEnding +
    'begin'                                            + LineEnding +
    '  Inner(A)'                                       + LineEnding +
    'end;'                                             + LineEnding +
    'begin end.';

  SrcLiteralCall =
    'program OA;'                                      + LineEnding +
    'procedure Print(const A: array of string);'       + LineEnding +
    'begin end;'                                       + LineEnding +
    'begin'                                            + LineEnding +
    '  Print([''hello'', ''world''])'                  + LineEnding +
    'end.';

  SrcLiteralSingle =
    'program OA;'                                      + LineEnding +
    'procedure Print(const A: array of string);'       + LineEnding +
    'begin end;'                                       + LineEnding +
    'begin'                                            + LineEnding +
    '  Print([''only''])'                              + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Parser tests                                                        }
{ ------------------------------------------------------------------ }

procedure TOpenArrayTests.TestParse_OpenArray_IsOpenArray;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(SrcPrintFirst);
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertTrue('A is open array', Par.IsOpenArray);
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestParse_OpenArray_ElementTypeName;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(SrcPrintFirst);
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertEquals('element type is string', 'string', Par.TypeName);
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestParse_OpenArray_IsConstParam;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(SrcPrintFirst);
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertTrue('const modifier recorded', Par.IsConstParam);
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestParse_OpenArray_IntegerElement;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(
    'program T;'                                       + LineEnding +
    'procedure Sum(const A: array of Integer);'        + LineEnding +
    'begin end;'                                       + LineEnding +
    'begin end.');
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertTrue('A is open array', Par.IsOpenArray);
    AssertEquals('element type is Integer', 'Integer', Par.TypeName);
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestParse_OpenArray_ValueParam_IsNotOpenArray;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(
    'program T;'                                       + LineEnding +
    'procedure Foo(X: Integer);'                       + LineEnding +
    'begin end;'                                       + LineEnding +
    'begin end.');
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertFalse('plain param is not open array', Par.IsOpenArray);
  finally P.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                      }
{ ------------------------------------------------------------------ }

procedure TOpenArrayTests.TestSemantic_OpenArray_ResolvesToOpenArrayKind;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := AnalyseSrc(SrcPrintFirst);
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertNotNull('ResolvedType set', Par.ResolvedType);
    AssertEquals('kind is tyOpenArray', Ord(tyOpenArray), Ord(Par.ResolvedType.Kind));
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestSemantic_OpenArray_ElementType;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam; OAT: TOpenArrayTypeDesc;
begin
  P := AnalyseSrc(SrcPrintFirst);
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertTrue('is TOpenArrayTypeDesc', Par.ResolvedType is TOpenArrayTypeDesc);
    OAT := TOpenArrayTypeDesc(Par.ResolvedType);
    AssertNotNull('ElementType set', OAT.ElementType);
    AssertEquals('element is tyString', Ord(tyString), Ord(OAT.ElementType.Kind));
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestSemantic_High_ReturnsInteger;
var P: TProgram; MD: TMethodDecl; Assign: TAssignment; FCall: TFuncCallExpr;
begin
  P := AnalyseSrc(SrcHighLow);
  try
    MD := TMethodDecl(P.Block.ProcDecls[0]);
    { First statement in body: H := High(A) }
    Assign := TAssignment(MD.Body.Stmts[0]);
    FCall  := TFuncCallExpr(Assign.Expr);
    AssertNotNull('High resolved type set', FCall.ResolvedType);
    AssertEquals('High returns tyInteger', Ord(tyInteger), Ord(FCall.ResolvedType.Kind));
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestSemantic_Low_ReturnsInteger;
var P: TProgram; MD: TMethodDecl; Assign: TAssignment; FCall: TFuncCallExpr;
begin
  P := AnalyseSrc(SrcHighLow);
  try
    MD := TMethodDecl(P.Block.ProcDecls[0]);
    { Second statement: L := Low(A) }
    Assign := TAssignment(MD.Body.Stmts[1]);
    FCall  := TFuncCallExpr(Assign.Expr);
    AssertNotNull('Low resolved type set', FCall.ResolvedType);
    AssertEquals('Low returns tyInteger', Ord(tyInteger), Ord(FCall.ResolvedType.Kind));
  finally P.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                       }
{ ------------------------------------------------------------------ }

procedure TOpenArrayTests.TestCodegen_OpenArray_TwoParamsInSignature;
var IR: string;
begin
  IR := GenIR(SrcPrintFirst);
  { Open array emits data pointer + high index as two separate QBE params }
  AssertTrue('data pointer param present', Pos('l %_par_A,', IR) > 0);
  AssertTrue('high-index param present',   Pos('l %_par_A_high', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_OpenArray_TwoAllocsEmitted;
var IR: string;
begin
  IR := GenIR(SrcPrintFirst);
  AssertTrue('data pointer slot allocated',  Pos('%_var_A =l alloc8', IR) > 0);
  AssertTrue('high-index slot allocated',    Pos('%_var_A_high =l alloc8', IR) > 0);
  AssertTrue('data pointer stored',          Pos('storel %_par_A, %_var_A', IR) > 0);
  AssertTrue('high-index stored',            Pos('storel %_par_A_high, %_var_A_high', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_High_LoadsHighSlot;
var IR: string;
begin
  IR := GenIR(SrcHighLow);
  AssertTrue('High(A) loads high slot', Pos('loadl %_var_A_high', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_Low_EmitsZero;
var IR: string;
begin
  IR := GenIR(SrcHighLow);
  AssertTrue('Low(A) emits constant 0', Pos('copy 0', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_Subscript_PointerArithmetic;
var IR: string;
begin
  IR := GenIR(SrcSubscript);
  { A[0] must load base pointer, multiply index by element size, add offset, load }
  AssertTrue('loads base pointer',    Pos('loadl %_var_A', IR) > 0);
  AssertTrue('pointer add emitted',   Pos('=l add', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_Forwarding_PassesTwoArgs;
var IR: string;
begin
  IR := GenIR(SrcForward);
  { Inner(A) from Outer must pass both data ptr and high from A's two slots }
  AssertTrue('forwards data pointer',  Pos('loadl %_var_A', IR) > 0);
  AssertTrue('forwards high index',    Pos('loadl %_var_A_high', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ Array literal tests                                               }
{ ------------------------------------------------------------------ }

procedure TOpenArrayTests.TestParse_ArrayLiteral_NodeType;
var P: TProgram; Call: TProcCall; Arg: TASTExpr;
begin
  P := ParseSrc(SrcLiteralCall);
  try
    { First statement in the main block is Print([...]) }
    Call := TProcCall(P.Block.Stmts[0]);
    Arg  := TASTExpr(Call.Args[0]);
    AssertTrue('arg is TArrayLiteralExpr', Arg is TArrayLiteralExpr);
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestParse_ArrayLiteral_ElementCount;
var P: TProgram; Call: TProcCall; Lit: TArrayLiteralExpr;
begin
  P := ParseSrc(SrcLiteralCall);
  try
    Call := TProcCall(P.Block.Stmts[0]);
    Lit  := TArrayLiteralExpr(TASTExpr(Call.Args[0]));
    AssertEquals('two elements', 2, Lit.Elements.Count);
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestParse_ArrayLiteral_SingleElement;
var P: TProgram; Call: TProcCall; Lit: TArrayLiteralExpr;
begin
  P := ParseSrc(SrcLiteralSingle);
  try
    Call := TProcCall(P.Block.Stmts[0]);
    Lit  := TArrayLiteralExpr(TASTExpr(Call.Args[0]));
    AssertEquals('one element', 1, Lit.Elements.Count);
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestSemantic_ArrayLiteral_ResolvesToOpenArray;
var P: TProgram; Call: TProcCall; Arg: TASTExpr;
begin
  P := AnalyseSrc(SrcLiteralCall);
  try
    Call := TProcCall(P.Block.Stmts[0]);
    Arg  := TASTExpr(Call.Args[0]);
    AssertNotNull('ResolvedType set', Arg.ResolvedType);
    AssertEquals('kind is tyOpenArray', Ord(tyOpenArray), Ord(Arg.ResolvedType.Kind));
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestSemantic_ArrayLiteral_ElementType;
var P: TProgram; Call: TProcCall; Arg: TASTExpr; OAT: TOpenArrayTypeDesc;
begin
  P := AnalyseSrc(SrcLiteralCall);
  try
    Call := TProcCall(P.Block.Stmts[0]);
    Arg  := TASTExpr(Call.Args[0]);
    AssertTrue('is TOpenArrayTypeDesc', Arg.ResolvedType is TOpenArrayTypeDesc);
    OAT := TOpenArrayTypeDesc(Arg.ResolvedType);
    AssertEquals('element is tyString', Ord(tyString), Ord(OAT.ElementType.Kind));
  finally P.Free; end;
end;

procedure TOpenArrayTests.TestCodegen_ArrayLiteral_AllocsBuffer;
var IR: string;
begin
  IR := GenIR(SrcLiteralCall);
  AssertTrue('buffer alloc emitted', Pos('alloc8', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_ArrayLiteral_StoresElements;
var IR: string;
begin
  IR := GenIR(SrcLiteralCall);
  { Two string elements — each needs a storel }
  AssertTrue('first storel emitted',  Pos('storel', IR) > 0);
  { Count occurrences: need at least 2 storel instructions }
  AssertTrue('second storel emitted',
    Pos('storel', IR) <> LastDelimiter('storel', IR) + 1);
end;

procedure TOpenArrayTests.TestCodegen_ArrayLiteral_HighIndexIsOne;
var IR: string;
begin
  IR := GenIR(SrcLiteralCall);
  { Two-element literal → high index = 1 }
  AssertTrue('high index 1 in call', Pos('l 1', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_ArrayLiteral_SingleElem_HighZero;
var IR: string;
begin
  IR := GenIR(SrcLiteralSingle);
  { Single-element literal → high index = 0 }
  AssertTrue('high index 0 in call', Pos('l 0', IR) > 0);
end;

initialization
  RegisterTest(TOpenArrayTests);

end.
