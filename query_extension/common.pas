unit common;

interface

uses System.Classes, System.DateUtils, System.IOUtils, System.SysUtils, System.UITypes, System.SyncObjs, System.AnsiStrings, Winapi.Windows;

var
  AppDir: string = '';
  DLLPath: string = '';
  DLLFullPath: string = '';
  DLLName: string = '';
  DLLVersion: string = '';
  DebugLog: boolean = false;
  LogCriticalSection: TCriticalSection;

function ExcludeTrailingPathDelimiter(TheString: string): string;
function MakeFileName(TheRoot, TheFile: string): string;
function GetConfigDir: string;
function GetDLLFullPath: string;
function GetDLLVersion(const FileName: string): string;
procedure LogIt(TheMsg: string; TheFile: string = '');

//strictly for hive, in case weird values are in ini files for hive
function ReadIniBool(AValue: string; Default: Boolean): Boolean;

procedure RVExtension(toArma: PAnsiChar; outputSize: Integer; fromArma: PAnsiChar); stdcall; export;

{ Is this callExtension payload for the hive rather than dzfunctions?

  The hive's own rule is that the first parsed parameter must be exactly
  "CHILD", and its grammar skips leading whitespace, so this matches that
  without needing to parse. Deliberately stricter than a bare pos('CHILD',..),
  which would also catch a dzfunctions call that merely mentioned it. }
function IsHiveRequest(const Request: AnsiString): Boolean;

{ Single entry point for the hive side. Creates and starts the datamodule on
  first use, the way HiveExt builds gApp on its first call, and tears it down
  again after a successful CHILD:400. Returns '' when nothing should be written
  back to Arma. }
function HiveCallExtension(const Request: AnsiString; OutputSize: Integer): AnsiString;

implementation

uses dmhive, dmmysql;

function ExcludeTrailingPathDelimiter(TheString: string): string;
begin
  if copy(TheString, length(TheString), 1) = '\' then
    Result := copy(TheString, 1, length(TheString) - 1)
  else
    Result := TheString;
end;

function MakeFileName(TheRoot, TheFile: string): string;
begin
  if copy(TheRoot, Length(TheRoot), 1) <> '\' then
    Result := TheRoot + '\' + TheFile
  else
    Result := TheRoot + TheFile;
end;

function GetDLLFullPath: string;
var
  Buffer: array[0..MAX_PATH - 1] of Char;
  Len: DWORD;
begin
  try
    Len := Winapi.Windows.GetModuleFileName(HInstance, Buffer, Length(Buffer));
    if Len = 0 then
      RaiseLastOSError;
    SetString(Result, Buffer, Len);
  except
    Result := EmptyStr;
  end;
end;

function GetDLLVersion(const FileName: string): string;
var
  InfoSize, Handle: DWORD;
  Buffer: TBytes;
  FixedPtr: PVSFixedFileInfo;
  ValueSize: DWORD;
