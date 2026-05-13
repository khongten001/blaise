{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e;

{ End-to-end tests: compile Pascal source through the full pipeline
  (Lexer -> Parser -> Semantic -> CodeGenQBE -> qbe -> cc -> native binary),
  execute the result, and assert on stdout / exit code / valgrind output.

  These tests exist because the IR-only test harness cannot detect
  RTL-contract mismatches. The alloc16-size bug in the exception frame
  (32 instead of 512) shipped past 626 IR-level assertions because none of
  them linked the IR against the RTL and ran it. Any change to code that
  interacts with the C RTL should add an end-to-end case here.

  Tests shell out via TProcess; each test compiles, runs, and cleans up
  one binary. Roughly ~150 ms per test on a dev laptop. Keep the suite
  focused on behaviour the IR harness cannot see (stack layout, RTL calls,
  leak-freedom, dispatch correctness), not on features already covered by
  IR-level assertions. }

interface

uses
  classes, sysutils, process, bcl.testing,
  uLexer, uParser, uAST, uSemantic, uCodeGenQBE;

type
  TE2ETests = class(TTestCase)
  private
    FQBE:     string;
    FRTL:     string;
    FScratch: string;
    FCounter: Integer;
    function  ProjectRoot: string;
    function  CompileToIR(const ASrc: string): string;
    function  CompileAndRun(const ASrc:       string;
                            out   AStdout:    string;
                            out   AExitCode:  Integer;
                            const AExtraArgs: array of string): Boolean; overload;
    function  CompileAndRun(const ASrc:    string;
                            out AStdout:   string;
                            out AExitCode: Integer): Boolean; overload;
    function  RunUnderValgrind(const ASrc: string; out ALog: string): Boolean;
    function  ToolchainAvailable: Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    { Regression for the alloc16-32 exception-frame bug:
      a bare try/finally with no locals, virtuals, or RTL use.
      Before the fix, setjmp's 200-byte jmp_buf write overflowed the
      32-byte frame and corrupted the return address. }
    procedure TestRun_BareTryFinally;

    { Locals live in the stack frame around the exception frame.
      If the exception frame is undersized, setjmp clobbers them. }
    procedure TestRun_TryFinally_PreservesLocals;

    { Exception frame must not corrupt caller state when nested. }
    procedure TestRun_NestedTryFinally;

    { Virtual dispatch in expression position inside try/finally —
      the exact pattern that first surfaced the undersize-frame bug. }
    procedure TestRun_VirtualDispatchInsideTryFinally;

    { Phase 2 milestone program: classes, inheritance, virtual, properties,
      try/finally, and 'is' — linked list with owned nodes. Asserts
      expected stdout. Acts as the canonical smoke test for Phase 2. }
    procedure TestRun_Phase2Milestone_Stdout;

    { Valgrind-clean: no leaks and no errors on the milestone program.
      Skipped (not failed) when valgrind is absent. }
    procedure TestRun_Phase2Milestone_Valgrind;

    { Smoke tests for the features added alongside this suite:
      AND/OR/NOT, Exit/Break, multi-arg WriteLn, chained field access. }
    procedure TestRun_BooleanOps_AllExpressions;
    procedure TestRun_MultiArgWriteLn_PrintsAllArgs;
    procedure TestRun_ForBreak_StopsAtFiveHalt;
    procedure TestRun_ExitFromFunction_ReturnsImmediately;
    procedure TestRun_ChainedRecordField_LoadsInner;

    { Universal-ARC e2e coverage: class/interface lifetime under valgrind.
      These programs exercise the insertion passes introduced in the
      class-ownership follow-up and assert leak-freedom. }
    procedure TestRun_ClassArc_NoExplicitFree_Valgrind;
    procedure TestRun_InterfaceArc_CarriesLifetime_Valgrind;

    { [Weak] cycle-break: two class instances referencing each other
      through a [Weak] field stay cycle-free and are valgrind-clean on
      scope exit.  This is the functional proof that the weak-ref
      insertion pass does what it says on the tin. }
    procedure TestRun_WeakRef_BreaksCycle_Valgrind;

    { Destroy as ARC destructor hook: a class with a Destroy method that
      frees an internal malloc buffer goes valgrind-clean when the only
      release is the scope-exit ARC release (no explicit Free call). }
    procedure TestRun_ClassDestroy_FreesBuffer_Valgrind;

    { RTL collections under ARC: a TList<Integer> built inline (no RTL
      unit needed) with a Destroy that frees FData is valgrind-clean. }
    procedure TestRun_TListARC_Valgrind;

    { Phase 3 milestone program: TList + TDictionary under ARC rules.
      Asserts expected stdout and valgrind-clean execution. }
    procedure TestRun_Phase3Milestone_Stdout;
    procedure TestRun_Phase3Milestone_Valgrind;

    { String operation RTL functions: verify correct output at runtime. }
    procedure TestRun_StringOps_Length;
    procedure TestRun_StringOps_Pos;
    procedure TestRun_StringOps_Copy;
    procedure TestRun_StringOps_UpperCase;
    procedure TestRun_StringOps_SameText;
    procedure TestRun_StringOps_IntToStr;
    procedure TestRun_StringOps_StrToInt;
    procedure TestRun_StringOps_StrToInt_Hex;
    procedure TestRun_StringOps_Copy_MaxIntCount;
    procedure TestRun_Int64_PositiveAboveInt32_FormatsCorrectly;
    procedure TestRun_StringOps_Format_IntArg;
    procedure TestRun_StringOps_Format_StrArg;
    procedure TestRun_StringOps_Format_MixedArgs;
    { ------------------------------------------------------------------ }
    { Collections: TObjectList, TStringList                               }
    { ------------------------------------------------------------------ }
    procedure TestRun_TObjectList_AddGetCount;
    procedure TestRun_TObjectList_Delete;
    procedure TestRun_TStringList_AddGet;
    procedure TestRun_TStringList_Find_Sorted;
    procedure TestRun_Collections_Valgrind;
    { ------------------------------------------------------------------ }
    { Self-hosting: file I/O, CLI args, multi-type blocks                 }
    { ------------------------------------------------------------------ }
    procedure TestRun_ParamStr_PrintsArg;
    procedure TestRun_ParamCount_WithArgs;
    procedure TestRun_ReadWriteFile_RoundTrip;
    procedure TestRun_FileExists_TrueAndFalse;
    procedure TestRun_GetEnvVar_Path;
    procedure TestRun_Halt_ExitCode;
    procedure TestRun_MultiTypeBlock_BothClassesWork;
    { ------------------------------------------------------------------ }
    { case statements and enum types                                       }
    { ------------------------------------------------------------------ }
    procedure TestRun_Case_IntegerBranch;
    procedure TestRun_Case_ElseBranch;
    procedure TestRun_Enum_OrdinalValues;
    procedure TestRun_Enum_InCase;
    { ------------------------------------------------------------------ }
    { File path manipulation (step 11)                                    }
    { ------------------------------------------------------------------ }
    procedure TestRun_ChangeFileExt_ChangesExtension;
    procedure TestRun_ExtractFileName_ReturnsName;
    procedure TestRun_ExtractFilePath_ReturnsDir;
    procedure TestRun_IncludeTrailingPathDelimiter_AppendsSlash;
    { ------------------------------------------------------------------ }
    { Process management built-ins (step 8)                               }
    { ------------------------------------------------------------------ }
    procedure TestRun_ProcessBuiltins_CapturesOutput;
    procedure TestRun_ProcessBuiltins_ExitCode;
    { ------------------------------------------------------------------ }
    { Typed except handlers (Step 8)                                      }
    { ------------------------------------------------------------------ }
    procedure TestRun_TypedExcept_CorrectHandlerMatched;
    procedure TestRun_TypedExcept_SubclassMatchesParentHandler;
    procedure TestRun_TypedExcept_UnmatchedReraises;
    procedure TestRun_TypedExcept_BareRaisePropagatesToOuter;
    procedure TestRun_TypedExcept_ElseBodyRunsWhenNoMatch;

    { ------------------------------------------------------------------ }
    { Built-in TObject.ToString                                           }
    { ------------------------------------------------------------------ }
    { Default ToString (no override) returns the runtime class name via
      vtable slot 1.  Exercises the RTL TObject_ToString helper and its
      vtable + typeinfo walk — IR tests cannot validate the helper. }
    procedure TestRun_ToString_DefaultReturnsClassName;
    { An override placed at vtable slot 1 must be reached through Obj.ToString
      even when the static type is the base class — i.e. the FieldAccess
      method-call path must dispatch virtually, not statically. }
    procedure TestRun_ToString_OverrideDispatchedVirtually;
    { When a derived class inherits the override without re-declaring it,
      the inherited slot must still resolve to the override at runtime. }
    procedure TestRun_ToString_InheritedOverrideStillReached;

    { ------------------------------------------------------------------ }
    { OS utility builtins (step 2a)                                      }
    { ------------------------------------------------------------------ }
    procedure TestRun_GetProcessID_ReturnsNonZero;
    procedure TestRun_DirectoryExists_TrueAndFalse;
    procedure TestRun_GetTempDir_ReturnsPath;
    procedure TestRun_ForceDirectories_CreatesTree;
    procedure TestRun_Sleep_DoesNotCrash;

    { TObject.InheritsFrom: class ancestry walk }
    procedure TestRun_InheritsFrom_SameClass_ReturnsTrue;
    procedure TestRun_InheritsFrom_Parent_ReturnsTrue;
    procedure TestRun_InheritsFrom_GrandParent_ReturnsTrue;
    procedure TestRun_InheritsFrom_Unrelated_ReturnsFalse;
    procedure TestRun_InheritsFrom_Reverse_ReturnsFalse;
    procedure TestRun_InheritsFrom_ClassType_Works;

    { for..in: full compile+run through QBE+gcc.
      IR-substring tests cannot detect the promoted-scalar storew bug
      (QBE rejects invalid IR at assembly time, not codegen time). }
    procedure TestRun_ForIn_String_ByteVar_PrintsBytes;
    procedure TestRun_ForIn_String_IntegerVar_PrintsBytes;
    procedure TestRun_ForIn_Array_Integer_PrintsElements;
    procedure TestRun_ForIn_ClassEnumerator_PrintsElements;

    { Control flow }
    procedure TestRun_For_Upward_PrintsRange;
    procedure TestRun_For_Downto_PrintsRange;
    procedure TestRun_While_PrintsRange;
    procedure TestRun_Repeat_PrintsRange;
    procedure TestRun_For_BreakExitsEarly;
    procedure TestRun_For_ContinueSkipsIteration;
    procedure TestRun_Nested_For_Loops;

    { Records }
    procedure TestRun_Record_FieldReadWrite;
    procedure TestRun_Record_PassByValue;
    procedure TestRun_Record_PassByVar;
    procedure TestRun_Record_StringField_ARC;
    procedure TestRun_Record_NestedRecord;

    { Pointers }
    procedure TestRun_Pointer_GetMem_WriteRead_FreeMem;
    procedure TestRun_Pointer_TypedPointer_Deref;
    procedure TestRun_Pointer_NilCheck;

    { Text blocks }
    procedure TestRun_TextBlock_BasicContent;
    procedure TestRun_TextBlock_IndentStripped;

    { Constants }
    procedure TestRun_Const_IntegerConst;
    procedure TestRun_Const_StringConst;
    procedure TestRun_Const_NegativeConst;

    { Sets }
    procedure TestRun_Set_Include_Exclude;
    procedure TestRun_Set_InOperator;
    procedure TestRun_Set_UnionIntersect;

    { Procedural types }
    procedure TestRun_ProcType_CallViaVariable;
    procedure TestRun_ProcType_OfObject_Dispatch;

    { Default parameters }
    procedure TestRun_DefaultParam_OmitLast;
    procedure TestRun_DefaultParam_OmitMultiple;

    { Open arrays }
    procedure TestRun_OpenArray_Sum;
    procedure TestRun_OpenArray_HighLow;
    procedure TestRun_OpenArray_Length;

    { var / const params }
    procedure TestRun_VarParam_SwapIntegers;
    procedure TestRun_VarParam_ModifyString;
    procedure TestRun_ConstParam_CanRead;

    { String operations }
    procedure TestRun_StringSubscript_ReadByte;
    procedure TestRun_StringConcat_TwoStrings;
    procedure TestRun_StringConcat_WithInt;
    procedure TestRun_StringDelete_Modifies;
    procedure TestRun_StringSetLength_Truncates;

    { Int64 }
    procedure TestRun_Int64_ArithmeticOverInt32;
    procedure TestRun_Int64_Comparison;
    procedure TestRun_Int64_ForLoop;

    { Type casts }
    procedure TestRun_TypeCast_IntegerByte;
    procedure TestRun_TypeCast_PointerInteger;

    { is / as }
    procedure TestRun_Is_CorrectSubclass_True;
    procedure TestRun_Is_WrongClass_False;
    procedure TestRun_As_DowncastCallsMethod;

    { Inheritance and virtual dispatch }
    procedure TestRun_Inherited_CallsParentMethod;
    procedure TestRun_Virtual_OverrideDispatch;
    procedure TestRun_MultiLevel_Inheritance_Chain;

    { Interfaces }
    procedure TestRun_Interface_Dispatch_CallsImpl;
    procedure TestRun_Interface_ARC_NoLeak;
    procedure TestRun_Interface_Is_As_Roundtrip;
    procedure TestRun_Supports_TwoArg_BooleanResult;
    procedure TestRun_Supports_ThreeArg_AssignsAndCalls;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Path discovery                                                       }
{ ------------------------------------------------------------------ }

function TE2ETests.ProjectRoot: string;
var
  Dir, Parent: string;
  Steps:       Integer;
