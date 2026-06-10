{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Andrew Haines
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.recordret;

{ Behavioural coverage for QBE record-by-value return: compile + run
  programs that return records through every reg-return shape (rcInt1
  in widths 1/2/4/8 + rcInt2 16-byte aggregate) and verify the values
  arrive at the caller's destination intact.

  These tests catch bugs that pure IR-shape assertions miss — wrong
  load width, wrong store width, sign-extend confusion, padding-byte
  leakage between fields. }

interface

uses
  SysUtils, blaise.testing, cp.test.e2e.base;

type
  [Threaded]
  TE2ERecordReturnTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    { rcInt1 1B — single Byte field. }
    procedure TestRun_RcInt1_OneByte_RoundTrip;
    { rcInt1 2B — two Byte fields. }
    procedure TestRun_RcInt1_TwoByte_RoundTrip;
    { rcInt1 4B — two SmallInt fields, negative value catches
      unsigned-load sign loss. }
    procedure TestRun_RcInt1_TwoSmallInt_NegativeValue;
    { rcInt1 8B — two Integer fields, multi-field one-eightbyte. }
    procedure TestRun_RcInt1_TwoInteger_RoundTrip;
    { rcInt1 8B — single Int64, boundary value. }
    procedure TestRun_RcInt1_Int64_MaxValue;
    { rcInt2 16B — two Int64 fields. }
    procedure TestRun_RcInt2_TwoInt64_RoundTrip;
    { rcInt2 16B — Integer + Int64 with tail-pad layout. }
    procedure TestRun_RcInt2_IntegerPlusInt64;
    { rcSSE1 8B — single Double field, xmm0 round-trip. }
    procedure TestRun_RcSSE1_Double_RoundTrip;
    { rcSSE2 16B — two Doubles, xmm0:xmm1. }
    procedure TestRun_RcSSE2_TwoDoubles_RoundTrip;
    { rcIntSSE 16B — Int64 + Double via (rax, xmm0). }
    procedure TestRun_RcIntSSE_Int64Double_RoundTrip;
    { rcSSEInt 16B — Double + Int64 via (xmm0, rax). }
    procedure TestRun_RcSSEInt_DoubleInt64_RoundTrip;
    { rcSSE1 with Single — 4B record via xmm0 as `s`. }
    procedure TestRun_RcSSE1_Single_RoundTrip;
    { Nested record — inner TPoint (8 B int) embedded in 12 B outer → rcInt2. }
    procedure TestRun_RcInt2_NestedRecord_RoundTrip;
    { Two Single fields — 8 B, all-float leaves → rcSSE1. }
    procedure TestRun_RcSSE1_TwoSingle_RoundTrip;
    { Managed-field record stays on sret (string field → no register return). }
    procedure TestRun_ManagedField_StaysSret;
  end;

implementation

procedure TE2ERecordReturnTests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-recordret');
end;

const
  LE = #10;

  SrcOneByte = '''
    program P;
    type TB = record C: Byte; end;
    function MakeIt(V: Byte): TB;
    begin
      Result.C := V
    end;
    var R: TB;
    begin
      R := MakeIt(200);
      WriteLn(R.C)
    end.
    ''';

  SrcTwoByte = '''
    program P;
    type T2B = record A, B: Byte; end;
    function MakeIt(A, B: Byte): T2B;
    begin
      Result.A := A;
      Result.B := B
    end;
    var R: T2B;
    begin
      R := MakeIt(7, 250);
      WriteLn(R.A, ' ', R.B)
    end.
    ''';

  SrcTwoSmallIntNeg = '''
    program P;
    type TS = record A, B: SmallInt; end;
    function MakeIt(A, B: SmallInt): TS;
    begin
      Result.A := A;
      Result.B := B
    end;
    var R: TS;
    begin
      R := MakeIt(-1, -32000);
      WriteLn(R.A, ' ', R.B)
    end.
    ''';

  SrcTwoInteger = '''
    program P;
    type TXY = record X, Y: Integer; end;
    function MakeIt(X, Y: Integer): TXY;
    begin
      Result.X := X;
      Result.Y := Y
    end;
    var R: TXY;
    begin
      R := MakeIt(123456, -789012);
      WriteLn(R.X, ' ', R.Y)
    end.
    ''';

  SrcInt64Max = '''
    program P;
    type TI = record V: Int64; end;
    function MakeIt(V: Int64): TI;
    begin
      Result.V := V
    end;
    var R: TI;
    begin
      R := MakeIt(9223372036854775807);
      WriteLn(R.V)
    end.
    ''';

  SrcTwoInt64 = '''
    program P;
    type T2 = record A, B: Int64; end;
    function MakeIt(A, B: Int64): T2;
    begin
      Result.A := A;
      Result.B := B
    end;
    var R: T2;
    begin
      R := MakeIt(111111111111, 222222222222);
      WriteLn(R.A, ' ', R.B)
    end.
    ''';

  SrcOneDouble = '''
    program P;
    type TF = record V: Double; end;
    function MakeIt(V: Double): TF;
    begin
      Result.V := V
    end;
    var R: TF;
    begin
      R := MakeIt(3.5);
      WriteLn(R.V)
    end.
    ''';

  SrcTwoDouble = '''
    program P;
    type T2D = record A, B: Double; end;
    function MakeIt(A, B: Double): T2D;
    begin
      Result.A := A;
      Result.B := B
    end;
    var R: T2D;
    begin
      R := MakeIt(1.5, -2.5);
      WriteLn(R.A);
      WriteLn(R.B)
    end.
    ''';

  SrcOneSingle = '''
    program P;
    type TF = record V: Single; end;
    function MakeIt(V: Single): TF;
    begin
      Result.V := V
    end;
    var R: TF;
    begin
      R := MakeIt(2.5);
      WriteLn(R.V)
    end.
    ''';

  SrcIntSSE = '''
    program P;
    type TM = record I: Int64; D: Double; end;
    function MakeIt(I: Int64; D: Double): TM;
    begin
      Result.I := I;
      Result.D := D
    end;
    var R: TM;
    begin
      R := MakeIt(42, 3.5);
      WriteLn(R.I);
      WriteLn(R.D)
    end.
    ''';

  SrcSSEInt = '''
    program P;
    type TM = record D: Double; I: Int64; end;
    function MakeIt(D: Double; I: Int64): TM;
    begin
      Result.D := D;
      Result.I := I
    end;
    var R: TM;
    begin
      R := MakeIt(-1.5, 99);
      WriteLn(R.D);
      WriteLn(R.I)
    end.
    ''';

  SrcMixIntInt64 = '''
    program P;
    type TM = record X: Integer; Y: Int64; end;
    function MakeIt(X: Integer; Y: Int64): TM;
    begin
      Result.X := X;
      Result.Y := Y
    end;
    var R: TM;
    begin
      R := MakeIt(42, 1000000000000);
      WriteLn(R.X, ' ', R.Y)
    end.
    ''';

procedure TE2ERecordReturnTests.TestRun_RcInt1_OneByte_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcOneByte, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('200', '200' + LE, Output);
end;

procedure TE2ERecordReturnTests.TestRun_RcInt1_TwoByte_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTwoByte, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('two-byte fields', '7 250' + LE, Output);
end;

procedure TE2ERecordReturnTests.TestRun_RcInt1_TwoSmallInt_NegativeValue;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTwoSmallIntNeg, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  { Negative SmallInts must survive the rcInt1 round-trip even though
    the eightbyte load is unsigned — sign restoration happens at field
    access time via LoadInstrFor on the destination buffer. }
  AssertEquals('negative SmallInts', '-1 -32000' + LE, Output);
end;

procedure TE2ERecordReturnTests.TestRun_RcInt1_TwoInteger_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTwoInteger, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('two integers', '123456 -789012' + LE, Output);
end;

procedure TE2ERecordReturnTests.TestRun_RcInt1_Int64_MaxValue;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcInt64Max, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Int64 max', '9223372036854775807' + LE, Output);
end;

procedure TE2ERecordReturnTests.TestRun_RcInt2_TwoInt64_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTwoInt64, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('two int64s', '111111111111 222222222222' + LE, Output);
end;

procedure TE2ERecordReturnTests.TestRun_RcInt2_IntegerPlusInt64;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcMixIntInt64, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('mixed Integer+Int64', '42 1000000000000' + LE, Output);
end;

procedure TE2ERecordReturnTests.TestRun_RcSSE1_Double_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcOneDouble, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('3.5 via xmm0', '3.5', Trim(Output));
end;

procedure TE2ERecordReturnTests.TestRun_RcSSE2_TwoDoubles_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTwoDouble, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('1.5 + -2.5 via xmm0:xmm1', '1.5' + LE + '-2.5', Trim(Output));
end;

procedure TE2ERecordReturnTests.TestRun_RcIntSSE_Int64Double_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcIntSSE, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Int64+Double via (rax, xmm0)', '42' + LE + '3.5', Trim(Output));
end;

procedure TE2ERecordReturnTests.TestRun_RcSSEInt_DoubleInt64_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcSSEInt, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Double+Int64 via (xmm0, rax)', '-1.5' + LE + '99', Trim(Output));
end;

procedure TE2ERecordReturnTests.TestRun_RcSSE1_Single_RoundTrip;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcOneSingle, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('2.5 via xmm0 as s', '2.5', Trim(Output));
end;

procedure TE2ERecordReturnTests.TestRun_RcInt2_NestedRecord_RoundTrip;
const
  Src = '''
    program P;
    type
      TInner = record X, Y: Integer; end;
      TOuter = record A: TInner; B: Integer; end;
    function MakeIt(X, Y, B: Integer): TOuter;
    begin
      Result.A.X := X;
      Result.A.Y := Y;
      Result.B := B
    end;
    var R: TOuter;
    begin
      R := MakeIt(10, 20, 30);
      WriteLn(R.A.X, ' ', R.A.Y, ' ', R.B)
    end.
    ''';
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(Src, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('nested record fields', '10 20 30' + LE, Output);
end;

procedure TE2ERecordReturnTests.TestRun_RcSSE1_TwoSingle_RoundTrip;
const
  Src = '''
    program P;
    type T2S = record A, B: Single; end;
    function MakeIt(A, B: Single): T2S;
    begin
      Result.A := A;
      Result.B := B
    end;
    var R: T2S;
    begin
      R := MakeIt(1.5, -2.5);
      WriteLn(R.A);
      WriteLn(R.B)
    end.
    ''';
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(Src, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('two Singles via xmm0', '1.5' + LE + '-2.5', Trim(Output));
end;

procedure TE2ERecordReturnTests.TestRun_ManagedField_StaysSret;
const
  Src = '''
    program P;
    type TS = record S: string; end;
    function MakeIt(S: string): TS;
    begin
      Result.S := S
    end;
    var R: TS;
    begin
      R := MakeIt('hello');
      WriteLn(R.S)
    end.
    ''';
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(Src, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('managed field stays on sret', 'hello' + LE, Output);
end;

initialization
  RegisterTest(TE2ERecordReturnTests);

end.
