{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.anonmethods;

{ Tests for anonymous methods / closures — Phases 0 and 1 of
  docs/anonymous-methods-design.adoc:

    * Parser: 'reference to procedure/function' type form; anonymous
      procedure/function literals in expression position; [Weak] capture
      list storage.
    * Semantic: reference type resolution (16-byte fat value); literal
      signature checking against the target; Phase-1 capture rejection
      (an enclosing local referenced from a literal body is undeclared in
      the thunk's module-scope analysis).
    * Codegen (QBE): lifted '__closure_<n>' thunk with the hidden env
      first param; 16-byte fat-value materialisation; closure-dispatch
      call shape.
    * E2E: capture-free literals assigned + called; function literals;
      '@Routine' adapter coercion; nil closure assignment. }

interface

uses
  Classes, SysUtils, Process, blaise.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, blaise.codegen.qbe,
  cp.test.rtllink, cp.test.attributes;

type
  TAnonMethodTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    function CompileAndRun(const ASrc: string): string;
  published
    { Parser }
    procedure TestParse_ReferenceToProcedure_TypeDecl;
    procedure TestParse_ReferenceToFunction_ReturnType;
    procedure TestParse_AnonLiteral_InAssignment;
    procedure TestParse_AnonLiteral_WeakCaptureListStored;

    { Semantic }
    procedure TestSemantic_ReferenceType_ResolvesTo16ByteDesc;
    procedure TestSemantic_LiteralSignatureMismatch_Fails;
    procedure TestSemantic_Phase1_CaptureRejected;

    { Codegen }
    procedure TestCodegen_ThunkEmitted;
    procedure TestCodegen_LiteralMaterialisesFatValue;

    { End-to-end }
    procedure TestE2E_CaptureFreeLiteral_AssignAndCall;
    procedure TestE2E_FunctionLiteral_ReturnsValue;
    procedure TestE2E_AdapterFromPlainRoutine;
    procedure TestE2E_NilClosure_Assignable;
  end;

implementation

function TAnonMethodTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Result := P.Parse();
  finally
    P.Free(); L.Free();
  end;
end;

function TAnonMethodTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create();
  try
    A.Analyse(Result);
  finally
    A.Free();
  end;
end;

function TAnonMethodTests.GenIR(const ASrc: string): string;
var
  Prog: TProgram;
  CG:   TCodeGenQBE;
begin
  Prog := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create();
    try
      CG.Generate(Prog);
      Result := CG.GetOutput();
    finally
      CG.Free();
    end;
  finally
    Prog.Free();
  end;
end;

function TAnonMethodTests.CompileAndRun(const ASrc: string): string;
var
  IR:                       string;
  Root:                     string;
  QBE, Scratch:             string;
  IRFile, AsmFile, BinFile: string;
  Lst:                      TStringList;
  Proc:                     TProcess;
  Chunk:                    string;
begin
  Result := '';
  Root   := ProjectRootAttr();
  QBE    := Root + 'vendor/qbe/qbe';
  if not RTLLinkToolchainAvailable(Root) then
  begin
    Result := '<toolchain-missing>';
    Exit;
  end;
  Scratch := Root + 'compiler/target/test-anonmethods';
  ForceDirectories(Scratch);
  IRFile  := IncludeTrailingPathDelimiter(Scratch) + 'case.ssa';
  AsmFile := IncludeTrailingPathDelimiter(Scratch) + 'case.s';
  BinFile := IncludeTrailingPathDelimiter(Scratch) + 'case.bin';

  IR := GenIR(ASrc);
  Lst := TStringList.Create();
  try
    Lst.Text := IR;
    Lst.SaveToFile(IRFile);
  finally
    Lst.Free();
  end;

  if RunCmdAttr(QBE, ['-o', AsmFile, IRFile]) <> 0 then
  begin
    Result := '<qbe-failed>';
    Exit;
  end;
  if LinkProgramWithRTL(Root, AsmFile, BinFile) <> 0 then
  begin
    Result := '<link-failed>';
    Exit;
  end;

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := BinFile;
    Proc.Execute();
    Result := '';
    repeat
      Chunk := Proc.ReadOutput();
      Result := Result + Chunk;
    until (Chunk = '') and not Proc.Running;
    Proc.WaitOnExit();
  finally
    Proc.Free();
  end;
end;

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TAnonMethodTests.TestParse_ReferenceToProcedure_TypeDecl;
const
  Src =
    '''
    program P;
    type
      TProc = reference to procedure(AValue: Integer);
    begin end.
    ''';
var
  Prog: TProgram;
  PD:   TProceduralTypeDef;
begin
  Prog := ParseSrc(Src);
  try
    AssertTrue('def is TProceduralTypeDef',
      TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def is TProceduralTypeDef);
    PD := TProceduralTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertTrue('IsReference set', PD.IsReference);
    AssertFalse('IsMethodPtr not set', PD.IsMethodPtr);
    AssertFalse('is a procedure', PD.IsFunction);
    AssertEquals('one param', 1, PD.Params.Count);
  finally
    Prog.Free();
  end;
end;

procedure TAnonMethodTests.TestParse_ReferenceToFunction_ReturnType;
const
  Src =
    '''
    program P;
    type
      TThunk = reference to function(const A, B: Integer): Integer;
    begin end.
    ''';
var
  Prog: TProgram;
  PD:   TProceduralTypeDef;
begin
  Prog := ParseSrc(Src);
  try
    PD := TProceduralTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertTrue('IsReference set', PD.IsReference);
    AssertTrue('is a function', PD.IsFunction);
    AssertEquals('return type', 'Integer', PD.ReturnTypeName);
    AssertEquals('two params', 2, PD.Params.Count);
  finally
    Prog.Free();
  end;
end;

procedure TAnonMethodTests.TestParse_AnonLiteral_InAssignment;
const
  Src =
    '''
    program P;
    type
      TIntProc = reference to procedure(AValue: Integer);
    var
      V: TIntProc;
    begin
      V := procedure(AValue: Integer)
      begin
        WriteLn(AValue)
      end
    end.
    ''';
var
  Prog: TProgram;
  Asn:  TAssignment;
  AME:  TAnonMethodExpr;
begin
  Prog := ParseSrc(Src);
  try
    Asn := TAssignment(Prog.Block.Stmts.Items[0]);
    AssertTrue('RHS is an anonymous-method literal',
      Asn.Expr is TAnonMethodExpr);
    AME := TAnonMethodExpr(Asn.Expr);
    AssertNotNull('literal decl present', AME.Decl);
    AssertEquals('one declared param', 1, AME.Decl.Params.Count);
    AssertEquals('procedure literal has no return type', '',
      AME.Decl.ReturnTypeName);
    AssertNotNull('body present', AME.Decl.Body);
  finally
    Prog.Free();
  end;
end;

procedure TAnonMethodTests.TestParse_AnonLiteral_WeakCaptureListStored;
const
  Src =
    '''
    program P;
    type
      TProc = reference to procedure;
    var
      V: TProc;
    begin
      V := procedure [Weak A, B]
      begin
      end
    end.
    ''';
var
  Prog: TProgram;
  AME:  TAnonMethodExpr;
begin
  Prog := ParseSrc(Src);
  try
    AME := TAnonMethodExpr(TAssignment(Prog.Block.Stmts.Items[0]).Expr);
    AssertNotNull('weak capture list stored', AME.WeakCaptures);
    AssertEquals('two names', 2, AME.WeakCaptures.Count);
    AssertEquals('first', 'A', AME.WeakCaptures.Strings[0]);
    AssertEquals('second', 'B', AME.WeakCaptures.Strings[1]);
  finally
    Prog.Free();
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                       }
{ ------------------------------------------------------------------ }

procedure TAnonMethodTests.TestSemantic_ReferenceType_ResolvesTo16ByteDesc;
const
  Src =
    '''
    program P;
    type
      TProc = reference to procedure(AValue: Integer);
    var
      V: TProc;
    begin
      V := nil
    end.
    ''';
var
  Prog: TProgram;
  Desc: TTypeDesc;
begin
  Prog := AnalyseSrc(Src);
  try
    Desc := Prog.SymbolTable.FindType('TProc');
    AssertNotNull('TProc resolved', Desc);
    AssertTrue('procedural desc', Desc is TProceduralTypeDesc);
    AssertTrue('IsReference on desc', TProceduralTypeDesc(Desc).IsReference);
    AssertEquals('16-byte fat value', 16, Desc.ByteSize());
  finally
    Prog.Free();
  end;
end;

procedure TAnonMethodTests.TestSemantic_LiteralSignatureMismatch_Fails;
const
  Src =
    '''
    program P;
    type
      TIntProc = reference to procedure(AValue: Integer);
    var
      V: TIntProc;
    begin
      V := procedure(AValue: string)
      begin
      end
    end.
    ''';
var
  Prog: TProgram;
  OK:   Boolean;
begin
  OK := False;
  try
    Prog := AnalyseSrc(Src);
    Prog.Free();
  except
    on E: TObject do OK := True;
  end;
  AssertTrue('literal with mismatched signature is rejected', OK);
end;

procedure TAnonMethodTests.TestSemantic_Phase1_CaptureRejected;
const
  { The literal references the enclosing routine's local 'Outer'.  Phase 1
    lifts the body into module scope, so the reference fails to resolve —
    the documented behaviour until capture promotion (Phase 2) lands. }
  Src =
    '''
    program P;
    type
      TProc = reference to procedure;
    procedure Run;
    var
      Outer: Integer;
      V: TProc;
    begin
      Outer := 1;
      V := procedure
      begin
        WriteLn(Outer)
      end;
      V()
    end;
    begin
      Run()
    end.
    ''';
var
  Prog: TProgram;
  OK:   Boolean;
begin
  OK := False;
  try
    Prog := AnalyseSrc(Src);
    Prog.Free();
  except
    on E: TObject do OK := True;
  end;
  AssertTrue('capturing an enclosing local is rejected in Phase 1', OK);
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                        }
{ ------------------------------------------------------------------ }

