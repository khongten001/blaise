{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.math;

{$mode objfpc}{$H+}

{ IR-level tests for Math unit functions and math compiler builtins.

  Builtins (handled in uSemantic + uCodeGenQBE, no RTL unit needed):
    Abs, Sqrt, Ceil, Floor, Round, Trunc, Ln, Log2, Log10, Power,
    Sin, Cos, Tan, ArcTan, ArcTan2, IsNaN, IsInfinite.

  RTL unit (math.pas, resolved via TUnitLoader):
    Min, Max, Sign, DivMod, InRange, EnsureRange, Pi. }

interface

uses
  SysUtils, Classes, contnrs, blaise.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE, uUnitLoader;

type
  TMathTests = class(TTestCase)
  private
    FRTLUnitPath: string;
    FStdlibUnitPath: string;
    function  GenIR(const ASrc: string): string;
    function  GenIRBuiltin(const ASrc: string): string;
    function  IRContains(const AIR, AFragment: string): Boolean;
    procedure SemanticOK(const ASrc: string);
    procedure SemanticOKBuiltin(const ASrc: string);
    procedure SemanticError(const ASrc: string);
  protected
    procedure SetUp; override;
  published
    { --- Compiler builtins: semantic type checking --- }

    { Sqrt }
    procedure TestSemantic_Sqrt_Double_OK;
    procedure TestSemantic_Sqrt_Single_OK;
    procedure TestSemantic_Sqrt_ReturnsDouble;
    procedure TestSemantic_Sqrt_RejectInteger;

    { Ceil / Floor / Round / Trunc → Integer }
    procedure TestSemantic_Ceil_OK;
    procedure TestSemantic_Ceil_ReturnsInteger;
    procedure TestSemantic_Floor_OK;
    procedure TestSemantic_Floor_ReturnsInteger;
    procedure TestSemantic_Round_OK;
    procedure TestSemantic_Round_ReturnsInteger;
    procedure TestSemantic_Trunc_OK;
    procedure TestSemantic_Trunc_ReturnsInteger;
    procedure TestSemantic_Ceil_RejectInteger;

    { Ln / Log2 / Log10 → Double }
    procedure TestSemantic_Ln_OK;
    procedure TestSemantic_Ln_ReturnsDouble;
    procedure TestSemantic_Log2_OK;
    procedure TestSemantic_Log10_OK;

    { Power → Double }
    procedure TestSemantic_Power_OK;
    procedure TestSemantic_Power_ReturnsDouble;

    { Trig — Sin / Cos / Tan / ArcTan / ArcTan2 }
    procedure TestSemantic_Sin_OK;
    procedure TestSemantic_Cos_OK;
    procedure TestSemantic_Tan_OK;
    procedure TestSemantic_ArcTan_OK;
    procedure TestSemantic_ArcTan2_OK;
    procedure TestSemantic_Sin_ReturnsDouble;
    procedure TestSemantic_Sin_Single_ReturnsSingle;

    { IsNaN / IsInfinite → Boolean }
    procedure TestSemantic_IsNaN_OK;
    procedure TestSemantic_IsNaN_ReturnsBoolean;
    procedure TestSemantic_IsInfinite_OK;
    procedure TestSemantic_IsInfinite_ReturnsBoolean;

    { Codegen — builtins emit correct IR }
    procedure TestCodegen_Sqrt_EmitsSqrt;
    procedure TestCodegen_Trunc_EmitsDtosi;
    procedure TestCodegen_Ceil_EmitsCeilAndDtosi;
    procedure TestCodegen_Floor_EmitsFloorAndDtosi;
    procedure TestCodegen_Round_EmitsRoundAndDtosi;
    procedure TestCodegen_Ln_EmitsLog;
    procedure TestCodegen_Log2_EmitsLog2;
    procedure TestCodegen_Log10_EmitsLog10;
    procedure TestCodegen_Power_EmitsPow;
    procedure TestCodegen_Sin_EmitsSin;
    procedure TestCodegen_Cos_EmitsCos;
    procedure TestCodegen_Tan_EmitsTan;
    procedure TestCodegen_ArcTan_EmitsAtan;
    procedure TestCodegen_ArcTan2_EmitsAtan2;
    procedure TestCodegen_IsNaN_EmitsIsnan;
    procedure TestCodegen_IsInfinite_EmitsIsinf;

    { --- RTL unit: Math.pas --- }

    { Min / Max }
    procedure TestSemantic_Min_Integer_OK;
    procedure TestSemantic_Max_Integer_OK;
    procedure TestSemantic_Min_Double_OK;
    procedure TestSemantic_Max_Double_OK;
    procedure TestSemantic_Min_ReturnsInteger;
    procedure TestSemantic_Max_ReturnsDouble;

    { Sign }
    procedure TestSemantic_Sign_Integer_OK;
    procedure TestSemantic_Sign_Double_OK;
    procedure TestSemantic_Sign_ReturnsInteger;

    { DivMod }
    procedure TestSemantic_DivMod_OK;

    { InRange }
    procedure TestSemantic_InRange_Integer_OK;
    procedure TestSemantic_InRange_Double_OK;
    procedure TestSemantic_InRange_ReturnsBoolean;

    { EnsureRange }
    procedure TestSemantic_EnsureRange_Integer_OK;
    procedure TestSemantic_EnsureRange_Double_OK;
    procedure TestSemantic_EnsureRange_Integer_ReturnsInteger;

    { Pi constant }
    procedure TestSemantic_Pi_UsableInExpr;

    { Codegen — RTL functions appear in IR }
    procedure TestCodegen_Min_InIR;
    procedure TestCodegen_Max_InIR;
    procedure TestCodegen_Sign_InIR;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                              }
{ ------------------------------------------------------------------ }

