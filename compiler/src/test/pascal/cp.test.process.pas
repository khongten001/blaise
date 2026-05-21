{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.process;

{ Tests for the process management built-ins:
    ProcessCreate, ProcessSetExe, ProcessAddArg, ProcessExecute,
    ProcessRunning, ProcessReadOutput, ProcessWaitOnExit,
    ProcessExitCode, ProcessFree.

  These are low-level C-backed built-ins used by Process.pas's TProcess
  class to fork/exec subprocesses. }

interface

uses
  Classes, SysUtils, blaise.testing,
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
    '''
        program P;
        var H: Pointer;
        begin
          H := ProcessCreate
        end.
        ''';

  SrcProcessRunning =
    '''
        program P;
        var H: Pointer;
            B: Boolean;
        begin
          H := ProcessCreate;
          B := ProcessRunning(H)
        end.
        ''';

  SrcProcessReadOutput =
    '''
        program P;
        var H: Pointer;
            S: string;
        begin
          H := ProcessCreate;
          S := ProcessReadOutput(H)
        end.
        ''';

  SrcProcessExitCode =
    '''
        program P;
        var H: Pointer;
            N: Integer;
        begin
          H := ProcessCreate;
          N := ProcessExitCode(H)
        end.
        ''';

  SrcProcessSetExe =
    '''
        program P;
        var H: Pointer;
        begin
          H := ProcessCreate;
          ProcessSetExe(H, 'echo')
        end.
        ''';

  SrcProcessAddArg =
    '''
        program P;
        var H: Pointer;
        begin
          H := ProcessCreate;
          ProcessAddArg(H, 'hello')
        end.
        ''';

  SrcProcessExecute =
    '''
        program P;
        var H: Pointer;
        begin
          H := ProcessCreate;
          ProcessSetExe(H, 'echo');
          ProcessExecute(H)
        end.
        ''';

  SrcProcessWaitOnExit =
    '''
        program P;
        var H: Pointer;
        begin
          H := ProcessCreate;
          ProcessSetExe(H, 'echo');
          ProcessExecute(H);
          ProcessWaitOnExit(H)
        end.
        ''';

  SrcProcessFree =
    '''
        program P;
        var H: Pointer;
        begin
          H := ProcessCreate;
          ProcessFree(H)
        end.
        ''';

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
