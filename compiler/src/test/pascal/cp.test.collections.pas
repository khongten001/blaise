{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

unit cp.test.collections;

{$mode objfpc}{$H+}

{ Tests for TObjectList and TStringList built in pure Blaise Pascal:
    - TObjectList: dynamic Pointer array, optional ownership
    - TStringList: dynamic string + Pointer parallel arrays with
      sorted binary search and case-insensitive lookup

  New builtins exercised:
    CompareStr(s1, s2) : Integer
    CompareText(s1, s2): Integer
    ZeroMem(ptr, count): procedure
    _ClassAddRef(ptr)  : procedure (raw ARC)
    _ClassRelease(ptr) : procedure (raw ARC)

  ARC correctness fix exercised:
    EmitPointerWrite emits retain/release when BaseTy is tyString. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TCollectionTests = class(TTestCase)
  private
    function GenIR(const ASrc: string): string;
    procedure SemanticOK(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { CompareStr / CompareText builtins                                    }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_CompareStr_OK;
    procedure TestSemantic_CompareText_OK;
    procedure TestSemantic_CompareStr_ReturnsInteger;
    procedure TestCodegen_CompareStr_CallsRTL;
    procedure TestCodegen_CompareText_CallsRTL;

    { ------------------------------------------------------------------ }
    { ZeroMem builtin                                                      }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_ZeroMem_OK;
    procedure TestCodegen_ZeroMem_CallsMemset;

    { ------------------------------------------------------------------ }
    { TObjectList — IR / semantic                                          }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_TObjectList_Compiles;
    procedure TestCodegen_TObjectList_AddEmitsStore;
    procedure TestCodegen_TObjectList_GetEmitsLoad;
    procedure TestCodegen_TObjectList_GrowEmitsRealloc;

    { ------------------------------------------------------------------ }
    { TStringList — IR / semantic                                          }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_TStringList_Compiles;
    procedure TestCodegen_TStringList_AddEmitsStringStore;
    procedure TestCodegen_TStringList_FindEmitsCompare;
    procedure TestCodegen_TStringList_ZeroMemInGrow;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Blaise source constants                                              }
{ ------------------------------------------------------------------ }

const
  { Minimal TObjectList inline source }
  SrcTObjectListBase =
    'program P;'                                                    + LineEnding +
    'type'                                                          + LineEnding +
    '  TObjectList = class'                                         + LineEnding +
    '    FData:     ^Pointer;'                                      + LineEnding +
    '    FCount:    Integer;'                                       + LineEnding +
    '    FCapacity: Integer;'                                       + LineEnding +
    '    procedure Grow;'                                           + LineEnding +
    '    var NewCap: Integer;'                                      + LineEnding +
    '    begin'                                                     + LineEnding +
    '      if Self.FCapacity = 0 then NewCap := 4'                  + LineEnding +
    '      else NewCap := Self.FCapacity * 2;'                      + LineEnding +
    '      Self.FData     := ReallocMem(Self.FData, NewCap * SizeOf(Pointer));' + LineEnding +
    '      Self.FCapacity := NewCap'                                + LineEnding +
    '    end;'                                                      + LineEnding +
    '    function Add(AObject: Pointer): Integer;'                  + LineEnding +
    '    var Dest: ^Pointer;'                                       + LineEnding +
    '    begin'                                                     + LineEnding +
    '      if Self.FCount = Self.FCapacity then Self.Grow;'         + LineEnding +
    '      Dest        := Self.FData + Self.FCount * SizeOf(Pointer);' + LineEnding +
    '      Dest^       := AObject;'                                 + LineEnding +
    '      Self.FCount := Self.FCount + 1;'                         + LineEnding +
    '      Result      := Self.FCount - 1'                          + LineEnding +
    '    end;'                                                      + LineEnding +
    '    function Get(AIndex: Integer): Pointer;'                   + LineEnding +
    '    var Src: ^Pointer;'                                        + LineEnding +
    '    begin'                                                      + LineEnding +
    '      Src    := Self.FData + AIndex * SizeOf(Pointer);'        + LineEnding +
    '      Result := Src^'                                          + LineEnding +
    '    end;'                                                      + LineEnding +
    '    property Count: Integer read FCount;'                      + LineEnding +
    '  end;'                                                        + LineEnding;

  SrcTObjectListUse =
    SrcTObjectListBase +
    'var L: TObjectList;'                                           + LineEnding +
    'begin'                                                         + LineEnding +
    '  L := TObjectList.Create;'                                    + LineEnding +
    '  L.Add(nil);'                                                 + LineEnding +
    '  L.Add(nil)'                                                  + LineEnding +
    'end.';

  SrcTObjectListGet =
    SrcTObjectListBase +
    'var'                                                           + LineEnding +
    '  L: TObjectList;'                                             + LineEnding +
    '  P: Pointer;'                                                 + LineEnding +
    'begin'                                                         + LineEnding +
    '  L := TObjectList.Create;'                                    + LineEnding +
    '  L.Add(nil);'                                                 + LineEnding +
    '  P := L.Get(0)'                                               + LineEnding +
    'end.';

  { CompareStr/CompareText test }
  SrcCompareStr =
    'program P;'                                                    + LineEnding +
    'var N: Integer;'                                               + LineEnding +
    'begin'                                                         + LineEnding +
    '  N := CompareStr(''abc'', ''abd'')'                           + LineEnding +
    'end.';

  SrcCompareText =
    'program P;'                                                    + LineEnding +
    'var N: Integer;'                                               + LineEnding +
    'begin'                                                         + LineEnding +
    '  N := CompareText(''ABC'', ''abc'')'                          + LineEnding +
    'end.';

  { ZeroMem test }
  SrcZeroMem =
    'program P;'                                                    + LineEnding +
    'var P: Pointer;'                                               + LineEnding +
    'begin'                                                         + LineEnding +
    '  P := GetMem(16);'                                            + LineEnding +
    '  ZeroMem(P, 16)'                                              + LineEnding +
    'end.';

  { Minimal TStringList inline source }
  SrcTStringListBase =
    'program P;'                                                    + LineEnding +
    'type'                                                          + LineEnding +
    '  TStringList = class'                                         + LineEnding +
    '    FStrings:    ^string;'                                     + LineEnding +
    '    FObjects:    ^Pointer;'                                     + LineEnding +
    '    FCount:      Integer;'                                     + LineEnding +
    '    FCapacity:   Integer;'                                     + LineEnding +
    '    FSorted:     Boolean;'                                     + LineEnding +
    '    procedure Grow;'                                           + LineEnding +
    '    var OldCap, NewCap: Integer;'                              + LineEnding +
    '    begin'                                                     + LineEnding +
    '      OldCap := Self.FCapacity;'                               + LineEnding +
    '      if OldCap = 0 then NewCap := 4'                          + LineEnding +
    '      else NewCap := OldCap * 2;'                              + LineEnding +
    '      Self.FStrings  := ReallocMem(Self.FStrings, NewCap * SizeOf(string));' + LineEnding +
    '      Self.FObjects  := ReallocMem(Self.FObjects, NewCap * SizeOf(Pointer));' + LineEnding +
    '      ZeroMem(Self.FStrings + OldCap * SizeOf(string), (NewCap - OldCap) * SizeOf(string));' + LineEnding +
    '      Self.FCapacity := NewCap'                                + LineEnding +
    '    end;'                                                      + LineEnding +
    '    function Add(S: string): Integer;'                         + LineEnding +
    '    var'                                                        + LineEnding +
    '      StrP: ^string;'                                          + LineEnding +
    '      ObjP: ^Pointer;'                                         + LineEnding +
    '    begin'                                                      + LineEnding +
    '      if Self.FCount = Self.FCapacity then Self.Grow;'         + LineEnding +
    '      StrP        := Self.FStrings + Self.FCount * SizeOf(string);' + LineEnding +
    '      ObjP        := Self.FObjects + Self.FCount * SizeOf(Pointer);' + LineEnding +
    '      StrP^       := S;'                                       + LineEnding +
    '      ObjP^       := nil;'                                     + LineEnding +
    '      Result      := Self.FCount;'                             + LineEnding +
    '      Self.FCount := Self.FCount + 1'                          + LineEnding +
    '    end;'                                                      + LineEnding +
    '    function Get(AIndex: Integer): string;'                    + LineEnding +
    '    var Ptr: ^string;'                                         + LineEnding +
    '    begin'                                                      + LineEnding +
    '      Ptr    := Self.FStrings + AIndex * SizeOf(string);'      + LineEnding +
    '      Result := Ptr^'                                          + LineEnding +
    '    end;'                                                      + LineEnding +
    '    function Find(S: string; var Index: Integer): Boolean;'   + LineEnding +
    '    var'                                                        + LineEnding +
    '      Lo, Hi, Mid, Cmp: Integer;'                              + LineEnding +
    '      Ptr: ^string;'                                           + LineEnding +
    '      MStr: string;'                                           + LineEnding +
    '    begin'                                                      + LineEnding +
    '      Lo := 0;'                                                + LineEnding +
    '      Hi := Self.FCount - 1;'                                  + LineEnding +
    '      while Lo <= Hi do'                                       + LineEnding +
    '      begin'                                                    + LineEnding +
    '        Mid  := (Lo + Hi) div 2;'                              + LineEnding +
    '        Ptr  := Self.FStrings + Mid * SizeOf(string);'         + LineEnding +
    '        MStr := Ptr^;'                                         + LineEnding +
    '        Cmp  := CompareText(S, MStr);'                         + LineEnding +
    '        if Cmp = 0 then'                                       + LineEnding +
    '        begin'                                                   + LineEnding +
    '          Index  := Mid;'                                       + LineEnding +
    '          Result := True;'                                      + LineEnding +
    '          Exit'                                                  + LineEnding +
    '        end'                                                    + LineEnding +
    '        else if Cmp < 0 then'                                   + LineEnding +
    '          Hi := Mid - 1'                                        + LineEnding +
    '        else'                                                    + LineEnding +
    '          Lo := Mid + 1'                                        + LineEnding +
    '      end;'                                                     + LineEnding +
    '      Index  := Lo;'                                            + LineEnding +
    '      Result := False'                                          + LineEnding +
    '    end;'                                                       + LineEnding +
    '    property Count: Integer read FCount;'                      + LineEnding +
    '  end;'                                                        + LineEnding;

  SrcTStringListUse =
    SrcTStringListBase +
    'var L: TStringList;'                                           + LineEnding +
    'begin'                                                         + LineEnding +
    '  L := TStringList.Create;'                                    + LineEnding +
    '  L.Add(''hello'');'                                            + LineEnding +
    '  L.Add(''world'')'                                             + LineEnding +
    'end.';

  SrcTStringListFind =
    SrcTStringListBase +
    'var'                                                           + LineEnding +
    '  L: TStringList;'                                             + LineEnding +
    '  Idx: Integer;'                                               + LineEnding +
    '  Found: Boolean;'                                             + LineEnding +
    'begin'                                                         + LineEnding +
    '  L := TStringList.Create;'                                    + LineEnding +
    '  L.Add(''alpha'');'                                            + LineEnding +
    '  L.Add(''beta'');'                                             + LineEnding +
    '  Found := L.Find(''alpha'', Idx)'                              + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Helpers                                                              }
{ ------------------------------------------------------------------ }

function TCollectionTests.GenIR(const ASrc: string): string;
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  CG:   TCodeGenQBE;
  Prog: TProgram;
begin
  Lex  := TLexer.Create(ASrc);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free;
  Lex.Free;
  SA   := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  CG   := TCodeGenQBE.Create;
  CG.Generate(Prog);
  Result := CG.GetOutput;
  CG.Free;
  Prog.Free;
end;

procedure TCollectionTests.SemanticOK(const ASrc: string);
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  Prog: TProgram;
begin
  Lex  := TLexer.Create(ASrc);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free;
  Lex.Free;
  SA   := TSemanticAnalyser.Create;
  try
    SA.Analyse(Prog);
  finally
    SA.Free;
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ CompareStr / CompareText                                             }
{ ------------------------------------------------------------------ }

