{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit blaise.elfwriter;

{ ELF relocatable-object writer for the internal assembler.

  Creates ET_REL (relocatable) ELF64 little-endian object files from
  scratch — the output format GNU `as` produces.  Scope: .text, .data,
  .rodata, .bss, .tbss sections; .symtab + .strtab; .rela.* relocation
  sections; .shstrtab.

  The API is append-oriented: callers select a section, append code/data
  bytes, define symbols at the current offset, and record relocations.
  Finish() serialises everything to a byte buffer suitable for writing
  to disk. }

interface

uses
  SysUtils, Generics.Collections;

type
  EElfWriter = class(Exception);

  TElfSectionKind = (
    eskText,     { .text — executable code }
    eskData,     { .data — read-write initialised data }
    eskRodata,   { .rodata — read-only data }
    eskBss,      { .bss — zero-initialised read-write data }
    eskTbss      { .tbss — thread-local zero-initialised data }
  );

  TElfSymBind = (
    esbLocal,    { STB_LOCAL — file scope }
    esbGlobal,   { STB_GLOBAL — visible to linker }
    esbWeak      { STB_WEAK — overridable global }
  );

  TElfSymType = (
    estNone,     { STT_NOTYPE }
    estFunc,     { STT_FUNC }
    estObject,   { STT_OBJECT }
    estSection,  { STT_SECTION }
    estTLS       { STT_TLS }
  );

  TElfRelocType = (
    ertNone,
    ert64,           { R_X86_64_64        — absolute 64-bit }
    ert32,           { R_X86_64_32        — absolute 32-bit (zero-extend) }
    ert32S,          { R_X86_64_32S       — absolute 32-bit (sign-extend) }
    ertPC32,         { R_X86_64_PC32      — PC-relative 32-bit }
    ertPLT32,        { R_X86_64_PLT32     — PLT-relative 32-bit }
    ertGOTPCREL,     { R_X86_64_GOTPCREL  — GOT PC-relative 32-bit }
    ertTPOFF32,      { R_X86_64_TPOFF32   — TLS TP-relative 32-bit }
    ertGOTPCRELX,    { R_X86_64_GOTPCRELX — relaxable GOTPCREL }
    ertREX_GOTPCRELX { R_X86_64_REX_GOTPCRELX — relaxable GOTPCREL with REX }
  );

  TElfReloc = record
    Offset:   Integer;      { byte offset within the section }
    SymIndex: Integer;      { index into the symbol table }
    RType:    TElfRelocType; { relocation type }
    Addend:   Int64;         { addend (RELA) }
  end;

  { In-memory section: accumulates bytes (for non-BSS) and relocations. }
  TElfWriterSection = class
  public
    Kind:      TElfSectionKind;
    Data:      string;         { byte buffer (empty for BSS/TBSS) }
    Size:      Integer;        { for BSS: logical size; for others: Length(Data) }
    Align:     Integer;        { section alignment (power of 2) }
    Relocs:    array of TElfReloc;
    RelocCount: Integer;
    constructor Create(AKind: TElfSectionKind);
    destructor Destroy; override;
  end;

  { Symbol definition recorded before serialisation. }
  TElfWriterSym = class
  public
    Name:      string;
    Section:   TElfSectionKind;
    Value:     Integer;
    Size:      Integer;
    Bind:      TElfSymBind;
    SType:     TElfSymType;
    IsExtern:  Boolean;
  end;

  { The main ELF object builder. }
  TElfObjectWriter = class
  private
    FSections: array of TElfWriterSection;
    FSymbols:  TList<TElfWriterSym>;
    FSymMap:   TDictionary<string, Integer>;

    function GetSection(AKind: TElfSectionKind): TElfWriterSection;
    function SectionName(AKind: TElfSectionKind): string;
  public
    constructor Create;
    destructor Destroy; override;

    { Switch to a section (creates on first use). }
    procedure SelectSection(AKind: TElfSectionKind);

    { Append raw bytes to a section.  Returns the offset at which the
      bytes were placed. }
    function Append(AKind: TElfSectionKind; const ABytes: string): Integer;
    { Append a single byte. }
    procedure AppendByte(AKind: TElfSectionKind; AVal: Integer);
    { Append a 16-bit little-endian value. }
    procedure AppendWord(AKind: TElfSectionKind; AVal: Integer);
    { Append a 32-bit little-endian value. }
    procedure AppendDWord(AKind: TElfSectionKind; AVal: Integer);
    { Append a 64-bit little-endian value. }
    procedure AppendQWord(AKind: TElfSectionKind; AVal: Int64);
    { Append N zero bytes. }
    procedure AppendZeros(AKind: TElfSectionKind; ACount: Integer);
    { Pad the section to the next multiple of AAlign. }
    procedure AlignSection(AKind: TElfSectionKind; AAlign: Integer);
    { Reserve ASize bytes in a BSS/TBSS section (no data emitted). }
    procedure ReserveBss(AKind: TElfSectionKind; ASize: Integer);

    { Current write offset in a section. }
    function CurrentOffset(AKind: TElfSectionKind): Integer;

    { Patch a 32-bit value at an existing offset in a section. }
    procedure Patch32(AKind: TElfSectionKind; AOffset: Integer; AVal: Integer);

    { Define a symbol.  Returns the symbol index. }
    function DefineSymbol(const AName: string; ASection: TElfSectionKind;
      AValue: Integer; ASize: Integer;
      ABind: TElfSymBind; ASType: TElfSymType): Integer;
    { Reference an external (undefined) symbol.  Returns the symbol index.
      Idempotent — returns existing index if already declared. }
    function ExternSymbol(const AName: string): Integer;
    { Look up a symbol by name.  Returns index or -1. }
    function FindSymbol(const AName: string): Integer;

    { Add a relocation to a section. }
    procedure AddReloc(ASection: TElfSectionKind; AOffset: Integer;
      ASymIndex: Integer; ARType: TElfRelocType; AAddend: Int64);

    { Serialise the complete ELF object to a byte string. }
    function Finish: string;

    { Write the ELF object to a file. }
    procedure WriteToFile(const APath: string);
  end;

implementation

uses
  streams;

const
  ELFCLASS64  = 2;
  ELFDATA2LSB = 1;
  EV_CURRENT  = 1;
  ELFOSABI_NONE = 0;
  ET_REL      = 1;
  EM_X86_64   = 62;
  ELF64_EHDR_SIZE = 64;
  ELF64_SHDR_SIZE = 64;
  ELF64_SYM_SIZE  = 24;
  ELF64_RELA_SIZE = 24;

  SHT_NULL     = 0;
  SHT_PROGBITS = 1;
  SHT_SYMTAB   = 2;
  SHT_STRTAB   = 3;
  SHT_RELA     = 4;
  SHT_NOBITS   = 8;

  SHF_WRITE     = $1;
  SHF_ALLOC     = $2;
  SHF_EXECINSTR = $4;
  SHF_TLS       = $200;

  STB_LOCAL  = 0;
  STB_GLOBAL = 1;
  STB_WEAK   = 2;

  STT_NOTYPE  = 0;
  STT_OBJECT  = 1;
  STT_FUNC    = 2;
  STT_SECTION = 3;
  STT_TLS     = 6;

  SHN_UNDEF  = 0;

  R_X86_64_NONE       = 0;
  R_X86_64_64         = 1;
  R_X86_64_PC32       = 2;
  R_X86_64_32         = 10;
  R_X86_64_32S        = 11;
  R_X86_64_TPOFF32    = 23;
  R_X86_64_GOTPCREL   = 9;
  R_X86_64_PLT32      = 4;
  R_X86_64_GOTPCRELX  = 41;
  R_X86_64_REX_GOTPCRELX = 42;

{ ---- TElfWriterSection ------------------------------------------------ }

constructor TElfWriterSection.Create(AKind: TElfSectionKind);
begin
  inherited Create();
  Kind  := AKind;
  Data  := '';
  Size  := 0;
  Align := 1;
  SetLength(Relocs, 0);
  RelocCount := 0;
end;

destructor TElfWriterSection.Destroy;
begin
  SetLength(Relocs, 0);
  inherited Destroy();
end;

{ ---- Byte helpers ----------------------------------------------------- }

procedure PutU8(var ABuf: string; AVal: Integer);
begin
  ABuf := ABuf + Chr(AVal and $FF);
end;

procedure PutU16LE(var ABuf: string; AVal: Integer);
begin
  ABuf := ABuf + Chr(AVal and $FF) + Chr((AVal shr 8) and $FF);
end;

procedure PutU32LE(var ABuf: string; AVal: Integer);
begin
  ABuf := ABuf + Chr(AVal and $FF)
              + Chr((AVal shr 8) and $FF)
              + Chr((AVal shr 16) and $FF)
              + Chr((AVal shr 24) and $FF);
end;

procedure PutU64LE(var ABuf: string; AVal: Int64);
var
  Lo, Hi: Integer;
begin
  Lo := Integer(AVal and $FFFFFFFF);
  Hi := Integer((AVal shr 32) and $FFFFFFFF);
  PutU32LE(ABuf, Lo);
  PutU32LE(ABuf, Hi);
end;

procedure PatchU32LE(var ABuf: string; AOff: Integer; AVal: Integer);
var
  P: PChar;
begin
  P := PChar(ABuf);
  P[AOff]     := Chr(AVal and $FF);
  P[AOff + 1] := Chr((AVal shr 8) and $FF);
  P[AOff + 2] := Chr((AVal shr 16) and $FF);
  P[AOff + 3] := Chr((AVal shr 24) and $FF);
end;

function MakeZeros(ACount: Integer): string;
var
  I: Integer;
begin
  Result := '';
  I := 0;
  while I < ACount do
  begin
    Result := Result + Chr(0);
    I := I + 1;
  end;
end;

function ElfAlignUp(AVal: Integer; AAlign: Integer): Integer;
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

function ElfAlignUp64(AVal: Int64; AAlign: Int64): Int64;
var
  Rem: Int64;
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

{ ---- TElfObjectWriter ------------------------------------------------- }

constructor TElfObjectWriter.Create;
var
  I: Integer;
begin
  inherited Create();
  SetLength(FSections, 5);
  for I := 0 to 4 do
    FSections[I] := nil;
  FSymbols  := TList<TElfWriterSym>.Create();
  FSymMap   := TDictionary<string, Integer>.Create();
end;

destructor TElfObjectWriter.Destroy;
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

function TElfObjectWriter.SectionName(AKind: TElfSectionKind): string;
begin
  case AKind of
    eskText:   Result := '.text';
    eskData:   Result := '.data';
    eskRodata: Result := '.rodata';
    eskBss:    Result := '.bss';
    eskTbss:   Result := '.tbss';
  else
    Result := '.text';
  end;
end;

function TElfObjectWriter.GetSection(AKind: TElfSectionKind): TElfWriterSection;
var
  Idx: Integer;
begin
  Idx := Ord(AKind);
  if FSections[Idx] = nil then
    FSections[Idx] := TElfWriterSection.Create(AKind);
  Result := FSections[Idx];
end;

procedure TElfObjectWriter.SelectSection(AKind: TElfSectionKind);
begin
  GetSection(AKind);
end;

function TElfObjectWriter.Append(AKind: TElfSectionKind; const ABytes: string): Integer;
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  Result := Length(Sec.Data);
  Sec.Data := Sec.Data + ABytes;
  Sec.Size := Length(Sec.Data);
end;

procedure TElfObjectWriter.AppendByte(AKind: TElfSectionKind; AVal: Integer);
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  Sec.Data := Sec.Data + Chr(AVal and $FF);
  Sec.Size := Length(Sec.Data);
end;

procedure TElfObjectWriter.AppendWord(AKind: TElfSectionKind; AVal: Integer);
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  PutU16LE(Sec.Data, AVal);
  Sec.Size := Length(Sec.Data);
end;

procedure TElfObjectWriter.AppendDWord(AKind: TElfSectionKind; AVal: Integer);
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  PutU32LE(Sec.Data, AVal);
  Sec.Size := Length(Sec.Data);
end;

procedure TElfObjectWriter.AppendQWord(AKind: TElfSectionKind; AVal: Int64);
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  PutU64LE(Sec.Data, AVal);
  Sec.Size := Length(Sec.Data);
end;

procedure TElfObjectWriter.AppendZeros(AKind: TElfSectionKind; ACount: Integer);
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  Sec.Data := Sec.Data + MakeZeros(ACount);
  Sec.Size := Length(Sec.Data);
end;

procedure TElfObjectWriter.AlignSection(AKind: TElfSectionKind; AAlign: Integer);
var
  Sec: TElfWriterSection;
  Pad: Integer;
begin
  Sec := GetSection(AKind);
  if AAlign > Sec.Align then
    Sec.Align := AAlign;
  if (AKind = eskBss) or (AKind = eskTbss) then
  begin
    Sec.Size := ElfAlignUp(Sec.Size, AAlign);
  end
  else
  begin
    Pad := ElfAlignUp(Length(Sec.Data), AAlign) - Length(Sec.Data);
    if Pad > 0 then
      Sec.Data := Sec.Data + MakeZeros(Pad);
    Sec.Size := Length(Sec.Data);
  end;
end;

procedure TElfObjectWriter.ReserveBss(AKind: TElfSectionKind; ASize: Integer);
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  Sec.Size := Sec.Size + ASize;
end;

function TElfObjectWriter.CurrentOffset(AKind: TElfSectionKind): Integer;
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  if (AKind = eskBss) or (AKind = eskTbss) then
    Result := Sec.Size
  else
    Result := Length(Sec.Data);
end;

procedure TElfObjectWriter.Patch32(AKind: TElfSectionKind; AOffset: Integer;
  AVal: Integer);
var
  Sec: TElfWriterSection;
begin
  Sec := GetSection(AKind);
  PatchU32LE(Sec.Data, AOffset, AVal);
end;

function TElfObjectWriter.DefineSymbol(const AName: string;
  ASection: TElfSectionKind; AValue: Integer; ASize: Integer;
  ABind: TElfSymBind; ASType: TElfSymType): Integer;
var
  Sym: TElfWriterSym;
  Existing: Integer;
begin
  if FSymMap.TryGetValue(AName, Existing) then
  begin
    Result := Existing;
    Exit;
  end;
  Sym := TElfWriterSym.Create();
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

function TElfObjectWriter.ExternSymbol(const AName: string): Integer;
var
  Sym: TElfWriterSym;
  Existing: Integer;
begin
  if FSymMap.TryGetValue(AName, Existing) then
  begin
    Result := Existing;
    Exit;
  end;
  Sym := TElfWriterSym.Create();
  Sym.Name     := AName;
  Sym.Section  := eskText;
  Sym.Value    := 0;
  Sym.Size     := 0;
  Sym.Bind     := esbGlobal;
  Sym.SType    := estNone;
  Sym.IsExtern := True;
  Result := FSymbols.Count;
  FSymbols.Add(Sym);
  FSymMap.Add(AName, Result);
end;

function TElfObjectWriter.FindSymbol(const AName: string): Integer;
var
  Val: Integer;
begin
  if FSymMap.TryGetValue(AName, Val) then
    Result := Val
  else
    Result := -1;
end;

procedure TElfObjectWriter.AddReloc(ASection: TElfSectionKind; AOffset: Integer;
  ASymIndex: Integer; ARType: TElfRelocType; AAddend: Int64);
var
  Sec: TElfWriterSection;
  R: TElfReloc;
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

{ ---- Finish: serialise to ELF bytes ---------------------------------- }

function RelocTypeToElf(ARType: TElfRelocType): Integer;
begin
  case ARType of
    ertNone:           Result := R_X86_64_NONE;
    ert64:             Result := R_X86_64_64;
    ert32:             Result := R_X86_64_32;
    ert32S:            Result := R_X86_64_32S;
    ertPC32:           Result := R_X86_64_PC32;
    ertPLT32:          Result := R_X86_64_PLT32;
    ertGOTPCREL:       Result := R_X86_64_GOTPCREL;
    ertTPOFF32:        Result := R_X86_64_TPOFF32;
    ertGOTPCRELX:      Result := R_X86_64_GOTPCRELX;
    ertREX_GOTPCRELX:  Result := R_X86_64_REX_GOTPCRELX;
  else
    Result := R_X86_64_NONE;
  end;
end;

function SymBindToElf(ABind: TElfSymBind): Integer;
begin
  case ABind of
    esbLocal:  Result := STB_LOCAL;
    esbGlobal: Result := STB_GLOBAL;
    esbWeak:   Result := STB_WEAK;
  else
    Result := STB_LOCAL;
  end;
end;

function SymTypeToElf(ASType: TElfSymType): Integer;
begin
  case ASType of
    estNone:    Result := STT_NOTYPE;
    estFunc:    Result := STT_FUNC;
    estObject:  Result := STT_OBJECT;
    estSection: Result := STT_SECTION;
    estTLS:     Result := STT_TLS;
  else
    Result := STT_NOTYPE;
  end;
end;

function ElfAddStrtab(var ATab: string; const AStr: string): Integer;
begin
  if AStr = '' then
  begin
    Result := 0;
    Exit;
  end;
  Result := Length(ATab);
  ATab := ATab + AStr + Chr(0);
end;

procedure ElfEmitShdr(var ABuf: string; ANameIdx: Integer; AType: Integer;
  AFlags: Int64; AAddr: Int64; AOffset: Int64; ASize: Int64;
  ALink: Integer; AInfo: Integer; AAddrAlign: Int64; AEntSize: Int64);
begin
  PutU32LE(ABuf, ANameIdx);
  PutU32LE(ABuf, AType);
  PutU64LE(ABuf, AFlags);
  PutU64LE(ABuf, AAddr);
  PutU64LE(ABuf, AOffset);
  PutU64LE(ABuf, ASize);
  PutU32LE(ABuf, ALink);
  PutU32LE(ABuf, AInfo);
  PutU64LE(ABuf, AAddrAlign);
  PutU64LE(ABuf, AEntSize);
end;

procedure ElfEmitSym(var ABuf: string; ANameIdx: Integer; AInfo: Integer;
  AOther: Integer; AShndx: Integer; AValue: Int64; ASize: Int64);
begin
  PutU32LE(ABuf, ANameIdx);  { st_name }
  PutU8(ABuf, AInfo);        { st_info }
  PutU8(ABuf, AOther);       { st_other }
  PutU16LE(ABuf, AShndx);    { st_shndx }
  PutU64LE(ABuf, AValue);    { st_value }
  PutU64LE(ABuf, ASize);     { st_size }
end;

procedure ElfEmitRela(var ABuf: string; AOffset: Int64; ASymIdx: Integer;
  AType: Integer; AAddend: Int64);
var
  RInfo: Int64;
begin
  PutU64LE(ABuf, AOffset);
  RInfo := (Int64(ASymIdx) shl 32) or (Int64(AType) and $FFFFFFFF);
  PutU64LE(ABuf, RInfo);
  PutU64LE(ABuf, AAddend);
end;

function TElfObjectWriter.Finish: string;
var
  Buf: string;
  { Section ordering: NULL, .text, .data, .rodata, .bss, .tbss,
    then .rela.text, .rela.data, .rela.rodata,
    then .symtab, .strtab, .shstrtab.
    We track which sections exist and their SHT indices. }
  SecOrder: array[0..4] of TElfSectionKind;
  SecPresent: array[0..4] of Boolean;
  SecShtIdx: array[0..4] of Integer;
  NumDataSecs: Integer;
  RelaShtIdx: array[0..4] of Integer;
  NumRelaSecs: Integer;
  SymtabIdx, StrtabIdx, ShstrtabIdx, NoteIdx: Integer;
  TotalShNum: Integer;
  I, J, K: Integer;
  Sec: TElfWriterSection;
  Sym: TElfWriterSym;
  R: TElfReloc;

  Strtab: string;
  Shstrtab: string;

  ShdrOff: Int64;
  CurOff: Int64;

  SecFileOff: array[0..4] of Int64;
  RelaFileOff: array[0..4] of Int64;
  SymtabFileOff, StrtabFileOff, ShstrtabFileOff, NoteFileOff: Int64;

  SymtabBuf: string;
  FirstGlobal: Integer;
  SymSecIdx: Integer;
  StInfo: Integer;

  RelaBuf: array[0..4] of string;
  RelaCount: array[0..4] of Integer;
  SymRemapIdx: array of Integer;
  LocalSymCount, GlobalSymCount: Integer;
  LocalSyms, GlobalSyms: TList<Integer>;
  TmpBuf: string;

  ShFlags: Int64;
  ShType: Integer;
  SecNameIdx: array[0..4] of Integer;
  RelaNameIdx: array[0..4] of Integer;
  SymtabNameIdx, StrtabNameIdx, ShstrtabNameIdx, NoteNameIdx: Integer;

begin
  SecOrder[0] := eskText;
  SecOrder[1] := eskData;
  SecOrder[2] := eskRodata;
  SecOrder[3] := eskBss;
  SecOrder[4] := eskTbss;

  NumDataSecs := 0;
  for I := 0 to 4 do
  begin
    SecPresent[I] := FSections[Ord(SecOrder[I])] <> nil;
    if SecPresent[I] then
    begin
      SecShtIdx[I] := NumDataSecs + 1;
      NumDataSecs := NumDataSecs + 1;
    end
    else
      SecShtIdx[I] := 0;
  end;

  NumRelaSecs := 0;
  for I := 0 to 4 do
  begin
    if SecPresent[I] and (GetSection(SecOrder[I]).RelocCount > 0) then
    begin
      RelaShtIdx[I] := NumDataSecs + NumRelaSecs + 1;
      NumRelaSecs := NumRelaSecs + 1;
    end
    else
      RelaShtIdx[I] := 0;
  end;

  { An empty .note.GNU-stack section marks the stack non-executable.
    Without it the kernel/linker default to an executable stack — a
    security regression relative to GNU as output. }
  NoteIdx      := NumDataSecs + NumRelaSecs + 1;
  SymtabIdx    := NoteIdx + 1;
  StrtabIdx    := SymtabIdx + 1;
  ShstrtabIdx  := StrtabIdx + 1;
  TotalShNum   := ShstrtabIdx + 1;

  { Build .strtab — symbol name string table (starts with NUL byte) }
  Strtab := Chr(0);

  { Build .shstrtab — section name string table }
  Shstrtab := Chr(0);
  for I := 0 to 4 do
  begin
    SecNameIdx[I] := 0;
    RelaNameIdx[I] := 0;
    if SecPresent[I] then
      SecNameIdx[I] := ElfAddStrtab(Shstrtab, SectionName(SecOrder[I]));
    if RelaShtIdx[I] > 0 then
      RelaNameIdx[I] := ElfAddStrtab(Shstrtab, '.rela' + SectionName(SecOrder[I]));
  end;
  NoteNameIdx     := ElfAddStrtab(Shstrtab, '.note.GNU-stack');
  SymtabNameIdx   := ElfAddStrtab(Shstrtab, '.symtab');
  StrtabNameIdx   := ElfAddStrtab(Shstrtab, '.strtab');
  ShstrtabNameIdx := ElfAddStrtab(Shstrtab, '.shstrtab');

  { Build symbol table — separate locals from globals (ELF requires
    all locals before all globals in .symtab). }
  LocalSyms := TList<Integer>.Create();
  GlobalSyms := TList<Integer>.Create();
  try
    for I := 0 to FSymbols.Count - 1 do
    begin
      Sym := FSymbols.Get(I);
      if Sym.Bind = esbLocal then
        LocalSyms.Add(I)
      else
        GlobalSyms.Add(I);
    end;

    SetLength(SymRemapIdx, FSymbols.Count);
    { Remap: slot 0 is the NULL symbol; then locals, then globals }
    for I := 0 to LocalSyms.Count - 1 do
      SymRemapIdx[LocalSyms.Get(I)] := I + 1;
    for I := 0 to GlobalSyms.Count - 1 do
      SymRemapIdx[GlobalSyms.Get(I)] := LocalSyms.Count + I + 1;

    FirstGlobal := LocalSyms.Count + 1;

    { Serialise .symtab }
    SymtabBuf := '';
    { NULL symbol (entry 0) }
    ElfEmitSym(SymtabBuf, 0, 0, 0, SHN_UNDEF, 0, 0);
    { Locals first }
    for I := 0 to LocalSyms.Count - 1 do
    begin
      Sym := FSymbols.Get(LocalSyms.Get(I));
      if Sym.IsExtern then
        SymSecIdx := SHN_UNDEF
      else
      begin
        SymSecIdx := 0;
        for J := 0 to 4 do
          if SecPresent[J] and (SecOrder[J] = Sym.Section) then
          begin
            SymSecIdx := SecShtIdx[J];
            break;
          end;
      end;
      StInfo := (SymBindToElf(Sym.Bind) shl 4) or SymTypeToElf(Sym.SType);
      ElfEmitSym(SymtabBuf, ElfAddStrtab(Strtab, Sym.Name), StInfo, 0,
              SymSecIdx, Int64(Sym.Value), Int64(Sym.Size));
    end;
    { Globals }
    for I := 0 to GlobalSyms.Count - 1 do
    begin
      Sym := FSymbols.Get(GlobalSyms.Get(I));
      if Sym.IsExtern then
        SymSecIdx := SHN_UNDEF
      else
      begin
        SymSecIdx := 0;
        for J := 0 to 4 do
          if SecPresent[J] and (SecOrder[J] = Sym.Section) then
          begin
            SymSecIdx := SecShtIdx[J];
            break;
          end;
      end;
      StInfo := (SymBindToElf(Sym.Bind) shl 4) or SymTypeToElf(Sym.SType);
      ElfEmitSym(SymtabBuf, ElfAddStrtab(Strtab, Sym.Name), StInfo, 0,
              SymSecIdx, Int64(Sym.Value), Int64(Sym.Size));
    end;

    { Build .rela.* sections }
    for I := 0 to 4 do
    begin
      RelaBuf[I] := '';
      RelaCount[I] := 0;
      if (not SecPresent[I]) or (RelaShtIdx[I] = 0) then Continue;
      Sec := GetSection(SecOrder[I]);
      TmpBuf := '';
      for J := 0 to Sec.RelocCount - 1 do
      begin
        R := Sec.Relocs[J];
        ElfEmitRela(TmpBuf, Int64(R.Offset),
                 SymRemapIdx[R.SymIndex],
                 RelocTypeToElf(R.RType), R.Addend);
        RelaCount[I] := RelaCount[I] + 1;
      end;
      RelaBuf[I] := TmpBuf;
    end;

    { Now lay out the file.  ELF header first, then section contents in order,
      then the section header table at the end. }
    CurOff := Int64(ELF64_EHDR_SIZE);

    for I := 0 to 4 do
    begin
      SecFileOff[I] := Int64(0);
      if not SecPresent[I] then Continue;
      Sec := GetSection(SecOrder[I]);
      if Sec.Align > 1 then
        CurOff := ElfAlignUp64(CurOff, Int64(Sec.Align));
      SecFileOff[I] := CurOff;
      if (SecOrder[I] <> eskBss) and (SecOrder[I] <> eskTbss) then
        CurOff := CurOff + Int64(Length(Sec.Data));
    end;

    for I := 0 to 4 do
    begin
      RelaFileOff[I] := Int64(0);
      if RelaShtIdx[I] = 0 then Continue;
      CurOff := ElfAlignUp64(CurOff, 8);
      RelaFileOff[I] := CurOff;
      CurOff := CurOff + Int64(RelaCount[I]) * ELF64_RELA_SIZE;
    end;

    NoteFileOff := CurOff;

    CurOff := ElfAlignUp64(CurOff, 8);
    SymtabFileOff := CurOff;
    CurOff := CurOff + Int64(Length(SymtabBuf));

    CurOff := ElfAlignUp64(CurOff, 1);
    StrtabFileOff := CurOff;
    CurOff := CurOff + Int64(Length(Strtab));

    CurOff := ElfAlignUp64(CurOff, 1);
    ShstrtabFileOff := CurOff;
    CurOff := CurOff + Int64(Length(Shstrtab));

    ShdrOff := ElfAlignUp64(CurOff, 8);

    { Emit the ELF header }
    Buf := '';
    { e_ident }
    PutU8(Buf, $7F);
    PutU8(Buf, $45);  { E }
    PutU8(Buf, $4C);  { L }
    PutU8(Buf, $46);  { F }
    PutU8(Buf, ELFCLASS64);                      { class }
    PutU8(Buf, ELFDATA2LSB);                     { data }
    PutU8(Buf, EV_CURRENT);                      { version }
    PutU8(Buf, ELFOSABI_NONE);                   { OS/ABI }
    Buf := Buf + MakeZeros(8);                    { padding }
    PutU16LE(Buf, ET_REL);                       { e_type }
    PutU16LE(Buf, EM_X86_64);                    { e_machine }
    PutU32LE(Buf, EV_CURRENT);                   { e_version }
    PutU64LE(Buf, 0);                            { e_entry }
    PutU64LE(Buf, 0);                            { e_phoff }
    PutU64LE(Buf, ShdrOff);                      { e_shoff }
    PutU32LE(Buf, 0);                            { e_flags }
    PutU16LE(Buf, ELF64_EHDR_SIZE);              { e_ehsize }
    PutU16LE(Buf, 0);                            { e_phentsize }
    PutU16LE(Buf, 0);                            { e_phnum }
    PutU16LE(Buf, ELF64_SHDR_SIZE);              { e_shentsize }
    PutU16LE(Buf, TotalShNum);                   { e_shnum }
    PutU16LE(Buf, ShstrtabIdx);                  { e_shstrndx }

    { Emit section data bodies }
    for I := 0 to 4 do
    begin
      if not SecPresent[I] then Continue;
      Sec := GetSection(SecOrder[I]);
      if (SecOrder[I] = eskBss) or (SecOrder[I] = eskTbss) then Continue;
      { Pad to file offset }
      while Length(Buf) < Integer(SecFileOff[I]) do
        PutU8(Buf, 0);
      Buf := Buf + Sec.Data;
    end;

    { Emit .rela.* bodies }
    for I := 0 to 4 do
    begin
      if RelaShtIdx[I] = 0 then Continue;
      while Length(Buf) < Integer(RelaFileOff[I]) do
        PutU8(Buf, 0);
      Buf := Buf + RelaBuf[I];
    end;

    { Emit .symtab }
    while Length(Buf) < Integer(SymtabFileOff) do
      PutU8(Buf, 0);
    Buf := Buf + SymtabBuf;

    { Emit .strtab }
    while Length(Buf) < Integer(StrtabFileOff) do
      PutU8(Buf, 0);
    Buf := Buf + Strtab;

    { Emit .shstrtab }
    while Length(Buf) < Integer(ShstrtabFileOff) do
      PutU8(Buf, 0);
    Buf := Buf + Shstrtab;

    { Pad to section header table }
    while Length(Buf) < Integer(ShdrOff) do
      PutU8(Buf, 0);

    { Section header table }
    { Entry 0: NULL }
    ElfEmitShdr(Buf, 0, SHT_NULL, 0, 0, 0, 0, 0, 0, 0, 0);

    { Data sections }
    for I := 0 to 4 do
    begin
      if not SecPresent[I] then Continue;
      Sec := GetSection(SecOrder[I]);
      case SecOrder[I] of
        eskText:
        begin
          ShFlags := SHF_ALLOC or SHF_EXECINSTR;
          ShType  := SHT_PROGBITS;
        end;
        eskData:
        begin
          ShFlags := SHF_ALLOC or SHF_WRITE;
          ShType  := SHT_PROGBITS;
        end;
        eskRodata:
        begin
          ShFlags := SHF_ALLOC;
          ShType  := SHT_PROGBITS;
        end;
        eskBss:
        begin
          ShFlags := SHF_ALLOC or SHF_WRITE;
          ShType  := SHT_NOBITS;
        end;
        eskTbss:
        begin
          ShFlags := SHF_ALLOC or SHF_WRITE or SHF_TLS;
          ShType  := SHT_NOBITS;
        end;
      end;
      ElfEmitShdr(Buf, SecNameIdx[I], ShType, ShFlags, 0,
               SecFileOff[I], Int64(Sec.Size), 0, 0,
               Int64(Sec.Align), 0);
    end;

    { .rela.* sections }
    for I := 0 to 4 do
    begin
      if RelaShtIdx[I] = 0 then Continue;
      ElfEmitShdr(Buf, RelaNameIdx[I], SHT_RELA,
               0, 0, RelaFileOff[I],
               Int64(RelaCount[I]) * ELF64_RELA_SIZE,
               SymtabIdx,     { sh_link -> .symtab }
               SecShtIdx[I],  { sh_info -> target section }
               8, ELF64_RELA_SIZE);
    end;

    { .note.GNU-stack — empty, type PROGBITS, no flags (=> RW stack) }
    ElfEmitShdr(Buf, NoteNameIdx, SHT_PROGBITS, 0, 0,
             NoteFileOff, 0, 0, 0, 1, 0);

    { .symtab }
    ElfEmitShdr(Buf, SymtabNameIdx, SHT_SYMTAB, 0, 0,
             SymtabFileOff, Int64(Length(SymtabBuf)),
             StrtabIdx,     { sh_link -> .strtab }
             FirstGlobal,   { sh_info = index of first global sym }
             8, ELF64_SYM_SIZE);

    { .strtab }
    ElfEmitShdr(Buf, StrtabNameIdx, SHT_STRTAB, 0, 0,
             StrtabFileOff, Int64(Length(Strtab)),
             0, 0, 1, 0);

    { .shstrtab }
    ElfEmitShdr(Buf, ShstrtabNameIdx, SHT_STRTAB, 0, 0,
             ShstrtabFileOff, Int64(Length(Shstrtab)),
             0, 0, 1, 0);

    Result := Buf;
  finally
    LocalSyms.Free();
    GlobalSyms.Free();
  end;
end;

procedure TElfObjectWriter.WriteToFile(const APath: string);
var
  FOut: TFileOutputStream;
  Buf: string;
begin
  Buf := Self.Finish();
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
