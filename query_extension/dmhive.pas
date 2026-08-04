unit dmhive;
{
  Copyright (C) 2009-2012 Rajko Stojadinovic (original C++ implementation)
  Copyright (C) 2026 Nathan Davalos (Delphi port)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  Port of HiveExtApp + DirectHiveApp + the SQL data sources
  Nothing here touches dzfunctions' own datamodule; the only shared code is RVExtension's CHILD branch.

  On any failure - parse error, unknown method id, handler exception, HiveExt writes nothing to the output buffer,
  not an error string, so CallExtension returns '' and the caller must leave the buffer alone.
}

interface

uses
  Windows, SysUtils, Classes, DateUtils, Math, Generics.Collections, System.Hash, System.IOUtils, DB, Uni, IniFiles,
  uSqfValue, uHiveLog, uHiveDb, uHiveCustomData;

type
  TDataModuleHive = class(TDataModule)
    procedure DataModuleCreate(Sender: TObject);
    procedure DataModuleDestroy(Sender: TObject);
  private
    FLog: THiveLogger;
    {
      FDb is the character database. FObjDb is the same object unless [ObjectDB] Use = true,
      which puts the object table on its own server - the split the C++ makes between _charDb and _objDb.
    }
    FDb: THiveDatabase;
    FObjDb: THiveDatabase;
    FOwnObjDb: boolean;
    FCustom: THiveCustomData;

    FServerId: Integer;
    FInitKey: AnsiString;
    FTimeOffset: TDateTime;
    FShutdownRequested: boolean;
    FDbAbandoned: boolean;

    FHiveIniFile: TInifile;

    { the object stream queue - _srvObjects }
    FStream: TObjectList<TSqfValue>;

    {
      [Objects] settings. VGTable/CleanupVehStoredDays really do live under [Objects], not [Garage]
      DirectHiveApp passes the Objects view to SqlObjDataSource, so the sample ini's [Garage] section is dead config.
    }
    FObjTable: string;
    FGarageTable: string;
    FMaintenanceObjs: string;
    FCleanupPlacedDays: Integer;
    FCleanupStoredDays: Integer;
    FVehicleOOBReset: boolean;
    FLogObjCleanup: boolean;

    { [Characters] }
    FIdField: string;
    FWsField: string;

    procedure SetupClock;
    procedure LogEffectiveConfig;
    function StreamCount: Integer;
    procedure ClearStream;
    procedure PopulateObjects;
    procedure RunObjectCleanup;

    function HGetDateTime(P: TSqfParams): TSqfValue; // 307
    function HStreamObjects(P: TSqfParams): TSqfValue; // 302
    function HServerShutdown(P: TSqfParams): TSqfValue; // 400

    function HObjectInventory(P: TSqfParams; ByUID: boolean): TSqfValue; // 303 / 309
    function HObjectDelete(P: TSqfParams; ByUID: boolean): TSqfValue; // 304 / 310
    function HDatestampObjectUpdate(P: TSqfParams; ByUID: boolean): TSqfValue; // 396 / 397
    function HVehicleMoved(P: TSqfParams): TSqfValue; // 305
    function HVehicleDamaged(P: TSqfParams): TSqfValue; // 306
    function HObjectPublish(P: TSqfParams): TSqfValue; // 308
    function HObjectReturnId(P: TSqfParams): TSqfValue; // 388
    function CreateObject(const ClassName: AnsiString; Damage: Double; CharacterId: Int64; WorldSpace, Inventory, HitPoints: TSqfValue;
      Fuel: Double; UniqueId: Int64): boolean;

    function HChangeTableAccess(P: TSqfParams): TSqfValue; // 500
    function HDataRequest(P: TSqfParams; Async: boolean): TSqfValue; // 501 / 502
    function HDataStatus(P: TSqfParams): TSqfValue; // 503
    function HDataFetchRow(P: TSqfParams): TSqfValue; // 504
    function HDataClose(P: TSqfParams): TSqfValue; // 505

    function HLoadTraderDetails(P: TSqfParams): TSqfValue; // 399
    function HTradeObject(P: TSqfParams): TSqfValue; // 398
    function HBEScriptScan(P: TSqfParams): TSqfValue; // 777

    function HVGQueryVeh(P: TSqfParams): TSqfValue; // 800
    function HVGSpawnVeh(P: TSqfParams): TSqfValue; // 801
    function HVGStoreVeh(P: TSqfParams): TSqfValue; // 802
    function HVGMaintainVeh(P: TSqfParams): TSqfValue; // 803

    function HLoadPlayer(P: TSqfParams): TSqfValue; // 101
    function HLoadCharacterDetails(P: TSqfParams): TSqfValue; // 102
    function HRecordLogin(P: TSqfParams): TSqfValue; // 103
    function HPlayerUpdate(P: TSqfParams): TSqfValue; // 201
    function HPlayerDeath(P: TSqfParams): TSqfValue; // 202
    function HPlayerInit(P: TSqfParams): TSqfValue; // 203
    function HUpdateGroup(P: TSqfParams): TSqfValue; // 204
    function HUpdateGlobalCoins(P: TSqfParams): TSqfValue; // 205
  public
    function Startup: boolean;
    {
      returns '' when the caller must write nothing back to arma, outputSize is Arma's buffer: a reply that does not fit is logged and dropped,
      which is what HiveExt does rather than truncating.
    }
    function CallExtension(const Request: AnsiString; OutputSize: Integer = MaxInt): AnsiString;
    {
      set by a successful CHILD:400, caller writes the result, then calls teardown - matching how RVExtension catches ServerShutdownException.
    }
    procedure Teardown;
    property ShutdownRequested: boolean read FShutdownRequested;
    {
      true when the database layer could not stop its worker and was left in place on purpose - the caller must then not free this datamodule
    }
    function DbAbandoned: boolean;

    property Log: THiveLogger read FLog;
    property Config: TInifile read FHiveIniFile;
    property Db: THiveDatabase read FDb;
    property InitKey: AnsiString read FInitKey;
  end;

var
  DataModuleHive: TDataModuleHive;

implementation

{$R *.dfm}

uses common;

const
  LoggerName = 'HiveExt';

var
  //locale-independent, for parsing the timestamps at the head of scripts.log
  SqfDateFmt: TFormatSettings;

  //helpers
function RtlGenRandom(RandomBuffer: Pointer; RandomBufferLength: ULONG): BOOL; stdcall; external 'advapi32.dll' name 'SystemFunction036';

//16 random bytes, lowercase hex - matches Poco::HexBinaryEncoder's output
function MakeInitKey: AnsiString;
const
  Hex: array[0..15] of AnsiChar = '0123456789abcdef';
var
  Buf: array[0..15] of Byte;
  I: Integer;
begin
  if not RtlGenRandom(@Buf, SizeOf(Buf)) then
    for I := 0 to High(Buf) do
      Buf[I] := Random(256);
  SetLength(Result, Length(Buf) * 2);
  for I := 0 to High(Buf) do
  begin
    Result[I * 2 + 1] := Hex[Buf[I] shr 4];
    Result[I * 2 + 2] := Hex[Buf[I] and $0F];
  end;
end;

function IfThenStr(Cond: boolean; const A, B: string): string;
begin
  if Cond then
    Result := A
  else
    Result := B;
end;

function StatusValue(const Status: AnsiString): TSqfValue;
begin
  Result := TSqfValue.CreateArray;
  Result.Add(TSqfValue.CreateStr(Status));
end;

function StatusValue2(const Status: AnsiString; Extra: TSqfValue): TSqfValue;
begin
  Result := TSqfValue.CreateArray;
  Result.Add(TSqfValue.CreateStr(Status));
  Result.Add(Extra);
end;

function BoolStatus(Ok: boolean): TSqfValue;
begin
  if Ok then
    Result := StatusValue('PASS')
  else
    Result := StatusValue('ERROR');
end;

{
  the c++ reads columns with getString(), which for a temporal column hands back MySQL's own text form.
  TField.AsString instead formats a TDateTimeField using the machine's locale, so DateMaintained came out as "8/1/2026 9:16:53 AM"
  where HiveExt gives "2026-08-01 09:16:44", always go through here for a column that might be temporal
}
function FieldAsMySqlString(F: TField): AnsiString;
begin
  if F.IsNull then
    Exit('');
  case F.DataType of
    ftDate:
      Result := AnsiString(FormatDateTime('yyyy-mm-dd', F.AsDateTime));
    ftTime:
      Result := AnsiString(FormatDateTime('hh:nn:ss', F.AsDateTime));
    ftDateTime, ftTimeStamp:
      Result := AnsiString(FormatDateTime('yyyy-mm-dd hh:nn:ss', F.AsDateTime));
  else
    Result := AnsiString(F.AsString);
  end; //case F.DataType of
end;

//parses a stored SQF blob, falling back to a supplied literal on bad data, exactly where the C++ catches bad_lexical_cast and warns
function ParseOrDefault(const S, Fallback: AnsiString): TSqfValue;
begin
  Result := SqfParseValue(S);
  if Result = nil then
    Result := SqfParseValue(Fallback);
  if Result = nil then
    Result := TSqfValue.CreateArray;
end;

//orig hive: worldspace is [dir,[x,y,z]]; if x < 0 or y > 15360 the position array is emptied, returns true when it changed something
function FixOOBWorldspace(WS: TSqfValue): boolean;
var
  Pos: TSqfValue;
  X, Y: Double;
begin
  Result := False;
  if (WS = nil) or (WS.Kind <> skArray) or (WS.Count <> 2) then
    Exit;
  Pos := WS[1];
  if (Pos.Kind <> skArray) or (Pos.Count <> 3) then
    Exit;
  try
    X := Pos[0].AsDouble;
    Y := Pos[1].AsDouble;
  except
    Exit;
  end; //try..except

  if (X < 0) or (Y > 15360) then
  begin
    Pos.Clear;
    Result := True;
  end; //if (X < 0) or (Y > 15360) then
end;

procedure TDataModuleHive.DataModuleCreate(Sender: TObject);
begin
  FServerId := -1;
  FStream := TObjectList<TSqfValue>.Create(True);
end;

procedure TDataModuleHive.DataModuleDestroy(Sender: TObject);
begin
  // same abandon-aware path, never frees under a worker
  Teardown;
  FreeAndNil(FStream);
end;

function TDataModuleHive.Startup: boolean;
var
  LogFileName: string;
  LogLevel: THiveLogLevel;
  DefMaintenanceObj: string;
  DBHost, DBName, DBUser, DBPass: string;
  DBPort: integer;

  ObjDBHost, ObjDBName, ObjDBUser, ObjDBPass: string;
  ObjDBPort: integer;
