@echo off
REM rebar3.cmd
REM
REM Windows launcher for the rebar3 escript that sits next to this
REM file. Allows invoking the tool as simply `rebar3` from any shell
REM whose PATH contains this directory.
REM
REM The %~dp0 token expands to the directory that contains this .cmd
REM file (with a trailing backslash), so the escript is found
REM regardless of the current working directory.

setlocal
escript "%~dp0rebar3" %*