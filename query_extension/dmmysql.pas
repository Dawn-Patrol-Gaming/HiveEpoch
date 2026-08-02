unit dmmysql;

interface

uses
  Windows, SysUtils, Classes, DB, IniFiles, stUtils, ansistrings, FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Error,
  FireDAC.UI.Intf, FireDAC.Phys.Intf, FireDAC.Stan.Def, FireDAC.Stan.Pool, FireDAC.Stan.Async, FireDAC.Phys, FireDAC.Phys.MySQL,
  FireDAC.Phys.MySQLDef, FireDAC.VCLUI.Wait, FireDAC.Stan.Param, FireDAC.DatS, FireDAC.DApt.Intf, FireDAC.DApt, system.math,
  FireDAC.Comp.DataSet, FireDAC.Comp.Client, stsystem, system.DateUtils, Uni, MemDS, UniProvider, MySQLUniProvider,
  DBAccess;

type
  TExecutionType = (extSelect, extInsert, extUpdate, extDelete);

  TDataModuleMySQL = class(TDataModule)
    mySQLQuery: TUniQuery;
    mySQLQueryObjects: TUniQuery;
    MySQLProvider: TMySQLUniProvider;
    mySQLDatabase: TUniConnection;
    procedure DataModuleDestroy(Sender: TObject);
  private
    { Private declarations }
    function InitializeDLL(TheParams: TStrings): AnsiString;
    function DeInitializeDLL: AnsiString;
    function ExecuteQuery(QueryName: string; TheParams: TStrings): AnsiString;

    // custom function that won't work with plain query ini file
    function WriteLog(TheParams: TStrings): AnsiString;
    function LoadObjects(TheParams: string): AnsiString;
    function GetNextObject(TheParams: string): AnsiString;
    function CreateObjects(TheParams: TStrings): AnsiString;
    function MaintainArea(TheParams: TStrings): AnsiString;

  public
    { Public declarations }
    function ExecuteFunction(TheName: string; Parameters: TStrings): AnsiString;
    procedure SetupConnection(var TheDB: TUniConnection; var TheQ: TUniQuery);
  end;

var
  DataModuleMySQL: TDataModuleMySQL;

implementation

uses common;

{$R *.dfm}

function TDataModuleMySQL.ExecuteFunction(TheName: string; Parameters: TStrings): AnsiString;
var
  TmpName: string;
begin
  if DebugLog then
    LogIt('Start: function ExecuteFunction(TheName: string = ' + TheName + '; Parameters: TStrings = ' + StringReplace(Parameters.Text, #13#10, ' ',
      [rfReplaceAll]) + '): string;');
  if DataModuleMySQL = nil then
    DataModuleMySQL := TDataModuleMySQL.Create(nil);
  try
    TmpName := trim(lowercase(TheName));
    with DataModuleMySQL do
    begin
      SetupConnection(mySQLDatabase, mySQLQuery);
      if lowercase(TmpName) = 'initialize' then
        Result := InitializeDLL(Parameters)
      else if lowercase(TmpName) = 'deinitialize' then
        Result := DeInitializeDLL
      else if lowercase(TmpName) = 'writelog' then
        Result := WriteLog(Parameters)
      else if lowercase(TmpName) = 'loadobjects' then
        Result := LoadObjects(Parameters[0])
      else if lowercase(TmpName) = 'createobjects' then
        Result := CreateObjects(Parameters)
      else if lowercase(TmpName) = 'getnextobject' then
        Result := GetNextObject(Parameters[0])
      else if lowercase(TmpName) = 'maintainarea' then
        Result := MaintainArea(Parameters)
      else
        Result := ExecuteQuery(TmpName, Parameters);
    end;//with DataModuleMySQL do
  except
    on E: exception do
      if Result = AnsiString(EmptyStr) then
        Result := '["ERROR","' + AnsiString(E.Message) + '"]'
      else
        Result := Result + ',"' + AnsiString(E.Message) + '"]';
  end;
  if DebugLog then
    LogIt('End: function ExecuteFunction(TheName: string = ' + TheName + '; Parameters: TStrings = ' + StringReplace(Parameters.Text, #13#10, ' ',
      [rfReplaceAll]) + '): string; = ' + string(Result));
