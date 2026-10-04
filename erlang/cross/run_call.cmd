@echo off
REM cross\run_call.cmd
REM
REM Windows convenience launcher for cross_call.escript.

setlocal
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."

pushd "%ROOT_DIR%"
escript "cross\cross_call.escript" %*
set "RC=%ERRORLEVEL%"
popd

exit /b %RC%