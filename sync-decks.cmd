@echo off
rem Resolve a Python interpreter, then hand off to sync_decks.py.
rem
rem Deliberately does NOT trust "python" on PATH: on a machine with no real
rem install that name is the Microsoft Store redirector stub, which opens the
rem Store instead of running anything.
rem
rem Override with MTG_SYNC_PYTHON=<full path to python.exe> if you keep Python
rem somewhere unusual.

setlocal

set "PY="

if defined MTG_SYNC_PYTHON if exist "%MTG_SYNC_PYTHON%" set "PY=%MTG_SYNC_PYTHON%"

for %%V in (316 315 314 313 312 311) do (
    if not defined PY if exist "%LOCALAPPDATA%\Programs\Python\Python%%V\python.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python%%V\python.exe"
    if not defined PY if exist "%ProgramFiles%\Python%%V\python.exe" set "PY=%ProgramFiles%\Python%%V\python.exe"
    if not defined PY if exist "%ProgramFiles(x86)%\Python%%V\python.exe" set "PY=%ProgramFiles(x86)%\Python%%V\python.exe"
)

rem The py launcher, if present, knows about installs in other locations.
if not defined PY if exist "%SystemRoot%\py.exe" set "PY=%SystemRoot%\py.exe"

if not defined PY (
    echo ERROR: No Python interpreter found.
    echo Run bootstrap.ps1 to install one, or set MTG_SYNC_PYTHON to a python.exe.
    exit /b 1
)

"%PY%" "%~dp0sync_decks.py" %*
exit /b %ERRORLEVEL%
