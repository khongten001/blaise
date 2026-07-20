{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit blaise.codegen.native;

{ Native code-generation backend — emits target assembly directly from the
  AST, replacing the external QBE tool (docs/toolchain-independence.adoc,
  Phase 5).

  Structure (two layers):

    TCodeGenNative   implements ICodeGen; walks the AST (the same TProgram /
                     TUnit the QBE backend receives) and drives a per-target
                     TNativeBackend.  GetOutput returns assembly text.

    TNativeBackend   abstract base over per-architecture machine-code lowering
                     (instruction selection, register allocation, assembly
                     printing, ABI).  Concrete subclasses live in
                     blaise.codegen.native.<arch> — TX86_64Backend first.

  Single-program compilation (Generate) and whole-program multi-unit
  compilation (AppendUnit per dependency, then AppendProgram) are both
  implemented for the x86-64 target.  Single-unit-in-isolation (GenerateUnit)
  is not yet implemented and raises ENativeCodeGenError. }

interface

uses
  SysUtils, Classes, uAST, uSymbolTable, blaise.codegen, uDebugFacts,
  blaise.codegen.target, blaise.codegen.native.backend;

type
  { ICodeGen implementation that lowers the AST to native assembly. }
  TCodeGenNative = class(TObject, ICodeGen)
  private
    FTarget:    TTargetDesc;
    FSymTable:  TSymbolTable;
    FDebugMode: Boolean;
    FSeparateCompile: Boolean;
    FBackend:   TNativeBackend;
    FDbgFacts:  TDbgFacts;   { owned; created by SetOpdfMode(True) }
    FRequiredLibs: TStringList;  { owned; always empty — the native backend
                                   emits float math inline (no libm calls) }
    procedure EnsureBackend;
  public
    constructor Create;
    destructor Destroy; override;

    { Backend-specific configuration — set before the object is used as an
      ICodeGen.  Not part of the ICodeGen contract. }
    procedure SetTarget(const ATarget: TTargetDesc);
    { Separate-compilation (incremental unit) mode: suppress per-unit system
      defs.  Set by the driver's CreateUnitCodeGen before AppendUnit. }
    procedure SetSeparateCompile(AEnabled: Boolean);

    { ICodeGen }
    procedure Generate(AProg: TProgram);
    procedure GenerateUnit(AUnit: TUnit);
    procedure SetSymbolTable(ASymTable: TSymbolTable);
    procedure SetDebugMode(AEnabled: Boolean);
    procedure SetOpdfMode(AEnabled: Boolean);
    function  GetDebugFacts: TDbgFacts;
    procedure AppendUnit(AUnit: TUnit);
    procedure AppendProgram(AProg: TProgram);
    procedure NoteDepInitUnit(const AUnitName: string; AHasInit: Boolean);
    procedure NoteDepFiniUnit(const AUnitName: string; AHasFini: Boolean);
    function  GetOutput: string;
    function  GetRequiredLibs: TStringList;
  end;

{ Construct the backend for a target, or raise ENativeCodeGenError if no
  native backend is implemented for it. }
function CreateNativeBackend(const ATarget: TTargetDesc): TNativeBackend;

implementation

uses
  blaise.codegen.toolkit;

{ ------------------------------------------------------------------ }
{ Backend factory                                                     }
{ ------------------------------------------------------------------ }

function CreateNativeBackend(const ATarget: TTargetDesc): TNativeBackend;
var
  Toolkit: TTargetToolkit;
begin
  { Resolve the per-target adapter family from the registry (Abstract
    Factory).  Adding a target is a new toolkit + one registration — this
    dispatch never changes.  See docs/native-target-architecture.adoc. }
  Toolkit := ResolveToolkit(ATarget);
  if Toolkit = nil then
    raise ENativeCodeGenError.Create(
      'native backend not yet implemented for target ' + TargetName(ATarget));
  Result := Toolkit.MakeBackend();
end;

{ ------------------------------------------------------------------ }
{ TCodeGenNative                                                      }
{ ------------------------------------------------------------------ }

constructor TCodeGenNative.Create;
begin
  inherited Create();
  MakeTarget(osLinux, cpuX86_64, FTarget);
  FSymTable  := nil;
  FDebugMode := False;
  FSeparateCompile := False;
  FBackend   := nil;
  FRequiredLibs := TStringList.Create();  { always empty — native math is inline }
end;

destructor TCodeGenNative.Destroy;
begin
  FBackend.Free();
  FRequiredLibs.Free();
  inherited Destroy();
end;

procedure TCodeGenNative.SetTarget(const ATarget: TTargetDesc);
begin
  FTarget := ATarget;
end;

procedure TCodeGenNative.SetSeparateCompile(AEnabled: Boolean);
begin
  FSeparateCompile := AEnabled;
end;

procedure TCodeGenNative.EnsureBackend;
begin
  if FBackend = nil then
    FBackend := CreateNativeBackend(FTarget);
end;

procedure TCodeGenNative.SetSymbolTable(ASymTable: TSymbolTable);
begin
  FSymTable := ASymTable;
end;

procedure TCodeGenNative.SetDebugMode(AEnabled: Boolean);
begin
  FDebugMode := AEnabled;
end;

procedure TCodeGenNative.SetOpdfMode(AEnabled: Boolean);
begin
  { OPDF mode: collect exact debug facts during codegen (frame offsets,
    per-statement line labels, function extents).  The driver appends the
    OPDF section to the same assembly file, so no symbol exports are needed. }
  if AEnabled and (FDbgFacts = nil) then
    FDbgFacts := TDbgFacts.Create();
end;

function TCodeGenNative.GetDebugFacts: TDbgFacts;
begin
  Result := FDbgFacts;
end;

procedure TCodeGenNative.Generate(AProg: TProgram);
begin
  Self.EnsureBackend();
  FBackend.SetSymbolTable(FSymTable);
  FBackend.SetDebugMode(FDebugMode);
  FBackend.SetDebugFacts(FDbgFacts);
  FBackend.GenerateProgram(AProg);
end;

procedure TCodeGenNative.GenerateUnit(AUnit: TUnit);
begin
  Self.EnsureBackend();
  FBackend.SetSymbolTable(FSymTable);
  FBackend.SetDebugMode(FDebugMode);
  FBackend.SetDebugFacts(FDbgFacts);
  FBackend.GenerateUnit(AUnit);
end;

procedure TCodeGenNative.AppendUnit(AUnit: TUnit);
begin
  Self.EnsureBackend();
  FBackend.SetSymbolTable(FSymTable);
  FBackend.SetDebugMode(FDebugMode);
  FBackend.SetSeparateCompile(FSeparateCompile);
  FBackend.SetDebugFacts(FDbgFacts);
  FBackend.AppendUnit(AUnit);
end;

procedure TCodeGenNative.AppendProgram(AProg: TProgram);
begin
  Self.EnsureBackend();
  FBackend.SetSymbolTable(FSymTable);
  FBackend.SetDebugMode(FDebugMode);
  FBackend.SetDebugFacts(FDbgFacts);
  FBackend.AppendProgram(AProg);
end;

procedure TCodeGenNative.NoteDepInitUnit(const AUnitName: string; AHasInit: Boolean);
begin
  Self.EnsureBackend();
  FBackend.NoteDepInitUnit(AUnitName, AHasInit);
end;

procedure TCodeGenNative.NoteDepFiniUnit(const AUnitName: string; AHasFini: Boolean);
begin
  Self.EnsureBackend();
  FBackend.NoteDepFiniUnit(AUnitName, AHasFini);
end;

function TCodeGenNative.GetOutput: string;
begin
  Result := FBackend.GetOutput();
end;

function TCodeGenNative.GetRequiredLibs: TStringList;
begin
  { The native backend emits float math inline (no libm calls), so it never
    demands a link library — return the always-empty list. }
  Result := FRequiredLibs;
end;

end.
