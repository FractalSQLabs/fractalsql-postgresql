<#
.SYNOPSIS
    easy_install.ps1: the "easy button" for FractalSQL on Windows. One
    command gets you from a bare Windows box to a running install with
    reasoning configured. PowerShell counterpart to scripts/easy_install.sh
    (Linux/macOS); same design, same GUCs, Windows-native underneath.

.DESCRIPTION
    Detects an installed PostgreSQL (registry, or -PgDir for a manual
    override). This covers postgresql.org's own two Windows install
    paths: the EDB interactive installer, and the no-registry ZIP archive.
    Offers to install the matching .msi if missing. Runs the same
    reasoning-provider wizard as easy_install.sh: activates the
    extension, configures fractalsql.* GUCs, offers a cold-start
    timeout fix for slow local Ollama models, and runs a smoke test.

    No telemetry. This script never reports usage, provider choice, or
    success or failure anywhere. That's deliberate, matching FractalSQL's
    own "sovereign reasoning" positioning: your infra choices stay yours.

    Never DROP EXTENSION without -ForceReinstall. Re-running the wizard
    (no -ForceReinstall) is the normal way to change providers or models.
    It only overwrites GUC values and reloads.

.PARAMETER PgDir
    Top-level PostgreSQL install directory, e.g. "C:\Program Files\PostgreSQL\17".
    Same convention as build_test.ps1's own -PgDir. Optional. When
    given, skips registry auto-detection and uses this directly. Also
    the only way to target a ZIP-archive install (no registry entry).

.PARAMETER PgMajor
    Target PG major (14-18) when several are detected, or to validate
    against -PgDir.

.PARAMETER Port
    Override the auto-detected port if it guessed wrong.

.PARAMETER PgPassword
    Password for the postgres role. The EDB Windows installer sets up
    password auth by default (unlike the Linux/macOS trust/peer setups
    easy_install.sh usually meets), so this is asked for once and
    cached for the rest of the run if not supplied here or already in
    $env:PGPASSWORD.

.PARAMETER Provider
    ollama | openai-compatible | skip

.PARAMETER Yes
    Pre-confirm every prompt (needed for CI/non-interactive use).

.PARAMETER NoInstall
    Don't offer to install a missing .msi.

.PARAMETER DryRun
    Print what would happen, change nothing.

.PARAMETER ForceReinstall
    Allow DROP+CREATE EXTENSION on a version mismatch.

.PARAMETER Uninstall
    Reverse everything this script can set up.

.PARAMETER Version
    Package version to install. Defaults to this script's own embedded
    version.

.EXAMPLE
    .\easy_install.ps1
    .\easy_install.ps1 -PgDir "C:\Program Files\PostgreSQL\17" -PgMajor 17 -Provider ollama -Yes
#>

param(
    [string]$PgDir,
    [ValidateSet('14', '15', '16', '17', '18')][string]$PgMajor,
    [int]$Port,
    [string]$PgPassword,
    [ValidateSet('ollama', 'openai-compatible', 'skip')][string]$Provider,
    [string]$Url,
    [string]$Model,
    [string]$Token,
    [string]$EmbedUrl,
    [string]$EmbedModel,
    [string]$Think,
    [string]$ThinkProvider,
    [switch]$Yes,
    [switch]$NoInstall,
    [switch]$DryRun,
    [switch]$ForceReinstall,
    [switch]$Uninstall,
    [string]$Version
)

$ErrorActionPreference = 'Stop'

# --- version -----------------------------------------------------------
# Stamped in by release.yml at build time (the placeholder below is
# replaced with the tag version before this file is uploaded as a
# release asset). Falls back to reading src/fractalsql.c directly when
# run from a repo checkout during development, matching
# scripts/package-darwin.sh's own VERSION-sourcing pattern and
# easy_install.sh's identical fallback.
$FsqlVersion = '@@FSQL_VERSION@@'
if ($FsqlVersion -eq '@@FSQL_VERSION@@') {
    $srcFile = Join-Path $PSScriptRoot '..\..\src\fractalsql.c'
    if (Test-Path $srcFile) {
        $m = Select-String -Path $srcFile -Pattern '^#define FSQL_VERSION "(.*)"$' | Select-Object -First 1
        if ($m) { $FsqlVersion = $m.Matches[0].Groups[1].Value }
    }
}
if (-not $Version) { $Version = $FsqlVersion }
if (-not $Version) { throw "could not determine a version to install. Pass -Version X.Y.Z" }

