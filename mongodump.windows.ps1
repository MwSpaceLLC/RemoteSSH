# =============================================================================
#  mongodb-sync.ps1 — Remote-to-local MongoDB synchronisation tool (Windows)
#  MwSpace LLC — https://mwspace.com
#
#  MIT License — Copyright (c) 2025 MwSpace LLC
#
#  Requirements:
#    - PowerShell 5.1+ or PowerShell 7+
#    - OpenSSH for Windows (Settings > Optional Features > OpenSSH Client)
#      OR Git for Windows (ships ssh.exe)
#    - MongoDB Database Tools:
#      https://www.mongodb.com/try/download/database-tools
#      (ensure mongodump.exe / mongorestore.exe are in your PATH)
#
#  Usage:
#    .\mongodb-sync.ps1
#    .\mongodb-sync.ps1 -Help
#    .\mongodb-sync.ps1 -ResetConfig
#    .\mongodb-sync.ps1 -NoSave
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
$CONFIG_FILE    = Join-Path $env:USERPROFILE '.mongodb_sync_config.json'
$TEMP_BASE      = Join-Path $env:TEMP 'mongodb_sync'

# ---------------------------------------------------------------------------
# Colour helpers (auto-disabled with -NoColor or when not interactive)
# ---------------------------------------------------------------------------
function Write-Ok      { param($Msg) Write-Host "  [OK] $Msg"   -ForegroundColor Green  }
function Write-Info    { param($Msg) Write-Host "  [..] $Msg"   -ForegroundColor Cyan   }
function Write-Warn    { param($Msg) Write-Host "  [!!] $Msg"   -ForegroundColor Yellow }
function Write-Fail    { param($Msg) Write-Host "  [XX] $Msg"   -ForegroundColor Red    }
function Write-Step    { param($Msg) Write-Host "`n>>  $Msg"    -ForegroundColor Cyan   }
function Write-Section { param($Msg) Write-Host "`n$Msg"        -ForegroundColor Blue   }

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
MongoDB remote-to-local database sync tool — MwSpace LLC

USAGE
  .\$SCRIPT_NAME [OPTIONS]

OPTIONS
  -Help              Show this help message and exit
  -Version           Print version and exit
  -NoColor           Disable coloured output
  -NoSave            Do not prompt to save configuration
  -ResetConfig       Delete saved configuration and exit

REQUIREMENTS
  1. OpenSSH Client (Windows 10/11):
       Settings > System > Optional Features > OpenSSH Client
  2. MongoDB Database Tools:
       https://www.mongodb.com/try/download/database-tools
       Add the install folder to your PATH environment variable.

NOTES
  * Requires SSH key-based authentication (no password prompt).
  * mongodump must also be installed on the remote host.
  * Configuration is saved to: $CONFIG_FILE

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
# Configuration persistence
# ---------------------------------------------------------------------------
function Save-Config {
    param($Cfg)
    $Cfg | ConvertTo-Json | Set-Content -Path $CONFIG_FILE -Encoding UTF8
    # Restrict read permissions to current user only
    $acl  = Get-Acl $CONFIG_FILE
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, 'FullControl', 'Allow'
    )
    $acl.AddAccessRule($rule)
    Set-Acl $CONFIG_FILE $acl
    Write-Ok "Configuration saved to $CONFIG_FILE"
}

