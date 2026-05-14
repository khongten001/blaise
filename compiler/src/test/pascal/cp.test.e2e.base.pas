{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.base;

{ Shared base class for all E2E test suites.
  Provides toolchain setup, scratch directory management, and two
  CompileAndRun variants:
    - CompileAndRun        : single-program, no RTL units (inline classes)
    - CompileAndRunWithRTL : multi-unit, loads RTL units via TUnitLoader }

interface

uses
  classes, sysutils, process, contnrs, bcl.testing,
  uLexer, uParser, uAST, uSemantic, uCodeGenQBE, uUnitLoader;

type
  TE2ETestCase = class(TTestCase)
  private
    FQBE:         string;
    FRTL:         string;
    FRTLUnitPath: string;
    FScratch:     string;
    FCounter:     Integer;
    function  ProjectRoot: string;
    function  RunProc(const AExe: string; const AArgs: array of string;
                      out AStdout: string): Integer;
    function  RunProcNoArgs(const AExe: string; out AStdout: string): Integer;
  protected
    function  ToolchainAvailable: Boolean;
    function  ValgrindAvailable: Boolean;
    procedure SetUpScratch(const ADirName: string);
    procedure SetUp; override;
    function  CompileAndRun(const ASrc: string;
                            out AStdout: string;
                            out AExitCode: Integer): Boolean; overload;
    function  CompileAndRun(const ASrc: string;
                            out AStdout: string;
                            out AExitCode: Integer;
                            const AExtraArgs: array of string): Boolean; overload;
    function  RunUnderValgrind(const ASrc: string; out ALog: string): Boolean;
    function  CompileAndRunWithRTL(const ASrc: string;
                                   out AStdout: string;
                                   out AExitCode: Integer): Boolean;
  end;

implementation

{ ------------------------------------------------------------------ }
{ TE2ETestCase                                                         }
{ ------------------------------------------------------------------ }

function TE2ETestCase.ProjectRoot: string;
var
  Dir, Parent: string;
  Steps: Integer;
begin
  Result := GetEnvironmentVariable('BLAISE_PROJECT_ROOT');
  if Result <> '' then begin Result := IncludeTrailingPathDelimiter(Result); Exit end;
  Dir := GetCurrentDir;
  for Steps := 0 to 5 do
  begin
    if DirectoryExists(IncludeTrailingPathDelimiter(Dir) + 'vendor/qbe') and
       DirectoryExists(IncludeTrailingPathDelimiter(Dir) + 'rtl') then
    begin
      Result := IncludeTrailingPathDelimiter(Dir);
      Exit
    end;
    Parent := ExtractFileDir(Dir);
    if (Parent = '') or (Parent = Dir) then Break;
    Dir := Parent
  end;
  Result := IncludeTrailingPathDelimiter(GetCurrentDir)
end;

function TE2ETestCase.ToolchainAvailable: Boolean;
begin
  Result := FileExists(FQBE) and FileExists(FRTL)
end;

function TE2ETestCase.ValgrindAvailable: Boolean;
var Dummy: string;
begin
  Result := RunProc('valgrind', ['--version'], Dummy) = 0
end;

procedure TE2ETestCase.SetUp;
begin
  { Subclasses must call SetUpScratch to set FScratch and FCounter }
  inherited SetUp;
  FCounter := 0;
  FQBE := GetEnvironmentVariable('BLAISE_QBE');
  if FQBE = '' then
    FQBE := ProjectRoot + 'vendor/qbe/qbe';
  FRTL := GetEnvironmentVariable('BLAISE_RTL');
  if FRTL = '' then
    FRTL := ProjectRoot + 'rtl/target/blaise_rtl.a';
  FRTLUnitPath := ProjectRoot + 'rtl/src/main/pascal'
end;

procedure TE2ETestCase.SetUpScratch(const ADirName: string);
begin
  FScratch := ProjectRoot + ADirName;
  ForceDirectories(FScratch);
  FCounter := 0
end;

function TE2ETestCase.RunProc(const AExe: string;
                              const AArgs: array of string;
                              out AStdout: string): Integer;
var
  Proc:  TProcess;
  I:     Integer;
  Chunk: string;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    for I := 0 to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Execute;
    AStdout := '';
    repeat
      Chunk := Proc.ReadOutput;
      AStdout := AStdout + Chunk
    until (Chunk = '') and not Proc.Running;
    Proc.WaitOnExit;
    Result := Proc.ExitCode
  finally
    Proc.Free
  end
end;

function TE2ETestCase.RunProcNoArgs(const AExe: string;
                                    out AStdout: string): Integer;
var
  Proc:  TProcess;
  Chunk: string;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    Proc.Execute;
    AStdout := '';
    repeat
      Chunk := Proc.ReadOutput;
      AStdout := AStdout + Chunk
    until (Chunk = '') and not Proc.Running;
    Proc.WaitOnExit;
    Result := Proc.ExitCode
  finally
    Proc.Free
  end
end;

function TE2ETestCase.CompileAndRun(const ASrc: string;
                                    out AStdout: string;
                                    out AExitCode: Integer): Boolean;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  CG:       TCodeGenQBE;
  IR:       string;
  IRFile:   string;
  AsmFile:  string;
  BinFile:  string;
  ToolOut:  string;
  Rc:       Integer;
begin
  Result := False;
  Inc(FCounter);
  IRFile  := FScratch + '/t' + IntToStr(FCounter) + '.ssa';
  AsmFile := FScratch + '/t' + IntToStr(FCounter) + '.s';
  BinFile := FScratch + '/t' + IntToStr(FCounter);

  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil; CG := nil;
  try
    Lexer    := TLexer.Create(ASrc);
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    CG       := TCodeGenQBE.Create;
    CG.Generate(Prog);
    IR       := CG.GetOutput
  finally
    CG.Free; Semantic.Free; Prog.Free; Parser.Free; Lexer.Free
  end;

  WriteFile(IRFile, IR);
  Rc := RunProc(FQBE, ['-o', AsmFile, IRFile], ToolOut);
  if Rc <> 0 then begin AStdout := 'qbe failed: ' + ToolOut; AExitCode := Rc; Exit end;
  Rc := RunProc('cc', ['-o', BinFile, AsmFile, FRTL, '-lm'], ToolOut);
  if Rc <> 0 then begin AStdout := 'cc failed: ' + ToolOut; AExitCode := Rc; Exit end;
  AExitCode := RunProcNoArgs(BinFile, AStdout);
  Result := True
end;

function TE2ETestCase.CompileAndRun(const ASrc: string;
                                    out AStdout: string;
                                    out AExitCode: Integer;
                                    const AExtraArgs: array of string): Boolean;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  CG:       TCodeGenQBE;
  IR:       string;
  IRFile:   string;
  AsmFile:  string;
  BinFile:  string;
  ToolOut:  string;
  Rc:       Integer;
begin
  Result := False;
  Inc(FCounter);
  IRFile  := FScratch + '/t' + IntToStr(FCounter) + '.ssa';
  AsmFile := FScratch + '/t' + IntToStr(FCounter) + '.s';
  BinFile := FScratch + '/t' + IntToStr(FCounter);

  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil; CG := nil;
  try
    Lexer    := TLexer.Create(ASrc);
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    CG       := TCodeGenQBE.Create;
    CG.Generate(Prog);
    IR       := CG.GetOutput
  finally
    CG.Free; Semantic.Free; Prog.Free; Parser.Free; Lexer.Free
  end;

  WriteFile(IRFile, IR);
  Rc := RunProc(FQBE, ['-o', AsmFile, IRFile], ToolOut);
  if Rc <> 0 then begin AStdout := 'qbe failed: ' + ToolOut; AExitCode := Rc; Exit end;
  Rc := RunProc('cc', ['-o', BinFile, AsmFile, FRTL, '-lm'], ToolOut);
  if Rc <> 0 then begin AStdout := 'cc failed: ' + ToolOut; AExitCode := Rc; Exit end;
  AExitCode := RunProc(BinFile, AExtraArgs, AStdout);
  Result := True
end;

function TE2ETestCase.RunUnderValgrind(const ASrc: string; out ALog: string): Boolean;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  CG:       TCodeGenQBE;
  IR:       string;
  IRFile:   string;
  AsmFile:  string;
  BinFile:  string;
  ToolOut:  string;
  Rc:       Integer;
begin
  Result := False;
  ALog   := '';
  Inc(FCounter);
  IRFile  := FScratch + '/vg' + IntToStr(FCounter) + '.ssa';
  AsmFile := FScratch + '/vg' + IntToStr(FCounter) + '.s';
  BinFile := FScratch + '/vg' + IntToStr(FCounter);

  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil; CG := nil;
  try
    Lexer    := TLexer.Create(ASrc);
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    Semantic.Analyse(Prog);
    CG       := TCodeGenQBE.Create;
    CG.Generate(Prog);
    IR       := CG.GetOutput
  finally
    CG.Free; Semantic.Free; Prog.Free; Parser.Free; Lexer.Free
  end;

  WriteFile(IRFile, IR);
  Rc := RunProc(FQBE, ['-o', AsmFile, IRFile], ToolOut);
  if Rc <> 0 then Exit;
  Rc := RunProc('cc', ['-o', BinFile, AsmFile, FRTL, '-lm'], ToolOut);
  if Rc <> 0 then Exit;

  Rc := RunProc('valgrind',
    ['--error-exitcode=99', '--leak-check=full', '--quiet', BinFile], ALog);
  Result := Rc = 0
end;

function TE2ETestCase.CompileAndRunWithRTL(const ASrc: string;
                                           out AStdout: string;
                                           out AExitCode: Integer): Boolean;
var
  Lexer:       TLexer;
  Parser:      TParser;
  Prog:        TProgram;
  Semantic:    TSemanticAnalyser;
  CG:          TCodeGenQBE;
  Loader:      TUnitLoader;
  Units:       TObjectList;
  SearchPaths: TStringList;
  IR:          string;
  IRFile:      string;
  AsmFile:     string;
  BinFile:     string;
  ToolOut:     string;
  Rc:          Integer;
  I:           Integer;
begin
  Result := False;
  Inc(FCounter);
  IRFile  := FScratch + '/t' + IntToStr(FCounter) + '.ssa';
  AsmFile := FScratch + '/t' + IntToStr(FCounter) + '.s';
  BinFile := FScratch + '/t' + IntToStr(FCounter);

  Lexer := nil; Parser := nil; Prog := nil; Semantic := nil; CG := nil;
  Loader := nil; Units := nil; SearchPaths := nil;
  try
    Lexer    := TLexer.Create(ASrc);
    Parser   := TParser.Create(Lexer);
    Prog     := Parser.Parse;
    Semantic := TSemanticAnalyser.Create;
    SearchPaths := TStringList.Create;
    SearchPaths.Add(FRTLUnitPath);
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
    IR := CG.GetOutput
  finally
    CG.Free; Semantic.Free;
    Units.Free; Loader.Free; SearchPaths.Free;
    Prog.Free; Parser.Free; Lexer.Free
  end;

  WriteFile(IRFile, IR);
  Rc := RunProc(FQBE, ['-o', AsmFile, IRFile], ToolOut);
  if Rc <> 0 then begin AStdout := 'qbe failed: ' + ToolOut; AExitCode := Rc; Exit end;
  Rc := RunProc('cc', ['-o', BinFile, AsmFile, FRTL, '-lm'], ToolOut);
  if Rc <> 0 then begin AStdout := 'cc failed: ' + ToolOut; AExitCode := Rc; Exit end;
  AExitCode := RunProcNoArgs(BinFile, AStdout);
  Result := True
end;

end.
