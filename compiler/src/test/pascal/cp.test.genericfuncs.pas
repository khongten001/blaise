{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.genericfuncs;

{$mode objfpc}{$H+}

{ Tests for standalone generic function monomorphization.
  Syntax: function Name<T>(Param: T): T — demand-driven instantiation on first call. }

interface

uses
  Classes, SysUtils, StrUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TGenericFuncTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
  published
    { ------------------------------------------------------------------ }
    { Parser — generic function declarations                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_GenericFunc_HasTypeParams;
    procedure TestParse_GenericFunc_TypeParamName;
    procedure TestParse_GenericFunc_TwoTypeParams;
    procedure TestParse_GenericFunc_ParamUsesTypeParam;
    procedure TestParse_GenericFunc_ReturnUsesTypeParam;

    { ------------------------------------------------------------------ }
    { Parser — generic function call sites                                 }
    { ------------------------------------------------------------------ }
    procedure TestParse_GenericFunc_CallSite_IsFuncCallExpr;
    procedure TestParse_GenericFunc_CallSite_Name;
    procedure TestParse_GenericFunc_CallSite_ArgCount;

    { ------------------------------------------------------------------ }
    { Semantic — instantiation on use                                      }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_GenericFunc_TemplateNotInstantiatedWithoutUse;
    procedure TestSemantic_GenericFunc_Usage_CreatesInstance;
    procedure TestSemantic_GenericFunc_ReturnType_IsInteger;
    procedure TestSemantic_GenericFunc_ParamType_IsInteger;

    { ------------------------------------------------------------------ }
    { Codegen — mangled names and emission                                 }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_GenericFunc_BodyEmitted;
    procedure TestCodegen_GenericFunc_CallEmitted;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Source constants                                                     }
{ ------------------------------------------------------------------ }

const
  { Generic function declaration only — no usage }
  SrcGenericFuncDecl =
    'program P;'                                       + LineEnding +
    'function Identity<T>(Val: T): T;'                 + LineEnding +
    'begin'                                            + LineEnding +
    '  Result := Val'                                  + LineEnding +
    'end;'                                             + LineEnding +
    'begin'                                            + LineEnding +
    'end.';

  { Two type params }
  SrcGenericFuncTwoParams =
    'program P;'                                       + LineEnding +
    'function Swap<A, B>(X: A; Y: B): A;'              + LineEnding +
    'begin'                                            + LineEnding +
    '  Result := X'                                    + LineEnding +
    'end;'                                             + LineEnding +
    'begin'                                            + LineEnding +
    'end.';

  { Usage — instantiates Identity<Integer> }
  SrcGenericFuncUsage =
    'program P;'                                       + LineEnding +
    'function Identity<T>(Val: T): T;'                 + LineEnding +
    'begin'                                            + LineEnding +
    '  Result := Val'                                  + LineEnding +
    'end;'                                             + LineEnding +
    'var X: Integer;'                                  + LineEnding +
    'begin'                                            + LineEnding +
    '  X := Identity<Integer>(42)'                     + LineEnding +
    'end.';

  { Call-site source for parser test only (semantics not needed) }
  SrcGenericFuncCallSite =
    'program P;'                                       + LineEnding +
    'function Identity<T>(Val: T): T;'                 + LineEnding +
    'begin'                                            + LineEnding +
    '  Result := Val'                                  + LineEnding +
    'end;'                                             + LineEnding +
    'var X: Integer;'                                  + LineEnding +
    'begin'                                            + LineEnding +
    '  X := Identity<Integer>(42)'                     + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TGenericFuncTests.ParseSrc(const ASrc: string): TProgram;
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

function TGenericFuncTests.AnalyseSrc(const ASrc: string): TProgram;
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

function TGenericFuncTests.GenIR(const ASrc: string): string;
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
{ Parser — generic function declarations                               }
{ ------------------------------------------------------------------ }

procedure TGenericFuncTests.TestParse_GenericFunc_HasTypeParams;
var
  Prog: TProgram;
  MD:   TMethodDecl;
begin
  Prog := ParseSrc(SrcGenericFuncDecl);
  try
    AssertEquals('one proc decl', 1, Prog.Block.ProcDecls.Count);
    MD := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertNotNull('TypeParams not nil', MD.TypeParams);
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestParse_GenericFunc_TypeParamName;
var
  Prog: TProgram;
  MD:   TMethodDecl;
begin
  Prog := ParseSrc(SrcGenericFuncDecl);
  try
    MD := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertEquals('one type param', 1, MD.TypeParams.Count);
    AssertEquals('param name T', 'T', MD.TypeParams[0]);
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestParse_GenericFunc_TwoTypeParams;
var
  Prog: TProgram;
  MD:   TMethodDecl;
begin
  Prog := ParseSrc(SrcGenericFuncTwoParams);
  try
    MD := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertNotNull('TypeParams not nil', MD.TypeParams);
    AssertEquals('two type params', 2, MD.TypeParams.Count);
    AssertEquals('first param A', 'A', MD.TypeParams[0]);
    AssertEquals('second param B', 'B', MD.TypeParams[1]);
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestParse_GenericFunc_ParamUsesTypeParam;
var
  Prog: TProgram;
  MD:   TMethodDecl;
  Par:  TMethodParam;
begin
  Prog := ParseSrc(SrcGenericFuncDecl);
  try
    MD  := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertEquals('one param', 1, MD.Params.Count);
    Par := TMethodParam(MD.Params[0]);
    AssertEquals('param name Val', 'Val', Par.ParamName);
    AssertEquals('param type T', 'T', Par.TypeName);
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestParse_GenericFunc_ReturnUsesTypeParam;
var
  Prog: TProgram;
  MD:   TMethodDecl;
begin
  Prog := ParseSrc(SrcGenericFuncDecl);
  try
    MD := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertEquals('return type T', 'T', MD.ReturnTypeName);
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Parser — generic function call sites                                 }
{ ------------------------------------------------------------------ }

