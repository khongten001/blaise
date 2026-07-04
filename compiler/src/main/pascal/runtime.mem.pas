{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{
  blaise_mem — Pascal memory allocator for the Blaise runtime.

  Replaces libc malloc/free/realloc with an allocator backed by POSIX
  mmap/munmap.  Self-contained: no dependency on strings, ARC, or
  any stdlib unit.

  Design:

  Small allocations (up to LARGE_THRESHOLD bytes):
    Served from 64 KB arenas obtained via mmap.  Each allocation has
    a 16-byte header storing the usable size and a back-pointer to the
    owning arena (the routing key for the migration-safe cross-thread
    free path — docs/concurrent-allocator-design.adoc).  Freed blocks
    go onto a per-size-class freelist for O(1) reuse.  Size classes are
    powers of two: 16, 32, 64, 128, 256, 512, 1024, 2048.

    Only the head arena is used for bump allocation.  When it fills,
    a new arena is allocated and becomes the head.  No arena-list walk.

  Large allocations (above LARGE_THRESHOLD):
    Each gets its own mmap region with a 24-byte header.  Freed large
    blocks are cached on a LIFO freelist for O(1) reuse.  The cache
    holds up to LARGE_CACHE_MAX entries; excess blocks are munmap-ed
    immediately.  Large reallocs use Linux mremap to resize in-place
    without copying.  All mmap sizes are rounded up to page granularity
    (4 KB) for better cache hit rates.

  All returned pointers are 8-byte aligned.

  Thread safety:
    All allocator state (arenas, freelists, large-block cache) is
    declared as threadvar, giving each thread its own independent
    allocator instance with zero contention and no locks.  Spawned
    threads start with nil arenas and empty freelists; their first
    allocation creates a fresh arena via mmap.  Memory allocated on
    one thread must not be freed on another (the freelist push would
    go to the wrong thread's list).
}

unit runtime.mem;

interface

uses
  runtime.atomic;

function  _BlaiseGetMem(Size: Integer): Pointer;
procedure _BlaiseFreeMem(Ptr: Pointer);
function  _BlaiseReallocMem(Ptr: Pointer; NewSize: Integer): Pointer;

implementation

function  _libc_mmap(Addr: Pointer; Length: Int64; Prot, Flags, Fd: Integer;
            Offset: Int64): Pointer; external name 'mmap';
function  _libc_munmap(Addr: Pointer; Length: Int64): Integer;
            external name 'munmap';
function  _libc_mremap(OldAddr: Pointer; OldSize, NewSize: Int64;
            Flags: Integer): Pointer; external name 'mremap';
procedure _libc_memcpy(Dst, Src: Pointer; N: Int64); external name 'memcpy';

const
  PROT_READ       = 1;
  PROT_WRITE      = 2;
  MAP_PRIVATE     = 2;
  MAP_ANONYMOUS   = 32;
  MAP_FAILED_VAL  = -1;
  MREMAP_MAYMOVE  = 1;

  PAGE_SIZE       = 4096;
  ARENA_SIZE      = 65536;
  LARGE_THRESHOLD = 2048;
  HEADER_SIZE     = 16;
  LARGE_HEADER    = 24;
  LARGE_CACHE_MAX = 32;

{ CROSS-LAYOUT INVARIANT (concurrent-allocator-design.adoc, §Data
  structures): IsLarge and GetAllocSize classify a block by reading Flags
  through the SMALL layout at Ptr - HEADER_SIZE, regardless of the block
  kind.  This works only because both layouts place Flags at the same
  distance from the user pointer:

    small: Ptr - 16 + 4  = Ptr - 12
    large: Ptr - 24 + 12 = Ptr - 12

  New fields must therefore be appended AFTER Flags in both records;
  reordering either silently breaks every free.  The invariant is pinned
  by Test_FlagsOffset_Invariant in test_blaise_mem.pas. }

type
  PArena = ^TArena;

  PBlockHeader = ^TBlockHeader;
  TBlockHeader = record
    AllocSize: Integer;
    Flags:     Integer;
    Arena:     PArena;   { owning arena — the cross-thread routing key }
  end;

  PLargeHeader = ^TLargeHeader;
  TLargeHeader = record
    TotalMapped: Int64;
    AllocSize:   Integer;
    Flags:       Integer;
    OwnerTid:    Int64;  { allocating thread's tid (MyTid).  LargeFreeMem
                           caches on a local free and munmaps on a
                           foreign one (concurrent-allocator-design.adoc,
                           §The large-block remote path, option 2) }
  end;

  PFreeNode = ^TFreeNode;
  TFreeNode = record
    Next: PFreeNode;
  end;

  PLargeFreeNode = ^TLargeFreeNode;
  TLargeFreeNode = record
    Next:        PLargeFreeNode;
    TotalMapped: Int64;
  end;

  TArena = record
    Base:     Pointer;
    Offset:   Integer;
    Capacity: Integer;
    Next:     PArena;
    { Migration-safe cross-thread free path (concurrent-allocator-design.adoc).
      OwnerTid identifies the owning thread (0 = abandoned, a later phase);
      RemoteHead is the MPSC remote-free stack head, touched ONLY through
      _AtomicCASPtr (producer push) / _AtomicXchgPtr (owner drain);
      RemoteList is reserved for the global abandoned-arena registry
      (phase 5) and stays nil until that lands. }
    OwnerTid:   Int64;
    RemoteHead: Pointer;
    RemoteList: PArena;
  end;

  { A foreign-freed block's intrusive node, living in the block's user
    bytes while it waits on an arena's RemoteHead.  SizeClass lets the
    draining owner file it without re-reading the block header.  16 bytes
    with default alignment — fits even the smallest (16-byte) class. }
  PRemoteNode = ^TRemoteNode;
  TRemoteNode = record
    Next:      PRemoteNode;
    SizeClass: Integer;
  end;

const
  FLAG_LARGE = 1;
  FLAG_SMALL = 0;

threadvar
  FreeLists: array[0..7] of PFreeNode;
  ArenaHead: PArena;
  LargeFreeHead: PLargeFreeNode;
  LargeFreeCount: Integer;
  { Cross-thread free path state.  TidAnchor exists only for its per-thread
    TLS address (see MyTid); FreeDrainCounter and DrainCursor implement the
    periodic rotating free-side drain. }
  TidAnchor: Int64;
  FreeDrainCounter: Integer;
  DrainCursor: PArena;

{ Per-thread identity for the owner-vs-foreign test.  The address of a
  threadvar is unique among live threads (each thread has its own TLS
  block) and never zero, which is all OwnerTid needs.  This deliberately
  deviates from the design doc's pthread_self binding: it costs one leaq
  instead of a libc call, needs no pthread_self shim in the static
  (libc-free) build, and is CPU/OS-invariant. }
function MyTid: Int64;
begin
  Result := Int64(PtrUInt(@TidAnchor));
end;

{ Producer side: push a foreign-freed block onto its owning arena's MPSC
  remote-free stack (Treiber push; one CAS, retried on contention with
  another producer).  lock cmpxchg is a full barrier on x86-64, so the
  node-field stores are published before the new head (release). }
procedure RemoteFreePush(Arena: PArena; Ptr: Pointer; SizeClass: Integer);
var
  Node: PRemoteNode;
  OldHead: Pointer;
begin
  Node := PRemoteNode(Ptr);
  Node^.SizeClass := SizeClass;
  repeat
    OldHead := Arena^.RemoteHead;
    Node^.Next := PRemoteNode(OldHead);
  until _AtomicCASPtr(@Arena^.RemoteHead, OldHead, Pointer(Node));
end;

{ Consumer side: the OWNING thread claims the whole remote stack with one
  atomic exchange, then walks the now-private list with no atomics and
  files each block onto its normal freelist.  Only the owner ever drains
  its arenas — the single-consumer guarantee that makes the walk safe. }
procedure DrainRemoteFrees(Arena: PArena);
var
  Claimed, Nxt: PRemoteNode;
  FNode: PFreeNode;
begin
  if Arena^.RemoteHead = nil then Exit;
  Claimed := PRemoteNode(_AtomicXchgPtr(@Arena^.RemoteHead, nil));
  while Claimed <> nil do
  begin
    Nxt := Claimed^.Next;
    FNode := PFreeNode(Claimed);
    FNode^.Next := FreeLists[Claimed^.SizeClass];
    FreeLists[Claimed^.SizeClass] := FNode;
    Claimed := Nxt;
  end;
end;

{ Cold path: drain every arena the calling thread owns.  Used before
  growing the arena list — reclaiming foreign frees can avoid the mmap. }
procedure DrainAllRemoteFrees;
var
  A: PArena;
begin
  A := ArenaHead;
  while A <> nil do
  begin
    DrainRemoteFrees(A);
    A := A^.Next;
  end;
end;

function MapFailed(P: Pointer): Boolean;
begin
  Result := (P = nil) or (PtrUInt(P) = PtrUInt(MAP_FAILED_VAL));
end;

function PageRound(Size: Int64): Int64;
begin
  Result := (Size + Int64(PAGE_SIZE - 1)) and Int64($FFFFFFFFFFFFF000);
end;

function MmapAlloc(Size: Int64): Pointer;
begin
  Size := PageRound(Size);
  Result := _libc_mmap(nil, Size,
    PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS,
    -1, 0);
  if MapFailed(Result) then
    Result := nil;
end;

function SizeClassIndex(Size: Integer): Integer;
begin
  if Size <= 16 then begin Result := 0; Exit end;
  if Size <= 32 then begin Result := 1; Exit end;
  if Size <= 64 then begin Result := 2; Exit end;
  if Size <= 128 then begin Result := 3; Exit end;
  if Size <= 256 then begin Result := 4; Exit end;
  if Size <= 512 then begin Result := 5; Exit end;
  if Size <= 1024 then begin Result := 6; Exit end;
  Result := 7;
end;

function SizeClassBytes(Index: Integer): Integer;
begin
  case Index of
    0: Result := 16;
    1: Result := 32;
    2: Result := 64;
    3: Result := 128;
    4: Result := 256;
    5: Result := 512;
    6: Result := 1024;
  else
    Result := 2048;
  end;
end;

function RoundUpToClass(Size: Integer): Integer;
begin
  Result := SizeClassBytes(SizeClassIndex(Size));
end;

function AllocArena: PArena;
var
  Base: Pointer;
  A: PArena;
begin
  Base := MmapAlloc(Int64(ARENA_SIZE));
  if Base = nil then
  begin
    Exit(nil);
  end;
  A := PArena(Base);
  A^.Base := Base;
  A^.Offset := SizeOf(TArena);
  A^.Capacity := ARENA_SIZE;
  A^.Next := ArenaHead;
  A^.OwnerTid := MyTid();
  A^.RemoteHead := nil;
  A^.RemoteList := nil;
  ArenaHead := A;
  Result := A;
end;

function ArenaAlloc(Size: Integer): Pointer;
var
  A: PArena;
  BlockSize, Needed: Integer;
  Hdr: PBlockHeader;
  Node: PFreeNode;
  Idx: Integer;
begin
  BlockSize := RoundUpToClass(Size);
  Needed := HEADER_SIZE + BlockSize;

  A := ArenaHead;
  if (A <> nil) and (A^.Offset + Needed <= A^.Capacity) then
  begin
    Hdr := Pointer(PtrUInt(A^.Base) + PtrUInt(A^.Offset));
    Hdr^.AllocSize := Size;
    Hdr^.Flags := FLAG_SMALL;
    Hdr^.Arena := A;
    A^.Offset := A^.Offset + Needed;
    Exit(Pointer(PtrUInt(Hdr) + HEADER_SIZE));
  end;

  { Head arena exhausted (cold path).  Drain every owned arena's remote
    queue first — a foreign-freed block of the needed class avoids the
    mmap entirely. }
  DrainAllRemoteFrees();
  Idx := SizeClassIndex(Size);
  Node := FreeLists[Idx];
  if Node <> nil then
  begin
    FreeLists[Idx] := Node^.Next;
    Hdr := PBlockHeader(Pointer(PtrUInt(Node) - HEADER_SIZE));
    Hdr^.AllocSize := Size;
    Exit(Pointer(Node));
  end;

  A := AllocArena();
  if A = nil then
  begin
    Exit(nil);
  end;
  Hdr := Pointer(PtrUInt(A^.Base) + PtrUInt(A^.Offset));
  Hdr^.AllocSize := Size;
  Hdr^.Flags := FLAG_SMALL;
  Hdr^.Arena := A;
  A^.Offset := A^.Offset + Needed;
  Result := Pointer(PtrUInt(Hdr) + HEADER_SIZE);
end;

function SmallGetMem(Size: Integer): Pointer;
var
  Idx: Integer;
  Node: PFreeNode;
  Hdr: PBlockHeader;
begin
  Idx := SizeClassIndex(Size);

  Node := FreeLists[Idx];
  if (Node = nil) and (ArenaHead <> nil)
     and (ArenaHead^.RemoteHead <> nil) then
  begin
    { Empty freelist: drain the head arena's remote queue first — a
      foreign free of this class satisfies the request without growing
      the arena.  The nil check above keeps the non-fiber fast path at
      one load + not-taken branch. }
    DrainRemoteFrees(ArenaHead);
    Node := FreeLists[Idx];
  end;
  if Node <> nil then
  begin
    FreeLists[Idx] := Node^.Next;
    Hdr := PBlockHeader(Pointer(PtrUInt(Node) - HEADER_SIZE));
    Hdr^.AllocSize := Size;
    Exit(Pointer(Node));
  end;

  Result := ArenaAlloc(Size);
end;

procedure SmallFreeMem(Ptr: Pointer);
var
  Hdr: PBlockHeader;
  Idx: Integer;
  Node: PFreeNode;
  Arena: PArena;
begin
  Hdr := PBlockHeader(Pointer(PtrUInt(Ptr) - HEADER_SIZE));
  Idx := SizeClassIndex(Hdr^.AllocSize);
  Arena := Hdr^.Arena;

  if Arena^.OwnerTid = MyTid() then
  begin
    { LOCAL fast path — identical to the pre-concurrency code, zero
      atomics. }
    Node := PFreeNode(Ptr);
    Node^.Next := FreeLists[Idx];
    FreeLists[Idx] := Node;
    { Periodic rotating drain: every 64th local free, drain ONE arena,
      walking ArenaHead -> Next and wrapping, so foreign frees to
      non-head arenas cannot starve regardless of allocation rate. }
    Inc(FreeDrainCounter);
    if (FreeDrainCounter and 63) = 0 then
    begin
      if DrainCursor = nil then
        DrainCursor := ArenaHead;
      if DrainCursor <> nil then
      begin
        DrainRemoteFrees(DrainCursor);
        DrainCursor := DrainCursor^.Next;
      end;
    end;
  end
  else
    { FOREIGN path: the block belongs to another thread's arena — route
      it back via the arena's MPSC remote-free queue; never touch this
      thread's freelists. }
    RemoteFreePush(Arena, Ptr, Idx);
end;

function LargeGetMem(Size: Integer): Pointer;
var
  Total: Int64;
  Base: Pointer;
  Hdr: PLargeHeader;
  Node: PLargeFreeNode;
  Needed, CachedSize: Int64;
begin
  Needed := PageRound(Int64(LARGE_HEADER) + Int64(Size));

  Node := LargeFreeHead;
  if Node <> nil then
  begin
    CachedSize := Node^.TotalMapped;
    LargeFreeHead := Node^.Next;
    Dec(LargeFreeCount);
    if CachedSize >= Needed then
    begin
      Hdr := PLargeHeader(Pointer(Node));
      Hdr^.TotalMapped := CachedSize;
      Hdr^.AllocSize := Size;
      Hdr^.Flags := FLAG_LARGE;
      Hdr^.OwnerTid := MyTid();
      Exit(Pointer(PtrUInt(Hdr) + LARGE_HEADER));
    end;
    Base := _libc_mremap(Pointer(Node), CachedSize, Needed, MREMAP_MAYMOVE);
    if not MapFailed(Base) then
    begin
      Hdr := PLargeHeader(Base);
      Hdr^.TotalMapped := Needed;
      Hdr^.AllocSize := Size;
      Hdr^.Flags := FLAG_LARGE;
      Hdr^.OwnerTid := MyTid();
      Exit(Pointer(PtrUInt(Base) + LARGE_HEADER));
    end;
    _libc_munmap(Pointer(Node), CachedSize);
  end;

  Total := Needed;
  Base := MmapAlloc(Total);
  if Base = nil then
  begin
    Exit(nil);
  end;
  Hdr := PLargeHeader(Base);
  Hdr^.TotalMapped := Total;
  Hdr^.AllocSize := Size;
  Hdr^.Flags := FLAG_LARGE;
  Hdr^.OwnerTid := MyTid();
  Result := Pointer(PtrUInt(Base) + LARGE_HEADER);
end;

procedure LargeFreeMem(Ptr: Pointer);
var
  Hdr: PLargeHeader;
  Node: PLargeFreeNode;
begin
  Hdr := PLargeHeader(Pointer(PtrUInt(Ptr) - LARGE_HEADER));
  { Foreign free: a large block is its own private mapping, so any
    thread can munmap it directly — the design's option 2 (§The
    large-block remote path).  Only a LOCAL free may cache the block;
    otherwise a mapping allocated by thread A would sit on thread B's
    threadvar LIFO cache and be handed out from there. }
  if Hdr^.OwnerTid <> MyTid() then
  begin
    _libc_munmap(Pointer(Hdr), Hdr^.TotalMapped);
    Exit;
  end;
  if LargeFreeCount < LARGE_CACHE_MAX then
  begin
    Node := PLargeFreeNode(Pointer(Hdr));
    Node^.TotalMapped := Hdr^.TotalMapped;
    Node^.Next := LargeFreeHead;
    LargeFreeHead := Node;
    Inc(LargeFreeCount);
  end
  else
    _libc_munmap(Pointer(Hdr), Hdr^.TotalMapped);
end;

function IsLarge(Ptr: Pointer): Boolean;
var
  Hdr: PBlockHeader;
begin
  Hdr := PBlockHeader(Pointer(PtrUInt(Ptr) - HEADER_SIZE));
  Result := Hdr^.Flags = FLAG_LARGE;
end;

function GetAllocSize(Ptr: Pointer): Integer;
var
  SmallHdr: PBlockHeader;
  LargeHdr: PLargeHeader;
begin
  SmallHdr := PBlockHeader(Pointer(PtrUInt(Ptr) - HEADER_SIZE));
  if SmallHdr^.Flags = FLAG_LARGE then
  begin
    LargeHdr := PLargeHeader(Pointer(PtrUInt(Ptr) - LARGE_HEADER));
    Result := LargeHdr^.AllocSize;
  end
  else
    Result := SmallHdr^.AllocSize;
end;

{ ------------------------------------------------------------------ }
{ Public API                                                           }
{ ------------------------------------------------------------------ }

function _BlaiseGetMem(Size: Integer): Pointer;
begin
  if Size <= 0 then
  begin
    Exit(nil);
  end;
  if Size > LARGE_THRESHOLD then
    Result := LargeGetMem(Size)
  else
    Result := SmallGetMem(Size);
end;

procedure _BlaiseFreeMem(Ptr: Pointer);
begin
  if Ptr = nil then Exit;
  if IsLarge(Ptr) then
    LargeFreeMem(Ptr)
  else
    SmallFreeMem(Ptr);
end;

function _BlaiseReallocMem(Ptr: Pointer; NewSize: Integer): Pointer;
var
  OldSize, CopySize: Integer;
  Hdr: PBlockHeader;
  LHdr: PLargeHeader;
  Base, NewBase: Pointer;
  OldMapped, NewMapped: Int64;
begin
  if Ptr = nil then
  begin
    Exit(_BlaiseGetMem(NewSize));
  end;
  if NewSize <= 0 then
  begin
    _BlaiseFreeMem(Ptr);
    Exit(nil);
  end;
  OldSize := GetAllocSize(Ptr);
  if (not IsLarge(Ptr)) and (NewSize <= LARGE_THRESHOLD) then
  begin
    if RoundUpToClass(NewSize) = RoundUpToClass(OldSize) then
    begin
      Hdr := PBlockHeader(Pointer(PtrUInt(Ptr) - HEADER_SIZE));
      Hdr^.AllocSize := NewSize;
      Exit(Ptr);
    end;
  end;
  if IsLarge(Ptr) and (NewSize > LARGE_THRESHOLD) then
  begin
    LHdr := PLargeHeader(Pointer(PtrUInt(Ptr) - LARGE_HEADER));
    OldMapped := LHdr^.TotalMapped;
    NewMapped := PageRound(Int64(LARGE_HEADER) + Int64(NewSize));
    if NewMapped = OldMapped then
    begin
      LHdr^.AllocSize := NewSize;
      Exit(Ptr);
    end;
    Base := Pointer(LHdr);
    NewBase := _libc_mremap(Base, OldMapped, NewMapped, MREMAP_MAYMOVE);
    if not MapFailed(NewBase) then
    begin
      LHdr := PLargeHeader(NewBase);
      LHdr^.TotalMapped := NewMapped;
      LHdr^.AllocSize := NewSize;
      LHdr^.Flags := FLAG_LARGE;
      LHdr^.OwnerTid := MyTid();
      Exit(Pointer(PtrUInt(NewBase) + LARGE_HEADER));
    end;
  end;
  Result := _BlaiseGetMem(NewSize);
  if Result = nil then Exit;
  if OldSize < NewSize then
    CopySize := OldSize
  else
    CopySize := NewSize;
  _libc_memcpy(Result, Ptr, Int64(CopySize));
  _BlaiseFreeMem(Ptr);
end;

end.
