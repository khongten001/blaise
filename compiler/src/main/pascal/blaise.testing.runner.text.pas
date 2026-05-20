{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{
  blaise.testing.runner.text — plain-text test runner for blaise.testing.

  Step 11e.  Walks the blaise.testing global registry, instantiates one
  TTestCase per published method per registered class, runs each
  against a single TTestResult, and prints PASS / FAIL output plus a
  summary line.

  CLI filtering (Step 15):
    --suite ClassName              run all tests in ClassName
    --suite ClassName.MethodName   run one specific test method

  When invoked by 'pasbuild test' no arguments are passed, so all
  registered tests run.  Manual invocation can narrow the run:
    ./TestRunner --suite TClassTests
    ./TestRunner --suite TClassTests.TestParse_ClassSection_Exists

  ARC: TTestCase instances created via ClassCreate are released at
  loop-iteration end via the standard scope-based _ClassRelease the
  codegen emits for class-typed locals.  No explicit Free calls.
}

unit blaise.testing.runner.text;

interface

uses
  blaise.testing, Classes, SysUtils, Process;

{ Run every test method of every TTestCase class registered via
  RegisterTest.  Returns the result so the caller can compute an
  exit code or feed it to subsequent reporters. }
function RunRegisteredTests: TTestResult;

{ Print a one-line summary plus per-failure detail to standard output.
  Suitable for direct call after RunRegisteredTests. }
procedure PrintSummary(AResult: TTestResult);

{ Convenience: run, print, return 0 on all-green and 1 otherwise.
  Respects --suite / --suite Class.Method command-line filtering.
  Programs can do 'Halt(RunAll)' as the last statement. }
function RunAll: Integer;


implementation

{ -----------------------------------------------------------------------
  Published-method table walk

  Reads the typeinfo's slot 3 (methods table) for the given class
  metaclass value and climbs the parent chain so inherited published
  methods are visible.  Returns the count and i'th name through
  per-class out-helpers.

  Typeinfo and methods-table layout are documented in
  uCodeGenQBE.pas:EmitTypeInfoDefs.
  ----------------------------------------------------------------------- }

function PublishedMethodCount(ATestClass: TTestCaseClass): Integer;
var
  TInfo:   Pointer;
  Slot:    ^Pointer;
  Methods: Pointer;
  Count:   ^Int64;
begin
  Result := 0;
  TInfo  := Pointer(ATestClass);
  while TInfo <> nil do
  begin
    Slot    := TInfo + 24;       { typeinfo[3] = methods table ptr }
    Methods := Slot^;
    if Methods <> nil then
    begin
      Count  := Methods;
      Result := Result + Integer(Count^);
    end;
    Slot  := TInfo;              { typeinfo[0] = parent }
    TInfo := Slot^;
  end;
end;

{ Return the i'th published method name across the full parent chain.
  Methods declared in the class itself come first; parent methods
  follow.  Returns '' if AIndex is out of range. }
function PublishedMethodName(ATestClass: TTestCaseClass;
  AIndex: Integer): string;
var
  TInfo:   Pointer;
  Slot:    ^Pointer;
  Methods: Pointer;
  Count:   ^Int64;
  Entry:   ^Pointer;
  EntName: Pointer;
  Local:   Integer;
  Seen:    Integer;
  I:       Integer;
begin
  Result := '';
  Seen   := 0;
  TInfo  := Pointer(ATestClass);
  while TInfo <> nil do
  begin
    Slot    := TInfo + 24;
    Methods := Slot^;
    if Methods <> nil then
    begin
      Count := Methods;
      Local := Integer(Count^);
      if AIndex < Seen + Local then
      begin
        { The wanted entry lives in this class's own table. }
        Entry := Methods + 8;
        for I := 0 to (AIndex - Seen) - 1 do
          Entry := Pointer(Entry) + 16;     { skip name + addr pair }
        EntName := Entry^;
        Result  := string(PChar(EntName));
        Exit;
      end;
      Seen := Seen + Local;
    end;
    Slot  := TInfo;
    TInfo := Slot^;
  end;
end;

{ Return the class name of a TTestCaseClass by reading typeinfo[2]
  (offset 16) — the immortal Blaise string emitted by EmitClassNameRef.
  Same read pattern as PublishedMethodName uses for method name entries. }
function TestClassName(ATestClass: TTestCaseClass): string;
var
  TInfo:    Pointer;
  NameSlot: ^Pointer;
begin
  TInfo    := Pointer(ATestClass);
  NameSlot := TInfo + 16;           { typeinfo[2] = class name string ptr }
  Result   := string(PChar(NameSlot^));
end;

{ -----------------------------------------------------------------------
  CLI argument parsing
  ----------------------------------------------------------------------- }

{ Parse --suite and --verbose from the process command line.
  ASuite is set to the class name filter ('' = no filter).
  AMethod is set to the method name filter ('' = all methods in the class).
  AVerbose is set to True when --verbose is present. }
procedure ParseArgs(out ASuite: string; out AMethod: string; out AVerbose: Boolean);
var
  I:      Integer;
  Arg:    string;
  Filter: string;
  Dot:    Integer;
begin
  ASuite   := '';
  AMethod  := '';
  AVerbose := False;
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if Arg = '--verbose' then
      AVerbose := True
    else if (Arg = '--suite') and (I < ParamCount) then
    begin
      I      := I + 1;
      Filter := ParamStr(I);
      Dot    := Pos('.', Filter);
      if Dot >= 0 then
      begin
        { Pos is 0-based in Blaise; Copy(s, start, count) where start is
          also 0-based.  Dot is the 0-based index of '.'. }
        ASuite  := Copy(Filter, 0, Dot);
        AMethod := Copy(Filter, Dot + 1, Length(Filter));
      end
      else
        ASuite := Filter;
    end;
    I := I + 1;
  end;
end;

{ -----------------------------------------------------------------------
  Subprocess-based parallel runner
  ----------------------------------------------------------------------- }

function IsThreadedClass(ATestClass: TTestCaseClass): Boolean;
begin
  Result := HasClassAttribute(ATestClass, ThreadedAttribute);
end;

{ ParseSubprocessOutput: parse --verbose output from a suite subprocess
  into AResult.  Called in the main thread after subprocess completes. }
procedure ParseSubprocessOutput(const AOutput: string; AResult: TTestResult);
var
  Lines:   TStringList;
  I:       Integer;
  Line:    string;
  InFail:  Boolean;
  InErr:   Boolean;
  P:       Integer;
  MsgName: string;
  MsgBody: string;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AOutput;
    InFail := False;
    InErr  := False;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines.Strings[I];
      if Line = 'Failures:' then begin InFail := True; InErr := False; Continue end;
      if Line = 'Errors:'   then begin InErr  := True; InFail := False; Continue end;
      if InFail or InErr then
      begin
        { Indented detail lines: "  MethodName: message" }
        if (Length(Line) > 2) and (Copy(Line, 0, 2) = '  ') then
        begin
          P := Pos(': ', Line);
          if P >= 0 then
          begin
            MsgName := Copy(Line, 2, P - 2);
            MsgBody := Copy(Line, P + 2, Length(Line));
            if InFail then
              AResult.AddFailure(MsgName, MsgBody)
            else
              AResult.AddError(MsgName, MsgBody);
          end;
          Continue;
        end;
        InFail := False; InErr := False;
      end;
      { Verbose outcome line: "CName.MName ... OUTCOME" }
      if Pos(' ... ', Line) >= 0 then
      begin
        AResult.StartTest('', '');
        if (Pos(' ... FAIL', Line) >= 0) or (Pos(' ... ERROR', Line) >= 0) then
          AResult.EndTest('FAIL')
        else if Pos(' ... IGNORED', Line) >= 0 then
          AResult.EndTest('IGNORED')
        else
          AResult.EndTest('OK');
      end;
    end;
  finally
    Lines.Free;
  end;
end;

{ -----------------------------------------------------------------------
  Test execution
  ----------------------------------------------------------------------- }

{ Run tests with optional class/method filtering and verbosity.
  Pass '' for both ASuite and AMethod to run all registered tests.

  [Threaded] suites are dispatched as subprocesses and launched in
  parallel while non-threaded suites run in-process.  After in-process
  tests finish, remaining subprocess output is collected.
  When --suite is given, the named suite runs directly (no subprocess). }
function RunFilteredTests(const ASuite: string;
  const AMethod: string; AVerbose: Boolean): TTestResult;
var
  ClsIdx:    Integer;
  Cls:       TTestCaseClass;
  CName:     string;
  MethCnt:   Integer;
  MethIdx:   Integer;
  MethName:  string;
  Inst:      TTestCase;
  Procs:     array[0..63] of TProcess;
  ProcCount: Integer;
  Proc:      TProcess;
  Output:    string;
  Chunk:     string;
  SubResult: TTestResult;
  I:         Integer;
begin
  Result := TTestResult.Create;
  Result.Verbose := AVerbose;
  ProcCount := 0;
  for ClsIdx := 0 to GetRegisteredTestCount - 1 do
  begin
    Cls   := GetRegisteredTest(ClsIdx);
    CName := TestClassName(Cls);
    if (ASuite <> '') and (CName <> ASuite) then
      Continue;
    if (ASuite = '') and IsThreadedClass(Cls) and (ProcCount < 64) then
    begin
      Proc := TProcess.Create(nil);
      Proc.Executable := ParamStr(0);
      Proc.Parameters.Add('--suite');
      Proc.Parameters.Add(CName);
      Proc.Parameters.Add('--verbose');
      Proc.Execute;
      Procs[ProcCount] := Proc;
      ProcCount := ProcCount + 1;
    end
    else
    begin
      MethCnt := PublishedMethodCount(Cls);
      for MethIdx := 0 to MethCnt - 1 do
      begin
        MethName := PublishedMethodName(Cls, MethIdx);
        if MethName = '' then Continue;
        if (AMethod <> '') and (MethName <> AMethod) then
          Continue;
        Inst := ClassCreate(Cls, MethName);
        Inst.SetClassName(CName);
        Inst.Run(Result);
      end;
    end;
  end;
  for I := 0 to ProcCount - 1 do
  begin
    Proc := Procs[I];
    Output := '';
    repeat
      Chunk  := Proc.ReadOutput;
      Output := Output + Chunk;
    until (Chunk = '') and not Proc.Running;
    Proc.WaitOnExit;
    SubResult := TTestResult.Create;
    ParseSubprocessOutput(Output, SubResult);
    Result.MergeFrom(SubResult);
    if AVerbose then
      Write(Output);
  end;
end;

function RunRegisteredTests: TTestResult;
begin
  Result := RunFilteredTests('', '', False);
end;

{ -----------------------------------------------------------------------
  Reporting
  ----------------------------------------------------------------------- }

procedure PrintSummary(AResult: TTestResult);
var
  I:     Integer;
  Fails: TStringList;
  Errs:  TStringList;
  Line:  string;
begin
  WriteLn(AResult.Summary);

  if AResult.NumberOfFailures > 0 then
  begin
    WriteLn('Failures:');
    Fails := AResult.Failures;
    I     := 0;
    while I < AResult.NumberOfFailures do
    begin
      Line := Fails.Strings[I];
      WriteLn('  ' + Line);
      I := I + 1
    end;
  end;

  if AResult.NumberOfErrors > 0 then
  begin
    WriteLn('Errors:');
    Errs := AResult.Errors;
    I    := 0;
    while I < AResult.NumberOfErrors do
    begin
      Line := Errs.Strings[I];
      WriteLn('  ' + Line);
      I := I + 1
    end;
  end;
end;

function RunAll: Integer;
var
  R:       TTestResult;
  Suite:   string;
  Method:  string;
  Verbose: Boolean;
begin
  ParseArgs(Suite, Method, Verbose);
  R := RunFilteredTests(Suite, Method, Verbose);
  PrintSummary(R);
  if (R.NumberOfFailures = 0) and (R.NumberOfErrors = 0) then
    Result := 0
  else
    Result := 1;
end;

end.
