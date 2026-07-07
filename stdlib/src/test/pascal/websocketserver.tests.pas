{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Tests for Net.WebSocket.Server: a fiber-per-connection WebSocket server over
  loopback, driven by a raw Net.Tcp client that speaks the handshake bytes and
  masked frames itself.  All inside the single-worker scheduler in the test
  runner process.

    * TestEchoRoundTrip     — handshake, client sends a masked text frame, the
      server echoes it back, client decodes and asserts round-trip.
    * TestPingPong          — client sends a PING, server answers PONG.
    * TestCloseHandshake    — client sends CLOSE, server echoes CLOSE.
    * TestPartialFrame      — client dribbles a frame in two TCP writes so the
      server must reassemble it across recvs before echoing.

  NATIVE BACKEND ONLY.  Self-registers via the initialization section. }

unit WebSocketServer.Tests;

interface

uses
  blaise.testing, SysUtils, Net.Tcp, Net.WebSockets, Net.WebSocket.Server,
  async.fibers, Security.Crypto, Encoding.Base64;

type
  TWebSocketServerTests = class(TTestCase)
  published
    procedure TestEchoRoundTrip;
    procedure TestPingPong;
    procedure TestCloseHandshake;
    procedure TestPartialFrame;
  end;

  { Echo handler: send every received message straight back. }
  TEchoWsHandler = class(IWebSocketHandler)
    procedure OnMessage(AConn: TWebSocketConn; const AData: string; AIsBinary: Boolean);
  end;

implementation

procedure TEchoWsHandler.OnMessage(AConn: TWebSocketConn; const AData: string; AIsBinary: Boolean);
begin
  if AIsBinary then
    AConn.SendBinary(AData)
  else
    AConn.SendText(AData);
end;

{ --- shared fixture (single-worker scheduler is serial across fibers) --- }

var
  GServer: TWebSocketServer;
  GHandler: IWebSocketHandler;
  GPort: UInt16;
  GResult: string;
  GDone: Boolean;

procedure ServerFiber(AArg: Pointer);
begin
  GServer.Serve(GHandler);
end;

{ Build the client HTTP upgrade request head with a fixed key. }
function ClientUpgrade(const AKey: string): string;
begin
  Result := 'GET / HTTP/1.1'#13#10 +
            'Host: 127.0.0.1'#13#10 +
            'Upgrade: websocket'#13#10 +
            'Connection: Upgrade'#13#10 +
            'Sec-WebSocket-Key: ' + AKey + #13#10 +
            'Sec-WebSocket-Version: 13'#13#10#13#10;
end;

{ Read one complete WS frame from a raw TCP conn (buffering partial reads). }
function ReadOneFrame(AConn: TTcpConn): TWsFrame;
var
  Buf, Chunk: string;
  F: TWsFrame;
begin
  Buf := '';
  while True do
  begin
    F := DecodeFrame(Buf);
    if F.Valid then
      Exit(F);
    Chunk := AConn.Read(4096);
    if Chunk = '' then
    begin
      F.Valid := False;
      Exit(F);
    end;
    Buf := Buf + Chunk;
  end;
end;

{ Read and discard the 101 response head (up to CRLFCRLF). }
procedure ReadHandshakeResponse(AConn: TTcpConn);
var
  Acc, Chunk: string;
begin
  Acc := '';
  while Pos(#13#10#13#10, Acc) < 0 do
  begin
    Chunk := AConn.Read(4096);
    if Chunk = '' then
      Break;
    Acc := Acc + Chunk;
  end;
end;

{ --- TestEchoRoundTrip --- }

procedure EchoClientFiber(AArg: Pointer);
var
  Cli: TTcpClient;
  Conn: TTcpConn;
  F: TWsFrame;
begin
  FiberSleep(2);
  Cli := TTcpClient.Create();
  Conn := Cli.Connect('127.0.0.1', GPort);
  Cli.Free();
  if Conn = nil then
  begin
    GResult := 'connfail';
    GDone := True;
    GServer.Stop();
    Exit;
  end;
  Conn.Write(ClientUpgrade('dGhlIHNhbXBsZSBub25jZQ=='));
  ReadHandshakeResponse(Conn);
  { client frames must be masked }
  Conn.Write(EncodeMaskedTextFrame('hello ws'));
  F := ReadOneFrame(Conn);
  if F.Valid then
    GResult := F.Payload
  else
    GResult := 'noframe';
  Conn.Free();
  GDone := True;
  GServer.Stop();
end;

procedure TWebSocketServerTests.TestEchoRoundTrip;
const
  PORT = 29501;
begin
  GServer := TWebSocketServer.Create(PORT);
  AssertTrue('server start', GServer.Start());
  GHandler := TEchoWsHandler.Create();
  GPort := PORT;
  GResult := '';
  GDone := False;

  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@EchoClientFiber, nil);
  RunScheduler();

  AssertEquals('server echoed the text message', 'hello ws', GResult);
  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

