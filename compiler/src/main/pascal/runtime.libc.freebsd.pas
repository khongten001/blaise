{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.libc.freebsd;

// libc-shaped leaves that are MORE than a raw syscall - they need logic the
// kernel does not provide: env lookup, the libc-style return shapes, the
// hw.ncpu sysctl.  Built on the raw syscalls in runtime.syscall.freebsd.
// Linked only in a static (libc-free) FreeBSD build
// (docs/freebsd-x86_64-backend-design.adoc).  The FreeBSD sibling of
// runtime.libc.linux.
//
// These DEFINE the bare POSIX names (getcwd, getenv, time, waitpid, execvp,
// sysconf) that rtl.platform.posix / runtime.thread import via `external name`,
// so they resolve here instead of FreeBSD's libc.
//
// Deltas from the Linux sibling:
//   * time() has no SYS_time on FreeBSD; it reads CLOCK_REALTIME via
//     clock_gettime and returns tv_sec.
//   * sysconf(CPU count) uses sysctl(hw.ncpu) — FreeBSD has no
//     sched_getaffinity.
// getcwd / getenv / waitpid / execvp are structurally identical (the syscall
// leaf provides sys_getcwd / wait4 / execve / environ on both targets).

interface

uses
  runtime.syscall.freebsd;   { provides `environ`, captured by _start }

{ libc-shaped getcwd: returns Buf on success, nil on error (the raw syscall
  returns 0 / -errno). }
function getcwd(Buf: PChar; Size: Int64): PChar;

{ getenv: linear scan of `environ` for "Name="   returns a pointer to the value
  (just past '='), or nil if not present. }
function getenv(Name: PChar): PChar;

{ time(2): FreeBSD has no SYS_time — read CLOCK_REALTIME and return tv_sec.  If
  T is non-nil the same value is written there (libc's optional out-param). }
function time(T: Pointer): Int64;

{ waitpid via wait4 with a NULL rusage. }
function waitpid(Pid: Integer; Status: Pointer; Options: Integer): Integer;

{ execvp: execve the name with the current `environ` as envp.  No $PATH search
  yet (matches the Linux sibling — the RTL only execs explicit paths). }
function execvp(File_: PChar; Argv: Pointer): Integer;

{ sysconf for the few names the RTL queries - currently only the online CPU
  count (_SC_NPROCESSORS_ONLN, passed as 84 by runtime.thread on every target),
  via sysctl(hw.ncpu). }
function sysconf(Name: Integer): Int64;

implementation

type
  PPointer = ^Pointer;
  PInt64   = ^Int64;

const
  { The token runtime.thread passes for the CPU-count query.  It is an internal
    RTL contract value (runtime.thread hardcodes 84 on every target), NOT
    FreeBSD's libc _SC_NPROCESSORS_ONLN (58) — we never reach FreeBSD's libc. }
  _SC_NPROCESSORS_ONLN = 84;
  CLOCK_REALTIME       = 0;
  { sysctl MIB for hw.ncpu (FreeBSD sys/sysctl.h): CTL_HW=6, HW_NCPU=3. }
  CTL_HW   = 6;
  HW_NCPU  = 3;

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
    Pointer at environ + I*8 (PPointer deref, the RTL idiom - no [] on a typed
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
var
  Ts: array[0..1] of Int64;   { struct timespec: tv_sec (Int64), tv_nsec (long) }
  Rc: Integer;
  Out_: PInt64;
begin
  Rc := clock_gettime(CLOCK_REALTIME, @Ts[0]);
  if Rc <> 0 then
    Result := -1
  else
    Result := Ts[0];          { tv_sec }
  if (T <> nil) and (Result >= 0) then
  begin
    Out_ := PInt64(T);
    Out_^ := Result;          { libc's optional out-param: *T = tv_sec }
  end;
end;

function waitpid(Pid: Integer; Status: Pointer; Options: Integer): Integer;
begin
  Result := wait4(Pid, Status, Options, nil);
end;

function execvp(File_: PChar; Argv: Pointer): Integer;
var
  PathEnv: PChar;
  PathKey: array[0..4] of Byte;
  Buf: array[0..4095] of Byte;
  NLen, DirStart, DirLen, I, J: Int64;
begin
  { Names containing '/' resolve relative to the CWD only (POSIX semantics):
    execve directly, no $PATH scan. }
  NLen := CStrLen(File_);
  I := 0;
  while I < NLen do
  begin
    if (File_[I] and $FF) = Ord('/') then
      Exit(execve(File_, Argv, environ));
    I := I + 1;
  end;

  { Bare name: try each colon-separated $PATH prefix in order.  execve only
    returns on failure, so falling through means "try the next directory".
    The 'PATH' key is copied into a local byte buffer for a stable address
    (freestanding: no managed-string literals here). }
  PathKey[0]:=Ord('P'); PathKey[1]:=Ord('A'); PathKey[2]:=Ord('T'); PathKey[3]:=Ord('H'); PathKey[4]:=0;
  PathEnv := getenv(PChar(@PathKey[0]));
  if PathEnv = nil then
    Exit(execve(File_, Argv, environ));

  DirStart := 0;
  while True do
  begin
    DirLen := 0;
    while ((PathEnv[DirStart + DirLen] and $FF) <> 0) and
          ((PathEnv[DirStart + DirLen] and $FF) <> Ord(':')) do
      DirLen := DirLen + 1;
    if DirLen + 1 + NLen + 1 <= 4096 then   { skip entries that cannot fit }
    begin
      J := 0;
      if DirLen = 0 then
      begin
        { An empty $PATH entry means the CWD: use "./name". }
        Buf[0] := Ord('.');
        J := 1;
      end
      else
      begin
        I := 0;
        while I < DirLen do
        begin
          Buf[J] := PathEnv[DirStart + I] and $FF;
          J := J + 1;
          I := I + 1;
        end;
      end;
      Buf[J] := Ord('/');
      J := J + 1;
      I := 0;
      while I < NLen do
      begin
        Buf[J] := File_[I] and $FF;
        J := J + 1;
        I := I + 1;
      end;
      Buf[J] := 0;
      execve(PChar(@Buf[0]), Argv, environ);
    end;
    if (PathEnv[DirStart + DirLen] and $FF) = 0 then Break;
    DirStart := DirStart + DirLen + 1;
  end;
  Result := -1;
end;

function sysconf(Name: Integer): Int64;
var
  Mib: array[0..1] of Integer;   { the two-element MIB: CTL_HW, HW_NCPU }
  NCpu: Integer;
  OldLen: Int64;                 { size_t }
  Rc: Integer;
begin
  if Name = _SC_NPROCESSORS_ONLN then
  begin
    Mib[0] := CTL_HW;
    Mib[1] := HW_NCPU;
    NCpu := 0;
    OldLen := SizeOf(NCpu);      { 4 }
    Rc := sysctl(@Mib[0], 2, @NCpu, @OldLen, nil, 0);
    if (Rc <> 0) or (NCpu < 1) then
      Result := 1                { fall back to single CPU on error }
    else
      Result := NCpu;
  end
  else
    Result := -1;
end;

end.