begin
  //follow how hive did it, use -profiles that is passed, otherwise just look adjacent to dll (my fallback)
  FHiveIniFile := TiniFile.Create(MakeFileName(GetConfigDir, 'HiveExt.ini'));

  LogLevel := ParseHiveLogLevel(FHiveIniFile.ReadString('Logger', 'Level', 'information'), hlInformation);
  LogFileName := AppDir + FHiveIniFile.ReadString('Logger', 'Filename', DLLName + '.log');

  FLog := THiveLogger.Create(LogFileName, LogLevel);

  FLog.Information('HiveExt', 'Initializing - DLL Location: ' + ExtractFilePath(DLLFullPath) +
    ', Config Dir: ' + GetConfigDir +
    ', DLL Name: ' + ExtractFileName(DLLFullPath) +
    ', DLL Version: ' + DLLVersion +
    ', Logging Level: ' + HiveLogLevelName(LogLevel));

  SetupClock;

  FObjTable := FHiveIniFile.ReadString('Objects', 'Table', 'Object_DATA');
  FCleanupPlacedDays := FHiveIniFile.ReadInteger('Objects', 'CleanupPlacedAfterDays', 6);
  FVehicleOOBReset := ReadIniBool(FHiveIniFile.ReadString('Objects', 'ResetOOBVehicles', 'False'), false);

  DefMaintenanceObj := quotedStr('Land_DZE_GarageWoodDoorLocked') + ',' +
    quotedStr('Land_DZE_LargeWoodDoorLocked') + ',' +
    quotedStr('Land_DZE_WoodDoorLocked') + ',' +
    quotedStr('CinderWallDoorLocked_DZ') + ',' +
    quotedStr('CinderWallDoorSmallLocked_DZ') + ',' +
    quotedStr('Plastic_Pole_EP1_DZ');

  FMaintenanceObjs := FHiveIniFile.ReadString('Objects', 'MaintenanceObjects', DefMaintenanceObj);
  FGarageTable := FHiveIniFile.ReadString('Objects', 'VGTable', 'garage');
  FCleanupStoredDays := FHiveIniFile.ReadInteger('Objects', 'CleanupVehStoredDays', 35);
  FLogObjCleanup := ReadIniBool(FHiveIniFile.ReadString('Objects', 'LogObjectCleanup', 'False'), False);

  FIdField := FHiveIniFile.ReadString('Characters', 'IDField', 'PlayerUID');
  FWsField := FHiveIniFile.ReadString('Characters', 'WSField', 'Worldspace');

  FDb := THiveDatabase.Create(FLog);

  DBHost := FHiveIniFile.ReadString('Database', 'Host', 'localhost');
  DBName := FHiveIniFile.ReadString('Database', 'Database', '');
  DBUser := FHiveIniFile.ReadString('Database', 'Username', '');
  DBPass := FHiveIniFile.ReadString('Database', 'Password', '');
  DBPort := FHiveIniFile.ReadInteger('Database', 'Port', 3306);

  FLog.Information('HiveExt', 'Database connection information: ' +
    'Host: ' + DBHost + ',' +
    'Database: ' + DBName + ',' +
    'User: ' + DBUser + ',' +
    'Port: ' + IntToStr(DBPort));

  Result := FDb.Initialise(DBHost, DBName, DBUser, DBPass, DBPort);

  if not Result then
    Exit;
  FDb.AllowAsyncOperations;

  //orig hive: different object db section (probably not used in most cases)
  FOwnObjDb := ReadIniBool(FHiveIniFile.ReadString('ObjectDB', 'Use', 'False'), False);
  if FOwnObjDb then
  begin
    FObjDb := THiveDatabase.Create(FLog);

    ObjDBHost := FHiveIniFile.ReadString('ObjectDB', 'Host', 'localhost');
    ObjDBName := FHiveIniFile.ReadString('ObjectDB', 'Database', '');
    ObjDBUser := FHiveIniFile.ReadString('ObjectDB', 'Username', '');
    ObjDBPass := FHiveIniFile.ReadString('ObjectDB', 'Password', '');
    ObjDBPort := FHiveIniFile.ReadInteger('ObjectDB', 'Port', 3306);

    FLog.Information('HiveExt', 'Object Database connection information: ' +
      'Host: ' + ObjDBHost + ',' +
      'Database: ' + ObjDBName + ',' +
      'User: ' + ObjDBUser + ',' +
      'Port: ' + IntToStr(ObjDBPort));

    Result := FObjDb.Initialise(ObjDBHost, ObjDBName, ObjDBUser, ObjDBPass, ObjDBPort);
    if not Result then
      Exit;
    FObjDb.AllowAsyncOperations;
  end //if FOwnObjDb then
  else
    FObjDb := FDb;

  FCustom := THiveCustomData.Create(FDb, FObjDb);
  LogEffectiveConfig;
end;

{
  dumps every setting actually in force, not just the ones the ini mentions defaults included,
  so a support log shows what the server really did rather than what the operator thinks they configured
}
procedure TDataModuleHive.LogEffectiveConfig;

  procedure DebugLog(const Section, Key, Value: string);
  begin
    if FHiveIniFile.ValueExists(Section, Key) then
      FLog.Debug(LoggerName, Format('  config %s.%s = %s', [Section, Key, Value]))
    else
      FLog.Debug(LoggerName, Format('  config %s.%s = %s   (default, not in ini)',
        [Section, Key, Value]));
  end; //procedure DebugLog(const Section, Key, Value: string);

begin
  if not FLog.Accepts(hlDebug) then
    Exit;

  FLog.Debug(LoggerName, 'effective configuration:');
  DebugLog('Database', 'Host', FHiveIniFile.ReadString('Database', 'Host', 'localhost'));
  DebugLog('Database', 'Port', IntToStr(FHiveIniFile.ReadInteger('Database', 'Port', 3306)));
  DebugLog('Database', 'Database', FHiveIniFile.ReadString('Database', 'Database', ''));
  DebugLog('Database', 'Username', FHiveIniFile.ReadString('Database', 'Username', ''));

  // never the password, only whether one was supplied
  FLog.Debug(LoggerName, Format('  config Database.Password = %s', [IfThenStr(FHiveIniFile.ReadString('Database', 'Password', '') <> '', '<set>',
        '<empty>')]));

  DebugLog('ObjectDB', 'Use', BoolToStr(FOwnObjDb, True));
  if FOwnObjDb then
  begin
    DebugLog('ObjectDB', 'Host', FHiveIniFile.ReadString('ObjectDB', 'Host', 'localhost'));
    DebugLog('ObjectDB', 'Port', FHiveIniFile.ReadString('ObjectDB', 'Port', '3306'));
    DebugLog('ObjectDB', 'Database', FHiveIniFile.ReadString('ObjectDB', 'Database', ''));
  end; //if FOwnObjDb then

  DebugLog('Characters', 'IDField', FIdField);
  DebugLog('Characters', 'WSField', FWsField);

  DebugLog('Objects', 'Table', FObjTable);
  DebugLog('Objects', 'CleanupPlacedAfterDays', IntToStr(FCleanupPlacedDays));
  DebugLog('Objects', 'ResetOOBVehicles', BoolToStr(FVehicleOOBReset, True));
  DebugLog('Objects', 'MaintenanceObjects', FMaintenanceObjs);
  DebugLog('Objects', 'VGTable', FGarageTable);
  DebugLog('Objects', 'CleanupVehStoredDays', IntToStr(FCleanupStoredDays));
  DebugLog('Objects', 'LogObjectCleanup', BoolToStr(FLogObjCleanup, True));

  DebugLog('Time', 'Type', FHiveIniFile.ReadString('Time', 'Type', 'Local'));
  DebugLog('Time', 'Hour', FHiveIniFile.ReadString('Time', 'Hour', '<unset>'));
  DebugLog('Time', 'Offset', FHiveIniFile.ReadString('Time', 'Offset', '<unset>'));
  DebugLog('Time', 'Date', FHiveIniFile.ReadString('Time', 'Date', '<unset>'));
  FLog.Debug(LoggerName, Format('  clock offset from UTC = %s',
    [FormatDateTime('hh:nn:ss', Abs(FTimeOffset))]));

  DebugLog('Logger', 'Level', HiveLogLevelName(FLog.Level));
  DebugLog('Battleye', 'ScriptsLogLine', FHiveIniFile.ReadString('Battleye', 'ScriptsLogLine', 'DISABLED'));
  DebugLog('Battleye', 'ScriptsLogPath', FHiveIniFile.ReadString('Battleye', 'ScriptsLogPath', 'DISABLED'));
  DebugLog('Battleye', 'BansPath', FHiveIniFile.ReadString('Battleye', 'BansPath', 'DISABLED'));

  // the [Garage] section is dead config - flag it, because people will use it
  if FHiveIniFile.ValueExists('Garage', 'Table') or FHiveIniFile.ValueExists('Garage', 'CleanupVehStoredDays') then
    FLog.Warning(LoggerName, 'ini has a [Garage] section, which HiveExt ignores - ' +
      'VGTable and CleanupVehStoredDays are read from [Objects]');
end;

//orig hive: HiveExtApp::setupClock. _timeOffset is what getDateTime later adds to UTC
procedure TDataModuleHive.SetupClock;
var
  TimeType, OffsetStr, DateStr: string;
  Utc, Nw: TDateTime;
  HourOfDay, Sign, H, M, S: Integer;
  Parts: TArray<string>;
  D, Mo, Y: Word;
begin
  Utc := TTimeZone.Local.ToUniversalTime(Now);
  TimeType := LowerCase(FHiveIniFile.ReadString('Time', 'Type', 'Local'));

  if TimeType = 'custom' then
  begin
    Nw := Utc;
    OffsetStr := Trim(FHiveIniFile.ReadString('Time', 'Offset', '0'));
    if OffsetStr = '' then
      OffsetStr := '0';
    Sign := 1;
    if Copy(OffsetStr, 1, 1) = '-' then
    begin
      Sign := -1;
      Delete(OffsetStr, 1, 1);
    end //if Copy(OffsetStr, 1, 1) = '-' then
    else if Copy(OffsetStr, 1, 1) = '+' then
      Delete(OffsetStr, 1, 1);
    Parts := OffsetStr.Split([':']);
    H := 0;
    M := 0;
    S := 0;
    if Length(Parts) > 0 then
      H := StrToIntDef(Parts[0], 0);
    if Length(Parts) > 1 then
      M := StrToIntDef(Parts[1], 0);
    if Length(Parts) > 2 then
      S := StrToIntDef(Parts[2], 0);
    Nw := IncSecond(Nw, Sign * (H * 3600 + M * 60 + S));
  end //if TimeType = 'custom' then
  else if TimeType = 'static' then
  begin
    Nw := Now;

    if FHiveIniFile.ValueExists('Time', 'Hour') then
    begin
      HourOfDay := FHiveIniFile.ReadInteger('Time', 'Hour', -1);
      if HourOfDay >= 0 then
        Nw := IncHour(Nw, HourOfDay - HourOf(Nw));
    end; //if FHiveIniFile.ValueExists('Time', 'Hour') then

    DateStr := Trim(FHiveIniFile.ReadString('Time', 'Date', ''));
    if DateStr <> '' then
    begin
      // boost from_uk_string, i.e. day first
      Parts := DateStr.Split(['/', '-', '.']);
      if Length(Parts) = 3 then
      begin
        D := StrToIntDef(Parts[0], 0);
        Mo := StrToIntDef(Parts[1], 0);
        Y := StrToIntDef(Parts[2], 0);
        if (D > 0) and (Mo > 0) and (Y > 0) then
          Nw := EncodeDate(Y, Mo, D) + Frac(Nw)
        else
          FLog.Warning(LoggerName, 'Invalid value for Time.Date configuration variable (expected date, given: ' + DateStr + ')');
      end //if Length(Parts) = 3 then
      else
        FLog.Warning(LoggerName, 'Invalid value for Time.Date configuration variable (expected date, given: ' + DateStr + ')');
    end; //if DateStr <> '' then

  end //else if TimeType = 'static' then
  else
    Nw := Now;

  FTimeOffset := Nw - Utc;
end;

//stream
function TDataModuleHive.StreamCount: Integer;
begin
  Result := FStream.Count;
end;

procedure TDataModuleHive.ClearStream;
begin
  FStream.Clear;
end;

procedure TDataModuleHive.RunObjectCleanup;
var
  Q: TUniQuery;
  N: Integer;
  Common: string;