$Repo = 'FractalSQLabs/fractalsql-postgresql'

# --- output helpers ------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor White }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Die   { param([string]$Msg) Write-Host "  [X] $Msg" -ForegroundColor Red; exit 1 }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Doubles any single quote in a value before it goes inside a SQL string
# literal. Values here come from user input (a URL, a model name, a
# token), and a literal quote in one of them would otherwise break the
# ALTER SYSTEM SET statement's syntax.
function SqlQuote { param([string]$Value) $Value -replace "'", "''" }

# --- prompting -----------------------------------------------------------
# Unlike `curl | bash`, `iwr ... | iex` does not hijack Read-Host's
# console input the same way piped stdin does in bash. Read-Host talks
# to the console host directly. Still wrapped for a clear error instead
# of an opaque exception in a genuinely non-interactive host (a
# scheduled task, some CI runners), where -Yes / explicit params are
# required instead.
function Confirm-Step {
    param([string]$Question)
    if ($Yes) { Write-Ok "$Question -> yes (-Yes)"; return $true }
    try {
        $reply = Read-Host "$Question [Y/n]"
    } catch {
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass -Yes, or the specific parameter for what you're trying to set."
    }
    return ($reply -eq '' -or $reply -match '^[Yy]')
}

function Prompt-Value {
    param([string]$Question, [string]$Default = '')
    try {
        if ($Default) {
            $reply = Read-Host "$Question [$Default]"
            if (-not $reply) { return $Default }
            return $reply
        } else {
            return Read-Host $Question
        }
    } catch {
        if ($Default) { return $Default }
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass the corresponding parameter."
    }
}

function Prompt-Secret {
    param([string]$Question)
    try {
        $secure = Read-Host $Question -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass -Token."
    }
}

# Resolved once, not per-call. Without this, every single Invoke-Psql
# call below would trigger psql's own native password prompt
# separately. The EDB Windows installer sets up password auth by
# default, unlike the Linux/macOS trust or peer setups easy_install.sh
# usually meets. Setting $env:PGPASSWORD for the rest of this process
# lets every subsequent psql.exe child process (started with
# UseShellExecute=$false, which inherits the parent's environment)
# pick it up automatically with no further prompting. Harmless to set
# even against a trust-auth server, since libpq only consults
# PGPASSWORD if the server actually requests one.
function Resolve-PgPassword {
    if ($env:PGPASSWORD) { return }
    if ($PgPassword) { $env:PGPASSWORD = $PgPassword; return }
    $env:PGPASSWORD = Prompt-Secret "Password for the postgres role"
}

# --- detect ----------------------------------------------------------------
# Recorded as objects: @{ Major; Port; Dir }
function Get-PgInstalls {
    if ($PgDir) {
        if (-not (Test-Path (Join-Path $PgDir 'bin\pg_config.exe'))) {
            Write-Die "-PgDir '$PgDir' doesn't look like a PostgreSQL install (no bin\pg_config.exe)"
        }
        $verOut = & (Join-Path $PgDir 'bin\pg_config.exe') --version
        $major = [regex]::Match($verOut, '^PostgreSQL (\d+)').Groups[1].Value
        $pgPort = Get-PortFor -Major $major -BaseDir $PgDir
        # Write-Output enumerates one level of whatever's handed to
        # `return`, so a single-hashtable array (@(@{...}) or ,@{...},
        # both one level and structurally identical) still collapses
        # back down to the bare hashtable by the time the caller
        # captures it. $installs.Count then reads as the hashtable's
        # own key count instead of the number of installs found. The
        # fix needs two levels: build the real array into a variable
        # first, then comma-prefix that variable. The comma wraps the
        # already-array value one level deeper, which is what survives
        # exactly one level of pipeline flattening.
        $result = @(@{ Major = $major; Port = $pgPort; Dir = $PgDir })
        return ,$result
    }

    # postgresql.org's own two Windows install paths: the EDB interactive
    # installer (registers HKLM:\SOFTWARE\PostgreSQL\Installations\*,
    # Base Directory property) and the no-installer ZIP archive. The ZIP
    # archive leaves no registry entry at all, which is why -PgDir
    # exists above.
    $installs = @()
    $regRoot = 'HKLM:\SOFTWARE\PostgreSQL\Installations'
    if (Test-Path $regRoot) {
        foreach ($key in Get-ChildItem $regRoot -ErrorAction SilentlyContinue) {
            $baseDir = (Get-ItemProperty -Path $key.PSPath -Name 'Base Directory' -ErrorAction SilentlyContinue).'Base Directory'
            if (-not $baseDir) { continue }
            $pgConfig = Join-Path $baseDir 'bin\pg_config.exe'
            if (-not (Test-Path $pgConfig)) { continue }
            $verOut = & $pgConfig --version
            $major = [regex]::Match($verOut, '^PostgreSQL (\d+)').Groups[1].Value
            $pgPort = Get-PortFor -Major $major -BaseDir $baseDir
            $installs += @{ Major = $major; Port = $pgPort; Dir = $baseDir }
        }
    }
    if ($installs.Count -eq 0) {
        Write-Die "no PostgreSQL installation found in the registry. If you installed from the ZIP archive (no installer), pass -PgDir."
    }
    # Same single-item collapse risk as the -PgDir branch above when
    # exactly one registry install is found. The unary comma forces it
    # to survive as a real array.
    return ,$installs
}

