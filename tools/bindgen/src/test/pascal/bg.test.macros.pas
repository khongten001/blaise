{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit bg.test.macros;

{ Tests for Bindgen.Macros — the macro-constants pass.

  #define constants never reach the AST, so they are harvested in two
  steps, each covered here against real clang fixtures:

    1. ParseDefines on 'clang -E -dD' output: object-like macros only,
       with linemarker-based file attribution for --match filtering.
    2. A probe file of '(long long)(NAME)' consts is AST-dumped and
       each initialiser's expression tree is constant-folded by
       EvalExprNode (clang does not pre-evaluate in C mode).  Macros
       that are not integer constants (type aliases, function
       references) simply fail to fold and are skipped.

  String-literal macros are taken directly from the define body. }

interface

uses
  blaise.testing, classes, strutils,
  Bindgen.Model, Bindgen.Macros, Bindgen.Emit;

type
  TMacroTests = class(TTestCase)
  private
    FMacros: TList<TCMacro>;
    function LoadText(const APath: string): string;
    function FindMacro(const AName: string): TCMacro;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestParse_ObjectLikeMacro_Collected;
    procedure TestParse_FunctionLikeMacro_Skipped;
    procedure TestParse_UnderscorePrefixed_Skipped;
    procedure TestParse_FileFilter_ExcludesDepHeader;
    procedure TestParse_StringMacro_ValueCaptured;
    procedure TestHarvest_PlainInt;
    procedure TestHarvest_ShiftExpression;
    procedure TestHarvest_NegativeAndComplement;
    procedure TestHarvest_MacroReferencingMacros;
    procedure TestHarvest_TypeMacro_NoValue;
    procedure TestEmit_MacroConsts_InOutput;
    procedure TestEmit_UnevaluatedMacro_NotEmitted;
  end;

implementation

function FixtureDir: string;
begin
  Result := 'src/test/fixtures/';
  if not FileExists(Result + 'sample.defines') then
    Result := '../src/test/fixtures/';
  if not FileExists(Result + 'sample.defines') then
    Result := 'tools/bindgen/src/test/fixtures/';
end;

function TMacroTests.LoadText(const APath: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create();
  Lines.LoadFromFile(APath);
  Result := Lines.Text;
end;

function TMacroTests.FindMacro(const AName: string): TCMacro;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FMacros.Count - 1 do
    if FMacros[I].Name = AName then
    begin
      Result := FMacros[I];
      Exit;
    end;
end;

procedure TMacroTests.SetUp;
var
  Dir: string;
begin
  Dir := FixtureDir();
  FMacros := ParseDefines(Self.LoadText(Dir + 'sample.defines'), 'sample.h');
  HarvestProbeValues(Self.LoadText(Dir + 'sample_probe.json'), FMacros);
end;

procedure TMacroTests.TearDown;
begin
  FMacros := nil;
end;

procedure TMacroTests.TestParse_ObjectLikeMacro_Collected;
begin
  AssertTrue('SAMPLE_A collected', Self.FindMacro('SAMPLE_A') <> nil);
  AssertTrue('SAMPLE_MASK collected', Self.FindMacro('SAMPLE_MASK') <> nil);
end;

procedure TMacroTests.TestParse_FunctionLikeMacro_Skipped;
begin
  AssertTrue(Self.FindMacro('SAMPLE_FN') = nil);
end;

procedure TMacroTests.TestParse_UnderscorePrefixed_Skipped;
begin
  { Compiler-internal names (__STDC__ etc.) are noise. }
  AssertTrue(Self.FindMacro('__STDC__') = nil);
end;

procedure TMacroTests.TestParse_FileFilter_ExcludesDepHeader;
begin
  AssertTrue(Self.FindMacro('DEP_HIDDEN') = nil);
end;

procedure TMacroTests.TestParse_StringMacro_ValueCaptured;
var
  M: TCMacro;
begin
  M := Self.FindMacro('SAMPLE_STR');
  AssertTrue('collected', M <> nil);
  AssertTrue('is string', M.IsString);
  AssertEquals('hello', M.StrValue);
end;

procedure TMacroTests.TestHarvest_PlainInt;
var
  M: TCMacro;
begin
  M := Self.FindMacro('SAMPLE_A');
  AssertTrue('has value', M.HasValue);
  AssertEquals(2, Integer(M.Value));
end;

procedure TMacroTests.TestHarvest_ShiftExpression;
var
  M: TCMacro;
begin
  M := Self.FindMacro('SAMPLE_MASK');
  AssertTrue('has value', M.HasValue);
  AssertEquals(32768, Integer(M.Value));
end;

procedure TMacroTests.TestHarvest_NegativeAndComplement;
var
  M: TCMacro;
begin
  M := Self.FindMacro('SAMPLE_NEG');
  AssertTrue('neg has value', M.HasValue);
  AssertEquals(-5, Integer(M.Value));
  M := Self.FindMacro('SAMPLE_ALL');
  AssertTrue('all has value', M.HasValue);
  AssertEquals('~0L folds to -1', Int64(-1), M.Value);
end;

procedure TMacroTests.TestHarvest_MacroReferencingMacros;
var
  M: TCMacro;
begin
  M := Self.FindMacro('SAMPLE_COMBO');
  AssertTrue('has value', M.HasValue);
  AssertEquals(32770, Integer(M.Value));
end;

procedure TMacroTests.TestHarvest_TypeMacro_NoValue;
var
  M: TCMacro;
begin
  { '#define SAMPLE_TYPE int' cannot fold — it must be collected but
    carry no value, and must not abort the harvest of the others. }
  M := Self.FindMacro('SAMPLE_TYPE');
  AssertTrue('collected', M <> nil);
  AssertTrue('no value', not M.HasValue);
end;

procedure TMacroTests.TestEmit_MacroConsts_InOutput;
var
  Model: TCModel;
  Src: string;
begin
  Model := TCModel.Create();
  Src := EmitBinding(Model, 'sample', 'sample', FMacros);
  AssertTrue('int macro', ContainsStr(Src, 'SAMPLE_A = 2;'));
  AssertTrue('shift macro', ContainsStr(Src, 'SAMPLE_MASK = 32768;'));
  AssertTrue('combo macro', ContainsStr(Src, 'SAMPLE_COMBO = 32770;'));
  AssertTrue('string macro', ContainsStr(Src, 'SAMPLE_STR = ''hello'';'));
end;

procedure TMacroTests.TestEmit_UnevaluatedMacro_NotEmitted;
var
  Model: TCModel;
  Src: string;
begin
  Model := TCModel.Create();
  Src := EmitBinding(Model, 'sample', 'sample', FMacros);
  AssertTrue('type macro absent', not ContainsStr(Src, 'SAMPLE_TYPE'));
end;

initialization
  RegisterTest(TMacroTests);

end.
