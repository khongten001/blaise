{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit blaise.machowriter;

{ Mach-O relocatable-object writer for the internal AArch64 assembler —
  the Mach-O sibling of blaise.elfwriter behind the IContainerWriter
  Bridge (docs/macos-arm64-backend-design.adoc, Phase 1).

  Creates MH_OBJECT (relocatable) Mach-O 64-bit little-endian arm64
  object files from scratch — the output format `clang -c` produces on
  Apple Silicon.  Shape:

    mach_header_64
    LC_SEGMENT_64 (one, unnamed) holding every section_64
    LC_BUILD_VERSION (platform macOS, minos 11.0)
    LC_SYMTAB   (nlist_64 entries + string table)
    LC_DYSYMTAB (local / externally-defined / undefined index ranges)
    section data, per-section relocation_info arrays, symtab, strtab

  Section mapping from the container vocabulary:

    cskText   -> (__TEXT,__text)   S_REGULAR + PURE/SOME_INSTRUCTIONS
    cskRodata -> (__TEXT,__const)  S_REGULAR
    cskData   -> (__DATA,__data)   S_REGULAR
    cskOpdf   -> (__OPDF,__opdf)   S_REGULAR (OPDF debug payload)
    cskBss    -> (__DATA,__bss)          S_ZEROFILL
    cskTbss   -> (__DATA,__thread_bss)   S_THREAD_LOCAL_ZEROFILL

  Zerofill sections are laid out LAST in the segment (a Mach-O rule).
  Symbols are serialised locals -> externally-defined -> undefined (the
  order LC_DYSYMTAB requires); relocation records are remapped to the
  reordered symbol indices.

  Relocations use the AArch64 crkArm64* container kinds only (they are
  architecture facts — the x86-64 crk* kinds are rejected).  Mach-O
  relocation_info has no addend field: an ARM64_RELOC_ADDEND pseudo-
  relocation precedes BRANCH26/PAGE21/PAGEOFF12 records that carry one,
  and an UNSIGNED addend is added into the section bytes themselves.
  GOT/TLV kinds must be addend-free (rejected otherwise). }

interface

uses
  SysUtils, Generics.Collections, blaise.container.writer;

type
  EMachOWriter = class(Exception);

  { In-memory section: same amortized-growth backing store as the ELF
    writer's section (see blaise.elfwriter for the O(n^2) rationale). }
  TMachOWriterSection = class
  public
    Kind:       TContainerSectionKind;
    Bytes:      array of Byte;
    Count:      Integer;
    Size:       Integer;       { for zerofill: logical size; else Count }
    Align:      Integer;       { section alignment (power of 2) }
    Relocs:     array of TContainerReloc;
    RelocCount: Integer;
    constructor Create(AKind: TContainerSectionKind);
    destructor Destroy; override;
    procedure PushByte(AVal: Integer);
    function AsString: string;
  end;

  { Symbol definition recorded before serialisation. }
  TMachOWriterSym = class
  public
    Name:      string;
    Section:   TContainerSectionKind;
    Value:     Integer;
    Size:      Integer;
    Bind:      TContainerSymBind;
    SType:     TContainerSymType;
    IsExtern:  Boolean;
  end;

  { The MH_OBJECT builder.  Implements the container-agnostic
    IContainerWriter seam (ARC-managed when held through the interface —
    do not mix with manual Free in that case). }
  TMachOObjectWriter = class(TObject, IContainerWriter)
  private
    FSections: array of TMachOWriterSection;
    FSymbols:  TList<TMachOWriterSym>;
    FSymMap:   TDictionary<string, Integer>;

    function GetSection(AKind: TContainerSectionKind): TMachOWriterSection;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SelectSection(AKind: TContainerSectionKind);
    function Append(AKind: TContainerSectionKind; const ABytes: string): Integer;
    procedure AppendByte(AKind: TContainerSectionKind; AVal: Integer);
    procedure AppendWord(AKind: TContainerSectionKind; AVal: Integer);
    procedure AppendDWord(AKind: TContainerSectionKind; AVal: Integer);
    procedure AppendQWord(AKind: TContainerSectionKind; AVal: Int64);
    procedure AppendZeros(AKind: TContainerSectionKind; ACount: Integer);
    procedure AlignSection(AKind: TContainerSectionKind; AAlign: Integer);
    procedure ReserveBss(AKind: TContainerSectionKind; ASize: Integer);
    function CurrentOffset(AKind: TContainerSectionKind): Integer;
    procedure Patch32(AKind: TContainerSectionKind; AOffset: Integer;
      AVal: Integer);
    function DefineSymbol(const AName: string; ASection: TContainerSectionKind;
      AValue: Integer; ASize: Integer;
      ABind: TContainerSymBind; ASType: TContainerSymType): Integer;
    function ExternSymbol(const AName: string): Integer;
    function FindSymbol(const AName: string): Integer;
    procedure AddReloc(ASection: TContainerSectionKind; AOffset: Integer;
      ASymIndex: Integer; ARType: TContainerRelocKind; AAddend: Int64);
    function Finish: string;
    procedure WriteToFile(const APath: string);
  end;

{ (segname, sectname) a container section kind maps to — shared with the
  structural tests and the future link path. }
procedure MachOSectionNames(AKind: TContainerSectionKind;
  out ASegName, ASectName: string);

const
  MH_MAGIC_64        = Integer($FEEDFACF);
  CPU_TYPE_ARM64     = Integer($0100000C);
  CPU_SUBTYPE_ARM64_ALL = 0;
  MH_OBJECT          = 1;
  MH_EXECUTE         = 2;
  MH_SUBSECTIONS_VIA_SYMBOLS = $2000;

  LC_SEGMENT_64      = $19;
  LC_SYMTAB          = $02;
  LC_DYSYMTAB        = $0B;
  LC_BUILD_VERSION   = $32;

  PLATFORM_MACOS     = 1;

  { section_64 flags }
  S_REGULAR                = $00;
  S_ZEROFILL               = $01;
  S_THREAD_LOCAL_REGULAR   = $11;
  S_THREAD_LOCAL_ZEROFILL  = $12;
  S_THREAD_LOCAL_VARIABLES = $13;
  S_ATTR_PURE_INSTRUCTIONS = Integer($80000000);
  S_ATTR_SOME_INSTRUCTIONS = $00000400;

  { nlist_64 n_type / n_desc }
  N_EXT      = $01;
  N_UNDF     = $00;
  N_SECT     = $0E;
  N_WEAK_REF = $0040;
  N_WEAK_DEF = $0080;

  { AArch64 relocation types (r_type) }
  ARM64_RELOC_UNSIGNED            = 0;
  ARM64_RELOC_SUBTRACTOR          = 1;
  ARM64_RELOC_BRANCH26            = 2;
  ARM64_RELOC_PAGE21              = 3;
  ARM64_RELOC_PAGEOFF12           = 4;
  ARM64_RELOC_GOT_LOAD_PAGE21     = 5;
  ARM64_RELOC_GOT_LOAD_PAGEOFF12  = 6;
  ARM64_RELOC_POINTER_TO_GOT      = 7;
  ARM64_RELOC_TLVP_LOAD_PAGE21    = 8;
  ARM64_RELOC_TLVP_LOAD_PAGEOFF12 = 9;
  ARM64_RELOC_ADDEND              = 10;

implementation

uses
  streams, uStrCompat;

procedure _mw_memcpy(Dst, Src: Pointer; N: Int64); external name 'memcpy';

const
  MACH_HEADER_SIZE   = 32;
  SEGMENT_CMD_SIZE   = 72;
  SECTION_64_SIZE    = 80;
  BUILD_VERSION_SIZE = 24;
  SYMTAB_CMD_SIZE    = 24;
  DYSYMTAB_CMD_SIZE  = 80;
  NLIST_64_SIZE      = 16;
  RELOC_INFO_SIZE    = 8;

  { Serialisation order: file-backed sections first, zerofill LAST (a
    Mach-O segment rule).  Indexed by emission position. }
  SectionEmitOrder: array[0..5] of TContainerSectionKind = (
    cskText, cskRodata, cskData, cskOpdf, cskBss, cskTbss);

procedure MachOSectionNames(AKind: TContainerSectionKind;
  out ASegName, ASectName: string);
begin
  case AKind of
    cskText:
    begin
      ASegName := '__TEXT'; ASectName := '__text';
    end;
    cskRodata:
    begin
      ASegName := '__TEXT'; ASectName := '__const';
    end;
    cskData:
    begin
      ASegName := '__DATA'; ASectName := '__data';
    end;
    cskBss:
    begin
      ASegName := '__DATA'; ASectName := '__bss';
    end;
    cskTbss:
    begin
      ASegName := '__DATA'; ASectName := '__thread_bss';
    end;
    cskOpdf:
    begin
      ASegName := '__OPDF'; ASectName := '__opdf';
    end;
  else
    begin
      ASegName := '__TEXT'; ASectName := '__text';
    end;
  end;
end;

function MachOSectionFlags(AKind: TContainerSectionKind): Integer;
begin
  case AKind of
    cskText:   Result := S_REGULAR or S_ATTR_PURE_INSTRUCTIONS
                         or S_ATTR_SOME_INSTRUCTIONS;
    cskBss:    Result := S_ZEROFILL;
    cskTbss:   Result := S_THREAD_LOCAL_ZEROFILL;
  else
    Result := S_REGULAR;
  end;
end;

function IsZeroFill(AKind: TContainerSectionKind): Boolean;
begin
  Result := (AKind = cskBss) or (AKind = cskTbss);
end;

function MoAlignUp(AVal: Integer; AAlign: Integer): Integer;
var
  Rem: Integer;
begin
  if AAlign <= 1 then
  begin
    Result := AVal;
    Exit;
  end;
  Rem := AVal mod AAlign;
  if Rem = 0 then
    Result := AVal
  else
    Result := AVal + (AAlign - Rem);
end;

function Log2Align(AAlign: Integer): Integer;
var
  V: Integer;
begin
  Result := 0;
  V := AAlign;
  while V > 1 do
  begin
    V := V shr 1;
    Result := Result + 1;
  end;
end;

{ 16-byte fixed-width name field (segname/sectname), NUL-padded. }
procedure PushName16(ABuf: TByteBuf; const AName: string);
var
  I: Integer;
begin
  for I := 0 to 15 do
  begin
    if I < Length(AName) then
      ABuf.PushByte(StrAt(AName, I))
    else
      ABuf.PushByte(0);
  end;
end;

{ ---- TMachOWriterSection ---------------------------------------------- }

constructor TMachOWriterSection.Create(AKind: TContainerSectionKind);
begin
  inherited Create();
  Kind := AKind;
  SetLength(Bytes, 0);
  Count := 0;
  Size := 0;
  Align := 1;
  SetLength(Relocs, 0);
  RelocCount := 0;
end;

destructor TMachOWriterSection.Destroy;
begin
  SetLength(Bytes, 0);
  SetLength(Relocs, 0);
  inherited Destroy();
end;

procedure TMachOWriterSection.PushByte(AVal: Integer);
var
  NewCap: Integer;
begin
  if Count >= Length(Bytes) then
  begin
    NewCap := Length(Bytes) * 2;
    if NewCap < 64 then
      NewCap := 64;
    SetLength(Bytes, NewCap);
  end;
  Bytes[Count] := AVal and $FF;
  Count := Count + 1;
  Size := Count;
end;

function TMachOWriterSection.AsString: string;
begin
  SetLength(Result, Count);
  if Count > 0 then
    _mw_memcpy(PChar(Result), @Bytes[0], Count);
end;

{ ---- TMachOObjectWriter ------------------------------------------------ }

constructor TMachOObjectWriter.Create;
var
  I: Integer;
begin
  inherited Create();
  SetLength(FSections, 6);
  for I := 0 to 5 do
    FSections[I] := nil;
  FSymbols := TList<TMachOWriterSym>.Create();
  FSymMap  := TDictionary<string, Integer>.Create();
end;

destructor TMachOObjectWriter.Destroy;
var
  I: Integer;
begin
  for I := 0 to Length(FSections) - 1 do
  begin
    if FSections[I] <> nil then
      FSections[I].Free();
  end;
  SetLength(FSections, 0);
  if FSymbols <> nil then
  begin
    for I := 0 to FSymbols.Count - 1 do
      FSymbols.Get(I).Free();
  end;
  FSymbols.Free();
  FSymMap.Free();
  inherited Destroy();
end;

function TMachOObjectWriter.GetSection(AKind: TContainerSectionKind): TMachOWriterSection;
var
  Idx: Integer;
begin
  Idx := Ord(AKind);
  if FSections[Idx] = nil then
    FSections[Idx] := TMachOWriterSection.Create(AKind);
  Result := FSections[Idx];
end;

procedure TMachOObjectWriter.SelectSection(AKind: TContainerSectionKind);
begin
  GetSection(AKind);
end;

function TMachOObjectWriter.Append(AKind: TContainerSectionKind;
  const ABytes: string): Integer;
var
  Sec: TMachOWriterSection;
  I: Integer;
begin
  Sec := GetSection(AKind);
  Result := Sec.Count;
  for I := 0 to Length(ABytes) - 1 do
    Sec.PushByte(StrAt(ABytes, I));
end;

procedure TMachOObjectWriter.AppendByte(AKind: TContainerSectionKind; AVal: Integer);
begin
  GetSection(AKind).PushByte(AVal);
end;

procedure TMachOObjectWriter.AppendWord(AKind: TContainerSectionKind; AVal: Integer);
var
  Sec: TMachOWriterSection;
begin
  Sec := GetSection(AKind);
  Sec.PushByte(AVal and $FF);
  Sec.PushByte((AVal shr 8) and $FF);
end;

procedure TMachOObjectWriter.AppendDWord(AKind: TContainerSectionKind; AVal: Integer);
var
  Sec: TMachOWriterSection;
begin
  Sec := GetSection(AKind);
  Sec.PushByte(AVal and $FF);
  Sec.PushByte((AVal shr 8) and $FF);
  Sec.PushByte((AVal shr 16) and $FF);
  Sec.PushByte((AVal shr 24) and $FF);
end;

procedure TMachOObjectWriter.AppendQWord(AKind: TContainerSectionKind; AVal: Int64);
var
  Sec: TMachOWriterSection;
  I: Integer;
begin
  Sec := GetSection(AKind);
  for I := 0 to 7 do
    Sec.PushByte(Integer((AVal shr (I * 8)) and $FF));
end;

procedure TMachOObjectWriter.AppendZeros(AKind: TContainerSectionKind; ACount: Integer);
var
  Sec: TMachOWriterSection;
  I: Integer;
begin
  Sec := GetSection(AKind);
  for I := 1 to ACount do
    Sec.PushByte(0);
end;

procedure TMachOObjectWriter.AlignSection(AKind: TContainerSectionKind; AAlign: Integer);
var
  Sec: TMachOWriterSection;
  Pad, I: Integer;
begin
  Sec := GetSection(AKind);
  if AAlign > Sec.Align then
    Sec.Align := AAlign;
  if IsZeroFill(AKind) then
  begin
    Sec.Size := MoAlignUp(Sec.Size, AAlign);
  end
  else
  begin
    Pad := MoAlignUp(Sec.Count, AAlign) - Sec.Count;
    for I := 1 to Pad do
      Sec.PushByte(0);
  end;
end;

procedure TMachOObjectWriter.ReserveBss(AKind: TContainerSectionKind; ASize: Integer);
var
  Sec: TMachOWriterSection;
begin
  Sec := GetSection(AKind);
  Sec.Size := Sec.Size + ASize;
end;

function TMachOObjectWriter.CurrentOffset(AKind: TContainerSectionKind): Integer;
var
  Sec: TMachOWriterSection;
begin
  Sec := GetSection(AKind);
  if IsZeroFill(AKind) then
    Result := Sec.Size
  else
    Result := Sec.Count;
end;

procedure TMachOObjectWriter.Patch32(AKind: TContainerSectionKind;
  AOffset: Integer; AVal: Integer);
var
  Sec: TMachOWriterSection;
begin
  Sec := GetSection(AKind);
  Sec.Bytes[AOffset]     := AVal and $FF;
  Sec.Bytes[AOffset + 1] := (AVal shr 8) and $FF;
  Sec.Bytes[AOffset + 2] := (AVal shr 16) and $FF;
  Sec.Bytes[AOffset + 3] := (AVal shr 24) and $FF;
end;

function TMachOObjectWriter.DefineSymbol(const AName: string;
  ASection: TContainerSectionKind; AValue: Integer; ASize: Integer;
  ABind: TContainerSymBind; ASType: TContainerSymType): Integer;
var
  Sym: TMachOWriterSym;
  Existing: Integer;
begin
  if FSymMap.TryGetValue(AName, Existing) then
  begin
    Result := Existing;
    Exit;
  end;
  Sym := TMachOWriterSym.Create();
  Sym.Name     := AName;
  Sym.Section  := ASection;
  Sym.Value    := AValue;
  Sym.Size     := ASize;
  Sym.Bind     := ABind;
  Sym.SType    := ASType;
  Sym.IsExtern := False;
  Result := FSymbols.Count;
  FSymbols.Add(Sym);
  FSymMap.Add(AName, Result);
end;

function TMachOObjectWriter.ExternSymbol(const AName: string): Integer;
var
  Sym: TMachOWriterSym;
  Existing: Integer;
begin
  if FSymMap.TryGetValue(AName, Existing) then
  begin
    Result := Existing;
    Exit;
  end;
  Sym := TMachOWriterSym.Create();
  Sym.Name     := AName;
  Sym.Section  := cskText;
  Sym.Value    := 0;
  Sym.Size     := 0;
  Sym.Bind     := csbGlobal;
  Sym.SType    := cstNone;
  Sym.IsExtern := True;
  Result := FSymbols.Count;
  FSymbols.Add(Sym);
  FSymMap.Add(AName, Result);
end;

function TMachOObjectWriter.FindSymbol(const AName: string): Integer;
var
  Val: Integer;
begin
  if FSymMap.TryGetValue(AName, Val) then
    Result := Val
  else
    Result := -1;
end;

procedure TMachOObjectWriter.AddReloc(ASection: TContainerSectionKind;
  AOffset: Integer; ASymIndex: Integer; ARType: TContainerRelocKind;
  AAddend: Int64);
var
  Sec: TMachOWriterSection;
  R: TContainerReloc;
begin
  Sec := GetSection(ASection);
  R.Offset   := AOffset;
  R.SymIndex := ASymIndex;
  R.RType    := ARType;
  R.Addend   := AAddend;
  if Sec.RelocCount = Length(Sec.Relocs) then
    SetLength(Sec.Relocs, Sec.RelocCount * 2 + 8);
  Sec.Relocs[Sec.RelocCount] := R;
  Sec.RelocCount := Sec.RelocCount + 1;
end;

{ ---- Finish: serialise to MH_OBJECT bytes ------------------------------ }

function RelocKindToMachO(ARType: TContainerRelocKind): Integer;
begin
  case ARType of
    crkArm64Abs64:        Result := ARM64_RELOC_UNSIGNED;
    crkArm64Branch26:     Result := ARM64_RELOC_BRANCH26;
    crkArm64Page21:       Result := ARM64_RELOC_PAGE21;
    crkArm64PageOff12:    Result := ARM64_RELOC_PAGEOFF12;
    crkArm64GotPage21:    Result := ARM64_RELOC_GOT_LOAD_PAGE21;
    crkArm64GotPageOff12: Result := ARM64_RELOC_GOT_LOAD_PAGEOFF12;
    crkArm64TlvPage21:    Result := ARM64_RELOC_TLVP_LOAD_PAGE21;
    crkArm64TlvPageOff12: Result := ARM64_RELOC_TLVP_LOAD_PAGEOFF12;
  else
    raise EMachOWriter.Create(
      'machowriter: non-AArch64 relocation kind at a Mach-O arm64 section ('
      + IntToStr(Ord(ARType)) + ')');
  end;
end;

function RelocIsPcRel(AMachType: Integer): Boolean;
begin
  Result := (AMachType = ARM64_RELOC_BRANCH26)
    or (AMachType = ARM64_RELOC_PAGE21)
    or (AMachType = ARM64_RELOC_GOT_LOAD_PAGE21)
    or (AMachType = ARM64_RELOC_TLVP_LOAD_PAGE21);
end;

{ One packed relocation_info record.  r_address, then the packed word:
  r_symbolnum:24 | r_pcrel:1 | r_length:2 | r_extern:1 | r_type:4. }
procedure PushRelocInfo(ABuf: TByteBuf; AAddress, ASymNum: Integer;
  APcRel: Boolean; ALength: Integer; AExtern: Boolean; AType: Integer);
var
  W: Integer;
begin
  ABuf.PushU32(AAddress);
  W := ASymNum and $FFFFFF;
  if APcRel then
    W := W or (1 shl 24);
  W := W or ((ALength and 3) shl 25);
  if AExtern then
    W := W or (1 shl 27);
  W := W or ((AType and $F) shl 28);
  ABuf.PushU32(W);
end;

function TMachOObjectWriter.Finish: string;
var
  Emitted: array of TMachOWriterSection;   { emission-ordered, non-empty }
  NSects, I, J, K: Integer;
  Sec: TMachOWriterSection;
  SecAddr: array of Int64;                 { vm address per emitted section }
  SecFileOff: array of Integer;            { file offset per emitted section }
  SecRelOff: array of Integer;             { reloff per emitted section }
  SecNReloc: array of Integer;             { encoded reloc count per section }
  SectOrdinalOf: array of Integer;         { Ord(kind) -> 1-based ordinal }
  VmOff: Int64;
  FileOff, DataStart: Integer;
  SizeOfCmds, NCmds: Integer;
  Order: TList<Integer>;                   { old symbol index, serial order }
  NewIdxOf: array of Integer;              { old index -> serialised index }
  NLocal, NExtDef, NUndef: Integer;
  Sym: TMachOWriterSym;
  StrTab: TByteBuf;
  SymTabBuf: TByteBuf;
  RelocBuf: TByteBuf;
  Head: TByteBuf;
  StrOff: Integer;
  NType, NSect, NDesc: Integer;
  NValue: Int64;
  MachType, RelLen: Integer;
  R: TContainerReloc;
  V: Int64;
  SegName, SectName: string;
  SymOff, StrTabOff: Integer;
  FileSizeTotal: Int64;
  VmSizeTotal: Int64;
begin
  { ---- collect non-empty sections in emission order (zerofill last) ---- }
  SetLength(Emitted, 0);
  NSects := 0;
  SetLength(SectOrdinalOf, 6);
  for I := 0 to 5 do
    SectOrdinalOf[I] := 0;
  for I := 0 to 5 do
  begin
    Sec := FSections[Ord(SectionEmitOrder[I])];
    if Sec = nil then Continue;
    if (Sec.Count = 0) and (Sec.Size = 0) then Continue;
    SetLength(Emitted, NSects + 1);
    Emitted[NSects] := Sec;
    SectOrdinalOf[Ord(Sec.Kind)] := NSects + 1;   { 1-based n_sect ordinal }
    NSects := NSects + 1;
  end;

  { ---- order symbols: locals, externally-defined, undefined ---- }
  Order := TList<Integer>.Create();
  StrTab := TByteBuf.Create();
  SymTabBuf := TByteBuf.Create();
  RelocBuf := TByteBuf.Create();
  Head := TByteBuf.Create();
  try
    NLocal := 0;
    NExtDef := 0;
    NUndef := 0;
    for I := 0 to FSymbols.Count - 1 do
      if (not FSymbols.Get(I).IsExtern) and
         (FSymbols.Get(I).Bind = csbLocal) then
      begin
        Order.Add(I);
        NLocal := NLocal + 1;
      end;
    for I := 0 to FSymbols.Count - 1 do
      if (not FSymbols.Get(I).IsExtern) and
         (FSymbols.Get(I).Bind <> csbLocal) then
      begin
        Order.Add(I);
        NExtDef := NExtDef + 1;
      end;
    for I := 0 to FSymbols.Count - 1 do
      if FSymbols.Get(I).IsExtern then
      begin
        Order.Add(I);
        NUndef := NUndef + 1;
      end;
    SetLength(NewIdxOf, FSymbols.Count);
    for I := 0 to Order.Count - 1 do
      NewIdxOf[Order.Get(I)] := I;

    { ---- layout: header + load commands, then section data ---- }
    SizeOfCmds := (SEGMENT_CMD_SIZE + NSects * SECTION_64_SIZE)
      + BUILD_VERSION_SIZE + SYMTAB_CMD_SIZE + DYSYMTAB_CMD_SIZE;
    NCmds := 4;
    DataStart := MACH_HEADER_SIZE + SizeOfCmds;

    SetLength(SecAddr, NSects);
    SetLength(SecFileOff, NSects);
    SetLength(SecRelOff, NSects);
    SetLength(SecNReloc, NSects);

    VmOff := 0;
    FileOff := DataStart;
    for I := 0 to NSects - 1 do
    begin
      Sec := Emitted[I];
      VmOff := MoAlignUp(Integer(VmOff), Sec.Align);
      SecAddr[I] := VmOff;
      if IsZeroFill(Sec.Kind) then
      begin
        SecFileOff[I] := 0;
        VmOff := VmOff + Sec.Size;
      end
      else
      begin
        FileOff := MoAlignUp(FileOff, Sec.Align);
        SecFileOff[I] := FileOff;
        FileOff := FileOff + Sec.Count;
        VmOff := VmOff + Sec.Count;
      end;
    end;
    FileSizeTotal := FileOff - DataStart;   { file-backed section bytes }
    VmSizeTotal := VmOff;

    { ---- encode relocations (after section data) ---- }
    FileOff := MoAlignUp(FileOff, 8);
    for I := 0 to NSects - 1 do
    begin
      Sec := Emitted[I];
      SecRelOff[I] := FileOff;
      SecNReloc[I] := 0;
      for J := 0 to Sec.RelocCount - 1 do
      begin
        R := Sec.Relocs[J];
        MachType := RelocKindToMachO(R.RType);
        if MachType = ARM64_RELOC_UNSIGNED then
          RelLen := 3
        else
          RelLen := 2;
        if R.Addend <> 0 then
        begin
          if MachType = ARM64_RELOC_UNSIGNED then
          begin
            { No addend slot in relocation_info: fold it into the section
              bytes the relocation targets. }
            V := 0;
            for K := 0 to 7 do
              V := V or (Int64(Sec.Bytes[R.Offset + K]) shl (K * 8));
            V := V + R.Addend;
            for K := 0 to 7 do
              Sec.Bytes[R.Offset + K] := Integer((V shr (K * 8)) and $FF);
          end
          else if (MachType = ARM64_RELOC_BRANCH26)
               or (MachType = ARM64_RELOC_PAGE21)
               or (MachType = ARM64_RELOC_PAGEOFF12) then
          begin
            if (R.Addend > $7FFFFF) or (R.Addend < -$800000) then
              raise EMachOWriter.Create(
                'machowriter: ARM64_RELOC_ADDEND out of 24-bit range: '
                + IntToStr(R.Addend));
            { ADDEND pseudo-relocation immediately precedes its target. }
            PushRelocInfo(RelocBuf, R.Offset,
              Integer(R.Addend) and $FFFFFF, False, 2, False,
              ARM64_RELOC_ADDEND);
            SecNReloc[I] := SecNReloc[I] + 1;
          end
          else
            raise EMachOWriter.Create(
              'machowriter: relocation kind ' + IntToStr(MachType)
              + ' cannot carry an addend');
        end;
        PushRelocInfo(RelocBuf, R.Offset, NewIdxOf[R.SymIndex],
          RelocIsPcRel(MachType), RelLen, True, MachType);
        SecNReloc[I] := SecNReloc[I] + 1;
      end;
      FileOff := FileOff + SecNReloc[I] * RELOC_INFO_SIZE;
      if SecNReloc[I] = 0 then
        SecRelOff[I] := 0;
    end;

    { ---- symbol table + string table ---- }
    SymOff := FileOff;
    StrTab.PushByte(0);   { index 0 = empty name }
    for I := 0 to Order.Count - 1 do
    begin
      Sym := FSymbols.Get(Order.Get(I));
      if Sym.Name = '' then
        StrOff := 0
      else
      begin
        StrOff := StrTab.Count;
        StrTab.AppendBytes(Sym.Name);
        StrTab.PushByte(0);
      end;
      NDesc := 0;
      if Sym.IsExtern then
      begin
        NType := N_UNDF or N_EXT;
        NSect := 0;
        NValue := 0;
        if Sym.Bind = csbWeak then
          NDesc := N_WEAK_REF;
      end
      else
      begin
        NType := N_SECT;
        if Sym.Bind <> csbLocal then
          NType := NType or N_EXT;
        if Sym.Bind = csbWeak then
          NDesc := N_WEAK_DEF;
        NSect := SectOrdinalOf[Ord(Sym.Section)];
        if NSect = 0 then
          raise EMachOWriter.Create('machowriter: symbol "' + Sym.Name
            + '" defined in an empty/unemitted section');
        NValue := SecAddr[NSect - 1] + Sym.Value;
      end;
      SymTabBuf.PushU32(StrOff);
      SymTabBuf.PushByte(NType);
      SymTabBuf.PushByte(NSect);
      SymTabBuf.PushU16(NDesc);
      SymTabBuf.PushU64(NValue);
    end;
    StrTabOff := SymOff + Order.Count * NLIST_64_SIZE;

    { ---- header ---- }
    Head.PushU32(MH_MAGIC_64);
    Head.PushU32(CPU_TYPE_ARM64);
    Head.PushU32(CPU_SUBTYPE_ARM64_ALL);
    Head.PushU32(MH_OBJECT);
    Head.PushU32(NCmds);
    Head.PushU32(SizeOfCmds);
    Head.PushU32(MH_SUBSECTIONS_VIA_SYMBOLS);
    Head.PushU32(0);   { reserved }

    { ---- LC_SEGMENT_64 (single, unnamed) ---- }
    Head.PushU32(LC_SEGMENT_64);
    Head.PushU32(SEGMENT_CMD_SIZE + NSects * SECTION_64_SIZE);
    PushName16(Head, '');                 { segname: empty in MH_OBJECT }
    Head.PushU64(0);                      { vmaddr }
    Head.PushU64(VmSizeTotal);            { vmsize }
    Head.PushU64(DataStart);              { fileoff }
    Head.PushU64(FileSizeTotal);          { filesize }
    Head.PushU32(7);                      { maxprot rwx }
    Head.PushU32(7);                      { initprot rwx }
    Head.PushU32(NSects);
    Head.PushU32(0);                      { flags }
    for I := 0 to NSects - 1 do
    begin
      Sec := Emitted[I];
      MachOSectionNames(Sec.Kind, SegName, SectName);
      PushName16(Head, SectName);
      PushName16(Head, SegName);
      Head.PushU64(SecAddr[I]);
      if IsZeroFill(Sec.Kind) then
        Head.PushU64(Sec.Size)
      else
        Head.PushU64(Sec.Count);
      Head.PushU32(SecFileOff[I]);
      Head.PushU32(Log2Align(Sec.Align));
      Head.PushU32(SecRelOff[I]);
      Head.PushU32(SecNReloc[I]);
      Head.PushU32(MachOSectionFlags(Sec.Kind));
      Head.PushU32(0);                    { reserved1 }
      Head.PushU32(0);                    { reserved2 }
      Head.PushU32(0);                    { reserved3 }
    end;

    { ---- LC_BUILD_VERSION ---- }
    Head.PushU32(LC_BUILD_VERSION);
    Head.PushU32(BUILD_VERSION_SIZE);
    Head.PushU32(PLATFORM_MACOS);
    Head.PushU32($000B0000);              { minos 11.0.0 }
    Head.PushU32(0);                      { sdk (none recorded) }
    Head.PushU32(0);                      { ntools }

    { ---- LC_SYMTAB ---- }
    Head.PushU32(LC_SYMTAB);
    Head.PushU32(SYMTAB_CMD_SIZE);
    Head.PushU32(SymOff);
    Head.PushU32(Order.Count);
    Head.PushU32(StrTabOff);
    Head.PushU32(StrTab.Count);

    { ---- LC_DYSYMTAB ---- }
    Head.PushU32(LC_DYSYMTAB);
    Head.PushU32(DYSYMTAB_CMD_SIZE);
    Head.PushU32(0);                      { ilocalsym }
    Head.PushU32(NLocal);
    Head.PushU32(NLocal);                 { iextdefsym }
    Head.PushU32(NExtDef);
    Head.PushU32(NLocal + NExtDef);       { iundefsym }
    Head.PushU32(NUndef);
    for I := 1 to 12 do
      Head.PushU32(0);                    { toc..nlocrel: unused }

    if Head.Count <> DataStart then
      raise EMachOWriter.Create('machowriter: load-command size mismatch: '
        + IntToStr(Head.Count) + ' vs ' + IntToStr(DataStart));

    { ---- section data ---- }
    for I := 0 to NSects - 1 do
    begin
      Sec := Emitted[I];
      if IsZeroFill(Sec.Kind) then Continue;
      Head.PadTo(SecFileOff[I]);
      Head.AppendBytes(Sec.AsString());
    end;

    { ---- relocations, symtab, strtab ---- }
    Head.PadTo(SymOff - RelocBuf.Count);
    Head.AppendBuf(RelocBuf);
    Head.AppendBuf(SymTabBuf);
    Head.AppendBuf(StrTab);

    Result := Head.AsString();
  finally
    Head.Free();
    RelocBuf.Free();
    SymTabBuf.Free();
    StrTab.Free();
    Order.Free();
  end;
end;

procedure TMachOObjectWriter.WriteToFile(const APath: string);
var
  Buf: string;
  FOut: TFileOutputStream;
begin
  Buf := Finish();
  FOut := TFileOutputStream.Create(APath);
  try
    FOut.Write(PChar(Buf), Length(Buf));
    FOut.Flush();
  finally
    FOut.Close();
    FOut.Free();
  end;
end;

end.
