{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.math;

{ E2E tests for math compiler builtins and the Math RTL unit.

  Compiler builtins (no unit needed):
    Sqrt, Ceil, Floor, Round, Trunc, Ln, Log2, Log10, Power,
    Sin, Cos, Tan, ArcTan, ArcTan2, IsNaN, IsInfinite.

  Math RTL unit (requires 'uses Math'):
    Min, Max, Sign, DivMod, InRange, EnsureRange, Pi. }

interface

uses
  bcl.testing, cp.test.e2e.base;

type
  TE2EMathTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    { --- Compiler builtins --- }

    { Sqrt }
    procedure TestRun_Sqrt_PositiveDouble;
    procedure TestRun_Sqrt_Zero;

    { Ceil / Floor / Round / Trunc }
    procedure TestRun_Ceil_Positive;
    procedure TestRun_Ceil_Negative;
    procedure TestRun_Floor_Positive;
    procedure TestRun_Floor_Negative;
    procedure TestRun_Round_HalfUp;
    procedure TestRun_Round_HalfDown;
    procedure TestRun_Trunc_Positive;
    procedure TestRun_Trunc_Negative;

    { Ln / Log2 / Log10 }
    procedure TestRun_Ln_E;
    procedure TestRun_Log2_PowerOfTwo;
    procedure TestRun_Log10_Hundred;

    { Power }
    procedure TestRun_Power_Square;
    procedure TestRun_Power_Zero_Exp;

    { Sin / Cos / Tan / ArcTan }
    procedure TestRun_Sin_Zero;
    procedure TestRun_Cos_Zero;
    procedure TestRun_Tan_Zero;
    procedure TestRun_ArcTan_Zero;

    { ArcTan2 }
    procedure TestRun_ArcTan2_OneOne;

    { IsNaN / IsInfinite }
    procedure TestRun_IsNaN_NaN;
    procedure TestRun_IsNaN_Normal;
    procedure TestRun_IsInfinite_Inf;
    procedure TestRun_IsInfinite_Normal;

    { --- Math RTL unit --- }

    { Min / Max -- Integer }
    procedure TestRun_Min_Integer_Picks_Smaller;
    procedure TestRun_Max_Integer_Picks_Larger;
    procedure TestRun_Min_Integer_Equal;

    { Min / Max -- Double }
    procedure TestRun_Min_Double_Picks_Smaller;
    procedure TestRun_Max_Double_Picks_Larger;

    { Sign }
    procedure TestRun_Sign_Positive;
    procedure TestRun_Sign_Negative;
    procedure TestRun_Sign_Zero;

    { DivMod }
    procedure TestRun_DivMod_Basic;
    procedure TestRun_DivMod_Exact;

    { InRange }
    procedure TestRun_InRange_Inside;
    procedure TestRun_InRange_AtBoundary;
    procedure TestRun_InRange_Outside;

    { EnsureRange }
    procedure TestRun_EnsureRange_Inside;
    procedure TestRun_EnsureRange_ClampLow;
    procedure TestRun_EnsureRange_ClampHigh;

    { Pi constant }
    procedure TestRun_Pi_Approx;
  end;

implementation

procedure TE2EMathTests.SetUp;
begin
  inherited SetUp;
  SetUpScratch('compiler/target/test-e2e-math');
end;

{ ------------------------------------------------------------------ }
{ Sqrt                                                                 }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Sqrt_PositiveDouble;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Double;
    begin
      R := Sqrt(4.0);
      WriteLn(DoubleToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('sqrt(4)', '2', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Sqrt_Zero;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Double;
    begin
      R := Sqrt(0.0);
      WriteLn(DoubleToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('sqrt(0)', '0', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Ceil / Floor / Round / Trunc                                         }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Ceil_Positive;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Ceil(2.3);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('ceil(2.3)', '3', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Ceil_Negative;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Ceil(-2.7);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('ceil(-2.7)', '-2', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Floor_Positive;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Floor(2.9);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('floor(2.9)', '2', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Floor_Negative;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Floor(-2.3);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('floor(-2.3)', '-3', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Round_HalfUp;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(2.5);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('round(2.5)', '3', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Round_HalfDown;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(-2.5);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('round(-2.5)', '-3', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Trunc_Positive;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Trunc(3.9);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('trunc(3.9)', '3', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Trunc_Negative;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Trunc(-3.9);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('trunc(-3.9)', '-3', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Ln / Log2 / Log10                                                    }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Ln_E;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(Ln(2.71828182845904523536));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('ln(e) approx 1', '1', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Log2_PowerOfTwo;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(Log2(8.0));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('log2(8)', '3', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Log10_Hundred;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(Log10(100.0));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('log10(100)', '2', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Power                                                                }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Power_Square;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(Power(3.0, 2.0));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('power(3,2)', '9', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Power_Zero_Exp;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(Power(5.0, 0.0));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('power(5,0)', '1', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Trig                                                                 }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Sin_Zero;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(Sin(0.0));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('sin(0)', '0', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Cos_Zero;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(Cos(0.0));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('cos(0)', '1', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Tan_Zero;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(Tan(0.0));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('tan(0)', '0', Trim(Output));
end;

procedure TE2EMathTests.TestRun_ArcTan_Zero;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Integer;
    begin
      R := Round(ArcTan(0.0));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('arctan(0)', '0', Trim(Output));
end;

procedure TE2EMathTests.TestRun_ArcTan2_OneOne;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var R: Double;
    begin
      { ArcTan2(1, 1) = pi/4, roughly 0.785 -- verify positive and < 1 }
      R := ArcTan2(1.0, 1.0);
      if (R > 0.7) and (R < 0.8) then WriteLn('ok') else WriteLn('fail')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('arctan2(1,1)', 'ok', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ IsNaN / IsInfinite                                                   }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_IsNaN_NaN;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var X: Double;
    begin
      X := 0.0 / 0.0;
      if IsNaN(X) then WriteLn('yes') else WriteLn('no')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('isnan(0/0)', 'yes', Trim(Output));
end;

procedure TE2EMathTests.TestRun_IsNaN_Normal;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var X: Double;
    begin
      X := 42.0;
      if IsNaN(X) then WriteLn('yes') else WriteLn('no')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('isnan(42)', 'no', Trim(Output));
end;

procedure TE2EMathTests.TestRun_IsInfinite_Inf;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var X: Double;
    begin
      X := 1.0 / 0.0;
      if IsInfinite(X) then WriteLn('yes') else WriteLn('no')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('isinfinite(1/0)', 'yes', Trim(Output));
end;

procedure TE2EMathTests.TestRun_IsInfinite_Normal;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(
    '''
    program P;
    var X: Double;
    begin
      X := 42.0;
      if IsInfinite(X) then WriteLn('yes') else WriteLn('no')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('isinfinite(42)', 'no', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Min / Max -- Integer                                                  }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Min_Integer_Picks_Smaller;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var A, B: Integer;
    begin A := 7; B := 3; WriteLn(IntToStr(Min(A, B))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('min(7,3)', '3', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Max_Integer_Picks_Larger;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var A, B: Integer;
    begin A := 7; B := 3; WriteLn(IntToStr(Max(A, B))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('max(7,3)', '7', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Min_Integer_Equal;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var A, B: Integer;
    begin A := 5; B := 5; WriteLn(IntToStr(Min(A, B))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('min(5,5)', '5', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Min / Max -- Double                                                   }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Min_Double_Picks_Smaller;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var A, B, R: Double;
    begin
      A := 1.5;
      B := 2.5;
      R := Min(A, B);
      if R = 1.5 then WriteLn('ok') else WriteLn('fail')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('min(1.5,2.5)', 'ok', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Max_Double_Picks_Larger;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var A, B, R: Double;
    begin
      A := 1.5;
      B := 2.5;
      R := Max(A, B);
      if R = 2.5 then WriteLn('ok') else WriteLn('fail')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('max(1.5,2.5)', 'ok', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Sign                                                                 }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Sign_Positive;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var X: Integer;
    begin X := 42; WriteLn(IntToStr(Sign(X))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('sign(42)', '1', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Sign_Negative;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var X: Integer;
    begin X := -7; WriteLn(IntToStr(Sign(X))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('sign(-7)', '-1', Trim(Output));
end;

procedure TE2EMathTests.TestRun_Sign_Zero;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var X: Integer;
    begin X := 0; WriteLn(IntToStr(Sign(X))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('sign(0)', '0', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ DivMod                                                               }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_DivMod_Basic;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var Q, R: Integer;
    begin
      DivMod(17, 5, Q, R);
      WriteLn(IntToStr(Q));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('divmod(17,5)', '3' + #10 + '2', Trim(Output));
end;

procedure TE2EMathTests.TestRun_DivMod_Exact;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var Q, R: Integer;
    begin
      DivMod(12, 4, Q, R);
      WriteLn(IntToStr(Q));
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('divmod(12,4)', '3' + #10 + '0', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ InRange                                                              }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_InRange_Inside;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var V, Lo, Hi: Integer;
    begin
      V := 5; Lo := 1; Hi := 10;
      if InRange(V, Lo, Hi) then WriteLn('yes') else WriteLn('no')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('inrange(5,1,10)', 'yes', Trim(Output));
end;

procedure TE2EMathTests.TestRun_InRange_AtBoundary;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var V, Lo, Hi: Integer;
    begin
      V := 1; Lo := 1; Hi := 10;
      if InRange(V, Lo, Hi) then WriteLn('yes') else WriteLn('no')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('inrange(1,1,10)', 'yes', Trim(Output));
end;

procedure TE2EMathTests.TestRun_InRange_Outside;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var V, Lo, Hi: Integer;
    begin
      V := 11; Lo := 1; Hi := 10;
      if InRange(V, Lo, Hi) then WriteLn('yes') else WriteLn('no')
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('inrange(11,1,10)', 'no', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ EnsureRange                                                          }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_EnsureRange_Inside;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var V, Lo, Hi: Integer;
    begin V := 5; Lo := 1; Hi := 10; WriteLn(IntToStr(EnsureRange(V, Lo, Hi))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('ensurerange(5,1,10)', '5', Trim(Output));
end;

procedure TE2EMathTests.TestRun_EnsureRange_ClampLow;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var V, Lo, Hi: Integer;
    begin V := -3; Lo := 1; Hi := 10; WriteLn(IntToStr(EnsureRange(V, Lo, Hi))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('ensurerange(-3,1,10)', '1', Trim(Output));
end;

procedure TE2EMathTests.TestRun_EnsureRange_ClampHigh;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var V, Lo, Hi: Integer;
    begin V := 15; Lo := 1; Hi := 10; WriteLn(IntToStr(EnsureRange(V, Lo, Hi))) end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('ensurerange(15,1,10)', '10', Trim(Output));
end;

{ ------------------------------------------------------------------ }
{ Pi constant                                                          }
{ ------------------------------------------------------------------ }

procedure TE2EMathTests.TestRun_Pi_Approx;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRunWithRTL(
    '''
    program P; uses Math;
    var R: Integer;
    begin
      { Pi is approximately 3.14159 -- Round gives 3 }
      R := Round(Pi);
      WriteLn(IntToStr(R))
    end.
    ''', Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('round(pi)', '3', Trim(Output));
end;

initialization
  RegisterTest(TE2EMathTests);

end.
