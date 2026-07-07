{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Tests for L5 Net.Ftp (FTP client, RFC 959).  A MOCK FTP server runs as a fiber
  on Net.Tcp inside the test-runner process.  It speaks the two-connection FTP
  protocol:

    220 greeting, 331/230 for USER/PASS, 200 to TYPE I, and PASSIVE transfers:
    on PASV it opens a data listener on a fixed ephemeral port, replies 227 with
    that ip,port tuple, then for RETR serves a known file body over the data
    connection (150 start / 226 complete on control), for STOR accepts an upload
    to EOF, and for NLST serves a fixed listing.

  The client-driving fiber asserts login, a RETR round-trips the exact bytes, a
  STOR delivers the exact bytes to the mock, and NLST returns the entries.
  Plaintext (internal linker).  NATIVE BACKEND ONLY.

  Self-registers via the initialization section. }

unit Ftp.Tests;

interface

uses
  blaise.testing, SysUtils, Net.Tcp, Net.Ftp, Net.Mail.Reply,
  async.fibers, async.io, Net.Sockets;

type
  TFtpClientTests = class(TTestCase)
  published
    procedure TestLoginRetrStorList;
  end;

implementation

const
  CTRL_PORT = 29631;
  DATA_PORT = 29632;
  { The file the mock serves for RETR (includes CRLF + a NUL to prove the
    transfer is byte-exact and binary-clean). }
  RETR_BODY = 'line one' + #13#10 + 'binary' + #0 + 'byte' + #13#10 + 'end';

var
  GServer: TTcpServer;
  GHandler: IConnHandler;
  { results captured by the client fiber }
  GLoginOk: Boolean;
  GBinaryOk: Boolean;
  GRetr: string;
  GRetrOk: Boolean;
  GStorOk: Boolean;
  GList: string;
  GListOk: Boolean;
  GQuitOk: Boolean;
  { what the mock received via STOR }
  GStored: string;

type
  TMockFtpHandler = class(IConnHandler)
    procedure Handle(AConn: TTcpConn);
  end;

{ On PASV: open a data listener on DATA_PORT, reply 227 with its ip,port, accept
  the client's data connection and return it (caller owns / closes it).  Returns
  nil on failure. }
function OpenDataConn(AConn: TTcpConn): TTcpConn;
var
  ListenFd, DataFd: Integer;
begin
  Result := nil;
  ListenFd := TcpListenLocal(DATA_PORT, 8);
  if ListenFd < 0 then
    Exit;
  SetNonBlocking(ListenFd);
  { 227 Entering Passive Mode (127,0,0,1,p1,p2) }
  AConn.Write('227 Entering Passive Mode (127,0,0,1,'
    + IntToStr(DATA_PORT div 256) + ',' + IntToStr(DATA_PORT mod 256) + ').' + CRLF);
  DataFd := FiberAccept(ListenFd);
  CloseSocket(ListenFd);
  if DataFd < 0 then
    Exit;
  Result := TTcpConn.Create(DataFd);
end;

procedure TMockFtpHandler.Handle(AConn: TTcpConn);
var
  Line, U: string;
  Data: TTcpConn;
  Chunk: string;
begin
  AConn.Write('220 mock FTP ready' + CRLF);
  { the data connection opened by the most recent PASV, pending a transfer }
  Data := nil;
  while AConn.ReadLine(Line) do
  begin
    U := UpperCase(Line);
    if Copy(U, 0, 4) = 'USER' then
      AConn.Write('331 need password' + CRLF)
    else if Copy(U, 0, 4) = 'PASS' then
      AConn.Write('230 logged in' + CRLF)
    else if Copy(U, 0, 4) = 'TYPE' then
      AConn.Write('200 type set' + CRLF)
    else if U = 'PASV' then
      { the 227 reply and data-conn accept happen inside OpenDataConn }
      Data := OpenDataConn(AConn)
    else if Copy(U, 0, 4) = 'RETR' then
    begin
      if Data = nil then
        AConn.Write('425 no data connection' + CRLF)
      else
      begin
        AConn.Write('150 opening data connection' + CRLF);
        Data.Write(RETR_BODY);
        Data.Close();
        Data.Free();
        Data := nil;
        AConn.Write('226 transfer complete' + CRLF);
      end;
    end
    else if Copy(U, 0, 4) = 'STOR' then
    begin
      if Data = nil then
        AConn.Write('425 no data connection' + CRLF)
      else
      begin
        AConn.Write('150 opening data connection' + CRLF);
        GStored := '';
        while True do
        begin
          Chunk := Data.Read(4096);
          if Chunk = '' then
            Break;
          GStored := GStored + Chunk;
        end;
        Data.Close();
        Data.Free();
        Data := nil;
        AConn.Write('226 transfer complete' + CRLF);
      end;
    end
    else if Copy(U, 0, 4) = 'NLST' then
    begin
      if Data = nil then
        AConn.Write('425 no data connection' + CRLF)
      else
      begin
        AConn.Write('150 here comes the listing' + CRLF);
        Data.Write('hello.bin' + CRLF + 'upload.bin' + CRLF);
        Data.Close();
        Data.Free();
        Data := nil;
        AConn.Write('226 listing complete' + CRLF);
      end;
    end
    else if U = 'QUIT' then
    begin
      AConn.Write('221 bye' + CRLF);
      Break;
    end
    else
      AConn.Write('500 unknown' + CRLF);
  end;
  if Data <> nil then
  begin
    Data.Close();
    Data.Free();
  end;
end;

procedure ServerFiber(AArg: Pointer);
begin
  GServer.Serve(GHandler);
end;

procedure ClientFiber(AArg: Pointer);
var
  Cli: TFtpClient;
begin
  FiberSleep(2);
  Cli := TFtpClient.Create();
  if Cli.Connect('127.0.0.1', CTRL_PORT) then
  begin
    GLoginOk := Cli.Login('alice', 'secret');
    GBinaryOk := Cli.BinaryMode();
    GRetrOk := Cli.Retrieve('hello.bin', GRetr);
    GStorOk := Cli.Store('upload.bin', RETR_BODY);
    GListOk := Cli.List('', GList);
    GQuitOk := Cli.Quit();
  end;
  Cli.Free();
  GServer.Stop();
end;

procedure TFtpClientTests.TestLoginRetrStorList;
begin
  GServer := TTcpServer.Create(CTRL_PORT);
  AssertTrue('server start', GServer.Start());
  GHandler := TMockFtpHandler.Create();
  GLoginOk := False;
  GBinaryOk := False;
  GRetr := '';
  GRetrOk := False;
  GStorOk := False;
  GList := '';
  GListOk := False;
  GQuitOk := False;
  GStored := '';

  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@ClientFiber, nil);
  RunScheduler();

  AssertTrue('login', GLoginOk);
  AssertTrue('binary mode', GBinaryOk);
  AssertTrue('RETR ok', GRetrOk);
  AssertEquals('RETR byte-exact', RETR_BODY, GRetr);
  AssertTrue('STOR ok', GStorOk);
  AssertEquals('STOR byte-exact at server', RETR_BODY, GStored);
  AssertTrue('LIST ok', GListOk);
  AssertTrue('LIST has entry', Pos('hello.bin', GList) >= 0);
  AssertTrue('QUIT', GQuitOk);

  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

initialization
  RegisterTest(TFtpClientTests);

end.
