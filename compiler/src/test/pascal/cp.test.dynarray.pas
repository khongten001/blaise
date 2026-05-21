{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.dynarray;

{ Tests for dynamic array type declarations:
  parsing, semantic analysis, and QBE IR code generation.

  Dynamic arrays (array of T) are heap-allocated, reference-counted
  arrays with runtime length stored in a 2-word header before element 0.
  Layout: [refcount:4][length:4][element 0][element 1]...
  The variable slot holds a pointer to element 0 (nil = unassigned). }

interface

uses
  Classes, SysUtils, blaise.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TDynArrayTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    function CountOccurrences(const AHaystack, ANeedle: string): Integer;
  published
    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_DynArray_TypeAlias_AcceptsDecl;
    procedure TestParse_DynArray_InlineVarDecl_AcceptsDecl;
    procedure TestParse_DynArray_Combined_TypeAndVar;
    procedure TestParse_DynArray_TypeName_EncodesCorrectly;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_DynArray_Kind;
    procedure TestSemantic_DynArray_ElementType_Integer;
    procedure TestSemantic_DynArray_ElementType_String;
    procedure TestSemantic_DynArray_Var_ResolvesToDynArray;

    { ------------------------------------------------------------------ }
    { Codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_DynArray_Var_AllocatedAsPointerSlot;
    procedure TestCodegen_DynArray_Var_ZeroInitialised;
    procedure TestCodegen_DynArray_SetLength_CallsRTL;
    procedure TestCodegen_DynArray_Length_CallsRTL;
    procedure TestCodegen_DynArray_Read_ComputesOffset;
    procedure TestCodegen_DynArray_Write_ComputesOffset;
    procedure TestCodegen_DynArray_High_CallsRTL;
    procedure TestCodegen_DynArray_Low_ReturnsZero;
    procedure TestSemantic_DynArray_High_Accepted;
    procedure TestSemantic_DynArray_Low_Accepted;
  end;

implementation

function TDynArrayTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try Result := P.Parse; finally P.Free; L.Free; end;
end;

function TDynArrayTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try A.Analyse(Result); finally A.Free; end;
end;

function TDynArrayTests.GenIR(const ASrc: string): string;
var Prog: TProgram; CG: TCodeGenQBE;
begin
  Prog := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create;
    try CG.Generate(Prog); Result := CG.GetOutput; finally CG.Free; end;
  finally Prog.Free; end;
end;

function TDynArrayTests.CountOccurrences(
  const AHaystack, ANeedle: string): Integer;
var Pos2, I: Integer;
begin
  Result := 0;
  I := 0;
  repeat
    Pos2 := PosEx(ANeedle, AHaystack, I);
    if Pos2 < 0 then Break;
    Inc(Result);
    I := Pos2 + Length(ANeedle);
  until False;
end;

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TDynArrayTests.TestParse_DynArray_TypeAlias_AcceptsDecl;
var Prog: TProgram;
begin
  Prog := ParseSrc('''
      program P;
      type
        TIntArr = array of Integer;
      begin
      end.
      ''');
  try
    AssertEquals('one type decl', 1, Prog.Block.TypeDecls.Count);
  finally Prog.Free; end;
end;

procedure TDynArrayTests.TestParse_DynArray_InlineVarDecl_AcceptsDecl;
var Prog: TProgram;
begin
  Prog := ParseSrc('''
      program P;
      var
        A: array of Integer;
      begin
      end.
      ''');
  try
    AssertEquals('one var decl', 1, Prog.Block.Decls.Count);
  finally Prog.Free; end;
end;

procedure TDynArrayTests.TestParse_DynArray_Combined_TypeAndVar;
var Prog: TProgram;
begin
  Prog := ParseSrc('''
      program P;
      type
        TStrArr = array of string;
      var
        S: TStrArr;
      begin
      end.
      ''');
  try
    AssertEquals('one type decl', 1, Prog.Block.TypeDecls.Count);
    AssertEquals('one var decl', 1, Prog.Block.Decls.Count);
  finally Prog.Free; end;
end;

procedure TDynArrayTests.TestParse_DynArray_TypeName_EncodesCorrectly;
var Prog: TProgram; TD: TTypeDecl; AD: TTypeAliasDef;
begin
  Prog := ParseSrc('''
      program P;
      type
        TIntArr = array of Integer;
      begin
      end.
      ''');
  try
    TD := TTypeDecl(Prog.Block.TypeDecls.Items[0]);
    AD := TTypeAliasDef(TD.Def);
    AssertEquals('type name encoded as array of Integer',
      'array of Integer', AD.TypeName);
  finally Prog.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                       }
{ ------------------------------------------------------------------ }

procedure TDynArrayTests.TestSemantic_DynArray_Kind;
var Prog: TProgram; Sym: TSymbol;
begin
  Prog := AnalyseSrc('''
      program P;
      type
        TIntArr = array of Integer;
      begin
      end.
      ''');
  try
    Sym := Prog.SymbolTable.Lookup('TIntArr');
    AssertTrue('TIntArr symbol found', Sym <> nil);
    AssertEquals('kind is tyDynArray', Ord(tyDynArray), Ord(Sym.TypeDesc.Kind));
  finally Prog.Free; end;
end;

procedure TDynArrayTests.TestSemantic_DynArray_ElementType_Integer;
var Prog: TProgram; Sym: TSymbol; DAT: TDynArrayTypeDesc;
begin
  Prog := AnalyseSrc('''
      program P;
      type
        TIntArr = array of Integer;
      begin
      end.
      ''');
  try
    Sym := Prog.SymbolTable.Lookup('TIntArr');
    DAT := TDynArrayTypeDesc(Sym.TypeDesc);
    AssertEquals('element type is Integer', 'Integer', DAT.ElementType.Name);
  finally Prog.Free; end;
end;

procedure TDynArrayTests.TestSemantic_DynArray_ElementType_String;
var Prog: TProgram; Sym: TSymbol; DAT: TDynArrayTypeDesc;
begin
  Prog := AnalyseSrc('''
      program P;
      type
        TStrArr = array of string;
      begin
      end.
      ''');
  try
    Sym := Prog.SymbolTable.Lookup('TStrArr');
    DAT := TDynArrayTypeDesc(Sym.TypeDesc);
    AssertEquals('element type is string', 'string', DAT.ElementType.Name);
  finally Prog.Free; end;
end;

procedure TDynArrayTests.TestSemantic_DynArray_Var_ResolvesToDynArray;
var Prog: TProgram; VD: TVarDecl;
begin
  Prog := AnalyseSrc('''
      program P;
      var
        A: array of Integer;
      begin
      end.
      ''');
  try
    VD := TVarDecl(Prog.Block.Decls.Items[0]);
    AssertEquals('var resolved to tyDynArray',
      Ord(tyDynArray), Ord(VD.ResolvedType.Kind));
  finally Prog.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                        }
{ ------------------------------------------------------------------ }

