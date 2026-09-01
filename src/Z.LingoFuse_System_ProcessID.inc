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

function MakeProcessName: U_String;
begin
  Result := PFormat('%s(%d)', [umlGetFileName(ParamStr(0)).Text, System_ProcessID]);
end;