begin
  try
    InfoSize := Winapi.Windows.GetFileVersionInfoSize(PChar(FileName), Handle);
    if InfoSize = 0 then
      RaiseLastOSError;

    SetLength(Buffer, InfoSize);

    if not Winapi.Windows.GetFileVersionInfo(PChar(FileName), Handle, InfoSize, Buffer) then
      RaiseLastOSError;

    if not Winapi.Windows.VerQueryValue(Buffer, '\', Pointer(FixedPtr), ValueSize) then
      RaiseLastOSError;

    Result := Format('%d.%d.%d.%d', [
        LongRec(FixedPtr.dwFileVersionMS).Hi,
        LongRec(FixedPtr.dwFileVersionMS).Lo,
        LongRec(FixedPtr.dwFileVersionLS).Hi,
        LongRec(FixedPtr.dwFileVersionLS).Lo
        ]);
  except
    Result := EmptyStr;
  end;
end;

function GetConfigDir: string;
const
  Starter = '-profiles=';
var
  I: Integer;
  Arg, Rest, Folder: string;
begin
  try
    //  Folder := '@hive';
    Folder := '';
    for I := 1 to ParamCount do
    begin
      Arg := ParamStr(I);
      if Length(Arg) < Length(Starter) then
        Continue;
      if not SameText(Copy(Arg, 1, Length(Starter)), Starter) then
        Continue;
      Rest := Trim(Copy(Arg, Length(Starter) + 1, MaxInt));
      if Rest <> '' then
        Folder := Rest;
    end;
    if trim(folder) = emptystr then
      folder := DLLPath;
    // resolve against the current directory, like Poco::Path::resolve
    Result := ExpandFileName(IncludeTrailingPathDelimiter(Folder));
    Result := IncludeTrailingPathDelimiter(Result);
  except
    Result := EmptyStr;
  end;
end;

procedure LogIt(TheMsg: string; TheFile: string = '');
var
  fs: TFileStream;
  Buf: TBytes;
  FLogFile, TheMessage: string;
  TheDir: string;
begin
  // Gone once finalization has run. Anything still logging after that is on its
  // way out, so drop the line rather than fault.
  if not Assigned(LogCriticalSection) then
    Exit;
  try
    LogCriticalSection.Enter;
    try
      fs := nil;
      try
        if trim(TheFile) = '' then
          FLogFile := MakeFileName(AppDir, 'log_' + FormatDateTime('yyyy_mm_dd', now) + '.log')
        else
        begin
          TheDir := ExtractFilePath(TheFile);
          if trim(TheDir) <> '' then
            if not DirectoryExists(TheDir) then
              ForceDirectories(TheDir);
          if not DirectoryExists(TheDir) then
            Exit;
          FLogFile := TheFile;
        end;
        try
          fs := TFileStream.Create(FLogFile, fmOpenReadWrite or fmShareDenyNone);
        except
          fs := TFileStream.Create(FLogFile, fmCreate);
        end;
        fs.Seek(0, soFromEnd);
        TheMessage := FormatDateTime('yyyy-mm-dd hh:nn:ssAM/PM', Now) + ' - ' + TheMsg + sLineBreak;
        // UTF8, not TEncoding.Default. Default is the machine's ANSI codepage,
        // so the same player name or classname produced different bytes on
        // different servers and anything non-ASCII came out mangled. GetBytes
        // emits no BOM, so appending stays clean.
        Buf := TEncoding.UTF8.GetBytes(TheMessage);
        fs.Write(Buf[0], Length(Buf));
      finally
        fs.Free;
      end;
    finally
      LogCriticalSection.Leave;
    end;
  except
    // Swallow any exceptions from logging to avoid raising in exception contexts
  end;
end;

function HiveCallExtension(const Request: AnsiString; OutputSize: Integer): AnsiString;
begin
  Result := '';
  try
    if DataModuleHive = nil then
    begin
      DataModuleHive := TDataModuleHive.Create(nil);
      if not DataModuleHive.Startup then
      begin
        // HiveExt exits the process here; inside dzfunctions that would take
        // the whole Arma server down, so drop the instance and let the next
        // call retry. Arma sees an empty reply either way.
        FreeAndNil(DataModuleHive);
        Exit;
      end;
    end;

    Result := DataModuleHive.CallExtension(Request, OutputSize);

    if DataModuleHive.ShutdownRequested then
      FreeAndNil(DataModuleHive); // the destructor does the teardown
  except
    on E: Exception do
      Result := ''; // never let anything escape into Arma
  end;
end;

function IsHiveRequest(const Request: AnsiString): Boolean;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(Request)) and CharInSet(Request[I], [' ', #9, #10, #13]) do
    Inc(I);
  Result := Copy(Request, I, 6) = AnsiString('CHILD:');
end;

function ReadIniBool(AValue: string; Default: Boolean): Boolean;
begin
  // case-insensitive on purpose: Poco's getBool was, so stock HiveExt honours
  // "True"/"TRUE" in an ini. Comparing raw meant anything but all-lowercase
  // silently fell through to the default.
  AValue := LowerCase(Trim(AValue));

  if AValue = '' then
    Exit(Default);
  if (AValue = 'true') or (AValue = 'yes') or (AValue = 'on') or (AValue = '1') then
    Result := True
  else if (AValue = 'false') or (AValue = 'no') or (AValue = 'off') or (AValue = '0') then
    Result := False
  else
    Result := Default;
end;

procedure RVExtension(toArma: PAnsiChar; outputSize: Integer; fromArma: PAnsiChar); stdcall; export;
var
  FunctionName: string;
  LineString, ParamString: AnsiString;
  Params: TStringList;
  tmpFromArma: string;
  HiveReply: AnsiString;
begin
  // DLLPath first: GetConfigDir falls back to it when -profiles= is absent, and
  // an empty fallback resolves to the drive root instead of the DLL folder.
  if DLLFullPath = EmptyStr then
    DLLFullPath := GetDLLFullPath;

  if DLLPath = EmptyStr then
    DLLPath := ExtractFilePath(DLLFullPath);

  if DLLName = EmptyStr then
    DLLName := TPath.GetFileNameWithoutExtension(DLLFullPath);

  if DLLVersion = EmptyStr then
    DLLVersion := GetDLLVersion(DLLFullPath);

  if AppDir = EmptyStr then
    AppDir := GetConfigDir;

  if DebugLog then
    LogIt('procedure RVExtension(toArma: PAnsiChar = ' + string(toArma) + ' ; outputSize: Integer = ' + IntToStr(outputSize) +
      '; fromArma: PAnsiChar = ' + string(fromArma) + '); stdcall; export;');

  // HiveExt replacement. This is the only place the two sides meet: a CHILD
  // payload goes to the hive datamodule and returns here, everything else
  // carries on into dzfunctions untouched. An empty reply means write nothing
  // at all to the buffer - that is how HiveExt signals failure.
  if IsHiveRequest(AnsiString(fromArma)) then
  begin
    HiveReply := HiveCallExtension(AnsiString(fromArma), outputSize);
    if HiveReply <> '' then
      System.AnsiStrings.StrLCopy(toArma, PAnsiChar(HiveReply), outputSize - 1);
    Exit;
  end;

  tmpFromArma := string(fromArma);
  if pos('CHILD', tmpFromArma) > 0 then
  begin
    FunctionName := copy(string(tmpFromArma), 1, pos(':', string(fromArma)) - 1);
    LineString := AnsiString(copy(string(tmpFromArma), length(FunctionName) + 2, length(string(fromArma))));
    FunctionName := FunctionName + ':' + copy(string(LineString), 1, pos(':', string(LineString)) - 1);
    LineString := AnsiString(copy(string(tmpFromArma), length(FunctionName) + 2, length(string(tmpFromArma))));
  end // if pos('CHILD', fromArma) > 0 then
  else
  begin
    if pos(':', string(fromArma)) > 0 then
      FunctionName := copy(string(fromArma), 1, pos(':', string(fromArma)) - 1)
    else
      FunctionName := string(fromArma);
    LineString := AnsiString(copy(string(fromArma), length(FunctionName) + 2, length(string(fromArma))));
  end;
  Params := TStringList.Create;
  try
    try
      Params.Clear;
      repeat
        if pos(AnsiString(':'), LineString) > 0 then
          ParamString := copy(LineString, 1, pos(AnsiString(':'), LineString) - 1)
        else
        begin
          ParamString := LineString;
          LineString := AnsiString(EmptyStr);
        end;
        LineString := AnsiString(copy(LineString, pos(AnsiString(':'), LineString) + 1, length(LineString)));
        Params.Add(string(ParamString));
        ParamString := AnsiString(EmptyStr);
      until (LineString = AnsiString(EmptyStr)) and (pos(AnsiString(':'), LineString) = 0);
      LineString := ExecuteFunction(FunctionName, Params);
    except
      on E: exception do
        if LineString = AnsiString(EmptyStr) then
          LineString := '["ERROR","' + AnsiString(E.Message) + '"]'
        else
          LineString := LineString + ',"' + AnsiString(E.Message) + '"]';
    end;
  finally
    // Copy here, not in the try. Previously the copy sat before the raise
    // point, so any exception left toArma untouched and Arma read whatever
    // happened to be in the buffer - a failure looked like garbage instead of
    // naming itself.
    if LineString <> AnsiString(EmptyStr) then
      System.AnsiStrings.StrLCopy(toArma, PAnsiChar(LineString), outputSize - 1);
    FreeAndNil(Params);
  end;
end;

initialization
  { Owned here, by the unit that declares it. Created before any code can run,
    so there is no lazy-create race and no ordering assumption about who logs
    first. Previously it was created on the first RVExtension call and freed by
    two different datamodules - dmmysql.DeInitializeDLL freed it on a plain
    "deinitialize:" while the hive worker thread was still logging through it. }
  LogCriticalSection := TCriticalSection.Create;

finalization
  FreeAndNil(LogCriticalSection);

end.

