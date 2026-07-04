{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ punit tests for the errno-classification leaf (P3 of
  docs/async-networking-design.adoc): WouldBlock / Interrupted / GetOsErrno.

  The symbols are bound by bare name so this same program tests whichever
  profile it is linked against:

    * dynamic (default) — runtime.errno.<os>: read() returns -1, errno is
      *__errno_location(), GetOsErrno reflects it;
    * --static          — runtime.errno.static.<os>: read() returns -EAGAIN
      directly, GetOsErrno is always 0.

  Compile and run (dynamic profile):
    compiler/target/blaise --source runtime/src/test/pascal/test_blaise_errno.pas
        --unit-path runtime/src/test/pascal --output /tmp/test_blaise_errno
    /tmp/test_blaise_errno

  Add --static for the raw negative-errno profile. }

program test_blaise_errno;

uses punit;

function pipe(Fds: Pointer): Integer; external name 'pipe';
function fcntl(Fd, Cmd, Arg: Integer): Integer; external name 'fcntl';
function xread(Fd: Integer; Buf: Pointer; Count: Int64): Int64;
  external name 'read';
function WouldBlock(N: Int64): Boolean; external name 'WouldBlock';
function Interrupted(N: Int64): Boolean; external name 'Interrupted';
function GetOsErrno: Integer; external name 'GetOsErrno';

const
  F_GETFL = 3;
  F_SETFL = 4;
  O_NONBLOCK = 2048;   { Linux; the punit runtime tests run on the dev host }

var
  GReadRet: Int64;

{ Read from an empty non-blocking pipe once, in setup, so every test sees the
  same failing return value. }
function DoSetup: string;
var
  Fds: array[0..1] of Integer;
  Buf: array[0..7] of Byte;
  Flags: Integer;
begin
  Result := '';
  if pipe(@Fds[0]) <> 0 then
  begin
    Result := 'pipe() failed';
    Exit;
  end;
  Flags := fcntl(Fds[0], F_GETFL, 0);
  fcntl(Fds[0], F_SETFL, Flags or O_NONBLOCK);
  GReadRet := xread(Fds[0], @Buf[0], 8);
end;

function TestEmptyNonblockingReadWouldBlock: string;
begin
  { Libc profile: ret = -1 and errno = EAGAIN.  Static profile: ret = -EAGAIN.
    WouldBlock must classify both. }
  AssertTrue('read on empty O_NONBLOCK pipe classifies as would-block',
    WouldBlock(GReadRet));
  Result := '';
end;

function TestWouldBlockRejectsSuccess: string;
begin
  AssertFalse('0 is not would-block', WouldBlock(0));
  AssertFalse('positive byte count is not would-block', WouldBlock(42));
  Result := '';
end;

function TestNotInterrupted: string;
begin
  AssertFalse('EAGAIN is not EINTR', Interrupted(GReadRet));
  Result := '';
end;

function TestGetOsErrnoConsistent: string;
begin
  { Libc profile: read set errno; -1 + errno must agree with WouldBlock.
    Static profile: no errno variable — GetOsErrno is defined to return 0. }
  if GReadRet = -1 then
    AssertTrue('libc profile: errno nonzero after failing read',
      GetOsErrno() <> 0)
  else
    AssertEquals('static profile: GetOsErrno is 0', 0, GetOsErrno());
  Result := '';
end;

begin
  RequirePassed := True;
  AddSuite('ErrnoClassification', @DoSetup, nil, nil, False);
  AddTest('EmptyNonblockingReadWouldBlock',
    @TestEmptyNonblockingReadWouldBlock, 'ErrnoClassification');
  AddTest('WouldBlockRejectsSuccess',
    @TestWouldBlockRejectsSuccess, 'ErrnoClassification');
  AddTest('NotInterrupted', @TestNotInterrupted, 'ErrnoClassification');
  AddTest('GetOsErrnoConsistent',
    @TestGetOsErrnoConsistent, 'ErrnoClassification');
  RunAllSysTests();
end.
