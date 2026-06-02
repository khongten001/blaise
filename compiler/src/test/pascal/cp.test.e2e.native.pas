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
         counter-driven while/repeat.
    M5 — user procedures/functions: integer value parameters, integer/void
         return via Result, locals in a stack frame, direct calls (including
         in expressions and nested), recursion, and for loops over a local.
         Also: the wider integer family — Byte, Word, SmallInt, Int64 (and
         signed/unsigned cousins) as globals, locals, parameters and return
         values; mixed-width arithmetic (Int64 promotion); and explicit
         type-cast conversions Byte(X) / Word(X) / Int64(X) that
         truncate/extend correctly. }

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
    procedure TestRun_Native_FunctionsAndCalls;
    procedure TestRun_Native_Recursion;
    procedure TestRun_Native_ForLoopOverLocal;
    procedure TestRun_Native_WiderIntGlobals;
    procedure TestRun_Native_Int64Arithmetic;
    procedure TestRun_Native_WiderIntParamsAndReturn;
    procedure TestRun_Native_TypeCastConversions;
    procedure TestRun_Native_SignednessAndWraparound;
    procedure TestRun_Native_WriteUnsigned32;
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

  SrcFunctions = '''
    program P;
    function Square(x: Integer): Integer;
    begin
      Result := x * x
    end;
    function Sum3(a, b, c: Integer): Integer;
    begin
      Result := a + b + c
    end;
    procedure PrintTwice(n: Integer);
    begin
      WriteLn(n);
      WriteLn(n)
    end;
    begin
      WriteLn(Square(6));
      WriteLn(Sum3(1, 2, 3));
      PrintTwice(9);
      WriteLn(Square(Square(2)));
      WriteLn(Square(3) + Sum3(10, 20, 30))
    end.
    ''';

  SrcRecursion = '''
    program P;
    function Fact(n: Integer): Integer;
    begin
      if n <= 1 then
        Result := 1
      else
        Result := n * Fact(n - 1)
    end;
    begin
      WriteLn(Fact(5));
      WriteLn(Fact(1))
    end.
    ''';

  SrcForOverLocal = '''
    program P;
    function SumTo(n: Integer): Integer;
    var i, s: Integer;
    begin
      s := 0;
      for i := 1 to n do s := s + i;
      Result := s
    end;
    begin
      WriteLn(SumTo(10));
      WriteLn(SumTo(100))
    end.
    ''';

  { Wider integer family as program globals: declare, assign, read, and
    WriteLn each.  Byte/Word/SmallInt are stored narrow but read back to the
    full ordinal value; Int64 holds a value beyond 32 bits. }
  SrcWiderIntGlobals = '''
    program P;
    var
      b: Byte;
      w: Word;
      s: SmallInt;
      big: Int64;
    begin
      b := 200;
      w := 50000;
      s := -1000;
      big := 5000000000;
      WriteLn(b);
      WriteLn(w);
      WriteLn(s);
      WriteLn(big)
    end.
    ''';

  { Int64 arithmetic must use 64-bit operations: a product that overflows 32
    bits, and addition past the 32-bit boundary. }
  SrcInt64Arith = '''
    program P;
    var a, b, r: Int64;
    begin
      a := 100000;
      b := 100000;
      r := a * b;
      WriteLn(r);
      r := 4000000000 + 4000000000;
      WriteLn(r);
      r := r div 1000000;
      WriteLn(r)
    end.
    ''';

  { Wider-int parameters and return values across a call boundary. }
  SrcWiderIntParams = '''
    program P;
    function AddBytes(x, y: Byte): Integer;
    begin
      Result := x + y
    end;
    function ScaleBig(n: Int64): Int64;
    begin
      Result := n * 3
    end;
    function ClampWord(w: Word): Word;
    begin
      Result := w
    end;
    begin
      WriteLn(AddBytes(200, 100));
      WriteLn(ScaleBig(2000000000));
      WriteLn(ClampWord(40000))
    end.
    ''';

  { Explicit type-cast conversions truncate (narrowing) and extend (widening)
    exactly like the QBE backend: Byte(X) keeps the low 8 bits, Word(X) the
    low 16; Int64(X) widens a 32-bit value. }
  SrcTypeCasts = '''
    program P;
    var i: Integer;
    var big: Int64;
    begin
      i := 300;
      WriteLn(Byte(i));
      i := 70000;
      WriteLn(Word(i));
      i := 1000000;
      big := Int64(i) * Int64(i);
      WriteLn(big)
    end.
    ''';

  { Signedness on read-back: a SmallInt holding a value whose 16-bit pattern
    is negative reads back sign-extended; a Word with the same low-16 bits
    reads back as the large unsigned ordinal. }
  SrcSignedness = '''
    program P;
    var s: SmallInt;
    var w: Word;
    begin
      s := -2;
      w := 65534;
      WriteLn(s);
      WriteLn(w);
      WriteLn(s + 5)
    end.
    ''';

  { A Cardinal/UInt32 value above 2^31 must print as the large unsigned value,
    not a negative signed wrap. }
  SrcWriteUnsigned32 = '''
    program P;
    var c: Cardinal;
    begin
      c := 3000000000;
      WriteLn(c)
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

procedure TE2ENativeTests.TestRun_Native_FunctionsAndCalls;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcFunctions, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { Square(6)=36; Sum3(1,2,3)=6; PrintTwice(9)=9,9; Square(Square(2))=16;
    Square(3)+Sum3(10,20,30)=9+60=69 }
  AssertEquals('36 6 9 9 16 69',
    '36' + LE + '6' + LE + '9' + LE + '9' + LE + '16' + LE + '69' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_Recursion;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcRecursion, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('120 then 1', '120' + LE + '1' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_ForLoopOverLocal;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcForOverLocal, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('55 then 5050', '55' + LE + '5050' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_WiderIntGlobals;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcWiderIntGlobals, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('200 50000 -1000 5000000000',
    '200' + LE + '50000' + LE + '-1000' + LE + '5000000000' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_Int64Arithmetic;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcInt64Arith, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { 100000*100000 = 10000000000; 4e9+4e9 = 8000000000; /1e6 = 8000 }
  AssertEquals('10000000000 8000000000 8000',
    '10000000000' + LE + '8000000000' + LE + '8000' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_WiderIntParamsAndReturn;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcWiderIntParams, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { AddBytes(200,100)=300; ScaleBig(2e9)*3=6000000000; ClampWord(40000)=40000 }
  AssertEquals('300 6000000000 40000',
    '300' + LE + '6000000000' + LE + '40000' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_TypeCastConversions;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcTypeCasts, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { Byte(300)=44 (300 mod 256); Word(70000)=4464 (70000 mod 65536);
    Int64(1000000)^2 = 1000000000000 }
  AssertEquals('44 4464 1000000000000',
    '44' + LE + '4464' + LE + '1000000000000' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_SignednessAndWraparound;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcSignedness, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { SmallInt -2 reads back -2; Word 65534 reads back 65534; -2 + 5 = 3 }
  AssertEquals('-2 65534 3',
    '-2' + LE + '65534' + LE + '3' + LE, Output);
end;

procedure TE2ENativeTests.TestRun_Native_WriteUnsigned32;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunNative(SrcWriteUnsigned32, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('3000000000 (unsigned, not negative)', '3000000000' + LE, Output);
end;

initialization
  RegisterTest(TE2ENativeTests);

end.