begin
  //dedupe ObjectUID by forcing it to ObjectID + 1
  Common := Format(' WHERE `Instance` = %d AND `ObjectID` <> 0 AND `ObjectID` <> (`ObjectUID` - 1)', [FServerId]);
  N := 0;
  Q := FObjDb.Query('SELECT COUNT(*) FROM ' + FObjTable + Common, []);
  try
    if (Q <> nil) and not Q.EOF then
      N := Q.Fields[0].AsInteger;
  finally
    Q.Free;
  end; //try..finally

  if N > 0 then
  begin
    FLog.Information(LoggerName, Format('Updating %d Object_Data ObjectUID', [N]));
    if not FObjDb.DirectExecute('UPDATE ' + FObjTable + ' SET ObjectUID = (ObjectID + 1) ' + Common, []) then
      FLog.Error(LoggerName, 'Error executing update ObjectUID statement');
  end; //if N > 0 then

  //placed object cleanup
  if FCleanupPlacedDays >= 0 then
  begin
    Common := Format('FROM `%s` WHERE `Instance` = %d AND `ObjectUID` <> 0 AND `CharacterID` <> 0' +
      ' AND `Datestamp` < DATE_SUB(CURRENT_TIMESTAMP, INTERVAL %d DAY)' +
      ' AND ( (`Inventory` IS NULL) OR (`Inventory` = ''[]'') OR (`Classname` IN ( %s) ))',
      [FObjTable, FServerId, FCleanupPlacedDays, FMaintenanceObjs]);

    N := 0;
    Q := FObjDb.Query('SELECT COUNT(*) ' + Common, []);
    try
      if (Q <> nil) and not Q.EOF then
        N := Q.Fields[0].AsInteger;
    finally
      Q.Free;
    end; //try..finally
    if N > 0 then
    begin
      FLog.Notice(LoggerName, Format('Removing %d placed objects older than %d days', [N, FCleanupPlacedDays]));

      if FLogObjCleanup then
      begin
        Q := FObjDb.Query('SELECT ObjectUID, Inventory, Classname, CharacterID, Worldspace, StorageCoins ' + Common, []);

        try
          while (Q <> nil) and not Q.EOF do
          begin
            FLog.Notice(LoggerName, Format(
              'OBJ CLEANUP DELETE. Classname: %s with inventory:%s Object UID: %s Character ID: %s Storage Coins: %s At Worldspace: %s',
              [Q.Fields[2].AsString, Q.Fields[1].AsString, Q.Fields[0].AsString, Q.Fields[3].AsString, Q.Fields[5].AsString, Q.Fields[4].AsString]));
            Q.Next;
          end; //while (Q <> nil) and not Q.EOF do
        finally
          Q.Free;
        end; //try..finally

      end; //if FLogObjCleanup then
      if not FObjDb.DirectExecute('DELETE ' + Common, []) then
        FLog.Error(LoggerName, 'Error executing placed objects cleanup statement');
    end; //if N > 0 then
  end; //if FCleanupPlacedDays >= 0 then

  //virtual garage cleanup
  if FCleanupStoredDays >= 0 then
  begin
    Common := Format('FROM `%s` WHERE `DateMaintained` < DATE_SUB(CURRENT_TIMESTAMP, INTERVAL %d DAY)',
      [FGarageTable, FCleanupStoredDays]);
    N := 0;
    Q := FObjDb.Query('SELECT COUNT(*) ' + Common, []);
    try
      if (Q <> nil) and not Q.EOF then
        N := Q.Fields[0].AsInteger;
    finally
      Q.Free;
    end; //try..finally

    if N > 0 then
    begin
      FLog.Notice(LoggerName, Format('Removing %d virtual garage vehicles stored for %d days', [N, FCleanupStoredDays]));
      if not FObjDb.DirectExecute('DELETE ' + Common, []) then
        FLog.Error(LoggerName, 'Error executing placed objects cleanup statement');
    end; //if N > 0 then
  end; //if FCleanupStoredDays >= 0 then
end;

procedure TDataModuleHive.PopulateObjects;
var
  Q: TUniQuery;
  Row: TSqfValue;
  WS: TSqfValue;
  ObjectId: Integer;
  CharId: Int64;
  Inv: AnsiString;
begin
  ClearStream;
  RunObjectCleanup;

  Q := FObjDb.Query(Format(
    'SELECT `ObjectID`, `Classname`, `CharacterID`, `Worldspace`, `Inventory`, `Hitpoints`, ' +
    '`Fuel`, `Damage`, `StorageCoins` FROM `%s` WHERE `Instance`=%d AND `Classname` IS NOT NULL AND `Damage` < 1',
    [FObjTable, FServerId]), []);
  if Q = nil then
  begin
    FLog.Error(LoggerName, 'Failed to fetch objects from database');
    Exit;
  end; //if Q = nil then

  try
    while not Q.EOF do
    begin
      ObjectId := Q.Fields[0].AsInteger;
      CharId := Q.Fields[2].AsLargeInt;

      Row := TSqfValue.CreateArray;
      try
        Row.Add(TSqfValue.CreateStr('OBJ'));
        Row.Add(TSqfValue.CreateStr(AnsiString(IntToStr(ObjectId))));
        Row.Add(TSqfValue.CreateStr(AnsiString(Q.Fields[1].AsString)));
        Row.Add(TSqfValue.CreateStr(AnsiString(IntToStr(CharId))));

        WS := SqfParseValue(AnsiString(Q.Fields[3].AsString));
        if WS = nil then
        begin
          FLog.Error(LoggerName, Format('Skipping ObjectID %d load because of invalid data in db', [ObjectId]));
          FreeAndNil(Row);
          Q.Next;
          Continue;
        end; //if WS = nil then

        if FVehicleOOBReset and (CharId = 0) then
          if FixOOBWorldspace(WS) then
            FLog.Information(LoggerName, Format('Reset ObjectID %d (%s) from position', [ObjectId, Q.Fields[1].AsString]));
        Row.Add(WS);

        if Q.Fields[4].IsNull then
          Inv := '[]'
        else
          Inv := AnsiString(Q.Fields[4].AsString);

        Row.Add(ParseOrDefault(Inv, '[]'));
        Row.Add(ParseOrDefault(AnsiString(Q.Fields[5].AsString), '[]'));
        Row.Add(TSqfValue.CreateDouble(Q.Fields[6].AsFloat));
        Row.Add(TSqfValue.CreateDouble(Q.Fields[7].AsFloat));
        Row.Add(TSqfValue.CreateInt64(Q.Fields[8].AsLargeInt));

        FStream.Add(Row);
        Row := nil;
      finally
        Row.Free;
      end; //try..finally
      Q.Next;
    end; //while not Q.EOF do
  finally
    Q.Free;
  end;
end;

//orig hive handlers
//CHILD:307
function TDataModuleHive.HGetDateTime(P: TSqfParams): TSqfValue;
var
  Nw: TDateTime;
  DT: TSqfValue;
  Y, Mo, D, H, Mi, S, Ms: Word;
begin
  Nw := TTimeZone.Local.ToUniversalTime(Now) + FTimeOffset;
  DecodeDate(Nw, Y, Mo, D);
  DecodeTime(Nw, H, Mi, S, Ms);
  DT := TSqfValue.CreateArray;
  DT.Add(TSqfValue.CreateInt32(Y));
  DT.Add(TSqfValue.CreateInt32(Mo));
  DT.Add(TSqfValue.CreateInt32(D));
  DT.Add(TSqfValue.CreateInt32(H));
  DT.Add(TSqfValue.CreateInt32(Mi));
  Result := StatusValue2('PASS', DT);
end;

//CHILD:302 - three states, see HiveExtApp::streamObjects
function TDataModuleHive.HStreamObjects(P: TSqfParams): TSqfValue;
var
  LegacyStream: boolean;
  FileName, LastFileName: string;
  Dump: TStringStream;
  I: Integer;
  Line: AnsiString;
begin
  LegacyStream := P[1].AsBoolAny;

  if FLog.Accepts(hlDebug) then
    FLog.Debug(LoggerName, Format(
      '302: legacy=%s queued=%d initKey=%s -> %s',
      [BoolToStr(LegacyStream, True), StreamCount,
        IfThenStr(Length(FInitKey) > 0, 'set', 'unset'),
        IfThenStr(StreamCount > 0,
          IfThenStr(LegacyStream, 'pop one row', 'dump queue to file'),
          IfThenStr(Length(FInitKey) < 1, 'initialise instance', 'delete previous dump'))
        ]
      ));

  if StreamCount = 0 then
  begin
    if Length(FInitKey) < 1 then
    begin
      FServerId := P[0].AsIntAny;
      PopulateObjects;
      FInitKey := MakeInitKey;

      Result := TSqfValue.CreateArray;
      Result.Add(TSqfValue.CreateStr('ObjectStreamStart'));
      Result.Add(TSqfValue.CreateInt32(FStream.Count));
      Result.Add(TSqfValue.CreateStr(FInitKey));
      Exit;
    end; //if Length(FInitKey) < 1 then

    if LegacyStream then
      Exit(StatusValue2('ERROR', TSqfValue.CreateStr('Instance already initialized')));

    LastFileName := string(P[0].AsStringAny);
    if not DeleteFile(PChar(LastFileName)) then
      Result := StatusValue2('WARNING', TSqfValue.CreateStr(AnsiString(
        'Failed to delete previous hive DB file, please manually delete the file. ' +
        'Failure reason: No such file or directory occured when deleting file:' + LastFileName)))
    else
      Result := StatusValue2('NOTICE', TSqfValue.CreateStr(AnsiString(LastFileName + ' has been deleted')));

    Exit;
  end; //if StreamCount = 0 then

  if LegacyStream then
  begin
    // pop one row per call
    Result := FStream[0];
    FStream.Extract(Result);
    Exit;
  end; //if LegacyStream then

  //dump the whole queue to a file named after the init key, return the name, written relative to the cwd, like the C++ ofstream,
  //and as one long line.
  FileName := 'ObjectData' + string(FInitKey) + '.sqf';
  Dump := TStringStream.Create('', TEncoding.ANSI);
  try
    Dump.WriteString('[');
    for I := 0 to FStream.Count - 1 do
    begin
      Line := FStream[I].ToSqf;
      if I >= FStream.Count - 1 then
        Dump.WriteString(string(Line) + '];')
      else
        Dump.WriteString(string(Line) + ',');
    end; //for I := 0 to FStream.Count - 1 do
    Dump.SaveToFile(FileName);
  finally
    Dump.Free;
  end; //try..finally
  FLog.Information(LoggerName, Format('Loaded %d objects from the SQL database', [FStream.Count]));
  ClearStream;
  Result := TSqfValue.CreateStr(AnsiString(FileName));
end;

//CHILD:400
function TDataModuleHive.HServerShutdown(P: TSqfParams): TSqfValue;
var
  TheirKey: AnsiString;
begin
  TheirKey := P[0].AsStringAny;
  if (Length(FInitKey) > 0) and (TheirKey = FInitKey) then
  begin
    FLog.Information(LoggerName, 'Shutting down HiveExt instance');
    //orig hive: returns the value and then throws, so RVExtension writes the result before ExtStartup::ProcessShutdown tears the app down
    //It does not kill the process - the next call just re-creates everything, flag it and let the caller do the teardown after the
    //result is written.
    FShutdownRequested := True;
    Exit(BoolStatus(True));
  end; //if (Length(FInitKey) > 0) and (TheirKey = FInitKey) then
  Result := BoolStatus(False);
end;

function TDataModuleHive.DbAbandoned: boolean;
begin
  Result := (FDb <> nil) and FDb.Abandoned;
end;

//Drops everything so a later call re-initialises, like gApp.reset()
procedure TDataModuleHive.Teardown;

{
  stops a connection's worker and frees it, or - if the worker would not stops, leaves the whole thing in place and reports that
  freeing a connection, its lock or its logger while its thread is still running is what faults the host process on unload,
  could have been a problem in the original hive, this is here to make sure this doesn't break
}
  procedure Release(var Db: THiveDatabase);
  begin
    if Db = nil then
      Exit;
    if Db.Shutdown then
      FreeAndNil(Db)
    else
    begin
      FDbAbandoned := True;
      Db := nil; // deliberately leaked
    end; //if..then..else if Db.Shutdown then
  end; //procedure Release(var Db: THiveDatabase);

begin
  FShutdownRequested := False;
  ClearStream;
  FInitKey := '';
  FServerId := -1;
  FreeAndNil(FCustom);

  // FObjDb aliases FDb unless [ObjectDB] use gave it its own connection
  if FOwnObjDb then
    Release(FObjDb)
  else
    FObjDb := nil;
  FOwnObjDb := False;
  Release(FDb);

  // an abandoned worker still logs, so its logger has to outlive us too
  if not FDbAbandoned then
  begin
    FreeAndNil(FLog);
    FreeAndNil(FHiveIniFile);
  end //if not FDbAbandoned then
  else
  begin
    FLog := nil;
    FHiveIniFile := nil;
  end; //if..then..else if not FDbAbandoned then
end;

//object data source
{
  CHILD:303 / 309. Coins are optional - a missing param 2 means the server is not running the coin system,
  but a param 2 of the wrong type is a real error and must fall through to the empty-output path.
}
function TDataModuleHive.HObjectInventory(P: TSqfParams; ByUID: boolean): TSqfValue;
var
  Ident, Coins: Int64;
  Col, SQL: string;
