{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.genericconstraints;

{$mode objfpc}{$H+}

{ Tests for generic type parameter constraints:
    <T: class>        — T must be a class type
    <T: record>       — T must be a value type
    <T: SomeTypeName> — T must be that type (or subclass / implementor). }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TGenericConstraintTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    procedure AnalyseExpectError(const ASrc: string);
  published
    procedure TestParse_GenericType_ClassConstraint;
    procedure TestParse_GenericType_RecordConstraint;
    procedure TestParse_GenericType_NamedConstraint;
    procedure TestParse_GenericType_TwoParamsWithMixedConstraints;
    procedure TestParse_GenericFunc_ClassConstraint;
    procedure TestParse_GenericFunc_NamedConstraint;
    procedure TestSemantic_GenericFunc_ClassConstraint_Violation;
    procedure TestSemantic_GenericFunc_ClassConstraint_Satisfied;
    procedure TestSemantic_GenericType_ClassConstraint_Violation;
    procedure TestSemantic_GenericFunc_NamedConstraint_Violation;
    procedure TestSemantic_GenericFunc_NamedConstraint_Satisfied;
  end;

implementation

function TGenericConstraintTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try Result := P.Parse; finally P.Free; L.Free; end;
end;

function TGenericConstraintTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try A.Analyse(Result); finally A.Free; end;
end;

procedure TGenericConstraintTests.AnalyseExpectError(const ASrc: string);
var Prog: TProgram;
begin
  try
    Prog := AnalyseSrc(ASrc);
    Prog.Free;
    Fail('Expected ESemanticError');
  except
    on E: ESemanticError do ;
  end;
end;

procedure TGenericConstraintTests.TestParse_GenericType_ClassConstraint;
var Prog: TProgram; TD: TTypeDecl; GD: TGenericTypeDef;
begin
  Prog := ParseSrc(
    'program P;'                                    + LineEnding +
    'type'                                          + LineEnding +
    '  TBox<T: class> = class'                      + LineEnding +
    '    FItem: Integer;'                           + LineEnding +
    '  end;'                                        + LineEnding +
    'begin end.');
  try
    TD := TTypeDecl(Prog.Block.TypeDecls[0]);
    AssertTrue(TD.Def is TGenericTypeDef);
    GD := TGenericTypeDef(TD.Def);
    AssertEquals(1, GD.ParamNames.Count);
    AssertEquals('T', GD.ParamNames[0]);
    AssertEquals('class', GD.ParamConstraints[0]);
  finally Prog.Free; end;
end;

procedure TGenericConstraintTests.TestParse_GenericType_RecordConstraint;
var Prog: TProgram; TD: TTypeDecl; GD: TGenericTypeDef;
begin
  Prog := ParseSrc(
    'program P;'                                    + LineEnding +
    'type'                                          + LineEnding +
    '  TBox<T: record> = class'                     + LineEnding +
    '    FItem: Integer;'                           + LineEnding +
    '  end;'                                        + LineEnding +
    'begin end.');
  try
    TD := TTypeDecl(Prog.Block.TypeDecls[0]);
    GD := TGenericTypeDef(TD.Def);
    AssertEquals('record', GD.ParamConstraints[0]);
  finally Prog.Free; end;
end;

procedure TGenericConstraintTests.TestParse_GenericType_NamedConstraint;
var Prog: TProgram; TD: TTypeDecl; GD: TGenericTypeDef;
begin
  Prog := ParseSrc(
    'program P;'                                    + LineEnding +
    'type'                                          + LineEnding +
    '  TAnimal = class(TObject) X: Integer; end;'   + LineEnding +
    '  TPen<T: TAnimal> = class'                    + LineEnding +
    '    FCount: Integer;'                          + LineEnding +
    '  end;'                                        + LineEnding +
    'begin end.');
  try
    TD := TTypeDecl(Prog.Block.TypeDecls[1]);
    GD := TGenericTypeDef(TD.Def);
    AssertEquals('TAnimal', GD.ParamConstraints[0]);
  finally Prog.Free; end;
end;

procedure TGenericConstraintTests.TestParse_GenericType_TwoParamsWithMixedConstraints;
var Prog: TProgram; TD: TTypeDecl; GD: TGenericTypeDef;
begin
  Prog := ParseSrc(
    'program P;'                                    + LineEnding +
    'type'                                          + LineEnding +
    '  TPair<K, V: class> = class'                  + LineEnding +
    '    FKey: Integer;'                            + LineEnding +
    '  end;'                                        + LineEnding +
    'begin end.');
  try
    TD := TTypeDecl(Prog.Block.TypeDecls[0]);
    GD := TGenericTypeDef(TD.Def);
    AssertEquals(2, GD.ParamNames.Count);
    AssertEquals('', GD.ParamConstraints[0]);  { K unconstrained }
    AssertEquals('class', GD.ParamConstraints[1]);
  finally Prog.Free; end;
end;

procedure TGenericConstraintTests.TestParse_GenericFunc_ClassConstraint;
var Prog: TProgram; MD: TMethodDecl;
begin
  Prog := ParseSrc(
    'program P;'                                    + LineEnding +
    'function Id<T: class>(A: T): T;'               + LineEnding +
    'begin Result := A end;'                        + LineEnding +
    'begin end.');
  try
    MD := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertNotNull(MD.TypeParams);
    AssertEquals('class', MD.TypeParamConstraints[0]);
  finally Prog.Free; end;
end;

procedure TGenericConstraintTests.TestParse_GenericFunc_NamedConstraint;
var Prog: TProgram; MD: TMethodDecl;
begin
  Prog := ParseSrc(
    'program P;'                                         + LineEnding +
    'type TAnimal = class(TObject) X: Integer; end;'     + LineEnding +
    'function Box<T: TAnimal>(A: T): Integer;'           + LineEnding +
    'begin Result := 0 end;'                             + LineEnding +
    'begin end.');
  try
    MD := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertEquals('TAnimal', MD.TypeParamConstraints[0]);
  finally Prog.Free; end;
end;

procedure TGenericConstraintTests.TestSemantic_GenericFunc_ClassConstraint_Violation;
begin
  { Integer is not a class — must raise }
  AnalyseExpectError(
    'program P;'                                    + LineEnding +
    'function Id<T: class>(A: T): T;'               + LineEnding +
    'begin Result := A end;'                        + LineEnding +
    'var N: Integer;'                               + LineEnding +
    'begin'                                         + LineEnding +
    '  N := Id<Integer>(5)'                         + LineEnding +
    'end.');
end;

procedure TGenericConstraintTests.TestSemantic_GenericFunc_ClassConstraint_Satisfied;
var Prog: TProgram;
begin
  Prog := AnalyseSrc(
    'program P;'                                    + LineEnding +
    'type TAnimal = class(TObject) X: Integer; end;' + LineEnding +
    'function Id<T: class>(A: T): T;'               + LineEnding +
    'begin Result := A end;'                        + LineEnding +
    'var A: TAnimal;'                               + LineEnding +
    'begin'                                         + LineEnding +
    '  A := TAnimal.Create;'                        + LineEnding +
    '  A := Id<TAnimal>(A);'                        + LineEnding +
    '  A.Free'                                      + LineEnding +
    'end.');
  try AssertNotNull(Prog); finally Prog.Free; end;
end;

procedure TGenericConstraintTests.TestSemantic_GenericType_ClassConstraint_Violation;
begin
  AnalyseExpectError(
    'program P;'                                    + LineEnding +
    'type'                                          + LineEnding +
    '  TBox<T: class> = class'                      + LineEnding +
    '    FItem: Integer;'                           + LineEnding +
    '  end;'                                        + LineEnding +
    'var B: TBox<Integer>;'                         + LineEnding +
    'begin end.');
end;

procedure TGenericConstraintTests.TestSemantic_GenericFunc_NamedConstraint_Violation;
begin
  { TCat does not inherit from TDog → must raise }
  AnalyseExpectError(
    'program P;'                                             + LineEnding +
    'type'                                                   + LineEnding +
    '  TDog = class(TObject) X: Integer; end;'               + LineEnding +
    '  TCat = class(TObject) Y: Integer; end;'               + LineEnding +
    'function Use<T: TDog>(A: T): Integer;'                  + LineEnding +
    'begin Result := 0 end;'                                 + LineEnding +
    'var C: TCat; N: Integer;'                               + LineEnding +
    'begin'                                                  + LineEnding +
    '  C := TCat.Create;'                                    + LineEnding +
    '  N := Use<TCat>(C);'                                   + LineEnding +
    '  C.Free'                                               + LineEnding +
    'end.');
end;

procedure TGenericConstraintTests.TestSemantic_GenericFunc_NamedConstraint_Satisfied;
var Prog: TProgram;
begin
  { TPuppy inherits from TDog → OK }
  Prog := AnalyseSrc(
    'program P;'                                             + LineEnding +
    'type'                                                   + LineEnding +
    '  TDog = class(TObject) X: Integer; end;'               + LineEnding +
    '  TPuppy = class(TDog) Y: Integer; end;'                + LineEnding +
    'function Use<T: TDog>(A: T): Integer;'                  + LineEnding +
    'begin Result := 0 end;'                                 + LineEnding +
    'var P: TPuppy; N: Integer;'                             + LineEnding +
    'begin'                                                  + LineEnding +
    '  P := TPuppy.Create;'                                  + LineEnding +
    '  N := Use<TPuppy>(P);'                                 + LineEnding +
    '  P.Free'                                               + LineEnding +
    'end.');
  try AssertNotNull(Prog); finally Prog.Free; end;
end;

initialization
  RegisterTest(TGenericConstraintTests);

end.
