@echo off
rem mcp/scripts/windows/build.bat -- mirrors the repo's own
rem scripts\windows\ Windows build story (7.0/7.1: same cl.exe toolchain,
rem same vcpkg x64-windows-static OpenSSL the daemon and extension builds
rem already resolve, plus PgDir's libpq.lib -- no new toolchain, no package
rem manager). Requires cl.exe on PATH first: activate the VS dev env the
rem repo's own build uses (scripts\windows\Import-VsDevEnv.ps1, or
rem scripts\windows\build-windows.ps1 which sources vcvars64.bat), then
rem either run this script or just use build_test.ps1 -Gate 33, which
rem performs this same compile+link with the repo's own obj-dir layout.
setlocal
if "%VCPKG_ROOT%"=="" ( echo VCPKG_ROOT not set & exit /b 1 )
if "%PGDIR%"=="" ( echo PGDIR not set -- point it at the PostgreSQL install root ^(EDB install root or unpacked binaries.zip^) & exit /b 1 )
set "OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static"
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" ( echo OpenSSL x64-windows-static not under %VCPKG_ROOT% & exit /b 1 )
if not exist "%PGDIR%\lib\libpq.lib" ( echo libpq.lib not found at %PGDIR%\lib\libpq.lib & exit /b 1 )

rem /O1 not /O2: the json.hpp-heavy TUs can exhaust the MSVC optimizer heap
rem at /O2 (C1060, E2E-caught in gate 33's own build) -- same workaround the
rem gate uses.
cd /d "%~dp0..\..\.."
if not exist mcp\obj\msvc mkdir mcp\obj\msvc
cl.exe /nologo /std:c++17 /EHsc /O1 /MT /DNOMINMAX ^
    /Imcp\vendor /Imcp\src /I"%OPENSSL_DIR%\include" /I"%PGDIR%\include" ^
    /Fo"mcp\obj\msvc\\" ^
    mcp\src\*.cpp mcp\src\adapters\*.cpp ^
    /Fe:mcp\fractalsql-postgresql-mcp.exe ^
    /link /LIBPATH:"%OPENSSL_DIR%\lib" /LIBPATH:"%PGDIR%\lib" ^
    libpq.lib libssl.lib libcrypto.lib ws2_32.lib advapi32.lib crypt32.lib user32.lib
if errorlevel 1 (
  echo build failed
  exit /b 1
)
rem Regenerate the locks/manifest after any tool-table change (10.5/15.3's
rem same-PR regenerate-and-commit workflow); no-ops the catalog hash otherwise.
mcp\fractalsql-postgresql-mcp.exe --write-schema-lock
mcp\fractalsql-postgresql-mcp.exe --write-safety-annotations-lock
mcp\fractalsql-postgresql-mcp.exe --write-manifest
echo built: mcp\fractalsql-postgresql-mcp.exe ^(+ locks/manifest regenerated^)
endlocal