end;

procedure TDataModuleMySQL.SetupConnection(var TheDB: TUniConnection; var TheQ: TUniQuery);
var
  SettingsFile: TIniFile;
  PortNumber: Integer;
  HostName: string;
  UsrName: string;
  UsrPass: string;
  DBName: string;
  TheFileName: string;
begin
  if not TheDB.Connected then
  begin
    if DebugLog then
      LogIt('procedure SetupConnection(var TheDB: TMySQLDatabase; var TheQ: TMySQLQuery);');
    TheFileName := MakeFileName(ExtractFilePath(GetDLLFullPath), 'HiveExt.ini');
    SettingsFile := TIniFile.Create(TheFileName);
    try
      // do custom retrieval of host information here
      PortNumber := SettingsFile.ReadInteger('Database', 'Port', 3306);
      HostName := SettingsFile.ReadString('Database', 'Host', 'localhost');
      UsrName := SettingsFile.ReadString('Database', 'Username', EmptyStr);
      UsrPass := SettingsFile.ReadString('Database', 'Password', EmptyStr);
      DBName := SettingsFile.ReadString('Database', 'Database', EmptyStr);
      // fill out parameters and connect
      TheDB.ProviderName := 'MySQL';
      TheDB.Username := UsrName;
      TheDB.Password := UsrPass;
      TheDB.Server := HostName;
      TheDB.Port := PortNumber;
      TheDB.Database := DBName;
      with TheQ do
      begin
        Connection := TheDB;
        SQL.Clear;
      end;
      TheDB.Connected := true;
    finally
      FreeAndNil(SettingsFile);
    end;
  end;
end;

procedure TDataModuleMySQL.DataModuleDestroy(Sender: TObject);
begin
  DeInitializeDLL;
end;

function TDataModuleMySQL.InitializeDLL(TheParams: TStrings): AnsiString;
var
  TheBool: boolean;
begin
  Result := '[TRUE,[]]';
  try
    DebugLog := StrToBool(TheParams[0]);
  except
    on E: exception do
      Result := '[FALSE,[' + quotedstr(E.Message) + ']]';
  end;
end;

function TDataModuleMySQL.DeInitializeDLL: AnsiString;
begin
  Result := '[TRUE,[]]';
  try
    if mySQLQuery.Active then
      mySQLQuery.Close;
    if mySQLQueryObjects.Active then
      mySQLQueryObjects.Close;
    mySQLQuery.Connection := nil;
    mySQLQueryObjects.Connection := nil;
    if mySQLDatabase.Connected then
      mySQLDatabase.Close;
  except
    on E: exception do
      Result := '[FALSE,[' + quotedstr(E.Message) + ']]';
  end;
end;

function TDataModuleMySQL.WriteLog(TheParams: TStrings): AnsiString;
var
  TheFile: string;
  LogFileName: string;
  TheLog: AnsiString;
  FileStream: TFileStream;
  OpenMode: word;
  I: Integer;
begin
  TheFile := TheParams[0];
  TheLog := TheParams[1];
  // we do this because we may have ":" in the log entries, which also happen to be separators for parameters
  // for all other functions in this dll, so we'll just assume this got broken up by ":" characters and reconstruct
  for I := 2 to TheParams.Count - 1 do
    TheLog := TheLog + TheParams[I] + ':';
  LogFileName := MakeFileName(DLLPath, TheFile + '.log');
  if not FileExists(LogFileName) then
    OpenMode := fmCreate
  else
    OpenMode := fmOpenReadWrite or fmShareDenyNone;
  FileStream := TFileStream.Create(LogFileName, OpenMode);
  try
    TheLog := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' - ' + TheLog + #13#10;
    FileStream.Seek(0, soFromEnd);
    FileStream.WriteBuffer(TheLog[1], length(TheLog));
    Result := '[TRUE,[0]]';
  finally
    FreeAndNil(FileStream);
  end;
  Result := '[TRUE,["Written: ' + IntToStr(length(TheLog)) + '"]]';
