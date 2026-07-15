{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit Testing.Tests;

{ Self-tests for the blaise.testing framework.

  Regression guard for the 2026-07-15 bug: an exception raised inside
  TTestCase.SetUp escaped TTestCase.Run entirely (SetUp was called
  outside the exception-mapping try..except), aborting the whole test
  runner with SIGABRT and no output.  JUnit semantics are required: a
  SetUp/TearDown exception marks THAT test as an ERROR and the run
  continues.

  The misbehaving cases below are driven manually against a private
  TTestResult — they are deliberately NOT registered. }

interface

uses
  SysUtils, blaise.testing;

type
  { Helper: SetUp raises; the body must never run; TearDown must still
    run (JUnit semantics). }
  TSetUpBoomCase = class(TTestCase)
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestBody;
  end;

  { Helper: body passes; TearDown raises. }
  TTearDownBoomCase = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    procedure TestBody;
  end;

  TFrameworkTests = class(TTestCase)
  published
    procedure TestSetUpException_IsReportedAsError;
    procedure TestSetUpException_BodyDoesNotRun;
    procedure TestSetUpException_TearDownStillRuns;
    procedure TestTearDownException_IsReportedAsError;
  end;

implementation

var
  GBodyRan: Boolean;
  GTearDownRan: Boolean;

procedure TSetUpBoomCase.SetUp;
begin
  raise Exception.Create('boom in SetUp');
end;

procedure TSetUpBoomCase.TearDown;
begin
  GTearDownRan := True;
end;

procedure TSetUpBoomCase.TestBody;
begin
  GBodyRan := True;
end;

procedure TTearDownBoomCase.TearDown;
begin
  GTearDownRan := True;
  raise Exception.Create('boom in TearDown');
end;

procedure TTearDownBoomCase.TestBody;
begin
  GBodyRan := True;
end;

procedure TFrameworkTests.TestSetUpException_IsReportedAsError;
var
  C: TSetUpBoomCase;
  R: TTestResult;
begin
  C := TSetUpBoomCase.Create('TestBody');
  C.SetClassName('TSetUpBoomCase');
  R := TTestResult.Create();
  C.Run(R);   { must NOT propagate the exception }
  AssertEquals('tests', 1, R.NumberOfTests);
  AssertEquals('errors', 1, R.NumberOfErrors);
  AssertEquals('failures', 0, R.NumberOfFailures);
end;

procedure TFrameworkTests.TestSetUpException_BodyDoesNotRun;
var
  C: TSetUpBoomCase;
  R: TTestResult;
begin
  GBodyRan := False;
  C := TSetUpBoomCase.Create('TestBody');
  C.SetClassName('TSetUpBoomCase');
  R := TTestResult.Create();
  C.Run(R);
  AssertFalse('body must not run when SetUp fails', GBodyRan);
end;

procedure TFrameworkTests.TestSetUpException_TearDownStillRuns;
var
  C: TSetUpBoomCase;
  R: TTestResult;
begin
  GTearDownRan := False;
  C := TSetUpBoomCase.Create('TestBody');
  C.SetClassName('TSetUpBoomCase');
  R := TTestResult.Create();
  C.Run(R);
  AssertTrue('TearDown must run even when SetUp fails', GTearDownRan);
end;

procedure TFrameworkTests.TestTearDownException_IsReportedAsError;
var
  C: TTearDownBoomCase;
  R: TTestResult;
begin
  GBodyRan := False;
  GTearDownRan := False;
  C := TTearDownBoomCase.Create('TestBody');
  C.SetClassName('TTearDownBoomCase');
  R := TTestResult.Create();
  C.Run(R);   { must NOT propagate the exception }
  AssertTrue('body ran', GBodyRan);
  AssertTrue('teardown ran', GTearDownRan);
  AssertEquals('errors', 1, R.NumberOfErrors);
end;

initialization
  RegisterTest(TFrameworkTests);

end.