begin
  { Honour an explicit env override first. }
  Result := GetEnvironmentVariable('BLAISE_PROJECT_ROOT');
  if Result <> '' then
  begin
    Result := IncludeTrailingPathDelimiter(Result);
    Exit;
  end;

  { PasBuild runs the test binary from compiler/target/, not the project
    root. Walk up from the CWD looking for the pair of marker directories
    that together uniquely identify this project's root: vendor/qbe and rtl. }
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

  { Fallback: return CWD as-is. Tests that need paths will skip gracefully. }
  Result := IncludeTrailingPathDelimiter(GetCurrentDir);
end;

function TE2ETests.ToolchainAvailable: Boolean;
begin
  Result := FileExists(FQBE) and FileExists(FRTL);
end;

procedure TE2ETests.SetUp;
var Root: string;
begin
  Root := ProjectRoot;
  FQBE := GetEnvironmentVariable('BLAISE_QBE');
  if FQBE = '' then FQBE := Root + 'vendor/qbe/qbe';
  FRTL := GetEnvironmentVariable('BLAISE_RTL');
  if FRTL = '' then FRTL := Root + 'rtl/target/blaise_rtl.a';

  FScratch := Root + 'compiler/target/test-e2e';
  ForceDirectories(FScratch);
  FCounter := 0;
end;

procedure TE2ETests.TearDown;
begin
  { Scratch files are small; leave them on disk for post-mortem debugging
    when a test fails. A fresh SetUp run does not wipe them, but stale
    artefacts from prior runs are overwritten by name collisions. }
end;

{ ------------------------------------------------------------------ }
{ Compile + run pipeline                                               }
{ ------------------------------------------------------------------ }

function TE2ETests.CompileToIR(const ASrc: string): string;
var
  Lexer:    TLexer;
  Parser:   TParser;
  Prog:     TProgram;
  Semantic: TSemanticAnalyser;
  CG:       TCodeGenQBE;
begin
  Lexer    := nil;
  Parser   := nil;
  Prog     := nil;
  Semantic := nil;
  CG       := nil;
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
    CG.Free;
    Semantic.Free;
    Prog.Free;
    Parser.Free;
    Lexer.Free;
  end;
end;

{ Runs a process with no arguments, captures stdout, returns exit code. }
function RunProcNoArgs(const AExe: string; out AStdout: string): Integer;
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
      AStdout := AStdout + Chunk;
    until (Chunk = '') and not Proc.Running;
    Proc.WaitOnExit;
    Result := Proc.ExitCode;
  finally
    Proc.Free;
  end;
end;

{ Runs a process, captures stdout into AStdout, returns exit code. }
function RunProc(const AExe:     string;
                 const AArgs:    array of string;
                 out   AStdout:  string;
                 AInheritStdErr: Boolean): Integer;
var
  Proc:  TProcess;
  Chunk: string;
  I:     Integer;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    for I := Low(AArgs) to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Execute;
    AStdout := '';
    repeat
      Chunk := Proc.ReadOutput;
      AStdout := AStdout + Chunk;
    until (Chunk = '') and not Proc.Running;
    Proc.WaitOnExit;
    Result := Proc.ExitCode;
  finally
    Proc.Free;
  end;
end;

function TE2ETests.CompileAndRun(const ASrc:       string;
                                 out   AStdout:    string;
                                 out   AExitCode:  Integer;
                                 const AExtraArgs: array of string): Boolean;
var
  IR:       string;
  Base:     string;
  IRFile:   string;
  AsmFile:  string;
  BinFile:  string;
  ToolOut:  string;
  Rc:       Integer;
  Lst:      TStringList;
begin
  Result    := False;
  AStdout   := '';
  AExitCode := -1;

  Inc(FCounter);
  Base    := IncludeTrailingPathDelimiter(FScratch) +
             'case_' + IntToStr(GetProcessID) + '_' + IntToStr(FCounter);
  IRFile  := Base + '.ssa';
  AsmFile := Base + '.s';
  BinFile := Base;

  IR := CompileToIR(ASrc);

  Lst := TStringList.Create;
  try
    Lst.Text := IR;
    Lst.SaveToFile(IRFile);
  finally
    Lst.Free;
  end;

  Rc := RunProc(FQBE, ['-o', AsmFile, IRFile], ToolOut, True);
  if Rc <> 0 then
  begin
    Fail('qbe failed (exit ' + IntToStr(Rc) + '): ' + ToolOut + #10 +
         'IR file preserved at: ' + IRFile);
    Exit;
  end;

  Rc := RunProc('cc', ['-o', BinFile, AsmFile, FRTL], ToolOut, True);
  if Rc <> 0 then
  begin
    Fail('cc failed (exit ' + IntToStr(Rc) + '): ' + ToolOut + #10 +
         'IR: ' + IRFile + #10 + 'asm: ' + AsmFile);
    Exit;
  end;

  Rc := RunProc(BinFile, AExtraArgs, AStdout, False);
  AExitCode := Rc;
  Result    := True;

  { Clean up on success — keep artefacts on failure for debugging. }
  DeleteFile(AsmFile);
  DeleteFile(IRFile);
  DeleteFile(BinFile);
end;

function TE2ETests.CompileAndRun(const ASrc: string;
                                 out AStdout: string;
                                 out AExitCode: Integer): Boolean;
var
  IR:       string;
  Base:     string;
  IRFile:   string;
  AsmFile:  string;
  BinFile:  string;
  ToolOut:  string;
  Rc:       Integer;
  Lst:      TStringList;
begin
  Result    := False;
  AStdout   := '';
  AExitCode := -1;

  Inc(FCounter);
  Base    := IncludeTrailingPathDelimiter(FScratch) +
             'case_' + IntToStr(GetProcessID) + '_' + IntToStr(FCounter);
  IRFile  := Base + '.ssa';
  AsmFile := Base + '.s';
  BinFile := Base;

  IR := CompileToIR(ASrc);

  Lst := TStringList.Create;
  try
    Lst.Text := IR;
    Lst.SaveToFile(IRFile);
  finally
    Lst.Free;
  end;

  Rc := RunProc(FQBE, ['-o', AsmFile, IRFile], ToolOut, True);
  if Rc <> 0 then
  begin
    Fail('qbe failed (exit ' + IntToStr(Rc) + '): ' + ToolOut + #10 +
         'IR file preserved at: ' + IRFile);
    Exit;
  end;

  Rc := RunProc('cc', ['-o', BinFile, AsmFile, FRTL], ToolOut, True);
  if Rc <> 0 then
  begin
    Fail('cc failed (exit ' + IntToStr(Rc) + '): ' + ToolOut + #10 +
         'IR: ' + IRFile + #10 + 'asm: ' + AsmFile);
    Exit;
  end;

  Rc := RunProcNoArgs(BinFile, AStdout);
  AExitCode := Rc;
  Result    := True;

  DeleteFile(AsmFile);
  DeleteFile(IRFile);
  DeleteFile(BinFile);
end;

function TE2ETests.RunUnderValgrind(const ASrc: string;
                                    out   ALog: string): Boolean;
var
  IR:       string;
  Base:     string;
  IRFile:   string;
  AsmFile:  string;
  BinFile:  string;
  ToolOut:  string;
  VgOut:    string;
  Rc:       Integer;
  Lst:      TStringList;
begin
  Result := False;
  ALog   := '';

  Inc(FCounter);
  Base    := IncludeTrailingPathDelimiter(FScratch) +
             'vg_' + IntToStr(GetProcessID) + '_' + IntToStr(FCounter);
  IRFile  := Base + '.ssa';
  AsmFile := Base + '.s';
  BinFile := Base;

  IR := CompileToIR(ASrc);
  Lst := TStringList.Create;
  try
    Lst.Text := IR;
    Lst.SaveToFile(IRFile);
  finally
    Lst.Free;
  end;

  Rc := RunProc(FQBE, ['-o', AsmFile, IRFile], ToolOut, True);
  if Rc <> 0 then Exit;
  Rc := RunProc('cc', ['-o', BinFile, AsmFile, FRTL], ToolOut, True);
  if Rc <> 0 then Exit;

  { --error-exitcode=99 makes valgrind non-zero on errors independent of the
    program's own exit code. --leak-check=full catches reachable-but-unfreed
    heap blocks. stdout+stderr folded so our log contains the HEAP SUMMARY. }
  Rc := RunProc('valgrind',
    ['--error-exitcode=99', '--leak-check=full', '--quiet', BinFile],
    VgOut, True);
  ALog   := VgOut;
  Result := Rc = 0;

  DeleteFile(AsmFile);
  DeleteFile(IRFile);
  DeleteFile(BinFile);
end;

{ ------------------------------------------------------------------ }
{ Tests                                                                }
{ ------------------------------------------------------------------ }

const
  LE = #10;

  SrcBareTryFinally =
    'program P;'                  + LE +
    'begin'                       + LE +
    '  try'                       + LE +
    '    WriteLn(''in_try'')'     + LE +
    '  finally'                   + LE +
    '    WriteLn(''in_finally'')' + LE +
    '  end'                       + LE +
    'end.';

  SrcPreservesLocals =
    'program P;'                  + LE +
    'var A, B, C: Integer;'       + LE +
    'begin'                       + LE +
    '  A := 11;'                  + LE +
    '  B := 22;'                  + LE +
    '  C := 33;'                  + LE +
    '  try'                       + LE +
    '    WriteLn(A);'             + LE +
    '    WriteLn(B);'             + LE +
    '    WriteLn(C)'              + LE +
    '  finally'                   + LE +
    '    WriteLn(A + B + C)'      + LE +
    '  end'                       + LE +
    'end.';

  SrcNestedTryFinally =
    'program P;'                  + LE +
    'begin'                       + LE +
    '  try'                       + LE +
    '    try'                     + LE +
    '      WriteLn(''inner_try'')' + LE +
    '    finally'                 + LE +
    '      WriteLn(''inner_fin'')' + LE +
    '    end'                     + LE +
    '  finally'                   + LE +
    '    WriteLn(''outer_fin'')'  + LE +
    '  end'                       + LE +
    'end.';

  { Virtual dispatch in expression position inside try/finally:
    N.GetTag() reads the result into T. This is the pattern that
    crashed with the undersized exception frame. }
  SrcVirtualDispatchInTry =
    'program P;'                                        + LE +
    'type'                                              + LE +
    '  TNode = class'                                   + LE +
    '    function GetTag: Integer; virtual;'            + LE +
    '  end;'                                            + LE +
    '  TMarkedNode = class(TNode)'                      + LE +
    '    function GetTag: Integer; override;'           + LE +
    '  end;'                                            + LE +
    'function TNode.GetTag: Integer;'                   + LE +
    'begin Result := 0 end;'                            + LE +
    'function TMarkedNode.GetTag: Integer;'             + LE +
    'begin Result := 1 end;'                            + LE +
    'var N: TNode; T: Integer;'                         + LE +
    'begin'                                             + LE +
    '  N := TMarkedNode.Create;'                        + LE +
    '  try'                                             + LE +
    '    T := N.GetTag();'                              + LE +
    '    WriteLn(T)'                                    + LE +
    '  finally'                                         + LE +
    '    N.Free'                                        + LE +
    '  end'                                             + LE +
    'end.';

procedure TE2ETests.TestRun_BareTryFinally;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built: qbe=' + FQBE + '  rtl=' + FRTL);
    Exit;
  end;
  AssertTrue('compile+run',
    CompileAndRun(SrcBareTryFinally, Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('stdout',
    'in_try' + LE + 'in_finally' + LE, Output);
end;

procedure TE2ETests.TestRun_TryFinally_PreservesLocals;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue('compile+run',
    CompileAndRun(SrcPreservesLocals, Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('locals preserved',
    '11' + LE + '22' + LE + '33' + LE + '66' + LE, Output);
end;

procedure TE2ETests.TestRun_NestedTryFinally;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue('compile+run',
    CompileAndRun(SrcNestedTryFinally, Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('stdout',
    'inner_try' + LE + 'inner_fin' + LE + 'outer_fin' + LE, Output);
end;

procedure TE2ETests.TestRun_VirtualDispatchInsideTryFinally;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue('compile+run',
    CompileAndRun(SrcVirtualDispatchInTry, Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('stdout (virtual -> marked -> 1)', '1' + LE, Output);
end;

procedure TE2ETests.TestRun_Phase2Milestone_Stdout;
var
  Path, Src, Output: string;
  RCode:             Integer;
  Lst:               TStringList;
  Expected:          string;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  Path := ProjectRoot + 'tests/phase2_milestone.pas';
  if not FileExists(Path) then
  begin
    Ignore('phase2_milestone.pas not found at ' + Path);
    Exit;
  end;

  Lst := TStringList.Create;
  try
    Lst.LoadFromFile(Path);
    Src := Lst.Text;
  finally
    Lst.Free;
  end;

  AssertTrue('compile+run milestone',
    CompileAndRun(Src, Output, RCode));
  AssertEquals('milestone exit code', 0, RCode);

  Expected :=
    'count=4'             + LE +
    '--- walk ---'        + LE +
    '  value=40'          + LE +
    '  tag=0'             + LE +
    '  marked=0'          + LE +
    '  value=30'          + LE +
    '  tag=1'             + LE +
    '  marked=1'          + LE +
    '  value=20'          + LE +
    '  tag=0'             + LE +
    '  marked=0'          + LE +
    '  value=10'          + LE +
    '  tag=0'             + LE +
    '  marked=0'          + LE +
    'pop=40'              + LE +
    'pop=30'              + LE +
    'count_after_pops=2'  + LE;
  AssertEquals('milestone stdout', Expected, Output);
end;

procedure TE2ETests.TestRun_Phase2Milestone_Valgrind;
var
  Path, Src, Log: string;
  Lst:            TStringList;
  Found, Dummy:   string;
  OK:             Boolean;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  if RunProc('valgrind', ['--version'], Dummy, True) <> 0 then
  begin
    Ignore('valgrind not installed');
    Exit;
  end;
  Path := ProjectRoot + 'tests/phase2_milestone.pas';
  if not FileExists(Path) then
  begin
    Ignore('phase2_milestone.pas not found');
    Exit;
  end;

  Lst := TStringList.Create;
  try
    Lst.LoadFromFile(Path);
    Src := Lst.Text;
  finally
    Lst.Free;
  end;

  OK := RunUnderValgrind(Src, Log);
  if not OK then
  begin
    { valgrind --quiet prints nothing on a clean run, so the log on failure
      is the valuable signal: dump it into the assertion message. }
    Found := Log;
    if Found = '' then Found := '(valgrind produced no output — exit nonzero)';
    Fail('valgrind reported errors or leaks:' + LE + Found);
  end;
end;

{ ------------------------------------------------------------------ }
{ New-feature smoke tests (AND/OR/NOT, Exit/Break, multi-arg WriteLn,
  chained field access).  Kept here rather than a dedicated unit so
  all compile+run coverage lives together. }
{ ------------------------------------------------------------------ }

const
  SrcBoolOps =
    'program P;'                              + LE +
    'var A, B: Boolean;'                      + LE +
    'begin'                                   + LE +
    '  A := True;'                            + LE +
    '  B := False;'                           + LE +
    '  if A and not B then WriteLn(''t1'');'  + LE +
    '  if A or B then WriteLn(''t2'');'       + LE +
    '  if not (A and B) then WriteLn(''t3'')' + LE +
    'end.';

  SrcMultiArg =
    'program P;'                              + LE +
    'var I, J, K: Integer;'                   + LE +
    'begin'                                   + LE +
    '  I := 1; J := 2; K := 3;'               + LE +
    '  WriteLn(I, J, K)'                      + LE +
    'end.';

  SrcForBreak =
    'program P;'                              + LE +
    'var I, Last: Integer;'                   + LE +
    'begin'                                   + LE +
    '  Last := 0;'                            + LE +
    '  for I := 1 to 100 do'                  + LE +
    '  begin'                                 + LE +
    '    Last := I;'                          + LE +
    '    if I = 5 then break'                 + LE +
    '  end;'                                  + LE +
    '  WriteLn(Last)'                         + LE +
    'end.';

  SrcExitFunc =
    'program P;'                              + LE +
    'function FirstPositive(X: Integer): Integer;' + LE +
    'begin'                                   + LE +
    '  if X > 0 then'                         + LE +
    '  begin Result := X; exit end;'          + LE +
    '  Result := 0 - X'                       + LE +
    'end;'                                    + LE +
    'begin'                                   + LE +
    '  WriteLn(FirstPositive(7));'            + LE +
    '  WriteLn(FirstPositive(0 - 9))'         + LE +
    'end.';

  { Universal-ARC on classes: allocate, assign between vars, drop out of
    scope without calling Free.  Under the new rules every variable slot
    holds one retained reference balanced by a scope-exit release.  The
    program is leak-free only if both the per-variable release and the
    per-class field cleanup fire correctly at refcount zero.  We stage
    writes through a local (chained field *writes* are not yet in the
    language; chained reads are). }
  SrcClassArcNoFree =
    'program P;'                                        + LE +
    'type'                                              + LE +
    '  TInner = class'                                  + LE +
    '    V: Integer;'                                   + LE +
    '  end;'                                            + LE +
    '  TOuter = class'                                  + LE +
    '    Child: TInner;'                                + LE +
    '  end;'                                            + LE +
    'var'                                               + LE +
    '  A, B: TOuter;'                                   + LE +
    '  I:    TInner;'                                   + LE +
    'begin'                                             + LE +
    '  A       := TOuter.Create;'                       + LE +
    '  I       := TInner.Create;'                       + LE +
    '  I.V     := 42;'                                  + LE +
    '  A.Child := I;'                                   + LE +
    '  B       := A;'                                   + LE +
    '  WriteLn(B.Child.V)'                              + LE +
    'end.';

  { Universal-ARC on interface references: assigning a class through an
    interface variable addrefs the backing class; on scope exit the
    interface obj slot is released, and the class's final release fires
    its field-cleanup chain.  Without interface-obj ARC this program
    either leaks the backing class or double-frees it on exit.
    Interface *function* calls in expression position are not yet
    supported; we invoke a procedure on the interface which writes
    directly, which is enough to cover the ARC lifetime. }
  SrcInterfaceArcLifetime =
    'program P;'                                        + LE +
    'type'                                              + LE +
    '  IThing = interface'                              + LE +
    '    procedure Emit;'                               + LE +
    '  end;'                                            + LE +
    '  TThing = class(TObject, IThing)'                 + LE +
    '    FValue: Integer;'                              + LE +
    '    procedure Emit;'                               + LE +
    '  end;'                                            + LE +
    'procedure TThing.Emit;'                            + LE +
    'begin'                                             + LE +
    '  WriteLn(Self.FValue)'                            + LE +
    'end;'                                              + LE +
    'var'                                               + LE +
    '  T: TThing;'                                      + LE +
    '  F: IThing;'                                      + LE +
    'begin'                                             + LE +
    '  T        := TThing.Create;'                      + LE +
    '  T.FValue := 17;'                                 + LE +
    '  F        := T;'                                  + LE +
    '  F.Emit'                                          + LE +
    'end.';

  { [Weak] cycle-break: two TNode instances reference each other through a
    [Weak] Other field.  Under strong ARC this would be a refcount cycle
    and leak both nodes; with [Weak] neither side contributes to the
    other's refcount, so scope exit releases both cleanly and the weak
    slots are zeroed before their storage is reclaimed. }
  SrcWeakCycle =
    'program P;'                                        + LE +
    'type'                                              + LE +
    '  TNode = class'                                   + LE +
    '    Value: Integer;'                               + LE +
    '    [Weak] Other: TNode;'                          + LE +
    '  end;'                                            + LE +
    'var'                                               + LE +
    '  A, B: TNode;'                                    + LE +
    'begin'                                             + LE +
    '  A := TNode.Create;'                              + LE +
    '  B := TNode.Create;'                              + LE +
    '  A.Value := 1;'                                   + LE +
    '  B.Value := 2;'                                   + LE +
    '  A.Other := B;'                                   + LE +
    '  B.Other := A;'                                   + LE +
    '  WriteLn(A.Value);'                               + LE +
    '  WriteLn(B.Value)'                                + LE +
    'end.';

  { Destroy as ARC destructor: class allocates an internal buffer via Init,
    Destroy frees it.  No Free call in main — scope-exit ARC handles the
    class lifetime; Destroy is invoked via the field cleanup fn.  The
    program must produce the expected output and pass valgrind. }
  SrcDestroyFreesBuffer =
    'program P;'                                        + LE +
    'type'                                              + LE +
    '  TBuf = class'                                    + LE +
    '    FData: ^Integer;'                              + LE +
    '    procedure Init;'                               + LE +
    '    procedure Destroy;'                            + LE +
    '  end;'                                            + LE +
    'procedure TBuf.Init;'                              + LE +
    'begin'                                             + LE +
    '  Self.FData := GetMem(4 * SizeOf(Integer))'      + LE +
    'end;'                                              + LE +
    'procedure TBuf.Destroy;'                           + LE +
    'begin'                                             + LE +
    '  FreeMem(Self.FData);'                            + LE +
    '  Self.FData := nil'                               + LE +
    'end;'                                              + LE +
    'var B: TBuf;'                                      + LE +
    'begin'                                             + LE +
    '  B := TBuf.Create;'                               + LE +
    '  B.Init;'                                         + LE +
    '  WriteLn(''ok'')'                                 + LE +
    'end.';

  { TList<Integer> with Destroy: proves the pattern that the RTL uses.
    ARC releases the list on scope exit; Destroy frees FData. }
  SrcTListARCValgrind =
    'program P;'                                        + LE +
    'type'                                              + LE +
    '  TList = class'                                   + LE +
    '    FData:     ^Integer;'                          + LE +
    '    FCount:    Integer;'                           + LE +
    '    FCapacity: Integer;'                           + LE +
    '    procedure Grow;'                               + LE +
    '    procedure Add(V: Integer);'                    + LE +
    '    function  Get(I: Integer): Integer;'           + LE +
    '    procedure Destroy;'                            + LE +
    '    property Count: Integer read FCount;'          + LE +
    '  end;'                                            + LE +
    'procedure TList.Grow;'                             + LE +
    'var NewCap: Integer;'                              + LE +
    'begin'                                             + LE +
    '  if Self.FCapacity = 0 then NewCap := 4'         + LE +
    '  else NewCap := Self.FCapacity * 2;'              + LE +
    '  Self.FData     := ReallocMem(Self.FData, NewCap * SizeOf(Integer));' + LE +
    '  Self.FCapacity := NewCap'                        + LE +
    'end;'                                              + LE +
    'procedure TList.Add(V: Integer);'                  + LE +
    'var Dest: ^Integer;'                               + LE +
    'begin'                                             + LE +
    '  if Self.FCount = Self.FCapacity then Self.Grow;' + LE +
    '  Dest  := Self.FData + Self.FCount * SizeOf(Integer);' + LE +
    '  Dest^ := V;'                                     + LE +
    '  Self.FCount := Self.FCount + 1'                  + LE +
    'end;'                                              + LE +
    'function TList.Get(I: Integer): Integer;'          + LE +
    'var Src: ^Integer;'                                + LE +
    'begin'                                             + LE +
    '  Src    := Self.FData + I * SizeOf(Integer);'     + LE +
    '  Result := Src^'                                  + LE +
    'end;'                                              + LE +
    'procedure TList.Destroy;'                          + LE +
    'begin'                                             + LE +
    '  FreeMem(Self.FData);'                            + LE +
    '  Self.FData := nil'                               + LE +
    'end;'                                              + LE +
    'var L: TList;'                                     + LE +
    'begin'                                             + LE +
    '  L := TList.Create;'                              + LE +
    '  L.Add(10);'                                      + LE +
    '  L.Add(20);'                                      + LE +
    '  L.Add(30);'                                      + LE +
    '  WriteLn(L.Get(0));'                              + LE +
    '  WriteLn(L.Get(1));'                              + LE +
    '  WriteLn(L.Get(2));'                              + LE +
    '  WriteLn(L.Count)'                                + LE +
    'end.';

  { Chained READ: Pascal zero-initialises records, so O.I.Value defaults
    to 0 without any write.  Exercising the read path is enough for this
    smoke test; chained-WRITE support is tracked separately. }
  SrcChainedRecord =
    'program P;'                              + LE +
    'type'                                    + LE +
    '  TInner = record Value: Integer; end;'  + LE +
    '  TOuter = record I: TInner; end;'       + LE +
    'var O: TOuter; N: Integer;'              + LE +
    'begin'                                   + LE +
    '  N := O.I.Value;'                       + LE +
    '  WriteLn(N)'                            + LE +
    'end.';

procedure TE2ETests.TestRun_BooleanOps_AllExpressions;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue(CompileAndRun(SrcBoolOps, Output, RCode));
  AssertEquals('exit 0', 0, RCode);
  AssertEquals('all three branches fire',
    't1' + LE + 't2' + LE + 't3' + LE, Output);
end;

procedure TE2ETests.TestRun_MultiArgWriteLn_PrintsAllArgs;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue(CompileAndRun(SrcMultiArg, Output, RCode));
  AssertEquals('exit 0', 0, RCode);
  AssertEquals('three values concatenated with trailing newline',
    '123' + LE, Output);
end;

procedure TE2ETests.TestRun_ForBreak_StopsAtFiveHalt;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue(CompileAndRun(SrcForBreak, Output, RCode));
  AssertEquals('exit 0', 0, RCode);
  AssertEquals('loop broke at I=5', '5' + LE, Output);
end;

procedure TE2ETests.TestRun_ExitFromFunction_ReturnsImmediately;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue(CompileAndRun(SrcExitFunc, Output, RCode));
  AssertEquals('exit 0', 0, RCode);
  AssertEquals('exit early for positive, compute for negative',
    '7' + LE + '9' + LE, Output);
end;

procedure TE2ETests.TestRun_ChainedRecordField_LoadsInner;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue(CompileAndRun(SrcChainedRecord, Output, RCode));
  AssertEquals('exit 0', 0, RCode);
  AssertEquals('chained read of zero-initialised field', '0' + LE, Output);
end;

procedure TE2ETests.TestRun_ClassArc_NoExplicitFree_Valgrind;
var Output: string; RCode: Integer; Log: string; OK: Boolean;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  { Sanity: program runs and prints 42 }
  AssertTrue(CompileAndRun(SrcClassArcNoFree, Output, RCode));
  AssertEquals('exit 0',       0,         RCode);
  AssertEquals('field reread', '42' + LE, Output);
  { Leak-freedom: under valgrind, every class instance must be reclaimed
    by scope-exit releases alone (no Free calls anywhere in the source). }
  if RunProc('valgrind', ['--version'], Log, True) <> 0 then
  begin
    Ignore('valgrind not installed');
    Exit;
  end;
  OK := RunUnderValgrind(SrcClassArcNoFree, Log);
  if not OK then
  begin
    if Log = '' then Log := '(valgrind produced no output — exit nonzero)';
    Fail('valgrind reported errors or leaks:' + LE + Log);
  end;
end;

procedure TE2ETests.TestRun_InterfaceArc_CarriesLifetime_Valgrind;
var Output: string; RCode: Integer; Log: string; OK: Boolean;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue(CompileAndRun(SrcInterfaceArcLifetime, Output, RCode));
  AssertEquals('exit 0',                  0,         RCode);
  AssertEquals('interface method result', '17' + LE, Output);
  if RunProc('valgrind', ['--version'], Log, True) <> 0 then
  begin
    Ignore('valgrind not installed');
    Exit;
  end;
  OK := RunUnderValgrind(SrcInterfaceArcLifetime, Log);
  if not OK then
  begin
    if Log = '' then Log := '(valgrind produced no output — exit nonzero)';
    Fail('valgrind reported errors or leaks:' + LE + Log);
  end;
end;

procedure TE2ETests.TestRun_WeakRef_BreaksCycle_Valgrind;
var Output: string; RCode: Integer; Log: string; OK: Boolean;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue(CompileAndRun(SrcWeakCycle, Output, RCode));
  AssertEquals('exit 0',                0,              RCode);
  AssertEquals('values printed via A/B', '1' + LE + '2' + LE, Output);
  if RunProc('valgrind', ['--version'], Log, True) <> 0 then
  begin
    Ignore('valgrind not installed');
    Exit;
  end;
  OK := RunUnderValgrind(SrcWeakCycle, Log);
  if not OK then
  begin
    if Log = '' then Log := '(valgrind produced no output — exit nonzero)';
    Fail('valgrind reported errors or leaks:' + LE + Log);
  end;
end;

procedure TE2ETests.TestRun_ClassDestroy_FreesBuffer_Valgrind;
var
  Output: string;
  RCode:  Integer;
  Log:    string;
  OK:     Boolean;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue('compile+run', CompileAndRun(SrcDestroyFreesBuffer, Output, RCode));
  AssertEquals('exit 0',  0,          RCode);
  AssertEquals('stdout',  'ok' + LE,  Output);
  if RunProc('valgrind', ['--version'], Log, True) <> 0 then
  begin
    Ignore('valgrind not installed');
    Exit;
  end;
  OK := RunUnderValgrind(SrcDestroyFreesBuffer, Log);
  if not OK then
  begin
    if Log = '' then Log := '(valgrind produced no output — exit nonzero)';
    Fail('Destroy did not free buffer — valgrind reports:' + LE + Log);
  end;
end;

procedure TE2ETests.TestRun_TListARC_Valgrind;
var
  Output: string;
  RCode:  Integer;
  Log:    string;
  OK:     Boolean;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  AssertTrue('compile+run', CompileAndRun(SrcTListARCValgrind, Output, RCode));
  AssertEquals('exit 0',  0,   RCode);
  AssertEquals('stdout',
    '10' + LE + '20' + LE + '30' + LE + '3' + LE, Output);
  if RunProc('valgrind', ['--version'], Log, True) <> 0 then
  begin
    Ignore('valgrind not installed');
    Exit;
  end;
  OK := RunUnderValgrind(SrcTListARCValgrind, Log);
  if not OK then
  begin
    if Log = '' then Log := '(valgrind produced no output — exit nonzero)';
    Fail('TList FData leaked — valgrind reports:' + LE + Log);
  end;
end;

procedure TE2ETests.TestRun_Phase3Milestone_Stdout;
var
  Path, Src, Output: string;
  RCode:             Integer;
  Lst:               TStringList;
  Expected:          string;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  Path := ProjectRoot + 'tests/phase3_milestone.pas';
  if not FileExists(Path) then
  begin
    Ignore('phase3_milestone.pas not found at ' + Path);
    Exit;
  end;
  Lst := TStringList.Create;
  try
    Lst.LoadFromFile(Path);
    Src := Lst.Text;
  finally
    Lst.Free;
  end;
  AssertTrue('compile+run milestone', CompileAndRun(Src, Output, RCode));
  AssertEquals('milestone exit code', 0, RCode);
  Expected :=
    'list.count=5'             + LE +
    'list[0]=10'               + LE +
    'list[4]=50'               + LE +
    'count_after_delete=4'     + LE +
    'list[1]_after_delete=30'  + LE +
    'dict.count=4'             + LE +
    'beta=2'                   + LE +
    'has_gamma=1'              + LE +
    'beta_after_update=99'     + LE +
    'count_after_remove=3'     + LE +
    'has_alpha_after_remove=0' + LE;
  AssertEquals('milestone stdout', Expected, Output);
end;

procedure TE2ETests.TestRun_Phase3Milestone_Valgrind;
var
  Path, Src, Log: string;
  Lst:            TStringList;
  Dummy:          string;
  OK:             Boolean;
begin
  if not ToolchainAvailable then
  begin
    Ignore('qbe or RTL not built');
    Exit;
  end;
  if RunProc('valgrind', ['--version'], Dummy, True) <> 0 then
  begin
    Ignore('valgrind not installed');
    Exit;
  end;
  Path := ProjectRoot + 'tests/phase3_milestone.pas';
  if not FileExists(Path) then
  begin
    Ignore('phase3_milestone.pas not found');
    Exit;
  end;
  Lst := TStringList.Create;
  try
    Lst.LoadFromFile(Path);
    Src := Lst.Text;
  finally
    Lst.Free;
  end;
  OK := RunUnderValgrind(Src, Log);
  if not OK then
  begin
    if Log = '' then Log := '(valgrind produced no output — exit nonzero)';
    Fail('phase3 milestone has leaks or errors:' + LE + Log);
  end;
end;

{ ------------------------------------------------------------------ }
{ String operation e2e tests                                          }
{ ------------------------------------------------------------------ }

const
  SrcStringLength =
    '''
        program P;
        var s: string;
        var n: Integer;
        begin
          s := 'hello';
          n := Length(s);
          WriteLn(n)
        end.
        ''';

  SrcStringPos =
    '''
        program P;
        var s, sub: string;
        var n: Integer;
        begin
          s   := 'hello world';
          sub := 'world';
          n   := Pos(sub, s);
          WriteLn(n)
        end.
        ''';

  SrcStringCopy =
    '''
        program P;
        var s, t: string;
        begin
          s := 'hello';
          t := Copy(s, 1, 3);
          WriteLn(t)
        end.
        ''';

  SrcStringUpperCase =
    '''
        program P;
        var s, t: string;
        begin
          s := 'hello';
          t := UpperCase(s);
          WriteLn(t)
        end.
        ''';

  SrcStringSameText =
    '''
        program P;
        var s, t: string;
        var b: Boolean;
        begin
          s := 'Hello';
          t := 'hello';
          b := SameText(s, t);
          WriteLn(b)
        end.
        ''';

  SrcStringIntToStr =
    '''
        program P;
        var n: Integer;
        var s: string;
        begin
          n := 42;
          s := IntToStr(n);
          WriteLn(s)
        end.
        ''';

  SrcStringStrToInt =
    '''
        program P;
        var s: string;
        var n: Integer;
        begin
          s := '123';
          n := StrToInt(s);
          WriteLn(n)
        end.
        ''';

procedure TE2ETests.TestRun_StringOps_Length;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringLength, Output, RCode));
  AssertEquals('Length(''hello'') = 5', '5', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_Pos;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringPos, Output, RCode));
  AssertEquals('Pos(''world'', ''hello world'') = 6', '6', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_Copy;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringCopy, Output, RCode));
  AssertEquals('Copy(''hello'', 1, 3) = ''ell''', 'ell', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_UpperCase;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringUpperCase, Output, RCode));
  AssertEquals('UpperCase(''hello'') = ''HELLO''', 'HELLO', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_SameText;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringSameText, Output, RCode));
  AssertEquals('SameText(''Hello'', ''hello'') = True (1)', '1', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_IntToStr;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringIntToStr, Output, RCode));
  AssertEquals('IntToStr(42) = ''42''', '42', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_StrToInt;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringStrToInt, Output, RCode));
  AssertEquals('StrToInt(''123'') = 123', '123', Trim(Output));
end;

const
  SrcStringStrToIntHex =
    '''
        program P;
        var n: Integer;
        begin
          n := StrToInt('$FF');
          WriteLn(n)
        end.
        ''';

  SrcStringCopyMaxIntCount =
    '''
        program P;
        var s: string;
        begin
          s := Copy('^Integer', 1, MaxInt);
          WriteLn(s)
        end.
        ''';

procedure TE2ETests.TestRun_StringOps_StrToInt_Hex;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringStrToIntHex, Output, RCode));
  AssertEquals('StrToInt(''$FF'') = 255', '255', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_Copy_MaxIntCount;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringCopyMaxIntCount, Output, RCode));
  AssertEquals('Copy(''^Integer'', 1, MaxInt) = ''Integer''', 'Integer', Trim(Output));
