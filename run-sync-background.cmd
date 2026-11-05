@echo off
rem Run the deck sync and append output to a log. Launched hidden and
rem non-blocking by launch-cockatrice.vbs, so nothing here may prompt or
rem wait on input -- if the sync fails, Cockatrice still starts and the
rem reason lands in the log below.
set "SYNCLOG=%LOCALAPPDATA%\architrice\sync-launch.log"
if not exist "%LOCALAPPDATA%\architrice" mkdir "%LOCALAPPDATA%\architrice"
echo. >> "%SYNCLOG%"
echo ===== %DATE% %TIME% ===== >> "%SYNCLOG%"
call "%~dp0sync-decks.cmd" sync >> "%SYNCLOG%" 2>&1