begin
  Ident := P[0].AsBigInt;
  Coins := -1;
  if P.Count > 2 then
    if not P[2].IsNull then
      Coins := P[2].AsBigInt; // deliberately not guarded - see comment above

  // every vehicle has ObjectUID 0, so a 0 here must never match a WHERE clause
  if Ident = 0 then
    Exit(BoolStatus(True));

  if ByUID then
    Col := 'ObjectUID'
  else
    Col := 'ObjectID';

  if Coins >= 0 then
  begin
    SQL := Format('UPDATE `%s` SET `Inventory` = :p0, `StorageCoins` = :p1 ' + 'WHERE `%s` = :p2 AND `Instance` = :p3', [FObjTable, Col]);
    Result := BoolStatus(FObjDb.Execute(SQL, [string(P[1].ToSqf), Coins, Ident, FServerId]));
  end //if Coins >= 0 then
  else
  begin
    SQL := Format('UPDATE `%s` SET `Inventory` = :p0 WHERE `%s` = :p1 AND `Instance` = :p2', [FObjTable, Col]);
    Result := BoolStatus(FObjDb.Execute(SQL, [string(P[1].ToSqf), Ident, FServerId]));
  end; //if..then..else if Coins >= 0 then
end;

//CHILD:304 / 310
function TDataModuleHive.HObjectDelete(P: TSqfParams; ByUID: boolean): TSqfValue;
var
  Ident: Int64;
  Col: string;
begin
  Ident := P[0].AsBigInt;
  if Ident = 0 then
    Exit(BoolStatus(True));
  if ByUID then
    Col := 'ObjectUID'
  else
    Col := 'ObjectID';
  Result := BoolStatus(FObjDb.Execute(Format('DELETE FROM `%s` WHERE `%s` = :p0 AND `Instance` = :p1', [FObjTable, Col]), [Ident, FServerId]));
end;

//CHILD:396 / 397 - the maintain calls, damage is written as the string '0', same as orig hive
function TDataModuleHive.HDatestampObjectUpdate(P: TSqfParams; ByUID: boolean): TSqfValue;
var
  Ident: Int64;
  Col: string;
begin
  Ident := P[0].AsBigInt;
  if Ident = 0 then
    Exit(BoolStatus(True));
  if ByUID then
    Col := 'ObjectUID'
  else
    Col := 'ObjectID';
  Result := BoolStatus(FObjDb.Execute(Format('UPDATE `%s` SET `Datestamp` = CURRENT_TIMESTAMP, `Damage` = ''0'' ' +
    'WHERE `%s` = :p0 AND `Instance` = :p1', [FObjTable, Col]), [Ident, FServerId]));
end;

//CHILD:305 - note the > 0 test, not <> 0: the script sometimes sends id 0
function TDataModuleHive.HVehicleMoved(P: TSqfParams): TSqfValue;
var
  Ident: Int64;
begin
  Ident := P[0].AsBigInt;
  if Ident <= 0 then
    Exit(BoolStatus(True));
  Result := BoolStatus(FObjDb.Execute(Format('UPDATE `%s` SET `Worldspace` = :p0 , `Fuel` = :p1 WHERE `ObjectID` = :p2 ' + ' AND `Instance` = :p3',
    [FObjTable]), [string(P[1].ToSqf), P[2].AsDouble, Ident, FServerId]));
end;

//CHILD:306
function TDataModuleHive.HVehicleDamaged(P: TSqfParams): TSqfValue;
var
  Ident: Int64;
begin
  Ident := P[0].AsBigInt;
  if Ident <= 0 then
    Exit(BoolStatus(True));
  Result := BoolStatus(FObjDb.Execute(Format('UPDATE `%s` SET `Hitpoints` = :p0 , `Damage` = :p1 WHERE `ObjectID` = :p2 ' +
    'AND `Instance` = :p3', [FObjTable]), [string(P[1].ToSqf), P[2].AsDouble, Ident, FServerId]));
end;

//SqlObjDataSource::createObject - shared by CHILD:308 and the garage spawn
function TDataModuleHive.CreateObject(const ClassName: AnsiString; Damage: Double; CharacterId: Int64; WorldSpace, Inventory, HitPoints: TSqfValue;
  Fuel: Double; UniqueId: Int64): boolean;
begin
  Result := FObjDb.Execute(Format(
    'INSERT INTO `%s` (`ObjectUID`, `Instance`, `Classname`, `Damage`, `CharacterID`, ' +
    '`Worldspace`, `Inventory`, `Hitpoints`, `Fuel`, `Datestamp`) ' +
    'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8, CURRENT_TIMESTAMP)', [FObjTable]),
    [UniqueId, FServerId, string(ClassName), Damage, CharacterId,
      string(WorldSpace.ToSqf), string(Inventory.ToSqf), string(HitPoints.ToSqf), Fuel]);
end;

//CHILD:308 param 0 is the instance the script passed, but the orig hive ignores it and uses getServerId() so 302 must have run first
function TDataModuleHive.HObjectPublish(P: TSqfParams): TSqfValue;
begin
  Result := BoolStatus(CreateObject(P[1].AsStringAny, P[2].AsDouble, P[3].AsBigInt, P[4], P[5], P[6], P[7].AsDouble, P[8].AsBigInt));
end;

{
  CHILD:388 goes through epoch's retObjID procedure, which retry-polls 5x with 100ms sleeps - it exists because 308's INSERT is queued on
  the write connection while this SELECT runs on the read connection.
}
function TDataModuleHive.HObjectReturnId(P: TSqfParams): TSqfValue;
var
  Q: TUniQuery;
  ObjectId: Integer;
begin
  Q := FObjDb.Query('CALL retObjID(:p0, :p1, :p2, @OID)', [FObjTable, FServerId, P[0].AsBigInt]);
  try
    if (Q = nil) or Q.EOF then
      Exit(StatusValue('ERROR'));
    ObjectId := Q.Fields[0].AsInteger;
    if ObjectId = 0 then
      Exit(StatusValue('ERROR'));
    Result := StatusValue2('PASS', TSqfValue.CreateStr(AnsiString(IntToStr(ObjectId))));
  finally
    Q.Free;
  end;
end;

//custom data API, i don't think i've ever seen any of this used, just dragging it in from the orig hive
//i assume this is what my dzfunctions.dll is supposed to do, unfortunately this looks too terrible to have
//actually been used, on the off chance someone used it, bringing it forward
//CHILD:500:SUPERKEY:ALLOWTABLES:REMOVEALLOWTABLES: With neither list given, replies with the current allow list
function TDataModuleHive.HChangeTableAccess(P: TSqfParams): TSqfValue;
var
  TheirKey: AnsiString;
  Allow, Remove: TStringList;
  FailedAdd, FailedRem, Inner: TSqfValue;
  I: Integer;
  Names: TArray<string>;
  Which: string;
  Idx: Integer;

  procedure Collect(V: TSqfValue; Dest: TStringList);
  var
    K: Integer;
    S: string;
  begin
    if V = nil then
      Exit;
    if V.Kind = skString then
    begin
      S := Trim(string(V.AsStringAny));
      if S <> '' then
        Dest.Add(S);
    end //if V.Kind = skString then
    else if V.Kind = skArray then
      for K := 0 to V.Count - 1 do
      begin
        if V[K].Kind <> skString then
          raise ESqfBadGet.Create('not a string');
        Dest.Add(string(V[K].AsStringAny));
      end //for K := 0 to V.Count - 1 do
    else
      raise ESqfBadGet.Create('not a string');
  end; //procedure Collect(V: TSqfValue; Dest: TStringList);

begin
  TheirKey := P[0].AsStringAny;
  if (Length(FInitKey) = 0) or (TheirKey <> FInitKey) then
    Exit(StatusValue2('ERROR', TSqfValue.CreateStr('Invalid key')));

  Allow := TStringList.Create;
  Remove := TStringList.Create;
  try
    Which := 'ALLOWTABLES';
    Idx := -1;
    try
      if P.Count >= 2 then
        Collect(P[1], Allow);
      Which := 'REMOVEALLOWTABLES';
      if P.Count >= 3 then
        Collect(P[2], Remove);
    except
      on ESqfBadGet do
        Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(Which + ' not a string'))));
    end; //try..except

    // neither given - report what is currently allowed
    if (Allow.Count = 0) and (Remove.Count = 0) then
    begin
      Names := FCustom.GetAllowedTables;
      Inner := TSqfValue.CreateArray;
      for I := 0 to High(Names) do
        Inner.Add(TSqfValue.CreateStr(AnsiString(Names[I])));
      Exit(StatusValue2('PASS', Inner));
    end; //if (Allow.Count = 0) and (Remove.Count = 0) then

    // validate every name before applying anything
    try
      Which := 'ALLOWTABLES';
      for I := 0 to Allow.Count - 1 do
      begin
        Idx := I;
        THiveCustomData.VerifyTable(Allow[I]);
      end; //for I := 0 to Allow.Count - 1 do

      Which := 'REMOVEALLOWTABLES';
      for I := 0 to Remove.Count - 1 do
      begin
        Idx := I;
        THiveCustomData.VerifyTable(Remove[I]);
      end; //for I := 0 to Remove.Count - 1 do
    except
      on E: EHiveCustomData do
        Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(
          Format('%s[%d]: %s', [Which, Idx, E.Message])))));
    end; //try..except

    FailedAdd := TSqfValue.CreateArray;
    FailedRem := TSqfValue.CreateArray;
    try
      for I := 0 to Allow.Count - 1 do
        if not FCustom.AllowTable(Allow[I]) then
          FailedAdd.Add(TSqfValue.CreateStr(AnsiString(Allow[I])));
      for I := 0 to Remove.Count - 1 do
        if not FCustom.RemoveAllowedTable(Remove[I]) then
          FailedRem.Add(TSqfValue.CreateStr(AnsiString(Remove[I])));
    except
      on E: EHiveCustomData do
      begin
        FailedAdd.Free;
        FailedRem.Free;
        Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(E.Message))));
      end; //on E: EHiveCustomData do
    end; //try.except

    // ReturnStatus's Sqf::Parameters overload splices rather than nests, so this comes out as ["PASS",failedAdd,failedRem], three elements
    Result := TSqfValue.CreateArray;
    Result.Add(TSqfValue.CreateStr('PASS'));
    Result.Add(FailedAdd);
    Result.Add(FailedRem);
  finally
    Allow.Free;
    Remove.Free;
  end;
end;

//CHILD:501 (sync) / 502 (async), both are answered immediately here
function TDataModuleHive.HDataRequest(P: TSqfParams; Async: boolean): TSqfValue;
var
  TableName: string;
  Columns: TArray<string>;
  I: Integer;
  LimitCount, LimitOffset: Int64;
  Token: Cardinal;
  WhereArr: TSqfValue;