end;

const
  SrcInt64PositiveAboveInt32 =
    '''
        program P;
        var v: Int64;
        begin
          v := 1000000000;
          v := v + v + 166136261;
          if v < 0 then WriteLn('neg')
                  else WriteLn('pos');
          WriteLn(IntToStr(v))
        end.
        ''';

procedure TE2ETests.TestRun_Int64_PositiveAboveInt32_FormatsCorrectly;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInt64PositiveAboveInt32, Output, RCode));
  AssertEquals('Int64=2166136261 compares as positive and formats correctly',
    'pos' + #10 + '2166136261', Trim(Output));
end;

const
  SrcFormatIntArg =
    '''
        program P;
        var n: Integer;
        var s: string;
        begin
          n := 42;
          s := Format('val=%d', n);
          WriteLn(s)
        end.
        ''';

  SrcFormatStrArg =
    '''
        program P;
        var t: string;
        var s: string;
        begin
          t := 'world';
          s := Format('hello %s', t);
          WriteLn(s)
        end.
        ''';

  SrcFormatMixedArgs =
    '''
        program P;
        var name: string;
        var age: Integer;
        var s: string;
        begin
          name := 'Alice';
          age  := 30;
          s := Format('%s=%d', name, age);
          WriteLn(s)
        end.
        ''';

procedure TE2ETests.TestRun_StringOps_Format_IntArg;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcFormatIntArg, Output, RCode));
  AssertEquals('Format int arg', 'val=42', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_Format_StrArg;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcFormatStrArg, Output, RCode));
  AssertEquals('Format str arg', 'hello world', Trim(Output));
