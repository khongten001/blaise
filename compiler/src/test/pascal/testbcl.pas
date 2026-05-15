{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{
  testbcl — end-to-end smoke test for blaise.testing + blaise.testing.runner.text.

  Declares one TTestCase fixture with two published methods (one passes,
  one fails), registers the class via RegisterTest, then hands off to
  the text runner.  The runner is responsible for walking the
  published-method table, instantiating each test, and printing the
  PASS / FAIL summary.

  Successful run prints:

    FAIL (2 tests, 1 failures, 0 errors)
    Failures:
      TestFailing: deliberate failure Expected: 42  Actual: 2
}

program testbcl;

{$mode objfpc}{$H+}

uses
  blaise.testing,
  blaise.testing.runner.text;

type
  TSampleTests = class(TTestCase)
  published
    procedure TestPassing;
    procedure TestFailing;
  end;

procedure TSampleTests.TestPassing;
begin
  Self.AssertEquals(2, 1 + 1, 'integer addition');
  Self.AssertTrue(True, 'true is true');
end;

procedure TSampleTests.TestFailing;
begin
  Self.AssertEquals(42, 1 + 1, 'deliberate failure');
end;

begin
  RegisterTest(TSampleTests);
  Halt(RunAll);
end.