begin
  TableName := string(P[0].AsStringAny);

  if (P.Count < 2) or (P[1].Kind <> skArray) then
    Exit(StatusValue2('ERROR', TSqfValue.CreateStr('FIELDS not an array')));
  SetLength(Columns, P[1].Count);
  for I := 0 to P[1].Count - 1 do
  begin
    if P[1][I].Kind <> skString then
      Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(Format('FIELDS[%d] not a string', [I])))));
    Columns[I] := string(P[1][I].AsStringAny);
  end; //for I := 0 to P[1].Count - 1 do

  LimitCount := -1;
  LimitOffset := 0;
  if P.Count >= 4 then
  begin
    if P[3].Kind = skArray then
    begin
      if P[3].Count < 2 then
        Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(
          'LIMIT in invalid format: ''' + string(P[3].ToSqf) + ''''))));
      LimitOffset := P[3][0].AsBigInt;
      LimitCount := P[3][1].AsBigInt;
    end //if P[3].Kind = skArray then
    else
      try
        LimitCount := P[3].AsBigInt;
      except
        on ESqfBadGet do
          Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(
            'LIMIT in invalid format: ''' + string(P[3].ToSqf) + ''''))));
      end; //try..except..if..then..else if P[3].Kind = skArray then
  end; //if P.Count >= 4 then

  if P.Count >= 3 then
    WhereArr := P[2]
  else
    WhereArr := nil;

  try
    Token := FCustom.DataRequest(TableName, Columns, WhereArr, LimitCount, LimitOffset);
  except
    on E: EHiveCustomData do
      Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(E.Message))));
  end; //try..except

  Result := StatusValue2('PASS', TSqfValue.CreateStr(AnsiString(TokenToHex(Token))));
end;

//shared by 503/504/505 for a missing or malformed token
function BadToken(ReallyBad: boolean): TSqfValue;
begin
  Result := StatusValue2('UNKID', TSqfValue.CreateBool(ReallyBad));
end;

function StateReply(State: TRequestState): TSqfValue;
begin
  case State of
    reqPending: Result := StatusValue('WAIT');
    reqNoMoreRows: Result := StatusValue('NOMORE');
    reqUnknown: Result := BadToken(False);
  else
    Result := StatusValue2('ERROR', TSqfValue.CreateStr('Unknown status'));
  end; //case State of
end;

//CHILD:503
function TDataModuleHive.HDataStatus(P: TSqfParams): TSqfValue;
var
  Token: Cardinal;
  NumRows: Int64;
  NumFields, I: Integer;
  Names: TArray<string>;
  State: TRequestState;
  Inner, FieldArr: TSqfValue;
begin
  if (P.Count < 1) or not HexToToken(string(P[0].AsStringAny), Token) or (Token = 0) then
    Exit(BadToken(True));
  try
    State := FCustom.RequestStatus(Token, NumRows, NumFields, Names);
  except
    on E: EHiveCustomData do
      Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(E.Message))));
  end; //try..except
  if State <> reqOk then
    Exit(StateReply(State));

  FieldArr := TSqfValue.CreateArray;
  for I := 0 to High(Names) do
    FieldArr.Add(TSqfValue.CreateStr(AnsiString(Names[I])));

  Inner := TSqfValue.CreateArray;
  Inner.Add(TSqfValue.CreateStr('PASS'));
  Inner.Add(TSqfValue.CreateInt64(NumRows));
  Inner.Add(TSqfValue.CreateInt64(NumFields));
  Inner.Add(FieldArr);
  Result := Inner;
end;

//CHILD:504
function TDataModuleHive.HDataFetchRow(P: TSqfParams): TSqfValue;
var
  Token: Cardinal;
  State: TRequestState;
  Row: TSqfValue;
begin
  if (P.Count < 1) or not HexToToken(string(P[0].AsStringAny), Token) or (Token = 0) then
    Exit(BadToken(True));
  Row := TSqfValue.CreateArray;
  try
    try
      State := FCustom.GetRowData(Token, Row);
    except
      on E: EHiveCustomData do
      begin
        FreeAndNil(Row);
        Exit(StatusValue2('ERROR', TSqfValue.CreateStr(AnsiString(E.Message))));
      end; //on E: EHiveCustomData do
    end; //try..except
    if State <> reqOk then
    begin
      FreeAndNil(Row);
      Exit(StateReply(State));
    end; // if State <> reqOk then
    Result := StatusValue2('PASS', Row);
    Row := nil;
  finally
    Row.Free;
  end; //try..finally
end;

//CHILD:505
function TDataModuleHive.HDataClose(P: TSqfParams): TSqfValue;
var
  Token: Cardinal;
begin
  if (P.Count < 1) or not HexToToken(string(P[0].AsStringAny), Token) or (Token = 0) then
    Exit(BadToken(True));
  if FCustom.CloseRequest(Token) then
    Result := BoolStatus(True)
  else
    Result := BadToken(False);
end;

//traders - this is deprecated since moving to config traders in 1.0.6, dragging it along anyways

//CHILD:399 shares _srvObjects with CHILD:302, exactly like the orig hive
function TDataModuleHive.HLoadTraderDetails(P: TSqfParams): TSqfValue;
var
  Q: TUniQuery;
  Row: TSqfValue;
begin
  if StreamCount > 0 then
  begin
    Result := FStream[0];
    FStream.Extract(Result);
    Exit;
  end; //if StreamCount > 0 then

  Q := FObjDb.Query('SELECT `id`, `item`, `qty`, `buy`, `sell`, `order`, `tid`, `afile` ' + 'FROM `Traders_DATA` WHERE `tid`=:p0', [P[0].AsBigInt]);
  try
    while (Q <> nil) and not Q.EOF do
    begin
      Row := TSqfValue.CreateArray;
      Row.Add(TSqfValue.CreateInt32(Q.Fields[0].AsInteger));
      Row.Add(ParseOrDefault(AnsiString(Q.Fields[1].AsString), '[]'));
      Row.Add(TSqfValue.CreateInt32(Q.Fields[2].AsInteger));
      Row.Add(ParseOrDefault(AnsiString(Q.Fields[3].AsString), '[]'));
      Row.Add(ParseOrDefault(AnsiString(Q.Fields[4].AsString), '[]'));
      Row.Add(TSqfValue.CreateInt32(Q.Fields[5].AsInteger));
      Row.Add(TSqfValue.CreateInt32(Q.Fields[6].AsInteger));
      Row.Add(TSqfValue.CreateStr(AnsiString(Q.Fields[7].AsString)));
      FStream.Add(Row);
      Q.Next;
    end; //while (Q <> nil) and not Q.EOF do
  finally
    Q.Free;
  end; //try..finally

  Result := TSqfValue.CreateArray;
  Result.Add(TSqfValue.CreateStr('ObjectStreamStart'));
  Result.Add(TSqfValue.CreateInt32(FStream.Count));
end;

//CHILD:398 - action 0 buys (qty - 1, refused at 0), anything else sells
function TDataModuleHive.HTradeObject(P: TSqfParams): TSqfValue;
var
  TraderObjectId, Action, Qty: Integer;
  Q: TUniQuery;
begin
  TraderObjectId := P[0].AsIntAny;
  Action := P[1].AsIntAny;

  if Action <> 0 then
    Exit(BoolStatus(FDb.DirectExecute('UPDATE `Traders_DATA` SET qty = qty + 1 WHERE `id`= :p0', [TraderObjectId])));

  Qty := 0;
  Q := FDb.Query('SELECT `qty` FROM `Traders_DATA` WHERE `id`=:p0', [TraderObjectId]);
  try
    if (Q = nil) or Q.EOF then
      Exit(StatusValue('ERROR'));
    Qty := Q.Fields[0].AsInteger;
  finally
    Q.Free;
  end; //try..finally
  if Qty = 0 then
    Exit(StatusValue('ERROR'));

  Result := BoolStatus(FDb.DirectExecute('UPDATE `Traders_DATA` SET qty = qty - 1 WHERE `id`= :p0', [TraderObjectId]));
end;

{ ------------------------------------------------- battleye script scan --- }

{
  SteamID -> BattlEye GUID: "BE" followed by the id as 8 little-endian bytes, then MD5. Fank's derivation, same as orig hive
  Hash the RAW BYTES. Going through TEncoding.ANSI.GetString first is lossy for any byte >= 0x80, so ids with a high byte produced the wrong GUID
  and it would have varied with the system codepage too.
}
function SteamIDToBEGUID(SteamID: Int64): string;
var
  Raw: TBytes;
  I: Integer;
  V: UInt64;
  H: THashMD5;
begin
  SetLength(Raw, 10);
  Raw[0] := Ord('B');
  Raw[1] := Ord('E');
  V := UInt64(SteamId);

  for I := 0 to 7 do
  begin
    Raw[2 + I] := Byte(V and $FF);
    V := V shr 8;
  end; //for I := 0 to 7 do
  H := THashMD5.Create;
  H.Update(Raw);
  Result := LowerCase(H.HashAsString);
end;

{
  CHILD:777 - disabled unless all three [Battleye] paths are configured, scans scripts.log backwards for a line containing ScriptsLogLine
  and checks its timestamp against now; if no line matches, the player's GUID is appended to the bans file.

  The time comparison below looks wrong because it is wrong upstream: HiveExtApp.cpp:790 assigns TDMinutes from .hours() and TDHours from
  .minutes(), deliberately reproduced - changing it would alter who gets banned

  i've never seen this used either, but just dragging it along in case someone has, i personally recommend not using this stuff
}
function TDataModuleHive.HBEScriptScan(P: TSqfParams): TSqfValue;
var
  StringScan, BansFile, LogFile: string;
  TimeTolerance: Integer;
  BEGuid: string;
  Lines: TStringList;
  I: Integer;
  CheckLine, FormattedLogTime: string;
  LogTime, TimeNow: TDateTime;
  Diff: Double;
  TotalSec: Int64;
  DHours, DMinutes, DSeconds: Int64;
  Match: boolean;
  Bans: TStreamWriter;
begin
  StringScan := FHiveIniFile.ReadString('Battleye', 'ScriptsLogLine', 'DISABLED');
  BansFile := FHiveIniFile.ReadString('Battleye', 'BansPath', 'DISABLED');
  LogFile := FHiveIniFile.ReadString('Battleye', 'ScriptsLogPath', 'DISABLED');
  TimeTolerance := Abs(FHiveIniFile.ReadInteger('Battleye', 'LogTimeTolerance', 2));

  Match := True;
  if (StringScan = 'DISABLED') or (BansFile = 'DISABLED') or (LogFile = 'DISABLED') then
    Exit(BoolStatus(Match));

  BEGuid := SteamIDToBEGUID(P[0].AsBigInt);

  if not FileExists(LogFile) then
  begin
    FLog.Error(LoggerName, 'Failed to open scripts.log file!');
    Exit(BoolStatus(Match));
  end; //if not FileExists(LogFile) then

  Match := False;
  TimeNow := Now;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(LogFile);
    except
      on E: Exception do
      begin
        FLog.Error(LoggerName, 'Failed to open scripts.log file!');
        Exit(BoolStatus(True));
      end; //on E: Exception do
    end; //try..except

    for I := Lines.Count - 1 downto 0 do // scanned from the back, like logLines.back()
    begin
      CheckLine := Lines[I];
      if pos(StringScan, CheckLine) = 0 then
      begin
        FLog.Notice(LoggerName, 'Scanned scripts.log line does not match provided ' +
          '''ScriptsLogLine'' HiveExt.ini variable definition: ' + StringScan +
          'for player with GUID: ' + BEGuid);
        Continue;
      end; //if pos(StringScan, CheckLine) = 0 then

      if Length(CheckLine) < 19 then
        Continue;
      // line begins "dd.mm.yyyy hh:nn:ss"
      FormattedLogTime := copy(CheckLine, 7, 4) + '-' + copy(CheckLine, 4, 2) + '-' + copy(CheckLine, 1, 2) + copy(CheckLine, 11, 9);
      if not TryStrToDateTime(FormattedLogTime, LogTime, SqfDateFmt) then
        Continue;

      Diff := (LogTime - TimeNow) * 86400;
      TotalSec := Abs(Trunc(Diff));
      DHours := TotalSec div 3600;
      DMinutes := (TotalSec div 60) mod 60;
      DSeconds := TotalSec mod 60;

      // upstream swaps these two - see the comment above. TDMinutes holds
      // hours and TDHours holds minutes.
      if (DMinutes = 0) and ((DHours < TimeTolerance) or ((DHours = TimeTolerance) and (DSeconds < 5))) then
      begin
        Match := True;
        FLog.Notice(LoggerName, Format('Successfully found player in scripts.log,  within ' +
          '%d minutes of %s with log text: ''%s''',
          [TimeTolerance, FormatDateTime(' hh:nn:ss', TimeNow), CheckLine]));
        Break;
      end //if (DMinutes = 0) and ((DHours < TimeTolerance) or ((DHours = TimeTolerance) and (DSeconds < 5))) then
      else
        FLog.Notice(LoggerName, Format('Date time not within %d minutes of %s -- compared ' +
          'to string: %s', [TimeTolerance, FormatDateTime(' hh:nn:ss', TimeNow), CheckLine]));
    end; //for I := Lines.Count - 1 downto 0 do

    if not Match then
    begin
      Bans := TStreamWriter.Create(BansFile, True);
      try
        Bans.Write(sLineBreak + BEGuid + ' -1 scripts filter bypass');
      finally
        Bans.Free;
      end; //try..finally
    end; //if not Match then
  finally
    Lines.Free;
  end; //try..finally

  Result := BoolStatus(Match);
