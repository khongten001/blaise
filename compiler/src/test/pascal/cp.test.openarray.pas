{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.openarray;

{ Tests for const open array parameters: parsing, semantic analysis,
  and QBE IR code generation. }

interface

uses
  Classes, SysUtils, blaise.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, blaise.codegen.qbe;

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

    { ------------------------------------------------------------------ }
    { Length() on open-array and static-array parameters                  }
    { ------------------------------------------------------------------ }
    { Length(A) on an open-array param must compile (was rejected with
      "Length argument must be a string") and emit High+1 IR. }
    procedure TestSemantic_Length_OpenArray_Accepted;
    { Length(A) on a static-array param emits a compile-time constant. }
    procedure TestSemantic_Length_StaticArray_Accepted;
    { IR: Length(open-array) loads the _high slot and adds 1. }
    procedure TestCodegen_Length_OpenArray_EmitsHighPlusOne;
    { IR: Length(static-array) emits a constant equal to the element count. }
    procedure TestCodegen_Length_StaticArray_EmitsConstant;

    { ------------------------------------------------------------------ }
    { Static array coerced to open-array parameter                         }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_StaticArrayToOpenArray_Accepted;
    procedure TestSemantic_StaticArrayToOpenArray_NonZeroBase_Accepted;
    procedure TestCodegen_StaticArrayToOpenArray_PassesBasePtr;
    procedure TestCodegen_StaticArrayToOpenArray_PassesCompileTimeHigh;
    procedure TestCodegen_StaticArrayToOpenArray_NonZeroBase_HighIsFour;
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
    Result := P.Parse();
  finally
    P.Free(); L.Free();
  end;
end;

function TOpenArrayTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create();
  try
    A.Analyse(Result);
  finally
    A.Free();
  end;
end;

function TOpenArrayTests.GenIR(const ASrc: string): string;
var P: TProgram; CG: TCodeGenQBE;
begin
  P := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create();
    try
      CG.Generate(P);
      Result := CG.GetOutput();
    finally
      CG.Free();
    end;
  finally
    P.Free();
  end;
end;

{ ------------------------------------------------------------------ }
{ Shared source snippets                                              }
{ ------------------------------------------------------------------ }

const
  SrcPrintFirst =
    '''
        program OA;
        procedure PrintFirst(const A: array of string);
        begin
        end;
        begin end.
        ''';

  SrcHighLow =
    '''
        program OA;
        function Len(const A: array of string): Integer;
        var H, L: Integer;
        begin
          H := High(A);
          L := Low(A);
          Result := H - L + 1
        end;
        begin end.
        ''';

  SrcSubscript =
    '''
        program OA;
        function First(const A: array of string): string;
        begin
          Result := A[0]
        end;
        begin end.
        ''';

  SrcForward =
    '''
        program OA;
        procedure Inner(const B: array of string);
        begin end;
        procedure Outer(const A: array of string);
        begin
          Inner(A)
        end;
        begin end.
        ''';

  SrcLiteralCall =
    '''
        program OA;
        procedure Print(const A: array of string);
        begin end;
        begin
          Print(['hello', 'world'])
        end.
        ''';

  SrcLiteralSingle =
    '''
        program OA;
        procedure Print(const A: array of string);
        begin end;
        begin
          Print(['only'])
        end.
        ''';

  SrcLengthOpenArray =
    '''
        program OA;
        procedure Show(const A: array of string);
        var N: Integer;
        begin
          N := Length(A)
        end;
        begin
          Show(['x', 'y', 'z'])
        end.
        ''';

  SrcLengthStaticArray =
    '''
        program OA;
        var A: array[1..5] of Integer;
        var N: Integer;
        begin
          N := Length(A)
        end.
        ''';

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
  finally P.Free(); end;
end;

procedure TOpenArrayTests.TestParse_OpenArray_ElementTypeName;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(SrcPrintFirst);
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertEquals('element type is string', 'string', Par.TypeName);
  finally P.Free(); end;
end;

procedure TOpenArrayTests.TestParse_OpenArray_IsConstParam;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(SrcPrintFirst);
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertTrue('const modifier recorded', Par.IsConstParam);
  finally P.Free(); end;
end;

procedure TOpenArrayTests.TestParse_OpenArray_IntegerElement;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(
    '''
        program T;
        procedure Sum(const A: array of Integer);
        begin end;
        begin end.
        ''');
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertTrue('A is open array', Par.IsOpenArray);
    AssertEquals('element type is Integer', 'Integer', Par.TypeName);
  finally P.Free(); end;
end;

procedure TOpenArrayTests.TestParse_OpenArray_ValueParam_IsNotOpenArray;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(
    '''
        program T;
        procedure Foo(X: Integer);
        begin end;
        begin end.
        ''');
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params[0]);
    AssertFalse('plain param is not open array', Par.IsOpenArray);
  finally P.Free(); end;
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
  finally P.Free(); end;
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
  finally P.Free(); end;
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
  finally P.Free(); end;
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
  finally P.Free(); end;
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
  finally P.Free(); end;
