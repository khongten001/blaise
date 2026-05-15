{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit Generics.Collections;

// Blaise RTL — generic collections (mirrors Delphi's System.Generics.Collections
// and FPC's Generics.Collections for source-level compatibility).
//
// NOTE: This file is compiled by the Blaise compiler, not FPC.

interface

type
  TList<T> = class
    FData:     ^T;
    FCount:    Integer;
    FCapacity: Integer;
    procedure Grow;
    procedure Add(Value: T);
    function  Get(AIndex: Integer): T;
    procedure Delete(AIndex: Integer);
    procedure Clear;
    procedure Destroy;
    property Count: Integer read FCount;
  end;

  { Generic LIFO stack backed by a dynamic array.  Push/Pop/Peek operate on
    the top of the stack; Count reflects the number of items currently held. }
  TStack<T> = class
    FData:     ^T;
    FCount:    Integer;
    FCapacity: Integer;
    procedure Grow;
    procedure Push(Value: T);
    function  Pop: T;
    function  Peek: T;
    procedure Clear;
    procedure Destroy;
    property Count: Integer read FCount;
  end;

  { Generic FIFO queue backed by a dynamic circular-buffer array.
    Enqueue appends to the tail; Dequeue removes from the head.
    The buffer doubles when full, preserving insertion order. }
  TQueue<T> = class
    FData:     ^T;
    FCount:    Integer;
    FCapacity: Integer;
    FHead:     Integer;
    FTail:     Integer;
    procedure Grow;
    procedure Enqueue(Value: T);
    function  Dequeue: T;
    function  Peek: T;
    procedure Clear;
    procedure Destroy;
    property Count: Integer read FCount;
  end;

  { Generic unordered set backed by a dynamic array with linear-scan membership.
    Include adds an element only if not already present; Exclude removes it.
    Contains tests membership.  Suitable for small-to-medium sets where the
    element type supports '=' equality. }
  TSet<T> = class
    FData:     ^T;
    FCount:    Integer;
    FCapacity: Integer;
    procedure Grow;
    function  IndexOf(Value: T): Integer;
    procedure Include(Value: T);
    procedure Exclude(Value: T);
    function  Contains(Value: T): Boolean;
    procedure Clear;
    procedure Destroy;
    property Count: Integer read FCount;
  end;

  { Generic map interface: common contract for dictionary-like types. }
  IMap<K, V> = interface
    procedure Add(Key: K; Value: V);
    function  TryGetValue(Key: K; var Value: V): Boolean;
    function  ContainsKey(Key: K): Boolean;
    procedure Remove(Key: K);
    function  GetCount: Integer;
  end;

  { Generic dictionary: linear-scan key table backed by two parallel arrays.
    Key equality uses the '=' operator on the monomorphized type, so integer,
    boolean and pointer key types work out of the box.  String keys require
    content-aware equality which is deferred. }
  TDictionary<K, V> = class(IMap<K, V>)
    FKeys:     ^K;
    FValues:   ^V;
    FCount:    Integer;
    FCapacity: Integer;
    procedure Grow;
    function  FindKey(Key: K): Integer;
    procedure Add(Key: K; Value: V);
    function  TryGetValue(Key: K; var Value: V): Boolean;
    function  ContainsKey(Key: K): Boolean;
    procedure Remove(Key: K);
    function  GetCount: Integer;
    procedure Destroy;
    property Count: Integer read FCount;
  end;

  { Generic insertion-ordered map.  Entries are stored in the order they were
    first added; iteration and indexed access preserve that order.  Like
    TDictionary it uses linear-scan equality, so it is suitable for small maps
    where insertion order matters (e.g. preserving configuration file order,
    deterministic output). }
  TOrderedDictionary<K, V> = class(IMap<K, V>)
    FKeys:     ^K;
    FValues:   ^V;
    FCount:    Integer;
    FCapacity: Integer;
    procedure Grow;
    function  FindKey(Key: K): Integer;
    procedure Add(Key: K; Value: V);
    function  TryGetValue(Key: K; var Value: V): Boolean;
    function  ContainsKey(Key: K): Boolean;
    procedure Remove(Key: K);
    function  GetKey(AIndex: Integer): K;
    function  GetValue(AIndex: Integer): V;
    function  GetCount: Integer;
    procedure Destroy;
    property Count: Integer read FCount;
    property Keys[Index: Integer]: K read GetKey;
    property Values[Index: Integer]: V read GetValue;
  end;

implementation

{ ------------------------------------------------------------------ }
{ TList<T>                                                             }
{ ------------------------------------------------------------------ }

procedure TList<T>.Grow;
var
  NewCap: Integer;
  OldCap: Integer;
begin
  OldCap := Self.FCapacity;
  if OldCap = 0 then
    NewCap := 4
  else
    NewCap := OldCap * 2;
  Self.FData     := ReallocMem(Self.FData, NewCap * SizeOf(T));
  ZeroMem(Self.FData + OldCap * SizeOf(T), (NewCap - OldCap) * SizeOf(T));
  Self.FCapacity := NewCap
end;

procedure TList<T>.Add(Value: T);
var
  Dest: ^T;
begin
  if Self.FCount = Self.FCapacity then
    Self.Grow;
  Dest        := Self.FData + Self.FCount * SizeOf(T);
  Dest^       := Value;
  Self.FCount := Self.FCount + 1
end;

function TList<T>.Get(AIndex: Integer): T;
var
  Src: ^T;
begin
  Src    := Self.FData + AIndex * SizeOf(T);
  Result := Src^
end;

procedure TList<T>.Delete(AIndex: Integer);
var
  Src: ^T;
  Dst: ^T;
  I:   Integer;
begin
  I := AIndex;
  while I < Self.FCount - 1 do
  begin
    Dst  := Self.FData + I * SizeOf(T);
    Src  := Self.FData + (I + 1) * SizeOf(T);
    Dst^ := Src^;
    I    := I + 1
  end;
  Self.FCount := Self.FCount - 1
end;

procedure TList<T>.Clear;
begin
  Self.FCount := 0
end;

procedure TList<T>.Destroy;
begin
  FreeMem(Self.FData);
  Self.FData     := nil;
  Self.FCount    := 0;
  Self.FCapacity := 0
end;

{ ------------------------------------------------------------------ }
{ TStack<T>                                                            }
{ ------------------------------------------------------------------ }

procedure TStack<T>.Grow;
var
  NewCap: Integer;
  OldCap: Integer;
begin
  OldCap := Self.FCapacity;
  if OldCap = 0 then
    NewCap := 4
  else
    NewCap := OldCap * 2;
  Self.FData     := ReallocMem(Self.FData, NewCap * SizeOf(T));
  ZeroMem(Self.FData + OldCap * SizeOf(T), (NewCap - OldCap) * SizeOf(T));
  Self.FCapacity := NewCap
end;

procedure TStack<T>.Push(Value: T);
var
  Dest: ^T;
begin
  if Self.FCount = Self.FCapacity then
    Self.Grow;
  Dest        := Self.FData + Self.FCount * SizeOf(T);
  Dest^       := Value;
  Self.FCount := Self.FCount + 1
end;

function TStack<T>.Pop: T;
var
  Src: ^T;
begin
  Self.FCount := Self.FCount - 1;
  Src         := Self.FData + Self.FCount * SizeOf(T);
  Result      := Src^
end;

function TStack<T>.Peek: T;
var
  Src: ^T;
begin
  Src    := Self.FData + (Self.FCount - 1) * SizeOf(T);
  Result := Src^
end;

procedure TStack<T>.Clear;
begin
  Self.FCount := 0
end;

procedure TStack<T>.Destroy;
begin
  FreeMem(Self.FData);
  Self.FData     := nil;
  Self.FCount    := 0;
  Self.FCapacity := 0
end;

{ ------------------------------------------------------------------ }
{ TQueue<T>                                                            }
{ ------------------------------------------------------------------ }

procedure TQueue<T>.Grow;
var
  NewCap: Integer;
  OldCap: Integer;
  NewData: ^T;
  I: Integer;
  Src: ^T;
  Dst: ^T;
begin
  OldCap  := Self.FCapacity;
  if OldCap = 0 then
    NewCap := 4
  else
    NewCap := OldCap * 2;
  NewData := GetMem(NewCap * SizeOf(T));
  ZeroMem(NewData, NewCap * SizeOf(T));
  I := 0;
  while I < Self.FCount do
  begin
    Src  := Self.FData + ((Self.FHead + I) mod OldCap) * SizeOf(T);
    Dst  := NewData + I * SizeOf(T);
    Dst^ := Src^;
    I    := I + 1
  end;
  FreeMem(Self.FData);
  Self.FData     := NewData;
  Self.FHead     := 0;
  Self.FTail     := Self.FCount;
  Self.FCapacity := NewCap
end;

procedure TQueue<T>.Enqueue(Value: T);
var
  Dest: ^T;
begin
  if Self.FCount = Self.FCapacity then
    Self.Grow;
  Dest        := Self.FData + Self.FTail * SizeOf(T);
  Dest^       := Value;
  Self.FTail  := (Self.FTail + 1) mod Self.FCapacity;
  Self.FCount := Self.FCount + 1
end;

function TQueue<T>.Dequeue: T;
var
  Src: ^T;
begin
  Src         := Self.FData + Self.FHead * SizeOf(T);
  Result      := Src^;
  Self.FHead  := (Self.FHead + 1) mod Self.FCapacity;
  Self.FCount := Self.FCount - 1
end;

function TQueue<T>.Peek: T;
var
  Src: ^T;
begin
  Src    := Self.FData + Self.FHead * SizeOf(T);
  Result := Src^
end;

procedure TQueue<T>.Clear;
begin
  Self.FCount := 0;
  Self.FHead  := 0;
  Self.FTail  := 0
end;

procedure TQueue<T>.Destroy;
begin
  FreeMem(Self.FData);
  Self.FData     := nil;
  Self.FCount    := 0;
  Self.FCapacity := 0;
  Self.FHead     := 0;
  Self.FTail     := 0
end;

{ ------------------------------------------------------------------ }
{ TSet<T>                                                              }
{ ------------------------------------------------------------------ }

procedure TSet<T>.Grow;
var
  NewCap: Integer;
  OldCap: Integer;
begin
  OldCap := Self.FCapacity;
  if OldCap = 0 then
    NewCap := 4
  else
    NewCap := OldCap * 2;
  Self.FData     := ReallocMem(Self.FData, NewCap * SizeOf(T));
  ZeroMem(Self.FData + OldCap * SizeOf(T), (NewCap - OldCap) * SizeOf(T));
  Self.FCapacity := NewCap
end;

function TSet<T>.IndexOf(Value: T): Integer;
var
  I:   Integer;
  Ptr: ^T;
begin
  Result := -1;
  I      := 0;
  while I < Self.FCount do
  begin
    Ptr := Self.FData + I * SizeOf(T);
    if Ptr^ = Value then
    begin
      Result := I;
      break
    end;
    I := I + 1
  end
end;

procedure TSet<T>.Include(Value: T);
var
  Dest: ^T;
begin
  if Self.IndexOf(Value) >= 0 then
    Exit;
  if Self.FCount = Self.FCapacity then
    Self.Grow;
  Dest        := Self.FData + Self.FCount * SizeOf(T);
  Dest^       := Value;
  Self.FCount := Self.FCount + 1
end;

procedure TSet<T>.Exclude(Value: T);
var
  Idx: Integer;
  I:   Integer;
  Dst: ^T;
  Src: ^T;
begin
  Idx := Self.IndexOf(Value);
  if Idx < 0 then
    Exit;
  I := Idx;
  while I < Self.FCount - 1 do
  begin
    Dst  := Self.FData + I * SizeOf(T);
    Src  := Self.FData + (I + 1) * SizeOf(T);
    Dst^ := Src^;
    I    := I + 1
  end;
  Self.FCount := Self.FCount - 1
end;

function TSet<T>.Contains(Value: T): Boolean;
begin
  Result := Self.IndexOf(Value) >= 0
end;

procedure TSet<T>.Clear;
begin
  Self.FCount := 0
end;

procedure TSet<T>.Destroy;
begin
  FreeMem(Self.FData);
  Self.FData     := nil;
  Self.FCount    := 0;
  Self.FCapacity := 0
end;

{ ------------------------------------------------------------------ }
{ TDictionary<K, V>                                                    }
{ ------------------------------------------------------------------ }

procedure TDictionary<K, V>.Grow;
var
  NewCap: Integer;
  OldCap: Integer;
begin
  OldCap := Self.FCapacity;
  if OldCap = 0 then
    NewCap := 8
  else
    NewCap := OldCap * 2;
  Self.FKeys     := ReallocMem(Self.FKeys,   NewCap * SizeOf(K));
  ZeroMem(Self.FKeys + OldCap * SizeOf(K), (NewCap - OldCap) * SizeOf(K));
  Self.FValues   := ReallocMem(Self.FValues, NewCap * SizeOf(V));
  ZeroMem(Self.FValues + OldCap * SizeOf(V), (NewCap - OldCap) * SizeOf(V));
  Self.FCapacity := NewCap
end;

function TDictionary<K, V>.FindKey(Key: K): Integer;
var
  I:   Integer;
  Ptr: ^K;
begin
  Result := -1;
  I      := 0;
  while I < Self.FCount do
  begin
    Ptr := Self.FKeys + I * SizeOf(K);
    if Ptr^ = Key then
    begin
      Result := I;
      break
    end;
    I := I + 1
  end
end;

procedure TDictionary<K, V>.Add(Key: K; Value: V);
var
  Idx:  Integer;
  KPtr: ^K;
  VPtr: ^V;
begin
  Idx := Self.FindKey(Key);
  if Idx >= 0 then
  begin
    { Update existing entry }
    VPtr  := Self.FValues + Idx * SizeOf(V);
    VPtr^ := Value
  end
  else
  begin
    { Insert new entry }
    if Self.FCount = Self.FCapacity then
      Self.Grow;
    KPtr  := Self.FKeys   + Self.FCount * SizeOf(K);
    VPtr  := Self.FValues + Self.FCount * SizeOf(V);
    KPtr^ := Key;
    VPtr^ := Value;
    Self.FCount := Self.FCount + 1
  end
end;

function TDictionary<K, V>.TryGetValue(Key: K; var Value: V): Boolean;
var
  Idx:  Integer;
  VPtr: ^V;
begin
  Idx := Self.FindKey(Key);
  if Idx >= 0 then
  begin
    VPtr   := Self.FValues + Idx * SizeOf(V);
    Value  := VPtr^;
    Result := True
  end
  else
    Result := False
end;

function TDictionary<K, V>.ContainsKey(Key: K): Boolean;
begin
  Result := Self.FindKey(Key) >= 0
end;

procedure TDictionary<K, V>.Remove(Key: K);
var
  Idx:  Integer;
  I:    Integer;
  KDst: ^K;
  KSrc: ^K;
  VDst: ^V;
  VSrc: ^V;
begin
  Idx := Self.FindKey(Key);
  if Idx >= 0 then
  begin
    { Compact: shift entries after Idx one slot left }
    I := Idx;
    while I < Self.FCount - 1 do
    begin
      KDst  := Self.FKeys   + I * SizeOf(K);
      KSrc  := Self.FKeys   + (I + 1) * SizeOf(K);
      VDst  := Self.FValues + I * SizeOf(V);
      VSrc  := Self.FValues + (I + 1) * SizeOf(V);
      KDst^ := KSrc^;
      VDst^ := VSrc^;
      I     := I + 1
    end;
    Self.FCount := Self.FCount - 1
  end
end;

function TDictionary<K, V>.GetCount: Integer;
begin
  Result := Self.FCount
end;

procedure TDictionary<K, V>.Destroy;
begin
  FreeMem(Self.FKeys);
  FreeMem(Self.FValues);
  Self.FKeys     := nil;
  Self.FValues   := nil;
  Self.FCount    := 0;
  Self.FCapacity := 0
end;

{ ------------------------------------------------------------------ }
{ TOrderedDictionary<K, V>                                             }
{ ------------------------------------------------------------------ }

procedure TOrderedDictionary<K, V>.Grow;
var
  NewCap: Integer;
  OldCap: Integer;
begin
  OldCap := Self.FCapacity;
  if OldCap = 0 then
    NewCap := 8
  else
    NewCap := OldCap * 2;
  Self.FKeys     := ReallocMem(Self.FKeys,   NewCap * SizeOf(K));
  ZeroMem(Self.FKeys + OldCap * SizeOf(K), (NewCap - OldCap) * SizeOf(K));
  Self.FValues   := ReallocMem(Self.FValues, NewCap * SizeOf(V));
  ZeroMem(Self.FValues + OldCap * SizeOf(V), (NewCap - OldCap) * SizeOf(V));
  Self.FCapacity := NewCap
end;

function TOrderedDictionary<K, V>.FindKey(Key: K): Integer;
var
  I:   Integer;
  Ptr: ^K;
begin
  Result := -1;
  I      := 0;
  while I < Self.FCount do
  begin
    Ptr := Self.FKeys + I * SizeOf(K);
    if Ptr^ = Key then
    begin
      Result := I;
      break
    end;
    I := I + 1
  end
end;

procedure TOrderedDictionary<K, V>.Add(Key: K; Value: V);
var
  Idx:  Integer;
  KPtr: ^K;
  VPtr: ^V;
begin
  Idx := Self.FindKey(Key);
  if Idx >= 0 then
  begin
    VPtr  := Self.FValues + Idx * SizeOf(V);
    VPtr^ := Value
  end
  else
  begin
    if Self.FCount = Self.FCapacity then
      Self.Grow;
    KPtr  := Self.FKeys   + Self.FCount * SizeOf(K);
    VPtr  := Self.FValues + Self.FCount * SizeOf(V);
    KPtr^ := Key;
    VPtr^ := Value;
    Self.FCount := Self.FCount + 1
  end
end;

function TOrderedDictionary<K, V>.TryGetValue(Key: K; var Value: V): Boolean;
var
  Idx:  Integer;
  VPtr: ^V;
begin
  Idx := Self.FindKey(Key);
  if Idx >= 0 then
  begin
    VPtr   := Self.FValues + Idx * SizeOf(V);
    Value  := VPtr^;
    Result := True
  end
  else
    Result := False
end;

function TOrderedDictionary<K, V>.ContainsKey(Key: K): Boolean;
begin
  Result := Self.FindKey(Key) >= 0
end;

procedure TOrderedDictionary<K, V>.Remove(Key: K);
var
  Idx:  Integer;
  I:    Integer;
  KDst: ^K;
  KSrc: ^K;
  VDst: ^V;
  VSrc: ^V;
begin
  Idx := Self.FindKey(Key);
  if Idx >= 0 then
  begin
    I := Idx;
    while I < Self.FCount - 1 do
    begin
      KDst  := Self.FKeys   + I * SizeOf(K);
      KSrc  := Self.FKeys   + (I + 1) * SizeOf(K);
      VDst  := Self.FValues + I * SizeOf(V);
      VSrc  := Self.FValues + (I + 1) * SizeOf(V);
      KDst^ := KSrc^;
      VDst^ := VSrc^;
      I     := I + 1
    end;
    Self.FCount := Self.FCount - 1
  end
end;

function TOrderedDictionary<K, V>.GetKey(AIndex: Integer): K;
var
  Ptr: ^K;
begin
  Ptr    := Self.FKeys + AIndex * SizeOf(K);
  Result := Ptr^
end;

function TOrderedDictionary<K, V>.GetValue(AIndex: Integer): V;
var
  Ptr: ^V;
begin
  Ptr    := Self.FValues + AIndex * SizeOf(V);
  Result := Ptr^
end;

function TOrderedDictionary<K, V>.GetCount: Integer;
begin
  Result := Self.FCount
end;

procedure TOrderedDictionary<K, V>.Destroy;
begin
  FreeMem(Self.FKeys);
  FreeMem(Self.FValues);
  Self.FKeys     := nil;
  Self.FValues   := nil;
  Self.FCount    := 0;
  Self.FCapacity := 0
end;

end.