end;

procedure TE2ETests.TestRun_StringOps_Format_MixedArgs;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcFormatMixedArgs, Output, RCode));
  AssertEquals('Format mixed args', 'Alice=30', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Collections e2e tests                                               }
{ ------------------------------------------------------------------ }

const
  SrcTObjectListBase2 =
    '''
        type
          TObjectList = class
            FData:     ^Pointer;
            FCount:    Integer;
            FCapacity: Integer;
            procedure Grow;
            var OldCap, NewCap: Integer;
            begin
              OldCap := Self.FCapacity;
              if OldCap = 0 then NewCap := 4
              else NewCap := OldCap * 2;
              Self.FData     := ReallocMem(Self.FData, NewCap * SizeOf(Pointer));
              Self.FCapacity := NewCap
            end;
            function Add(AObject: Pointer): Integer;
            var Dest: ^Pointer;
            begin
              if Self.FCount = Self.FCapacity then Self.Grow;
              Dest        := Self.FData + Self.FCount * SizeOf(Pointer);
              Dest^       := AObject;
              Self.FCount := Self.FCount + 1;
              Result      := Self.FCount - 1
            end;
            function Get(AIndex: Integer): Pointer;
            var Src: ^Pointer;
            begin
              Src    := Self.FData + AIndex * SizeOf(Pointer);
              Result := Src^
            end;
            procedure Delete(AIndex: Integer);
            var I: Integer; Dst, Src: ^Pointer;
            begin
              I := AIndex;
              while I < Self.FCount - 1 do
              begin
                Dst  := Self.FData + I * SizeOf(Pointer);
                Src  := Self.FData + (I + 1) * SizeOf(Pointer);
                Dst^ := Src^;
                I    := I + 1
              end;
              Self.FCount := Self.FCount - 1
            end;
            property Count: Integer read FCount;
          end;
        ''';

  SrcTObjectListAddGetCount =
    'program P;' + #10 + 
    SrcTObjectListBase2 +
    '''
        var
          L:  TObjectList;
          P1, P2: Pointer;
        begin
          L  := TObjectList.Create;
          P1 := GetMem(1);
          P2 := GetMem(1);
          L.Add(P1);
          L.Add(P2);
          L.Add(nil);
          WriteLn(L.Count);
          WriteLn(L.Get(0) = P1);
          WriteLn(L.Get(1) = P2)
        end.
        ''';

  SrcTObjectListDelete =
    'program P;' + #10 + 
    SrcTObjectListBase2 +
    '''
        var L: TObjectList;
        begin
          L := TObjectList.Create;
          L.Add(GetMem(1));
          L.Add(GetMem(1));
          L.Add(GetMem(1));
          L.Delete(1);
          WriteLn(L.Count)
        end.
        ''';

  SrcTStringListBase2 =
    '''
        type
          TStringList = class
            FStrings:  ^string;
            FObjects:  ^Pointer;
            FCount:    Integer;
            FCapacity: Integer;
            procedure Grow;
            var OldCap, NewCap: Integer;
            begin
              OldCap := Self.FCapacity;
              if OldCap = 0 then NewCap := 4
              else NewCap := OldCap * 2;
              Self.FStrings := ReallocMem(Self.FStrings, NewCap * SizeOf(string));
              Self.FObjects := ReallocMem(Self.FObjects, NewCap * SizeOf(Pointer));
              ZeroMem(Self.FStrings + OldCap * SizeOf(string),
                      (NewCap - OldCap) * SizeOf(string));
              Self.FCapacity := NewCap
            end;
            procedure Destroy;
            var I: Integer; Ptr: ^string;
            begin
              I := 0;
              while I < Self.FCount do
              begin
                Ptr  := Self.FStrings + I * SizeOf(string);
                Ptr^ := nil;
                I    := I + 1
              end;
              FreeMem(Self.FStrings);
              FreeMem(Self.FObjects);
              Self.FStrings  := nil;
              Self.FObjects  := nil;
              Self.FCount    := 0;
              Self.FCapacity := 0
            end;
            function Add(S: string): Integer;
            var StrP: ^string; ObjP: ^Pointer;
            begin
              if Self.FCount = Self.FCapacity then Self.Grow;
              StrP        := Self.FStrings + Self.FCount * SizeOf(string);
              ObjP        := Self.FObjects + Self.FCount * SizeOf(Pointer);
              StrP^       := S;
              ObjP^       := nil;
              Result      := Self.FCount;
              Self.FCount := Self.FCount + 1
            end;
            function Get(AIndex: Integer): string;
            var Ptr: ^string;
            begin
              Ptr    := Self.FStrings + AIndex * SizeOf(string);
              Result := Ptr^
            end;
            function Find(S: string; var Index: Integer): Boolean;
            var Lo, Hi, Mid, Cmp: Integer; Ptr: ^string; MStr: string;
            begin
              Lo := 0; Hi := Self.FCount - 1;
              while Lo <= Hi do
              begin
                Mid  := (Lo + Hi) div 2;
                Ptr  := Self.FStrings + Mid * SizeOf(string);
                MStr := Ptr^;
                Cmp  := CompareText(S, MStr);
                if Cmp = 0 then
                begin
                  Index := Mid; Result := True; Exit
                end
                else if Cmp < 0 then Hi := Mid - 1
                else Lo := Mid + 1
              end;
              Index := Lo; Result := False
            end;
            property Count: Integer read FCount;
          end;
        ''';

  SrcTStringListAddGet =
    'program P;' + #10 + 
    SrcTStringListBase2 +
    '''
        var
          L: TStringList;
        begin
          L := TStringList.Create;
          L.Add('hello');
          L.Add('world');
          WriteLn(L.Count);
          WriteLn(L.Get(0));
          WriteLn(L.Get(1))
        end.
        ''';

  SrcTStringListFindSorted =
    'program P;' + #10 + 
    SrcTStringListBase2 +
    '''
        var
          L: TStringList;
          Idx: Integer;
          Found: Boolean;
        begin
          L := TStringList.Create;
          L.Add('alpha');
          L.Add('beta');
          L.Add('gamma');
          Found := L.Find('beta', Idx);
          WriteLn(Found);
          WriteLn(Idx);
          Found := L.Find('delta', Idx);
          WriteLn(Found)
        end.
        ''';

  { Combined program: both classes in a single type section }
  SrcCollectionsValgrind =
    '''
        program P;
        type
          TObjectList = class
            FData: ^Pointer; FCount: Integer; FCapacity: Integer;
            procedure Grow;
            var OldCap, NewCap: Integer;
            begin
              OldCap := Self.FCapacity;
              if OldCap = 0 then NewCap := 4 else NewCap := OldCap * 2;
              Self.FData := ReallocMem(Self.FData, NewCap * SizeOf(Pointer));
              Self.FCapacity := NewCap
            end;
            function Add(AObject: Pointer): Integer;
            var Dest: ^Pointer;
            begin
              if Self.FCount = Self.FCapacity then Self.Grow;
              Dest := Self.FData + Self.FCount * SizeOf(Pointer);
              Dest^ := AObject;
              Self.FCount := Self.FCount + 1;
              Result := Self.FCount - 1
            end;
            procedure Destroy;
            begin
              FreeMem(Self.FData);
              Self.FData := nil; Self.FCount := 0; Self.FCapacity := 0
            end;
            property Count: Integer read FCount;
          end;
          TStringList = class
            FStrings: ^string; FObjects: ^Pointer;
            FCount: Integer; FCapacity: Integer;
            procedure Grow;
            var OldCap, NewCap: Integer;
            begin
              OldCap := Self.FCapacity;
              if OldCap = 0 then NewCap := 4 else NewCap := OldCap * 2;
              Self.FStrings := ReallocMem(Self.FStrings, NewCap * SizeOf(string));
              Self.FObjects := ReallocMem(Self.FObjects, NewCap * SizeOf(Pointer));
              ZeroMem(Self.FStrings + OldCap * SizeOf(string),
                      (NewCap - OldCap) * SizeOf(string));
              Self.FCapacity := NewCap
            end;
            procedure Destroy;
            var I: Integer; Ptr: ^string;
            begin
              I := 0;
              while I < Self.FCount do
              begin
                Ptr := Self.FStrings + I * SizeOf(string); Ptr^ := nil; I := I + 1
              end;
              FreeMem(Self.FStrings); FreeMem(Self.FObjects);
              Self.FStrings := nil; Self.FObjects := nil;
              Self.FCount := 0; Self.FCapacity := 0
            end;
            function Add(S: string): Integer;
            var StrP: ^string; ObjP: ^Pointer;
            begin
              if Self.FCount = Self.FCapacity then Self.Grow;
              StrP := Self.FStrings + Self.FCount * SizeOf(string);
              ObjP := Self.FObjects + Self.FCount * SizeOf(Pointer);
              StrP^ := S; ObjP^ := nil;
              Result := Self.FCount; Self.FCount := Self.FCount + 1
            end;
            function Get(AIndex: Integer): string;
            var Ptr: ^string;
            begin
              Ptr := Self.FStrings + AIndex * SizeOf(string); Result := Ptr^
            end;
            property Count: Integer read FCount;
          end;
        var OL: TObjectList; SL: TStringList;
        begin
          OL := TObjectList.Create;
          OL.Add(nil); OL.Add(nil);
          SL := TStringList.Create;
          SL.Add('hello'); SL.Add('world');
          WriteLn(OL.Count);
          WriteLn(SL.Get(0))
        end.
        ''';

procedure TE2ETests.TestRun_TObjectList_AddGetCount;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTObjectListAddGetCount, Output, RCode));
  AssertEquals('count=3', '3', Trim(Copy(Output, 0, Pos(#10, Output))));
end;

procedure TE2ETests.TestRun_TObjectList_Delete;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTObjectListDelete, Output, RCode));
  AssertEquals('count after delete=2', '2', Trim(Output));
end;

procedure TE2ETests.TestRun_TStringList_AddGet;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTStringListAddGet, Output, RCode));
  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Output);
    AssertEquals('count=2',   '2',     Lines.Strings[0]);
    AssertEquals('get(0)',    'hello', Lines.Strings[1]);
    AssertEquals('get(1)',    'world', Lines.Strings[2]);
  finally
    Lines.Free;
  end;
end;

procedure TE2ETests.TestRun_TStringList_Find_Sorted;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTStringListFindSorted, Output, RCode));
  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Output);
    AssertEquals('found=1 (true)',  '1', Lines.Strings[0]);
    AssertEquals('idx=1',           '1', Lines.Strings[1]);
    AssertEquals('not found=0',     '0', Lines.Strings[2]);
  finally
    Lines.Free;
  end;
end;

procedure TE2ETests.TestRun_Collections_Valgrind;
var
  OK:  Boolean;
  Log: string;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  if RunProc('valgrind', ['--version'], Log, True) <> 0 then
  begin
    Ignore('valgrind not installed');
    Exit;
  end;
  OK := RunUnderValgrind(SrcCollectionsValgrind, Log);
  if not OK then
  begin
    if Log = '' then Log := '(valgrind produced no output)';
    Fail('Collections Valgrind check failed:' + #10 + Log);
  end;
end;

{ ------------------------------------------------------------------ }
{ Self-hosting e2e tests                                              }
{ ------------------------------------------------------------------ }

const
  SrcParamStrPrint =
    '''
        program P;
        begin
          WriteLn(ParamStr(1))
        end.
        ''';

  SrcParamCountPrint =
    '''
        program P;
        begin
          WriteLn(ParamCount)
        end.
        ''';

  SrcReadWriteFile =
    '''
        program P;
        var S: string;
        begin
          WriteFile(ParamStr(1), 'hello file');
          S := ReadFile(ParamStr(1));
          WriteLn(S)
        end.
        ''';

  SrcFileExistsTest =
    '''
        program P;
        begin
          WriteLn(FileExists(ParamStr(1)));
          WriteLn(FileExists('__no_such_file_xyz__'))
        end.
        ''';

  SrcGetEnvVarTest =
    '''
        program P;
        var S: string;
        begin
          S := GetEnvVar('BLAISE_TEST_VAR');
          WriteLn(S)
        end.
        ''';

  SrcHaltTest =
    '''
        program P;
        begin
          WriteLn(42);
          Halt(7)
        end.
        ''';

  SrcMultiTypeBlock =
    '''
        program P;
        type
          TCounter = class
            FN: Integer;
            procedure Inc;
            begin Self.FN := Self.FN + 1 end;
            property Value: Integer read FN;
          end;
        var N: Integer;
        type
          TDoubler = class
            function Double(X: Integer): Integer;
            begin Result := X * 2 end;
          end;
        var
          C: TCounter;
          D: TDoubler;
        begin
          C := TCounter.Create;
          D := TDoubler.Create;
          C.Inc; C.Inc; C.Inc;
          N := D.Double(C.Value);
          WriteLn(N)
        end.
        ''';

procedure TE2ETests.TestRun_ParamStr_PrintsArg;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcParamStrPrint, Output, RCode, ['hello']));
  AssertEquals('ParamStr(1) = hello', 'hello', Trim(Output));
