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
pushd "%ROOT%demos\CascadeDemo" && "%DCC%" -B CascadeDemo.dpr || goto :fail
popd
pushd "%ROOT%demos\ConfigDemo" && "%DCC%" -B ConfigDemo.dpr || goto :fail
popd
pushd "%ROOT%demos\WaterfallDemo" && "%DCC%" -B WaterfallDemo.dpr || goto :fail
popd
pushd "%ROOT%demos\UiMarshalDemo" && "%DCC%" -B UiMarshalDemo.dpr || goto :fail
popd

echo [5/6] Building BPL sample plugin (requires Oasis.Core + Oasis.Bpl)...
pushd "%ROOT%samples\BplPlugin" && "%DCC%" -B %NS% -U"%CORE%" -U"%HOSTING%" -U"%BPLP%" -U. SamplePlugin.dpk || goto :fail
popd

echo [6/6] Building BPL host demo (uses rtl.bpl - run it with the Oasis .bpl dirs on PATH)...
pushd "%ROOT%demos\BplDemo" && "%DCC%" -B %NS% -LUrtl BplDemo.dpr || goto :fail
popd

echo [+] Building VCL host demo (plugin-manager GUI, -LUrtl -LUvcl)...
pushd "%ROOT%demos\VclHostDemo" && "%DCC%" -B %NS% -LUrtl -LUvcl HostApp.dpr || goto :fail
popd
pushd "%ROOT%samples\VclBplPlugin" && "%DCC%" -B %NS% -U"%CORE%" -U"%HOSTING%" -U"%BPLP%" -U"%BIN%" -U. VclBplPlugin.dpk || goto :fail
popd

echo [+] Building Oasis Showroom (six-scenario Cordis showcase GUI) + selftest...
pushd "%ROOT%demos\VclShowroom" && "%DCC%" -B %NS% -LUrtl -LUvcl Showroom.dpr || goto :fail
Showroom.exe /selftest
if errorlevel 1 goto :fail
type vclshowroom_selftest.txt
popd

set "MORMOT=D:\code\awesome-pascal\mormot2"

echo [+] Building + running mORMot bridge tests + demo (SKIP when mormot2 absent)...
if not exist "%MORMOT%\src\core\mormot.core.interfaces.pas" (
  echo SKIP: mormot2 not found at %MORMOT% - bridge not built
  goto :mormot_done
)
pushd "%ROOT%tests\mormot" && "%DCC%" -B %NS% -U"%DUX%" -U"%CORE%" -U"%HOSTING%" -U"%MORMOT%\src\core" -U"%MORMOT%\src\soa" -U"%MORMOT%\static" Oasis.Mormot.Tests.dpr || goto :fail
Oasis.Mormot.Tests.exe
if errorlevel 1 goto :fail
popd
pushd "%ROOT%demos\MormotBridgeDemo" && "%DCC%" -B %NS% -U"%MORMOT%\src\core" -U"%MORMOT%\src\soa" -U"%MORMOT%\static" MormotBridgeDemo.dpr || goto :fail
popd
:mormot_done

echo.
echo ALL GREEN - packages in bin\, tests passed, demos built.
exit /b 0

:fail
echo.
echo BUILD FAILED - see errors above.
exit /b 1
