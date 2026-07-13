{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.macho;

{ Structural tests for the Mach-O container writer (macos-arm64 Phase 1).

  Emit an MH_OBJECT with blaise.machowriter, parse it back with
  blaise.machoreader, and assert the header, section, symbol-ordering and
  relocation shapes.  This is the Linux-CI lane of the macOS target: no
  Mac is needed to pin the container format. }

interface

uses
  SysUtils, blaise.testing, blaise.container.writer,
  blaise.machowriter, blaise.machoreader;

type
  TMachOWriterTests = class(TTestCase)
  private
    function BuildProbe: TMachOFile;
  published
    procedure TestHeader_MagicCpuFiletype;
    procedure TestSections_NamesAndOrder_ZerofillLast;
    procedure TestSections_FileOffsetsAndAddrs;
    procedure TestSymbols_OrderedLocalExtdefUndef;
    procedure TestSymbols_ValuesAreSectionRelativeAddrs;
    procedure TestSymbols_WeakDefCarriesDesc;
    procedure TestReloc_Branch26_ExternPcRel;
    procedure TestReloc_PagePair_Types;
    procedure TestReloc_AddendPseudo_PrecedesTarget;
    procedure TestReloc_Unsigned_AddendFoldedIntoData;
    procedure TestReloc_SymbolIndexRemappedAfterReorder;
    procedure TestReloc_X86KindRejected;
    procedure TestInterfaceSeam_MachOViaIContainerWriter;
  end;

implementation

{ Build a representative object through the IContainerWriter seam:
    __text:  16 bytes, one local label, one global func, a bl to an
             undefined symbol, an adrp/add pair against the global data
    __const: 8 bytes
    __data:  a pointer-sized slot with an UNSIGNED reloc (addend 16)
    __bss:   reserved zerofill
  Symbol insertion order deliberately interleaves undef/global/local so
  the serialised local->extdef->undef reordering is actually exercised. }
function TMachOWriterTests.BuildProbe: TMachOFile;
var
  W: IContainerWriter;
  UndefIdx, GlobIdx, LocIdx, DataIdx: Integer;
  Buf: string;
begin
  W := TMachOObjectWriter.Create();

  { interleave: extern first, then a global, then a local }
  UndefIdx := W.ExternSymbol('_puts');

  W.AlignSection(cskText, 4);
  GlobIdx := W.DefineSymbol('_probe_fn', cskText, 0, 0, csbGlobal, cstFunc);
  W.AppendDWord(cskText, $D503201F);          { nop }
  W.AppendDWord(cskText, $94000000);          { bl 0 (reloc patches) }
  W.AddReloc(cskText, 4, UndefIdx, crkArm64Branch26, 0);
  LocIdx := W.DefineSymbol('Lloc', cskText, 8, 0, csbLocal, cstNone);
  W.AppendDWord(cskText, $90000000);          { adrp x0, _probe_data@PAGE }
  W.AppendDWord(cskText, $91000000);          { add x0, x0, @PAGEOFF }

  W.AlignSection(cskData, 8);
  DataIdx := W.DefineSymbol('_probe_data', cskData, 0, 8, csbGlobal, cstObject);
  W.AppendQWord(cskData, 0);
  W.AddReloc(cskData, 0, GlobIdx, crkArm64Abs64, 16);

  W.AddReloc(cskText, 8, DataIdx, crkArm64Page21, 0);
  W.AddReloc(cskText, 12, DataIdx, crkArm64PageOff12, 0);

  W.AlignSection(cskRodata, 8);
  W.AppendQWord(cskRodata, $1122334455667788);

  W.ReserveBss(cskBss, 32);

  { weak-defined global in __data }
  W.DefineSymbol('_probe_weak', cskData, 8, 0, csbWeak, cstObject);
  W.AppendQWord(cskData, 0);

  Buf := W.Finish();
  Result := ParseMachO(Buf, 'probe.o');
end;

procedure TMachOWriterTests.TestHeader_MagicCpuFiletype;
var
  F: TMachOFile;
begin
  F := BuildProbe();
  try
    AssertEquals(CPU_TYPE_ARM64, F.CpuType);
    AssertEquals(CPU_SUBTYPE_ARM64_ALL, F.CpuSubtype);
    AssertEquals(MH_OBJECT, F.FileType);
    AssertTrue('MH_SUBSECTIONS_VIA_SYMBOLS set',
      (F.Flags and MH_SUBSECTIONS_VIA_SYMBOLS) <> 0);
    AssertEquals(1, F.Segments.Count);
    AssertEquals('', F.Segments.Get(0).Name);
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestSections_NamesAndOrder_ZerofillLast;
var
  F: TMachOFile;
  I, TextIdx, BssIdx: Integer;
begin
  F := BuildProbe();
  try
    AssertTrue('__text present', F.FindSection('__TEXT', '__text') <> nil);
    AssertTrue('__const present', F.FindSection('__TEXT', '__const') <> nil);
    AssertTrue('__data present', F.FindSection('__DATA', '__data') <> nil);
    AssertTrue('__bss present', F.FindSection('__DATA', '__bss') <> nil);
    AssertTrue('__bss is zerofill',
      (F.FindSection('__DATA', '__bss').Flags and $FF) = S_ZEROFILL);
    TextIdx := -1;
    BssIdx := -1;
    for I := 0 to F.Sections.Count - 1 do
    begin
      if F.Sections.Get(I).SectName = '__text' then TextIdx := I;
      if F.Sections.Get(I).SectName = '__bss' then BssIdx := I;
    end;
    AssertTrue('zerofill section serialised after file-backed ones',
      BssIdx > TextIdx);
    AssertEquals('zerofill has no file offset', 0,
      F.FindSection('__DATA', '__bss').Offset);
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestSections_FileOffsetsAndAddrs;
var
  F: TMachOFile;
  T: TMoSection;
begin
  F := BuildProbe();
  try
    T := F.FindSection('__TEXT', '__text');
    AssertEquals(16, Integer(T.Size));
    AssertTrue('text data offset lands after the load commands',
      T.Offset >= 32);
    AssertEquals('text bytes round-trip: nop first',
      $1F, StrAt(T.Data, 0));
    AssertEquals('text addr starts the object vm layout', 0, Integer(T.Addr));
    AssertTrue('data addr follows text/const',
      F.FindSection('__DATA', '__data').Addr >=
      T.Addr + T.Size);
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestSymbols_OrderedLocalExtdefUndef;
var
  F: TMachOFile;
begin
  F := BuildProbe();
  try
    { local (Lloc), extdef (_probe_fn/_probe_data/_probe_weak), undef (_puts) }
    AssertEquals(0, F.ILocalSym);
    AssertEquals(1, F.NLocalSym);
    AssertEquals(1, F.IExtDefSym);
    AssertEquals(3, F.NExtDefSym);
    AssertEquals(4, F.IUndefSym);
    AssertEquals(1, F.NUndefSym);
    AssertEquals('Lloc', F.Symbols.Get(0).Name);
    AssertEquals('_puts', F.Symbols.Get(4).Name);
    AssertTrue('undef symbol shape', F.Symbols.Get(4).IsUndef());
    AssertTrue('undef symbol external', F.Symbols.Get(4).IsExt());
    AssertTrue('local symbol not external', not F.Symbols.Get(0).IsExt());
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestSymbols_ValuesAreSectionRelativeAddrs;
var
  F: TMachOFile;
  S: TMoSymbol;
  D: TMoSection;
begin
  F := BuildProbe();
  try
    S := F.FindSymbol('Lloc');
    AssertTrue(S <> nil);
    AssertEquals('n_value = section addr + offset', 8, Integer(S.Value));
    S := F.FindSymbol('_probe_data');
    D := F.FindSection('__DATA', '__data');
    AssertEquals(Integer(D.Addr), Integer(S.Value));
    AssertEquals('n_sect is the 1-based ordinal of __data',
      3, S.Sect);   { emitted order: __text(1) __const(2) __data(3) }
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestSymbols_WeakDefCarriesDesc;
var
  F: TMachOFile;
  S: TMoSymbol;
begin
  F := BuildProbe();
  try
    S := F.FindSymbol('_probe_weak');
    AssertTrue(S <> nil);
    AssertTrue('weak definition flagged N_WEAK_DEF',
      (S.Desc and N_WEAK_DEF) <> 0);
    AssertTrue('weak definition still external', S.IsExt());
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestReloc_Branch26_ExternPcRel;
var
  F: TMachOFile;
  T: TMoSection;
  R: TMoReloc;
begin
  F := BuildProbe();
  try
    T := F.FindSection('__TEXT', '__text');
    AssertEquals(3, T.Relocs.Count);   { branch26 + page21 + pageoff12 }
    R := T.Relocs.Get(0);
    AssertEquals(ARM64_RELOC_BRANCH26, R.RType);
    AssertEquals(4, R.Address);
    AssertTrue('branch26 is pc-relative', R.PcRel);
    AssertTrue('branch26 is extern', R.IsExtern);
    AssertEquals('branch26 width 4 bytes', 2, R.Length_);
    AssertEquals('targets _puts',
      '_puts', F.Symbols.Get(R.SymbolNum).Name);
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestReloc_PagePair_Types;
var
  F: TMachOFile;
  T: TMoSection;
begin
  F := BuildProbe();
  try
    T := F.FindSection('__TEXT', '__text');
    AssertEquals(ARM64_RELOC_PAGE21, T.Relocs.Get(1).RType);
    AssertTrue('page21 pc-relative', T.Relocs.Get(1).PcRel);
    AssertEquals(ARM64_RELOC_PAGEOFF12, T.Relocs.Get(2).RType);
    AssertTrue('pageoff12 not pc-relative', not T.Relocs.Get(2).PcRel);
    AssertEquals('page21 targets _probe_data',
      '_probe_data', F.Symbols.Get(T.Relocs.Get(1).SymbolNum).Name);
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestReloc_AddendPseudo_PrecedesTarget;
var
  W: IContainerWriter;
  F: TMachOFile;
  T: TMoSection;
  Idx: Integer;
begin
  W := TMachOObjectWriter.Create();
  Idx := W.ExternSymbol('_target');
  W.AppendDWord(cskText, $94000000);
  W.AddReloc(cskText, 0, Idx, crkArm64Branch26, 8);
  F := ParseMachO(W.Finish(), 'addend.o');
  try
    T := F.FindSection('__TEXT', '__text');
    AssertEquals(2, T.Relocs.Count);
    AssertEquals('pseudo first', ARM64_RELOC_ADDEND, T.Relocs.Get(0).RType);
    AssertEquals('addend rides in r_symbolnum', 8, T.Relocs.Get(0).SymbolNum);
    AssertTrue('pseudo is non-extern', not T.Relocs.Get(0).IsExtern);
    AssertEquals('same address as its target reloc',
      T.Relocs.Get(1).Address, T.Relocs.Get(0).Address);
    AssertEquals(ARM64_RELOC_BRANCH26, T.Relocs.Get(1).RType);
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestReloc_Unsigned_AddendFoldedIntoData;
var
  F: TMachOFile;
  D: TMoSection;
  R: TMoReloc;
begin
  F := BuildProbe();
  try
    D := F.FindSection('__DATA', '__data');
    AssertEquals(1, D.Relocs.Count);
    R := D.Relocs.Get(0);
    AssertEquals(ARM64_RELOC_UNSIGNED, R.RType);
    AssertEquals('pointer width 8 bytes', 3, R.Length_);
    AssertTrue('absolute, not pc-relative', not R.PcRel);
    { the addend (16) was folded into the slot bytes, not a pseudo-reloc }
    AssertEquals(16, StrAt(D.Data, 0));
    AssertEquals(0, StrAt(D.Data, 1));
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestReloc_SymbolIndexRemappedAfterReorder;
var
  F: TMachOFile;
  T: TMoSection;
begin
  F := BuildProbe();
  try
    { _puts was inserted FIRST (writer index 0) but serialises LAST
      (undef range).  The branch26 record must reference the serialised
      index — if the remap were missing it would name Lloc instead. }
    T := F.FindSection('__TEXT', '__text');
    AssertEquals(4, T.Relocs.Get(0).SymbolNum);
    AssertEquals('_puts', F.Symbols.Get(T.Relocs.Get(0).SymbolNum).Name);
  finally
    F.Free();
  end;
end;

procedure TMachOWriterTests.TestReloc_X86KindRejected;
var
  W: IContainerWriter;
  Raised: Boolean;
  Buf: string;
begin
  W := TMachOObjectWriter.Create();
  W.AppendDWord(cskText, 0);
  W.AddReloc(cskText, 0, W.ExternSymbol('x'), crkPC32, 0);
  Raised := False;
  try
    Buf := W.Finish();
  except
    on EMachOWriter do
      Raised := True;
  end;
  AssertTrue('x86-64 reloc kind rejected by the arm64 Mach-O writer', Raised);
end;

procedure TMachOWriterTests.TestInterfaceSeam_MachOViaIContainerWriter;
var
  W: IContainerWriter;
  Buf: string;
begin
  { The Bridge in action: the same seam the assembler drives TElfObjectWriter
    through produces a Mach-O object when the concrete writer differs. }
  W := TMachOObjectWriter.Create();
  W.AppendDWord(cskText, $D65F03C0);   { ret }
  W.DefineSymbol('_f', cskText, 0, 0, csbGlobal, cstFunc);
  Buf := W.Finish();
  AssertEquals($CF, StrAt(Buf, 0));
  AssertEquals($FA, StrAt(Buf, 1));
  AssertEquals($ED, StrAt(Buf, 2));
  AssertEquals($FE, StrAt(Buf, 3));
end;

initialization
  RegisterTest(TMachOWriterTests);

end.