end;

procedure TE2ETests.TestRun_ParamCount_WithArgs;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcParamCountPrint, Output, RCode, ['a', 'b', 'c']));
  AssertEquals('ParamCount = 3', '3', Trim(Output));
end;

procedure TE2ETests.TestRun_ReadWriteFile_RoundTrip;
var
  Output: string;
  RCode:  Integer;
  TmpFile: string;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  TmpFile := GetTempFileName('', 'blaise_rwtest');
  try
    AssertTrue('compile+run',
      CompileAndRun(SrcReadWriteFile, Output, RCode, [TmpFile]));
    AssertEquals('ReadFile content', 'hello file', Trim(Output));
  finally
    if FileExists(TmpFile) then DeleteFile(TmpFile);
  end;
end;

procedure TE2ETests.TestRun_FileExists_TrueAndFalse;
var
  Output: string;
  RCode:  Integer;
  TmpFile: string;
  Lines:   TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  TmpFile := GetTempFileName('', 'blaise_fe_test');
  { Create the file so it exists }
  Lines := TStringList.Create;
  Lines.Add('x');
  Lines.SaveToFile(TmpFile);
  Lines.Free;
  try
    AssertTrue('compile+run',
      CompileAndRun(SrcFileExistsTest, Output, RCode, [TmpFile]));
    Lines := TStringList.Create;
    try
      Lines.Text := Trim(Output);
      AssertEquals('existing file = 1',     '1', Lines.Strings[0]);
      AssertEquals('missing file = 0',      '0', Lines.Strings[1]);
    finally
      Lines.Free;
    end;
  finally
    if FileExists(TmpFile) then DeleteFile(TmpFile);
  end;
end;

procedure TE2ETests.TestRun_GetEnvVar_Path;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcGetEnvVarTest, Output, RCode));
  AssertTrue('GetEnvVar(BLAISE_TEST_VAR) returns empty when unset',
    Trim(Output) = '');
end;

procedure TE2ETests.TestRun_Halt_ExitCode;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  CompileAndRun(SrcHaltTest, Output, RCode);
  AssertEquals('WriteLn before Halt', '42', Trim(Output));
  AssertEquals('Halt(7) sets exit code', 7, RCode);
end;

procedure TE2ETests.TestRun_MultiTypeBlock_BothClassesWork;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcMultiTypeBlock, Output, RCode));
  AssertEquals('TCounter(3).Double = 6', '6', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ case / enum e2e tests                                               }
{ ------------------------------------------------------------------ }

const
  SrcCaseInt =
    '''
        program P;
        var N: Integer;
        begin
          N := 2;
          case N of
            1: WriteLn(11);
            2: WriteLn(22);
            3: WriteLn(33)
          end
        end.
        ''';

  SrcCaseElse =
    '''
        program P;
        var N: Integer;
        begin
          N := 7;
          case N of
            1: WriteLn(1);
            2: WriteLn(2)
          else
            WriteLn(99)
          end
        end.
        ''';

  SrcEnumOrdinal =
    '''
        program P;
        type
          TColor = (cRed, cGreen, cBlue);
        var C: TColor;
        begin
          C := cRed;   WriteLn(C);
          C := cGreen; WriteLn(C);
          C := cBlue;  WriteLn(C)
        end.
        ''';

  SrcEnumCase =
    '''
        program P;
        type
          TDir = (dNorth, dSouth, dEast, dWest);
        var D: TDir;
        begin
          D := dEast;
          case D of
            dNorth: WriteLn(0);
            dSouth: WriteLn(1);
            dEast:  WriteLn(2);
            dWest:  WriteLn(3)
          end
        end.
        ''';

procedure TE2ETests.TestRun_Case_IntegerBranch;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcCaseInt, Output, RCode));
  AssertEquals('case N=2 → 22', '22', Trim(Output));
end;

procedure TE2ETests.TestRun_Case_ElseBranch;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcCaseElse, Output, RCode));
  AssertEquals('case N=7 → else → 99', '99', Trim(Output));
end;

procedure TE2ETests.TestRun_Enum_OrdinalValues;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcEnumOrdinal, Output, RCode));
  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Output);
    AssertEquals('cRed=0',   '0', Lines.Strings[0]);
    AssertEquals('cGreen=1', '1', Lines.Strings[1]);
    AssertEquals('cBlue=2',  '2', Lines.Strings[2]);
  finally
    Lines.Free;
  end;
end;

procedure TE2ETests.TestRun_Enum_InCase;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcEnumCase, Output, RCode));
  AssertEquals('dEast=2', '2', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ File path manipulation (step 11)                                    }
{ ------------------------------------------------------------------ }

const
  SrcChangeFileExtTest =
    '''
        program P;
        begin
          WriteLn(ChangeFileExt('test.pas', '.bak'));
          WriteLn(ChangeFileExt('noext', '.o'));
          WriteLn(ChangeFileExt('a.b.c', ''))
        end.
        ''';

  SrcExtractFileNameTest =
    '''
        program P;
        begin
          WriteLn(ExtractFileName('/usr/bin/ls'));
          WriteLn(ExtractFileName('ls'))
        end.
        ''';

  SrcExtractFilePathTest =
    '''
        program P;
        begin
          WriteLn(ExtractFilePath('/usr/bin/ls'));
          WriteLn('[' + ExtractFilePath('ls') + ']')
        end.
        ''';

  SrcIncludeTrailingPathDelimiterTest =
    '''
        program P;
        begin
          WriteLn(IncludeTrailingPathDelimiter('/usr/bin'));
          WriteLn(IncludeTrailingPathDelimiter('/usr/bin/'))
        end.
        ''';

  { Step 8: process built-ins — run 'echo' and capture output }
  SrcProcessBuiltinsCapture =
    '''
        program P;
        var
          H:     Pointer;
          Output: string;
          Chunk:  string;
        begin
          H := ProcessCreate;
          ProcessSetExe(H, 'echo');
          ProcessAddArg(H, 'hello from process');
          ProcessExecute(H);
          Output := '';
          Chunk := ProcessReadOutput(H);
          while Chunk <> '' do
          begin
            Output := Output + Chunk;
            Chunk := ProcessReadOutput(H)
          end;
          ProcessWaitOnExit(H);
          ProcessFree(H);
          Write(Output)
        end.
        ''';

  SrcProcessBuiltinsExitCode =
    '''
        program P;
        var
          H:    Pointer;
          Code: Integer;
          Chunk: string;
        begin
          H := ProcessCreate;
          ProcessSetExe(H, 'true');
          ProcessExecute(H);
          Chunk := ProcessReadOutput(H);
          while Chunk <> '' do
            Chunk := ProcessReadOutput(H);
          ProcessWaitOnExit(H);
          Code := ProcessExitCode(H);
          ProcessFree(H);
          WriteLn(IntToStr(Code))
        end.
        ''';

procedure TE2ETests.TestRun_ChangeFileExt_ChangesExtension;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcChangeFileExtTest, Output, RCode));
  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Output);
    AssertEquals('test.pas→.bak', 'test.bak', Lines.Strings[0]);
    AssertEquals('noext→.o',      'noext.o',  Lines.Strings[1]);
    AssertEquals('a.b.c→empty',   'a.b',      Lines.Strings[2]);
  finally
    Lines.Free;
  end;
end;

procedure TE2ETests.TestRun_ExtractFileName_ReturnsName;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcExtractFileNameTest, Output, RCode));
  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Output);
    AssertEquals('/usr/bin/ls → ls', 'ls', Lines.Strings[0]);
    AssertEquals('ls → ls',          'ls', Lines.Strings[1]);
  finally
    Lines.Free;
  end;
end;

procedure TE2ETests.TestRun_ExtractFilePath_ReturnsDir;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcExtractFilePathTest, Output, RCode));
  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Output);
    AssertEquals('/usr/bin/ls → /usr/bin/', '/usr/bin/', Lines.Strings[0]);
    AssertEquals('ls → empty',              '[]',        Lines.Strings[1]);
  finally
    Lines.Free;
  end;
end;

procedure TE2ETests.TestRun_IncludeTrailingPathDelimiter_AppendsSlash;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcIncludeTrailingPathDelimiterTest, Output, RCode));
  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Output);
    AssertEquals('/usr/bin → /usr/bin/',   '/usr/bin/', Lines.Strings[0]);
    AssertEquals('/usr/bin/ unchanged',    '/usr/bin/', Lines.Strings[1]);
  finally
    Lines.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Step 8: process management built-ins                                }
{ ------------------------------------------------------------------ }

procedure TE2ETests.TestRun_ProcessBuiltins_CapturesOutput;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcProcessBuiltinsCapture, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('captured echo output', 'hello from process', Trim(Output));
end;

procedure TE2ETests.TestRun_ProcessBuiltins_ExitCode;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcProcessBuiltinsExitCode, Output, RCode));
  AssertEquals('program exit code 0', 0, RCode);
  AssertEquals('true exits with 0', '0', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Typed except handlers — shared source base                         }
{ ------------------------------------------------------------------ }

