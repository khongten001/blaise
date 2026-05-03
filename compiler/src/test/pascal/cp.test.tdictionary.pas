{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.tdictionary;

{$mode objfpc}{$H+}

{ Tests for TDictionary<K,V> generic map: two-type-param generic,
  FindKey/Add/TryGetValue/ContainsKey/Remove operations, Count property.

  Key equality relies on the '=' operator on the monomorphized type;
  tests use Integer keys throughout.  String key support requires a
  content-aware RTL helper and is deferred. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TTDictionaryTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
  published
    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_TwoTypeParams_Parsed;
    procedure TestParse_Methods_InClassDecl;
    procedure TestParse_SeparateImpls_OwnerTypeName;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_IntInt_Instantiates;
    procedure TestSemantic_Add_ContainsKey_Compiles;
    procedure TestSemantic_TryGetValue_Compiles;
    procedure TestSemantic_Remove_Compiles;

    { ------------------------------------------------------------------ }
    { Codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_TypeInfoEmitted;
    procedure TestCodegen_FindKeyEmitted;
    procedure TestCodegen_AddEmitted;
    procedure TestCodegen_TryGetValueEmitted;
    procedure TestCodegen_ContainsKeyEmitted;
    procedure TestCodegen_RemoveEmitted;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Shared source building blocks                                         }
{ ------------------------------------------------------------------ }

const
  { Forward-only class declaration (interface section style) }
  DictDecl =
    'type'                                                    + LineEnding +
    '  TDictionary<K, V> = class'                            + LineEnding +
    '    FKeys:     ^K;'                                      + LineEnding +
    '    FValues:   ^V;'                                      + LineEnding +
    '    FCount:    Integer;'                                 + LineEnding +
    '    FCapacity: Integer;'                                 + LineEnding +
    '    procedure Grow;'                                     + LineEnding +
    '    function  FindKey(Key: K): Integer;'                + LineEnding +
    '    procedure Add(Key: K; Value: V);'                   + LineEnding +
    '    function  TryGetValue(Key: K; var Value: V): Boolean;' + LineEnding +
    '    function  ContainsKey(Key: K): Boolean;'            + LineEnding +
    '    procedure Remove(Key: K);'                          + LineEnding +
    '    property Count: Integer read FCount;'               + LineEnding +
    '  end;'                                                  + LineEnding;

  { Separate method implementations }
  DictImpls =
    'procedure TDictionary<K, V>.Grow;'                      + LineEnding +
    'var'                                                     + LineEnding +
    '  NewCap: Integer;'                                      + LineEnding +
    'begin'                                                   + LineEnding +
    '  if Self.FCapacity = 0 then'                           + LineEnding +
    '    NewCap := 8'                                         + LineEnding +
    '  else'                                                  + LineEnding +
    '    NewCap := Self.FCapacity * 2;'                       + LineEnding +
    '  Self.FKeys   := ReallocMem(Self.FKeys,   NewCap * SizeOf(K));' + LineEnding +
    '  Self.FValues := ReallocMem(Self.FValues, NewCap * SizeOf(V));' + LineEnding +
    '  Self.FCapacity := NewCap'                              + LineEnding +
    'end;'                                                    + LineEnding +
    'function TDictionary<K, V>.FindKey(Key: K): Integer;'  + LineEnding +
    'var'                                                     + LineEnding +
    '  I:   Integer;'                                         + LineEnding +
    '  Ptr: ^K;'                                              + LineEnding +
    'begin'                                                   + LineEnding +
    '  Result := -1;'                                         + LineEnding +
    '  I := 0;'                                               + LineEnding +
    '  while I < Self.FCount do'                              + LineEnding +
    '  begin'                                                 + LineEnding +
    '    Ptr := Self.FKeys + I * SizeOf(K);'                 + LineEnding +
    '    if Ptr^ = Key then'                                  + LineEnding +
    '    begin'                                               + LineEnding +
    '      Result := I;'                                      + LineEnding +
    '      I := Self.FCount'                                  + LineEnding +
    '    end'                                                 + LineEnding +
    '    else'                                                + LineEnding +
    '      I := I + 1'                                        + LineEnding +
    '  end'                                                   + LineEnding +
    'end;'                                                    + LineEnding +
    'procedure TDictionary<K, V>.Add(Key: K; Value: V);'    + LineEnding +
    'var'                                                     + LineEnding +
    '  Idx:  Integer;'                                        + LineEnding +
    '  KPtr: ^K;'                                             + LineEnding +
    '  VPtr: ^V;'                                             + LineEnding +
    'begin'                                                   + LineEnding +
    '  Idx := Self.FindKey(Key);'                            + LineEnding +
    '  if Idx >= 0 then'                                      + LineEnding +
    '  begin'                                                 + LineEnding +
    '    VPtr  := Self.FValues + Idx * SizeOf(V);'           + LineEnding +
    '    VPtr^ := Value'                                      + LineEnding +
    '  end'                                                   + LineEnding +
    '  else'                                                  + LineEnding +
    '  begin'                                                 + LineEnding +
    '    if Self.FCount = Self.FCapacity then'               + LineEnding +
    '      Self.Grow;'                                        + LineEnding +
    '    KPtr  := Self.FKeys   + Self.FCount * SizeOf(K);'  + LineEnding +
    '    VPtr  := Self.FValues + Self.FCount * SizeOf(V);'  + LineEnding +
    '    KPtr^ := Key;'                                       + LineEnding +
    '    VPtr^ := Value;'                                     + LineEnding +
    '    Self.FCount := Self.FCount + 1'                      + LineEnding +
    '  end'                                                   + LineEnding +
    'end;'                                                    + LineEnding +
    'function TDictionary<K, V>.TryGetValue(Key: K; var Value: V): Boolean;' + LineEnding +
    'var'                                                     + LineEnding +
    '  Idx:  Integer;'                                        + LineEnding +
    '  VPtr: ^V;'                                             + LineEnding +
    'begin'                                                   + LineEnding +
    '  Idx    := Self.FindKey(Key);'                         + LineEnding +
    '  Result := Idx >= 0;'                                   + LineEnding +
    '  if Idx >= 0 then'                                      + LineEnding +
    '  begin'                                                 + LineEnding +
    '    VPtr  := Self.FValues + Idx * SizeOf(V);'           + LineEnding +
    '    Value := VPtr^'                                      + LineEnding +
    '  end'                                                   + LineEnding +
    'end;'                                                    + LineEnding +
    'function TDictionary<K, V>.ContainsKey(Key: K): Boolean;' + LineEnding +
    'begin'                                                   + LineEnding +
    '  Result := Self.FindKey(Key) >= 0'                     + LineEnding +
    'end;'                                                    + LineEnding +
    'procedure TDictionary<K, V>.Remove(Key: K);'            + LineEnding +
    'var'                                                     + LineEnding +
    '  Idx:  Integer;'                                        + LineEnding +
    '  I:    Integer;'                                        + LineEnding +
    '  KDst: ^K;'                                             + LineEnding +
    '  KSrc: ^K;'                                             + LineEnding +
    '  VDst: ^V;'                                             + LineEnding +
    '  VSrc: ^V;'                                             + LineEnding +
    'begin'                                                   + LineEnding +
    '  Idx := Self.FindKey(Key);'                            + LineEnding +
    '  if Idx >= 0 then'                                      + LineEnding +
    '  begin'                                                 + LineEnding +
    '    I := Idx;'                                           + LineEnding +
    '    while I < Self.FCount - 1 do'                       + LineEnding +
    '    begin'                                               + LineEnding +
    '      KDst  := Self.FKeys   + I * SizeOf(K);'           + LineEnding +
    '      KSrc  := Self.FKeys   + (I + 1) * SizeOf(K);'    + LineEnding +
    '      VDst  := Self.FValues + I * SizeOf(V);'           + LineEnding +
    '      VSrc  := Self.FValues + (I + 1) * SizeOf(V);'    + LineEnding +
    '      KDst^ := KSrc^;'                                   + LineEnding +
    '      VDst^ := VSrc^;'                                   + LineEnding +
    '      I     := I + 1'                                    + LineEnding +
    '    end;'                                                + LineEnding +
    '    Self.FCount := Self.FCount - 1'                      + LineEnding +
    '  end'                                                   + LineEnding +
    'end;'                                                    + LineEnding;

  { Complete programs using TDictionary<Integer,Integer> }

  SrcCreate =
    'program P;'                                              + LineEnding +
    DictDecl +
    DictImpls +
    'var D: TDictionary<Integer, Integer>;'                  + LineEnding +
    'begin'                                                   + LineEnding +
    '  D := TDictionary<Integer, Integer>.Create'            + LineEnding +
    'end.';

  SrcAddGet =
    'program P;'                                              + LineEnding +
    DictDecl +
    DictImpls +
    'var'                                                     + LineEnding +
    '  D:  TDictionary<Integer, Integer>;'                   + LineEnding +
    '  OK: Boolean;'                                          + LineEnding +
    'begin'                                                   + LineEnding +
    '  D := TDictionary<Integer, Integer>.Create;'           + LineEnding +
    '  D.Add(1, 100);'                                        + LineEnding +
    '  D.Add(2, 200);'                                        + LineEnding +
    '  OK := D.ContainsKey(1)'                               + LineEnding +
    'end.';

  SrcTryGet =
    'program P;'                                              + LineEnding +
    DictDecl +
    DictImpls +
    'var'                                                     + LineEnding +
    '  D:  TDictionary<Integer, Integer>;'                   + LineEnding +
    '  V:  Integer;'                                          + LineEnding +
    '  OK: Boolean;'                                          + LineEnding +
    'begin'                                                   + LineEnding +
    '  D := TDictionary<Integer, Integer>.Create;'           + LineEnding +
    '  D.Add(42, 99);'                                        + LineEnding +
    '  OK := D.TryGetValue(42, V)'                           + LineEnding +
    'end.';

  SrcRemove =
    'program P;'                                              + LineEnding +
    DictDecl +
    DictImpls +
    'var'                                                     + LineEnding +
    '  D:  TDictionary<Integer, Integer>;'                   + LineEnding +
    '  OK: Boolean;'                                          + LineEnding +
    'begin'                                                   + LineEnding +
    '  D := TDictionary<Integer, Integer>.Create;'           + LineEnding +
    '  D.Add(7, 70);'                                         + LineEnding +
    '  D.Remove(7);'                                          + LineEnding +
    '  OK := D.ContainsKey(7)'                               + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Helpers                                                              }
{ ------------------------------------------------------------------ }

function TTDictionaryTests.ParseSrc(const ASrc: string): TProgram;
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

function TTDictionaryTests.AnalyseSrc(const ASrc: string): TProgram;
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

function TTDictionaryTests.GenIR(const ASrc: string): string;
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

procedure TTDictionaryTests.TestParse_TwoTypeParams_Parsed;
var
  Prog: TProgram;
  GD:   TGenericTypeDef;
begin
  Prog := ParseSrc(SrcCreate);
  try
    AssertEquals('One type decl', 1, Prog.Block.TypeDecls.Count);
    AssertTrue('Is generic type', TTypeDecl(Prog.Block.TypeDecls[0]).Def is TGenericTypeDef);
    GD := TGenericTypeDef(TTypeDecl(Prog.Block.TypeDecls[0]).Def);
    AssertEquals('Two type params', 2, GD.ParamNames.Count);
    AssertEquals('First param K', 'K', GD.ParamNames[0]);
    AssertEquals('Second param V', 'V', GD.ParamNames[1]);
  finally
    Prog.Free;
  end;
end;

procedure TTDictionaryTests.TestParse_Methods_InClassDecl;
var
  Prog: TProgram;
  GD:   TGenericTypeDef;
begin
  Prog := ParseSrc(SrcCreate);
  try
    GD := TGenericTypeDef(TTypeDecl(Prog.Block.TypeDecls[0]).Def);
    AssertEquals('Six methods in class', 6, GD.ClassDef.Methods.Count);
  finally
    Prog.Free;
  end;
end;

procedure TTDictionaryTests.TestParse_SeparateImpls_OwnerTypeName;
var
  Prog:  TProgram;
  MDecl: TMethodDecl;
begin
  Prog := ParseSrc(SrcCreate);
  try
    { ProcDecls[0] = Grow impl }
    AssertTrue('At least 6 proc decls', Prog.Block.ProcDecls.Count >= 6);
    MDecl := TMethodDecl(Prog.Block.ProcDecls[0]);
    AssertEquals('Grow OwnerTypeName', 'TDictionary', MDecl.OwnerTypeName);
    AssertTrue('Grow OwnerTypeParams set', MDecl.OwnerTypeParams <> nil);
    AssertEquals('Two owner type params', 2, MDecl.OwnerTypeParams.Count);
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                        }
{ ------------------------------------------------------------------ }

