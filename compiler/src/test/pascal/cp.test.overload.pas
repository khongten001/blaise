{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.overload;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TOverloadTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    procedure AnalyseExpectError(const ASrc: string);
  published
    { Phase A — arity-distinct standalone overloading }

    { Parser: 'overload' directive sets the IsOverload flag on TMethodDecl }
    procedure TestParse_OverloadDirective_SetsFlag;

    { Semantic: two same-named procs with 'overload' both keep their decls }
    procedure TestSemantic_TwoArities_BothRegistered;

    { Semantic: duplicate name without 'overload' is rejected }
    procedure TestSemantic_DuplicateWithoutOverload_RaisesError;

    { Semantic: mixing 'overload' with non-'overload' is rejected }
    procedure TestSemantic_MixingOverloadAndPlain_RaisesError;

    { Semantic: call site with no matching arity raises error }
    procedure TestSemantic_NoMatchingArity_RaisesError;

    { Codegen: each overload gets a distinct mangled QBE name }
    procedure TestCodegen_TwoArities_DistinctQBENames;

    { Codegen: call sites resolve to the correct mangled name based on arg count }
    procedure TestCodegen_CallSite_ResolvesByArity;

    { Phase B — type-distinct resolution }

    { Two same-arity overloads distinguished only by parameter type }
    procedure TestSemantic_TypeDistinct_BothRegistered;

    { Codegen: per-type mangled names use the type-code scheme }
    procedure TestCodegen_TypeDistinct_DistinctQBENames;

    { Resolution: exact-type match preferred over widening (Integer
      argument selects Integer overload, not Double overload) }
    procedure TestCodegen_ExactMatch_BeatsWidening;

    { Resolution: when no exact match, widening is taken (Integer argument
      selects Double overload when no Integer overload exists) }
    procedure TestCodegen_WideningMatch_Used;

    { Two same-arity overloads where the argument is an exact match for
      neither but a widening match for both — must be flagged ambiguous }
    procedure TestSemantic_AmbiguousOverload_RaisesError;

    { Phase C — class method overloading }

    { Two methods sharing a name but distinguished by parameter type }
    procedure TestSemantic_ClassOverload_BothRegistered;
    procedure TestCodegen_ClassOverload_DistinctQBENames;
    procedure TestCodegen_ClassOverload_CallSitesMangled;

    { Class method dup without 'overload' rejected }
    procedure TestSemantic_ClassDupNoOverload_RaisesError;

    { virtual + overload base; override + overload descendant }
    procedure TestCodegen_VirtualOverload_DistinctVTableSlots;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TOverloadTests.ParseSrc(const ASrc: string): TProgram;
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

function TOverloadTests.AnalyseSrc(const ASrc: string): TProgram;
var
  A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try
    A.Analyse(Result);
  finally
    A.Free;
  end;
end;

function TOverloadTests.GenIR(const ASrc: string): string;
var
  Prog: TProgram;
  CG:   TCodeGenQBE;
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

procedure TOverloadTests.AnalyseExpectError(const ASrc: string);
var
  Prog: TProgram;
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
{ Shared sources                                                      }
{ ------------------------------------------------------------------ }

const
  SrcTwoArities =
    'program P;'                                            + LineEnding +
    'procedure Greet; overload;'                            + LineEnding +
    'begin'                                                 + LineEnding +
    '  WriteLn(''hello'')'                                  + LineEnding +
    'end;'                                                  + LineEnding +
    'procedure Greet(N: Integer); overload;'                + LineEnding +
    'begin'                                                 + LineEnding +
    '  WriteLn(N)'                                          + LineEnding +
    'end;'                                                  + LineEnding +
    'begin'                                                 + LineEnding +
    '  Greet;'                                              + LineEnding +
    '  Greet(42)'                                           + LineEnding +
    'end.';

  SrcDupNoOverload =
    'program P;'                                            + LineEnding +
    'procedure Greet;'                                      + LineEnding +
    'begin'                                                 + LineEnding +
    'end;'                                                  + LineEnding +
    'procedure Greet(N: Integer);'                          + LineEnding +
    'begin'                                                 + LineEnding +
    'end;'                                                  + LineEnding +
    'begin'                                                 + LineEnding +
    'end.';

  SrcMixedOverloadFlag =
    'program P;'                                            + LineEnding +
    'procedure Greet; overload;'                            + LineEnding +
    'begin'                                                 + LineEnding +
    'end;'                                                  + LineEnding +
    'procedure Greet(N: Integer);'                          + LineEnding +
    'begin'                                                 + LineEnding +
    'end;'                                                  + LineEnding +
    'begin'                                                 + LineEnding +
    'end.';

  SrcNoMatchingArity =
    'program P;'                                            + LineEnding +
    'procedure Greet; overload;'                            + LineEnding +
    'begin'                                                 + LineEnding +
    'end;'                                                  + LineEnding +
    'procedure Greet(N: Integer); overload;'                + LineEnding +
    'begin'                                                 + LineEnding +
    'end;'                                                  + LineEnding +
    'begin'                                                 + LineEnding +
    '  Greet(1, 2)'                                         + LineEnding +
    'end.';

  SrcTypeDistinct =
    'program P;'                                            + LineEnding +
    'procedure Show(N: Integer); overload;'                 + LineEnding +
    'begin'                                                 + LineEnding +
    '  WriteLn(N)'                                          + LineEnding +
    'end;'                                                  + LineEnding +
    'procedure Show(S: string); overload;'                  + LineEnding +
    'begin'                                                 + LineEnding +
    '  WriteLn(S)'                                          + LineEnding +
    'end;'                                                  + LineEnding +
    'begin'                                                 + LineEnding +
    '  Show(42);'                                           + LineEnding +
    '  Show(''hi'')'                                        + LineEnding +
    'end.';

  { Two same-arity overloads — Integer + Double.  Calling with an
    Integer literal must pick the Integer overload (exact match). }
  SrcExactBeatsWidening =
    'program P;'                                            + LineEnding +
    'procedure F(N: Integer); overload;'                    + LineEnding +
    'begin'                                                 + LineEnding +
    '  WriteLn(N)'                                          + LineEnding +
    'end;'                                                  + LineEnding +
    'procedure F(D: Double); overload;'                     + LineEnding +
    'begin'                                                 + LineEnding +
    '  WriteLn(DoubleToStr(D))'                             + LineEnding +
    'end;'                                                  + LineEnding +
    'begin'                                                 + LineEnding +
    '  F(42)'                                               + LineEnding +
    'end.';

  { Single Double overload, called with Integer — widening succeeds. }
  SrcWideningUsed =
    'program P;'                                            + LineEnding +
    'procedure F(D: Double); overload;'                     + LineEnding +
    'begin'                                                 + LineEnding +
    '  WriteLn(DoubleToStr(D))'                             + LineEnding +
    'end;'                                                  + LineEnding +
    'begin'                                                 + LineEnding +
    '  F(42)'                                               + LineEnding +
    'end.';

  SrcClassOverload =
    'program P;'                                            + LineEnding +
    'type'                                                  + LineEnding +
    '  TFoo = class'                                        + LineEnding +
    '    procedure Show(N: Integer); overload;'             + LineEnding +
    '    procedure Show(S: string); overload;'              + LineEnding +
    '  end;'                                                + LineEnding +
    '  procedure TFoo.Show(N: Integer); overload;'          + LineEnding +
    '  begin WriteLn(N) end;'                               + LineEnding +
    '  procedure TFoo.Show(S: string); overload;'           + LineEnding +
    '  begin WriteLn(S) end;'                               + LineEnding +
    'var F: TFoo;'                                          + LineEnding +
    'begin'                                                 + LineEnding +
    '  F := TFoo.Create;'                                   + LineEnding +
    '  F.Show(42);'                                         + LineEnding +
    '  F.Show(''hi'')'                                      + LineEnding +
    'end.';

  SrcClassDupNoOverload =
    'program P;'                                            + LineEnding +
    'type'                                                  + LineEnding +
    '  TFoo = class'                                        + LineEnding +
    '    procedure Show(N: Integer);'                       + LineEnding +
    '    procedure Show(S: string);'                        + LineEnding +
    '  end;'                                                + LineEnding +
    '  procedure TFoo.Show(N: Integer);'                    + LineEnding +
    '  begin end;'                                          + LineEnding +
    '  procedure TFoo.Show(S: string);'                     + LineEnding +
    '  begin end;'                                          + LineEnding +
    'begin end.';

  SrcVirtualOverload =
    'program P;'                                            + LineEnding +
    'type'                                                  + LineEnding +
    '  TBase = class'                                       + LineEnding +
    '    procedure Greet(N: Integer); overload; virtual;'   + LineEnding +
    '    procedure Greet(S: string);  overload; virtual;'   + LineEnding +
    '  end;'                                                + LineEnding +
    '  TChild = class(TBase)'                               + LineEnding +
    '    procedure Greet(N: Integer); overload; override;'  + LineEnding +
    '    procedure Greet(S: string);  overload; override;'  + LineEnding +
    '  end;'                                                + LineEnding +
    '  procedure TBase.Greet(N: Integer); overload;'        + LineEnding +
    '  begin WriteLn(''base int '', N) end;'                + LineEnding +
    '  procedure TBase.Greet(S: string); overload;'         + LineEnding +
    '  begin WriteLn(''base str '', S) end;'                + LineEnding +
    '  procedure TChild.Greet(N: Integer); overload;'       + LineEnding +
    '  begin WriteLn(''child int '', N) end;'               + LineEnding +
    '  procedure TChild.Greet(S: string); overload;'        + LineEnding +
    '  begin WriteLn(''child str '', S) end;'               + LineEnding +
    'begin end.';

  { Two same-arity overloads — Double + Single — both reachable from an
    integer literal only by widening, with equal score → ambiguous. }
  SrcAmbiguousOverload =
    'program P;'                                            + LineEnding +
    'procedure F(D: Double); overload;'                     + LineEnding +
    'begin'                                                 + LineEnding +
    'end;'                                                  + LineEnding +
    'procedure F(S: Single); overload;'                     + LineEnding +
    'begin'                                                 + LineEnding +
    'end;'                                                  + LineEnding +
    'begin'                                                 + LineEnding +
    '  F(42)'                                               + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Tests                                                               }
{ ------------------------------------------------------------------ }

