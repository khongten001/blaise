{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.process;

{$mode objfpc}{$H+}

{ Tests for the process management built-ins:
    ProcessCreate, ProcessSetExe, ProcessAddArg, ProcessExecute,
    ProcessRunning, ProcessReadOutput, ProcessWaitOnExit,
    ProcessExitCode, ProcessFree.

  These are low-level C-backed built-ins used by Process.pas's TProcess
  class to fork/exec subprocesses. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TProcessBuiltinTests = class(TTestCase)
  private
    function  GenIR(const ASrc: string): string;
    procedure SemanticOK(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { Semantic: function built-ins return correct types                   }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_ProcessCreate_ReturnsPointer;
    procedure TestSemantic_ProcessRunning_ReturnsBoolean;
    procedure TestSemantic_ProcessReadOutput_ReturnsString;
    procedure TestSemantic_ProcessExitCode_ReturnsInteger;

    { ------------------------------------------------------------------ }
    { Semantic: procedure built-ins compile without error                 }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_ProcessSetExe_OK;
    procedure TestSemantic_ProcessAddArg_OK;
    procedure TestSemantic_ProcessExecute_OK;
    procedure TestSemantic_ProcessWaitOnExit_OK;
    procedure TestSemantic_ProcessFree_OK;

    { ------------------------------------------------------------------ }
    { Codegen: built-ins emit the correct RTL call                        }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_ProcessCreate_CallsRTL;
    procedure TestCodegen_ProcessRunning_CallsRTL;
    procedure TestCodegen_ProcessReadOutput_CallsRTL;
    procedure TestCodegen_ProcessExitCode_CallsRTL;
    procedure TestCodegen_ProcessSetExe_CallsRTL;
    procedure TestCodegen_ProcessAddArg_CallsRTL;
    procedure TestCodegen_ProcessExecute_CallsRTL;
    procedure TestCodegen_ProcessWaitOnExit_CallsRTL;
    procedure TestCodegen_ProcessFree_CallsRTL;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Source snippets                                                      }
{ ------------------------------------------------------------------ }

const
  SrcProcessCreate =
    'program P;'                    + LineEnding +
    'var H: Pointer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  H := ProcessCreate'          + LineEnding +
    'end.';

  SrcProcessRunning =
    'program P;'                    + LineEnding +
    'var H: Pointer;'               + LineEnding +
    '    B: Boolean;'               + LineEnding +
    'begin'                         + LineEnding +
    '  H := ProcessCreate;'         + LineEnding +
    '  B := ProcessRunning(H)'      + LineEnding +
    'end.';

  SrcProcessReadOutput =
    'program P;'                    + LineEnding +
    'var H: Pointer;'               + LineEnding +
    '    S: string;'                + LineEnding +
    'begin'                         + LineEnding +
    '  H := ProcessCreate;'         + LineEnding +
    '  S := ProcessReadOutput(H)'   + LineEnding +
    'end.';

  SrcProcessExitCode =
    'program P;'                    + LineEnding +
    'var H: Pointer;'               + LineEnding +
    '    N: Integer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  H := ProcessCreate;'         + LineEnding +
    '  N := ProcessExitCode(H)'     + LineEnding +
    'end.';

  SrcProcessSetExe =
    'program P;'                    + LineEnding +
    'var H: Pointer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  H := ProcessCreate;'         + LineEnding +
    '  ProcessSetExe(H, ''echo'')'  + LineEnding +
    'end.';

  SrcProcessAddArg =
    'program P;'                      + LineEnding +
    'var H: Pointer;'                 + LineEnding +
    'begin'                           + LineEnding +
    '  H := ProcessCreate;'           + LineEnding +
    '  ProcessAddArg(H, ''hello'')'   + LineEnding +
    'end.';

  SrcProcessExecute =
    'program P;'                    + LineEnding +
    'var H: Pointer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  H := ProcessCreate;'         + LineEnding +
    '  ProcessSetExe(H, ''echo'');'  + LineEnding +
    '  ProcessExecute(H)'           + LineEnding +
    'end.';

  SrcProcessWaitOnExit =
    'program P;'                    + LineEnding +
    'var H: Pointer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  H := ProcessCreate;'         + LineEnding +
    '  ProcessSetExe(H, ''echo'');'  + LineEnding +
    '  ProcessExecute(H);'          + LineEnding +
    '  ProcessWaitOnExit(H)'        + LineEnding +
    'end.';

  SrcProcessFree =
    'program P;'                    + LineEnding +
    'var H: Pointer;'               + LineEnding +
    'begin'                         + LineEnding +
    '  H := ProcessCreate;'         + LineEnding +
    '  ProcessFree(H)'              + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Helpers                                                              }
{ ------------------------------------------------------------------ }

function TProcessBuiltinTests.GenIR(const ASrc: string): string;
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

procedure TProcessBuiltinTests.SemanticOK(const ASrc: string);
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
  SA := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  Prog.Free;
  AssertTrue('Semantic analysis succeeded', True);
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                       }
{ ------------------------------------------------------------------ }

procedure TProcessBuiltinTests.TestSemantic_ProcessCreate_ReturnsPointer;
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  Prog: TProgram;
  Ass:  TAssignment;
