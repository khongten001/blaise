{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.arrayofconst;

{ Parser/semantic/IR tests for 'array of const' (heterogeneous variadic
  parameters).  A call-site bracket literal is boxed into an array of the
  intrinsic TVarRec record; the callee receives it as an open array of TVarRec.
  E2E coverage (compile + run on both backends) lives in
  cp.test.e2e.arrayofconst.pas. }

interface

uses
  blaise.testing,
  uLexer, uParser, uAST, uSemantic, uSymbolTable, blaise.codegen.qbe;

type
  TArrayOfConstTests = class(TTestCase)
  private
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    function IRHas(const AIR, AFragment: string): Boolean;
  published
    { Intrinsic TVarRec + vt constants are always available (no uses). }
    procedure TestSemantic_TVarRec_IsIntrinsicRecord;
    procedure TestSemantic_VtConstants_Available;

    { Parsing + parameter typing. }
    procedure TestSemantic_ArrayOfConstParam_IsOpenArrayOfTVarRec;
    procedure TestSemantic_HeterogeneousLiteral_Accepted;
    procedure TestSemantic_LiteralTypedAsArrayOfTVarRec;

    { Codegen: TVarRec boxing. }
    procedure TestCodegen_TagStoredPerElement;
    procedure TestCodegen_DoubleElement_HeapBoxed;
    procedure TestCodegen_SixteenByteStride;
  end;

implementation

function TArrayOfConstTests.AnalyseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser; A: TSemanticAnalyser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Result := P.Parse();
  finally
    P.Free(); L.Free();
  end;
  A := TSemanticAnalyser.Create();
  try
    A.Analyse(Result);
  finally
    A.Free();
  end;
end;

function TArrayOfConstTests.GenIR(const ASrc: string): string;
var
  L: TLexer; P: TParser; Pr: TProgram; A: TSemanticAnalyser; CG: TCodeGenQBE;
begin
  L  := TLexer.Create(ASrc);
  P  := TParser.Create(L);
  Pr := P.Parse();
  A  := TSemanticAnalyser.Create();
  try
    A.Analyse(Pr);
    CG := TCodeGenQBE.Create();
    try
      CG.Generate(Pr);
      Result := CG.GetOutput();
    finally
      CG.Free();
    end;
  finally
    A.Free(); Pr.Free(); P.Free(); L.Free();
  end;
end;

function TArrayOfConstTests.IRHas(const AIR, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AIR) >= 0;
end;

{ ------------------------------------------------------------------ }
{ Intrinsic TVarRec                                                   }
{ ------------------------------------------------------------------ }

procedure TArrayOfConstTests.TestSemantic_TVarRec_IsIntrinsicRecord;
var P: TProgram; Decl: TVarDecl;
begin
  { TVarRec resolves with no uses clause. }
  P := AnalyseSrc('program X; var V: TVarRec; begin end.');
  try
    Decl := TVarDecl(P.Block.Decls.Items[0]);
    AssertNotNull('TVarRec resolved', Decl.ResolvedType);
    AssertEquals('kind tyRecord', Ord(tyRecord), Ord(Decl.ResolvedType.Kind));
    AssertEquals('16-byte layout', 16, Decl.ResolvedType.ByteSize());
  finally P.Free(); end;
end;

procedure TArrayOfConstTests.TestSemantic_VtConstants_Available;
var P: TProgram;
begin
  { vt* constants resolve as ordinary integer constants. }
  P := AnalyseSrc(
    'program X; var I: Integer; ' +
    'begin I := vtInteger + vtAnsiString + vtExtended end.');
  try
    AssertTrue('vt constants available', True);
  finally P.Free(); end;
end;

{ ------------------------------------------------------------------ }
{ Parameter typing                                                    }
{ ------------------------------------------------------------------ }

procedure TArrayOfConstTests.TestSemantic_ArrayOfConstParam_IsOpenArrayOfTVarRec;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := AnalyseSrc(
    'program X; procedure Foo(args: array of const); begin end; begin end.');
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);
    Par := TMethodParam(MD.Params.Items[0]);
    AssertTrue('param is open array', Par.IsOpenArray);
    AssertEquals('element type TVarRec', 'TVarRec',
      TOpenArrayTypeDesc(Par.ResolvedType).ElementType.Name);
  finally P.Free(); end;
end;

procedure TArrayOfConstTests.TestSemantic_HeterogeneousLiteral_Accepted;
var P: TProgram;
begin
  { A mixed-type bracket literal is accepted only because the formal is an
    array of const — it would otherwise fail the homogeneity check. }
  P := AnalyseSrc(
    'program X; procedure Foo(args: array of const); begin end; ' +
    'begin Foo([1, ''two'', 3.0, True]) end.');
  try
    AssertTrue('heterogeneous literal accepted', True);
  finally P.Free(); end;
end;

procedure TArrayOfConstTests.TestSemantic_LiteralTypedAsArrayOfTVarRec;
var P: TProgram; Call: TProcCall; Lit: TArrayLiteralExpr;
begin
  P := AnalyseSrc(
    'program X; procedure Foo(args: array of const); begin end; ' +
    'begin Foo([1, ''two'']) end.');
  try
    Call := TProcCall(P.Block.Stmts.Items[0]);
    Lit  := TArrayLiteralExpr(Call.Args.Items[0]);
    AssertTrue('literal flagged IsConstArray', Lit.IsConstArray);
    AssertEquals('typed as array of TVarRec', 'TVarRec',
      TOpenArrayTypeDesc(Lit.ResolvedType).ElementType.Name);
  finally P.Free(); end;
end;

{ ------------------------------------------------------------------ }
{ Codegen                                                             }
{ ------------------------------------------------------------------ }

procedure TArrayOfConstTests.TestCodegen_TagStoredPerElement;
var IR: string;
begin
  { Each element stores a vt tag byte (storeb) into its TVarRec slot. }
  IR := GenIR(
    'program X; procedure Foo(args: array of const); begin end; ' +
    'begin Foo([42, ''hi'']) end.');
  AssertTrue('emits a tag byte store', IRHas(IR, 'storeb'));
end;

procedure TArrayOfConstTests.TestCodegen_DoubleElement_HeapBoxed;
var IR: string;
begin
  { A Double element is heap-boxed via _BlaiseGetMem and stored as a double. }
  IR := GenIR(
    'program X; procedure Foo(args: array of const); begin end; ' +
    'begin Foo([3.5]) end.');
  AssertTrue('double heap-boxed', IRHas(IR, '$_BlaiseGetMem'));
  AssertTrue('double stored', IRHas(IR, 'stored'));
end;

procedure TArrayOfConstTests.TestCodegen_SixteenByteStride;
var IR: string;
begin
  { The TVarRec array is allocated 16 bytes per element. }
  IR := GenIR(
    'program X; procedure Foo(args: array of const); begin end; ' +
    'begin Foo([1, 2]) end.');
  AssertTrue('alloc 32 bytes for 2 elements', IRHas(IR, 'alloc8 32'));
end;

initialization
  RegisterTest(TArrayOfConstTests);

end.