procedure TOverloadTests.TestParse_OverloadDirective_SetsFlag;
var
  Prog: TProgram;
  MD:   TMethodDecl;
begin
  Prog := ParseSrc(SrcTwoArities);
  try
    AssertEquals('two procs parsed', 2, Prog.Block.ProcDecls.Count);
    MD := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertTrue('first proc has IsOverload=True', MD.IsOverload);
    MD := TMethodDecl(Prog.Block.ProcDecls[1]);
    AssertTrue('second proc has IsOverload=True', MD.IsOverload);
  finally
    Prog.Free;
  end;
end;

procedure TOverloadTests.TestSemantic_TwoArities_BothRegistered;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcTwoArities);
  try
    AssertEquals('both proc decls survive', 2, Prog.Block.ProcDecls.Count);
  finally
    Prog.Free;
  end;
end;

procedure TOverloadTests.TestSemantic_DuplicateWithoutOverload_RaisesError;
begin
  AnalyseExpectError(SrcDupNoOverload);
end;

procedure TOverloadTests.TestSemantic_MixingOverloadAndPlain_RaisesError;
begin
  AnalyseExpectError(SrcMixedOverloadFlag);
end;

procedure TOverloadTests.TestSemantic_NoMatchingArity_RaisesError;
begin
  AnalyseExpectError(SrcNoMatchingArity);
