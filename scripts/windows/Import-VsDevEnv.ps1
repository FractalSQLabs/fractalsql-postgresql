<#
.SYNOPSIS
    Import the Visual Studio 2022 x64 dev environment into the CURRENT
    PowerShell session (cl.exe, link.exe, dumpbin.exe on PATH, INCLUDE/LIB
    set, etc.).

.DESCRIPTION
    IDE-integrated terminals (VS Code, etc.) are a separate, persistent
    PowerShell process from any standalone "Developer Command Prompt"
    window you may have opened elsewhere -- they never inherit its
    environment. This script runs vcvars64.bat in a child cmd.exe, captures
    the resulting environment, and applies it to THIS session.

    Environment variables in PowerShell are process-wide (unlike regular
    $variables, which are scope-limited) -- so this works whether you dot-
    source it (". .\Import-VsDevEnv.ps1") or just run it
    (".\Import-VsDevEnv.ps1"). Dot-sourcing is shown in the example below
    as the conventional way to signal "this modifies my current session,"
    but it is not required for correctness here.

.EXAMPLE
    PS> . .\scripts\windows\Import-VsDevEnv.ps1
    PS> cl.exe          # should now print the MSVC banner
#>

$ErrorActionPreference = 'Stop'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found at $vswhere -- is Visual Studio Installer present?"
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    Write-Warning "No VS install found with the C++ workload via -requires filter; retrying without it."
    $vsPath = & $vswhere -latest -products * -property installationPath
}
if (-not $vsPath) {
    throw "vswhere found no Visual Studio installation at all. Install VS 2022 (or Build Tools) with the 'Desktop development with C++' workload."
}
$vsPath = $vsPath.Trim()
Write-Host "[Import-VsDevEnv] VS install: $vsPath"

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    throw "vcvars64.bat not found at $vcvars -- the C++ workload may not be installed."
}
Write-Host "[Import-VsDevEnv] Running: $vcvars"

$envDump = cmd /c "`"$vcvars`" && set"
$applied = 0
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item -Path "env:\$($Matches[1])" -Value $Matches[2]
        $applied++
    }
}
Write-Host "[Import-VsDevEnv] Applied $applied environment variables."

$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if ($cl) {
    Write-Host "[Import-VsDevEnv] cl.exe found: $($cl.Source)" -ForegroundColor Green
} else {
    throw "cl.exe still not on PATH after import -- something went wrong."
}
