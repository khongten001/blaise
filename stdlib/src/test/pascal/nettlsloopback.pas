{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Standalone loopback proof for L5 Net.Tls (TTlsClient <-> TTlsServer).

  A TTlsServer (self-signed cert) serves an echo handler over TLS; a TTlsClient
  connects, handshakes (SNI = localhost, verify OFF for the self-signed cert),
  and round-trips a message.  Prints a fixed transcript:

    ECHO:hello-net-tls
    OK

  On failure prints FAIL:<reason> and exits non-zero.  Also exercises the
  ETlsError degradation path when GTlsProvider is nil.

  MUST be built with `--backend native --linker external`.
  Args: <cert> <key>. }

program NetTlsLoopback;

uses
  SysUtils, async.fibers, Net.Tls, Net.Tls.Provider;

var
  GServer: TTlsServer;
  GCert: string;
  GKey: string;
  GEcho: string;
  GDegradeOk: Boolean;

type
  TEchoHandler = class(ITlsConnHandler)
    procedure Handle(AStream: TTlsStream);
  end;

procedure TEchoHandler.Handle(AStream: TTlsStream);
var
  Msg: string;
begin
  Msg := AStream.Read(256);
  AStream.Write('echo:' + Msg);
end;

var
  GHandler: ITlsConnHandler;

procedure ServerFiber(AArg: Pointer);
begin
  GServer.Serve(GHandler);
end;

procedure ClientFiber(AArg: Pointer);
var
  Cli: TTlsClient;
  Stream: TTlsStream;
begin
  FiberSleep(3);
  Cli := TTlsClient.Create();
  Stream := Cli.Connect('127.0.0.1', GServer.Port, 'localhost', False);
  Cli.Free();
  if Stream = nil then
  begin
    GEcho := '<connect-failed>';
    GServer.Stop();
    Exit;
  end;
  Stream.Write('hello-net-tls');
  GEcho := Stream.Read(256);
  Stream.Close();
  Stream.Free();
  GServer.Stop();
end;

{ Degradation: with no provider installed, TTlsClient.Connect must raise
  ETlsError (a clear runtime error, not a link failure). }
procedure CheckDegradation;
var
  SavedProvider: TTlsProvider;
  Cli: TTlsClient;
begin
  SavedProvider := GTlsProvider;
  GTlsProvider := nil;
  GDegradeOk := False;
  Cli := TTlsClient.Create();
  try
    try
      Cli.Connect('127.0.0.1', 1, 'localhost', False);
    except
      on E: ETlsError do
        GDegradeOk := True;
    end;
  finally
    Cli.Free();
    GTlsProvider := SavedProvider;
  end;
end;

begin
  if ParamCount() < 2 then
  begin
    WriteLn('FAIL:usage <cert> <key>');
    Halt(2);
  end;
  GCert := ParamStr(1);
  GKey := ParamStr(2);
  GEcho := '';

  InstallOpenSSLProvider();
  if GTlsProvider = nil then
  begin
    WriteLn('FAIL:no-provider');
    Halt(1);
  end;

  CheckDegradation();
  if not GDegradeOk then
  begin
    WriteLn('FAIL:degradation-no-error');
    Halt(1);
  end;

  GServer := TTlsServer.Create(29521, GCert, GKey);
  if not GServer.Start() then
  begin
    WriteLn('FAIL:server-start');
    Halt(1);
  end;
  GHandler := TEchoHandler.Create();

  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@ClientFiber, nil);
  RunScheduler();

  WriteLn('ECHO:' + GEcho);
  if GEcho = 'echo:hello-net-tls' then
    WriteLn('OK')
  else
  begin
    WriteLn('FAIL:roundtrip');
    Halt(1);
  end;
end.