end;

function TDataModuleMySQL.ExecuteQuery(QueryName: string; TheParams: TStrings): AnsiString;
var
  TQ: TUniQuery;
  IniFile: TIniFile;
  TmpString, QueryText: string; // each line of sql in ini
  ExecutionType: TExecutionType; // select, update, insert, delete
  TheQuery: TStringList; // query to put in TQy
  OutputList, InputsList: TStringList;
  ItemNum, NumInput, I, X: Integer;
  DoBool, DoQuote, ReturnVal: boolean;
  function ReplaceParams(TheVal: string): string;
  var
    ReplaceCount: Integer;
    LineString, TmpString: string;
  begin
    ReplaceCount := 0;
    LineString := TheVal;
    while pos('?', LineString) > 0 do
    begin
      TmpString := copy(LineString, 1, pos('?', LineString) - 1);
      Inc(ReplaceCount);
      TmpString := TmpString + ':param' + IntToStr(ReplaceCount);
      LineString := copy(LineString, pos('?', LineString) + 1, length(LineString));
      Result := Result + TmpString;
    end; // while pos('?',LineString) > 0 do
    Result := Result + LineString;
  end;

  procedure FillParams(var TheQ: TUniQuery; PositionList, TheParams: TStrings);
  var
    TheCount, TheCounter: Integer;
    ParamPos: Integer;
    Item, TheVal: string;
    CanDoPrepare: boolean;
  begin
    if TheQ.Prepared then
      TheQ.Unprepare;
    // we have to do Counter-1 when retrieving params[x] because ext2db expects the
    // numbering to start at 1, lists start at 0
    CanDoPrepare := true;
    if TheQ.Params.Count > 0 then
    begin
      TheCounter := 0;
      TheCount := PositionList.Count - 1;
      for TheCounter := 0 to TheCount do
      begin
        Item := PositionList[TheCounter];

        if pos('-ARRAY', Item) > 0 then
        begin
          Item := StringReplace(PositionList[TheCounter], '-ARRAY', EmptyStr, [rfReplaceAll, rfIgnoreCase]);
          TheVal := StringReplace(TheParams[StrToInt(Item) - 1], '[', '(', [rfReplaceAll, rfIgnoreCase]);
          TheVal := StringReplace(TheVal, ']', ')', [rfReplaceAll, rfIgnoreCase]);
          // for X := 0 to TheQ.SQL.Count - 1 do

          // fix for sending double quotes sometimes
          if (copy(TheVal, 1, 1) = '"') and (copy(TheVal, length(TheVal), 1) = '"') then
            TheVal := copy(TheVal, 2, length(TheVal) - 2);

          TheQ.SQL.Text := StringReplace(TheQ.SQL.Text, ':param' + IntToStr(TheCounter + 1), TheVal, [rfReplaceAll, rfIgnoreCase]);
          CanDoPrepare := false;
        end//if pos('-ARRAY', Item) > 0 then
        else
        begin
          // fix for sending double quotes sometimes
          TheVal := TheParams[StrToInt(PositionList[TheCounter]) - 1];
          if (copy(TheVal, 1, 1) = '"') and (copy(TheVal, length(TheVal), 1) = '"') then
            TheVal := copy(TheVal, 2, length(TheVal) - 2);
          TheQ.Params[TheCounter].Value := TheVal;
        end;//if..then..else if pos('-ARRAY', Item) > 0 then

      end;//for TheCounter := 0 to TheCount do
      if CanDoPrepare then
        TheQ.Prepare;
    end; // if TheQ.Params.Count > 0 then
    if DebugLog then
      TheQ.SQL.SaveToFile(MakeFileName(DLLPath, QueryName + '.log'));
  end;//procedure FillParams(var TheQ: TUniQuery; PositionList, TheParams: TStrings);