procedure TGenericFuncTests.TestParse_GenericFunc_CallSite_IsFuncCallExpr;
var
  Prog:   TProgram;
  Assign: TAssignment;
begin
  Prog := ParseSrc(SrcGenericFuncCallSite);
  try
    AssertEquals('one stmt', 1, Prog.Block.Stmts.Count);
    AssertTrue('assign stmt', Prog.Block.Stmts[0] is TAssignment);
    Assign := TAssignment(Prog.Block.Stmts[0]);
    AssertTrue('rhs is TFuncCallExpr', Assign.Expr is TFuncCallExpr);
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestParse_GenericFunc_CallSite_Name;
var
  Prog:   TProgram;
  Assign: TAssignment;
  FCall:  TFuncCallExpr;
begin
  Prog := ParseSrc(SrcGenericFuncCallSite);
  try
    Assign := TAssignment(Prog.Block.Stmts[0]);
    FCall  := TFuncCallExpr(Assign.Expr);
    AssertEquals('call name', 'Identity<Integer>', FCall.Name);
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestParse_GenericFunc_CallSite_ArgCount;
var
  Prog:   TProgram;
  Assign: TAssignment;
  FCall:  TFuncCallExpr;
begin
  Prog := ParseSrc(SrcGenericFuncCallSite);
  try
    Assign := TAssignment(Prog.Block.Stmts[0]);
    FCall  := TFuncCallExpr(Assign.Expr);
    AssertEquals('one arg', 1, FCall.Args.Count);
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic — instantiation on use                                      }
{ ------------------------------------------------------------------ }

procedure TGenericFuncTests.TestSemantic_GenericFunc_TemplateNotInstantiatedWithoutUse;
var
  Prog: TProgram;
begin
  { Declaration without use: no instance created }
  Prog := AnalyseSrc(SrcGenericFuncDecl);
  try
    AssertEquals('no instances', 0, Prog.GenericFuncInstances.Count);
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestSemantic_GenericFunc_Usage_CreatesInstance;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcGenericFuncUsage);
  try
    AssertEquals('one instance', 1, Prog.GenericFuncInstances.Count);
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestSemantic_GenericFunc_ReturnType_IsInteger;
var
  Prog: TProgram;
  GFI:  TGenericFuncInstance;
begin
  Prog := AnalyseSrc(SrcGenericFuncUsage);
  try
    GFI := TGenericFuncInstance(Prog.GenericFuncInstances[0]);
    AssertNotNull('return type not nil', GFI.MethodDecl.ResolvedReturnType);
    AssertEquals('return type is Integer', Ord(tyInteger),
      Ord(GFI.MethodDecl.ResolvedReturnType.Kind));
  finally
    Prog.Free;
  end;
end;

procedure TGenericFuncTests.TestSemantic_GenericFunc_ParamType_IsInteger;
var
  Prog: TProgram;
  GFI:  TGenericFuncInstance;
  Par:  TMethodParam;
begin
  Prog := AnalyseSrc(SrcGenericFuncUsage);
  try
    GFI := TGenericFuncInstance(Prog.GenericFuncInstances[0]);
    AssertEquals('one param', 1, GFI.MethodDecl.Params.Count);
    Par := TMethodParam(GFI.MethodDecl.Params[0]);
    AssertNotNull('param type not nil', Par.ResolvedType);
    AssertEquals('param type is Integer', Ord(tyInteger), Ord(Par.ResolvedType.Kind));
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Codegen — mangled names and emission                                 }
{ ------------------------------------------------------------------ }

procedure TGenericFuncTests.TestCodegen_GenericFunc_BodyEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcGenericFuncUsage);
  AssertTrue('body emitted with mangled name',
    Pos('$Identity_Integer', IR) > 0);
end;

procedure TGenericFuncTests.TestCodegen_GenericFunc_CallEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcGenericFuncUsage);
  AssertTrue('call emitted with mangled name',
    Pos('call $Identity_Integer', IR) > 0);
end;

initialization
  RegisterTest(TGenericFuncTests);
end.
