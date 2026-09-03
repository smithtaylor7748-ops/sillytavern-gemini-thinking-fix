@echo off
setlocal
rem NOTE: keep this file pure ASCII. cmd.exe splits batch lines by byte offset,
rem so multi-byte Chinese in a .cmd that has switched to code page 65001 breaks
rem line parsing. All Chinese output comes from Fix-GeminiThinking.ps1 instead.
rem Line endings are CRLF on purpose: cmd.exe seeks goto labels by byte offset
rem and goto is unreliable in an LF-only batch file.

rem NOTE: this file deliberately uses goto instead of "if ... ( ... )" blocks.
rem cmd.exe parses a whole parenthesised block up front, so an unquoted path
rem expanded inside one closes the block early when the folder name itself
rem contains a bracket -- e.g. dropping this tool in "New folder (2)" used to
rem fail with "\Fix-GeminiThinking.ps1 was unexpected at this time."

rem chcp changes the WHOLE console and stays in effect after this script exits.
rem Record the incoming code page and restore it on every exit path.
set "ORIG_CP="
for /f "tokens=2 delims=:" %%A in ('chcp') do set "ORIG_CP=%%A"
if defined ORIG_CP set "ORIG_CP=%ORIG_CP: =%"
if defined ORIG_CP set "ORIG_CP=%ORIG_CP:.=%"
chcp 65001 >nul
set "EXIT_CODE=0"
title Fix SillyTavern Gemini Thinking

rem Script sits next to this .cmd, so the whole folder can be copied anywhere.
set "FIX_SCRIPT=%~dp0Fix-GeminiThinking.ps1"
if not exist "%FIX_SCRIPT%" goto :no_script

rem Windows PowerShell 5.1 is the tested path and exists on every Windows box.
rem Unlike the launcher .cmd files in the bridge project this one does NOT narrow
rem PSModulePath: it never touches Microsoft.PowerShell.Security, and narrowing
rem would break the pwsh fallback below.
set "PS_EXE=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS_EXE%" goto :run
where pwsh.exe >nul 2>&1
if errorlevel 1 goto :no_ps
set "PS_EXE=pwsh.exe"

:run
rem Extra arguments pass straight through, so -DeepScan / -PatchOnly / -Revert
rem / -Path "D:\...\SillyTavern" all work from this button too.
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%FIX_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
pause
goto :restore_cp

:no_script
echo Missing script: "%FIX_SCRIPT%"
echo Keep Fix-GeminiThinking.ps1 in the same folder as this .cmd file.
pause
set "EXIT_CODE=1"
goto :restore_cp

:no_ps
echo PowerShell not found on this machine.
pause
set "EXIT_CODE=1"
goto :restore_cp

:restore_cp
if defined ORIG_CP chcp %ORIG_CP% >nul 2>nul
endlocal & exit /b %EXIT_CODE%
