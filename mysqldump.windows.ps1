# =============================================================================
#  mysqldump.windows.ps1 — Remote-to-local MySQL synchronisation tool (Windows)
#  MwSpace LLC — https://mwspace.com
#
#  MIT License — Copyright (c) 2025 MwSpace LLC
#
#  Requirements:
#    - PowerShell 5.1+ or PowerShell 7+
#    - OpenSSH Client:
#        Settings > System > Optional Features > OpenSSH Client
#    - MySQL Shell / Client (mysqldump.exe + mysql.exe in PATH):
#        https://dev.mysql.com/downloads/mysql/
#        OR via winget: winget install Oracle.MySQL
#    - mysqldump must also be installed on the remote host
#
#  Usage:
#    .\mysqldump.windows.ps1
#    .\mysqldump.windows.ps1 -Help
#    .\mysqldump.windows.ps1 -ResetConfig
#    .\mysqldump.windows.ps1 -NoSave
# =============================================================================

[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$Version,
    [switch]$NoSave,
    [switch]$ResetConfig,
    [switch]$NoColor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$SCRIPT_VERSION = '1.0.0'
$SCRIPT_NAME    = Split-Path -Leaf $PSCommandPath
$CONFIG_FILE    = Join-Path $env:USERPROFILE '.mysql_sync_config.json'
$TEMP_BASE      = Join-Path $env:TEMP 'mysql_sync'

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
function Write-Ok      { param($Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green  }
function Write-Info    { param($Msg) Write-Host "  [..] $Msg" -ForegroundColor Cyan   }
function Write-Warn    { param($Msg) Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Write-Fail    { param($Msg) Write-Host "  [XX] $Msg" -ForegroundColor Red    }
function Write-Step    { param($Msg) Write-Host "`n>>  $Msg"  -ForegroundColor Cyan   }
function Write-Section { param($Msg) Write-Host "`n$Msg"      -ForegroundColor Blue   }

function Stop-WithError {
    param($Msg)
    Write-Fail $Msg
    exit 1
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
function Show-Help {
    Write-Host @"

$SCRIPT_NAME v$SCRIPT_VERSION
MySQL remote-to-local database sync tool — MwSpace LLC

USAGE
  .\$SCRIPT_NAME [OPTIONS]

OPTIONS
  -Help              Show this help message and exit
  -Version           Print version and exit
  -NoColor           Disable coloured output
  -NoSave            Do not save local configuration
  -ResetConfig       Delete saved configuration and exit

REQUIREMENTS
  1. OpenSSH Client (Windows 10/11):
       Settings > System > Optional Features > OpenSSH Client
  2. MySQL Client tools (mysqldump + mysql):
       winget install Oracle.MySQL
       OR download from https://dev.mysql.com/downloads/mysql/
       Make sure mysqldump.exe and mysql.exe are in your PATH.

NOTES
  * Requires SSH key-based authentication (no password prompt).
  * Remote credentials (user/password) are always prompted and never saved.
  * Local credentials and SSH settings are saved to: $CONFIG_FILE
  * mysqldump must also be installed on the remote host.

EXAMPLES
  # Interactive wizard
  .\$SCRIPT_NAME

  # Reset saved defaults
  .\$SCRIPT_NAME -ResetConfig

"@
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
if ($Help)    { Show-Help; exit 0 }
if ($Version) { Write-Host "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 }

if ($ResetConfig) {
    if (Test-Path $CONFIG_FILE) {
        Remove-Item $CONFIG_FILE -Force
        Write-Ok "Configuration reset: $CONFIG_FILE deleted."
    } else {
        Write-Host "No saved configuration found."
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Configuration persistence (local credentials only — remote never saved)
# ---------------------------------------------------------------------------
function Save-SyncConfig {
    param($Cfg)
    $Cfg | ConvertTo-Json | Set-Content -Path $CONFIG_FILE -Encoding UTF8

    # Restrict permissions to current user only
    try {
        $acl = Get-Acl $CONFIG_FILE
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl',
            'Allow'
        )
        $acl.AddAccessRule($rule)
        Set-Acl $CONFIG_FILE $acl
    } catch {
        Write-Warn "Could not restrict config file permissions: $_"
    }

    Write-Ok "Local configuration saved to $CONFIG_FILE"
}

function Load-SyncConfig {
    if (Test-Path $CONFIG_FILE) {
        $cfg = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json
        Write-Ok "Previous configuration loaded from $CONFIG_FILE"
        return $cfg
    }
    return $null
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
function Test-Dependencies {
    $missing = @()
    foreach ($cmd in @('ssh', 'mysqldump', 'mysql')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            $missing += $cmd
        }
    }

    if ($missing.Count -gt 0) {
        Write-Fail "Missing required tools: $($missing -join ', ')"
        Write-Host ""
        Write-Host "  Install guides:" -ForegroundColor Yellow
        if ($missing -contains 'ssh') {
            Write-Host "    OpenSSH  : Settings > System > Optional Features > OpenSSH Client"
        }
        if ($missing -contains 'mysqldump' -or $missing -contains 'mysql') {
            Write-Host "    MySQL    : winget install Oracle.MySQL"
            Write-Host "               OR https://dev.mysql.com/downloads/mysql/"
            Write-Host "               Ensure mysqldump.exe and mysql.exe are in your PATH."
        }
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
function Read-Input {
    param(
        [string]$Label,
        [string]$Default = ''
    )
    if ($Default -ne '') {
        $value = Read-Host "  $Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        return $value
    } else {
        $value = Read-Host "  $Label"
        return $value
    }
}

function Read-Password {
    param([string]$Label)
    $secure = Read-Host "  $Label" -AsSecureString
    # Convert SecureString to plain text (needed for passing to mysqldump via env var)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-YesNo {
    param(
        [string]$Label,
        [string]$Default = 'y'
    )
    $opts = if ($Default -eq 'y') { 'Y/n' } else { 'y/N' }
    $value = Read-Host "  $Label ($opts)"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.ToLower()[0].ToString()
}

# ---------------------------------------------------------------------------
# SSH validation
# ---------------------------------------------------------------------------
function Test-SshConnection {
    param($User, $Host)
    Write-Step "Testing SSH connection to ${User}@${Host} ..."

    ssh -o BatchMode=yes `
        -o ConnectTimeout=10 `
        -o StrictHostKeyChecking=accept-new `
        "${User}@${Host}" "echo OK" 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "SSH connection successful."
    } else {
        Write-Fail "Cannot connect to ${User}@${Host} via SSH."
        Write-Host ""
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "    1. Host unreachable (check firewall / VPN)."
        Write-Host "    2. No SSH key found. Generate one with:"
        Write-Host "         ssh-keygen -t ed25519"
        Write-Host "    3. Public key not in server's authorized_keys."
        Write-Host ""
        Write-Host "  Copy your key to the server:" -ForegroundColor Cyan
        Write-Host "    type `$env:USERPROFILE\.ssh\id_ed25519.pub | ssh ${User}@${Host} `"cat >> ~/.ssh/authorized_keys`""
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Remote mysqldump check
# ---------------------------------------------------------------------------
function Test-RemoteMysqldump {
    param($User, $Host)
    Write-Info "Checking mysqldump on remote host ..."

    ssh "${User}@${Host}" "command -v mysqldump" 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "mysqldump not found on ${Host}. Install mysql-client on the server first."
    }
    Write-Ok "mysqldump found on remote host."
}

# ---------------------------------------------------------------------------
# Test local MySQL connection
# ---------------------------------------------------------------------------
function Test-LocalConnection {
    param($Host, $Port, $User, $Pass)
    Write-Info "Testing local MySQL connection ..."

    $env:MYSQL_PWD = $Pass
    try {
        mysql -h $Host -P $Port -u $User --connect-timeout=5 -e "SELECT 1" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Cannot connect to local MySQL. Check host, port, user and password."
        }
    } finally {
        Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    }

    Write-Ok "Local MySQL connection successful."
}

# ---------------------------------------------------------------------------
# Dump → transfer
# ---------------------------------------------------------------------------
function Invoke-Dump {
    param($SshUser, $SshHost, $RemoteHost, $RemotePort, $RemoteUser, $RemotePass, $DbName, $TempDir)
    Write-Step "Dumping remote database ..."

    # Password passed via MYSQL_PWD env var on the remote side — never in process list
    $remoteCmd  = "MYSQL_PWD='$RemotePass' mysqldump"
    $remoteCmd += " -h'$RemoteHost' -P'$RemotePort' -u'$RemoteUser'"
    $remoteCmd += " --single-transaction --routines --triggers"
    $remoteCmd += " --set-gtid-purged=OFF --no-tablespaces"
    $remoteCmd += " '$DbName' | gzip"

    $archivePath = Join-Path $TempDir 'dump.sql.gz'

    # Stream dump over SSH into local file as raw bytes
    & ssh "${SshUser}@${SshHost}" $remoteCmd | Set-Content -Path $archivePath -AsByteStream -NoNewline

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Dump failed. Check remote MySQL credentials and database name."
    }

    $fileInfo = Get-Item $archivePath
    if ($fileInfo.Length -eq 0) {
        Stop-WithError "Dump produced an empty file. Check remote MySQL credentials and database name."
    }

    $sizeMb = [math]::Round($fileInfo.Length / 1MB, 2)
    Write-Ok "Dump complete — archive size: ${sizeMb} MB."

    return $archivePath
}

# ---------------------------------------------------------------------------
# Optional drop + recreate
# ---------------------------------------------------------------------------
function Invoke-Drop {
    param($LocalHost, $LocalPort, $LocalUser, $LocalPass, $DbName)
    Write-Step "Dropping and recreating local database '$DbName' ..."

    $env:MYSQL_PWD = $LocalPass
    try {
        mysql -h $LocalHost -P $LocalPort -u $LocalUser `
            -e "DROP DATABASE IF EXISTS \`$DbName\`;" 2>$null | Out-Null

        mysql -h $LocalHost -P $LocalPort -u $LocalUser `
            -e "CREATE DATABASE \`$DbName\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Could not recreate local database '$DbName'."
        }
    } finally {
        Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    }

    Write-Ok "Database '$DbName' recreated with utf8mb4 charset."
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
function Invoke-Restore {
    param($LocalHost, $LocalPort, $LocalUser, $LocalPass, $DbName, $ArchivePath)
    Write-Step "Restoring into local database '$DbName' ..."

    $env:MYSQL_PWD = $LocalPass
    try {
        # Decompress and pipe into mysql
        # PowerShell 5.1 doesn't have native gzip — use a .NET stream
        $inStream  = [System.IO.File]::OpenRead($ArchivePath)
        $gzStream  = New-Object System.IO.Compression.GZipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
        $reader    = New-Object System.IO.StreamReader($gzStream)
        $sqlContent = $reader.ReadToEnd()
        $reader.Close()
        $gzStream.Close()
        $inStream.Close()

        $sqlContent | mysql -h $LocalHost -P $LocalPort -u $LocalUser $DbName

        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Restore failed. Check local MySQL credentials and permissions."
        }
    } finally {
        Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    }

    Write-Ok "Restore complete."
}

# ---------------------------------------------------------------------------
# Secure temp file deletion
# ---------------------------------------------------------------------------
function Remove-SecureFile {
    param($Path)
    if (-not (Test-Path $Path)) { return }
    try {
        # Overwrite with zeros before deleting
        $size   = (Get-Item $Path).Length
        $zeros  = New-Object byte[] $size
        [System.IO.File]::WriteAllBytes($Path, $zeros)
        Remove-Item $Path -Force
    } catch {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Post-import stats
# ---------------------------------------------------------------------------
function Show-Stats {
    param($LocalHost, $LocalPort, $LocalUser, $LocalPass, $DbName)

    Write-Section "Import statistics"

    $env:MYSQL_PWD = $LocalPass
    try {
        $query = "SELECT CONCAT('  Table  ', table_name, ': ', table_rows, ' rows (approx)') " +
                 "FROM information_schema.tables " +
                 "WHERE table_schema = '$DbName' ORDER BY table_name;"

        $result = mysql -h $LocalHost -P $LocalPort -u $LocalUser `
                        --silent --skip-column-names $DbName -e $query 2>$null

        if ($LASTEXITCODE -eq 0 -and $result) {
            $result | ForEach-Object { Write-Host $_ }
        } else {
            Write-Warn "Could not retrieve table stats."
        }
    } finally {
        Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Main {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Blue
    Write-Host "  |      MySQL Sync Tool -- MwSpace LLC       |" -ForegroundColor Blue
    Write-Host "  |         v$SCRIPT_VERSION   (Windows)              |" -ForegroundColor Blue
    Write-Host "  +------------------------------------------+" -ForegroundColor Blue
    Write-Host ""

    Test-Dependencies
    $cfg = Load-SyncConfig

    # ── Defaults from saved config ─────────────────────────────────────────
    $defSshUser      = if ($cfg) { $cfg.SSH_USER }       else { '' }
    $defSshHost      = if ($cfg) { $cfg.SSH_HOST }       else { '' }
    $defLocalHost    = if ($cfg) { $cfg.LOCAL_DB_HOST }  else { '127.0.0.1' }
    $defLocalPort    = if ($cfg) { $cfg.LOCAL_DB_PORT }  else { '3306' }
    $defLocalUser    = if ($cfg) { $cfg.LOCAL_DB_USER }  else { 'root' }
    $defLocalPass    = if ($cfg) { $cfg.LOCAL_DB_PASS }  else { '' }

    # ── SSH ────────────────────────────────────────────────────────────────
    Write-Section "SSH Configuration"
    $sshUser = Read-Input "Remote SSH user"      $defSshUser
    if ([string]::IsNullOrWhiteSpace($sshUser)) { Stop-WithError "SSH user is required." }

    $sshHost = Read-Input "Remote SSH host / IP" $defSshHost
    if ([string]::IsNullOrWhiteSpace($sshHost)) { Stop-WithError "SSH host is required." }

    # ── Remote MySQL credentials (always prompted, never saved) ───────────
    Write-Section "Remote MySQL Credentials"
    Write-Warn "Remote credentials are never saved to disk."
    Write-Host ""

    $remoteHost = Read-Input    "Remote MySQL host"     "127.0.0.1"
    $remotePort = Read-Input    "Remote MySQL port"     "3306"
    $remoteUser = Read-Input    "Remote MySQL user"     "root"
    $remotePass = Read-Password "Remote MySQL password"

    # ── Local MySQL credentials (saved to config) ─────────────────────────
    Write-Section "Local MySQL Credentials"
    Write-Info "These will be saved to $CONFIG_FILE (user-only permissions)."
    Write-Host ""

    $localHost = Read-Input    "Local MySQL host"     $defLocalHost
    $localPort = Read-Input    "Local MySQL port"     $defLocalPort
    $localUser = Read-Input    "Local MySQL user"     $defLocalUser
    $localPass = Read-Password "Local MySQL password"

    # ── Target ─────────────────────────────────────────────────────────────
    Write-Section "Sync Target"
    $dbName = Read-Input "Database name to sync (required)" ''
    if ([string]::IsNullOrWhiteSpace($dbName)) { Stop-WithError "Database name is required." }

    # ── Options ────────────────────────────────────────────────────────────
    Write-Section "Sync Options"
    $dropFirst = Read-YesNo "Drop and recreate local database before restore?" 'y'

    if (-not $NoSave) {
        $saveCfg = Read-YesNo "Save local configuration for future runs?" 'y'
        if ($saveCfg -eq 'y') {
            Save-SyncConfig @{
                SSH_USER      = $sshUser
                SSH_HOST      = $sshHost
                LOCAL_DB_HOST = $localHost
                LOCAL_DB_PORT = $localPort
                LOCAL_DB_USER = $localUser
                LOCAL_DB_PASS = $localPass
            }
        }
    }

    # ── Summary ────────────────────────────────────────────────────────────
    $modeLabel = if ($dropFirst -eq 'y') { 'replace (drop + restore)' } else { 'merge (no drop)' }

    Write-Section "Summary"
    Write-Host "  Source (remote) : ${sshUser}@${sshHost}  ->  ${remoteUser}@${remoteHost}:${remotePort}"
    Write-Host "  Target (local)  : localhost  ->  ${localUser}@${localHost}:${localPort}"
    Write-Host "  Database        : $dbName"
    Write-Host "  Mode            : $modeLabel"
    Write-Host ""

    $confirm = Read-YesNo "Proceed with synchronisation?" 'y'
    if ($confirm -ne 'y') { Write-Host "Aborted."; exit 0 }

    # ── Temp directory ─────────────────────────────────────────────────────
    $tempDir = Join-Path $TEMP_BASE ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        # ── Pipeline ───────────────────────────────────────────────────────
        Test-SshConnection    $sshUser $sshHost
        Test-RemoteMysqldump  $sshUser $sshHost
        Test-LocalConnection  $localHost $localPort $localUser $localPass

        $archive = Invoke-Dump $sshUser $sshHost $remoteHost $remotePort $remoteUser $remotePass $dbName $tempDir

        if ($dropFirst -eq 'y') {
            Invoke-Drop    $localHost $localPort $localUser $localPass $dbName
        }

        Invoke-Restore     $localHost $localPort $localUser $localPass $dbName $archive
        Show-Stats         $localHost $localPort $localUser $localPass $dbName

    } finally {
        # Secure cleanup — always runs even on error
        $dumpFile = Join-Path $tempDir 'dump.sql.gz'
        Remove-SecureFile $dumpFile
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # ── Done ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Green
    Write-Host "  |     Synchronisation completed  OK         |" -ForegroundColor Green
    Write-Host "  +------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Database : $dbName"
    Write-Host "  From     : ${sshUser}@${sshHost}"
    Write-Host "  To       : localhost"
    Write-Host ""
}

Main