const
  SrcExcBase2 =
    '''
        program P;
        type
          Exception = class
            FMessage: string;
            property Message: string read FMessage;
          end;
          EFoo = class(Exception) end;
          EBar = class(EFoo) end;
        ''';

  SrcTypedExceptCorrect =
    SrcExcBase2 +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            raise EFoo.Create
          except
            on E: EFoo do X := 42;
            on E: Exception do X := 1
          end;
          WriteLn(X)
        end.
        ''';

  SrcTypedExceptSubclass =
    SrcExcBase2 +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            raise EBar.Create
          except
            on E: EFoo do X := 7
          end;
          WriteLn(X)
        end.
        ''';

  SrcTypedExceptElseRun =
    SrcExcBase2 +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            raise EFoo.Create
          except
            on E: EBar do X := 9
            else X := 5
          end;
          WriteLn(X)
        end.
        ''';

  SrcTypedExceptBareRaise =
    SrcExcBase2 +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            try
              raise EFoo.Create
            except
              on E: EFoo do
              begin
                X := 1;
                raise
              end
            end
          except
            on E: EFoo do X := 2
          end;
          WriteLn(X)
        end.
        ''';

  SrcTypedExceptUnmatched =
    SrcExcBase2 +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            try
              raise EFoo.Create
            except
              on E: EBar do X := 9
            end
          except
            on E: EFoo do X := 3
          end;
          WriteLn(X)
        end.
        ''';

{ ------------------------------------------------------------------ }
{ Typed except handler — E2E tests                                   }
{ ------------------------------------------------------------------ }

procedure TE2ETests.TestRun_TypedExcept_CorrectHandlerMatched;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptCorrect, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('EFoo handler ran', '42', Trim(Output));
end;

procedure TE2ETests.TestRun_TypedExcept_SubclassMatchesParentHandler;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptSubclass, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('EBar matches EFoo handler', '7', Trim(Output));
end;

procedure TE2ETests.TestRun_TypedExcept_UnmatchedReraises;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptUnmatched, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('unmatched inner re-raises to outer', '3', Trim(Output));
end;

procedure TE2ETests.TestRun_TypedExcept_BareRaisePropagatesToOuter;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptBareRaise, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('bare raise propagated to outer handler', '2', Trim(Output));
end;

procedure TE2ETests.TestRun_TypedExcept_ElseBodyRunsWhenNoMatch;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptElseRun, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('else body ran when no handler matched', '5', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Built-in TObject.ToString                                           }
{ ------------------------------------------------------------------ }

const
  SrcToStringDefault =
    'program P;'                              + LE +
    'type'                                    + LE +
    '  TFoo = class end;'                     + LE +
    '  TBar = class(TFoo) end;'               + LE +
    'var F: TFoo; B: TBar;'                   + LE +
    'begin'                                   + LE +
    '  F := TFoo.Create;'                     + LE +
    '  WriteLn(F.ToString);'                  + LE +
    '  B := TBar.Create;'                     + LE +
    '  WriteLn(B.ToString)'                   + LE +
    'end.';

  SrcToStringOverride =
    'program P;'                                          + LE +
    'type'                                                + LE +
    '  TFoo = class'                                      + LE +
    '    function ToString: string; override;'            + LE +
    '  end;'                                              + LE +
    '  TBar = class(TFoo)'                                + LE +
    '    function ToString: string; override;'            + LE +
    '  end;'                                              + LE +
    '  function TFoo.ToString: string;'                   + LE +
    '  begin Result := ''foo!'' end;'                     + LE +
    '  function TBar.ToString: string;'                   + LE +
    '  begin Result := ''bar!'' end;'                     + LE +
    'var F: TFoo; B: TFoo;'                               + LE +
    'begin'                                               + LE +
    '  F := TFoo.Create;'                                 + LE +
    '  WriteLn(F.ToString);'                              + LE +
    '  B := TBar.Create;'                                 + LE +
    '  WriteLn(B.ToString)'                               + LE +
    'end.';

  SrcToStringInheritedOverride =
    'program P;'                                          + LE +
    'type'                                                + LE +
    '  TFoo = class'                                      + LE +
    '    function ToString: string; override;'            + LE +
    '  end;'                                              + LE +
    '  TBar = class(TFoo) end;'                           + LE +
    '  function TFoo.ToString: string;'                   + LE +
    '  begin Result := ''foo override'' end;'             + LE +
    'var F: TFoo; B: TFoo;'                               + LE +
    'begin'                                               + LE +
    '  F := TFoo.Create;'                                 + LE +
    '  WriteLn(F.ToString);'                              + LE +
    '  B := TBar.Create;'                                 + LE +
    '  WriteLn(B.ToString)'                               + LE +
    'end.';

procedure TE2ETests.TestRun_ToString_DefaultReturnsClassName;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcToStringDefault, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('default ToString returns class name',
    'TFoo' + LE + 'TBar' + LE, Output);
end;

procedure TE2ETests.TestRun_ToString_OverrideDispatchedVirtually;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcToStringOverride, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('override reached through static base type',
    'foo!' + LE + 'bar!' + LE, Output);
end;

procedure TE2ETests.TestRun_ToString_InheritedOverrideStillReached;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcToStringInheritedOverride, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('inherited override still reached',
    'foo override' + LE + 'foo override' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ TObject.InheritsFrom                                                }
{ ------------------------------------------------------------------ }

const
  SrcInheritsFromBase =
    '''
        program P;
        type TBase = class end;
        var B: TBase;
        begin
          B := TBase.Create;
          if B.InheritsFrom(TBase) then
            WriteLn('yes')
          else
            WriteLn('no');
          B.Free;
        end.
        ''';

  SrcInheritsFromParent =
    '''
        program P;
        type TBase = class end;
             TChild = class(TBase) end;
        var C: TChild;
        begin
          C := TChild.Create;
          if C.InheritsFrom(TBase) then
            WriteLn('yes')
          else
            WriteLn('no');
          C.Free;
        end.
        ''';

  SrcInheritsFromGrandParent =
    '''
        program P;
        type TBase = class end;
             TChild = class(TBase) end;
             TGrandChild = class(TChild) end;
        var G: TGrandChild;
        begin
          G := TGrandChild.Create;
          if G.InheritsFrom(TBase) then
            WriteLn('yes')
          else
            WriteLn('no');
          G.Free;
        end.
        ''';

  SrcInheritsFromUnrelated =
    '''
        program P;
        type TBase = class end;
             TUnrelated = class end;
        var B: TBase;
        begin
          B := TBase.Create;
          if B.InheritsFrom(TUnrelated) then
            WriteLn('yes')
          else
            WriteLn('no');
          B.Free;
        end.
        ''';

  SrcInheritsFromReverse =
    '''
        program P;
        type TBase = class end;
             TChild = class(TBase) end;
        var B: TBase;
        begin
          B := TBase.Create;
          if B.InheritsFrom(TChild) then
            WriteLn('yes')
          else
            WriteLn('no');
          B.Free;
        end.
        ''';

  SrcInheritsFromClassType =
    '''
        program P;
        type TBase = class end;
             TChild = class(TBase) end;
        var C: TChild;
            CT: Pointer;
        begin
          C := TChild.Create;
          CT := C.ClassType;
          if CT.InheritsFrom(TBase) then
            WriteLn('yes')
          else
            WriteLn('no');
          C.Free;
        end.
        ''';

procedure TE2ETests.TestRun_InheritsFrom_SameClass_ReturnsTrue;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInheritsFromBase, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('same class returns true', 'yes' + LE, Output);
end;

procedure TE2ETests.TestRun_InheritsFrom_Parent_ReturnsTrue;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInheritsFromParent, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('child inherits from parent', 'yes' + LE, Output);
end;

procedure TE2ETests.TestRun_InheritsFrom_GrandParent_ReturnsTrue;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInheritsFromGrandParent, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('grandchild inherits from base', 'yes' + LE, Output);
end;

procedure TE2ETests.TestRun_InheritsFrom_Unrelated_ReturnsFalse;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInheritsFromUnrelated, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('unrelated class returns false', 'no' + LE, Output);
end;

procedure TE2ETests.TestRun_InheritsFrom_Reverse_ReturnsFalse;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInheritsFromReverse, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('parent does not inherit from child', 'no' + LE, Output);
end;

procedure TE2ETests.TestRun_InheritsFrom_ClassType_Works;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInheritsFromClassType, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('ClassType.InheritsFrom works', 'yes' + LE, Output);
end;

{ ================================================================== }
{ OS utility builtins (step 2a)                                      }
{ ================================================================== }

const
  SrcGetProcessID =
    '''
        program P;
        begin
          WriteLn(GetProcessID)
        end.
        ''';

  SrcDirectoryExists =
    '''
        program P;
        begin
          WriteLn(DirectoryExists('/tmp'));
          WriteLn(DirectoryExists('/__no_such_dir__'))
        end.
        ''';

  SrcGetTempDir =
    '''
        program P;
        begin
          WriteLn(GetTempDir)
        end.
        ''';

  SrcForceDirectories =
    '''
        program P;
        var Dir: string;
        begin
          Dir := ParamStr(1);
          WriteLn(ForceDirectories(Dir));
          WriteLn(DirectoryExists(Dir))
        end.
        ''';

  SrcSleepTest =
    '''
        program P;
        begin
          Sleep(1);
          WriteLn('ok')
        end.
        ''';

procedure TE2ETests.TestRun_GetProcessID_ReturnsNonZero;
var
  Output: string;
  RCode:  Integer;
  PID:    Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcGetProcessID, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  PID := StrToInt(Trim(Output));
  AssertTrue('PID > 0', PID > 0);
end;

procedure TE2ETests.TestRun_DirectoryExists_TrueAndFalse;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcDirectoryExists, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  Lines := TStringList.Create;
  try
    Lines.Text := Trim(Output);
    AssertEquals('/tmp exists = 1',           '1', Lines.Strings[0]);
    AssertEquals('missing dir = 0',           '0', Lines.Strings[1]);
  finally
    Lines.Free;
  end;
end;

procedure TE2ETests.TestRun_GetTempDir_ReturnsPath;
var
  Output: string;
  RCode:  Integer;
  Dir:    string;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcGetTempDir, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  Dir := Trim(Output);
  AssertTrue('dir is non-empty', Length(Dir) > 0);
  AssertTrue('dir ends with /', Dir[Length(Dir) - 1] = '/');
end;

procedure TE2ETests.TestRun_ForceDirectories_CreatesTree;
var
  Output: string;
  RCode:  Integer;
  Lines:  TStringList;
  Dir:    string;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  Dir := IncludeTrailingPathDelimiter(GetTempDir) +
         'blaise_test_' + IntToStr(GetProcessID) + '/a/b/c';
  try
    AssertTrue('compile+run',
      CompileAndRun(SrcForceDirectories, Output, RCode, [Dir]));
    AssertEquals('exit code 0', 0, RCode);
    Lines := TStringList.Create;
    try
      Lines.Text := Trim(Output);
      AssertEquals('ForceDirectories returned 1', '1', Lines.Strings[0]);
      AssertEquals('DirectoryExists returned 1',  '1', Lines.Strings[1]);
    finally
      Lines.Free;
    end;
  finally
    { Clean up the test directory tree }
    RemoveDir(Dir);
    RemoveDir(ExtractFilePath(ExcludeTrailingPathDelimiter(Dir)));
    RemoveDir(ExtractFilePath(ExcludeTrailingPathDelimiter(
      ExtractFilePath(ExcludeTrailingPathDelimiter(Dir)))));
    RemoveDir(ExtractFilePath(ExcludeTrailingPathDelimiter(
      ExtractFilePath(ExcludeTrailingPathDelimiter(
        ExtractFilePath(ExcludeTrailingPathDelimiter(Dir)))))));
  end;
end;

procedure TE2ETests.TestRun_Sleep_DoesNotCrash;
var
  Output: string;
  RCode:  Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcSleepTest, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('output is ok', 'ok', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ for..in e2e tests                                                    }
{ ------------------------------------------------------------------ }

const
  { Iterates 'Hi' with a local Byte var — the exact case that triggered
    the promoted-scalar storew bug. Byte is always promoted to a QBE
    register; storew to a register is a QBE error. }
  SrcForInStringByte =
    'program P;'                                        + #10 +
    'var'                                               + #10 +
    '  S: string;'                                      + #10 +
    '  B: Byte;'                                        + #10 +
    'begin'                                             + #10 +
    '  S := ''Hi'';'                                    + #10 +
    '  for B in S do'                                   + #10 +
    '    WriteLn(B)'                                    + #10 +
    'end.';

  { Same program with Integer loop var — also promoted, exercises the
    same IsPromoted path via a different type. }
  SrcForInStringInteger =
    'program P;'                                        + #10 +
    'var'                                               + #10 +
    '  S: string;'                                      + #10 +
    '  I: Integer;'                                     + #10 +
    'begin'                                             + #10 +
    '  S := ''Hi'';'                                    + #10 +
    '  for I in S do'                                   + #10 +
    '    WriteLn(I)'                                    + #10 +
    'end.';

  { Static array iteration with a local Integer element var. }
  SrcForInArrayInteger =
    'program P;'                                        + #10 +
    'var'                                               + #10 +
    '  A: array[0..2] of Integer;'                      + #10 +
    '  X: Integer;'                                     + #10 +
    'begin'                                             + #10 +
    '  A[0] := 10;'                                     + #10 +
    '  A[1] := 20;'                                     + #10 +
    '  A[2] := 30;'                                     + #10 +
    '  for X in A do'                                   + #10 +
    '    WriteLn(X)'                                    + #10 +
    'end.';

  { Class enumerator protocol: a minimal range enumerator that yields
    3, 4, 5 so the expected output is deterministic. }
  SrcForInClassEnum =
    'program P;'                                                  + #10 +
    'type'                                                        + #10 +
    '  TRangeEnum = class'                                        + #10 +
    '    FCurrent: Integer;'                                      + #10 +
    '    FLast: Integer;'                                         + #10 +
    '    constructor Create(AFirst, ALast: Integer);'             + #10 +
    '    function MoveNext: Boolean;'                             + #10 +
    '    function GetCurrent: Integer;'                           + #10 +
    '    property Current: Integer read GetCurrent;'              + #10 +
    '  end;'                                                      + #10 +
    '  TRange = class'                                            + #10 +
    '    FFirst: Integer;'                                        + #10 +
    '    FLast: Integer;'                                         + #10 +
    '    constructor Create(AFirst, ALast: Integer);'             + #10 +
    '    function GetEnumerator: TRangeEnum;'                     + #10 +
    '  end;'                                                      + #10 +
    'constructor TRangeEnum.Create(AFirst, ALast: Integer);'      + #10 +
    'begin'                                                       + #10 +
    '  FCurrent := AFirst - 1;'                                   + #10 +
    '  FLast := ALast;'                                           + #10 +
    'end;'                                                        + #10 +
    'function TRangeEnum.MoveNext: Boolean;'                      + #10 +
    'begin'                                                       + #10 +
    '  FCurrent := FCurrent + 1;'                                 + #10 +
    '  Result := FCurrent <= FLast;'                              + #10 +
    'end;'                                                        + #10 +
    'function TRangeEnum.GetCurrent: Integer;'                    + #10 +
    'begin'                                                       + #10 +
    '  Result := FCurrent;'                                       + #10 +
    'end;'                                                        + #10 +
    'constructor TRange.Create(AFirst, ALast: Integer);'          + #10 +
    'begin'                                                       + #10 +
    '  FFirst := AFirst;'                                         + #10 +
    '  FLast := ALast;'                                           + #10 +
    'end;'                                                        + #10 +
    'function TRange.GetEnumerator: TRangeEnum;'                  + #10 +
    'begin'                                                       + #10 +
    '  Result := TRangeEnum.Create(FFirst, FLast);'               + #10 +
    'end;'                                                        + #10 +
    'var'                                                         + #10 +
    '  R: TRange;'                                                + #10 +
    '  N: Integer;'                                               + #10 +
    'begin'                                                       + #10 +
    '  R := TRange.Create(3, 5);'                                 + #10 +
    '  for N in R do'                                             + #10 +
    '    WriteLn(N);'                                             + #10 +
    '  R.Free;'                                                   + #10 +
    'end.';

procedure TE2ETests.TestRun_ForIn_String_ByteVar_PrintsBytes;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcForInStringByte, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { 'H' = 72, 'i' = 105 }
  AssertEquals('bytes of ''Hi''', '72' + LE + '105' + LE, Output);
end;

procedure TE2ETests.TestRun_ForIn_String_IntegerVar_PrintsBytes;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcForInStringInteger, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('bytes of ''Hi'' via Integer var', '72' + LE + '105' + LE, Output);
end;

procedure TE2ETests.TestRun_ForIn_Array_Integer_PrintsElements;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcForInArrayInteger, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('array elements 10 20 30',
    '10' + LE + '20' + LE + '30' + LE, Output);
end;

procedure TE2ETests.TestRun_ForIn_ClassEnumerator_PrintsElements;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcForInClassEnum, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('range 3..5', '3' + LE + '4' + LE + '5' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Control flow e2e tests                                               }
{ ------------------------------------------------------------------ }

const
  SrcForUp =
    'program P;'                        + #10 +
    'var I: Integer;'                   + #10 +
    'begin'                             + #10 +
    '  for I := 1 to 3 do'             + #10 +
    '    WriteLn(I)'                    + #10 +
    'end.';

  SrcForDown =
    'program P;'                        + #10 +
    'var I: Integer;'                   + #10 +
    'begin'                             + #10 +
    '  for I := 3 downto 1 do'         + #10 +
    '    WriteLn(I)'                    + #10 +
    'end.';

  SrcWhile =
    'program P;'                        + #10 +
    'var I: Integer;'                   + #10 +
    'begin'                             + #10 +
    '  I := 1;'                         + #10 +
    '  while I <= 3 do'                 + #10 +
    '  begin'                           + #10 +
    '    WriteLn(I);'                   + #10 +
    '    I := I + 1'                    + #10 +
    '  end'                             + #10 +
    'end.';

  SrcRepeat =
    'program P;'                        + #10 +
    'var I: Integer;'                   + #10 +
    'begin'                             + #10 +
    '  I := 1;'                         + #10 +
    '  repeat'                          + #10 +
    '    WriteLn(I);'                   + #10 +
    '    I := I + 1'                    + #10 +
    '  until I > 3'                     + #10 +
    'end.';

  SrcForBreakE2E =
    'program P;'                        + #10 +
    'var I: Integer;'                   + #10 +
    'begin'                             + #10 +
    '  for I := 1 to 10 do'            + #10 +
    '  begin'                           + #10 +
    '    if I = 4 then break;'          + #10 +
    '    WriteLn(I)'                    + #10 +
    '  end'                             + #10 +
    'end.';

  SrcForContinue =
    'program P;'                        + #10 +
    'var I: Integer;'                   + #10 +
    'begin'                             + #10 +
    '  for I := 1 to 5 do'             + #10 +
    '  begin'                           + #10 +
    '    if I = 3 then continue;'       + #10 +
    '    WriteLn(I)'                    + #10 +
    '  end'                             + #10 +
    'end.';

  SrcNestedFor =
    'program P;'                        + #10 +
    'var I, J: Integer;'                + #10 +
    'begin'                             + #10 +
    '  for I := 1 to 2 do'             + #10 +
    '    for J := 1 to 2 do'           + #10 +
    '      WriteLn(I * 10 + J)'        + #10 +
    'end.';

procedure TE2ETests.TestRun_For_Upward_PrintsRange;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcForUp, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('1 2 3', '1' + LE + '2' + LE + '3' + LE, Output);
end;

procedure TE2ETests.TestRun_For_Downto_PrintsRange;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcForDown, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('3 2 1', '3' + LE + '2' + LE + '1' + LE, Output);
end;

procedure TE2ETests.TestRun_While_PrintsRange;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcWhile, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('1 2 3', '1' + LE + '2' + LE + '3' + LE, Output);
end;

procedure TE2ETests.TestRun_Repeat_PrintsRange;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcRepeat, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('1 2 3', '1' + LE + '2' + LE + '3' + LE, Output);
end;

procedure TE2ETests.TestRun_For_BreakExitsEarly;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcForBreakE2E, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('1 2 3', '1' + LE + '2' + LE + '3' + LE, Output);
end;

procedure TE2ETests.TestRun_For_ContinueSkipsIteration;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcForContinue, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('1 2 4 5', '1' + LE + '2' + LE + '4' + LE + '5' + LE, Output);
end;

procedure TE2ETests.TestRun_Nested_For_Loops;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcNestedFor, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('nested 2x2', '11' + LE + '12' + LE + '21' + LE + '22' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Record e2e tests                                                     }
{ ------------------------------------------------------------------ }