begin
  Lex  := TLexer.Create(SrcProcessCreate);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free;
  Lex.Free;
  SA   := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  Ass := TAssignment(Prog.Block.Stmts[0]);
  AssertEquals('ProcessCreate returns Pointer',
    Ord(tyPointer), Ord(Ass.Expr.ResolvedType.Kind));
  Prog.Free;
end;

procedure TProcessBuiltinTests.TestSemantic_ProcessRunning_ReturnsBoolean;
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  Prog: TProgram;
  Ass:  TAssignment;
begin
  Lex  := TLexer.Create(SrcProcessRunning);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free;
  Lex.Free;
  SA   := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  Ass := TAssignment(Prog.Block.Stmts[1]);
  AssertEquals('ProcessRunning returns Boolean',
    Ord(tyBoolean), Ord(Ass.Expr.ResolvedType.Kind));
  Prog.Free;
end;

procedure TProcessBuiltinTests.TestSemantic_ProcessReadOutput_ReturnsString;
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  Prog: TProgram;
  Ass:  TAssignment;
begin
  Lex  := TLexer.Create(SrcProcessReadOutput);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free;
  Lex.Free;
  SA   := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  Ass := TAssignment(Prog.Block.Stmts[1]);
  AssertEquals('ProcessReadOutput returns string',
    Ord(tyString), Ord(Ass.Expr.ResolvedType.Kind));
  Prog.Free;
end;

procedure TProcessBuiltinTests.TestSemantic_ProcessExitCode_ReturnsInteger;
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  Prog: TProgram;
  Ass:  TAssignment;
begin
  Lex  := TLexer.Create(SrcProcessExitCode);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse;
  Par.Free;
  Lex.Free;
  SA   := TSemanticAnalyser.Create;
  SA.Analyse(Prog);
  SA.Free;
  Ass := TAssignment(Prog.Block.Stmts[1]);
  AssertEquals('ProcessExitCode returns Integer',
    Ord(tyInteger), Ord(Ass.Expr.ResolvedType.Kind));
  Prog.Free;
end;

procedure TProcessBuiltinTests.TestSemantic_ProcessSetExe_OK;
begin
  SemanticOK(SrcProcessSetExe);
end;

procedure TProcessBuiltinTests.TestSemantic_ProcessAddArg_OK;
begin
  SemanticOK(SrcProcessAddArg);
end;

procedure TProcessBuiltinTests.TestSemantic_ProcessExecute_OK;
begin
  SemanticOK(SrcProcessExecute);
end;

procedure TProcessBuiltinTests.TestSemantic_ProcessWaitOnExit_OK;
begin
  SemanticOK(SrcProcessWaitOnExit);
end;

procedure TProcessBuiltinTests.TestSemantic_ProcessFree_OK;
begin
  SemanticOK(SrcProcessFree);
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                        }
{ ------------------------------------------------------------------ }

procedure TProcessBuiltinTests.TestCodegen_ProcessCreate_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessCreate);
  AssertTrue('ProcessCreate calls $_ProcessCreate', Pos('_ProcessCreate', IR) > 0);
end;

procedure TProcessBuiltinTests.TestCodegen_ProcessRunning_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessRunning);
  AssertTrue('ProcessRunning calls $_ProcessRunning', Pos('_ProcessRunning', IR) > 0);
end;

procedure TProcessBuiltinTests.TestCodegen_ProcessReadOutput_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessReadOutput);
  AssertTrue('ProcessReadOutput calls $_ProcessReadOutput', Pos('_ProcessReadOutput', IR) > 0);
end;

procedure TProcessBuiltinTests.TestCodegen_ProcessExitCode_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessExitCode);
  AssertTrue('ProcessExitCode calls $_ProcessExitCode', Pos('_ProcessExitCode', IR) > 0);
end;

procedure TProcessBuiltinTests.TestCodegen_ProcessSetExe_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessSetExe);
  AssertTrue('ProcessSetExe calls $_ProcessSetExe', Pos('_ProcessSetExe', IR) > 0);
end;

procedure TProcessBuiltinTests.TestCodegen_ProcessAddArg_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessAddArg);
  AssertTrue('ProcessAddArg calls $_ProcessAddArg', Pos('_ProcessAddArg', IR) > 0);
end;

procedure TProcessBuiltinTests.TestCodegen_ProcessExecute_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessExecute);
  AssertTrue('ProcessExecute calls $_ProcessExecute', Pos('_ProcessExecute', IR) > 0);
end;

procedure TProcessBuiltinTests.TestCodegen_ProcessWaitOnExit_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessWaitOnExit);
  AssertTrue('ProcessWaitOnExit calls $_ProcessWaitOnExit', Pos('_ProcessWaitOnExit', IR) > 0);
end;

procedure TProcessBuiltinTests.TestCodegen_ProcessFree_CallsRTL;
var IR: string;
begin
  IR := GenIR(SrcProcessFree);
  AssertTrue('ProcessFree calls $_ProcessFree', Pos('_ProcessFree', IR) > 0);
end;

initialization
  RegisterTest(TProcessBuiltinTests);

end.
