{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

unit cp.test.genericmethodimpls;

{$mode objfpc}{$H+}

{ Tests for generic class method implementations in standalone form:
    procedure TList<T>.Add(Value: T);
    begin ... end;
  This is the standard Object Pascal unit structure where method bodies live in
  the implementation section rather than inline in the class declaration. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TGenericMethodImplTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
  published
    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_OwnerTypeName_SetForGenericImpl;
    procedure TestParse_OwnerTypeParams_SetForGenericImpl;
    procedure TestParse_MethodName_IsCorrect;
    procedure TestParse_TwoTypeParams_BothRecorded;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_ForwardOnlyClass_WithSeparateImpl_Compiles;
    procedure TestSemantic_TwoMethods_BothLinked;

    { ------------------------------------------------------------------ }
    { Codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_SeparateImpl_ProducesSetValBody;
    procedure TestCodegen_SeparateImpl_ProducesGetValBody;
    procedure TestCodegen_SeparateImpl_IRMatchesInlineVersion;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Source constants                                                      }
{ ------------------------------------------------------------------ }

const
  { Class with forward-only method signatures — bodies supplied separately }
  SrcForwardOnly =
    'program P;'                                                + LineEnding +
    'type'                                                      + LineEnding +
    '  TBox<T> = class'                                         + LineEnding +
    '    FVal: T;'                                              + LineEnding +
    '    procedure SetVal(V: T);'                               + LineEnding +
    '    function GetVal: T;'                                   + LineEnding +
    '  end;'                                                    + LineEnding +
    'procedure TBox<T>.SetVal(V: T);'                           + LineEnding +
    'begin'                                                     + LineEnding +
    '  Self.FVal := V'                                          + LineEnding +
    'end;'                                                      + LineEnding +
    'function TBox<T>.GetVal: T;'                               + LineEnding +
    'begin'                                                     + LineEnding +
    '  Result := Self.FVal'                                     + LineEnding +
    'end;'                                                      + LineEnding +
    'var B: TBox<Integer>;'                                     + LineEnding +
    'begin'                                                     + LineEnding +
    '  B := TBox<Integer>.Create'                               + LineEnding +
    'end.';

  { Identical logic, but methods defined inline — used to check IR equivalence }
  SrcInline =
    'program P;'                                                + LineEnding +
    'type'                                                      + LineEnding +
    '  TBox<T> = class'                                         + LineEnding +
    '    FVal: T;'                                              + LineEnding +
    '    procedure SetVal(V: T);'                               + LineEnding +
    '    begin'                                                 + LineEnding +
    '      Self.FVal := V'                                      + LineEnding +
    '    end;'                                                  + LineEnding +
    '    function GetVal: T;'                                   + LineEnding +
    '    begin'                                                 + LineEnding +
    '      Result := Self.FVal'                                 + LineEnding +
    '    end;'                                                  + LineEnding +
    '  end;'                                                    + LineEnding +
    'var B: TBox<Integer>;'                                     + LineEnding +
    'begin'                                                     + LineEnding +
    '  B := TBox<Integer>.Create'                               + LineEnding +
    'end.';

  { Two type params — exercises multi-param parsing }
  SrcTwoTypeParams =
    'program P;'                                                + LineEnding +
    'type'                                                      + LineEnding +
    '  TPair<K, V> = class'                                     + LineEnding +
    '    FKey: K;'                                              + LineEnding +
    '    FVal: V;'                                              + LineEnding +
    '    procedure Assign(AKey: K; AVal: V);'                   + LineEnding +
    '  end;'                                                    + LineEnding +
    'procedure TPair<K, V>.Assign(AKey: K; AVal: V);'           + LineEnding +
    'begin'                                                     + LineEnding +
    '  Self.FKey := AKey;'                                      + LineEnding +
    '  Self.FVal := AVal'                                       + LineEnding +
    'end;'                                                      + LineEnding +
    'begin end.';

{ ------------------------------------------------------------------ }
{ Helpers                                                              }
{ ------------------------------------------------------------------ }

function TGenericMethodImplTests.ParseSrc(const ASrc: string): TProgram;
var
  L: TLexer;
  P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Result := P.Parse;
  finally
    P.Free;
    L.Free;
  end;
end;

function TGenericMethodImplTests.AnalyseSrc(const ASrc: string): TProgram;
var
  SA: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  SA     := TSemanticAnalyser.Create;
  try
    SA.Analyse(Result);
  finally
    SA.Free;
  end;
end;

function TGenericMethodImplTests.GenIR(const ASrc: string): string;
var
  CG:   TCodeGenQBE;
  Prog: TProgram;
begin
  Prog := AnalyseSrc(ASrc);
  CG   := TCodeGenQBE.Create;
  try
    CG.Generate(Prog);
    Result := CG.GetOutput;
  finally
    CG.Free;
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TGenericMethodImplTests.TestParse_OwnerTypeName_SetForGenericImpl;
var
  Prog:  TProgram;
  MDecl: TMethodDecl;
begin
  Prog := ParseSrc(SrcForwardOnly);
  try
    AssertTrue('At least one proc decl', Prog.Block.ProcDecls.Count >= 1);
    MDecl := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertEquals('OwnerTypeName is TBox', 'TBox', MDecl.OwnerTypeName);
  finally
    Prog.Free;
  end;
end;

procedure TGenericMethodImplTests.TestParse_OwnerTypeParams_SetForGenericImpl;
var
  Prog:  TProgram;
  MDecl: TMethodDecl;
begin
  Prog := ParseSrc(SrcForwardOnly);
  try
    MDecl := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertTrue('OwnerTypeParams assigned', MDecl.OwnerTypeParams <> nil);
    AssertEquals('One type param', 1, MDecl.OwnerTypeParams.Count);
    AssertEquals('Param name is T', 'T', MDecl.OwnerTypeParams[0]);
  finally
    Prog.Free;
  end;
end;

procedure TGenericMethodImplTests.TestParse_MethodName_IsCorrect;
var
  Prog:  TProgram;
  MDecl: TMethodDecl;
begin
  Prog := ParseSrc(SrcForwardOnly);
  try
    MDecl := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertEquals('Method name is SetVal', 'SetVal', MDecl.Name);
  finally
    Prog.Free;
  end;
end;

procedure TGenericMethodImplTests.TestParse_TwoTypeParams_BothRecorded;
var
  Prog:  TProgram;
  MDecl: TMethodDecl;
begin
  Prog := ParseSrc(SrcTwoTypeParams);
  try
    AssertTrue('Has proc decl', Prog.Block.ProcDecls.Count >= 1);
    MDecl := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertEquals('OwnerTypeName is TPair', 'TPair', MDecl.OwnerTypeName);
    AssertTrue('OwnerTypeParams assigned', MDecl.OwnerTypeParams <> nil);
    AssertEquals('Two type params', 2, MDecl.OwnerTypeParams.Count);
    AssertEquals('First param K', 'K', MDecl.OwnerTypeParams[0]);
    AssertEquals('Second param V', 'V', MDecl.OwnerTypeParams[1]);
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                        }
{ ------------------------------------------------------------------ }

procedure TGenericMethodImplTests.TestSemantic_ForwardOnlyClass_WithSeparateImpl_Compiles;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcForwardOnly);
  Prog.Free;
