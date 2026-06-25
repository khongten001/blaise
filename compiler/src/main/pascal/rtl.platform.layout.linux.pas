{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit rtl.platform.layout.linux;

// Linux x86_64 struct layouts and OS constants — the concrete TPlatformLayout
// adapter for Linux (docs/native-target-architecture.adoc, Step 0b).
//
// These are the values that previously lived as `const` declarations and the
// TStatBuf record inside rtl.platform.posix.pas.  Moving them behind the
// TPlatformLayout port keeps the POSIX method bodies (which are shared with
// FreeBSD) free of any Linux-specific layout assumption; the FreeBSD adapter
// supplies its own offsets and flag values without conditional compilation.
//
// struct stat offsets below match the Linux x86_64 `struct stat`
// (sys/stat.h): st_mode at byte 24, st_size at byte 48, st_mtime at byte 88.
// The buffer is sized at 144 bytes (sizeof(struct stat) on Linux x86_64).

interface

uses
  rtl.platform;

type
  TPlatformLayoutLinuxX86_64 = class(TPlatformLayout)
  public
    function O_RDONLY: Integer; override;
    function O_WRONLY: Integer; override;
    function O_RDWR:   Integer; override;
    function O_CREAT:  Integer; override;
    function O_TRUNC:  Integer; override;
    function O_APPEND: Integer; override;

    function S_IFMT:  Integer; override;
    function S_IFDIR: Integer; override;

    function SEEK_SET: Integer; override;
    function SEEK_CUR: Integer; override;
    function SEEK_END: Integer; override;

    function CLOCK_REALTIME: Integer; override;
    function WNOHANG:        Integer; override;

    function StatBufSize: Integer; override;
    function StatSize(Buf: Pointer):  Int64; override;
    function StatMtime(Buf: Pointer): Int64; override;
    function StatMode(Buf: Pointer):  Integer; override;
  end;

implementation

const
  { Linux x86_64 struct stat field offsets (bytes). }
  STAT_OFF_MODE  = 24;   { st_mode  (Integer) }
  STAT_OFF_SIZE  = 48;   { st_size  (Int64)   }
  STAT_OFF_MTIME = 88;   { st_mtim.tv_sec (Int64) }
  STAT_SIZE      = 144;  { sizeof(struct stat) }

function TPlatformLayoutLinuxX86_64.O_RDONLY: Integer; begin Result := 0;     end;
function TPlatformLayoutLinuxX86_64.O_WRONLY: Integer; begin Result := 1;     end;
function TPlatformLayoutLinuxX86_64.O_RDWR:   Integer; begin Result := 2;     end;
function TPlatformLayoutLinuxX86_64.O_CREAT:  Integer; begin Result := $40;   end;
function TPlatformLayoutLinuxX86_64.O_TRUNC:  Integer; begin Result := $200;  end;
function TPlatformLayoutLinuxX86_64.O_APPEND: Integer; begin Result := $400;  end;

function TPlatformLayoutLinuxX86_64.S_IFMT:  Integer; begin Result := $F000; end;
function TPlatformLayoutLinuxX86_64.S_IFDIR: Integer; begin Result := $4000; end;

function TPlatformLayoutLinuxX86_64.SEEK_SET: Integer; begin Result := 0; end;
function TPlatformLayoutLinuxX86_64.SEEK_CUR: Integer; begin Result := 1; end;
function TPlatformLayoutLinuxX86_64.SEEK_END: Integer; begin Result := 2; end;

function TPlatformLayoutLinuxX86_64.CLOCK_REALTIME: Integer; begin Result := 0; end;
function TPlatformLayoutLinuxX86_64.WNOHANG:        Integer; begin Result := 1; end;

function TPlatformLayoutLinuxX86_64.StatBufSize: Integer;
begin
  Result := STAT_SIZE;
end;

function TPlatformLayoutLinuxX86_64.StatSize(Buf: Pointer): Int64;
var
  P: ^Int64;
begin
  P := Pointer(PChar(Buf) + STAT_OFF_SIZE);
  Result := P^;
end;

function TPlatformLayoutLinuxX86_64.StatMtime(Buf: Pointer): Int64;
var
  P: ^Int64;
begin
  P := Pointer(PChar(Buf) + STAT_OFF_MTIME);
  Result := P^;
end;

function TPlatformLayoutLinuxX86_64.StatMode(Buf: Pointer): Integer;
var
  P: ^Integer;
begin
  P := Pointer(PChar(Buf) + STAT_OFF_MODE);
  Result := P^;
end;

initialization
  if GPlatformLayout = nil then
    GPlatformLayout := TPlatformLayoutLinuxX86_64.Create();

end.