procedure TDynArrayTests.TestCodegen_DynArray_Var_AllocatedAsPointerSlot;
var IR: string;
begin
  IR := GenIR('''
      program P;
      procedure Foo;
      var A: array of Integer;
      begin
      end;
      begin
      end.
      ''');
  AssertTrue('alloc8 8 for dyn array var',
    Self.CountOccurrences(IR, 'alloc8 8') > 0);
end;

procedure TDynArrayTests.TestCodegen_DynArray_Var_ZeroInitialised;
var IR: string;
begin
  IR := GenIR('''
      program P;
      procedure Foo;
      var A: array of Integer;
      begin
      end;
      begin
      end.
      ''');
  AssertTrue('storel 0 for nil init',
    Self.CountOccurrences(IR, 'storel 0,') > 0);
end;

procedure TDynArrayTests.TestCodegen_DynArray_SetLength_CallsRTL;
var IR: string;
begin
  IR := GenIR('''
      program P;
      procedure Foo;
      var A: array of Integer;
      begin
        SetLength(A, 5);
      end;
      begin
      end.
      ''');
  AssertTrue('calls _DynArraySetLength',
    Self.CountOccurrences(IR, 'call $_DynArraySetLength(') > 0);
end;

procedure TDynArrayTests.TestCodegen_DynArray_Length_CallsRTL;
var IR: string;
begin
  IR := GenIR('''
      program P;
      procedure Foo;
      var A: array of Integer; N: Integer;
      begin
        N := Length(A);
      end;
      begin
      end.
      ''');
  AssertTrue('calls _DynArrayLength',
    Self.CountOccurrences(IR, 'call $_DynArrayLength(') > 0);