end;

//virtual garage - i think this was new in 107
//CHILD:800. Returns a bare array of rows, NOT wrapped in ["PASS",...]
function TDataModuleHive.HVGQueryVeh(P: TSqfParams): TSqfValue;
var
  SortColumn: string;
  Q: TUniQuery;
  Row: TSqfValue;
begin
  SortColumn := 'DisplayName';
  case P[1].AsIntAny of
    1: SortColumn := 'DateStored';
    2: SortColumn := 'id';
    3: SortColumn := 'Name';
    4: SortColumn := 'DateMaintained';
  end; //case P[1].AsIntAny of

  Result := TSqfValue.CreateArray;
  // SortColumn comes from the fixed switch above, so interpolating it is safe;
  // the UID is a parameter (the C++ concatenates it, which is an injection hole)
  Q := FObjDb.Query(Format('SELECT id, classname, StorageCounts, CharacterID, DateStored, ' +
    'DateMaintained FROM `%s` WHERE PlayerUID = :p0 ORDER BY `%s`',
    [FGarageTable, SortColumn]), [string(P[0].AsStringAny)]);
  if Q = nil then
    Exit;
  try
    while not Q.EOF do
    begin
      Row := TSqfValue.CreateArray;
      Row.Add(TSqfValue.CreateInt32(Q.Fields[0].AsInteger));
      Row.Add(TSqfValue.CreateStr(AnsiString(Q.Fields[1].AsString)));
      Row.Add(ParseOrDefault(AnsiString(Q.Fields[2].AsString), '[]'));
      Row.Add(TSqfValue.CreateInt32(Q.Fields[3].AsInteger)); // Int32 in the C++ too
      Row.Add(TSqfValue.CreateStr(FieldAsMySqlString(Q.Fields[4])));
      Row.Add(TSqfValue.CreateStr(FieldAsMySqlString(Q.Fields[5])));
      Row.Add(TSqfValue.CreateInt32(FCleanupStoredDays));
      Result.Add(Row);
      Q.Next;
    end; //while not Q.EOF do
  finally
    Q.Free;
  end;
end;

//CHILD:801 - read the stored vehicle, recreate it as a world object, then drop the garage row, on any failure the whole reply ["ERROR"]
function TDataModuleHive.HVGSpawnVeh(P: TSqfParams): TSqfValue;
var
  VehID, UniqueId, CharacterId: Int64;
  WorldSpace: TSqfValue;
  Q: TUniQuery;
  ClassName: AnsiString;
  Inventory, HitPoints: TSqfValue; // ours to free until Result takes them
  InvRef, HpRef: TSqfValue; // borrowed, owned by Result
  Fuel, Damage: Double;
  Ok: boolean;
begin
  VehID := P[0].AsBigInt;
  WorldSpace := P[1];
  UniqueId := P[2].AsBigInt;

  Inventory := nil;
  HitPoints := nil;
  Q := FObjDb.Query(Format('SELECT classname, CharacterID, Inventory, Hitpoints, Fuel, Damage, ' +
    'Colour, Colour2, serverKey, ObjUID FROM `%s` WHERE ID=:p0', [FGarageTable]), [VehID]);
  try
    if (Q = nil) or Q.EOF then
    begin
      FLog.Error(LoggerName, Format('ERROR spawning virtual garage vehicle. worldspace = %s ' +
        'VehID = %d uniqueID = %d', [string(WorldSpace.ToSqf), VehID, UniqueId]));
      Exit(StatusValue('ERROR'));
    end; //if (Q = nil) or Q.EOF then

    ClassName := AnsiString(Q.Fields[0].AsString);
    CharacterId := Q.Fields[1].AsLargeInt;
    Inventory := ParseOrDefault(AnsiString(Q.Fields[2].AsString), '[]');
    HitPoints := ParseOrDefault(AnsiString(Q.Fields[3].AsString), '[]');
    Fuel := Q.Fields[4].AsFloat;
    Damage := Q.Fields[5].AsFloat;

    Result := TSqfValue.CreateArray;
    Result.Add(TSqfValue.CreateStr('PASS'));
    Result.Add(TSqfValue.CreateStr(ClassName));
    Result.Add(TSqfValue.CreateInt64(CharacterId));
    {
      Add() takes ownership, keeping it until after CreateObject left a window where an exception there would have made the finally
      free something Result already owned, borrowed references are fine to pass; result keeps them alive
    }
    Result.Add(Inventory);
    Result.Add(HitPoints);
    InvRef := Inventory;
    HpRef := HitPoints;
    Inventory := nil;
    HitPoints := nil;

    Result.Add(TSqfValue.CreateDouble(Fuel));
    Result.Add(TSqfValue.CreateDouble(Damage));
    Result.Add(TSqfValue.CreateStr(AnsiString(Q.Fields[6].AsString)));
    Result.Add(TSqfValue.CreateStr(AnsiString(Q.Fields[7].AsString)));
    Result.Add(TSqfValue.CreateStr(AnsiString(Q.Fields[8].AsString)));
    Result.Add(TSqfValue.CreateStr(AnsiString(Q.Fields[9].AsString)));

    Ok := CreateObject(ClassName, Damage, CharacterId, WorldSpace, InvRef, HpRef, Fuel, UniqueId);

    if Ok then
      FObjDb.Execute(Format('DELETE FROM `%s` WHERE `ID` = :p0', [FGarageTable]), [VehID])
    else
    begin
      FLog.Error(LoggerName, 'Failed to create object when removing from virtual garage, ' +
        'DB will not delete the requested object (as it shouldn''t spawn anyway)');
      FreeAndNil(Result);
      Result := StatusValue('ERROR');
    end; //if Ok then
  finally
    Q.Free;
    Inventory.Free;
    HitPoints.Free;
  end;
end;

//CHILD:802 - refuses to store a duplicate (same serverKey + ObjUID)
function TDataModuleHive.HVGStoreVeh(P: TSqfParams): TSqfValue;
var
  Q: TUniQuery;
  DateStored: string;
  Y, M, D: Word;
  Existing: Integer;
begin
  DecodeDate(Now, Y, M, D);
  DateStored := Format('%.2d-%.2d-%d', [D, M, Y]);

  Existing := -1;
  Q := FObjDb.Query(Format('select count(*) FROM `%s` WHERE `serverKey` = :p0 AND `ObjUID` = :p1',
    [FGarageTable]), [string(P[11].AsStringAny), string(P[12].AsStringAny)]);
  try
    if (Q <> nil) and not Q.EOF then
      Existing := Q.Fields[0].AsInteger;
  finally
    Q.Free;
  end; //try..finally

  if Existing < 0 then
    Exit(BoolStatus(False)); // the count query failed; exRes stays false
  if Existing >= 1 then
  begin
    FLog.Error(LoggerName, Format('Duplicate object NOT stored in virtual garage. storage ' +
      'attempt by player with UID: %s ObjectID: %s VG_ServerKey: %s',
      [P[0].AsStringAny, P[12].AsStringAny, P[11].AsStringAny]));
    Exit(BoolStatus(False));
  end; //if Existing >= 1 then

  Result := BoolStatus(FObjDb.Execute(Format(
    'INSERT INTO `%s` (`PlayerUID`, `Name`, `DisplayName`, `Classname`, `Datestamp`, ' +
    '`DateStored`, `DateMaintained`, `CharacterID`, StorageCounts, `Inventory`, `Hitpoints`, ' +
    '`Fuel`, `Damage`, `Colour`, `Colour2`, `serverKey`, `ObjUID`) ' +
    'VALUES (:p0, :p1, :p2, :p3, CURRENT_TIMESTAMP, :p4, CURRENT_TIMESTAMP, :p5, :p6, :p7, ' +
    ':p8, :p9, :p10, :p11, :p12, :p13, :p14)', [FGarageTable]),
    [string(P[0].AsStringAny), string(P[1].AsStringAny), string(P[2].AsStringAny),
      string(P[3].AsStringAny), DateStored, string(P[4].AsStringAny),
      string(P[13].ToSqf), string(P[5].ToSqf), string(P[6].ToSqf),
      P[7].AsDouble, P[8].AsDouble, string(P[9].AsStringAny), string(P[10].AsStringAny),
      string(P[11].AsStringAny), string(P[12].AsStringAny)
      ]
    ));
end;

//CHILD:803
function TDataModuleHive.HVGMaintainVeh(P: TSqfParams): TSqfValue;
begin
  Result := BoolStatus(FObjDb.Execute(
    Format('UPDATE `%s` SET `DateMaintained` = CURRENT_TIMESTAMP WHERE `PlayerUID` = :p0',
    [FGarageTable]), [string(P[0].AsStringAny)]));
end;

//character data source
//CharDataSource::SanitiseInv - inventory is [weapons,magazines]; keep only the first of each melee swing ammo type and drop the rest
function SanitiseInv(Inv: TSqfValue): Integer;
const
  MeleeAmmo: array[0..6] of string = (
    'Hatchet_Swing',
    'Crowbar_Swing',
    'Machete_Swing',
    'Bat_Swing',
    'BatBarbed_Swing',
    'BatNails_Swing',
    'Fishing_Swing'
    );
var
  Mags: TSqfValue;
  Seen: array[0..6] of Integer;
  I, J, K: Integer;
  Item: string;
  Which: Integer;
begin
  Result := 0;
  if (Inv = nil) or (Inv.Kind <> skArray) or (Inv.Count <> 2) then
    Exit;
  Mags := Inv[1];
  if Mags.Kind <> skArray then
    Exit;
  for I := 0 to High(Seen) do
    Seen[I] := 0;

  J := 0;
  while J < Mags.Count do
  begin
    Which := -1;
    if Mags[J].Kind = skString then
    begin
      Item := string(Mags[J].AsStringAny);
      for K := 0 to High(MeleeAmmo) do
        if SameText(Item, MeleeAmmo[K]) then
        begin
          Which := K;
          Break;
        end; //for K := 0 to High(MeleeAmmo) do if SameText(Item, MeleeAmmo[K]) then
    end; //if Mags[J].Kind = skString then

    if Which >= 0 then
    begin
      Inc(Seen[Which]);
      if Seen[Which] > 1 then
      begin
        Mags.DeleteItem(J);
        Inc(Result);
        Continue; // do not advance, the list shifted
      end; //if Seen[Which] > 1 then
    end; //if Which >= 0 then
    Inc(J);
  end; //while J < Mags.Count do
end;

{
  hive tries cast<Sqf::Value> and takes the string out of it, falling back to the raw column text, covers model being stored either as
  "Survivor2_DZ" with quotes or bare
}
function ModelFromDb(const Raw: AnsiString): AnsiString;
var
  V: TSqfValue;
begin
  Result := Raw;
  V := SqfParseValue(Raw);
  try
    if (V <> nil) and (V.Kind = skString) then
      Result := V.AsStringAny;
  finally
    V.Free;
  end;
end;

//CHILD:101 - SqlCharDataSource::fetchCharacterInitial
function TDataModuleHive.HLoadPlayer(P: TSqfParams): TSqfValue;
var
  PlayerId, PlayerName: AnsiString;
  Q: TUniQuery;
  NewPlayer, NewChar: boolean;
  PlayerGroup, WorldSpace, Inventory, Backpack, Survival: TSqfValue;
  PlayerCoins, BankCoins, CharacterCoins, CharacterId: Int64;
  Model: AnsiString;
  Infected, Generation, Humanity: Integer;
