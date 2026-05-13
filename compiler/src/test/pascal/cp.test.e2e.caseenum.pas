{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.caseenum;

{ E2E tests for case statements and enum types. }

interface

uses
  bcl.testing, classes, cp.test.e2e.base;

type
  TE2ECaseEnumTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestRun_Case_IntegerBranch;
    procedure TestRun_Case_ElseBranch;
    procedure TestRun_Enum_OrdinalValues;
    procedure TestRun_Enum_InCase;
  end;

implementation

procedure TE2ECaseEnumTests.SetUp;
begin
  inherited SetUp;
  SetUpScratch('compiler/target/test-e2e-caseenum');
end;

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

procedure TE2ECaseEnumTests.TestRun_Case_IntegerBranch;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcCaseInt, Output, RCode));
  AssertEquals('case N=2 -> 22', '22', Trim(Output));
end;

procedure TE2ECaseEnumTests.TestRun_Case_ElseBranch;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcCaseElse, Output, RCode));
  AssertEquals('case N=7 -> else -> 99', '99', Trim(Output));
end;

procedure TE2ECaseEnumTests.TestRun_Enum_OrdinalValues;
var Output: string; RCode: Integer; Lines: TStringList;
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

procedure TE2ECaseEnumTests.TestRun_Enum_InCase;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcEnumCase, Output, RCode));
  AssertEquals('dEast=2', '2', Trim(Output));
end;

initialization
  RegisterTest(TE2ECaseEnumTests);

end.
