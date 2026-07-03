{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.toolchain;

{ Tests for host-aware external-tool resolution (uToolchain.ResolveSpec) and
  the target host/extension helpers it relies on.

  ResolveSpec resolves a tool, per candidate, in this order:
    1. EnvVar override (verbatim)                         — not exercised here
       (no setenv binding in the test RTL; the override branch is a simple
        GetEnvironmentVariable + FileExists guard).
    2. $BLAISE_TOOLCHAIN_PREFIX + candidate               — env-driven, skipped
    3. cross-triple prefix on $PATH (cross builds only)
    4. bare candidate on $PATH — host tools always, target tools native-only
    5. actionable fallback name

  The behaviour these tests pin is the part that is independent of the
  environment: the host-tool-vs-target-tool cross-suppression (step 4), the
  fallback naming (step 5), and the pure host/extension helpers. }

interface

uses
  blaise.testing, sysutils, process,
  blaise.codegen.target, uToolchain;

type
  TToolchainTests = class(TTestCase)
  private
    { Build a linker-like target tool spec (HostTool=False) with a mingw
      cross prefix, the shape TBackendDriver.LinkerToolSpec produces. }
    function MakeLinkerSpec: TToolSpec;
    { Build a host tool spec (HostTool=True, e.g. llc) — runs anywhere. }
    function MakeHostToolSpec: TToolSpec;
    function LinuxTarget: TTargetDesc;
    function WindowsTarget: TTargetDesc;
  published
    { ---- pure helpers ---- }
    procedure TestExecutableExtension_Windows_IsExe;
    procedure TestExecutableExtension_Linux_IsEmpty;
    procedure TestHostTarget_OnThisHost_MatchesUname;
    procedure TestHostExeExt_OnThisHost_IsEmpty;

    { ---- ResolveSpec: native (non-cross) build ---- }
    { A target tool resolves to a real $PATH binary on a native build. }
    procedure TestResolveSpec_NativeLinker_FindsCcOnPath;

    { ---- ResolveSpec: cross build, target tool ---- }
    { Cross + target tool + no cross-linker installed: the bare host fallback
      is SUPPRESSED, so we never resolve to the host cc for a Windows output;
      the actionable cross-prefixed name is returned instead. }
    procedure TestResolveSpec_CrossLinker_DoesNotFallBackToHostCc;
    procedure TestResolveSpec_CrossLinker_FallbackIsCrossPrefixed;

    { ---- ResolveSpec: cross build, host tool ---- }
    { Cross + host tool: a bare $PATH match IS allowed (host tools run on the
      host and target via flags), so a host tool still resolves. }
    procedure TestResolveSpec_CrossHostTool_AllowsBarePathMatch;
  end;

implementation

function TToolchainTests.MakeLinkerSpec: TToolSpec;
begin
  Result.Name := 'linker';
  Result.EnvVar := 'BLAISE_LINKER';
  SetLength(Result.Cands, 2);
  Result.Cands[0] := 'cc';
  Result.Cands[1] := 'clang';
  Result.CrossPrefix := 'x86_64-w64-mingw32-';
  Result.HostTool := False;
end;

function TToolchainTests.MakeHostToolSpec: TToolSpec;
begin
  { 'cc' is guaranteed present on $PATH in the build environment, so it makes
    a reliable stand-in for a host tool (llc) that resolves by bare name. }
  Result.Name := 'hosttool';
  Result.EnvVar := 'BLAISE_HOSTTOOL';
  SetLength(Result.Cands, 1);
  Result.Cands[0] := 'cc';
  Result.CrossPrefix := 'x86_64-w64-mingw32-';
  Result.HostTool := True;
end;

function TToolchainTests.LinuxTarget: TTargetDesc;
begin
  MakeTarget(osLinux, cpuX86_64, Result);
end;

function TToolchainTests.WindowsTarget: TTargetDesc;
begin
  MakeTarget(osWindows, cpuX86_64, Result);
end;

{ ---- pure helpers ---- }

procedure TToolchainTests.TestExecutableExtension_Windows_IsExe;
begin
  AssertEquals('Windows target → .exe', '.exe',
    ExecutableExtension(Self.WindowsTarget()));
end;

procedure TToolchainTests.TestExecutableExtension_Linux_IsEmpty;
begin
  AssertEquals('Linux target → no extension', '',
    ExecutableExtension(Self.LinuxTarget()));
end;

procedure TToolchainTests.TestHostTarget_OnThisHost_MatchesUname;
var
  Proc:  TProcess;
  Chunk: string;
  Uname: string;
  Expected: TTargetOS;
begin
  { HostTarget is a COMPILE-TIME property of the binary (target-driven
    defines).  Verify the baked-in identity matches the OS the suite is
    actually running on, as reported by uname(1) — a genuine round-trip
    check that works unchanged on every POSIX host.  The inline
    HostTarget().OS read as an AssertEquals argument also exercises the
    native sret-call-field-arg path fixed alongside this work. }
  Proc := TProcess.Create(nil);
  Proc.Executable := 'uname';
  Proc.Parameters.Add('-s');
  Proc.Execute();
  Uname := '';
  repeat
    Chunk := Proc.ReadOutput();
    Uname := Uname + Chunk
  until (Chunk = '') and not Proc.Running;
  Proc.WaitOnExit();
  Proc.Free();
  Uname := Trim(Uname);
  if Uname = 'FreeBSD' then
    Expected := osFreeBSD
  else if Uname = 'Darwin' then
    Expected := osMacOS
  else
    Expected := osLinux;
  AssertEquals('host OS matches uname (' + Uname + ')',
    Ord(Expected), Ord(HostTarget().OS));
end;

procedure TToolchainTests.TestHostExeExt_OnThisHost_IsEmpty;
begin
  AssertEquals('no host exe extension on a unix host', '', HostExeExt());
end;

{ ---- ResolveSpec: native build ---- }

procedure TToolchainTests.TestResolveSpec_NativeLinker_FindsCcOnPath;
var
  Resolved: string;
begin
  { Native build: the linker is a target tool, but the target IS the host
    (HostTarget, whatever this suite was built for), so the bare $PATH lookup
    applies and finds a real cc/clang. }
  Resolved := ResolveSpec(Self.MakeLinkerSpec(), HostTarget());
  AssertTrue('resolved to an absolute path on $PATH (found cc/clang)',
    (Length(Resolved) > 0) and (Resolved[0] = '/'));
end;

{ ---- ResolveSpec: cross build, target tool ---- }

procedure TToolchainTests.TestResolveSpec_CrossLinker_DoesNotFallBackToHostCc;
var
  Resolved: string;
begin
  { Cross-compiling to Windows from a linux host.  The mingw cross-linker is
    not installed in the build environment, so resolution must NOT silently
    fall back to the host /usr/bin/cc — that would link Windows output with
    the host linker.  The result must therefore not be an absolute host path. }
  Resolved := ResolveSpec(Self.MakeLinkerSpec(), Self.WindowsTarget());
  AssertTrue('cross target tool did not resolve to a host path',
    not ((Length(Resolved) > 0) and (Resolved[0] = '/')));
end;

procedure TToolchainTests.TestResolveSpec_CrossLinker_FallbackIsCrossPrefixed;
var
  Resolved: string;
begin
  { With no installed cross tool, the fallback (step 5) names the
    cross-prefixed first candidate so the exec-time error is actionable. }
  Resolved := ResolveSpec(Self.MakeLinkerSpec(), Self.WindowsTarget());
  AssertEquals('fallback is the cross-prefixed first candidate',
    'x86_64-w64-mingw32-cc', Resolved);
end;

{ ---- ResolveSpec: cross build, host tool ---- }

procedure TToolchainTests.TestResolveSpec_CrossHostTool_AllowsBarePathMatch;
var
  Resolved: string;
begin
  { A host tool may resolve to a bare $PATH binary even when cross-compiling,
    because it runs on the host and targets via flags.  The stand-in ('cc') is
    on $PATH, so it must resolve to an absolute path despite the Windows
    target. }
  Resolved := ResolveSpec(Self.MakeHostToolSpec(), Self.WindowsTarget());
  AssertTrue('host tool resolves to a $PATH binary even when cross',
    (Length(Resolved) > 0) and (Resolved[0] = '/'));
end;

initialization
  RegisterTest(TToolchainTests);

end.