begin
  PlayerId := P[0].AsStringAny;
  PlayerName := P[2].AsStringAny;

  PlayerGroup := nil;
  WorldSpace := nil;
  Inventory := nil;
  Backpack := nil;
  Survival := nil;
  NewPlayer := False;
  PlayerCoins := 0;
  BankCoins := 0;
  CharacterCoins := 0;
  CharacterId := -1;
  Model := '';
  Infected := 0;
  Generation := 1;
  Humanity := 2500;

  try
    //make sure the player row exists
    Q := FDb.Query(Format('SELECT `PlayerName`, `PlayerSex`, `playerGroup`, `PlayerCoins`, ' +
      '`BankCoins` FROM `Player_DATA` WHERE `%s`=:p0', [FIdField]), [string(PlayerId)]);
    try
      if (Q <> nil) and not Q.EOF then
      begin
        NewPlayer := False;
        if AnsiString(Q.Fields[0].AsString) <> PlayerName then
        begin
          FDb.Execute(Format('UPDATE `Player_DATA` SET `PlayerName`=:p0 WHERE `%s`=:p1',
            [FIdField]), [string(PlayerName), string(PlayerId)]);
          FLog.Notice(LoggerName, Format('Changed name of player %s from ''%s'' to ''%s''',
            [PlayerId, Q.Fields[0].AsString, PlayerName]));
        end; //if AnsiString(Q.Fields[0].AsString) <> PlayerName then
        PlayerGroup := ParseOrDefault(AnsiString(Q.Fields[2].AsString), '[]');
        PlayerCoins := Q.Fields[3].AsLargeInt;
        BankCoins := Q.Fields[4].AsLargeInt;
      end //if (Q <> nil) and not Q.EOF then
      else
      begin
        NewPlayer := True;
        PlayerGroup := TSqfValue.CreateArray;
        FDb.Execute(Format('INSERT INTO `Player_DATA` (`%s`, `PlayerName`, playerGroup) ' +
          'VALUES (:p0, :p1, :p2)', [FIdField]),
          [string(PlayerId), string(PlayerName), string(PlayerGroup.ToSqf)]);
        FLog.Information(LoggerName, Format('Created a new player %s named ''%s''',
          [PlayerId, PlayerName]));
      end; //if..then..else if (Q <> nil) and not Q.EOF then
    finally
      Q.Free;
    end; //try..finally

    //current living character, if any
    Q := FDb.Query(Format(
      'SELECT `CharacterID`, `%s`, `Inventory`, `Backpack`, ' +
      'TIMESTAMPDIFF(MINUTE,`Datestamp`,`LastLogin`) as `SurvivalTime`, ' +
      'TIMESTAMPDIFF(MINUTE,`LastAte`,NOW()) as `MinsLastAte`, ' +
      'TIMESTAMPDIFF(MINUTE,`LastDrank`,NOW()) as `MinsLastDrank`, ' +
      '`Model`, `duration`, `Coins` FROM `Character_DATA` WHERE `%s` = :p0 AND `Alive` = 1 ' +
      'ORDER BY `CharacterID` DESC LIMIT 1', [FWsField, FIdField]), [string(PlayerId)]);
    try
      NewChar := (Q = nil) or Q.EOF;
      if not NewChar then
      begin
        CharacterId := Q.Fields[0].AsLargeInt;
        WorldSpace := ParseOrDefault(AnsiString(Q.Fields[1].AsString), '[]');
        if Q.Fields[2].IsNull then
          Inventory := TSqfValue.CreateArray
        else
        begin
          Inventory := ParseOrDefault(AnsiString(Q.Fields[2].AsString), '[]');
          SanitiseInv(Inventory);
        end; //if..then..else if Q.Fields[2].IsNull then
        if Q.Fields[3].IsNull then
          Backpack := TSqfValue.CreateArray
        else
          Backpack := ParseOrDefault(AnsiString(Q.Fields[3].AsString), '[]');

        Survival := TSqfValue.CreateArray;
        Survival.Add(TSqfValue.CreateInt32(Q.Fields[4].AsInteger));
        Survival.Add(TSqfValue.CreateInt32(Q.Fields[5].AsInteger));
        Survival.Add(TSqfValue.CreateInt32(Q.Fields[6].AsInteger));
        Survival.Add(TSqfValue.CreateInt32(Q.Fields[8].AsInteger));

        Model := ModelFromDb(AnsiString(Q.Fields[7].AsString));
        CharacterCoins := Q.Fields[9].AsLargeInt;
      end; //if not NewChar then
    finally
      Q.Free;
    end;

    if not NewChar then
      FDb.Execute('UPDATE `Character_DATA` SET `LastLogin` = CURRENT_TIMESTAMP ' +
        'WHERE `CharacterID` = :p0', [CharacterId])
    else
    begin
      // carry generation/humanity/model/infected forward from the last dead one
      Q := FDb.Query(Format('SELECT `Generation`, `Humanity`, `Model`, `Infected` ' +
        'FROM `Character_DATA` WHERE `%s` = :p0 AND `Alive` = 0 ORDER BY `CharacterID` DESC LIMIT 1',
        [FIdField]), [string(PlayerId)]);
      try
        if (Q <> nil) and not Q.EOF then
        begin
          Generation := Q.Fields[0].AsInteger + 1;
          Humanity := Q.Fields[1].AsInteger;
          Model := ModelFromDb(AnsiString(Q.Fields[2].AsString));
          Infected := Q.Fields[3].AsInteger;
        end; //if (Q <> nil) and not Q.EOF then
      finally
        Q.Free;
      end; //try..finally

      WorldSpace := TSqfValue.CreateArray;
      Inventory := TSqfValue.CreateArray;
      Backpack := TSqfValue.CreateArray;
      Survival := ParseOrDefault('[0,0,0,0]', '[]');

      // synchronous - the CharacterID is needed immediately after
      if not FDb.DirectExecute(Format(
        'INSERT INTO `Character_DATA` (`%s`, `InstanceID`, `%s`, `Inventory`, `Backpack`, ' +
        '`Medical`, `Generation`, `Datestamp`, `LastLogin`, `LastAte`, `LastDrank`, `Humanity`) ' +
        'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ' +
        'CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, :p7)', [FIdField, FWsField]),
        [string(PlayerId), FServerId, '[]', '[]', '[]', '[]', Generation, Humanity]) then
      begin
        FLog.Error(LoggerName, 'Error creating character for playerId ' + string(PlayerId));
        Exit(StatusValue('ERROR'));
      end; //if not FDb.DirectExecute

      Q := FDb.Query(Format('SELECT `CharacterID` FROM `Character_DATA` WHERE `%s` = :p0 ' +
        'AND `Alive` = 1 ORDER BY `CharacterID` DESC LIMIT 1', [FIdField]), [string(PlayerId)]);
      try
        if (Q = nil) or Q.EOF then
        begin
          FLog.Error(LoggerName, 'Error fetching created character for playerId ' + string(PlayerId));
          Exit(StatusValue('ERROR'));
        end; //if (Q = nil) or Q.EOF then
        CharacterId := Q.Fields[0].AsLargeInt;
      finally
        Q.Free;
      end; //try..finally
      FLog.Information(LoggerName, Format('Created a new character %d for player ''%s'' (%s)', [CharacterId, PlayerName, PlayerId]));
    end;

    if FLog.Accepts(hlDebug) then
      FLog.Debug(LoggerName, Format(
        '101: uid=%s newPlayer=%s newChar=%s charId=%d generation=%d humanity=%d ' +
        'model=%s coins=%d/%d/%d -> %d element reply',
        [PlayerId, BoolToStr(NewPlayer, True), BoolToStr(NewChar, True), CharacterId,
          Generation, Humanity, Model, CharacterCoins, PlayerCoins, BankCoins,
          IfThen(NewChar, 9, 13)]));

    Result := TSqfValue.CreateArray;
    Result.Add(TSqfValue.CreateStr('PASS'));
    Result.Add(TSqfValue.CreateBool(NewPlayer));
    Result.Add(TSqfValue.CreateStr(AnsiString(IntToStr(CharacterId))));
    if not NewChar then
    begin
      Result.Add(WorldSpace);
      WorldSpace := nil;
      Result.Add(Inventory);
      Inventory := nil;
      Result.Add(Backpack);
      Backpack := nil;
      Result.Add(Survival);
      Survival := nil;
      Result.Add(TSqfValue.CreateInt64(CharacterCoins));
    end //if not NewChar then
    else
      Result.Add(TSqfValue.CreateInt32(Infected));
    Result.Add(TSqfValue.CreateStr(Model));
    Result.Add(PlayerGroup);
    PlayerGroup := nil;
    Result.Add(TSqfValue.CreateInt64(PlayerCoins));
    Result.Add(TSqfValue.CreateInt64(BankCoins));
    Result.Add(TSqfValue.CreateDouble(0.97));
  finally
    PlayerGroup.Free;
    WorldSpace.Free;
    Inventory.Free;
    Backpack.Free;
    Survival.Free;
  end;
end;

//CHILD:102 fetchCharacterDetails, orig hive: coins is selected but never returned
function TDataModuleHive.HLoadCharacterDetails(P: TSqfParams): TSqfValue;
var
  CharacterId: Int64;
  Q: TUniQuery;
  Stats: TSqfValue;
begin
  CharacterId := P[0].AsBigInt;
  Q := FDb.Query(Format(
    'SELECT `%s`, `Medical`, `Generation`, `KillsZ`, `HeadshotsZ`, `KillsH`, `KillsB`, ' +
    '`CurrentState`, `Humanity`, `InstanceID`, `Coins` FROM `Character_DATA` ' +
    'WHERE `CharacterID`=:p0', [FWsField]), [CharacterId]);
  try
    if (Q = nil) or Q.EOF then
      Exit(StatusValue('ERROR'));

    Stats := TSqfValue.CreateArray;
    Stats.Add(TSqfValue.CreateInt32(Q.Fields[3].AsInteger));
    Stats.Add(TSqfValue.CreateInt32(Q.Fields[4].AsInteger));
    Stats.Add(TSqfValue.CreateInt32(Q.Fields[5].AsInteger));
    Stats.Add(TSqfValue.CreateInt32(Q.Fields[6].AsInteger));

    Result := TSqfValue.CreateArray;
    Result.Add(TSqfValue.CreateStr('PASS'));
    Result.Add(ParseOrDefault(AnsiString(Q.Fields[1].AsString), '[]'));
    Result.Add(Stats);
    Result.Add(ParseOrDefault(AnsiString(Q.Fields[7].AsString), '[]'));
    Result.Add(ParseOrDefault(AnsiString(Q.Fields[0].AsString), '[]'));
    Result.Add(TSqfValue.CreateInt32(Q.Fields[8].AsInteger));
    Result.Add(TSqfValue.CreateInt32(Q.Fields[9].AsInteger));
  finally
    Q.Free;
  end;
end;

//CHILD:103
function TDataModuleHive.HRecordLogin(P: TSqfParams): TSqfValue;
begin
  Result := BoolStatus(FDb.Execute(Format(
    'INSERT INTO `Player_LOGIN` (`%s`, `CharacterID`, `Datestamp`, `Action`) ' +
    'VALUES (:p0, :p1, CURRENT_TIMESTAMP, :p2)', [FIdField]),
    [string(P[0].AsStringAny), P[1].AsBigInt, P[2].AsIntAny]));
end;

{
  CHILD:201 - playerUpdate + updateCharacter Fields go into a std::map in orig hive, so the set clause comes out in alpha order,
  sorted list keeps sql identical
}
function TDataModuleHive.HPlayerUpdate(P: TSqfParams): TSqfValue;
var
  CharacterId: Int64;
  Names: TStringList; // sorted, so the SET clause matches std::map order
  Lits: TDictionary<string, string>; // fields written as a literal expression
  Pars: TDictionary<string, Integer>; // fields written as a bound parameter
  Args: TList<Variant>;
  I: Integer;
  SQL, Col, Name: string;

  procedure PutParam(const AName, AValue: string);
  begin
    Names.Add(AName);
    Pars.AddOrSetValue(AName, Args.Count);
    Args.Add(AValue);
  end; //procedure PutParam(const AName, AValue: string);

  procedure PutLiteral(const AName, AExpr: string);
  begin
    Names.Add(AName);
    Lits.AddOrSetValue(AName, AExpr);
  end; //procedure PutLiteral(const AName, AExpr: string);

  procedure AddArrayField(const AName: string; Idx: Integer);
  begin
    if (Idx >= P.Count) or P[Idx].IsNull then
      Exit;
    if (P[Idx].Kind <> skArray) or (P[Idx].Count = 0) then
      Exit;
    PutParam(AName, string(P[Idx].ToSqf));
  end; //procedure AddArrayField(const AName: string; Idx: Integer);

  procedure AddAdditive(const AName: string; Idx: Integer);
  var
    Amount: Integer;
    Sign: Char;
  begin
    if (Idx >= P.Count) or P[Idx].IsNull then
      Exit;
    try
      Amount := Trunc(P[Idx].AsDouble);
    except
      Exit;
    end; //try..except
    if Amount = 0 then
      Exit;
    if Amount < 0 then
    begin
      Sign := '-';
      Amount := Abs(Amount);
    end //if Amount < 0 then
    else
      Sign := '+';
    // the C++ builds "(`Name` + N)" inline, so this stays a literal
    PutLiteral(AName, Format('(`%s` %s %d)', [AName, Sign, Amount]));
  end; //procedure AddAdditive(const AName: string; Idx: Integer);