begin
  IniFile := TIniFile.Create(MakeFileName(AppDir, 'dbfunctions.ini'));
  TheQuery := TStringList.Create;
  InputsList := TStringList.Create;
  OutputList := TStringList.Create;
  TQ := TUniQuery.Create(nil);
  try
    try
      I := 0;
      // load the sql
      QueryText := 'Load';
      while QueryText <> EmptyStr do
      begin
        Inc(I);
        QueryText := IniFile.ReadString(QueryName, 'SQL1_' + IntToStr(I), EmptyStr);
        TheQuery.Add(trim(QueryText));
      end; // while QueryText <> EmptyStr do

      // get number of inputs, this is kind of useless, maybe i'll find a use for it
      NumInput := IniFile.ReadInteger(QueryName, 'Number Of Inputs', 1);

      // get SQL1 inputs - this is the order in which the parameters are passed should be like 1,2,3 etc
      // the number denotes which passed parameter goes to which parameter in sql
      // it goes in order, the first value represents the first sql parameter and the number in the value
      // represents which position in the "TheParams" stringlist to pull from
      InputsList.CommaText := IniFile.ReadString(QueryName, 'SQL1_INPUTS', '1');
      ReturnVal := StrToBool(IniFile.ReadString(QueryName, 'Return InsertID', 'false'));

      // get output - for each value in the list, if one of them says -STRING then quote the value
      // otherwise just put it in the result as is
      OutputList.CommaText := IniFile.ReadString(QueryName, 'OUTPUT', '1');

      // load TQ
      with TQ, TQ.SQL do
      begin
        Connection := mySQLDatabase;
        Clear;
        TheQuery.Text := ReplaceParams(TheQuery.Text);
        SQL.Assign(TheQuery);
        if DebugLog then
          SQL.SaveToFile(MakeFileName(DLLPath, QueryName + '.log'));
        if pos('select ', lowercase(TheQuery.Text)) = 1 then
          ExecutionType := extSelect;
        if pos('update ', lowercase(TheQuery.Text)) = 1 then
          ExecutionType := extUpdate;
        if pos('insert ', lowercase(TheQuery.Text)) = 1 then
          ExecutionType := extInsert;
        if pos('delete ', lowercase(TheQuery.Text)) = 1 then
          ExecutionType := extDelete;

        // fill out the query parameters based on position in TheParams specified
        // this is kinda dumb because if you're not stupid, you'll set it up to go
        // in order, but this is what ext2db does, so we'll just replicate it for now
        FillParams(TQ, InputsList, TheParams);

        case ExecutionType of
          extSelect:
            begin
              Open;
              // we want to return false if no record found otherwise just continue on
              if RecordCount <> 0 then
              begin
                Result := '[TRUE,';
                // if more than one record then we'll nest the records in another array
                if RecordCount > 1 then
                  Result := Result + '[';
                while not EOF do
                begin
                  // fill out result with field vaules
                  Result := Result + '[';
                  // for I := 0 to FieldDefs.Count - 1 do
                  for I := 0 to OutputList.Count - 1 do
                  begin
                    TmpString := OutputList[I];
                    if pos('-STRING', TmpString) > 0 then
                    begin
                      ItemNum := StrToInt(copy(TmpString, 1, pos('-', TmpString) - 1));
                      DoQuote := true;
                    end
                    else if pos('-BOOLEAN', TmpString) > 0 then
                    begin
                      ItemNum := StrToInt(copy(TmpString, 1, pos('-', TmpString) - 1));
                      DoBool := true;
                    end
                    else
                    begin
                      ItemNum := StrToInt(TmpString);
                      DoQuote := false;
                      DoBool := false;
                    end;
                    if DoQuote then
                      Result := Result + quotedstr(Fields[ItemNum - 1].asString)
                    else if DoBool then
                    begin
                      try
                        if Fields[ItemNum - 1].asBoolean then
                          Result := Result + quotedstr('TRUE')
                        else
                          Result := Result + quotedstr('FALSE');
                      except
                        if Fields[ItemNum - 1].asString = '1' then
                          Result := Result + quotedstr('TRUE')
                        else
                          Result := Result + quotedstr('FALSE');
                      end;
                    end
                    else
                      Result := Result + Fields[ItemNum - 1].asString;
                    if I < FieldDefs.Count - 1 then
                      Result := Result + ',';
                  end; // for I := 0 to FieldDefs.Count - 1 do
                  Next;
                  Result := Result + ']';
                  // we have more records then add another array to the array of arrays
                  if not EOF then
                    Result := Result + ',';
                end; // while not EOF do
                if RecordCount > 1 then
                  Result := Result + ']';
                Result := Result + ']';
              end
              else
                Result := '[FALSE,[]]';
            end; // extSelect:
          extInsert:
            begin
              Connection.StartTransaction;
              ExecSQL;
              Connection.Commit;
              if ReturnVal then
              begin
                Clear;
                Add('select last_insert_id();');
                Open;
                Result := '[TRUE,[' + Fields[0].asString + ']]';
                Close;
              end
              else
                Result := '[TRUE,[' + IntToStr(RowsAffected) + ']]';
            end;
          extUpdate, extDelete:
            begin
              Connection.StartTransaction;
              ExecSQL;
              Connection.Commit;
              Result := '[TRUE,[' + IntToStr(RowsAffected) + ']]';
            end; // extUpdate, extInsert, extDelete:
        end; // case
      end; // with TQ, TQ.SQL do
    except
      on E: exception do
      begin
        if mySQLDatabase.InTransaction then
          mySQLDatabase.RollBack;
        Result := '[FALSE,[' + quotedstr(E.Message) + ']]';
      end;
    end;
  finally
    if mySQLDatabase.InTransaction then
      mySQLDatabase.Commit;
    if TQ.Active then
      TQ.Close;
    FreeAndNil(TQ);
    FreeAndNil(TheQuery);
    FreeAndNil(InputsList);
    FreeAndNil(OutputList);
    FreeAndNil(IniFile);
  end;