procedure TMathTests.SetUp;
var
  ExeDir: string;
begin
  inherited SetUp;
  ExeDir := ExtractFilePath(ParamStr(0));
  FRTLUnitPath := ExpandFileName(ExeDir + '../../runtime/src/main/pascal');
  FStdlibUnitPath := ExpandFileName(ExeDir + '../../stdlib/src/main/pascal');
end;

{ Compile with RTL unit loader (for Math.pas functions). }
procedure TMathTests.SemanticOK(const ASrc: string);
var
  Lexer:       TLexer;
  Parser:      TParser;
  Prog:        TProgram;
  Semantic:    TSemanticAnalyser;
  Loader:      TUnitLoader;
  Units:       TObjectList;
  SearchPaths: TStringList;
  I:           Integer;
begin
  Lexer  := nil; Parser := nil; Prog := nil; Semantic := nil;
  Loader := nil; Units  := nil; SearchPaths := nil;
  try
    Lexer       := TLexer.Create(ASrc);
    Parser      := TParser.Create(Lexer);
    Prog        := Parser.Parse;
    Semantic    := TSemanticAnalyser.Create;
    SearchPaths := TStringList.Create;
    SearchPaths.Add(FRTLUnitPath);
    SearchPaths.Add(FStdlibUnitPath);
    Loader := TUnitLoader.Create(SearchPaths);
    Units  := Loader.LoadAll(Prog.UsedUnits);
    for I := 0 to Units.Count - 1 do
      Semantic.AnalyseUnitForExport(TUnit(Units.Items[I]));
    Semantic.Analyse(Prog);
  finally
    Semantic.Free;
    Units.Free; Loader.Free; SearchPaths.Free;
    Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ Compile without RTL unit loader (for compiler builtins that need no unit). }
procedure TMathTests.SemanticOKBuiltin(const ASrc: string);
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create(ASrc);
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.SemanticError(const ASrc: string);
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    try
      Lexer    := TLexer.Create(ASrc);
      Parser   := TParser.Create(Lexer);
      Prog     := Parser.Parse;
      Semantic := TSemanticAnalyser.Create;
      Semantic.Analyse(Prog);
      Fail('Expected ESemanticError but none was raised');
    except
      on E: ESemanticError do ;
    end;
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ Generate IR with RTL unit loader. }
function TMathTests.GenIR(const ASrc: string): string;
var
  Lexer:       TLexer;
  Parser:      TParser;
  Prog:        TProgram;
  Semantic:    TSemanticAnalyser;
  CG:          TCodeGenQBE;
  Loader:      TUnitLoader;
  Units:       TObjectList;
  SearchPaths: TStringList;
  I:           Integer;