# Best-effort real port lookup, same spirit as easy_install.sh's
# detect_port_for(): read the actual `port` setting out of postgresql.conf
# under the install's own data directory, falling back to PostgreSQL's
# compiled-in default (5432) when that can't be determined.
function Get-PortFor {
    param([string]$Major, [string]$BaseDir)
    $conf = Join-Path $BaseDir "data\postgresql.conf"
    if (Test-Path $conf) {
        $m = Select-String -Path $conf -Pattern "^\s*port\s*=\s*'?(\d+)" | Select-Object -Last 1
        if ($m) { return [int]$m.Matches[0].Groups[1].Value }
    }
    return 5432
}

function Select-PgTarget {
    param($Installs)
    if ($PgMajor) {
        # @() here is reliable (unlike the return-boundary case above)
        # because this is a same-scope assignment, not a function
        # return, so there's no Write-Output re-enumeration step in between.
        $match = @($Installs | Where-Object { $_.Major -eq $PgMajor })
        if ($match.Count -eq 0) { Write-Die "PG major $PgMajor not found among detected installs ($($Installs | ForEach-Object { $_.Major } | Join-String -Separator ', '))" }
        return $match[0]
    }
    if ($Installs.Count -eq 1) { return $Installs[0] }
    Write-Step "Found multiple PostgreSQL installs:"
    for ($i = 0; $i -lt $Installs.Count; $i++) {
        Write-Host "  $($i+1)) PG$($Installs[$i].Major) (port $($Installs[$i].Port))"
    }
    $choice = Prompt-Value "Which one? (1-$($Installs.Count), or a PG major like 17)"
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $Installs.Count) {
        return $Installs[[int]$choice - 1]
    }
    $script:PgMajor = $choice
    return Select-PgTarget $Installs
}

# --- psql plumbing -----------------------------------------------------
# ArgumentList (not a raw string) needs no manual argv-escaping, matching
# build_test.ps1's own Psql helper. One statement per call, never
# `-c "A; B"`, since ALTER SYSTEM cannot run inside the implicit
# transaction block that creates, the same hazard documented in both
# build_test.sh and build_test.ps1's PgSetGuc.
# $Sql accepts one statement or an array of statements. Each element
# becomes its own -c flag on one psql.exe invocation, sharing a single
# connection, session, and backend for the whole call. That's required
# whenever a fractalsql.* GUC needs to be set, since those GUCs are
# registered by _PG_init(), which runs lazily per-backend on first
# load. A backend that hasn't loaded the module yet doesn't know the
# GUC name, so ALTER SYSTEM SET on a truly fresh connection can fail
# with "unrecognized configuration parameter". A newly added GUC can
# fail this way even while older GUCs on the same connection happen to
# still work, if leftover postgresql.auto.conf state masks the gap.
# Calling Invoke-Psql once per statement spawns a separate psql.exe
# process each time, a fresh session every time, which is exactly what
# breaks this. Multiple -c flags (not a single -c "A; B") also avoids
# the implicit-transaction-block problem that would otherwise reject
# ALTER SYSTEM, matching the same pattern already used in
# easy_install.sh and install-test.yml.
function Invoke-Psql {
    param([string]$Bin, [int]$PgPort, [string[]]$Sql, [string]$Db = 'postgres')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Bin 'psql.exe'
    $argList = @('-h', '127.0.0.1', '-p', "$PgPort", '-U', 'postgres', '-d', $Db, '-X', '-tA')
    foreach ($s in $Sql) { $argList += @('-c', $s) }
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $errOut = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "psql failed: $errOut" }
    return $out.Trim()
}

