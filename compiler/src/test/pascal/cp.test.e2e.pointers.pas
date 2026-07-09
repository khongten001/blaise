{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.pointers;

{ E2E tests for pointer operations: GetMem/FreeMem, typed pointer dereferencing,
  and nil checks. }

interface

uses
  blaise.testing, cp.test.e2e.base;

type
  [Threaded]
  TE2EPointersTests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestRun_Pointer_GetMem_WriteRead_FreeMem;
    procedure TestRun_Pointer_TypedPointer_Deref;
    procedure TestRun_Pointer_NilCheck;
    procedure TestRun_PCharSubscript_ChrAssignment;
    procedure TestRun_PCharSubscript_HashCharLiteralAssignment;
    procedure TestRun_StaticArrayOfPChar_ElementPreservesAllBits;
    procedure TestRun_DoublePointerWrite_PreservesValue;
    procedure TestRun_SinglePointerWrite_NoAdjacentSlotClobber;
    procedure TestRun_Int64PointerWrite_IntegerRhsWidened;
    procedure TestRun_Int64PointerWrite_CardinalRhsZeroExtended;
    procedure TestRun_DoublePointerWrite_IntegerRhsConverted;
    procedure TestRun_SinglePointerWrite_IntegerRhsConverted;
    procedure TestRun_DoublePointerWrite_SingleRhsWidened;
    { Added by the hardening sweep — run on BOTH backends. }
    procedure TestRun_PointerToRecordField;
    procedure TestRun_PointerParam;
    procedure TestRun_PointerEquality;
    procedure TestRun_PointerToArrayElement;
    procedure TestRun_LinkedListViaGetMem;
  end;

implementation

procedure TE2EPointersTests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-pointers');
end;

const
  LE = #10;

  SrcGetMemWriteRead = '''
    program P;
    var P1: ^Integer;
    begin
      P1 := GetMem(4);
      P1^ := 42;
      WriteLn(P1^);
      FreeMem(P1)
    end.
    ''';

  SrcTypedPointerDeref = '''
    program P;
    var
      A: Integer;
      P1: ^Integer;
    begin
      A  := 99;
      P1 := @A;
      WriteLn(P1^)
    end.
    ''';

  SrcPointerNilCheck = '''
    program P;
    var P1: ^Integer;
    begin
      P1 := nil;
      if P1 = nil then
        WriteLn('nil')
      else
        WriteLn('not nil')
    end.
    ''';

  { Regression: assigning a PChar value to Arr[I] of a static
    array-of-PChar used to emit storew (32-bit) instead of storel,
    truncating the heap pointer's high 32 bits to zero. }
  SrcStaticArrayPChar = '''
    program P;
    procedure Print(P: PChar);
    begin
      WriteLn(string(P))
    end;
    var
      Arr: array[0..1] of PChar;
      A, B: PChar;
      I: Integer;
    begin
      A := GetMem(3);
      for I := 0 to 1 do A[I] := Chr(72 + I);
      A[2] := Chr(0);
      B := GetMem(3);
      for I := 0 to 1 do B[I] := Chr(89 + I);
      B[2] := Chr(0);
      Arr[0] := A;
      Arr[1] := B;
      Print(Arr[0]);
      Print(Arr[1]);
      FreeMem(A);
      FreeMem(B)
    end.
    ''';

  { Regression: P[I] := #N (Char literal) previously emitted a string-literal
    data item and storeb of its data pointer's low byte (the address byte),
    instead of N itself.  Verifies both ASCII characters and the NUL
    terminator land in the buffer correctly. }
  SrcPCharSubscriptHashChar = '''
    program P;
    var
      P1: PChar;
    begin
      P1 := GetMem(5);
      P1[0] := #65;
      P1[1] := #66;
      P1[2] := #67;
      P1[3] := #68;
      P1[4] := #0;
      WriteLn(string(P1));
      FreeMem(P1)
    end.
    ''';

  { Regression: P[I] := Chr(N) previously stored the low byte of the
    _Chr-allocated string pointer (garbage) instead of N itself. }
  SrcPCharSubscriptChr = '''
    program P;
    var
      P1: PChar;
      I:  Integer;
    begin
      P1 := GetMem(5);
      for I := 0 to 3 do
        P1[I] := Chr(65 + I);
      P1[4] := Chr(0);
      WriteLn(string(P1));
      FreeMem(P1)
    end.
    ''';

  SrcDoublePtrWriteE2E = '''
    program P;
    var
      D:  Double;
      PD: ^Double;
    begin
      D := 0.0;
      PD := @D;
      PD^ := 3.14;
      WriteLn(D)
    end.
    ''';

  SrcSinglePtrAdjacentE2E = '''
    program P;
    var
      A:  Single;
      B:  Single;
      PA: ^Single;
    begin
      A := 0.0;
      B := 9.5;
      PA := @A;
      PA^ := 1.25;
      WriteLn(B)
    end.
    ''';

  { BUG-020: storing a 32-bit Integer RHS through an ^Int64 must sign-extend
    (extsw) the value before the 64-bit storel; without it QBE rejects the IR
    ("invalid type for first operand ... in storel"). Uses a negative value so
    a truncation/missing sign-extend would corrupt the high word. }
  SrcInt64PtrIntRhsE2E = '''
    program P;
    var
      V:   Int64;
      Ptr: ^Int64;
      I:   Integer;
    begin
      V := 0;
      Ptr := @V;
      I := -42;
      Ptr^ := I;
      WriteLn(Ptr^)
    end.
    ''';

  { BUG-020 follow-up: an UNSIGNED 32-bit RHS must be zero-extended (extuw),
    not sign-extended — extsw smears the sign bit and turns Cardinal values
    >= 2^31 negative (observed: 4000000000 stored as -294967296). }
  SrcInt64PtrCardRhsE2E = '''
    program P;
    var
      V:   Int64;
      Ptr: ^Int64;
      C:   Cardinal;
    begin
      V := 0;
      Ptr := @V;
      C := 4000000000;
      Ptr^ := C;
      WriteLn(Ptr^)
    end.
    ''';

  { An integer RHS through a ^Double must be converted (swtof), not stored
    raw — QBE previously rejected the 'stored <w>, ...' outright. }
  SrcDoublePtrIntRhsE2E = '''
    program P;
    var
      D:   Double;
      Ptr: ^Double;
      I:   Integer;
    begin
      D := 0.0;
      Ptr := @D;
      I := 3;
      Ptr^ := I;
      WriteLn(D)
    end.
    ''';

  { BUG-027: an integer RHS through a ^Single must be CONVERTED to single
    (cvtsd2ss), not stored as the low 32 bits of the double bit-pattern —
    native previously wrote 0.0 for a small integer. }
  SrcSinglePtrIntRhsE2E = '''
    program P;
    var
      F:   Single;
      Ptr: ^Single;
      I:   Integer;
    begin
      F := 0.0;
      Ptr := @F;
      I := 5;
      Ptr^ := I;
      WriteLn(F)
    end.
    ''';

  { BUG-027 mirror: a Single RHS through a ^Double must be WIDENED
    (cvtss2sd) before the movsd — native previously stored garbage. }
  SrcDoublePtrSingleRhsE2E = '''
    program P;
    var
      D:   Double;
      Ptr: ^Double;
      S:   Single;
    begin
      D := 0.0;
      Ptr := @D;
      S := 2.5;
      Ptr^ := S;
      WriteLn(D)
    end.
    ''';

procedure TE2EPointersTests.TestRun_Pointer_GetMem_WriteRead_FreeMem;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcGetMemWriteRead, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('42', '42' + LE, Output);
end;

procedure TE2EPointersTests.TestRun_Pointer_TypedPointer_Deref;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcTypedPointerDeref, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('99', '99' + LE, Output);
end;

procedure TE2EPointersTests.TestRun_Pointer_NilCheck;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcPointerNilCheck, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('nil', 'nil' + LE, Output);
end;

procedure TE2EPointersTests.TestRun_PCharSubscript_ChrAssignment;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcPCharSubscriptChr, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('ABCD', 'ABCD' + LE, Output);
end;

procedure TE2EPointersTests.TestRun_PCharSubscript_HashCharLiteralAssignment;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcPCharSubscriptHashChar, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('ABCD', 'ABCD' + LE, Output);
end;

procedure TE2EPointersTests.TestRun_StaticArrayOfPChar_ElementPreservesAllBits;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcStaticArrayPChar, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('two PChar values round-tripped through static array',
    'HI' + LE + 'YZ' + LE, Output);
end;

procedure TE2EPointersTests.TestRun_DoublePointerWrite_PreservesValue;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcDoublePtrWriteE2E, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('Double round-trips through PDouble^',
    '3.14' + LE, Output);
end;

procedure TE2EPointersTests.TestRun_SinglePointerWrite_NoAdjacentSlotClobber;
var Output: string; RCode: Integer;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertTrue('compile+run', CompileAndRun(SrcSinglePtrAdjacentE2E, Output, RCode));
  AssertEquals('exit code 0', 0, RCode);
  AssertEquals('PSingle^ write must not clobber adjacent Single B',
    '9.5' + LE, Output);
end;

procedure TE2EPointersTests.TestRun_Int64PointerWrite_IntegerRhsWidened;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  { Must compile (QBE previously rejected the storel) and print the sign-extended
    value on BOTH backends. }
  AssertRunsOnAll(SrcInt64PtrIntRhsE2E, '-42' + LE, 0);
end;

procedure TE2EPointersTests.TestRun_Int64PointerWrite_CardinalRhsZeroExtended;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  { The stored value must keep its unsigned magnitude on BOTH backends. }
  AssertRunsOnAll(SrcInt64PtrCardRhsE2E, '4000000000' + LE, 0);
end;

procedure TE2EPointersTests.TestRun_DoublePointerWrite_IntegerRhsConverted;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  { Must compile (QBE previously rejected the stored) and print the converted
    value on BOTH backends. }
  AssertRunsOnAll(SrcDoublePtrIntRhsE2E, '3' + LE, 0);
end;

procedure TE2EPointersTests.TestRun_SinglePointerWrite_IntegerRhsConverted;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  { Native previously stored 0.0 (low 32 bits of the double); must print 5. }
  AssertRunsOnAll(SrcSinglePtrIntRhsE2E, '5' + LE, 0);
end;

procedure TE2EPointersTests.TestRun_DoublePointerWrite_SingleRhsWidened;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  { Native previously stored a garbage double; must print 2.5. }
  AssertRunsOnAll(SrcDoublePtrSingleRhsE2E, '2.5' + LE, 0);
end;

const
  SrcPtrRecordField = '''
    program Prg;
    type TP = record X, Y: Integer; end;
    var r: TP; pr: ^TP;
    begin r.X := 5; pr := @r; pr^.Y := 8; WriteLn(pr^.X + pr^.Y) end.
    ''';

  SrcPtrParam2 = '''
    program Prg;
    type PInt = ^Integer;
    procedure Bump(P: PInt); begin P^ := P^ + 10 end;
    var a: Integer;
    begin a := 5; Bump(@a); WriteLn(a) end.
    ''';

  SrcPtrEquality = '''
    program Prg;
    var a, b: Integer; pa, pb: ^Integer;
    begin a := 1; b := 2; pa := @a; pb := @a;
      if pa = pb then WriteLn('same') else WriteLn('diff');
      pb := @b;
      if pa = pb then WriteLn('same') else WriteLn('diff')
    end.
    ''';

  SrcPtrToElem2 = '''
    program Prg;
    type PInt = ^Integer;
    var arr: array[0..4] of Integer; p: PInt; i: Integer;
    begin
      for i := 0 to 4 do arr[i] := i * 11;
      p := @arr[2];
      WriteLn(p^)
    end.
    ''';

  SrcLinkedList2 = '''
    program Prg;
    type PNode = ^TNode; TNode = record Val: Integer; Next: PNode; end;
    var head, n: PNode; sum: Integer;
    begin
      head := nil;
      n := GetMem(SizeOf(TNode)); n^.Val := 1; n^.Next := head; head := n;
      n := GetMem(SizeOf(TNode)); n^.Val := 2; n^.Next := head; head := n;
      sum := 0; n := head;
      while n <> nil do begin sum := sum + n^.Val; n := n^.Next end;
      WriteLn(sum)
    end.
    ''';

procedure TE2EPointersTests.TestRun_PointerToRecordField;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcPtrRecordField, '13' + LE, 0);
end;

procedure TE2EPointersTests.TestRun_PointerParam;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcPtrParam2, '15' + LE, 0);
end;

procedure TE2EPointersTests.TestRun_PointerEquality;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcPtrEquality, 'same' + LE + 'diff' + LE, 0);
end;

procedure TE2EPointersTests.TestRun_PointerToArrayElement;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcPtrToElem2, '22' + LE, 0);
end;

procedure TE2EPointersTests.TestRun_LinkedListViaGetMem;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRunsOnAll(SrcLinkedList2, '3' + LE, 0);
end;

initialization
  RegisterTest(TE2EPointersTests);

end.
