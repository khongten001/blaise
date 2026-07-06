{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Standalone loopback TLS echo proof for L4 Net.Tls.Provider.

  A TLS server fiber (server-side TTlsConn, self-signed cert) and a TLS client
  fiber (client-side TTlsConn) complete a REAL OpenSSL handshake over a loopback
  TCP connection inside a single-worker fiber scheduler, then exchange an
  encrypted round-trip message.  Prints a fixed transcript so an e2e harness can
  assert on stdout:

    HS-SERVER-OK
    HS-CLIENT-OK
    SERVER-GOT:hello-tls
    CLIENT-GOT:srv:hello-tls
    OK

  On any failure it prints FAIL:<reason> and exits non-zero.

  MUST be built with `--backend native --linker external` (Net.Tls.Provider
  binds libssl/libcrypto).  Cert/key paths are the two command-line arguments. }

program TlsLoopback;

uses
  SysUtils, async.fibers, Net.Tcp, Net.Tls.Provider;

var
  GProvider: TOpenSSLProvider;
  GServer: TTcpServer;
  GPort: UInt16;
  GCertPath: string;
  GKeyPath: string;
  GServerPlain: string;
  GClientPlain: string;
  GServerHsOk: Boolean;
  GClientHsOk: Boolean;

type
  TTlsEchoHandler = class(IConnHandler)
    procedure Handle(AConn: TTcpConn);
  end;

procedure TTlsEchoHandler.Handle(AConn: TTcpConn);
var
  Ctx: TTlsContext;
  Tls: TTlsConn;
  Msg: string;
begin
  Ctx := GProvider.CreateServerContext(GCertPath, GKeyPath);
  if Ctx = nil then
    Exit;
  try
    Tls := Ctx.NewConn(AConn.Fd, '');
    try
      GServerHsOk := Tls.Handshake();
      if GServerHsOk then
      begin
        Msg := Tls.Read(256);
        GServerPlain := Msg;
        Tls.Write('srv:' + Msg);
      end;
      Tls.Close();
    finally
      Tls.Free();
    end;
  finally
    Ctx.Free();
  end;
end;

var
  GHandler: IConnHandler;

procedure ServerFiber(AArg: Pointer);
begin
  GServer.Serve(GHandler);
end;

procedure ClientFiber(AArg: Pointer);
var
  Cli: TTcpClient;
  Conn: TTcpConn;
  Ctx: TTlsContext;
  Tls: TTlsConn;
begin
  FiberSleep(2);
  Cli := TTcpClient.Create();
  Conn := Cli.Connect('127.0.0.1', GPort);
  Cli.Free();
  if Conn = nil then
  begin
    GServer.Stop();
    Exit;
  end;
  Ctx := GProvider.CreateClientContext(False);    { self-signed: verify off }
  try
    Tls := Ctx.NewConn(Conn.Fd, 'localhost');
    try
      GClientHsOk := Tls.Handshake();
      if GClientHsOk then
      begin
        Tls.Write('hello-tls');
        GClientPlain := Tls.Read(256);
      end;
      Tls.Close();
    finally
      Tls.Free();
    end;
  finally
    Ctx.Free();
    Conn.Close();
    Conn.Free();
  end;
  GServer.Stop();
end;

begin
  if ParamCount() < 2 then
  begin
    WriteLn('FAIL:usage <cert> <key>');
    Halt(2);
  end;
  GCertPath := ParamStr(1);
  GKeyPath := ParamStr(2);
  GPort := 29511;
  GServerPlain := '';
  GClientPlain := '';
  GServerHsOk := False;
  GClientHsOk := False;

  GProvider := TOpenSSLProvider.Create();
  GServer := TTcpServer.Create(GPort);
  if not GServer.Start() then
  begin
    WriteLn('FAIL:server-start');
    Halt(1);
  end;
  GHandler := TTlsEchoHandler.Create();

  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@ClientFiber, nil);
  RunScheduler();

  if not GServerHsOk then
  begin
    WriteLn('FAIL:server-handshake');
    Halt(1);
  end;
  WriteLn('HS-SERVER-OK');
  if not GClientHsOk then
  begin
    WriteLn('FAIL:client-handshake');
    Halt(1);
  end;
  WriteLn('HS-CLIENT-OK');
  WriteLn('SERVER-GOT:' + GServerPlain);
  WriteLn('CLIENT-GOT:' + GClientPlain);
  if (GServerPlain = 'hello-tls') and (GClientPlain = 'srv:hello-tls') then
    WriteLn('OK')
  else
  begin
    WriteLn('FAIL:roundtrip');
    Halt(1);
  end;
end.