end;

function TDataModuleMySQL.LoadObjects(TheParams: string): AnsiString;
begin
  try
    mySQLQueryObjects.Open;
    mySQLQueryObjects.Last;
    mySQLQueryObjects.First;
    Result := AnsiString('["PASS",' + IntToStr(mySQLQueryObjects.RecordCount) + ']');
    mySQLQueryObjects.First;
  except
    on E: exception do
      Result := AnsiString('["ERROR","' + E.Message + '"]');
  end;
  if DebugLog then
    LogIt('function TDataModuleMySQL.LoadObjects(TheParams: string = ' + TheParams + '): string; = ' + string(Result));
end;

function TDataModuleMySQL.GetNextObject(TheParams: string): AnsiString;
begin
  Result := '[';
  try
    try
      with mySQLQueryObjects, mySQLQueryObjects.SQL do
        if Active then
        begin
          repeat
            Next;
            Result := Result + '["OBJ",';
            Result := Result + '"' + AnsiString(FieldByName('ObjectID').asString) + '",';
            Result := Result + '"' + AnsiString(FieldByName('ClassName').asString) + '",';
            Result := Result + '"' + AnsiString(FieldByName('CharacterID').asString) + '",';
            Result := Result + AnsiString(FieldByName('Worldspace').asString) + ',';
            Result := Result + AnsiString(FieldByName('Inventory').asString) + ',';
            Result := Result + AnsiString(FieldByName('Hitpoints').asString) + ',';
            Result := Result + AnsiString(FieldByName('Fuel').asString) + ',';
            Result := Result + AnsiString(FieldByName('Damage').asString) + ',';
            Result := Result + AnsiString(FieldByName('objectname').asString) + ',';
            Result := Result + AnsiString(FieldByName('owneruid').asString) + ',';
            Result := Result + AnsiString(FieldByName('accesslist').asString);
            Result := Result + '],';

          until ((RecNo / 20) = (RecNo div 20)) or EOF;
          Result := copy(Result, 1, length(Result) - 1) + ']';
          if EOF then
            Close;
        end // with mySQLQuery, mySQLQuery.SQL do
        else
          Result := Result + '-1]';
    except
      on E: exception do
        Result := AnsiString('["ERROR","' + E.Message + '"]');
    end;
  finally
    if mySQLQuery.Active then
      mySQLQuery.Close;
  end;
  if DebugLog then
    LogIt('function TDataModuleMySQL.GetNextObject(TheParams: string = ' + TheParams + '): string; = ' + string(Result));
