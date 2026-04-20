unit cp.test.varparams;

{$mode objfpc}{$H+}

{ Tests for var parameters: pass-by-reference semantics across
  lexer, parser, semantic analysis, and code generation. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TVarParamTests = class(TTestCase)
  private
    function  ParseSrc(const ASrc: string): TProgram;
    function  AnalyseSrc(const ASrc: string): TProgram;
    function  GenIR(const ASrc: string): string;
    procedure AnalyseExpectError(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_VarParam_IsVarParam;
    procedure TestParse_VarParam_MultiInGroup;
    procedure TestParse_VarParam_Mixed_VarAndValue;
    procedure TestParse_VarParam_ValueParam_IsNotVar;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_VarParam_OK;
    procedure TestSemantic_VarParam_NonVariable_RaisesError;
    procedure TestSemantic_VarParam_TypeMismatch_RaisesError;

    { ------------------------------------------------------------------ }
    { Codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_VarParam_SignatureUsesPointerType;
    procedure TestCodegen_VarParam_CallPassesAddress;
    procedure TestCodegen_VarParam_WriteStoresThroughPointer;
    procedure TestCodegen_VarParam_ReadDereferencesPointer;
    procedure TestCodegen_VarParam_Swap;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TVarParamTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Result := P.Parse;
  finally
    P.Free; L.Free;
  end;
end;

function TVarParamTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try
    A.Analyse(Result);
  finally
    A.Free;
  end;
end;

function TVarParamTests.GenIR(const ASrc: string): string;
var P: TProgram; CG: TCodeGenQBE;
begin
  P := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create;
    try
      CG.Generate(P);
      Result := CG.GetOutput;
    finally
      CG.Free;
    end;
  finally
    P.Free;
  end;
end;

procedure TVarParamTests.AnalyseExpectError(const ASrc: string);
var P: TProgram;
begin
  try
    P := AnalyseSrc(ASrc);
    P.Free;
    Fail('Expected ESemanticError');
  except
    on E: ESemanticError do ;
  end;
end;

{ ------------------------------------------------------------------ }
{ Shared source snippets                                               }
{ ------------------------------------------------------------------ }

const
  SrcVarSet =
    'program VarTest;'                              + LineEnding +
    'procedure SetVal(var X: Integer);'             + LineEnding +
    'begin'                                         + LineEnding +
    '  X := 42'                                     + LineEnding +
    'end;'                                          + LineEnding +
    'var V: Integer;'                               + LineEnding +
    'begin'                                         + LineEnding +
    '  V := 0;'                                     + LineEnding +
    '  SetVal(V)'                                   + LineEnding +
    'end.';

  SrcVarSwap =
    'program SwapTest;'                             + LineEnding +
    'procedure Swap(var A, B: Integer);'            + LineEnding +
    'var T: Integer;'                               + LineEnding +
    'begin'                                         + LineEnding +
    '  T := A;'                                     + LineEnding +
    '  A := B;'                                     + LineEnding +
    '  B := T'                                      + LineEnding +
    'end;'                                          + LineEnding +
    'var X, Y: Integer;'                            + LineEnding +
    'begin'                                         + LineEnding +
    '  X := 1;'                                     + LineEnding +
    '  Y := 2;'                                     + LineEnding +
    '  Swap(X, Y)'                                  + LineEnding +
    'end.';

  SrcMixed =
    'program MixedTest;'                            + LineEnding +
    'procedure P(var A: Integer; B: Integer);'      + LineEnding +
    'begin'                                         + LineEnding +
    '  A := B'                                      + LineEnding +
    'end;'                                          + LineEnding +
    'var X: Integer;'                               + LineEnding +
    'begin'                                         + LineEnding +
    '  P(X, 5)'                                     + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TVarParamTests.TestParse_VarParam_IsVarParam;
var P: TProgram; MD: TMethodDecl; Par: TMethodParam;
begin
  P := ParseSrc(SrcVarSet);
  try
    MD  := TMethodDecl(P.Block.ProcDecls[0]);  { SetVal }
    Par := TMethodParam(MD.Params[0]);         { var X }
    AssertTrue('X is var param', Par.IsVarParam);
  finally P.Free; end;
end;

procedure TVarParamTests.TestParse_VarParam_MultiInGroup;
var P: TProgram; MD: TMethodDecl;
begin
  P := ParseSrc(SrcVarSwap);
  try
    MD := TMethodDecl(P.Block.ProcDecls[0]);  { Swap }
    AssertTrue('A is var param', TMethodParam(MD.Params[0]).IsVarParam);
    AssertTrue('B is var param', TMethodParam(MD.Params[1]).IsVarParam);
  finally P.Free; end;
end;

procedure TVarParamTests.TestParse_VarParam_Mixed_VarAndValue;
var P: TProgram; MD: TMethodDecl;
begin
  P := ParseSrc(SrcMixed);
  try
    MD := TMethodDecl(P.Block.ProcDecls[0]);  { P(var A; B) }
    AssertTrue('A is var param',    TMethodParam(MD.Params[0]).IsVarParam);
    AssertFalse('B is value param', TMethodParam(MD.Params[1]).IsVarParam);
  finally P.Free; end;
end;

procedure TVarParamTests.TestParse_VarParam_ValueParam_IsNotVar;
var P: TProgram; MD: TMethodDecl;
begin
  P := ParseSrc(
    'program T;'                                    + LineEnding +
    'procedure Q(X: Integer);'                      + LineEnding +
    'begin end;'                                    + LineEnding +
    'begin end.');
  try
    MD := TMethodDecl(P.Block.ProcDecls[0]);
    AssertFalse('X is not var param', TMethodParam(MD.Params[0]).IsVarParam);
  finally P.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                       }
{ ------------------------------------------------------------------ }

procedure TVarParamTests.TestSemantic_VarParam_OK;
begin
  AnalyseSrc(SrcVarSet).Free;
end;

procedure TVarParamTests.TestSemantic_VarParam_NonVariable_RaisesError;
begin
  AnalyseExpectError(
    'program Bad;'                                  + LineEnding +
    'procedure Inc(var X: Integer);'                + LineEnding +
    'begin X := X + 1 end;'                        + LineEnding +
    'begin'                                         + LineEnding +
    '  Inc(42)'                                     + LineEnding +  { literal, not a variable }
    'end.');
end;

procedure TVarParamTests.TestSemantic_VarParam_TypeMismatch_RaisesError;
begin
  AnalyseExpectError(
    'program Bad;'                                  + LineEnding +
    'procedure SetI(var X: Integer);'               + LineEnding +
    'begin X := 1 end;'                             + LineEnding +
    'var B: Boolean;'                               + LineEnding +
    'begin'                                         + LineEnding +
    '  SetI(B)'                                     + LineEnding +  { wrong type }
    'end.');
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                        }
{ ------------------------------------------------------------------ }

procedure TVarParamTests.TestCodegen_VarParam_SignatureUsesPointerType;
var IR: string;
begin
  IR := GenIR(SrcVarSet);
  { var X: Integer → pointer param, QBE type l }
  AssertTrue('var param uses l type', Pos('l %_par_X', IR) > 0);
end;

procedure TVarParamTests.TestCodegen_VarParam_CallPassesAddress;
var IR: string;
begin
  IR := GenIR(SrcVarSet);
  { SetVal(V) must pass the address of V, not its loaded value }
  AssertTrue('call passes address of V', Pos('call $SetVal(l %_var_V)', IR) > 0);
end;

procedure TVarParamTests.TestCodegen_VarParam_WriteStoresThroughPointer;
var IR: string;
begin
  IR := GenIR(SrcVarSet);
  { X := 42 inside SetVal must load the pointer then store through it }
  AssertTrue('loads pointer for write', Pos('loadl %_var_X', IR) > 0);
  AssertTrue('storew used for Integer write', Pos('storew', IR) > 0);
end;

procedure TVarParamTests.TestCodegen_VarParam_ReadDereferencesPointer;
var IR: string;
begin
  IR := GenIR(SrcVarSwap);
  { T := A inside Swap must load the pointer then load through it }
  AssertTrue('loads pointer for read', Pos('loadl %_var_A', IR) > 0);
end;

procedure TVarParamTests.TestCodegen_VarParam_Swap;
var IR: string;
begin
  IR := GenIR(SrcVarSwap);
  { Both X and Y addresses passed to Swap }
  AssertTrue('passes address of X', Pos('l %_var_X', IR) > 0);
  AssertTrue('passes address of Y', Pos('l %_var_Y', IR) > 0);
end;

initialization
  RegisterTest(TVarParamTests);

end.
