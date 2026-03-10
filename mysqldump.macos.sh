#!/usr/bin/env bash
# =============================================================================
#  mysqldump.macos.sh — Remote-to-local MySQL synchronisation tool (macOS)
#  MwSpace LLC — https://mwspace.com
#
#  MIT License — Copyright (c) 2025 MwSpace LLC
#
#  Requirements (install via Homebrew):
#    brew install mysql-client
#    brew install openssh        # usually pre-installed on macOS
#
#  Then add mysql-client to your PATH (Homebrew will remind you):
#    echo 'export PATH="/opt/homebrew/opt/mysql-client/bin:$PATH"' >> ~/.zshrc
#
#  Usage:
#    ./mysqldump.macos.sh [OPTIONS]
#    ./mysqldump.macos.sh --help
# =============================================================================

# macOS ships Bash 3.2 — avoid bashisms that require Bash 4+
case "$BASH_VERSION" in
  [0-2].*|3.[01].*) echo "ERROR: Bash 3.2+ required." >&2; exit 1 ;;
esac

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly CONFIG_FILE="${HOME}/.mysql_sync_config"
readonly TEMP_BASE="${TMPDIR:-/tmp}/mysql_sync"

# ---------------------------------------------------------------------------
# Homebrew PATH injection (Intel + Apple Silicon)
# ---------------------------------------------------------------------------
for brew_prefix in /opt/homebrew /usr/local; do
  [[ -d "${brew_prefix}/opt/mysql-client/bin" ]] && \
    export PATH="${brew_prefix}/opt/mysql-client/bin:${PATH}"
  [[ -d "${brew_prefix}/bin" ]] && \
    export PATH="${brew_prefix}/bin:${PATH}"
done

# ---------------------------------------------------------------------------
# Colours (disabled automatically when not a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()    { echo -e "  ${BLUE}i${NC}  $*"; }
log_ok()      { echo -e "  ${GREEN}v${NC}  $*"; }
log_warn()    { echo -e "  ${YELLOW}!${NC}  $*" >&2; }
log_error()   { echo -e "  ${RED}x${NC}  $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}>>  $*${NC}"; }
log_section() { echo -e "\n${BOLD}${BLUE}${*}${NC}"; }

die() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# Portable lowercase (Bash 3.2 safe — no ${var,,})
# ---------------------------------------------------------------------------
to_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
TEMP_DIR=""
cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    # Securely remove dump (may contain sensitive SQL data)
    if [[ -f "$TEMP_DIR/dump.sql.gz" ]]; then
      # macOS: use rm -P for secure overwrite (no shred available by default)
      rm -Pf "$TEMP_DIR/dump.sql.gz" 2>/dev/null || rm -f "$TEMP_DIR/dump.sql.gz"
    fi
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF

${BOLD}${SCRIPT_NAME}${NC} v${SCRIPT_VERSION}
MySQL remote-to-local database sync tool — MwSpace LLC

${BOLD}USAGE${NC}
  ${SCRIPT_NAME} [OPTIONS]

${BOLD}OPTIONS${NC}
  -h, --help              Show this help message and exit
  -v, --version           Print version and exit
      --no-color          Disable coloured output
      --no-save           Do not save local configuration
      --reset-config      Delete saved configuration and exit

${BOLD}REQUIREMENTS${NC}
  Install MySQL client tools via Homebrew:
    brew install mysql-client

  Then add to PATH (Apple Silicon):
    echo 'export PATH="/opt/homebrew/opt/mysql-client/bin:\$PATH"' >> ~/.zshrc

  Or for Intel Macs:
    echo 'export PATH="/usr/local/opt/mysql-client/bin:\$PATH"' >> ~/.zshrc

${BOLD}NOTES${NC}
  • Requires SSH key-based authentication (no password prompt).
  • Remote credentials (user/password) are always prompted and never saved.
  • Local credentials and SSH settings are saved in: ${CONFIG_FILE}
  • mysqldump must also be installed on the remote host.

${BOLD}EXAMPLES${NC}
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --reset-config

EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_NO_SAVE=false
OPT_RESET_CONFIG=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          usage; exit 0 ;;
    -v|--version)       echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
    --no-color)         RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC='' ;;
    --no-save)          OPT_NO_SAVE=true ;;
    --reset-config)     OPT_RESET_CONFIG=true ;;
    *)                  die "Unknown option: $1  (run '${SCRIPT_NAME} --help')" ;;
  esac
  shift
done

