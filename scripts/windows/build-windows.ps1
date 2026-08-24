<#
.SYNOPSIS
    Build fractalsql.dll (the PostgreSQL extension) for Windows x64 with MSVC.

.DESCRIPTION
    Pure-C Windows build (the successor to the legacy LuaJIT build.bat).
    Compiles src\fractalsql.c and STATICALLY LINKS the vendored
    FractalSQL core archive (include\windows-x86_64\fractalsql-<variant>.lib).
    No LuaJIT.

    Static posture, matching the Linux build and the vendored .lib:
      /MT  static CRT  (no VCRUNTIME/MSVCP DLL dependency)
      the core .lib is embedded; the reasoning plugin is loaded at
      runtime via LoadLibrary (fsql_load_reasoning), not linked here.

    Deliberately NOT using /GL /LTCG: confirmed by A/B testing (2026-08-23)
    to cause a real MSVC LTCG miscompilation -- STATUS_STACK_BUFFER_OVERRUN
    inside fsql_ledger_flush(), 100% reproducible with /GL, gone without it.
    Not a source bug on either side. See tests\windows\repro_enterprise_ledger_crash.c
    for the repro.

    Output: dist\windows\pg<major>\fractalsql.dll (stamped for one PG major).

    Prerequisites:
      * Visual Studio 2022 (Build Tools or Community, Desktop C++ workload).
        Run this from an "x64 Native Tools Command Prompt for VS 2022"
        (so cl.exe / link.exe / dumpbin.exe are on PATH), or launch
        PowerShell after sourcing vcvars64.bat.
      * A PostgreSQL server tree for the target major with:
            <PgDir>\include\server\postgres.h
            <PgDir>\lib\postgres.lib
            <PgDir>\lib\libcrypto.lib   (ships with any SSL-enabled build,
                                         which is the EDB default -- needed
                                         for fractalsql.c's enterprise-.so
                                         Ed25519 signature check)
        An EDB install root (C:\Program Files\PostgreSQL\<major>) works, as
        does the unpacked EDB "...-windows-x64-binaries.zip" (pgsql root).
      * The vendored core .lib present under include\windows-x86_64\
        (a vendored artifact).

.PARAMETER PgDir
    PostgreSQL server tree (EDB install root or unpacked binaries.zip).

.PARAMETER PgMajor
    Target PostgreSQL major (14-18). Stamps PG_MODULE_MAGIC; the DLL loads
    only under a server of this major.

.PARAMETER CoreVariant
    Vendored core archive to link. Default community-sovereign-c (search +
    reasoning surface). Use community-minimal-c for search-only.

.PARAMETER OutputDir
    Output directory. Default: <repo>\dist\windows\pg<major>.

.PARAMETER SkipAudit
    Skip the dumpbin export/dependency audit.

.EXAMPLE
    PS> .\scripts\windows\build-windows.ps1 -PgDir "C:\Program Files\PostgreSQL\17" -PgMajor 17

.NOTES
    Reasoning caveat (not a build issue): the reasoning plugin DLL is built
    /MD and mallocs its response; the core embedded here is /MT. If you test
    fractal_reason(), watch for a cross-CRT free -- search is unaffected.

    The text-to-sql allowlist uses the backend's own raw_parser() (in
    postgres.lib). Do NOT reintroduce libpg_query -- an earlier revision
    statically linked it and it corrupted the DLL's load-time state on
    Windows, crashing every function in the extension.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgDir,
    [Parameter(Mandatory = $true)][ValidateSet('14', '15', '16', '17', '18')][string]$PgMajor,
    [string]$CoreVariant = 'community-sovereign-c',
    [string]$OutputDir,
    [switch]$SkipAudit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)   # scripts\windows -> repo

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "cl.exe not found on PATH. Open an 'x64 Native Tools Command Prompt " +
          "for VS 2022' (or source vcvars64.bat) and run this from there."
}

$PgDir = (Resolve-Path $PgDir).Path
$PgLib = Join-Path $PgDir 'lib\postgres.lib'
$PgServerInc = Join-Path $PgDir 'include\server'
if (-not (Test-Path $PgLib)) {
    throw "postgres.lib not found at $PgLib`n" +
          "  Point -PgDir at a PostgreSQL $PgMajor install root or unpacked EDB binaries tree."
}
if (-not (Test-Path (Join-Path $PgServerInc 'postgres.h'))) {
    throw "$PgServerInc\postgres.h not found - is -PgDir a PostgreSQL server tree?"
}

