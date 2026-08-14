@echo off
rem ============================================================================
rem  Oasis framework - one-click build & test (Delphi 13 / RAD Studio 37.0)
rem
rem  Builds the runtime packages, both test suites (runs them), and the demos.
rem  Edit the paths below if your Delphi or OmniThreadLibrary lives elsewhere.
rem ============================================================================
setlocal

set "DCC=C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.EXE"
set "DUX=C:\Program Files (x86)\Embarcadero\Studio\37.0\source\DunitX"
set "OTL=D:\code\awesome-pascal\OmniThreadLibrary"
set "ROOT=%~dp0"
set "NS=-NSWinapi;System;System.Win;Vcl;System.Classes"

set "CORE=%ROOT%src\Oasis.Core"
set "HOSTING=%ROOT%src\Oasis.Hosting"
set "OTLP=%ROOT%src\Oasis.Otl"
set "BPLP=%ROOT%src\Oasis.Bpl"
set "UIP=%ROOT%src\Oasis.UI"
set "BIN=%ROOT%bin"

if exist "%BIN%" rmdir /s /q "%BIN%"
mkdir "%BIN%"

echo.
echo [1/6] Building runtime packages...
pushd "%CORE%" && "%DCC%" -B %NS% -U"%CORE%" -E"%BIN%" Oasis.Core.dpk   || goto :fail
popd
pushd "%HOSTING%" && "%DCC%" -B %NS% -U"%CORE%" -U"%HOSTING%" -U"%BIN%" -E"%BIN%" Oasis.Hosting.dpk || goto :fail
popd
pushd "%OTLP%" && "%DCC%" -B %NS% -U"%CORE%" -U"%OTLP%" -U"%OTL%" -U"%OTL%\src" -U"%BIN%" -E"%BIN%" Oasis.Otl.dpk || goto :fail
popd
pushd "%BPLP%" && "%DCC%" -B %NS% -U"%CORE%" -U"%HOSTING%" -U"%BPLP%" -U"%BIN%" -E"%BIN%" Oasis.Bpl.dpk || goto :fail
popd
pushd "%UIP%" && "%DCC%" -B %NS% -U"%CORE%" -U"%UIP%" -U"%BIN%" -E"%BIN%" Oasis.UI.dpk || goto :fail
popd

echo [2/6] Building + running MVP test suite (Core + Hosting)...
pushd "%ROOT%tests" && "%DCC%" -B -U"%DUX%" Oasis.Tests.dpr || goto :fail
Oasis.Tests.exe
if errorlevel 1 goto :fail
popd

echo [3/6] Building + running OTL test suite...
pushd "%ROOT%tests\otl" && "%DCC%" -B %NS% -U"%DUX%" -U"%OTL%" -U"%OTL%\src" Oasis.Otl.Tests.dpr || goto :fail
Oasis.Otl.Tests.exe
if errorlevel 1 goto :fail
popd

echo [4/6] Building demos...
pushd "%ROOT%demos\ConsoleDemo" && "%DCC%" -B ConsoleDemo.dpr || goto :fail
popd
pushd "%ROOT%demos\OtlDemo" && "%DCC%" -B %NS% -U"%OTL%" -U"%OTL%\src" OasisOtlDemo.dpr || goto :fail
popd

echo [5/6] Building BPL sample plugin (requires Oasis.Core + Oasis.Bpl)...
pushd "%ROOT%samples\BplPlugin" && "%DCC%" -B %NS% -U"%CORE%" -U"%HOSTING%" -U"%BPLP%" -U. SamplePlugin.dpk || goto :fail
popd

echo [6/6] Building BPL host demo (uses rtl.bpl - run it with the Oasis .bpl dirs on PATH)...
pushd "%ROOT%demos\BplDemo" && "%DCC%" -B %NS% -LUrtl BplDemo.dpr || goto :fail
popd

echo.
echo ALL GREEN - packages in bin\, tests passed, demos built.
exit /b 0

:fail
echo.
echo BUILD FAILED - see errors above.
exit /b 1