const
  SrcRecordFieldRW =
    'program P;'                                    + #10 +
    'type TPoint = record X, Y: Integer; end;'      + #10 +
    'var P1: TPoint;'                               + #10 +
    'begin'                                         + #10 +
    '  P1.X := 3;'                                  + #10 +
    '  P1.Y := 7;'                                  + #10 +
    '  WriteLn(P1.X + P1.Y)'                        + #10 +
    'end.';

  SrcRecordPassByValue =
    'program P;'                                    + #10 +
    'type TPoint = record X, Y: Integer; end;'      + #10 +
    'procedure Print(Pt: TPoint);'                  + #10 +
    'begin'                                         + #10 +
    '  WriteLn(Pt.X);'                              + #10 +
    '  WriteLn(Pt.Y)'                               + #10 +
    'end;'                                          + #10 +
    'var P1: TPoint;'                               + #10 +
    'begin'                                         + #10 +
    '  P1.X := 5;'                                  + #10 +
    '  P1.Y := 9;'                                  + #10 +
    '  Print(P1)'                                   + #10 +
    'end.';

  SrcRecordPassByVar =
    'program P;'                                    + #10 +
    'type TPoint = record X, Y: Integer; end;'      + #10 +
    'procedure Scale(var Pt: TPoint);'              + #10 +
    'begin'                                         + #10 +
    '  Pt.X := Pt.X * 2;'                           + #10 +
    '  Pt.Y := Pt.Y * 2'                            + #10 +
    'end;'                                          + #10 +
    'var P1: TPoint;'                               + #10 +
    'begin'                                         + #10 +
    '  P1.X := 3;'                                  + #10 +
    '  P1.Y := 4;'                                  + #10 +
    '  Scale(P1);'                                  + #10 +
    '  WriteLn(P1.X);'                              + #10 +
    '  WriteLn(P1.Y)'                               + #10 +
    'end.';

  SrcRecordStringField =
    'program P;'                                    + #10 +
    'type TName = record First, Last: string; end;' + #10 +
    'var N: TName;'                                 + #10 +
    'begin'                                         + #10 +
    '  N.First := ''Ada'';'                         + #10 +
    '  N.Last  := ''Lovelace'';'                    + #10 +
    '  WriteLn(N.First + '' '' + N.Last)'           + #10 +
    'end.';

  SrcRecordNested =
    'program P;'                                    + #10 +
    'type'                                          + #10 +
    '  TInner = record V: Integer; end;'            + #10 +
    '  TOuter = record A, B: TInner; end;'          + #10 +
    'var O: TOuter;'                                + #10 +
    'begin'                                         + #10 +
    '  O.A.V := 10;'                                + #10 +
    '  O.B.V := 20;'                                + #10 +
    '  WriteLn(O.A.V + O.B.V)'                      + #10 +
    'end.';

procedure TE2ETests.TestRun_Record_FieldReadWrite;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcRecordFieldRW, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('3 + 7 = 10', '10' + LE, Output);
end;

procedure TE2ETests.TestRun_Record_PassByValue;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcRecordPassByValue, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('5 then 9', '5' + LE + '9' + LE, Output);
end;

procedure TE2ETests.TestRun_Record_PassByVar;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcRecordPassByVar, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('6 then 8', '6' + LE + '8' + LE, Output);
end;

procedure TE2ETests.TestRun_Record_StringField_ARC;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcRecordStringField, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Ada Lovelace', 'Ada Lovelace' + LE, Output);
end;

procedure TE2ETests.TestRun_Record_NestedRecord;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcRecordNested, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('10 + 20 = 30', '30' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Pointer e2e tests                                                    }
{ ------------------------------------------------------------------ }

const
  SrcGetMemWriteRead =
    'program P;'                                    + #10 +
    'var P1: ^Integer;'                             + #10 +
    'begin'                                         + #10 +
    '  P1 := GetMem(4);'                            + #10 +
    '  P1^ := 42;'                                  + #10 +
    '  WriteLn(P1^);'                               + #10 +
    '  FreeMem(P1)'                                 + #10 +
    'end.';

  SrcTypedPointerDeref =
    'program P;'                                    + #10 +
    'var'                                           + #10 +
    '  A: Integer;'                                 + #10 +
    '  P1: ^Integer;'                               + #10 +
    'begin'                                         + #10 +
    '  A  := 99;'                                   + #10 +
    '  P1 := @A;'                                   + #10 +
    '  WriteLn(P1^)'                                + #10 +
    'end.';

  SrcPointerNilCheck =
    'program P;'                                    + #10 +
    'var P1: ^Integer;'                             + #10 +
    'begin'                                         + #10 +
    '  P1 := nil;'                                  + #10 +
    '  if P1 = nil then'                            + #10 +
    '    WriteLn(''nil'')'                          + #10 +
    '  else'                                        + #10 +
    '    WriteLn(''not nil'')'                      + #10 +
    'end.';

procedure TE2ETests.TestRun_Pointer_GetMem_WriteRead_FreeMem;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcGetMemWriteRead, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('42', '42' + LE, Output);
end;

procedure TE2ETests.TestRun_Pointer_TypedPointer_Deref;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedPointerDeref, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('99', '99' + LE, Output);
end;

procedure TE2ETests.TestRun_Pointer_NilCheck;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcPointerNilCheck, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('nil', 'nil' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Text block e2e tests                                                 }
{ ------------------------------------------------------------------ }

const
  SrcTextBlockBasic =
    'program P;'                                    + #10 +
    'var S: string;'                                + #10 +
    'begin'                                         + #10 +
    '  S := '''''''                                 + #10 +
    '  hello'                                       + #10 +
    '  '''''';'                                     + #10 +
    '  WriteLn(S)'                                  + #10 +
    'end.';

  SrcTextBlockIndent =
    'program P;'                                    + #10 +
    'var S: string;'                                + #10 +
    'begin'                                         + #10 +
    '  S := '''''''                                 + #10 +
    '    line1'                                     + #10 +
    '    line2'                                     + #10 +
    '    '''''';'                                   + #10 +
    '  WriteLn(Length(S))'                          + #10 +
    'end.';

procedure TE2ETests.TestRun_TextBlock_BasicContent;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTextBlockBasic, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { Text block content is 'hello' + LF (the newline before closing ''');
    WriteLn adds a second LF, so output is hello+LF+LF. }
  AssertEquals('hello+lf', 'hello' + LE + LE, Output);
end;

procedure TE2ETests.TestRun_TextBlock_IndentStripped;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTextBlockIndent, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { 'line1' + LF + 'line2' + LF = 12 chars after indent strip }
  AssertEquals('length 12', '12' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Constant e2e tests                                                   }
{ ------------------------------------------------------------------ }

const
  SrcConstInt =
    'program P;'                    + #10 +
    'const MaxVal = 100;'           + #10 +
    'var X: Integer;'               + #10 +
    'begin'                         + #10 +
    '  X := MaxVal + 1;'            + #10 +
    '  WriteLn(X)'                  + #10 +
    'end.';

  SrcConstStr =
    'program P;'                          + #10 +
    'const Greeting = ''Hello'';'         + #10 +
    'begin'                               + #10 +
    '  WriteLn(Greeting)'                 + #10 +
    'end.';

  SrcConstNeg =
    'program P;'                    + #10 +
    'const MinVal = -10;'           + #10 +
    'var X: Integer;'               + #10 +
    'begin'                         + #10 +
    '  X := MinVal * 2;'            + #10 +
    '  WriteLn(X)'                  + #10 +
    'end.';

procedure TE2ETests.TestRun_Const_IntegerConst;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcConstInt, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('101', '101' + LE, Output);
end;

procedure TE2ETests.TestRun_Const_StringConst;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcConstStr, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Hello', 'Hello' + LE, Output);
end;

procedure TE2ETests.TestRun_Const_NegativeConst;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcConstNeg, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('-20', '-20' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Set e2e tests                                                        }
{ ------------------------------------------------------------------ }

const
  SrcSetIncludeExclude =
    'program P;'                                    + #10 +
    'type TColor = (Red, Green, Blue);'             + #10 +
    '     TColors = set of TColor;'                 + #10 +
    'var S: TColors;'                               + #10 +
    'begin'                                         + #10 +
    '  S := [];'                                    + #10 +
    '  Include(S, Red);'                            + #10 +
    '  Include(S, Blue);'                           + #10 +
    '  if Red in S then WriteLn(''red'');'          + #10 +
    '  if Green in S then WriteLn(''green'');'      + #10 +
    '  if Blue in S then WriteLn(''blue'');'        + #10 +
    '  Exclude(S, Red);'                            + #10 +
    '  if Red in S then WriteLn(''red2'')'          + #10 +
    'end.';

  SrcSetIn =
    'program P;'                                    + #10 +
    'type TDir = (North, South, East, West);'       + #10 +
    '     TDirs = set of TDir;'                     + #10 +
    'var Horizontal: TDirs;'                        + #10 +
    'begin'                                         + #10 +
    '  Horizontal := [East, West];'                 + #10 +
    '  if North in Horizontal then WriteLn(''N'');' + #10 +
    '  if East  in Horizontal then WriteLn(''E'');' + #10 +
    '  if West  in Horizontal then WriteLn(''W'')'  + #10 +
    'end.';

  SrcSetUnion =
    'program P;'                                    + #10 +
    'type TBit = (B0, B1, B2, B3);'                + #10 +
    '     TBits = set of TBit;'                     + #10 +
    'var A, B, C: TBits;'                           + #10 +
    'begin'                                         + #10 +
    '  A := [B0, B1];'                              + #10 +
    '  B := [B1, B2];'                              + #10 +
    '  C := A + B;'                                 + #10 +
    '  if B0 in C then WriteLn(''0'');'             + #10 +
    '  if B1 in C then WriteLn(''1'');'             + #10 +
    '  if B2 in C then WriteLn(''2'');'             + #10 +
    '  if B3 in C then WriteLn(''3'');'             + #10 +
    '  C := A * B;'                                 + #10 +
    '  if B1 in C then WriteLn(''inter1'')'         + #10 +
    'end.';

procedure TE2ETests.TestRun_Set_Include_Exclude;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcSetIncludeExclude, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('red blue', 'red' + LE + 'blue' + LE, Output);
end;

procedure TE2ETests.TestRun_Set_InOperator;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcSetIn, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('E W', 'E' + LE + 'W' + LE, Output);
end;

procedure TE2ETests.TestRun_Set_UnionIntersect;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcSetUnion, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('union 0 1 2, intersect 1',
    '0' + LE + '1' + LE + '2' + LE + 'inter1' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Procedural type e2e tests                                            }
{ ------------------------------------------------------------------ }

const
  SrcProcTypeVar =
    'program P;'                                    + #10 +
    'type TFn = function(X: Integer): Integer;'     + #10 +
    'function Twice(X: Integer): Integer;'          + #10 +
    'begin Result := X * 2 end;'                    + #10 +
    'var F: TFn;'                                   + #10 +
    'begin'                                         + #10 +
    '  F := @Twice;'                                + #10 +
    '  WriteLn(F(7))'                               + #10 +
    'end.';

  SrcProcTypeOfObject =
    'program P;'                                    + #10 +
    'type'                                          + #10 +
    '  TProc = procedure of object;'                + #10 +
    '  TFoo = class'                                + #10 +
    '    FVal: Integer;'                            + #10 +
    '    procedure Print;'                          + #10 +
    '  end;'                                        + #10 +
    'procedure TFoo.Print;'                         + #10 +
    'begin WriteLn(FVal) end;'                      + #10 +
    'var'                                           + #10 +
    '  Obj: TFoo;'                                  + #10 +
    '  M: TProc;'                                   + #10 +
    'begin'                                         + #10 +
    '  Obj := TFoo.Create;'                         + #10 +
    '  Obj.FVal := 55;'                             + #10 +
    '  M := @Obj.Print;'                            + #10 +
    '  M;'                                          + #10 +
    '  Obj.Free'                                    + #10 +
    'end.';

procedure TE2ETests.TestRun_ProcType_CallViaVariable;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcProcTypeVar, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('14', '14' + LE, Output);
end;

procedure TE2ETests.TestRun_ProcType_OfObject_Dispatch;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcProcTypeOfObject, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('55', '55' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Default parameter e2e tests                                          }
{ ------------------------------------------------------------------ }

const
  SrcDefaultParam =
    'program P;'                                            + #10 +
    'function Add(A: Integer; B: Integer = 10): Integer;'  + #10 +
    'begin Result := A + B end;'                           + #10 +
    'begin'                                                + #10 +
    '  WriteLn(Add(5));'                                   + #10 +
    '  WriteLn(Add(5, 20))'                                + #10 +
    'end.';

  SrcDefaultParamMulti =
    'program P;'                                                    + #10 +
    'function Greet(Name: string; Prefix: string = ''Hello'';'      + #10 +
    '               Suffix: string = ''!''): string;'               + #10 +
    'begin Result := Prefix + '' '' + Name + Suffix end;'          + #10 +
    'begin'                                                         + #10 +
    '  WriteLn(Greet(''World''));'                                   + #10 +
    '  WriteLn(Greet(''Ada'', ''Hi''))'                             + #10 +
    'end.';

procedure TE2ETests.TestRun_DefaultParam_OmitLast;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcDefaultParam, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('15 then 25', '15' + LE + '25' + LE, Output);
end;

procedure TE2ETests.TestRun_DefaultParam_OmitMultiple;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcDefaultParamMulti, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('greetings', 'Hello World!' + LE + 'Hi Ada!' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Open array e2e tests                                                 }
{ ------------------------------------------------------------------ }

const
  SrcOpenArraySum =
    'program P;'                                            + #10 +
    'function Sum(const A: array of Integer): Integer;'    + #10 +
    'var I: Integer;'                                      + #10 +
    'begin'                                                + #10 +
    '  Result := 0;'                                       + #10 +
    '  for I := 0 to High(A) do'                          + #10 +
    '    Result := Result + A[I]'                          + #10 +
    'end;'                                                 + #10 +
    'begin'                                                + #10 +
    '  WriteLn(Sum([1, 2, 3, 4, 5]))'                     + #10 +
    'end.';

  SrcOpenArrayHighLow =
    'program P;'                                            + #10 +
    'procedure PrintBounds(const A: array of Integer);'    + #10 +
    'begin'                                                + #10 +
    '  WriteLn(Low(A));'                                   + #10 +
    '  WriteLn(High(A))'                                   + #10 +
    'end;'                                                 + #10 +
    'begin'                                                + #10 +
    '  PrintBounds([10, 20, 30])'                          + #10 +
    'end.';

  SrcOpenArrayLength =
    '''
        program P;
        function Count(const A: array of Integer): Integer;
        begin
          Result := Length(A)
        end;
        begin
          WriteLn(Count([10, 20, 30]))
        end.
        ''';

procedure TE2ETests.TestRun_OpenArray_Sum;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcOpenArraySum, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('15', '15' + LE, Output);
end;

procedure TE2ETests.TestRun_OpenArray_HighLow;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcOpenArrayHighLow, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('low=0 high=2', '0' + LE + '2' + LE, Output);
end;

procedure TE2ETests.TestRun_OpenArray_Length;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcOpenArrayLength, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Length([10,20,30]) = 3', '3' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ var/const param e2e tests                                            }
{ ------------------------------------------------------------------ }

const
  SrcVarParamSwap =
    'program P;'                                    + #10 +
    'procedure Swap(var A, B: Integer);'            + #10 +
    'var T: Integer;'                               + #10 +
    'begin'                                         + #10 +
    '  T := A; A := B; B := T'                     + #10 +
    'end;'                                          + #10 +
    'var X, Y: Integer;'                            + #10 +
    'begin'                                         + #10 +
    '  X := 3; Y := 7;'                             + #10 +
    '  Swap(X, Y);'                                 + #10 +
    '  WriteLn(X);'                                 + #10 +
    '  WriteLn(Y)'                                  + #10 +
    'end.';

  SrcVarParamString =
    'program P;'                                    + #10 +
    'procedure Append(var S: string; const T: string);' + #10 +
    'begin'                                         + #10 +
    '  S := S + T'                                  + #10 +
    'end;'                                          + #10 +
    'var R: string;'                                + #10 +
    'begin'                                         + #10 +
    '  R := ''Hello'';'                             + #10 +
    '  Append(R, '' World'');'                      + #10 +
    '  WriteLn(R)'                                  + #10 +
    'end.';

  SrcConstParam =
    'program P;'                                    + #10 +
    'function Twice(const X: Integer): Integer;'    + #10 +
    'begin Result := X * 2 end;'                    + #10 +
    'begin'                                         + #10 +
    '  WriteLn(Twice(21))'                          + #10 +
    'end.';

procedure TE2ETests.TestRun_VarParam_SwapIntegers;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcVarParamSwap, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('7 then 3', '7' + LE + '3' + LE, Output);
end;

