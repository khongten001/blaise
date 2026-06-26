{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.libc.linux;

// libc-shaped leaves that are MORE than a raw syscall — they need logic the
// kernel does not provide: PATH/env lookup, the libc-style return shapes, etc.
// Built on the raw syscalls in runtime.syscall.linux.  Linked only in a
// --static (libc-free) build (docs/linux-syscall-migration.adoc).
//
// These DEFINE the bare POSIX names (getcwd, getenv, …) that rtl.platform.posix
// imports via `external name`, so they resolve here instead of libc.so.6.

interface

uses
  runtime.syscall.linux;

{ The process environment vector (NULL-terminated array of "KEY=VALUE" PChars).
  Captured by the freestanding _start (runtime.start.static.linux) from the
  initial process stack; libc would otherwise own this symbol.  getenv/execvp
  read it. }
var
  environ: Pointer;

{ libc-shaped getcwd: returns Buf on success, nil on error (the raw syscall
  returns a length / -errno). }
function getcwd(Buf: PChar; Size: Int64): PChar;

{ getenv: linear scan of `environ` for "Name=" → returns a pointer to the value
  (just past '='), or nil if not present. }
function getenv(Name: PChar): PChar;

{ time(2) wrapper matching libc's signature (the raw syscall already supports the
  optional out-param, so this just forwards). }
function time(T: Pointer): Int64;

{ waitpid via wait4 with a NULL rusage. }
function waitpid(Pid: Integer; Status: Pointer; Options: Integer): Integer;

{ execvp: search $PATH for File when it has no '/', then execve.  Argv is the
  NULL-terminated argument vector; the current `environ` is passed as envp. }
function execvp(File_: PChar; Argv: Pointer): Integer;

{ sysconf for the few names the RTL queries — currently only the online CPU
  count (_SC_NPROCESSORS_ONLN = 84), via sched_getaffinity + popcount. }
function sysconf(Name: Integer): Int64;

implementation

type
  PPointer = ^Pointer;

const
  _SC_NPROCESSORS_ONLN = 84;

{ --- small freestanding string helpers (no dependency on runtime.str) --- }

function CStrLen(S: PChar): Int64;
var I: Int64;
begin
  I := 0;
  while (S[I] and $FF) <> 0 do I := I + 1;
  Result := I;
end;

{ Compare the "KEY=" prefix of an environ entry against Name (length NLen).
  Returns True when Entry starts with Name immediately followed by '='. }
function EnvKeyMatches(Entry, Name: PChar; NLen: Int64): Boolean;
var I: Int64;
begin
  I := 0;
  while I < NLen do
  begin
    if (Entry[I] and $FF) <> (Name[I] and $FF) then Exit(False);
    if (Entry[I] and $FF) = 0 then Exit(False);
    I := I + 1;
  end;
  Result := (Entry[NLen] and $FF) = Ord('=');
end;

function getcwd(Buf: PChar; Size: Int64): PChar;
var Rc: Int64;
begin
  Rc := sys_getcwd(Buf, Size);
  if Rc < 0 then
    Result := nil
  else
    Result := Buf;
end;

function getenv(Name: PChar): PChar;
var
  Entry: PChar;
  NLen, Off: Int64;
begin
  Result := nil;
  if environ = nil then Exit;
  NLen := CStrLen(Name);
  { environ is a NULL-terminated array of PChar; read the I-th slot as a
    Pointer at environ + I*8 (PPointer deref, the RTL idiom — no [] on a typed
    pointer). }
  Off := 0;
  Entry := PChar(PPointer(Pointer(PChar(environ) + Off))^);
  while Entry <> nil do
  begin
    if EnvKeyMatches(Entry, Name, NLen) then
    begin
      Result := PChar(Pointer(PChar(Entry) + NLen + 1));  { just past '=' }
      Exit;
    end;
    Off := Off + 8;
    Entry := PChar(PPointer(Pointer(PChar(environ) + Off))^);
  end;
end;

function time(T: Pointer): Int64;
begin
  Result := sys_time(T);
end;

function waitpid(Pid: Integer; Status: Pointer; Options: Integer): Integer;
begin
  Result := wait4(Pid, Status, Options, nil);
end;

function execvp(File_: PChar; Argv: Pointer): Integer;
var
  HasSlash: Boolean;
  I: Int64;
begin
  { If File contains a '/', execve it directly; otherwise a PATH search would be
    needed.  The RTL only execs absolute/relative program paths (system() builds
    "/bin/sh"), so direct execve covers the present call sites; a PATH search can
    be added when a bare-name exec appears. }
  HasSlash := False;
  I := 0;
  while (File_[I] and $FF) <> 0 do
  begin
    if (File_[I] and $FF) = Ord('/') then HasSlash := True;
    I := I + 1;
  end;
  if HasSlash then
    Result := execve(File_, Argv, environ)
  else
    { No PATH search yet — try as-is so the failure is the kernel's ENOENT
      rather than a silent wrong result. }
    Result := execve(File_, Argv, environ);
end;

{ Population count of a 1024-bit affinity mask (128 bytes), counting set CPUs. }
function PopCountMask(Mask: PChar; NBytes: Int64): Int64;
var
  I, J, Cnt: Int64;
  B: Integer;
begin
  Cnt := 0;
  I := 0;
  while I < NBytes do
  begin
    B := Mask[I] and $FF;
    J := 0;
    while J < 8 do
    begin
      if (B and (1 shl J)) <> 0 then Cnt := Cnt + 1;
      J := J + 1;
    end;
    I := I + 1;
  end;
  Result := Cnt;
end;

function sysconf(Name: Integer): Int64;
var
  Mask: array[0..127] of Byte;   { 1024 CPUs worth of affinity bits }
  Rc: Integer;
begin
  if Name = _SC_NPROCESSORS_ONLN then
  begin
    Rc := sched_getaffinity(0, 128, @Mask[0]);
    if Rc <= 0 then
      Result := 1                { fall back to single CPU on error }
    else
      Result := PopCountMask(PChar(@Mask[0]), Rc);
    if Result < 1 then Result := 1;
  end
  else
    Result := -1;
end;

end.