procedure TTDictionaryTests.TestSemantic_IntInt_Instantiates;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcCreate);
  Prog.Free;
end;

procedure TTDictionaryTests.TestSemantic_Add_ContainsKey_Compiles;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcAddGet);
  Prog.Free;
end;

procedure TTDictionaryTests.TestSemantic_TryGetValue_Compiles;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcTryGet);
  Prog.Free;
end;

procedure TTDictionaryTests.TestSemantic_Remove_Compiles;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcRemove);
  Prog.Free;
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                         }
{ ------------------------------------------------------------------ }

procedure TTDictionaryTests.TestCodegen_TypeInfoEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcCreate);
  AssertTrue('Typeinfo emitted',
    Pos('typeinfo_TDictionary_Integer_Integer', IR) > 0);
end;

procedure TTDictionaryTests.TestCodegen_FindKeyEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcAddGet);
  AssertTrue('FindKey body emitted',
    Pos('$TDictionary_Integer_Integer_FindKey', IR) > 0);
end;

procedure TTDictionaryTests.TestCodegen_AddEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcAddGet);
  AssertTrue('Add body emitted',
    Pos('$TDictionary_Integer_Integer_Add', IR) > 0);
end;

procedure TTDictionaryTests.TestCodegen_TryGetValueEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcTryGet);
  AssertTrue('TryGetValue body emitted',
    Pos('$TDictionary_Integer_Integer_TryGetValue', IR) > 0);
end;

procedure TTDictionaryTests.TestCodegen_ContainsKeyEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcAddGet);
  AssertTrue('ContainsKey body emitted',
    Pos('$TDictionary_Integer_Integer_ContainsKey', IR) > 0);
end;

procedure TTDictionaryTests.TestCodegen_RemoveEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcRemove);
  AssertTrue('Remove body emitted',
    Pos('$TDictionary_Integer_Integer_Remove', IR) > 0);
end;

initialization
  RegisterTest(TTDictionaryTests);

end.
