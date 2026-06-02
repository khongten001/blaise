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
    M1 — empty program compiles, links, and exits 0. }

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
  end;

implementation

procedure TE2ENativeTests.SetUp;
begin
  inherited SetUp;
  SetUpScratch('compiler/target/test-e2e-native');
end;

const
  SrcEmpty = '''
    program P;
    begin
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

initialization
  RegisterTest(TE2ENativeTests);

end.
