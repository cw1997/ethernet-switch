@echo off
setlocal
rem ============================================================================
rem  build.bat - one-shot Quartus II compile of the DE2-115 board project.
rem
rem  usage:
rem    build.bat              auto-detect a Quartus installation and run the
rem                           full compile flow (map / fit / asm / sta)
rem    build.bat <quartus>    use this Quartus installation root - the folder
rem                           that contains bin64\quartus_sh.exe, for example
rem                               build.bat C:\altera\13.1\quartus
rem                           an install root one level up (C:\altera\13.1)
rem                           also works.  An explicit path is trusted as-is.
rem    build.bat clean        delete every build product this flow creates
rem
rem  requires: Quartus II 13.0sp1 / 13.1 Web Edition, or any Quartus up to
rem  18.1, with the Cyclone IV E device library installed (see README.md).
rem
rem  Output is plain ASCII on purpose: batch files run under whatever code page
rem  the console has, and the explanations live in README.md anyway.
rem ============================================================================

set "PROJECT=ethernet_switch"

if /i "%~1"=="clean" goto clean
if /i "%~1"=="help"  goto usage
if /i "%~1"=="/h"    goto usage
if "%~1"=="-h"       goto usage

rem ---- locate quartus_sh.exe -------------------------------------------------
rem  An auto-detected candidate must have BOTH quartus_sh.exe and a Cyclone IV
rem  device library; a Quartus without devices passes the first check and then
rem  fails minutes into the fitter with "device not supported", which is a
rem  worse error message than the one this script prints instead.
set "QROOT="
set "QSH="

if not "%~1"=="" (
  set "QROOT=%~1"
  goto have_root
)

if defined QUARTUS_ROOTDIR call :try_root "%QUARTUS_ROOTDIR%" 0

if not defined QROOT (
  for %%B in (altera altera_lite intelFPGA intelFPGA_lite) do (
    for /d %%V in ("C:\%%B\*") do (
      if not defined QROOT call :try_root "%%~fV\quartus" 0
    )
  )
)

if not defined QROOT goto not_found

:have_root
rem  Resolve quartus_sh.exe under the root: bin64 (64-bit installs) first,
rem  then bin, then one level up via a quartus\ child folder.
if not defined QSH if exist "%QROOT%\bin64\quartus_sh.exe" set "QSH=%QROOT%\bin64\quartus_sh.exe"
if not defined QSH if exist "%QROOT%\bin\quartus_sh.exe"   set "QSH=%QROOT%\bin\quartus_sh.exe"
if not defined QSH if exist "%QROOT%\quartus\bin64\quartus_sh.exe" (
  set "QSH=%QROOT%\quartus\bin64\quartus_sh.exe"
  set "QROOT=%QROOT%\quartus"
)
if not defined QSH if exist "%QROOT%\quartus\bin\quartus_sh.exe" (
  set "QSH=%QROOT%\quartus\bin\quartus_sh.exe"
  set "QROOT=%QROOT%\quartus"
)
if not defined QSH (
  echo ERROR: no quartus_sh.exe under "%QROOT%" - expected bin64\ or bin\.
  exit /b 2
)

set "QUARTUS_ROOTDIR=%QROOT%"
set "PATH=%QROOT%\bin64;%QROOT%\bin;%PATH%"

echo ============================================================
echo  Quartus : %QSH%
echo  Project : %PROJECT%.qpf  ^(DE2-115, EP4CE115F29C7, MII 2x100M^)
echo  Flow    : quartus_sh --flow compile %PROJECT%
echo ============================================================
echo.

cd /d "%~dp0"
"%QSH%" --flow compile %PROJECT%
if errorlevel 1 goto fail

echo.
echo ============================================================
echo  BUILD PASS
echo    output_files\%PROJECT%.sof     programming file
echo    output_files\%PROJECT%.sta.rpt timing summary
echo ============================================================
exit /b 0

:fail
echo.
echo ============================================================
echo  BUILD FAIL - exit code %errorlevel%
echo  Check output_files\*.rpt and output_files\%PROJECT%.flow.rpt;
echo  the first "Error:" line in the .map/.fit report names the cause.
echo ============================================================
exit /b 1

:clean
cd /d "%~dp0"
echo Cleaning Quartus build products in %CD% ...
for %%D in (db incremental_db output_files greybox_tmp) do (
  if exist "%%D" rmdir /s /q "%%D"
)
for %%F in (*.qws *.jdi *.rpt *.smsg *.summary *.done *.srf *.bak) do (
  if exist "%%F" del /q "%%F"
)
echo done.
exit /b 0

rem ---------------------------------------------------------------------------
rem  :try_root <candidate-quartus-root> <trust:0|1>
rem  Sets QROOT/QSH when the candidate is usable.  trust=1 (an explicit user
rem  path or $QUARTUS_ROOTDIR) skips the device-library check.
rem ---------------------------------------------------------------------------
:try_root
if defined QROOT goto :eof
if not exist "%~1" goto :eof
if exist "%~1\bin64\quartus_sh.exe" set "QSH=%~1\bin64\quartus_sh.exe"
if not defined QSH if exist "%~1\bin\quartus_sh.exe" set "QSH=%~1\bin\quartus_sh.exe"
if not defined QSH goto :eof
if "%~2"=="1" (
  set "QROOT=%~1"
  goto :eof
)
set "DEVOK="
if exist "%~1\devices\cycloneive"  set "DEVOK=1"
if not defined DEVOK if exist "%~1\devices\cycloneiv"  set "DEVOK=1"
if not defined DEVOK if exist "%~1\devices\cycloneivg" set "DEVOK=1"
if not defined DEVOK (
  echo [skip] %~1 - no Cyclone IV device library installed
  goto :eof
)
set "QROOT=%~1"
goto :eof

:not_found
echo.
echo ERROR: no usable Quartus installation found.
echo.
echo Looked in QUARTUS_ROOTDIR (if set) and the version folders under
echo C:\altera, C:\altera_lite, C:\intelFPGA and C:\intelFPGA_lite.
echo A candidate counts as usable when it has bin64\quartus_sh.exe (or bin\)
echo AND a Cyclone IV device library (devices\cycloneive).  Quartus 19.1 and
echo later dropped Cyclone IV E entirely; use Quartus II 13.0sp1 / 13.1 Web
echo Edition, or Quartus Prime up to 18.1, with the Cyclone IV E devices
echo installed - or pass the install root explicitly:
echo.
echo     build.bat C:\altera\13.1\quartus
echo.
exit /b 2

:usage
echo build.bat [clean ^| help ^| ^<quartus_root^>]
echo   (no argument)   auto-detect Quartus and compile the project
echo   clean           remove db\, incremental_db\, output_files\, reports
echo   ^<quartus_root^>  e.g. C:\altera\13.1\quartus - skips auto-detection
exit /b 0