begin
  CharacterId := P[0].AsBigInt;
  Names := TStringList.Create;
  Lits := TDictionary<string, string>.Create;
  Pars := TDictionary<string, Integer>.Create;
  Args := TList<Variant>.Create;
  try
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;

    AddArrayField('Worldspace', 1);
    AddArrayField('Inventory', 2);
    AddArrayField('Backpack', 3);

    // medical: any "any" entries become []
    if (4 < P.Count) and not P[4].IsNull and (P[4].Kind = skArray) and (P[4].Count > 0) then
    begin
      for I := 0 to P[4].Count - 1 do
        if P[4][I].IsAny then
        begin
          FLog.Warning(LoggerName, Format('update.medical[%d] changed from any to []', [I]));
          P[4].ReplaceWithEmptyArray(I);
        end;
      PutParam('Medical', string(P[4].ToSqf));
    end; //if (4 < P.Count) and not P[4].IsNull and (P[4].Kind = skArray) and (P[4].Count > 0) then

    if (5 < P.Count) and not P[5].IsNull and P[5].AsBoolAny then
      PutLiteral('LastAte', 'CURRENT_TIMESTAMP');
    if (6 < P.Count) and not P[6].IsNull and P[6].AsBoolAny then
      PutLiteral('LastDrank', 'CURRENT_TIMESTAMP');

    AddAdditive('KillsZ', 7);
    AddAdditive('HeadshotsZ', 8);
    AddAdditive('DistanceFoot', 9);
    AddAdditive('Duration', 10);
    AddArrayField('CurrentState', 11);
    AddAdditive('KillsH', 12);
    AddAdditive('KillsB', 13);

    if (14 < P.Count) and not P[14].IsNull and (P[14].Kind = skString) then
      PutParam('Model', string(P[14].AsStringAny));
    AddAdditive('Humanity', 15);

    if (16 < P.Count) and not P[16].IsNull then
      try
        if P[16].AsBigInt >= 0 then
          PutLiteral('Coins', IntToStr(P[16].AsBigInt));
      except
        // not using the coin system
      end; //try..except if (16 < P.Count) and not P[16].IsNull then

    // which fields survived the "only write what changed" filtering - the
    // usual complaint is that some stat is not persisting
    if FLog.Accepts(hlDebug) then
      FLog.Debug(LoggerName, Format('201: charId=%d params=%d fields written: %s',
        [CharacterId, P.Count, IfThenStr(Names.Count = 0, '<none, nothing to update>', StringReplace(Names.CommaText, ',', ', ', [rfReplaceAll]))]));

    if Names.Count = 0 then
      Exit(BoolStatus(True));

    SQL := 'UPDATE `Character_DATA` SET ';
    for I := 0 to Names.Count - 1 do
    begin
      Name := Names[I];
      if I > 0 then
        SQL := SQL + ' , ';
      // Worldspace is the one field whose column name is configurable
      if Name = 'Worldspace' then
        Col := FWsField
      else
        Col := Name;
      if Lits.ContainsKey(Name) then
        SQL := SQL + Format('`%s` = %s', [Col, Lits[Name]])
      else
        SQL := SQL + Format('`%s` = :p%d', [Col, Pars[Name]]);
    end;
    SQL := SQL + Format(', `InstanceID` = %d  WHERE `CharacterID` = %d', [FServerId, CharacterId]);

    Result := BoolStatus(FDb.Execute(SQL, Args.ToArray));
  finally
    Names.Free;
    Lits.Free;
    Pars.Free;
    Args.Free;
  end;
end;

//CHILD:202
function TDataModuleHive.HPlayerDeath(P: TSqfParams): TSqfValue;
begin
  Result := BoolStatus(FDb.Execute(
    'UPDATE `Character_DATA` SET `Alive` = 0, `Infected` = :p0, ' +
    '`LastLogin` = DATE_SUB(CURRENT_TIMESTAMP, INTERVAL :p1 MINUTE) ' +
    'WHERE `CharacterID` = :p2 AND `Alive` = 1',
    [P[2].AsIntAny, Trunc(P[1].AsDouble), P[0].AsBigInt]));
end;

//CHILD:203
function TDataModuleHive.HPlayerInit(P: TSqfParams): TSqfValue;
begin
  Result := BoolStatus(FDb.Execute(
    'UPDATE `Character_DATA` SET `Inventory` = :p0 , `Backpack` = :p1 WHERE `CharacterID` = :p2',
    [string(P[1].ToSqf), string(P[2].ToSqf), P[0].AsBigInt]));
end;

//CHILD:204
function TDataModuleHive.HUpdateGroup(P: TSqfParams): TSqfValue;
begin
  Result := BoolStatus(FDb.Execute(
    Format('UPDATE `Player_DATA` SET `playerGroup`=:p0 WHERE `%s`=:p1', [FIdField]),
    [string(P[2].ToSqf), string(P[0].AsStringAny)]));
end;

//CHILD:205
function TDataModuleHive.HUpdateGlobalCoins(P: TSqfParams): TSqfValue;
var
  PlayerId: string;
  Coins, Bank: Int64;
  Ok: boolean;
begin
  PlayerId := string(P[0].AsStringAny);
  Coins := P[2].AsBigInt;
  Bank := P[3].AsBigInt;
  Ok := True;
  if (Coins >= 0) and (Bank >= 0) then
    Ok := FDb.Execute(Format(
      'UPDATE `Player_DATA` SET `PlayerCoins`=:p0, `BankCoins`=:p1 WHERE `%s`=:p2', [FIdField]),
      [Coins, Bank, PlayerId])
  else if Coins >= 0 then
  begin
    FLog.Information(LoggerName, 'SQF Failed to pass player bank value, skipping column: `BankCoins` update');
    Ok := FDb.Execute(Format('UPDATE `Player_DATA` SET `PlayerCoins`=:p0 WHERE `%s`=:p1',
      [FIdField]), [Coins, PlayerId]);
  end //else if Coins >= 0 then
  else if Bank >= 0 then
  begin
    FLog.Information(LoggerName, 'SQF Failed to pass player coins value, skipping column: `PlayerCoins` update');
    Ok := FDb.Execute(Format('UPDATE `Player_DATA` SET `BankCoins`=:p0 WHERE `%s`=:p1',
      [FIdField]), [Bank, PlayerId]);
  end //else if Bank >= 0 then
  else
    FLog.Information(LoggerName, 'SQF Failed to pass both player coins and player bank values skipping update');
  Result := BoolStatus(Ok);
end;

//dispatch
//replica of RVExtension, we duplicated this here so we can just pass raw from common and make
//sure everything works as the way hive did being called directly
function TDataModuleHive.CallExtension(const Request: AnsiString; OutputSize: Integer): AnsiString;
var
  P: TSqfParams;
  FuncNum: Integer;
  Res: TSqfValue;
begin
  Result := '';
  P := SqfParseParams(Request);
  try
    if P.Count < 2 then
    begin
      FLog.Error(LoggerName, 'Invalid function format: ' + string(Request));
      Exit;
    end; //if P.Count < 2 then

    if (P[0].Kind <> skString) or (P[0].AsStringAny <> 'CHILD') then
    begin
      FLog.Error(LoggerName, 'Invalid function format: ' + string(Request));
      Exit;
    end; //if (P[0].Kind <> skString) or (P[0].AsStringAny <> 'CHILD') then

    try
      FuncNum := P[1].AsIntAny;
    except
      FLog.Error(LoggerName, 'Invalid function format: ' + string(Request));
      Exit;
    end; //try..except

    // drop CHILD and the method id, so handlers index from 0 like the C++
    P.Delete(0);
    P.Delete(0);

    if FLog.Accepts(hlDebug) then
      FLog.Debug(LoggerName, 'Original params: |' + string(Request) + '|');
    FLog.Information(LoggerName, Format('Method: %d Params: %s', [FuncNum, string(P.ToSqf)]));

    Res := nil;
    try
      try
        case FuncNum of
          307: Res := HGetDateTime(P);
          302: Res := HStreamObjects(P);
          400: Res := HServerShutdown(P);
          101: Res := HLoadPlayer(P);
          102: Res := HLoadCharacterDetails(P);
          103: Res := HRecordLogin(P);
          201: Res := HPlayerUpdate(P);
          202: Res := HPlayerDeath(P);
          203: Res := HPlayerInit(P);
          204: Res := HUpdateGroup(P);
          205: Res := HUpdateGlobalCoins(P);
          303: Res := HObjectInventory(P, False);
          309: Res := HObjectInventory(P, True);
          304: Res := HObjectDelete(P, False);
          310: Res := HObjectDelete(P, True);
          305: Res := HVehicleMoved(P);
          306: Res := HVehicleDamaged(P);
          308: Res := HObjectPublish(P);
          388: Res := HObjectReturnId(P);
          396: Res := HDatestampObjectUpdate(P, False);
          397: Res := HDatestampObjectUpdate(P, True);
          398: Res := HTradeObject(P);
          399: Res := HLoadTraderDetails(P);
          777: Res := HBEScriptScan(P);
          500: Res := HChangeTableAccess(P);
          501: Res := HDataRequest(P, False);
          502: Res := HDataRequest(P, True);
          503: Res := HDataStatus(P);
          504: Res := HDataFetchRow(P);
          505: Res := HDataClose(P);
          800: Res := HVGQueryVeh(P);
          801: Res := HVGSpawnVeh(P);
          802: Res := HVGStoreVeh(P);
          803: Res := HVGMaintainVeh(P);
        else
          FLog.Error(LoggerName, 'Invalid method id: ' + IntToStr(FuncNum));
          Exit;
        end; //case FuncNum of
      except
        on E: Exception do
        begin
          FLog.Error(LoggerName, 'Error executing |' + string(Request) + '|');
          Exit;
        end; //on E: Exception do
      end; //try..except

      Result := Res.ToSqf;
      FLog.Information(LoggerName, 'Result: ' + string(Result));

      // too big for Arma's buffer: log and write nothing, never truncate, although I've never seen this actually happen
      if Length(Result) >= OutputSize then
      begin
        FLog.Error(LoggerName, Format('Output size too big (%d) for request : %s', [Length(Result), string(Request)]));
        Result := '';
      end; //if Length(Result) >= OutputSize then
    finally
      Res.Free;
    end;
  finally
    P.Free;
  end;
end;

{
  Runs on DLL_PROCESS_DETACH. Without this the worker thread keeps running while the DLL's code is being unmapped,
  which faults the host - an access violation inside HiveSqlDelay, and the process goes down with it
  This is HiveExt's ExtStartup::ProcessShutdown, minus the deadlock
}
procedure ShutdownHive;
begin
  if DataModuleHive <> nil then
    try
      DataModuleHive.Teardown;
      if DataModuleHive.DbAbandoned then
        DataModuleHive := nil // deliberately leaked, see THiveDatabase.Shutdown
      else
        FreeAndNil(DataModuleHive);
    except
      DataModuleHive := nil; // never raise out of finalization
    end;
end;

initialization
  SqfDateFmt := TFormatSettings.Create;
  SqfDateFmt.DateSeparator := '-';
  SqfDateFmt.TimeSeparator := ':';
  SqfDateFmt.ShortDateFormat := 'yyyy-mm-dd';
  SqfDateFmt.LongTimeFormat := 'hh:nn:ss';
  SqfDateFmt.DecimalSeparator := '.';

finalization
  ShutdownHive;

end.

