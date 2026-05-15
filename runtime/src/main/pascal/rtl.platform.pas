{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit rtl.platform;

// Blaise RTL — platform abstraction layer.
//
// TRtlPlatform is the abstract base class defining all OS-level operations.
// No {$IFDEF} directives appear anywhere in this unit or its concrete
// implementations.  Platform-specific behaviour is expressed by subclassing
// TRtlPlatform and assigning the instance to GRtlPlatform at program start.

interface

type
  TRtlPlatform = class
  public
    { File operations }
    function FileExists(const APath: string): Boolean; virtual; abstract;
    procedure DeleteFile(const APath: string); virtual; abstract;
    function RenameFile(const AOldPath, ANewPath: string): Boolean; virtual; abstract;
    function ReadFile(const APath: string): string; virtual; abstract;
    procedure WriteFile(const APath, AContent: string); virtual; abstract;
    procedure AppendFile(const APath, AContent: string); virtual; abstract;

    { Directory operations }
    function DirectoryExists(const APath: string): Boolean; virtual; abstract;
    function ForceDirectories(const APath: string): Boolean; virtual; abstract;
    function RemoveDir(const APath: string): Boolean; virtual; abstract;
    function GetCurrentDir: string; virtual; abstract;
    function SetCurrentDir(const APath: string): Boolean; virtual; abstract;

    { Path utilities }
    function ChangeFileExt(const APath, AExt: string): string; virtual; abstract;
    function ExtractFileName(const APath: string): string; virtual; abstract;
    function ExtractFilePath(const APath: string): string; virtual; abstract;
    function ExtractFileDir(const APath: string): string; virtual; abstract;
    function ExtractFileExt(const APath: string): string; virtual; abstract;
    function IncludeTrailingPathDelimiter(const APath: string): string; virtual; abstract;
    function ExcludeTrailingPathDelimiter(const APath: string): string; virtual; abstract;

    { OS utilities }
    function GetTempDir: string; virtual; abstract;
    function GetTempFileName(const ADir, APrefix: string): string; virtual; abstract;
    function GetProcessID: Integer; virtual; abstract;
    function GetEnvVar(const AName: string): string; virtual; abstract;
    procedure Sleep(AMilliseconds: Integer); virtual; abstract;
    procedure Halt(AExitCode: Integer); virtual; abstract;

    { Process }
    function Exec(const ACmd: string): Integer; virtual; abstract;
    function ParamCount: Integer; virtual; abstract;
    function ParamStr(AIndex: Integer): string; virtual; abstract;
  end;

var
  GRtlPlatform: TRtlPlatform;

implementation

end.