end;

function TDataModuleMySQL.CreateObjects(TheParams: TStrings): AnsiString;
const
  Template =
    '_myArray = ["OBJ","%ObjectID%","%ClassName%","%CharacterID%",%Worldspace%,%Inventory%,%Hitpoints%,%Fuel%,%Damage%,%StorageCoins%,"%objectname%","%owneruid%",%accesslist%];_objArray set [count _objArray, _myArray];';
var
  ModulePath, ThePath, TmpString: string;
  CreateTemplate, TmpStringList: TStringList;
  procedure Cleanup;
  var
    FileList: TStringList;
    I: Integer;
  begin
    FileList := TStringList.Create;
    try
      try
        EnumerateFiles(ThePath + '\objspawn', FileList, false, nil);
        for I := 0 to FileList.Count - 1 do
          if (pos(lowercase(TheParams[1]), lowercase(FileList[I])) > 0) and (lowercase(ExtractFileExt(FileList[I])) = '.sqf') then
            DeleteFile(FileList[I]);
      except
      end;
    finally
      FreeAndNil(FileList);
    end;
  end;

begin
  TmpStringList := TStringList.Create;
  CreateTemplate := TStringList.Create;
  try
    // in order to get this thing to get the correct folder to put the output of objects
    // from the database you need to extractfilepath from module name, then
    // extractfilepath again, but the trailing backslash needs to be removed beforehand
    // otherwise it just returns the original file path (module directory)
    // thepath should equal the root arma install directory
    ThePath := ExcludeTrailingPathDelimiter(ExtractFilePath(ExcludeTrailingPathDelimiter(ExtractFilePath(DLLFullPath))));
    ModulePath := ExcludeTrailingPathDelimiter(ExtractFilePath(DLLFullPath));
    CreateTemplate.LoadFromFile(MakeFileName(ModulePath, 'template.sqf'));
    Cleanup;
    TmpStringList.Add('DZ_Object_Array = [];');
    TmpStringList.Add('_objArray = [];');
    try
      with mySQLQueryObjects, mySQLQueryObjects.SQL do
      begin
        if Active then
        begin
          while not EOF do
          begin
            TmpString := Template;
            TmpString := StringReplace(TmpString, '%ObjectID%', FieldByName('ObjectID').asString, []);
            TmpString := StringReplace(TmpString, '%ClassName%', FieldByName('ClassName').asString, []);
            TmpString := StringReplace(TmpString, '%CharacterID%', FieldByName('CharacterID').asString, []);
            TmpString := StringReplace(TmpString, '%Worldspace%', FieldByName('Worldspace').asString, []);
            TmpString := StringReplace(TmpString, '%Inventory%', FieldByName('Inventory').asString, []);
            TmpString := StringReplace(TmpString, '%Hitpoints%', FieldByName('Hitpoints').asString, []);
            TmpString := StringReplace(TmpString, '%Fuel%', FieldByName('Fuel').asString, []);
            TmpString := StringReplace(TmpString, '%Damage%', FieldByName('Damage').asString, []);
            TmpString := StringReplace(TmpString, '%StorageCoins%', FieldByName('StorageCoins').asString, []);
            TmpString := StringReplace(TmpString, '%objectname%', FieldByName('objectname').asString, []);
            TmpString := StringReplace(TmpString, '%owneruid%', FieldByName('owneruid').asString, []);
            TmpString := StringReplace(TmpString, '%accesslist%', FieldByName('accesslist').asString, []);
            TmpStringList.Add(TmpString);
            Next;
          end; // while not EOF do
          TmpStringList.AddStrings(CreateTemplate);
          Result := AnsiString('["PASS",' + IntToStr(RecordCount) + ']');
        end // if Active then
        else
          Result := AnsiString('["ERROR",0]');
      end; // with mySQLQueryObjects, mySQLQueryObjects.SQL do
      TmpStringList.Add('decayed_bases = [];');
      if not DirectoryExists(MakeFileName(ThePath, '\objspawn')) then
        ForceDirectories(MakeFileName(ThePath, '\objspawn'));
      TmpStringList.SaveToFile(MakeFileName(ThePath, '\objspawn\object' + TheParams[0] + '.sqf'));
    except
      on E: exception do
        Result := AnsiString('["ERROR","' + E.Message + '"]');
    end;
  finally
    FreeAndNil(TmpStringList);
    FreeAndNil(CreateTemplate);
    if mySQLQuery.Active then
      mySQLQuery.Close;
  end;
  if DebugLog then
    LogIt('function TDataModuleMySQL.CreateObjects(TheParams: string = ' + TheParams.Text + '): string; = ' + string(Result));