end;

procedure TOverloadTests.TestCodegen_TwoArities_DistinctQBENames;
var
  IR: string;
begin
  IR := GenIR(SrcTwoArities);
  { Type-code mangling: '$' in the resolved name is escaped to '_D_' in QBE
    symbols (QBE allows '$' inside identifiers, but other downstream tools
    do not).  Zero-arg overload is '_D_' (empty signature), Integer overload
    is '_D_i'. }
  AssertTrue('zero-arg overload defined',
    Pos('function $Greet_D_(', IR) > 0);
  AssertTrue('Integer overload defined',
    Pos('function $Greet_D_i(', IR) > 0);
end;

procedure TOverloadTests.TestCodegen_CallSite_ResolvesByArity;
var
  IR: string;
begin
  IR := GenIR(SrcTwoArities);
  AssertTrue('zero-arg call site mangled',
    Pos('call $Greet_D_(', IR) > 0);
  AssertTrue('Integer call site mangled',
    Pos('call $Greet_D_i(', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ Phase B — type-distinct resolution                                  }
{ ------------------------------------------------------------------ }

procedure TOverloadTests.TestSemantic_TypeDistinct_BothRegistered;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcTypeDistinct);
  try
    AssertEquals('both proc decls survive', 2, Prog.Block.ProcDecls.Count);
  finally
    Prog.Free;
  end;