if $OPT_RESET_CONFIG; then
  if [[ -f "$CONFIG_FILE" ]]; then
    rm -f "$CONFIG_FILE"
    log_ok "Configuration reset: ${CONFIG_FILE} deleted."
  else
    echo "No saved configuration found."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# macOS-specific: suggest Homebrew install for missing tools
# ---------------------------------------------------------------------------
suggest_brew_install() {
  local tool="$1"
  case "$tool" in
    mysqldump|mysql)
      log_info "Install via: brew install mysql-client"
      log_info "Then add to PATH: echo 'export PATH=\"/opt/homebrew/opt/mysql-client/bin:\$PATH\"' >> ~/.zshrc"
      ;;
    ssh)
      log_info "ssh should be built-in on macOS. Try: xcode-select --install"
      ;;
    gzip)
      log_info "Install via: brew install gzip"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_dependencies() {
  local missing=()
  for cmd in ssh mysqldump mysql gzip; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    for t in "${missing[@]}"; do suggest_brew_install "$t"; done
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Configuration persistence (local credentials only)
# ---------------------------------------------------------------------------
save_config() {
  cat > "$CONFIG_FILE" <<CFG
SSH_USER="${SSH_USER}"
SSH_HOST="${SSH_HOST}"
LOCAL_DB_HOST="${LOCAL_DB_HOST}"
LOCAL_DB_PORT="${LOCAL_DB_PORT}"
LOCAL_DB_USER="${LOCAL_DB_USER}"
LOCAL_DB_PASS="${LOCAL_DB_PASS}"
CFG
  chmod 600 "$CONFIG_FILE"
  log_ok "Local configuration saved to ${CONFIG_FILE}"
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log_ok "Previous configuration loaded from ${CONFIG_FILE}"
  fi
}

# ---------------------------------------------------------------------------
# Prompt helpers (Bash 3.2 safe — returns via stdout)
# ---------------------------------------------------------------------------
_prompt_read() {
  local label="$1"
  local default="$2"
  local result

  if [[ -n "$default" ]]; then
    read -rp "  ${label} [${default}]: " result
  else
    read -rp "  ${label}: " result
  fi

  echo "${result:-$default}"
}

_prompt_password() {
  local label="$1"
  local result

  read -rsp "  ${label}: " result
  echo "" >&2   # newline after hidden input (to stderr to not pollute stdout capture)
  echo "$result"
}

# ---------------------------------------------------------------------------
# SSH validation
# ---------------------------------------------------------------------------
test_ssh_connection() {
  log_step "Testing SSH connection to ${SSH_USER}@${SSH_HOST} ..."
  if ssh -o BatchMode=yes \
         -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=accept-new \
         "${SSH_USER}@${SSH_HOST}" true 2>/dev/null; then
    log_ok "SSH connection successful."
  else
    log_error "Cannot connect to ${SSH_USER}@${SSH_HOST} via SSH."
    cat >&2 <<EOF

  Possible causes:
    1. Host unreachable (check firewall / VPN).
    2. No SSH key configured (~/.ssh/id_rsa or id_ed25519).
    3. Public key not in server's authorized_keys.

  Quick fix:
    ssh-copy-id ${SSH_USER}@${SSH_HOST}

  Or manually:
    cat ~/.ssh/id_ed25519.pub | ssh ${SSH_USER}@${SSH_HOST} "cat >> ~/.ssh/authorized_keys"
EOF
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Remote mysqldump availability check
# ---------------------------------------------------------------------------
test_remote_mysqldump() {
  log_info "Checking mysqldump on remote host ..."
  if ! ssh "${SSH_USER}@${SSH_HOST}" "command -v mysqldump" &>/dev/null; then
    die "mysqldump not found on ${SSH_HOST}. Install mysql-client on the server first."
  fi
  log_ok "mysqldump found on remote host."
}

# ---------------------------------------------------------------------------
# Test local MySQL connection
# ---------------------------------------------------------------------------
test_local_connection() {
  log_info "Testing local MySQL connection ..."

  local mysql_opts
  mysql_opts="$(build_local_opts)"

  # eval needed because build_local_opts returns a string with flags
  if eval "mysql ${mysql_opts} --connect-timeout=5 -e 'SELECT 1'" &>/dev/null; then
    log_ok "Local MySQL connection successful."
  else
    die "Cannot connect to local MySQL. Check host, port, user and password."
  fi
}

# ---------------------------------------------------------------------------
# Build local mysql options string
# ---------------------------------------------------------------------------
build_local_opts() {
  local opts="-h${LOCAL_DB_HOST} -P${LOCAL_DB_PORT} -u${LOCAL_DB_USER}"
  [[ -n "$LOCAL_DB_PASS" ]] && opts="${opts} -p${LOCAL_DB_PASS}"
  echo "$opts"
}

# ---------------------------------------------------------------------------
# Dump → transfer
# ---------------------------------------------------------------------------
run_dump() {
  log_step "Dumping remote database ..."

  local remote_cmd
  remote_cmd="MYSQL_PWD='${REMOTE_DB_PASS}' mysqldump"
  remote_cmd="${remote_cmd} -h'${REMOTE_DB_HOST}'"
  remote_cmd="${remote_cmd} -P'${REMOTE_DB_PORT}'"
  remote_cmd="${remote_cmd} -u'${REMOTE_DB_USER}'"
  remote_cmd="${remote_cmd} --single-transaction"
  remote_cmd="${remote_cmd} --routines"
  remote_cmd="${remote_cmd} --triggers"
  remote_cmd="${remote_cmd} --set-gtid-purged=OFF"
  remote_cmd="${remote_cmd} --no-tablespaces"
  remote_cmd="${remote_cmd} '${DB_NAME}'"
  remote_cmd="${remote_cmd} | gzip"

  ssh "${SSH_USER}@${SSH_HOST}" "$remote_cmd" > "${TEMP_DIR}/dump.sql.gz"

  if [[ ! -s "${TEMP_DIR}/dump.sql.gz" ]]; then
    die "Dump failed or produced an empty file. Check remote MySQL credentials and database name."
  fi

  # macOS-compatible file size (BSD du, no --si flag)
  local dump_size
  dump_size="$(du -sh "${TEMP_DIR}/dump.sql.gz" | awk '{print $1}')"
  log_ok "Dump complete — archive size: ${dump_size}."
}

# ---------------------------------------------------------------------------
# Optional drop + recreate database
# ---------------------------------------------------------------------------
run_drop() {
  log_step "Dropping and recreating local database '${DB_NAME}' ..."

  local mysql_opts
  mysql_opts="$(build_local_opts)"

  eval "mysql ${mysql_opts} -e \"DROP DATABASE IF EXISTS \\\`${DB_NAME}\\\`;\"" 2>/dev/null || true
  eval "mysql ${mysql_opts} -e \"CREATE DATABASE \\\`${DB_NAME}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""

  log_ok "Database '${DB_NAME}' recreated with utf8mb4 charset."
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
run_restore() {
  log_step "Restoring into local database '${DB_NAME}' ..."

  local mysql_opts
  mysql_opts="$(build_local_opts)"

  # Use a subshell to capture pipe exit codes (Bash 3.2 safe, no PIPESTATUS trick)
  if ! (gzip -dc "${TEMP_DIR}/dump.sql.gz" | eval "mysql ${mysql_opts} '${DB_NAME}'"); then
    die "Restore failed. Check local MySQL credentials and permissions."
  fi

  log_ok "Restore complete."
}

# ---------------------------------------------------------------------------
# Post-import stats
# ---------------------------------------------------------------------------
print_stats() {
  log_section "Import statistics"

  local mysql_opts
  mysql_opts="$(build_local_opts)"

  eval "mysql ${mysql_opts} --silent --skip-column-names '${DB_NAME}'" \
    -e "SELECT CONCAT('  Table  ', table_name, ': ', table_rows, ' rows (approx)')
        FROM information_schema.tables
        WHERE table_schema = '${DB_NAME}'
        ORDER BY table_name;" 2>/dev/null \
    || log_warn "Could not retrieve table stats."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  +------------------------------------------+"
  echo "  |      MySQL Sync Tool -- MwSpace LLC       |"
  echo "  |         v${SCRIPT_VERSION}   (macOS)               |"
  echo "  +------------------------------------------+"
  echo -e "${NC}"

  check_dependencies
  load_config

  # Initialise variables with safe defaults (set -u safe)
  SSH_USER="${SSH_USER:-}"
  SSH_HOST="${SSH_HOST:-}"
  LOCAL_DB_HOST="${LOCAL_DB_HOST:-127.0.0.1}"
  LOCAL_DB_PORT="${LOCAL_DB_PORT:-3306}"
  LOCAL_DB_USER="${LOCAL_DB_USER:-root}"
  LOCAL_DB_PASS="${LOCAL_DB_PASS:-}"

  # ── SSH configuration ─────────────────────────────────────────────────────
  log_section "SSH Configuration"
  SSH_USER="$(_prompt_read "Remote SSH user"      "$SSH_USER")"
  [[ -z "$SSH_USER" ]] && die "SSH user is required."

  SSH_HOST="$(_prompt_read "Remote SSH host / IP" "$SSH_HOST")"
  [[ -z "$SSH_HOST" ]] && die "SSH host is required."

  # ── Remote MySQL credentials (always prompted, never saved) ───────────────
  log_section "Remote MySQL Credentials"
  log_warn "Remote credentials are never saved to disk."
  echo ""

  REMOTE_DB_HOST="$(_prompt_read "Remote MySQL host" "127.0.0.1")"
  REMOTE_DB_PORT="$(_prompt_read "Remote MySQL port" "3306")"
  REMOTE_DB_USER="$(_prompt_read "Remote MySQL user" "root")"
  REMOTE_DB_PASS="$(_prompt_password "Remote MySQL password")"

  # ── Local MySQL credentials (saved to config) ─────────────────────────────
  log_section "Local MySQL Credentials"
  log_info "These will be saved to ${CONFIG_FILE} (chmod 600)."
  echo ""

  LOCAL_DB_HOST="$(_prompt_read "Local MySQL host" "$LOCAL_DB_HOST")"
  LOCAL_DB_PORT="$(_prompt_read "Local MySQL port" "$LOCAL_DB_PORT")"
  LOCAL_DB_USER="$(_prompt_read "Local MySQL user" "$LOCAL_DB_USER")"
  LOCAL_DB_PASS="$(_prompt_password "Local MySQL password")"

  # ── Target ────────────────────────────────────────────────────────────────
  log_section "Sync Target"
  DB_NAME="$(_prompt_read "Database name to sync (required)" "")"
  [[ -z "$DB_NAME" ]] && die "Database name is required."

  # ── Options ───────────────────────────────────────────────────────────────
  log_section "Sync Options"
  local drop_ans
  drop_ans="$(_prompt_read "Drop and recreate local database before restore? (y/n)" "y")"
  DROP_FIRST="$(to_lower "$drop_ans")"

  if ! $OPT_NO_SAVE; then
    local save_ans
    save_ans="$(_prompt_read "Save local configuration for future runs? (y/n)" "y")"
    [[ "$(to_lower "$save_ans")" == "y" ]] && save_config
  fi

  # ── Summary ───────────────────────────────────────────────────────────────
  log_section "Summary"
  echo -e "  Source (remote) : ${BOLD}${SSH_USER}@${SSH_HOST}${NC}  ->  ${REMOTE_DB_USER}@${REMOTE_DB_HOST}:${REMOTE_DB_PORT}"
  echo -e "  Target (local)  : ${BOLD}localhost${NC}  ->  ${LOCAL_DB_USER}@${LOCAL_DB_HOST}:${LOCAL_DB_PORT}"
  echo -e "  Database        : ${BOLD}${DB_NAME}${NC}"
  if [[ "$DROP_FIRST" == "y" ]]; then
    echo -e "  Mode            : ${YELLOW}replace${NC} (drop + restore)"
  else
    echo -e "  Mode            : ${CYAN}merge${NC} (no drop)"
  fi

  echo ""
  local confirm_ans
  confirm_ans="$(_prompt_read "Proceed with synchronisation? (y/n)" "y")"
  [[ "$(to_lower "$confirm_ans")" != "y" ]] && { echo "Aborted."; exit 0; }

  # ── Create temp directory (macOS mktemp syntax) ───────────────────────────
  TEMP_DIR="$(mktemp -d "${TEMP_BASE}_XXXXXX")"

  # ── Run pipeline ──────────────────────────────────────────────────────────
  test_ssh_connection
  test_remote_mysqldump
  test_local_connection
  run_dump
  [[ "$DROP_FIRST" == "y" ]] && run_drop
  run_restore
  print_stats

  # ── Done ──────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}${GREEN}"
  echo "  +------------------------------------------+"
  echo "  |     Synchronisation completed  v         |"
  echo "  +------------------------------------------+"
  echo -e "${NC}"
  echo -e "  Database : ${BOLD}${DB_NAME}${NC}"
  echo -e "  From     : ${BOLD}${SSH_USER}@${SSH_HOST}${NC}"
  echo -e "  To       : ${BOLD}localhost${NC}"
  echo ""
}

main "$@"
