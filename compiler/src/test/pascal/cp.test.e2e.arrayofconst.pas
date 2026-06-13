{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.arrayofconst;

{ E2E tests for 'array of const': compile -> run on every backend (QBE +
  native).  Exercises the call-site TVarRec boxing and the callee reading
  each element back via the cast API.  Parser/semantic/IR tests live in
  cp.test.arrayofconst.pas. }

interface

uses
  classes, blaise.testing, cp.test.e2e.base;

type
  [Threaded]
  TE2EArrayOfConstTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestRun_Tags;
    procedure TestRun_ReadValues;
    procedure TestRun_EmptyList;
    procedure TestRun_HomogeneousList;
    procedure TestRun_StringVariableBorrow;
    procedure TestRun_Count;
  end;

implementation

procedure TE2EArrayOfConstTests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-arrayofconst')
end;

procedure TE2EArrayOfConstTests.TestRun_Tags;
const Src =
  '''
  program P;
  procedure Dump(args: array of const);
  var i: Integer;
  begin
    for i := 0 to High(args) do
      WriteLn(args[i].VType)
  end;
  begin
    Dump([42, 'hi', True, 3.5])
  end.
  ''';
var LE: string;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  LE := LineEnding;
  { vtInteger=0, vtAnsiString=20, vtBoolean=1, vtExtended=3 }
  AssertRunsOnAll(Src, '0' + LE + '20' + LE + '1' + LE + '3' + LE, 0);
end;

procedure TE2EArrayOfConstTests.TestRun_ReadValues;
const Src =
  '''
  program P;
  type PDouble = ^Double;
  procedure Dump(args: array of const);
  var i: Integer;
  begin
    for i := 0 to High(args) do
      case args[i].VType of
        vtInteger:    WriteLn(Integer(args[i].VValue));
        vtBoolean:    if Boolean(args[i].VValue) then WriteLn('true')
                      else WriteLn('false');
        vtExtended:   WriteLn(PDouble(args[i].VValue)^);
        vtAnsiString: WriteLn(string(PChar(args[i].VValue)));
      end
  end;
  begin
    Dump([42, 'hello', True, 3.5, 100])
  end.
  ''';
var LE: string;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  LE := LineEnding;
  AssertRunsOnAll(Src,
    '42' + LE + 'hello' + LE + 'true' + LE + '3.5' + LE + '100' + LE, 0);
end;

procedure TE2EArrayOfConstTests.TestRun_EmptyList;
const Src =
  '''
  program P;
  function Count(args: array of const): Integer;
  begin
    Result := High(args) + 1
  end;
  begin
    WriteLn(Count([]))
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '0' + LineEnding, 0);
end;

procedure TE2EArrayOfConstTests.TestRun_HomogeneousList;
const Src =
  '''
  program P;
  function SumInts(args: array of const): Integer;
  var i: Integer;
  begin
    Result := 0;
    for i := 0 to High(args) do
      if args[i].VType = vtInteger then
        Result := Result + Integer(args[i].VValue)
  end;
  begin
    WriteLn(SumInts([10, 20, 30]))
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '60' + LineEnding, 0);
end;

procedure TE2EArrayOfConstTests.TestRun_StringVariableBorrow;
const Src =
  '''
  program P;
  procedure Show(args: array of const);
  var i: Integer;
  begin
    for i := 0 to High(args) do
      if args[i].VType = vtAnsiString then
        WriteLn(string(PChar(args[i].VValue)))
  end;
  var S: string;
  begin
    S := 'dyn' + 'amic';
    Show([S, 'literal'])
  end.
  ''';
var LE: string;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  LE := LineEnding;
  AssertRunsOnAll(Src, 'dynamic' + LE + 'literal' + LE, 0);
end;

procedure TE2EArrayOfConstTests.TestRun_Count;
const Src =
  '''
  program P;
  function Count(args: array of const): Integer;
  begin
    Result := High(args) + 1
  end;
  begin
    WriteLn(Count([1, 'two', 3.0, True, nil]))
  end.
  ''';
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertRunsOnAll(Src, '5' + LineEnding, 0);
end;

initialization
  RegisterTest(TE2EArrayOfConstTests);

end.
