{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.driver;

{ Unit tests for the backend-driver option contract (Steps 2-5 of
  docs/backend-options-design.adoc).

  These exercise the real registered driver singletons (the QBE and native
  drivers, pulled in via the uses clause so their initialization blocks
  register them).  A test-only stub driver is deliberately avoided: it would
  need a slot in the fixed array[0..1] registry and muddy the real
  singletons.  Testing the actual drivers is both possible and more honest. }

interface

uses
  SysUtils, Classes, blaise.testing,
  blaise.codegen.driver,
  blaise.codegen.target,          { TTargetOS: osLinux / osFreeBSD }
  blaise.codegen.qbe.driver,      { registers the QBE driver }
  blaise.codegen.native.driver;   { registers the native driver }

type
  TBackendDriverContractTests = class(TTestCase)
  private
    function ListContains(AList: TStringList; const AName: string): Boolean;
  published
    { Per-target RTL unit-list selection (FreeBSD Step 5).  BuildRTLUnitList is
      the pure selection helper EnsureRTLObjects drives off AOpts.Static +
      AOpts.Target.OS; these assert Linux vs FreeBSD swaps without invoking the
      whole compile+link pipeline. }
    procedure TestRTLUnits_LinuxDynamic_UsesLinuxLayout;
    procedure TestRTLUnits_LinuxStatic_SwapsLinuxLeaf;
    procedure TestRTLUnits_FreeBSDStatic_SwapsFreeBSDLeaf;
    procedure TestRTLUnits_FreeBSDStatic_NoLinuxLeaf;

    { P3 (async design): the errno-classification leaf (WouldBlock) follows
      the same per-OS + per-profile swap as runtime.start — the libc variant
      in dynamic links, the raw negative-errno variant under --static. }
    procedure TestRTLUnits_Errno_LinuxDynamic_LibcVariant;
    procedure TestRTLUnits_Errno_LinuxStatic_StaticVariant;
    procedure TestRTLUnits_Errno_FreeBSD_FollowsTarget;
    procedure TestRTLUnits_MacOSArm64_DarwinProfile;

    { ClaimsEmitIR selection policy. }
    procedure TestQBE_ClaimsEmitIR_True;
    procedure TestNative_ClaimsEmitIR_False;

    { SupportsLibrary is keyed on the TARGET, not just the backend: shared
      objects are ELF-specific, so the native backend supports a library for
      an ELF target and refuses for Mach-O.  QBE refuses outright. }
    procedure TestNative_SupportsLibrary_LinuxX86_64_True;
    procedure TestNative_SupportsLibrary_FreeBSDX86_64_True;
    procedure TestNative_SupportsLibrary_MacOSArm64_False;
    procedure TestQBE_SupportsLibrary_LinuxX86_64_False;

    { Native owns --assembler via AcceptOption. }
    procedure TestNative_AcceptInternal_ConsumesValue_SetsFlag;
    procedure TestNative_AcceptExternal_ConsumesValue_ClearsFlag;
    procedure TestNative_AcceptBogus_ConsumesValue_FlagsBad;
    procedure TestNative_AcceptUnknownFlag_Unknown;

    { QBE does not own --assembler. }
    procedure TestQBE_AcceptAssembler_Unknown;

    { ValidateOptions. }
    procedure TestNative_Validate_BadValue_NonEmpty;
    procedure TestNative_Validate_GoodValue_Empty;

    { DescribeOptions surfaces the native flag. }
    procedure TestNative_DescribeOptions_MentionsAssembler;

    { FormatFlagLine column helper. }
    procedure TestFormatFlagLine_Indents_And_Pads;
  end;

implementation

function TBackendDriverContractTests.ListContains(AList: TStringList;
  const AName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to AList.Count - 1 do
    if SameText(AList.Strings[I], AName) then
      Exit(True);
end;

procedure TBackendDriverContractTests.TestRTLUnits_LinuxDynamic_UsesLinuxLayout;
var
  U: TStringList;
begin
  { A dynamic (libc) Linux link keeps the plain RTL list: the Linux layout
    adapter is present and no freestanding kernel leaf is pulled in. }
  U := BuildRTLUnitList(False, osLinux);
  try
    AssertTrue('linux layout present',
      ListContains(U, 'rtl.platform.layout.linux'));
    AssertFalse('no static start in dynamic mode',
      ListContains(U, 'runtime.start.static.linux'));
    AssertFalse('no syscall leaf in dynamic mode',
      ListContains(U, 'runtime.syscall.linux'));
  finally
    U.Free();
  end;
end;

procedure TBackendDriverContractTests.TestRTLUnits_LinuxStatic_SwapsLinuxLeaf;
var
  U: TStringList;
begin
  { A --static Linux link swaps runtime.start for the freestanding
    runtime.start.static.linux and adds the Linux syscall/cstub/libc leaf. }
  U := BuildRTLUnitList(True, osLinux);
  try
    AssertTrue('freestanding start present',
      ListContains(U, 'runtime.start.static.linux'));
    AssertFalse('libc start dropped',
      ListContains(U, 'runtime.start'));
    AssertTrue('linux syscall leaf present',
      ListContains(U, 'runtime.syscall.linux'));
    AssertTrue('linux libc2 present',
      ListContains(U, 'runtime.libc2.linux'));
    AssertTrue('linux static thread leaf present',
      ListContains(U, 'runtime.thread.static.linux'));
    AssertTrue('linux layout present',
      ListContains(U, 'rtl.platform.layout.linux'));
  finally
    U.Free();
  end;
end;

procedure TBackendDriverContractTests.TestRTLUnits_FreeBSDStatic_SwapsFreeBSDLeaf;
var
  U: TStringList;
begin
  { A --static FreeBSD link selects the FreeBSD adapter set: the FreeBSD
    layout, freestanding start, syscall leaf, libc2 and static thread leaf. }
  U := BuildRTLUnitList(True, osFreeBSD);
  try
    AssertTrue('freebsd layout present',
      ListContains(U, 'rtl.platform.layout.freebsd'));
    AssertTrue('freebsd freestanding start present',
      ListContains(U, 'runtime.start.static.freebsd'));
    AssertTrue('freebsd syscall leaf present',
      ListContains(U, 'runtime.syscall.freebsd'));
    AssertTrue('freebsd libc2 present',
      ListContains(U, 'runtime.libc2.freebsd'));
    AssertTrue('freebsd static thread leaf present',
      ListContains(U, 'runtime.thread.static.freebsd'));
  finally
    U.Free();
  end;
end;

procedure TBackendDriverContractTests.TestRTLUnits_FreeBSDStatic_NoLinuxLeaf;
var
  U: TStringList;
begin
  { The FreeBSD list must contain NO Linux-specific RTL unit — the whole point
    of the per-target swap. }
  U := BuildRTLUnitList(True, osFreeBSD);
  try
    AssertFalse('no linux layout',
      ListContains(U, 'rtl.platform.layout.linux'));
    AssertFalse('no linux start',
      ListContains(U, 'runtime.start.static.linux'));
    AssertFalse('no linux syscall leaf',
      ListContains(U, 'runtime.syscall.linux'));
    AssertFalse('no linux libc2',
      ListContains(U, 'runtime.libc2.linux'));
    AssertFalse('no linux static thread leaf',
      ListContains(U, 'runtime.thread.static.linux'));
  finally
    U.Free();
  end;
end;

procedure TBackendDriverContractTests.TestRTLUnits_Errno_LinuxDynamic_LibcVariant;
var
  U: TStringList;
begin
  { Dynamic (libc) Linux link: the __errno_location-reading variant is linked;
    the raw negative-errno variant is not. }
  U := BuildRTLUnitList(False, osLinux);
  try
    AssertTrue('libc errno leaf present',
      ListContains(U, 'runtime.errno.linux'));
    AssertFalse('no static errno leaf in dynamic mode',
      ListContains(U, 'runtime.errno.static.linux'));
  finally
    U.Free();
  end;
end;

procedure TBackendDriverContractTests.TestRTLUnits_Errno_LinuxStatic_StaticVariant;
var
  U: TStringList;
begin
  { --static Linux link: the raw negative-errno variant replaces the libc one
    (the raw syscall leaves return -errno; there is no errno variable). }
  U := BuildRTLUnitList(True, osLinux);
  try
    AssertTrue('static errno leaf present',
      ListContains(U, 'runtime.errno.static.linux'));
    AssertFalse('libc errno leaf dropped',
      ListContains(U, 'runtime.errno.linux'));
  finally
    U.Free();
  end;
end;

procedure TBackendDriverContractTests.TestRTLUnits_MacOSArm64_DarwinProfile;
var
  U: TStringList;
begin
  { macos-arm64: darwin OS leaves, arm64 CPU leaves, and NO start unit at
    all — LC_MAIN + dyld's libSystem glue call main directly and exit()
    its return, and the backend's _main already follows that contract. }
  U := BuildRTLUnitList(False, osMacOS, cpuArm64);
  try
    AssertTrue('darwin layout present',
      ListContains(U, 'rtl.platform.layout.darwin'));
    AssertTrue('darwin errno leaf present',
      ListContains(U, 'runtime.errno.darwin'));
    AssertTrue('atomics unit present (CPU picked via defines)',
      ListContains(U, 'runtime.atomic'));
    AssertTrue('setjmp unit present (CPU picked via defines)',
      ListContains(U, 'runtime.setjmp'));
    AssertFalse('no start unit under LC_MAIN',
      ListContains(U, 'runtime.start'));
    AssertFalse('no linux layout on darwin',
      ListContains(U, 'rtl.platform.layout.linux'));
    AssertFalse('no syscall leaf — libSystem only',
      ListContains(U, 'runtime.syscall.darwin'));
  finally
    U.Free();
  end;
end;

procedure TBackendDriverContractTests.TestRTLUnits_Errno_FreeBSD_FollowsTarget;
var
  U: TStringList;
begin
  { The errno leaf follows the target OS on both profiles. }
  U := BuildRTLUnitList(False, osFreeBSD);
  try
    AssertTrue('freebsd libc errno leaf present',
      ListContains(U, 'runtime.errno.freebsd'));
    AssertFalse('no linux errno leaf on freebsd',
      ListContains(U, 'runtime.errno.linux'));
  finally
    U.Free();
  end;
  U := BuildRTLUnitList(True, osFreeBSD);
  try
    AssertTrue('freebsd static errno leaf present',
      ListContains(U, 'runtime.errno.static.freebsd'));
    AssertFalse('no freebsd libc errno leaf under --static',
      ListContains(U, 'runtime.errno.freebsd'));
  finally
    U.Free();
  end;
end;

procedure TBackendDriverContractTests.TestQBE_ClaimsEmitIR_True;
begin
  AssertTrue('QBE must claim --emit-ir',
    GetDriver(bkQBE).ClaimsEmitIR());
end;

procedure TBackendDriverContractTests.TestNative_ClaimsEmitIR_False;
begin
  AssertFalse('native must not claim --emit-ir (its IR is --emit-asm)',
    GetDriver(bkNative).ClaimsEmitIR());
end;

procedure TBackendDriverContractTests.TestNative_SupportsLibrary_LinuxX86_64_True;
var
  T: TTargetDesc;
begin
  MakeTarget(osLinux, cpuX86_64, T);
  AssertTrue('native emits shared objects for an ELF target',
    GetDriver(bkNative).SupportsLibrary(T));
end;

procedure TBackendDriverContractTests.TestNative_SupportsLibrary_FreeBSDX86_64_True;
var
  T: TTargetDesc;
begin
  MakeTarget(osFreeBSD, cpuX86_64, T);
  AssertTrue('native emits shared objects for FreeBSD (also ELF)',
    GetDriver(bkNative).SupportsLibrary(T));
end;

procedure TBackendDriverContractTests.TestNative_SupportsLibrary_MacOSArm64_False;
var
  T: TTargetDesc;
begin
  { The gate that stops an ELF ET_DYN being written for a Mach-O target.
    Lift this only when __mod_init_func + LC_DYLD_INFO exports are emitted. }
  MakeTarget(osMacOS, cpuArm64, T);
  AssertFalse('native must refuse a library for a Mach-O target',
    GetDriver(bkNative).SupportsLibrary(T));
end;

procedure TBackendDriverContractTests.TestQBE_SupportsLibrary_LinuxX86_64_False;
var
  T: TTargetDesc;
begin
  MakeTarget(osLinux, cpuX86_64, T);
  AssertFalse('QBE emits no shared objects',
    GetDriver(bkQBE).SupportsLibrary(T));
end;

procedure TBackendDriverContractTests.TestNative_AcceptInternal_ConsumesValue_SetsFlag;
var
  Opts: TBackendOpts;
  R: TOptionAccept;
begin
  Opts := TBackendOpts.Create();
  try
    R := GetDriver(bkNative).AcceptOption('--assembler', 'internal', Opts);
    AssertEquals('internal must consume a value', Ord(oaConsumedValue), Ord(R));
    AssertTrue('internal must set UseInternalAsm', Opts.UseInternalAsm);
    AssertFalse('internal is a valid value', Opts.AssemblerChoiceBad);
  finally
    Opts.Free();
  end;
end;

procedure TBackendDriverContractTests.TestNative_AcceptExternal_ConsumesValue_ClearsFlag;
var
  Opts: TBackendOpts;
  R: TOptionAccept;
begin
  Opts := TBackendOpts.Create();
  try
    R := GetDriver(bkNative).AcceptOption('--assembler', 'external', Opts);
    AssertEquals('external must consume a value', Ord(oaConsumedValue), Ord(R));
    AssertFalse('external must clear UseInternalAsm', Opts.UseInternalAsm);
    AssertFalse('external is a valid value', Opts.AssemblerChoiceBad);
  finally
    Opts.Free();
  end;
end;

procedure TBackendDriverContractTests.TestNative_AcceptBogus_ConsumesValue_FlagsBad;
var
  Opts: TBackendOpts;
  R: TOptionAccept;
begin
  Opts := TBackendOpts.Create();
  try
    { A bad value is still CONSUMED here; ValidateOptions rejects it later. }
    R := GetDriver(bkNative).AcceptOption('--assembler', 'bogus', Opts);
    AssertEquals('bogus must consume a value', Ord(oaConsumedValue), Ord(R));
    AssertTrue('bogus must be flagged bad', Opts.AssemblerChoiceBad);
  finally
    Opts.Free();
  end;
end;

procedure TBackendDriverContractTests.TestNative_AcceptUnknownFlag_Unknown;
var
  Opts: TBackendOpts;
begin
  Opts := TBackendOpts.Create();
  try
    AssertEquals('an unowned flag is oaUnknown', Ord(oaUnknown),
      Ord(GetDriver(bkNative).AcceptOption('--nope', '', Opts)));
  finally
    Opts.Free();
  end;
end;

procedure TBackendDriverContractTests.TestQBE_AcceptAssembler_Unknown;
var
  Opts: TBackendOpts;
begin
  Opts := TBackendOpts.Create();
  try
    { QBE does not own --assembler — Chain-of-Responsibility asymmetry. }
    AssertEquals('QBE must not own --assembler', Ord(oaUnknown),
      Ord(GetDriver(bkQBE).AcceptOption('--assembler', 'internal', Opts)));
  finally
    Opts.Free();
  end;
end;

procedure TBackendDriverContractTests.TestNative_Validate_BadValue_NonEmpty;
var
  Opts: TBackendOpts;
begin
  Opts := TBackendOpts.Create();
  try
    GetDriver(bkNative).AcceptOption('--assembler', 'bogus', Opts);
    AssertTrue('bad --assembler must produce a diagnostic',
      GetDriver(bkNative).ValidateOptions(Opts) <> '');
  finally
    Opts.Free();
  end;
end;

procedure TBackendDriverContractTests.TestNative_Validate_GoodValue_Empty;
var
  Opts: TBackendOpts;
begin
  Opts := TBackendOpts.Create();
  try
    GetDriver(bkNative).AcceptOption('--assembler', 'internal', Opts);
    AssertEquals('valid --assembler must validate clean', '',
      GetDriver(bkNative).ValidateOptions(Opts));
  finally
    Opts.Free();
  end;
end;

procedure TBackendDriverContractTests.TestNative_DescribeOptions_MentionsAssembler;
var
  Lines: TStringList;
  I: Integer;
  Found: Boolean;
begin
  Lines := TStringList.Create();
  try
    GetDriver(bkNative).DescribeOptions(Lines);
    Found := False;
    for I := 0 to Lines.Count - 1 do
      if Pos('--assembler', Lines.Strings[I]) >= 0 then
        Found := True;
    AssertTrue('native DescribeOptions must mention --assembler', Found);
  finally
    Lines.Free();
  end;
end;

procedure TBackendDriverContractTests.TestFormatFlagLine_Indents_And_Pads;
var
  Line: string;
begin
  Line := FormatFlagLine('--x <v>', 'a description');
  { Two-space indent, flag, then the description after column padding. }
  AssertEquals('must start with two-space indent', '  ', Copy(Line, 0, 2));
  AssertTrue('must contain the flag', Pos('--x <v>', Line) >= 0);
  AssertTrue('must contain the description', Pos('a description', Line) >= 0);
  AssertTrue('description must come after the flag',
    Pos('a description', Line) > Pos('--x <v>', Line));
end;

{ ---- Registration ---- }

initialization
  RegisterTest(TBackendDriverContractTests);

end.
