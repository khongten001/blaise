{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.interfaces;

{ End-to-end tests for interfaces — compile + run on BOTH backends.  Grew
  out of the test-hardening sweep; the existing interface tests were
  IR/semantic-only, so the generated dispatch code was never exercised. }

interface

uses
  SysUtils, blaise.testing, cp.test.e2e.base;

type
  TE2EInterfaceTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestRun_BasicDispatch;
    procedure TestRun_MethodWithArgs;
    procedure TestRun_PolymorphicThroughInterfaceVar;
    procedure TestRun_ClassImplementsTwoInterfaces;
    { Passing a class instance directly to an interface-typed parameter
      (implicit class->interface narrowing at the call site). }
    procedure TestRun_GlobalClassVar_ToInterfaceParam;
    procedure TestRun_LocalClassVar_ToInterfaceParam;
    procedure TestRun_ConstructorResult_ToInterfaceParam;
    procedure TestRun_ProcInterfaceParam;
  end;

implementation

const
  LE = #10;

procedure TE2EInterfaceTests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-interfaces');
end;

const
  SrcBasic = '''
    program Prg;
    type
      IGreeter = interface function Greet: string; end;
      TEng = class(IGreeter) function Greet: string; begin Result := 'hello' end; end;
    var g: IGreeter;
    begin g := TEng.Create(); WriteLn(g.Greet()) end.
    ''';

  SrcArgs = '''
    program Prg;
    type
      ICalc = interface function Add(A, B: Integer): Integer; end;
      TCalc = class(ICalc) function Add(A, B: Integer): Integer; begin Result := A + B end; end;
    var c: ICalc;
    begin c := TCalc.Create(); WriteLn(c.Add(15, 27)) end.
    ''';

  SrcPolymorphic = '''
    program Prg;
    type
      IShape = interface function Area: Integer; end;
      TSquare = class(IShape) FS: Integer; function Area: Integer; begin Result := FS * FS end; end;
      TRect = class(IShape) FW, FH: Integer; function Area: Integer; begin Result := FW * FH end; end;
    var s: IShape; total: Integer;
    begin
      total := 0;
      s := TSquare.Create(); TSquare(s).FS := 4; total := total + s.Area();
      s := TRect.Create(); TRect(s).FW := 3; TRect(s).FH := 5; total := total + s.Area();
      WriteLn(total)
    end.
    ''';

  SrcTwoIntfs = '''
    program Prg;
    type
      IA = interface function NA: Integer; end;
      IB = interface function NB: Integer; end;
      TBoth = class(IA, IB) function NA: Integer; begin Result := 1 end; function NB: Integer; begin Result := 2 end; end;
    var a: IA; b: IB; o: TBoth;
    begin o := TBoth.Create(); a := o; b := o; WriteLn(a.NA() + b.NB()) end.
    ''';

  SrcGlobalToParam = '''
    program Prg;
    type INamed = interface function Name: string; end;
      TThing = class(INamed) function Name: string; begin Result := 'thing' end; end;
    function Describe(N: INamed): string; begin Result := 'I am ' + N.Name() end;
    var t: TThing;
    begin t := TThing.Create(); WriteLn(Describe(t)) end.
    ''';

  SrcLocalToParam = '''
    program Prg;
    type INamed = interface function Name: string; end;
      TThing = class(INamed) function Name: string; begin Result := 'thing' end; end;
    function Describe(N: INamed): string; begin Result := 'I am ' + N.Name() end;
    procedure Run; var t: TThing; begin t := TThing.Create(); WriteLn(Describe(t)) end;
    begin Run() end.
    ''';

  SrcCtorToParam = '''
    program Prg;
    type INamed = interface function Name: string; end;
      TThing = class(INamed) function Name: string; begin Result := 'thing' end; end;
    function Describe(N: INamed): string; begin Result := 'I am ' + N.Name() end;
    begin WriteLn(Describe(TThing.Create())) end.
    ''';

  SrcProcParam = '''
    program Prg;
    type ILog = interface procedure Emit; end;
      TC = class(ILog) procedure Emit; begin WriteLn('emit') end; end;
    procedure Use(L: ILog); begin L.Emit() end;
    var c: TC;
    begin c := TC.Create(); Use(c) end.
    ''';

procedure TE2EInterfaceTests.TestRun_BasicDispatch;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcBasic, 'hello' + LE, 0);
end;

procedure TE2EInterfaceTests.TestRun_MethodWithArgs;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcArgs, '42' + LE, 0);
end;

procedure TE2EInterfaceTests.TestRun_PolymorphicThroughInterfaceVar;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcPolymorphic, '31' + LE, 0);
end;

procedure TE2EInterfaceTests.TestRun_ClassImplementsTwoInterfaces;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcTwoIntfs, '3' + LE, 0);
end;

procedure TE2EInterfaceTests.TestRun_GlobalClassVar_ToInterfaceParam;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcGlobalToParam, 'I am thing' + LE, 0);
end;

procedure TE2EInterfaceTests.TestRun_LocalClassVar_ToInterfaceParam;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcLocalToParam, 'I am thing' + LE, 0);
end;

procedure TE2EInterfaceTests.TestRun_ConstructorResult_ToInterfaceParam;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcCtorToParam, 'I am thing' + LE, 0);
end;

procedure TE2EInterfaceTests.TestRun_ProcInterfaceParam;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcProcParam, 'emit' + LE, 0);
end;

initialization
  RegisterTest(TE2EInterfaceTests);

end.