end;

procedure TGenericMethodImplTests.TestSemantic_TwoMethods_BothLinked;
var
  Prog:  TProgram;
  GDef:  TGenericTypeDef;
  MDecl: TMethodDecl;
  SA:    TSemanticAnalyser;
begin
  Prog := ParseSrc(SrcForwardOnly);
  try
    SA := TSemanticAnalyser.Create;
    try
      SA.Analyse(Prog);
    finally
      SA.Free;
    end;
    { Locate the generic template's method bodies directly on the AST }
    GDef := TGenericTypeDef(TTypeDecl(Prog.Block.TypeDecls[0]).Def);
    MDecl := TMethodDecl(GDef.ClassDef.Methods[0]);  { SetVal }
    AssertTrue('SetVal body linked', MDecl.Body <> nil);
    MDecl := TMethodDecl(GDef.ClassDef.Methods[1]);  { GetVal }
    AssertTrue('GetVal body linked', MDecl.Body <> nil);
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                         }
{ ------------------------------------------------------------------ }

procedure TGenericMethodImplTests.TestCodegen_SeparateImpl_ProducesSetValBody;
var
  IR: string;
begin
  IR := GenIR(SrcForwardOnly);
  AssertTrue('SetVal body emitted',
    Pos('$TBox_Integer_SetVal', IR) > 0);
end;

procedure TGenericMethodImplTests.TestCodegen_SeparateImpl_ProducesGetValBody;
var
  IR: string;
begin
  IR := GenIR(SrcForwardOnly);
  AssertTrue('GetVal body emitted',
    Pos('$TBox_Integer_GetVal', IR) > 0);
end;

procedure TGenericMethodImplTests.TestCodegen_SeparateImpl_IRMatchesInlineVersion;
var
  IRSep, IRInl: string;
begin
  IRSep := GenIR(SrcForwardOnly);
  IRInl := GenIR(SrcInline);
  AssertEquals('Separate-impl IR equals inline IR', IRInl, IRSep);
end;

initialization
  RegisterTest(TGenericMethodImplTests);

end.