end;

procedure TOverloadTests.TestCodegen_TypeDistinct_DistinctQBENames;
var
  IR: string;
begin
  IR := GenIR(SrcTypeDistinct);
  AssertTrue('Integer-typed overload uses ''i'' suffix',
    Pos('function $Show_D_i(', IR) > 0);
  AssertTrue('string-typed overload uses ''S'' suffix',
    Pos('function $Show_D_S(', IR) > 0);
  AssertTrue('Integer call site mangled',
    Pos('call $Show_D_i(', IR) > 0);
  AssertTrue('string call site mangled',
    Pos('call $Show_D_S(', IR) > 0);
end;

procedure TOverloadTests.TestCodegen_ExactMatch_BeatsWidening;
var
  IR: string;
begin
  IR := GenIR(SrcExactBeatsWidening);
  AssertTrue('exact-match overload selected (Integer)',
    Pos('call $F_D_i(', IR) > 0);
  AssertFalse('widening overload not selected (Double)',
    Pos('call $F_D_d(', IR) > 0);
end;

procedure TOverloadTests.TestCodegen_WideningMatch_Used;
var
  IR: string;
begin
  IR := GenIR(SrcWideningUsed);
  AssertTrue('widening overload selected (Double)',
    Pos('call $F_D_d(', IR) > 0);
end;

procedure TOverloadTests.TestSemantic_AmbiguousOverload_RaisesError;
begin
  AnalyseExpectError(SrcAmbiguousOverload);
end;

{ ------------------------------------------------------------------ }
{ Phase C — class method overloading                                  }
{ ------------------------------------------------------------------ }

procedure TOverloadTests.TestSemantic_ClassOverload_BothRegistered;
var
  Prog: TProgram;
  CD:   TClassTypeDef;
begin
  Prog := AnalyseSrc(SrcClassOverload);
  try
    CD := TClassTypeDef(TTypeDecl(Prog.Block.TypeDecls[0]).Def);
    AssertEquals('TFoo has two Show methods', 2, CD.Methods.Count);
  finally
    Prog.Free;
  end;
end;

procedure TOverloadTests.TestCodegen_ClassOverload_DistinctQBENames;
var
  IR: string;
begin
  IR := GenIR(SrcClassOverload);
  AssertTrue('Integer overload defined as $TFoo_Show_D_i',
    Pos('function $TFoo_Show_D_i(', IR) > 0);
  AssertTrue('string overload defined as $TFoo_Show_D_S',
    Pos('function $TFoo_Show_D_S(', IR) > 0);
end;

procedure TOverloadTests.TestCodegen_ClassOverload_CallSitesMangled;
var
  IR: string;
begin
  IR := GenIR(SrcClassOverload);
  AssertTrue('Integer call site mangled',
    Pos('call $TFoo_Show_D_i(', IR) > 0);
  AssertTrue('string call site mangled',
    Pos('call $TFoo_Show_D_S(', IR) > 0);
end;

procedure TOverloadTests.TestSemantic_ClassDupNoOverload_RaisesError;
begin
  AnalyseExpectError(SrcClassDupNoOverload);
end;

procedure TOverloadTests.TestCodegen_VirtualOverload_DistinctVTableSlots;
var
  IR: string;
begin
  IR := GenIR(SrcVirtualOverload);
  { Each (name, signature) pair gets its own vtable slot.  The TBase
    typeinfo data record carries one entry per slot pointing to the
    matching base implementation; TChild carries overrides keyed by
    the same mangled signatures. }
  AssertTrue('TBase Integer slot',
    Pos('$TBase_Greet_D_i', IR) > 0);
  AssertTrue('TBase string slot',
    Pos('$TBase_Greet_D_S', IR) > 0);
  AssertTrue('TChild Integer override',
    Pos('$TChild_Greet_D_i', IR) > 0);
  AssertTrue('TChild string override',
    Pos('$TChild_Greet_D_S', IR) > 0);
end;

initialization
  RegisterTest(TOverloadTests);

end.