end;

function TDataModuleMySQL.MaintainArea(TheParams: TStrings): AnsiString;
var
  TheFieldName: string;
  TheList: TStringList;
  PlayerInfo, MapGrid, TmpString: string;
  PlotID: Integer;
  TQ: TUniQuery;
begin
  Result := '[';
  TheList := TStringList.Create;
  TQ := TUniQuery.Create(nil);
  try
    try
      if TheParams[0] = 'ID' then
        TheFieldName := 'objectid'
      else
        TheFieldName := 'objectuid';

      PlayerInfo := TheParams[1];
      PlotID := StrToInt(StringReplace(TheParams[2], '"', EmptyStr, [rfReplaceAll, rfIgnoreCase]));
      MapGrid := StringReplace(TheParams[3], '"', EmptyStr, [rfReplaceAll, rfIgnoreCase]);

      TmpString := TheParams[4];
      TmpString := StringReplace(TmpString, '[', EmptyStr, [rfReplaceAll, rfIgnoreCase]);
      TmpString := StringReplace(TmpString, ']', EmptyStr, [rfReplaceAll, rfIgnoreCase]);
      TmpString := StringReplace(TmpString, '"', EmptyStr, [rfReplaceAll, rfIgnoreCase]);
      TheList.CommaText := TmpString;
      // TheList.savetofile('c:\temp\thelist' + formatdatetime('yyyymmddhhnnss',now) +TheFieldName+ '.log');
      with TQ, TQ.SQL do
      begin
        Connection := mySQLDatabase;
        Clear;
        Add('update object_Data set lastupdated = current_timestamp, datestamp = current_timestamp,');
        Add('damage = 0');
        Add('where ' + TheFieldName + ' in (');
        Add(TheList.CommaText);
        Add(')');
        ExecSQL;
        if RowsAffected > 0 then
          Result := AnsiString('["PASS","' + IntToStr(RowsAffected) + '"]')
        else
          Result := AnsiString('["ERROR","Not found"]');
        Clear;
        Add('update object_Data set characterid = objectid');
        Add('where ' + TheFieldName + ' in (');
        Add(TheList.CommaText);
        Add(')');
        Add('and characterid = 0 and classname like ''%plastic%''');
        ExecSQL;
        Close;
        Clear;
        Add('REPLACE INTO maintained_objects');
        Add('(objectid, plotid, maintainedby, worldspace, mapgrid, maintaineddate)');
        Add('SELECT objectid, :plotid, :playerinfo, worldspace, :mapgrid,CURRENT_TIMESTAMP');
        Add('FROM object_data');
        Add('where ' + TheFieldName + ' in (');
        Add(TheList.CommaText);
        Add(')');
        ParamByName('playerinfo').asString := PlayerInfo;
        ParamByName('mapgrid').asString := MapGrid;
        ParamByName('plotid').asInteger := PlotID;
        Prepare;
        ExecSQL;
      end; // with TQ, TQ.SQL do
    except
      on E: exception do
        Result := AnsiString('["ERROR","' + E.Message + '"]');
    end;
  finally
    if TQ.Active then
      TQ.Close;
    FreeAndNil(TQ);
    if TheList <> nil then
      FreeAndNil(TheList);
  end;
  if DebugLog then
    LogIt('function TDataModuleMySQL.MaintainArea(TheParams: TStrings = ' + TheParams.CommaText + '): string; = ' + string(Result));
end;

end.

