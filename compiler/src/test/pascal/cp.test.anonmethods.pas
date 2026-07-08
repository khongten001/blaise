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
    procedure TestSemantic_Phase2_LocalCaptureAccepted;
    procedure TestSemantic_Phase2_VarParamCaptureRejected;
    procedure TestSemantic_Phase3_MethodLiteralCapturesSelf;
    procedure TestSemantic_Phase3_MethodPtrCoercionAccepted;
    procedure TestSemantic_Phase4_BlockVarOutOfScopeAfterBlock;
    procedure TestSemantic_Phase4_BlockVarDuplicateRejected;
    procedure TestSemantic_Phase4_MixedScopeCaptureRejected;
    procedure TestSemantic_Phase5_WeakNonSelfRejected;

    { Codegen }
    procedure TestCodegen_ThunkEmitted;
    procedure TestCodegen_LiteralMaterialisesFatValue;
    procedure TestCodegen_Phase2_EnvAllocAndCleanupEmitted;
    procedure TestCodegen_Phase2_CapturedAccessRedirected;
    procedure TestCodegen_Phase2_ClosureCreationAddRefsEnv;
    procedure TestCodegen_Phase2_FrameExitReleasesEnv;

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

procedure TAnonMethodTests.TestSemantic_Phase2_LocalCaptureAccepted;
const
  { Phase 2: the literal references the enclosing routine's local 'Outer'.
    Capture promotion accepts it and records the captured name on the lifted
    thunk so codegen can redirect through the environment record. }
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
  Prog:  TProgram;
  MD:    TMethodDecl;
  Thunk: TMethodDecl;
  I:     Integer;