function Test-Installed {
    param([string]$PgDirPath)
    return Test-Path (Join-Path $PgDirPath 'share\extension\fractalsql.control')
}

# --- Phase B: install the package (default-on, confirmed) ------------------
function Install-Package {
    param($Target)
    if (Test-Installed $Target.Dir) { return }
    if ($NoInstall) {
        Write-Die "FractalSQL isn't installed for PG$($Target.Major). Grab the matching .msi from https://github.com/$Repo/releases and install it, then re-run this script (or drop -NoInstall)."
    }
    if (-not (Confirm-Step "FractalSQL isn't installed for PG$($Target.Major) yet. Install it now?")) {
        Write-Die "Nothing to do without installing the package first. Re-run without -NoInstall, or install it yourself from https://github.com/$Repo/releases."
    }

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { Write-Die "unsupported architecture (this script and the .msi are x64-only)" }
    $asset = "FractalSQL-PostgreSQL-$($Target.Major)-$Version-$arch.msi"
    $assetUrl = "https://github.com/$Repo/releases/download/v$Version/$asset"
    $tmp = Join-Path $env:TEMP "fsql-easy-install-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $msiPath = Join-Path $tmp $asset
        Write-Step "Downloading $asset..."
        # -UseBasicParsing: without it, older PowerShell/IE-engine
        # configurations throw an interactive "script code might run"
        # Y/N security prompt that sits outside this script's own
        # Confirm-Step/-Yes handling entirely and would silently block
        # a non-interactive run.
        Invoke-WebRequest -Uri $assetUrl -OutFile $msiPath -UseBasicParsing
        Write-Step "msiexec /i `"$msiPath`" /quiet /norestart"
        if (-not $DryRun) {
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msiPath`"", '/quiet', '/norestart') -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "msiexec exited with code $($p.ExitCode)" }
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    Write-Ok "Package installed for PG$($Target.Major)."
}

