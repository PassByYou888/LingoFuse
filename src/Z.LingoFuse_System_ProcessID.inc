function System_ProcessID: Cardinal;
begin
{$IFDEF FPC}
  // Free Pascal 全平台通用
  Result := GetProcessID;
{$ELSE FPC}
{$IFDEF MSWINDOWS}
  // Delphi Windows
  Result := GetCurrentProcessId;
{$ELSE MSWINDOWS}
{$IFDEF LINUX}
  // Delphi Linux
  Result := getpid;
{$ELSE LINUX}
  Result := 0;
{$ENDIF LINUX}
{$ENDIF MSWINDOWS}
{$ENDIF FPC}
end;

function Make_LingoFuse_Process_Name: TLF_String;
begin
  if LingoFuse_Process_Name = '' then
      LingoFuse_Process_Name := PFormat('%s:%d',
      [
  {$IFDEF MSWINDOWS}
      umlChangeFileExt(umlGetFileName(ParamStr(0)), '').Text,
  {$ELSE MSWINDOWS}
      umlGetFileName(ParamStr(0)).Text,
  {$ENDIF MSWINDOWS}
      System_ProcessID
      ]);
  Result := LingoFuse_Process_Name;
end;
