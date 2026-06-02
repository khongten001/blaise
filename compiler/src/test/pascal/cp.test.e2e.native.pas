{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.native;

{ E2E tests for the native code-generation backend (--backend native).

  These compile a program with TCodeGenNative (no QBE), link with cc, and run.
  The correctness oracle is parity with the QBE path on the same source; as the
  backend grows, tests here mirror the behaviour the QBE e2e suites already
  cover, run through the native path.

  Milestone coverage:
    M1 — empty program compiles, links, and exits 0.
    M2 — integer arithmetic (+ - * div mod, nesting, precedence) and
         Write/WriteLn of integers.
    M3 — control flow: if/else, while, repeat, and the comparison operators
         (= <> < > <= >=).
    M4 — program-global integer variables (declare, assign, read) and the for
         loop (to / downto, nesting, end-expression evaluated once), plus
         counter-driven while/repeat. }

interface

uses
  blaise.testing, cp.test.e2e.base;

type
  [Threaded]
  TE2ENativeTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestRun_Native_EmptyProgram_ExitsZero;
    procedure TestRun_Native_IntArithmetic_WriteLn;
    procedure TestRun_Native_DivModAndNesting;
    procedure TestRun_Native_WriteNoNewline;
    procedure TestRun_Native_IfElse;
    procedure TestRun_Native_ComparisonsAndNestedIf;
    procedure TestRun_Native_Repeat;
    procedure TestRun_Native_VarsAndForLoop;
    procedure TestRun_Native_DownToAndNestedFor;
    procedure TestRun_Native_CounterLoops;
    procedure TestRun_Native_ForEndEvaluatedOnce;
  end;

implementation

procedure TE2ENativeTests.SetUp;
begin
  inherited SetUp;
  SetUpScratch('compiler/target/test-e2e-native');
end;

const
  LE = #10;

  SrcEmpty = '''
    program P;
    begin
    end.
    ''';

  SrcArith = '''
    program P;
    begin
      WriteLn(2 + 3 * 4);
      WriteLn(100 - 58)
    end.
    ''';

  SrcDivMod = '''
    program P;
    begin
      WriteLn(20 div 6);
      WriteLn(20 mod 6);
      WriteLn((2 + 3) * (10 - 4));
      WriteLn(7 - 10)
    end.
    ''';

  SrcWriteNoNL = '''
    program P;
    begin
      Write(1);
      Write(2);
      WriteLn(3)
    end.
    ''';

  SrcIfElse = '''
    program P;
    begin
      if 5 > 3 then WriteLn(1) else WriteLn(0);
      if 2 > 9 then WriteLn(1) else WriteLn(0);
      if 4 = 4 then WriteLn(44)
    end.
    ''';

  SrcComparisons = '''
    program P;
    begin
      if 3 < 5 then WriteLn(11);
      if 5 <= 5 then WriteLn(22);
      if 6 >= 9 then WriteLn(33) else WriteLn(44);
      if 7 <> 8 then WriteLn(55);
      if (2 + 2) = 4 then
        if 10 > 1 then WriteLn(66)
    end.
    ''';

  { while with a false condition never runs; repeat runs once then exits when
    the until condition is true.  (Counter-driven loops arrive with M4 locals.) }
  SrcRepeat = '''
    program P;
    begin
      while 3 > 5 do WriteLn(999);
      repeat WriteLn(8) until 1 = 1
    end.
    ''';

  SrcVarsForLoop = '''
    program P;
    var i, sum: Integer;
    begin
      sum := 0;
      for i := 1 to 5 do
        sum := sum + i;
      WriteLn(sum)
    end.
    ''';

  SrcDownToNested = '''
    program P;
    var i, j, total: Integer;
    begin
      for i := 5 downto 1 do Write(i);
      WriteLn(0);
      total := 0;
      for i := 1 to 3 do
        for j := 1 to 3 do
          total := total + 1;
      WriteLn(total)
    end.
    ''';

  SrcCounterLoops = '''
    program P;
    var n: Integer;
    begin
      n := 0;
      while n < 3 do
      begin
        Write(n);
        n := n + 1
      end;
      WriteLn(9);
      n := 0;
      repeat
        n := n + 2
      until n >= 6;
      WriteLn(n)
    end.
    ''';

  SrcForEndOnce = '''
    program P;
    var i, limit, count: Integer;
    begin
      limit := 3;
      count := 0;
      for i := 1 to limit do
      begin
        count := count + 1;
        limit := limit + 10
      end;
      WriteLn(count)
    end.
    ''';

procedure TE2ENativeTests.TestRun_Native_EmptyProgram_ExitsZero;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcEmpty, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('no output', '', Output);
end;

procedure TE2ENativeTests.TestRun_Native_IntArithmetic_WriteLn;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcArith, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('14 then 42', '14' + LE + '42' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_DivModAndNesting;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcDivMod, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('3 2 30 -3',
    '3' + LE + '2' + LE + '30' + LE + '-3' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_WriteNoNewline;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcWriteNoNL, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('123 then newline', '123' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_IfElse;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcIfElse, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('1 0 44', '1' + LE + '0' + LE + '44' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_ComparisonsAndNestedIf;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcComparisons, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('11 22 44 55 66',
    '11' + LE + '22' + LE + '44' + LE + '55' + LE + '66' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_Repeat;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcRepeat, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('8 once', '8' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_VarsAndForLoop;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcVarsForLoop, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('sum 1..5 = 15', '15' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_DownToAndNestedFor;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcDownToNested, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('54321 0 then 9', '543210' + LE + '9' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_CounterLoops;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcCounterLoops, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { while writes 0,1,2 (Write, no newline), then WriteLn(9) -> "0129"; repeat
    counts 0->2->4->6 and WriteLn(n) -> "6". }
  AssertEquals('0129 then 6', '0129' + LE + '6' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_ForEndEvaluatedOnce;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcForEndOnce, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('count = 3 (end not extended)', '3' + LE, Output);
end;

initialization
  RegisterTest(TE2ENativeTests);

end.