# libcrypto.lib: ent_verify_signature() in fractalsql.c (Ed25519 detached-
# signature check on the optional enterprise .so before dlopen -- see
# ensure_enterprise_lib()) calls OpenSSL's EVP API. On Linux this links
# fine with those symbols left UNDEFINED in fractalsql.so -- ELF shared
# objects tolerate that, and the symbols resolve at dlopen() time against
# the postgres backend's own already-loaded libcrypto.so (every real PG
# build is --with-openssl). Windows PE .dlls have no equivalent lazy
# resolution -- MSVC's linker requires every imported symbol satisfied by
# an explicit import library at link time, so we need libcrypto.lib here
# even though, at runtime, this resolves the exact same way Linux's does:
# against the copy of OpenSSL Postgres itself already ships and loads
# (libcrypto-3-x64.dll sits in <PgDir>\bin\ on any EDB install with SSL
# support, which is the default). No new runtime dependency is introduced
# by this -- Postgres on Windows already requires it for itself.
$CryptoLib = Join-Path $PgDir 'lib\libcrypto.lib'
if (-not (Test-Path $CryptoLib)) {
    throw "libcrypto.lib not found at $CryptoLib`n" +
          "  This ships with any EDB PostgreSQL install/binaries tree built " +
          "with SSL support (the default). If it's genuinely absent, " +
          "OpenSSL needs to be available at build time some other way " +
          "(e.g. vcpkg) -- fractalsql.c's enterprise-.so signature check " +
          "needs it."
}

$CoreLib = Join-Path $RepoRoot "include\windows-x86_64\fractalsql-$CoreVariant.lib"
if (-not (Test-Path $CoreLib)) {
    throw "vendored core library not found: $CoreLib`n" +
          "  Re-run the vendored-artifact deploy step."
}

# No libpg_query -- text-to-sql's allowlist uses the backend's own
# raw_parser() (in postgres.lib, linked below). See the .NOTES header
# comment for why libpg_query must not be reintroduced.

$Src = Join-Path $RepoRoot 'src\fractalsql.c'
# fsql_extract_best_point / fsql_parse_embedding_array /
# fsql_extract_population live here, not in fractalsql.c -- factored out
# into their own postgres.h-free translation unit so a libFuzzer driver
# can link them standalone on Linux (see src/fractalsql_parse.h's header
# comment). fractalsql.c calls them via #include "fractalsql_parse.h";
# both .c files must be compiled and linked together on every platform,
# same as the Linux Makefile's OBJS now lists both src/fractalsql.o and
# src/fractalsql_parse.o.
$SrcParse = Join-Path $RepoRoot 'src\fractalsql_parse.c'
# fractal_vector type I/O, typmod, casts, distance operators -- the third
# translation unit the Linux Makefile's OBJS lists (src/fractalsql_vector.o).
# Calls core's fsql_vector_* (vendored header) for the float32 distance/arith
# ops; its PG_FUNCTION_INFO_V1 symbols are resolved at CALL time via
# MODULE_PATHNAME, so omitting it never broke the link -- but without it the
# fractal_vector type's functions are absent from the DLL and fail at first
# use ("could not find function fractal_vector_in"). Compile it on Windows
# too, matching the Makefile.
$SrcVector = Join-Path $RepoRoot 'src\fractalsql_vector.c'
$Inc = Join-Path $RepoRoot 'include'

if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot "dist\windows\pg$PgMajor" }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$FractalsqlObj = Join-Path $OutputDir 'fractalsql.obj'
$FractalsqlParseObj = Join-Path $OutputDir 'fractalsql_parse.obj'
$FractalsqlVectorObj = Join-Path $OutputDir 'fractalsql_vector.obj'
$Dll = Join-Path $OutputDir 'fractalsql.dll'

Write-Host "[build-windows] PG major   = $PgMajor"
Write-Host "[build-windows] PgDir      = $PgDir"
Write-Host "[build-windows] core lib   = $CoreLib"
Write-Host "[build-windows] output     = $Dll"

# PostgreSQL's Windows server headers require this include order:
#   port\win32_msvc  (compiler shims) -> port\win32 (platform shims)
#   -> server (core headers) -> include (client headers). Wrong order
# yields "redefinition of struct timezone" and similar.
$commonCompileArgs = @(
    '/nologo', '/MT', '/O2', '/c',
    '/DWIN32', '/D_WINDOWS', '/D_CRT_SECURE_NO_WARNINGS',
    # FSQL_STATIC: switches fractalsql.h's FSQL_API macro from the default
    # dllimport (consumer-of-a-DLL mode) to a plain extern, matching the
    # vendored static .lib we link below (see include/fractalsql.h:82-91).
    # Without this the compiler emits __imp_fsql_* references that only an
    # import library (fractalsql-*-import.lib, the .dll's companion) would
    # satisfy -- the static .lib has plain fsql_* symbols, not __imp_ thunks.
    '/DFSQL_STATIC',
    "/I$(Join-Path $PgServerInc 'port\win32_msvc')",
    "/I$(Join-Path $PgServerInc 'port\win32')",
    "/I$PgServerInc",
    "/I$(Join-Path $PgDir 'include')",
    "/I$Inc"
)

