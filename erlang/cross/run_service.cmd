@echo off
REM cross\run_service.cmd
REM
REM Windows convenience launcher for cross_service.escript.
REM Run this script from anywhere; it locates the project root
REM relative to its own path and invokes escript from there.

setlocal
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."

pushd "%ROOT_DIR%"
escript "cross\cross_service.escript" %*
set "RC=%ERRORLEVEL%"
popd

exit /b %RC%