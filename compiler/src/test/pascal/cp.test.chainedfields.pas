{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.chainedfields;

{$mode objfpc}{$H+}

{ Tests for chained field access expressions: A.B.C and deeper. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TChainedFieldTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
  published
    procedure TestParse_TwoDots_HasBase;
    procedure TestParse_ThreeDots_HasNestedBases;
    procedure TestSemantic_RecordChain_ResolvesToInnerType;
    procedure TestSemantic_ClassFieldThenRecordField_Resolves;
    procedure TestCodegen_RecordChain_EmitsLoadw;
    procedure TestCodegen_ImplicitSelfChain_LoadsThroughSelf;
  end;

implementation

function TChainedFieldTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try Result := P.Parse; finally P.Free; L.Free; end;
end;

function TChainedFieldTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try A.Analyse(Result); finally A.Free; end;
end;

function TChainedFieldTests.GenIR(const ASrc: string): string;
var Prog: TProgram; CG: TCodeGenQBE;
begin
  Prog := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create;
    try CG.Generate(Prog); Result := CG.GetOutput; finally CG.Free; end;
  finally Prog.Free; end;
end;

const
  SrcTwoDeep =
    'program P;'                                    + LineEnding +
    'type'                                          + LineEnding +
    '  TInner = record'                             + LineEnding +
    '    Value: Integer;'                           + LineEnding +
    '  end;'                                        + LineEnding +
    '  TOuter = record'                             + LineEnding +
    '    Inner: TInner;'                            + LineEnding +
    '  end;'                                        + LineEnding +
    'var O: TOuter; N: Integer;'                    + LineEnding +
    'begin'                                         + LineEnding +
    '  N := O.Inner.Value'                          + LineEnding +
    'end.';

  SrcThreeDeep =
    'program P;'                                    + LineEnding +
    'type'                                          + LineEnding +
    '  TA = record X: Integer; end;'                + LineEnding +
    '  TB = record A: TA; end;'                     + LineEnding +
    '  TC = record B: TB; end;'                     + LineEnding +
    'var C: TC; N: Integer;'                        + LineEnding +
    'begin'                                         + LineEnding +
    '  N := C.B.A.X'                                + LineEnding +
    'end.';

  SrcClassFieldOfRecord =
    'program P;'                                    + LineEnding +
    'type'                                          + LineEnding +
    '  TThing = class(TObject)'                     + LineEnding +
    '    Inner: Integer;'                           + LineEnding +
    '  end;'                                        + LineEnding +
    '  TBox = record'                               + LineEnding +
    '    Thing: TThing;'                            + LineEnding +
    '  end;'                                        + LineEnding +
    'var B: TBox; N: Integer; T: TThing;'           + LineEnding +
    'begin'                                         + LineEnding +
    '  B.Thing := TThing.Create;'                   + LineEnding +
    '  N := B.Thing.Inner;'                         + LineEnding +
    '  T := B.Thing;'                               + LineEnding +
    '  T.Free'                                      + LineEnding +
    'end.';

procedure TChainedFieldTests.TestParse_TwoDots_HasBase;
var Prog: TProgram; Assn: TAssignment; Fld: TFieldAccessExpr;
begin
  Prog := ParseSrc(SrcTwoDeep);
  try
    Assn := TAssignment(Prog.Block.Stmts[0]);
    AssertTrue('rhs is field access', Assn.Expr is TFieldAccessExpr);
    Fld := TFieldAccessExpr(Assn.Expr);
    AssertEquals('outer field name', 'Value', Fld.FieldName);
    AssertNotNull('has Base', Fld.Base);
    AssertTrue('base is field access', Fld.Base is TFieldAccessExpr);
    AssertEquals('inner field name', 'Inner',
      TFieldAccessExpr(Fld.Base).FieldName);
  finally Prog.Free; end;
end;

procedure TChainedFieldTests.TestParse_ThreeDots_HasNestedBases;
var Prog: TProgram; Assn: TAssignment; Fld: TFieldAccessExpr;
begin
  Prog := ParseSrc(SrcThreeDeep);
  try
    Assn := TAssignment(Prog.Block.Stmts[0]);
    Fld := TFieldAccessExpr(Assn.Expr);
    AssertEquals('leaf field', 'X', Fld.FieldName);
    AssertTrue('base 1 is field access', Fld.Base is TFieldAccessExpr);
    AssertEquals('mid field', 'A', TFieldAccessExpr(Fld.Base).FieldName);
    AssertTrue('base 2 is field access',
      TFieldAccessExpr(Fld.Base).Base is TFieldAccessExpr);
    AssertEquals('base field', 'B',
      TFieldAccessExpr(TFieldAccessExpr(Fld.Base).Base).FieldName);
  finally Prog.Free; end;
end;

procedure TChainedFieldTests.TestSemantic_RecordChain_ResolvesToInnerType;
var Prog: TProgram; Assn: TAssignment;
begin
  Prog := AnalyseSrc(SrcTwoDeep);
  try
    Assn := TAssignment(Prog.Block.Stmts[0]);
    AssertEquals('chain type is Integer',
      Ord(tyInteger), Ord(Assn.Expr.ResolvedType.Kind));
  finally Prog.Free; end;
end;

procedure TChainedFieldTests.TestSemantic_ClassFieldThenRecordField_Resolves;
var Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcClassFieldOfRecord);
  try AssertNotNull(Prog); finally Prog.Free; end;
end;

procedure TChainedFieldTests.TestCodegen_RecordChain_EmitsLoadw;
var IR: string;
begin
  IR := GenIR(SrcTwoDeep);
  AssertTrue('emits loadw for inner integer field',
    Pos('loadw', IR) > 0);
end;

{ Regression: a chained field access whose leftmost identifier is an implicit
  Self field (e.g. FField.SubField.Property inside a method) must load the
  base through %_var_Self, not through a phantom %_var_FField local.        }
procedure TChainedFieldTests.TestCodegen_ImplicitSelfChain_LoadsThroughSelf;
const
  Src =
    'program P;'                                          + LineEnding +
    'type'                                                + LineEnding +
    '  TLeaf = class'                                     + LineEnding +
    '    Value: Integer;'                                 + LineEnding +
    '  end;'                                              + LineEnding +
    '  TInner = class'                                    + LineEnding +
    '    Leaf: TLeaf;'                                    + LineEnding +
    '  end;'                                              + LineEnding +
    '  TOuter = class'                                    + LineEnding +
    '    FInner: TInner;'                                 + LineEnding +
    '    procedure Work;'                                 + LineEnding +
    '  end;'                                              + LineEnding +
    'procedure TOuter.Work;'                              + LineEnding +
    'var I, K: Integer;'                                  + LineEnding +
    'begin'                                               + LineEnding +
    '  K := 0;'                                           + LineEnding +
    '  for I := 0 to FInner.Leaf.Value - 1 do K := K + 1;'+ LineEnding +
    'end;'                                                + LineEnding +
    'begin'                                               + LineEnding +
    'end.';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('does not emit phantom %_var_FInner',
    Pos('%_var_FInner', IR) = 0);
  AssertTrue('loads through %_var_Self',
    Pos('loadl %_var_Self', IR) > 0);
end;

initialization
  RegisterTest(TChainedFieldTests);

end.