end;

procedure TDynArrayTests.TestCodegen_DynArray_Read_ComputesOffset;
var IR: string;
begin
  IR := GenIR('''
      program P;
      procedure Foo;
      var A: array of Integer; X: Integer;
      begin
        SetLength(A, 3);
        X := A[1];
      end;
      begin
      end.
      ''');
  { Element read: loads data ptr, computes offset via mul + add, then loadw }
  AssertTrue('mul for element offset in read',
    Self.CountOccurrences(IR, 'mul') > 0);
  AssertTrue('loadw for integer element read',
    Self.CountOccurrences(IR, 'loadw') > 0);
end;

procedure TDynArrayTests.TestCodegen_DynArray_Write_ComputesOffset;
var IR: string;
begin
  IR := GenIR('''
      program P;
      procedure Foo;
      var A: array of Integer;
      begin
        SetLength(A, 3);
        A[0] := 99;
      end;
      begin
      end.
      ''');
  { Element write: storew for Integer element }
  AssertTrue('storew for integer element write',
    Self.CountOccurrences(IR, 'storew') > 0);
end;

procedure TDynArrayTests.TestSemantic_DynArray_High_Accepted;
var Prog: TProgram;
begin
  { High() on a named dynamic array type must not raise a semantic error }
  Prog := AnalyseSrc('''
      program P;
      type Tar = array of Integer;
      var ar: Tar;
          i: Integer;
      begin
        i := High(ar);
      end.
      ''');
  AssertNotNil('program parsed and analysed without error', Prog);
  Prog.Free;
end;

procedure TDynArrayTests.TestSemantic_DynArray_Low_Accepted;
var Prog: TProgram;
begin
  { Low() on a named dynamic array type must not raise a semantic error }
  Prog := AnalyseSrc('''
      program P;
      type Tar = array of Integer;
      var ar: Tar;
          i: Integer;
      begin
        i := Low(ar);
      end.
      ''');
  AssertNotNil('program parsed and analysed without error', Prog);
  Prog.Free;
end;

procedure TDynArrayTests.TestCodegen_DynArray_High_CallsRTL;
var IR: string;
begin
  { High(dynArr) = DynArrayLength(dynArr) - 1; must call _DynArrayLength }
  IR := GenIR('''
      program P;
      type Tar = array of Integer;
      var ar: Tar;
          i: Integer;
      begin
        SetLength(ar, 15);
        i := High(ar);
        WriteLn(i);
      end.
      ''');
  AssertTrue('calls _DynArrayLength for High(dynArr)',
    Pos('_DynArrayLength', IR) > 0);
end;

procedure TDynArrayTests.TestCodegen_DynArray_Low_ReturnsZero;
var IR: string;
begin
  { Low(dynArr) is always 0; must emit a copy of 0 }
  IR := GenIR('''
      program P;
      type Tar = array of Integer;
      var ar: Tar;
          i: Integer;
      begin
        i := Low(ar);
        WriteLn(i);
      end.
      ''');
  AssertTrue('emits constant 0 for Low(dynArr)',
    Pos('copy 0', IR) > 0);
end;

initialization
  RegisterTest(TDynArrayTests);

end.