procedure TE2ETests.TestRun_VarParam_ModifyString;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcVarParamString, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Hello World', 'Hello World' + LE, Output);
end;

procedure TE2ETests.TestRun_ConstParam_CanRead;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcConstParam, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('42', '42' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ String operation e2e tests                                           }
{ ------------------------------------------------------------------ }

const
  SrcStringSubscript =
    'program P;'                            + #10 +
    'var S: string;'                        + #10 +
    'begin'                                 + #10 +
    '  S := ''ABC'';'                       + #10 +
    '  WriteLn(S[0]);'                      + #10 +
    '  WriteLn(S[1]);'                      + #10 +
    '  WriteLn(S[2])'                       + #10 +
    'end.';

  SrcStringConcatStr =
    'program P;'                            + #10 +
    'var A, B, C: string;'                  + #10 +
    'begin'                                 + #10 +
    '  A := ''foo'';'                       + #10 +
    '  B := ''bar'';'                       + #10 +
    '  C := A + B;'                         + #10 +
    '  WriteLn(C)'                          + #10 +
    'end.';

  SrcStringDelete =
    'program P;'                            + #10 +
    'var S: string;'                        + #10 +
    'begin'                                 + #10 +
    '  S := ''Hello World'';'              + #10 +
    '  Delete(S, 5, 6);'                    + #10 +
    '  WriteLn(S)'                          + #10 +
    'end.';

  SrcStringSetLength =
    'program P;'                            + #10 +
    'var S: string;'                        + #10 +
    'begin'                                 + #10 +
    '  S := ''Hello'';'                     + #10 +
    '  SetLength(S, 3);'                    + #10 +
    '  WriteLn(S)'                          + #10 +
    'end.';

procedure TE2ETests.TestRun_StringSubscript_ReadByte;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringSubscript, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { 'A'=65 'B'=66 'C'=67 }
  AssertEquals('65 66 67', '65' + LE + '66' + LE + '67' + LE, Output);
end;

procedure TE2ETests.TestRun_StringConcat_TwoStrings;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringConcatStr, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('foobar', 'foobar' + LE, Output);
end;

procedure TE2ETests.TestRun_StringConcat_WithInt;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun('program P; begin WriteLn(''x='' + IntToStr(7)) end.',
                  Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('x=7', 'x=7' + LE, Output);
end;

procedure TE2ETests.TestRun_StringDelete_Modifies;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringDelete, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Hellod', 'Hello' + LE, Output);
end;

procedure TE2ETests.TestRun_StringSetLength_Truncates;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStringSetLength, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Hel', 'Hel' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Int64 e2e tests                                                      }
{ ------------------------------------------------------------------ }

const
  SrcInt64Arith =
    'program P;'                                    + #10 +
    'var A, B: Int64;'                              + #10 +
    'begin'                                         + #10 +
    '  A := 3000000000;'                            + #10 +
    '  B := A * 2;'                                 + #10 +
    '  WriteLn(B)'                                  + #10 +
    'end.';

  SrcInt64Compare =
    'program P;'                                    + #10 +
    'var A: Int64;'                                 + #10 +
    'begin'                                         + #10 +
    '  A := 5000000000;'                            + #10 +
    '  if A > 4000000000 then WriteLn(''big'');'   + #10 +
    '  if A < 6000000000 then WriteLn(''small'')'  + #10 +
    'end.';

  SrcInt64ForLoop =
    'program P;'                                    + #10 +
    'var I: Int64; S: Int64;'                       + #10 +
    'begin'                                         + #10 +
    '  S := 0;'                                     + #10 +
    '  for I := 1 to 5 do'                          + #10 +
    '    S := S + I;'                               + #10 +
    '  WriteLn(S)'                                  + #10 +
    'end.';

procedure TE2ETests.TestRun_Int64_ArithmeticOverInt32;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInt64Arith, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('6000000000', '6000000000' + LE, Output);
end;

procedure TE2ETests.TestRun_Int64_Comparison;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInt64Compare, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('big small', 'big' + LE + 'small' + LE, Output);
end;

procedure TE2ETests.TestRun_Int64_ForLoop;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInt64ForLoop, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('15', '15' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Type cast e2e tests                                                  }
{ ------------------------------------------------------------------ }

const
  SrcTypeCastIntByte =
    'program P;'                                    + #10 +
    'var I: Integer; B: Byte;'                      + #10 +
    'begin'                                         + #10 +
    '  I := 300;'                                   + #10 +
    '  B := Byte(I);'                               + #10 +
    '  WriteLn(B)'                                  + #10 +
    'end.';

  SrcTypeCastPointerInt =
    'program P;'                                    + #10 +
    'var I: Integer; P1: Pointer;'                  + #10 +
    'begin'                                         + #10 +
    '  I  := 42;'                                   + #10 +
    '  P1 := Pointer(I);'                           + #10 +
    '  WriteLn(Integer(P1))'                        + #10 +
    'end.';

procedure TE2ETests.TestRun_TypeCast_IntegerByte;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypeCastIntByte, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { 300 mod 256 = 44 }
  AssertEquals('44', '44' + LE, Output);
end;

procedure TE2ETests.TestRun_TypeCast_PointerInteger;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypeCastPointerInt, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('42', '42' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ is / as e2e tests                                                    }
{ ------------------------------------------------------------------ }

const
  SrcIsTrue =
    'program P;'                                    + #10 +
    'type'                                          + #10 +
    '  TAnimal = class end;'                        + #10 +
    '  TDog = class(TAnimal) end;'                  + #10 +
    'var D: TAnimal;'                               + #10 +
    'begin'                                         + #10 +
    '  D := TDog.Create;'                           + #10 +
    '  if D is TDog then WriteLn(''yes'');'         + #10 +
    '  D.Free'                                      + #10 +
    'end.';

  SrcIsFalse =
    'program P;'                                    + #10 +
    'type'                                          + #10 +
    '  TAnimal = class end;'                        + #10 +
    '  TDog = class(TAnimal) end;'                  + #10 +
    '  TCat = class(TAnimal) end;'                  + #10 +
    'var D: TAnimal;'                               + #10 +
    'begin'                                         + #10 +
    '  D := TDog.Create;'                           + #10 +
    '  if D is TCat then WriteLn(''yes'') else WriteLn(''no'');' + #10 +
    '  D.Free'                                      + #10 +
    'end.';

  SrcAsDowncast =
    'program P;'                                    + #10 +
    'type'                                          + #10 +
    '  TBase = class'                               + #10 +
    '    function Name: string; virtual;'           + #10 +
    '  end;'                                        + #10 +
    '  TChild = class(TBase)'                       + #10 +
    '    FVal: Integer;'                            + #10 +
    '    function Name: string; override;'          + #10 +
    '  end;'                                        + #10 +
    'function TBase.Name: string;'                  + #10 +
    'begin Result := ''base'' end;'                 + #10 +
    'function TChild.Name: string;'                 + #10 +
    'begin Result := ''child'' end;'                + #10 +
    'var B: TBase;'                                 + #10 +
    'begin'                                         + #10 +
    '  B := TChild.Create;'                         + #10 +
    '  WriteLn((B as TChild).Name);'                + #10 +
    '  B.Free'                                      + #10 +
    'end.';

procedure TE2ETests.TestRun_Is_CorrectSubclass_True;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcIsTrue, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('yes', 'yes' + LE, Output);
end;

procedure TE2ETests.TestRun_Is_WrongClass_False;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcIsFalse, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('no', 'no' + LE, Output);
end;

procedure TE2ETests.TestRun_As_DowncastCallsMethod;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcAsDowncast, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('child', 'child' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Inheritance and virtual dispatch e2e tests                           }
{ ------------------------------------------------------------------ }

const
  SrcInherited =
    'program P;'                                    + #10 +
    'type'                                          + #10 +
    '  TBase = class'                               + #10 +
    '    function Val: Integer; virtual;'           + #10 +
    '  end;'                                        + #10 +
    '  TChild = class(TBase)'                       + #10 +
    '    function Val: Integer; override;'          + #10 +
    '  end;'                                        + #10 +
    'function TBase.Val: Integer;'                  + #10 +
    'begin Result := 10 end;'                       + #10 +
    'function TChild.Val: Integer;'                 + #10 +
    'var B: Integer;'                               + #10 +
    'begin'                                         + #10 +
    '  inherited Val;'                              + #10 +
    '  B := Result;'                                + #10 +
    '  Result := B + 5'                             + #10 +
    'end;'                                          + #10 +
    'var C: TChild;'                                + #10 +
    'begin'                                         + #10 +
    '  C := TChild.Create;'                         + #10 +
    '  WriteLn(C.Val);'                             + #10 +
    '  C.Free'                                      + #10 +
    'end.';

  SrcVirtualOverride =
    'program P;'                                    + #10 +
    'type'                                          + #10 +
    '  TShape = class'                              + #10 +
    '    function Area: Integer; virtual;'          + #10 +
    '  end;'                                        + #10 +
    '  TSquare = class(TShape)'                     + #10 +
    '    FSide: Integer;'                           + #10 +
    '    function Area: Integer; override;'         + #10 +
    '  end;'                                        + #10 +
    'function TShape.Area: Integer;'                + #10 +
    'begin Result := 0 end;'                        + #10 +
    'function TSquare.Area: Integer;'               + #10 +
    'begin Result := FSide * FSide end;'            + #10 +
    'var S: TShape;'                                + #10 +
    'begin'                                         + #10 +
    '  S := TSquare.Create;'                        + #10 +
    '  TSquare(S).FSide := 4;'                      + #10 +
    '  WriteLn(S.Area);'                            + #10 +
    '  S.Free'                                      + #10 +
    'end.';

  SrcMultiLevelChain =
    'program P;'                                    + #10 +
    'type'                                          + #10 +
    '  TA = class'                                  + #10 +
    '    function Lvl: Integer; virtual;'           + #10 +
    '  end;'                                        + #10 +
    '  TB = class(TA)'                              + #10 +
    '    function Lvl: Integer; override;'          + #10 +
    '  end;'                                        + #10 +
    '  TC = class(TB)'                              + #10 +
    '    function Lvl: Integer; override;'          + #10 +
    '  end;'                                        + #10 +
    'function TA.Lvl: Integer; begin Result := 1 end;' + #10 +
    'function TB.Lvl: Integer; begin Result := 2 end;' + #10 +
    'function TC.Lvl: Integer; begin Result := 3 end;' + #10 +
    'var A: TA;'                                    + #10 +
    'begin'                                         + #10 +
    '  A := TC.Create;'                             + #10 +
    '  WriteLn(A.Lvl);'                             + #10 +
    '  A.Free'                                      + #10 +
    'end.';

procedure TE2ETests.TestRun_Inherited_CallsParentMethod;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInherited, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('15', '15' + LE, Output);
end;

procedure TE2ETests.TestRun_Virtual_OverrideDispatch;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcVirtualOverride, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('16', '16' + LE, Output);
end;

procedure TE2ETests.TestRun_MultiLevel_Inheritance_Chain;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcMultiLevelChain, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('3', '3' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Interface e2e tests                                                  }
{ ------------------------------------------------------------------ }

const
  SrcIntfDispatch =
    'program P;'                                            + #10 +
    'type'                                                  + #10 +
    '  IGreeter = interface'                                + #10 +
    '    procedure Greet;'                                  + #10 +
    '  end;'                                               + #10 +
    '  THello = class(TObject, IGreeter)'                  + #10 +
    '    procedure Greet;'                                  + #10 +
    '  end;'                                               + #10 +
    'procedure THello.Greet;'                              + #10 +
    'begin WriteLn(''hello'') end;'                        + #10 +
    'var G: IGreeter;'                                     + #10 +
    '    H: THello;'                                       + #10 +
    'begin'                                                + #10 +
    '  H := THello.Create;'                                + #10 +
    '  G := H;'                                            + #10 +
    '  G.Greet;'                                           + #10 +
    '  H.Free'                                             + #10 +
    'end.';

  SrcIntfIsAs =
    'program P;'                                            + #10 +
    'type'                                                  + #10 +
    '  IPrinter = interface'                                + #10 +
    '    procedure Print;'                                  + #10 +
    '  end;'                                               + #10 +
    '  TPrinter = class(TObject, IPrinter)'                + #10 +
    '    procedure Print;'                                  + #10 +
    '  end;'                                               + #10 +
    'procedure TPrinter.Print;'                            + #10 +
    'begin WriteLn(''printing'') end;'                     + #10 +
    'var'                                                  + #10 +
    '  Obj: TObject;'                                      + #10 +
    '  P: IPrinter;'                                       + #10 +
    'begin'                                                + #10 +
    '  Obj := TPrinter.Create;'                            + #10 +
    '  if Obj is IPrinter then'                            + #10 +
    '  begin'                                              + #10 +
    '    P := Obj as IPrinter;'                            + #10 +
    '    P.Print'                                          + #10 +
    '  end;'                                               + #10 +
    '  Obj.Free'                                           + #10 +
    'end.';

procedure TE2ETests.TestRun_Interface_Dispatch_CallsImpl;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcIntfDispatch, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('hello', 'hello' + LE, Output);
end;

procedure TE2ETests.TestRun_Interface_ARC_NoLeak;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run',
    CompileAndRun(SrcIntfDispatch, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
end;

procedure TE2ETests.TestRun_Interface_Is_As_Roundtrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcIntfIsAs, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('printing', 'printing' + LE, Output);
end;

{ ------------------------------------------------------------------ }
{ Supports() e2e tests                                               }
{ ------------------------------------------------------------------ }

const
  SrcSupportsTwoArgRun =
    'program P;'                                              + #10 +
    'type'                                                    + #10 +
    '  IGreeter = interface'                                  + #10 +
    '    procedure Greet;'                                    + #10 +
    '  end;'                                                  + #10 +
    '  THello = class(TObject, IGreeter)'                     + #10 +
    '    procedure Greet;'                                    + #10 +
    '  end;'                                                  + #10 +
    'procedure THello.Greet;'                                 + #10 +
    'begin WriteLn(''hello'') end;'                           + #10 +
    'var Obj: TObject;'                                       + #10 +
    'begin'                                                   + #10 +
    '  Obj := THello.Create;'                                 + #10 +
    '  if Supports(Obj, IGreeter) then'                       + #10 +
    '    WriteLn(''yes'')'                                    + #10 +
    '  else'                                                  + #10 +
    '    WriteLn(''no'');'                                    + #10 +
    '  Obj.Free'                                              + #10 +
    'end.';

  SrcSupportsThreeArgRun =
    'program P;'                                              + #10 +
    'type'                                                    + #10 +
    '  IGreeter = interface'                                  + #10 +
    '    procedure Greet;'                                    + #10 +
    '  end;'                                                  + #10 +
    '  THello = class(TObject, IGreeter)'                     + #10 +
    '    procedure Greet;'                                    + #10 +
    '  end;'                                                  + #10 +
    'procedure THello.Greet;'                                 + #10 +
    'begin WriteLn(''hello'') end;'                           + #10 +
    'var Obj: TObject;'                                       + #10 +
    '    G: IGreeter;'                                        + #10 +
    'begin'                                                   + #10 +
    '  Obj := THello.Create;'                                 + #10 +
    '  if Supports(Obj, IGreeter, G) then'                    + #10 +
    '    G.Greet'                                             + #10 +
    '  else'                                                  + #10 +
    '    WriteLn(''no'');'                                    + #10 +
    '  Obj.Free'                                              + #10 +
    'end.';

procedure TE2ETests.TestRun_Supports_TwoArg_BooleanResult;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcSupportsTwoArgRun, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('yes', 'yes' + LE, Output);
end;

procedure TE2ETests.TestRun_Supports_ThreeArg_AssignsAndCalls;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcSupportsThreeArgRun, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('hello', 'hello' + LE, Output);
end;

initialization
  RegisterTest(TE2ETests);

end.
