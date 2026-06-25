{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit blaise.codegen.native.driver;

{ TBackendDriver subclass for the native backend.

  Differences from the QBE driver:

    * The "IR" the native codegen emits IS the target .s assembly text,
      so IRFileExt is '.s' and no lowering tool runs before the link.

    * Linking honours --assembler: external (default) feeds the .s to
      the cc driver; internal assembles in-process via AssembleToObject
      and only shells out for the final link.

    * SupportsIncremental / SupportsWarmCache are True: the native pipeline
      writes a self-contained per-unit .o (its assembly, assembled to an object,
      with the .bif iface embedded) so the --incremental worker pool runs on the
      native backend directly.  Unit objects are compiled in separate-compilation
      mode (FSeparateCompile) — they omit the once-per-program TObject/
      TCustomAttribute system defs (the program object provides the single
      global definition) and carry their own file-local string literals.

  Architecture follows Andrew Haines' unify_backend_interface proposal.

  Pull this unit into Blaise.pas's uses clause; the initialization block
  registers the singleton driver. }

interface

uses
  Classes,
  blaise.codegen,
  blaise.codegen.native,
  blaise.codegen.driver;

type
  TNativeBackendDriver = class(TBackendDriver)
  public
    function Kind: TBackendKind; override;
    function Name: string; override;
    function IRFileExt: string; override;
    function CreateCodeGen(AOpts: TBackendOpts): ICodeGen; override;
    function CreateUnitCodeGen(AOpts: TBackendOpts): ICodeGen; override;
    function LinkProgram(const AIRFile, AOutputFile: string;
      AOpts: TBackendOpts; AExtraObjects: TStringList): string; override;
    function LowerToObject(const AIRFile, AObjFile: string;
      AOpts: TBackendOpts): string; override;

    { Per-unit parallel compilation + warm cache: native emits a self-contained
      object per unit (.s assembled to .o, plus an embedded .bif), the same as
      QBE.  Enabling these routes the --incremental worker pool through the
      native backend instead of falling back to QBE. }
    function SupportsIncremental: Boolean; override;
    function SupportsWarmCache: Boolean; override;

    { --- Option contract: owns --assembler/--linker internal|external --- }
    function AcceptOption(const AFlag, ANextArg: string;
      AOpts: TBackendOpts): TOptionAccept; override;
    procedure DescribeOptions(ALines: TStringList); override;
    function ValidateOptions(AOpts: TBackendOpts): string; override;

  private
    function LinkViaInternalLinker(const AObjFile, AOutputFile: string;
      AOpts: TBackendOpts; AExtraObjects: TStringList): string;
    { Compile the implicit RTL units to a per-compiler object cache and return
      their .o paths in AObjPaths (link order).  Each unit is (re)compiled only
      when its cached .o is missing or older than the source.  Replaces the
      pre-built blaise_rtl.a: the RTL is now built from source by the compiler
      itself (docs/rtl-unification-plan.adoc).  '' on success, else an error. }
    function EnsureRTLObjects(AOpts: TBackendOpts;
      AObjPaths: TStringList): string;
  end;

implementation

uses
  SysUtils, Classes,
  uToolchain,
  blaise.codegen.toolkit,
  blaise.assembler.x86_64,
  blaise.elfreader,
  blaise.linker.elf;

function TNativeBackendDriver.Kind: TBackendKind;
begin
  Result := bkNative;
end;

function TNativeBackendDriver.Name: string;
begin
  Result := 'native';
end;

function TNativeBackendDriver.IRFileExt: string;
begin
  Result := '.s';
end;

function TNativeBackendDriver.CreateCodeGen(AOpts: TBackendOpts): ICodeGen;
var
  CG: TCodeGenNative;
begin
  CG := TCodeGenNative.Create();
  CG.SetTarget(AOpts.Target);
  CG.SetDebugMode(AOpts.DebugMode);
  CG.SetOpdfMode(AOpts.OPDFEnabled);
  Result := CG;
end;

function TNativeBackendDriver.CreateUnitCodeGen(AOpts: TBackendOpts): ICodeGen;
var
  CG: TCodeGenNative;
begin
  { Same as CreateCodeGen; the native backend already emits unit globals,
    methods, vtables and typeinfo with global (.globl) visibility, so sibling
    units in the link resolve this unit's symbols without an extra export knob. }
  CG := TCodeGenNative.Create();
  CG.SetTarget(AOpts.Target);
  CG.SetDebugMode(AOpts.DebugMode);
  CG.SetOpdfMode(AOpts.OPDFEnabled);
  CG.SetSeparateCompile(True);   { suppress per-unit system defs (link collision) }
  Result := CG;
end;

function TNativeBackendDriver.SupportsIncremental: Boolean;
begin
  Result := True;
end;

function TNativeBackendDriver.SupportsWarmCache: Boolean;
begin
  Result := True;
end;

function TNativeBackendDriver.LowerToObject(const AIRFile, AObjFile: string;
  AOpts: TBackendOpts): string;
var
  Args:     TStringList;
  AsmText:  TStringList;
  Msg:      string;
  ExitCode: Integer;
begin
  Result := '';
  { For the native backend the "IR file" already IS the x86-64 assembly the
    unit codegen emitted — there is no qbe step.  Assemble it to a relocatable
    object: in-process when --assembler internal, else via the toolchain's
    `cc -c`. }
  if AOpts.UseInternalAsm then
  begin
    AsmText := TStringList.Create();
    try
      try
        AsmText.LoadFromFile(AIRFile);
        AssembleToObject(AsmText.Text, AObjFile);
      except
        on E: EAssembler do
          Exit('Internal assembler error: ' + Exception(E).Message);
        on E: Exception do
          Exit('Internal assembler error [' + Exception(E).ClassName + ']: ' +
            Exception(E).Message);
      end;
    finally
      AsmText.Free();
    end;
    Exit;
  end;
  Args := TStringList.Create();
  try
    Args.Add('-c');
    { Force assembler language: the worker writes the IR to a name like
      '<unit>.o.s.tmp', whose extension cc would not recognise as assembly. }
    Args.Add('-x');
    Args.Add('assembler');
    Args.Add('-o');
    Args.Add(AObjFile);
    Args.Add(AIRFile);
    ExitCode := RunProcess(ResolveLinker(AOpts.Target).Path, Args, Msg);
  finally
    Args.Free();
  end;
  if ExitCode <> 0 then
    Result := 'cc -c error (exit ' + IntToStr(ExitCode) + '): ' + Msg;
end;

{ The implicit RTL units, in archive/link order.  The compiler emits calls to
  their symbols (_SetArgs, _BlaiseGetMem, _start, ARC helpers, …) in every
  program, so every program links them.  Names are the dotted-flat unit names;
  the source files are <name>.pas in the RTL source directory. }
const
  RTL_UNITS: array[0..13] of string = (
    'runtime.start', 'runtime.atomic', 'runtime.setjmp', 'runtime.utf8',
    'runtime.mem', 'runtime.str', 'runtime.set', 'runtime.arc',
    'runtime.weak', 'runtime.float', 'runtime.thread', 'runtime.exc',
    'rtl.platform.layout.linux', 'rtl.platform.posix');

function TNativeBackendDriver.EnsureRTLObjects(AOpts: TBackendOpts;
  AObjPaths: TStringList): string;
var
  SrcDir, CacheDir, BlaiseBin: string;
  SrcFile, ObjFile: string;
  I, ExitCode: Integer;
  Args: TStringList;
  Msg: string;
begin
  Result := '';
  { RTL source lives in the compiler's own source tree.  Resolution order:
      1. --rtl-src DIR (AOpts.RTLSrcDir) — explicit, for a relocated binary;
      2. $BLAISE_RTL_SRC;
      3. binary/CWD-relative default (RTLSourceDir). }
  if AOpts.RTLSrcDir <> '' then
    SrcDir := ExpandFileName(AOpts.RTLSrcDir)
  else
  begin
    SrcDir := GetEnvironmentVariable('BLAISE_RTL_SRC');
    if SrcDir = '' then
      SrcDir := ExpandFileName(RTLSourceDir());
  end;
  if not DirectoryExists(SrcDir) then
    Exit('internal linker: RTL source directory not found (' + SrcDir +
      '); pass --rtl-src DIR or set $BLAISE_RTL_SRC to compiler/src/main/pascal');

  { Object cache lives beside the compiler binary so repeated program builds
    reuse it (compiler/target/rtl/). }
  CacheDir := IncludeTrailingPathDelimiter(CompilerBinDir()) + 'rtl';
  ForceDirectories(CacheDir);
  BlaiseBin := ParamStr(0);

  for I := 0 to High(RTL_UNITS) do
  begin
    SrcFile := IncludeTrailingPathDelimiter(SrcDir) + RTL_UNITS[I] + '.pas';
    ObjFile := IncludeTrailingPathDelimiter(CacheDir) + RTL_UNITS[I] + '.o';
    if not FileExists(SrcFile) then
      Exit('internal linker: RTL unit source missing: ' + SrcFile);

    { Recompile only when the cached object is missing or stale. }
    if (not FileExists(ObjFile)) or (FileAge(ObjFile) < FileAge(SrcFile)) then
    begin
      Args := TStringList.Create();
      try
        Args.Add('--no-incremental');
        Args.Add('--assembler');   Args.Add('internal');
        Args.Add('--source');      Args.Add(SrcFile);
        Args.Add('--unit-path');   Args.Add(SrcDir);
        Args.Add('--output');      Args.Add(ObjFile);
        ExitCode := RunProcess(BlaiseBin, Args, Msg);
      finally
        Args.Free();
      end;
      if ExitCode <> 0 then
        Exit('internal linker: failed to build RTL unit ' + RTL_UNITS[I] +
          ' (exit ' + IntToStr(ExitCode) + '): ' + Msg);
    end;
    AObjPaths.Add(ObjFile);
  end;
end;

function TNativeBackendDriver.LinkViaInternalLinker(
  const AObjFile, AOutputFile: string;
  AOpts: TBackendOpts; AExtraObjects: TStringList): string;
var
  Lk: TLinker;
  Obj: TElfObjectFile;
  Toolkit: TTargetToolkit;
  LinkTarget: TLinkTarget;
  RTLObjs: TStringList;
  I: Integer;
begin
  Result := '';

  { Build the linker with the resolved target's TLinkTarget so the emitted ELF
    carries the right EI_OSABI / machine / load base for AOpts.Target — without
    this the internal linker always produced a Linux-shaped ELF regardless of
    --target.  The toolkit is the single source of per-target link facts
    (docs/native-target-architecture.adoc). }
  Toolkit := ResolveToolkit(AOpts.Target);
  if Toolkit = nil then
    Exit('internal linker: no toolkit registered for target ' +
      TargetName(AOpts.Target));

  { Build the implicit RTL objects from source (cached beside the compiler).
    Every Blaise program emits calls to RTL symbols (_SetArgs, _BlaiseGetMem,
    _start, ARC/string/exception helpers, …) as undefined externals; these
    objects supply them.  Replaces the pre-built blaise_rtl.a — the RTL is now
    compiled by the compiler itself. }
  RTLObjs := TStringList.Create();
  try
    Result := Self.EnsureRTLObjects(AOpts, RTLObjs);
    if Result <> '' then Exit;

    { TLinker.Create(ATarget) borrows the target — we own and free it here. }
    LinkTarget := Toolkit.MakeLinkTarget();
    Lk := TLinker.Create(LinkTarget);
    try
      try
        Lk.SetDynamic(True);

        Obj := ReadElfObjectFile(AObjFile);
        Lk.AddOwnedObject(Obj);

        if AExtraObjects <> nil then
          for I := 0 to AExtraObjects.Count - 1 do
          begin
            Obj := ReadElfObjectFile(AExtraObjects.Strings[I]);
            Lk.AddOwnedObject(Obj);
          end;

        { The RTL objects — including _start (runtime.start) and the implicit
          runtime symbols — built from source above. }
        for I := 0 to RTLObjs.Count - 1 do
        begin
          Obj := ReadElfObjectFile(RTLObjs.Strings[I]);
          Lk.AddOwnedObject(Obj);
        end;

        Lk.Link('_start', AOutputFile);
      except
        on E: Exception do
          Result := 'internal linker error [' + Exception(E).ClassName + ']: ' +
            Exception(E).Message;
      end;
    finally
      Lk.Free();
      LinkTarget.Free();
    end;
  finally
    RTLObjs.Free();
  end;
end;

function TNativeBackendDriver.LinkProgram(const AIRFile, AOutputFile: string;
  AOpts: TBackendOpts; AExtraObjects: TStringList): string;
var
  ObjFile: string;
  AsmText: TStringList;
begin
  if AOpts.UseInternalAsm then
  begin
    { --assembler internal: assemble the .s text in-process, then drive
      only the final link.  The IR file IS the assembly the top-program
      codegen emitted. }
    ObjFile := ChangeFileExt(AOutputFile, '.o');
    AsmText := TStringList.Create();
    try
      try
        AsmText.LoadFromFile(AIRFile);
        AssembleToObject(AsmText.Text, ObjFile);
      except
        on E: EAssembler do
          Exit('Internal assembler error: ' + Exception(E).Message);
        on E: Exception do
          Exit('Internal assembler error [' + Exception(E).ClassName + ']: ' +
            Exception(E).Message);
      end;
    finally
      AsmText.Free();
    end;
    if AOpts.UseInternalLinker then
      Result := Self.LinkViaInternalLinker(ObjFile, AOutputFile, AOpts,
        AExtraObjects)
    else
      Result := Self.LinkViaToolchain(ObjFile, AOutputFile, AOpts, AExtraObjects);
    if Result = '' then
      DeleteFile(ObjFile);
  end
  else if AOpts.UseInternalLinker then
  begin
    { External assembler + internal linker: assemble to .o via cc -c,
      then link with the internal linker. }
    ObjFile := ChangeFileExt(AOutputFile, '.o');
    Result := Self.LowerToObject(AIRFile, ObjFile, AOpts);
    if Result <> '' then Exit;
    Result := Self.LinkViaInternalLinker(ObjFile, AOutputFile, AOpts,
      AExtraObjects);
    if Result = '' then
      DeleteFile(ObjFile);
  end
  else
    { External assembler + external linker: the cc driver assembles and
      links the .s in one invocation.  The IR file is owned by the
      caller — no cleanup here. }
    Result := Self.LinkViaToolchain(AIRFile, AOutputFile, AOpts, AExtraObjects);
end;

function TNativeBackendDriver.AcceptOption(const AFlag, ANextArg: string;
  AOpts: TBackendOpts): TOptionAccept;
begin
  if AFlag = '--assembler' then
  begin
    AOpts.UseInternalAsm := (ANextArg = 'internal');
    AOpts.AssemblerExplicit := True;
    AOpts.AssemblerChoiceBad :=
      (ANextArg <> 'internal') and (ANextArg <> 'external');
    Result := oaConsumedValue;
  end
  else if AFlag = '--linker' then
  begin
    AOpts.UseInternalLinker := (ANextArg = 'internal');
    AOpts.LinkerExplicit := True;
    AOpts.LinkerChoiceBad :=
      (ANextArg <> 'internal') and (ANextArg <> 'external');
    Result := oaConsumedValue;
  end
  else
    Result := oaUnknown;
end;

procedure TNativeBackendDriver.DescribeOptions(ALines: TStringList);
begin
  ALines.Add(FormatFlagLine('--assembler <id>',
    'internal | external (default: internal)'));
  ALines.Add(FormatFlagLine('--linker <id>',
    'internal | external (default: internal)'));
end;

function TNativeBackendDriver.ValidateOptions(AOpts: TBackendOpts): string;
begin
  Result := '';
  if AOpts.AssemblerChoiceBad then
    Result := '--assembler must be ''internal'' or ''external'''
  else if AOpts.LinkerChoiceBad then
    Result := '--linker must be ''internal'' or ''external''';

  if not AOpts.AssemblerExplicit then
    AOpts.UseInternalAsm := True;
  if not AOpts.LinkerExplicit then
    AOpts.UseInternalLinker := True;
end;

initialization
  RegisterDriver(TNativeBackendDriver.Create());

end.
