{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.proctypes_ofobject;

{$mode objfpc}{$H+}

{ Tests for Step 11c — 'procedure of object' method-pointer types and the
  TMethod intrinsic record.

  Layout: a method-pointer value is a 16-byte block, Code at offset 0 and
  Data (Self) at offset 8.  This matches TMethod byte-for-byte; the cast
  TMyMethod(m) is a no-op at the QBE level.  A method-pointer call site
  loads both halves and emits 'call code(l data, args...)'. }

interface

uses
  Classes, SysUtils, Process, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TProcTypesOfObjectTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    function CompileAndRun(const ASrc: string): string;
  published
    { Parser }
    procedure TestParse_OfObject_SetsIsMethodPtr;
    procedure TestParse_BareProcType_LeavesIsMethodPtrFalse;
    procedure TestParse_FunctionOfObject_AcceptsReturnType;

    { Semantic / Symbol Table }
    procedure TestSemantic_TMethod_IsRegistered;
    procedure TestSemantic_TMethod_HasCodeAndDataFields;
    procedure TestSemantic_MethodPtr_PropagatesIsMethodPtr;

    { Codegen }
    procedure TestCodegen_MethodPtrLocal_Allocates16Bytes;
    procedure TestCodegen_MethodPtrGlobal_DataIs16Bytes;
    procedure TestCodegen_MethodPtrAssign_CallsMemcpy16;
    procedure TestCodegen_MethodPtrCall_LoadsCodeAndData;

    { End-to-end }
    procedure TestE2E_MethodPtr_NoArgs;
    procedure TestE2E_MethodPtr_WithArgs;
    procedure TestE2E_MethodPtr_PreservesSelf;
  end;

implementation

function TProcTypesOfObjectTests.ParseSrc(const ASrc: string): TProgram;
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

function TProcTypesOfObjectTests.AnalyseSrc(const ASrc: string): TProgram;
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

function TProcTypesOfObjectTests.GenIR(const ASrc: string): string;
var Prog: TProgram; CG: TCodeGenQBE;
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

function TProcTypesOfObjectTests.CompileAndRun(const ASrc: string): string;

  function ProjectRoot: string;
  var
    Dir, Parent: string;
    Steps:       Integer;
  begin
    Result := GetEnvironmentVariable('BLAISE_PROJECT_ROOT');
    if Result <> '' then
    begin
      Result := IncludeTrailingPathDelimiter(Result);
      Exit;
    end;
    Dir := GetCurrentDir;
    for Steps := 0 to 5 do
    begin
      if DirectoryExists(IncludeTrailingPathDelimiter(Dir) + 'vendor/qbe') and
         DirectoryExists(IncludeTrailingPathDelimiter(Dir) + 'rtl') then
      begin
        Result := IncludeTrailingPathDelimiter(Dir);
        Exit;
      end;
      Parent := ExtractFileDir(Dir);
      if (Parent = '') or (Parent = Dir) then Break;
      Dir := Parent;
    end;
    Result := IncludeTrailingPathDelimiter(GetCurrentDir);
  end;

var
  IR:                       string;
  Root:                     string;
  QBE, RTL, Scratch:        string;
  IRFile, AsmFile, BinFile: string;
  Lst:                      TStringList;
  Proc:                     TProcess;
  OutLst:                   TStringList;
begin
  Result := '';
  Root   := ProjectRoot;
  QBE    := Root + 'vendor/qbe/qbe';
  RTL    := Root + 'compiler/target/blaise_rtl.a';
  if not (FileExists(QBE) and FileExists(RTL)) then
  begin
    Result := '<toolchain-missing>';
    Exit;
  end;
  Scratch := Root + 'compiler/target/test-proctypes-ofobject';
  ForceDirectories(Scratch);
  IRFile  := IncludeTrailingPathDelimiter(Scratch) + 'case.ssa';
  AsmFile := IncludeTrailingPathDelimiter(Scratch) + 'case.s';
  BinFile := IncludeTrailingPathDelimiter(Scratch) + 'case.bin';

  IR := GenIR(ASrc);
  Lst := TStringList.Create;
  try
    Lst.Text := IR;
    Lst.SaveToFile(IRFile);
  finally
    Lst.Free;
  end;

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := QBE;
    Proc.Parameters.Add('-o');
    Proc.Parameters.Add(AsmFile);
    Proc.Parameters.Add(IRFile);
    Proc.Options := [poWaitOnExit];
    Proc.Execute;
    if Proc.ExitStatus <> 0 then
    begin
      Result := '<qbe-failed>';
      Exit;
    end;
  finally
    Proc.Free;
  end;

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := 'cc';
    Proc.Parameters.Add('-o');
    Proc.Parameters.Add(BinFile);
    Proc.Parameters.Add(AsmFile);
    Proc.Parameters.Add(RTL);
    Proc.Options := [poWaitOnExit];
    Proc.Execute;
    if Proc.ExitStatus <> 0 then
    begin
      Result := '<link-failed>';
      Exit;
    end;
  finally
    Proc.Free;
  end;

  Proc := TProcess.Create(nil);
  OutLst := TStringList.Create;
  try
    Proc.Executable := BinFile;
    Proc.Options := [poWaitOnExit, poUsePipes];
    Proc.Execute;
    OutLst.LoadFromStream(Proc.Output);
    Result := TrimRight(OutLst.Text);
  finally
    OutLst.Free;
    Proc.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{  Parser                                                              }
{ ------------------------------------------------------------------ }

procedure TProcTypesOfObjectTests.TestParse_OfObject_SetsIsMethodPtr;
const
  Src =
    'program P;'                                + LineEnding +
    'type TM = procedure of object;'            + LineEnding +
    'begin end.';
var
  Prog: TProgram;
  TD:   TTypeDecl;
  Def:  TProceduralTypeDef;
begin
  Prog := ParseSrc(Src);
  try
    TD  := TTypeDecl(Prog.Block.TypeDecls.Items[0]);
    Def := TProceduralTypeDef(TD.Def);
    AssertTrue('IsMethodPtr is True for "of object" type', Def.IsMethodPtr);
  finally
    Prog.Free;
  end;
end;

procedure TProcTypesOfObjectTests.TestParse_BareProcType_LeavesIsMethodPtrFalse;
const
  Src =
    'program P;'                                + LineEnding +
    'type TP = procedure;'                      + LineEnding +
    'begin end.';
var
  Def: TProceduralTypeDef;
begin
  Def := TProceduralTypeDef(TTypeDecl(ParseSrc(Src).Block.TypeDecls.Items[0]).Def);
  AssertFalse('IsMethodPtr is False for bare procedural type', Def.IsMethodPtr);
end;

procedure TProcTypesOfObjectTests.TestParse_FunctionOfObject_AcceptsReturnType;
const
  Src =
    'program P;'                                                   + LineEnding +
    'type TF = function (X: Integer): Integer of object;'          + LineEnding +
    'begin end.';
var
  Def: TProceduralTypeDef;
begin
  Def := TProceduralTypeDef(TTypeDecl(ParseSrc(Src).Block.TypeDecls.Items[0]).Def);
  AssertTrue('IsFunction set',   Def.IsFunction);
  AssertTrue('IsMethodPtr set',  Def.IsMethodPtr);
  AssertEquals('return type',    'Integer', Def.ReturnTypeName);
end;

{ ------------------------------------------------------------------ }
{  Semantic / Symbol Table                                             }
{ ------------------------------------------------------------------ }

procedure TProcTypesOfObjectTests.TestSemantic_TMethod_IsRegistered;
const
  Src =
    'program P;'                                + LineEnding +
    'var M: TMethod;'                           + LineEnding +
    'begin end.';
var
  Prog: TProgram;
  VD:   TVarDecl;
begin
  Prog := AnalyseSrc(Src);
  try
    VD := TVarDecl(Prog.Block.Decls.Items[0]);
    AssertNotNull('TMethod resolves',         VD.ResolvedType);
    AssertEquals('TMethod kind is tyRecord',  Ord(tyRecord), Ord(VD.ResolvedType.Kind));
    AssertEquals('TMethod name',              'TMethod',     VD.ResolvedType.Name);
  finally
    Prog.Free;
  end;
end;

procedure TProcTypesOfObjectTests.TestSemantic_TMethod_HasCodeAndDataFields;
const
  Src =
    'program P;'                                + LineEnding +
    'var M: TMethod;'                           + LineEnding +
    'begin end.';
var
  Prog: TProgram;
  RT:   TRecordTypeDesc;
begin
  Prog := AnalyseSrc(Src);
  try
    RT := TRecordTypeDesc(TVarDecl(Prog.Block.Decls.Items[0]).ResolvedType);
    AssertNotNull('Code field exists', RT.FindField('Code'));
    AssertNotNull('Data field exists', RT.FindField('Data'));
    AssertEquals('Code at offset 0', 0, RT.FindField('Code').Offset);
    AssertEquals('Data at offset 8', 8, RT.FindField('Data').Offset);
  finally
    Prog.Free;
  end;
end;

procedure TProcTypesOfObjectTests.TestSemantic_MethodPtr_PropagatesIsMethodPtr;
const
  Src =
    'program P;'                                + LineEnding +
    'type TM = procedure of object;'            + LineEnding +
    'var G: TM;'                                + LineEnding +
    'begin end.';
var
  Prog:     TProgram;
  ProcDesc: TProceduralTypeDesc;
begin
  Prog := AnalyseSrc(Src);
  try
    ProcDesc := TProceduralTypeDesc(TVarDecl(Prog.Block.Decls.Items[0]).ResolvedType);
    AssertTrue('IsMethodPtr propagated to type descriptor',
      ProcDesc.IsMethodPtr);
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{  Codegen                                                             }
{ ------------------------------------------------------------------ }

procedure TProcTypesOfObjectTests.TestCodegen_MethodPtrLocal_Allocates16Bytes;
const
  Src =
    'program P;'                                + LineEnding +
    'type TM = procedure of object;'            + LineEnding +
    'procedure Q;'                              + LineEnding +
    'var G: TM;'                                + LineEnding +
    'begin end;'                                + LineEnding +
    'begin end.';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('local method-ptr var is alloc8 16',
    Pos('%_var_G =l alloc8 16', IR) > 0);
end;

procedure TProcTypesOfObjectTests.TestCodegen_MethodPtrGlobal_DataIs16Bytes;
const
  Src =
    'program P;'                                + LineEnding +
    'type TM = procedure of object;'            + LineEnding +
    'var G: TM;'                                + LineEnding +
    'begin end.';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('global method-ptr emits 16-byte zero data',
    Pos('export data $G = { z 16 }', IR) > 0);
end;

procedure TProcTypesOfObjectTests.TestCodegen_MethodPtrAssign_CallsMemcpy16;
const
  Src =
    'program P;'                                + LineEnding +
    'type TM = procedure of object;'            + LineEnding +
    'var G: TM; M: TMethod;'                    + LineEnding +
    'begin'                                     + LineEnding +
    '  G := TM(M)'                              + LineEnding +
    'end.';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('method-ptr assignment uses memcpy of 16 bytes',
    Pos('call $memcpy(', IR) > 0);
  AssertTrue('memcpy length is 16',
    Pos(', l 16)', IR) > 0);
end;

procedure TProcTypesOfObjectTests.TestCodegen_MethodPtrCall_LoadsCodeAndData;
const
  Src =
    'program P;'                                + LineEnding +
    'type TM = procedure of object;'            + LineEnding +
    'var G: TM;'                                + LineEnding +
    'begin G end.';
var IR: string;
begin
  IR := GenIR(Src);
  { Method-ptr call must load both Code (slot+0) and Data (slot+8) }
  AssertTrue('call site adds 8 to load Data',
    Pos('=l add $G, 8', IR) > 0);
  AssertTrue('call site loads Code from slot',
    Pos('=l loadl $G', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{  End-to-end                                                          }
{ ------------------------------------------------------------------ }

procedure TProcTypesOfObjectTests.TestE2E_MethodPtr_NoArgs;
const
  Src =
    'program P;'                                + LineEnding +
    'type'                                      + LineEnding +
    '  TFoo = class(TObject)'                   + LineEnding +
    '  published'                               + LineEnding +
    '    procedure SayHi;'                      + LineEnding +
    '  end;'                                    + LineEnding +
    '  TGreet = procedure of object;'           + LineEnding +
    'procedure TFoo.SayHi;'                     + LineEnding +
    'begin WriteLn(''hi'') end;'                + LineEnding +
    'var F: TFoo; M: TMethod; G: TGreet;'       + LineEnding +
    'begin'                                     + LineEnding +
    '  F := TFoo.Create;'                       + LineEnding +
    '  M.Code := MethodAddress(F, ''SayHi'');'  + LineEnding +
    '  M.Data := F;'                            + LineEnding +
    '  G := TGreet(M);'                         + LineEnding +
    '  G;'                                      + LineEnding +
    '  F.Free'                                  + LineEnding +
    'end.';
begin
  AssertEquals('zero-arg method-ptr call invokes the method',
    'hi', CompileAndRun(Src));
end;

procedure TProcTypesOfObjectTests.TestE2E_MethodPtr_WithArgs;
const
  Src =
    'program P;'                                              + LineEnding +
    'type'                                                    + LineEnding +
    '  TFoo = class(TObject)'                                 + LineEnding +
    '  published'                                             + LineEnding +
    '    procedure Show(const S: string; N: Integer);'        + LineEnding +
    '  end;'                                                  + LineEnding +
    '  TShow = procedure (const S: string; N: Integer) of object;' + LineEnding +
    'procedure TFoo.Show(const S: string; N: Integer);'       + LineEnding +
    'begin'                                                   + LineEnding +
    '  WriteLn(S);'                                           + LineEnding +
    '  WriteLn(IntToStr(N))'                                  + LineEnding +
    'end;'                                                    + LineEnding +
    'var F: TFoo; M: TMethod; G: TShow;'                      + LineEnding +
    'begin'                                                   + LineEnding +
    '  F := TFoo.Create;'                                     + LineEnding +
    '  M.Code := MethodAddress(F, ''Show'');'                 + LineEnding +
    '  M.Data := F;'                                          + LineEnding +
    '  G := TShow(M);'                                        + LineEnding +
    '  G(''hello'', 42);'                                     + LineEnding +
    '  F.Free'                                                + LineEnding +
    'end.';
begin
  AssertEquals('args are forwarded after Self',
    'hello' + LineEnding + '42', CompileAndRun(Src));
end;

procedure TProcTypesOfObjectTests.TestE2E_MethodPtr_PreservesSelf;
const
  Src =
    'program P;'                                       + LineEnding +
    'type'                                             + LineEnding +
    '  TCounter = class(TObject)'                      + LineEnding +
    '    Value: Integer;'                              + LineEnding +
    '  published'                                      + LineEnding +
    '    procedure Print;'                             + LineEnding +
    '  end;'                                           + LineEnding +
    '  TPrintMethod = procedure of object;'            + LineEnding +
    'procedure TCounter.Print;'                        + LineEnding +
    'begin WriteLn(IntToStr(Value)) end;'              + LineEnding +
    'var C: TCounter; M: TMethod; G: TPrintMethod;'    + LineEnding +
    'begin'                                            + LineEnding +
    '  C := TCounter.Create;'                          + LineEnding +
    '  C.Value := 99;'                                 + LineEnding +
    '  M.Code := MethodAddress(C, ''Print'');'         + LineEnding +
    '  M.Data := C;'                                   + LineEnding +
    '  G := TPrintMethod(M);'                          + LineEnding +
    '  G;'                                             + LineEnding +
    '  C.Free'                                         + LineEnding +
    'end.';
begin
  AssertEquals('Self is bound through the call: instance state visible',
    '99', CompileAndRun(Src));
end;

initialization
  RegisterTest(TProcTypesOfObjectTests);
end.