end;

procedure TOpenArrayTests.TestParse_ArrayLiteral_ElementCount;
var P: TProgram; Call: TProcCall; Lit: TArrayLiteralExpr;
begin
  P := ParseSrc(SrcLiteralCall);
  try
    Call := TProcCall(P.Block.Stmts[0]);
    Lit  := TArrayLiteralExpr(TASTExpr(Call.Args[0]));
    AssertEquals('two elements', 2, Lit.Elements.Count);
  finally P.Free(); end;
end;

procedure TOpenArrayTests.TestParse_ArrayLiteral_SingleElement;
var P: TProgram; Call: TProcCall; Lit: TArrayLiteralExpr;
begin
  P := ParseSrc(SrcLiteralSingle);
  try
    Call := TProcCall(P.Block.Stmts[0]);
    Lit  := TArrayLiteralExpr(TASTExpr(Call.Args[0]));
    AssertEquals('one element', 1, Lit.Elements.Count);
  finally P.Free(); end;
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
  finally P.Free(); end;
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
  finally P.Free(); end;
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
    PosEx('storel', IR, Pos('storel', IR) + 1) > 0);
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

procedure TOpenArrayTests.TestSemantic_Length_OpenArray_Accepted;
var P: TProgram;
begin
  P := AnalyseSrc(SrcLengthOpenArray);
  P.Free();
  AssertTrue('no error raised', True);
end;

procedure TOpenArrayTests.TestSemantic_Length_StaticArray_Accepted;
var P: TProgram;
begin
  P := AnalyseSrc(SrcLengthStaticArray);
  P.Free();
  AssertTrue('no error raised', True);
end;

procedure TOpenArrayTests.TestCodegen_Length_OpenArray_EmitsHighPlusOne;
var IR: string;
begin
  IR := GenIR(SrcLengthOpenArray);
  { Length(A) = High(A) + 1: load _high slot then add 1 }
  AssertTrue('loads _high slot', Pos('loadl %_var_A_high', IR) > 0);
  AssertTrue('adds 1 for length', Pos('add', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_Length_StaticArray_EmitsConstant;
var IR: string;
begin
  IR := GenIR(SrcLengthStaticArray);
  { array[1..5] has 5 elements — Length emits the constant 5 }
  AssertTrue('constant 5 emitted', Pos('copy 5', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ Static array coerced to open-array — source constants               }
{ ------------------------------------------------------------------ }

const
  SrcStaticToOpen =
    '''
        program P;
        procedure Show(const A: array of Integer);
        var N: Integer;
        begin
          N := Length(A)
        end;
        var B: array[0..3] of Integer;
        begin
          Show(B)
        end.
        ''';

  SrcStaticToOpenNonZero =
    '''
        program P;
        procedure Show(const A: array of Integer);
        var N: Integer;
        begin
          N := Length(A)
        end;
        var B: array[3..7] of Integer;
        begin
          Show(B)
        end.
        ''';

{ ------------------------------------------------------------------ }
{ Static array coerced to open-array — tests                           }
{ ------------------------------------------------------------------ }

procedure TOpenArrayTests.TestSemantic_StaticArrayToOpenArray_Accepted;
var P: TProgram;
begin
  P := AnalyseSrc(SrcStaticToOpen);
  P.Free();
  AssertTrue('static array passed to open-array param compiles', True);
end;

procedure TOpenArrayTests.TestSemantic_StaticArrayToOpenArray_NonZeroBase_Accepted;
var P: TProgram;
begin
  P := AnalyseSrc(SrcStaticToOpenNonZero);
  P.Free();
  AssertTrue('non-zero-base static array passed to open-array param compiles', True);
end;

procedure TOpenArrayTests.TestCodegen_StaticArrayToOpenArray_PassesBasePtr;
var IR: string;
begin
  IR := GenIR(SrcStaticToOpen);
  { Call must pass exactly two l arguments: the array base pointer and the high index }
  AssertTrue('call passes two l args', Pos('call $Show(l', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_StaticArrayToOpenArray_PassesCompileTimeHigh;
var IR: string;
begin
  IR := GenIR(SrcStaticToOpen);
  { array[0..3]: high = 3 - 0 = 3, passed as compile-time constant }
  AssertTrue('high index 3 in call', Pos(', l 3', IR) > 0);
end;

procedure TOpenArrayTests.TestCodegen_StaticArrayToOpenArray_NonZeroBase_HighIsFour;
var IR: string;
begin
  IR := GenIR(SrcStaticToOpenNonZero);
  { array[3..7]: high = 7 - 3 = 4, passed as compile-time constant }
  AssertTrue('high index 4 in call', Pos(', l 4', IR) > 0);
end;

initialization
  RegisterTest(TOpenArrayTests);

end.