function Load-Config {
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
    foreach ($cmd in @('ssh', 'mongodump', 'mongorestore')) {
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
        if ($missing -contains 'mongodump' -or $missing -contains 'mongorestore') {
            Write-Host "    MongoDB Tools: https://www.mongodb.com/try/download/database-tools"
            Write-Host "    Remember to add the install path to your PATH environment variable."
        }
        exit 1
    }

    # Detect mongosh or legacy mongo for stats
    if (Get-Command 'mongosh' -ErrorAction SilentlyContinue) {
        return 'mongosh'
    } elseif (Get-Command 'mongo' -ErrorAction SilentlyContinue) {
        return 'mongo'
    } else {
        Write-Warn "mongosh not found — post-import document counts will be skipped."
        Write-Host "    Install: https://www.mongodb.com/try/download/shell" -ForegroundColor Cyan
        return ''
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
        return Read-Host "  $Label"
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

    $result = ssh -o BatchMode=yes `
                  -o ConnectTimeout=10 `
                  -o StrictHostKeyChecking=accept-new `
                  "${User}@${Host}" "echo OK" 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "SSH connection successful."
    } else {
        Write-Fail "Cannot connect to ${User}@${Host} via SSH."
        Write-Host ""
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "    1. Host unreachable (check firewall / VPN)."
        Write-Host "    2. No SSH key found (generate with: ssh-keygen -t ed25519)"
        Write-Host "    3. Public key not in server's authorized_keys."
        Write-Host ""
        Write-Host "  Copy your key to the server:" -ForegroundColor Cyan
        Write-Host "    type `$env:USERPROFILE\.ssh\id_ed25519.pub | ssh ${User}@${Host} `"cat >> ~/.ssh/authorized_keys`""
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Remote mongodump check
# ---------------------------------------------------------------------------
function Test-RemoteMongodump {
    param($User, $Host)
    Write-Info "Checking mongodump on remote host ..."
    $check = ssh "${User}@${Host}" "command -v mongodump || where mongodump" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "mongodump not found on ${Host}. Install MongoDB Database Tools on the server."
    }
    Write-Ok "mongodump found on remote host."
}

# ---------------------------------------------------------------------------
# Dump → transfer
# ---------------------------------------------------------------------------
function Invoke-Dump {
    param($SshUser, $SshHost, $RemoteUri, $DbName, $Collection, $TempDir)
    Write-Step "Dumping remote database ..."

    $remoteCmd = "mongodump --uri=`"$RemoteUri`" --db=`"$DbName`" --archive --gzip"
    if ($Collection -ne '') {
        $remoteCmd += " --collection=`"$Collection`""
    }

    $archivePath = Join-Path $TempDir 'dump.archive.gz'

    # Stream dump over SSH into local file
    $sshArgs = @("${SshUser}@${SshHost}", $remoteCmd)
    & ssh @sshArgs | Set-Content -Path $archivePath -AsByteStream -NoNewline

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Dump failed. Check mongodump on the remote host."
    }

    $size = (Get-Item $archivePath).Length / 1MB
    Write-Ok ("Dump complete — archive size: {0:N2} MB." -f $size)

    return $archivePath
}

# ---------------------------------------------------------------------------
# Optional drop
# ---------------------------------------------------------------------------
function Invoke-Drop {
    param($MongoCli, $LocalUri, $DbName, $Collection)
    Write-Step "Dropping local data before restore ..."

    if ($MongoCli -eq '') {
        Write-Warn "mongo CLI not found, skipping drop step."
        return
    }

    if ($Collection -ne '') {
        & $MongoCli "${LocalUri}/${DbName}" --quiet `
            --eval "db.getCollection('$Collection').drop()" 2>$null | Out-Null
        Write-Ok "Collection '$Collection' dropped (if it existed)."
    } else {
        & $MongoCli "${LocalUri}/${DbName}" --quiet `
            --eval "db.dropDatabase()" 2>$null | Out-Null
        Write-Ok "Database '$DbName' dropped (if it existed)."
    }
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
function Invoke-Restore {
    param($LocalUri, $DbName, $Collection, $ArchivePath)
    Write-Step "Restoring into local database ..."

    $nsInclude = if ($Collection -ne '') { "${DbName}.${Collection}" } else { "${DbName}.*" }

    mongorestore `
        --uri="$LocalUri" `
        --archive="$ArchivePath" `
        --gzip `
        --nsInclude="$nsInclude"

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Restore failed."
    }
    Write-Ok "Restore complete."
}

# ---------------------------------------------------------------------------
# Post-import stats
# ---------------------------------------------------------------------------
function Show-Stats {
    param($MongoCli, $LocalUri, $DbName, $Collection)

    if ($MongoCli -eq '') { return }

    Write-Section "Import statistics"

    if ($Collection -ne '') {
        $count = & $MongoCli "${LocalUri}/${DbName}" --quiet `
            --eval "db.getCollection('$Collection').countDocuments()" 2>$null
        Write-Host "  Collection  ${Collection}: $count documents"
    } else {
        & $MongoCli "${LocalUri}/${DbName}" --quiet --eval @"
db.getCollectionNames().forEach(function(c) {
    var n = db.getCollection(c).countDocuments();
    print('  Collection  ' + c + ': ' + n + ' documents');
});
"@ 2>$null
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Main {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Blue
    Write-Host "  |     MongoDB Sync Tool -- MwSpace LLC      |" -ForegroundColor Blue
    Write-Host "  |         v$SCRIPT_VERSION   (Windows)              |" -ForegroundColor Blue
    Write-Host "  +------------------------------------------+" -ForegroundColor Blue
    Write-Host ""

    $mongoCli = Test-Dependencies
    $cfg      = Load-Config

    # ── Defaults from saved config ─────────────────────────────────────────
    $defSshUser   = if ($cfg) { $cfg.SSH_USER }           else { '' }
    $defSshHost   = if ($cfg) { $cfg.SSH_HOST }           else { '' }
    $defRemoteUri = if ($cfg) { $cfg.REMOTE_MONGO_URI }   else { 'mongodb://localhost:27017' }
    $defLocalUri  = if ($cfg) { $cfg.LOCAL_MONGO_URI }    else { 'mongodb://localhost:27017' }

    # ── SSH ────────────────────────────────────────────────────────────────
    Write-Section "SSH Configuration"
    $sshUser = Read-Input "Remote SSH user"      $defSshUser
    if ([string]::IsNullOrWhiteSpace($sshUser)) { Stop-WithError "SSH user is required." }

    $sshHost = Read-Input "Remote SSH host / IP" $defSshHost
    if ([string]::IsNullOrWhiteSpace($sshHost)) { Stop-WithError "SSH host is required." }

    # ── MongoDB URIs ───────────────────────────────────────────────────────
    Write-Section "MongoDB Configuration"
    $remoteUri = Read-Input "Remote MongoDB URI" $defRemoteUri
    $localUri  = Read-Input "Local  MongoDB URI" $defLocalUri

    # ── Target ─────────────────────────────────────────────────────────────
    Write-Section "Sync Target"
    $dbName = Read-Input "Database name (required)" ''
    if ([string]::IsNullOrWhiteSpace($dbName)) { Stop-WithError "Database name is required." }

    $collection = Read-Input "Collection name (leave empty for full DB)" ''

    # ── Options ────────────────────────────────────────────────────────────
    Write-Section "Sync Options"
    $dropFirst = Read-YesNo "Drop local data before restore?" 'y'

    if (-not $NoSave) {
        $saveCfg = Read-YesNo "Save configuration for future runs?" 'y'
        if ($saveCfg -eq 'y') {
            Save-Config @{
                SSH_USER         = $sshUser
                SSH_HOST         = $sshHost
                REMOTE_MONGO_URI = $remoteUri
                LOCAL_MONGO_URI  = $localUri
            }
        }
    }

    # ── Summary ────────────────────────────────────────────────────────────
    $targetDesc = if ($collection -ne '') { "${dbName}.${collection}" } else { $dbName }
    $modeLabel  = if ($dropFirst -eq 'y') { 'replace (drop + restore)' } else { 'merge (no drop)' }

    Write-Section "Summary"
    Write-Host "  Source  : ${sshUser}@${sshHost}  ($remoteUri)"
    Write-Host "  Target  : localhost  ($localUri)"
    Write-Host "  Scope   : $targetDesc"
    Write-Host "  Mode    : $modeLabel"
    Write-Host ""

    $confirm = Read-YesNo "Proceed with synchronisation?" 'y'
    if ($confirm -ne 'y') { Write-Host "Aborted."; exit 0 }

    # ── Temp directory ─────────────────────────────────────────────────────
    $tempDir = Join-Path $TEMP_BASE ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        # ── Pipeline ───────────────────────────────────────────────────────
        Test-SshConnection    $sshUser $sshHost
        Test-RemoteMongodump  $sshUser $sshHost
        $archive = Invoke-Dump $sshUser $sshHost $remoteUri $dbName $collection $tempDir
        if ($dropFirst -eq 'y') { Invoke-Drop $mongoCli $localUri $dbName $collection }
        Invoke-Restore $localUri $dbName $collection $archive
        Show-Stats     $mongoCli $localUri $dbName $collection
    } finally {
        # Always clean up temp files
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    }

    # ── Done ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Green
    Write-Host "  |     Synchronisation completed  OK         |" -ForegroundColor Green
    Write-Host "  +------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Database   : $dbName"
    if ($collection -ne '') { Write-Host "  Collection : $collection" }
    Write-Host "  From       : ${sshUser}@${sshHost}"
    Write-Host "  To         : localhost"
    Write-Host ""
}

Main
