{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit blaise.container.writer;

{ Container-writer seam (the Bridge "Implementor" role).

  The internal assemblers produce relocatable objects by driving an
  append-oriented writer: select a section, append code/data bytes, define
  symbols at the current offset, record relocations, then Finish() to a
  byte buffer.  That surface is container-agnostic — ELF (ET_REL) and
  Mach-O (MH_OBJECT) disagree about headers, section naming, and the
  relocation encoding, but they agree about everything the assembler
  computes.

  IContainerWriter is that surface as an interface, so an assembler holds
  "a writer" without naming the container: TElfObjectWriter
  (blaise.elfwriter) implements it today; TMachOWriter is the planned
  sibling (docs/macos-arm64-backend-design.adoc).  Which concrete writer is
  constructed is the per-target choice, made by the toolkit family — never
  by conditional compilation or a case statement inside the assembler.

  Lifetime: IContainerWriter is ARC-managed (same convention as ICodeGen).
  Assign a freshly-created concrete writer to an IContainerWriter variable
  and let assignment/scope-exit release it — no manual Free.  (Mixing an
  explicit Free with ARC would double-free.)

  The types below are the writer's vocabulary:

  * TContainerSectionKind — the abstract section set the backends emit
    into.  Each writer maps a kind to its native name (.text/.data/... for
    ELF; __text/__data/... for Mach-O).
  * TContainerSymBind / TContainerSymType — symbol binding and type,
    encoded per container (ELF st_info; Mach-O nlist n_type/n_desc).
  * TContainerRelocKind — relocation kinds.  These are ARCHITECTURE facts
    (they name what the CPU's addressing needs fixed up), so the enum is a
    union of per-arch families: the x86-64 members below today; the
    AArch64 family (ARM64_RELOC_BRANCH26, PAGE21/PAGEOFF12, ...) joins
    when the arm64 assembler lands.  Each writer encodes the kinds its
    container defines and rejects the rest. }

interface

type
  { Abstract section identity.  The writer owns the container-specific
    section name, flags, and alignment defaults. }
  TContainerSectionKind = (
    cskText,     { executable code }
    cskData,     { read-write initialised data }
    cskRodata,   { read-only data }
    cskBss,      { zero-initialised read-write data (no file bytes) }
    cskTbss,     { thread-local zero-initialised data }
    cskOpdf      { OPDF debug info (alloc+write, progbits) }
  );

  TContainerSymBind = (
    csbLocal,    { file scope }
    csbGlobal,   { visible to the linker }
    csbWeak      { overridable global }
  );

  TContainerSymType = (
    cstNone,
    cstFunc,
    cstObject,
    cstSection,
    cstTLS
  );

  { Relocation kinds.  x86-64 family (ELF R_X86_64_* semantics): }
  TContainerRelocKind = (
    crkNone,
    crk64,           { absolute 64-bit }
    crk32,           { absolute 32-bit (zero-extend) }
    crk32S,          { absolute 32-bit (sign-extend) }
    crkPC32,         { PC-relative 32-bit }
    crkPLT32,        { PLT-relative 32-bit }
    crkGOTPCREL,     { GOT PC-relative 32-bit }
    crkTPOFF32,      { TLS TP-relative 32-bit }
    crkGOTPCRELX,    { relaxable GOTPCREL }
    crkREX_GOTPCRELX { relaxable GOTPCREL with REX prefix }
  );

  TContainerReloc = record
    Offset:   Integer;             { byte offset within the section }
    SymIndex: Integer;             { index into the writer's symbol table }
    RType:    TContainerRelocKind; { relocation kind }
    Addend:   Int64;               { addend (RELA-style) }
  end;

  { The append-oriented writer contract the assemblers drive. }
  IContainerWriter = interface
    { Switch to a section (creates on first use). }
    procedure SelectSection(AKind: TContainerSectionKind);

    { Append raw bytes to a section.  Returns the offset at which the
      bytes were placed. }
    function Append(AKind: TContainerSectionKind; const ABytes: string): Integer;
    { Append a single byte. }
    procedure AppendByte(AKind: TContainerSectionKind; AVal: Integer);
    { Append a 16-bit little-endian value. }
    procedure AppendWord(AKind: TContainerSectionKind; AVal: Integer);
    { Append a 32-bit little-endian value. }
    procedure AppendDWord(AKind: TContainerSectionKind; AVal: Integer);
    { Append a 64-bit little-endian value. }
    procedure AppendQWord(AKind: TContainerSectionKind; AVal: Int64);
    { Append N zero bytes. }
    procedure AppendZeros(AKind: TContainerSectionKind; ACount: Integer);
    { Pad the section to the next multiple of AAlign. }
    procedure AlignSection(AKind: TContainerSectionKind; AAlign: Integer);
    { Reserve ASize bytes in a BSS/TBSS section (no data emitted). }
    procedure ReserveBss(AKind: TContainerSectionKind; ASize: Integer);

    { Current write offset in a section. }
    function CurrentOffset(AKind: TContainerSectionKind): Integer;

    { Patch a 32-bit value at an existing offset in a section. }
    procedure Patch32(AKind: TContainerSectionKind; AOffset: Integer;
      AVal: Integer);

    { Define a symbol.  Returns the symbol index. }
    function DefineSymbol(const AName: string; ASection: TContainerSectionKind;
      AValue: Integer; ASize: Integer;
      ABind: TContainerSymBind; ASType: TContainerSymType): Integer;
    { Reference an external (undefined) symbol.  Returns the symbol index.
      Idempotent — returns the existing index if already declared. }
    function ExternSymbol(const AName: string): Integer;
    { Look up a symbol by name.  Returns index or -1. }
    function FindSymbol(const AName: string): Integer;

    { Add a relocation to a section. }
    procedure AddReloc(ASection: TContainerSectionKind; AOffset: Integer;
      ASymIndex: Integer; ARType: TContainerRelocKind; AAddend: Int64);

    { Serialise the complete object to a byte string. }
    function Finish: string;

    { Write the object to a file. }
    procedure WriteToFile(const APath: string);
  end;

implementation

end.
