@echo off
rem SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
rem SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
rem
rem mcp\scripts\windows\build-asan.bat: the sanitizer leg of the MCP server on
rem Windows: the SAME tree and the same link posture as build.bat (libpq +
rem x64-windows-static OpenSSL), but driven by the VS toolchain's clang-cl
rem with -fsanitize=address (native cl.exe has no ASan support; clang-cl is
rem exactly this repo's own precedent -- the harness's UBSan leg builds the C
rem extension with clang-cl for the same reason). Runs through an identical
rem contract as build.bat.
rem
rem Usage: build-asan.bat [output-dir]   (default: dist\windows-mcp-asan in mcp\)

setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set MCP_DIR=%SCRIPT_DIR%..\..
set REPO_DIR=%MCP_DIR%\..
set OUTDIR=%~1
if "%OUTDIR%"=="" set OUTDIR=%MCP_DIR%\dist\windows-mcp-asan

rem Save the caller's VCPKG_ROOT before vcvars64.bat runs -- newer VS
rem versions' vcvars64.bat sets its own VCPKG_ROOT (VS's bundled, usually
rem placeholder-empty vcpkg), clobbering whatever the caller already pointed at a real
rem openssl install.
set INCOMING_VCPKG_ROOT=%VCPKG_ROOT%
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
set VSPATH=
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSPATH=%%i
)
if "%VSPATH%"=="" set VSPATH=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
if not exist "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" (
  echo FATAL: no Visual Studio VC tools found 1>&2
  exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
if not "%INCOMING_VCPKG_ROOT%"=="" set VCPKG_ROOT=%INCOMING_VCPKG_ROOT%

rem clang-cl lives in VS's own LLVM tools dir (the same location the repo's
rem UBSan leg resolves).
set CLANGCL=%VSPATH%\VC\Tools\Llvm\x64\bin\clang-cl.exe
if not exist "%CLANGCL%" set CLANGCL=clang-cl.exe

set OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  set CANDIDATE=%REPO_DIR%\..\vcpkg
  if exist "!CANDIDATE!\installed\x64-windows-static\include\openssl\evp.h" set OPENSSL_DIR=!CANDIDATE!\installed\x64-windows-static
)
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  echo FATAL: OpenSSL for MSVC not found: run vcpkg install openssl:x64-windows-static 1>&2
  exit /b 1
)
if "%PGDIR%"=="" (
  set CANDIDATE2=C:\Program Files\PostgreSQL\16
  if exist "!CANDIDATE2!\lib\libpq.lib" set PGDIR=!CANDIDATE2!
)
if not exist "%PGDIR%\lib\libpq.lib" (
  echo PGDIR not set -- point it at the PostgreSQL install root 1>&2
  exit /b 1
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

"%CLANGCL%" -std:c++17 /utf-8 /EHsc /O1 /W3 /DNOMINMAX -fsanitize=address ^
  /I "%MCP_DIR%\vendor" /I "%MCP_DIR%\src" ^
  /I "%OPENSSL_DIR%\include" /I "%PGDIR%\include" ^
  "%MCP_DIR%\src\*.cpp" "%MCP_DIR%\src\adapters\*.cpp" ^
  /Fo"%OUTDIR%\\" ^
  /Fe"%OUTDIR%\fractalsql-postgresql-mcp.exe" ^
  /link /LIBPATH:"%OPENSSL_DIR%\lib" /LIBPATH:"%PGDIR%\lib" ^
  libpq.lib libssl.lib libcrypto.lib ws2_32.lib advapi32.lib user32.lib crypt32.lib
if errorlevel 1 (
  echo FATAL: asan mcp build failed 1>&2
  exit /b 1
)

rem The ASan runtime the exe imports (clang_rt.asan_dynamic-x86_64.dll) must
rem come from the SAME LLVM that compiled the exe. The runtime's thunk-init
rem table is version-specific, so a mismatched runtime aborts the process at
rem startup with "Failed to find sanitizer DLL export '__asan_wrap_...'" and
rem a CHECK failure -- and whichever clang_rt the loader happens to find on
rem PATH wins, which on a build box with several LLVM installs is the wrong
rem one. Ship the matching runtime beside the exe: the exe's own directory
rem is searched before PATH, so the load is deterministic. Same
rem "travels with the binary" rule the committed MCP lock files follow.
set "RESDIR="
for /f "usebackq tokens=*" %%d in (`"%CLANGCL%" -print-resource-dir`) do set "RESDIR=%%d"
if defined RESDIR (
  if exist "!RESDIR!\lib\windows\clang_rt.asan_dynamic-x86_64.dll" (
    copy /y "!RESDIR!\lib\windows\clang_rt.asan_dynamic-x86_64.dll" "%OUTDIR%\" >nul
  ) else (
    echo WARN: no asan runtime DLL under "!RESDIR!\lib\windows" -- the exe will load whatever clang_rt.asan_dynamic-x86_64.dll is first on PATH 1>&2
  )
)
echo asan mcp build OK: %OUTDIR%\fractalsql-postgresql-mcp.exe
endlocal
exit /b 0