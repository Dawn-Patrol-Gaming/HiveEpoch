unit uHiveLog;
{
  Copyright (C) 2009-2012 Rajko Stojadinovic (original C++ implementation)
  Copyright (C) 2026 Nathan Davalos (Delphi port)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

originally tried to replicate hive code for logging, decided to just use my pre-existing log functionality,
never holds a lock on log file, thread-safe, will not cause issues on unload like hive's logger did
}

interface

uses
  Windows, SysUtils, Classes, SyncObjs;

type
  THiveLogLevel = (
    hlNone = 0,
    hlFatal = 1,
    hlCritical = 2,
    hlError = 3,
    hlWarning = 4,
    hlNotice = 5,
    hlInformation = 6,
    hlDebug = 7,
    hlTrace = 8
    );

  THiveLogger = class
  private
    FLock: TCriticalSection;
    FStream: TFileStream;
    FPath: string;
    FLevel: THiveLogLevel;
  public
    constructor Create(const APath: string; ALevel: THiveLogLevel);

    procedure Log(Level: THiveLogLevel; const Source, Msg: string);
    { convenience wrappers - Source is orig hive - the Poco logger name, "HiveExt" or "Database" }
    procedure Trace(const Source, Msg: string);
    procedure Debug(const Source, Msg: string);
    procedure Information(const Source, Msg: string);
    procedure Notice(const Source, Msg: string);
    procedure Warning(const Source, Msg: string);
    procedure Error(const Source, Msg: string);

    function Accepts(Level: THiveLogLevel): Boolean;
    property Level: THiveLogLevel read FLevel write FLevel;
    property Path: string read FPath;
  end;

//orig hive - Poco::Logger::parseLevel names. Unknown text falls back to Default.
function ParseHiveLogLevel(const S: string; Default: THiveLogLevel): THiveLogLevel;
function HiveLogLevelName(Level: THiveLogLevel): string;

implementation

uses common;

const
  LevelNames: array[THiveLogLevel] of string = (
    'None',
    'Fatal',
    'Critical',
    'Error',
    'Warning',
    'Notice',
    'Information',
    'Debug',
    'Trace'
  );

function ParseHiveLogLevel(const S: string; Default: THiveLogLevel): THiveLogLevel;
var
  L: THiveLogLevel;
  T: string;
begin
  T := LowerCase(Trim(S));
  if T = '' then
    Exit(Default);
  for L := Low(THiveLogLevel) to High(THiveLogLevel) do
    if T = LowerCase(LevelNames[L]) then
      Exit(L);
  Result := Default;
end;

function HiveLogLevelName(Level: THiveLogLevel): string;
begin
  Result := LevelNames[Level];
end;

constructor THiveLogger.Create(const APath: string; ALevel: THiveLogLevel);
begin
  inherited Create;
  FPath := APath;
  FLevel := ALevel;
end;

function THiveLogger.Accepts(Level: THiveLogLevel): Boolean;
begin
  Result := (FLevel <> hlNone) and (Ord(Level) <= Ord(FLevel));
end;

procedure THiveLogger.Log(Level: THiveLogLevel; const Source, Msg: string);
var
  Line: AnsiString;
begin
  if not Accepts(Level) then
    Exit;
//  Line := AnsiString(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + Source + ': [' + LevelNames[Level] + '] ' + Msg);
//logit automatically adds a timestamp to each log line, no need to do it like hive did
  Line := AnsiString(Source + ': [' + LevelNames[Level] + '] ' + Msg);
  LogIt(Line, FPath);
end;

procedure THiveLogger.Trace(const Source, Msg: string);
begin
  Log(hlTrace, Source, Msg);
end;

procedure THiveLogger.Debug(const Source, Msg: string);
begin
  Log(hlDebug, Source, Msg);
end;

procedure THiveLogger.Information(const Source, Msg: string);
begin
  Log(hlInformation, Source, Msg);
end;

procedure THiveLogger.Notice(const Source, Msg: string);
begin
  Log(hlNotice, Source, Msg);
end;

procedure THiveLogger.Warning(const Source, Msg: string);
begin
  Log(hlWarning, Source, Msg);
end;

procedure THiveLogger.Error(const Source, Msg: string);
begin
  Log(hlError, Source, Msg);
end;

end.