{ --- TestPingPong: client PING -> server PONG (same payload) --- }

procedure PingClientFiber(AArg: Pointer);
var
  Cli: TTcpClient;
  Conn: TTcpConn;
  F: TWsFrame;
begin
  FiberSleep(2);
  Cli := TTcpClient.Create();
  Conn := Cli.Connect('127.0.0.1', GPort);
  Cli.Free();
  if Conn = nil then
  begin
    GResult := 'connfail';
    GDone := True;
    GServer.Stop();
    Exit;
  end;
  Conn.Write(ClientUpgrade('dGhlIHNhbXBsZSBub25jZQ=='));
  ReadHandshakeResponse(Conn);
  Conn.Write(EncodeMaskedFrame(WS_OP_PING, 'beat'));
  F := ReadOneFrame(Conn);
  if F.Valid and (F.Opcode = WS_OP_PONG) then
    GResult := 'pong:' + F.Payload
  else
    GResult := 'nopong';
  Conn.Free();
  GDone := True;
  GServer.Stop();
end;

procedure TWebSocketServerTests.TestPingPong;
const
  PORT = 29502;
begin
  GServer := TWebSocketServer.Create(PORT);
  AssertTrue('server start', GServer.Start());
  GHandler := TEchoWsHandler.Create();
  GPort := PORT;
  GResult := '';
  GDone := False;

  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@PingClientFiber, nil);
  RunScheduler();

  AssertEquals('server answered ping with matching pong', 'pong:beat', GResult);
  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

{ --- TestCloseHandshake: client CLOSE -> server echoes CLOSE --- }

procedure CloseClientFiber(AArg: Pointer);
var
  Cli: TTcpClient;
  Conn: TTcpConn;
  F: TWsFrame;
begin
  FiberSleep(2);
  Cli := TTcpClient.Create();
  Conn := Cli.Connect('127.0.0.1', GPort);
  Cli.Free();
  if Conn = nil then
  begin
    GResult := 'connfail';
    GDone := True;
    GServer.Stop();
    Exit;
  end;
  Conn.Write(ClientUpgrade('dGhlIHNhbXBsZSBub25jZQ=='));
  ReadHandshakeResponse(Conn);
  Conn.Write(EncodeMaskedFrame(WS_OP_CLOSE, ''));
  F := ReadOneFrame(Conn);
  if F.Valid and (F.Opcode = WS_OP_CLOSE) then
    GResult := 'closed'
  else
    GResult := 'noclose';
  Conn.Free();
  GDone := True;
  GServer.Stop();
end;

procedure TWebSocketServerTests.TestCloseHandshake;
const
  PORT = 29503;
begin
  GServer := TWebSocketServer.Create(PORT);
  AssertTrue('server start', GServer.Start());
  GHandler := TEchoWsHandler.Create();
  GPort := PORT;
  GResult := '';
  GDone := False;

  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@CloseClientFiber, nil);
  RunScheduler();

  AssertEquals('server echoed the close frame', 'closed', GResult);
  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

{ --- TestPartialFrame: dribble a frame in two writes so the server must
      reassemble it across recvs --- }

procedure PartialClientFiber(AArg: Pointer);
var
  Cli: TTcpClient;
  Conn: TTcpConn;
  Frame, Part1, Part2: string;
  F: TWsFrame;
begin
  FiberSleep(2);
  Cli := TTcpClient.Create();
  Conn := Cli.Connect('127.0.0.1', GPort);
  Cli.Free();
  if Conn = nil then
  begin
    GResult := 'connfail';
    GDone := True;
    GServer.Stop();
    Exit;
  end;
  Conn.Write(ClientUpgrade('dGhlIHNhbXBsZSBub25jZQ=='));
  ReadHandshakeResponse(Conn);

  { Build one masked frame, then send it in two TCP writes with a scheduler
    yield in between, forcing the server's message loop to buffer a partial
    frame and read again before it can decode. }
  Frame := EncodeMaskedTextFrame('split across recvs');
  Part1 := Copy(Frame, 0, 4);
  Part2 := Copy(Frame, 4, Length(Frame) - 4);
  Conn.Write(Part1);
  FiberSleep(5);                   { give the server a chance to recv Part1 }
  Conn.Write(Part2);

  F := ReadOneFrame(Conn);
  if F.Valid then
    GResult := F.Payload
  else
    GResult := 'noframe';
  Conn.Free();
  GDone := True;
  GServer.Stop();
end;

procedure TWebSocketServerTests.TestPartialFrame;
const
  PORT = 29504;
begin
  GServer := TWebSocketServer.Create(PORT);
  AssertTrue('server start', GServer.Start());
  GHandler := TEchoWsHandler.Create();
  GPort := PORT;
  GResult := '';
  GDone := False;

  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@PartialClientFiber, nil);
  RunScheduler();

  AssertEquals('server reassembled the split frame and echoed it',
    'split across recvs', GResult);
  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

initialization
  RegisterTest(TWebSocketServerTests);

end.
