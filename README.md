# RemoteSSH — MwSpace LLC

> A collection of production-ready shell scripts to manage remote servers, databases, and services over SSH.  
> Built and maintained by [MwSpace LLC](https://mwspace.com).

---

## Available Scripts

| Script                  | Platform | Description                                               |
| ----------------------- | -------- | --------------------------------------------------------- |
| `mongodump.sh`          | Linux    | Sync a MongoDB database from a remote server to localhost |
| `mongodump.macos.sh`    | macOS    | Same as above, fully compatible with macOS (Bash 3.2+)    |
| `mongodump.windows.ps1` | Windows  | PowerShell equivalent for Windows environments            |
| `mysqldump.sh`          | Linux    | Sync a MySQL database from a remote server to localhost   |
| `mysqldump.macos.sh`    | macOS    | Same as above, fully compatible with macOS (Bash 3.2+)    |
| `mysqldump.windows.ps1` | Windows  | PowerShell equivalent for Windows environments            |
| `update.deploy.pm2.sh`  | Linux    | PM2 Complete Deploy system                                |

> More scripts coming soon. Each script is self-contained, interactive, and requires no additional dependencies beyond the tools listed below.

---

## Quick Start — Run directly from GitHub

No clone needed. Copy and paste the command for your OS.

> **Note:** We use `curl ... | bash` instead of `bash <(curl ...)` for universal shell compatibility.  
> The `<(...)` process substitution syntax is not supported in all shells (e.g. Fish).

### 🐧 Linux — MongoDB

```bash
curl -fsSL https://raw.githubusercontent.com/MwSpaceLLC/RemoteSSH/main/mongodump.sh | bash
```

### 🐧 Linux — MySQL

```bash
curl -fsSL https://raw.githubusercontent.com/MwSpaceLLC/RemoteSSH/main/mysqldump.sh | bash
```

### 🍎 macOS — MongoDB

```bash
curl -fsSL https://raw.githubusercontent.com/MwSpaceLLC/RemoteSSH/main/mongodump.macos.sh | bash
```

### 🍎 macOS — MySQL

```bash
curl -fsSL https://raw.githubusercontent.com/MwSpaceLLC/RemoteSSH/main/mysqldump.macos.sh | bash
```

### 🪟 Windows (PowerShell) — MongoDB

```powershell
irm https://raw.githubusercontent.com/MwSpaceLLC/RemoteSSH/main/mongodump.windows.ps1 | iex
```

### 🪟 Windows (PowerShell) — MySQL

```powershell
irm https://raw.githubusercontent.com/MwSpaceLLC/RemoteSSH/main/mysqldump.windows.ps1 | iex
```

> **Note for Windows users:** if you see an execution policy error, run this first:
>
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

---

## Requirements

### SSH key-based authentication

All scripts require **passwordless SSH access** to the remote host.  
If you haven't set it up yet:

```bash
# Generate a key (if you don't have one)
ssh-keygen -t ed25519 -C "your@email.com"

# Copy it to the remote server
ssh-copy-id user@your-server.com
```

### Per-script dependencies

#### `mongodump.sh` / `mongodump.macos.sh` — Linux & macOS

- `ssh` (pre-installed on most systems)
- `mongodump` + `mongorestore` → [MongoDB Database Tools](https://www.mongodb.com/try/download/database-tools)
- `mongosh` _(optional, for post-import stats)_ → [mongosh](https://www.mongodb.com/try/download/shell)
- `mongodump` must also be installed **on the remote host**

```bash
# macOS (Homebrew)
brew tap mongodb/brew
brew install mongodb/brew/mongodb-database-tools
brew install mongodb/brew/mongosh   # optional
```

#### `mysqldump.sh` / `mysqldump.macos.sh` — Linux & macOS

- `ssh` (pre-installed on most systems)
- `mysqldump` + `mysql` + `gzip`
- `mysqldump` must also be installed **on the remote host**

```bash
# macOS (Homebrew)
brew install mysql-client

# Add to PATH — Apple Silicon:
echo 'export PATH="/opt/homebrew/opt/mysql-client/bin:$PATH"' >> ~/.zshrc

# Add to PATH — Intel:
echo 'export PATH="/usr/local/opt/mysql-client/bin:$PATH"' >> ~/.zshrc
```

#### `mongodump.windows.ps1` / `mysqldump.windows.ps1` — Windows

- **OpenSSH Client**: Settings → System → Optional Features → OpenSSH Client
- **MongoDB Database Tools**: [download here](https://www.mongodb.com/try/download/database-tools) — add the install folder to your `PATH`
- **MySQL Client Tools**: [download here](https://dev.mysql.com/downloads/mysql/) — add the install folder to your `PATH`
- **mongosh** _(optional)_: [download here](https://www.mongodb.com/try/download/shell)

---

## Features

- ✅ Interactive wizard with smart defaults
- ✅ Saves configuration locally for future runs
- ✅ SSH connection test before starting
- ✅ Remote `mongodump` / `mysqldump` availability check
- ✅ Compressed transfer (`--gzip` / `gzip`) for faster syncs
- ✅ Optional drop-before-restore or merge mode
- ✅ Post-import document / row count per collection / table
- ✅ Safe temp file cleanup on exit (even on errors)
- ✅ `--help`, `--version`, `--reset-config` flags
- ✅ Works with any shell via `curl | bash` (Fish, Zsh, Bash, sh, ...)

---

## Configuration

After the first run, settings are saved locally so you won't need to retype them:

| OS            | MongoDB config                            | MySQL config                            |
| ------------- | ----------------------------------------- | --------------------------------------- |
| Linux / macOS | `~/.mongodb_sync_config`                  | `~/.mysql_sync_config`                  |
| Windows       | `%USERPROFILE%\.mongodb_sync_config.json` | `%USERPROFILE%\.mysql_sync_config.json` |

To clear saved settings:

```bash
# Linux / macOS — MongoDB
mongodump.sh --reset-config

# Linux / macOS — MySQL
mysqldump.sh --reset-config

# Windows
.\mongodump.windows.ps1 -ResetConfig
.\mysqldump.windows.ps1 -ResetConfig
```

---

## Security

- Config files are created with **user-only read permissions** (`chmod 600` on Unix, ACL on Windows).
- SSH connections use `BatchMode=yes` — no password prompts, no interactive fallback.
- No credentials are ever stored in plain environment variables or passed via command-line arguments.
- Remote MySQL credentials are **always prompted and never saved** to disk.

---

## License

MIT License — © 2025 [MwSpace LLC](https://mwspace.com)

---

<p align="center">
  Made with ❤️ by <a href="https://mwspace.com">MwSpace LLC</a>
</p>