# Compile-only (/c) to an explicitly named .obj, not a directory-form
# /Fo (trailing backslash). The directory form breaks when $OutputDir
# contains a space: PowerShell quotes the argument, and a path ending
# in \ before the closing " is parsed by MSVC as an escaped quote (\"
# -> literal "), so the quoting never closes and swallows the next
# argument (D8036). An explicit single-file .obj name sidesteps it.
Write-Host "[build-windows] cl.exe (compile fractalsql.c) $($commonCompileArgs -join ' ') /Fo$FractalsqlObj $Src"
& cl.exe @commonCompileArgs "/Fo$FractalsqlObj" $Src
if ($LASTEXITCODE -ne 0) { throw "cl.exe failed compiling fractalsql.c (exit $LASTEXITCODE)" }

# Same commonCompileArgs as fractalsql.c above (the postgres include
# paths / /DFSQL_STATIC are simply unused by this postgres.h-free file,
# harmless to pass) -- matches the Linux Makefile applying the same
# PG_CPPFLAGS uniformly to both OBJS rather than a separate minimal
# flag set for this TU.
Write-Host "[build-windows] cl.exe (compile fractalsql_parse.c) $($commonCompileArgs -join ' ') /Fo$FractalsqlParseObj $SrcParse"
& cl.exe @commonCompileArgs "/Fo$FractalsqlParseObj" $SrcParse
if ($LASTEXITCODE -ne 0) { throw "cl.exe failed compiling fractalsql_parse.c (exit $LASTEXITCODE)" }

# fractalsql_vector.c uses the SAME $commonCompileArgs as the other two TUs
# (it #includes "postgres.h" and calls fsql_vector_* from the vendored header,
# so it needs the PG include paths + /DFSQL_STATIC), exactly as fractalsql.c
# does. Same rationale as fractalsql_parse.c sharing the flag set.
Write-Host "[build-windows] cl.exe (compile fractalsql_vector.c) $($commonCompileArgs -join ' ') /Fo$FractalsqlVectorObj $SrcVector"
& cl.exe @commonCompileArgs "/Fo$FractalsqlVectorObj" $SrcVector
if ($LASTEXITCODE -ne 0) { throw "cl.exe failed compiling fractalsql_vector.c (exit $LASTEXITCODE)" }

# bcrypt.lib: the vendored community-sovereign-c.lib includes
# src/diversify/entropy.c, which calls BCryptGenRandom (the OS entropy
# source) on Windows, so bcrypt.lib must be linked.
# libcrypto.lib: fractalsql.c's ent_verify_signature() (Ed25519 check on
# the optional enterprise .so) calls OpenSSL's EVP API -- see $CryptoLib's
# resolution above for why this is needed and why it adds no new runtime
# dependency.
$linkArgs = @(
    '/nologo', '/LD',
    $FractalsqlObj,
    $FractalsqlParseObj,
    $FractalsqlVectorObj,
    "/Fe$Dll",
    '/link',
    $CoreLib,
    $PgLib,
    $CryptoLib,
    'ws2_32.lib', 'advapi32.lib', 'secur32.lib', 'bcrypt.lib'
)
Write-Host "[build-windows] cl.exe (link) $($linkArgs -join ' ')"
& cl.exe @linkArgs
if ($LASTEXITCODE -ne 0) { throw "cl.exe failed linking $Dll (exit $LASTEXITCODE)" }
if (-not (Test-Path $Dll)) { throw "build did not produce $Dll" }

if (-not $SkipAudit) {
    Write-Host "[build-windows] export audit (dumpbin /exports)"
    $exports = & dumpbin /nologo /exports $Dll | Out-String
    foreach ($sym in @('_PG_init', 'Pg_magic_func')) {
        if ($exports -notmatch [regex]::Escape($sym)) {
            throw "export audit FAILED: '$sym' not exported by $Dll"
        }
    }
    Write-Host "[build-windows]   _PG_init + Pg_magic_func exported OK"

    Write-Host "[build-windows] dependency audit (dumpbin /dependents)"
    $deps = & dumpbin /nologo /dependents $Dll | Out-String
    if ($deps -match '(?i)lua') { throw "LuaJIT dependency leaked into $Dll" }
    if ($deps -match '(?i)(VCRUNTIME|MSVCP|api-ms-win-crt)') {
        Write-Warning "DLL imports a dynamic CRT -- expected /MT static CRT. Review the dependents above."
    }
    Write-Host $deps
}

Write-Host "[build-windows] Built $Dll (PG $PgMajor)"
