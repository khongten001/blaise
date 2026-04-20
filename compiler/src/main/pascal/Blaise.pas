program Blaise;

{$mode objfpc}{$H+}

{ Blaise Compiler — main entry point.

  Usage:
    cleanpascal --source Hello.pas --output hello
    cleanpascal --source Hello.pas --emit-ir
    cleanpascal --source Hello.pas --output hello --target linux-x86_64

  The compiler generates QBE IR, then shells out to qbe + cc to produce
  the final binary. With --emit-ir, the IR is written to stdout and no
  binary is produced.
}

uses
  SysUtils, Classes, Process,
  uLexer, uParser, uCodeGenQBE;

const
  Version = '0.1.0-alpha';
  CompilerName = 'Blaise';

procedure PrintUsage;
begin
  WriteLn('Blaise Compiler v', Version);
  WriteLn('');
  WriteLn('Usage:');
  WriteLn('  cleanpascal --source <file.pas> --output <binary>');
  WriteLn('  cleanpascal --source <file.pas> --emit-ir');
  WriteLn('');
  WriteLn('Flags:');
  WriteLn('  --source <path>     Pascal source file');
  WriteLn('  --output <path>     Output binary path');
  WriteLn('  --target <id>       linux-x86_64 (default), macos-arm64');
  WriteLn('  --emit-ir           Print QBE IR to stdout and exit');
end;

function ParseArgs(
  out SourceFile: string;
  out OutputFile: string;
  out EmitIR:     Boolean): Boolean;
var
  I: Integer;
  Arg: string;
begin
  Result     := False;
  SourceFile := '';
  OutputFile := '';
  EmitIR     := False;

  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if (Arg = '--source') and (I < ParamCount) then
    begin
      Inc(I);
      SourceFile := ParamStr(I);
    end
    else if (Arg = '--output') and (I < ParamCount) then
    begin
      Inc(I);
      OutputFile := ParamStr(I);
    end
    else if Arg = '--emit-ir' then
      EmitIR := True
    else if Arg = '--target' then
      Inc(I)  { consume next arg — target is not used in Phase 1 }
    else if (Arg = '--help') or (Arg = '-h') then
    begin
      PrintUsage;
      Halt(0);
    end
    else
    begin
      WriteLn(StdErr, 'Unknown flag: ', Arg);
      Exit;
    end;
    Inc(I);
  end;

  if SourceFile = '' then
  begin
    WriteLn(StdErr, 'Error: --source is required');
    Exit;
  end;
  if (not EmitIR) and (OutputFile = '') then
  begin
    WriteLn(StdErr, 'Error: --output is required (or use --emit-ir)');
    Exit;
  end;

  Result := True;
end;

function RunProcess(const AExe: string; const AArgs: array of string;
  out AOutput: string): Integer;
var
  Proc:  TProcess;
  Lines: TStringList;
  I:     Integer;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    for I := Low(AArgs) to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Options := [poWaitOnExit, poUsePipes];
    Proc.Execute;
    Lines := TStringList.Create;
    try
      Lines.LoadFromStream(Proc.Stderr);
      AOutput := Lines.Text;
    finally
      Lines.Free;
    end;
    Result := Proc.ExitCode;
  finally
    Proc.Free;
  end;
end;

procedure CompileToNative(const AIRFile, AOutputFile: string);
var
  AsmFile:    string;
  Msg:        string;
  ExitCode:   Integer;
begin
  AsmFile := ChangeFileExt(AIRFile, '.s');

  ExitCode := RunProcess('qbe', ['-o', AsmFile, AIRFile], Msg);
  if ExitCode <> 0 then
  begin
    WriteLn(StdErr, 'qbe error (exit ', ExitCode, '):');
    Write(StdErr, Msg);
    Halt(1);
  end;

  ExitCode := RunProcess('cc', ['-o', AOutputFile, AsmFile], Msg);
  if ExitCode <> 0 then
  begin
    WriteLn(StdErr, 'cc error (exit ', ExitCode, '):');
    Write(StdErr, Msg);
    Halt(1);
  end;

  DeleteFile(AsmFile);
end;

var
  SourceFile, OutputFile: string;
  EmitIR: Boolean;
  Source: TStringList;
  Lexer:  TLexer;
  Parser: TParser;
  Prog:   TProgram;
  CG:     TCodeGenQBE;
  IR:     string;
  IRFile: string;

begin
  if not ParseArgs(SourceFile, OutputFile, EmitIR) then
  begin
    PrintUsage;
    Halt(1);
  end;

  if not FileExists(SourceFile) then
  begin
    WriteLn(StdErr, 'Error: source file not found: ', SourceFile);
    Halt(1);
  end;

  Source := TStringList.Create;
  try
    Source.LoadFromFile(SourceFile);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'Error reading source: ', E.Message);
      Halt(1);
    end;
  end;

  Lexer  := nil;
  Parser := nil;
  Prog   := nil;
  CG     := nil;
  try
    try
      Lexer  := TLexer.Create(Source.Text);
      Parser := TParser.Create(Lexer);
      Prog   := Parser.Parse;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'Parse error: ', E.Message);
        Halt(1);
      end;
    end;

    try
      CG := TCodeGenQBE.Create;
      CG.Generate(Prog);
      IR := CG.GetOutput;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'Code generation error: ', E.Message);
        Halt(1);
      end;
    end;
  finally
    CG.Free;
    Prog.Free;
    Parser.Free;
    Lexer.Free;
    Source.Free;
  end;

  if EmitIR then
  begin
    Write(IR);
    Halt(0);
  end;

  IRFile := ChangeFileExt(OutputFile, '.ssa');
  try
    Source := TStringList.Create;
    try
      Source.Text := IR;
      Source.SaveToFile(IRFile);
    finally
      Source.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'Error writing IR: ', E.Message);
      Halt(1);
    end;
  end;

  CompileToNative(IRFile, OutputFile);
  DeleteFile(IRFile);
end.