begin
  Lexer  := nil; Parser := nil; Prog := nil; Semantic := nil; CG := nil;
  Loader := nil; Units  := nil; SearchPaths := nil;
  try
    Lexer       := TLexer.Create(ASrc);
    Parser      := TParser.Create(Lexer);
    Prog        := Parser.Parse;
    Semantic    := TSemanticAnalyser.Create;
    SearchPaths := TStringList.Create;
    SearchPaths.Add(FRTLUnitPath);
    SearchPaths.Add(FStdlibUnitPath);
    Loader := TUnitLoader.Create(SearchPaths);
    Units  := Loader.LoadAll(Prog.UsedUnits);
    for I := 0 to Units.Count - 1 do
      Semantic.AnalyseUnitForExport(TUnit(Units.Items[I]));
    Semantic.Analyse(Prog);
    CG := TCodeGenQBE.Create;
    CG.SetSymbolTable(Prog.SymbolTable);
    for I := 0 to Units.Count - 1 do
      CG.AppendUnit(TUnit(Units.Items[I]));
    CG.AppendProgram(Prog);
    Result := CG.GetOutput;
  finally
    CG.Free; Semantic.Free;
    Units.Free; Loader.Free; SearchPaths.Free;
    Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ Generate IR without RTL unit loader (for builtins). }
function TMathTests.GenIRBuiltin(const ASrc: string): string;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  CG:       TCodeGenQBE;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil; CG := nil;
  try
    Lexer    := TLexer.Create(ASrc);
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    CG       := TCodeGenQBE.Create;
    CG.Generate(Prog);
    Result   := CG.GetOutput;
  finally
    CG.Free; Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

function TMathTests.IRContains(const AIR, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AIR) > 0;
end;

{ ------------------------------------------------------------------ }
{ Sqrt                                                                 }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_Sqrt_Double_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Double; begin R := Sqrt(X) end.');
end;

procedure TMathTests.TestSemantic_Sqrt_Single_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Single; begin R := Sqrt(X) end.');
end;

