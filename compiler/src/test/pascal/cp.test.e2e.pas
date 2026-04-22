unit cp.test.e2e;

{$mode objfpc}{$H+}

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
  Classes, SysUtils, Process, fpcunit, testregistry,
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
                            const AExtraArgs: array of string): Boolean;
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

{ Runs a process, captures stdout into AStdout, returns exit code.
  Returns -1 if the process could not be started. }
function RunProc(const AExe:      string;
                 const AArgs:     array of string;
                 out   AStdout:   string;
                 AInheritStdErr:  Boolean): Integer;
var
  Proc:    TProcess;
  Ss:      TStringStream;
  Buf:     array[0..4095] of Byte;
  N:       LongInt;
  I:       Integer;
begin
  Proc := TProcess.Create(nil);
  Ss   := TStringStream.Create('');
  try
    Proc.Executable := AExe;
    for I := Low(AArgs) to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Options := [poUsePipes];
    if AInheritStdErr then
      Proc.Options := Proc.Options + [poStderrToOutPut];
    try
      Proc.Execute;
    except
      Result := -1;
      Exit;
    end;
    while Proc.Running or (Proc.Output.NumBytesAvailable > 0) do
    begin
      if Proc.Output.NumBytesAvailable > 0 then
      begin
        N := Proc.Output.Read(Buf, SizeOf(Buf));
        if N > 0 then Ss.Write(Buf, N);
      end
      else
        Sleep(2);
    end;
    Result  := Proc.ExitCode;
    AStdout := Ss.DataString;
  finally
    Ss.Free;
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
    Fail('qbe failed (exit ' + IntToStr(Rc) + '): ' + ToolOut + sLineBreak +
         'IR file preserved at: ' + IRFile);
    Exit;
  end;

  Rc := RunProc('cc', ['-o', BinFile, AsmFile, FRTL], ToolOut, True);
  if Rc <> 0 then
  begin
    Fail('cc failed (exit ' + IntToStr(Rc) + '): ' + ToolOut + sLineBreak +
         'IR: ' + IRFile + sLineBreak + 'asm: ' + AsmFile);
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
  LE = LineEnding;

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
    CompileAndRun(SrcBareTryFinally, Output, RCode, []));
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
    CompileAndRun(SrcPreservesLocals, Output, RCode, []));
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
    CompileAndRun(SrcNestedTryFinally, Output, RCode, []));
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
    CompileAndRun(SrcVirtualDispatchInTry, Output, RCode, []));
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
    CompileAndRun(Src, Output, RCode, []));
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

initialization
  RegisterTest(TE2ETests);

end.