begin
  Prog := AnalyseSrc(Src);
  try
    { Find the lifted thunk appended to the module's ProcDecls. }
    Thunk := nil;
    for I := 0 to Prog.Block.ProcDecls.Count - 1 do
    begin
      MD := TMethodDecl(Prog.Block.ProcDecls.Items[I]);
      if MD.Name = '__closure_1' then Thunk := MD;
    end;
    AssertNotNull('lifted thunk registered', Thunk);
    AssertNotNull('thunk records env captures', Thunk.EnvCaptured);
    AssertEquals('one captured name', 1, Thunk.EnvCaptured.Count);
    AssertEquals('captured name', 'Outer', Thunk.EnvCaptured.Strings[0]);
  finally
    Prog.Free();
  end;
end;

procedure TAnonMethodTests.TestSemantic_Phase2_VarParamCaptureRejected;
const
  { Capturing a var/out parameter is rejected in Phase 2: the env would have
    to store the CALLER frame's address, which dangles once the closure
    escapes (design doc, Risks).  A clear diagnostic is required. }
  Src =
    '''
    program P;
    type
      TProc = reference to procedure;
    procedure Run(var X: Integer);
    var
      V: TProc;
    begin
      V := procedure
      begin
        WriteLn(X)
      end;
      V()
    end;
    var N: Integer;
    begin
      N := 5;
      Run(N)
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
  AssertTrue('capturing a var parameter is rejected', OK);
end;

procedure TAnonMethodTests.TestSemantic_Phase3_MethodLiteralCapturesSelf;
const
  { Phase 3: a literal inside an INSTANCE method body captures the method's
    locals AND Self (conservatively), so implicit and explicit member access
    work through the env.  The lifted thunk's EnvCaptured must list both. }
  Src =
    '''
    program P;
    type
      TProc = reference to procedure;
      TCounter = class
        FCount: Integer;
        procedure Bump;
      end;
    procedure TCounter.Bump;
    var
      Step: Integer;
      V: TProc;
    begin
      Step := 2;
      V := procedure
      begin
        FCount := FCount + Step
      end;
      V()
    end;
    var C: TCounter;
    begin
      C := TCounter.Create();
      C.Bump();
      WriteLn(C.FCount)
    end.
    ''';
var
  Prog:  TProgram;
  MD:    TMethodDecl;
  Thunk: TMethodDecl;
  I:     Integer;
begin
  Prog := AnalyseSrc(Src);
  try
    Thunk := nil;
    for I := 0 to Prog.Block.ProcDecls.Count - 1 do
    begin
      MD := TMethodDecl(Prog.Block.ProcDecls.Items[I]);
      if MD.Name = '__closure_1' then Thunk := MD;
    end;
    AssertNotNull('lifted thunk registered', Thunk);
    AssertNotNull('thunk records env captures', Thunk.EnvCaptured);
    AssertTrue('Step captured', Thunk.EnvCaptured.IndexOf('Step') >= 0);
    AssertTrue('Self captured', Thunk.EnvCaptured.IndexOf('Self') >= 0);
  finally
    Prog.Free();
  end;
end;

procedure TAnonMethodTests.TestSemantic_Phase4_BlockVarOutOfScopeAfterBlock;
const
  { A block-scoped var is invisible after its enclosing block ends. }
  Src =
    '''
    program P;
    procedure Run;
    begin
      begin
        var X: Integer := 1;
        WriteLn(X)
      end;
      WriteLn(X)
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
  AssertTrue('block var out of scope after the block', OK);
end;

procedure TAnonMethodTests.TestSemantic_Phase4_BlockVarDuplicateRejected;
const
  { v1 restriction: a block var may not shadow an existing local. }
  Src =
    '''
    program P;
    procedure Run;
    var
      X: Integer;
    begin
      X := 1;
      begin
        var X: Integer := 2;
        WriteLn(X)
      end
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
  AssertTrue('shadowing block var is rejected', OK);
end;

procedure TAnonMethodTests.TestSemantic_Phase4_MixedScopeCaptureRejected;
const
  { v1 restriction: one closure may not capture BOTH a block-scoped var and
    a routine-level var (environment chaining is deferred). }
  Src =
    '''
    program P;
    type
      TProc = reference to procedure;
    var G: TProc;
    procedure Run;
    var
      Outer: Integer;
    begin
      Outer := 1;
      begin
        var Inner: Integer := 2;
        G := procedure
        begin
          WriteLn(Outer + Inner)
        end
      end
    end;
    begin
      Run();
      G()
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
  AssertTrue('mixed-scope capture is rejected in v1', OK);
end;

procedure TAnonMethodTests.TestSemantic_Phase5_WeakNonSelfRejected;
const
  { v1: [Weak] capture is supported for Self only (the cycle-breaking use
    case); weak capture of ordinary variables is a later extension. }
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
      V := procedure [Weak Outer]
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
  AssertTrue('[Weak] on a non-Self capture is rejected', OK);
end;

procedure TAnonMethodTests.TestSemantic_Phase3_MethodPtrCoercionAccepted;
const
  { Phase 3: an 'of object' method-pointer value coerces into a
    'reference to' slot of the same signature (Env := receiver,
    strong-retained). }
  Src =
    '''
    program P;
    type
      TProc = reference to procedure;
      TObj = class
        procedure Ping;
      end;
    procedure TObj.Ping;
    begin
      WriteLn('ping')
    end;
    var
      O: TObj;
      V: TProc;
    begin
      O := TObj.Create();
      V := @O.Ping;
      V()
    end.
    ''';
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(Src);   { must not raise }
  Prog.Free();
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

const
  { Shared source for the Phase-2 codegen tests: 'Run' has one captured
    local (Outer) promoted into an env record, one non-captured local, and
    a closure that both reads and writes the capture. }
  Phase2CodegenSrc =
    '''
    program P;
    type
      TProc = reference to procedure;
    procedure Run;
    var
      Outer: Integer;
      Plain: Integer;
      V: TProc;
    begin
      Outer := 1;
      Plain := 2;
      V := procedure
      begin
        Outer := Outer + 1;
        WriteLn(Outer)
      end;
      V();
      WriteLn(Outer + Plain)
    end;
    begin
      Run()
    end.
    ''';

procedure TAnonMethodTests.TestCodegen_Phase2_EnvAllocAndCleanupEmitted;
var IR: string;
begin
  IR := GenIR(Phase2CodegenSrc);
  AssertTrue('env record heap-allocated via _ClassAlloc',
    Pos('call $_ClassAlloc(', IR) > 0);
  AssertTrue('env field-cleanup function defined',
    Pos('__env_', IR) > 0);
end;

procedure TAnonMethodTests.TestCodegen_Phase2_CapturedAccessRedirected;
var IR: string;
begin
  IR := GenIR(Phase2CodegenSrc);
  AssertTrue('captured local redirected through the env pointer',
    Pos('%_env_Outer', IR) > 0);
  AssertTrue('non-captured local still a plain frame slot',
    Pos('%_var_Plain', IR) > 0);
end;

procedure TAnonMethodTests.TestCodegen_Phase2_ClosureCreationAddRefsEnv;
var IR: string;
begin
  IR := GenIR(Phase2CodegenSrc);
  AssertTrue('closure creation retains the env',
    Pos('call $_ClassAddRef(', IR) > 0);
end;

procedure TAnonMethodTests.TestCodegen_Phase2_FrameExitReleasesEnv;
var IR: string;
begin
  IR := GenIR(Phase2CodegenSrc);
  AssertTrue('enclosing frame releases its env reference on exit',
    Pos('call $_ClassRelease(', IR) > 0);
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