procedure TMathTests.TestSemantic_Sqrt_ReturnsDouble;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X, R: Double; begin R := Sqrt(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Double', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_Sqrt_RejectInteger;
begin
  SemanticError('program P; var X: Integer; R: Double; begin R := Sqrt(X) end.');
end;

{ ------------------------------------------------------------------ }
{ Ceil / Floor / Round / Trunc                                         }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_Ceil_OK;
begin
  SemanticOKBuiltin(
    'program P; var X: Double; R: Integer; begin R := Ceil(X) end.');
end;

procedure TMathTests.TestSemantic_Ceil_ReturnsInteger;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X: Double; R: Integer; begin R := Ceil(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Integer', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_Floor_OK;
begin
  SemanticOKBuiltin(
    'program P; var X: Double; R: Integer; begin R := Floor(X) end.');
end;

procedure TMathTests.TestSemantic_Floor_ReturnsInteger;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X: Double; R: Integer; begin R := Floor(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Integer', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_Round_OK;
begin
  SemanticOKBuiltin(
    'program P; var X: Double; R: Integer; begin R := Round(X) end.');
end;

procedure TMathTests.TestSemantic_Round_ReturnsInteger;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X: Double; R: Integer; begin R := Round(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Integer', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_Trunc_OK;
begin
  SemanticOKBuiltin(
    'program P; var X: Double; R: Integer; begin R := Trunc(X) end.');
end;

procedure TMathTests.TestSemantic_Trunc_ReturnsInteger;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X: Double; R: Integer; begin R := Trunc(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Integer', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_Ceil_RejectInteger;
begin
  SemanticError('program P; var X: Integer; R: Integer; begin R := Ceil(X) end.');
end;

{ ------------------------------------------------------------------ }
{ Ln / Log2 / Log10                                                    }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_Ln_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Double; begin R := Ln(X) end.');
end;

procedure TMathTests.TestSemantic_Ln_ReturnsDouble;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X, R: Double; begin R := Ln(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Double', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_Log2_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Double; begin R := Log2(X) end.');
end;

procedure TMathTests.TestSemantic_Log10_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Double; begin R := Log10(X) end.');
end;

{ ------------------------------------------------------------------ }
{ Power                                                                }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_Power_OK;
begin
  SemanticOKBuiltin(
    'program P; var B, E, R: Double; begin R := Power(B, E) end.');
end;

procedure TMathTests.TestSemantic_Power_ReturnsDouble;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var B, E, R: Double; begin R := Power(B, E) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Double', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Trig                                                                 }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_Sin_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Double; begin R := Sin(X) end.');
end;

procedure TMathTests.TestSemantic_Cos_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Double; begin R := Cos(X) end.');
end;

procedure TMathTests.TestSemantic_Tan_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Double; begin R := Tan(X) end.');
end;

procedure TMathTests.TestSemantic_ArcTan_OK;
begin
  SemanticOKBuiltin(
    'program P; var X, R: Double; begin R := ArcTan(X) end.');
end;

procedure TMathTests.TestSemantic_ArcTan2_OK;
begin
  SemanticOKBuiltin(
    'program P; var Y, X, R: Double; begin R := ArcTan2(Y, X) end.');
end;

procedure TMathTests.TestSemantic_Sin_ReturnsDouble;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X, R: Double; begin R := Sin(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Double', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_Sin_Single_ReturnsSingle;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X, R: Single; begin R := Sin(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Single', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ IsNaN / IsInfinite                                                   }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_IsNaN_OK;
begin
  SemanticOKBuiltin(
    'program P; var X: Double; B: Boolean; begin B := IsNaN(X) end.');
end;

procedure TMathTests.TestSemantic_IsNaN_ReturnsBoolean;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X: Double; B: Boolean; begin B := IsNaN(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Boolean', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_IsInfinite_OK;
begin
  SemanticOKBuiltin(
    'program P; var X: Double; B: Boolean; begin B := IsInfinite(X) end.');
end;

procedure TMathTests.TestSemantic_IsInfinite_ReturnsBoolean;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  Assign:   TAssignment;
begin
  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil;
  try
    Lexer    := TLexer.Create('program P; var X: Double; B: Boolean; begin B := IsInfinite(X) end.');
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Boolean', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free; Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Codegen — builtins                                                   }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestCodegen_Sqrt_EmitsSqrt;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X, R: Double; begin R := Sqrt(X) end.');
  AssertTrue('sqrt in IR', IRContains(IR, '$sqrt'));
end;

procedure TMathTests.TestCodegen_Trunc_EmitsDtosi;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X: Double; R: Integer; begin R := Trunc(X) end.');
  AssertTrue('dtosi in IR', IRContains(IR, 'dtosi'));
end;

procedure TMathTests.TestCodegen_Ceil_EmitsCeilAndDtosi;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X: Double; R: Integer; begin R := Ceil(X) end.');
  AssertTrue('ceil in IR', IRContains(IR, '$ceil'));
  AssertTrue('dtosi in IR', IRContains(IR, 'dtosi'));
end;

procedure TMathTests.TestCodegen_Floor_EmitsFloorAndDtosi;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X: Double; R: Integer; begin R := Floor(X) end.');
  AssertTrue('floor in IR', IRContains(IR, '$floor'));
  AssertTrue('dtosi in IR', IRContains(IR, 'dtosi'));
end;

procedure TMathTests.TestCodegen_Round_EmitsRoundAndDtosi;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X: Double; R: Integer; begin R := Round(X) end.');
  AssertTrue('round in IR', IRContains(IR, '$round'));
  AssertTrue('dtosi in IR', IRContains(IR, 'dtosi'));
end;

procedure TMathTests.TestCodegen_Ln_EmitsLog;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X, R: Double; begin R := Ln(X) end.');
  AssertTrue('log in IR', IRContains(IR, '$log'));
end;

procedure TMathTests.TestCodegen_Log2_EmitsLog2;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X, R: Double; begin R := Log2(X) end.');
  AssertTrue('log2 in IR', IRContains(IR, '$log2'));
end;

procedure TMathTests.TestCodegen_Log10_EmitsLog10;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X, R: Double; begin R := Log10(X) end.');
  AssertTrue('log10 in IR', IRContains(IR, '$log10'));
end;

procedure TMathTests.TestCodegen_Power_EmitsPow;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var B, E, R: Double; begin R := Power(B, E) end.');
  AssertTrue('pow in IR', IRContains(IR, '$pow'));
end;

procedure TMathTests.TestCodegen_Sin_EmitsSin;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X, R: Double; begin R := Sin(X) end.');
  AssertTrue('sin in IR', IRContains(IR, '$sin'));
end;

procedure TMathTests.TestCodegen_Cos_EmitsCos;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X, R: Double; begin R := Cos(X) end.');
  AssertTrue('cos in IR', IRContains(IR, '$cos'));
end;

procedure TMathTests.TestCodegen_Tan_EmitsTan;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X, R: Double; begin R := Tan(X) end.');
  AssertTrue('tan in IR', IRContains(IR, '$tan'));
end;

procedure TMathTests.TestCodegen_ArcTan_EmitsAtan;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X, R: Double; begin R := ArcTan(X) end.');
  AssertTrue('atan in IR', IRContains(IR, '$atan'));
end;

procedure TMathTests.TestCodegen_ArcTan2_EmitsAtan2;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var Y, X, R: Double; begin R := ArcTan2(Y, X) end.');
  AssertTrue('atan2 in IR', IRContains(IR, '$atan2'));
end;

procedure TMathTests.TestCodegen_IsNaN_EmitsIsnan;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X: Double; B: Boolean; begin B := IsNaN(X) end.');
  AssertTrue('__isnan in IR', IRContains(IR, '$__isnan'));
end;

procedure TMathTests.TestCodegen_IsInfinite_EmitsIsinf;
var IR: string;
begin
  IR := GenIRBuiltin(
    'program P; var X: Double; B: Boolean; begin B := IsInfinite(X) end.');
  AssertTrue('__isinf in IR', IRContains(IR, '$__isinf'));
end;

{ ------------------------------------------------------------------ }
{ RTL unit — Min / Max                                                 }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_Min_Integer_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var A, B, R: Integer;
    begin R := Min(A, B) end.
    ''');
end;

procedure TMathTests.TestSemantic_Max_Integer_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var A, B, R: Integer;
    begin R := Max(A, B) end.
    ''');
end;

procedure TMathTests.TestSemantic_Min_Double_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var A, B, R: Double;
    begin R := Min(A, B) end.
    ''');
end;

procedure TMathTests.TestSemantic_Max_Double_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var A, B, R: Double;
    begin R := Max(A, B) end.
    ''');
end;

procedure TMathTests.TestSemantic_Min_ReturnsInteger;
var
  Lexer:       TLexer;
  Parser:      TParser;
  Prog:        TProgram;
  Semantic:    TSemanticAnalyser;
  Loader:      TUnitLoader;
  Units:       TObjectList;
  SearchPaths: TStringList;
  Assign:      TAssignment;
  I:           Integer;
begin
  Lexer  := nil; Parser := nil; Prog := nil; Semantic := nil;
  Loader := nil; Units  := nil; SearchPaths := nil;
  try
    Lexer := TLexer.Create(
      'program P; uses Math; var A, B, R: Integer; begin R := Min(A, B) end.');
    Parser      := TParser.Create(Lexer);
    Prog        := Parser.Parse;
    Semantic    := TSemanticAnalyser.Create;
    SearchPaths := TStringList.Create;
    SearchPaths.Add(FRTLUnitPath);
    SearchPaths.Add(FStdlibUnitPath);
    Loader := TUnitLoader.Create(SearchPaths);
    Units  := Loader.LoadAll(Prog.UsedUnits);
    for I := 0 to Units.Count - 1 do
      Semantic.AnalyseUnitForExport(TUnit(Units.Items[I]));
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Integer', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free;
    Units.Free; Loader.Free; SearchPaths.Free;
    Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

procedure TMathTests.TestSemantic_Max_ReturnsDouble;
var
  Lexer:       TLexer;
  Parser:      TParser;
  Prog:        TProgram;
  Semantic:    TSemanticAnalyser;
  Loader:      TUnitLoader;
  Units:       TObjectList;
  SearchPaths: TStringList;
  Assign:      TAssignment;
  I:           Integer;
begin
  Lexer  := nil; Parser := nil; Prog := nil; Semantic := nil;
  Loader := nil; Units  := nil; SearchPaths := nil;
  try
    Lexer := TLexer.Create(
      'program P; uses Math; var A, B, R: Double; begin R := Max(A, B) end.');
    Parser      := TParser.Create(Lexer);
    Prog        := Parser.Parse;
    Semantic    := TSemanticAnalyser.Create;
    SearchPaths := TStringList.Create;
    SearchPaths.Add(FRTLUnitPath);
    SearchPaths.Add(FStdlibUnitPath);
    Loader := TUnitLoader.Create(SearchPaths);
    Units  := Loader.LoadAll(Prog.UsedUnits);
    for I := 0 to Units.Count - 1 do
      Semantic.AnalyseUnitForExport(TUnit(Units.Items[I]));
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Double', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free;
    Units.Free; Loader.Free; SearchPaths.Free;
    Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ RTL unit — Sign                                                      }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_Sign_Integer_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var X, R: Integer;
    begin R := Sign(X) end.
    ''');
end;

procedure TMathTests.TestSemantic_Sign_Double_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var X: Double; R: Integer;
    begin R := Sign(X) end.
    ''');
