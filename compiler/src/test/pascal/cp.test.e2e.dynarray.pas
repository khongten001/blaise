{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.dynarray;

{ End-to-end tests for dynamic arrays — compile + run on BOTH backends.
  Grew out of the test-hardening sweep (dynarray was IR-only).  Includes
  SetLength on an array element (SetLength(m[i], n)), which enables ragged
  2-D dynamic arrays and was previously rejected. }

interface

uses
  SysUtils, blaise.testing, cp.test.e2e.base;

type
  TE2EDynArrayTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestRun_SetLengthFillSum;
    procedure TestRun_LengthAndHigh;
    procedure TestRun_GrowPreservesContents;
    procedure TestRun_ArrayOfString;
    procedure TestRun_ReferenceSemantics;
    procedure TestRun_ReturnByValue;
    { SetLength on an element (ragged 2-D dynamic array). }
    procedure TestRun_SetLengthOnElement_Ragged;
    procedure TestRun_SetLengthOnElement_FillViaRow;
  end;

implementation

const
  LE = #10;

procedure TE2EDynArrayTests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-dynarray');
end;

const
  SrcFillSum = '''
    program Prg;
    var a: array of Integer; i, sum: Integer;
    begin SetLength(a, 5); for i := 0 to 4 do a[i] := i * 2;
      sum := 0; for i := 0 to High(a) do sum := sum + a[i]; WriteLn(sum) end.
    ''';

  SrcLenHigh = '''
    program Prg;
    var a: array of Integer;
    begin SetLength(a, 7); WriteLn(Length(a), ' ', High(a)) end.
    ''';

  SrcGrow = '''
    program Prg;
    var a: array of Integer; i: Integer;
    begin SetLength(a, 3); for i := 0 to 2 do a[i] := i + 1;
      SetLength(a, 6); WriteLn(a[0], a[1], a[2], ' ', Length(a)) end.
    ''';

  SrcOfString = '''
    program Prg;
    var a: array of string; i: Integer;
    begin SetLength(a, 3); a[0] := 'x'; a[1] := 'y'; a[2] := 'z';
      for i := 0 to 2 do Write(a[i]); WriteLn end.
    ''';

  SrcRefSem = '''
    program Prg;
    var a, b: array of Integer;
    begin SetLength(a, 3); a[0] := 7; b := a; b[0] := 99; WriteLn(a[0]) end.
    ''';

  SrcReturn = '''
    program Prg;
    type TIntArr = array of Integer;
    function MakeArr(n: Integer): TIntArr; var i: Integer; begin SetLength(Result, n); for i := 0 to n-1 do Result[i] := i end;
    var a: TIntArr;
    begin a := MakeArr(5); WriteLn(Length(a), ' ', a[4]) end.
    ''';

  SrcRagged = '''
    program Prg;
    var m: array of array of Integer;
    begin SetLength(m, 3); SetLength(m[0], 1); SetLength(m[1], 2); SetLength(m[2], 3);
      WriteLn(Length(m[0]), Length(m[1]), Length(m[2])) end.
    ''';

  SrcFillViaRow = '''
    program Prg;
    var m: array of array of Integer; row: array of Integer; i, sum: Integer;
    begin SetLength(m, 2); SetLength(m[0], 3);
      row := m[0]; for i := 0 to 2 do row[i] := i + 1;
      sum := 0; for i := 0 to 2 do sum := sum + m[0][i];
      WriteLn(sum) end.
    ''';

procedure TE2EDynArrayTests.TestRun_SetLengthFillSum;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcFillSum, '20' + LE, 0);
end;

procedure TE2EDynArrayTests.TestRun_LengthAndHigh;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcLenHigh, '7 6' + LE, 0);
end;

procedure TE2EDynArrayTests.TestRun_GrowPreservesContents;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcGrow, '123 6' + LE, 0);
end;

procedure TE2EDynArrayTests.TestRun_ArrayOfString;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcOfString, 'xyz' + LE, 0);
end;

procedure TE2EDynArrayTests.TestRun_ReferenceSemantics;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcRefSem, '99' + LE, 0);
end;

procedure TE2EDynArrayTests.TestRun_ReturnByValue;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcReturn, '5 4' + LE, 0);
end;

procedure TE2EDynArrayTests.TestRun_SetLengthOnElement_Ragged;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcRagged, '123' + LE, 0);
end;

procedure TE2EDynArrayTests.TestRun_SetLengthOnElement_FillViaRow;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcFillViaRow, '6' + LE, 0);
end;

initialization
  RegisterTest(TE2EDynArrayTests);

end.
