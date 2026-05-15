{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.exceptions;

{ E2E tests for try/finally, try/except, raise, and typed exception handlers. }

interface

uses
  blaise.testing, cp.test.e2e.base;

type
  TE2EExceptionTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    { Regression for the alloc16-32 exception-frame bug:
      a bare try/finally with no locals, virtuals, or RTL use. }
    procedure TestRun_BareTryFinally;

    { Locals live in the stack frame around the exception frame.
      If the exception frame is undersized, setjmp clobbers them. }
    procedure TestRun_TryFinally_PreservesLocals;

    { Exception frame must not corrupt caller state when nested. }
    procedure TestRun_NestedTryFinally;

    { Virtual dispatch in expression position inside try/finally. }
    procedure TestRun_VirtualDispatchInsideTryFinally;

    { Typed except handlers }
    procedure TestRun_TypedExcept_CorrectHandlerMatched;
    procedure TestRun_TypedExcept_SubclassMatchesParentHandler;
    procedure TestRun_TypedExcept_UnmatchedReraises;
    procedure TestRun_TypedExcept_BareRaisePropagatesToOuter;
    procedure TestRun_TypedExcept_ElseBodyRunsWhenNoMatch;
  end;

implementation

procedure TE2EExceptionTests.SetUp;
begin
  inherited SetUp;
  SetUpScratch('compiler/target/test-e2e-exceptions');
end;

const
  LE = #10;

  SrcBareTryFinally = '''
    program P;
    begin
      try
        WriteLn('in_try')
      finally
        WriteLn('in_finally')
      end
    end.
    ''';

  SrcPreservesLocals = '''
    program P;
    var A, B, C: Integer;
    begin
      A := 11;
      B := 22;
      C := 33;
      try
        WriteLn(A);
        WriteLn(B);
        WriteLn(C)
      finally
        WriteLn(A + B + C)
      end
    end.
    ''';

  SrcNestedTryFinally = '''
    program P;
    begin
      try
        try
          WriteLn('inner_try')
        finally
          WriteLn('inner_fin')
        end
      finally
        WriteLn('outer_fin')
      end
    end.
    ''';

  SrcVirtualDispatchInTry = '''
    program P;
    type
      TNode = class
        function GetTag: Integer; virtual;
      end;
      TMarkedNode = class(TNode)
        function GetTag: Integer; override;
      end;
    function TNode.GetTag: Integer;
    begin Result := 0 end;
    function TMarkedNode.GetTag: Integer;
    begin Result := 1 end;
    var N: TNode; T: Integer;
    begin
      N := TMarkedNode.Create;
      try
        T := N.GetTag();
        WriteLn(T)
      finally
        N.Free
      end
    end.
    ''';

  SrcExcBase =
    '''
        program P;
        type
          Exception = class
            FMessage: string;
            property Message: string read FMessage;
          end;
          EFoo = class(Exception) end;
          EBar = class(EFoo) end;
        ''';

  SrcTypedExceptCorrect =
    SrcExcBase +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            raise EFoo.Create
          except
            on E: EFoo do X := 42;
            on E: Exception do X := 1
          end;
          WriteLn(X)
        end.
        ''';

  SrcTypedExceptSubclass =
    SrcExcBase +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            raise EBar.Create
          except
            on E: EFoo do X := 7
          end;
          WriteLn(X)
        end.
        ''';

  SrcTypedExceptElseRun =
    SrcExcBase +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            raise EFoo.Create
          except
            on E: EBar do X := 9
            else X := 5
          end;
          WriteLn(X)
        end.
        ''';

  SrcTypedExceptBareRaise =
    SrcExcBase +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            try
              raise EFoo.Create
            except
              on E: EFoo do
              begin
                X := 1;
                raise
              end
            end
          except
            on E: EFoo do X := 2
          end;
          WriteLn(X)
        end.
        ''';

  SrcTypedExceptUnmatched =
    SrcExcBase +
    '''
        var X: Integer;
        begin
          X := 0;
          try
            try
              raise EFoo.Create
            except
              on E: EBar do X := 9
            end
          except
            on E: EFoo do X := 3
          end;
          WriteLn(X)
        end.
        ''';

procedure TE2EExceptionTests.TestRun_BareTryFinally;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcBareTryFinally, Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('stdout', 'in_try' + LE + 'in_finally' + LE, Output);
end;

procedure TE2EExceptionTests.TestRun_TryFinally_PreservesLocals;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcPreservesLocals, Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('locals preserved',
    '11' + LE + '22' + LE + '33' + LE + '66' + LE, Output);
end;

procedure TE2EExceptionTests.TestRun_NestedTryFinally;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcNestedTryFinally, Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('stdout',
    'inner_try' + LE + 'inner_fin' + LE + 'outer_fin' + LE, Output);
end;

procedure TE2EExceptionTests.TestRun_VirtualDispatchInsideTryFinally;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcVirtualDispatchInTry, Output, RCode));
  AssertEquals('exit code', 0, RCode);
  AssertEquals('stdout (virtual -> marked -> 1)', '1' + LE, Output);
end;

procedure TE2EExceptionTests.TestRun_TypedExcept_CorrectHandlerMatched;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptCorrect, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('EFoo handler ran', '42', Trim(Output));
end;

procedure TE2EExceptionTests.TestRun_TypedExcept_SubclassMatchesParentHandler;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptSubclass, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('EBar matches EFoo handler', '7', Trim(Output));
end;

procedure TE2EExceptionTests.TestRun_TypedExcept_UnmatchedReraises;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptUnmatched, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('unmatched inner re-raises to outer', '3', Trim(Output));
end;

procedure TE2EExceptionTests.TestRun_TypedExcept_BareRaisePropagatesToOuter;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptBareRaise, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('bare raise propagated to outer handler', '2', Trim(Output));
end;

procedure TE2EExceptionTests.TestRun_TypedExcept_ElseBodyRunsWhenNoMatch;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedExceptElseRun, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('else body ran when no handler matched', '5', Trim(Output));
end;

initialization
  RegisterTest(TE2EExceptionTests);

end.