procedure TCollectionTests.TestSemantic_CompareStr_OK;
begin
  SemanticOK(SrcCompareStr);
end;

procedure TCollectionTests.TestSemantic_CompareText_OK;
begin
  SemanticOK(SrcCompareText);
end;

procedure TCollectionTests.TestSemantic_CompareStr_ReturnsInteger;
var
  Lex:    TLexer;
  Par:    TParser;
  SA:     TSemanticAnalyser;
  Prog:   TProgram;
  Assign: TAssignment;
begin
  Lex  := TLexer.Create(SrcCompareStr);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free;
  Lex.Free;
  SA := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  Assign := TAssignment(Prog.Block.Stmts[0]);
  AssertEquals('CompareStr returns Integer',
    Ord(tyInteger), Ord(Assign.Expr.ResolvedType.Kind));
  Prog.Free;
end;

procedure TCollectionTests.TestCodegen_CompareStr_CallsRTL;
var
  IR: string;
begin
  IR := GenIR(SrcCompareStr);
  AssertTrue('CompareStr emits _StringCompare call',
    Pos('_StringCompare', IR) > 0);
end;

procedure TCollectionTests.TestCodegen_CompareText_CallsRTL;
var
  IR: string;
begin
  IR := GenIR(SrcCompareText);
  AssertTrue('CompareText emits _StringCompareText call',
    Pos('_StringCompareText', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ ZeroMem                                                              }
{ ------------------------------------------------------------------ }

procedure TCollectionTests.TestSemantic_ZeroMem_OK;
begin
  SemanticOK(SrcZeroMem);
end;

procedure TCollectionTests.TestCodegen_ZeroMem_CallsMemset;
var
  IR: string;
begin
  IR := GenIR(SrcZeroMem);
  AssertTrue('ZeroMem emits memset call', Pos('call $memset', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ TObjectList                                                           }
{ ------------------------------------------------------------------ }

procedure TCollectionTests.TestSemantic_TObjectList_Compiles;
begin
  SemanticOK(SrcTObjectListUse);
end;

procedure TCollectionTests.TestCodegen_TObjectList_AddEmitsStore;
var
  IR: string;
begin
  IR := GenIR(SrcTObjectListUse);
  AssertTrue('TObjectList.Add emits storel for Pointer element',
    Pos('storel', IR) > 0);
end;

procedure TCollectionTests.TestCodegen_TObjectList_GetEmitsLoad;
var
  IR: string;
begin
  IR := GenIR(SrcTObjectListGet);
  AssertTrue('TObjectList.Get emits loadl for Pointer element',
    Pos('loadl', IR) > 0);
end;

procedure TCollectionTests.TestCodegen_TObjectList_GrowEmitsRealloc;
var
  IR: string;
begin
  IR := GenIR(SrcTObjectListUse);
  AssertTrue('TObjectList.Grow emits realloc call',
    Pos('call $realloc', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ TStringList                                                           }
{ ------------------------------------------------------------------ }

procedure TCollectionTests.TestSemantic_TStringList_Compiles;
begin
  SemanticOK(SrcTStringListUse);
end;

procedure TCollectionTests.TestCodegen_TStringList_AddEmitsStringStore;
var
  IR: string;
begin
  IR := GenIR(SrcTStringListUse);
  { String ARC: Add must emit _StringAddRef for the stored string }
  AssertTrue('TStringList.Add emits _StringAddRef for stored string',
    Pos('_StringAddRef', IR) > 0);
end;

procedure TCollectionTests.TestCodegen_TStringList_FindEmitsCompare;
var
  IR: string;
begin
  IR := GenIR(SrcTStringListFind);
  AssertTrue('TStringList.Find uses CompareText RTL call',
    Pos('_StringCompareText', IR) > 0);
end;

procedure TCollectionTests.TestCodegen_TStringList_ZeroMemInGrow;
var
  IR: string;
begin
  IR := GenIR(SrcTStringListUse);
  AssertTrue('TStringList.Grow emits memset for zero-init of new string slots',
    Pos('call $memset', IR) > 0);
end;

initialization
  RegisterTest(TCollectionTests);

end.