# --- Phase C: the wizard -----------------------------------------------
# A cold-loading local model can take minutes to answer, longer than
# the reasoning-http plugin's default CURLOPT_TIMEOUT_MS and slowloris
# window. These are process env vars, not fractalsql.* GUCs, read once
# at plugin init, so a real service restart is needed. Windows has no
# equivalent of a plain environment file: a Windows Service's
# environment lives in the registry
# (HKLM:\SYSTEM\CurrentControlSet\Services\<service>\Environment, a
# REG_MULTI_SZ value), set here via Set-ItemProperty, then
# Restart-Service. Values match docker-compose.yml's own
# FSQL_REASONING_HTTP_TIMEOUT_MS=330000 / _LOW_SPEED_SECS=300 and
# docs/reasoning-setup.md's "Handling Constrained Hardware" section.
function Invoke-ColdStartTimeoutOffer {
    param($Target)
    $serviceName = "postgresql-x64-$($Target.Major)"
    if (-not (Confirm-Step "Local models can be slow to answer the first time while they load into memory. Raise the reasoning HTTP timeout to handle that? This needs a PostgreSQL service restart, which drops active connections, not just a reload.")) {
        return
    }
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warn2 "expected service '$serviceName' not found. Skipping (unusual Windows PG install?)."
        return
    }
    $envValues = @('FSQL_REASONING_HTTP_TIMEOUT_MS=330000', 'FSQL_REASONING_HTTP_LOW_SPEED_SECS=300')
    Write-Step "Writing service environment for '$serviceName':"
    $envValues | ForEach-Object { Write-Host "  $_" }
    if ($DryRun) {
        Write-Step "(-DryRun: not actually writing or restarting)"
        return
    }

    # Ask about the restart BEFORE doing any elevated work, so a single
    # elevated child process (one UAC prompt, if needed) can do the write
    # and the restart together instead of popping UAC twice.
    $doRestart = Confirm-Step "Restart the PostgreSQL service now to apply it?"

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    $quotedValues = ($envValues | ForEach-Object { "'$_'" }) -join ','
    $elevatedCmd = "Set-ItemProperty -Path '$regPath' -Name Environment -Value @($quotedValues) -Type MultiString"
    if ($doRestart) { $elevatedCmd += "; Restart-Service -Name '$serviceName' -Force" }

    # Writing a service's Environment value lives under HKLM\SYSTEM, which
    # is protected even for a member of Administrators unless the process
    # itself is elevated. A non-elevated `pwsh` process hits "Requested
    # registry access is not allowed" here even when the account itself
    # is an admin. Rather than requiring the caller to already know to
    # relaunch the whole script as Administrator, this self-elevates
    # just this one step: Windows pops its normal UAC consent prompt
    # once, the same way a single `sudo` prompt works on Linux.
    if (Test-IsAdmin) {
        try {
            Invoke-Expression $elevatedCmd
        } catch {
            Write-Warn2 "Could not write the service environment ($($_.Exception.Message)). Set those two values by hand and restart $serviceName, or skip this and rely on the default timeout."
            return
        }
    } elseif ([Environment]::UserInteractive) {
        Write-Step "This needs administrator access. Windows will show a permission prompt. Accept it to continue."
        try {
            $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $elevatedCmd)
            if ($p.ExitCode -ne 0) { throw "elevated step exited with code $($p.ExitCode)" }
        } catch {
            Write-Warn2 "Couldn't complete this as administrator ($($_.Exception.Message)). Set FSQL_REASONING_HTTP_TIMEOUT_MS=330000 and FSQL_REASONING_HTTP_LOW_SPEED_SECS=300 by hand under $regPath and restart $serviceName yourself, or re-run this whole script from an Administrator PowerShell to skip the extra prompt."
            return
        }
    } else {
        # No desktop session to click a UAC prompt on: a genuinely
        # unattended run. Don't pop one and hang; just say so.
        Write-Warn2 "Skipping: this needs administrator access and there's no interactive session to grant it in. Set FSQL_REASONING_HTTP_TIMEOUT_MS=330000 and FSQL_REASONING_HTTP_LOW_SPEED_SECS=300 by hand under $regPath and restart $serviceName, or re-run this whole script from an Administrator PowerShell."
        return
    }

    if ($doRestart) {
        Write-Ok "$serviceName restarted with a longer reasoning timeout."
    } else {
        Write-Ok "Environment written."
        Write-Warn2 "Not restarted. The longer timeout won't take effect until you run: Restart-Service $serviceName (as Administrator)"
    }
}