end;

procedure TMathTests.TestSemantic_Sign_ReturnsInteger;
var
  Lexer:       TLexer;
  Parser:      TParser;
  Prog:        TProgram;
  Semantic:    TSemanticAnalyser;
  Loader:      TUnitLoader;
  Units:       TObjectList;
  SearchPaths: TStringList;
  Assign:      TAssignment;
  I:           Integer;
begin
  Lexer  := nil; Parser := nil; Prog := nil; Semantic := nil;
  Loader := nil; Units  := nil; SearchPaths := nil;
  try
    Lexer := TLexer.Create(
      'program P; uses Math; var X: Double; R: Integer; begin R := Sign(X) end.');
    Parser      := TParser.Create(Lexer);
    Prog        := Parser.Parse;
    Semantic    := TSemanticAnalyser.Create;
    SearchPaths := TStringList.Create;
    SearchPaths.Add(FRTLUnitPath);
    SearchPaths.Add(FStdlibUnitPath);
    Loader := TUnitLoader.Create(SearchPaths);
    Units  := Loader.LoadAll(Prog.UsedUnits);
    for I := 0 to Units.Count - 1 do
      Semantic.AnalyseUnitForExport(TUnit(Units.Items[I]));
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Integer', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free;
    Units.Free; Loader.Free; SearchPaths.Free;
    Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ RTL unit — DivMod                                                    }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_DivMod_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var D, V, Q, R: Integer;
    begin DivMod(D, V, Q, R) end.
    ''');
end;

{ ------------------------------------------------------------------ }
{ RTL unit — InRange                                                   }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_InRange_Integer_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var V, Lo, Hi: Integer; B: Boolean;
    begin B := InRange(V, Lo, Hi) end.
    ''');