procedure TAnonMethodTests.TestCodegen_ThunkEmitted;
const
  Src =
    '''
    program P;
    type
      TIntProc = reference to procedure(AValue: Integer);
    var
      V: TIntProc;
    begin
      V := procedure(AValue: Integer)
      begin
        WriteLn(AValue)
      end;
      V(7)
    end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('lifted thunk $__closure_1 emitted',
    Pos('$__closure_1(', IR) > 0);
end;

procedure TAnonMethodTests.TestCodegen_LiteralMaterialisesFatValue;
const
  Src =
    '''
    program P;
    type
      TProc = reference to procedure;
    var
      V: TProc;
    begin
      V := procedure
      begin
      end
    end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('16-byte fat value allocated', Pos('alloc8 16', IR) > 0);
  AssertTrue('thunk address stored into the Code half',
    Pos('storel $__closure_1', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ End-to-end tests                                                     }
{ ------------------------------------------------------------------ }

procedure TAnonMethodTests.TestE2E_CaptureFreeLiteral_AssignAndCall;
const
  Src =
    '''
    program P;
    type
      TIntProc = reference to procedure(AValue: Integer);
    var
      V: TIntProc;
    begin
      V := procedure(AValue: Integer)
      begin
        WriteLn(AValue * 2)
      end;
      V(21)
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', '42' + #10, Output);
end;

procedure TAnonMethodTests.TestE2E_FunctionLiteral_ReturnsValue;
const
  Src =
    '''
    program P;
    type
      TAdd = reference to function(const A, B: Integer): Integer;
    var
      F: TAdd;
    begin
      F := function(const A, B: Integer): Integer
      begin
        Result := A + B
      end;
      WriteLn(F(19, 23))
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', '42' + #10, Output);
end;

procedure TAnonMethodTests.TestE2E_AdapterFromPlainRoutine;
const
  Src =
    '''
    program P;
    type
      TIntProc = reference to procedure(AValue: Integer);
    procedure Show(AValue: Integer);
    begin
      WriteLn(AValue + 1)
    end;
    var
      V: TIntProc;
    begin
      V := @Show;
      V(41)
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', '42' + #10, Output);
end;

procedure TAnonMethodTests.TestE2E_NilClosure_Assignable;
const
  Src =
    '''
    program P;
    type
      TProc = reference to procedure;
    var
      V: TProc;
    begin
      V := procedure
      begin
        WriteLn('lived')
      end;
      V();
      V := nil;
      WriteLn('done')
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', 'lived' + #10 + 'done' + #10, Output);
end;

initialization
  RegisterTest(TAnonMethodTests);

end.
