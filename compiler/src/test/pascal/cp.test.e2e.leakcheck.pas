{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.leakcheck;

{ E2E tests for the --debug leak tracker.
  Verifies that _LeakTrackerEnable is activated in debug builds,
  that leaked objects are reported on exit, and that cleanly-released
  objects produce no report. }

interface

uses
  blaise.testing, cp.test.e2e.base;

type
  [Threaded]
  TE2ELeakCheckTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestDebug_NoLeak_NoReport;
    procedure TestDebug_ExceptionHandlerVar_NoLeakNoOverRelease;
    procedure TestDebug_ConstructorWithArgs_NoDoubleAddRef;
    procedure TestDebug_LeakedObject_ReportedOnExit;
    procedure TestDebug_MultipleLeaks_AllReported;
    procedure TestDebug_CycleRetained_Reported;
    procedure TestRelease_NoReport_WhenDebugOff;
    procedure TestDebug_LeakReport_IncludesUnitAndLine;
    procedure TestDebug_LeakReport_IncludesUnitAndLine_Native;
    procedure TestDebug_StringLeak_Reported;
    procedure TestDebug_StringClean_NoReport;

    { obj.Field := MakeClass() consumes the call's +1 — no leak per store. }
    procedure TestDebug_ClassFieldFromCall_NoLeak;

    { local := MakeClass() consumes the call's +1 — no leak per assignment.
      Pins the native class-assignment AddRef elision against the QBE backend. }
    procedure TestDebug_FuncReturnAssign_NoLeak;
    { MakeClass() called in statement position discards its +1 result — it must
      be released or one object leaks per call.  Both backends. }
    procedure TestDebug_DiscardedClassReturn_NoLeak;
    { X := Call().ClassField must keep the field value valid past the base
      release (QBE use-after-free before the deferred-base-release fix) and not
      leak on QBE.  Correct output (42) is asserted on BOTH backends. }
    procedure TestDebug_CallResultClassFieldRead_NoUseAfterFree;
    { A deep chain MakeIt().A.B.N reads a scalar off a base that is itself two
      field-reads off an owned transient.  Each intermediate owned transient's
      release must be deferred to statement end so none leak, while the value
      still survives (no UAF).  Both backends (BUG-003). }
    procedure TestDebug_DeepChainFieldRead_NoLeak;
    { Multiple same-named typed handlers share one slot — no over-release. }
    procedure TestDebug_MultiHandlerVar_NoOverRelease;
    { for-in over a TList: GetEnumerator's +1 result must be transferred
      into the loop slot, not re-retained — one enumerator leaked per
      loop otherwise. }
    procedure TestDebug_ForInEnumerator_NoLeak;
    procedure TestDebug_ForInEnumerator_NoLeak_Native;
    { Objects allocated inside generic method bodies must be attributed
      to the unit that DECLARES the template (the line number already
      refers to the template source), not the instantiating unit. }
    procedure TestDebug_GenericAllocSite_ReportsDefiningUnit;
    procedure TestDebug_GenericAllocSite_ReportsDefiningUnit_Native;
    { An interface-returning call passed directly as an argument — Show(Make())
      — hands the callee an owned (+1) fat pointer it borrows; the caller must
      release it after the call or one instance leaks. }
    procedure TestDebug_IntfCallResultArg_NoLeak;
    procedure TestDebug_IntfCallResultArg_NoLeak_Native;
    { A call/getter result used as a field-access receiver must be released
      after the field load.  L[I].HitPoints — the TList<T>.Get getter returns
      +1, the field is read, then the transient base must be released. }
    procedure TestDebug_ReceiverFieldAccess_NoLeak;
    { A static array of interfaces (array[0..N] of IFoo): the elements are
      ARC-managed but the scope-exit cleanup previously skipped tyStaticArray
      locals entirely, so every stored element leaked on BOTH backends.  The
      fix releases each element at scope exit. }
    procedure TestDebug_StaticArrayOfInterface_NoLeak;
    { A string-returning call/getter used DIRECTLY as a Write/WriteLn argument
      (WriteLn(GetBar)) returns a fresh +1 string that _SysWriteStr only borrows.
      EmitWrite previously never released it, leaking one string per call.  The
      fix releases the owned string transient after the write (both backends). }
    procedure TestDebug_WriteLnCallArg_NoLeak;
    { Anonymous-method capture (Phase 2): the heap environment record must be
      allocated once and released exactly once — the enclosing frame drops its
      reference at exit and the escaped closure drops the last one when the
      closure slot is released. }
    procedure TestDebug_ClosureEnv_ReleasedExactlyOnce;
    { Phase 3: a closure capturing Self stored in the receiver's OWN field
      forms the documented strong cycle Self -> field -> env -> Self.  It
      MUST leak (asserted) until [Weak] capture (Phase 5) provides the
      break; this pins the behaviour as intentional. }
    procedure TestDebug_ClosureSelfCycle_LeaksByDesign;
    { Phase 3: a coerced method pointer strong-retains its receiver; when
      the closure slot dies, the receiver must be released — no leak. }
    procedure TestDebug_MethodPtrCoercion_NoLeak;
    { A captured string is an ARC slot inside the env record: the env cleanup
      proc must release it, and closure-body reassignment must go through the
      string retain/release store path. }
    procedure TestDebug_ClosureCapturedString_NoLeak;
  end;

implementation

procedure TE2ELeakCheckTests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-leakcheck');
end;

const
  LE = #10;

  { A clean program: object is created and properly released by ARC at scope exit. }
  SrcNoLeak = '''
    program P;
    uses runtime.arc;
    type
      TBox = class
        Value: Integer;
      end;
    var
      B: TBox;
    begin
      B := TBox.Create();
      B.Value := 99;
      WriteLn(B.Value)
    end.
    ''';

  { Exception handler variable: `on E: T do` binds the caught exception to E.
    E is a class local that scope-exit ARC releases, so the handler must retain
    the exception on bind.  Without that AddRef the exception (created at rc=0
    by `raise EFoo.Create`) is over-released to a negative refcount — a
    use-after-free.  With the fix it is freed exactly once: no leak, no crash. }
  SrcExceptionHandlerVar = '''
    program P;
    uses runtime.arc;
    type
      Exception = class
        FMessage: string;
      end;
      EFoo = class(Exception) end;
    procedure DoIt;
    begin
      try
        raise EFoo.Create()
      except
        on E: EFoo do
          WriteLn('caught')
      end
    end;
    begin
      DoIt();
      WriteLn('done')
    end.
    ''';

  { Constructor with args — must not double-AddRef; object must be clean after scope. }
  SrcConstructorWithArgs = '''
    program P;
    uses runtime.arc;
    type
      TBox = class
        Value: Integer;
        constructor Create(V: Integer);
      end;
    constructor TBox.Create(V: Integer);
    begin
      Self.Value := V
    end;
    var
      B: TBox;
    begin
      B := TBox.Create(42);
      WriteLn(B.Value)
    end.
    ''';

  { Deliberately leaked: object assigned to a raw Pointer, bypassing ARC release. }
  SrcOneLeak = '''
    program P;
    uses runtime.arc;
    type
      TBox = class
        Value: Integer;
      end;
    var
      B: TBox;
    begin
      B := TBox.Create();
      B.Value := 7;
      _ClassAddRef(Pointer(B));
      { Artificial extra addref: rc=2.  Scope-exit releases B (rc=1),
        but the unbalanced addref keeps the object alive — leak. }
      WriteLn('done')
    end.
    ''';

  { Two distinct classes leaked to verify count and class-name reporting. }
  SrcTwoLeaks = '''
    program P;
    uses runtime.arc;
    type
      TAlpha = class
        X: Integer;
      end;
      TBeta = class
        Y: Integer;
      end;
    var
      A: TAlpha;
      B: TBeta;
    begin
      A := TAlpha.Create();
      B := TBeta.Create();
      _ClassAddRef(Pointer(A));
      _ClassAddRef(Pointer(B));
      { Artificial extra addref on each: scope-exit releases both
        (rc 2->1) but the unbalanced addref keeps them alive. }
      WriteLn('done')
    end.
    ''';

  { Reference cycle: each object holds the other — both leak. }
  SrcCycleLeak = '''
    program P;
    uses runtime.arc;
    type
      TNode = class
        Other: TNode;
      end;
    var
      X, Y: TNode;
    begin
      X := TNode.Create();
      Y := TNode.Create();
      X.Other := Y;
      Y.Other := X;
      { X and Y each hold refcount >= 2 due to the cycle; when the local
        vars go out of scope the refcount drops to 1, not 0 — both leak. }
      WriteLn('done')
    end.
    ''';

  { Leak with allocation-site info: the report must include the unit name and
    line number where the leaking TBox.Create() call was made. }
  SrcLeakWithSite = '''
    program LeakSite;
    uses runtime.arc;
    type
      TBox = class
        Value: Integer;
      end;
    var
      B: TBox;
    begin
      B := TBox.Create();
      _ClassAddRef(Pointer(B));
      WriteLn('done')
    end.
    ''';

  { Leaked string: concatenation produces a heap-allocated string (non-immortal).
    Extra AddRef prevents scope-exit release from freeing it. }
  SrcStringLeak = '''
    program P;
    uses runtime.arc;
    var
      S: string;
    begin
      S := 'hel' + 'lo';
      _StringAddRef(Pointer(S));
      WriteLn('done')
    end.
    ''';

  { Clean string usage: no leak expected — scope-exit ARC releases properly. }
  SrcStringClean = '''
    program P;
    uses runtime.arc;
    var
      S: string;
    begin
      S := 'hello';
      WriteLn(S)
    end.
    ''';

{ ------------------------------------------------------------------ }

const
  SrcForInEnum = '''
    program P;
    uses generics.collections;
    var
      L: TList<Integer>;
      I, Total: Integer;
    begin
      L := TList<Integer>.Create;
      L.Add(5);
      L.Add(4);
      Total := 0;
      for I in L do
        Total := Total + I;
      WriteLn(Total);
    end.
    ''';

procedure TE2ELeakCheckTests.TestDebug_ForInEnumerator_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebug(SrcForInEnum, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', '9' + LE, Output);
  AssertTrue('no leak report, got: ' + Output, Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_ForInEnumerator_NoLeak_Native;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebugOn(beNative, SrcForInEnum, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', '9' + LE, Output);
  AssertTrue('no leak report, got: ' + Output, Pos('leak', Output) < 0);
end;

const
  { The enumerator is allocated INSIDE TList<T>.GetEnumerator — a generic
    method body declared in generics.collections.pas.  The extra AddRef
    keeps it alive past scope exit, so the leak report must show its
    allocation site as 'generics.collections:<line>', not '<program>:<line>'. }
  SrcGenericAllocSite = '''
    program LeakGen;
    uses runtime.arc, generics.collections;
    var
      L: TList<Integer>;
      E: TListEnumerator<Integer>;
    begin
      L := TList<Integer>.Create();
      L.Add(1);
      E := L.GetEnumerator();
      _ClassAddRef(Pointer(E));
      WriteLn('done')
    end.
    ''';

procedure TE2ELeakCheckTests.TestDebug_GenericAllocSite_ReportsDefiningUnit;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebugOn(beQBE, SrcGenericAllocSite, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('leak header', Pos('Blaise leak report', Output) >= 0);
  AssertTrue('enumerator class reported', Pos('TListEnumerator', Output) >= 0);
  AssertTrue('defining unit in report, got: ' + Output,
    Pos(' at Generics.Collections:', Output) >= 0);
  AssertTrue('instantiating program NOT in report, got: ' + Output,
    Pos(' at LeakGen:', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_GenericAllocSite_ReportsDefiningUnit_Native;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebugOn(beNative, SrcGenericAllocSite, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('leak header', Pos('Blaise leak report', Output) >= 0);
  AssertTrue('enumerator class reported', Pos('TListEnumerator', Output) >= 0);
  AssertTrue('defining unit in report, got: ' + Output,
    Pos(' at Generics.Collections:', Output) >= 0);
  AssertTrue('instantiating program NOT in report, got: ' + Output,
    Pos(' at LeakGen:', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_NoLeak_NoReport;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcNoLeak, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', '99' + LE, Output);
  AssertTrue('no leak report', Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_ExceptionHandlerVar_NoLeakNoOverRelease;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebug(SrcExceptionHandlerVar, Output, ExitCode, True));
  { Clean exit (no abort from a negative-refcount free), expected stdout, and
    no leak report (the exception is freed exactly once). }
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', 'caught' + LE + 'done' + LE, Output);
  AssertTrue('no leak report', Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_ConstructorWithArgs_NoDoubleAddRef;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcConstructorWithArgs, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', '42' + LE, Output);
  AssertTrue('no leak report', Pos('Blaise leak report', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_LeakedObject_ReportedOnExit;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcOneLeak, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('leak header present', Pos('Blaise leak report', Output) >= 0);
  AssertTrue('count 1', Pos('1 leak(s)', Output) >= 0);
  AssertTrue('class name', Pos('TBox', Output) >= 0);
end;

procedure TE2ELeakCheckTests.TestDebug_MultipleLeaks_AllReported;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcTwoLeaks, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('leak header present', Pos('Blaise leak report', Output) >= 0);
  AssertTrue('count 2', Pos('2 leak(s)', Output) >= 0);
  AssertTrue('TAlpha reported', Pos('TAlpha', Output) >= 0);
  AssertTrue('TBeta reported', Pos('TBeta', Output) >= 0);
end;

procedure TE2ELeakCheckTests.TestDebug_CycleRetained_Reported;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcCycleLeak, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('leak header present', Pos('Blaise leak report', Output) >= 0);
  AssertTrue('count 2', Pos('2 leak(s)', Output) >= 0);
  AssertTrue('TNode reported', Pos('TNode', Output) >= 0);
end;

procedure TE2ELeakCheckTests.TestRelease_NoReport_WhenDebugOff;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  { Same leaking source but compiled without debug mode — no report expected. }
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcOneLeak, Output, ExitCode, False));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('no leak report', Pos('Blaise leak report', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_LeakReport_IncludesUnitAndLine;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebugOn(beQBE, SrcLeakWithSite, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('leak header', Pos('Blaise leak report', Output) >= 0);
  AssertTrue('class name', Pos('TBox', Output) >= 0);
  AssertTrue('unit name in report', Pos('LeakSite', Output) >= 0);
  AssertTrue('at separator', Pos(' at ', Output) >= 0);
end;

procedure TE2ELeakCheckTests.TestDebug_LeakReport_IncludesUnitAndLine_Native;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebugOn(beNative, SrcLeakWithSite, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('leak header', Pos('Blaise leak report', Output) >= 0);
  AssertTrue('class name', Pos('TBox', Output) >= 0);
  AssertTrue('unit name in report', Pos('LeakSite', Output) >= 0);
  AssertTrue('at separator', Pos(' at ', Output) >= 0);
end;

procedure TE2ELeakCheckTests.TestDebug_StringLeak_Reported;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebug(SrcStringLeak, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('leak header', Pos('Blaise leak report', Output) >= 0);
  AssertTrue('string tag', Pos('string', Output) >= 0);
end;

procedure TE2ELeakCheckTests.TestDebug_StringClean_NoReport;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebug(SrcStringClean, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('no leak report', Pos('Blaise leak report', Output) < 0);
end;

const
  SrcClassFieldFromCall = '''
    program P;
    type
      TThing = class N: Integer; end;
      THolder = class Item: TThing; end;
    function MakeThing(): TThing;
    begin
      Result := TThing.Create();
      Result.N := 7;
    end;
    var
      H: THolder;
      I: Integer;
    begin
      H := THolder.Create();
      for I := 1 to 100 do
        H.Item := MakeThing();
      WriteLn(H.Item.N);
    end.
    ''';

  { A function returning a class leaves Result at +1 (the callee's `Result := x`
    AddRef'd and the epilogue did not release it).  Assigning that call result to
    a local consumes the transferred reference — the assignment site must NOT
    AddRef again, or one object leaks per call.  The native backend used to
    AddRef class assignments unconditionally; this pins the elision. }
  SrcFuncReturnAssign = '''
    program P;
    type
      TThing = class N: Integer; end;
    function MakeThing(): TThing;
    begin
      Result := TThing.Create();
      Result.N := 9;
    end;
    var
      T: TThing;
      I, Sum: Integer;
    begin
      Sum := 0;
      for I := 1 to 100 do
      begin
        T := MakeThing();
        Sum := Sum + T.N;
        T := nil;
      end;
      WriteLn(Sum);
    end.
    ''';

  { A class-returning function called in STATEMENT position discards its
    result.  The callee transferred a +1 reference (Result was AddRef'd on
    `Result := x` and not released at scope exit); the discard must release it
    or one object leaks per call.  This is the same transient-release rule the
    assignment path applies (SrcFuncReturnAssign above), for the discarded case.
    Regressed on BOTH backends before the discarded-class-call release landed in
    EmitProcCall (qbe) / EmitStmt's TProcCall tail (native). }
  SrcDiscardedClassReturn = '''
    program P;
    type
      TThing = class N: Integer; end;
    function MakeThing(): TThing;
    begin
      Result := TThing.Create();
      Result.N := 7;
    end;
    var
      I: Integer;
    begin
      for I := 1 to 100 do
        MakeThing();
      WriteLn(100);
    end.
    ''';

  { X := Call().ClassField — reading a managed-class field off an OWNED
    call-result base.  The loaded value aliases into the base's object graph, so
    releasing the transient base (whose Destroy nils+frees the field) must not
    happen until the field value has been stored, or the stored reference
    dangles.  On QBE this was a use-after-free (the base was released inline);
    the program must print 42, not garbage, after allocation churn that would
    reuse the freed block.  (Guards the deferred-base-release fix.) }
  SrcCallResultClassFieldRead = '''
    program P;
    type
      TInner = class N: Integer; end;
      TOuter = class
        Inner: TInner;
        destructor Destroy; override;
      end;
    destructor TOuter.Destroy;
    begin
      Inner := nil;
      inherited Destroy();
    end;
    function MakeOuter(): TOuter;
    begin
      Result := TOuter.Create();
      Result.Inner := TInner.Create();
      Result.Inner.N := 42;
    end;
    var
      X: TInner;
      I: Integer;
      Junk: TInner;
    begin
      X := MakeOuter().Inner;
      for I := 0 to 100 do
        Junk := TInner.Create();
      WriteLn(X.N);
      X := nil;
    end.
    ''';

  { A DEEP chain field read: MakeIt().A.B.N reads a scalar field off a base that
    is itself two field-reads-off-an-owned-transient.  EmitInstancePtr resolved
    each intermediate hop's owned transient (the MakeIt() result, then .A, .B)
    without releasing it, leaking every intermediate on QBE (3) and native (2).
    The value 7 must still print (no use-after-free), and — once the base
    releases are deferred to statement end — no transient should leak. }
  SrcDeepChainFieldRead = '''
    program P;
    type
      TB = class N: Integer; end;
      TA = class B: TB; destructor Destroy; override; end;
      TOuter = class A: TA; destructor Destroy; override; end;
    destructor TA.Destroy; begin B := nil; inherited Destroy(); end;
    destructor TOuter.Destroy; begin A := nil; inherited Destroy(); end;
    function MakeIt(): TOuter;
    begin
      Result := TOuter.Create();
      Result.A := TA.Create();
      Result.A.B := TB.Create();
      Result.A.B.N := 7;
    end;
    var
      V: Integer;
      I: Integer;
      Junk: TB;
    begin
      V := MakeIt().A.B.N;
      for I := 0 to 100 do
        Junk := TB.Create();
      WriteLn(V);
    end.
    ''';

  SrcMultiHandlerVar = '''
    program P;
    type
      EBase = class
        FMessage: string;
      end;
      EFoo = class(EBase) end;
    var X: Integer;
    begin
      X := 0;
      try
        raise EFoo.Create()
      except
        on E: EFoo do X := 42;
        on E: EBase do X := 1
      end;
      WriteLn(X)
    end.
    ''';

procedure TE2ELeakCheckTests.TestDebug_ClassFieldFromCall_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcClassFieldFromCall, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertEquals('stdout (qbe)', '7' + LE, Output);
  AssertTrue('no leak report (qbe)', Pos('leak', Output) < 0);
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcClassFieldFromCall, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertEquals('stdout (native)', '7' + LE, Output);
  AssertTrue('no leak report (native)', Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_FuncReturnAssign_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcFuncReturnAssign, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertEquals('stdout (qbe)', '900' + LE, Output);
  AssertTrue('no leak report (qbe)', Pos('leak', Output) < 0);
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcFuncReturnAssign, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertEquals('stdout (native)', '900' + LE, Output);
  AssertTrue('no leak report (native)', Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_DiscardedClassReturn_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcDiscardedClassReturn, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertEquals('stdout (qbe)', '100' + LE, Output);
  AssertTrue('no leak report (qbe)', Pos('leak', Output) < 0);
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcDiscardedClassReturn, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertEquals('stdout (native)', '100' + LE, Output);
  AssertTrue('no leak report (native)', Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_CallResultClassFieldRead_NoUseAfterFree;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  { The CORRECTNESS guard (both backends): the stored field value must survive
    the base release + allocation churn and still read 42.  QBE printed garbage
    here before the deferred-base-release fix. }
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcCallResultClassFieldRead, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertTrue('field value survives base release, prints 42 (qbe)',
    Pos('42' + LE, Output) >= 0);
  { QBE now releases the deferred base at statement end, so no leak. }
  AssertTrue('no leak report (qbe)', Pos('leak', Output) < 0);
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcCallResultClassFieldRead, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertTrue('field value survives base release, prints 42 (native)',
    Pos('42' + LE, Output) >= 0);
  { Native now defers the owned base release to statement end (BUG-003 native
    half), so the field value's +1 no longer leaks. }
  AssertTrue('no leak report (native)', Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_DeepChainFieldRead_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  { QBE (BUG-003 ii): the deep chain's intermediate owned transients must be
    deferred-released at statement end — value 7 survives (no UAF) AND no leak. }
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcDeepChainFieldRead, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertTrue('deep-chain value survives, prints 7 (qbe)',
    Pos('7' + LE, Output) >= 0);
  AssertTrue('no leak report (qbe)', Pos('leak', Output) < 0);
  { Native now has a statement-scoped deferred-release list too, so the deep
    chain's intermediate owned transients are released (BUG-003 native half). }
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcDeepChainFieldRead, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertTrue('deep-chain value survives, prints 7 (native)',
    Pos('7' + LE, Output) >= 0);
  AssertTrue('no leak report (native)', Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_MultiHandlerVar_NoOverRelease;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcMultiHandlerVar, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertEquals('stdout (qbe)', '42' + LE, Output);
  AssertTrue('no leak report (qbe)', Pos('leak', Output) < 0);
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcMultiHandlerVar, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertEquals('stdout (native)', '42' + LE, Output);
  AssertTrue('no leak report (native)', Pos('leak', Output) < 0);
end;

const
  { Interface-returning call result passed positionally — Show(MakeFoo(42)).
    MakeFoo returns an owned (+1) interface; the borrowing parameter does not
    release it, so the caller must.  One TFoo leaked on native before the
    akIntfConsume hoist released it after the call. }
  SrcIntfCallResultArg = '''
    program P;
    type
      IFoo = interface
        function Val: Integer;
      end;
      TFoo = class(TObject, IFoo)
        FN: Integer;
        function Val: Integer;
      end;
    function TFoo.Val: Integer;
    begin Result := FN end;
    function MakeFoo(N: Integer): IFoo;
    var F: TFoo;
    begin
      F := TFoo.Create();
      F.FN := N;
      Result := F
    end;
    procedure Show(F: IFoo);
    begin
      WriteLn(F.Val())
    end;
    begin
      Show(MakeFoo(42))
    end.
    ''';

procedure TE2ELeakCheckTests.TestDebug_IntfCallResultArg_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebugOn(beQBE, SrcIntfCallResultArg, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', '42' + LE, Output);
  AssertTrue('no leak report, got: ' + Output, Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_IntfCallResultArg_NoLeak_Native;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run',
    CompileAndRunWithRTLDebugOn(beNative, SrcIntfCallResultArg, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', '42' + LE, Output);
  AssertTrue('no leak report, got: ' + Output, Pos('leak', Output) < 0);
end;

const
  { Call result used as a field-access receiver — the getter's +1 must be
    released after the field read, otherwise one object leaks per access.
    Uses TList<T>[I].HitPoints which is the most common trigger. }
  SrcReceiverFieldAccess = '''
    program P;
    type
      TCreature = class
        HitPoints: Integer;
      end;
    function MakeCreature(): TCreature;
    begin
      Result := TCreature.Create();
      Result.HitPoints := 42;
    end;
    var
      X: Integer;
    begin
      X := MakeCreature().HitPoints;
      WriteLn(X);
    end.
    ''';

  { Static array of interfaces: three IGreet elements stored into a local
    array[0..2].  Scope-exit cleanup must release each element.  Prints the
    three greetings, then exits with no leak report. }
  SrcStaticArrayOfInterface = '''
    program P;
    type
      IGreet = interface
        function Name(): string;
      end;
      TGreet = class(IGreet)
        FName: string;
        function Name(): string;
      end;
    function TGreet.Name(): string;
    begin
      Result := Self.FName;
    end;
    procedure MakeInto(var G: IGreet; const N: string);
    var
      T: TGreet;
    begin
      T := TGreet.Create();
      T.FName := N;
      G := T;
    end;
    procedure Run();
    var
      Arr: array[0..2] of IGreet;
      I: Integer;
    begin
      MakeInto(Arr[0], 'a');
      MakeInto(Arr[1], 'b');
      MakeInto(Arr[2], 'c');
      for I := 0 to 2 do
        Write(Arr[I].Name());
      WriteLn('');
    end;
    begin
      Run();
    end.
    ''';

  { A string-returning getter used directly as a WriteLn argument.  The getter
    returns a fresh +1 string (Copy result); WriteLn only borrows it, so the
    caller must release it after the write.  Three calls => three leaks before
    the fix. }
  SrcWriteLnCallArg = '''
    program P;
    type
      TFoo = class
      private
        function GetBar: String;
      public
        property Bar: String read GetBar;
      end;
    function TFoo.GetBar: String;
    begin
      Result := Copy('abcd', 1, 3);
    end;
    var
      X: TFoo;
    begin
      X := TFoo.Create;
      WriteLn(X.Bar);
      WriteLn(X.Bar);
      WriteLn(X.Bar);
      X := nil;
    end.
    ''';

procedure TE2ELeakCheckTests.TestDebug_ReceiverFieldAccess_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcReceiverFieldAccess, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertEquals('stdout (qbe)', '42' + LE, Output);
  AssertTrue('no leak report (qbe), got: ' + Output, Pos('leak', Output) < 0);
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcReceiverFieldAccess, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertEquals('stdout (native)', '42' + LE, Output);
  AssertTrue('no leak report (native), got: ' + Output, Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_StaticArrayOfInterface_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcStaticArrayOfInterface, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertEquals('stdout (qbe)', 'abc' + LE, Output);
  AssertTrue('no leak report (qbe), got: ' + Output, Pos('leak', Output) < 0);
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcStaticArrayOfInterface, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertEquals('stdout (native)', 'abc' + LE, Output);
  AssertTrue('no leak report (native), got: ' + Output, Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_WriteLnCallArg_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run (qbe)',
    CompileAndRunWithRTLDebugOn(beQBE, SrcWriteLnCallArg, Output, ExitCode, True));
  AssertEquals('exit 0 (qbe)', 0, ExitCode);
  AssertEquals('stdout (qbe)', 'bcd' + LE + 'bcd' + LE + 'bcd' + LE, Output);
  AssertTrue('no leak report (qbe), got: ' + Output, Pos('leak', Output) < 0);
  AssertTrue('compile+run (native)',
    CompileAndRunWithRTLDebugOn(beNative, SrcWriteLnCallArg, Output, ExitCode, True));
  AssertEquals('exit 0 (native)', 0, ExitCode);
  AssertEquals('stdout (native)', 'bcd' + LE + 'bcd' + LE + 'bcd' + LE, Output);
  AssertTrue('no leak report (native), got: ' + Output, Pos('leak', Output) < 0);
end;

const
  { Escaping closure: env allocated in Make, last release when the global
    closure slot is released at program exit. }
  SrcClosureEnvOnce = '''
    program P;
    uses runtime.arc;
    type
      TProc = reference to procedure;
    var
      G: TProc;
    procedure Make;
    var
      Secret: Integer;
    begin
      Secret := 7;
      G := procedure
      begin
        WriteLn(Secret)
      end
    end;
    begin
      Make();
      G();
      G := nil;
      WriteLn('done')
    end.
    ''';

  { Captured string reassigned inside the closure body: the old value must be
    released on reassignment and the final value by the env cleanup proc. }
  SrcClosureCapturedString = '''
    program P;
    uses runtime.arc;
    type
      TProc = reference to procedure;
    procedure Run;
    var
      S: string;
      V: TProc;
    begin
      S := 'alpha';
      V := procedure
      begin
        S := S + '-beta';
        WriteLn(S)
      end;
      V()
    end;
    begin
      Run();
      WriteLn('done')
    end.
    ''';

const
  SrcClosureSelfCycle = '''
    program P;
    uses runtime.arc;
    type
      TProc = reference to procedure;
      TButton = class
        FOnClick: TProc;
        procedure Wire;
      end;
    procedure TButton.Wire;
    begin
      FOnClick := procedure
      begin
        Self.Wire()
      end
    end;
    procedure Make;
    var
      B: TButton;
    begin
      B := TButton.Create();
      B.Wire()
    end;
    begin
      Make();
      WriteLn('done')
    end.
    ''';

  SrcMethodPtrCoercionClean = '''
    program P;
    uses runtime.arc;
    type
      TProc = reference to procedure;
      TObj = class
        procedure Ping;
      end;
    procedure TObj.Ping;
    begin
      WriteLn('ping')
    end;
    procedure Run;
    var
      O: TObj;
      V: TProc;
    begin
      O := TObj.Create();
      V := @O.Ping;
      V()
    end;
    begin
      Run();
      WriteLn('done')
    end.
    ''';

procedure TE2ELeakCheckTests.TestDebug_ClosureSelfCycle_LeaksByDesign;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcClosureSelfCycle, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertTrue('strong Self-capture cycle leaks (documented until [Weak], ' +
    'got: ' + Output + ')', Pos('leak', Output) >= 0);
end;

procedure TE2ELeakCheckTests.TestDebug_MethodPtrCoercion_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcMethodPtrCoercionClean, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', 'ping' + LE + 'done' + LE, Output);
  AssertTrue('no leak report, got: ' + Output, Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_ClosureEnv_ReleasedExactlyOnce;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcClosureEnvOnce, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', '7' + LE + 'done' + LE, Output);
  AssertTrue('no leak report, got: ' + Output, Pos('leak', Output) < 0);
end;

procedure TE2ELeakCheckTests.TestDebug_ClosureCapturedString_NoLeak;
var
  Output: string;
  ExitCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit end;
  AssertTrue('compile+run', CompileAndRunWithRTLDebug(SrcClosureCapturedString, Output, ExitCode, True));
  AssertEquals('exit 0', 0, ExitCode);
  AssertEquals('stdout', 'alpha-beta' + LE + 'done' + LE, Output);
  AssertTrue('no leak report, got: ' + Output, Pos('leak', Output) < 0);
end;

initialization
  RegisterTest(TE2ELeakCheckTests);

end.