end;

procedure TMathTests.TestSemantic_InRange_Double_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var V, Lo, Hi: Double; B: Boolean;
    begin B := InRange(V, Lo, Hi) end.
    ''');
end;

procedure TMathTests.TestSemantic_InRange_ReturnsBoolean;
var
  Lexer:       TLexer;
  Parser:      TParser;
  Prog:        TProgram;
  Semantic:    TSemanticAnalyser;
  Loader:      TUnitLoader;
  Units:       TObjectList;
  SearchPaths: TStringList;
  Assign:      TAssignment;
  I:           Integer;
begin
  Lexer  := nil; Parser := nil; Prog := nil; Semantic := nil;
  Loader := nil; Units  := nil; SearchPaths := nil;
  try
    Lexer := TLexer.Create(
      'program P; uses Math; var V, Lo, Hi: Integer; B: Boolean; begin B := InRange(V, Lo, Hi) end.');
    Parser      := TParser.Create(Lexer);
    Prog        := Parser.Parse;
    Semantic    := TSemanticAnalyser.Create;
    SearchPaths := TStringList.Create;
    SearchPaths.Add(FRTLUnitPath);
    SearchPaths.Add(FStdlibUnitPath);
    Loader := TUnitLoader.Create(SearchPaths);
    Units  := Loader.LoadAll(Prog.UsedUnits);
    for I := 0 to Units.Count - 1 do
      Semantic.AnalyseUnitForExport(TUnit(Units.Items[I]));
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Boolean', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free;
    Units.Free; Loader.Free; SearchPaths.Free;
    Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ RTL unit — EnsureRange                                               }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_EnsureRange_Integer_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var V, Lo, Hi, R: Integer;
    begin R := EnsureRange(V, Lo, Hi) end.
    ''');
