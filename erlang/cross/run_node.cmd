@echo off
REM cross\run_node.cmd
REM
REM Windows convenience launcher for cross_node.escript.

setlocal
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."

pushd "%ROOT_DIR%"
escript "cross\cross_node.escript" %*
set "RC=%ERRORLEVEL%"
popd

exit /b %RC%