function Invoke-Wizard {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $pgPort = if ($Port) { $Port } else { $Target.Port }
    Resolve-PgPassword

    Write-Step "Activating the extension in database 'postgres' on PG$($Target.Major)..."
    $extver = ''
    try { $extver = Invoke-Psql $bin $pgPort "SELECT extversion FROM pg_extension WHERE extname='fractalsql';" } catch {}
    $stale = $false
    if ($extver) {
        if ($extver -ne '1.0') {
            $stale = $true
        } else {
            # extversion alone can't detect staleness: this project's SQL
            # extension version is permanently fixed at 1.0 (the real
            # version lives in fractal_version() itself), so a
            # same-version-but-older-content install, for example one
            # left over from working on this repo directly before this
            # script existed, sails right past an extversion check.
            # CREATE EXTENSION IF NOT EXISTS would then silently no-op
            # against it, leaving stale catalog objects that are missing
            # fractal_version(). Check for the function directly instead.
            $hasFn = ''
            try { $hasFn = Invoke-Psql $bin $pgPort "SELECT 1 FROM pg_proc WHERE proname = 'fractal_version';" } catch {}
            if (-not $hasFn) { $stale = $true }
        }
    }
    if ($stale) {
        if (-not $ForceReinstall) {
            Write-Die "fractalsql is already CREATE EXTENSION'd here but looks stale or foreign (version '$extver', fractal_version() missing or unexpected). Re-run with -ForceReinstall to drop and recreate it fresh, only after checking nothing depends on it (see docs/reasoning-setup.md)."
        }
        Write-Warn2 "Dropping existing fractalsql extension (-ForceReinstall)..."
        if (-not $DryRun) { Invoke-Psql $bin $pgPort "DROP EXTENSION IF EXISTS fractalsql_agents, fractalsql;" | Out-Null }
    }
    if (-not $DryRun) {
        Invoke-Psql $bin $pgPort "CREATE EXTENSION IF NOT EXISTS fractalsql;" | Out-Null
        Invoke-Psql $bin $pgPort "CREATE EXTENSION IF NOT EXISTS fractalsql_agents;" | Out-Null
    }
    Write-Ok "fractalsql + fractalsql_agents extensions active."

    if (-not $Provider) {
        Write-Step "Reasoning provider:"
        Write-Host "  1) Local Ollama"
        Write-Host "  2) Cloud / OpenAI-compatible endpoint"
        Write-Host "  3) Skip: search-only install, configure reasoning later"
        $choice = Prompt-Value "Choice" "1"
        $Provider = switch ($choice) { '1' { 'ollama' } '2' { 'openai-compatible' } default { 'skip' } }
    }

    # fractalsql.wxs installs the plugin DLL to lib\ directly under the
    # top-level PG install dir (same level as bin\), not under bin\.
    $pluginDll = Join-Path $Target.Dir 'lib\fractalsql-reasoning-http.dll'

    $gucs = [ordered]@{}
    switch ($Provider) {
        'ollama' {
            if (-not $Url) { $Url = Prompt-Value "Ollama chat URL" "http://localhost:11434/v1/chat/completions" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-oss:20b" }
            if (-not $EmbedUrl) { $EmbedUrl = Prompt-Value "Ollama embeddings URL" "http://localhost:11434/v1/embeddings" }
            if (-not $EmbedModel) { $EmbedModel = Prompt-Value "Embedding model" "nomic-embed-text" }
            if (-not $Think) { $Think = 'off' }
            if (-not $ThinkProvider) { $ThinkProvider = 'ollama' }
            $gucs['reasoning_plugin'] = "'$(SqlQuote $pluginDll)'"
            $gucs['http_url'] = "'$(SqlQuote $Url)'"
            $gucs['http_allow_plaintext'] = 'on'
            $gucs['http_model'] = "'$(SqlQuote $Model)'"
            $gucs['http_embed_url'] = "'$(SqlQuote $EmbedUrl)'"
            $gucs['http_embed_model'] = "'$(SqlQuote $EmbedModel)'"
            $gucs['http_think'] = "'$(SqlQuote $Think)'"
            $gucs['http_think_provider'] = "'$(SqlQuote $ThinkProvider)'"
        }
        'openai-compatible' {
            if (-not $Url) { $Url = Prompt-Value "Chat completions URL" }
            if (-not $Url) { Write-Die "a URL is required for a cloud/OpenAI-compatible endpoint" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-4o-mini" }
            if (-not $Token) { $Token = Prompt-Secret "API token (masked, never logged)" }
            $gucs['reasoning_plugin'] = "'$(SqlQuote $pluginDll)'"
            $gucs['http_url'] = "'$(SqlQuote $Url)'"
            $gucs['http_token'] = "'$(SqlQuote $Token)'"
            $gucs['http_model'] = "'$(SqlQuote $Model)'"
            if ($Url -notlike 'https://*') {
                Write-Warn2 "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            }
        }
        'skip' {
            Write-Step "Skipping reasoning config. Search functions like fractal_search and fractal_search_explore work with no model."
        }
    }

    if ($Provider -ne 'skip') {
        Write-Step "About to set:"
        foreach ($k in $gucs.Keys) {
            if ($k -eq 'http_token') { Write-Host "  ALTER SYSTEM SET fractalsql.http_token = '***'" }
            else { Write-Host "  ALTER SYSTEM SET fractalsql.$k = $($gucs[$k])" }
        }
        if (-not (Confirm-Step "Apply this configuration and reload?")) { Write-Die "Aborted. Nothing was changed." }
        if ($DryRun) {
            Write-Step "(-DryRun: not actually applying)"
        } else {
            # SELECT fractal_version() first, in the SAME psql
            # invocation as every ALTER SYSTEM SET below: forces
            # _PG_init() to register the fractalsql.* GUCs in this
            # backend before ALTER SYSTEM SET needs to recognize them.
            # All in one Invoke-Psql call so it's genuinely one session,
            # not one connection per statement.
            $sqlBatch = @('SELECT fractal_version();')
            foreach ($k in $gucs.Keys) { $sqlBatch += "ALTER SYSTEM SET fractalsql.$k = $($gucs[$k]);" }
            $sqlBatch += 'SELECT pg_reload_conf();'
            Invoke-Psql $bin $pgPort $sqlBatch | Out-Null
            Write-Ok "Reasoning configured and reloaded."
        }
    }

    if ($Provider -eq 'ollama') { Invoke-ColdStartTimeoutOffer $Target }

    if (-not $DryRun) {
        $ed = Invoke-Psql $bin $pgPort "SELECT fractal_edition();"
        $ver = Invoke-Psql $bin $pgPort "SELECT fractal_version();"
        Write-Ok "fractal_edition() = $ed, fractal_version() = $ver"
        if ($ver -ne $Version) {
            # DROP+CREATE (even with -ForceReinstall) only touches the
            # SQL catalog objects. It registers whatever fractalsql.dll
            # is already on disk, it doesn't replace it. A mismatch here
            # means the installed files are stale, not something this
            # script's extension-activation step can fix on its own.
            # Test-Installed only checks that the control file exists,
            # never its version, so an old install can sit untouched
            # indefinitely without this check catching it.
            Write-Warn2 "That's not $Version, the version this script expected. The installed files themselves are out of date. Reinstall the current .msi from https://github.com/$Repo/releases over this PG$($Target.Major) install to actually update fractalsql.dll, then re-run this script."
        }
        if ($Provider -ne 'skip' -and (Confirm-Step "Run a live reasoning smoke test (SELECT fractal_reason('say ok'))? A cloud endpoint may incur cost, and a cold local model can take several minutes the first time.")) {
            try {
                $reply = Invoke-Psql $bin $pgPort "SELECT fractal_reason('say ok');"
                Write-Host "  $reply"
            } catch {
                Write-Warn2 "That failed. If it looks like a timeout on a slow/cold local model, re-run and accept the cold-start timeout offer above, or see docs/reasoning-setup.md's 'Handling Constrained Hardware' section."
            }
        }
    }

    Write-Host ""
    Write-Host "You're set up. Where next:" -ForegroundColor Green
    Write-Host "  - docs/starter-kits.md: industry-specific runnable examples"
    Write-Host "  - docs/api-agency.md: the 16 built-in agents, full reference"
    Write-Host "  - docs/composition-guide.md: build your own agent"
    Write-Host "  - Re-run this script anytime to switch providers or models. It's"
    Write-Host "    safe, it just overwrites the GUCs above and reloads."
}

# --- -Uninstall ---------------------------------------------------------
function Invoke-Uninstall {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $pgPort = if ($Port) { $Port } else { $Target.Port }
    Resolve-PgPassword
    Write-Step "This will reset all fractalsql.* reasoning GUCs on PG$($Target.Major)."

    if (Confirm-Step "Reset reasoning config now?") {
        if ($DryRun) {
            Write-Step "(-DryRun: not actually resetting)"
        } else {
            # Same one-session batching as Invoke-Wizard's GUC-apply step,
            # and for the same reason. See Invoke-Psql's own comment.
            $sqlBatch = @('SELECT fractal_version();')
            foreach ($g in @('reasoning_plugin', 'http_url', 'http_token', 'http_model', 'http_allow_plaintext',
                              'http_embed_url', 'http_embed_model', 'http_think', 'http_think_provider',
                              'http_native_url', 'http_num_ctx')) {
                $sqlBatch += "ALTER SYSTEM RESET fractalsql.$g;"
            }
            $sqlBatch += 'SELECT pg_reload_conf();'
            Invoke-Psql $bin $pgPort $sqlBatch | Out-Null
            Write-Ok "Reasoning GUCs reset."
        }
    }

    if (Confirm-Step "Also DROP EXTENSION fractalsql_agents, fractalsql (deletes any dependent objects too)?") {
        if ($DryRun) {
            Write-Step "(-DryRun: not actually dropping)"
        } else {
            Invoke-Psql $bin $pgPort "DROP EXTENSION IF EXISTS fractalsql_agents, fractalsql;" | Out-Null
            Write-Ok "Extensions dropped."
        }
    }

    Write-Host "  To remove the package: uninstall 'FractalSQL for PostgreSQL $($Target.Major)' from Windows Settings > Apps, or msiexec /x <product code>"
}

# --- main ------------------------------------------------------------------
$installs = Get-PgInstalls
$target = Select-PgTarget $installs
Write-Step "Targeting PostgreSQL $($target.Major) (port $(if ($Port) { $Port } else { $target.Port }))"

if ($Uninstall) {
    Invoke-Uninstall $target
    exit 0
}

Install-Package $target
Invoke-Wizard $target