end;

procedure TMathTests.TestSemantic_EnsureRange_Double_OK;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var V, Lo, Hi, R: Double;
    begin R := EnsureRange(V, Lo, Hi) end.
    ''');
end;

procedure TMathTests.TestSemantic_EnsureRange_Integer_ReturnsInteger;
var
  Lexer:       TLexer;
  Parser:      TParser;
  Prog:        TProgram;
  Semantic:    TSemanticAnalyser;
  Loader:      TUnitLoader;
  Units:       TObjectList;
  SearchPaths: TStringList;
  Assign:      TAssignment;
  I:           Integer;
begin
  Lexer  := nil; Parser := nil; Prog := nil; Semantic := nil;
  Loader := nil; Units  := nil; SearchPaths := nil;
  try
    Lexer := TLexer.Create(
      'program P; uses Math; var V, Lo, Hi, R: Integer; begin R := EnsureRange(V, Lo, Hi) end.');
    Parser      := TParser.Create(Lexer);
    Prog        := Parser.Parse;
    Semantic    := TSemanticAnalyser.Create;
    SearchPaths := TStringList.Create;
    SearchPaths.Add(FRTLUnitPath);
    SearchPaths.Add(FStdlibUnitPath);
    Loader := TUnitLoader.Create(SearchPaths);
    Units  := Loader.LoadAll(Prog.UsedUnits);
    for I := 0 to Units.Count - 1 do
      Semantic.AnalyseUnitForExport(TUnit(Units.Items[I]));
    Semantic.Analyse(Prog);
    Assign := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertNotNil('resolved type', Assign.Expr.ResolvedType);
    AssertEquals('return type', 'Integer', Assign.Expr.ResolvedType.Name);
  finally
    Semantic.Free;
    Units.Free; Loader.Free; SearchPaths.Free;
    Prog.Free; Parser.Free; Lexer.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Pi constant                                                          }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestSemantic_Pi_UsableInExpr;
begin
  SemanticOK(
    '''
    program P; uses Math;
    var R: Double;
    begin R := Pi * 2.0 end.
    ''');
end;

{ ------------------------------------------------------------------ }
{ Codegen — RTL functions                                              }
{ ------------------------------------------------------------------ }

procedure TMathTests.TestCodegen_Min_InIR;
var IR: string;
begin
  IR := GenIR(
    '''
    program P; uses Math;
    var A, B, R: Integer;
    begin R := Min(A, B) end.
    ''');
  AssertTrue('Math_Min in IR', IRContains(IR, 'Min'));
end;

procedure TMathTests.TestCodegen_Max_InIR;
var IR: string;
begin
  IR := GenIR(
    '''
    program P; uses Math;
    var A, B, R: Double;
    begin R := Max(A, B) end.
    ''');
  AssertTrue('Math_Max in IR', IRContains(IR, 'Max'));
end;

procedure TMathTests.TestCodegen_Sign_InIR;
var IR: string;
begin
  IR := GenIR(
    '''
    program P; uses Math;
    var X, R: Integer;
    begin R := Sign(X) end.
    ''');
  AssertTrue('Math_Sign in IR', IRContains(IR, 'Sign'));
end;

initialization
  RegisterTest(TMathTests);

end.
