{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit rtl.platform.posix;

// Blaise RTL — POSIX implementation of the platform abstraction layer.
//
// TRtlPlatformPosix delegates every operation to the corresponding C RTL
// function declared below.  All external bindings are in the interface
// section (Blaise requirement: external declarations with a nil body must
// not appear in the implementation section to avoid codegen crashes).

interface

uses
  rtl.platform;

type
  TRtlPlatformPosix = class(TRtlPlatform)
  public
    { File operations }
    function FileExists(const APath: string): Boolean; override;
    procedure DeleteFile(const APath: string); override;
    function RenameFile(const AOldPath, ANewPath: string): Boolean; override;
    function ReadFile(const APath: string): string; override;
    procedure WriteFile(const APath, AContent: string); override;
    procedure AppendFile(const APath, AContent: string); override;

    { Directory operations }
    function DirectoryExists(const APath: string): Boolean; override;
    function ForceDirectories(const APath: string): Boolean; override;
    function RemoveDir(const APath: string): Boolean; override;
    function GetCurrentDir: string; override;
    function SetCurrentDir(const APath: string): Boolean; override;

    { Path utilities }
    function ChangeFileExt(const APath, AExt: string): string; override;
    function ExtractFileName(const APath: string): string; override;
    function ExtractFilePath(const APath: string): string; override;
    function ExtractFileDir(const APath: string): string; override;
    function ExtractFileExt(const APath: string): string; override;
    function IncludeTrailingPathDelimiter(const APath: string): string; override;
    function ExcludeTrailingPathDelimiter(const APath: string): string; override;

    { OS utilities }
    function GetTempDir: string; override;
    function GetTempFileName(const ADir, APrefix: string): string; override;
    function GetProcessID: Integer; override;
    function GetEnvVar(const AName: string): string; override;
    procedure Sleep(AMilliseconds: Integer); override;
    procedure Halt(AExitCode: Integer); override;

    { Process }
    function Exec(const ACmd: string): Integer; override;
    function ParamCount: Integer; override;
    function ParamStr(AIndex: Integer): string; override;
  end;

{ All external C RTL bindings in the interface section (Blaise requirement) }
function _FileExists(Path: Pointer): Integer; external name '_FileExists';
procedure _DeleteFile(Path: Pointer); external name '_DeleteFile';
function _RenameFile(OldPath, NewPath: Pointer): Integer; external name '_RenameFile';
function _ReadFile(Path: Pointer): Pointer; external name '_ReadFile';
procedure _WriteFile(Path, Content: Pointer); external name '_WriteFile';
procedure _AppendFile(Path, Content: Pointer); external name '_AppendFile';
function _DirectoryExists(Path: Pointer): Integer; external name '_DirectoryExists';
function _ForceDirectories(Path: Pointer): Integer; external name '_ForceDirectories';
procedure _RemoveDir(Path: Pointer); external name '_RemoveDir';
function _GetCurrentDir: Pointer; external name '_GetCurrentDir';
function _SetCurrentDir(Path: Pointer): Integer; external name '_SetCurrentDir';
function _ChangeFileExt(Path, Ext: Pointer): Pointer; external name '_ChangeFileExt';
function _ExtractFileName(Path: Pointer): Pointer; external name '_ExtractFileName';
function _ExtractFilePath(Path: Pointer): Pointer; external name '_ExtractFilePath';
function _ExtractFileDir(Path: Pointer): Pointer; external name '_ExtractFileDir';
function _ExtractFileExt(Path: Pointer): Pointer; external name '_ExtractFileExt';
function _IncludeTrailingPathDelimiter(Path: Pointer): Pointer; external name '_IncludeTrailingPathDelimiter';
function _ExcludeTrailingPathDelimiter(Path: Pointer): Pointer; external name '_ExcludeTrailingPathDelimiter';
function _GetTempDir: Pointer; external name '_GetTempDir';
function _GetTempFileName(Dir, Prefix: Pointer): Pointer; external name '_GetTempFileName';
function _GetProcessID: Integer; external name '_GetProcessID';
function _GetEnvVar(Name: Pointer): Pointer; external name '_GetEnvVar';
procedure _Sleep(Ms: Integer); external name '_Sleep';
procedure _Halt(Code: Integer); external name '_Halt';
function _Exec(Cmd: Pointer): Integer; external name '_Exec';
function _ParamCount: Integer; external name '_ParamCount';
function _ParamStr(Index: Integer): Pointer; external name '_ParamStr';

implementation

function TRtlPlatformPosix.FileExists(const APath: string): Boolean;
begin
  Result := _FileExists(Pointer(APath)) <> 0
end;

procedure TRtlPlatformPosix.DeleteFile(const APath: string);
begin
  _DeleteFile(Pointer(APath))
end;

function TRtlPlatformPosix.RenameFile(const AOldPath, ANewPath: string): Boolean;
begin
  Result := _RenameFile(Pointer(AOldPath), Pointer(ANewPath)) <> 0
end;

function TRtlPlatformPosix.ReadFile(const APath: string): string;
begin
  Result := string(_ReadFile(Pointer(APath)))
end;

procedure TRtlPlatformPosix.WriteFile(const APath, AContent: string);
begin
  _WriteFile(Pointer(APath), Pointer(AContent))
end;

procedure TRtlPlatformPosix.AppendFile(const APath, AContent: string);
begin
  _AppendFile(Pointer(APath), Pointer(AContent))
end;

function TRtlPlatformPosix.DirectoryExists(const APath: string): Boolean;
begin
  Result := _DirectoryExists(Pointer(APath)) <> 0
end;

function TRtlPlatformPosix.ForceDirectories(const APath: string): Boolean;
begin
  Result := _ForceDirectories(Pointer(APath)) <> 0
end;

function TRtlPlatformPosix.RemoveDir(const APath: string): Boolean;
begin
  _RemoveDir(Pointer(APath));
  Result := True
end;

function TRtlPlatformPosix.GetCurrentDir: string;
begin
  Result := string(_GetCurrentDir)
end;

function TRtlPlatformPosix.SetCurrentDir(const APath: string): Boolean;
begin
  Result := _SetCurrentDir(Pointer(APath)) <> 0
end;

function TRtlPlatformPosix.ChangeFileExt(const APath, AExt: string): string;
begin
  Result := string(_ChangeFileExt(Pointer(APath), Pointer(AExt)))
end;

function TRtlPlatformPosix.ExtractFileName(const APath: string): string;
begin
  Result := string(_ExtractFileName(Pointer(APath)))
end;

function TRtlPlatformPosix.ExtractFilePath(const APath: string): string;
begin
  Result := string(_ExtractFilePath(Pointer(APath)))
end;

function TRtlPlatformPosix.ExtractFileDir(const APath: string): string;
begin
  Result := string(_ExtractFileDir(Pointer(APath)))
end;

function TRtlPlatformPosix.ExtractFileExt(const APath: string): string;
begin
  Result := string(_ExtractFileExt(Pointer(APath)))
end;

function TRtlPlatformPosix.IncludeTrailingPathDelimiter(const APath: string): string;
begin
  Result := string(_IncludeTrailingPathDelimiter(Pointer(APath)))
end;

function TRtlPlatformPosix.ExcludeTrailingPathDelimiter(const APath: string): string;
begin
  Result := string(_ExcludeTrailingPathDelimiter(Pointer(APath)))
end;

function TRtlPlatformPosix.GetTempDir: string;
begin
  Result := string(_GetTempDir)
end;

function TRtlPlatformPosix.GetTempFileName(const ADir, APrefix: string): string;
begin
  Result := string(_GetTempFileName(Pointer(ADir), Pointer(APrefix)))
end;

function TRtlPlatformPosix.GetProcessID: Integer;
begin
  Result := _GetProcessID
end;

function TRtlPlatformPosix.GetEnvVar(const AName: string): string;
begin
  Result := string(_GetEnvVar(Pointer(AName)))
end;

procedure TRtlPlatformPosix.Sleep(AMilliseconds: Integer);
begin
  _Sleep(AMilliseconds)
end;

procedure TRtlPlatformPosix.Halt(AExitCode: Integer);
begin
  _Halt(AExitCode)
end;

function TRtlPlatformPosix.Exec(const ACmd: string): Integer;
begin
  Result := _Exec(Pointer(ACmd))
end;

function TRtlPlatformPosix.ParamCount: Integer;
begin
  Result := _ParamCount
end;

function TRtlPlatformPosix.ParamStr(AIndex: Integer): string;
begin
  Result := string(_ParamStr(AIndex))
end;


initialization
  GRtlPlatform := TRtlPlatformPosix.Create;

end.
