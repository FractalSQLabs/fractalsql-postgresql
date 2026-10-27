<#
.SYNOPSIS
    build_test.ps1 -- Windows post-build validation gate runner for
    fractalsql-postgresql. PowerShell port of build_test.sh; same gate
    numbering/behavior where the underlying technique is portable.

.DESCRIPTION
    Windows post-build validation gate runner for fractalsql-postgresql;
    PowerShell port of build_test.sh with the same gate numbering. Default
    gates: 01-20, 22-33, 39-42 (gate 21/fuzz is opt-in via -Fuzz).

    Gates (see build_test.sh for the full rationale behind each):
      01  build              scripts\windows\build-windows.ps1
      02  smoke              version + fractal_search convergence
      03  schema_context     PK / NOT NULL / comment / FK introspection
      04  text_to_sql        allowlist matrix + never-executes proof
      05  evil_overread      guard-page (VirtualAlloc/VirtualProtect)
                             non-terminated response survives -- at
                             GENERATE, REVIEW, and bare fractal_reason()
      06  crash_recovery     deliberately-segfaulting plugin: connection
                             drops, cluster auto-restarts, data intact.
                             Windows uses EXEC_BACKEND (CreateProcess per
                             backend, no fork()) -- the crash-recovery
                             CONTRACT should hold (documented, 20+ years
                             of Windows PG support) but the exact log/
                             error-message wording this gate string-
                             matches has not been confirmed on Windows.
      07  evil_lying_length  guard_ai_response_len rejects an implausible
                             claimed length before any read -- pure
                             malloc/free, no platform-specific technique,
                             lowest-risk of the three evil gates to port.
      08  authz              low-priv role blocked from schema_context on
                             a table it lacks SELECT on
      09  guc_superuser      non-superuser rejected from setting
                             reasoning_plugin
      10  dos_and_injection  512-table cap fires at 513; SQL-injection-
                             shaped table_names cleanly rejected
      11  scout              fractal_search_explore population + dispersion
      12  soak               concurrent workers x mixed benign calls
      13  siu_mode           text_to_sql_allowed_statements=select_insert_
                             update: INSERT/UPDATE returned (never executed),
                             DDL/DELETE still rejected
      14  retry              max_attempts=2 retry-with-feedback: attempt 1
                             rejected, attempt 2 succeeds, rejection reason
                             threaded into the attempt-2 prompt
                             (uses tests\windows\retry_reasoning_plugin_win.c)
      15  embed              fractal_embed()/vectorizer dispatch, NULL/
                             bad-path/over-limit/injection/double-create
      16  embed_authz        vectorizer authz: owner vs. outsider
      17  embed_soak         concurrent process_queue() workers, no
                             double-processing
      18  embed_crash        crash mid-process_queue() rolls back the
                             whole batch atomically
      19  sfs_bounds         validate_sfs_params() bounds across all
                             three search entry points
      20  api_func           fractal_reason() happy path + NULL,
                             fractal_text_to_sql(NULL), search_explore's
                             own bounds via options jsonb, stale_after
                             reclaim (see build_test.sh Gate 20)
      21  fuzz_smoke         FUZZ ONLY (-Fuzz, not in default gates).
                             libFuzzer via clang-cl against the 3
                             hand-rolled parsers in
                             src\fractalsql_parse.c -- no cluster, no
                             extension DLL (see build_test.sh Gate 21)
      22  v2_functions       v2.x additions smoke: dimension analysis,
                             portfolio optimization, domain geometry,
                             named feature store, Diversify/feedback
                             controls, telemetry/trajectory/cross-modal
                             search (see build_test.sh Gate 22)
      38  mcp_https        the MCP server's direct-TLS mode (--https):
                             mcp\tests\mcp_https_smoke_client.py drives
                             the fail-fast startup modes (missing/
                             garbage/mismatched cert-or-key -> nonzero
                             exit), TLS-only port, bearer-under-TLS
                             (openssl for the throwaway cert; no DB)
      39  extract_parse   standalone C unit probe
                             (tests\extract_parse_probe.c) linked against
                             src\fractalsql_parse.c: best_point/
                             embedding_array/topk malformed-input branches
                             (mingw gcc, no cluster)
      40  vectors_probe   standalone C++17 unit probe (mcp\tests\
                             vectors_probe.cpp) against mcp\src\vectors.cpp
                             + errors.cpp -- coercion/validation branches
                             (mingw g++, no DB)
      41  db_probe        standalone C++17 unit probe (mcp\tests\
                             db_probe.cpp) against libpq: DB-less
                             branches always (16 checks), then the
                             connected branches live against the
                             throwaway cluster (run after gate 33)
      42  concurrency_probe  standalone C++17 unit probe (mcp\tests\
                             concurrency_probe.cpp) for mcp\src\
                             concurrency.h's limit/timeout/Token-release
                             branches (mingw g++, no DB)

.PARAMETER PgDir
    PostgreSQL server tree (EDB install root or unpacked binaries.zip).
    Same meaning as build-windows.ps1's -PgDir.

.PARAMETER PgMajor
    Target PostgreSQL major (14-18).

.PARAMETER Quick
    Gates 01-02 only.

.PARAMETER Gate
    Run a single gate by number (e.g. -Gate 05).

.PARAMETER TimeoutMult
    Scales gate 06/16's post-crash restart poll budget. Same purpose as
    build_test.sh's FSQL_TEST_TIMEOUT_MULT. Default 1, auto-bumped to 8
    under -Asan/-Ubsan unless passed explicitly (confirmed on real
    hardware: the default of 1 does not survive gate 06 under -Asan).

.PARAMETER Fuzz
    Gate 21 only -- libFuzzer smoke via clang-cl against
    src\fractalsql_parse.c's 3 hand-rolled parsers. Set FSQL_FUZZ_TIME
    (seconds per target, default 30) to run longer than the pre-push
    smoke budget.

.EXAMPLE
    PS> .\build_test.ps1 -PgDir "C:\Program Files\PostgreSQL\17" -PgMajor 17
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgDir,
    [Parameter(Mandatory = $true)][ValidateSet('14', '15', '16', '17', '18')][string]$PgMajor,
    [switch]$Quick,
    [string]$Gate,
    [int]$TimeoutMult = 1,
    # Rebuilds fractalsql.dll with MSVC /fsanitize=address into a
    # separate dist\windows-asan\ tree (never touches the normal
    # dist\windows\ release output), then runs the same gates against
    # the instrumented DLL loaded into postgres.exe. Only fractalsql.c
    # (this repo's own source) gets instrumented; the vendored core .lib
    # (include\windows-x86_64\fractalsql-*.lib) is linked as-is, not
    # rebuilt, so this catches bugs in the extension's own glue code but
    # not inside core's own SFS algorithm internals. /GL (whole-program
    # optimization, on in the normal build) is dropped -- documented
    # MSVC incompatibility with /fsanitize=address -- and /LTCG drops
    # with it at link time. -TimeoutMult auto-bumps to 8 under -Asan
    # (see below): ASan overhead blows the default 15s gate-06 crash-
    # recovery poll budget, cascade-failing later gates with "database
    # system is in recovery mode".
    [switch]$Asan,
    # Same structure as -Asan (separate dist\windows-ubsan\ tree, same
    # gates run against the instrumented DLL), but via clang-cl
    # (LLVM's MSVC-ABI-compatible driver -- native cl.exe has no UBSan
    # support at all) and -fsanitize=undefined instead of native
    # cl.exe's /fsanitize=address. Mutually exclusive with -Asan -- each
    # rebuilds its own separate dist\ tree, run one at a time. Whether
    # gate 06 needs the same -TimeoutMult headroom ASan needed is
    # unverified -- instrumentation overhead differs by sanitizer,
    # don't assume identical without checking a real run.
    [switch]$Ubsan,
    # Windows port of build_test.sh's Gate 21 (--fuzz): builds and
    # briefly runs libFuzzer drivers against the 3 hand-rolled parsers
    # in src\fractalsql_parse.c, via the same clang-cl -Ubsan already
    # resolves (LLVM's fuzzer support is a real, longstanding clang-cl
    # feature, not Linux-only). Unlike -Asan/-Ubsan, this does NOT
    # touch fractalsql.dll or postgres.exe at all -- fractalsql_parse.c
    # was split into its own postgres.h-free translation unit
    # specifically so these 3 functions link into a standalone .exe
    # directly, same as the Linux gate. Not mutually exclusive with
    # -Asan/-Ubsan (harmless to combine, just pointless -- this gate
    # doesn't use the extension DLL either builds).
    [switch]$Fuzz
)

if ($Asan -and $Ubsan) {
    throw "-Asan and -Ubsan are mutually exclusive -- each rebuilds its own separate dist\ tree. Run one at a time."
}

# -Asan/-Ubsan auto-set $TimeoutMult to 8 unless the caller explicitly
# passed a value ($PSBoundParameters check honors an explicit -TimeoutMult 1).
if (-not $PSBoundParameters.ContainsKey('TimeoutMult') -and ($Asan -or $Ubsan)) {
    $TimeoutMult = 8
}

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ defaults to treating ANY native-command stderr write
# as a terminating error under $ErrorActionPreference = 'Stop' --
# regardless of the writing program's own actual severity level. psql
# sends NOTICE/WARNING/ERROR all to stderr; without this, a routine
# "NOTICE: table ... does not exist, skipping" from a plain
# DROP TABLE IF EXISTS throws and aborts the whole script. This
# script already checks $LASTEXITCODE and regex-matches expected
# output text explicitly wherever it actually needs to detect a real
# failure -- it doesn't rely on PowerShell's automatic error handling
# for native commands, so restore the pre-7.3 lenient behavior.
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RepoRoot

$DefaultGates = @('01','02','03','04','05','06','07','08','09','10','11','12','13','14','15','16','17','18','19','20','22','23','24','25','26','27','28','29','30','31','32','33','38','39','40','41','42','43','44','45','46','47','48')
$QuickGates   = @('01','02')
$FuzzGates    = @('21')

$script:Failed = 0
function Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:Failed = 1 }
function Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }
# Doesn't set $script:Failed -- for environment-flake conditions (e.g. a
# pg_ctl restart not completing in time) where forcing the whole run
# red would hide the actual pass/fail signal for everything else.
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor DarkYellow }

# --- per-run state ------------------------------------------------------
$Bin      = Join-Path $PgDir 'bin'
$DistSubdir = if ($Asan) { "dist\windows-asan\pg$PgMajor" }
              elseif ($Ubsan) { "dist\windows-ubsan\pg$PgMajor" }
              else { "dist\windows\pg$PgMajor" }
$Dll      = Join-Path $RepoRoot "$DistSubdir\fractalsql.dll"

# ASan reports to stderr and aborts by default on the first violation --
# halt_on_error=1 makes that explicit. Inherited ambiently by every
# child process this script spawns (postgres.exe included, since it
# loads fractalsql.dll into its own process).
if ($Asan) { $env:ASAN_OPTIONS = 'halt_on_error=1:print_stats=0' }

# Discovery order: PATH -> vswhere-resolved VC\Tools\Llvm\x64\bin\clang-cl.exe
# -> standalone LLVM. Throws instead of skipping -- -Ubsan being passed at
# all means the caller wants it to actually run.
function Find-ClangCl {
    $candidate = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    $VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $VsWhere) {
        $vsPath = & $VsWhere -latest -products * -property installationPath 2>$null
        if ($vsPath) {
            $vsClang = Join-Path $vsPath 'VC\Tools\Llvm\x64\bin\clang-cl.exe'
            if (Test-Path $vsClang) { return $vsClang }
        }
    }
    $standalone = 'C:\Program Files\LLVM\bin\clang-cl.exe'
    if (Test-Path $standalone) { return $standalone }
    throw "-Ubsan/-Fuzz requested but clang-cl.exe not found (checked PATH, VS's 'C++ Clang tools for Windows' component, standalone LLVM)."
}
$script:ClangCl = $null
if ($Ubsan -or $Fuzz) {
    $script:ClangCl = Find-ClangCl
    Write-Host "Using clang-cl: $script:ClangCl"
}
if ($Ubsan) {
    $env:UBSAN_OPTIONS = 'print_stacktrace=1:halt_on_error=1'
}

# --- probe toolchain (gates 39-42) ------------------------------------------
# The standalone unit-probe gates need HOST-side C/C++ compilers, not a
# cluster toolchain: gate 39 links this repo's postgres.h-free src\
# fractalsql_parse.c with gcc (mingw -- the same role Strawberry mingw's
# gcc plays for the fixture plugins in build_test.sh's host-side runs),
# and gates 40/41/42 are C++17 probes needing g++/clang++ SPECIFICALLY --
# gcc alone mis-links the C++ standard-library symbols for these probes
# (the same finding the sibling SQLite column's build_test.ps1 recorded
# for its Find-Toolchain, which this mirrors). FSQL_CC / FSQL_CXX
# override. Resolution happens up front but is only *used* by the gates;
# absent compilers make the gates SKIP, not the run FAIL.
$script:Cc = $null
$script:Cxx = $null
if ($env:FSQL_CC) {
    $script:Cc = $env:FSQL_CC
}
else {
    foreach ($n in @('gcc', 'clang', 'cc')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { $script:Cc = $c.Source; break }
    }
}
if ($env:FSQL_CXX) {
    $script:Cxx = $env:FSQL_CXX
}
else {
    foreach ($n in @('g++', 'clang++')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { $script:Cxx = $c.Source; break }
    }
}
# Postgres's "is this library already loaded" dedup (internal_load_library)
# compares the path STRING, not a canonicalized/resolved path -- two
# different spellings of the same file (backslash vs forward-slash) are
# NOT recognized as the same library. shared_preload_libraries loads it
# once at postmaster/backend startup; every CREATE FUNCTION ... AS
# below ALSO names it. If those two spellings ever differ, Postgres
# loads the DLL a second time in the same process and _PG_init() runs
# twice, which genuinely IS "attempt to redefine parameter" the second
# time -- reproduced exactly this way on the first real Windows run
# (shared_preload_libraries used the forward-slash form, CREATE
# FUNCTION used the raw backslash form). Never hit on Linux, where
# build_test.sh uses the identical string in both places. Single
# normalized value, used everywhere the DLL path appears, closes it.
$DllPath  = $Dll -replace '\\','/'
$DataDir  = Join-Path $env:TEMP "fractalsql_bt_data_$PgMajor"
$Port     = 5600 + [int]$PgMajor
$PluginDir = Join-Path $env:TEMP "fractalsql_bt_plugins_$PgMajor"
# Inside $DataDir, not an absolute C:\Windows\Temp\... path -- that
# was the previous attempt and it silently never worked (fopen always
# returned NULL despite the file demonstrably existing there with the
# right content, confirmed via diagnostics on a real Windows run).
# tests\windows\*_win.c's plugins open these by BARE RELATIVE FILENAME,
# resolving against the backend's CWD, which PostgreSQL sets to its
# own data directory at startup -- a location the backend
# unquestionably has full access to, since it's postgres's own. These
# two locations must always agree with each other.
$TriggerFile = Join-Path $DataDir 'fractalsql_bt_evil_trigger_call.txt'
$SqlFile     = Join-Path $DataDir 'fractalsql_bt_sql.txt'
# Bare relative filename the retry plugin (tests\windows\retry_reasoning_
# plugin_win.c) writes the 2nd-call GENERATE prompt to, resolved against
# the backend's CWD (its own data dir) -- same mechanism as $SqlFile /
# $TriggerFile above. gate 14 (retry) reads this back to prove the
# attempt-1 rejection reason was threaded into the attempt-2 prompt.
$RetryPromptFile = Join-Path $DataDir 'fractalsql_bt_retry_prompt.txt'

# Bare relative filename the THINK plugin (tests\windows\think_reasoning_
# plugin_win.c) dumps the four FSQL_REASONING_HTTP_THINK*/NUM_CTX env vars
# to at format_prompt() time -- same resolved-against-CWD mechanism as
# $RetryPromptFile above. Gate 27 reads this back.
$ThinkDumpFile = Join-Path $DataDir 'fractalsql_bt_think_dump.txt'

# Bare relative filename the MOCK plugin (tests\windows\mock_reasoning_
# plugin_win.c) dumps FSQL_REASONING_HTTP_RESPONSE_MODE to on every
# generate() call (GENERATE, REVIEW, or a bare fractal_reason()) -- same
# resolved-against-CWD mechanism as $ThinkDumpFile above. Gate 28 reads
# this back after a full fractal_text_to_sql() call, whose last dispatch
# is always REVIEW.
$ReviewEnvDumpFile = Join-Path $DataDir 'fractalsql_bt_review_env_dump.txt'

$Mock  = Join-Path $PluginDir 'mock.dll'
$Evil  = Join-Path $PluginDir 'evil_overread.dll'
$Crash = Join-Path $PluginDir 'evil_crash.dll'
$Lying = Join-Path $PluginDir 'evil_lying.dll'
$Retry = Join-Path $PluginDir 'retry.dll'
$Embed = Join-Path $PluginDir 'mock_embed.dll'
$EvilEmbed = Join-Path $PluginDir 'evil_embed.dll'
$Think = Join-Path $PluginDir 'think.dll'

# Runs psql.exe via .NET's Process API directly rather than PowerShell's
# own native-command invocation (`&`). Simpler approaches still let a
# routine psql NOTICE (e.g. from DROP TABLE IF EXISTS) get wrapped as a
# NativeCommandError and, under $ErrorActionPreference = 'Stop', abort
# the whole script. ProcessStartInfo.ArgumentList passes each argument
# through CreateProcess exactly as given (no shell-level re-quoting), and
# reading StandardOutput/StandardError as plain .NET strings never touches
# PowerShell's ErrorRecord/$ErrorActionPreference machinery.
# ProcessStartInfo.ArgumentList needs .NET Core 2.1+ / pwsh 7+ -- it is
# absent under the ambient Windows PowerShell 5.1 host, so this script
# must be invoked via `pwsh -File`. (SQL travels via stdin -- `-f -` --
# not the command line, so there is no argv-escaping of $Sql at all.)

function Psql {
    param([string]$Sql, [string]$Db = 'postgres', [string]$User = 'postgres')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$Bin\psql.exe"
    # SQL is fed via stdin (`-f -`), NOT via `-c` on the command line.
    # PgSetup loads three slices of the extension SQL through this helper;
    # the fractalsql_agents slice alone is ~58KB after Stage 4's 9 new
    # engines -- far over the 32,767-char CreateProcess command-line
    # limit. Passing it via `-c $Sql` threw Win32 error 206 ("The
    # filename or extension is too long") at .Start, caught upstream as
    # "PG16 cluster setup". stdin has no such cap. `-f -` is also more
    # correct for multi-statement DDL than `-c "A; B; C"` (the latter
    # runs as one implicit transaction -- the same hazard documented at
    # PgSetGuc, which is why ALTER SYSTEM is split into two calls).
    # ArgumentList (not the Arguments string) needs no manual argv-
    # escaping and matches initdb's launch + the gate-23 psql helpers.
    foreach ($a in @('-h','127.0.0.1','-p',"$Port",'-U',$User,'-d',$Db,'-X','-tA','-f','-')) {
        $psi.ArgumentList.Add($a)
    }
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    # Read both streams concurrently, not sequentially -- a query whose
    # ERROR/DETAIL text is large (e.g. gate 15's evil-embed case, whose
    # errdetail echoes the plugin's ~33KB raw response) fills the stderr
    # pipe's OS buffer while stdout sits empty; ReadToEnd()'ing stdout
    # first then blocks forever waiting for EOF that can't arrive because
    # psql.exe itself is blocked writing the rest of stderr into a full
    # pipe. Starting both reads before WaitForExit() drains each pipe as
    # the child writes to it, so neither side can back the other up.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    # Feed the SQL via stdin and close (EOF) so psql (-f -) processes it.
    # This is done AFTER starting the async stdout/stderr reads above:
    # psql executes -f - input statement-by-statement and writes output
    # as it goes, so if stdout were not being drained concurrently a
    # large SQL could fill the OS pipe buffer and deadlock (our stdin
    # Write blocks waiting for psql to read, psql blocks waiting for us
    # to drain stdout). The async reads keep both pipes drained.
    $proc.StandardInput.Write($Sql)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    ($stdoutTask.Result + $stderrTask.Result).Trim()
}

# pg_ctl stop -w confirms the postmaster process itself has exited, but
# that's not the same guarantee as the OS having released every file
# handle it held -- on Windows, CloseHandle for a file under real-time
# antivirus scanning (or just plain process-teardown scheduling) can
# trail process-exit by up to a couple seconds. Confirmed the hard way:
# a run with -w already added to both stop call sites still hit "the
# process cannot access the file ...\log because it is being used by
# another process" on the very next Remove-Item. Retry with backoff
# instead of a one-shot delete.
function RemoveDataDirRetrying($path) {
    for ($i = 0; $i -lt 20; $i++) {
        try {
            Remove-Item -Recurse -Force $path -ErrorAction Stop
            return
        } catch {
            if ($i -eq 19) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Cleanup {
    if (Test-Path $DataDir) {
        # -w: see the matching comment on PgSetup's own stale-cleanup
        # stop call -- same race, same fix, here so a *later* run's
        # PgSetup doesn't inherit a not-yet-exited postmaster from this
        # one's teardown.
        try { & "$Bin\pg_ctl.exe" -D $DataDir -m immediate -w stop 2>&1 | Out-Null } catch { Write-Verbose "best-effort: pg_ctl stop failed (harmless if the server is already stopped): $($_.Exception.Message)" }
        # TEMPORARY: FSQL_BT_KEEP_DATADIR preserves $DataDir\log for
        # post-mortem debugging of the gate-24 Windows enterprise crash --
        # revert this gate once that's root-caused.
        if (-not $env:FSQL_BT_KEEP_DATADIR) {
            try { RemoveDataDirRetrying $DataDir } catch { Write-Verbose "best-effort at teardown; PgSetup's own retrying delete is what actually has to succeed: $($_.Exception.Message)" }
        } else {
            Write-Information "[build_test] FSQL_BT_KEEP_DATADIR set -- leaving $DataDir in place (log at $DataDir\log)" -InformationAction Continue
        }
    }
    Remove-Item -Force $SqlFile, $TriggerFile, $RetryPromptFile, $ThinkDumpFile, $ReviewEnvDumpFile -ErrorAction SilentlyContinue
}

# --- gate 01: build -------------------------------------------------------
# Replicates scripts\windows\build-windows.ps1's compile+link for
# fractalsql.c directly (doesn't call that script -- no
# ASan option there), with /fsanitize=address + /Zi added, /GL + /LTCG
# dropped (documented MSVC /fsanitize=address incompatibility with
# /GL), and /DEBUG added at link time. /MT unchanged -- already proven
# to work with /fsanitize=address. The vendored core .lib and
# postgres.lib are linked as-is (see the -Asan PARAMETER block above for
# why that's an accepted, documented limit of this gate's coverage).
function Build-AsanExtension {
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw "cl.exe not on PATH. Activate MSVC first (Native Tools Command Prompt / ilammy/msvc-dev-cmd)."
    }
    $outDir = Split-Path -Parent $Dll
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $pgLib       = Join-Path $PgDir 'lib\postgres.lib'
    $pgServerInc = Join-Path $PgDir 'include\server'
    if (-not (Test-Path $pgLib)) { throw "postgres.lib not found at $pgLib" }

    $coreLib = Join-Path $RepoRoot 'include\windows-x86_64\fractalsql-community-sovereign-c.lib'
    if (-not (Test-Path $coreLib)) { throw "vendored core library not found: $coreLib" }

    # libcrypto.lib: ent_verify_signature() in fractalsql.c (Ed25519 check
    # on the optional enterprise .so) calls OpenSSL's EVP API -- see
    # build-windows.ps1's $CryptoLib resolution for the full rationale
    # (Linux gets this for free via dlopen-time resolution against
    # postgres's own libcrypto.so; Windows needs it named at link time).
    $cryptoLib = Join-Path $PgDir 'lib\libcrypto.lib'
    if (-not (Test-Path $cryptoLib)) { throw "libcrypto.lib not found at $cryptoLib" }

    $src        = Join-Path $RepoRoot 'src\fractalsql.c'
    # fsql_extract_best_point / fsql_parse_embedding_array /
    # fsql_extract_population live in this separate, postgres.h-free TU,
    # not fractalsql.c -- must be compiled and linked here too, or the
    # link fails on 3 unresolved externals.
    $srcParse   = Join-Path $RepoRoot 'src\fractalsql_parse.c'
    $inc        = Join-Path $RepoRoot 'include'
    $fractalsqlObj      = Join-Path $outDir 'fractalsql.obj'
    $fractalsqlParseObj = Join-Path $outDir 'fractalsql_parse.obj'

    $commonCompileArgs = @(
        '/nologo', '/MT', '/O2', '/fsanitize=address', '/Zi', '/c',
        '/DWIN32', '/D_WINDOWS', '/D_CRT_SECURE_NO_WARNINGS', '/DFSQL_STATIC', '/DFSQL_FAULT_INJECT',
        "/I$(Join-Path $pgServerInc 'port\win32_msvc')",
        "/I$(Join-Path $pgServerInc 'port\win32')",
        "/I$pgServerInc",
        "/I$(Join-Path $PgDir 'include')",
        "/I$inc"
    )

    & cl.exe @commonCompileArgs "/Fo$fractalsqlObj" $src
    if ($LASTEXITCODE -ne 0) { throw "ASan compile failed for fractalsql.c (exit $LASTEXITCODE)" }
    & cl.exe @commonCompileArgs "/Fo$fractalsqlParseObj" $srcParse
    if ($LASTEXITCODE -ne 0) { throw "ASan compile failed for fractalsql_parse.c (exit $LASTEXITCODE)" }
    # fractalsql_vector.c -- third TU (fractal_vector type), same as the
    # Makefile's OBJS.
    $srcVector           = Join-Path $RepoRoot 'src\fractalsql_vector.c'
    $fractalsqlVectorObj = Join-Path $outDir 'fractalsql_vector.obj'
    & cl.exe @commonCompileArgs "/Fo$fractalsqlVectorObj" $srcVector
    if ($LASTEXITCODE -ne 0) { throw "ASan compile failed for fractalsql_vector.c (exit $LASTEXITCODE)" }

    # bcrypt.lib: the vendored community-sovereign-c.lib includes
    # src/diversify/entropy.c, which calls BCryptGenRandom on Windows.
    $linkArgs = @(
        '/nologo', '/LD',
        $fractalsqlObj,
        $fractalsqlParseObj,
        $fractalsqlVectorObj,
        "/Fe$Dll",
        '/link', '/DEBUG',
        $coreLib, $pgLib, $cryptoLib,
        'ws2_32.lib', 'advapi32.lib', 'secur32.lib', 'bcrypt.lib'
    )
    & cl.exe @linkArgs
    if ($LASTEXITCODE -ne 0) { throw "ASan link failed for $Dll (exit $LASTEXITCODE)" }
    if (-not (Test-Path $Dll)) { throw "ASan build did not produce $Dll" }
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $Dll, (Get-Item $Dll).Length) -ForegroundColor Green
}

# Same structure as Build-AsanExtension above -- clang-cl instead of
# cl.exe, -fsanitize=undefined instead of /fsanitize=address. Both
# invocations (compile-to-.obj, then the second cl-driver invocation
# that links via /LD ... /link) go through clang-cl here, so clang-cl
# itself resolves the UBSan runtime's /DEFAULTLIB directives during its
# own driver-orchestrated link step (single-driver compile+link shape).
function Build-UbsanExtension {
    $outDir = Split-Path -Parent $Dll
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $pgLib       = Join-Path $PgDir 'lib\postgres.lib'
    $pgServerInc = Join-Path $PgDir 'include\server'
    if (-not (Test-Path $pgLib)) { throw "postgres.lib not found at $pgLib" }

    $coreLib = Join-Path $RepoRoot 'include\windows-x86_64\fractalsql-community-sovereign-c.lib'
    if (-not (Test-Path $coreLib)) { throw "vendored core library not found: $coreLib" }

    # libcrypto.lib: same requirement as Build-AsanExtension above -- see
    # build-windows.ps1's $CryptoLib resolution for the full rationale.
    $cryptoLib = Join-Path $PgDir 'lib\libcrypto.lib'
    if (-not (Test-Path $cryptoLib)) { throw "libcrypto.lib not found at $cryptoLib" }

    $src        = Join-Path $RepoRoot 'src\fractalsql.c'
    # fsql_extract_best_point / fsql_parse_embedding_array /
    # fsql_extract_population live in this separate, postgres.h-free TU,
    # not fractalsql.c -- must be compiled and linked here too, or the
    # link fails on 3 unresolved externals.
    $srcParse   = Join-Path $RepoRoot 'src\fractalsql_parse.c'
    $inc        = Join-Path $RepoRoot 'include'
    $fractalsqlObj      = Join-Path $outDir 'fractalsql.obj'
    $fractalsqlParseObj = Join-Path $outDir 'fractalsql_parse.obj'

    # /MD, not /MT: LLVM's prebuilt clang_rt.ubsan_standalone-x86_64.lib
    # expects dynamic-CRT (/MD) import-thunk symbols -- linking it into a
    # /MT (static CRT) binary produces 17 unresolved __imp_* externals
    # (getenv, SymInitialize, StackWalk64, etc.). UNVERIFIED here: whether
    # the vendored core .lib (a /MT release artifact, linked unchanged
    # below) is CRT-compatible with these now-/MD-compiled objects in the
    # same final .dll -- watch the first real run for a CRT mismatch
    # (LNK4098-class warning/error).
    $commonCompileArgs = @(
        '/nologo', '/MD', '/O2', '-fsanitize=undefined', '/Zi', '/c',
        '/DWIN32', '/D_WINDOWS', '/D_CRT_SECURE_NO_WARNINGS', '/DFSQL_STATIC', '/DFSQL_FAULT_INJECT',
        "/I$(Join-Path $pgServerInc 'port\win32_msvc')",
        "/I$(Join-Path $pgServerInc 'port\win32')",
        "/I$pgServerInc",
        "/I$(Join-Path $PgDir 'include')",
        "/I$inc",
        # PostgreSQL's own port\atomics\generic-msvc.h passes volatile uint32*
        # into InterlockedCompareExchange/InterlockedExchangeAdd's LONG
        # volatile* params (and uint64* into the signed LONG64*_64 versions).
        # MSVC compiles that fine, but clang >= 16 promotes
        # -Wincompatible-pointer-types from a warning to an ERROR by default,
        # and C mode has no -fpermissive to fall back on -- so without this the
        # compile dies inside PG's header (2 errors at generic-msvc.h:55/:65)
        # before reaching a line of fractalsql.c. The mismatch is
        # same-width-only-different-sign and the two Interlocked calls have
        # identical semantics for both pointee types, so this is a header
        # lint, not a real bug -- downgrade to the warning clang defaults it
        # to and move on. Verified 2026-10-13 on PG16 + LLVM 22: with this
        # flag fractalsql.c/fractalsql_parse.c/fractalsql_vector.c all
        # compile clean (2 benign -Wpointer-sign warnings remain).
        '-Wno-error=incompatible-pointer-types'
    )

    & $script:ClangCl @commonCompileArgs "/Fo$fractalsqlObj" $src
    if ($LASTEXITCODE -ne 0) { throw "UBSan compile failed for fractalsql.c (exit $LASTEXITCODE)" }
    & $script:ClangCl @commonCompileArgs "/Fo$fractalsqlParseObj" $srcParse
    if ($LASTEXITCODE -ne 0) { throw "UBSan compile failed for fractalsql_parse.c (exit $LASTEXITCODE)" }
    # fractalsql_vector.c -- third TU (fractal_vector type), same as the
    # Makefile's OBJS.
    $srcVector           = Join-Path $RepoRoot 'src\fractalsql_vector.c'
    $fractalsqlVectorObj = Join-Path $outDir 'fractalsql_vector.obj'
    & $script:ClangCl @commonCompileArgs "/Fo$fractalsqlVectorObj" $srcVector
    if ($LASTEXITCODE -ne 0) { throw "UBSan compile failed for fractalsql_vector.c (exit $LASTEXITCODE)" }

    $linkArgs = @(
        '/nologo', '/LD',
        $fractalsqlObj,
        $fractalsqlParseObj,
        $fractalsqlVectorObj,
        "/Fe$Dll",
        '/link', '/DEBUG',
        $coreLib, $pgLib, $cryptoLib,
        'ws2_32.lib', 'advapi32.lib', 'secur32.lib', 'bcrypt.lib'
    )
    & $script:ClangCl @linkArgs
    if ($LASTEXITCODE -ne 0) { throw "UBSan link failed for $Dll (exit $LASTEXITCODE)" }
    if (-not (Test-Path $Dll)) { throw "UBSan build did not produce $Dll" }
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $Dll, (Get-Item $Dll).Length) -ForegroundColor Green
}

function Gate01Build {
    Write-Information "  building..." -InformationAction Continue
    if ($Asan) {
        Build-AsanExtension
    } elseif ($Ubsan) {
        Build-UbsanExtension
    } else {
        # -FaultInject: test builds only -- compiles in src\fsql_fault.h so gate 47
        # can fail individual SPI/core calls. The shipped build never sets it.
        & "$RepoRoot\scripts\windows\build-windows.ps1" -PgDir $PgDir -PgMajor $PgMajor -FaultInject
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Dll)) {
        Fail "01 build (PG$PgMajor)"
        return $false
    }
    Pass "01 build (PG$PgMajor)$(if ($Asan) { ' [ASan]' } elseif ($Ubsan) { ' [UBSan]' })"
    return $true
}

# --- build the test plugins (mirrors build_test.sh's pg_setup) ----------
function BuildTestPlugins {
    # New-Item -Force on an existing $PluginDir just means "don't error,"
    # it does NOT clear contents -- a stale .dll memory-mapped by a
    # lingering backend can shadow a rebuilt plugin. Remove-Item first to
    # start genuinely fresh.
    if (Test-Path $PluginDir) { Remove-Item -Recurse -Force $PluginDir -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $PluginDir | Out-Null
    $DefFile = Join-Path $RepoRoot 'tests\windows\fractalsql-test-plugin.def'
    $Inc = Join-Path $RepoRoot 'include'

    $targets = @(
        @{ Src = Join-Path $RepoRoot 'tests\windows\mock_reasoning_plugin_win.c';   Out = $Mock  },
        @{ Src = Join-Path $RepoRoot 'tests\windows\evil_nonterminating_plugin_win.c'; Out = $Evil  },
        @{ Src = Join-Path $RepoRoot 'tests\evil_crash_plugin.c';                  Out = $Crash },
        @{ Src = Join-Path $RepoRoot 'tests\evil_lying_length_plugin.c';           Out = $Lying },
        @{ Src = Join-Path $RepoRoot 'tests\windows\retry_reasoning_plugin_win.c'; Out = $Retry },
        @{ Src = Join-Path $RepoRoot 'tests\mock_embed_plugin.c';                  Out = $Embed },
        @{ Src = Join-Path $RepoRoot 'tests\evil_embed_plugin.c';                  Out = $EvilEmbed },
        @{ Src = Join-Path $RepoRoot 'tests\windows\think_reasoning_plugin_win.c'; Out = $Think }
    )
    foreach ($t in $targets) {
        $obj = [System.IO.Path]::ChangeExtension($t.Out, '.obj')
        & cl.exe /nologo /MT /LD /DFSQL_STATIC "/I$Inc" $t.Src "/Fo$obj" "/Fe$($t.Out)" `
            /link "/DEF:$DefFile" | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $t.Out)) {
            throw "failed to build test plugin: $($t.Src)"
        }
    }
}

# --- cluster setup/teardown ----------------------------------------------
function PgSetup {
    # pg_ctl start (below) runs postgres.exe DETACHED from this script's
    # own process tree -- killing a previous run's pwsh/build_test.ps1
    # (Ctrl+C, closing the terminal) does NOT kill the postgres.exe it
    # started. A stale instance from an earlier interrupted run can be
    # left holding files open in $DataDir, so Remove-Item below fails or
    # partially succeeds, and initdb then genuinely fails against a
    # locked/non-empty directory ("removing data directory ... because
    # initialization failed") -- confirmed as the likely cause of a real
    # run that looked hung and got killed. Stop anything still bound to
    # THIS specific datadir first (scoped, not a general postgres.exe
    # sweep -- see this same pattern already used at teardown).
    if (Test-Path $DataDir) {
        # -w: wait for the stop to actually complete before we touch the
        # datadir below. Without it, pg_ctl returns as soon as the signal
        # is sent, not once postgres.exe (and its checkpointer/bgwriter/
        # walwriter/logger children) have actually exited and released
        # their open handles -- confirmed the hard way: Remove-Item here
        # racing a still-live postmaster left orphaned, unkillable-by-us
        # postgres.exe processes behind (reparented once the owning
        # terminal session ended), and a later run's pg_ctl start then
        # failed with "the process cannot access the file ...\log
        # because it is being used by another process" against the very
        # datadir this was supposed to have already cleared out.
        try { & "$Bin\pg_ctl.exe" -D $DataDir -m immediate -w stop 2>&1 | Out-Null } catch { Write-Verbose "best-effort: pg_ctl stop failed (harmless if the server is already stopped): $($_.Exception.Message)" }
        RemoveDataDirRetrying $DataDir
    }
    BuildTestPlugins

    # Real diagnostic gap fixed here: this used to be
    # `& "$Bin\initdb.exe" ... | Out-Null`, which hides ALL of initdb's
    # normal stdout progress ("creating directory ... ok", "selecting
    # default...", etc.) -- a genuinely slow-but-healthy initdb (Windows
    # Defender scanning every file it writes can take 30-60s+) looks
    # completely silent, indistinguishable from a real hang, which is
    # exactly what caused a real run to be killed as "stuck" when
    # initdb may have simply been working with no visible feedback.
    # `&` native-command invocation is also what this file's own header
    # comment already documents as unsafe under PowerShell 7.3+'s
    # ANY-stderr-is-a-terminating-error behavior (the same reason Psql
    # uses the .NET Process API directly instead) -- initdb writing
    # even a routine NOTICE-class line to stderr could have aborted the
    # whole script right here, silently, before ever reaching the
    # explicit exit-code check this now has. Same Process API pattern
    # as Psql, echoing captured output live instead of swallowing it.
    $initdbPsi = New-Object System.Diagnostics.ProcessStartInfo
    $initdbPsi.FileName = "$Bin\initdb.exe"
    foreach ($a in @('-D', $DataDir, '-U', 'postgres', '--auth=trust')) {
        $initdbPsi.ArgumentList.Add($a)
    }
    $initdbPsi.RedirectStandardOutput = $true
    $initdbPsi.RedirectStandardError  = $true
    $initdbPsi.UseShellExecute = $false
    $initdbProc = [System.Diagnostics.Process]::Start($initdbPsi)
    $initdbOutTask = $initdbProc.StandardOutput.ReadToEndAsync()
    $initdbErrTask = $initdbProc.StandardError.ReadToEndAsync()
    $initdbProc.WaitForExit()
    $initdbOut = $initdbOutTask.Result
    $initdbErr = $initdbErrTask.Result
    if ($initdbOut) { Write-Information $initdbOut -InformationAction Continue }
    if ($initdbErr) { Write-Information $initdbErr -InformationAction Continue }
    if ($initdbProc.ExitCode -ne 0) {
        throw "initdb.exe failed (exit $($initdbProc.ExitCode)) -- see output above."
    }

    # All config via postgresql.conf, not pg_ctl -o's command-line
    # options string -- deliberately, not by oversight. PowerShell's
    # own native-argument quoting when shelling out (via &) is
    # inconsistent about embedded quotes/spaces across PS versions,
    # and $Dll/$RepoRoot can contain spaces on a real dev machine
    # (e.g. "C:\Users\Daniel Gardiner\..."). Same lesson build_test.sh
    # already learned the hard way on Linux for a different reason
    # (command-line -c permanently outranks later ALTER SYSTEM) --
    # postgresql.conf is the robust way to hand the server config that
    # might contain spaces or need later overriding.
    # fractalsql.reasoning_plugin: raw native (backslash) path, NOT
    # forward-slash-converted like $DllPath above. The core library's
    # fsql_load_reasoning() rejects a non-canonical path (one of three
    # defense layers before dlopen/LoadLibrary) -- on Windows the OS's
    # own canonicalization resolves to backslash form, so a forward-
    # slash-converted value fails that check with "path is not
    # canonical". Opposite requirement from $DllPath's fix above (that
    # one's about matching shared_preload_libraries' string-equality
    # dedup, a completely different subsystem).
    #
    # postgresql.conf's own file format additionally does C-style
    # backslash-escape processing on quoted string values (undocumented
    # in most guides but real: \f, \n, \t etc. are recognized escapes,
    # and an unrecognized one like \U or \A silently drops the
    # backslash) -- writing this file directly via Add-Content, I'm
    # responsible for doing that escaping myself, unlike ALTER SYSTEM
    # (PgSwapPlugin, below) which goes through SQL + Postgres's own
    # internal postgresql.auto.conf serialization and handles the
    # round-trip correctly without help. Confirmed the hard way: the
    # unescaped path's "\f" (from "...\fractalsql_bt_..." in the temp
    # dir name) got read back as a literal form-feed character, and
    # every other single backslash was silently dropped.
    $MockEscaped = $Mock -replace '\\','\\'
    $confLines = @(
        "listen_addresses = '127.0.0.1'",
        "port = $Port",
        "shared_preload_libraries = '$DllPath'",
        "fractalsql.reasoning_plugin = '$MockEscaped'",
        "fractalsql.text_to_sql_max_attempts = 1"
    )
    Add-Content -Path (Join-Path $DataDir 'postgresql.conf') -Value $confLines

    # REVERTED to the original bare invocation -- a redirected-pipe
    # version of this call was tried and caused a real regression: `pg_ctl
    # start` spawns postgres.exe as a long-running DETACHED daemon (that's
    # its whole job), which inherits handles to any redirected stdout/
    # stderr pipe. pg_ctl.exe itself exits promptly once the server is
    # ready, but reading a redirected pipe to EOF (Process.StandardOutput/
    # StandardError) blocks until EVERY process holding a handle to the
    # write end closes it -- and postgres.exe (plus its own child
    # processes: checkpointer, bgwriter, walwriter, ...) never do, since
    # they're meant to keep running. That made the script hang
    # indefinitely right here, even though the server itself had started
    # successfully (confirmed via its own log showing "ready to accept
    # connections") -- initdb doesn't have this problem (no long-lived
    # daemon children, the pipe reaches real EOF), so its own Process API
    # version above is unaffected and stays as-is. The PS7.3+ stderr-as-
    # terminating-error risk this bare form was originally rewritten to
    # avoid is real in theory, but this exact call has been empirically
    # proven fine across every real Windows run this session predating
    # that rewrite -- pg_ctl -w start's normal (success) path doesn't
    # write to stderr at all, so the risk never actually manifested,
    # unlike the pipe-EOF hang, which manifested immediately.
    #
    # ...except the bare form carries a SECOND latent hang, observed
    # twice on 2026-10-13/14 (both runs byte-identically stalled at
    # initdb's tail with zero child processes): it only avoids the pipe
    # when THIS script's own stdout is a terminal handle. Any caller
    # that redirects the script in-band (a background harness doing
    # `& build_test.ps1 ... *> log`, the exact form the first observed
    # hang already ran under) makes PowerShell wrap even this bare
    # pg_ctl call's stdout in a pipe it reads to EOF -- the detached
    # postmaster keeps the inherited write end open forever (that IS
    # the daemon's job), and the read blocks at exactly "server
    # started" like the original bug. (A `cmd.exe /s /c "... > file"`
    # wrapper tried first here also fails: pwsh's native-argument
    # re-quoting mangles the embedded quotes and cmd sees '""C:\Program'
    # as the command.)
    #
    # The context-independent fix is the Gate28RunPgCtlWithTimeout pattern
    # (gate 28's own retry-loop fix): the .NET Process API with Use-
    # ShellExecute=false and NO stream redirection -- the child gets
    # PowerShell's raw standard handles directly, bypassing pwsh's
    # in-band redirection plumbing entirely, so nothing ever wraps the
    # daemon's inherited handle in a pipe. start output (the two
    # "waiting/server started" lines) is lost to the terminal in a
    # redirected run -- by design; failure diagnosis still points at
    # $DataDir\log, and pg_ctl itself gets a bounded wall clock (its
    # -w readiness wait is the piece the gate-28 comment says can block
    # on Windows) via WaitForExit + Kill.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$Bin\pg_ctl.exe"
    foreach ($a in @('-D', $DataDir, '-w', '-l', (Join-Path $DataDir 'log'), 'start')) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(60000)) {
        try { $proc.Kill($true) } catch { }
        throw "pg_ctl start did not return within 60s -- see $DataDir\log"
    }
    if ($proc.ExitCode -ne 0) { throw "pg_ctl start failed (exit $($proc.ExitCode)) -- see $DataDir\log" }

    $createSql = @"
CREATE FUNCTION fractal_version() RETURNS text AS '$DllPath','fractal_version' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION fractal_edition() RETURNS text AS '$DllPath','fractal_edition' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION fractal_search(query float8[], iterations int4 DEFAULT 30, population_size int4 DEFAULT 50, diffusion_factor int4 DEFAULT 2) RETURNS float8[] AS '$DllPath','fractal_search' LANGUAGE C VOLATILE STRICT;
CREATE FUNCTION fractal_search_debug(query float8[], iterations int4 DEFAULT 30, population_size int4 DEFAULT 50, diffusion_factor int4 DEFAULT 2) RETURNS jsonb AS '$DllPath','fractal_search_debug' LANGUAGE C VOLATILE STRICT;
CREATE FUNCTION fractal_schema_context(table_names text[] DEFAULT NULL, query_hint text DEFAULT NULL) RETURNS text AS '$DllPath','fractal_schema_context' LANGUAGE C;
CREATE FUNCTION fractal_text_to_sql(question text, table_names text[] DEFAULT NULL) RETURNS text AS '$DllPath','fractal_text_to_sql' LANGUAGE C;
CREATE FUNCTION fractal_reason(query text, context text DEFAULT '{}') RETURNS text AS '$DllPath','fractal_reason' LANGUAGE C;
CREATE FUNCTION fractal_search_explore(table_name text, vector_col text, query float8[], options jsonb DEFAULT '{}'::jsonb) RETURNS SETOF float8[] AS '$DllPath','fractal_search_explore' LANGUAGE C VOLATILE STRICT;
CREATE FUNCTION fractal_embed(input text) RETURNS float8[] AS '$DllPath','fractal_embed' LANGUAGE C;
"@
    Psql -Sql $createSql | Out-Null

    # Load the two post-core sections of sql\fractalsql--1.0.sql straight
    # from the real file (not duplicated here by hand), matching build_test.sh's
    # Linux pg_setup() slice pattern exactly:
    #
    #   1. Vectorizer section (tables/trigger function/fractal_vectorizer_create/
    #      fractal_vectorizer_process_queue/fractal_vectorizer_status view) --
    #      pure SQL/PLpgSQL, NO MODULE_PATHNAME references, so it is loaded raw.
    #
    #   2. v2.x additions section (Diversify/Repulsion, feedback, dimension
    #      analysis, portfolio optimization, domain geometry, fractal_vector
    #      type, _fv overloads) -- this section DOES reference MODULE_PATHNAME
    #      (every C function in it), which only CREATE EXTENSION substitutes
    #      automatically; replace it with $DllPath before loading, exactly as
    #      build_test.sh does via `sed "s#MODULE_PATHNAME#$SO#g"` (its lines
    #      518-521). Without this the functions load with a literal
    #      "MODULE_PATHNAME" library string (CREATE FUNCTION does not validate
    #      the lib at create time) and fail at first call ("could not find
    #      function ... in file MODULE_PATHNAME").
    $sqlFileLines = Get-Content (Join-Path $RepoRoot 'sql\fractalsql--1.0.sql')
    $vectorizerIdx = ($sqlFileLines | Select-String -Pattern '^-- Vectorizer --' | Select-Object -First 1).LineNumber
    if (-not $vectorizerIdx) { throw "could not find '-- Vectorizer --' marker in sql\fractalsql--1.0.sql" }
    $v2xIdx = ($sqlFileLines | Select-String -Pattern '^-- v2.x additions --' | Select-Object -First 1).LineNumber
    if (-not $v2xIdx) { throw "could not find '-- v2.x additions --' marker in sql\fractalsql--1.0.sql" }

    # Slice 0 (Agent-tier): the 6 C-level "Universal Agent" functions +
    # their composite return types (fractal_search_agent, fractal_sql_agent,
    # fractal_rag_agent, fractal_agent_plan_explore, fractal_agent_
    # trajectory_predict, fractal_agent_detect_loop). This section sits
    # between the core (hand-registered as createSql above) and the
    # Vectorizer marker; it references MODULE_PATHNAME, so substitute
    # $DllPath. Engine G (fractal_agent_data_analyst) composes
    # fractal_sql_agent, so its fractal_sql_agent_result composite type
    # MUST exist before the agents extension slice loads -- PL/pgSQL
    # resolves DECLARE res fractal_sql_agent_result at CREATE time, so
    # without this slice engine G's CREATE fails with "type
    # fractal_sql_agent_result does not exist".
    $agentTierIdx = ($sqlFileLines | Select-String -Pattern '^-- Agent-tier results types' | Select-Object -First 1).LineNumber
    if (-not $agentTierIdx) { throw "could not find '-- Agent-tier results types' marker in sql\fractalsql--1.0.sql" }
    $agentTierSql = ($sqlFileLines[($agentTierIdx - 1)..($vectorizerIdx - 2)]) -join "`n"
    $agentTierSql = $agentTierSql -replace 'MODULE_PATHNAME', $DllPath
    $agentTierResult = Psql -Sql $agentTierSql
    if ($agentTierResult -match '(?i)error') { throw "agent-tier DDL failed to load: $agentTierResult" }

    # Slice 1 (Vectorizer): from its marker up to but EXCLUDING the v2.x
    # marker -- pure SQL/PLpgSQL, no MODULE_PATHNAME, load raw.
    $vectorizerSql = ($sqlFileLines[($vectorizerIdx - 1)..($v2xIdx - 2)]) -join "`n"
    $vzResult = Psql -Sql $vectorizerSql
    if ($vzResult -match '(?i)error') { throw "vectorizer DDL failed to load: $vzResult" }

    # Slice 2 (v2.x + fractal_vector): from its marker to EOF, with
    # MODULE_PATHNAME replaced by $DllPath (forward-slash DLL path, same
    # form the inline CREATE FUNCTION block above uses).
    $v2xSql = ($sqlFileLines[($v2xIdx - 1)..($sqlFileLines.Count - 1)]) -join "`n"
    $v2xSql = $v2xSql -replace 'MODULE_PATHNAME', $DllPath
    $v2xResult = Psql -Sql $v2xSql
    if ($v2xResult -match '(?i)error') { throw "v2.x/vector DDL failed to load: $v2xResult" }

    # Slice 3 (fractalsql_agents dependent extension): the parameterized
    # PL/pgSQL agent engines shipped in fractalsql_agents/. Pure PL/pgSQL
    # (no MODULE_PATHNAME), loaded raw like the Vectorizer slice -- but read
    # from its own extension subdir, with the \echo ... \quit guard line
    # stripped (the same guard the base SQL carries; \quit would abort psql).
    # The base functions it composes (fractal_dimension_drift, fractal_reason,
    # fractal_optimize_portfolio) are already registered above (hand-registered
    # C + the v2.x slice), so PL/pgSQL CREATE defers-resolution succeeds.
    $agentsSqlFile = Join-Path $RepoRoot 'fractalsql_agents\sql\fractalsql_agents--1.0.sql'
    if (-not (Test-Path $agentsSqlFile)) { throw "fractalsql_agents\sql\fractalsql_agents--1.0.sql not found -- run from a checkout that includes the fractalsql_agents/ extension" }
    $agentsSql = ((Get-Content $agentsSqlFile) | Where-Object { $_ -notmatch '^\s*\\echo.*\\quit' }) -join "`n"
    $agentsResult = Psql -Sql $agentsSql
    if ($agentsResult -match '(?i)error') { throw "fractalsql_agents DDL failed to load: $agentsResult" }
}

function PgTeardown {
    try { & "$Bin\pg_ctl.exe" -D $DataDir -m fast stop 2>&1 | Out-Null } catch { Write-Verbose "best-effort: pg_ctl stop failed (harmless if the server is already stopped): $($_.Exception.Message)" }
    # TEMPORARY: see Cleanup's matching FSQL_BT_KEEP_DATADIR comment.
    if (-not $env:FSQL_BT_KEEP_DATADIR) {
        Remove-Item -Recurse -Force $DataDir, $PluginDir -ErrorAction SilentlyContinue
    } else {
        Remove-Item -Recurse -Force $PluginDir -ErrorAction SilentlyContinue
    }
}

# ALTER SYSTEM cannot run inside a transaction block; a single -c "A; B"
# string runs as one implicit transaction (same finding as
# build_test.sh's pg_swap_plugin). Two separate psql invocations here,
# same as the Linux fix.
function PgSetGuc {
    param([string]$Name, [string]$SetVal, [string]$Want)
    Psql -Sql "ALTER SYSTEM SET $Name = $SetVal;" | Out-Null
    Psql -Sql "SELECT pg_reload_conf();" | Out-Null
    for ($i = 0; $i -lt (10 * $TimeoutMult); $i++) {
        $v = Psql -Sql "SELECT current_setting('$Name');"
        if ($v -eq $Want) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function PgSwapPlugin($path) {
    # Raw native path, not forward-slash-converted -- see the matching
    # comment on the initial postgresql.conf write in PgSetup for why.
    PgSetGuc -Name 'fractalsql.reasoning_plugin' -SetVal "'$path'" -Want $path
}

# --- gates 02-12 ----------------------------------------------------------

function Gate02Smoke {
    $ver = Psql -Sql "SELECT fractal_version();"
    if ($ver -eq '2.0.20') { Pass "02 smoke: version=$ver" } else { Fail "02 smoke: version='$ver' (want 2.0.20)" }
    $r = Psql -Sql @"
WITH q AS (SELECT fractal_search(ARRAY[0.6,0.8]::float8[],100,50,2) AS v)
SELECT CASE WHEN sqrt(v[1]*v[1]+v[2]*v[2])>1e-9
             AND (v[1]*0.6+v[2]*0.8)/sqrt(v[1]*v[1]+v[2]*v[2])>0.99
            THEN 'ok' ELSE 'FAIL' END FROM q;
"@
    if ($r -eq 'ok') { Pass "02 smoke: fractal_search convergence" } else { Fail "02 smoke: convergence=$r" }
    $ed = Psql -Sql "SELECT fractal_edition();"
    if ($ed -and $ed -notmatch 'ERROR') { Pass "02 smoke: edition=$ed" } else { Fail "02 smoke: edition='$ed'" }
    # fractal_search_debug returns the FULL fsql_search_ptr result JSON
    # (not just the best_point extraction fractal_search uses) -- assert
    # the best_point key survives the jsonb_in round-trip.
    $dbg = Psql -Sql "SELECT fractal_search_debug(ARRAY[0.6,0.8]::float8[],100,50,2);"
    if ($dbg -match 'best_point') { Pass "02 smoke: fractal_search_debug has best_point" }
    else { Fail "02 smoke: fractal_search_debug='$dbg'" }
}

function Gate03SchemaContext {
    Psql -Sql @"
DROP TABLE IF EXISTS bt_orders, bt_customers;
CREATE TABLE bt_customers (id serial PRIMARY KEY, name text NOT NULL, status text);
COMMENT ON TABLE bt_customers IS 'buyers';
CREATE TABLE bt_orders (id serial PRIMARY KEY, customer_id int NOT NULL REFERENCES bt_customers(id), total int NOT NULL);
"@ | Out-Null
    $ctx = Psql -Sql "SELECT fractal_schema_context(ARRAY['bt_customers','bt_orders']);"
    if ($ctx -match 'id integer PK')          { Pass "03 schema_context: PK" }       else { Fail "03 schema_context: PK" }
    if ($ctx -match 'name text NOT NULL')     { Pass "03 schema_context: NOT NULL" } else { Fail "03 schema_context: NOT NULL" }
    if ($ctx -match 'buyers')                 { Pass "03 schema_context: comment" }  else { Fail "03 schema_context: comment" }
    if ($ctx -match 'REFERENCES bt_customers'){ Pass "03 schema_context: FK" }       else { Fail "03 schema_context: FK" }

    # Composite-FK schema context: a multi-column FK with both referential
    # actions. The FK section of append_table_context prints
    # pg_get_constraintdef output verbatim (src\fractalsql.c), so the
    # emitted line must carry BOTH the (pa, pb) column pair -- proving a
    # composite FK isn't rendered as a single-column one -- and both ON
    # DELETE / ON UPDATE actions. Child columns stay NULLable: ON UPDATE
    # SET NULL writes NULL into them by design, so NOT NULL here would be
    # a self-contradictory (though create-time-accepted) schema. Cleaned
    # up at gate end. Mirrors build_test.sh's gate 03.
    Psql -Sql @"
DROP TABLE IF EXISTS bt_fk_child, bt_fk_parent;
CREATE TABLE bt_fk_parent (col_a int, col_b int, id serial PRIMARY KEY);
ALTER TABLE bt_fk_parent ADD CONSTRAINT bt_fk_parent_ab_uniq UNIQUE (col_a, col_b);
CREATE TABLE bt_fk_child (pa int, pb int);
ALTER TABLE bt_fk_child ADD CONSTRAINT bt_fk_child_ab_fk
  FOREIGN KEY (pa, pb) REFERENCES bt_fk_parent (col_a, col_b)
  ON DELETE CASCADE ON UPDATE SET NULL;
"@ | Out-Null
    $fkCtx = Psql -Sql "SELECT fractal_schema_context(ARRAY['bt_fk_parent','bt_fk_child']);"
    if ($fkCtx -match [regex]::Escape('FOREIGN KEY (pa, pb)')) { Pass "03 schema_context: composite-FK multi-column (pa, pb) line rendered" }
    else { Fail "03 schema_context: composite-FK (pa, pb) columns missing: '$fkCtx'" }
    if ($fkCtx -match 'REFERENCES bt_fk_parent') { Pass "03 schema_context: composite-FK REFERENCES line present" }
    else { Fail "03 schema_context: composite-FK REFERENCES missing: '$fkCtx'" }
    if ($fkCtx -match 'ON DELETE CASCADE') { Pass "03 schema_context: composite-FK ON DELETE CASCADE rendered" }
    else { Fail "03 schema_context: ON DELETE CASCADE missing: '$fkCtx'" }
    if ($fkCtx -match 'ON UPDATE SET NULL') { Pass "03 schema_context: composite-FK ON UPDATE SET NULL rendered" }
    else { Fail "03 schema_context: ON UPDATE SET NULL missing: '$fkCtx'" }
    Psql -Sql "DROP TABLE IF EXISTS bt_fk_child, bt_fk_parent;" | Out-Null
}

function T2sExpect($Canned, $Want, $Label) {
    Set-Content -Path $SqlFile -Value $Canned -NoNewline
    $r = Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);"
    if ([string]::IsNullOrEmpty($Want)) {
        if ($r -match 'ERROR') { Fail "$Label (expected PASS): $r" } else { Pass "$Label -> returned" }
    } else {
        if ($r -match [regex]::Escape($Want)) { Pass "$Label -> rejected ($Want)" } else { Fail "${Label}: got '$r' (want '$Want')" }
    }
}

function Gate04TextToSql {
    T2sExpect 'SELECT count(*) FROM bt_orders' '' '04 valid-SELECT'
    T2sExpect 'SELECT 1; DROP TABLE bt_orders' 'exactly one SQL' '04 stacked'
    T2sExpect 'DROP TABLE bt_orders' 'not permitted' '04 DDL'
    T2sExpect 'DELETE FROM bt_orders' 'not permitted' '04 DELETE'
    T2sExpect 'WITH d AS (DELETE FROM bt_orders RETURNING *) SELECT * FROM d' 'data-modifying CTE' '04 modifying-CTE'
    T2sExpect 'SELECT nope FROM bt_orders' 'does not analyze' '04 bad-column'
    # Empty-candidate contract (sibling v2.0.9 port): a zero-length SUCCESS
    # response from the plugin is a validation failure fed back + retried,
    # never an empty statement passed on or executed.
    T2sExpect 'FSQL_BT_EMPTY_RESPONSE' 'found 0' '04 empty-candidate'
    $n = Psql -Sql "SELECT count(*) FROM bt_orders;"
    if ($n -eq '0') { Pass "04 never-executes (bt_orders still empty)" } else { Fail "04 never-executes: row count=$n" }
}

function Gate05EvilOverread {
    if (-not (PgSwapPlugin $Evil)) { Fail "05 evil_overread: plugin swap did not take effect"; return }

    Set-Content -Path $TriggerFile -Value '1' -NoNewline
    Set-Content -Path $SqlFile -Value 'SELECT 1' -NoNewline
    $r = Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);"
    if ($r -match 'server closed the connection|could not connect') { Fail "05 evil_overread: GENERATE path -- backend crashed -- $r" }
    else { Pass "05 evil_overread: GENERATE path (non-terminated guard-page response) survived" }

    $r2 = Psql -Sql "SELECT fractal_reason('q');"
    if ($r2 -match 'server closed the connection|could not connect') { Fail "05 evil_overread: bare fractal_reason() -- backend crashed -- $r2" }
    else { Pass "05 evil_overread: bare fractal_reason() survived" }

    if (-not (PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'on' -Want 'on')) {
        Fail "05 evil_overread: could not enable text_to_sql_use_review"; PgSwapPlugin $Mock | Out-Null; return
    }
    Set-Content -Path $TriggerFile -Value '2' -NoNewline
    $r3 = Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);"
    if ($r3 -match 'server closed the connection|could not connect') { Fail "05 evil_overread: REVIEW path -- backend crashed -- $r3" }
    else { Pass "05 evil_overread: REVIEW path (t2s_run_review) survived" }
    PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'off' -Want 'off' | Out-Null
    Set-Content -Path $TriggerFile -Value '1' -NoNewline

    PgSwapPlugin $Mock | Out-Null
}

function Gate06CrashRecovery {
    Psql -Sql "INSERT INTO bt_customers (name, status) VALUES ('canary', 'ok');" | Out-Null
    if (-not (PgSwapPlugin $Crash)) { Fail "06 crash_recovery: plugin swap did not take effect"; return }

    Set-Content -Path $SqlFile -Value 'SELECT 1' -NoNewline
    $r = Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);"
    if ($r -match 'server closed the connection|could not connect') {
        Pass "06 crash_recovery: triggering connection dropped as expected"
    } else {
        Fail "06 crash_recovery: expected the connection to drop, got: $r"
    }

    # Pass/fail budget and actual up-detection must not share the same
    # cutoff -- restoring $Mock below depends on $up, and a near-miss on
    # the original budget (cluster comes back a few seconds late) left
    # the deliberately-crashing plugin active for every remaining gate,
    # cascading into unrelated-looking failures far downstream (confirmed
    # on real Windows CI: 06 missed a 15s budget by ~4s, then gates
    # 07/12/13/14/15/17/20 all failed against the still-active crash
    # plugin). Poll for up to double the budget; report pass/fail against
    # the original window, but restore the plugin as long as the cluster
    # comes back at all within the extended one.
    $up = $false
    $withinBudget = $false
    $tries = 30 * $TimeoutMult
    for ($i = 0; $i -lt ($tries * 2); $i++) {
        $t = Psql -Sql "SELECT 1;"
        if ($t -eq '1') { $up = $true; if ($i -lt $tries) { $withinBudget = $true }; break }
        Start-Sleep -Milliseconds 500
    }
    if ($withinBudget) { Pass "06 crash_recovery: cluster auto-restarted" }
    else { Fail "06 crash_recovery: cluster did not come back within $($tries / 2)s" }

    if ($up) {
        $n = Psql -Sql "SELECT count(*) FROM bt_customers WHERE name = 'canary';"
        if ($n -eq '1') { Pass "06 crash_recovery: prior data intact after recovery" }
        else { Fail "06 crash_recovery: canary row missing after recovery (n=$n)" }
        PgSwapPlugin $Mock | Out-Null
    } else {
        Fail "06 crash_recovery: cluster never came back -- remaining gates will run against the crash plugin"
    }
}

function Gate07EvilLyingLength {
    if (-not (PgSwapPlugin $Lying)) { Fail "07 evil_lying_length: plugin swap did not take effect"; return }

    Set-Content -Path $TriggerFile -Value '1' -NoNewline
    $r = Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);"
    if ($r -match 'server closed the connection|could not connect') { Fail "07 evil_lying_length: GENERATE path -- backend crashed -- $r" }
    elseif ($r -match 'implausible response length') { Pass "07 evil_lying_length: GENERATE path rejected cleanly" }
    else { Fail "07 evil_lying_length: GENERATE path -- expected rejection, got: $r" }

    $r2 = Psql -Sql "SELECT fractal_reason('q');"
    if ($r2 -match 'server closed the connection|could not connect') { Fail "07 evil_lying_length: bare fractal_reason() -- backend crashed -- $r2" }
    elseif ($r2 -match 'implausible response length') { Pass "07 evil_lying_length: bare fractal_reason() rejected cleanly" }
    else { Fail "07 evil_lying_length: bare fractal_reason() -- expected rejection, got: $r2" }

    if (-not (PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'on' -Want 'on')) {
        Fail "07 evil_lying_length: could not enable text_to_sql_use_review"; PgSwapPlugin $Mock | Out-Null; return
    }
    Set-Content -Path $TriggerFile -Value '2' -NoNewline
    $r3 = Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);"
    if ($r3 -match 'server closed the connection|could not connect') { Fail "07 evil_lying_length: REVIEW path -- backend crashed -- $r3" }
    elseif ($r3 -match 'implausible response length') { Pass "07 evil_lying_length: REVIEW path (t2s_run_review) rejected cleanly" }
    else { Fail "07 evil_lying_length: REVIEW path -- expected rejection, got: $r3" }
    PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'off' -Want 'off' | Out-Null
    Set-Content -Path $TriggerFile -Value '1' -NoNewline

    PgSwapPlugin $Mock | Out-Null
}

function Gate08Authz {
    Psql -Sql @"
DROP TABLE IF EXISTS bt_secret;
CREATE TABLE bt_secret (id serial PRIMARY KEY, ssn text);
COMMENT ON TABLE bt_secret IS 'PII - restricted';
REVOKE ALL ON bt_secret FROM PUBLIC;
DROP ROLE IF EXISTS bt_lowpriv;
CREATE ROLE bt_lowpriv LOGIN;
"@ | Out-Null

    $r = Psql -Sql "SELECT fractal_schema_context(ARRAY['bt_secret']);" -User 'bt_lowpriv'
    if ($r -match 'ssn') { Fail "08 authz: low-priv role saw bt_secret's columns (info disclosure): $r" }
    elseif ($r -match 'not found or not visible') { Pass "08 authz: low-priv role correctly blocked from bt_secret" }
    else { Fail "08 authz: unexpected result: $r" }

    Psql -Sql "GRANT SELECT ON bt_secret TO bt_lowpriv;" | Out-Null
    $r2 = Psql -Sql "SELECT fractal_schema_context(ARRAY['bt_secret']);" -User 'bt_lowpriv'
    if ($r2 -match 'ssn') { Pass "08 authz: SELECT grant restores visibility" } else { Fail "08 authz: granted role still blocked: $r2" }

    Psql -Sql "DROP ROLE bt_lowpriv; DROP TABLE bt_secret;" | Out-Null
}

function Gate09GucSuperuser {
    Psql -Sql "DROP ROLE IF EXISTS bt_lowpriv2; CREATE ROLE bt_lowpriv2 LOGIN;" | Out-Null
    $r = Psql -Sql "ALTER SYSTEM SET fractalsql.reasoning_plugin = 'C:\evil.dll';" -User 'bt_lowpriv2'
    if ($r -match '(?i)permission denied|must be a?n? ?superuser') {
        Pass "09 guc_superuser: non-superuser rejected from setting reasoning_plugin"
    } else {
        Fail "09 guc_superuser: expected rejection, got: $r"
    }
    # The whole fractalsql.http_* provider family (url, token, model,
    # embed_url, embed_model, think, think_provider, native_url, num_ctx,
    # allow_plaintext) is GUC_SUPERUSER_ONLY: a non-superuser must not be
    # able to READ the deployment's provider configuration, while the rest
    # of the config surface stays readable. The boundary is PER-KEY -- the
    # positive control below proves the gate is not a blanket refusal.
    $rRead = Psql -Sql "SELECT current_setting('fractalsql.http_model', true);" -User 'bt_lowpriv2'
    if ($rRead -match '(?i)permission denied|must be a?n? ?superuser') {
        Pass "09 guc_superuser: non-superuser rejected from reading http_model"
    } else {
        Fail "09 guc_superuser: expected a privilege error reading http_model, got: $rRead"
    }
    $rRead2 = Psql -Sql "SELECT current_setting('fractalsql.text_to_sql_max_attempts', true);" -User 'bt_lowpriv2'
    if ($rRead2 -match '^\d+$') {
        Pass "09 guc_superuser: the boundary is per-key -- a non-superuser still reads a non-superuser-only key"
    } else {
        Fail "09 guc_superuser: expected text_to_sql_max_attempts to stay readable, got: $rRead2"
    }

    # ---- T-G: the typed config surface (fractalsql_set_config() /
    # fractalsql_get_config(), src\fractalsql.c's fsql_cfg_keys[] table).
    # This is the SQL-callable wrapper over the fractalsql.* GUCs, and
    # it is what promises typed validation, a per-key privilege
    # boundary, a scope boundary, and an error naming the known keys.
    # None of that was asserted anywhere before: the surface compiled
    # and loaded, but no gate ever called it.
    $rG = Psql -Sql "SELECT fractalsql_get_config('nope');"
    if ($rG -match 'unknown config key "nope"' -and $rG -match 'Known keys:') {
        Pass "09 cfg: an unknown key is an error that lists the known keys (get)"
    } else {
        Fail "09 cfg: expected an unknown-key error naming the known keys, got: $rG"
    }
    $rG2 = Psql -Sql "SELECT fractalsql_set_config('nope','x');"
    if ($rG2 -match 'unknown config key "nope"') {
        Pass "09 cfg: an unknown key is an error, never a silent no-op (set)"
    } else {
        Fail "09 cfg: expected an unknown-key error, got: $rG2"
    }

    # Both spellings of a key are accepted, case-insensitively -- the
    # bare name ("http_url") and the GUC's own name
    # ("fractalsql.http_url"). The bare form used to be matched
    # case-SENSITIVELY (fsql_cfg_lookup() folded only the prefixed
    # spelling), which contradicted both the function's own contract
    # and the SQL COMMENT on the two functions.
    $rG3 = Psql -Sql "SELECT fractalsql_get_config('text_to_sql_max_attempts');"
    $rG4 = Psql -Sql "SELECT fractalsql_get_config('fractalsql.text_to_sql_max_attempts');"
    if ($rG3 -eq $rG4 -and $rG3 -match '^\d+$') {
        Pass "09 cfg: the bare key and the GUC spelling return the same value"
    } else {
        Fail "09 cfg: expected the two spellings to agree, got bare='$rG3' prefixed='$rG4'"
    }
    $rG5 = Psql -Sql "SELECT fractalsql_get_config('TEXT_TO_SQL_MAX_ATTEMPTS');"
    $rG6 = Psql -Sql "SELECT fractalsql_get_config('FRACTALSQL.text_to_sql_max_attempts');"
    if ($rG5 -eq $rG3 -and $rG6 -eq $rG3) {
        Pass "09 cfg: both key spellings are matched case-insensitively"
    } else {
        Fail "09 cfg: expected case-insensitive matching, got bare-upper='$rG5' prefixed-upper='$rG6' (expected '$rG3')"
    }

    # A bool key canonicalizes to on/off and the value written IS the
    # GUC's own value -- current_setting() has to agree with it in the
    # SAME session. One Psql call = one backend = one session, which
    # matters: the write is session-scoped, so a separate call would
    # read a fresh backend's untouched default.
    $rG7 = Psql -Sql "SELECT fractalsql_set_config('agent_partial_reasoning_fail','yes') || '=' || fractalsql_get_config('agent_partial_reasoning_fail') || '=' || current_setting('fractalsql.agent_partial_reasoning_fail');"
    if ($rG7 -eq 'on=on=on') {
        Pass "09 cfg: a bool key canonicalizes 'yes' to 'on' and the value lands in the GUC itself"
    } else {
        Fail "09 cfg: expected on=on=on, got: $rG7"
    }
    $rG8 = Psql -Sql "SELECT fractalsql_set_config('agent_partial_reasoning_fail','tru');"
    if ($rG8 -match 'expects a boolean' -and $rG8 -match 'Accepted spellings') {
        Pass "09 cfg: a bool key rejects an unrecognised spelling and names the accepted ones"
    } else {
        Fail "09 cfg: expected a boolean rejection, got: $rG8"
    }

    # Typed validation: int, enum, and the documented order --
    # the VALUE is validated before the privilege and scope checks, so
    # a bad value is reported as a bad value even for a key a session
    # may not change.
    $rG9 = Psql -Sql "SELECT fractalsql_set_config('http_num_ctx','notanint');"
    if ($rG9 -match 'expects an integer') {
        Pass "09 cfg: an int key rejects a non-integer"
    } else {
        Fail "09 cfg: expected an integer rejection, got: $rG9"
    }
    $rG10 = Psql -Sql "SELECT fractalsql_set_config('http_num_ctx','1048577');"
    if ($rG10 -match 'must be between 0 and 1048576') {
        Pass "09 cfg: an int key rejects a value outside its range"
    } else {
        Fail "09 cfg: expected a range rejection, got: $rG10"
    }
    $rG11 = Psql -Sql "SELECT fractalsql_set_config('text_to_sql_allowed_statements','drop');"
    if ($rG11 -match 'must be one of: select\|select_insert_update') {
        Pass "09 cfg: an enum key rejects a value outside its member list"
    } else {
        Fail "09 cfg: expected an enum rejection, got: $rG11"
    }
    $rG12 = Psql -Sql "SELECT fractalsql_set_config('text_to_sql_max_attempts','99');"
    if ($rG12 -match 'must be between 1 and 10') {
        Pass "09 cfg: an invalid value is reported BEFORE the scope check (text_to_sql_max_attempts is reload-scoped)"
    } else {
        Fail "09 cfg: expected the value error to win over the scope error, got: $rG12"
    }

    # The scope boundary: a reload-scoped (PGC_SIGHUP) key cannot be
    # changed in a session, and the error names the ALTER SYSTEM +
    # pg_reload_conf() path instead of silently doing nothing.
    $rG13 = Psql -Sql "SELECT fractalsql_set_config('text_to_sql_max_attempts','3');"
    if ($rG13 -match 'is reload-scoped and cannot be changed in a session' -and $rG13 -match 'ALTER SYSTEM SET' -and $rG13 -match 'pg_reload_conf') {
        Pass "09 cfg: a reload-scoped key refuses a session change and names the ALTER SYSTEM + pg_reload_conf path"
    } else {
        Fail "09 cfg: expected the reload-scoped refusal with the ALTER SYSTEM hint, got: $rG13"
    }
    # ... while a session-settable key (PGC_USERSET / PGC_SUSET) IS
    # writable in a session, and the canonical value comes back.
    $rG14 = Psql -Sql "SELECT fractalsql_set_config('enterprise_ledger_key','cfgtest');"
    if ($rG14 -eq 'cfgtest') {
        Pass "09 cfg: a session-settable key (enterprise_ledger_key) is writable in a session"
    } else {
        Fail "09 cfg: expected the value to be accepted, got: $rG14"
    }

    # NULL arguments are argument faults, not "unset".
    $rG15 = Psql -Sql "SELECT fractalsql_set_config(NULL,'x');"
    if ($rG15 -match 'the key must not be NULL') {
        Pass "09 cfg: set rejects a NULL key"
    } else {
        Fail "09 cfg: expected the NULL-key rejection, got: $rG15"
    }
    $rG16 = Psql -Sql "SELECT fractalsql_set_config('text_to_sql_max_attempts',NULL);"
    if ($rG16 -match 'the value must not be NULL') {
        Pass "09 cfg: set rejects a NULL value"
    } else {
        Fail "09 cfg: expected the NULL-value rejection, got: $rG16"
    }
    $rG17 = Psql -Sql "SELECT fractalsql_get_config(NULL);"
    if ($rG17 -match 'the key must not be NULL') {
        Pass "09 cfg: get rejects a NULL key"
    } else {
        Fail "09 cfg: expected the NULL-key rejection, got: $rG17"
    }

    # The config API enforces the SAME per-key privilege boundary the
    # GUCs carry -- and, like the GUCs, it is per-key, not blanket.
    $rL1 = Psql -Sql "SELECT fractalsql_set_config('http_url','http://x');" -User 'bt_lowpriv2'
    if ($rL1 -match 'is a superuser-only setting') {
        Pass "09 cfg: a non-superuser cannot SET a superuser-only key through the config API"
    } else {
        Fail "09 cfg: expected the superuser-only rejection, got: $rL1"
    }
    $rL2 = Psql -Sql "SELECT fractalsql_get_config('http_url');" -User 'bt_lowpriv2'
    if ($rL2 -match 'is a superuser-only setting') {
        Pass "09 cfg: a non-superuser cannot READ a superuser-only key through the config API"
    } else {
        Fail "09 cfg: expected the superuser-only rejection, got: $rL2"
    }
    $rL3 = Psql -Sql "SELECT fractalsql_get_config('text_to_sql_max_attempts');" -User 'bt_lowpriv2'
    if ($rL3 -match '^\d+$') {
        Pass "09 cfg: the config API's privilege boundary is per-key -- a non-superuser still reads a non-superuser-only key"
    } else {
        Fail "09 cfg: expected text_to_sql_max_attempts to stay readable, got: $rL3"
    }
    $rL4 = Psql -Sql "SELECT fractalsql_set_config('agent_partial_reasoning_fail','on');" -User 'bt_lowpriv2'
    if ($rL4 -eq 'on') {
        Pass "09 cfg: a non-superuser may set a non-superuser-only, session-settable key"
    } else {
        Fail "09 cfg: expected the set to be accepted, got: $rL4"
    }

    Psql -Sql "DROP ROLE bt_lowpriv2;" | Out-Null
}

function Gate10DosAndInjection {
    $many = (1..513 | ForEach-Object { "'t$_'" }) -join ','
    $r = Psql -Sql "SELECT fractal_schema_context(ARRAY[$many]);"
    if ($r -match 'exceeds the limit of 512') { Pass "10 dos_cap: 513 table names rejected" }
    else { Fail "10 dos_cap: expected PROGRAM_LIMIT_EXCEEDED, got: $r" }

    $r2 = Psql -Sql "SELECT fractal_schema_context(ARRAY['bt_customers''; DROP TABLE bt_orders; --']);"
    $n = Psql -Sql "SELECT count(*) FROM bt_orders;"
    if ($n -eq '0') { Pass "10 injection: SQL-injection-shaped table name did not execute (bt_orders intact)" }
    else { Fail "10 injection: bt_orders row count changed (n=$n) -- injection may have executed" }
    if ($r2 -match 'not found or not visible|ERROR') { Pass "10 injection: injection-shaped table name cleanly rejected" }
    else { Fail "10 injection: unexpected result: $r2" }
}

function Gate11Scout {
    Psql -Sql @"
DROP TABLE IF EXISTS bt_scout_docs;
CREATE TABLE bt_scout_docs (id int, emb_arr float8[]);
INSERT INTO bt_scout_docs
  SELECT i, ARRAY[1.0,0.0,0.0]::float8[] FROM generate_series(1,20) i
  UNION ALL
  SELECT i, ARRAY[0.0,1.0,0.0]::float8[] FROM generate_series(21,40) i
  UNION ALL
  SELECT i, ARRAY[0.0,0.0,1.0]::float8[] FROM generate_series(41,60) i;
"@ | Out-Null

    $n = Psql -Sql @"
SELECT count(*) FROM fractal_search_explore(
  'bt_scout_docs', 'emb_arr', ARRAY[1.0,0.0,0.0]::float8[],
  '{"population_size": 24, "iterations": 12}'::jsonb);
"@
    if ($n -eq '24') { Pass "11 scout: returns full population (24 particles)" }
    else { Fail "11 scout: expected 24 particles, got: $n" }

    $islands = Psql -Sql @"
SELECT count(DISTINCT
  CASE WHEN p[1] > p[2] AND p[1] > p[3] THEN 0
       WHEN p[2] > p[1] AND p[2] > p[3] THEN 1
       ELSE 2 END)
FROM fractal_search_explore(
  'bt_scout_docs', 'emb_arr', ARRAY[1.0,0.0,0.0]::float8[],
  '{"population_size": 24, "iterations": 12}'::jsonb) AS p;
"@
    $islandsNum = 0
    if ([int]::TryParse($islands, [ref]$islandsNum) -and $islandsNum -gt 1) {
        Pass "11 scout: particles disperse across >1 island"
    } else {
        Fail "11 scout: expected dispersion, got islands=$islands"
    }

    Psql -Sql "DROP TABLE IF EXISTS bt_scout_docs;" | Out-Null
}

function Gate12Soak {
    # Diagnostic: a real run produced zero Pass/Fail output for this
    # gate (and 13/14) against a cluster still recovering from gate 06's
    # crash, while gates 07-11 printed FAIL lines against the same dead
    # cluster -- this entry echo exists to disambiguate "never started"
    # from "started but its own Pass/Fail calls didn't print" the next
    # time that happens, since ForEach-Object -Parallel's 20 runspaces
    # give this gate a materially different failure surface than the
    # other gates' single synchronous Psql calls. Cheap, always-on
    # (unlike a -Verbose-gated line) since gate 12 already prints on
    # every run anyway.
    Write-Information "  12 soak: starting (20 workers x 15 iterations)..." -InformationAction Continue
    $workers = 20
    $iters = 15
    Set-Content -Path $SqlFile -Value 'SELECT count(*) FROM bt_orders' -NoNewline

    $results = 1..$workers | ForEach-Object -Parallel {
        $w = $_
        $bin = $using:Bin
        $port = $using:Port
        $rc = 0
        for ($i = 1; $i -le $using:iters; $i++) {
            $q = switch ((($w + $i) % 3)) {
                0 { "SELECT fractal_search(ARRAY[0.6,0.8]::float8[],20,20,2);" }
                1 { "SELECT fractal_schema_context(ARRAY['bt_customers','bt_orders']);" }
                2 { "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" }
            }
            # Process API directly (not & psql.exe), matching the
            # script-scope Psql function's approach -- see its comment.
            # -Parallel runs in an isolated runspace that doesn't
            # inherit script-scope preference variables, so this can't
            # just call that function; inlined here instead.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "$bin\psql.exe"
            foreach ($a in @('-h','127.0.0.1','-p',"$port",'-U','postgres','-d','postgres','-X','-tA','-c',$q)) {
                $psi.ArgumentList.Add($a)
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            # Concurrent async reads, not sequential ReadToEnd() -- see
            # the script-scope Psql function's comment for why a large
            # stderr payload (an unexpected error's detail text) can
            # deadlock a stdout-then-stderr read order.
            $soT = $proc.StandardOutput.ReadToEndAsync()
            $seT = $proc.StandardError.ReadToEndAsync()
            $proc.WaitForExit()
            $soT.Result | Out-Null
            $seT.Result | Out-Null
            if ($proc.ExitCode -ne 0) { $rc = 1 }
        }
        $rc
    } -ThrottleLimit $workers

    # @(...) forces an array even when zero items match -- under
    # Set-StrictMode, Where-Object matching nothing returns $null, and
    # $null.Count throws "property cannot be found" (confirmed the
    # hard way: all 20 workers succeeding -- a GOOD result -- crashed
    # the script here on the first real Windows run).
    $failedWorkers = @($results | Where-Object { $_ -ne 0 }).Count
    $total = $workers * $iters
    if ($failedWorkers -eq 0) { Pass "12 soak: $workers workers x $iters iterations ($total calls) all succeeded" }
    else { Fail "12 soak: $failedWorkers/$workers workers had a failed call" }

    $t = Psql -Sql "SELECT 1;"
    if ($t -eq '1') { Pass "12 soak: cluster responsive after concurrent load" }
    else { Fail "12 soak: cluster unresponsive after concurrent load" }
}

# select_insert_update mode: fractalsql.text_to_sql_allowed_statements
# widens the allowlist from SELECT-only to SELECT/INSERT/UPDATE. Proves
# both halves of that: writes are now returned (not rejected) instead of
# executed (still just EXPLAINed, per t2s_check_explain), and DDL/DELETE
# remain rejected regardless -- the GUC only ever adds INSERT/UPDATE to
# the allowed set, never removes the DDL/DELETE block. Mirrors
# build_test.sh's gate 13. Pure SQL/GUC -- no plugin swap needed (runs
# against the mock plugin T2sExpect already drives through $SqlFile).
function Gate13SiuMode {
    if (-not (PgSetGuc -Name 'fractalsql.text_to_sql_allowed_statements' -SetVal "'select_insert_update'" -Want 'select_insert_update')) {
        Fail "13 siu_mode: GUC did not take effect"; return
    }

    T2sExpect 'INSERT INTO bt_orders (customer_id, total) VALUES (1, 100)' '' '13 siu-insert-allowed'
    T2sExpect 'UPDATE bt_orders SET total = 0'                             '' '13 siu-update-allowed'
    T2sExpect 'DROP TABLE bt_orders'          'not permitted' '13 siu-ddl-still-rejected'
    T2sExpect 'DELETE FROM bt_orders'         'not permitted' '13 siu-delete-still-rejected'

    $n = Psql -Sql "SELECT count(*) FROM bt_orders;"
    if ($n -eq '0') { Pass "13 siu_mode: INSERT/UPDATE never execute (bt_orders still empty)" }
    else { Fail "13 siu_mode: row count=$n" }

    PgSetGuc -Name 'fractalsql.text_to_sql_allowed_statements' -SetVal "'select'" -Want 'select' | Out-Null

    # ---- T-I: the check hook on fractalsql.text_to_sql_allowed_statements.
    # The GUC carries a check hook (src\fractalsql.c's
    # check_t2s_allowed_statements), so an invalid value is rejected AT
    # SET TIME rather than merely refused later.
    #
    # A session SET cannot reach the hook: the GUC is PGC_SIGHUP, so
    # PostgreSQL refuses the SET first ("cannot be changed now") and
    # the hook never runs. ALTER SYSTEM is the one path that validates
    # at set time, because that is where Postgres parses and checks the
    # value it is about to persist.
    $rI1 = Psql -Sql "SET fractalsql.text_to_sql_allowed_statements = 'bogus';"
    if ($rI1 -match 'cannot be changed now') {
        Pass "13 check-hook: a session SET of the PGC_SIGHUP GUC is refused by PostgreSQL itself"
    } else {
        Fail "13 check-hook: expected 'cannot be changed now', got: $rI1"
    }
    $rI2 = Psql -Sql "ALTER SYSTEM SET fractalsql.text_to_sql_allowed_statements = 'bogus';"
    if ($rI2 -match 'invalid value for parameter "fractalsql\.text_to_sql_allowed_statements"' -and $rI2 -match 'Allowed values are "select" and "select_insert_update"') {
        Pass "13 check-hook: ALTER SYSTEM rejects an invalid value and names the accepted ones"
    } else {
        Fail "13 check-hook: expected the check hook's rejection, got: $rI2"
    }
    # The rejected value must not have been persisted, and the server
    # must still be alive and serving the previous value.
    $autoConf = Join-Path $DataDir 'postgresql.auto.conf'
    if (Test-Path $autoConf) {
        $confText = Get-Content $autoConf -Raw
        if ($confText -notmatch 'bogus') {
            Pass "13 check-hook: the rejected value never reached postgresql.auto.conf"
        } else {
            Fail "13 check-hook: the rejected value was persisted to postgresql.auto.conf"
        }
    } else {
        Warn "13 check-hook: postgresql.auto.conf not found -- skipped the persistence check"
    }
    Psql -Sql "SELECT pg_reload_conf();" | Out-Null
    Start-Sleep -Seconds 2
    $rI3 = Psql -Sql "SELECT current_setting('fractalsql.text_to_sql_allowed_statements');"
    if ($rI3 -eq 'select') {
        Pass "13 check-hook: the effective value is unchanged after the rejected ALTER SYSTEM"
    } else {
        Fail "13 check-hook: expected the effective value to still be 'select', got: $rI3"
    }
    $rI4 = Psql -Sql "SELECT 1;"
    if ($rI4 -eq '1') {
        Pass "13 check-hook: the server survived the rejected ALTER SYSTEM"
    } else {
        Fail "13 check-hook: expected the server to be alive, got: $rI4"
    }
    Psql -Sql "ALTER SYSTEM RESET fractalsql.text_to_sql_allowed_statements;" | Out-Null
    Psql -Sql "SELECT pg_reload_conf();" | Out-Null

    # The check hook is deliberately NOT applied to
    # fractalsql.enterprise_lib: a rejecting hook there would fail the
    # config reload of every backend that has the library loaded (the
    # postmaster re-reads the same file), so an arbitrary path has to be
    # accepted there and the refusal is raised at USE time instead --
    # which is gate 31's job. Assert the asymmetry explicitly.
    $rI5 = Psql -Sql "ALTER SYSTEM SET fractalsql.enterprise_lib = 'C:/nonexistent/fractalsql_ent_probe.dll';"
    if ($rI5 -notmatch '(?i)error|invalid value') {
        Pass "13 check-hook: enterprise_lib deliberately has no check hook (an arbitrary path is accepted at set time)"
    } else {
        Fail "13 check-hook: expected enterprise_lib to accept any path, got: $rI5"
    }
    Psql -Sql "ALTER SYSTEM RESET fractalsql.enterprise_lib;" | Out-Null
    Psql -Sql "SELECT pg_reload_conf();" | Out-Null
}

# Retry-with-feedback: max_attempts>1 with a plugin (tests\windows\
# retry_reasoning_plugin_win.c) that returns a rejected DDL statement
# ("DROP TABLE bt_orders", fails the ALLOWLIST) on GENERATE call 1, then
# "SELECT 1" (passes) on call 2 -- exercising fractal_text_to_sql()'s
# retry loop (fractalsql.c, the `last_sql != NULL` prompt-rebuild branch)
# which every other gate leaves untouched (they all run at
# max_attempts=1, so the loop body only ever executes once). The plugin
# dumps the 2nd-call GENERATE prompt to $RetryPromptFile so this gate can
# confirm the attempt-1 rejection reason was actually threaded back into
# the attempt-2 prompt, not just that *a* retry happened. Mirrors
# build_test.sh's gate 14.
function Gate14Retry {
    # Fresh prompt file -- a stale file from a prior run must not fool the
    # feedback-threading assertion. (Cleanup also removes it on exit.)
    Remove-Item -Force $RetryPromptFile -ErrorAction SilentlyContinue
    if (-not (PgSetGuc -Name 'fractalsql.text_to_sql_max_attempts' -SetVal '2' -Want '2')) {
        Fail "14 retry: GUC did not take effect"; return
    }
    if (-not (PgSwapPlugin $Retry)) {
        Fail "14 retry: plugin swap did not take effect"
        PgSetGuc -Name 'fractalsql.text_to_sql_max_attempts' -SetVal '1' -Want '1' | Out-Null; return
    }

    $r = Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);"
    if ($r -match 'server closed the connection|could not connect') {
        Fail "14 retry: backend crashed -- $r"
    } elseif ($r -match '^SELECT 1') {
        Pass "14 retry: succeeded on 2nd attempt after 1st was rejected"
    } else {
        Fail "14 retry: expected eventual success (SELECT 1), got: $r"
    }

    # The plugin only writes the prompt file on call_count >= 2 (the
    # attempt-2 GENERATE prompt, which carries the attempt-1 rejection
    # feedback). Read it back to prove the feedback was threaded through.
    $prompt = Get-Content -Path $RetryPromptFile -Raw -ErrorAction SilentlyContinue
    if ($prompt -and $prompt -match 'not permitted') {
        Pass "14 retry: attempt-1 rejection reason fed back into attempt-2 prompt"
    } else {
        Fail "14 retry: retry prompt missing feedback text: '$prompt'"
    }

    $n = Psql -Sql "SELECT count(*) FROM bt_orders;"
    if ($n -eq '0') { Pass "14 retry: never-executes held across retries" }
    else { Fail "14 retry: row count=$n" }

    # --- review exhaustion: t2s_run_review's own exhausted-attempts branch
    #     (src\fractalsql.c: "exhausted %d attempt(s), last review verdict").
    #     Review PASSES only when the critique response starts with PASS
    #     (pg_strncasecmp(p, "PASS", 4) in t2s_run_review) -- and the
    #     standard MOCK plugin's REVIEW response can NEVER satisfy that, by
    #     construction: ensure_review_ctx() loads with RESPONSE_MODE unset
    #     (see its own comment), so mock_generate() always renders the
    #     canned file content as a ```sql-fenced chat response beginning
    #     "```s..." -- no sentinel content can ever produce a PASS prefix.
    #     max_attempts=1 therefore turns the first (and only) review FAIL
    #     directly into the exhaustion error. Mirrors build_test.sh's
    #     gate 14.
    if (-not (PgSetGuc -Name 'fractalsql.text_to_sql_max_attempts' -SetVal '1' -Want '1')) {
        Fail "14 review-exhaustion: max_attempts GUC did not take effect"; return
    }
    if (-not (PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'on' -Want 'on')) {
        Fail "14 review-exhaustion: use_review GUC did not take effect"; return
    }
    if (-not (PgSwapPlugin $Mock)) {
        Fail "14 review-exhaustion: plugin swap did not take effect"
        PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'off' -Want 'off' | Out-Null; return
    }
    Set-Content -Path $SqlFile -Value 'SELECT 1' -NoNewline
    $rr = Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);"
    if ($rr -match 'server closed the connection|could not connect') {
        Fail "14 review-exhaustion: backend crashed -- $rr"
    } elseif ($rr -match 'exhausted 1 attempt\(s\), last review verdict' -and $rr -match '```sql') {
        Pass "14 review-exhaustion: review FAIL twice over -> 'exhausted 1 attempt(s), last review verdict' with the mock's fenced critique"
    } else {
        Fail "14 review-exhaustion: expected the review-exhaustion rejection, got: $rr"
    }
    if ($rr -match 'Last candidate SQL: SELECT 1') {
        Pass "14 review-exhaustion: errdetail carries the last candidate SQL"
    } else {
        Fail "14 review-exhaustion: errdetail missing: '$rr'"
    }
    Remove-Item -Force $SqlFile -ErrorAction SilentlyContinue
    PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'off' -Want 'off' | Out-Null
    # max_attempts and the plugin are left at 1/$Mock by the restores below.

    PgSetGuc -Name 'fractalsql.text_to_sql_max_attempts' -SetVal '1' -Want '1' | Out-Null
    PgSwapPlugin $Mock | Out-Null
    Remove-Item -Force $RetryPromptFile -ErrorAction SilentlyContinue
}

# fractal_embed() + the vectorizer, real dispatch through
# ensure_embed_ctx()/g_embed_ctx (the three-tier reasoning-context split
# -- see fractalsql.c's own header comment) using a canned-vector mock
# plugin, not just the "no plugin configured"/"no http_embed_url
# configured" precondition-error paths every other gate here leaves
# untouched. HTTP-level embedding-response parsing is covered separately
# in tests/test_vectorizer.py against the real vendored plugin (Linux-
# verified; needs its own Windows equivalent if this repo ever wires
# psycopg into this harness -- not done here, see build_test.sh's own
# gate 15 comment for the identical scope note) -- this gate is about
# fractalsql-postgresql's OWN glue, matching every other gate's
# mock-plugin scope in this file. Mirrors build_test.sh's gate 15.
function Gate15Embed {
    Write-Information "  15 embed: starting..." -InformationAction Continue
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings')) {
        Fail "15 embed: http_embed_url GUC did not take effect"; return
    }
    if (-not (PgSwapPlugin $Embed)) { Fail "15 embed: plugin swap did not take effect"; return }

    $r = Psql -Sql "SELECT fractal_embed('test input');"
    if ($r -eq '{0.1,0.2,0.3}') { Pass "15 embed: fractal_embed() returned the canned vector" }
    else { Fail "15 embed: fractal_embed() expected {0.1,0.2,0.3}, got: $r" }

    $rnull = Psql -Sql "SELECT fractal_embed(NULL);"
    if ($rnull -match 'must not be NULL') { Pass "15 embed: NULL input rejected cleanly" }
    else { Fail "15 embed: NULL input expected a clear rejection, got: $rnull" }

    # Nonexistent plugin path -- exercises ensure_reasoning_tier_ctx's own
    # load-failure branch (distinct from "no plugin configured at all").
    if (-not (PgSetGuc -Name 'fractalsql.reasoning_plugin' -SetVal "'C:\fractalsql_bt_nonexistent.dll'" -Want 'C:\fractalsql_bt_nonexistent.dll')) {
        Fail "15 embed: bad-path GUC did not take effect"; PgSwapPlugin $Mock | Out-Null; return
    }
    $rbad = Psql -Sql "SELECT fractal_embed('test input');"
    if ($rbad -match 'failed to load reasoning plugin') { Pass "15 embed: nonexistent plugin path rejected cleanly" }
    else { Fail "15 embed: nonexistent plugin path expected a clear rejection, got: $rbad" }
    if (-not (PgSwapPlugin $Embed)) { Fail "15 embed: plugin swap back did not take effect"; PgSwapPlugin $Mock | Out-Null; return }

    # Evil embed: a plugin returning MAX_EMBED_DIM+1 (16385) floats must
    # be REJECTED, not silently truncated to a wrong-but-plausible 16384-
    # element vector -- a real bug fixed in parse_embedding_array()
    # alongside this test (see tests/evil_embed_plugin.c / build_test.sh's
    # matching gate 15 comment for the full story).
    if (-not (PgSwapPlugin $EvilEmbed)) { Fail "15 embed: evil_embed plugin swap did not take effect"; PgSwapPlugin $Mock | Out-Null; return }
    $revil = Psql -Sql "SELECT fractal_embed('test input');"
    if ($revil -match 'could not parse embedding response') { Pass "15 embed: over-limit embedding array rejected, not silently truncated" }
    else { Fail "15 embed: expected a clean rejection, got: $revil" }
    if (-not (PgSwapPlugin $Embed)) { Fail "15 embed: plugin swap back (post evil_embed) did not take effect"; PgSwapPlugin $Mock | Out-Null; return }

    Psql -Sql "DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_docs';" | Out-Null
    Psql -Sql "DROP TABLE IF EXISTS bt_embed_docs;" | Out-Null
    Psql -Sql "CREATE TABLE bt_embed_docs (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);" | Out-Null
    Psql -Sql "INSERT INTO bt_embed_docs (body) VALUES ('a'), ('b');" | Out-Null

    # SQL-injection-shaped source_table, same pattern gate 10 already
    # proves for fractal_schema_context/fractal_search_explore, extended
    # to the vectorizer's own dynamic SQL. Must fail cleanly via the
    # ::regclass cast before ever reaching format().
    $rinj = Psql -Sql "SELECT fractal_vectorizer_create('bt_embed_docs''; DROP TABLE bt_embed_docs; --', 'body', 'embedding');"
    $ninj = Psql -Sql "SELECT count(*) FROM bt_embed_docs;"
    if ($ninj -eq '2') { Pass "15 embed: injection-shaped source_table did not execute (bt_embed_docs intact)" }
    else { Fail "15 embed: bt_embed_docs row count changed (n=$ninj) -- injection may have executed" }
    if ($rinj -match 'invalid name syntax|does not exist|ERROR') { Pass "15 embed: injection-shaped source_table cleanly rejected" }
    else { Fail "15 embed: unexpected result: $rinj" }

    $vzid = Psql -Sql "SELECT fractal_vectorizer_create('bt_embed_docs', 'body', 'embedding');"

    # Double-create: same (source_table, text_col, embedding_col) again
    # must fail with a clean, fractal_-prefixed message naming the
    # existing vectorizer id -- not a raw "duplicate key value violates
    # unique constraint ..." that leaks the constraint name and a
    # PL/pgSQL stack frame.
    $rdup = Psql -Sql "SELECT fractal_vectorizer_create('bt_embed_docs', 'body', 'embedding');"
    if ($rdup -match "already exists \(id=$vzid\)") { Pass "15 embed: double-create rejected with a clean, specific error" }
    else { Fail "15 embed: expected a clean double-create rejection naming id=$vzid, got: $rdup" }

    $n = Psql -Sql "SELECT fractal_vectorizer_process_queue();"
    if ($n -eq '2') { Pass "15 embed: process_queue processed 2 backfilled rows" }
    else { Fail "15 embed: process_queue expected 2, got: $n" }

    $embedded = Psql -Sql "SELECT count(*) FROM bt_embed_docs WHERE embedding = '{0.1,0.2,0.3}';"
    if ($embedded -eq '2') { Pass "15 embed: both rows got the real embedding written back" }
    else { Fail "15 embed: expected 2 rows with the embedding written back, got: $embedded" }

    $status = Psql -Sql "SELECT status FROM fractal_vectorizer_status WHERE vectorizer_id = $vzid;"
    if ($status -eq 'done') { Pass "15 embed: vectorizer status shows done, no failures" }
    else { Fail "15 embed: expected status 'done', got: $status" }

    # --- vectorizer-failed-rows: the process_queue failure path
    #     (sql\fractalsql--1.0.sql's EXCEPTION WHEN OTHERS block: every
    #     failing row must END status='failed' with error=SQLERRM and an
    #     updated_at, visible through fractal_vectorizer_status's
    #     last_failure_at/last_error columns) -- plus the claim/retry logic
    #     that decides what "recovering" means. Disrupt ONE condition: blank
    #     fractalsql.http_embed_url the way this gate itself swaps GUCs
    #     (PgSetGuc = ALTER SYSTEM + reload + poll; save the pinned value
    #     and restore it below). With the URL unset, ensure_embed_ctx()
    #     (src\fractalsql.c) raises "fractal_embed:
    #     fractalsql.http_embed_url is not configured" before any dispatch
    #     -- deterministic, no HTTP involved. Two new trigger-enqueued rows
    #     exercise it. Mirrors build_test.sh's gate 15.
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "''" -Want '')) {
        Fail "15 vectorizer-failed-rows: could not blank fractalsql.http_embed_url"; return
    }
    Psql -Sql "INSERT INTO bt_embed_docs (body) VALUES ('c'), ('d');" | Out-Null
    $rfail = Psql -Sql "SELECT fractal_vectorizer_process_queue();"
    $nfail = Psql -Sql "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id = $vzid AND status = 'failed' AND COALESCE(error, '') <> '';"
    if ($nfail -eq '2') { Pass "15 vectorizer-failed-rows: both queued rows end status='failed' with a non-empty error" }
    else { Fail "15 vectorizer-failed-rows: expected 2 failed rows with an error string, got: $nfail ($rfail)" }
    $ftxt = Psql -Sql "SELECT bool_and(error LIKE '%http_embed_url is not configured%') FROM fractal_vectorizer_queue WHERE vectorizer_id = $vzid AND status = 'failed';"
    if ($ftxt -eq 't') { Pass "15 vectorizer-failed-rows: error carries the engine's own 'http_embed_url is not configured' message" }
    else { Fail "15 vectorizer-failed-rows: expected the ensure_embed_ctx error text in the queue rows, got: $ftxt" }
    # The view groups BY status (one row per queued-status group for this
    # vectorizer -- done/failed/... coexist), so assert on the failed GROUP's
    # presence, not on any one emitted line (the docker gate caught the
    # line-shape assumption: the done row sorts first, the failed row's
    # display truncates, and the line-regexes were order-fragile).
    $vstat = Psql -Sql "SELECT count(*) FROM fractal_vectorizer_status WHERE vectorizer_id = $vzid AND status = 'failed' AND last_failure_at IS NOT NULL AND last_error LIKE '%http_embed_url is not configured%';"
    if ($vstat -eq '1') {
        Pass "15 vectorizer-failed-rows: fractal_vectorizer_status shows the failed group with last_failure_at and last_error set"
    } else {
        Fail "15 vectorizer-failed-rows: expected the failed group row in fractal_vectorizer_status, got: $vstat"
    }

    # Recovery: the claim loop only ever picks status='pending' rows (the
    # FOR r IN SELECT ... WHERE q.status = 'pending' in process_queue), so a
    # bare re-run never retries the failed rows -- it returns 0 and leaves
    # them failed. Restoring the embed config alone is therefore not
    # enough; the operator path is a pending-reset UPDATE (the exact shape
    # of process_queue's own stale_after reclaim UPDATE), after which the
    # same rows complete with the canned embedding.
    $nretry = Psql -Sql "SELECT fractal_vectorizer_process_queue();"
    if ($nretry -eq '0') { Pass "15 vectorizer-failed-rows: a bare re-run does NOT retry failed rows (claim only picks 'pending'; returned 0)" }
    else { Fail "15 vectorizer-failed-rows: expected process_queue to not retry failed rows (0), got: $nretry" }
    # Restore the pinned embed URL FIRST: by itself it recovers nothing
    # (asserted above), and it is what lets the pending-reset rows below
    # actually succeed with the canned embedding.
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings')) {
        Fail "15 vectorizer-failed-rows: could not restore fractalsql.http_embed_url"; return
    }
    Psql -Sql "UPDATE fractal_vectorizer_queue SET status = 'pending', processing_started_at = NULL WHERE vectorizer_id = $vzid AND status = 'failed';" | Out-Null
    $nrec = Psql -Sql "SELECT fractal_vectorizer_process_queue();"
    if ($nrec -eq '2') { Pass "15 vectorizer-failed-rows: after restoring the config + a pending-reset, the recovered rows process to done" }
    else { Fail "15 vectorizer-failed-rows: expected 2 recovered rows after the pending-reset, got: $nrec" }
    $ndone = Psql -Sql "SELECT count(*) FROM bt_embed_docs WHERE embedding = '{0.1,0.2,0.3}';"
    if ($ndone -eq '4') { Pass "15 vectorizer-failed-rows: all 4 rows carry the canned embedding after recovery" }
    else { Fail "15 vectorizer-failed-rows: expected 4 embedded rows after recovery, got: $ndone" }

    Psql -Sql "DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_docs';" | Out-Null
    Psql -Sql "DROP TABLE IF EXISTS bt_embed_docs;" | Out-Null
    PgSwapPlugin $Mock | Out-Null
}

# Vectorizer authz: two real properties, not assumed from reading the
# GRANTs added alongside this test --
#   1. A role that owns its OWN table can fully use the vectorizer on
#      it (create, backfill, trigger-driven auto-enqueue on a new
#      write) without any DBA-granted access to fractal_vectorizers/
#      fractal_vectorizer_queue -- requires those tables' PUBLIC grants
#      (see sql/fractalsql--1.0.sql) plus fractal_vectorizer_enqueue()
#      being SECURITY DEFINER; a real bug before that fix was every
#      non-owner-of-the-tracking-tables role's INSERT into a vectorized
#      table failing entirely.
#   2. A DIFFERENT role, with no SELECT on that table, calling
#      fractal_vectorizer_process_queue() (which processes the GLOBAL
#      queue, not just its own caller's vectorizers) must not be able
#      to read or embed that table's content. Mirrors build_test.sh's
#      gate 16.
function Gate16EmbedAuthz {
    Write-Information "  16 embed_authz: starting..." -InformationAction Continue
    Psql -Sql @"
DROP ROLE IF EXISTS bt_embed_owner;
CREATE ROLE bt_embed_owner LOGIN;
GRANT CREATE ON SCHEMA public TO bt_embed_owner;
DROP ROLE IF EXISTS bt_embed_outsider;
CREATE ROLE bt_embed_outsider LOGIN;
"@ | Out-Null

    Psql -User 'bt_embed_owner' -Sql @"
CREATE TABLE bt_embed_owned (id serial PRIMARY KEY, body text, embedding float8[]);
INSERT INTO bt_embed_owned (body) VALUES ('owner data');
"@ | Out-Null

    $vzid = Psql -User 'bt_embed_owner' -Sql "SELECT fractal_vectorizer_create('bt_embed_owned', 'body', 'embedding');"
    $vzidNum = 0
    if ([int]::TryParse($vzid, [ref]$vzidNum)) {
        Pass "16 embed_authz: owner role created a vectorizer on its own table"
    } else {
        Fail "16 embed_authz: owner role could not create its own vectorizer: $vzid"
    }

    Psql -User 'bt_embed_owner' -Sql "INSERT INTO bt_embed_owned (body) VALUES ('second row, via trigger');" | Out-Null
    $qn = Psql -User 'bt_embed_owner' -Sql @"
SELECT count(*) FROM fractal_vectorizer_queue q
JOIN fractal_vectorizers v ON v.id = q.vectorizer_id
WHERE v.source_table = 'bt_embed_owned' AND q.status = 'pending';
"@
    if ($qn -eq '2') { Pass "16 embed_authz: backfill + trigger-driven enqueue both succeeded for the owner (2 pending)" }
    else { Fail "16 embed_authz: expected 2 pending rows (1 backfilled + 1 via trigger), got: $qn" }

    $rout = Psql -User 'bt_embed_outsider' -Sql "SELECT fractal_vectorizer_process_queue();"
    $statuses = Psql -User 'bt_embed_owner' -Sql @"
SELECT string_agg(DISTINCT q.status, ',') FROM fractal_vectorizer_queue q
JOIN fractal_vectorizers v ON v.id = q.vectorizer_id
WHERE v.source_table = 'bt_embed_owned';
"@
    if ($statuses -eq 'failed') { Pass "16 embed_authz: outsider's process_queue() call left both rows 'failed', not processed" }
    else { Fail "16 embed_authz: expected both rows 'failed' after the outsider's call, got statuses: $statuses" }

    $errtext = Psql -User 'bt_embed_owner' -Sql "SELECT last_error FROM fractal_vectorizer_status WHERE vectorizer_id = $vzid AND status = 'failed';"
    if ($errtext -match 'permission denied for table bt_embed_owned') { Pass "16 embed_authz: failure reason correctly names a permission error, not a data value" }
    else { Fail "16 embed_authz: expected a permission-denied error, got: $errtext" }

    $leaked = Psql -User 'bt_embed_owner' -Sql "SELECT embedding FROM bt_embed_owned WHERE embedding IS NOT NULL;"
    if ([string]::IsNullOrEmpty($leaked)) { Pass "16 embed_authz: no embedding was written by the unauthorized outsider's call" }
    else { Fail "16 embed_authz: an embedding was written despite the outsider lacking SELECT: $leaked" }

    Psql -Sql @"
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_owned';
DROP TABLE IF EXISTS bt_embed_owned;
DROP ROLE IF EXISTS bt_embed_owner;
DROP ROLE IF EXISTS bt_embed_outsider;
"@ | Out-Null

    # ---- the CONFUSED-DEPUTY half (the PROCESSOR's read) ----
    #
    # The asserts above prove the CALLER's own privileges are enforced:
    # the dynamic SELECT runs as the caller, so an outsider gets
    # Postgres's own "permission denied". The other half of the H fix is
    # the read that happens with the PROCESSOR's privileges.
    # fractal_vectorizer_process_queue() is SECURITY INVOKER, so it reads
    # the content column with whoever ran the batch -- and in the default
    # deployment that is the MCP server's own role, a SUPERUSER
    # (docker-compose.yml: PGUSER: postgres), while the vectorizer row may
    # have been registered by, and the queue row INSERTed by, a DIFFERENT
    # unprivileged role. fractal_vectorizers and fractal_vectorizer_queue
    # are both PUBLIC-writable, so without a gate an unprivileged role
    # could name ANY real relation and have the superuser's
    # process_queue() read that relation's content column and ship it to
    # the embedding provider -- the read is UNAUTHORIZED even though the
    # SQL that triggers it is legitimate.
    #
    # The gate now asks the vectorizer's CREATOR -- the role that
    # legitimately asked for this content to be embedded -- whether IT is
    # entitled to SELECT the content column. The creator is unforgeable
    # (pinned by fractal_vectorizer_pin_creator) and the target is
    # immutable (fractal_vectorizer_guard_identity), so the pair cannot be
    # steered at a target its creator is not entitled to.
    Psql -Sql @"
DROP ROLE IF EXISTS bt_dep_lowpriv;
CREATE ROLE bt_dep_lowpriv LOGIN;
GRANT USAGE ON SCHEMA public TO bt_dep_lowpriv;
DROP TABLE IF EXISTS bt_dep_secret;
CREATE TABLE bt_dep_secret (id int PRIMARY KEY, body text, embedding float8[]);
INSERT INTO bt_dep_secret(id, body) VALUES (1, 'the secret body');
REVOKE ALL ON bt_dep_secret FROM PUBLIC;
GRANT SELECT (id, embedding) ON bt_dep_secret TO bt_dep_lowpriv;
"@ | Out-Null

    # The registry row names a table the low-priv role does not own and
    # cannot read the content column of -- and ASKS to be attributed to a
    # superuser, so the pinning trigger has to refuse the attribution.
    $depid = Psql -User 'bt_dep_lowpriv' -Sql @"
INSERT INTO fractal_vectorizers
       (source_table, source_pk_col, text_col, embedding_col, created_by)
VALUES ('bt_dep_secret', 'id', 'body', 'embedding', 'postgres')
RETURNING id;
"@
    # psql prints the command tag ("INSERT 0 1") after the RETURNING row,
    # so the captured text is two lines -- take the first one only.
    $depid = (($depid -split "`r?`n") | Where-Object { $_ -ne '' } | Select-Object -First 1)
    $depidNum = 0
    if ([int]::TryParse($depid, [ref]$depidNum)) {
        $depOwner = Psql -Sql "SELECT created_by FROM fractal_vectorizers WHERE id = $depidNum;"
        if ($depOwner -eq 'bt_dep_lowpriv') {
            Pass "16 embed_authz: the registry row's creator is pinned to the inserting role (a forged superuser attribution is ignored)"
        } else {
            Fail "16 embed_authz: expected created_by=bt_dep_lowpriv (pinned), got: $depOwner"
        }
    } else {
        Fail "16 embed_authz: the low-priv role could not register a vectorizer row: $depid"
    }

    if ([int]::TryParse($depid, [ref]$depidNum)) {
        # The queue row is INSERTed by the same unprivileged role -- the
        # registry and the queue are both PUBLIC-writable.
        Psql -User 'bt_dep_lowpriv' -Sql "INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value) VALUES ($depidNum, '1');" | Out-Null

        # The PROCESSOR is the superuser: exactly the default deployment.
        Psql -Sql "SELECT fractal_vectorizer_process_queue();" | Out-Null

        $depErr = Psql -Sql @"
SELECT last_error FROM fractal_vectorizer_status
 WHERE vectorizer_id = $depidNum AND status = 'failed';
"@
        if ($depErr -match 'is not entitled to SELECT the content column') {
            Pass "16 embed_authz: the superuser's process_queue() refuses the low-priv creator's deputy read of the content column"
        } else {
            Fail "16 embed_authz: expected the entitlement refusal, got: $depErr"
        }

        $depLeak = Psql -Sql "SELECT embedding FROM bt_dep_secret WHERE embedding IS NOT NULL;"
        if ([string]::IsNullOrEmpty($depLeak)) {
            Pass "16 embed_authz: nothing was embedded, so the secret body never left the database"
        } else {
            Fail "16 embed_authz: an embedding was written despite the refused deputy read: $depLeak"
        }

        # The target and the creator are immutable against UPDATE, so a
        # privileged role cannot re-point an existing vectorizer at
        # another relation after the fact.
        $depRetarget = Psql -Sql "UPDATE fractal_vectorizers SET created_by = 'postgres' WHERE id = $depidNum;"
        if ($depRetarget -match 'immutable') {
            Pass "16 embed_authz: the registry row's creator cannot be re-attributed by an UPDATE"
        } else {
            Fail "16 embed_authz: expected the immutability guard to reject the re-attribution, got: $depRetarget"
        }

        # Positive control: once the creator IS entitled to the content
        # column, the entitlement gate must stop firing -- otherwise the
        # refusal above would prove nothing.
        Psql -Sql "GRANT SELECT (body) ON bt_dep_secret TO bt_dep_lowpriv;" | Out-Null
        $depEntitled = Psql -Sql "SELECT has_column_privilege('bt_dep_lowpriv', 'bt_dep_secret'::regclass, 'body', 'SELECT');"
        if ($depEntitled -eq 't') {
            Pass "16 embed_authz: the creator's column-level entitlement is what the gate reads"
        } else {
            Fail "16 embed_authz: expected has_column_privilege=true after the grant, got: $depEntitled"
        }

        Psql -User 'bt_dep_lowpriv' -Sql "UPDATE fractal_vectorizer_queue SET status = 'pending', error = NULL WHERE vectorizer_id = $depidNum;" | Out-Null
        Psql -Sql "SELECT fractal_vectorizer_process_queue();" | Out-Null
        $depErr2 = Psql -Sql @"
SELECT coalesce(max(last_error), '') FROM fractal_vectorizer_status
 WHERE vectorizer_id = $depidNum AND status = 'failed';
"@
        if ($depErr2 -match 'is not entitled to SELECT the content column') {
            Fail "16 embed_authz: the entitlement gate still fired after granting the creator SELECT on the content column"
        } else {
            Pass "16 embed_authz: once the creator is entitled, the entitlement gate stops firing (the refusal above was the gate, not a broken batch)"
        }
    }

    Psql -Sql @"
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_dep_secret';
DROP TABLE IF EXISTS bt_dep_secret;
DROP ROLE IF EXISTS bt_dep_lowpriv;
"@ | Out-Null
}

# Concurrent fractal_vectorizer_process_queue() calls against a SHARED
# queue, proving the "safe to call concurrently" claim (SELECT ... FOR
# UPDATE SKIP LOCKED) rather than assuming it: every row processed
# exactly once, no double-embedding, no row left behind, no worker
# error. Mirrors Gate12Soak's -Parallel pattern and build_test.sh's
# gate 17.
$EmbedSoakRows = 100
$EmbedSoakWorkers = 10
$EmbedSoakBatch = 5

function Gate17EmbedSoak {
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings')) {
        Fail "17 embed_soak: http_embed_url GUC did not take effect"; return
    }
    if (-not (PgSwapPlugin $Embed)) { Fail "17 embed_soak: plugin swap did not take effect"; return }

    Psql -Sql @"
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_soak';
DROP TABLE IF EXISTS bt_embed_soak;
CREATE TABLE bt_embed_soak (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
INSERT INTO bt_embed_soak (body) SELECT 'row ' || i FROM generate_series(1, $EmbedSoakRows) i;
"@ | Out-Null
    $vzid = Psql -Sql "SELECT fractal_vectorizer_create('bt_embed_soak', 'body', 'embedding');"
    $queued = Psql -Sql "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id = $vzid AND status = 'pending';"
    if ($queued -ne "$EmbedSoakRows") {
        Fail "17 embed_soak: setup: expected $EmbedSoakRows queued rows, got $queued"
        PgSwapPlugin $Mock | Out-Null; return
    }

    $itersPerWorker = [int]([math]::Floor($EmbedSoakRows / $EmbedSoakBatch)) + 2
    $results = 1..$EmbedSoakWorkers | ForEach-Object -Parallel {
        $bin = $using:Bin
        $port = $using:Port
        $batch = $using:EmbedSoakBatch
        $iters = $using:itersPerWorker
        $rc = 0
        $total = 0
        for ($i = 1; $i -le $iters; $i++) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "$bin\psql.exe"
            foreach ($a in @('-h','127.0.0.1','-p',"$port",'-U','postgres','-d','postgres','-X','-tA','-c',"SELECT fractal_vectorizer_process_queue($batch);")) {
                $psi.ArgumentList.Add($a)
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            # Concurrent async reads -- see the script-scope Psql
            # function's comment for why sequential ReadToEnd() can
            # deadlock on an unexpectedly large stderr payload.
            $soT = $proc.StandardOutput.ReadToEndAsync()
            $seT = $proc.StandardError.ReadToEndAsync()
            $proc.WaitForExit()
            $out = $soT.Result.Trim()
            $seT.Result | Out-Null
            $n = 0
            if ($proc.ExitCode -ne 0 -or -not [int]::TryParse($out, [ref]$n)) { $rc = 1 }
            else { $total += $n }
        }
        [PSCustomObject]@{ Rc = $rc; Total = $total }
    } -ThrottleLimit $EmbedSoakWorkers

    $failedWorkers = @($results | Where-Object { $_.Rc -ne 0 }).Count
    $sumProcessed = ($results | Measure-Object -Property Total -Sum).Sum

    if ($failedWorkers -eq 0) { Pass "17 embed_soak: $EmbedSoakWorkers concurrent workers, no call errored" }
    else { Fail "17 embed_soak: $failedWorkers/$EmbedSoakWorkers workers had a failed call" }

    if ($sumProcessed -eq $EmbedSoakRows) { Pass "17 embed_soak: exactly $EmbedSoakRows rows processed total (no double-count, none lost)" }
    else { Fail "17 embed_soak: expected $EmbedSoakRows rows processed summed across workers, got $sumProcessed" }

    $doneN = Psql -Sql "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id = $vzid AND status = 'done';"
    if ($doneN -eq "$EmbedSoakRows") { Pass "17 embed_soak: all $EmbedSoakRows queue rows are 'done', none stuck pending/processing" }
    else { Fail "17 embed_soak: expected $EmbedSoakRows rows 'done', got $doneN" }

    $embeddedN = Psql -Sql "SELECT count(*) FROM bt_embed_soak WHERE embedding = '{0.1,0.2,0.3}';"
    if ($embeddedN -eq "$EmbedSoakRows") { Pass "17 embed_soak: all $EmbedSoakRows rows got the embedding written back exactly once" }
    else { Fail "17 embed_soak: expected $EmbedSoakRows rows with the embedding, got $embeddedN" }

    Psql -Sql @"
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_soak';
DROP TABLE IF EXISTS bt_embed_soak;
"@ | Out-Null
    PgSwapPlugin $Mock | Out-Null
}

# Real crash mid-process_queue(), via the same deliberately-segfaulting
# plugin Gate06CrashRecovery already uses. fractal_vectorizer_process_
# queue() is one PL/pgSQL function call -- one transaction -- so a crash
# mid-call rolls back everything it touched, reverting rows to 'pending'
# rather than leaving them stuck in 'processing'. Confirmed against a
# real crash, not assumed. Mirrors build_test.sh's gate 18.
function Gate18EmbedCrash {
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings')) {
        Fail "18 embed_crash: http_embed_url GUC did not take effect"; return
    }

    Psql -Sql @"
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_crash';
DROP TABLE IF EXISTS bt_embed_crash;
CREATE TABLE bt_embed_crash (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
INSERT INTO bt_embed_crash (body) VALUES ('a'), ('b'), ('c');
"@ | Out-Null
    $vzid = Psql -Sql "SELECT fractal_vectorizer_create('bt_embed_crash', 'body', 'embedding');"

    if (-not (PgSwapPlugin $Crash)) { Fail "18 embed_crash: plugin swap did not take effect"; return }
    $r = Psql -Sql "SELECT fractal_vectorizer_process_queue();"
    if ($r -match 'server closed the connection|could not connect') {
        Pass "18 embed_crash: triggering connection dropped as expected"
    } else {
        Fail "18 embed_crash: expected the connection to drop, got: $r"
    }

    # See Gate06CrashRecovery's comment on why pass/fail budget and actual
    # up-detection must not share the same cutoff -- restoring the plugin
    # below depends on $up, and a near-miss here previously left the
    # crash plugin active for the rest of the run.
    $up = $false
    $withinBudget = $false
    $tries = 30 * $TimeoutMult
    for ($i = 0; $i -lt ($tries * 2); $i++) {
        $t = Psql -Sql "SELECT 1;"
        if ($t -eq '1') { $up = $true; if ($i -lt $tries) { $withinBudget = $true }; break }
        Start-Sleep -Milliseconds 500
    }
    if ($withinBudget) { Pass "18 embed_crash: cluster auto-restarted" }
    else { Fail "18 embed_crash: cluster did not come back within $($tries / 2)s" }
    if (-not $up) {
        Fail "18 embed_crash: cluster never came back -- remaining gates will run against the crash plugin"
        return
    }

    $statuses = Psql -Sql "SELECT string_agg(DISTINCT status, ',') FROM fractal_vectorizer_queue WHERE vectorizer_id = $vzid;"
    if ($statuses -eq 'pending') { Pass "18 embed_crash: all 3 rows reverted to 'pending' after the crash (atomic rollback, not stuck 'processing')" }
    else { Fail "18 embed_crash: expected all rows 'pending' post-crash, got statuses: $statuses" }

    if (-not (PgSwapPlugin $Embed)) { Fail "18 embed_crash: plugin swap to EMBED did not take effect"; PgSwapPlugin $Mock | Out-Null; return }
    $n = Psql -Sql "SELECT fractal_vectorizer_process_queue();"
    if ($n -eq '3') { Pass "18 embed_crash: post-recovery call processed all 3 previously-crashed rows" }
    else { Fail "18 embed_crash: expected 3 rows processed after recovery, got: $n" }

    $doneN = Psql -Sql "SELECT count(*) FROM bt_embed_crash WHERE embedding = '{0.1,0.2,0.3}';"
    if ($doneN -eq '3') { Pass "18 embed_crash: all 3 rows correctly embedded after recovery" }
    else { Fail "18 embed_crash: expected 3 embedded rows after recovery, got: $doneN" }

    Psql -Sql @"
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_crash';
DROP TABLE IF EXISTS bt_embed_crash;
"@ | Out-Null
    PgSwapPlugin $Mock | Out-Null
}

# validate_sfs_params() bounds for fractal_search/_debug/_explore, plus
# an injection-shaped table_name into fractal_search_explore (mirrors
# gate 10's equivalent test for fractal_schema_context). Mirrors
# build_test.sh's gate 19. The core library's FSQL_MAX_DIM=16384 ceiling
# is always tighter than MAX_QUERY_DIM and fires first, so the latter is
# effectively dead code.
function Gate19SfsBounds {
    $r = Psql -Sql "SELECT fractal_search(ARRAY(SELECT 0.1 FROM generate_series(1,16385)));"
    if ($r -match 'exceeds FSQL_MAX_DIM|out of range') { Pass "19 sfs_bounds: over-limit query dim (16385) rejected cleanly" }
    else { Fail "19 sfs_bounds: expected a clean dim-limit rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_search(ARRAY[]::float8[]);"
    if ($r -match '1-D non-null|must be non-empty') { Pass "19 sfs_bounds: empty query array rejected cleanly" }
    else { Fail "19 sfs_bounds: expected a clean empty-array rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_search(ARRAY[0.1,0.2]::float8[], 10001);"
    if ($r -match 'iterations 10001 out of range') { Pass "19 sfs_bounds: iterations over MAX_ITERATIONS (10000) rejected cleanly" }
    else { Fail "19 sfs_bounds: expected an iterations-limit rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_search(ARRAY[0.1,0.2]::float8[], 10, 100001);"
    if ($r -match 'population_size 100001 out of range') { Pass "19 sfs_bounds: population_size over MAX_POPULATION_SIZE (100000) rejected cleanly" }
    else { Fail "19 sfs_bounds: expected a population_size-limit rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_search(ARRAY[0.1,0.2]::float8[], 10, 20, 33);"
    if ($r -match 'diffusion_factor 33 out of range') { Pass "19 sfs_bounds: diffusion_factor over MAX_DIFFUSION_FACTOR (32) rejected cleanly" }
    else { Fail "19 sfs_bounds: expected a diffusion_factor-limit rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_search_debug(ARRAY[0.1,0.2]::float8[], 10, 20, 33);"
    if ($r -match 'diffusion_factor 33 out of range') { Pass "19 sfs_bounds: fractal_search_debug shares the same bounds check" }
    else { Fail "19 sfs_bounds: expected fractal_search_debug to reject diffusion_factor=33, got: $r" }

    # fractal_search_debug's full search-state telemetry: the result jsonb
    # is the vendored core's raw fsql_search_ptr JSON round-tripped through
    # jsonb_in, and its UNCONDITIONAL keys (one printf format in the core:
    # {"dim":%d,"n_corpus":%zu,"best_fit":...,"best_point":...}) must all
    # survive. Gate 02 only asserts best_point; this proves the debug
    # payload is the full state, not a reduced shape. Mirrors
    # build_test.sh's gate 19.
    $rdbg = Psql -Sql "SELECT fractal_search_debug(ARRAY[0.6,0.8]::float8[], 30, 50, 2);"
    if ($rdbg -match '"dim"' -and $rdbg -match '"n_corpus"' -and $rdbg -match '"best_fit"' -and $rdbg -match '"best_point"') {
        Pass "19 sfs_bounds: fractal_search_debug returns the full search-state telemetry (dim/n_corpus/best_fit/best_point)"
    } else {
        Fail "19 sfs_bounds: fractal_search_debug missing telemetry keys: $rdbg"
    }

    # Wrong-typed query arg: float8[] cannot be resolved from text[] (no
    # implicit array-element cast), so postgres's own type resolver rejects
    # before the C function ever runs. The C-side ARR_ELEMTYPE guard in
    # float8_array_to_doubles ("query must be float8[], got %s") is only
    # reachable from internal callers, not SQL typing.
    $rwt = Psql -Sql "SELECT fractal_search_debug('{0.1,0.2}'::text[], 30, 50, 2);"
    if ($rwt -match 'does not exist') { Pass "19 sfs_bounds: fractal_search_debug rejects a wrong-typed query arg (PG type resolution)" }
    else { Fail "19 sfs_bounds: expected a type-resolution rejection, got: $rwt" }

    $rinj = Psql -Sql "SELECT * FROM fractal_search_explore('bt_orders''; DROP TABLE bt_orders; --', 'vec', ARRAY[0.1,0.2]::float8[]);"
    $n = Psql -Sql "SELECT count(*) FROM bt_orders;"
    if ($n -eq '0') { Pass "19 sfs_bounds: injection-shaped table_name into fractal_search_explore did not execute (bt_orders intact)" }
    else { Fail "19 sfs_bounds: bt_orders row count changed (n=$n) -- injection may have executed" }
    if ($rinj -match 'does not exist|ERROR') { Pass "19 sfs_bounds: injection-shaped table_name cleanly rejected" }
    else { Fail "19 sfs_bounds: unexpected result: $rinj" }
}

# Closes 5 concrete API-surface coverage gaps found by a gap analysis
# against README's API table (each an explicit, existing code path --
# not speculative). Mirrors build_test.sh's Gate 20 line-for-line:
#   1. fractal_reason(): happy-path correctness was never checked --
#      every other gate touching it only asserts "didn't crash" /
#      "cleanly rejected a bad plugin", never "returned the right text".
#   2. fractal_reason(NULL): its own explicit PG_ARGISNULL(0) check
#      (fractal_reason isn't STRICT, unlike the search functions) had
#      zero coverage.
#   3. fractal_text_to_sql(NULL): same pattern, its own explicit
#      PG_ARGISNULL(0) check, zero coverage.
#   4. fractal_search_explore()'s bounds: it calls the same
#      validate_sfs_params() as fractal_search/_debug, but nothing had
#      ever proved that by actually passing an over-limit value through
#      its options jsonb.
#   5. fractal_vectorizer_process_queue()'s stale_after reclaim: Gate 16
#      already proved a crash can't produce a stuck 'processing' row in
#      the CURRENT implementation, but the reclaim UPDATE itself (the
#      WHERE processing_started_at < now() - stale_after clause) was
#      never independently exercised -- staged directly here, with a
#      negative control (a row still within the window) proving the
#      time comparison actually gates rather than reclaiming
#      unconditionally.
function Gate20ApiFunc {
    # --- 1: fractal_reason() happy path ---------------------------------
    Set-Content -Path $SqlFile -Value "gap-analysis-canary" -NoNewline
    $r1 = Psql -Sql "SELECT fractal_reason('q');"
    # Normalize CRLF -> LF before comparing: this is the first exact
    # multi-line string-equality check in this file (every other -eq/
    # -match elsewhere is single-line or a substring match), and it's
    # what first exposed a real Windows-specific quirk -- psql.exe's C
    # runtime writes its redirected stdout in text mode, which
    # translates embedded \n bytes in a query result into \r\n. The
    # mock plugin (and the real response) only ever emits plain \n; the
    # \r is a Windows stdio artifact of the pipe, not a content
    # difference, so strip it rather than build $expect1 with `r`n and
    # bake the artifact into the assertion.
    $r1Normalized = $r1 -replace "`r", ""
    $expect1 = "``````sql`ngap-analysis-canary`n``````"
    if ($r1Normalized -eq $expect1) { Pass "20 api_func: fractal_reason() returns the plugin's actual response" }
    else { Fail "20 api_func: fractal_reason() expected the fenced canary text, got: $r1" }
    Remove-Item -Force $SqlFile -ErrorAction SilentlyContinue

    # --- 2: fractal_reason(NULL) ----------------------------------------
    $r2 = Psql -Sql "SELECT fractal_reason(NULL);"
    if ($r2 -match 'query must not be NULL') { Pass "20 api_func: fractal_reason(NULL) rejected cleanly" }
    else { Fail "20 api_func: fractal_reason(NULL) expected a clear rejection, got: $r2" }

    # --- 3: fractal_text_to_sql(NULL) -----------------------------------
    $r3 = Psql -Sql "SELECT fractal_text_to_sql(NULL);"
    if ($r3 -match 'question must not be NULL') { Pass "20 api_func: fractal_text_to_sql(NULL) rejected cleanly" }
    else { Fail "20 api_func: fractal_text_to_sql(NULL) expected a clear rejection, got: $r3" }

    # --- 4: fractal_search_explore()'s own bounds ------------------------
    Psql -Sql @"
DROP TABLE IF EXISTS bt_explore_bounds;
CREATE TABLE bt_explore_bounds (id int, emb float8[]);
INSERT INTO bt_explore_bounds VALUES (1, ARRAY[0.1,0.2]::float8[]);
"@ | Out-Null
    $r4 = Psql -Sql @"
SELECT * FROM fractal_search_explore('bt_explore_bounds', 'emb',
  ARRAY[0.1,0.2]::float8[], '{"iterations": 10001}'::jsonb);
"@
    if ($r4 -match 'iterations 10001 out of range') { Pass "20 api_func: fractal_search_explore rejects an over-limit iterations option" }
    else { Fail "20 api_func: expected an iterations-limit rejection, got: $r4" }

    $r4b = Psql -Sql @"
SELECT * FROM fractal_search_explore('bt_explore_bounds', 'emb',
  ARRAY[0.1,0.2]::float8[], '{"diffusion_factor": 33}'::jsonb);
"@
    if ($r4b -match 'diffusion_factor 33 out of range') { Pass "20 api_func: fractal_search_explore rejects an over-limit diffusion_factor option" }
    else { Fail "20 api_func: expected a diffusion_factor-limit rejection, got: $r4b" }
    Psql -Sql "DROP TABLE IF EXISTS bt_explore_bounds;" | Out-Null

    # --- 5: fractal_vectorizer_process_queue()'s stale_after reclaim ----
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings')) {
        Fail "20 api_func: http_embed_url GUC did not take effect"; return
    }
    if (-not (PgSwapPlugin $Embed)) { Fail "20 api_func: plugin swap did not take effect"; PgSwapPlugin $Mock | Out-Null; return }

    Psql -Sql @"
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_stale_reclaim';
DROP TABLE IF EXISTS bt_stale_reclaim;
CREATE TABLE bt_stale_reclaim (id serial PRIMARY KEY, body text NOT NULL, embedding float8[]);
INSERT INTO bt_stale_reclaim (body) VALUES ('old-stuck'), ('recent-stuck');
"@ | Out-Null
    $vzid = Psql -Sql "SELECT fractal_vectorizer_create('bt_stale_reclaim', 'body', 'embedding');"

    # old-stuck: claimed 1 hour ago, past the 5-minute stale_after below
    # -- must be reclaimed. recent-stuck: claimed 30 seconds ago, still
    # within it -- must be left alone (the negative control).
    Psql -Sql @"
UPDATE fractal_vectorizer_queue q
   SET status = 'processing', processing_started_at = now() - interval '1 hour'
  FROM bt_stale_reclaim t
 WHERE q.vectorizer_id = $vzid AND t.body = 'old-stuck' AND q.source_pk_value = t.id::text;
UPDATE fractal_vectorizer_queue q
   SET status = 'processing', processing_started_at = now() - interval '30 seconds'
  FROM bt_stale_reclaim t
 WHERE q.vectorizer_id = $vzid AND t.body = 'recent-stuck' AND q.source_pk_value = t.id::text;
"@ | Out-Null

    Psql -Sql "SELECT fractal_vectorizer_process_queue(10, '5 minutes'::interval);" | Out-Null

    $statuses = Psql -Sql @"
SELECT t.body || '=' || q.status FROM fractal_vectorizer_queue q
JOIN bt_stale_reclaim t ON t.id::text = q.source_pk_value
WHERE q.vectorizer_id = $vzid ORDER BY t.body;
"@
    if ($statuses -match 'old-stuck=done') { Pass "20 api_func: a row stranded past stale_after was reclaimed and processed" }
    else { Fail "20 api_func: expected old-stuck=done, got: $statuses" }
    if ($statuses -match 'recent-stuck=processing') { Pass "20 api_func: a row still within stale_after was left alone, not reclaimed" }
    else { Fail "20 api_func: expected recent-stuck=processing (untouched), got: $statuses" }

    Psql -Sql @"
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_stale_reclaim';
DROP TABLE IF EXISTS bt_stale_reclaim;
"@ | Out-Null

    # --- 6: FSQL_MAX_INPUT_BYTES over-cap rejection (src\fractalsql.c:239).
    #     grep FSQL_MAX_INPUT_BYTES shows exactly ONE use site in this repo:
    #     the dispatch budget in fractal_embed() itself (its strlen check)
    #     -- fractal_text_to_sql() has NO byte cap to reject with (its
    #     input is the question string plus in-engine-built schema context;
    #     there is no engine-side over-cap error text to assert), so the
    #     overload call here goes to fractal_embed() only. 4 MiB + 1 chars,
    #     built with repeat(), and rejected BEFORE any plugin dispatch --
    #     deterministic even though the URL/embed GUCs are still configured
    #     for part 5 above. Mirrors build_test.sh's gate 20.
    $rov = Psql -Sql "SELECT fractal_embed(repeat('A', 4*1024*1024 + 1));"
    if ($rov -match 'fractal_embed: input exceeds the 4 MiB limit') {
        Pass "20 api_func: a 4 MiB + 1 embed input is rejected with the engine's own over-cap error"
    } else {
        Fail "20 api_func: expected 'input exceeds the 4 MiB limit', got: $rov"
    }

    PgSwapPlugin $Mock | Out-Null
}

# v2.x additions smoke gate -- HNSW/Diversify-era functions (dimension
# analysis, portfolio optimization, domain geometry, the named feature
# store, Diversify/feedback controls, table-backed telemetry/trajectory/
# cross-modal search). Deliberately a smoke gate, not exhaustive unit
# coverage -- proves the SQL wiring end-to-end against the real DLL, same
# scope/spirit as gate 02 and gate 11. Mirrors build_test.sh's gate 22.
#
# Fixture note: fractal_dimension_boxcount / _vascular_network /
# _nerve_plexus_metric / _morphological_complexity all bottom out in
# box-counting, which needs enough points AND enough dynamic range of
# scales to produce >= 3 valid epsilon buckets -- too few points (or an
# exactly-regular lattice) silently fails that filter even for
# well-defined geometry. The fixtures here are built INLINE via
# generate_series (no awk dependency -- fully portable, unlike
# build_test.sh's awk-generated fixtures) with deterministic non-
# degenerate coordinates chosen so every assertion's result key is
# present. Assertions only check the result jsonb carries the expected
# key (plus the two deterministic exact-value checks: the tetrahedron
# gyrification_index=1.0 and the feature-store k-NN order), matching
# build_test.sh's gate 22.
function Gate22V2Functions {
    # --- fixtures (inline generate_series, deterministic) ---------------
    # 40 box-count points (x,y) interleaved: point i = (i, i*0.5)
    $boxpts = "(SELECT array_agg(CASE WHEN g%2=1 THEN ((g+1)/2)::float8 ELSE ((g+1)/2)::float8*0.5 END) FROM generate_series(1,80) g)"
    # 30 vascular nodes (x,y,z): node i = (i, (i%7)*0.01, (i%5)*0.01)
    $vascNc = "(SELECT array_agg(CASE (g-1)%3 WHEN 0 THEN ((g-1)/3)::float8 WHEN 1 THEN (((g-1)/3)%7)*0.01 ELSE (((g-1)/3)%5)*0.01 END) FROM generate_series(1,90) g)"
    # 29 edges (src,dst): (0,1),(1,2),...,(28,29)
    $vascEl = "(SELECT array_agg(CASE (g-1)%2 WHEN 0 THEN ((g-1)/2)::int WHEN 1 THEN ((g-1)/2+1)::int END) FROM generate_series(1,58) g)"
    # 29 edge lengths (~1.0: consecutive nodes are ~1 apart in x; the y/z
    # jitter is ~0.01 so the true length is 1.0 to 4dp -- close enough that
    # the function's tortuosity is well-defined, which is all the assertion
    # checks for)
    $vascAl = "(SELECT array_agg(1.0::float8) FROM generate_series(1,29) g)"
    # 80 nerve nodes (x,y): node i = (i, (i%2) + (i%3)*0.001)
    $nerveNc = "(SELECT array_agg(CASE (g-1)%2 WHEN 0 THEN ((g-1)/2)::float8 ELSE ((g-1)/2 % 2)::float8 + ((g-1)/2 % 3)*0.001 END) FROM generate_series(1,160) g)"
    # 79 edges (src,dst): (0,1),...,(78,79)
    $nerveEl = "(SELECT array_agg(CASE (g-1)%2 WHEN 0 THEN ((g-1)/2)::int WHEN 1 THEN ((g-1)/2+1)::int END) FROM generate_series(1,158) g)"

    # --- 1: dimension analysis -----------------------------------------
    $r1 = Psql -Sql "SELECT fractal_dimension_dfa((SELECT array_agg(sin(i/3.0) + i*0.001) FROM generate_series(1,64) i));"
    if ($r1 -match '^[0-9]+\.[0-9]+$') { Pass "22 v2_functions: fractal_dimension_dfa returns a numeric exponent" }
    else { Fail "22 v2_functions: fractal_dimension_dfa expected a float8, got: $r1" }

    $r1b = Psql -Sql "SELECT fractal_dimension_dfa(ARRAY[1,2,3]::float8[]);"
    if ($r1b -match 'series needs >= 16 points') { Pass "22 v2_functions: fractal_dimension_dfa rejects a too-short series" }
    else { Fail "22 v2_functions: expected a too-short-series rejection, got: $r1b" }

    $r2 = Psql -Sql "SELECT fractal_dimension_boxcount($boxpts, 2);"
    if ($r2 -match '^[0-9]+\.[0-9]+$') { Pass "22 v2_functions: fractal_dimension_boxcount returns a numeric dimension" }
    else { Fail "22 v2_functions: fractal_dimension_boxcount expected a float8, got: $r2" }

    $r3 = Psql -Sql "SELECT fractal_dimension_drift((SELECT array_agg(sin(i/3.0) + i*0.001) FROM generate_series(1,200) i), 64);"
    if ($r3 -match '"drift"') { Pass "22 v2_functions: fractal_dimension_drift returns {drift, recent_alpha, baseline_alpha}" }
    else { Fail "22 v2_functions: fractal_dimension_drift expected a drift jsonb, got: $r3" }

    # --- 2: portfolio optimization -------------------------------------
    $r4 = Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.08,0.12,0.10,0.15]::float8[], ARRAY[0.04,0.01,0.01,0.01, 0.01,0.06,0.01,0.01, 0.01,0.01,0.05,0.01, 0.01,0.01,0.01,0.09]::float8[], 2, 12345);"
    if ($r4 -match '"sharpe"') { Pass "22 v2_functions: fractal_optimize_portfolio returns {sharpe, weights}" }
    else { Fail "22 v2_functions: fractal_optimize_portfolio expected a sharpe/weights jsonb, got: $r4" }

    $r4b = Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.1]::float8[], ARRAY[1.0]::float8[], 1, NULL);"
    if ($r4b -match 'cov length') { Pass "22 v2_functions: fractal_optimize_portfolio rejects a mismatched cov length" }
    else { Fail "22 v2_functions: expected a cov-length rejection, got: $r4b" }

    # diffusion_mode (parse_diffusion_mode in src/fractalsql.c): r4 above
    # omits it entirely (the 'gaussian' default), never exercising the
    # 'levy' branch or the rejection of an unrecognized value.
    $r4c = Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.08,0.12,0.10,0.15]::float8[], ARRAY[0.04,0.01,0.01,0.01, 0.01,0.06,0.01,0.01, 0.01,0.01,0.05,0.01, 0.01,0.01,0.01,0.09]::float8[], 2, 12345, false, 'levy');"
    if ($r4c -match '"sharpe"') { Pass "22 v2_functions: fractal_optimize_portfolio diffusion_mode=levy returns {sharpe, weights}" }
    else { Fail "22 v2_functions: diffusion_mode=levy='$r4c'" }

    $r4d = Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.08,0.12,0.10,0.15]::float8[], ARRAY[0.04,0.01,0.01,0.01, 0.01,0.06,0.01,0.01, 0.01,0.01,0.05,0.01, 0.01,0.01,0.01,0.09]::float8[], 2, 12345, false, 'bogus');"
    if ($r4d -match 'diffusion_mode must be') { Pass "22 v2_functions: fractal_optimize_portfolio rejects an unrecognized diffusion_mode" }
    else { Fail "22 v2_functions: expected a diffusion_mode rejection, got: $r4d" }

    # --- 3: domain-specific geometry -----------------------------------
    $r5 = Psql -Sql "SELECT fractal_morphological_complexity($boxpts, 2);"
    if ($r5 -match '"lacunarity"') { Pass "22 v2_functions: fractal_morphological_complexity returns {dimension, lacunarity}" }
    else { Fail "22 v2_functions: fractal_morphological_complexity expected a dimension/lacunarity jsonb, got: $r5" }

    $r6 = Psql -Sql "SELECT fractal_vascular_network($vascNc, $vascEl, $vascAl);"
    if ($r6 -match '"mean_tortuosity"') { Pass "22 v2_functions: fractal_vascular_network returns {mean_tortuosity, branch_density, fractal_dimension}" }
    else { Fail "22 v2_functions: fractal_vascular_network expected a tortuosity jsonb, got: $r6" }

    $r7 = Psql -Sql "SELECT fractal_nerve_plexus_metric($nerveNc, 2, $nerveEl);"
    if ($r7 -match '"fiber_length_density"') { Pass "22 v2_functions: fractal_nerve_plexus_metric returns {fiber_length_density, branch_density, fractal_dimension}" }
    else { Fail "22 v2_functions: fractal_nerve_plexus_metric expected a fiber-density jsonb, got: $r7" }

    # Tetrahedron: mesh IS its own convex hull, so gyrification_index must
    # be exactly 1.0 -- a clean deterministic check, not just "didn't error".
    $r8 = Psql -Sql "SELECT fractal_cortical_folding(ARRAY[0,0,0, 1,0,0, 0,1,0, 0,0,1]::float8[], ARRAY[0,1,2, 0,1,3, 0,2,3, 1,2,3]::int4[]);"
    if ($r8 -match '"gyrification_index": 1\.0000000000') { Pass "22 v2_functions: fractal_cortical_folding gives gyrification_index=1.0 for a tetrahedron (mesh == its own hull)" }
    else { Fail "22 v2_functions: expected gyrification_index=1.0 for a tetrahedron, got: $r8" }

    # --- 4: named feature store (postgres-side, no core primitive) ------
    Psql -Sql @"
DELETE FROM fractalsql_feature_store WHERE doc_id IN (901,902,903,904);
SELECT fractal_store_morphology(901, ARRAY[0.0,0.0,0.0]::float8[]);
SELECT fractal_store_morphology(902, ARRAY[10.0,10.0,10.0]::float8[]);
SELECT fractal_store_morphology(903, ARRAY[1.0,0.0,0.0]::float8[]);
SELECT fractal_store_morphology(904, ARRAY[0.5,0.5,0.5]::float8[]);
"@ | Out-Null
    # upsert-overwrite: doc 901 moves far away, must drop out of a k=2 mine
    Psql -Sql "SELECT fractal_store_morphology(901, ARRAY[100.0,100.0,100.0]::float8[]);" | Out-Null
    $r9 = Psql -Sql "SELECT string_agg(doc_id::text, ',' ORDER BY distance) FROM fractal_mine_topology_negatives(ARRAY[0.0,0.0,0.0]::float8[], 2) WHERE doc_id IN (901,902,903,904);"
    if ($r9 -eq '904,903') { Pass "22 v2_functions: fractal_mine_topology_negatives k-NN order + upsert-overwrite correct" }
    else { Fail "22 v2_functions: expected mine order 904,903 (901 overwritten far away), got: $r9" }

    $r9b = Psql -Sql "SELECT fractal_store_morphology(-1, ARRAY[1.0]::float8[]);"
    if ($r9b -match 'doc_id must be >= 0') { Pass "22 v2_functions: fractal_store_morphology rejects a negative doc_id" }
    else { Fail "22 v2_functions: expected a negative-doc_id rejection, got: $r9b" }

    $r9c = Psql -Sql "SELECT fractal_mine_topology_negatives(ARRAY[0.0]::float8[], 0);"
    if ($r9c -match 'k must be > 0') { Pass "22 v2_functions: fractal_mine_topology_negatives rejects k<=0" }
    else { Fail "22 v2_functions: expected a k<=0 rejection, got: $r9c" }

    Psql -Sql "DELETE FROM fractalsql_feature_store WHERE doc_id IN (901,902,903,904);" | Out-Null

    # --- 5: Diversify / feedback controls ------------------------------
    Psql -Sql "SELECT fractal_diversify_enable();" | Out-Null
    Psql -Sql "SELECT fractal_diversify_set_params(20, 0.1, 1.0, 0.5, 100, 50);" | Out-Null
    $r10 = Psql -Sql "SELECT fractal_explain_result();"
    if ($r10 -match '"diversify_enabled": true') { Pass "22 v2_functions: fractal_explain_result reflects diversify_enabled after enable" }
    else { Fail "22 v2_functions: expected diversify_enabled=true, got: $r10" }

    $fbr = Psql -Sql "SELECT fractal_feedback_report(0, 'negative', 100);"
    if ($fbr -match 'ERROR') { Fail "22 v2_functions: fractal_feedback_report errored on a valid call: $fbr" }
    else { Pass "22 v2_functions: fractal_feedback_report accepted a valid negative-engagement report" }

    $r11 = Psql -Sql "SELECT fractal_feedback_report(0, 'bogus', NULL);"
    if ($r11 -match 'kind must be one of') { Pass "22 v2_functions: fractal_feedback_report rejects an invalid kind" }
    else { Fail "22 v2_functions: expected an invalid-kind rejection, got: $r11" }

    Psql -Sql "SELECT fractal_diversify_disable();" | Out-Null

    # --- 6: table-backed top-k telemetry search + thin compositions -----
    Psql -Sql @"
DROP TABLE IF EXISTS bt_telemetry_docs;
CREATE TABLE bt_telemetry_docs (id serial PRIMARY KEY, emb float8[]);
INSERT INTO bt_telemetry_docs (emb) VALUES
  (ARRAY[1.0,0.0,0.0]::float8[]),
  (ARRAY[0.0,1.0,0.0]::float8[]),
  (ARRAY[0.9,0.1,0.0]::float8[]),
  (ARRAY[0.0,0.0,1.0]::float8[]),
  (ARRAY[0.5,0.5,0.0]::float8[]);
"@ | Out-Null

    # telemetry/hybrid report doc_id as a ctid (text), not a 0-indexed scan
    # position. Each assertion joins t.doc_id back to the real row via
    # d.ctid::text = t.doc_id and checks the table's own id. This verifies
    # the ctid mapping and stays independent of the physical page layout.
    $r12 = Psql -Sql "SELECT d.id, t.distance FROM fractal_search_telemetry('bt_telemetry_docs', 'emb', ARRAY[1.0,0.0,0.0]::float8[], 2) t JOIN bt_telemetry_docs d ON d.ctid::text = t.doc_id ORDER BY t.distance LIMIT 1;"
    if ($r12 -eq '1|0') { Pass "22 v2_functions: fractal_search_telemetry finds the exact match at distance 0 (ctid doc_id resolves to id 1)" }
    else { Fail "22 v2_functions: expected id=1 dist=0 first via the ctid doc_id, got: $r12" }

    # The old 0-indexed cohort doc_ids [1,3,4] were scan positions of
    # physical rows 2,4,5. In the ctid world the cohort is built with
    # ordinary SQL (array_agg of ctid::text) and the expected id order is
    # the same three rows in the same distance order: 2,5,4.
    # CRLF normalization: psql -tA prints one row per line, and the Windows
    # C runtime writes \r\n -- see Gate20ApiFunc's matching note. The
    # multi-line exact-equality check below needs LF-only to compare.
    $r13 = (Psql -Sql "SELECT d.id FROM fractal_hybrid_clinical_search('bt_telemetry_docs', 'emb', ARRAY[0.0,1.0,0.0]::float8[], (SELECT array_agg(ctid::text) FROM bt_telemetry_docs WHERE id IN (2,4,5)), 3) t JOIN bt_telemetry_docs d ON d.ctid::text = t.doc_id ORDER BY t.distance;") -replace "`r", ""
    if ($r13 -eq "2`n5`n4") { Pass "22 v2_functions: fractal_hybrid_clinical_search restricts to the ctid cohort and returns real row ids" }
    else { Fail "22 v2_functions: expected doc_ids 2,5,4 in that order, got: $r13" }

    $r14 = Psql -Sql "SELECT fractal_hybrid_clinical_search('bt_telemetry_docs', 'emb', ARRAY[0.0,1.0,0.0]::float8[], ARRAY['(999,1)']::text[], 1);"
    if ($r14 -match 'cohort matched no rows') { Pass "22 v2_functions: fractal_hybrid_clinical_search rejects a cohort matching zero rows" }
    else { Fail "22 v2_functions: expected a no-rows-matched rejection, got: $r14" }

    $r15 = Psql -Sql "SELECT doc_id, distance FROM fractal_search_trajectory('bt_telemetry_docs', 'emb', ARRAY[0.0,0.0,0.0]::float8[], ARRAY[1.0,0.0,0.0]::float8[], 1);"
    if ($r15 -match '^0\|0') { Pass "22 v2_functions: fractal_search_trajectory searches near the delta vector" }
    else { Fail "22 v2_functions: expected doc_id=0 dist=0 for a [1,0,0] delta, got: $r15" }

    # fractal_vector-typed overload (fractal_search_trajectory_fv): the
    # call above only ever resolves the float8[] signature -- confirmed
    # via gcov this never ran before this (0% coverage), same for its
    # shared decode_vector_datum helper.
    $r15fv = Psql -Sql "SELECT doc_id, distance FROM fractal_search_trajectory('bt_telemetry_docs', 'emb', '[0.0,0.0,0.0]'::fractal_vector, '[1.0,0.0,0.0]'::fractal_vector, 1);"
    if ($r15fv -match '^0\|0') { Pass "22 v2_functions: fractal_search_trajectory (fractal_vector overload) searches near the delta vector" }
    else { Fail "22 v2_functions: expected doc_id=0 dist=0 for a [1,0,0] delta (fv overload), got: $r15fv" }

    Psql -Sql @"
DROP TABLE IF EXISTS bt_combined_docs;
CREATE TABLE bt_combined_docs (id serial PRIMARY KEY, emb float8[]);
INSERT INTO bt_combined_docs (emb) VALUES
  (ARRAY[1.0,0.0, 0.0,0.0]::float8[]),
  (ARRAY[0.0,0.0, 1.0,0.0]::float8[]);
"@ | Out-Null
    $r16 = Psql -Sql "SELECT doc_id, distance FROM fractal_cross_modal_search('bt_combined_docs', 'emb', ARRAY[1.0,0.0]::float8[], ARRAY[1.0,0.0]::float8[], 1.0, 1);"
    if ($r16 -match '^0\|0') { Pass "22 v2_functions: fractal_cross_modal_search at alpha=1.0 favors the morphology-only row" }
    else { Fail "22 v2_functions: expected doc_id=0 dist=0 at alpha=1.0, got: $r16" }

    # fractal_vector-typed overload (fractal_cross_modal_search_fv):
    # same table/query as r16, just fractal_vector-cast -- confirmed
    # via gcov this never ran before this (0% coverage).
    $r16fv = Psql -Sql "SELECT doc_id, distance FROM fractal_cross_modal_search('bt_combined_docs', 'emb', '[1.0,0.0]'::fractal_vector, '[1.0,0.0]'::fractal_vector, 1.0, 1);"
    if ($r16fv -match '^0\|0') { Pass "22 v2_functions: fractal_cross_modal_search (fractal_vector overload) at alpha=1.0 favors the morphology-only row" }
    else { Fail "22 v2_functions: expected doc_id=0 dist=0 at alpha=1.0 (fv overload), got: $r16fv" }

    $r17 = Psql -Sql "SELECT fractal_cross_modal_search('bt_combined_docs', 'emb', ARRAY[1.0,0.0]::float8[], ARRAY[1.0,0.0]::float8[], 1.5, 1);"
    if ($r17 -match 'alpha_weight must be in') { Pass "22 v2_functions: fractal_cross_modal_search rejects an out-of-range alpha_weight" }
    else { Fail "22 v2_functions: expected an alpha_weight rejection, got: $r17" }

    Psql -Sql "DROP TABLE IF EXISTS bt_telemetry_docs, bt_combined_docs;" | Out-Null

    # --- 7: rejection-class sweep for the v2.x primitives, extending the
    #     happy paths gates 22/29/30 already prove. Every string asserted
    #     here is this repo's own error text (src\fractalsql.c /
    #     src\fractalsql_vector.c), not the SQLite sibling's wording.
    #     Mirrors build_test.sh's gate 22 section 7.
    $rk1 = Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.05]::float8[], ARRAY[0.04,0.01,0.01,0.03]::float8[], 0, 1);"
    if ($rk1 -match 'k must satisfy 1 <= k <= n_assets') { Pass "22 rejection: optimize_portfolio rejects k<=0" }
    else { Fail "22 rejection: expected the k<=0 rejection, got: $rk1" }
    $rk2 = Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.05]::float8[], ARRAY[0.04,0.01,0.01,0.03]::float8[], 3, 1);"
    if ($rk2 -match 'k must satisfy 1 <= k <= n_assets') { Pass "22 rejection: optimize_portfolio rejects k>n_assets" }
    else { Fail "22 rejection: expected the k>n_assets rejection, got: $rk2" }

    $rt1 = Psql -Sql "SELECT fractal_tda_persistence_diagram(ARRAY[0.0,0.0,1.0,1.0]::float8[], 0);"
    if ($rt1 -match 'dim must be > 0') { Pass "22 rejection: tda_persistence_diagram rejects dim<=0" }
    else { Fail "22 rejection: expected a dim<=0 rejection, got: $rt1" }
    $rt2 = Psql -Sql "SELECT fractal_tda_persistence_diagram(ARRAY[0.0,1.0]::float8[], 3);"
    if ($rt2 -match [regex]::Escape('points length (2) must be a multiple of dim (3)')) { Pass "22 rejection: tda_persistence_diagram rejects a point list that is not a multiple of dim" }
    else { Fail "22 rejection: expected a points-length rejection, got: $rt2" }
    $rt3 = Psql -Sql "SELECT fractal_tda_persistence_diagram(ARRAY[0.0,0.0]::float8[], 2);"
    if ($rt3 -match '2 <= n_points') { Pass "22 rejection: tda_persistence_diagram rejects a single-point cloud (n_points >= 2)" }
    else { Fail "22 rejection: expected a too-few-points rejection, got: $rt3" }
    $rt4 = Psql -Sql "SELECT fractal_tda_persistence_diagram(ARRAY[0.0,0.0,1.0,1.0,2.0,2.0]::float8[], 2, 2);"
    if ($rt4 -match 'max_dim in \{0,1\}') { Pass "22 rejection: tda_persistence_diagram rejects max_dim=2 (core supports only {0,1})" }
    else { Fail "22 rejection: expected a max_dim rejection, got: $rt4" }

    $rp1 = Psql -Sql "SELECT fractal_periodogram(ARRAY[1.0,2.0,3.0,4.0]::float8[], 0);"
    if ($rp1 -match 'max_peaks must be > 0') { Pass "22 rejection: periodogram rejects max_peaks<=0" }
    else { Fail "22 rejection: expected a max_peaks rejection, got: $rp1" }
    $rp2 = Psql -Sql "SELECT fractal_periodogram(ARRAY[1.0,2.0,3.0]::float8[], 4);"
    if ($rp2 -match 'need n >= 4') { Pass "22 rejection: periodogram rejects a too-short series" }
    else { Fail "22 rejection: expected a need-n>=4 rejection, got: $rp2" }
    $rp3 = Psql -Sql "SELECT fractal_periodogram(ARRAY[[1.0,2.0],[3.0,4.0]]::float8[], 4);"
    if ($rp3 -match 'query must be 1-D non-null float8\[\]') { Pass "22 rejection: periodogram rejects a 2-D (malformed) series" }
    else { Fail "22 rejection: expected the 1-D-non-null rejection, got: $rp3" }

    # (The negative hamming_threshold branch is gate 30's already.)
    $rc1 = Psql -Sql "SELECT count(*) FROM fractal_cycle_detect(ARRAY[]::bytea[], 0);"
    if ($rc1 -match 'fingerprints array must not be empty') { Pass "22 rejection: cycle_detect rejects an empty fingerprints array" }
    else { Fail "22 rejection: expected an empty-array rejection, got: $rc1" }
    $rc2 = Psql -Sql "SELECT count(*) FROM fractal_cycle_detect(ARRAY['ab'::bytea, NULL]::bytea[], 0);"
    if ($rc2 -match 'fingerprints array must not contain NULLs') { Pass "22 rejection: cycle_detect rejects a NULL fingerprint element" }
    else { Fail "22 rejection: expected a NULL-element rejection, got: $rc2" }
    $rc3 = Psql -Sql "SELECT count(*) FROM fractal_cycle_detect(ARRAY['ab'::bytea, 'abc'::bytea]::bytea[], 0);"
    if ($rc3 -match 'every fingerprint must be the same length') { Pass "22 rejection: cycle_detect rejects mixed-length fingerprints" }
    else { Fail "22 rejection: expected a length-mismatch rejection, got: $rc3" }

    $rs1 = Psql -Sql "SELECT fractal_state_fingerprint(ARRAY[[1.0,2.0],[3.0,4.0]]::float8[], 8, 42);"
    if ($rs1 -match 'query must be 1-D non-null float8\[\]') { Pass "22 rejection: state_fingerprint rejects a 2-D vec" }
    else { Fail "22 rejection: expected a 1-D-non-null rejection, got: $rs1" }

    # The native vector type's dimension cap -- the REAL cap is
    # FRACTALVEC_MAX_DIM = 32767 (src\fractalsql_vector.c). fractal_vector_
    # add's happy path is gate 29's; this covers its input-parse rejection
    # surface.
    $rv1 = Psql -Sql "SELECT fractal_vector_add('[]'::fractal_vector, '[1,2,3]'::fractal_vector);"
    if ($rv1 -match 'fractal_vector dimension must be between 1 and 32767, got 0') { Pass "22 rejection: fractal_vector rejects a zero-dimension ('[]') input" }
    else { Fail "22 rejection: expected the zero-dim rejection, got: $rv1" }
    $rv2 = Psql -Sql "SELECT fractal_vector_add('[1,2'::fractal_vector, '[1,2,3]'::fractal_vector);"
    if ($rv2 -match "expected ']'") { Pass "22 rejection: fractal_vector_add rejects an unclosed vector literal" }
    else { Fail "22 rejection: expected an unclosed-literal rejection, got: $rv2" }
    $rv3 = Psql -Sql "SELECT fractal_vector_dims(('[' || repeat('1,', 32767) || '1]')::fractal_vector);"
    if ($rv3 -match 'dimension exceeds maximum 32767') { Pass "22 rejection: fractal_vector rejects dim>32767 (32768-element literal)" }
    else { Fail "22 rejection: expected the 32767-cap rejection, got: $rv3" }

    # NULL required vector args: the portfolio entries are deliberately
    # non-STRICT (their optional args use SQL-side NULL defaults), so a NULL
    # mu/cov can legally arrive -- and the C entry used to deref it (backend
    # SIGSEGV; the in-function guard now rejects cleanly). One case per
    # entry: mu-null on _portfolio, cov-null on _portfolio, and mu-null on
    # both multimodal entries.
    $rn1 = Psql -Sql "SELECT fractal_optimize_portfolio(NULL, '{0.5,0.5,0.5,0.5}'::float8[], 1);"
    if ($rn1 -match 'fractal_optimize_portfolio: mu must not be NULL') { Pass "22 rejection: fractal_optimize_portfolio rejects a NULL mu" }
    else { Fail "22 rejection: expected the NULL-mu rejection, got: $rn1" }
    $rn2 = Psql -Sql "SELECT fractal_optimize_portfolio('{0.25,0.25,0.5,0}'::float8[], NULL, 1);"
    if ($rn2 -match 'fractal_optimize_portfolio: cov must not be NULL') { Pass "22 rejection: fractal_optimize_portfolio rejects a NULL cov" }
    else { Fail "22 rejection: expected the NULL-cov rejection, got: $rn2" }
    $rn3 = Psql -Sql "SELECT fractal_optimize_portfolio_multimodal(NULL, '{0.25,0.25,0.5,0}'::float8[], 2, 1, 0.25, 0.9, 42, false, 'diffusion');"
    if ($rn3 -match 'fractal_optimize_portfolio_multimodal: mu must not be NULL') { Pass "22 rejection: fractal_optimize_portfolio_multimodal rejects a NULL mu" }
    else { Fail "22 rejection: expected the multimodal NULL-mu rejection, got: $rn3" }
    $rn4 = Psql -Sql "SELECT fractal_optimize_portfolio_multimodal_pareto(NULL, '{0.25,0.25,0.5,0}'::float8[], 2, 1, 8, 42, false, 'diffusion');"
    if ($rn4 -match 'fractal_optimize_portfolio_multimodal_pareto: mu must not be NULL') { Pass "22 rejection: fractal_optimize_portfolio_multimodal_pareto rejects a NULL mu" }
    else { Fail "22 rejection: expected the pareto NULL-mu rejection, got: $rn4" }

    # ---- T-H: fractal_vector_to_json() / fractal_vector_from_text().
    # A JSON and a text front end for the native vector type. The JSON
    # is built on the type's OWN text rendering, deliberately NOT on a
    # float8[] round trip (which would widen 0.1f to
    # 0.10000000149011612) -- that difference is the point, so it is
    # asserted rather than assumed.
    $rh1 = Psql -Sql "SELECT fractal_vector_to_json('[1,2,3]'::fractal_vector)::text;"
    if (($rh1 -replace '\s','') -eq '[1,2,3]') { Pass "22 vector-json: to_json renders a vector as a JSON array" }
    else { Fail "22 vector-json: expected '[1, 2, 3]', got: $rh1" }
    $rh2 = Psql -Sql "SELECT fractal_vector_to_json('[0.1,0.2,0.3]'::fractal_vector) = '[0.1,0.2,0.3]'::fractal_vector::text::jsonb;"
    if ($rh2 -eq 't') { Pass "22 vector-json: to_json is exactly the type's own text rendering parsed as JSON" }
    else { Fail "22 vector-json: expected the JSON to match the type's own text rendering, got: $rh2" }
    $rh3 = Psql -Sql "SELECT fractal_vector_to_json('[0.1]'::fractal_vector) <> to_jsonb('[0.1]'::fractal_vector::float8[]);"
    if ($rh3 -eq 't') { Pass "22 vector-json: the JSON is deliberately NOT the float8[] round trip (which would widen 0.1f)" }
    else { Fail "22 vector-json: expected the JSON to differ from the float8[] round trip, got: $rh3" }

    # from_text: exactly two accepted forms -- a JSON/pgvector-style
    # array and a plain comma-separated list -- each with and without
    # spaces after the commas.
    $rh4 = Psql -Sql "SELECT fractal_vector_from_text('[1,2,3]')::text;"
    if ($rh4 -eq '[1,2,3]') { Pass "22 vector-text: from_text parses the array form" }
    else { Fail "22 vector-text: expected '[1,2,3]', got: $rh4" }
    $rh5 = Psql -Sql "SELECT fractal_vector_from_text('1,2,3')::text;"
    if ($rh5 -eq '[1,2,3]') { Pass "22 vector-text: from_text parses the plain list form" }
    else { Fail "22 vector-text: expected '[1,2,3]' from the list form, got: $rh5" }
    $rh6 = Psql -Sql "SELECT fractal_vector_from_text('[1, 2, 3]')::text;"
    if ($rh6 -eq '[1,2,3]') { Pass "22 vector-text: from_text tolerates spaces after the commas" }
    else { Fail "22 vector-text: expected '[1,2,3]', got: $rh6" }
    $rh7 = Psql -Sql "SELECT fractal_vector_from_text('1, 2, 3')::text;"
    if ($rh7 -eq '[1,2,3]') { Pass "22 vector-text: from_text tolerates spaces in the list form" }
    else { Fail "22 vector-text: expected '[1,2,3]', got: $rh7" }
    $rh8 = Psql -Sql "SELECT fractal_vector_from_text(NULL) IS NULL, fractal_vector_to_json(NULL::fractal_vector) IS NULL;"
    if ($rh8 -eq 't|t') { Pass "22 vector-text: NULL in, NULL out (both helpers are STRICT)" }
    else { Fail "22 vector-text: expected t|t, got: $rh8" }
    $rh9 = Psql -Sql "SELECT fractal_vector_from_text('');"
    if ($rh9 -match 'an empty string is not a vector') { Pass "22 vector-text: an empty string is rejected" }
    else { Fail "22 vector-text: expected the empty-string rejection, got: $rh9" }
    # The rejection has to name the offending text EXACTLY: PL/pgSQL's
    # RAISE placeholder is a bare "%", so a "%s" in the format string
    # used to leave a stray literal "s" inside the quoted text
    # ("[1,2,x]s").
    $rh10 = Psql -Sql "SELECT fractal_vector_from_text('[1,2,x]');"
    if ($rh10 -match 'could not parse "\[1,2,x\]" as a vector array') { Pass "22 vector-text: a malformed array is rejected and the offending text is quoted exactly" }
    else { Fail "22 vector-text: expected the array-form parse rejection, got: $rh10" }
    $rh11 = Psql -Sql "SELECT fractal_vector_from_text('1,2,x');"
    if ($rh11 -match 'could not parse "1,2,x" as a vector') { Pass "22 vector-text: a malformed list is rejected and the offending text is quoted exactly" }
    else { Fail "22 vector-text: expected the list-form parse rejection, got: $rh11" }
    # The round trip is compared on the type's own text rendering --
    # fractal_vector has no "=" operator, and the rendering is the
    # exact thing the round trip has to preserve.
    $rh12 = Psql -Sql "SELECT fractal_vector_from_text(fractal_vector_to_json('[0.1,0.2,0.3]'::fractal_vector)::text)::text = '[0.1,0.2,0.3]'::fractal_vector::text;"
    if ($rh12 -eq 't') { Pass "22 vector-text: a JSON round trip through the type's own rendering is lossless" }
    else { Fail "22 vector-text: expected the round trip to be lossless, got: $rh12" }
}

# fractalsql_agents dependent-extension smoke gate -- the two parameterized
# PL/pgSQL agent engines (fractal_agent_anomaly_triage, fractal_agent_allocate)
# shipped in fractalsql_agents/. Deliberately a smoke gate, same scope/spirit
# as gate 22: proves the engine compositions run end-to-end against the real DLL
# + the real C primitives they wrap (fractal_dimension_drift, fractal_reason,
# fractal_optimize_portfolio). The engines' LLM step is fed by the gate-20 mock
# reasoning canary so it is deterministic without a live endpoint: the drift
# and optimizer steps are real C (deterministic); the reason step returns the
# canary. Mirrors build_test.sh's gate 23.
function Gate23Agents {
    # The engines call fractal_reason; the mock reasoning plugin (the resting
    # $Mock state) returns $SqlFile's content as the response. Set the same
    # canary gate 20 uses, so the engines' triage_summary / rationale carry it.
    # PgSwapPlugin $Mock guarantees the mock is active even if gate 23 is run
    # standalone (without gate 20 before it).
    PgSwapPlugin $Mock | Out-Null
    Set-Content -Path $SqlFile -Value "gap-analysis-canary" -NoNewline

    # --- fixture: a drifting metric series for one host -----------------
    # Same step-up shape as demo/demo-vertical-agentic-ops-devops.sql: baseline ~50
    # for the first 48 rows then a +30 step-up, 96 points, so
    # fractal_dimension_drift's 32-point recent window has a real regime change
    # to detect (window=16 is too small for DFA on the recent window -- see the
    # demo's own note). A second host makes the host filter meaningful.
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_logs;
CREATE TABLE bt_agents_logs (metric float8, ts timestamptz, host text);
INSERT INTO bt_agents_logs (metric, ts, host)
SELECT 50.0 + (gs % 8)::float8 * 1.3 + CASE WHEN gs > 48 THEN 30.0 ELSE 0.0 END,
       now() - (96 - gs) * interval '1 second', 'host-1'
FROM generate_series(1,96) gs;
INSERT INTO bt_agents_logs VALUES (10, now(), 'host-2'), (11, now() + interval '1 min', 'host-2');
"@ | Out-Null

    # --- 1: fractal_agent_anomaly_triage happy path ---------------------
    # threat_score is the REAL drift exponent (fractal_dimension_drift ran);
    # triage_summary is the REAL reason step (canary proves fractal_reason ran).
    $r1 = Psql -Sql "SELECT threat_score FROM fractal_agent_anomaly_triage('bt_agents_logs','metric','ts','host','host-1',32);"
    if ($r1 -match '^-?[0-9]+(\.[0-9]+)?$') { Pass "23 agents: anomaly_triage threat_score is a real computed drift float" }
    else { Fail "23 agents: expected a numeric threat_score, got: $r1" }

    $r1b = Psql -Sql "SELECT triage_summary FROM fractal_agent_anomaly_triage('bt_agents_logs','metric','ts','host','host-1',32);"
    if ($r1b -match 'gap-analysis-canary') { Pass "23 agents: anomaly_triage composes drift -> reason (reason step ran)" }
    else { Fail "23 agents: expected the reasoning canary in triage_summary, got: $r1b" }

    # --- 2: anomaly_triage empty-series guard ---------------------------
    $r2 = Psql -Sql "SELECT * FROM fractal_agent_anomaly_triage('bt_agents_logs','metric','ts','host','no-such-host',32);"
    if ($r2 -match 'no rows in') { Pass "23 agents: anomaly_triage raises a clean ERROR when the filter matches no rows" }
    else { Fail "23 agents: expected a no-rows ERROR, got: $r2" }

    # --- 2b: agent_partial_reasoning_fail pair (PL/pgSQL engines) -------
    # Mirror of build_test.sh's gate-23 section 2b (the sqlite repo's
    # gate-29 pair convention). TWO DIFFERENT failure shapes, kept apart on
    # purpose -- the drift half needs no plugin at all, so the pair isolates
    # exactly the raise-vs-partial difference:
    #   (a) a SETUP mistake -- the reasoning plugin does not load at all
    #       (SQLSTATE 55000). This is NEVER softened: with the flag on the
    #       engine still raises (a missing plugin is a configuration mistake,
    #       not a transient endpoint failure -- the sibling sqlite engine
    #       hard-errors on it too).
    #   (b) a TRANSIENT endpoint failure -- the mock plugin LOADS, but its
    #       dispatch fails (the FSQL_BT_FORCE_FAIL sentinel in $SqlFile).
    #       This IS softened: the engine returns its computed data half with
    #       the LLM column NULL and a SEPARATE reasoning_step_failed column
    #       carrying the error text (the two-column contract, matching the
    #       sibling's {"<llm>":null,"reasoning_step_failed":"<error>"} shape).
    if (-not (PgSetGuc -Name 'fractalsql.reasoning_plugin' -SetVal "'C:\fractalsql_bt_broken.dll'" -Want 'C:\fractalsql_bt_broken.dll')) {
        Fail "23 agents: could not point reasoning_plugin at the broken path"; PgSwapPlugin $Mock | Out-Null; return
    }

    $r2b = Psql -Sql "SELECT threat_score FROM fractal_agent_anomaly_triage('bt_agents_logs','metric','ts','host','host-1',32);"
    if ($r2b -match 'reasoning') { Pass "23 agents: agent_partial_reasoning_fail off -- the reasoning failure raises through the engine" }
    else { Fail "23 agents: expected the reasoning failure to raise with the flag off, got: $r2b" }

    if (-not (PgSetGuc -Name 'fractalsql.agent_partial_reasoning_fail' -SetVal 'on' -Want 'on')) {
        Fail "23 agents: could not set agent_partial_reasoning_fail=on"; PgSwapPlugin $Mock | Out-Null; return
    }

    # (a) the setup mistake is NOT softened by the flag.
    $r2b2 = Psql -Sql "SELECT threat_score FROM fractal_agent_anomaly_triage('bt_agents_logs','metric','ts','host','host-1',32);"
    if ($r2b2 -match 'reasoning plugin') { Pass "23 agents: a missing reasoning plugin is a setup mistake -- it still raises with the flag on" }
    else { Fail "23 agents: expected the setup mistake to raise even with the flag on, got: $r2b2" }

    # (b) the transient dispatch failure IS softened, into the two-column
    # contract: threat_score is still the real (signed) drift float, the
    # fixture's drift is ~(0.43-1.87) = -1.44, so a >= -1.0 threshold was a
    # wrong first guess -- assert finiteness, not a magnitude. triage_summary
    # is NULL and reasoning_step_failed carries the raw error text (no
    # 'reasoning_step_failed: ' prefix -- the column name says it).
    PgSwapPlugin $Mock | Out-Null
    Set-Content -LiteralPath $SqlFile -Value "FSQL_BT_FORCE_FAIL" -NoNewline
    $r2c = Psql -Sql "SELECT (threat_score IS NOT NULL), (triage_summary IS NULL), (reasoning_step_failed IS NOT NULL), (reasoning_step_failed <> ''), (reasoning_step_failed NOT LIKE 'reasoning_step_failed:%') FROM fractal_agent_anomaly_triage('bt_agents_logs','metric','ts','host','host-1',32);"
    if ($r2c -match '^t\|t\|t\|t\|t$') { Pass "23 agents: agent_partial_reasoning_fail on -- data half (real drift float) + NULL LLM column + reasoning_step_failed error column" }
    else { Fail "23 agents: expected the partial row (drift float + NULL triage_summary + reasoning_step_failed), got: $r2c" }

    # flag off + the same transient failure: the failure propagates again.
    PgSetGuc -Name 'fractalsql.agent_partial_reasoning_fail' -SetVal 'off' -Want 'off' | Out-Null
    $r2d = Psql -Sql "SELECT threat_score FROM fractal_agent_anomaly_triage('bt_agents_logs','metric','ts','host','host-1',32);"
    if ($r2d -match 'dispatch failed') { Pass "23 agents: agent_partial_reasoning_fail off -- a transient reasoning failure still raises" }
    else { Fail "23 agents: expected the transient reasoning failure to raise with the flag off, got: $r2d" }

    # Restore the resting state the rest of the gate (and gate 24+) expects.
    PgSwapPlugin $Mock | Out-Null
    Set-Content -LiteralPath $SqlFile -Value "gap-analysis-canary"

    # --- 3: fractal_agent_allocate happy path --------------------------
    # allocation is the REAL optimizer jsonb {sharpe, weights}; sharpe is the
    # REAL risk-adjusted return extracted from it (replaces the demo's 0.042
    # literal); rationale is the REAL reason step (canary).
    $r3 = Psql -Sql "SELECT allocation FROM fractal_agent_allocate(ARRAY[0.05,0.1]::float8[], ARRAY[1.0,0.0,0.0,1.0]::float8[], 1, '{}'::text);"
    if ($r3 -match '"sharpe"') { Pass "23 agents: allocate composes optimize_portfolio -> reason (real optimizer jsonb with sharpe)" }
    else { Fail "23 agents: expected a sharpe-bearing allocation jsonb, got: $r3" }

    $r3b = Psql -Sql "SELECT rationale FROM fractal_agent_allocate(ARRAY[0.05,0.1]::float8[], ARRAY[1.0,0.0,0.0,1.0]::float8[], 1, '{}'::text);"
    if ($r3b -match 'gap-analysis-canary') { Pass "23 agents: allocate rationale is the real reason step output (canary)" }
    else { Fail "23 agents: expected the reasoning canary in rationale, got: $r3b" }

    # --- 4: allocate cov-length rejection -------------------------------
    # The engine must surface fractal_optimize_portfolio's clean 'cov length'
    # ERROR unchanged, not swallow it.
    $r4 = Psql -Sql "SELECT * FROM fractal_agent_allocate(ARRAY[0.1,0.1]::float8[], ARRAY[1.0]::float8[], 1, NULL::text);"
    if ($r4 -match 'cov length') { Pass "23 agents: allocate surfaces the optimizer's clean cov-length rejection" }
    else { Fail "23 agents: expected a cov-length rejection, got: $r4" }

    # --- 5: fractal_agent_route_task happy path -------------------------
    # routed_to is the REAL nearest capability (telemetry ran + doc_id
    # resolved to the named id); confidence is real, derived from the nearest
    # distance (1/(1+d)); rationale is the REAL reason step (canary).
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_caps;
CREATE TABLE bt_agents_caps (capability_name text, emb float8[]);
INSERT INTO bt_agents_caps VALUES ('cap-a', ARRAY[0.1,0.2,0.3]), ('cap-b', ARRAY[0.9,0.8,0.7]);
"@ | Out-Null
    $r5 = Psql -Sql "SELECT routed_to FROM fractal_agent_route_task(ARRAY[0.1,0.2,0.3]::float8[], 'bt_agents_caps','emb','capability_name', 1000);"
    if ($r5 -match '^cap-a$') { Pass "23 agents: route_task returns the real nearest capability name (telemetry + doc_id resolution)" }
    else { Fail "23 agents: expected routed_to=cap-a, got: $r5" }

    $r5b = Psql -Sql "SELECT confidence FROM fractal_agent_route_task(ARRAY[0.1,0.2,0.3]::float8[], 'bt_agents_caps','emb','capability_name', 1000);"
    if ($r5b -match '^[0-9]+(\.[0-9]+)?$') { Pass "23 agents: route_task confidence is a real float derived from the nearest distance" }
    else { Fail "23 agents: expected a numeric confidence, got: $r5b" }

    $r5c = Psql -Sql "SELECT rationale FROM fractal_agent_route_task(ARRAY[0.1,0.2,0.3]::float8[], 'bt_agents_caps','emb','capability_name', 1000);"
    if ($r5c -match 'gap-analysis-canary') { Pass "23 agents: route_task composes telemetry -> reason (reason step ran)" }
    else { Fail "23 agents: expected the reasoning canary in rationale, got: $r5c" }

    # --- 6: route_task empty-capability-table guard ---------------------
    Psql -Sql "DELETE FROM bt_agents_caps;" | Out-Null
    $r6 = Psql -Sql "SELECT * FROM fractal_agent_route_task(ARRAY[0.1,0.2,0.3]::float8[], 'bt_agents_caps','emb','capability_name', 1000);"
    if ($r6 -match 'no capability rows') { Pass "23 agents: route_task raises a clean ERROR when the capability table is empty" }
    else { Fail "23 agents: expected a no-capability-rows ERROR, got: $r6" }

    # --- 7: fractal_agent_outlier_intercept intercept + allow -----------
    # Bad states point along the x-axis. Cosine distance ignores magnitude,
    # so the "far" probe must differ in DIRECTION (orthogonal y-axis), not
    # just magnitude -- [0.1,0.1,0.1] vs [0.9,0.9,0.9] would be distance 0.
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_badstates;
CREATE TABLE bt_agents_badstates (emb float8[]);
INSERT INTO bt_agents_badstates VALUES (ARRAY[1,0,0]), (ARRAY[0.9,0.1,0.0]);
"@ | Out-Null
    $r7 = Psql -Sql "SELECT intercepted FROM fractal_agent_outlier_intercept(ARRAY[1,0,0]::float8[], 'bt_agents_badstates','emb', 0.5);"
    if ($r7 -match '^t$') { Pass "23 agents: outlier_intercept intercepts a state within the threshold (real distance 0 < 0.5)" }
    else { Fail "23 agents: expected intercepted=t for a near state, got: $r7" }

    $r7b = Psql -Sql "SELECT intercepted FROM fractal_agent_outlier_intercept(ARRAY[0,1,0]::float8[], 'bt_agents_badstates','emb', 0.5);"
    if ($r7b -match '^f$') { Pass "23 agents: outlier_intercept allows an orthogonal state (real cosine distance 1 > 0.5)" }
    else { Fail "23 agents: expected intercepted=f for an orthogonal state, got: $r7b" }

    $r7c = Psql -Sql "SELECT reason FROM fractal_agent_outlier_intercept(ARRAY[1,0,0]::float8[], 'bt_agents_badstates','emb', 0.5);"
    if ($r7c -match 'gap-analysis-canary') { Pass "23 agents: outlier_intercept reason is the real reason step output (canary)" }
    else { Fail "23 agents: expected the reasoning canary in reason, got: $r7c" }

    # The explicit metric argument: a threshold is calibrated against one
    # metric, so the metric is caller-chosen, and the same probe can get
    # opposite decisions under different metrics. [0.05,0,0] is
    # cosine-parallel to the bad x-axis states (cosine distance ~0, so
    # intercepted, as r7 showed for [1,0,0]) but L2-far: the nearest bad
    # state is [0.9,0.1,0.0] at sqrt(0.7225+0.01) = 0.856 > 0.5, so
    # allowed. An unknown metric must be a hard error, never a fallback.
    $r7d = Psql -Sql "SELECT intercepted FROM fractal_agent_outlier_intercept(ARRAY[0.05,0,0]::float8[], 'bt_agents_badstates','emb', 0.5, 'l2');"
    if ($r7d -match '^f$') { Pass "23 agents: outlier_intercept metric=l2 allows the parallel state cosine intercepts (real L2 distance 0.856 > 0.5)" }
    else { Fail "23 agents: expected intercepted=f for metric=l2 (L2 distance 0.856 > 0.5), got: $r7d" }

    $r7e = Psql -Sql "SELECT * FROM fractal_agent_outlier_intercept(ARRAY[1,0,0]::float8[], 'bt_agents_badstates','emb', 0.5, 'euclid');"
    if ($r7e -match "metric must be 'cosine' or 'l2'") { Pass "23 agents: outlier_intercept rejects an unknown metric (no silent fallback)" }
    else { Fail "23 agents: expected a metric rejection, got: $r7e" }

    # --- 7b: the metric column is exposed (sibling parity) --------------
    # The metric the engine actually used must be visible in the returned
    # columns, not only inside the nested payload -- the sibling's shape is
    # {"intercepted":..,"metric":..,"reason":..}.
    $r7f = Psql -Sql "SELECT metric FROM fractal_agent_outlier_intercept(ARRAY[1,0,0]::float8[], 'bt_agents_badstates','emb', 0.5);"
    if ($r7f -match '^cosine$') { Pass "23 agents: outlier_intercept exposes the metric it actually used (metric column)" }
    else { Fail "23 agents: expected metric=cosine in the outlier_intercept row, got: $r7f" }

    $r7g = Psql -Sql "SELECT metric FROM fractal_agent_outlier_intercept(ARRAY[0.05,0,0]::float8[], 'bt_agents_badstates','emb', 0.5, 'l2');"
    if ($r7g -match '^l2$') { Pass "23 agents: outlier_intercept reports the caller-chosen l2 metric in the metric column" }
    else { Fail "23 agents: expected metric=l2 in the outlier_intercept row, got: $r7g" }

    # --- 7c: a NULL input vector is an ARGUMENT fault, not a data fault --
    # The engine rejects the NULL itself with invalid_parameter_value
    # (22023) instead of letting it reach the vector math, where it would
    # surface as a generic low-level data error.
    $r7h = Psql -Sql @'
DO $$
BEGIN
  PERFORM * FROM fractal_agent_route_task(NULL::float8[], 'bt_agents_caps','emb','capability_name', 10);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'sqlstate=%', SQLSTATE;
END $$;
'@
    if ($r7h -match 'sqlstate=22023') { Pass "23 agents: a NULL input vector is an argument error (22023), not a vector-math data error" }
    else { Fail "23 agents: expected a 22023 argument error for a NULL input vector, got: $r7h" }

    # --- 8: fractal_agent_recall_hybrid happy path + guard --------------
    # Real session_ids + real content (NOT the stub's generate_series 1-5 /
    # 'recalled memory snippet N'); the cohort (customer_id filter) excludes
    # cust-b's session. Pure retrieval -- no LLM step, no canary, real C.
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_mem;
CREATE TABLE bt_agents_mem (session_id bigint, customer_id text, state_vector float8[], content text);
INSERT INTO bt_agents_mem VALUES
  (1001, 'cust-a', ARRAY[0.1,0.2,0.3], 'resolved churn via loyalty upgrade'),
  (1002, 'cust-a', ARRAY[0.15,0.25,0.35], 'offered retention discount'),
  (1003, 'cust-b', ARRAY[0.9,0.8,0.7], 'escalated to human agent');
"@ | Out-Null
    $r8 = Psql -Sql "SELECT mem_id FROM fractal_agent_recall_hybrid('bt_agents_mem','state_vector', ARRAY[0.1,0.2,0.3]::float8[], 'customer_id','cust-a', 5, 'session_id','content') LIMIT 1;"
    if ($r8 -match '^1001$') { Pass "23 agents: recall_hybrid returns the real nearest session_id (not the stub's generate_series 1-5)" }
    else { Fail "23 agents: expected mem_id=1001, got: $r8" }

    $r8b = Psql -Sql "SELECT content FROM fractal_agent_recall_hybrid('bt_agents_mem','state_vector', ARRAY[0.1,0.2,0.3]::float8[], 'customer_id','cust-a', 5, 'session_id','content') LIMIT 1;"
    if ($r8b -match 'resolved churn via loyalty upgrade') { Pass "23 agents: recall_hybrid returns the real row content (not the stub's canned snippet)" }
    else { Fail "23 agents: expected the real content, got: $r8b" }

    $r8c = Psql -Sql "SELECT * FROM fractal_agent_recall_hybrid('bt_agents_mem','state_vector', ARRAY[0.1,0.2,0.3]::float8[], 'customer_id','no-such-cust', 5, 'session_id','content');"
    if ($r8c -match 'filter matched no rows') { Pass "23 agents: recall_hybrid raises a clean ERROR when the filter matches no rows" }
    else { Fail "23 agents: expected a filter-matched-no-rows ERROR, got: $r8c" }

    # --- 9: fractal_agent_recommend_diverse happy path ------------------
    # Real catalog ids + real scores (NOT the stub's generate_series 1..k /
    # 0.95 - i*0.01). Diversify enabled as a session side effect; no feedback
    # reported so repulsion is a no-op and telemetry returns the plain nearest
    # first (id 10, distance 0 -> score 1). Pure retrieval.
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_catalog;
CREATE TABLE bt_agents_catalog (id bigint, emb float8[]);
INSERT INTO bt_agents_catalog VALUES (10, ARRAY[0.1,0.2,0.3]), (20, ARRAY[0.9,0.8,0.7]), (30, ARRAY[0.5,0.5,0.5]);
"@ | Out-Null
    $r9 = Psql -Sql "SELECT item_id FROM fractal_agent_recommend_diverse('bt_agents_catalog','emb', ARRAY[0.1,0.2,0.3]::float8[], 3, 'id') LIMIT 1;"
    if ($r9 -match '^10$') { Pass "23 agents: recommend_diverse returns the real nearest catalog id (not the stub's generate_series 1..k)" }
    else { Fail "23 agents: expected item_id=10, got: $r9" }

    $r9b = Psql -Sql "SELECT score FROM fractal_agent_recommend_diverse('bt_agents_catalog','emb', ARRAY[0.1,0.2,0.3]::float8[], 3, 'id') LIMIT 1;"
    if ($r9b -match '^[0-9]+(\.[0-9]+)?$') { Pass "23 agents: recommend_diverse score is a real float (1 - cosine distance), not the stub's canned 0.95-i*0.01" }
    else { Fail "23 agents: expected a numeric score, got: $r9b" }

    # ====================================================================
    # Stage 4 engines G-O (9 new). The 8 cognition engines (G,H,J,K,L,M,N,O)
    # reuse the gate-20 mock canary set above, so their rationale/analysis
    # columns carry it; feedback_audit (I) is pure analytics (no LLM, no
    # canary). Real C primitives feed the analytics columns; the canary proves
    # the reason step ran. Mirrors build_test.sh's gate_23_agents.
    # ====================================================================

    # --- 10: fractal_agent_data_analyst happy path ----------------------
    # Composes fractal_sql_agent (NL->SQL->execute, auto_execute=true) ->
    # fractal_reason. With the mock canary the generated_sql IS the canary
    # (the mock LLM); auto_execute's subtransaction catches the canary-as-SQL
    # syntax error into a real execution_failed result_json, proving the
    # execute step ran; analysis is the real reason step (canary).
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_data;
CREATE TABLE bt_agents_data (id int PRIMARY KEY, val float8);
INSERT INTO bt_agents_data VALUES (1,10.5),(2,20.5);
"@ | Out-Null
    $r10 = Psql -Sql "SELECT generated_sql FROM fractal_agent_data_analyst('sum of val', ARRAY['bt_agents_data'], 2);"
    if ($r10 -match 'gap-analysis-canary') { Pass "23 agents: data_analyst composes sql_agent (generated_sql is the real LLM step, canary)" }
    else { Fail "23 agents: expected the canary in generated_sql, got: $r10" }

    $r10b = Psql -Sql "SELECT result_json::text FROM fractal_agent_data_analyst('sum of val', ARRAY['bt_agents_data'], 2);"
    if ($r10b -match '"status"') { Pass "23 agents: data_analyst result_json is a real jsonb (auto_execute subtransaction ran)" }
    else { Fail "23 agents: expected a status-bearing result_json, got: $r10b" }

    $r10c = Psql -Sql "SELECT analysis FROM fractal_agent_data_analyst('sum of val', ARRAY['bt_agents_data'], 2);"
    if ($r10c -match 'gap-analysis-canary') { Pass "23 agents: data_analyst composes sql_agent -> reason (analysis is the real reason step, canary)" }
    else { Fail "23 agents: expected the canary in analysis, got: $r10c" }

    # --- 10d: fractal_sql_agent's auto_execute SAVEPOINT scoping --------
    # Unlike the canary-as-SQL path above (10/10b/10c, which proves the
    # compose-and-fail shape), this drives the mock's single canned-reply file
    # (the same mock_sql.txt file gate 04's auto-discovery case writes)
    # with a real, valid INSERT, so one call can genuinely succeed and a
    # colliding call can genuinely fail. One connection (one Psql call,
    # one backend), one open transaction: a real prior COMMITted write
    # (id=99), then three fractal_sql_agent calls that always generate
    # the SAME INSERT (id=1) -- the first succeeds, the second and third
    # both collide with the PRIMARY KEY and must each report
    # execution_failed via auto_execute's internal subtransaction,
    # proving the same fixed call is safely reusable after a prior
    # rollback, not just after a clean release.
    Psql -Sql @"
DROP TABLE IF EXISTS bt_sql_agent_sp;
CREATE TABLE bt_sql_agent_sp (id int PRIMARY KEY, val text);
INSERT INTO bt_sql_agent_sp (id, val) VALUES (99, 'prior');
"@ | Out-Null
    if (-not (PgSetGuc -Name 'fractalsql.text_to_sql_allowed_statements' -SetVal "'select_insert_update'" -Want 'select_insert_update')) {
        Fail "23 agents: sql_agent_savepoint GUC did not take effect"
    }
    Set-Content -Path $SqlFile -Value "INSERT INTO bt_sql_agent_sp (id, val) VALUES (1, 'x')" -NoNewline
    $out = Psql -Sql @"
BEGIN;
SELECT execution_status FROM fractal_sql_agent('insert canary row', ARRAY['bt_sql_agent_sp'], 1, true);
SELECT execution_status FROM fractal_sql_agent('insert canary row', ARRAY['bt_sql_agent_sp'], 1, true);
SELECT execution_status FROM fractal_sql_agent('insert canary row', ARRAY['bt_sql_agent_sp'], 1, true);
COMMIT;
"@
    # BEGIN/COMMIT print their own command tags even under -tA (only
    # SELECT's tuples are suppressed by -t) -- filter them out before
    # indexing, rather than assuming the 3 statuses are lines 1-3.
    $lines = @($out -split "`r?`n" | Where-Object { $_ -ne '' -and $_ -ne 'BEGIN' -and $_ -ne 'COMMIT' })
    $status1 = $lines[0]; $status2 = $lines[1]; $status3 = $lines[2]
    if ($status1 -eq 'executed') { Pass "23 agents: sql_agent_savepoint: first INSERT executed cleanly" }
    else { Fail "23 agents: sql_agent_savepoint: first call expected status=executed, got '$status1' (full: $out)" }
    if ($status2 -eq 'execution_failed') { Pass "23 agents: sql_agent_savepoint: second (colliding) INSERT reported execution_failed via the auto_execute subtransaction, not a raw error" }
    else { Fail "23 agents: sql_agent_savepoint: second call expected status=execution_failed, got '$status2'" }
    if ($status3 -eq 'execution_failed') { Pass "23 agents: sql_agent_savepoint: third call reused the same call shape after the second call's rollback, no escaped error" }
    else { Fail "23 agents: sql_agent_savepoint: third call expected status=execution_failed, got '$status3'" }
    $cnt = Psql -Sql "SELECT count(*) FROM bt_sql_agent_sp;"
    if ($cnt -eq '2') { Pass "23 agents: sql_agent_savepoint: both the prior commit (id=99) and the first call's write (id=1) survive -- no phantom rows from the two rolled-back calls" }
    else { Fail "23 agents: sql_agent_savepoint: expected exactly 2 surviving rows (id=1,99), count=$cnt" }
    Psql -Sql "DROP TABLE IF EXISTS bt_sql_agent_sp;" | Out-Null
    PgSetGuc -Name 'fractalsql.text_to_sql_allowed_statements' -SetVal "'select'" -Want 'select' | Out-Null
    # Restore the shared mock-reply file: every engine after this point
    # in gate 23 expects the "gap-analysis-canary" reply this gate's own
    # header already set, not the INSERT text this sub-test just wrote.
    Set-Content -Path $SqlFile -Value "gap-analysis-canary" -NoNewline

    # --- 11: fractal_agent_patient_deterioration_triage happy + guard ----
    # nearest_cohort_id is the REAL hybrid_clinical_search nearest resolved via
    # ctid; cohort_distance/drift_distance are real; rationale is the reason
    # step (canary). cohort_doc_ids built from age>65 AND condition='sepsis'
    # (the two-predicate case recall_hybrid cannot express).
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_patients;
CREATE TABLE bt_agents_patients (id int PRIMARY KEY, age int, condition text, vitals float8[]);
INSERT INTO bt_agents_patients VALUES
  (1,70,'sepsis',ARRAY[0.9,-0.8,0.7,0.6]),
  (2,30,'sepsis',ARRAY[0.1,0.1,0.1,0.1]),
  (3,72,'flu',  ARRAY[0.2,0.2,0.2,0.2]),
  (4,80,'sepsis',ARRAY[0.85,-0.75,0.65,0.55]);
"@ | Out-Null
    $r11 = Psql -Sql "SELECT nearest_cohort_id FROM fractal_agent_patient_deterioration_triage('bt_agents_patients','vitals', ARRAY[0.9,-0.8,0.7,0.6]::float8[], ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.95,-0.85,0.75,0.65]::float8[], (SELECT array_agg(ctid::text) FROM bt_agents_patients WHERE age>65 AND condition='sepsis'), 5, 'id');"
    if ($r11 -match '^[0-9]+$') { Pass "23 agents: patient_deterioration_triage returns the real nearest cohort id (hybrid search + ctid resolution)" }
    else { Fail "23 agents: expected a numeric nearest_cohort_id, got: $r11" }

    $r11m = Psql -Sql "SELECT jsonb_array_length(cohort_matches) FROM fractal_agent_patient_deterioration_triage('bt_agents_patients','vitals', ARRAY[0.9,-0.8,0.7,0.6]::float8[], ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.95,-0.85,0.75,0.65]::float8[], (SELECT array_agg(ctid::text) FROM bt_agents_patients WHERE age>65 AND condition='sepsis'), 5, 'id');"
    if ($r11m -eq '2') { Pass "23 agents: patient_deterioration_triage cohort_matches now honors k (got 2 of 2 qualifying rows)" }
    else { Fail "23 agents: expected cohort_matches length 2, got: $r11m" }

    $r11b = Psql -Sql "SELECT rationale FROM fractal_agent_patient_deterioration_triage('bt_agents_patients','vitals', ARRAY[0.9,-0.8,0.7,0.6]::float8[], ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.95,-0.85,0.75,0.65]::float8[], (SELECT array_agg(ctid::text) FROM bt_agents_patients WHERE age>65 AND condition='sepsis'), 5, 'id');"
    if ($r11b -match 'gap-analysis-canary') { Pass "23 agents: patient_deterioration_triage composes hybrid+trajectory -> reason (canary)" }
    else { Fail "23 agents: expected the canary in rationale, got: $r11b" }

    Psql -Sql "DELETE FROM bt_agents_patients;" | Out-Null
    $r11c = Psql -Sql "SELECT * FROM fractal_agent_patient_deterioration_triage('bt_agents_patients','vitals', ARRAY[0.9,-0.8,0.7,0.6]::float8[], ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.95,-0.85,0.75,0.65]::float8[], NULL, 5, 'id');"
    if ($r11c -match 'no patient rows') { Pass "23 agents: patient_deterioration_triage raises a clean ERROR when the patient table is empty" }
    else { Fail "23 agents: expected a no-patient-rows ERROR, got: $r11c" }

    # --- 12: fractal_agent_feedback_audit happy + guard ------------------
    # Pure analytics (NO LLM, no canary): enables diversify, warms the D_q
    # window from the warmup table, isolates the target, reads back a real
    # diversity_quotient (NOT NaN -- the warmup populated the window) + the
    # real session diagnostics jsonb. Self-disables diversify.
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_fcatalog, bt_agents_fwarmup;
CREATE TABLE bt_agents_fcatalog (id bigint PRIMARY KEY, emb float8[]);
INSERT INTO bt_agents_fcatalog SELECT gs, ARRAY[random()*2-1, random()*2-1, random()*2-1] FROM generate_series(1,20) gs;
CREATE TABLE bt_agents_fwarmup (center float8[]);
INSERT INTO bt_agents_fwarmup SELECT ARRAY[random()*2-1, random()*2-1, random()*2-1] FROM generate_series(1,8);
"@ | Out-Null
    $r12 = Psql -Sql "SELECT diversity_quotient::text FROM fractal_agent_feedback_audit('bt_agents_fcatalog','emb', ARRAY[0.5,0.5,0.5]::float8[], 'bt_agents_fwarmup','center', 8, 3);"
    if ($r12 -match '^[0-9]+(\.[0-9]+)?$') { Pass "23 agents: feedback_audit diversity_quotient is a real float (warmup populated the D_q window, not NaN)" }
    else { Fail "23 agents: expected a numeric diversity_quotient, got: $r12" }

    $r12b = Psql -Sql "SELECT (explanation IS NOT NULL)::text FROM fractal_agent_feedback_audit('bt_agents_fcatalog','emb', ARRAY[0.5,0.5,0.5]::float8[], 'bt_agents_fwarmup','center', 8, 3);"
    if ($r12b -match '^true$') { Pass "23 agents: feedback_audit returns the real session diagnostics jsonb" }
    else { Fail "23 agents: expected a non-null explanation, got: $r12b" }

    Psql -Sql "DELETE FROM bt_agents_fcatalog;" | Out-Null
    $r12c = Psql -Sql "SELECT * FROM fractal_agent_feedback_audit('bt_agents_fcatalog','emb', ARRAY[0.5,0.5,0.5]::float8[], 'bt_agents_fwarmup','center', 8, 3);"
    if ($r12c -match 'no catalog rows') { Pass "23 agents: feedback_audit raises a clean ERROR when the catalog is empty" }
    else { Fail "23 agents: expected a no-catalog-rows ERROR, got: $r12c" }

    # --- 13: fractal_agent_schedule_workload happy + guard ---------------
    # assigned_node is the REAL nearest node (fractal_search refinement +
    # telemetry + ctid resolution); confidence = 1/(1+d) is real; rationale
    # is the reason step (canary).
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_nodes;
CREATE TABLE bt_agents_nodes (id int PRIMARY KEY, capability float8[]);
INSERT INTO bt_agents_nodes VALUES
  (1,ARRAY[0.9,0.1,0.0,0.0,0.0]),
  (2,ARRAY[0.0,0.0,0.9,0.1,0.0]),
  (3,ARRAY[0.1,0.0,0.0,0.0,0.9]);
"@ | Out-Null
    $r13 = Psql -Sql "SELECT assigned_node FROM fractal_agent_schedule_workload(ARRAY[0.8,0.1,0.0,0.0,0.1]::float8[], 'bt_agents_nodes','capability','id', 30, 50, 5);"
    if ($r13 -match '^[0-9]+$') { Pass "23 agents: schedule_workload returns the real nearest node (fractal_search + telemetry + ctid)" }
    else { Fail "23 agents: expected a numeric assigned_node, got: $r13" }

    $r13b = Psql -Sql "SELECT rationale FROM fractal_agent_schedule_workload(ARRAY[0.8,0.1,0.0,0.0,0.1]::float8[], 'bt_agents_nodes','capability','id', 30, 50, 5);"
    if ($r13b -match 'gap-analysis-canary') { Pass "23 agents: schedule_workload composes search+telemetry -> reason (canary)" }
    else { Fail "23 agents: expected the canary in rationale, got: $r13b" }

    Psql -Sql "DELETE FROM bt_agents_nodes;" | Out-Null
    $r13c = Psql -Sql "SELECT * FROM fractal_agent_schedule_workload(ARRAY[0.8,0.1,0.0,0.0,0.1]::float8[], 'bt_agents_nodes','capability','id', 30, 50, 5);"
    if ($r13c -match 'no node rows') { Pass "23 agents: schedule_workload raises a clean ERROR when the node table is empty" }
    else { Fail "23 agents: expected a no-node-rows ERROR, got: $r13c" }

    # --- 14: fractal_agent_rebalance_sibling happy + guard ---------------
    # sharpe is the REAL optimizer output; weights is the real jsonb;
    # nearest_alloc_id is the real trajectory-search nearest resolved via
    # ctid; rationale is the reason step (canary).
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_alloc;
CREATE TABLE bt_agents_alloc (id bigint PRIMARY KEY, alloc float8[]);
INSERT INTO bt_agents_alloc VALUES
  (1,ARRAY[0.25,0.25,0.25,0.25]),
  (2,ARRAY[0.4,0.3,0.2,0.1]),
  (3,ARRAY[0.1,0.2,0.3,0.4]);
"@ | Out-Null
    $r14 = Psql -Sql "SELECT sharpe::text FROM fractal_agent_rebalance_sibling(ARRAY[0.05,0.10,0.15,0.20]::float8[], ARRAY[0.04,0.0,0.0,0.0, 0.0,0.09,0.0,0.0, 0.0,0.0,0.16,0.0, 0.0,0.0,0.0,0.25]::float8[], 4, 'bt_agents_alloc','alloc', ARRAY[0.25,0.25,0.25,0.25]::float8[], NULL, 5, 'id');"
    if ($r14 -match '^-?[0-9]+(\.[0-9]+)?$') { Pass "23 agents: rebalance_sibling sharpe is the real optimizer output" }
    else { Fail "23 agents: expected a numeric sharpe, got: $r14" }

    $r14b = Psql -Sql "SELECT nearest_alloc_id FROM fractal_agent_rebalance_sibling(ARRAY[0.05,0.10,0.15,0.20]::float8[], ARRAY[0.04,0.0,0.0,0.0, 0.0,0.09,0.0,0.0, 0.0,0.0,0.16,0.0, 0.0,0.0,0.0,0.25]::float8[], 4, 'bt_agents_alloc','alloc', ARRAY[0.25,0.25,0.25,0.25]::float8[], NULL, 5, 'id');"
    if ($r14b -match '^[0-9]+$') { Pass "23 agents: rebalance_sibling nearest_alloc_id is the real trajectory nearest (ctid resolution)" }
    else { Fail "23 agents: expected a numeric nearest_alloc_id, got: $r14b" }

    $r14c = Psql -Sql "SELECT rationale FROM fractal_agent_rebalance_sibling(ARRAY[0.05,0.10,0.15,0.20]::float8[], ARRAY[0.04,0.0,0.0,0.0, 0.0,0.09,0.0,0.0, 0.0,0.0,0.16,0.0, 0.0,0.0,0.0,0.25]::float8[], 4, 'bt_agents_alloc','alloc', ARRAY[0.25,0.25,0.25,0.25]::float8[], NULL, 5, 'id');"
    if ($r14c -match 'gap-analysis-canary') { Pass "23 agents: rebalance_sibling composes optimize+trajectory -> reason (canary)" }
    else { Fail "23 agents: expected the canary in rationale, got: $r14c" }

    Psql -Sql "DELETE FROM bt_agents_alloc;" | Out-Null
    $r14d = Psql -Sql "SELECT * FROM fractal_agent_rebalance_sibling(ARRAY[0.05,0.10,0.15,0.20]::float8[], ARRAY[0.04,0.0,0.0,0.0, 0.0,0.09,0.0,0.0, 0.0,0.0,0.16,0.0, 0.0,0.0,0.0,0.25]::float8[], 4, 'bt_agents_alloc','alloc', ARRAY[0.25,0.25,0.25,0.25]::float8[], NULL, 5, 'id');"
    if ($r14d -match 'no allocation rows') { Pass "23 agents: rebalance_sibling raises a clean ERROR when the allocation table is empty" }
    else { Fail "23 agents: expected a no-allocation-rows ERROR, got: $r14d" }

    # --- 15: fractal_agent_detour_classify happy + guard -----------------
    # nearest_fleet_id is the REAL trajectory-search nearest; trace_complexity
    # is the REAL box-counting dimension of the GPS trace; rationale is the
    # reason step (canary).
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_vehicles;
CREATE TABLE bt_agents_vehicles (id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO bt_agents_vehicles SELECT gs, ARRAY[b1,b2,b3,b4], ARRAY[b1+0.05,b2+0.05,b3+0.05,b4+0.05]
  FROM generate_series(1,8) gs,
       LATERAL (SELECT random()*2-1 a, random()*2-1 b, random()*2-1 c, random()*2-1 d) bl(b1,b2,b3,b4);
UPDATE bt_agents_vehicles SET current = ARRAY[(baseline::float8[])[1]-0.7,(baseline::float8[])[2]+0.6,(baseline::float8[])[3]+0.5,(baseline::float8[])[4]-0.4] WHERE id=1;
"@ | Out-Null
    $r15 = Psql -Sql "SELECT trace_complexity::text FROM fractal_agent_detour_classify('bt_agents_vehicles','current', (SELECT baseline::float8[] FROM bt_agents_vehicles WHERE id=1), (SELECT current::float8[] FROM bt_agents_vehicles WHERE id=1), (SELECT array_agg(cum ORDER BY t, ord) FROM (SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum FROM generate_series(1,100) t CROSS JOIN LATERAL (VALUES (1,(random()-0.5)*0.3),(2,(random()-0.5)*0.3)) AS s(ord,step)) c), 5, 'id', 2);"
    if ($r15 -match '^[0-9]+(\.[0-9]+)?$') { Pass "23 agents: detour_classify trace_complexity is the real box-counting dimension of the GPS trace" }
    else { Fail "23 agents: expected a numeric trace_complexity, got: $r15" }

    $r15b = Psql -Sql "SELECT rationale FROM fractal_agent_detour_classify('bt_agents_vehicles','current', (SELECT baseline::float8[] FROM bt_agents_vehicles WHERE id=1), (SELECT current::float8[] FROM bt_agents_vehicles WHERE id=1), (SELECT array_agg(cum ORDER BY t, ord) FROM (SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum FROM generate_series(1,100) t CROSS JOIN LATERAL (VALUES (1,(random()-0.5)*0.3),(2,(random()-0.5)*0.3)) AS s(ord,step)) c), 5, 'id', 2);"
    if ($r15b -match 'gap-analysis-canary') { Pass "23 agents: detour_classify composes trajectory+boxcount -> reason (canary)" }
    else { Fail "23 agents: expected the canary in rationale, got: $r15b" }

    Psql -Sql "DELETE FROM bt_agents_vehicles;" | Out-Null
    $r15c = Psql -Sql "SELECT * FROM fractal_agent_detour_classify('bt_agents_vehicles','current', ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.2,0.2,0.2,0.2]::float8[], ARRAY[0,0,0,0]::float8[], 5, 'id', 2);"
    if ($r15c -match 'no vehicle rows') { Pass "23 agents: detour_classify raises a clean ERROR when the vehicle table is empty" }
    else { Fail "23 agents: expected a no-vehicle-rows ERROR, got: $r15c" }

    # --- 16: fractal_agent_track_anomaly happy + guard -------------------
    # nearest_fleet_id is the REAL trajectory nearest; dfa_exponent is the REAL
    # DFA exponent of the heading series (may be -1, still numeric); rationale
    # is the reason step (canary).
    Psql -Sql @"
DROP TABLE IF EXISTS bt_agents_tracks;
CREATE TABLE bt_agents_tracks (id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO bt_agents_tracks SELECT gs, ARRAY[b1,b2,b3,b4], ARRAY[b1+0.04,b2+0.04,b3+0.04,b4+0.04]
  FROM generate_series(1,8) gs,
       LATERAL (SELECT random()*2-1 a, random()*2-1 b, random()*2-1 c, random()*2-1 d) bl(b1,b2,b3,b4);
UPDATE bt_agents_tracks SET current = ARRAY[(baseline::float8[])[1]+0.6,(baseline::float8[])[2]-0.5,(baseline::float8[])[3]-0.9,(baseline::float8[])[4]+0.8] WHERE id=1;
"@ | Out-Null
    $r16 = Psql -Sql "SELECT dfa_exponent::text FROM fractal_agent_track_anomaly('bt_agents_tracks','current', (SELECT baseline::float8[] FROM bt_agents_tracks WHERE id=1), (SELECT current::float8[] FROM bt_agents_tracks WHERE id=1), (SELECT array_agg(cum ORDER BY t) FROM (SELECT t, sum(step) OVER (ORDER BY t) AS cum FROM (SELECT t, (random()-0.5)*(CASE WHEN t BETWEEN 40 AND 60 THEN 0.35 ELSE 0.03 END) AS step FROM generate_series(1,120) t) s) c), 5, 'id');"
    if ($r16 -match '^-?[0-9]+(\.[0-9]+)?$') { Pass "23 agents: track_anomaly dfa_exponent is the real DFA exponent of the heading series" }
    else { Fail "23 agents: expected a numeric dfa_exponent, got: $r16" }

    $r16b = Psql -Sql "SELECT rationale FROM fractal_agent_track_anomaly('bt_agents_tracks','current', (SELECT baseline::float8[] FROM bt_agents_tracks WHERE id=1), (SELECT current::float8[] FROM bt_agents_tracks WHERE id=1), (SELECT array_agg(cum ORDER BY t) FROM (SELECT t, sum(step) OVER (ORDER BY t) AS cum FROM (SELECT t, (random()-0.5)*(CASE WHEN t BETWEEN 40 AND 60 THEN 0.35 ELSE 0.03 END) AS step FROM generate_series(1,120) t) s) c), 5, 'id');"
    if ($r16b -match 'gap-analysis-canary') { Pass "23 agents: track_anomaly composes trajectory+dfa -> reason (canary)" }
    else { Fail "23 agents: expected the canary in rationale, got: $r16b" }

    Psql -Sql "DELETE FROM bt_agents_tracks;" | Out-Null
    $r16c = Psql -Sql "SELECT * FROM fractal_agent_track_anomaly('bt_agents_tracks','current', ARRAY[0.1,0.1,0.1,0.1]::float8[], ARRAY[0.2,0.2,0.2,0.2]::float8[], ARRAY[0,0,0]::float8[], 5, 'id');"
    if ($r16c -match 'no track rows') { Pass "23 agents: track_anomaly raises a clean ERROR when the track table is empty" }
    else { Fail "23 agents: expected a no-track-rows ERROR, got: $r16c" }

    # --- 17: fractal_agent_network_coverage_alert happy + NULL guard -----
    # morph_dimension + lacunarity are the REAL morphological_complexity output
    # (needs >= ~256 points -- use a 20x20 grid, matching the smart-cities
    # demo); drift_detected is the REAL |drift|>threshold over a step-up
    # series (true); rationale is the reason step (canary).
    $r17 = Psql -Sql @"
SELECT morph_dimension::text FROM fractal_agent_network_coverage_alert(
  (SELECT array_agg(v ORDER BY id, ord) FROM (
     SELECT r*20+c AS id, ord, v FROM generate_series(0,19) r
     CROSS JOIN generate_series(0,19) c
     CROSS JOIN LATERAL unnest(ARRAY[r+(random()-0.5)*0.3, c+(random()-0.5)*0.3]) WITH ORDINALITY AS u(v,ord)
   ) g),
  (SELECT array_agg(v ORDER BY t) FROM (
     SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                    ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
     FROM generate_series(1,96) t) s),
  2, 48, 0.5);
"@
    if ($r17 -match '^[0-9]+(\.[0-9]+)?$') { Pass "23 agents: network_coverage_alert morph_dimension is the real morphological complexity" }
    else { Fail "23 agents: expected a numeric morph_dimension, got: $r17" }

    $r17b = Psql -Sql @"
SELECT drift_detected::text FROM fractal_agent_network_coverage_alert(
  (SELECT array_agg(v ORDER BY id, ord) FROM (
     SELECT r*20+c AS id, ord, v FROM generate_series(0,19) r
     CROSS JOIN generate_series(0,19) c
     CROSS JOIN LATERAL unnest(ARRAY[r+(random()-0.5)*0.3, c+(random()-0.5)*0.3]) WITH ORDINALITY AS u(v,ord)
   ) g),
  (SELECT array_agg(v ORDER BY t) FROM (
     SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                    ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
     FROM generate_series(1,96) t) s),
  2, 48, 0.5);
"@
    if ($r17b -match '^true$') { Pass "23 agents: network_coverage_alert drift_detected=true for a real regime-change series (|drift|>0.5)" }
    else { Fail "23 agents: expected drift_detected=t, got: $r17b" }

    $r17c = Psql -Sql @"
SELECT rationale FROM fractal_agent_network_coverage_alert(
  (SELECT array_agg(v ORDER BY id, ord) FROM (
     SELECT r*20+c AS id, ord, v FROM generate_series(0,19) r
     CROSS JOIN generate_series(0,19) c
     CROSS JOIN LATERAL unnest(ARRAY[r+(random()-0.5)*0.3, c+(random()-0.5)*0.3]) WITH ORDINALITY AS u(v,ord)
   ) g),
  (SELECT array_agg(v ORDER BY t) FROM (
     SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                    ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
     FROM generate_series(1,96) t) s),
  2, 48, 0.5);
"@
    if ($r17c -match 'gap-analysis-canary') { Pass "23 agents: network_coverage_alert composes morph+drift -> reason (canary)" }
    else { Fail "23 agents: expected the canary in rationale, got: $r17c" }

    $r17d = Psql -Sql "SELECT * FROM fractal_agent_network_coverage_alert(NULL::float8[], ARRAY[1,2,3]::float8[], 2, 48, 0.5);"
    if ($r17d -match 'point_cloud and drift_series are required') { Pass "23 agents: network_coverage_alert raises a clean ERROR when point_cloud/drift_series is NULL" }
    else { Fail "23 agents: expected a required-args ERROR, got: $r17d" }

    # --- 18: fractal_agent_regime_triage happy + NULL guard --------------
    # dfa_exponent is the REAL DFA exponent; drift_detected is the REAL
    # |drift|>threshold (true for the step-up series); recent/baseline alphas
    # are real; rationale is the reason step (canary).
    $r18 = Psql -Sql @"
SELECT dfa_exponent::text FROM fractal_agent_regime_triage(
  (SELECT array_agg(v ORDER BY t) FROM (
     SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                    ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
     FROM generate_series(1,96) t) s),
  64, 0.5);
"@
    if ($r18 -match '^-?[0-9]+(\.[0-9]+)?$') { Pass "23 agents: regime_triage dfa_exponent is the real DFA exponent" }
    else { Fail "23 agents: expected a numeric dfa_exponent, got: $r18" }

    $r18b = Psql -Sql @"
SELECT drift_detected::text FROM fractal_agent_regime_triage(
  (SELECT array_agg(v ORDER BY t) FROM (
     SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                    ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
     FROM generate_series(1,96) t) s),
  64, 0.5);
"@
    if ($r18b -match '^true$') { Pass "23 agents: regime_triage drift_detected=true for a real regime-change series (|drift|>0.5)" }
    else { Fail "23 agents: expected drift_detected=t, got: $r18b" }

    $r18c = Psql -Sql @"
SELECT rationale FROM fractal_agent_regime_triage(
  (SELECT array_agg(v ORDER BY t) FROM (
     SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                    ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
     FROM generate_series(1,96) t) s),
  64, 0.5);
"@
    if ($r18c -match 'gap-analysis-canary') { Pass "23 agents: regime_triage composes dfa+drift -> reason (canary)" }
    else { Fail "23 agents: expected the canary in rationale, got: $r18c" }

    $r18d = Psql -Sql "SELECT * FROM fractal_agent_regime_triage(NULL::float8[], 64, 0.5);"
    if ($r18d -match 'series is required') { Pass "23 agents: regime_triage raises a clean ERROR when series is NULL" }
    else { Fail "23 agents: expected a series-required ERROR, got: $r18d" }

    # An EXPLICIT NULL for the trailing optional numeric parameter must fall
    # back to the documented default (0.5), like the sibling's da_opt_double.
    # PostgreSQL substitutes a DEFAULT only for an OMITTED argument, so
    # without the COALESCE the comparison `abs(dv) > drift_threshold` yields
    # NULL, drift_detected comes back NULL (not true) and the prompt text is
    # left with a hole. The series is the SAME shape as the passing
    # assertion above -- only the third argument differs (NULL instead of
    # 0.5) -- so the assertion isolates the COALESCE and nothing else. (A
    # two-level step series is NOT usable here: the core drift estimator
    # rejects a degenerate series with rc=-1 before the threshold is ever
    # compared.)
    $r18e = Psql -Sql @"
SELECT drift_detected::text FROM fractal_agent_regime_triage(
  (SELECT array_agg(v ORDER BY t) FROM (
     SELECT t, CASE WHEN t<48 THEN 4.0+1.5*sin(t*0.31)+(random()-0.5)*0.8
                    ELSE 4.0+3.0*sin(t*1.4)+(random()-0.5)*0.4 END AS v
     FROM generate_series(1,96) t) s),
  64, NULL);
"@
    if ($r18e -match '^true$') { Pass "23 agents: regime_triage applies the 0.5 default when drift_threshold is an explicit NULL" }
    else { Fail "23 agents: expected drift_detected=t for an explicit-NULL drift_threshold, got: '$r18e'" }

    # Restore session state: diversify was enabled by recommend_diverse and
    # feedback_audit (feedback_audit self-disables, but belt-and-suspenders).
    Psql -Sql "SELECT fractal_diversify_disable();" | Out-Null

    Psql -Sql "DROP TABLE IF EXISTS bt_agents_caps, bt_agents_badstates, bt_agents_mem, bt_agents_catalog;" | Out-Null
    Psql -Sql "DROP TABLE IF EXISTS bt_agents_logs;" | Out-Null
    Psql -Sql "DROP TABLE IF EXISTS bt_agents_data, bt_agents_patients, bt_agents_fcatalog, bt_agents_fwarmup, bt_agents_nodes, bt_agents_alloc, bt_agents_vehicles, bt_agents_tracks;" | Out-Null
    Remove-Item -Force $SqlFile -ErrorAction SilentlyContinue
}

# Windows port of build_test.sh's Gate 21 (--fuzz). No live cluster
# needed -- same as gate 01, this builds and briefly runs standalone
# .exe's linking only src\fractalsql_parse.c (postgres.h-free by
# design, see that file's header comment) + one libFuzzer driver each,
# nothing else. Uses $script:ClangCl (resolved by -Fuzz/-Ubsan's shared
# Find-ClangCl call above) -- LLVM's fuzzer support is a real, long-
# standing clang-cl feature, not something Linux-only that needed
# reinventing here.
#
# Same stderr-redirection care as every other native-process call in
# this file: libFuzzer writes its progress/coverage stats to STDERR
# continuously throughout the run (confirmed convention, same on every
# platform) -- a bare `&` invocation would trip PowerShell 7.3+'s
# ANY-stderr-is-a-terminating-error behavior on the very first progress
# line, the exact class of regression already found and fixed in
# PgSetup's pg_ctl start call this session. Unlike that case, THIS
# process has no long-lived daemon children (the fuzzer exits cleanly
# once -max_total_time elapses), so reading its redirected pipes to EOF
# via ReadToEndAsync().Result is safe -- same safety profile as initdb,
# not pg_ctl start.
function Gate21FuzzSmoke {
    $fuzzDir = Join-Path $RepoRoot 'dist\windows-fuzz'
    if (Test-Path $fuzzDir) { Remove-Item -Recurse -Force $fuzzDir }
    New-Item -ItemType Directory -Force -Path $fuzzDir | Out-Null

    $srcParse = Join-Path $RepoRoot 'src\fractalsql_parse.c'
    $srcDir   = Join-Path $RepoRoot 'src'
    $fuzzTime = if ($env:FSQL_FUZZ_TIME) { $env:FSQL_FUZZ_TIME } else { '30' }

    # clang-cl defaults to /MD (dynamic CRT), so -fsanitize=address links
    # against clang_rt.asan_dynamic-x86_64.dll rather than a static
    # runtime -- unlike -Ubsan's UBSan runtime, which is a static .lib
    # with no launch-time dependency at all. Without this DLL's directory
    # on PATH, the built .exe fails to even START (STATUS_DLL_NOT_FOUND,
    # exit -1073741511 / 0xC0000135) -- confirmed on a real run: all 3
    # targets "failed" identically, which was the tell that this was a
    # launch failure, not 3 independent fuzzer-found crashes. Resolve the
    # runtime directory the same way Find-ClangCl resolves the compiler
    # itself, and prepend it to PATH for this process only.
    $clangResourceDir = $null
    try { $clangResourceDir = (& $script:ClangCl -print-resource-dir 2>$null | Select-Object -First 1) } catch { Write-Verbose "best-effort: clang -print-resource-dir absent/unsupported is not fatal, `$clangResourceDir stays `$null: $($_.Exception.Message)" }
    if ($clangResourceDir) {
        $sanRtDir = Join-Path $clangResourceDir 'lib\windows'
        if (Test-Path $sanRtDir) { $env:PATH = "$sanRtDir;$env:PATH" }
    }

    foreach ($target in @('parse_embedding_array', 'extract_best_point', 'extract_population')) {
        $bin    = Join-Path $fuzzDir "fuzz_$target.exe"
        $driver = Join-Path $RepoRoot "tests\fuzz\fuzz_$target.c"
        $corpus = Join-Path $RepoRoot "tests\fuzz\corpus_$target"

        # /Fe<name> (direct concatenation, no colon) -- same form already
        # proven working in Build-UbsanExtension's own $script:ClangCl
        # invocations above, not a new untested variant.
        $compileArgs = @(
            # -std=c99 dropped: clang-cl (cl.exe-compatible mode) doesn't
            # recognize that spelling ("unknown argument ignored" warning,
            # harmless but noisy) and fractalsql_parse.c needs nothing
            # beyond clang-cl's own C default.
            '-O1', '-Zi', '-fsanitize=fuzzer,address',
            "-I$srcDir",
            $srcParse, $driver,
            "/Fe$bin"
        )
        & $script:ClangCl @compileArgs
        if ($LASTEXITCODE -ne 0) {
            Fail "21 fuzz_smoke: $target -- build failed (exit $LASTEXITCODE)"
            continue
        }

        $fuzzPsi = New-Object System.Diagnostics.ProcessStartInfo
        $fuzzPsi.FileName = $bin
        foreach ($a in @("-max_total_time=$fuzzTime", '-print_final_stats=1', $corpus)) {
            $fuzzPsi.ArgumentList.Add($a)
        }
        $fuzzPsi.RedirectStandardOutput = $true
        $fuzzPsi.RedirectStandardError  = $true
        $fuzzPsi.UseShellExecute = $false
        $fuzzProc = [System.Diagnostics.Process]::Start($fuzzPsi)
        $fuzzOutTask = $fuzzProc.StandardOutput.ReadToEndAsync()
        $fuzzErrTask = $fuzzProc.StandardError.ReadToEndAsync()
        $fuzzProc.WaitForExit()
        $fuzzOut = $fuzzOutTask.Result
        $fuzzErr = $fuzzErrTask.Result

        if ($fuzzProc.ExitCode -eq 0) {
            $execsMatch = [regex]::Match($fuzzErr, 'stat::number_of_executed_units:\s*(\d+)')
            $execs = if ($execsMatch.Success) { $execsMatch.Groups[1].Value } else { '?' }
            Pass "21 fuzz_smoke: $target -- ${fuzzTime}s clean ($execs execs, no crash)"
        } else {
            $logPath = Join-Path $fuzzDir "fuzz_${target}_crash.log"
            ($fuzzOut + "`n" + $fuzzErr) | Out-File -FilePath $logPath -Encoding utf8
            Fail "21 fuzz_smoke: $target -- crash/hang found (exit $($fuzzProc.ExitCode)), see $logPath"
        }
        Remove-Item -Force $bin -ErrorAction SilentlyContinue
    }
}

# --- dispatch --------------------------------------------------------------
function Gate24Enterprise {
    # QTL ledger + CISO audit -- runtime-gated behind the enterprise core
    # library. Self-skips on a community-only checkout (no enterprise
    # shared lib vendored in include/). When present, exercises the full
    # wiring: dlopen + dlsym of fsql_ledger_*/fsql_audit_unpack, the
    # Postgres-backed storage VFS round-trip (flush -> fractalsql_ledger ->
    # audit_unpack), and the dormant-path error when the library is absent.
    $ent = Get-ChildItem -Path include -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(lib)?fractalsql-enterprise-sovereign-c\.dll$' } |
        Select-Object -First 1
    if (-not $ent) {
        Skip "24 enterprise: skipped (community edition; no fractalsql-enterprise-sovereign-c.* shared lib in include/)"
        return
    }
    $abs = $ent.FullName

    # Phase E below calls agents that invoke fractal_reason -- make sure the
    # mock plugin is active regardless of whether gate 23 ran first (this
    # gate must be standalone-runnable, same rationale as gate 23's swap).
    PgSwapPlugin $Mock | Out-Null

    # fractalsql.enterprise_lib is PGC_SIGHUP: ALTER SYSTEM + reload, then a
    # short settle delay -- pg_reload_conf() returns before the postmaster
    # re-reads config, so a fresh backend started immediately could still
    # see the old value. The local build_test cluster reloads in ms.
    $applyGuc = {
        param($val)
        $escaped = $val -replace "'", "''"
        [void](Psql -Sql "ALTER SYSTEM SET fractalsql.enterprise_lib = '$escaped';")
        [void](Psql -Sql "SELECT pg_reload_conf();")
        Start-Sleep -Milliseconds 1500
    }

    # Phase A: enterprise library present -- the surface activates.
    & $applyGuc $abs
    $ra = Psql -Sql @"
SELECT fractal_ledger_flush();
SELECT fractal_ledger_truth_count() AS truth, fractal_ledger_shadow_count() AS shadow;
SELECT fractal_ledger_load();
SELECT fractal_ledger_compact();
SELECT fractal_ledger_reset_soft();
SELECT fractal_ledger_reset_hard();
SELECT fractal_audit_unpack(blob)::text AS audit
  FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
"@
    if ($ra -match 'ERROR:') {
        Fail "24 enterprise: ledger/audit errored with the enterprise library present: $ra"
    } else {
        Pass "24 enterprise: ledger flush/load/compact/reset/counts work with the enterprise library"
    }
    if ($ra -match '\[\]') {
        Pass "24 enterprise: fractal_audit_unpack decoded the persisted QTL blob end-to-end (storage VFS round-trip)"
    } else {
        Fail "24 enterprise: audit_unpack did not return the flushed QTL jsonb (got: $ra)"
    }

    # Phase B: point the GUC at a missing path -- the surface goes dormant,
    # equivalent to removing the .dll. Fresh backend -> LoadLibrary fails ->
    # the documented 'enterprise tier not loaded' error.
    & $applyGuc '/nonexistent/fractalsql-enterprise-absent.dll'
    $rb = Psql -Sql "SELECT fractal_ledger_flush();"
    if ($rb -match 'enterprise tier not loaded') {
        Pass "24 enterprise: ledger functions return 'enterprise tier not loaded' when the library is absent"
    } else {
        Fail "24 enterprise: expected 'enterprise tier not loaded' when absent, got: $rb"
    }

    # Phase C: fractal_optimize_portfolio_multimodal -- dormant then active.
    $rcDormant = Psql -Sql "SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);"
    if ($rcDormant -match 'enterprise tier not loaded') {
        Pass "24 enterprise: portfolio_multimodal returns 'enterprise tier not loaded' when the library is absent"
    } else {
        Fail "24 enterprise: expected 'enterprise tier not loaded' for portfolio_multimodal when absent, got: $rcDormant"
    }
    & $applyGuc $abs
    # Psql concatenates stdout+stderr (see its own header comment) -- the
    # enterprise-lib load WARNING that fires on every fresh connection
    # lands in stderr, appended AFTER the real stdout result. An anchored
    # ^...$ match against the whole combined string breaks on that extra
    # text even though the actual value is correct; take just the first
    # line (the real stdout result) before matching, same as every other
    # gate's loose substring checks already tolerate implicitly.
    $rcActive = Psql -Sql "SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2, 4)->>'n_found';"
    $rcActiveFirstLine = (($rcActive -split "`r?`n")[0]).Trim()
    if ($rcActiveFirstLine -match '^[1-9][0-9]?$') {
        Pass "24 enterprise: portfolio_multimodal returns real candidates (n_found=$rcActiveFirstLine) with the library present"
    } else {
        Fail "24 enterprise: expected a positive n_found from portfolio_multimodal, got: $rcActive"
    }

    # Phase D: fractal_audit_log / fractal_ledger_verify(2) -- the general
    # decision-audit chain. Library still active from Phase C.
    [void](Psql -Sql "DELETE FROM fractalsql_ledger WHERE kind = 2;")
    $rdWrite = Psql -Sql "SELECT fractal_audit_log('test_entry', '{""note"":""gate24""}'::jsonb);"
    if ($rdWrite -match 'ERROR:') {
        Fail "24 enterprise: fractal_audit_log errored with the library present: $rdWrite"
    } else {
        Pass "24 enterprise: fractal_audit_log writes to the audit chain (kind=2) with the library present"
    }
    # Same stdout+stderr-concatenation issue as the n_found check above --
    # take just the first line before comparing.
    $rdVerifyRaw = Psql -Sql "SELECT fractal_ledger_verify(2)->>'ok';"
    $rdVerify = (($rdVerifyRaw -split "`r?`n")[0]).Trim()
    if ($rdVerify -eq 'true') {
        Pass "24 enterprise: fractal_ledger_verify(2) confirms the audit chain is clean"
    } else {
        Fail "24 enterprise: expected fractal_ledger_verify(2) ok=true, got: $rdVerifyRaw"
    }

    # TryParse, not a blind [int] cast: a dead/recovering connection (e.g.
    # if something upstream in this gate crashed the backend) returns
    # psql's error text here, not a number -- a blind cast throws an
    # unhandled exception that kills the whole script instead of failing
    # this one assertion cleanly (same TryParse pattern already used
    # elsewhere in this file, e.g. Gate11Scout/Gate19SfsBounds).
    $rdBeforeRaw = (Psql -Sql "SELECT count(*) FROM fractalsql_ledger WHERE kind = 2;").Trim()
    [void](Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);")
    $rdAfterRaw = (Psql -Sql "SELECT count(*) FROM fractalsql_ledger WHERE kind = 2;").Trim()
    $rdBefore = 0; $rdAfter = 0
    if (-not [int]::TryParse($rdBeforeRaw, [ref]$rdBefore) -or -not [int]::TryParse($rdAfterRaw, [ref]$rdAfter)) {
        Fail "24 enterprise: could not read kind=2 row count (before='$rdBeforeRaw' after='$rdAfterRaw') -- connection likely dead"
    } elseif ($rdAfter -gt $rdBefore) {
        Pass "24 enterprise: fractal_optimize_portfolio logs a provenance record to the audit chain when enterprise is active"
    } else {
        Fail "24 enterprise: expected a new kind=2 row after fractal_optimize_portfolio, before=$rdBefore after=$rdAfter"
    }

    & $applyGuc '/nonexistent/fractalsql-enterprise-absent.dll'
    $rdDormant = Psql -Sql "SELECT fractal_audit_log('test_entry', '{}'::jsonb);"
    if ($rdDormant -match 'enterprise tier not loaded') {
        Pass "24 enterprise: fractal_audit_log returns 'enterprise tier not loaded' when the library is absent"
    } else {
        Fail "24 enterprise: expected 'enterprise tier not loaded' for fractal_audit_log when absent, got: $rdDormant"
    }
    $rdPortfolioStillWorks = Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);"
    if ($rdPortfolioStillWorks -match 'ERROR:') {
        Fail "24 enterprise: fractal_optimize_portfolio broke on community (no enterprise lib): $rdPortfolioStillWorks"
    } else {
        Pass "24 enterprise: fractal_optimize_portfolio (community feature) keeps working with the enterprise library absent"
    }

    # Phase E: representative sample of the newly-wired agent bindings --
    # confirm each writes a correctly-typed kind=2 row when enterprise is
    # active. Gate 23 already proves all 11 candidates behave identically
    # (best-effort no-op) on community; this proves the enterprise side of
    # the same bindings actually fires.
    & $applyGuc $abs
    $latestAuditType = {
        (Psql -Sql "SELECT convert_from(blob, 'UTF8')::jsonb->>'type' FROM fractalsql_ledger WHERE kind = 2 ORDER BY id DESC LIMIT 1;").Trim()
    }

    [void](Psql -Sql @"
DROP TABLE IF EXISTS bt_gate24_history;
CREATE TABLE bt_gate24_history (id int PRIMARY KEY, emb float8[]);
INSERT INTO bt_gate24_history VALUES (1, ARRAY[0.1,0.2,0.3]);
"@)
    [void](Psql -Sql "SELECT * FROM fractal_agent_outlier_intercept(ARRAY[0.1,0.2,0.3]::float8[], 'bt_gate24_history', 'emb', 0.5);")
    if ((& $latestAuditType) -eq 'agent_outlier_intercept') {
        Pass "24 enterprise: fractal_agent_outlier_intercept logs a provenance record to the audit chain"
    } else {
        Fail "24 enterprise: expected agent_outlier_intercept in the latest kind=2 row"
    }

    [void](Psql -Sql @"
DROP TABLE IF EXISTS bt_gate24_data;
CREATE TABLE bt_gate24_data (id int PRIMARY KEY, val float8);
INSERT INTO bt_gate24_data VALUES (1,10.5),(2,20.5);
"@)
    [void](Psql -Sql "SELECT * FROM fractal_agent_data_analyst('sum of val', ARRAY['bt_gate24_data'], 2);")
    if ((& $latestAuditType) -eq 'agent_data_analyst') {
        Pass "24 enterprise: fractal_agent_data_analyst logs a provenance record to the audit chain"
    } else {
        Fail "24 enterprise: expected agent_data_analyst in the latest kind=2 row"
    }

    # fractal_agent_diverse_portfolios (enterprise-only gap-fix binding) --
    # both the C-side portfolio_optimize_multimodal entry and the agent-level
    # entry must land (same double-logging pattern as allocate/rebalance).
    [void](Psql -Sql "SELECT * FROM fractal_agent_diverse_portfolios(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2, 4);")
    $rdDiverseTypes = Psql -Sql "SELECT convert_from(blob, 'UTF8')::jsonb->>'type' FROM fractalsql_ledger WHERE kind = 2 ORDER BY id DESC LIMIT 2;"
    if ($rdDiverseTypes -match 'agent_diverse_portfolios' -and $rdDiverseTypes -match 'portfolio_optimize_multimodal') {
        Pass "24 enterprise: fractal_agent_diverse_portfolios + fractal_optimize_portfolio_multimodal both log (double-logging, gap-fix binding)"
    } else {
        Fail "24 enterprise: expected both agent_diverse_portfolios and portfolio_optimize_multimodal in the last 2 kind=2 rows, got: $rdDiverseTypes"
    }

    # Reset the GUC so it does not leak into later gates on a reused cluster.
    [void](Psql -Sql "ALTER SYSTEM RESET fractalsql.enterprise_lib;")
    [void](Psql -Sql "SELECT pg_reload_conf();")
}

function Gate25EnterpriseStress {
    # Enterprise QTL ledger under stress + tamper-evidence + concurrency.
    # Self-skips on a community-only checkout (same detection as gate 24).
    # Gate 24 covers the basic active/dormant wiring; this gate exercises
    # the ledger at its capacity bound, under repeated churn, against a
    # corrupted blob, and under concurrent + cross-backend access.
    $ent = Get-ChildItem -Path include -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(lib)?fractalsql-enterprise-sovereign-c\.dll$' } |
        Select-Object -First 1
    if (-not $ent) {
        Skip "25 enterprise-stress: skipped (community edition; no fractalsql-enterprise-sovereign-c.* shared lib in include/)"
        return
    }
    $abs = $ent.FullName

    # PGC_SIGHUP GUC -- same apply + settle pattern as gate 24.
    $applyGuc = {
        param($val)
        $escaped = $val -replace "'", "''"
        [void](Psql -Sql "ALTER SYSTEM SET fractalsql.enterprise_lib = '$escaped';")
        [void](Psql -Sql "SELECT pg_reload_conf();")
        Start-Sleep -Milliseconds 1500
    }

    & $applyGuc $abs

    # Clean slate for the gate.
    [void](Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;")

    # ---- Phase A: stress -- fill-to-cap (64 truth + 64 shadow = 128) + churn.
    # Truth/Shadow each cap at 64 (FSQL_TRUTH/SHADOW_DEFAULT_CAP); beyond that
    # the lowest-weight entry is evicted. 64+64 with disjoint doc_ids encodes
    # all 128 (no QTL dedup). Churn = 10 reset+reseed+flush+load cycles.
    # @'...'@ (single-quoted here-string) so $$/PL/pgSQL vars are not expanded
    # by PowerShell -- see the Psql function's comment on -f - via stdin.
    $ra = Psql -Sql @'
SELECT fractal_diversify_enable();
DO $$
DECLARE i int; c int; tc bigint; sc bigint; ev int; audit jsonb;
BEGIN
  PERFORM fractal_ledger_reset_hard();
  FOR i IN 1..64 LOOP PERFORM fractal_feedback_report(i, 'positive'); END LOOP;
  FOR i IN 65..128 LOOP PERFORM fractal_feedback_report(i, 'negative'); END LOOP;
  SELECT fractal_ledger_truth_count()  INTO tc;
  SELECT fractal_ledger_shadow_count() INTO sc;
  PERFORM fractal_ledger_flush();
  SELECT fractal_audit_unpack(blob) INTO audit FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
  ev := jsonb_array_length(audit);
  IF tc <> 64 OR sc <> 64 OR ev <> 128 THEN
    RAISE EXCEPTION 'A fill mismatch: truth=% shadow=% events=%', tc, sc, ev;
  END IF;
  FOR c IN 1..10 LOOP
    PERFORM fractal_ledger_reset_hard();
    FOR i IN 1..64  LOOP PERFORM fractal_feedback_report(i + 1000*c, 'positive'); END LOOP;
    FOR i IN 65..128 LOOP PERFORM fractal_feedback_report(i + 1000*c, 'negative'); END LOOP;
    PERFORM fractal_ledger_flush();
    PERFORM fractal_ledger_load();
  END LOOP;
  SELECT fractal_ledger_truth_count()  INTO tc;
  SELECT fractal_ledger_shadow_count() INTO sc;
  SELECT fractal_audit_unpack(blob) INTO audit FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
  ev := jsonb_array_length(audit);
  IF tc <> 64 OR sc <> 64 OR ev <> 128 THEN
    RAISE EXCEPTION 'A churn mismatch: truth=% shadow=% events=%', tc, sc, ev;
  END IF;
END $$;
'@
    if ($ra -match 'ERROR:') {
        Fail "25 enterprise-stress Phase A: fill-to-cap/churn errored: $ra"
    } else {
        Pass "25 enterprise-stress Phase A: fill-to-cap (64+64=128) + 10 flush/load churn cycles, audit round-trips 128 events"
    }

    # ---- Phase B: tamper-evidence (structural). Truncate the persisted QTL
    # blob below the 24-byte header and assert load rejects it. NOTE: the QTL
    # format carries no CRC/MAC and ledger_seal_ledger is a no-op, so this is
    # STRUCTURAL tamper-evidence only -- a targeted payload byte-flip is NOT
    # caught. The gate asserts the structural case and documents the gap.
    [void](Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;")
    $rb = Psql -Sql @'
SELECT fractal_diversify_enable();
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(1, 'positive');
SELECT fractal_feedback_report(2, 'negative');
SELECT fractal_ledger_flush();
UPDATE fractalsql_ledger SET blob = substring(blob from 1 for 5) WHERE id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 1);
SELECT fractal_ledger_load();
'@
    # B-full's entry_hash covers the blob unconditionally (no key
    # required), so this UPDATE is now caught by ledger_verify_latest()'s
    # chain-hash check BEFORE the core's own structural decode ever runs.
    # Accept either message.
    if ($rb -match 'ERROR:' -and $rb -match '(fsql_ledger_load|ledger chain verification failed)') {
        Pass "25 enterprise-stress Phase B: structural tamper (truncated QTL blob) rejected by load"
    } else {
        Fail "25 enterprise-stress Phase B: expected load to reject a truncated blob, got: $rb"
    }

    # ---- Phase C: concurrency.
    # (a) Cross-session persistence: seed+flush in one backend, load+count in
    #     a FRESH backend; counts must match (proves the table-backed VFS is
    #     backend-independent, not in-memory only).
    # (b) 8 concurrent backends each seed one event + flush. Under B-full's
    #     append-only chain this correctly produces MULTIPLE rows (B-lite's
    #     UPSERT collapsed concurrent flushes into one; that's gone by
    #     design). The invariant now is that the chain stays a single
    #     unforked line -- ledger_write_entry's advisory xact lock (keyed
    #     on kind) serializes the "read head, link, insert" sequence.
    [void](Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;")
    # NOTE: seed+flush MUST run as ONE Psql call (one backend, one
    # g_ctx) -- each separate call previously below opened its own
    # psql.exe process/connection/backend, so the in-memory truth/
    # shadow ledgers from one call were never visible to the next and
    # fractal_ledger_flush() persisted an EMPTY ledger (the
    # cross-session load then correctly reported 0|0, silently masking
    # this rather than erroring). Semicolon-joined is safe here (not
    # DDL, no ALTER SYSTEM reload-visibility hazard like PgSetGuc).
    [void](Psql -Sql "SELECT fractal_diversify_enable(); SELECT fractal_ledger_reset_hard(); SELECT fractal_feedback_report(g, 'positive') FROM generate_series(1,10) g; SELECT fractal_feedback_report(g, 'negative') FROM generate_series(11,20) g; SELECT fractal_ledger_flush();")
    $cross = Psql -Sql "SELECT fractal_ledger_load(); SELECT fractal_ledger_truth_count() AS t, fractal_ledger_shadow_count() AS s;"
    if ($cross -match '10\|10') {
        Pass "25 enterprise-stress Phase C(a): cross-session persistence -- fresh backend loaded 10/10 from the persisted blob"
    } else {
        Fail "25 enterprise-stress Phase C(a): expected 10|10 after cross-session load, got: $cross"
    }

    # 8 concurrent workers, each: seed one event + flush. Fresh chain
    # (drop first) so the row count is self-contained; pre-flush one row
    # before the workers start so they write to an EXISTING chain,
    # avoiding the concurrent CREATE TABLE IF NOT EXISTS race on pg_class.
    # feedback_report inserts unconditionally, so workers need not
    # re-enable diversify. Invariant: 9 rows total (1 pre-flush + 8
    # concurrent), chain verifies as one unforked line, latest blob
    # decodes. ForEach-Object -Parallel runs in an isolated runspace that
    # doesn't inherit script-scope functions/vars, so psql.exe is
    # launched inline via the Process API (same pattern as Gate12Soak)
    # with $Bin/$Port captured via $using:. Short -c SQL is well under the
    # 32K cmdline cap.
    [void](Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;")
    [void](Psql -Sql "SELECT fractal_diversify_enable(); SELECT fractal_feedback_report(0, 'positive'); SELECT fractal_ledger_flush();")
    $workers = 8
    $results = 1..$workers | ForEach-Object -Parallel {
        $w = $_
        $bin = $using:Bin
        $port = $using:Port
        $q = "SELECT fractal_feedback_report($w, 'positive'); SELECT fractal_ledger_flush();"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$bin\psql.exe"
        foreach ($a in @('-h','127.0.0.1','-p',"$port",'-U','postgres','-d','postgres','-X','-tA','-c',$q)) {
            $psi.ArgumentList.Add($a)
        }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $soT = $proc.StandardOutput.ReadToEndAsync()
        $seT = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $soT.Result | Out-Null
        $seT.Result | Out-Null
        $proc.ExitCode
    } -ThrottleLimit $workers

    # The invariant is chain consistency, not that every worker's flush
    # produced a distinguishable outcome -- a worker whose tx aborts under
    # contention rolls back cleanly and cannot corrupt the chain, so
    # failedWorkers is reported but does not gate the pass (a real
    # failure surfaces as rows != 9, verify not ok, or a decode ERROR).
    $failedWorkers = @($results | Where-Object { $_ -ne 0 }).Count
    # fractal_ledger_verify() re-runs the same schema-ensure check as
    # flush/migrate, so it NOTICEs "already exists, skipping" for the
    # table + index on every call once they exist (harmless, expected
    # Postgres behavior). Psql concatenates stdout+stderr with stdout
    # first, so those NOTICEs land AFTER the real 'true'/'false' value in
    # the captured string -- same issue as gate 24's rdVerify check, take
    # just the first line before comparing.
    $rowsRaw = (Psql -Sql "SELECT count(*) FROM fractalsql_ledger WHERE kind = 1;")
    $rows = (($rowsRaw -split "`r?`n")[0]).Trim()
    $verifyOkRaw = (Psql -Sql "SELECT fractal_ledger_verify()->>'ok';")
    $verifyOk = (($verifyOkRaw -split "`r?`n")[0]).Trim()
    $latestDecode = Psql -Sql "SELECT fractal_audit_unpack(blob)::text FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;"
    if ($rows -eq '9' -and $verifyOk -eq 'true' -and $latestDecode -notmatch 'ERROR:') {
        Pass "25 enterprise-stress Phase C(b): 8 concurrent flushes -> 9 append-only rows, chain verifies as one unforked line, latest blob decodes ($failedWorkers worker(s) aborted under contention, ledger consistent)"
    } else {
        Fail "25 enterprise-stress Phase C(b): expected 9 linked rows + clean decode after parallel flush, got failedWorkers=$failedWorkers rows=$rows verifyOk=$verifyOk decode=$latestDecode"
    }

    # ---- Phase D: MAC-authenticated tamper-evidence (enterprise_ledger_key).
    # Phases A-C ran with the key UNSET (structural path). D sets the key
    # (PGC_SUSET -> SET per-session, no reload): flush tags the blob with
    # HMAC-SHA256 (assert length(mac)=32), load verifies; a middle payload
    # byte-flip (length + count preserved -> structural check blind to it) is
    # rejected by the MAC; re-flush re-tags and load verifies clean. This is
    # B-lite: the MAC lives in the open extension at the storage seam; the
    # enterprise core is unchanged and is never handed tampered bytes.
    # @'...'@ single-quoted here-string so $$/PL-pgSQL vars are not expanded.
    [void](Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;")
    $rd = Psql -Sql @'
SET fractalsql.enterprise_ledger_key = 'gate25-mac-key';
DO $$
DECLARE mac_len int;
BEGIN
  PERFORM fractal_diversify_enable();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(1, 'positive');
  PERFORM fractal_ledger_flush();
  SELECT length(mac) INTO mac_len FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
  IF mac_len IS NULL OR mac_len <> 32 THEN
    RAISE EXCEPTION 'D tag mismatch: mac length = % (expected 32)', mac_len;
  END IF;
  PERFORM fractal_ledger_load();
  UPDATE fractalsql_ledger
     SET blob = set_byte(blob, length(blob) / 2, 254)
   WHERE id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 1);
  BEGIN
    PERFORM fractal_ledger_load();
    RAISE EXCEPTION 'D tamper NOT detected: load accepted a byte-flipped blob';
  EXCEPTION
    WHEN internal_error THEN
      RAISE NOTICE 'D tamper detected by HMAC (byte-flip rejected)';
  END;
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(1, 'positive');
  PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_load();
EXCEPTION
  WHEN object_not_in_prerequisite_state THEN
    RAISE EXCEPTION 'D enterprise not loaded';
END $$;
RESET fractalsql.enterprise_ledger_key;
'@
    if ($rd -match 'D tamper detected by HMAC') {
        Pass "25 enterprise-stress Phase D: HMAC MAC tags blob (32B), rejects a structural-blind byte-flip, re-flush re-tags cleanly"
    } else {
        Fail "25 enterprise-stress Phase D: MAC path did not behave as expected: $rd"
    }

    # ---- Phase E: B-full append-only chain -- multi-row verify, a
    # MIDDLE-row tamper that load()'s O(1) tip-only check cannot see but
    # verify()'s full O(n) walk catches, and a deleted-row gap. NOTE
    # (documented limitation, not tested here): a chain can prove nothing
    # in the MIDDLE was altered/removed, but not that nothing was
    # truncated off the very END -- that needs an external anchor, out of
    # scope here.
    [void](Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;")
    $re = Psql -Sql @'
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM fractal_diversify_enable();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(1, 'positive'); PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(2, 'positive'); PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(3, 'positive'); PERFORM fractal_ledger_flush();

  SELECT fractal_ledger_verify() INTO v;
  IF NOT (v->>'ok')::boolean OR (v->>'rows_verified')::int <> 3 THEN
    RAISE EXCEPTION 'E chain mismatch after 3 flushes: %', v;
  END IF;
  RAISE NOTICE 'E verify: 3/3 rows clean after 3 flushes';

  UPDATE fractalsql_ledger SET blob = set_byte(blob, 0, 254) WHERE id = 2;

  PERFORM fractal_ledger_load();
  RAISE NOTICE 'E load: still passes after a MIDDLE-row tamper (O(1) tip-only scope)';

  SELECT fractal_ledger_verify() INTO v;
  IF (v->>'ok')::boolean OR (v->>'first_failure_id')::int <> 2 THEN
    RAISE EXCEPTION 'E verify() did not catch the middle-row tamper: %', v;
  END IF;
  RAISE NOTICE 'E verify: caught middle-row tamper at id=2 (%)', v->>'reason';
END $$;
'@
    if ($re -match 'E verify: 3/3 rows clean' -and $re -match 'E load: still passes' -and $re -match 'E verify: caught middle-row tamper') {
        Pass "25 enterprise-stress Phase E: B-full chain -- multi-row verify, middle-row tamper undetected by load but caught by verify()"
    } else {
        Fail "25 enterprise-stress Phase E: B-full chain checks did not behave as expected: $re"
    }

    [void](Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;")
    $rg = Psql -Sql @'
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM fractal_diversify_enable();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(1, 'positive'); PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(2, 'positive'); PERFORM fractal_ledger_flush();
  PERFORM fractal_ledger_reset_hard();
  PERFORM fractal_feedback_report(3, 'positive'); PERFORM fractal_ledger_flush();

  DELETE FROM fractalsql_ledger WHERE id = 2;

  SELECT fractal_ledger_verify() INTO v;
  IF (v->>'ok')::boolean OR (v->>'reason' NOT LIKE '%gap%') THEN
    RAISE EXCEPTION 'E deletion gap not detected: %', v;
  END IF;
  RAISE NOTICE 'E verify: caught deletion gap (%)', v->>'reason';
END $$;
'@
    if ($rg -match 'E verify: caught deletion gap') {
        Pass "25 enterprise-stress Phase E: deleting a middle row leaves a visible id-sequence gap, caught by verify()"
    } else {
        Fail "25 enterprise-stress Phase E: deletion gap detection did not behave as expected: $rg"
    }

    # Migrating an existing B-lite-shaped table (kind PK, no id/prev_hash/
    # entry_hash) -- expect a NOTICE and a clean fresh chain, not an error.
    [void](Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;")
    [void](Psql -Sql @'
CREATE TABLE fractalsql_ledger (
  kind    integer PRIMARY KEY,
  blob    bytea   NOT NULL,
  mac     bytea,
  sealed  boolean NOT NULL DEFAULT false,
  updated timestamptz NOT NULL DEFAULT now()
);
INSERT INTO fractalsql_ledger (kind, blob) VALUES (1, '\x00'::bytea);
'@)
    $rm = Psql -Sql "SELECT fractal_diversify_enable(); SELECT fractal_ledger_reset_hard(); SELECT fractal_feedback_report(1, 'positive'); SELECT fractal_ledger_flush();"
    $rmVerify = Psql -Sql "SELECT fractal_ledger_verify();"
    if ($rm -match 'migrating fractalsql_ledger from the single-row snapshot schema' -and $rmVerify -match '"ok"\s*:\s*true') {
        Pass "25 enterprise-stress Phase E: single-row-snapshot -> append-only-chain schema migration -- NOTICE fires, fresh chain verifies clean"
    } else {
        Fail "25 enterprise-stress Phase E: migration did not behave as expected: flush=$rm verify=$rmVerify"
    }

    # Reset the GUC so it does not leak into later gates on a reused cluster.
    [void](Psql -Sql "ALTER SYSTEM RESET fractalsql.enterprise_lib;")
    [void](Psql -Sql "SELECT pg_reload_conf();")
}

function Gate26EnterpriseSignature {
    # Detached Ed25519 signature verification for the enterprise .so
    # (fractalsql.enterprise_require_signature). Self-skips on a
    # community-only checkout, same detection as gates 24/25.
    #
    # Deliberately does NOT test the "valid signature, actually verifies"
    # happy path -- that requires the matching private key, which is
    # FractalSQLabs's release-process secret and does not belong in this
    # repo or its test fixtures. That path was validated manually against
    # a throwaway keypair during development (see fractalsql.c's
    # FSQL_ENTERPRISE_PUBKEY comment). What's tested here needs no key at
    # all: a missing .sig (soft unless require=on) and an invalid .sig
    # (always hard-refused, regardless of require).
    $ent = Get-ChildItem -Path include -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(lib)?fractalsql-enterprise-sovereign-c\.dll$' } |
        Select-Object -First 1
    if (-not $ent) {
        Skip "26 enterprise-signature: skipped (community edition; no fractalsql-enterprise-sovereign-c.* shared lib in include/)"
        return
    }
    $abs = $ent.FullName
    $sigPath = "$abs.sig"
    # Back up a real .sig (if present) before this gate starts overwriting
    # it with missing/garbage variants for Cases A-C, and restore it at
    # the end (below) instead of leaving it permanently deleted -- a
    # destructive Remove-Item with no restore here previously orphaned
    # any real signature for every later run against the same staged
    # enterprise library, silently forcing gates 24/25 down the
    # "unsigned, loading unverified" path instead of ever exercising the
    # real one.
    $sigBackup = $null
    if (Test-Path $sigPath) {
        $sigBackup = "$sigPath.gate26-orig"
        Copy-Item -Path $sigPath -Destination $sigBackup -Force
    }
    Remove-Item -Path $sigPath -ErrorAction SilentlyContinue

    if (-not (PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$abs'" -Want $abs)) {
        Fail "26 enterprise-signature: could not apply fractalsql.enterprise_lib"
        return
    }

    # ---- Case A: no .sig, require=off (default) -- soft: WARNING logged,
    # library still loads and works.
    [void](PgSetGuc -Name 'fractalsql.enterprise_require_signature' -SetVal 'off' -Want 'off')
    $ra = Psql -Sql "SELECT fractal_ledger_reset_hard();"
    if ($ra -match 'no signature found for enterprise library' -and $ra -notmatch 'enterprise tier not loaded') {
        Pass "26 enterprise-signature Case A: missing .sig + require=off -- WARNS but still loads"
    } else {
        Fail "26 enterprise-signature Case A: expected a WARN-and-load, got: $ra"
    }

    # ---- Case B: no .sig, require=on -- hard: refused.
    [void](PgSetGuc -Name 'fractalsql.enterprise_require_signature' -SetVal 'on' -Want 'on')
    $rb = Psql -Sql "SELECT fractal_ledger_reset_hard();"
    if ($rb -match 'no signature found for enterprise library' -and $rb -match 'enterprise tier not loaded') {
        Pass "26 enterprise-signature Case B: missing .sig + require=on -- refused"
    } else {
        Fail "26 enterprise-signature Case B: expected a hard refusal, got: $rb"
    }

    # ---- Case C: invalid/garbage .sig (64 random bytes, matches no key)
    # -- always refused, even with require=off.
    [void](PgSetGuc -Name 'fractalsql.enterprise_require_signature' -SetVal 'off' -Want 'off')
    $rnd = New-Object byte[] 64
    (New-Object System.Random).NextBytes($rnd)
    [System.IO.File]::WriteAllBytes($sigPath, $rnd)
    $rc = Psql -Sql "SELECT fractal_ledger_reset_hard();"
    if ($rc -match 'failed signature verification' -and $rc -match 'enterprise tier not loaded') {
        Pass "26 enterprise-signature Case C: invalid .sig -- always refused regardless of require setting"
    } else {
        Fail "26 enterprise-signature Case C: expected a hard refusal on invalid signature, got: $rc"
    }
    # Restore the real .sig this gate started with, rather than leaving
    # Case C's garbage bytes (or nothing) in place for whatever runs next.
    if ($sigBackup) {
        Move-Item -Path $sigBackup -Destination $sigPath -Force
    } else {
        Remove-Item -Path $sigPath -ErrorAction SilentlyContinue
    }

    # Reset the GUCs so they do not leak into later gates on a reused cluster.
    [void](PgSetGuc -Name 'fractalsql.enterprise_require_signature' -SetVal 'off' -Want 'off')
    [void](Psql -Sql "ALTER SYSTEM RESET fractalsql.enterprise_lib;")
    [void](Psql -Sql "SELECT pg_reload_conf();")
}

# Reasoning-effort (THINK) GUC passthrough -- mirrors build_test.sh's
# gate 27. Each Psql call below is a fresh backend process (matches
# build_test.sh's own reasoning behind this), so ensure_reason_ctx()/
# ensure_embed_ctx()'s per-backend g_*_loaded statics start false and
# actually re-apply the current GUC values each time.
function Gate27Think {
    if (-not (PgSwapPlugin $Think)) { Fail "27 think: plugin swap did not take effect"; return }

    # Case A: all four unset -- byte-identical to pre-v1.4.0 behavior.
    if (-not (PgSetGuc -Name 'fractalsql.http_think' -SetVal "''" -Want '')) { Fail "27 think: reset http_think"; PgSwapPlugin $Mock | Out-Null; return }
    if (-not (PgSetGuc -Name 'fractalsql.http_think_provider' -SetVal "''" -Want '')) { Fail "27 think: reset http_think_provider"; PgSwapPlugin $Mock | Out-Null; return }
    if (-not (PgSetGuc -Name 'fractalsql.http_native_url' -SetVal "''" -Want '')) { Fail "27 think: reset http_native_url"; PgSwapPlugin $Mock | Out-Null; return }
    if (-not (PgSetGuc -Name 'fractalsql.http_num_ctx' -SetVal '0' -Want '0')) { Fail "27 think: reset http_num_ctx"; PgSwapPlugin $Mock | Out-Null; return }
    Remove-Item -Force $ThinkDumpFile -ErrorAction SilentlyContinue
    Psql -Sql "SELECT fractal_reason('q');" | Out-Null
    $a = Get-Content -Path $ThinkDumpFile -Raw -ErrorAction SilentlyContinue
    if ($a -and $a -match 'THINK=\(unset\)' -and $a -match 'THINK_PROVIDER=\(unset\)' `
              -and $a -match 'NATIVE_URL=\(unset\)' -and $a -match 'NUM_CTX=\(unset\)') {
        Pass "27 think Case A: all four GUCs unset -> no THINK-related env var reaches the plugin"
    } else {
        Fail "27 think Case A: expected all four (unset), got: $a"
    }

    # Case B: set all four -- each reaches the plugin's environment via
    # fractal_reason() (ensure_reason_ctx()'s apply_think_env()).
    if (-not (PgSetGuc -Name 'fractalsql.http_think' -SetVal "'medium'" -Want 'medium')) { Fail "27 think: set http_think"; PgSwapPlugin $Mock | Out-Null; return }
    if (-not (PgSetGuc -Name 'fractalsql.http_think_provider' -SetVal "'ollama'" -Want 'ollama')) { Fail "27 think: set http_think_provider"; PgSwapPlugin $Mock | Out-Null; return }
    if (-not (PgSetGuc -Name 'fractalsql.http_native_url' -SetVal "'http://127.0.0.1:9/native'" -Want 'http://127.0.0.1:9/native')) { Fail "27 think: set http_native_url"; PgSwapPlugin $Mock | Out-Null; return }
    if (-not (PgSetGuc -Name 'fractalsql.http_num_ctx' -SetVal '8192' -Want '8192')) { Fail "27 think: set http_num_ctx"; PgSwapPlugin $Mock | Out-Null; return }
    Remove-Item -Force $ThinkDumpFile -ErrorAction SilentlyContinue
    Psql -Sql "SELECT fractal_reason('q');" | Out-Null
    $b = Get-Content -Path $ThinkDumpFile -Raw -ErrorAction SilentlyContinue
    if ($b -and $b -match 'THINK=medium' -and $b -match 'THINK_PROVIDER=ollama' `
              -and $b -match 'NATIVE_URL=http://127\.0\.0\.1:9/native' -and $b -match 'NUM_CTX=8192') {
        Pass "27 think Case B: all four GUCs reach the plugin via fractal_reason()"
    } else {
        Fail "27 think Case B: expected THINK=medium/THINK_PROVIDER=ollama/NATIVE_URL=http://127.0.0.1:9/native/NUM_CTX=8192, got: $b"
    }

    # Case C: fractal_text_to_sql()'s GENERATE step forwards the same
    # four (apply_think_env() is shared with ensure_text_to_sql_ctx()) --
    # the mock's canned "OK" response isn't a fenced SQL block, so this
    # call is expected to error; only the dump file (written before that
    # error, at format_prompt() time) is under test here.
    Remove-Item -Force $ThinkDumpFile -ErrorAction SilentlyContinue
    Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers']);" | Out-Null
    $c = Get-Content -Path $ThinkDumpFile -Raw -ErrorAction SilentlyContinue
    if ($c -and $c -match 'THINK=medium' -and $c -match 'THINK_PROVIDER=ollama') {
        Pass "27 think Case C: fractal_text_to_sql()'s GENERATE step also forwards THINK/THINK_PROVIDER"
    } else {
        Fail "27 think Case C: expected THINK=medium/THINK_PROVIDER=ollama from the GENERATE step, got: $c"
    }

    # Case D: fractal_embed() never sees THINK vars even with the GUCs
    # still set from Case B/C -- proves ensure_embed_ctx()'s explicit
    # unsetenv() calls, not just "embed happens not to set them".
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings')) {
        Fail "27 think Case D: http_embed_url GUC did not take effect"; PgSwapPlugin $Mock | Out-Null; return
    }
    Remove-Item -Force $ThinkDumpFile -ErrorAction SilentlyContinue
    Psql -Sql "SELECT fractal_embed('test input');" | Out-Null
    $d = Get-Content -Path $ThinkDumpFile -Raw -ErrorAction SilentlyContinue
    if ($d -and $d -match 'THINK=\(unset\)' -and $d -match 'THINK_PROVIDER=\(unset\)' `
              -and $d -match 'NATIVE_URL=\(unset\)' -and $d -match 'NUM_CTX=\(unset\)') {
        Pass "27 think Case D: fractal_embed() never sees THINK vars, even with the GUCs still set"
    } else {
        Fail "27 think Case D: expected all four (unset) in the embed tier, got: $d"
    }

    # Reset the GUCs so they do not leak into later gates on a reused cluster.
    [void](PgSetGuc -Name 'fractalsql.http_think' -SetVal "''" -Want '')
    [void](PgSetGuc -Name 'fractalsql.http_think_provider' -SetVal "''" -Want '')
    [void](PgSetGuc -Name 'fractalsql.http_native_url' -SetVal "''" -Want '')
    [void](PgSetGuc -Name 'fractalsql.http_num_ctx' -SetVal '0' -Want '0')
    PgSwapPlugin $Mock | Out-Null
    Remove-Item -Force $ThinkDumpFile -ErrorAction SilentlyContinue
}

# Regression test for ensure_review_ctx()/g_review_ctx: fractal_text_to_
# sql()'s REVIEW step must never see an operator-set
# FSQL_REASONING_HTTP_RESPONSE_MODE, even though REVIEW is "just a
# second fractal_reason()-shaped call" sharing the same URL/token/model
# config. Before this fix REVIEW shared g_reason_ctx directly, so an
# operator setting RESPONSE_MODE=json (say) for their own
# fractal_reason() calls would silently break t2s_run_review()'s
# hardcoded leading-PASS/FAIL text parsing too.
#
# Unlike THINK (gate 27), RESPONSE_MODE has no GUC -- it's captured
# from the raw process environment exactly once, at postmaster startup
# (_PG_init's g_response_mode_boot), so exercising it needs a real
# pg_ctl restart with the var exported into the postmaster's own
# environment, not just an ALTER SYSTEM + reload. Restores the
# un-restarted baseline afterward so later gates on this same reused
# cluster see a clean postmaster environment again.
function Gate28ReviewIsolation {
    function RestartPgForGate28 {
        # A PowerShell retry-loop with a bounded iteration count is only
        # actually bounded in wall-clock time if every call inside it is
        # itself bounded. It isn't here by default: pg_ctl.exe's own
        # Windows-side signaling (CallNamedPipe, pidfile polling -- see
        # the well-documented upstream bugs around "pg_ctl stop fails on
        # Windows") can block indefinitely on a single invocation, and
        # the shared Psql() helper's $proc.WaitForExit() has no timeout
        # at all. Confirmed the hard way: a version of this function
        # already wrapped in bounded retry loops still hung 10+ minutes,
        # because one single iteration's underlying process call never
        # returned control -- the loop never got to advance.
        #
        # Fix: every external process invocation below uses the .NET
        # Process API directly with an explicit WaitForExit(ms) + Kill()
        # fallback, so each individual call has a real, enforced
        # wall-clock cap -- not just a retry count around an unbounded
        # primitive. -w is not used anywhere here for the same reason:
        # its internal Windows readiness/completion signal is exactly
        # the unreliable piece these timeouts are working around.
        function RunPgCtlWithTimeout([string[]]$PgCtlArgs, [int]$TimeoutMs) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "$Bin\pg_ctl.exe"
            foreach ($a in (@('-D', $DataDir) + $PgCtlArgs)) { $psi.ArgumentList.Add($a) }
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            if (-not $proc.WaitForExit($TimeoutMs)) {
                try { $proc.Kill($true) } catch { Write-Verbose "best-effort: process tree kill failed (process may have already exited): $($_.Exception.Message)" }
                return $false
            }
            return ($proc.ExitCode -eq 0)
        }

        function PsqlPingWithTimeout([int]$TimeoutMs) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "$Bin\psql.exe"
            foreach ($a in @('-h','127.0.0.1','-p',"$Port",'-U','postgres','-d','postgres','-X','-tA','-c','SELECT 1;')) {
                $psi.ArgumentList.Add($a)
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $null = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutMs)) {
                try { $proc.Kill($true) } catch { Write-Verbose "best-effort: process tree kill failed (process may have already exited): $($_.Exception.Message)" }
                return $false
            }
            return ($outTask.Result.Trim() -eq '1')
        }

        # -m fast stop: 15s hard cap. Best-effort -- a timed-out stop
        # here just means the pidfile-wait loop below (which checks
        # reality directly via Test-Path, not another process call) has
        # to do the actual work of confirming the old server is gone.
        [void](RunPgCtlWithTimeout @('-m', 'fast', 'stop') 15000)

        $pidFile = Join-Path $DataDir 'postmaster.pid'
        for ($i = 0; $i -lt (40 * $TimeoutMult) -and (Test-Path $pidFile); $i++) {
            Start-Sleep -Milliseconds 250
        }

        if (-not (RunPgCtlWithTimeout @('-l', (Join-Path $DataDir 'log'), 'start') 15000)) { return $false }

        for ($i = 0; $i -lt (30 * $TimeoutMult); $i++) {
            if (PsqlPingWithTimeout 1000) { return $true }
            Start-Sleep -Milliseconds 500
        }
        return $false
    }

    # Progress markers, not just Pass/Fail at the end -- a hang inside
    # any one of these steps (pg_ctl restart, or a Psql() call, which
    # has no timeout of its own -- see Psql's own header comment) would
    # otherwise look identical to the whole gate being silently stuck,
    # with no way to tell which step it's actually in. Confirmed the
    # hard way: a real run sat with zero output for 10+ minutes here and
    # there was no way to tell whether it was the restart, the positive-
    # control query, or the REVIEW-path query without adding these.
    Write-Information "[build_test] gate 28: swapping to mock plugin..." -InformationAction Continue
    if (-not (PgSwapPlugin $Mock)) { Fail "28 review_isolation: plugin swap did not take effect"; return }

    Write-Information "[build_test] gate 28: restarting cluster with RESPONSE_MODE=json..." -InformationAction Continue
    $env:FSQL_REASONING_HTTP_RESPONSE_MODE = 'json'
    if (-not (RestartPgForGate28)) {
        Warn "28 review_isolation: could not restart cluster with FSQL_REASONING_HTTP_RESPONSE_MODE=json set (env restart flake, not a code regression -- skipping this gate's assertions)"
        Remove-Item Env:\FSQL_REASONING_HTTP_RESPONSE_MODE -ErrorAction SilentlyContinue
        RestartPgForGate28 | Out-Null
        return
    }

    # Positive control: fractal_reason()'s own tier DOES see the boot-
    # captured value -- proves the env var actually reached the
    # postmaster (and that g_response_mode_boot's capture/re-apply
    # mechanism works) before trusting REVIEW's negative result below.
    Write-Information "[build_test] gate 28: positive control -- fractal_reason('q')..." -InformationAction Continue
    Remove-Item -Force $ReviewEnvDumpFile -ErrorAction SilentlyContinue
    Psql -Sql "SELECT fractal_reason('q');" | Out-Null
    Write-Information "[build_test] gate 28: positive control query returned" -InformationAction Continue
    $ra = Get-Content -Path $ReviewEnvDumpFile -Raw -ErrorAction SilentlyContinue
    if ($ra -and $ra -match 'RESPONSE_MODE=json') {
        Pass "28 review_isolation: positive control -- fractal_reason() sees the boot-captured RESPONSE_MODE=json"
    } else {
        Fail "28 review_isolation: positive control failed, expected RESPONSE_MODE=json from fractal_reason(), got: $ra"
    }

    # The actual regression check: REVIEW must NOT see it, regardless.
    # REVIEW runs after GENERATE within one fractal_text_to_sql() call,
    # so the dump file's content once the whole call returns/errors
    # reflects REVIEW's own env (see mock_reasoning_plugin_win.c's
    # header).
    Write-Information "[build_test] gate 28: enabling text_to_sql_use_review..." -InformationAction Continue
    if (-not (PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'on' -Want 'on')) {
        Fail "28 review_isolation: could not enable text_to_sql_use_review"
    } else {
        Set-Content -Path $SqlFile -Value 'SELECT 1' -NoNewline
        Remove-Item -Force $ReviewEnvDumpFile -ErrorAction SilentlyContinue
        Write-Information "[build_test] gate 28: REVIEW-path query -- fractal_text_to_sql('q', ...)..." -InformationAction Continue
        Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" | Out-Null
        Write-Information "[build_test] gate 28: REVIEW-path query returned" -InformationAction Continue
        $rb = Get-Content -Path $ReviewEnvDumpFile -Raw -ErrorAction SilentlyContinue
        if ($rb -and $rb -match 'RESPONSE_MODE=\(unset\)') {
            Pass "28 review_isolation: REVIEW step never sees the boot-captured RESPONSE_MODE, even though fractal_reason() does"
        } else {
            Fail "28 review_isolation: expected RESPONSE_MODE=(unset) from the REVIEW dispatch, got: $rb"
        }
        PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal 'off' -Want 'off' | Out-Null
    }

    # Restore: stop, drop the env var, restart -- so later gates on this
    # same reused cluster see a clean postmaster environment again.
    Write-Information "[build_test] gate 28: restoring baseline (dropping RESPONSE_MODE, restarting)..." -InformationAction Continue
    Remove-Item Env:\FSQL_REASONING_HTTP_RESPONSE_MODE -ErrorAction SilentlyContinue
    if (-not (RestartPgForGate28)) { Warn "28 review_isolation: could not restart cluster to restore the clean baseline environment (env restart flake -- gate 28 is last, nothing downstream depends on it)" }
    PgSwapPlugin $Mock | Out-Null
    Remove-Item -Force $ReviewEnvDumpFile -ErrorAction SilentlyContinue
}

# All 17 fractal_vector_* functions (sql/fractalsql--1.0.sql): the
# native vector type's arithmetic/distance/quantization family,
# known-answer asserted. Mirrors build_test.sh's gate_29_vector_ops.
function Gate29VectorOps {
    $r = Psql -Sql "SELECT fractal_vector_cosine_similarity('[1,0,0]'::fractal_vector, '[1,0,0]'::fractal_vector);"
    if ($r -eq '1') { Pass "29 vector_ops: cosine_similarity(identical)=1" } else { Fail "29 vector_ops: cosine_similarity='$r'" }

    $r = Psql -Sql "SELECT fractal_vector_norm('[3,4,0]'::fractal_vector);"
    if ($r -eq '5') { Pass "29 vector_ops: norm([3,4,0])=5" } else { Fail "29 vector_ops: norm='$r'" }

    $r = Psql -Sql "SELECT fractal_vector_add('[1,2,3]'::fractal_vector, '[1,1,1]'::fractal_vector);"
    if ($r -eq '[2,3,4]') { Pass "29 vector_ops: add([1,2,3],[1,1,1])=[2,3,4]" } else { Fail "29 vector_ops: add='$r'" }

    $r = Psql -Sql "SELECT fractal_vector_sub('[3,4,5]'::fractal_vector, '[1,1,1]'::fractal_vector);"
    if ($r -eq '[2,3,4]') { Pass "29 vector_ops: sub([3,4,5],[1,1,1])=[2,3,4]" } else { Fail "29 vector_ops: sub='$r'" }

    $r = Psql -Sql "SELECT fractal_vector_dims('[1,2,3,4]'::fractal_vector);"
    if ($r -eq '4') { Pass "29 vector_ops: dims([1,2,3,4])=4" } else { Fail "29 vector_ops: dims='$r'" }

    # float32 storage, not exact decimal: 0.6/0.8 round-trip through
    # fractal_vector's actual float32 precision as
    # 0.600000024/0.800000012 (fractal_vector_out's "%.9g", confirmed in
    # src\fractalsql_vector.c).
    $r = Psql -Sql "SELECT fractal_vector_normalize('[3,4,0]'::fractal_vector);"
    if ($r -eq '[0.600000024,0.800000012,0]') { Pass "29 vector_ops: normalize([3,4,0]) -> unit vector [0.6,0.8,0]" } else { Fail "29 vector_ops: normalize='$r'" }
    $r = Psql -Sql "SELECT fractal_vector_normalize(NULL);"
    if ($r -eq '') { Pass "29 vector_ops: normalize(NULL) -> NULL (STRICT)" } else { Fail "29 vector_ops: expected NULL, got: $r" }

    $r = Psql -Sql "SELECT fractal_vector_scale('[1,2,3]'::fractal_vector, 2);"
    if ($r -eq '[2,4,6]') { Pass "29 vector_ops: scale([1,2,3],2)=[2,4,6]" } else { Fail "29 vector_ops: scale='$r'" }
    $r = Psql -Sql "SELECT fractal_vector_scale(NULL, 2);"
    if ($r -eq '') { Pass "29 vector_ops: scale(NULL,...) -> NULL (STRICT)" } else { Fail "29 vector_ops: expected NULL, got: $r" }

    $r = Psql -Sql "SELECT fractal_vector_negative_inner_product('[1,0,0]'::fractal_vector, '[1,0,0]'::fractal_vector);"
    if ($r -eq '-1') { Pass "29 vector_ops: negative_inner_product(identical unit vectors)=-1" } else { Fail "29 vector_ops: negative_inner_product='$r'" }
    $r = Psql -Sql "SELECT fractal_vector_negative_inner_product(NULL, '[1,0,0]'::fractal_vector);"
    if ($r -eq '') { Pass "29 vector_ops: negative_inner_product(NULL,...) -> NULL (STRICT)" } else { Fail "29 vector_ops: expected NULL, got: $r" }

    $r = Psql -Sql "SELECT fractal_vector_l2_distance('[0,0,0]'::fractal_vector, '[3,4,0]'::fractal_vector);"
    if ($r -eq '5') { Pass "29 vector_ops: l2_distance([0,0,0],[3,4,0])=5" } else { Fail "29 vector_ops: l2_distance='$r'" }

    $r = Psql -Sql "SELECT fractal_vector_l2_squared('[3,4,0]'::fractal_vector, '[0,0,0]'::fractal_vector);"
    if ($r -eq '25') { Pass "29 vector_ops: l2_squared([3,4,0],[0,0,0])=25 (skips the sqrt in l2_distance)" } else { Fail "29 vector_ops: l2_squared='$r'" }

    $r = Psql -Sql "SELECT fractal_vector_cosine_distance('[1,0,0]'::fractal_vector, '[1,0,0]'::fractal_vector);"
    if ($r -eq '0') { Pass "29 vector_ops: cosine_distance(identical)=0" } else { Fail "29 vector_ops: cosine_distance='$r'" }
    $r = Psql -Sql "SELECT fractal_vector_cosine_distance(NULL, '[1,0,0]'::fractal_vector);"
    if ($r -eq '') { Pass "29 vector_ops: cosine_distance(NULL,...) -> NULL (STRICT)" } else { Fail "29 vector_ops: expected NULL, got: $r" }

    $r = Psql -Sql "SELECT fractal_vector_from_float8_array(ARRAY[1,2,3]::float8[]);"
    if ($r -eq '[1,2,3]') { Pass "29 vector_ops: from_float8_array canonicalizes [1,2,3]" } else { Fail "29 vector_ops: from_float8_array='$r'" }
    $r = Psql -Sql "SELECT fractal_vector_to_float8_array('[1,2,3]'::fractal_vector);"
    if ($r -eq '{1,2,3}') { Pass "29 vector_ops: to_float8_array canonicalizes to {1,2,3} (native array text, not fractal_vector's own [1,2,3] form)" } else { Fail "29 vector_ops: to_float8_array='$r'" }

    # --- v2.0.20: Lp distance, quantization, Hamming distance -----------
    $r = Psql -Sql "SELECT fractal_vector_lp_distance('[3,4,0]'::fractal_vector, '[0,0,0]'::fractal_vector, 2.0);"
    if ($r -eq '5') { Pass "29 vector_ops: lp_distance p=2 ([3,4] from origin) = 5" } else { Fail "29 vector_ops: lp_distance p=2='$r'" }
    $r = Psql -Sql "SELECT fractal_vector_lp_distance('[3,4,0]'::fractal_vector, '[0,0,0]'::fractal_vector, 1.0);"
    if ($r -eq '7') { Pass "29 vector_ops: lp_distance p=1 ([3,4] from origin) = 7" } else { Fail "29 vector_ops: lp_distance p=1='$r'" }
    $r = Psql -Sql "SELECT fractal_vector_lp_distance('[3,4,0]'::fractal_vector, '[0,0,0]'::fractal_vector, 0);"
    if ($r -match 'p must be > 0') { Pass "29 vector_ops: lp_distance rejects p<=0" } else { Fail "29 vector_ops: expected a p<=0 rejection, got: $r" }

    # quantize_int8: dim raw signed bytes (hex bytea text "\xHHHH..."),
    # dequantization v[i] ~= codes[i]*scale within half a quantization step.
    $q8 = Psql -Sql "SELECT codes, scale FROM fractal_vector_quantize_int8('[1,-2,3]'::fractal_vector);"
    $q8Parts = $q8 -split '\|'
    $q8Codes = $q8Parts[0]
    $q8Scale = [double]$q8Parts[1]
    $hex = $q8Codes -replace '^\\x', ''
    $q8Ok = $false
    if ($hex.Length -eq 6 -and $q8Scale -gt 0) {
        $q = @()
        for ($i = 0; $i -lt 3; $i++) {
            $b = [Convert]::ToInt32($hex.Substring($i * 2, 2), 16)
            if ($b -ge 128) { $b -= 256 }
            $q += $b
        }
        $tol = $q8Scale * 0.6
        if ([Math]::Abs($q[0] * $q8Scale - 1) -le $tol -and
            [Math]::Abs($q[1] * $q8Scale + 2) -le $tol -and
            [Math]::Abs($q[2] * $q8Scale - 3) -le $tol) { $q8Ok = $true }
    }
    if ($q8Ok) { Pass "29 vector_ops: quantize_int8 dequantizes [1,-2,3] within rounding error (codes=$q8Codes scale=$q8Scale)" }
    else { Fail "29 vector_ops: quantize_int8 codes='$q8Codes' scale='$q8Scale' (dequantization out of tolerance)" }

    # quantize_binary + hamming_distance: 2 dims pack into 1 byte;
    # identical vectors -> 0; one flipped sign -> 1. (The sign-bit
    # polarity itself is the vendored core's choice -- these assertions
    # hold either way.)
    $qb = Psql -Sql "SELECT octet_length(fractal_vector_quantize_binary('[1,-1]'::fractal_vector));"
    if ($qb -eq '1') { Pass "29 vector_ops: quantize_binary 2 dims -> 1 packed byte" } else { Fail "29 vector_ops: quantize_binary byte count=$qb" }
    $hm0 = Psql -Sql "SELECT fractal_vector_hamming_distance(fractal_vector_quantize_binary('[1,-1]'::fractal_vector), fractal_vector_quantize_binary('[1,-1]'::fractal_vector));"
    if ($hm0 -eq '0') { Pass "29 vector_ops: hamming_distance(identical)=0" } else { Fail "29 vector_ops: hamming_distance(identical)='$hm0'" }
    $hm1 = Psql -Sql "SELECT fractal_vector_hamming_distance(fractal_vector_quantize_binary('[1,-1]'::fractal_vector), fractal_vector_quantize_binary('[1,1]'::fractal_vector));"
    if ($hm1 -eq '1') { Pass "29 vector_ops: hamming_distance(one flipped sign)=1" } else { Fail "29 vector_ops: hamming_distance(flipped sign)='$hm1'" }
    $hmBad = Psql -Sql "SELECT fractal_vector_hamming_distance('\x01'::bytea, '\x0102'::bytea);"
    if ($hmBad -match 'length mismatch') { Pass "29 vector_ops: hamming_distance rejects unequal byte lengths" } else { Fail "29 vector_ops: expected a length-mismatch rejection, got: $hmBad" }
}

# The 6 newest analytics/vector-math primitives (v2.0.20), known-answer
# asserted: real float8[]/bytea[] array args, with fractal_periodogram
# and fractal_cycle_detect set-returning (TABLE). Mirrors build_test.sh's
# gate_30_new_primitives.
# Gate 48: the twenty-nine newer industry kits (demo/demo-vertical-*.sql).
# Each kit is fed to psql against the scratch cluster (fractalsql_agents
# installed, the mock reasoning plugin answering the reasoned steps) and
# must (a) exist, (b) raise no SQL error beyond the documented exception
# (the scenario-planning kit's plan_explore call needs an embedding
# endpoint: at most one error), (c) print no NaN, and (d) reproduce its
# headline result -- the fixtures are deterministic (no random()), so the
# claim is checked against fixed numbers.
function KitNum { param([string]$S)
    $d = 0.0
    if ([double]::TryParse($S, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return [double]::NaN
}

# KitShape: the older kits print no HEADLINE line and seed random(), so only the SHAPE of their output is
# pinned: the count of lines that are neither psql noise nor command tags. A step that silently returns
# no rows drops them. Callers require three quarters of what a clean run prints.
function KitShape($lines) {
    return @($lines | Where-Object { $_ -notmatch '^(psql:|NOTICE|HINT|DETAIL|CONTEXT|LINE|DROP |CREATE |INSERT |UPDATE |DELETE |SELECT [0-9]|ALTER |SET$|Timing|Time:|\s*$)' }).Count
}

function Gate48Kits {
    $demoDir = Join-Path $RepoRoot 'demo'
    if (-not (Test-Path -LiteralPath $demoDir)) {
        Skip '48 kits (demo/ not present)'
        return
    }
    if (-not (PgSwapPlugin $Mock)) { Fail '48 kits: plugin swap did not take effect'; return }
    $kits = @('ev-battery-lifecycle', 'adas-safety-validation', 'v2x-warranty-triage',
              'critical-inventory-routing', 'heavy-industry-predictive-maintenance',
              'climatech-grid-balancing', 'hazmat-occupational-triage',
              'scenario-planning-simulation', 'avionics-fault-prediction',
              'satellite-constellation-coverage', 'telecom-account-anomaly-screening',
              'telecom-traffic-routing', 'climatech-emissions-monitoring',
              'climatech-risk-exposure', 'rf-spectrum-sensing',
              'event-stream-anomaly-triage', 'outlier-interception-footprint',
              'agentic-budget-reallocation', 'stalled-process-triage',
              'intent-matching-discovery', 'agentic-next-action-ranking',
              'document-risk-drift', 'coordinated-record-detection',
              'sensor-telemetry-allocation', 'simulated-economy-drift',
              'multi-series-replenishment', 'periodicity-portfolio-selection',
              'agentic-recall-recommendation', 'spatial-footprint-portfolio-risk',
              'agentic-customer-support', 'agentic-edge-swarm',
              'agentic-fintech-mcts', 'agentic-ops-devops',
              'biotech-genomics', 'cybersecurity-threat-detection',
              'fleet-logistics', 'maritime-defense', 'medtech-clinical',
              'quant-finance', 'recommendation-search', 'smart-cities-iot',
              'sovereign-edge-ai')
    foreach ($k in $kits) {
        $kit = Join-Path $demoDir "demo-vertical-$k.sql"
        if (-not (Test-Path -LiteralPath $kit)) { Fail "48 kits: demo-vertical-$k.sql is missing"; continue }
        $out = Psql -Sql ([IO.File]::ReadAllText($kit))
        $lines = @($out -split "`r?`n")
        $nerr = @($lines | Where-Object { $_ -match 'ERROR:' }).Count
        $maxerr = 0
        if ($k -eq 'scenario-planning-simulation') { $maxerr = 1 }
        if ($k -eq 'periodicity-portfolio-selection') { $maxerr = 1 }
        if ($k -eq 'agentic-fintech-mcts') { $maxerr = 1 }
        if ($k -eq 'agentic-ops-devops') { $maxerr = 2 }
        if ($nerr -gt $maxerr) {
            $first = (@($lines | Where-Object { $_ -match 'ERROR:' }) | Select-Object -First 2) -join ' '
            Fail "48 kits: $k raised $nerr SQL error(s), at most ${maxerr} expected: $first"
            continue
        }
        if (@($lines | Where-Object { $_ -match '(^|\|)-?(nan|NaN|inf|Infinity)(\||$)' }).Count -gt 0) { Fail "48 kits: $k printed a NaN/inf cell"; continue }
        $rows = @($lines | ForEach-Object { ,($_ -split '\|') })
        $ok = $false
        switch ($k) {
            { $_ -in @('event-stream-anomaly-triage', 'outlier-interception-footprint', 'agentic-budget-reallocation', 'stalled-process-triage', 'intent-matching-discovery', 'agentic-next-action-ranking', 'document-risk-drift', 'coordinated-record-detection', 'sensor-telemetry-allocation', 'simulated-economy-drift', 'multi-series-replenishment', 'periodicity-portfolio-selection', 'agentic-recall-recommendation', 'spatial-footprint-portfolio-risk') } {
                $ok = [bool]($out -match ("HEADLINE kit=" + $k + " ok")) }
            'agentic-customer-support' { $ok = (KitShape $lines) -ge 11 }
            'agentic-edge-swarm' { $ok = (KitShape $lines) -ge 22 }
            'agentic-fintech-mcts' { $ok = (KitShape $lines) -ge 3 }
            'agentic-ops-devops' { $ok = (KitShape $lines) -ge 6 }
            'biotech-genomics' { $ok = (KitShape $lines) -ge 12 }
            'cybersecurity-threat-detection' { $ok = (KitShape $lines) -ge 25 }
            'fleet-logistics' { $ok = (KitShape $lines) -ge 19 }
            'maritime-defense' { $ok = (KitShape $lines) -ge 22 }
            'medtech-clinical' { $ok = (KitShape $lines) -ge 18 }
            'quant-finance' { $ok = (KitShape $lines) -ge 15 }
            'recommendation-search' { $ok = (KitShape $lines) -ge 24 }
            'smart-cities-iot' { $ok = (KitShape $lines) -ge 18 }
            'sovereign-edge-ai' { $ok = (KitShape $lines) -ge 21 }
            'ev-battery-lifecycle' {
                $a = @($rows | Where-Object { $_[0] -eq 'EV-203' -and $_.Count -eq 4 -and (KitNum $_[1]) -gt 0.5 -and (KitNum $_[2]) -gt 1.5 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'EV-101' -and $_.Count -eq 4 -and (KitNum $_[1]) -lt 0 -and (KitNum $_[2]) -lt 1 }).Count -gt 0
                $ok = $a -and $b }
            'adas-safety-validation' {
                $a = @($rows | Where-Object { $_[0] -like 'P1 firm*' -and $_.Count -eq 4 -and $_[3] -eq 't' }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -like 'P2 steady*' -and $_.Count -eq 4 -and $_[3] -eq 'f' }).Count -gt 0
                $c = @($rows | Where-Object { $_[0] -like 'P3 gentle*' -and $_.Count -eq 4 -and $_[3] -eq 't' }).Count -gt 0
                $ok = $a -and $b -and $c }
            'v2x-warranty-triage' { $ok = $out -match '(?m)^battery-thermal-service\|0\.99' }
            'critical-inventory-routing' {
                $ok = @($rows | Where-Object { $_[0] -eq '4' -and $_.Count -ge 5 -and $_[1] -eq 'west' -and (KitNum $_[4]) -gt 1.2 }).Count -gt 0 }
            'heavy-industry-predictive-maintenance' {
                $a = @($rows | Where-Object { $_[0] -eq 'PUMP-07' -and $_.Count -eq 4 -and (KitNum $_[1]) -gt 0.5 -and (KitNum $_[2]) -gt 1.5 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'PUMP-03' -and $_.Count -eq 4 -and (KitNum $_[1]) -lt 0 }).Count -gt 0
                $ok = $a -and $b }
            'climatech-grid-balancing' {
                $a = @($rows | Where-Object { $_[0] -eq 'AREA-C' -and $_.Count -eq 4 -and (KitNum $_[1]) -gt 0.5 -and (KitNum $_[2]) -gt 1.2 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'AREA-A' -and $_.Count -eq 4 -and (KitNum $_[1]) -lt 0 }).Count -gt 0
                $ok = $a -and $b }
            'hazmat-occupational-triage' {
                $n = @($rows | Where-Object { @('7', '15', '31') -contains $_[0] -and $_.Count -eq 4 -and $_[1] -eq 'reactor-bay' -and $_[2] -eq 'night' -and (KitNum $_[3]) -lt 0.001 }).Count
                $ok = $n -ge 3 }
            'scenario-planning-simulation' {
                $ok = @($lines | Where-Object { $_ -match 'variant' }).Count -ge 6 }
            'avionics-fault-prediction' { $ok = $out -match '(?m)^AC-09\|0\.2' }
            'satellite-constellation-coverage' {
                $h = @($rows | Where-Object { $_[0] -eq 'healthy' -and $_.Count -eq 3 } | Select-Object -First 1)
                $d = @($rows | Where-Object { $_[0] -eq 'degraded' -and $_.Count -eq 3 } | Select-Object -First 1)
                $ok = ($h.Count -eq 1) -and ($d.Count -eq 1) -and ((KitNum $h[0][2]) -gt 0) -and ((KitNum $d[0][2]) -gt (KitNum $h[0][2])) }
            'telecom-account-anomaly-screening' {
                $a = @($rows | Where-Object { $_[0] -like 'E1 swap*' -and $_.Count -eq 4 -and $_[3] -eq 't' }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -like 'E2 routine*' -and $_.Count -eq 4 -and $_[3] -eq 'f' }).Count -gt 0
                $c = @($rows | Where-Object { $_[0] -like 'E4 faint*' -and $_.Count -eq 4 -and $_[3] -eq 't' }).Count -gt 0
                $ok = $a -and $b -and $c }
            'telecom-traffic-routing' {
                $ok = ($out -match '(?m)^R3 mobile handover burst\|edge-mobile-hub\|') -and ($out -match '(?m)^R3 mobile handover burst\|edge-backup-west\s*$') }
            'climatech-emissions-monitoring' {
                $a = @($rows | Where-Object { $_[0] -eq 'CH4-02' -and $_.Count -eq 4 -and (KitNum $_[1]) -gt 0.5 -and (KitNum $_[2]) -gt 1.5 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'CH4-01' -and $_.Count -eq 4 -and (KitNum $_[1]) -lt 0 }).Count -gt 0
                $ok = $a -and $b }
            'climatech-risk-exposure' {
                $a = @($rows | Where-Object { $_[0] -eq 'dry season' -and $_.Count -eq 3 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'wet season' -and $_.Count -eq 3 }).Count -gt 0
                $ok = $a -and $b }
            'rf-spectrum-sensing' {
                $ok = ($out -match '(?m)^CH-A\|\{9\}\s*$') -and ($out -match '(?m)^CH-B\|\{\}\s*$') -and ($out -match '(?m)^CH-C\|\{\}\s*$') }
        }
        if ($ok) { Pass "48 kits: demo-vertical-$k.sql runs clean and reproduces its headline result" }
        else { Fail "48 kits: demo-vertical-$k.sql did not reproduce its headline result" }
    }
    # The kits leave their tables behind for inspection; this gate does not.
    $null = Psql -Sql 'DROP TABLE IF EXISTS ebl_telemetry, asv_known_bad, asv_proposed, asv_routes, v2x_capabilities, v2x_claims, cir_depots, cir_consumption, cir_profile, cir_result, hpm_readings, cgb_freq, cgb_resources, cgb_result, hot_workers, sps_scenarios, sps_scout, afp_flights, scc_footprints, scc_slots, taa_known_anomalous, taa_proposed, ttr_nodes, ttr_requests, cem_readings, cre_grid, rfs_capture, rfs_entropy, esa_latency, esa_rate, esa_lprof, esa_rprof, esa_health, esa_traj, oif_known, oif_proposed, oif_screen, oif_screen_l2, oif_clicks, oif_dim, abr_outcome, abr_prof, abr_result, abr_models, abr_events, abr_routed, spt_items, spt_traj, spt_triage, imd_entities, imd_picks, imd_scout, imd_content, imd_rec, anr_candidates, anr_recall, anr_actions, anr_rec, drd_risk, drd_prof, drd_clauses, drd_picks, drd_scout, drd_approved, drd_rec, crd_known, crd_proposed, crd_screen, crd_records, crd_traj, crd_locations, crd_dim, sta_demand, sta_prof, sta_result, sed_price, sed_prof, sed_result, sed_loop, msr_units, msr_prof, msr_result, pps_sales, pps_prof, pps_result, pps_catalog, pps_rec, arr_offers, arr_picks, arr_scout, arr_sessions, arr_recall, sfp_parcels, sfp_dim, sfp_index, sfp_prof, sfp_result, sfp_comps, sfp_picks, sfp_scout CASCADE;'
}

function Gate30NewPrimitives {
    # --- fractal_change_point_detect: step up at t=50 in a 100-sample
    # series with a non-degenerate (sine) wobble, win=16, threshold=2.0.
    # At least one flagged boundary must land near the true split.
    $r = Psql -Sql @"
SELECT fractal_change_point_detect(array_agg(v ORDER BY i), 16, 2.0, 16)
  FROM (SELECT i, CASE WHEN i < 50 THEN 0.2*sin(0.5*i) ELSE 5.2+0.2*cos(0.5*i) END AS v
          FROM generate_series(0, 99) i) s;
"@
    $cpOk = $false
    foreach ($v in (($r -replace '[{}]', '') -split ',')) {
        if ($v -ne '' -and [double]$v -ge 30 -and [double]$v -le 70) { $cpOk = $true }
    }
    if ($cpOk) { Pass "30 new_primitives: change_point_detect flags a boundary near the t=50 step ($r)" }
    else { Fail "30 new_primitives: change_point_detect='$r' (no boundary in [30,70])" }

    $r = Psql -Sql "SELECT fractal_change_point_detect(ARRAY[1,2,3]::float8[], 0, 2.0, 16);"
    if ($r -match 'win must be > 0') { Pass "30 new_primitives: change_point_detect rejects window <= 0" }
    else { Fail "30 new_primitives: expected a win<=0 rejection, got: $r" }

    # --- fractal_periodogram: 64 samples of sin(2*pi*t/8) -> an exact
    # k=8/64 bin at 0.125 cycles/sample as the top-power peak.
    $r = Psql -Sql @"
SELECT freq FROM fractal_periodogram(
  (SELECT array_agg(0.5*sin(2*pi()*i/8.0) ORDER BY i) FROM generate_series(0, 63) i), 4)
ORDER BY power DESC LIMIT 1;
"@
    $freqOk = $false
    if ($r -ne '') { $f = [double]$r; if ($f -gt 0.124 -and $f -lt 0.126) { $freqOk = $true } }
    if ($freqOk) { Pass "30 new_primitives: periodogram top freq is the true 0.125 bin (got $r)" }
    else { Fail "30 new_primitives: periodogram top freq='$r' (expected 0.125)" }

    # --- fractal_state_fingerprint: 128 bits -> exactly 16 packed bytes,
    # byte-for-byte deterministic across identical calls (seeded random
    # hyperplanes).
    $fp1 = Psql -Sql "SELECT fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 128, 42);"
    $nFp = Psql -Sql "SELECT octet_length(fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 128, 42));"
    if ($nFp -eq '16') { Pass "30 new_primitives: state_fingerprint 128 bits -> 16 bytes" } else { Fail "30 new_primitives: state_fingerprint byte count=$nFp" }
    $fp2 = Psql -Sql "SELECT fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 128, 42);"
    if ($fp1 -eq $fp2) { Pass "30 new_primitives: state_fingerprint is deterministic (same seed, same bytes)" }
    else { Fail "30 new_primitives: state_fingerprint differs across identical calls: '$fp1' vs '$fp2'" }
    $r = Psql -Sql "SELECT fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 0, 42);"
    if ($r -match 'n_bits must be > 0') { Pass "30 new_primitives: state_fingerprint rejects n_bits <= 0" }
    else { Fail "30 new_primitives: expected an n_bits<=0 rejection, got: $r" }

    # --- fractal_cycle_detect: fingerprints of A,B,A,B,A,B as a bytea[].
    # Brent's checkpoint schedule needs roughly twice the period in
    # stream length to close, so a bare A,B,A does NOT report a cycle --
    # the 6-element stream does
    # (0-indexed at_index=3, cycle_len=2). Negative case uses A,B,D with
    # mutually non-collinear state vectors: SimHash fingerprints of
    # SCALAR-MULTIPLE states are byte-identical (both '9,9,9' and
    # '4,4,4' sit on the (1,1,1) diagonal), so the negative case needs a
    # different direction, not a different magnitude.
    $r = Psql -Sql @"
SELECT at_index, cycle_len FROM fractal_cycle_detect(
  ARRAY[
    fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64, 7),
    fractal_state_fingerprint(ARRAY[9,9,9]::float8[], 64, 7),
    fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64, 7),
    fractal_state_fingerprint(ARRAY[9,9,9]::float8[], 64, 7),
    fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64, 7),
    fractal_state_fingerprint(ARRAY[9,9,9]::float8[], 64, 7)
  ], 0);
"@
    if ($r -eq '3|2') { Pass "30 new_primitives: cycle_detect closes the A,B,A,B,A,B period-2 stream at_index=3 cycle_len=2" }
    else { Fail "30 new_primitives: cycle_detect(A,B,A,B,A,B)='$r'" }

    $r = Psql -Sql @"
SELECT count(*) FROM fractal_cycle_detect(
  ARRAY[
    fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64, 7),
    fractal_state_fingerprint(ARRAY[9,9,9]::float8[], 64, 7),
    fractal_state_fingerprint(ARRAY[4,5,6]::float8[], 64, 7)
  ], 0);
"@
    if ($r -eq '0') { Pass "30 new_primitives: cycle_detect reports no cycle for three distinct states" }
    else { Fail "30 new_primitives: cycle_detect(A,B,D) row count='$r' (expected 0)" }

    $r = Psql -Sql "SELECT fractal_cycle_detect(ARRAY[fractal_state_fingerprint(ARRAY[1]::float8[], 8, 1)], -1);"
    if ($r -match 'hamming_threshold must be >= 0') { Pass "30 new_primitives: cycle_detect rejects a negative hamming_threshold" }
    else { Fail "30 new_primitives: expected a negative-threshold rejection, got: $r" }

    # --- fractal_tda_persistence_diagram: 12 points in two tight
    # 6-point clusters far apart. Each cluster forms a complete graph
    # under thresh=1.0, so the 1-skeleton cycle rank is 15 edges -
    # 6 vertices + 1 component = 10 per cluster = 20 total; h0_bars is
    # 5 merge bars per cluster = 10. max_dim=0 must leave betti1 NULL.
    $pts = "0.0,0.0, 0.1,0.0, 0.05,0.0866, 0.1,0.0866, 0.02,0.05, 0.08,0.03, 10.0,10.0, 10.1,10.0, 10.05,10.0866, 10.1,10.0866, 10.02,10.05, 10.08,10.03"
    $r = Psql -Sql "SELECT betti1, jsonb_array_length(h0_bars) FROM fractal_tda_persistence_diagram(ARRAY[$pts]::float8[], 2, 1, 1.0, 64);"
    if ($r -eq '20|10') { Pass "30 new_primitives: tda_persistence_diagram two-cluster betti1=20 (2 x (15-6+1)), n_h0_bars=10 (2 x 5 merge bars)" }
    else { Fail "30 new_primitives: tda_persistence_diagram='$r' (expected betti1=20, n_h0_bars=10)" }
    $r = Psql -Sql "SELECT betti1 FROM fractal_tda_persistence_diagram(ARRAY[$pts]::float8[], 2, 0, 1.0, 64);"
    if ($r -eq '') { Pass "30 new_primitives: tda_persistence_diagram max_dim=0 leaves betti1 NULL" }
    else { Fail "30 new_primitives: tda max_dim=0 betti1='$r' (expected NULL)" }

    # --- fractal_optimize_subset: value-weighted allocation with bounds
    # 0.6 per item and at-most-2 nonzero. Weights sum to 1.0, so with
    # k=2 each cap must allow the pair to reach 1.0 (0.6+0.4 works;
    # [0.4]x5 caps the pair at 0.8 < 1.0, infeasible). With feasible
    # [0.6]x5 caps the optimum puts 0.6 on the largest value (0.15) and
    # 0.4 on the second (0.12) -> score exactly 0.138.
    $r = Psql -Sql @"
SELECT (s->>'score')::float8
  FROM (SELECT fractal_optimize_subset(
          ARRAY[0.12,0.09,0.15,0.06,0.11]::float8[],
          ARRAY[0.6,0.6,0.6,0.6,0.6]::float8[], 2) s) t;
"@
    $scoreOk = $false
    if ($r -ne '') { $sc = [double]$r; if ($sc -gt 0.1378 -and $sc -lt 0.1382) { $scoreOk = $true } }
    if ($scoreOk) { Pass "30 new_primitives: optimize_subset hits the exact 0.138 optimum (got $r)" }
    else { Fail "30 new_primitives: optimize_subset score='$r' (expected 0.138)" }

    $osW = Psql -Sql @"
SELECT s->'weights'
  FROM (SELECT fractal_optimize_subset(
          ARRAY[0.12,0.09,0.15,0.06,0.11]::float8[],
          ARRAY[0.6,0.6,0.6,0.6,0.6]::float8[], 2) s) t;
"@
    $osNz = 0
    foreach ($w in (($osW -replace '[\[\]]', '') -split ',')) {
        if ($w -ne '' -and [double]$w -gt 0.0000001) { $osNz++ }
    }
    if ($osNz -le 2) { Pass "30 new_primitives: optimize_subset honors the at-most-2-nonzero cap ($osNz nonzero)" }
    else { Fail "30 new_primitives: optimize_subset nonzero weights=$osNz ('$osW')" }

    $r = Psql -Sql @"
SELECT fractal_optimize_subset(
  ARRAY[0.12,0.09,0.15,0.06,0.11]::float8[],
  ARRAY[0.4,0.4,0.4,0.4,0.4]::float8[], 2);
"@
    if ($r -match 'fractal_optimize_subset rc=') { Pass "30 new_primitives: optimize_subset infeasible instance (caps 0.4x5 < 1.0 at k=2) rejected cleanly" }
    else { Fail "30 new_primitives: infeasible optimize_subset='$r' (expected a clean rc= rejection)" }

    # --- fractal_spectrogram_entropy (core v2.0.26): short-time spectral
    # entropy. Series = 256 samples of a pure tone (period 8) then 256 of
    # deterministic pseudo-noise; win=64, hop=32 -> 15 frames, frames 0-6
    # entirely tone, frames 8-14 entirely noise (frame 7 straddles).
    # Measured against the core directly: tone frames read 0.250, noise
    # frames 0.78-0.92, so the 0.40 / 0.70 cut-offs have wide margins.
    $specSeries = @"
(SELECT array_agg(CASE WHEN i < 256 THEN 0.5*sin(2*pi()*i/8.0)
                       ELSE (x - floor(x)) - 0.5 END ORDER BY i)
   FROM (SELECT i, sin(i::float8 * 12.9898::float8) * 43758.5453::float8 AS x
           FROM generate_series(0, 511) i) q)
"@
    $r = Psql -Sql "SELECT array_length(fractal_spectrogram_entropy($specSeries, 64, 32), 1);"
    if ($r -eq '15') { Pass "30 new_primitives: spectrogram_entropy frame count = floor((512-64)/32)+1 = 15" }
    else { Fail "30 new_primitives: spectrogram_entropy frames='$r' (expected 15)" }

    $r = Psql -Sql @"
WITH h AS (SELECT fractal_spectrogram_entropy($specSeries, 64, 32) e)
SELECT (SELECT avg(x) FROM unnest(e[1:7])  x) < 0.40
   AND (SELECT avg(x) FROM unnest(e[9:15]) x) > 0.70
   AND (SELECT bool_and(x BETWEEN 0 AND 1) FROM unnest(e) x)
  FROM h;
"@
    if ($r -eq 't') { Pass "30 new_primitives: spectrogram_entropy separates a tone (<0.40) from noise (>0.70), all frames in [0,1]" }
    else { Fail "30 new_primitives: spectrogram_entropy tone/noise separation='$r'" }

    # The point of returning float8[]: it composes with change_point_detect.
    # The tone->noise transition is at frame ~7; a boundary must land in [5,11].
    $r = Psql -Sql "SELECT fractal_change_point_detect(fractal_spectrogram_entropy($specSeries, 64, 32), 4, 2.0, 8);"
    $spOk = $false
    foreach ($v in (($r -replace '[{}]', '') -split ',')) {
        if ($v -ne '' -and [double]$v -ge 5 -and [double]$v -le 11) { $spOk = $true }
    }
    if ($spOk) { Pass "30 new_primitives: change_point_detect over spectrogram_entropy flags the tone->noise transition ($r)" }
    else { Fail "30 new_primitives: change_point_detect(spectrogram_entropy)='$r' (no boundary in [5,11])" }

    # A constant signal has no spectral energy: every frame reports exactly
    # 0.0 (never NaN), and max_frames truncates to the first frames.
    $r = Psql -Sql "SELECT bool_and(x = 0.0) AND count(*) = 5 FROM unnest(fractal_spectrogram_entropy(array_fill(3.0::float8, ARRAY[200]), 64, 32)) x;"
    if ($r -eq 't') { Pass "30 new_primitives: spectrogram_entropy of a constant signal is 0.0 in all 5 frames (no NaN)" }
    else { Fail "30 new_primitives: spectrogram_entropy constant='$r'" }

    $r = Psql -Sql "SELECT array_length(fractal_spectrogram_entropy($specSeries, 64, 32, 4), 1);"
    if ($r -eq '4') { Pass "30 new_primitives: spectrogram_entropy max_frames=4 truncates to the first 4 frames" }
    else { Fail "30 new_primitives: spectrogram_entropy max_frames='$r' (expected 4)" }

    # Defaults (win=64, hop=32) match the explicit call.
    $r = Psql -Sql "SELECT fractal_spectrogram_entropy($specSeries) = fractal_spectrogram_entropy($specSeries, 64, 32);"
    if ($r -eq 't') { Pass "30 new_primitives: spectrogram_entropy defaults are win=64, hop=32" }
    else { Fail "30 new_primitives: spectrogram_entropy defaults='$r'" }

    $r = Psql -Sql "SELECT fractal_spectrogram_entropy(ARRAY[1,2,3,4,5,6,7,8,9,10]::float8[], 4, 2);"
    if ($r -match 'win must be in \[8, 512\]') { Pass "30 new_primitives: spectrogram_entropy rejects win < 8" }
    else { Fail "30 new_primitives: expected a win range rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_spectrogram_entropy(array_fill(1.0::float8, ARRAY[64]), 513, 32);"
    if ($r -match 'win must be in \[8, 512\]') { Pass "30 new_primitives: spectrogram_entropy rejects win > 512" }
    else { Fail "30 new_primitives: expected a win range rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_spectrogram_entropy(array_fill(1.0::float8, ARRAY[64]), 16, 0);"
    if ($r -match 'hop must be > 0') { Pass "30 new_primitives: spectrogram_entropy rejects hop <= 0" }
    else { Fail "30 new_primitives: expected a hop rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_spectrogram_entropy(array_fill(1.0::float8, ARRAY[64]), 16, 8, 0);"
    if ($r -match 'max_frames must be in') { Pass "30 new_primitives: spectrogram_entropy rejects max_frames < 1" }
    else { Fail "30 new_primitives: expected a max_frames rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_spectrogram_entropy(array_fill(1.0::float8, ARRAY[10]), 16, 8);"
    if ($r -match 'fractal_spectrogram_entropy rc=') { Pass "30 new_primitives: spectrogram_entropy rejects a series shorter than win (clean rc= error)" }
    else { Fail "30 new_primitives: expected a short-series rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_spectrogram_entropy(array_fill('NaN'::float8, ARRAY[64]), 16, 8);"
    if ($r -match 'fractal_spectrogram_entropy rc=') { Pass "30 new_primitives: spectrogram_entropy rejects a non-finite sample (clean rc= error)" }
    else { Fail "30 new_primitives: expected a NaN rejection, got: $r" }

    $r = Psql -Sql "SELECT fractal_spectrogram_entropy(NULL::float8[], 16, 8);"
    if ([string]::IsNullOrEmpty($r)) { Pass "30 new_primitives: spectrogram_entropy(NULL, ...) -> NULL (STRICT)" }
    else { Fail "30 new_primitives: spectrogram_entropy NULL series='$r' (expected NULL / empty)" }
}

# Enterprise activation/signature-verification wiring, exercised via a
# throwaway, self-signed mock enterprise .dll compiled at test time --
# gives gates 24-26's dlopen/dlsym/signature-verification machinery real
# CI coverage instead of self-skipping. Unlike the other test plugin
# DLLs in BuildTestPlugins (/DFSQL_STATIC + a shared .def file), this
# mock has no matching .def entry, so it's compiled with
# /DFSQL_BUILDING_DLL instead -- FSQL_API then expands to
# __declspec(dllexport) directly, no .def needed.
#
# Not covered here: torn-tail repair and ledger-directory permission
# failures don't apply (the ledger is a real table, not a flat file),
# and there's no persistent in-process state for a reload-time guard to
# race against (each Psql call is a fresh backend). Byte-level tamper
# detection reuses gate 25's UPDATE ... SET blob = set_byte(...) technique.
function Gate31EnterpriseMock {
    # Same bounded-timeout restart technique as Gate28ReviewIsolation's
    # own RestartPgForGate28 (see its header comment for why -w/a plain
    # retry loop around pg_ctl is not safe on Windows) -- a second,
    # independent copy rather than a shared helper, matching this
    # file's existing one-restart-helper-per-gate convention.
    function RunPgCtlWithTimeout31([string[]]$PgCtlArgs, [int]$TimeoutMs) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$Bin\pg_ctl.exe"
        foreach ($a in (@('-D', $DataDir) + $PgCtlArgs)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill($true) } catch { Write-Verbose "best-effort: process tree kill failed (process may have already exited): $($_.Exception.Message)" }
            return $false
        }
        return ($proc.ExitCode -eq 0)
    }
    function PsqlPingWithTimeout31([int]$TimeoutMs) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$Bin\psql.exe"
        foreach ($a in @('-h','127.0.0.1','-p',"$Port",'-U','postgres','-d','postgres','-X','-tA','-c','SELECT 1;')) {
            $psi.ArgumentList.Add($a)
        }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill($true) } catch { Write-Verbose "best-effort: process tree kill failed (process may have already exited): $($_.Exception.Message)" }
            return $false
        }
        return ($outTask.Result.Trim() -eq '1')
    }
    function RestartPgForGate31 {
        [void](RunPgCtlWithTimeout31 @('-m', 'fast', 'stop') 15000)
        $pidFile = Join-Path $DataDir 'postmaster.pid'
        for ($i = 0; $i -lt (40 * $TimeoutMult) -and (Test-Path $pidFile); $i++) { Start-Sleep -Milliseconds 250 }
        if (-not (RunPgCtlWithTimeout31 @('-l', (Join-Path $DataDir 'log'), 'start') 15000)) { return $false }
        for ($i = 0; $i -lt (30 * $TimeoutMult); $i++) {
            if (PsqlPingWithTimeout31 1000) { return $true }
            Start-Sleep -Milliseconds 500
        }
        return $false
    }

    $mockSo = Join-Path $env:TEMP "fractalsql_bt_mock_ent_$PgMajor.dll"
    $badsigSo = "$mockSo.badsig.dll"
    $badsigSig = "$badsigSo.sig"
    $failSentinel = Join-Path $env:TEMP "fractalsql_bt_mock_ent_fail_$PgMajor"
    Remove-Item -Force $mockSo, $badsigSo, $badsigSig, $failSentinel -ErrorAction SilentlyContinue

    $obj = [System.IO.Path]::ChangeExtension($mockSo, '.obj')
    $src = Join-Path $RepoRoot 'tests\mock_enterprise_core.c'
    $inc = Join-Path $RepoRoot 'include'
    # Captured, not | Out-Null'd: this was the first time anyone had
    # compiled this file on Windows at all, and swallowing cl.exe's own
    # output here is exactly what made the first real failure (a POSIX-
    # only <unistd.h> include) silent and undiagnosable from the gate's
    # own FAIL line alone.
    $buildOut = & cl.exe /nologo /MT /LD /DFSQL_BUILDING_DLL "/I$inc" $src "/Fo$obj" "/Fe$mockSo" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $mockSo)) {
        Fail "31 enterprise_mock: mock .dll failed to build"
        Write-Host ($buildOut -join "`n")
        return
    }
    Copy-Item $mockSo $badsigSo -Force
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $randBytes = New-Object byte[] 64
    $rng.GetBytes($randBytes)
    [System.IO.File]::WriteAllBytes($badsigSig, $randBytes)

    $env:FSQL_MOCK_ENT_FAIL = $failSentinel
    if (-not (RestartPgForGate31)) {
        Fail "31 enterprise_mock: could not restart cluster with FSQL_MOCK_ENT_FAIL set"
        Remove-Item Env:\FSQL_MOCK_ENT_FAIL -ErrorAction SilentlyContinue
        Remove-Item -Force $mockSo, $badsigSo, $badsigSig, $failSentinel -ErrorAction SilentlyContinue
        return
    }

    $pre = Psql -Sql "SELECT fractal_ledger_truth_count();"
    if ($pre -match 'enterprise tier not loaded') { Pass "31 enterprise_mock: truth_count refuses cleanly before enterprise_lib is set" }
    else { Fail "31 enterprise_mock: expected 'enterprise tier not loaded', got: $pre" }

    # g_ent_attempted short-circuit (src\fractalsql.c:1049-1051): the
    # dormant dlopen attempt is cached per backend, so the SECOND
    # enterprise call in the SAME session takes the short-circuit return
    # instead of re-reading the GUC and re-attempting. Both statements
    # below run in one backend (one Psql call = one connection; psql -f -
    # executes each statement as its own batch, so it continues past the
    # first ERROR), and both must report the engine's own dormant error,
    # identically, with no crash. Mirrors build_test.sh's gate 31.
    $rsc = Psql -Sql @"
SELECT fractal_ledger_flush();
SELECT fractal_ledger_flush();
"@
    if ($rsc -match 'server closed the connection|could not connect') {
        Fail "31 ent-attempted: backend crashed -- $rsc"
    } elseif (([regex]::Matches($rsc, 'fractalsql: enterprise tier not loaded')).Count -eq 2) {
        Pass "31 ent-attempted: two dormant enterprise calls in ONE backend both report the same dormant error (2nd via the g_ent_attempted short-circuit)"
    } else {
        Fail "31 ent-attempted: expected 2 dormant errors, got: $rsc"
    }

    # Path 1: a corrupt/wrong .sig is ALWAYS fatal -- no real signing
    # key needed. ensure_enterprise_lib() only WARNs on this (src\
    # fractalsql.c) and returns false, so the caller's own "enterprise
    # tier not loaded" still fires -- the WARNING text is what's
    # matched here, not the final result.
    if (PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$badsigSo'" -Want $badsigSo) {
        $r1 = Psql -Sql "SELECT fractal_ledger_truth_count();"
        if ($r1 -match '(?i)signature') { Pass "31 enterprise_mock: a corrupt/wrong .sig refuses to load" }
        else { Fail "31 enterprise_mock: expected a signature-refusal, got: $r1" }
    } else { Fail "31 enterprise_mock: could not apply enterprise_lib=badsig_so" }

    # A wrong-SIZED .sig (not just wrong-content) is a distinct branch in
    # ent_verify_signature: the file-size check is rejected BEFORE the
    # signature-verify step the badsig test above exercises -- confirmed
    # via gcov this specific size-check branch never ran before this.
    $wrongsizeSo = "$mockSo.wrongsize.dll"
    Copy-Item $mockSo $wrongsizeSo -Force
    $wrongsizeBytes = New-Object byte[] 10
    $rng.GetBytes($wrongsizeBytes)
    [System.IO.File]::WriteAllBytes("$wrongsizeSo.sig", $wrongsizeBytes)
    if (PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$wrongsizeSo'" -Want $wrongsizeSo) {
        $rsize = Psql -Sql "SELECT fractal_ledger_truth_count();"
        if ($rsize -match '(?i)signature') { Pass "31 enterprise_mock: a wrong-SIZED .sig (not 64 bytes) refuses to load" }
        else { Fail "31 enterprise_mock: expected a signature-refusal, got: $rsize" }
    } else { Fail "31 enterprise_mock: could not apply enterprise_lib=wrongsize_so" }
    Remove-Item -Force $wrongsizeSo, "$wrongsizeSo.sig" -ErrorAction SilentlyContinue

    # Path 2: no .sig at all + enterprise_require_signature=on -- fatal.
    Psql -Sql "ALTER SYSTEM SET fractalsql.enterprise_require_signature = on;" | Out-Null
    if (PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$mockSo'" -Want $mockSo) {
        $r2 = Psql -Sql "SELECT fractal_ledger_truth_count();"
        if ($r2 -match '(?i)signature') { Pass "31 enterprise_mock: a missing .sig refuses to load when enterprise_require_signature is set" }
        else { Fail "31 enterprise_mock: expected a signature-refusal, got: $r2" }
    } else { Fail "31 enterprise_mock: could not apply enterprise_lib=mock_so (require_signature path)" }

    # Path 3: no .sig, enterprise_require_signature back off -- loads
    # unverified (the backward-compatible default). This is the config
    # that stays in place for the rest of this gate.
    Psql -Sql "ALTER SYSTEM SET fractalsql.enterprise_require_signature = off;" | Out-Null
    if (PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$mockSo'" -Want $mockSo) {
        # ensure_enterprise_lib() re-WARNs "no signature found ...
        # loading unverified" on EVERY call from here on (it's a
        # backend-local static, and every Psql call here is a fresh
        # backend -- see this gate's own header comment), so every
        # exact-match check for the rest of this gate needs the FIRST
        # result line, not the whole combined text. Confirmed live:
        # unlike bash's true-interleaved `2>&1`, Psql's own
        # implementation is `($stdoutTask.Result + $stderrTask.Result)`
        # -- stdout is ALWAYS the leading block and stderr (the
        # WARNING/HINT/NOTICE noise) is ALWAYS appended after,
        # regardless of real chronological order, so the real value is
        # first, not last (the opposite of this file's earlier -Last 1
        # attempt, which grabbed the trailing HINT line instead).
        $r3 = (Psql -Sql "SELECT fractal_ledger_truth_count();") -split "`r?`n" | Select-Object -First 1
        if ($r3 -eq '0') { Pass "31 enterprise_mock: a missing .sig loads unverified by default once require_signature is off" }
        else { Fail "31 enterprise_mock: expected 0, got: $r3" }
    } else { Fail "31 enterprise_mock: could not apply enterprise_lib=mock_so (unverified path)" }

    # Every ledger void/count wrapper's success branch.
    foreach ($fn in @('fractal_ledger_flush','fractal_ledger_compact','fractal_ledger_reset_soft','fractal_ledger_reset_hard','fractal_ledger_load')) {
        $r = Psql -Sql "SELECT $fn();"
        if ($r -match 'ERROR') { Fail "31 enterprise_mock: $fn errored while the mock is loaded: $r" }
        else { Pass "31 enterprise_mock: $fn succeeds while the mock is loaded" }
    }
    $sc = (Psql -Sql "SELECT fractal_ledger_shadow_count();") -split "`r?`n" | Select-Object -First 1
    if ($sc -eq '0') { Pass "31 enterprise_mock: shadow_count succeeds while the mock is loaded" }
    else { Fail "31 enterprise_mock: expected 0 from shadow_count, got: $sc" }

    # Failure branch: the sentinel flips the SAME mock's return codes
    # without touching the postmaster's environment or enterprise_lib
    # again (see tests\mock_enterprise_core.c's own header for why a
    # file, not a value, is the toggle).
    New-Item -ItemType File -Force -Path $failSentinel | Out-Null
    $rf = Psql -Sql "SELECT fractal_ledger_flush();"
    if ($rf -match 'ERROR') { Pass "31 enterprise_mock: flush refuses cleanly when the mock reports failure" }
    else { Fail "31 enterprise_mock: expected flush to error with the fail sentinel set, got: $rf" }
    Remove-Item -Force $failSentinel -ErrorAction SilentlyContinue

    # Deep storage layer, entirely this repo's own code (ledger write/
    # verify, HMAC, chain hashing) -- audit_log/ledger_verify never
    # call back into the dlopen'd library at all ("pure storage-layer
    # check" per fractal_ledger_verify's own SQL comment), so this
    # exercises real ground regardless of what the mock above did.
    Psql -Sql "DELETE FROM fractalsql_ledger WHERE kind = 2;" | Out-Null
    $rg = Psql -Sql @"
SET fractalsql.enterprise_ledger_key = 'gate31-hmac-test-key';
SELECT fractal_audit_log('test.small', '{"n":1}'::jsonb);
SELECT fractal_ledger_verify(2)::text;
UPDATE fractalsql_ledger
   SET blob = set_byte(blob, length(blob) / 2, 254)
 WHERE kind = 2 AND id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 2);
SELECT fractal_ledger_verify(2)::text;
RESET fractalsql.enterprise_ledger_key;
"@
    if ($rg -match '"ok": true') { Pass "31 enterprise_mock: audit_log + ledger_verify round-trip a real HMAC-keyed chain entry" }
    else { Fail "31 enterprise_mock: expected an ok verify before tamper, got: $rg" }
    if ($rg -match '"ok": false') { Pass "31 enterprise_mock: ledger_verify detects a byte-level HMAC tamper (no real .so needed)" }
    else { Fail "31 enterprise_mock: expected a tamper-detected report after the byte-flip, got: $rg" }

    # ---- ledger-verify per-row error report: the malformed-row branches
    # and a pure chain-LINK break, each asserted through verify()'s own
    # jsonb report ({ok, first_failure_id, reason}). Fixture: the chain
    # table is first swapped for a CONSTRAINT-FREE copy of the same shape.
    # Rationale: ledger_ensure_table's own DDL declares prev_hash/entry_hash
    # NOT NULL, so verify()'s "malformed row (unexpected NULL)" branch is
    # unreachable through normal writes -- it defends storage the extension
    # does not control (externally replaced / lenient tables, the same
    # premise as gate 25's migration case). No HMAC key is set here, so
    # rows carry NULL mac exactly as ledger_write_entry wrote them.
    #
    # Tamper shape implemented for the link case ("31 ledger-tamper-link"):
    # UPDATE the MIDDLE row's prev_hash to a fake 32B value. This repo's
    # verify() (src\fractalsql.c, fractal_ledger_verify) recomputes a row's
    # entry_hash over expect_prev = the PREVIOUS row's STORED entry_hash --
    # not the row's own stored prev_hash -- but the chain-LINK check
    # (row.prev_hash vs expect_prev) runs BEFORE the structural recompute,
    # so a fake prev_hash fails THAT row's own link check while its
    # untouched entry_hash stays fully self-consistent. The SQLite
    # sibling's "blob + recomputed entry_hash" shape is deliberately NOT
    # implemented: in pg it would only make the NEXT row's link check fire,
    # and it needs a SQL-side sha256 (pgcrypto) this harness avoids.
    # Mirrors build_test.sh's gate 31.
    # The lenient fixture must carry ledger_ensure_table's OWN index (by
    # name and shape) — with the index missing, every audit_log/verify's
    # ensure step runs a CREATE INDEX inside the session's active query and
    # postgres rejects it ("used by active queries in this session") — the
    # docker gate caught the Linux twin of this. Mirrors build_test.sh's
    # _31_reset_lenient_ledger.
    Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;" | Out-Null
    Psql -Sql @"
CREATE TABLE fractalsql_ledger (
  id         bigserial   PRIMARY KEY,
  kind       integer     NOT NULL,
  blob       bytea       NOT NULL,
  mac        bytea,
  prev_hash  bytea,
  entry_hash bytea,
  sealed     boolean     NOT NULL DEFAULT false,
  updated    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fractalsql_ledger_kind_id_idx
  ON fractalsql_ledger (kind, id DESC);
"@ | Out-Null
    # The "ok" verdict is ONE line among several: psql also prints the
    # command tags of the DELETE/UPDATE above it, so the verdict is
    # picked by matching a line that is exactly "ok" -- the same
    # grep -q "^ok$" the POSIX twin does. Taking the FIRST line of the
    # output (the "DELETE 0" tag) never matched.
    $rf = Psql -Sql @"
DELETE FROM fractalsql_ledger WHERE kind = 2;
SELECT fractal_audit_log('test.small', '{"n":1}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":2}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":3}'::jsonb);
UPDATE fractalsql_ledger SET entry_hash = NULL
 WHERE kind = 2 AND id = (SELECT min(id) + 1 FROM fractalsql_ledger WHERE kind = 2);
SELECT CASE WHEN v->>'ok' = 'false'
             AND v->>'reason' = 'malformed row (unexpected NULL)'
             AND (v->>'first_failure_id')::bigint = m.mid
       THEN 'ok' ELSE 'FAIL: ' || v::text END
  FROM (SELECT fractal_ledger_verify(2) AS v) s,
       (SELECT min(id) + 1 AS mid FROM fractalsql_ledger WHERE kind = 2) m;
"@
    $rfOut = ($rf -split "`r?`n") | Where-Object { $_.Trim() -eq 'ok' } | Select-Object -First 1
    if ($rfOut -eq 'ok') { Pass "31 ledger-verify-malformed-null: entry_hash=NULL hits verify()'s 'malformed row (unexpected NULL)' branch at the middle row id" }
    else { Fail "31 ledger-verify-malformed-null: expected the strict ok report, got: $rf" }

    $rf = Psql -Sql @"
DELETE FROM fractalsql_ledger WHERE kind = 2;
SELECT fractal_audit_log('test.small', '{"n":1}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":2}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":3}'::jsonb);
UPDATE fractalsql_ledger SET mac = decode(repeat('cd', 16), 'hex')
 WHERE kind = 2 AND id = (SELECT min(id) + 1 FROM fractalsql_ledger WHERE kind = 2);
SELECT CASE WHEN v->>'ok' = 'false'
             AND v->>'reason' = 'malformed row (bad hash/mac length)'
             AND (v->>'first_failure_id')::bigint = m.mid
       THEN 'ok' ELSE 'FAIL: ' || v::text END
  FROM (SELECT fractal_ledger_verify(2) AS v) s,
       (SELECT min(id) + 1 AS mid FROM fractalsql_ledger WHERE kind = 2) m;
"@
    $rfOut = ($rf -split "`r?`n") | Where-Object { $_.Trim() -eq 'ok' } | Select-Object -First 1
    if ($rfOut -eq 'ok') { Pass "31 ledger-verify-malformed-length: a 16-byte mac (expects 32) hits verify()'s 'malformed row (bad hash/mac length)' branch at the middle row id" }
    else { Fail "31 ledger-verify-malformed-length: expected the strict ok report, got: $rf" }

    $rf = Psql -Sql @"
DELETE FROM fractalsql_ledger WHERE kind = 2;
SELECT fractal_audit_log('test.small', '{"n":1}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":2}'::jsonb);
SELECT fractal_audit_log('test.small', '{"n":3}'::jsonb);
UPDATE fractalsql_ledger SET prev_hash = decode(repeat('ab', 32), 'hex')
 WHERE kind = 2 AND id = (SELECT min(id) + 1 FROM fractalsql_ledger WHERE kind = 2);
SELECT CASE WHEN v->>'ok' = 'false'
             AND v->>'reason' = 'chain-link break (prev_hash mismatch)'
             AND (v->>'first_failure_id')::bigint = m.mid
       THEN 'ok' ELSE 'FAIL: ' || v::text END
  FROM (SELECT fractal_ledger_verify(2) AS v) s,
       (SELECT min(id) + 1 AS mid FROM fractalsql_ledger WHERE kind = 2) m;
"@
    $rfOut = ($rf -split "`r?`n") | Where-Object { $_.Trim() -eq 'ok' } | Select-Object -First 1
    if ($rfOut -eq 'ok') { Pass "31 ledger-tamper-link: a self-consistent row whose prev_hash no longer matches the previous row's entry_hash fails its OWN link check ('chain-link break (prev_hash mismatch)')" }
    else { Fail "31 ledger-tamper-link: expected the strict ok report, got: $rf" }

    # Restore the CANONICAL chain shape (NOT NULL on prev_hash/entry_hash)
    # for the rest of the run: drop the lenient fixture and let
    # ledger_ensure_table re-create its own DDL on the next write (the
    # audit_log call below does exactly that and seeds a fresh genesis row).
    Psql -Sql "DROP TABLE IF EXISTS fractalsql_ledger;" | Out-Null
    Psql -Sql 'SELECT fractal_audit_log(''test.reset'', ''{"n":0}''::jsonb);' | Out-Null

    # fractal_audit_unpack: a direct decode call -- distinct from the
    # audit_log+ledger_verify round-trip above, which never calls this
    # function at all (confirmed 0% coverage via gcov before this). The
    # mock's fsql_audit_unpack is a pure echo, so round-tripping jsonb
    # through it is an exact equality check. A payload past the
    # 8192-byte default cap forces the FSQL_ETRUNCATED buffer-growth
    # retry loop.
    $au = (Psql -Sql "SELECT (fractal_audit_unpack(jsonb_build_object('n', repeat('A', 9000))::text::bytea) = jsonb_build_object('n', repeat('A', 9000)));") -split "`r?`n" | Select-Object -First 1
    if ($au -eq 't') { Pass "31 enterprise_mock: audit_unpack round-trips a payload past the 8192-byte default cap" }
    else { Fail "31 enterprise_mock: expected audit_unpack to echo the 9000-byte payload back exactly, got: $au" }

    # Portfolio multimodal family (all 3 optional symbols present here).
    $pm = (Psql -Sql "SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.05]::float8[], ARRAY[0.04,0.01,0.01,0.03]::float8[], 1, 2)->>'n_found';") -split "`r?`n" | Select-Object -First 1
    if ($pm -eq '1') { Pass "31 enterprise_mock: fractal_optimize_portfolio_multimodal returns a well-formed result" }
    else { Fail "31 enterprise_mock: expected n_found=1, got: $pm" }
    # n_restarts omitted here (defaults to 8): the _pareto variant also
    # requires 1 <= max_front <= n_restarts, which an explicit
    # n_restarts=2 against max_front's default of 8 violates.
    $pmp = (Psql -Sql "SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.05]::float8[], ARRAY[0.04,0.01,0.01,0.03]::float8[], 1)->>'n_found';") -split "`r?`n" | Select-Object -First 1
    if ($pmp -eq '1') { Pass "31 enterprise_mock: fractal_optimize_portfolio_multimodal_pareto returns a well-formed result" }
    else { Fail "31 enterprise_mock: expected n_found=1, got: $pmp" }

    # t2s_audit_log_best_effort / portfolio_audit_log_best_effort: the
    # SAME two "best-effort kind=2 audit record" helpers fractal_text_
    # to_sql/fractal_optimize_portfolio always call, but confirmed via
    # gcov to only ever hit their early "enterprise not loaded" return
    # branch -- neither gate 04/14/20 (text_to_sql) nor gate 22
    # (optimize_portfolio) ever runs with enterprise loaded. One call
    # to each here, now that the mock IS loaded, exercises the real
    # JSON-build + ledger_write_entry branch in both. convert_from(...,
    # 'UTF8'), not a bare ::text cast: bytea's default ::text cast
    # gives its hex-escaped literal form under bytea_output=hex, not
    # the decoded string jsonb_in needs.
    Psql -Sql "SELECT fractal_text_to_sql('q', ARRAY['bt_customers','bt_orders']);" | Out-Null
    $t2sAudit = (Psql -Sql "SELECT convert_from(blob, 'UTF8')::jsonb->>'type' FROM fractalsql_ledger WHERE kind = 2 ORDER BY id DESC LIMIT 1;") -split "`r?`n" | Select-Object -First 1
    if ($t2sAudit -eq 'text_to_sql') { Pass "31 enterprise_mock: fractal_text_to_sql logs a text_to_sql provenance record when enterprise is loaded" }
    else { Fail "31 enterprise_mock: expected the latest kind=2 row to be type=text_to_sql, got: $t2sAudit" }

    Psql -Sql "SELECT fractal_optimize_portfolio(ARRAY[0.08,0.12,0.10,0.15]::float8[], ARRAY[0.04,0.01,0.01,0.01, 0.01,0.06,0.01,0.01, 0.01,0.01,0.05,0.01, 0.01,0.01,0.01,0.09]::float8[], 2, 12345);" | Out-Null
    $portfolioAudit = (Psql -Sql "SELECT convert_from(blob, 'UTF8')::jsonb->>'type' FROM fractalsql_ledger WHERE kind = 2 ORDER BY id DESC LIMIT 1;") -split "`r?`n" | Select-Object -First 1
    if ($portfolioAudit -eq 'portfolio_optimize') { Pass "31 enterprise_mock: fractal_optimize_portfolio logs a portfolio_optimize provenance record when enterprise is loaded" }
    else { Fail "31 enterprise_mock: expected the latest kind=2 row to be type=portfolio_optimize, got: $portfolioAudit" }

    # ---- T-J: the enterprise_lib verdict cache (ensure_enterprise_lib).
    # The dlopen verdict is cached PER BACKEND and keyed by the PATH it
    # was reached for. Two consequences, and they are opposites:
    #   - LOADED, then the GUC changes: REFUSED, with the old and new
    #     paths named. The core is dlopen'd once per backend and its
    #     image is the trust anchor, so it cannot be re-pointed under a
    #     session that already loaded it. The refusal is raised at USE
    #     time (the GUC is PGC_SIGHUP, so a value that arrives with a
    #     config reload cannot be rejected by a check hook without
    #     failing the reload of every backend).
    #   - FAILED, then the GUC changes: re-evaluated. Nothing is
    #     loaded, so there is no trust anchor to protect.
    #
    # The re-point can only arrive through a config RELOAD, so the test
    # has to hold ONE session open across the reload -- every Psql call
    # is a new backend, and a new backend starts with an empty verdict
    # cache. Hence the multi-statement, single-Psql-call blocks below.
    $repointPath = "$mockSo.repoint.dll"
    $rj1 = Psql -Sql @"
SELECT 'LOAD:' || fractal_ledger_truth_count()::text;
ALTER SYSTEM SET fractalsql.enterprise_lib = '$repointPath';
SELECT pg_reload_conf();
SELECT pg_sleep(3);
SELECT 'SEEN:' || current_setting('fractalsql.enterprise_lib');
SELECT 'USE:' || fractal_ledger_truth_count()::text;
"@
    if ($rj1 -match 'LOAD:0') {
        Pass "31 ent-repoint: the enterprise core loads from the configured path"
    } else {
        Fail "31 ent-repoint: expected the mock to load, got: $rj1"
    }
    if ($rj1 -match ('SEEN:' + [regex]::Escape($repointPath))) {
        Pass "31 ent-repoint: the reload delivered the new path to the open session"
    } else {
        Fail "31 ent-repoint: expected the session to see '$repointPath' after the reload, got: $rj1"
    }
    if ($rj1 -match 'was changed from' -and $rj1 -match [regex]::Escape($mockSo) -and $rj1 -match [regex]::Escape($repointPath)) {
        Pass "31 ent-repoint: a LOADED library refuses a mid-session re-point, naming the old and the new path"
    } else {
        Fail "31 ent-repoint: expected the re-point refusal, got: $rj1"
    }

    # The FAILED half: a load that failed is re-evaluated when the path
    # changes, so a bad path does not poison the session forever. The
    # first call must FAIL (the file is not there) and the second must
    # SUCCEED -- after the path was changed back, in the SAME session.
    $missingPath = "$mockSo.missing.dll"
    if (PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$missingPath'" -Want $missingPath) {
        $rj2 = Psql -Sql @"
SELECT 'F1:' || fractal_ledger_truth_count()::text;
ALTER SYSTEM SET fractalsql.enterprise_lib = '$mockSo';
SELECT pg_reload_conf();
SELECT pg_sleep(3);
SELECT 'F2:' || fractal_ledger_truth_count()::text;
"@
        if ($rj2 -match 'enterprise tier not loaded' -and $rj2 -notmatch 'F1:') {
            Pass "31 ent-repoint: a load that failed refuses cleanly (the dormant error)"
        } else {
            Fail "31 ent-repoint: expected the dormant error for the missing library, got: $rj2"
        }
        if ($rj2 -match 'F2:0') {
            Pass "31 ent-repoint: a FAILED verdict is re-evaluated when the path changes (the same session then loads the good library)"
        } else {
            Fail "31 ent-repoint: expected the second call to succeed after the path changed, got: $rj2"
        }
    } else {
        Fail "31 ent-repoint: could not point enterprise_lib at the missing path"
    }

    Remove-Item Env:\FSQL_MOCK_ENT_FAIL -ErrorAction SilentlyContinue
    Remove-Item -Force $mockSo, $badsigSo, $badsigSig, $failSentinel -ErrorAction SilentlyContinue
    Psql -Sql "ALTER SYSTEM RESET fractalsql.enterprise_lib; ALTER SYSTEM RESET fractalsql.enterprise_require_signature;" | Out-Null
    RestartPgForGate31 | Out-Null
}

# The 5 C-native Agent functions (src\fractalsql.c): fractal_search_
# agent, fractal_agent_plan_explore, fractal_agent_trajectory_predict,
# fractal_agent_detect_loop, fractal_rag_agent, plus their shared helper
# build_retrieval_context. Gate 23's "agents" only exercises the
# PL/pgSQL agent layer, never these direct C UDFs. Mirrors
# build_test.sh's gate_32_sovereign_agents.
#
# search_agent/rag_agent need a working embed dispatch, which $Mock
# can't provide. $Embed always returns "[0.1,0.2,0.3]" regardless of
# input -- used for both the embed step and, as a deterministic value,
# the reason step.
function Gate32SovereignAgents {
    if (-not (PgSwapPlugin $Embed)) { Fail "32 sovereign_agents: plugin swap did not take effect"; return }

    # Standalone-scoped gate runs never execute gate 15 (the embed gate), and
    # that gate is what normally leaves fractalsql.http_embed_url pinned in a
    # full-run invocation. Without the pin the engine refuses every embed
    # dispatch outright -- "fractalsql.http_embed_url is not configured" --
    # BEFORE the plugin is even consulted, which took out search_agent,
    # plan_explore, rag_agent AND the new section-6 pair in the first
    # standalone validation. Pin it here (ALTER SYSTEM; persisted harmlessly
    # into the full run since gates 15/17/20/27 re-set the same value).
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings')) {
        Fail "32 sovereign_agents: http_embed_url GUC did not take effect"; return
    }

    Psql -Sql @"
DROP TABLE IF EXISTS bt_agent_vec, bt_agent_fvec, bt_agent_nopk, bt_agent_empty;
CREATE TABLE bt_agent_vec (id serial PRIMARY KEY, emb float8[]);
INSERT INTO bt_agent_vec (emb) VALUES
  (ARRAY[0.0,0.0,0.0]::float8[]),
  (ARRAY[1.0,0.0,0.0]::float8[]),
  (ARRAY[0.0,1.0,0.0]::float8[]),
  (ARRAY[0.0,0.0,1.0]::float8[]);
CREATE TABLE bt_agent_fvec (id serial PRIMARY KEY, emb fractal_vector);
INSERT INTO bt_agent_fvec (emb) VALUES ('[0,0,0]'), ('[1,1,1]');
CREATE TABLE bt_agent_nopk (id int, emb float8[]);
INSERT INTO bt_agent_nopk VALUES (1, ARRAY[0.0,0.0,0.0]::float8[]);
CREATE TABLE bt_agent_empty (id int PRIMARY KEY, emb float8[]);
"@ | Out-Null

    # --- 1: fractal_search_agent ----------------------------------------
    $sa = Psql -Sql "SELECT answer, array_length(source_doc_ids, 1), execution_time_ms FROM fractal_search_agent('q', 'bt_agent_vec', 'emb');"
    if ($sa -match '^\[0\.1,0\.2,0\.3\]\|') { Pass "32 sovereign_agents: fractal_search_agent returns the real dispatch answer + non-empty source_doc_ids" }
    else { Fail "32 sovereign_agents: expected the embed/reason canary answer, got: $sa" }

    $saNull = Psql -Sql "SELECT fractal_search_agent(NULL, 'bt_agent_vec', 'emb');"
    if ($saNull -match 'query, table_name, and vector_col are required') { Pass "32 sovereign_agents: fractal_search_agent rejects a NULL query" }
    else { Fail "32 sovereign_agents: expected a required-args rejection, got: $saNull" }

    $saEmpty = Psql -Sql "SELECT fractal_search_agent('q', 'bt_agent_empty', 'emb');"
    if ($saEmpty -match 'no rows found in bt_agent_empty\.emb') { Pass "32 sovereign_agents: fractal_search_agent rejects an empty table" }
    else { Fail "32 sovereign_agents: expected a no-rows rejection, got: $saEmpty" }

    # --- 2: fractal_agent_plan_explore (SETOF, STRICT) ------------------
    $pe = Psql -Sql "SELECT count(*), bool_and(array_length(plan_trajectory, 1) = 3) FROM fractal_agent_plan_explore('q', 'bt_agent_vec', 'emb', 3);"
    if ($pe -match '^[1-9][0-9]*\|t$') { Pass "32 sovereign_agents: fractal_agent_plan_explore returns branches with real 3-dim trajectories" }
    else { Fail "32 sovereign_agents: expected >=1 row with 3-dim trajectories, got: $pe" }

    $peNull = Psql -Sql "SELECT * FROM fractal_agent_plan_explore(NULL, 'bt_agent_vec', 'emb', 3);"
    if ([string]::IsNullOrEmpty($peNull)) { Pass "32 sovereign_agents: fractal_agent_plan_explore(NULL, ...) returns an empty set (STRICT)" }
    else { Fail "32 sovereign_agents: expected an empty set for a NULL arg, got: $peNull" }

    # --- 3: fractal_agent_trajectory_predict (STRICT) -------------------
    $tp = Psql -Sql "SELECT array_length(predicted_state_vector, 1), projected_drift_delta IS NOT NULL, risk_threshold_exceeded IS NOT NULL FROM fractal_agent_trajectory_predict('bt_agent_vec', 'emb', 1, 1);"
    if ($tp -eq '3|t|t') { Pass "32 sovereign_agents: fractal_agent_trajectory_predict returns a real 3-dim predicted state (float8[] vector_col)" }
    else { Fail "32 sovereign_agents: expected 3|t|t, got: $tp" }

    # Same call against a fractal_vector-typed vector_col -- the other
    # branch of decode_vector_datum (confirmed 0% coverage before this).
    $tpfv = Psql -Sql "SELECT array_length(predicted_state_vector, 1), projected_drift_delta IS NOT NULL, risk_threshold_exceeded IS NOT NULL FROM fractal_agent_trajectory_predict('bt_agent_fvec', 'emb', 1, 1);"
    if ($tpfv -eq '3|t|t') { Pass "32 sovereign_agents: fractal_agent_trajectory_predict returns a real 3-dim predicted state (fractal_vector vector_col)" }
    else { Fail "32 sovereign_agents: expected 3|t|t (fractal_vector vector_col), got: $tpfv" }

    $tpNull = Psql -Sql "SELECT fractal_agent_trajectory_predict(NULL, 'emb', 1, 1);"
    if ([string]::IsNullOrEmpty($tpNull)) { Pass "32 sovereign_agents: fractal_agent_trajectory_predict(NULL, ...) returns NULL (STRICT)" }
    else { Fail "32 sovereign_agents: expected an empty/NULL result, got: $tpNull" }

    $tpNopk = Psql -Sql "SELECT fractal_agent_trajectory_predict('bt_agent_nopk', 'emb', 1, 1);"
    if ($tpNopk -match 'has no primary key') { Pass "32 sovereign_agents: fractal_agent_trajectory_predict rejects a table with no primary key" }
    else { Fail "32 sovereign_agents: expected a no-primary-key rejection, got: $tpNopk" }

    $tpOob = Psql -Sql "SELECT fractal_agent_trajectory_predict('bt_agent_vec', 'emb', 999, 1);"
    if ($tpOob -match 'no row in bt_agent_vec with') { Pass "32 sovereign_agents: fractal_agent_trajectory_predict rejects a nonexistent baseline_id" }
    else { Fail "32 sovereign_agents: expected a no-such-baseline rejection, got: $tpOob" }

    # --- 4: fractal_agent_detect_loop (pure math, no table/plugin) ------
    $dl = Psql -Sql "SELECT agent_id, is_loop_detected FROM fractal_agent_detect_loop('agent1', ARRAY[1,1, 9,9, 1,1, 9,9, 1,1, 9,9]::float8[], 2, 64, 7.0, 0);"
    if ($dl -eq 'agent1|t') { Pass "32 sovereign_agents: fractal_agent_detect_loop closes a real period-2 cycle (A,B,A,B,A,B)" }
    else { Fail "32 sovereign_agents: expected agent1|t, got: $dl" }

    $dlConst = Psql -Sql "SELECT is_loop_detected FROM fractal_agent_detect_loop('agent2', ARRAY[5,5, 5,5, 5,5]::float8[], 2, 64, 7.0, 0);"
    if ($dlConst -eq 't') { Pass "32 sovereign_agents: fractal_agent_detect_loop closes a cycle on a constant-state log" }
    else { Fail "32 sovereign_agents: expected t for a constant-state log, got: $dlConst" }

    # fractal_agent_detect_loop was found to be (wrongly) declared
    # STRICT in SQL -- its C body already explicitly handles every
    # arg's NULL case (a clear error for the 3 required args, a
    # documented default for the 3 optional ones), which STRICT was
    # silently short-circuiting around. Fixed (STRICT removed from the
    # SQL declaration); asserting the real, now-reachable error message.
    $dlReq = Psql -Sql "SELECT fractal_agent_detect_loop(NULL, ARRAY[1,1]::float8[], 2);"
    if ($dlReq -match 'agent_id, state_log, and dim are required') { Pass "32 sovereign_agents: fractal_agent_detect_loop rejects a NULL agent_id" }
    else { Fail "32 sovereign_agents: expected a required-args rejection, got: $dlReq" }

    # The other half of the same bug: an explicitly-NULL OPTIONAL arg
    # (n_bits here) must fall back to its documented default (64), not
    # null out the whole result.
    $dlOptNull = Psql -Sql "SELECT is_loop_detected FROM fractal_agent_detect_loop('agent3', ARRAY[1,1, 9,9, 1,1, 9,9, 1,1, 9,9]::float8[], 2, NULL, 7.0, 0);"
    if ($dlOptNull -eq 't') { Pass "32 sovereign_agents: fractal_agent_detect_loop(..., n_bits=NULL, ...) falls back to the n_bits=64 default, not a NULL result" }
    else { Fail "32 sovereign_agents: expected t (default n_bits honored), got: $dlOptNull" }

    $dlDim0 = Psql -Sql "SELECT fractal_agent_detect_loop('a', ARRAY[1,1]::float8[], 0);"
    if ($dlDim0 -match 'dim must be > 0') { Pass "32 sovereign_agents: fractal_agent_detect_loop rejects dim <= 0" }
    else { Fail "32 sovereign_agents: expected a dim<=0 rejection, got: $dlDim0" }

    $dlBits0 = Psql -Sql "SELECT fractal_agent_detect_loop('a', ARRAY[1,1,2,2]::float8[], 2, 0);"
    if ($dlBits0 -match 'n_bits must be > 0') { Pass "32 sovereign_agents: fractal_agent_detect_loop rejects n_bits <= 0" }
    else { Fail "32 sovereign_agents: expected an n_bits<=0 rejection, got: $dlBits0" }

    $dlHam = Psql -Sql "SELECT fractal_agent_detect_loop('a', ARRAY[1,1,2,2]::float8[], 2, 64, 42.0, -1);"
    if ($dlHam -match 'hamming_threshold must be >= 0') { Pass "32 sovereign_agents: fractal_agent_detect_loop rejects a negative hamming_threshold" }
    else { Fail "32 sovereign_agents: expected a negative-threshold rejection, got: $dlHam" }

    $dlShort = Psql -Sql "SELECT fractal_agent_detect_loop('a', ARRAY[1,1]::float8[], 2);"
    if ($dlShort -match 'state_log must contain at least 2 states') { Pass "32 sovereign_agents: fractal_agent_detect_loop rejects a state_log with fewer than 2 states" }
    else { Fail "32 sovereign_agents: expected a too-few-states rejection, got: $dlShort" }

    $dlShape = Psql -Sql "SELECT fractal_agent_detect_loop('a', ARRAY[1,1,2]::float8[], 2);"
    if ($dlShape -match 'is not a multiple of dim') { Pass "32 sovereign_agents: fractal_agent_detect_loop rejects a state_log length not divisible by dim" }
    else { Fail "32 sovereign_agents: expected a length-not-divisible rejection, got: $dlShape" }

    # --- 5: fractal_rag_agent -------------------------------------------
    $ra = Psql -Sql "SELECT answer FROM fractal_rag_agent('q', 'bt_agent_vec', 'emb');"
    if ($ra -eq '[0.1,0.2,0.3]') { Pass "32 sovereign_agents: fractal_rag_agent returns the real embed/reason dispatch answer" }
    else { Fail "32 sovereign_agents: expected the embed/reason canary answer, got: $ra" }

    $raNull = Psql -Sql "SELECT fractal_rag_agent(NULL, 'bt_agent_vec', 'emb');"
    if ($raNull -match 'query, table_name, and vector_col are required') { Pass "32 sovereign_agents: fractal_rag_agent rejects a NULL query" }
    else { Fail "32 sovereign_agents: expected a required-args rejection, got: $raNull" }

    $raEmpty = Psql -Sql "SELECT fractal_rag_agent('q', 'bt_agent_empty', 'emb');"
    if ($raEmpty -match 'no rows found in bt_agent_empty\.emb') { Pass "32 sovereign_agents: fractal_rag_agent rejects an empty table" }
    else { Fail "32 sovereign_agents: expected a no-rows rejection, got: $raEmpty" }

    # --- 6: agent_partial_reasoning_fail pair (C agents) ---------------
    # Mirror of build_test.sh's gate-32 section 6 (the sqlite repo's gate-29
    # pair convention): the embed mock (tests\mock_embed_plugin.c) fails its
    # generate() when the dispatched CONTEXT carries FSQL_BT_FAIL_REASON --
    # context is real content ONLY for the reasoning call (embed always
    # dispatches "{}"), so the embed half stays healthy and the forced failure
    # lands exactly on the reasoning flip point. Flag off -> raise; flag on ->
    # computed data half + reasoning_step_failed marker.
    Psql -Sql @"
ALTER TABLE bt_agent_vec ADD COLUMN IF NOT EXISTS note text;
INSERT INTO bt_agent_vec (emb, note) VALUES (ARRAY[0.5,0.5,0.0]::float8[], 'FSQL_BT_FAIL_REASON');
"@ | Out-Null

    $srf = Psql -Sql "SELECT fractal_search_agent('q', 'bt_agent_vec', 'emb');"
    if ($srf -match 'search_agent reasoning failed') { Pass "32 sovereign_agents: agent_partial_reasoning_fail off -- the reasoning failure still raises" }
    else { Fail "32 sovereign_agents: expected the reasoning raise with the flag off, got: $srf" }

    if (-not (PgSetGuc -Name 'fractalsql.agent_partial_reasoning_fail' -SetVal 'on' -Want 'on')) {
        Fail "32 sovereign_agents: could not set agent_partial_reasoning_fail=on"; PgSwapPlugin $Mock | Out-Null; return
    }
    $srp = Psql -Sql @"
SELECT (answer LIKE 'reasoning_step_failed:%') AND (answer LIKE '%rc=%'), array_length(source_doc_ids, 1), execution_time_ms
  FROM fractal_search_agent('q', 'bt_agent_vec', 'emb');
"@
    if ($srp -match '^t\|[1-9][0-9]*\|') { Pass "32 sovereign_agents: agent_partial_reasoning_fail on -- search_agent returns data half + reasoning_step_failed" }
    else { Fail "32 sovereign_agents: expected a partial result (data half + reasoning_step_failed), got: $srp" }

    $rap = Psql -Sql "SELECT answer LIKE 'reasoning_step_failed:%' FROM fractal_rag_agent('q', 'bt_agent_vec', 'emb');"
    if ($rap -eq 't') { Pass "32 sovereign_agents: agent_partial_reasoning_fail on -- rag_agent returns the partial answer" }
    else { Fail "32 sovereign_agents: expected the rag_agent partial answer, got: $rap" }

    if (-not (PgSetGuc -Name 'fractalsql.agent_partial_reasoning_fail' -SetVal 'off' -Want 'off')) {
        Fail "32 sovereign_agents: could not reset agent_partial_reasoning_fail=off"; PgSwapPlugin $Mock | Out-Null; return
    }

    Psql -Sql "DROP TABLE IF EXISTS bt_agent_vec, bt_agent_fvec, bt_agent_nopk, bt_agent_empty;" | Out-Null
    PgSwapPlugin $Mock | Out-Null
}

# Shared by gates 33 (smoke) and 38 (https): the cl.exe build of mcp/ once,
# in ONE place. Never tests a stale exe or relinks stale objects (both
# burned an E2E run: old obj + old exe passing existence checks) -- rebuilds
# every call; make it cheap by keeping the two gates adjacent to each other.
# Returns the exe path, or $null after the caller-visible Fail.
function BuildMcpServerMsvc([string]$GateLabel) {
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if (-not $cl) { Skip "$GateLabel (cl.exe not on PATH -- activate MSVC first)"; return $null }
    $vcpkgRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot '..\vcpkg'))
    $vcpkgInc = Join-Path $vcpkgRoot 'installed\x64-windows-static\include'
    $vcpkgLib = Join-Path $vcpkgRoot 'installed\x64-windows-static\lib'
    if (-not (Test-Path (Join-Path $vcpkgInc 'openssl\evp.h')) -or -not (Test-Path (Join-Path $vcpkgLib 'libssl.lib'))) {
        Skip "$GateLabel (vcpkg x64-windows-static OpenSSL not found at $vcpkgRoot)"; return $null
    }
    Write-Host "         [$($GateLabel.Split(' ')[0])] building mcp server (cl.exe + vcpkg openssl + PgDir libpq)..."
    $objDir = Join-Path $RepoRoot 'mcp\obj\msvc'
    New-Item -ItemType Directory -Force $objDir | Out-Null
    $exePath = Join-Path $RepoRoot 'mcp\fractalsql-postgresql-mcp.exe'
    Remove-Item $exePath -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $objDir '*.obj') -ErrorAction SilentlyContinue
    $srcSources = @(Get-ChildItem (Join-Path $RepoRoot 'mcp\src\*.cpp') | ForEach-Object { $_.FullName })
    $adapterSources = @(Get-ChildItem (Join-Path $RepoRoot 'mcp\src\adapters\*.cpp') | ForEach-Object { $_.FullName })
    $common = @('/nologo', '/std:c++17', '/EHsc', '/O1', '/MT', '/DNOMINMAX', '/nologo',   # /O1: /O2 exhausts the MSVC heap on the json.hpp-heavy TUs (C1060, E2E-caught)
        "/I$(Join-Path $RepoRoot 'mcp\vendor')",
        "/I$(Join-Path $RepoRoot 'mcp\src')",
        "/I$vcpkgInc",
        "/I$(Join-Path $PgDir 'include')")
    foreach ($src in ($srcSources + $adapterSources)) {
        $obj = Join-Path $objDir ((Split-Path $src -Leaf) -replace '\.cpp$', '.obj')
        $cLog = & cl.exe @common '/c' $src "/Fo$obj" 2>&1
        if (-not (Test-Path $obj)) {
            ($cLog | Select-Object -Last 12) | ForEach-Object { Write-Host "         [cl] $_" }
            Fail "$GateLabel (cl.exe failed compiling $(Split-Path $src -Leaf))"; return $null
        }
    }
    # Link via a response file -- pwsh's native-arg passing re-splits every
    # argument containing spaces (the user profile has one), so BOTH the
    # .obj list and the option/paths live in the rsp, quote-wrapped.
    $objs = Get-ChildItem (Join-Path $objDir '*.obj') | ForEach-Object { '"' + $_.FullName + '"' }
    $rsp = Join-Path $objDir 'link.rsp'
    @('/OUT:"' + $exePath + '"', '/nologo',
        '/LIBPATH:"' + $vcpkgLib + '"',
        '/LIBPATH:"' + (Join-Path $PgDir 'lib') + '"',
        'libpq.lib', 'libssl.lib', 'libcrypto.lib', 'ws2_32.lib', 'advapi32.lib', 'crypt32.lib', 'user32.lib') +
      $objs | Set-Content -LiteralPath $rsp
    $linkLog = & link.exe ('@' + $rsp) 2>&1
    if (-not (Test-Path $exePath)) {
        ($linkLog | Select-Object -Last 15) | ForEach-Object { Write-Host "         [link] $_" }
        Fail "$GateLabel (link.exe failed)"; return $null
    }
    return $exePath
}

function Gate33McpSmoke {
    # The FractalSQL MCP plugin (mcp/, docs/mcp-plugin.md) end
    # to end over stdio, via the shared BuildMcpServerMsvc builder + the
    # mcp\test\smoke.py driver. Skips (not fails) when cl/vcpkg-OpenSSL/
    # python are absent -- the plugin's gates are additive.
    $exePath = BuildMcpServerMsvc "33 mcp_smoke"
    if (-not $exePath) { return }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) { Skip "33 mcp_smoke (python not on PATH -- the smoke driver is a zero-dep python script)"; return }

    # Fixture for the row-locator/truncation/vectorizer calls (single-column
    # PK for the vectorizer lifecycle; label col for text registration; empty
    # emb_auto as the vectorizer's target column -- create() needs it to exist).
    Psql -Sql @"
DROP TABLE IF EXISTS mcpsmoke_items;
CREATE TABLE mcpsmoke_items (id serial PRIMARY KEY, name text, label text, emb float8[], emb_auto float8[]);
INSERT INTO mcpsmoke_items (name, label, emb) SELECT 'i' || g, 'l' || g, ARRAY[0.1*g, 0.2, 0.0]::float8[] FROM generate_series(1, 5) g;
DROP TABLE IF EXISTS mcpsw_logs;
CREATE TABLE mcpsw_logs (metric float8, ts timestamptz, host text);
INSERT INTO mcpsw_logs SELECT 50.0 + (g % 8) * 1.3 + CASE WHEN g > 48 THEN 30.0 ELSE 0.0 END,
       now() - (96 - g) * interval '1 second', 'h1' FROM generate_series(1, 96) g;
"@ | Out-Null

    # The mock reasoning plugin is usually still active in this cluster (the
    # initial postgresql.conf write and every gate's own swap-back), but gates
    # 14/27 leave the retry/think plugins behind -- and earlier cognition
    # gates overwrite $SqlFile. Pin BOTH fresh so smoke.py's Cognition round
    # trip against $Mock is deterministic no matter which gates ran before
    # this one. $SqlFile is inside $DataDir by design -- the Windows mock
    # plugins open it by bare relative filename resolved against the
    # backend's CWD (its own data dir), see the $SqlFile comment at top.
    Set-Content -LiteralPath $SqlFile -Value "SELECT 'mcp-cognition-ok'::text;" -NoNewline
    if (-not (PgSwapPlugin $Mock)) {
        Fail "33 mcp_smoke: could not pin the mock reasoning plugin for the Cognition round trip"; return
    }

    # Point the MCP server's libpq env at THIS gate run's throwaway cluster;
    # save+restore so later gates are unaffected. PgDir\bin goes on PATH so
    # libpq.dll (and its crypto deps) resolve for the child process.
    $saved = @{}
    foreach ($k in @('PGHOST','PGPORT','PGUSER','PGDATABASE','PGPASSWORD','FSQL_MCP_LOG_LEVEL','FSQL_MCP_EXE','FSQL_MCP_MOCK_SQL_FILE','PATH')) {
        $saved[$k] = [System.Environment]::GetEnvironmentVariable($k, 'Process')
    }
    $env:PGHOST = '127.0.0.1'
    $env:PGPORT = "$Port"
    $env:PGUSER = 'postgres'
    $env:PGDATABASE = 'postgres'
    $env:FSQL_MCP_LOG_LEVEL = 'normal'
    # smoke.py's agent_partial_reasoning_fail case writes the FSQL_BT_FORCE_FAIL
    # sentinel into the mock plugin's response file, then restores it; the path is
    # $SqlFile ($DataDir-relative, backend-CWD-resolved -- see the pin comment above).
    $env:FSQL_MCP_MOCK_SQL_FILE = $SqlFile
    $env:FSQL_MCP_DEBUG_SQL = '1'
    $env:FSQL_MCP_EXE = $exePath
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    $env:PATH = (Join-Path $PgDir 'bin') + ';' + $env:PATH

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $py.Source
    foreach ($a in @((Join-Path $RepoRoot 'mcp\test\smoke.py'))) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(180000)) {
        try { $proc.Kill() } catch { }
        Fail "33 mcp_smoke: smoke driver timed out after 180s"
    }
    $out = ($outTask.Result + $errTask.Result)
    # The server's stderr ([srv] audit/debug lines, plus engine NOTICEs that echo
    # the robustness sweep's oversized identifiers) is thousands of lines. Keep it
    # all in a log file; show only the driver's own lines on success, everything
    # on failure/skip so a red gate is still fully diagnosable.
    $gateLog = Join-Path ([System.IO.Path]::GetTempPath()) 'fsql_gate33_mcp_smoke.log'
    Set-Content -Path $gateLog -Value $out -Encoding UTF8
    $allLines = @($out -split "`n" | Where-Object { $_.Trim() })
    if ($proc.ExitCode -eq 0) {
        $shown = @($allLines | Where-Object { $_ -match '^\s*(PASS|FAIL|SKIP|SMOKE|robustness|sanitize_probe|differential|large inputs|offender)' })
        foreach ($line in $shown) { Write-Host "         $line" }
        Write-Host "         ($($allLines.Count) lines total, $($allLines.Count - $shown.Count) server-log lines hidden; full log: $gateLog)"
    } else {
        foreach ($line in $allLines) { Write-Host "         $line" }
        Write-Host "         (full log: $gateLog)"
    }
    if ($proc.ExitCode -eq 0) {
        Pass "33 mcp_smoke: handshake + tools/list invariants + per-tier tools/call round trips (C++17 server)"
    } elseif ($proc.ExitCode -eq 77) {
        Skip "33 mcp_smoke (smoke driver reported self-skip)"
    } else {
        Fail "33 mcp_smoke (see assert lines above)"
    }

    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item ("Env:\" + $k) -ErrorAction SilentlyContinue }
        else { [System.Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
    Psql -Sql "DROP TABLE IF EXISTS mcpsmoke_items, mcpsw_logs;" | Out-Null
}

function Gate38McpHttps {
    # The MCP server's direct-TLS mode (--https): mcp\tests\
    # mcp_https_smoke_client.py drives the three fail-fast startup modes
    # (missing cert/key, garbage key, mismatched key -> nonzero exit), proves
    # the port speaks TLS not plaintext, and round-trips an authenticated
    # session under the Bearer-token check. The DB-dependent live-leg checks
    # self-skip without PG* env (this gate stays cluster-free; plaintext
    # HTTP behavior is gate 33's/smoke.py's). Needs the exe (the shared
    # BuildMcpServerMsvc builder), python, and an openssl CLI for the
    # throwaway self-signed pair.
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) { Skip "38 mcp_https (python not on PATH)"; return }
    $ossl = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if (-not $ossl) { Skip "38 mcp_https (openssl not on PATH -- the throwaway self-signed cert needs it)"; return }
    $exePath = BuildMcpServerMsvc "38 mcp_https"
    if (-not $exePath) { return }

    Write-Host "         [38] generating throwaway self-signed cert/key..."
    $work = Join-Path $env:TEMP "fsql_mcp38_https"
    New-Item -ItemType Directory -Force $work | Out-Null
    $cert = Join-Path $work 'mcp_https_cert.pem'
    $key  = Join-Path $work 'mcp_https_key.pem'
    # Strawberry/other openssl builds may reach for a broken external config
    # (the psqlODBC dir's openssl.cnf is the observed failure); an EMPTY
    # config file sidesteps it without affecting the generated key pair.
    $emptyCnf = Join-Path $work 'mcp_https_openssl.cnf'
    if (-not (Test-Path $emptyCnf)) { Set-Content -LiteralPath $emptyCnf -Value '' -NoNewline }
    $env:OPENSSL_CONF = $emptyCnf
    & $ossl.Source req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" `
        -config $emptyCnf -keyout $key -out $cert 2>&1 | Out-Null
    if (-not ((Test-Path $cert) -and (Test-Path $key))) {
        Skip "38 mcp_https (openssl self-signed generation failed)"; return
    }

    Write-Host "         [38] driving mcp_https_smoke_client.py..."
    # PgDir\bin on PATH: every subprocess the client spawns (cli_run's
    # startup-fail probes and the served leg) loads libpq.dll from the
    # loader, whose search only sees the inherited PATH -- the same
    # prepend gate 33 does for smoke.py's server. The client passes
    # os.environ down, so setting it here covers the whole tree.
    $env:PATH = (Join-Path $PgDir 'bin') + ';' + $env:PATH
    $outLog = & {
        $env:MCP_SERVER_EXE = $exePath
        $env:MCP_SERVER_CWD = $RepoRoot
        $env:MCP_HTTPS_PORT = '18953'
        $env:MCP_HTTPS_CERT = $cert
        $env:MCP_HTTPS_KEY  = $key
        & $py.Source (Join-Path $RepoRoot 'mcp\tests\mcp_https_smoke_client.py')
    } 2>&1
    foreach ($line in ($outLog | Where-Object { $_ })) { Write-Host "         $line" }
    if ($LASTEXITCODE -eq 0) {
        Pass "38 mcp_https: --https fail-fast modes + TLS-only port + bearer-under-TLS round trip"
    } else {
        Fail "38 mcp_https (see client output above)"
    }
}

# Gates 39-42: standalone host-side unit probes, no cluster needed for
# the probe binaries themselves (gate 41's live half runs inside the db
# block, after gate 33). Probes build into dist\windows-probes\ -- the
# established throwaway-outside-the-source-tree convention gate 21's
# fuzz targets (dist\windows-fuzz) already set. Object names carry the
# _*_probe_* prefix (mirroring build_test.sh's gate 39-42; on the POSIX
# side they are what keeps a --coverage lcov merge from overwriting the
# main build's objects -- the .ps1 has no coverage legs, but the names
# keep the two harnesses' artifacts shaped alike).

function Gate39ExtractParse {
    # fsql_extract_best_point / fsql_parse_embedding_array /
    # fsql_extract_topk (src\fractalsql_parse.c -- the SAME postgres.h-
    # free TU gate 21's fuzz drivers link) parse JSON text that through
    # any real SQL-level call only ever comes back well-formed, so
    # their error branches are otherwise dead. Same standalone-probe /
    # separately-named-object treatment as build_test.sh's gate 39 and
    # the SQLite column's (tests\extract_parse_probe.c is THIS repo's
    # adapted copy of the sibling's probe -- the two parse TUs declare
    # the identical fsql_* APIs).
    $srcProbe = Join-Path $RepoRoot 'tests\extract_parse_probe.c'
    $srcParse = Join-Path $RepoRoot 'src\fractalsql_parse.c'
    if (-not (Test-Path -LiteralPath $srcProbe)) { Skip '39 extract_parse (tests\extract_parse_probe.c not present)'; return }
    if (-not (Test-Path -LiteralPath $srcParse)) { Skip '39 extract_parse (src\fractalsql_parse.c not present)'; return }
    if (-not $script:Cc) { Skip '39 extract_parse (no gcc/clang on PATH -- set FSQL_CC)'; return }

    $outDir = Join-Path $RepoRoot 'dist\windows-probes'
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $mainObj    = Join-Path $outDir '_extract_parse_main.o'
    $supportObj = Join-Path $outDir '_extract_parse_support.o'
    $buildLog   = Join-Path $outDir 'extract_parse_build.log'
    & $script:Cc -std=c11 -O1 -g -Isrc -c $srcProbe -o $mainObj 1>$buildLog 2>&1
    $rc1 = $LASTEXITCODE
    & $script:Cc -std=c11 -O1 -g -Isrc -c $srcParse -o $supportObj 1>>$buildLog 2>&1
    $rc2 = $LASTEXITCODE
    if ($rc1 -ne 0 -or $rc2 -ne 0 -or -not (Test-Path -LiteralPath $mainObj) -or -not (Test-Path -LiteralPath $supportObj)) {
        Get-Content -LiteralPath $buildLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "         $_" }
        Fail "39 extract_parse: probe failed to build (see $buildLog)"
        return
    }
    $bin = Join-Path $outDir 'extract_parse_probe.exe'
    $linkLog = Join-Path $outDir 'extract_parse_link.log'
    & $script:Cc $mainObj $supportObj -o $bin 1>$linkLog 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bin)) {
        Get-Content -LiteralPath $linkLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "         $_" }
        Fail "39 extract_parse: probe failed to link (see $linkLog)"
        return
    }
    $out = & $bin 2>&1
    $rc = $LASTEXITCODE
    $nOk = @($out | Where-Object { $_ -match '^OK:' }).Count
    if ($rc -eq 0) {
        Pass "39 extract_parse: best_point/embedding_array/topk malformed-input branches ($nOk checks OK)"
    }
    else {
        $out | ForEach-Object { Write-Host "         $_" }
        Fail "39 extract_parse: see driver output above"
    }
}

function Gate40VectorsProbe {
    # mcp\src\vectors.cpp's own coercion/validation branches are
    # reachable through a real tools/call round trip only indirectly (a
    # tool whose schema lets a deliberately-malformed element through);
    # the unit probe hits each branch with certainty. errors.cpp is
    # linked too -- the probe's ToolError/ErrorClass assertions live
    # there (same shape as build_test.sh's gate 40, which compiles the
    # same sources with the same _vectors_probe_* object names for its
    # --coverage merge).
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'mcp\tests\vectors_probe.cpp'))) {
        Skip '40 vectors_probe (mcp\tests\vectors_probe.cpp not present)'
        return
    }
    if (-not $script:Cxx) { Skip '40 vectors_probe (no g++/clang++ on PATH -- set FSQL_CXX)'; return }

    $outDir = Join-Path $RepoRoot 'dist\windows-probes'
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $mainObj  = Join-Path $outDir '_vectors_probe_main.o'
    $vecObj   = Join-Path $outDir '_vectors_probe_vectors.o'
    $errObj   = Join-Path $outDir '_vectors_probe_errors.o'
    $buildLog = Join-Path $outDir 'vectors_probe_build.log'
    Push-Location (Join-Path $RepoRoot 'mcp')
    try {
        & $script:Cxx -std=c++17 -O1 -g -Ivendor -Isrc -c 'tests\vectors_probe.cpp' -o $mainObj 1>$buildLog 2>&1
        $rc1 = $LASTEXITCODE
        & $script:Cxx -std=c++17 -O1 -g -Ivendor -Isrc -c 'src\vectors.cpp' -o $vecObj 1>>$buildLog 2>&1
        $rc2 = $LASTEXITCODE
        & $script:Cxx -std=c++17 -O1 -g -Ivendor -Isrc -c 'src\errors.cpp' -o $errObj 1>>$buildLog 2>&1
        $rc3 = $LASTEXITCODE
    }
    finally { Pop-Location }
    if ($rc1 -ne 0 -or $rc2 -ne 0 -or $rc3 -ne 0 -or -not (Test-Path -LiteralPath $mainObj) `
            -or -not (Test-Path -LiteralPath $vecObj) -or -not (Test-Path -LiteralPath $errObj)) {
        Get-Content -LiteralPath $buildLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "         $_" }
        Fail "40 vectors_probe: probe failed to build (see $buildLog)"
        return
    }
    $bin = Join-Path $outDir 'vectors_probe.exe'
    $linkLog = Join-Path $outDir 'vectors_probe_link.log'
    & $script:Cxx $mainObj $vecObj $errObj -o $bin 1>$linkLog 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bin)) {
        Get-Content -LiteralPath $linkLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "         $_" }
        Fail "40 vectors_probe: probe failed to link (see $linkLog)"
        return
    }
    $out = & $bin 2>&1
    $rc = $LASTEXITCODE
    $nOk = @($out | Where-Object { $_ -match '^OK:' }).Count
    if ($rc -eq 0) {
        Pass "40 vectors_probe: mcp\src\vectors.cpp coercion/validation branches ($nOk checks OK)"
    }
    else {
        $out | ForEach-Object { Write-Host "         $_" }
        Fail "40 vectors_probe: see driver output above"
    }
}

function Gate41DbProbe {
    # mcp\src\db.h's unconnected/refused-connection and
    # SQLSTATE-classification branches DB-less (16 checks, no PG* env --
    # the probe's live section self-skips, mirroring smoke.py's exit-77
    # posture), then -- this being the db block, after gate 33 in gate
    # order -- the same binary run LIVE against the throwaway cluster
    # with the same PG* env gate 33 exports, exercising the connected/
    # version-skew/agent-partial branches against the real engine.
    #
    # Toolchain: PRIMARY is the mingw $script:Cxx the sibling probes use
    # (verified against this PG install's own libpq: -L <PgDir>\lib -lpq
    # imports PG's own libpq.dll, with <PgDir>\bin prepended to PATH at
    # run time for libpq.dll + its crypto/intl deps). The FALLBACK
    # mirrors gate 33's established cl.exe/PgDir layout for hosts
    # without a mingw g++ -- db_probe needs no OpenSSL and no
    # amalgamation (unlike the sibling column's db_probe), so it is
    # libpq-only there.
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'mcp\tests\db_probe.cpp'))) {
        Skip '41 db_probe (mcp\tests\db_probe.cpp not present)'
        return
    }
    # Verify the resolution with a trivial PQlibVersion() compile+run
    # before trusting it (test-compile-before-trusting convention as in
    # build_test.sh's gate 41 / gate 21).
    $mcpDir  = Join-Path $RepoRoot 'mcp'
    $outDir  = Join-Path $RepoRoot 'dist\windows-probes'
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $pqProbeC  = Join-Path $outDir 'db_probe_toolchain.c'
    $pqProbeExe = Join-Path $outDir 'db_probe_toolchain.exe'
    Set-Content -LiteralPath $pqProbeC -Value @('#include <libpq-fe.h>', 'int main(void) { return PQlibVersion() >= 0 ? 0 : 1; }') -ErrorAction SilentlyContinue
    function Test-Pq([string]$PqInclude, [string]$PqLibDir, [string]$PqBinDir) {
        & $script:Cxx -O1 -g "-I$PqInclude" $pqProbeC "-L$PqLibDir" -lpq -o $pqProbeExe 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pqProbeExe)) { return $false }
        # libpq is a DLL here too (PgDir\bin, with its own crypto/intl
        # deps) -- PATH must carry it for the run half of this probe.
        $savedPath = $env:PATH
        try {
            $env:PATH = "$PqBinDir;$env:PATH"
            & $pqProbeExe *> $null
            return ($LASTEXITCODE -eq 0)
        }
        finally { $env:PATH = $savedPath }
    }

    if ($script:Cxx) {
        $pqOk = Test-Pq (Join-Path $PgDir 'include') (Join-Path $PgDir 'lib') (Join-Path $PgDir 'bin')
        if (-not $pqOk) {
            Skip "41 db_probe (no working libpq against PgDir ($PgDir) -- -I/-L/-lpq probe compile+run failed)"
            return
        }
        Remove-Item $pqProbeC, $pqProbeExe -ErrorAction SilentlyContinue

        $mainObj  = Join-Path $outDir '_db_probe_main.o'
        $errObj   = Join-Path $outDir '_db_probe_errors.o'
        $buildLog = Join-Path $outDir 'db_probe_build.log'
        # Absolute, resolved BEFORE Push-Location: CI passes a relative -PgDir
        # (deps\pg\root), which would not resolve from inside mcp\.
        $pgIncAbs = (Resolve-Path -LiteralPath (Join-Path $PgDir 'include')).Path
        Push-Location $mcpDir
        try {
            & $script:Cxx -std=c++17 -O1 -g '-Ivendor' '-Isrc' "-I$pgIncAbs" `
                -c 'tests\db_probe.cpp' -o $mainObj 1>$buildLog 2>&1
            $rc1 = $LASTEXITCODE
            & $script:Cxx -std=c++17 -O1 -g '-Ivendor' '-Isrc' "-I$pgIncAbs" `
                -c 'src\errors.cpp' -o $errObj 1>>$buildLog 2>&1
            $rc2 = $LASTEXITCODE
        }
        finally { Pop-Location }
        if ($rc1 -ne 0 -or $rc2 -ne 0 -or -not (Test-Path -LiteralPath $mainObj) -or -not (Test-Path -LiteralPath $errObj)) {
            Get-Content -LiteralPath $buildLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "         $_" }
            Fail "41 db_probe: probe failed to build (see $buildLog)"
            return
        }
        $bin = Join-Path $outDir 'db_probe.exe'
        $linkLog = Join-Path $outDir 'db_probe_link.log'
        & $script:Cxx $mainObj $errObj -o $bin "-L$(Join-Path $PgDir 'lib')" -lpq 1>$linkLog 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bin)) {
            Get-Content -LiteralPath $linkLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "         $_" }
            Fail "41 db_probe: probe failed to link (see $linkLog)"
            return
        }
    }
    else {
        # MSVC fallback -- gate 33's cl.exe/PgDir layout (libpq only).
        $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
        if (-not $cl) { Skip "41 db_probe (no g++ and no cl.exe on PATH -- activate MSVC or set FSQL_CXX)"; return }
        $pqOk = Test-Pq (Join-Path $PgDir 'include') (Join-Path $PgDir 'lib') (Join-Path $PgDir 'bin')
        if (-not $pqOk) {
            Skip "41 db_probe (no working libpq against PgDir ($PgDir) for the cl.exe path either)"
            return
        }
        Remove-Item $pqProbeC, $pqProbeExe -ErrorAction SilentlyContinue
        Write-Host "         [41] building db_probe (cl.exe + PgDir libpq)..."
        $srcProbe = Join-Path $mcpDir 'tests\db_probe.cpp'
        $srcErr   = Join-Path $mcpDir 'src\errors.cpp'
        $common = @('/nologo', '/std:c++17', '/EHsc', '/MT', '/O1', '/DNOMINMAX',
            "/I$(Join-Path $mcpDir 'vendor')",
            "/I$(Join-Path $mcpDir 'src')",
            "/I$(Join-Path $PgDir 'include')")
        $mainObj = Join-Path $outDir '_db_probe_main.obj'
        $errObj  = Join-Path $outDir '_db_probe_errors.obj'
        $cLog = & cl.exe @common '/c' $srcProbe "/Fo$mainObj" 2>&1
        if (-not (Test-Path -LiteralPath $mainObj)) {
            ($cLog | Select-Object -Last 12) | ForEach-Object { Write-Host "         [41 cl] $_" }
            Fail "41 db_probe (cl.exe failed compiling db_probe.cpp)"; return
        }
        $cLog = & cl.exe @common '/c' $srcErr "/Fo$errObj" 2>&1
        if (-not (Test-Path -LiteralPath $errObj)) {
            ($cLog | Select-Object -Last 12) | ForEach-Object { Write-Host "         [41 cl] $_" }
            Fail "41 db_probe (cl.exe failed compiling errors.cpp)"; return
        }
        $bin = Join-Path $outDir 'db_probe.exe'
        $rsp = Join-Path $outDir 'db_probe_link.rsp'
        @('/OUT:"' + $bin + '"', '/nologo',
            '/LIBPATH:"' + (Join-Path $PgDir 'lib') + '"',
            'libpq.lib', 'ws2_32.lib', 'advapi32.lib', 'user32.lib',
            '"' + $mainObj + '"', '"' + $errObj + '"') | Set-Content -LiteralPath $rsp
        $linkLog = & link.exe ('@' + $rsp) 2>&1
        if (-not (Test-Path -LiteralPath $bin)) {
            ($linkLog | Select-Object -Last 15) | ForEach-Object { Write-Host "         [41 link] $_" }
            Fail "41 db_probe (link.exe failed)"; return
        }
    }

    # The MinGW runtime DLLs the probe needs, copied next to the exe: the Windows
    # loader searches the exe's own directory BEFORE PATH, and PATH below puts
    # PgDir\bin first. A PostgreSQL package that ships its own (different)
    # libgcc/libstdc++/libwinpthread would otherwise win and the probe would die
    # at load with no output (seen on the PG 14-16 packages, not 17/18).
    if ($script:Cxx) {
        $cxxDir = Split-Path -Parent $script:Cxx
        if ($cxxDir) {
            foreach ($dll in 'libstdc++-6.dll', 'libgcc_s_seh-1.dll', 'libwinpthread-1.dll') {
                $dllSrc = Join-Path $cxxDir $dll
                if (Test-Path -LiteralPath $dllSrc) { Copy-Item -LiteralPath $dllSrc -Destination $outDir -Force }
            }
        }
    }

    # --- run: DB-less leg, then the live leg (cluster is up inside the
    # db block; single -Gate 41 runs go through PgSetup for the same
    # reason gate 33 does). Save/clear the PG* env for the DB-less leg,
    # then wire gate 33's PG* for the live leg, restoring everything.
    $saved = @{}
    foreach ($k in @('PGHOST','PGPORT','PGUSER','PGDATABASE','PGPASSWORD','FSQL_MCP_TEST_CONNINFO','PATH')) {
        $saved[$k] = [System.Environment]::GetEnvironmentVariable($k, 'Process')
    }
    foreach ($k in @('PGHOST','PGPORT','PGUSER','PGDATABASE','PGPASSWORD','FSQL_MCP_TEST_CONNINFO')) {
        Remove-Item ("Env:\" + $k) -ErrorAction SilentlyContinue
    }
    # libpq.dll (and its crypto/intl deps) resolve from PgDir\bin for
    # BOTH legs -- the DB-less one included, since even the
    # unconnected branches' link-time import needs the DLL at load.
    $env:PATH = (Join-Path $PgDir 'bin') + ';' + $env:PATH
    try {
        $out = & $bin 2>&1   # DB-less: no PG* env; probe self-skips its live section
        $rc = $LASTEXITCODE
        $nOk = @($out | Where-Object { $_ -match '^OK:' }).Count
        if ($rc -eq 0) {
            Pass "41 db_probe: unconnected/refused-connection + SQLSTATE-classification branches, DB-less ($nOk checks OK; live checks self-skipped without PG* env)"
        }
        else {
            $out | ForEach-Object { Write-Host "         $_" }
            Write-Host ("         [41] exit code {0} (0x{1:X8}); 0xC0000135 = DLL not found at load, 0xC0000005 = access violation" -f $rc, [uint32]([int64]$rc -band 0xFFFFFFFF))
            Write-Host ("         [41] runtime DLLs in PgDir\bin: " + ((Get-ChildItem -LiteralPath (Join-Path $PgDir 'bin') -Filter 'lib*.dll' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'gcc|stdc|winpthread' } | ForEach-Object { $_.Name }) -join ', '))
            Fail "41 db_probe: see driver output above (DB-less leg)"
            return
        }
        # LIVE leg -- mirror gate 33's PG* wiring exactly.
        $env:PGHOST = '127.0.0.1'
        $env:PGPORT = "$Port"
        $env:PGUSER = 'postgres'
        $env:PGDATABASE = 'postgres'
        $out = & $bin 2>&1
        $rc = $LASTEXITCODE
        $nOk = @($out | Where-Object { $_ -match '^OK:' }).Count
        if ($rc -eq 0) {
            Pass "41 db_probe live leg: connected callScalar/callRow/callRows, engine-failure classification, version-skew warning and agent-partial wiring on the live cluster ($nOk checks OK)"
        }
        else {
            $out | ForEach-Object { Write-Host "         $_" }
            Write-Host ("         [41] exit code {0} (0x{1:X8}); 0xC0000135 = DLL not found at load, 0xC0000005 = access violation" -f $rc, [uint32]([int64]$rc -band 0xFFFFFFFF))
            Write-Host ("         [41] runtime DLLs in PgDir\bin: " + ((Get-ChildItem -LiteralPath (Join-Path $PgDir 'bin') -Filter 'lib*.dll' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'gcc|stdc|winpthread' } | ForEach-Object { $_.Name }) -join ', '))
            Fail "41 db_probe live leg: see driver output above"
        }
    }
    finally {
        foreach ($k in $saved.Keys) {
            if ($null -eq $saved[$k]) { Remove-Item ("Env:\" + $k) -ErrorAction SilentlyContinue }
            else { [System.Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
        }
    }
}

function Gate42ConcurrencyProbe {
    # mcp\src\concurrency.h's per-client-limit-reached and global-timeout
    # throw branches (and the Token-destructor release paths each throw
    # takes on its way out) are never hit by any live-protocol test: a
    # synchronous request/response round trip always releases its Token
    # before the next request is read. concurrency.h is header-only (no
    # concurrency.cpp of its own), so -- like gate 41's db_probe sibling --
    # this probe's own translation unit is the only place its coverage
    # data exists at all, and no other object needs to be separately
    # compiled alongside it.
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'mcp\tests\concurrency_probe.cpp'))) {
        Skip '42 concurrency_probe (mcp\tests\concurrency_probe.cpp not present)'
        return
    }
    if (-not $script:Cxx) { Skip '42 concurrency_probe (no g++/clang++ on PATH -- set FSQL_CXX)'; return }

    $outDir = Join-Path $RepoRoot 'dist\windows-probes'
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $obj = Join-Path $outDir '_concurrency_probe.o'
    $buildLog = Join-Path $outDir 'concurrency_probe_build.log'
    Push-Location (Join-Path $RepoRoot 'mcp')
    try {
        & $script:Cxx -std=c++17 -O1 -g -pthread -Ivendor -Isrc -c 'tests\concurrency_probe.cpp' -o $obj 1>$buildLog 2>&1
        $rc1 = $LASTEXITCODE
    }
    finally { Pop-Location }
    if ($rc1 -ne 0 -or -not (Test-Path -LiteralPath $obj)) {
        Get-Content -LiteralPath $buildLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "         $_" }
        Fail "42 concurrency_probe: probe failed to build (see $buildLog)"
        return
    }
    $bin = Join-Path $outDir 'concurrency_probe.exe'
    $linkLog = Join-Path $outDir 'concurrency_probe_link.log'
    & $script:Cxx -pthread $obj -o $bin 1>$linkLog 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bin)) {
        Get-Content -LiteralPath $linkLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "         $_" }
        Fail "42 concurrency_probe: probe failed to link (see $linkLog)"
        return
    }
    $out = & $bin 2>&1
    $rc = $LASTEXITCODE
    if ($rc -eq 0) {
        Pass "42 concurrency_probe: mcp\src\concurrency.h per-client-limit, global-timeout and Token-release branches (driver: $out)"
    }
    else {
        $out | ForEach-Object { Write-Host "         $_" }
        Fail "42 concurrency_probe: see driver output above"
    }
}

# Table runner shared by gates 44 and 45 -- see build_test.sh's sql_table_run.
# Rows are "label<TAB>expect<TAB>sql": expect = "E:<text>" (an ERROR whose
# message contains <text>), "OK" (no ERROR) or "NONE" (either); every row
# also fails if the backend dies. A "@mock" row swaps the reasoning mock back
# in. Sets $script:TblN / $script:TblBad.
function SqlTableRun([string]$Gate, [string]$Rows) {
    $script:TblN = 0; $script:TblBad = 0
    foreach ($line in ($Rows -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $f = $line -split "`t", 3
        $label = $f[0]
        if ($label -eq '@mock') { PgSwapPlugin $Mock | Out-Null; continue }
        # "@plugin<TAB>NAME": swap the reasoning plugin to the script variable $NAME (Mock, Embed, ...).
        # "@guc<TAB>name<TAB>value": ALTER SYSTEM SET fractalsql.<name> = value, then wait for it.
        if ($label -eq '@plugin') { PgSwapPlugin (Get-Variable -Name $f[1] -ValueOnly -Scope Script) | Out-Null; continue }
        if ($label -eq '@guc') {
            $gv = if ($f.Count -gt 2) { $f[2] } else { '' }
            if (-not (PgSetGuc -Name "fractalsql.$($f[1])" -SetVal "'$gv'" -Want $gv)) { Fail "$Gate error_paths: could not set fractalsql.$($f[1])" }
            continue
        }
        $expect = $f[1]; $sql = $f[2]
        $script:TblN++
        $out = Psql -Sql $sql
        $short = ($out -replace '\s+', ' ')
        if ($short.Length -gt 160) { $short = $short.Substring(0, 160) }
        if ($out -match 'server closed the connection|terminated by signal|in recovery mode|not yet accepting') {
            Fail "$Gate error_paths: '$label' CRASHED the backend: $short"
            $script:TblBad++
            for ($i = 0; $i -lt (60 * $TimeoutMult); $i++) {
                if ((Psql -Sql 'SELECT 1') -eq '1') { break }
                Start-Sleep -Milliseconds 500
            }
            continue
        }
        $isErr = $out -match 'ERROR:'
        if ($expect.StartsWith('E:')) {
            if (-not ($isErr -and $out.Contains($expect.Substring(2)))) {
                Fail "$Gate error_paths: '$label' expected ERROR containing '$($expect.Substring(2))', got: $short"; $script:TblBad++
            }
        } elseif ($expect -eq 'OK') {
            if ($isErr) { Fail "$Gate error_paths: '$label' expected success, got: $short"; $script:TblBad++ }
        }
    }
}

# Gate 44: error-path / argument-validation sweep -- see build_test.sh's
# gate_44_error_paths for the full rationale. One table of calls, each with
# the outcome it must produce ("E:<text>" = an ERROR containing <text>, "OK" =
# no ERROR, "NONE" = either); every row also fails if the backend dies.
function Gate44ErrorPaths {
    Psql -Sql @"
DROP TABLE IF EXISTS bt_g44;
CREATE TABLE bt_g44 (id int, emb float8[]);
INSERT INTO bt_g44 VALUES (1, ARRAY[0.1,0.2]), (2, ARRAY[0.3,0.2]), (3, ARRAY[0.9,0.8]);
DROP TABLE IF EXISTS bt_g44x, bt_g44e;
CREATE TABLE bt_g44x (id serial PRIMARY KEY, emb float8[]);
INSERT INTO bt_g44x (emb) VALUES (ARRAY[0.1,0.2,0.3,0.4]), (ARRAY[0.4,0.3,0.2,0.1]), (ARRAY[0.9,0.8,0.7,0.6]);
CREATE TABLE bt_g44e (id serial PRIMARY KEY, emb float8[], txt text);
INSERT INTO bt_g44e (emb, txt) VALUES (ARRAY[0.1,0.2,0.3], 'a'), (ARRAY[0.3,0.2,0.1], 'b'), (ARRAY[0.9,0.8,0.7], 'c');
DROP TABLE IF EXISTS bt_g44n, bt_g44d, bt_g44z, bt_g44t, bt_g44v, bt_g44w;
CREATE TABLE bt_g44n (id serial PRIMARY KEY, emb float8[]);
INSERT INTO bt_g44n (emb) VALUES (NULL), (ARRAY[0.1,0.2]), (NULL);
CREATE TABLE bt_g44d (id serial PRIMARY KEY, emb float8[]);
INSERT INTO bt_g44d (emb) VALUES (ARRAY[0.1,0.2]), (ARRAY[0.1,0.2,0.3]);
CREATE TABLE bt_g44z (id serial PRIMARY KEY, emb float8[]);
CREATE TABLE bt_g44t (id serial PRIMARY KEY, emb text);
INSERT INTO bt_g44t (emb) VALUES ('x'), ('y');
CREATE TABLE bt_g44v (id serial PRIMARY KEY, emb fractal_vector);
INSERT INTO bt_g44v (emb) VALUES ('[0.1,0.2]'), ('[0.3,0.2]'), ('[0.9,0.8]');
CREATE TABLE bt_g44w (id serial PRIMARY KEY, emb fractal_vector);
INSERT INTO bt_g44w (emb) VALUES ('[0.1,0.2]'), ('[0.1,0.2,0.3]');
"@ | Out-Null
    # The embed-dependent rows need the embed mock + a configured endpoint;
    # the "@mock" row swaps the reasoning mock back in for what follows.
    if (-not (PgSwapPlugin $Embed)) { Fail "44 error_paths: plugin swap did not take effect"; return }
    if (-not (PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings')) {
        Fail "44 error_paths: http_embed_url GUC did not take effect"; PgSwapPlugin $Mock | Out-Null; return
    }

    $rows = @'
search_agent null query	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_search_agent(NULL,'bt_g44e','emb')
search_agent null table	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_search_agent('q',NULL,'emb')
search_agent null col	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_search_agent('q','bt_g44e',NULL)
search_agent pop 0	E:fractalsql: search failed	SELECT * FROM fractal_search_agent('q','bt_g44e','emb',0,15)
search_agent iter 0	OK	SELECT * FROM fractal_search_agent('q','bt_g44e','emb',50,0)
search_agent null pop	OK	SELECT * FROM fractal_search_agent('q','bt_g44e','emb',NULL,NULL)
rag null q	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_rag_agent(NULL,'bt_g44e','emb')
rag null tbl	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_rag_agent('q',NULL,'emb')
rag null col	E:fractalsql: query, table_name, and vector_col are required	SELECT * FROM fractal_rag_agent('q','bt_g44e',NULL)
rag bad filter	OK	SELECT * FROM fractal_rag_agent('q','bt_g44e','emb','not json')
plan null state	OK	SELECT * FROM fractal_agent_plan_explore(NULL,'bt_g44e','emb',3)
plan null tbl	OK	SELECT * FROM fractal_agent_plan_explore('s',NULL,'emb',3)
plan null col	OK	SELECT * FROM fractal_agent_plan_explore('s','bt_g44e',NULL,3)
plan null br	OK	SELECT * FROM fractal_agent_plan_explore('s','bt_g44e','emb',NULL)
plan br 0	E:fractalsql: plan_explore search failed (rc=-1)	SELECT * FROM fractal_agent_plan_explore('s','bt_g44e','emb',0)
traj null tbl	OK	SELECT * FROM fractal_agent_trajectory_predict(NULL,'emb',1,3)
traj null col	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e',NULL,1,3)
traj null id	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',NULL,3)
traj null steps	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',1,NULL)
traj steps 0	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',1,0)
traj steps big	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',1,100000)
traj missing id	E:fractal_agent_trajectory_predict: no row in bt_g44e with id = 999999	SELECT * FROM fractal_agent_trajectory_predict('bt_g44e','emb',999999,3)
loop null id	E:fractalsql: agent_id, state_log, and dim are required	SELECT * FROM fractal_agent_detect_loop(NULL,ARRAY[1,2]::float8[],1)
loop null log	E:fractalsql: agent_id, state_log, and dim are required	SELECT * FROM fractal_agent_detect_loop('a',NULL,1)
loop null dim	E:fractalsql: agent_id, state_log, and dim are required	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],NULL)
loop dim 0	E:fractalsql: dim must be > 0	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],0)
loop bits 0	E:fractalsql: n_bits must be > 0	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],1,0)
loop bits huge	OK	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],1,100000)
loop ragged	E:fractalsql: state_log length (3) is not a multiple of dim (2)	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2,3]::float8[],2)
loop neg thresh	E:fractalsql: hamming_threshold must be >= 0	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],1,64,0.0,-1)
loop null opts	OK	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2,1,2,1,2]::float8[],2,NULL,NULL,NULL)
loop empty log	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_agent_detect_loop('a','{}'::float8[],1)
loop null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,NULL]::float8[],1)
loop 2d array	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[[1,2],[3,4]]::float8[],1)
fingerprint bits 0	E:fractalsql: n_bits must be > 0	SELECT fractal_state_fingerprint(ARRAY[1,2]::float8[],0)
fingerprint empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_state_fingerprint('{}'::float8[],8)
cycle null elem	E:fractalsql: fingerprints array must not contain NULLs	SELECT * FROM fractal_cycle_detect(ARRAY['\x01',NULL]::bytea[])
cycle ragged	E:fractalsql: every fingerprint must be the same length (index 0 was 1 b	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x0102']::bytea[])
cycle neg thresh	E:fractalsql: hamming_threshold must be >= 0	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x01']::bytea[],-1)
cycle empty	E:fractalsql: fingerprints array must not be empty	SELECT * FROM fractal_cycle_detect('{}'::bytea[])
cycle repeat	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x02','\x01','\x02','\x01','\x02']::bytea[])
cycle thresh	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x00','\x01','\x00','\x01','\x00','\x01']::bytea[],2)
cycle 2d	OK	SELECT * FROM fractal_cycle_detect(ARRAY[['\x01','\x02'],['\x03','\x04']]::bytea[])
dfa null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_dimension_dfa(ARRAY[1,NULL,3]::float8[])
dfa empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_dimension_dfa('{}'::float8[])
boxcount dim 0	E:fractalsql: points length (4) must be a positive multiple of dim (0)	SELECT fractal_dimension_boxcount(ARRAY[1,2,3,4]::float8[],0)
boxcount ragged	E:fractalsql: points length (3) must be a positive multiple of dim (2)	SELECT fractal_dimension_boxcount(ARRAY[1,2,3]::float8[],2)
boxcount few	E:fractalsql: fractal_dimension_boxcount rc=-1 (need >= 8 points, non-de	SELECT fractal_dimension_boxcount(ARRAY[1,2]::float8[],2)
cp thresh	E:fractalsql: fractal_change_point_detect rc=-1 (need n >= 2*win, thresh	SELECT fractal_change_point_detect(ARRAY[1,2,3,4,5,6,7,8]::float8[],2,-1.0,16)
cp max_points 0	E:fractalsql: max_points must be > 0	SELECT fractal_change_point_detect(ARRAY[1,2,3,4,5,6,7,8]::float8[],2,2.0,0)
cp short	E:fractalsql: fractal_change_point_detect rc=-1 (need n >= 2*win, thresh	SELECT fractal_change_point_detect(ARRAY[1,2,3]::float8[],16,2.0,16)
cp null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_change_point_detect(ARRAY[1,NULL,3]::float8[],2,2.0,16)
periodogram short	E:fractalsql: fractal_periodogram rc=-1 (need n >= 4)	SELECT * FROM fractal_periodogram(ARRAY[1,2,3]::float8[],4)
periodogram peaks 0	E:fractalsql: max_peaks must be > 0	SELECT * FROM fractal_periodogram(ARRAY[1,2,3,4,5,6,7,8]::float8[],0)
periodogram null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_periodogram(ARRAY[1,NULL,3,4,5]::float8[],4)
tda dim 0	E:fractalsql: dim must be > 0	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4]::float8[],0)
tda ragged	E:fractalsql: points length (3) must be a multiple of dim (2)	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3]::float8[],2)
tda max_dim	E:fractalsql: fractal_tda_persistence_diagram rc=-1 (2 <= n_points <= 51	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4]::float8[],2,-1)
tda thresh	E:fractalsql: fractal_tda_persistence_diagram rc=-1 (2 <= n_points <= 51	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4]::float8[],2,1,-1.0)
tda bars	E:fractalsql: max_h0_bars must be > 0	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4]::float8[],2,1,1.0,0)
drift win	E:fractalsql: window must be > 0	SELECT fractal_dimension_drift(ARRAY[1,2,3,4]::float8[],0)
drift short	E:fractalsql: fractal_dimension_drift rc=-1 (need n >= window + 16, wind	SELECT fractal_dimension_drift(ARRAY[1,2,3,4]::float8[],64)
portfolio k 0	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],0)
portfolio k big	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],5)
portfolio cov len	E:fractalsql: cov length (3) must be n_assets^2 (n_assets=2, expected 4)	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0]::float8[],1)
portfolio bad mode	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'bogus')	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,NULL,false,'bogus')
portfolio null k	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],NULL)
portfolio null mu	E:fractalsql: fractal_optimize_portfolio: mu must not be NULL	SELECT fractal_optimize_portfolio(NULL,ARRAY[1,0,0,1]::float8[],1)
portfolio null cov	E:fractalsql: fractal_optimize_portfolio: cov must not be NULL	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2]::float8[],NULL,1)
portfolio null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_optimize_portfolio(ARRAY[0.1,NULL]::float8[],ARRAY[1,0,0,1]::float8[],1)
portfolio ok	OK	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,7)
portfolio ok obl	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'cauchy')	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,7,true,'cauchy')
mm null mu	E:fractalsql: fractal_optimize_portfolio_multimodal: mu must not be NULL	SELECT fractal_optimize_portfolio_multimodal(NULL,ARRAY[1,0,0,1]::float8[],1)
mm null cov	E:fractalsql: fractal_optimize_portfolio_multimodal: cov must not be NUL	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],NULL,1)
pareto null mu	E:fractalsql: fractal_optimize_portfolio_multimodal_pareto: mu must not 	SELECT fractal_optimize_portfolio_multimodal_pareto(NULL,ARRAY[1,0,0,1]::float8[],1)
pareto null cov	E:fractalsql: fractal_optimize_portfolio_multimodal_pareto: cov must not	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],NULL,1)
subset null vals	E:fractalsql: item_values, upper_bounds, and k must not be NULL	SELECT fractal_optimize_subset(NULL,ARRAY[1,1]::float8[],1)
subset null ub	E:fractalsql: item_values, upper_bounds, and k must not be NULL	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],NULL,1)
subset null k	E:fractalsql: item_values, upper_bounds, and k must not be NULL	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1,1]::float8[],NULL)
subset k 0	E:fractalsql: k must satisfy 1 <= k <= n_items (2)	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1,1]::float8[],0)
subset ub len	E:fractalsql: upper_bounds length (1) must match item_values length (2)	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1]::float8[],1)
subset prev len	E:fractalsql: prev_weights length (1) must match item_values length (2)	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1,1]::float8[],1,ARRAY[1]::float8[])
subset neg pen	E:fractalsql: fractal_optimize_subset rc=-1 (check upper_bounds in [0,1]	SELECT fractal_optimize_subset(ARRAY[1,2]::float8[],ARRAY[1,1]::float8[],1,NULL,-1.0)
subset ok prev	OK	SELECT fractal_optimize_subset(ARRAY[1,2,3]::float8[],ARRAY[1,1,1]::float8[],2,ARRAY[0.5,0.5,0]::float8[],0.1,3)
subset ok nulls	OK	SELECT fractal_optimize_subset(ARRAY[1,2,3]::float8[],ARRAY[1,1,1]::float8[],2,NULL,NULL,NULL)
vascular null	OK	SELECT fractal_vascular_network(NULL,ARRAY[0,1]::int4[],ARRAY[1.0]::float8[])
vascular null edges	OK	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],NULL,ARRAY[1.0]::float8[])
vascular null arc	OK	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,1]::int4[],NULL)
vascular coords len	E:fractalsql: node_coords length must be a multiple of 3	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0]::float8[],ARRAY[0,1]::int4[],ARRAY[1.0]::float8[])
vascular edges odd	E:fractalsql: edges length must be a multiple of 2	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,1,0]::int4[],ARRAY[1.0]::float8[])
vascular arc len	E:fractalsql: edge_arc_length length (2) must equal edges length / 2 (1)	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,1]::int4[],ARRAY[1.0,2.0]::float8[])
vascular idx range	E:fractalsql: fractal_vascular_network rc=-1	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,9]::int4[],ARRAY[1.0]::float8[])
vascular neg idx	E:fractalsql: index array entries must be >= 0 (got -1)	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[-1,1]::int4[],ARRAY[1.0]::float8[])
vascular neg arc	E:fractalsql: fractal_vascular_network rc=-1	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,1]::int4[],ARRAY[-1.0]::float8[])
folding null	OK	SELECT fractal_cortical_folding(NULL,ARRAY[0,1,2]::int4[])
folding null faces	OK	SELECT fractal_cortical_folding(ARRAY[0,0,0,1,0,0,0,1,0]::float8[],NULL)
folding verts len	E:fractalsql: vertices length must be a multiple of 3	SELECT fractal_cortical_folding(ARRAY[0,0,0,1,0]::float8[],ARRAY[0,1,2]::int4[])
folding faces len	E:fractalsql: faces length must be a multiple of 3	SELECT fractal_cortical_folding(ARRAY[0,0,0,1,0,0,0,1,0]::float8[],ARRAY[0,1]::int4[])
folding idx range	E:fractalsql: fractal_cortical_folding rc=-1 (need >= 4 non-coplanar ver	SELECT fractal_cortical_folding(ARRAY[0,0,0,1,0,0,0,1,0]::float8[],ARRAY[0,1,9]::int4[])
nerve null	OK	SELECT fractal_nerve_plexus_metric(NULL,2,ARRAY[0,1]::int4[])
nerve null dim	OK	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],NULL,ARRAY[0,1]::int4[])
nerve null edges	OK	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],2,NULL)
nerve dim 0	E:fractalsql: node_coords length (4) must be a positive multiple of dim 	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],0,ARRAY[0,1]::int4[])
nerve ragged	E:fractalsql: node_coords length (3) must be a positive multiple of dim 	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1]::float8[],2,ARRAY[0,1]::int4[])
nerve edges odd	E:fractalsql: edges length must be a multiple of 2	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],2,ARRAY[0,1,0]::int4[])
nerve idx range	E:fractalsql: fractal_nerve_plexus_metric rc=-1	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],2,ARRAY[0,7]::int4[])
morph null	OK	SELECT fractal_morphological_complexity(NULL,2)
morph null dim	OK	SELECT fractal_morphological_complexity(ARRAY[0,0,1,0]::float8[],NULL)
morph dim 0	E:fractalsql: points length (4) must be a positive multiple of dim (0)	SELECT fractal_morphological_complexity(ARRAY[0,0,1,0]::float8[],0)
morph ragged	E:fractalsql: points length (3) must be a positive multiple of dim (2)	SELECT fractal_morphological_complexity(ARRAY[0,0,1]::float8[],2)
store_morph null	OK	SELECT fractal_store_morphology(NULL,ARRAY[1,2]::float8[])
store_morph null arr	OK	SELECT fractal_store_morphology(1,NULL)
store_morph empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_store_morphology(1,'{}'::float8[])
mine null	OK	SELECT * FROM fractal_mine_topology_negatives(NULL,3)
mine null k	OK	SELECT * FROM fractal_mine_topology_negatives(ARRAY[1,2]::float8[],NULL)
mine k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_mine_topology_negatives(ARRAY[1,2]::float8[],0)
mine empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_mine_topology_negatives('{}'::float8[],3)
telemetry null tbl	OK	SELECT * FROM fractal_search_telemetry(NULL,'emb',ARRAY[1,2]::float8[],1)
telemetry null col	OK	SELECT * FROM fractal_search_telemetry('bt_g44',NULL,ARRAY[1,2]::float8[],1)
telemetry null q	OK	SELECT * FROM fractal_search_telemetry('bt_g44','emb',NULL,1)
telemetry null k	OK	SELECT * FROM fractal_search_telemetry('bt_g44','emb',ARRAY[1,2]::float8[],NULL)
telemetry k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_search_telemetry('bt_g44','emb',ARRAY[1,2]::float8[],0)
telemetry no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_search_telemetry('bt_nope','emb',ARRAY[1,2]::float8[],1)
telemetry no col	E:column "nope" does not exist	SELECT * FROM fractal_search_telemetry('bt_g44','nope',ARRAY[1,2]::float8[],1)
telemetry empty q	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_search_telemetry('bt_g44','emb','{}'::float8[],1)
telemetry dim mismatch	E:fractalsql: bt_g44.emb row 0 has dim 2, expected 3 (match the query)	SELECT * FROM fractal_search_telemetry('bt_g44','emb',ARRAY[1,2,3]::float8[],1)
telemetry ok	OK	SELECT * FROM fractal_search_telemetry('bt_g44','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid null tbl	OK	SELECT * FROM fractal_hybrid_clinical_search(NULL,'emb',ARRAY[1,2]::float8[],ARRAY['(0,1)'],1)
hybrid null col	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44',NULL,ARRAY[1,2]::float8[],ARRAY['(0,1)'],1)
hybrid null q	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',NULL,ARRAY['(0,1)'],1)
hybrid null ids	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],NULL,1)
hybrid null k	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY['(0,1)'],NULL)
hybrid k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY['(0,1)'],0)
hybrid bad ctid	E:fractalsql: doc_ids cohort matched no rows in bt_g44.emb	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY['zzz'],1)
hybrid empty ids	E:fractalsql: doc_ids must be a 1-D non-null text[] of ctid strings	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],'{}'::text[],1)
hybrid null id elem	E:fractalsql: doc_ids must be a 1-D non-null text[] of ctid strings	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY[NULL]::text[],1)
hybrid no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_hybrid_clinical_search('bt_nope','emb',ARRAY[1,2]::float8[],ARRAY['(0,1)'],1)
hybrid ok	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[0.1,0.2]::float8[],ARRAY['(0,1)','(0,2)'],2)
traj_search null tbl	OK	SELECT * FROM fractal_search_trajectory(NULL,'emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],1)
traj_search null col	OK	SELECT * FROM fractal_search_trajectory('bt_g44',NULL,ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],1)
traj_search null base	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',NULL::float8[],ARRAY[1,2]::float8[],1)
traj_search null cur	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[1,2]::float8[],NULL::float8[],1)
traj_search null k	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],NULL)
traj_search k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],0)
traj_search dim mismatch	E:fractalsql: baseline_vector dim (2) must match current_vector dim (3)	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[1,2]::float8[],ARRAY[1,2,3]::float8[],1)
traj_search no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_search_trajectory('bt_nope','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],1)
traj_search ok	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
traj_search_fv null tbl	OK	SELECT * FROM fractal_search_trajectory(NULL,'emb','[1,2]'::fractal_vector,'[1,2]'::fractal_vector,1)
traj_search_fv null base	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb',NULL::fractal_vector,'[1,2]'::fractal_vector,1)
traj_search_fv k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_search_trajectory('bt_g44','emb','[1,2]'::fractal_vector,'[1,2]'::fractal_vector,0)
traj_search_fv ok	OK	SELECT * FROM fractal_search_trajectory('bt_g44','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2]'::fractal_vector,2)
cross null tbl	OK	SELECT * FROM fractal_cross_modal_search(NULL,'emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],0.5,1)
cross null m	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',NULL::float8[],ARRAY[1,2]::float8[],0.5,1)
cross null c	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],NULL::float8[],0.5,1)
cross null alpha	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],NULL,1)
cross alpha lo	E:fractalsql: alpha_weight must be in [0,1]	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],-0.1,1)
cross alpha hi	E:fractalsql: alpha_weight must be in [0,1]	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],1.1,1)
cross k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2]::float8[],0.5,0)
cross dim mismatch	E:fractalsql: bt_g44x.emb row 0 has dim 4, expected 5 (match the query)	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[1,2]::float8[],ARRAY[1,2,3]::float8[],0.5,1)
cross ok	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],0.5,2)
cross_fv null tbl	OK	SELECT * FROM fractal_cross_modal_search(NULL,'emb','[1,2]'::fractal_vector,'[1,2]'::fractal_vector,0.5,1)
cross_fv alpha	E:fractalsql: alpha_weight must be in [0,1]	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb','[1,2]'::fractal_vector,'[1,2]'::fractal_vector,2.0,1)
cross_fv ok	OK	SELECT * FROM fractal_cross_modal_search('bt_g44x','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2]'::fractal_vector,0.5,2)
explore bad col	E:column "nope" does not exist	SELECT * FROM fractal_search_explore('bt_g44','nope',ARRAY[1,2]::float8[])
explore no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_search_explore('bt_nope','emb',ARRAY[1,2]::float8[])
explore bad opts	OK	SELECT * FROM fractal_search_explore('bt_g44','emb',ARRAY[1,2]::float8[],'[1]'::jsonb)
explore pop	E:fractalsql: population_size 0 out of range [1, 100000]	SELECT * FROM fractal_search_explore('bt_g44','emb',ARRAY[1,2]::float8[],'{"population_size":0}')
explore ok	OK	SELECT * FROM fractal_search_explore('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{"iterations":3,"population_size":5}')
explore str opt	OK	SELECT * FROM fractal_search_explore('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{"iterations":"x"}')
search iter 0	E:fractalsql: iterations 0 out of range [1, 10000]	SELECT fractal_search(ARRAY[1,2]::float8[],0)
search pop 0	E:fractalsql: population_size 0 out of range [1, 100000]	SELECT fractal_search(ARRAY[1,2]::float8[],5,0)
search empty	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_search('{}'::float8[])
search_dbg diff	E:fractalsql: diffusion_factor 99 out of range [1, 32]	SELECT fractal_search_debug(ARRAY[1,2]::float8[],5,5,99)
embed null	E:fractal_embed: input must not be NULL	SELECT fractal_embed(NULL)
embed empty	E:fractal_embed: dispatch failed (rc=-1): fractalsql: invalid arguments 	SELECT fractal_embed('')
schema bad tbl	E:fractal_schema_context: table "bt_nope" not found or not visible	SELECT fractal_schema_context(ARRAY['bt_nope'])
schema empty arr	E:fractal_schema_context: no visible tables found	SELECT fractal_schema_context('{}'::text[])
schema null elem	E:fractal_schema_context: no visible tables found	SELECT fractal_schema_context(ARRAY[NULL]::text[])
schema hint	OK	SELECT length(fractal_schema_context(ARRAY['bt_g44'],'embedding'))>0
t2s null tables elem	E:fractal_schema_context: no visible tables found	SELECT fractal_text_to_sql('q',ARRAY[NULL]::text[])
getcfg unknown	E:fractalsql_get_config: unknown config key "nope"	SELECT fractalsql_get_config('nope')
getcfg secret	OK	SELECT fractalsql_get_config('enterprise_ledger_key')
getcfg prefixed	OK	SELECT fractalsql_get_config('fractalsql.http_url')
getcfg null	E:fractalsql_get_config: the key must not be NULL	SELECT fractalsql_get_config(NULL)
getcfg all keys	OK	SELECT k,fractalsql_get_config(k) FROM unnest(ARRAY['reasoning_plugin','http_url','http_model','http_allow_plaintext','http_embed_url','http_embed_model','http_think','http_think_provider','http_native_url','http_num_ctx','text_to_sql_max_attempts','text_to_sql_allowed_statements','text_to_sql_use_review','enterprise_lib','enterprise_require_signature','agent_partial_reasoning_fail']) k
setcfg unknown	E:fractalsql_set_config: unknown config key "nope"	SELECT fractalsql_set_config('nope','x')
setcfg null val	E:fractalsql_set_config: the value must not be NULL	SELECT fractalsql_set_config('agent_partial_reasoning_fail',NULL)
setcfg bad bool	E:fractalsql_set_config: "agent_partial_reasoning_fail" expects a boolea	SELECT fractalsql_set_config('agent_partial_reasoning_fail','maybe')
setcfg ok	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','on')
setcfg reload	E:fractalsql_set_config: "fractalsql.http_url" is reload-scoped and cann	SELECT fractalsql_set_config('http_url','http://x')
setcfg secret	NONE	SELECT fractalsql_set_config('enterprise_ledger_key','abc')
setcfg max_attempts bad	E:fractalsql_set_config: "text_to_sql_max_attempts" expects an integer	SELECT fractalsql_set_config('text_to_sql_max_attempts','abc')
setcfg prefixed	OK	SELECT fractalsql_set_config('fractalsql.agent_partial_reasoning_fail','off')
ledger verify kind	OK	SELECT fractal_ledger_verify(3)
ledger verify null	OK	SELECT fractal_ledger_verify(NULL)
ledger verify 1	OK	SELECT fractal_ledger_verify(1)
ledger verify 2	OK	SELECT fractal_ledger_verify(2)
diversify bad win	E:fractalsql: fsql_diversify_set_params rc=-1:	SELECT fractal_diversify_set_params(-1)
diversify bad stall	E:fractalsql: fsql_diversify_set_params rc=-1:	SELECT fractal_diversify_set_params(NULL,-1.0)
diversify bad sigma	OK	SELECT fractal_diversify_set_params(NULL,NULL,0.0)
diversify bad weight	E:fractalsql: fsql_diversify_set_params rc=-1:	SELECT fractal_diversify_set_params(NULL,NULL,NULL,-1.0)
feedback bad kind	E:fractalsql: kind must be one of 'dwell', 'positive', 'negative' (got '	SELECT fractal_feedback_report(1,'bogus')
feedback null	E:fractalsql: kind must be one of 'dwell', 'positive', 'negative' (got '	SELECT fractal_feedback_report(NULL,'click')
feedback dwell	OK	SELECT fractal_feedback_report(1,'dwell',-5)
feedback ok	E:fractalsql: kind must be one of 'dwell', 'positive', 'negative' (got '	SELECT fractal_feedback_report(1,'click')
isolate null	OK	SELECT fractal_isolate_background(NULL)
isolate bad	E:fractalsql: result_handle must be >= 0	SELECT fractal_isolate_background(-1)
explain	OK	SELECT fractal_explain_result()
collapse	OK	SELECT fractal_detect_collapse()
vec from_text bad	E:fractal_vector_from_text: could not parse "abc" as a vector: invalid i	SELECT fractal_vector_from_text('abc')
vec from_text empty	E:fractal_vector_from_text: could not parse "[]" as a vector array: frac	SELECT fractal_vector_from_text('[]')
vec from_text nan	OK	SELECT fractal_vector_from_text('[NaN,1]')
vec from_array null elem	E:fractal_vector: source float8[] must be 1-D non-null	SELECT fractal_vector_from_float8_array(ARRAY[1,NULL]::float8[])
vec from_array empty	E:fractal_vector: source float8[] must be 1-D non-null	SELECT fractal_vector_from_float8_array('{}'::float8[])
vec dim mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_l2_distance('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec add mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_add('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec sub mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_sub('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec cos mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_cosine_distance('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec cos zero	OK	SELECT fractal_vector_cosine_distance('[0,0]'::fractal_vector,'[1,2]'::fractal_vector)
vec cossim zero	OK	SELECT fractal_vector_cosine_similarity('[0,0]'::fractal_vector,'[0,0]'::fractal_vector)
vec ip mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_negative_inner_product('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec l2sq mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_l2_squared('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector)
vec lp p0	E:fractal_vector_lp_distance: p must be > 0	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[1,2]'::fractal_vector,0)
vec lp mismatch	E:fractal_vector: dimension mismatch (2 vs 3)	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[1,2,3]'::fractal_vector,2)
vec lp inf	OK	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[3,5]'::fractal_vector,'Infinity')
vec lp 1	OK	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[3,5]'::fractal_vector,1)
vec lp 3	OK	SELECT fractal_vector_lp_distance('[1,2]'::fractal_vector,'[3,5]'::fractal_vector,3)
vec normalize zero	OK	SELECT fractal_vector_normalize('[0,0]'::fractal_vector)
vec scale nan	OK	SELECT fractal_vector_scale('[1,2]'::fractal_vector,'NaN')
vec scale inf	OK	SELECT fractal_vector_scale('[1,2]'::fractal_vector,'Infinity')
vec typmod bad	E:fractal_vector dimension mismatch: column is fractal_vector(3), value 	SELECT '[1,2]'::fractal_vector(3)
vec typmod zero	E:fractal_vector dimension must be between 1 and 32767, got 0	SELECT '[1,2]'::fractal_vector(0)
vec typmod huge	E:fractal_vector dimension must be between 1 and 32767, got 100000	SELECT '[1,2]'::fractal_vector(100000)
vec typmod ok	OK	SELECT '[1,2]'::fractal_vector(2)
vec cast explicit	E:fractal_vector dimension mismatch: column is fractal_vector(3), value 	SELECT fractal_vector('[1,2]'::fractal_vector,3,true)
vec quant zero	OK	SELECT fractal_vector_quantize_int8('[0,0]'::fractal_vector)
vec quant ok	OK	SELECT fractal_vector_quantize_int8('[0.5,-1]'::fractal_vector)
vec hamming empty	E:fractal_vector_hamming_distance rc=-1	SELECT fractal_vector_hamming_distance('\x'::bytea,'\x'::bytea)
vec to_json	OK	SELECT fractal_vector_to_json('[1,2]'::fractal_vector)
vec recv send	OK	SELECT fractal_vector_send('[1,2]'::fractal_vector)
vec in bad bracket	E:fractal_vector: expected '[' at start of "1,2"	SELECT '1,2'::fractal_vector
vec in trailing	E:fractal_vector: unexpected trailing data in "[1,2]x"	SELECT '[1,2]x'::fractal_vector
vec in dims big	OK	SELECT fractal_vector_dims(('['||(SELECT string_agg('1',',') FROM generate_series(1,17000))||']')::fractal_vector)
vec in too long	E:fractal_vector: dimension exceeds maximum 32767	SELECT ('['||(SELECT string_agg('1',',') FROM generate_series(1,100000))||']')::fractal_vector
vec typmod_in bad	E:fractal_vector: invalid dimension "abc"	SELECT 'x'::fractal_vector(abc)
vec in leading ws	OK	SELECT '   [1,2]'::fractal_vector
vec in inner ws	OK	SELECT '[ 1 , 2 ]   '::fractal_vector
vec in empty	E:fractal_vector dimension must be between 1 and 32767, got 0	SELECT '[]'::fractal_vector
vec in empty ws	E:fractal_vector dimension must be between 1 and 32767, got 0	SELECT '[  ]'::fractal_vector
vec in blank	E:fractal_vector: expected '[' at start of "   "	SELECT '   '::fractal_vector
vec in empty str	E:fractal_vector: expected '[' at start of ""	SELECT ''::fractal_vector
vec in bad number	E:fractal_vector: invalid number in "[1,abc]"	SELECT '[1,abc]'::fractal_vector
vec in trailing comma	E:fractal_vector: invalid number in "[1,]"	SELECT '[1,]'::fractal_vector
vec in no close	E:fractal_vector: expected ']' in "[1,2"	SELECT '[1,2'::fractal_vector
vec in no close ws	E:fractal_vector: expected ']' in "[1 2]"	SELECT '[1 2]'::fractal_vector
vec in 64 elems	OK	SELECT fractal_vector_dims(('['||(SELECT string_agg('1',',') FROM generate_series(1,64))||']')::fractal_vector)
vec in 65 elems	OK	SELECT fractal_vector_dims(('['||(SELECT string_agg('1',',') FROM generate_series(1,65))||']')::fractal_vector)
vec in 200 elems	OK	SELECT fractal_vector_dims(('['||(SELECT string_agg('1',',') FROM generate_series(1,200))||']')::fractal_vector)
vec in exp inf	NONE	SELECT '[1e999,-1e999]'::fractal_vector
vec typmod two args	E:fractal_vector typmod takes exactly one non-NULL parameter	SELECT '[1,2]'::fractal_vector(1,2)
vec typmod junk	E:fractal_vector: invalid dimension "2x"	SELECT '[1,2]'::fractal_vector('2x')
vec typmod empty str	E:fractal_vector: invalid dimension ""	SELECT '[1,2]'::fractal_vector('')
vec typmod negative	E:fractal_vector dimension must be between 1 and 32767, got -1	SELECT '[1,2]'::fractal_vector(-1)
vec typmod null	NONE	SELECT '[1,2]'::fractal_vector(NULL)
vec hamming long eq	OK	SELECT fractal_vector_hamming_distance(decode(repeat('ab',200),'hex'),decode(repeat('ab',200),'hex'))
vec hamming long diff	OK	SELECT fractal_vector_hamming_distance(decode(repeat('ab',200),'hex'),decode(repeat('ba',200),'hex'))
vec hamming long mismatch	E:fractal_vector_hamming_distance: length mismatch (200 vs 201 bytes)	SELECT fractal_vector_hamming_distance(decode(repeat('ab',200),'hex'),decode(repeat('ab',201),'hex'))
vec hamming short vs long	E:fractal_vector_hamming_distance: length mismatch (1 vs 200 bytes)	SELECT fractal_vector_hamming_distance('\x01'::bytea,decode(repeat('ab',200),'hex'))
vec hamming long vs short	E:fractal_vector_hamming_distance: length mismatch (200 vs 1 bytes)	SELECT fractal_vector_hamming_distance(decode(repeat('ab',200),'hex'),'\x01'::bytea)
vec quant binary long	OK	SELECT length(fractal_vector_quantize_binary(('['||(SELECT string_agg(((i%2)*2-1)::text,',') FROM generate_series(1,1100) i)||']')::fractal_vector))
vec quant int8 long	OK	SELECT (fractal_vector_quantize_int8(('['||(SELECT string_agg((i-70)::text,',') FROM generate_series(1,140) i)||']')::fractal_vector)).scale
vectorizer create no table	E:relation "bt_nope" does not exist	SELECT fractal_vectorizer_create('bt_nope','t','e')
vectorizer create no col	E:column "nope" of relation "bt_g44e" does not exist	SELECT fractal_vectorizer_create('bt_g44e','nope','emb')
vectorizer pause missing	E:fractal_vectorizer_pause: no vectorizer with id 999999	SELECT fractal_vectorizer_pause(999999)
vectorizer resume missing	E:fractal_vectorizer_resume: no vectorizer with id 999999	SELECT fractal_vectorizer_resume(999999)
vectorizer drop missing	E:fractal_vectorizer_drop: no vectorizer with id 999999	SELECT fractal_vectorizer_drop(999999)
vectorizer null	E:fractal_vectorizer_pause: no vectorizer with id <NULL>	SELECT fractal_vectorizer_pause(NULL)
vectorizer queue 0	OK	SELECT fractal_vectorizer_process_queue(0)
vectorizer queue neg	E:LIMIT must not be negative	SELECT fractal_vectorizer_process_queue(-1)
rag ok	OK	SELECT count(*)>=0 FROM fractal_rag_agent('q','bt_g44e','emb')
rag meta filter	OK	SELECT count(*)>=0 FROM fractal_rag_agent('q','bt_g44e','emb','{"id":1}')
search_agent ok	OK	SELECT count(*)>=0 FROM fractal_search_agent('q','bt_g44e','emb')
search_agent small	E:fractalsql: search failed	SELECT count(*)>=0 FROM fractal_search_agent('q','bt_g44e','emb',1,1)
plan ok	OK	SELECT count(*) FROM fractal_agent_plan_explore('q','bt_g44e','emb',2)
plan no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_agent_plan_explore('q','bt_nope','emb',2)
plan no col	E:column "nope" does not exist	SELECT * FROM fractal_agent_plan_explore('q','bt_g44e','nope',2)
traj ok	OK	SELECT predicted_state_vector IS NOT NULL FROM fractal_agent_trajectory_predict('bt_g44e','emb',1,2)
embed ok	OK	SELECT array_length(fractal_embed('hello'),1)
embed huge	E:fractal_embed: input exceeds the 4 MiB limit	SELECT fractal_embed(repeat('A', 4*1024*1024 + 1))
vectorizer create ok	OK	SELECT fractal_vectorizer_create('bt_g44e','txt','emb')
cycle empty elems	E:fractalsql: fsql_cycle_detect_init rc=-1	SELECT * FROM fractal_cycle_detect(ARRAY['\x','\x']::bytea[])
cycle thresh huge	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x01']::bytea[],100000)
cycle long ok	OK	SELECT * FROM fractal_cycle_detect(ARRAY[decode(repeat('ab',200),'hex'),decode(repeat('ab',200),'hex'),decode(repeat('ab',200),'hex'),decode(repeat('ab',200),'hex')]::bytea[])
cycle long mismatch	E:fractalsql: every fingerprint must be the same length (index 0 was 200	SELECT * FROM fractal_cycle_detect(ARRAY[decode(repeat('ab',200),'hex'),decode(repeat('ab',201),'hex')]::bytea[])
cycle first null	E:fractalsql: fingerprints array must not contain NULLs	SELECT * FROM fractal_cycle_detect(ARRAY[NULL,'\x01']::bytea[])
cycle long null	E:fractalsql: fingerprints array must not contain NULLs	SELECT * FROM fractal_cycle_detect(ARRAY[decode(repeat('ab',200),'hex'),NULL]::bytea[])
cycle short mismatch long	E:fractalsql: every fingerprint must be the same length (index 0 was 1 b	SELECT * FROM fractal_cycle_detect(ARRAY['\x01',decode(repeat('ab',200),'hex')]::bytea[])
cycle abab	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x010203','\x040506','\x010203','\x040506','\x010203','\x040506','\x010203','\x040506']::bytea[])
cycle thresh near	OK	SELECT * FROM fractal_cycle_detect(ARRAY['\x00','\x01','\x00','\x01','\x00','\x01']::bytea[],4)
loop one state	E:fractalsql: state_log must contain at least 2 states	SELECT * FROM fractal_agent_detect_loop('a',ARRAY[1,2]::float8[],2)
loop repeating	OK	SELECT * FROM fractal_agent_detect_loop('a',(SELECT array_agg(v) FROM (SELECT CASE WHEN i%2=0 THEN 1.0 ELSE 2.0 END AS v FROM generate_series(1,80) i) s),2)
loop wander	OK	SELECT * FROM fractal_agent_detect_loop('a',(SELECT array_agg(sin(i*1.7)+i*0.05) FROM generate_series(1,96) i),2)
loop thresh	OK	SELECT * FROM fractal_agent_detect_loop('a',(SELECT array_agg(sin(i*1.3)) FROM generate_series(1,64) i),4,64,1.0,8)
setcfg http_num_ctx=abc	E:fractalsql_set_config: "http_num_ctx" expects an integer	SELECT fractalsql_set_config('http_num_ctx','abc')
setcfg http_num_ctx=99999999999999999999	E:fractalsql_set_config: "http_num_ctx" expects an integer	SELECT fractalsql_set_config('http_num_ctx','99999999999999999999')
setcfg http_num_ctx=-5	E:fractalsql_set_config: "http_num_ctx" must be between 0 and 1048576	SELECT fractalsql_set_config('http_num_ctx','-5')
setcfg http_num_ctx=2000000	E:fractalsql_set_config: "http_num_ctx" must be between 0 and 1048576	SELECT fractalsql_set_config('http_num_ctx','2000000')
setcfg http_num_ctx=4096	E:fractalsql_set_config: "fractalsql.http_num_ctx" is reload-scoped and 	SELECT fractalsql_set_config('http_num_ctx','4096')
setcfg text_to_sql_max_attempts=0	E:fractalsql_set_config: "text_to_sql_max_attempts" must be between 1 an	SELECT fractalsql_set_config('text_to_sql_max_attempts','0')
setcfg text_to_sql_max_attempts=11	E:fractalsql_set_config: "text_to_sql_max_attempts" must be between 1 an	SELECT fractalsql_set_config('text_to_sql_max_attempts','11')
setcfg text_to_sql_max_attempts=3x	E:fractalsql_set_config: "text_to_sql_max_attempts" expects an integer	SELECT fractalsql_set_config('text_to_sql_max_attempts','3x')
setcfg text_to_sql_max_attempts=3	E:fractalsql_set_config: "fractalsql.text_to_sql_max_attempts" is reload	SELECT fractalsql_set_config('text_to_sql_max_attempts','3')
setcfg text_to_sql_allowed_statements=bogus	E:fractalsql_set_config: "text_to_sql_allowed_statements" must be one of	SELECT fractalsql_set_config('text_to_sql_allowed_statements','bogus')
setcfg text_to_sql_allowed_statements=select	E:fractalsql_set_config: "fractalsql.text_to_sql_allowed_statements" is 	SELECT fractalsql_set_config('text_to_sql_allowed_statements','select')
setcfg text_to_sql_allowed_statements=select_insert_update	E:fractalsql_set_config: "fractalsql.text_to_sql_allowed_statements" is 	SELECT fractalsql_set_config('text_to_sql_allowed_statements','select_insert_update')
setcfg text_to_sql_use_review=maybe	E:fractalsql_set_config: "text_to_sql_use_review" expects a boolean	SELECT fractalsql_set_config('text_to_sql_use_review','maybe')
setcfg text_to_sql_use_review=on	E:fractalsql_set_config: "fractalsql.text_to_sql_use_review" is reload-s	SELECT fractalsql_set_config('text_to_sql_use_review','on')
setcfg http_allow_plaintext=no	E:fractalsql_set_config: "fractalsql.http_allow_plaintext" is reload-sco	SELECT fractalsql_set_config('http_allow_plaintext','no')
setcfg http_allow_plaintext=y	E:fractalsql_set_config: "fractalsql.http_allow_plaintext" is reload-sco	SELECT fractalsql_set_config('http_allow_plaintext','y')
setcfg too long	E:fractalsql_set_config: "http_url" is too long	SELECT fractalsql_set_config('http_url',repeat('x',9000))
setcfg upper key	E:fractalsql_set_config: "fractalsql.http_url" is reload-scoped and cann	SELECT fractalsql_set_config('FractalSQL.HTTP_URL','http://x')
setcfg long key	E:fractalsql_set_config: unknown config key "kkkkkkkkkkkkkkkkkkkkkkkkkkk	SELECT fractalsql_set_config(repeat('k',200),'x')
setcfg bool on	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','on')
setcfg bool 1	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','1')
setcfg bool true	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','true')
setcfg bool yes	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','yes')
setcfg bool t	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','t')
setcfg bool y	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','y')
setcfg bool TRUE	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','TRUE')
setcfg bool off	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','off')
setcfg bool 0	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','0')
setcfg bool false	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','false')
setcfg bool no	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','no')
setcfg bool f	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','f')
setcfg bool n	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','n')
setcfg bool Off	OK	SELECT fractalsql_set_config('agent_partial_reasoning_fail','Off')
getcfg reasoning_plugin	OK	SELECT fractalsql_get_config('reasoning_plugin')
getcfg http_model	OK	SELECT fractalsql_get_config('http_model')
getcfg http_embed_url	OK	SELECT fractalsql_get_config('http_embed_url')
getcfg http_think	OK	SELECT fractalsql_get_config('http_think')
getcfg enterprise_lib	OK	SELECT fractalsql_get_config('enterprise_lib')
getcfg http_token	OK	SELECT fractalsql_get_config('http_token')
telemetry empty	E:fractalsql: no corpus rows to search	SELECT * FROM fractal_search_telemetry('bt_g44z','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid empty	E:fractalsql: doc_ids cohort matched no rows in bt_g44z.emb	SELECT * FROM fractal_hybrid_clinical_search('bt_g44z','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44z),ARRAY['(0,1)']),2)
explore empty	E:fractalsql: bt_g44z.emb has no rows to explore	SELECT count(*) FROM fractal_search_explore('bt_g44z','emb',ARRAY[0.1,0.2]::float8[])
traj_search empty	E:fractalsql: no corpus rows to search	SELECT * FROM fractal_search_trajectory('bt_g44z','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross empty	E:fractalsql: no corpus rows to search	SELECT * FROM fractal_cross_modal_search('bt_g44z','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
telemetry null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_search_telemetry('bt_g44n','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid null vec	E:fractalsql: NULL vector at cohort row 0	SELECT * FROM fractal_hybrid_clinical_search('bt_g44n','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44n),ARRAY['(0,1)']),2)
explore null vec	E:fractalsql: NULL vector at row 0	SELECT count(*) FROM fractal_search_explore('bt_g44n','emb',ARRAY[0.1,0.2]::float8[])
traj_search null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_search_trajectory('bt_g44n','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_cross_modal_search('bt_g44n','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
telemetry ragged dims	E:fractalsql: bt_g44d.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_search_telemetry('bt_g44d','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid ragged dims	E:fractalsql: bt_g44d.emb cohort row 1 has dim 3, expected 2 (match the 	SELECT * FROM fractal_hybrid_clinical_search('bt_g44d','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44d),ARRAY['(0,1)']),2)
explore ragged dims	E:fractalsql: bt_g44d.emb row 1 has dim 3, expected 2 (match the query)	SELECT count(*) FROM fractal_search_explore('bt_g44d','emb',ARRAY[0.1,0.2]::float8[])
traj_search ragged dims	E:fractalsql: bt_g44d.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_search_trajectory('bt_g44d','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross ragged dims	E:fractalsql: bt_g44d.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_cross_modal_search('bt_g44d','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
telemetry text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_search_telemetry('bt_g44t','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid text col	E:fractalsql: query must be 1-D non-null float8[]	SELECT * FROM fractal_hybrid_clinical_search('bt_g44t','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44t),ARRAY['(0,1)']),2)
explore text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT count(*) FROM fractal_search_explore('bt_g44t','emb',ARRAY[0.1,0.2]::float8[])
traj_search text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_search_trajectory('bt_g44t','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_cross_modal_search('bt_g44t','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
telemetry mixed fvec dims	E:fractalsql: bt_g44w.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_search_telemetry('bt_g44w','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid mixed fvec dims	E:fractalsql: bt_g44w.emb cohort row 1 has dim 3, expected 2 (match the 	SELECT * FROM fractal_hybrid_clinical_search('bt_g44w','emb',ARRAY[0.1,0.2]::float8[],COALESCE((SELECT array_agg(ctid::text) FROM bt_g44w),ARRAY['(0,1)']),2)
explore mixed fvec dims	E:fractalsql: bt_g44w.emb row 1 has dim 3, expected 2 (match the query)	SELECT count(*) FROM fractal_search_explore('bt_g44w','emb',ARRAY[0.1,0.2]::float8[])
traj_search mixed fvec dims	E:fractalsql: bt_g44w.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_search_trajectory('bt_g44w','emb',ARRAY[0.1,0.2]::float8[],ARRAY[0.3,0.2]::float8[],2)
cross mixed fvec dims	E:fractalsql: bt_g44w.emb row 1 has dim 3, expected 2 (match the query)	SELECT * FROM fractal_cross_modal_search('bt_g44w','emb',ARRAY[0.1]::float8[],ARRAY[0.2]::float8[],0.5,2)
search_agent empty	E:fractalsql: no rows found in bt_g44z.emb	SELECT * FROM fractal_search_agent('q','bt_g44z','emb')
rag empty	E:fractalsql: no rows found in bt_g44z.emb	SELECT * FROM fractal_rag_agent('q','bt_g44z','emb')
plan empty	E:fractalsql: no rows found in bt_g44z.emb	SELECT * FROM fractal_agent_plan_explore('q','bt_g44z','emb',2)
search_agent null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_search_agent('q','bt_g44n','emb')
rag null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_rag_agent('q','bt_g44n','emb')
plan null vec	E:fractalsql: NULL vector at row 0	SELECT * FROM fractal_agent_plan_explore('q','bt_g44n','emb',2)
search_agent ragged dims	E:fractalsql: bt_g44d.emb row 0 has dim 2, expected 3 (match the query)	SELECT * FROM fractal_search_agent('q','bt_g44d','emb')
rag ragged dims	E:fractalsql: bt_g44d.emb row 0 has dim 2, expected 3 (match the query)	SELECT * FROM fractal_rag_agent('q','bt_g44d','emb')
plan ragged dims	E:fractalsql: bt_g44d.emb row 0 has dim 2, expected 3 (match the query)	SELECT * FROM fractal_agent_plan_explore('q','bt_g44d','emb',2)
search_agent text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_search_agent('q','bt_g44t','emb')
rag text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_rag_agent('q','bt_g44t','emb')
plan text col	E:fractalsql: bt_g44t.emb vector_col must be float8[] or fractal_vector,	SELECT * FROM fractal_agent_plan_explore('q','bt_g44t','emb',2)
telemetry fvec	OK	SELECT * FROM fractal_search_telemetry('bt_g44v','emb',ARRAY[0.1,0.2]::float8[],2)
hybrid fvec	OK	SELECT * FROM fractal_hybrid_clinical_search('bt_g44v','emb',ARRAY[0.1,0.2]::float8[],(SELECT array_agg(ctid::text) FROM bt_g44v),2)
explore fvec	OK	SELECT count(*) FROM fractal_search_explore('bt_g44v','emb',ARRAY[0.1,0.2]::float8[])
explore mmr low	OK	SELECT count(*) FROM fractal_search_explore('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{"mmr_lambda":-1}')
explore mmr high	OK	SELECT count(*) FROM fractal_search_explore('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{"mmr_lambda":2}')
traj baseline null	E:fractal_agent_trajectory_predict: baseline vector is NULL	SELECT * FROM fractal_agent_trajectory_predict('bt_g44n','emb',1,2)
traj current null	E:fractal_agent_trajectory_predict: current vector is NULL	SELECT * FROM fractal_agent_trajectory_predict('bt_g44n','emb',2,2)
traj dim mismatch	E:fractal_agent_trajectory_predict: baseline dim 2 != current dim 3	SELECT * FROM fractal_agent_trajectory_predict('bt_g44d','emb',1,2)
traj empty table	E:fractal_agent_trajectory_predict: no row in bt_g44z with id = 1	SELECT * FROM fractal_agent_trajectory_predict('bt_g44z','emb',1,2)
traj no table	E:relation "bt_nope" does not exist	SELECT * FROM fractal_agent_trajectory_predict('bt_nope','emb',1,2)
traj fvec	OK	SELECT * FROM fractal_agent_trajectory_predict('bt_g44v','emb',1,2)
traj fvec mixed	E:fractal_agent_trajectory_predict: baseline dim 2 != current dim 3	SELECT * FROM fractal_agent_trajectory_predict('bt_g44w','emb',1,2)
mine ok	OK	SELECT * FROM fractal_mine_topology_negatives(ARRAY[0.1,0.2]::float8[],2)
store_morph ok	OK	SELECT fractal_store_morphology(1,ARRAY[0.1,0.2]::float8[])
mine after store	OK	SELECT * FROM fractal_mine_topology_negatives(ARRAY[0.1,0.2]::float8[],2)
mine dim differs	OK	SELECT * FROM fractal_mine_topology_negatives(ARRAY[0.1,0.2,0.3]::float8[],2)
store_morph null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_store_morphology(2,ARRAY[0.1,NULL]::float8[])
store_morph neg	E:fractalsql: doc_id must be >= 0	SELECT fractal_store_morphology(-1,ARRAY[0.1,0.2]::float8[])
@mock		
sql_agent null q	E:fractal_sql_agent: question must not be NULL	SELECT * FROM fractal_sql_agent(NULL)
sql_agent neg retries	E:fractal_sql_agent: max_retries must be >= 1 (got -1)	SELECT * FROM fractal_sql_agent('q',NULL,-1)
sql_agent ok	NONE	SELECT * FROM fractal_sql_agent('q')
vascular 2d edges	E:fractalsql: index array must be 1-D non-null int4[]	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[[0,1],[1,0]]::int4[],ARRAY[1.0,1.0]::float8[])
vascular null elem edges	E:fractalsql: index array must be 1-D non-null int4[]	SELECT fractal_vascular_network(ARRAY[0,0,0,1,0,0]::float8[],ARRAY[0,NULL]::int4[],ARRAY[1.0]::float8[])
nerve 2d edges	E:fractalsql: index array must be 1-D non-null int4[]	SELECT fractal_nerve_plexus_metric(ARRAY[0,0,1,0]::float8[],2,ARRAY[[0,1],[1,0]]::int4[])
feedback neg handle	E:fractalsql: result_handle must be >= 0	SELECT fractal_feedback_report(-1,'positive')
isolate neg handle	NONE	SELECT fractal_isolate_background(-1)
diversify dq	OK	SELECT fractal_diversify_current_dq()
diversify p99	OK	SELECT fractal_diversify_overhead_p99_us()
hybrid 2d ids	E:fractalsql: doc_ids must be a 1-D non-null text[]	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[0.1,0.2]::float8[],ARRAY[['(0,1)','(0,2)'],['(0,3)','(0,4)']],2)
hybrid null elem ids	E:fractalsql: doc_ids must be a 1-D non-null text[]	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[0.1,0.2]::float8[],ARRAY['(0,1)',NULL],2)
hybrid empty ids	E:fractalsql: doc_ids must be a 1-D non-null text[]	SELECT * FROM fractal_hybrid_clinical_search('bt_g44','emb',ARRAY[0.1,0.2]::float8[],'{}'::text[],2)
trajectory fv k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_search_trajectory('bt_g44v','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2]'::fractal_vector,0)
trajectory fv dims	E:fractalsql: baseline_vector dim (2) must match current_vector dim (3)	SELECT * FROM fractal_search_trajectory('bt_g44v','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2,0.1]'::fractal_vector,2)
cross fv k 0	E:fractalsql: k must be > 0	SELECT * FROM fractal_cross_modal_search('bt_g44v','emb','[0.1,0.2]'::fractal_vector,'[0.3,0.2]'::fractal_vector,0.5,0)
agent trajectory text col	NONE	SELECT * FROM fractal_agent_trajectory_predict('bt_g44t','emb',1,3)
'@
    SqlTableRun '44' $rows
    $n = $script:TblN; $bad = $script:TblBad
    if ($bad -eq 0) { Pass "44 error_paths: all $n argument-validation / error-path / NULL-argument calls behaved as specified (no backend crash)" }

    Psql -Sql "SELECT fractal_vectorizer_drop(v.id) FROM fractal_vectorizers v WHERE v.source_table = 'bt_g44e';" | Out-Null
    Psql -Sql "DROP TABLE IF EXISTS bt_g44, bt_g44x, bt_g44e, bt_g44n, bt_g44d, bt_g44z, bt_g44t, bt_g44v, bt_g44w; DELETE FROM fractalsql_feature_store;" | Out-Null
    PgSwapPlugin $Mock | Out-Null
}

# Gate 45: enterprise-tier paths driven through tests\mock_enterprise_core.c --
# see build_test.sh's gate_45_enterprise_paths for the full rationale
# (validation behind the tier check, and the ledger-tip authentication that
# fractal_ledger_load() runs before handing the chain to the core).
function Gate45EnterprisePaths {
    $mockSo = Join-Path $env:TEMP "fractalsql_bt_g45_ent_$PgMajor.dll"
    Remove-Item -Force $mockSo, "$mockSo.sig" -ErrorAction SilentlyContinue
    $obj = [System.IO.Path]::ChangeExtension($mockSo, '.obj')
    $src = Join-Path $RepoRoot 'tests\mock_enterprise_core.c'
    $inc = Join-Path $RepoRoot 'include'
    $buildOut = & cl.exe /nologo /MT /LD /DFSQL_BUILDING_DLL "/I$inc" $src "/Fo$obj" "/Fe$mockSo" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $mockSo)) {
        Fail "45 enterprise_paths: mock .dll failed to build"
        Write-Host ($buildOut -join "`n")
        return
    }
    Psql -Sql "ALTER SYSTEM SET fractalsql.enterprise_require_signature = off;" | Out-Null
    if (-not (PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$mockSo'" -Want $mockSo)) {
        Fail "45 enterprise_paths: could not point enterprise_lib at the mock"
        Remove-Item -Force $mockSo -ErrorAction SilentlyContinue
        return
    }

    # ---- (a) argument validation behind the tier check ----
    $rowsA = @'
mm null mu	E:fractalsql: fractal_optimize_portfolio_multimodal: mu must not be NULL	SELECT fractal_optimize_portfolio_multimodal(NULL,ARRAY[1,0,0,1]::float8[],1)
mm null cov	E:fractalsql: fractal_optimize_portfolio_multimodal: cov must not be NUL	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],NULL,1)
mm null k	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],NULL)
mm k 0	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],0)
mm cov len	E:fractalsql: cov length (3) must be n_assets^2 (n_assets=2, expected 4)	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0]::float8[],1)
mm restarts 0	E:fractalsql: n_restarts must satisfy 1 <= n_restarts <= 64	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,0)
mm overlap	NONE	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,2.0)
mm quality	NONE	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,0.1,2.0)
mm bad mode	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'bogus')	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,0.1,0.9,1,false,'bogus')
mm ok	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'cauchy')	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,3,0.15,0.9,5,true,'cauchy')
mm ok nulls	OK	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,NULL,NULL,NULL,NULL,NULL,NULL)
pareto null mu	E:fractalsql: fractal_optimize_portfolio_multimodal_pareto: mu must not 	SELECT fractal_optimize_portfolio_multimodal_pareto(NULL,ARRAY[1,0,0,1]::float8[],1)
pareto null cov	E:fractalsql: fractal_optimize_portfolio_multimodal_pareto: cov must not	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],NULL,1)
pareto null k	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],NULL)
pareto k 0	E:fractalsql: k must satisfy 1 <= k <= n_assets (2)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],0)
pareto cov len	E:fractalsql: cov length (3) must be n_assets^2 (n_assets=2, expected 4)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0]::float8[],1)
pareto restarts 0	E:fractalsql: n_restarts must satisfy 1 <= n_restarts <= 64	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,0)
pareto front 0	E:fractalsql: max_front must satisfy 1 <= max_front <= n_restarts (2)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,0)
pareto front big	E:fractalsql: max_front must satisfy 1 <= max_front <= n_restarts (2)	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,99)
pareto bad mode	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'bogus')	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],1,2,2,1,false,'bogus')
pareto ok	E:fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got 'cauchy')	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,3,3,5,true,'cauchy')
pareto ok nulls	OK	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2,NULL,NULL,NULL,NULL,NULL)
audit_unpack null	OK	SELECT fractal_audit_unpack(NULL)
audit_unpack short	E:invalid input syntax for type json	SELECT fractal_audit_unpack('\x00')
audit_unpack garbage	E:invalid input syntax for type json	SELECT fractal_audit_unpack(decode(repeat('ab',64),'hex'))
audit_log null	E:fractalsql: fractal_audit_log: entry_type and payload must not be NULL	SELECT fractal_audit_log(NULL,'{}')
audit_log null payload	E:fractalsql: fractal_audit_log: entry_type and payload must not be NULL	SELECT fractal_audit_log('x',NULL)
audit_log ok	OK	SELECT fractal_audit_log('g45.test', '{"n":1}'::jsonb)
audit_log big	OK	SELECT fractal_audit_log('g45.test', jsonb_build_object('p', repeat('x', 200000)))
audit_log keyed	OK	SET fractalsql.enterprise_ledger_key = 'g45-key'; SELECT fractal_audit_log('g45.keyed', '{"n":2}'::jsonb)
audit_unpack json	OK	SELECT fractal_audit_unpack(convert_to('{"a":1}', 'UTF8'))
audit_unpack not json	E:invalid input syntax for type json	SELECT fractal_audit_unpack(convert_to('not json', 'UTF8'))
audit_unpack empty	E:invalid input syntax for type json	SELECT fractal_audit_unpack('\x'::bytea)
audit_unpack big	OK	SELECT length(fractal_audit_unpack(convert_to('"' || repeat('x', 300000) || '"', 'UTF8'))::text)
mm ok k=n	OK	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],2)
pareto ok k=n	OK	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2]::float8[],ARRAY[1,0,0,1]::float8[],2)
mm null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,NULL]::float8[],ARRAY[1,0,0,1]::float8[],1)
pareto null elem	E:fractalsql: query must be 1-D non-null float8[]	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,NULL]::float8[],ARRAY[1,0,0,1]::float8[],1)
'@
    SqlTableRun '45' $rowsA
    if ($script:TblBad -eq 0) { Pass "45 enterprise_paths: all $($script:TblN) multimodal / pareto / audit validation calls behaved as specified (mock core loaded)" }

    # ---- (b) ledger tip authentication ----
    # Constraint-free ledger fixture (same shape and index as gate 31's) so
    # rows the extension's own DDL would refuse can be staged; bt_hmac() is
    # a plain HMAC-SHA256 over the built-in sha256().
    Psql -Sql @'
DROP TABLE IF EXISTS fractalsql_ledger;
CREATE TABLE fractalsql_ledger (
  id bigserial PRIMARY KEY, kind integer NOT NULL, blob bytea NOT NULL,
  mac bytea, prev_hash bytea, entry_hash bytea,
  sealed boolean NOT NULL DEFAULT false, updated timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS fractalsql_ledger_kind_id_idx ON fractalsql_ledger (kind, id DESC);
CREATE OR REPLACE FUNCTION bt_put(p bytea, b bytea, m bytea) RETURNS bytea LANGUAGE plpgsql AS $f$
DECLARE h bytea := sha256(p || b || coalesce(m, '\x'::bytea));
BEGIN
  INSERT INTO fractalsql_ledger (kind, blob, mac, prev_hash, entry_hash) VALUES (1, b, m, p, h);
  RETURN h;
END $f$;
CREATE OR REPLACE FUNCTION bt_hmac(k bytea, m bytea) RETURNS bytea LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE ik bytea := '\x'::bytea; ok bytea := '\x'::bytea; kk bytea := k; i int;
BEGIN
  IF length(kk) > 64 THEN kk := sha256(kk); END IF;
  kk := kk || decode(repeat('00', 64 - length(kk)), 'hex');
  FOR i IN 0..63 LOOP
    ik := ik || set_byte('\x00'::bytea, 0, get_byte(kk, i) # 54);
    ok := ok || set_byte('\x00'::bytea, 0, get_byte(kk, i) # 92);
  END LOOP;
  RETURN sha256(ok || sha256(ik || m));
END $f$;
'@ | Out-Null
    $rowsB = @'
tip empty	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT fractal_ledger_load()
tip genesis ok	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x01020304',NULL); SELECT fractal_ledger_load()
tip genesis nonzero prev	E:fractalsql: ledger chain verification failed -- the sole entry's prev_	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put(decode(repeat('11',32),'hex'),'\x01',NULL); SELECT fractal_ledger_load()
tip chain ok	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put(bt_put($zero,'\x01',NULL),'\x02',NULL); SELECT fractal_ledger_load()
tip chain link broken	E:fractalsql: ledger chain verification failed -- the latest entry's pre	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x01',NULL); SELECT bt_put(decode(repeat('22',32),'hex'),'\x02',NULL); SELECT fractal_ledger_load()
tip prior hash null	E:fractalsql: ledger chain verification failed -- the latest entry's pre	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',$zero,NULL); SELECT bt_put($zero,'\x02',NULL); SELECT fractal_ledger_load()
tip prior hash short	E:fractalsql: ledger chain verification failed -- the latest entry's pre	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',$zero,'\x0011'); SELECT bt_put($zero,'\x02',NULL); SELECT fractal_ledger_load()
tip blob tampered	E:fractalsql: ledger chain verification failed -- the latest entry's has	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x0102',NULL); UPDATE fractalsql_ledger SET blob='\x0103' WHERE kind=1; SELECT fractal_ledger_load()
tip prev short	E:fractalsql: ledger chain verification failed -- stored prev_hash/entry	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01','\x0011',$zero); SELECT fractal_ledger_load()
tip hash short	E:fractalsql: ledger chain verification failed -- stored prev_hash/entry	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',$zero,'\x0011'); SELECT fractal_ledger_load()
tip entry_hash null	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',$zero,NULL); SELECT fractal_ledger_load()
tip prev null	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; INSERT INTO fractalsql_ledger(kind,blob,prev_hash,entry_hash) VALUES (1,'\x01',NULL,$zero); SELECT fractal_ledger_load()
tip key, no mac	E:fractalsql: ledger MAC verification failed -- the persisted blob has n	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',NULL); SELECT fractal_ledger_load()
tip key, mac short	E:fractalsql: ledger MAC verification failed -- stored MAC is 16 bytes, 	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',decode(repeat('cd',16),'hex')); SELECT fractal_ledger_load()
tip key, mac wrong	E:fractalsql: ledger MAC verification failed -- the persisted QTL blob i	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',decode(repeat('cd',32),'hex')); SELECT fractal_ledger_load()
tip key, mac valid	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',bt_hmac(convert_to('$key','UTF8'),'\x01')); SELECT fractal_ledger_load()
tip key, mac valid, blob tampered	E:fractalsql: ledger MAC verification failed -- the persisted QTL blob i	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',bt_hmac(convert_to('$key','UTF8'),'\x01')); UPDATE fractalsql_ledger SET blob='\x02' WHERE kind=1; SELECT fractal_ledger_load()
tip key, mac valid, hash tampered	E:fractalsql: ledger chain verification failed -- the latest entry's has	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SET fractalsql.enterprise_ledger_key = '$key'; SELECT bt_put($zero,'\x01',bt_hmac(convert_to('$key','UTF8'),'\x01')); UPDATE fractalsql_ledger SET entry_hash=decode(repeat('ee',32),'hex') WHERE kind=1; SELECT fractal_ledger_load()
tip nokey, mac present	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x01',decode(repeat('ab',32),'hex')); SELECT fractal_ledger_load()
tip nokey, mac short	E:fractalsql: ledger MAC verification failed -- stored MAC is 16 bytes, 	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put($zero,'\x01',decode(repeat('ab',16),'hex')); SELECT fractal_ledger_load()
tip verify kind1 ok	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put(bt_put($zero,'\x01',NULL),'\x02',NULL); SELECT fractal_ledger_verify(1)::text
tip verify kind1 tampered	OK	DELETE FROM fractalsql_ledger; RESET fractalsql.enterprise_ledger_key; SELECT bt_put(bt_put($zero,'\x01',NULL),'\x02',NULL); UPDATE fractalsql_ledger SET blob='\x09' WHERE kind=1 AND id=(SELECT min(id) FROM fractalsql_ledger WHERE kind=1); SELECT fractal_ledger_verify(1)::text
migrate old schema	OK	DROP TABLE IF EXISTS fractalsql_ledger; CREATE TABLE fractalsql_ledger (kind int PRIMARY KEY, blob bytea); SELECT fractal_ledger_verify(1)
migrate missing index	OK	DROP TABLE IF EXISTS fractalsql_ledger; CREATE TABLE fractalsql_ledger (id bigserial PRIMARY KEY, kind integer NOT NULL, blob bytea NOT NULL, mac bytea, prev_hash bytea NOT NULL, entry_hash bytea NOT NULL, sealed boolean NOT NULL DEFAULT false, updated timestamptz NOT NULL DEFAULT now()); SELECT fractal_ledger_verify(1)
'@
    $rowsB = $rowsB.Replace('$zero', "decode(repeat('00',32),'hex')").Replace('$key', 'gate45-ledger-key')
    SqlTableRun '45' $rowsB
    if ($script:TblBad -eq 0) { Pass "45 enterprise_paths: all $($script:TblN) ledger-tip authentication cases behaved as specified (genesis, link, hash, MAC, key/no-key)" }

    # ---- (c) enterprise libraries that are missing symbols ----
    # One built without the optional multimodal symbols (an older enterprise
    # build: the loader accepts it, the multimodal functions refuse), one
    # without a required symbol (the loader refuses the whole library).
    $mockOld = Join-Path $env:TEMP "fractalsql_bt_g45_old_$PgMajor.dll"
    $mockBad = Join-Path $env:TEMP "fractalsql_bt_g45_bad_$PgMajor.dll"
    Remove-Item -Force $mockOld, $mockBad -ErrorAction SilentlyContinue
    $okOld = $false; $okBad = $false
    & cl.exe /nologo /MT /LD /DFSQL_BUILDING_DLL /DMOCK_OMIT_MULTIMODAL "/I$inc" $src "/Fo$([System.IO.Path]::ChangeExtension($mockOld, '.obj'))" "/Fe$mockOld" 2>&1 | Out-Null
    $okOld = ($LASTEXITCODE -eq 0 -and (Test-Path $mockOld))
    & cl.exe /nologo /MT /LD /DFSQL_BUILDING_DLL /DMOCK_OMIT_AUDIT_UNPACK "/I$inc" $src "/Fo$([System.IO.Path]::ChangeExtension($mockBad, '.obj'))" "/Fe$mockBad" 2>&1 | Out-Null
    $okBad = ($LASTEXITCODE -eq 0 -and (Test-Path $mockBad))
    if ($okOld -and $okBad) {
        PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$mockOld'" -Want $mockOld | Out-Null
        $rowsOld = @'
old core multimodal	E:not available in this enterprise library	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2)
old core pareto	E:not available in this enterprise library	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2)
old core ledger still works	OK	SELECT fractal_ledger_truth_count()
'@
        SqlTableRun '45' $rowsOld
        if ($script:TblBad -eq 0) { Pass "45 enterprise_paths: a core without the optional multimodal symbols loads, and only the multimodal functions refuse" }
        PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$mockBad'" -Want $mockBad | Out-Null
        $rowsBad = @'
bad core ledger	E:enterprise tier not loaded	SELECT fractal_ledger_flush()
bad core multimodal	E:enterprise tier not loaded	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[],ARRAY[1,0,0,0,1,0,0,0,1]::float8[],2)
'@
        SqlTableRun '45' $rowsBad
        if ($script:TblBad -eq 0) { Pass "45 enterprise_paths: a core missing a required symbol is refused as a whole" }
    } else {
        Fail "45 enterprise_paths: reduced mock cores failed to build"
    }
    Remove-Item -Force $mockOld, $mockBad -ErrorAction SilentlyContinue

    Psql -Sql "DROP FUNCTION IF EXISTS bt_hmac(bytea,bytea), bt_put(bytea,bytea,bytea); DELETE FROM fractalsql_ledger;" | Out-Null
    Psql -Sql "ALTER SYSTEM RESET fractalsql.enterprise_require_signature;" | Out-Null
    Psql -Sql "ALTER SYSTEM RESET fractalsql.enterprise_lib;" | Out-Null
    Psql -Sql "SELECT pg_reload_conf();" | Out-Null
    Remove-Item -Force $mockSo, "$mockSo.sig" -ErrorAction SilentlyContinue
}

# Gate 46: plugin / provider configuration paths -- see build_test.sh's
# gate_46_plugin_config. Sets every "if configured" provider setting, runs the
# reasoning / embed / text-to-sql entry points against the mock plugins, then
# clears the plugin path to exercise the "no plugin configured" errors.
function Gate46PluginConfig {
    Psql -Sql @"
DROP TABLE IF EXISTS bt_g46;
CREATE TABLE bt_g46 (id serial PRIMARY KEY, emb float8[], txt text);
INSERT INTO bt_g46 (emb, txt) VALUES (ARRAY[0.1,0.2,0.3],'a'), (ARRAY[0.3,0.2,0.1],'b');
"@ | Out-Null
    [System.IO.File]::WriteAllText($SqlFile, "SELECT count(*) FROM bt_g46`n")
    PgSwapPlugin $Mock | Out-Null
    $rows = @'
@guc	http_url	http://127.0.0.1:9/v1/chat/completions
@guc	http_token	bt-token
@guc	http_model	bt-model
@guc	http_allow_plaintext	on
@guc	http_embed_url	http://127.0.0.1:9/v1/embeddings
@guc	http_embed_model	bt-embed
@guc	http_think	low
@guc	http_think_provider	ollama
@guc	http_native_url	http://127.0.0.1:9/api/chat
@guc	http_num_ctx	4096
@guc	text_to_sql_max_attempts	3
@guc	text_to_sql_allowed_statements	select_insert_update
configured reason	OK	SELECT fractal_reason('q')
configured reason ctx	OK	SELECT fractal_reason('q', '{"k":1}')
configured t2s	OK	SELECT fractal_text_to_sql('count rows in bt_g46')
configured t2s tables	OK	SELECT fractal_text_to_sql('count rows', ARRAY['bt_g46'])
configured sql_agent	OK	SELECT * FROM fractal_sql_agent('count rows in bt_g46')
configured sql_agent exec	OK	SELECT * FROM fractal_sql_agent('count rows in bt_g46', ARRAY['bt_g46'], 2, true)
configured schema	OK	SELECT length(fractal_schema_context(ARRAY['bt_g46'], 'rows')) > 0
@guc	text_to_sql_use_review	on
review t2s	E:fractal_text_to_sql: exhausted 3 attempt(s), last review verdict: ```s	SELECT fractal_text_to_sql('count rows in bt_g46')
review sql_agent	OK	SELECT * FROM fractal_sql_agent('count rows in bt_g46')
@guc	text_to_sql_use_review	off
@plugin	EMBED
configured embed	OK	SELECT array_length(fractal_embed('hello'), 1)
configured search_agent	OK	SELECT * FROM fractal_search_agent('q', 'bt_g46', 'emb')
configured rag	OK	SELECT * FROM fractal_rag_agent('q', 'bt_g46', 'emb')
configured plan	OK	SELECT count(*) FROM fractal_agent_plan_explore('q', 'bt_g46', 'emb', 2)
@guc	http_embed_url	
embed url unset	E:http_embed_url is not configured	SELECT fractal_embed('hello')
embed url unset agent	E:fractal_embed: fractalsql.http_embed_url is not configured	SELECT * FROM fractal_search_agent('q', 'bt_g46', 'emb')
@guc	reasoning_plugin	
no plugin reason	E:fractal_reason: no reasoning plugin loaded	SELECT fractal_reason('q')
no plugin t2s	E:fractal_text_to_sql: no reasoning plugin loaded	SELECT fractal_text_to_sql('count rows in bt_g46')
no plugin sql_agent	E:fractal_sql_agent: no reasoning plugin loaded	SELECT * FROM fractal_sql_agent('count rows in bt_g46')
no plugin embed	E:fractal_embed: no reasoning plugin loaded	SELECT fractal_embed('hello')
no plugin schema	OK	SELECT length(fractal_schema_context(ARRAY['bt_g46'])) > 0
no plugin search_agent	E:fractal_search_agent: no reasoning plugin loaded	SELECT * FROM fractal_search_agent('q', 'bt_g46', 'emb')
'@
    SqlTableRun '46' $rows
    if ($script:TblBad -eq 0) { Pass "46 plugin_config: all $($script:TblN) provider-configuration / no-plugin calls behaved as specified (no backend crash)" }
    foreach ($k in 'http_url','http_token','http_model','http_allow_plaintext','http_embed_url','http_embed_model','http_think',
                   'http_think_provider','http_native_url','http_num_ctx','text_to_sql_max_attempts','text_to_sql_allowed_statements',
                   'text_to_sql_use_review') {
        Psql -Sql "ALTER SYSTEM RESET fractalsql.$k;" | Out-Null
    }
    Psql -Sql "SELECT pg_reload_conf();" | Out-Null
    PgSwapPlugin $Mock | Out-Null
    Psql -Sql "DROP TABLE IF EXISTS bt_g46;" | Out-Null
}

# Gate 47: fault injection into the SPI and core calls the extension checks --
# see build_test.sh's gate_47_fault_injection for the full rationale. A test
# build (Gate01Build passes -FaultInject; src\fsql_fault.h) lets a session fail
# the Nth call of one named site (SET fractalsql.fault_inject = 'SPI_execute:3').
# Each statement is swept over every site, failing call 1, 2, 3, ... until a
# run no longer reaches that many calls; every injected run must end without a
# backend crash or a leak warning. Unlike the Linux gate there is no per-run
# timeout (Psql has none), so a hang shows as a stuck run rather than a failure.
$script:FiSites = @('srf_context','SPI_connect','SPI_execute','SPI_execute_with_args','fsql_new_sovereign','fsql_load_reasoning','fsql_search_ptr','fsql_search_null_json','fsql_dispatch_ai','fsql_dispatch_ai_resp','fsql_dispatch_ai_nosummary','fsql_extract_topk','fsql_topk_idx_neg','fsql_topk_idx_big','fsql_extract_best_point','fsql_extract_population','fsql_parse_embedding_array','fsql_cycle_detect_init','fsql_cycle_detect_feed','fsql_state_fingerprint','fsql_feedback_report','fsql_diversify_enable','fsql_diversify_disable','fsql_diversify_get_params','fsql_diversify_set_params','fsql_optimize_portfolio_ex','get_call_result_type','g_ent_ledger_flush','g_ent_ledger_load','g_ent_ledger_compact','g_ent_ledger_reset_soft','g_ent_ledger_reset_hard','g_ent_ledger_truth_count','g_ent_ledger_shadow_count','g_ent_optimize_portfolio_multimodal','g_ent_optimize_portfolio_multimodal_ex','g_ent_optimize_portfolio_multimodal_pareto')
$script:FiRuns = 0; $script:FiFired = 0; $script:FiBad = 0

function FaultSweep([string]$Label, [string]$Sql) {
    foreach ($site in $script:FiSites) {
        for ($k = 1; $k -le 100; $k++) {
            $out = Psql -Sql "SET fractalsql.fault_inject = '${site}:$k'; $Sql"
            $script:FiRuns++
            if ($out -match 'server closed the connection|terminated by signal|in recovery mode|not yet accepting') {
                $short = ($out -replace '\s+', ' '); if ($short.Length -gt 160) { $short = $short.Substring(0, 160) }
                Fail "47 fault_injection: '$Label' with ${site}:$k CRASHED the backend: $short"
                $script:FiBad++
                for ($i = 0; $i -lt (60 * $TimeoutMult); $i++) {
                    if ((Psql -Sql 'SELECT 1') -eq '1') { break }
                    Start-Sleep -Milliseconds 500
                }
                break
            }
            if ($out -notmatch 'fractalsql: fault injected at') { break }    # ran past the last call of this site
            $script:FiFired++
            if ($out -match 'non-empty SPI stack|leak|was not closed|still open') {
                Fail "47 fault_injection: '$Label' with ${site}:$k leaked: $(($out -split "`n" | Where-Object { $_ -match 'non-empty SPI stack|leak|was not closed|still open' } | Select-Object -First 1))"
                $script:FiBad++
            }
        }
    }
}

# Sweep every "label<TAB>sql" row of a here-string.
function FaultSweepRows([string]$Rows) {
    foreach ($line in ($Rows -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $f = $line -split "`t", 2
        FaultSweep $f[0] $f[1]
    }
}

function Gate47FaultInjection {
    $probe = Psql -Sql 'SHOW fractalsql.fault_inject;'
    if ($probe -match 'ERROR|unrecognized') {
        Skip "47 fault_injection: this build has no fault-injection hook (needs build-windows.ps1 -FaultInject)"
        return
    }
    Psql -Sql @"
DROP TABLE IF EXISTS bt_g47, bt_g47v;
CREATE TABLE bt_g47 (id serial PRIMARY KEY, emb float8[], txt text);
INSERT INTO bt_g47 (emb, txt) VALUES (ARRAY[0.1,0.2,0.3],'a'), (ARRAY[0.3,0.2,0.1],'b'), (ARRAY[0.9,0.8,0.7],'c'), (ARRAY[0.5,0.5,0.5],'d');
CREATE TABLE bt_g47v (id serial PRIMARY KEY, emb fractal_vector);
INSERT INTO bt_g47v (emb) VALUES ('[0.1,0.2,0.3]'), ('[0.3,0.2,0.1]'), ('[0.9,0.8,0.7]');
"@ | Out-Null
    [System.IO.File]::WriteAllText($SqlFile, "SELECT count(*) FROM bt_g47`n")
    $script:FiRuns = 0; $script:FiFired = 0; $script:FiBad = 0

    # ---- reasoning mock: text-to-SQL, the SQL agent, schema context ----
    PgSwapPlugin $Mock | Out-Null
    FaultSweepRows @'
sql_agent	SELECT * FROM fractal_sql_agent('count rows in bt_g47')
sql_agent exec	SELECT * FROM fractal_sql_agent('count rows in bt_g47', ARRAY['bt_g47'], 2, true)
text_to_sql	SELECT fractal_text_to_sql('count rows in bt_g47', ARRAY['bt_g47'])
schema_context	SELECT length(fractal_schema_context(ARRAY['bt_g47'], 'rows'))
schema_context auto	SELECT length(fractal_schema_context())
reason	SELECT fractal_reason('q')
'@
    PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal "'on'" -Want 'on' | Out-Null
    PgSetGuc -Name 'fractalsql.text_to_sql_max_attempts' -SetVal "'2'" -Want '2' | Out-Null
    FaultSweep 'sql_agent review' "SELECT * FROM fractal_sql_agent('count rows in bt_g47')"
    FaultSweep 'text_to_sql review' "SELECT fractal_text_to_sql('count rows in bt_g47')"
    PgSetGuc -Name 'fractalsql.text_to_sql_use_review' -SetVal "'off'" -Want 'off' | Out-Null

    # ---- embed mock: the embedding-driven agents ----
    PgSwapPlugin $Embed | Out-Null
    PgSetGuc -Name 'fractalsql.http_embed_url' -SetVal "'http://unused/embeddings'" -Want 'http://unused/embeddings' | Out-Null
    FaultSweepRows @'
embed	SELECT array_length(fractal_embed('hello'), 1)
search_agent	SELECT * FROM fractal_search_agent('q', 'bt_g47', 'emb')
rag_agent	SELECT * FROM fractal_rag_agent('q', 'bt_g47', 'emb')
plan_explore	SELECT count(*) FROM fractal_agent_plan_explore('q', 'bt_g47', 'emb', 2)
'@
    Psql -Sql 'ALTER SYSTEM RESET fractalsql.http_embed_url;' | Out-Null
    Psql -Sql 'SELECT pg_reload_conf();' | Out-Null

    # ---- no plugin needed: search, trajectory, loop/cycle, diversify ----
    PgSwapPlugin $Mock | Out-Null
    FaultSweepRows @'
search	SELECT fractal_search(ARRAY[0.1,0.2,0.3]::float8[], 3, 6)
search_debug	SELECT fractal_search_debug(ARRAY[0.1,0.2,0.3]::float8[], 3, 6)
search_explore	SELECT count(*) FROM fractal_search_explore('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], '{"iterations":3,"population_size":5}')
search_explore fv	SELECT count(*) FROM fractal_search_explore('bt_g47v', 'emb', ARRAY[0.1,0.2,0.3]::float8[])
telemetry	SELECT count(*) FROM fractal_search_telemetry('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], 2)
telemetry fv	SELECT count(*) FROM fractal_search_telemetry('bt_g47v', 'emb', ARRAY[0.1,0.2,0.3]::float8[], 2)
trajectory	SELECT count(*) FROM fractal_search_trajectory('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], ARRAY[0.3,0.2,0.1]::float8[], 2)
trajectory fv	SELECT count(*) FROM fractal_search_trajectory('bt_g47v', 'emb', '[0.1,0.2,0.3]'::fractal_vector, '[0.3,0.2,0.1]'::fractal_vector, 2)
cross_modal	SELECT count(*) FROM fractal_cross_modal_search('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], ARRAY[0.3,0.2,0.1]::float8[], 0.5, 2)
cross_modal fv	SELECT count(*) FROM fractal_cross_modal_search('bt_g47v', 'emb', '[0.1,0.2,0.3]'::fractal_vector, '[0.3,0.2,0.1]'::fractal_vector, 0.5, 2)
hybrid	SELECT count(*) FROM fractal_hybrid_clinical_search('bt_g47', 'emb', ARRAY[0.1,0.2,0.3]::float8[], (SELECT array_agg(ctid::text) FROM bt_g47), 2)
hybrid fv	SELECT count(*) FROM fractal_hybrid_clinical_search('bt_g47v', 'emb', ARRAY[0.1,0.2,0.3]::float8[], (SELECT array_agg(ctid::text) FROM bt_g47v), 2)
agent trajectory	SELECT * FROM fractal_agent_trajectory_predict('bt_g47', 'emb', 1, 3)
agent trajectory fv	SELECT * FROM fractal_agent_trajectory_predict('bt_g47v', 'emb', 1, 3)
detect_loop	SELECT * FROM fractal_agent_detect_loop('a', ARRAY[1,2,1,2,1,2,1,2]::float8[], 2)
fingerprint	SELECT fractal_state_fingerprint(ARRAY[1,2,3]::float8[], 64)
cycle_detect	SELECT * FROM fractal_cycle_detect(ARRAY['\x01','\x02','\x01','\x02','\x01','\x02']::bytea[])
diversify	SELECT fractal_diversify_enable(); SELECT fractal_diversify_set_params(5); SELECT fractal_feedback_report(1,'positive'); SELECT fractal_explain_result(); SELECT fractal_detect_collapse(); SELECT fractal_diversify_disable()
diversify dq	SELECT fractal_diversify_enable(); SELECT fractal_diversify_current_dq(); SELECT fractal_diversify_overhead_p99_us(); SELECT fractal_isolate_background(1); SELECT fractal_diversify_disable()
periodogram	SELECT * FROM fractal_periodogram(ARRAY[1,2,3,4,5,6,7,8]::float8[], 4)
tda	SELECT * FROM fractal_tda_persistence_diagram(ARRAY[1,2,3,4,5,6]::float8[], 2)
portfolio	SELECT fractal_optimize_portfolio(ARRAY[0.1,0.2,0.15]::float8[], ARRAY[1,0,0,0,1,0,0,0,1]::float8[], 2, 7)
set_config	SELECT fractalsql_set_config('http_model', 'bt-model'); SELECT fractalsql_get_config('http_model')
store/mine	SELECT fractal_store_morphology(1, ARRAY[0.1,0.2]::float8[]); SELECT count(*) FROM fractal_mine_topology_negatives(ARRAY[0.1,0.2]::float8[], 2)
'@

    # ---- enterprise mock: ledger / audit ----
    $mockSo = Join-Path $env:TEMP "fractalsql_bt_g47_ent_$PgMajor.dll"
    Remove-Item -Force $mockSo, "$mockSo.sig" -ErrorAction SilentlyContinue
    $obj = [System.IO.Path]::ChangeExtension($mockSo, '.obj')
    $src = Join-Path $RepoRoot 'tests\mock_enterprise_core.c'
    $inc = Join-Path $RepoRoot 'include'
    $buildOut = & cl.exe /nologo /MT /LD /DFSQL_BUILDING_DLL "/I$inc" $src "/Fo$obj" "/Fe$mockSo" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $mockSo)) {
        Fail "47 fault_injection: mock enterprise core failed to build"
        Write-Host ($buildOut -join "`n")
    } else {
        Psql -Sql 'ALTER SYSTEM SET fractalsql.enterprise_require_signature = off;' | Out-Null
        if (PgSetGuc -Name 'fractalsql.enterprise_lib' -SetVal "'$mockSo'" -Want $mockSo) {
            FaultSweepRows @'
ledger verify	SELECT fractal_ledger_verify(1)
ledger load	SELECT fractal_ledger_load()
ledger flush	SELECT fractal_ledger_flush()
audit_log	SELECT fractal_audit_log('bt', '{"k":1}')
ledger compact	SELECT fractal_ledger_compact()
ledger reset	SELECT fractal_ledger_reset_soft(); SELECT fractal_ledger_reset_hard()
ledger counts	SELECT fractal_ledger_truth_count(); SELECT fractal_ledger_shadow_count()
multimodal	SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.2,0.15]::float8[], ARRAY[1,0,0,0,1,0,0,0,1]::float8[], 2)
pareto	SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.2,0.15]::float8[], ARRAY[1,0,0,0,1,0,0,0,1]::float8[], 2)
'@
        } else {
            Fail "47 fault_injection: could not point enterprise_lib at the mock"
        }
        Psql -Sql 'ALTER SYSTEM RESET fractalsql.enterprise_require_signature;' | Out-Null
        Psql -Sql 'ALTER SYSTEM RESET fractalsql.enterprise_lib;' | Out-Null
        Psql -Sql 'SELECT pg_reload_conf();' | Out-Null
    }
    Remove-Item -Force $mockSo, "$mockSo.sig" -ErrorAction SilentlyContinue

    # ---- ledger storage callbacks, driven directly (test-only SQL wrapper) ----
    # The enterprise core is what normally calls them, and none is vendored in a
    # community checkout, so the build's fractal_fi_ledger_vfs() stands in.
    Psql -Sql "CREATE OR REPLACE FUNCTION bt_fi_ledger_vfs(op text, kind int4, payload bytea DEFAULT NULL) RETURNS text AS '$DllPath','fractal_fi_ledger_vfs' LANGUAGE C VOLATILE; DROP TABLE IF EXISTS fractalsql_ledger;" | Out-Null
    $lr = Psql -Sql "SELECT bt_fi_ledger_vfs('read', 1)"
    if ($lr -eq 'rc=-46 len=0 hex=') { Pass "47 fault_injection: reading an empty ledger reports 'unavailable' (-46), not an error" }
    else { Fail "47 fault_injection: empty-ledger read returned: $lr" }
    Psql -Sql "SELECT bt_fi_ledger_vfs('write', 1, '\x616263')" | Out-Null
    $lr = Psql -Sql "SELECT bt_fi_ledger_vfs('read', 1)"
    if ($lr -eq 'rc=0 len=3 hex=616263') { Pass "47 fault_injection: a ledger entry written through the storage callback reads back byte for byte" }
    else { Fail "47 fault_injection: ledger read-back returned: $lr" }
    FaultSweepRows @'
ledger vfs write	SELECT bt_fi_ledger_vfs('write', 1, '\x616263')
ledger vfs write keyed	SET fractalsql.enterprise_ledger_key = 'bt-key'; SELECT bt_fi_ledger_vfs('write', 1, '\x616263'); SELECT bt_fi_ledger_vfs('read', 1)
ledger vfs read	SELECT bt_fi_ledger_vfs('read', 1)
ledger vfs seal	SELECT bt_fi_ledger_vfs('seal', 1)
'@
    Psql -Sql "DROP FUNCTION IF EXISTS bt_fi_ledger_vfs(text,int4,bytea); DROP TABLE IF EXISTS fractalsql_ledger;" | Out-Null

    if ($script:FiBad -eq 0 -and $script:FiFired -gt 100) {
        Pass "47 fault_injection: $($script:FiFired) injected SPI/core failures across $($script:FiRuns) runs; none crashed or leaked"
    } elseif ($script:FiBad -eq 0) {
        Fail "47 fault_injection: only $($script:FiFired) faults fired in $($script:FiRuns) runs -- the hook is not reaching the call sites"
    }
    Psql -Sql 'RESET fractalsql.fault_inject; DROP TABLE IF EXISTS bt_g47, bt_g47v;' | Out-Null
    PgSwapPlugin $Mock | Out-Null
}

function Gate43EnterpriseSurface {
    # The enterprise SURFACE invariant: of the twelve user-facing
    # enterprise functions, exactly ONE is not gated on the enterprise
    # core library.
    #
    # fractal_ledger_verify() is a pure storage-layer check -- it walks
    # the persisted ledger chain with SPI and never touches the
    # enterprise core (no ensure_search_ctx, no ensure_enterprise_lib) --
    # so it must answer on EVERY edition, including community with no
    # shared lib anywhere. The other ELEVEN (9 ledger/audit + 2
    # portfolio) must raise the documented 'enterprise tier not loaded'
    # error when the library is absent.
    #
    # This is easy to break by accident, in both directions:
    #   - GATING fractal_ledger_verify() "for consistency" would take the
    #     CISO audit query offline on community -- a forensic read of the
    #     persisted chain, which community still writes via the
    #     best-effort audit bindings, with no core library involved.
    #   - UNGATING one of the other eleven would make a dormant function
    #     appear to work, and then fail deeper in, in a way that leaks
    #     the enterprise core's internals.
    # The sibling engine (fractalsql-sqlite) holds the same invariant,
    # and the whole point of pinning it here is that it is a property of
    # the SURFACE, not of any one edition.
    #
    # The dormant state is forced deterministically by pointing
    # fractalsql.enterprise_lib at a path that does not exist -- the
    # same trick gate 24's Phase B uses -- so this gate asserts the SAME
    # thing whether or not an enterprise library happens to be vendored
    # in include/. It therefore does NOT self-skip on a community
    # checkout: the community checkout is precisely the state it is here
    # to pin.
    $applyGuc = {
        param($val)
        $escaped = $val -replace "'", "''"
        [void](Psql -Sql "ALTER SYSTEM SET fractalsql.enterprise_lib = '$escaped';")
        [void](Psql -Sql "SELECT pg_reload_conf();")
        Start-Sleep -Milliseconds 1500
    }
    & $applyGuc '/nonexistent/fractalsql-enterprise-absent.dll'
    $v = Psql -Sql "SHOW fractalsql.enterprise_lib;"
    if ($v -ne '/nonexistent/fractalsql-enterprise-absent.dll') {
        Fail "43 enterprise_surface: could not force the dormant tier (reload did not take effect; got '$v')"
        return
    }

    # The one UNGATED function: a forensic read of the persisted chain
    # that must work with no enterprise core loaded at all.
    $vres = Psql -Sql "SELECT fractal_ledger_verify();"
    if ($vres -match 'enterprise tier not loaded') {
        Fail "43 enterprise_surface: fractal_ledger_verify() must NOT be gated on the enterprise core, but it raised the dormant error"
    }
    elseif ($vres -match '"ok":\s*true') {
        Pass "43 enterprise_surface: fractal_ledger_verify() answers with no enterprise core loaded (the one ungated function)"
    }
    else {
        Fail "43 enterprise_surface: expected fractal_ledger_verify() to return an ok report, got: $vres"
    }

    # The other ELEVEN: each must raise the documented dormant error.
    # The portfolio pair is checked with the same arguments gate 24 uses,
    # so a failure here is about the GATE and not about the arguments.
    $gatedCalls = @(
        'SELECT fractal_ledger_flush();',
        'SELECT fractal_ledger_load();',
        'SELECT fractal_ledger_compact();',
        'SELECT fractal_ledger_reset_soft();',
        'SELECT fractal_ledger_reset_hard();',
        'SELECT fractal_ledger_truth_count();',
        'SELECT fractal_ledger_shadow_count();',
        "SELECT fractal_audit_log('t', '{}'::jsonb);",
        "SELECT fractal_audit_unpack(''::bytea);",
        'SELECT fractal_optimize_portfolio_multimodal(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);',
        'SELECT fractal_optimize_portfolio_multimodal_pareto(ARRAY[0.1,0.05,0.08]::float8[], ARRAY[0.04,0.01,0.01, 0.01,0.03,0.01, 0.01,0.01,0.05]::float8[], 2);'
    )
    $gatedNames = @(
        'fractal_ledger_flush',
        'fractal_ledger_load',
        'fractal_ledger_compact',
        'fractal_ledger_reset_soft',
        'fractal_ledger_reset_hard',
        'fractal_ledger_truth_count',
        'fractal_ledger_shadow_count',
        'fractal_audit_log',
        'fractal_audit_unpack',
        'fractal_optimize_portfolio_multimodal',
        'fractal_optimize_portfolio_multimodal_pareto'
    )
    $badGated = @()
    for ($i = 0; $i -lt $gatedCalls.Count; $i++) {
        $out = Psql -Sql $gatedCalls[$i]
        if ($out -notmatch 'enterprise tier not loaded') {
            $badGated += ("{0}: {1}" -f $gatedNames[$i], $out)
        }
    }
    if ($badGated.Count -eq 0) {
        Pass "43 enterprise_surface: all 11 gated enterprise functions raise 'enterprise tier not loaded' with no core loaded"
    }
    else {
        Fail "43 enterprise_surface: expected all 11 gated functions to be dormant, got: $($badGated -join '; ')"
    }

    # Database-side guard behind the MCP server's FSQL_MCP_READ_ONLY switch: the two
    # ledger resets are not executable by PUBLIC (sql\fractalsql--1.0.sql), so a role
    # with no grant is refused by Postgres itself, before the enterprise core is even
    # consulted. The superuser calls above still reach the dormant error.
    Psql -Sql "DROP ROLE IF EXISTS bt_ledger_lowpriv; CREATE ROLE bt_ledger_lowpriv LOGIN;" | Out-Null
    $lpBad = @()
    foreach ($lpFn in 'fractal_ledger_reset_soft', 'fractal_ledger_reset_hard') {
        $out = Psql -Sql "SELECT $lpFn();" -User 'bt_ledger_lowpriv'
        if ($out -notmatch "permission denied for function $lpFn") {
            $lpBad += ("{0}: {1}" -f $lpFn, $out)
        }
    }
    Psql -Sql "DROP ROLE IF EXISTS bt_ledger_lowpriv;" | Out-Null
    if ($lpBad.Count -eq 0) {
        Pass "43 enterprise_surface: fractal_ledger_reset_soft/_hard are refused to a role with no EXECUTE grant (permission denied)"
    }
    else {
        Fail "43 enterprise_surface: expected 'permission denied' for a low-privilege role on the ledger resets, got: $($lpBad -join '; ')"
    }

    # The gate must not leak into later gates on a reused cluster.
    & $applyGuc ''
}

function RunGates($gates) {
    Write-Information "== PG$PgMajor (Windows) ==" -InformationAction Continue
    if ($gates -contains '01') {
        if (-not (Gate01Build)) { return }
    }
    # Gate 21 (fuzz smoke) is standalone like gate 01 -- links only
    # src\fractalsql_parse.c directly, no extension DLL, no postgres.exe,
    # no cluster at all. Same for the gate 39-42 unit probes (39/40/42
    # entirely; 41's DB-less half runs inside the db block below, where
    # its live half then runs after gate 33 against the live cluster).
    if ($gates -contains '21') {
        Gate21FuzzSmoke
    }
    if ($gates -contains '39') { Gate39ExtractParse }
    if ($gates -contains '40') { Gate40VectorsProbe }
    if ($gates -contains '42') { Gate42ConcurrencyProbe }
    if ($gates -contains '38') { Gate38McpHttps }   # standalone: needs no cluster
    # @(...): same $null-vs-empty-array StrictMode trap as Gate12Soak's
    # $failedWorkers below -- not yet hit here (would need e.g. -Gate 01
    # alone), but the identical shape of bug, fixed proactively.
    $needDb = @($gates | Where-Object { $_ -notin @('01','21','38','39','40','42') })
    if ($needDb.Count -gt 0) {
        try { PgSetup } catch { Fail "PG$PgMajor cluster setup: $_"; return }
        # gate 03 creates bt_customers/bt_orders; several later gates
        # (04, 05, 06, 07, 10, 12, 19) depend on that fixture already
        # existing, so ensure it exists even if 03 wasn't explicitly
        # requested (matches build_test.sh's same fixture-priming logic).
        if ($needDb -notcontains '03') {
            Gate03SchemaContext
        }
        foreach ($g in $needDb) {
            switch ($g) {
                '02' { Gate02Smoke }
                '03' { Gate03SchemaContext }
                '04' { Gate04TextToSql }
                '05' { Gate05EvilOverread }
                '06' { Gate06CrashRecovery }
                '07' { Gate07EvilLyingLength }
                '08' { Gate08Authz }
                '09' { Gate09GucSuperuser }
                '10' { Gate10DosAndInjection }
                '11' { Gate11Scout }
                '12' { Gate12Soak }
                '13' { Gate13SiuMode }
                '14' { Gate14Retry }
                '15' { Gate15Embed }
                '16' { Gate16EmbedAuthz }
                '17' { Gate17EmbedSoak }
                '18' { Gate18EmbedCrash }
                '19' { Gate19SfsBounds }
                '20' { Gate20ApiFunc }
                '22' { Gate22V2Functions }
                '23' { Gate23Agents }
                '24' { Gate24Enterprise }
                '25' { Gate25EnterpriseStress }
                '26' { Gate26EnterpriseSignature }
                '27' { Gate27Think }
                '28' { Gate28ReviewIsolation }
                '29' { Gate29VectorOps }
                '30' { Gate30NewPrimitives }
                '31' { Gate31EnterpriseMock }
                '32' { Gate32SovereignAgents }
                '33' { Gate33McpSmoke }
                '43' { Gate43EnterpriseSurface }
                '44' { Gate44ErrorPaths }
                '45' { Gate45EnterprisePaths }
                '46' { Gate46PluginConfig }
                '47' { Gate47FaultInjection }
                '48' { Gate48Kits }
                '41' { Gate41DbProbe }
            }
        }
        PgTeardown
    }
}

try {
    if ($Gate) { RunGates @($Gate) }
    elseif ($Quick) { RunGates $QuickGates }
    elseif ($Fuzz) { RunGates $FuzzGates }
    else { RunGates $DefaultGates }
} finally {
    Cleanup
}

Write-Host ""
if ($script:Failed -eq 0) {
    Write-Host "build_test: PASS" -ForegroundColor Green
    exit 0
} else {
    Write-Host "build_test: FAIL" -ForegroundColor Red
    exit 1
}
