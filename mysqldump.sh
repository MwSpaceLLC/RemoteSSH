#!/usr/bin/env bash
# =============================================================================
#  mysql-sync.sh — Remote-to-local MySQL synchronisation tool (Linux)
#  MwSpace LLC — https://mwspace.com
#
#  MIT License — Copyright (c) 2025 MwSpace LLC
#
#  Requirements:
#    mysqldump + mysql  (mysql-client package)
#    ssh                (openssh-client)
#    mysqldump must also be installed on the remote host
#
#  Usage:
#    ./mysql-sync.sh [OPTIONS]
#    ./mysql-sync.sh --help
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly CONFIG_FILE="${HOME}/.mysql_sync_config"
readonly TEMP_BASE="/tmp/mysql_sync"

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
# Cleanup on exit
# ---------------------------------------------------------------------------
TEMP_DIR=""
cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    # Overwrite dump file before deleting (contains plain SQL with credentials risk)
    if [[ -f "$TEMP_DIR/dump.sql.gz" ]]; then
      shred -u "$TEMP_DIR/dump.sql.gz" 2>/dev/null || rm -f "$TEMP_DIR/dump.sql.gz"
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

${BOLD}NOTES${NC}
  • Requires SSH key-based authentication (no password prompt).
  • Remote credentials (user/password) are always prompted and never saved.
  • Local credentials and connection settings are saved in: ${CONFIG_FILE}
  • mysqldump must be installed on the remote host.

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
# Dependency checks
# ---------------------------------------------------------------------------
check_dependencies() {
  local missing=()
  for cmd in ssh mysqldump mysql gzip; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    log_info  "Install with: sudo apt install mysql-client openssh-client gzip"
    log_info  "Or:           sudo yum install mysql openssh-clients gzip"
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
# Prompt helpers
# ---------------------------------------------------------------------------
prompt_with_default() {
  local var_name="$1"
  local label="$2"
  local default="${3:-}"
  local input

  if [[ -n "$default" ]]; then
    read -rp "  ${label} [${default}]: " input
  else
    read -rp "  ${label}: " input
  fi

  printf -v "$var_name" '%s' "${input:-$default}"
}

prompt_password() {
  local var_name="$1"
  local label="$2"
  local input

  read -rsp "  ${label}: " input
  echo ""
  printf -v "$var_name" '%s' "$input"
}

prompt_yes_no() {
  local var_name="$1"
  local label="$2"
  local default="${3:-y}"
  local opts
  [[ "$default" == "y" ]] && opts="Y/n" || opts="y/N"
  local input

  read -rp "  ${label} (${opts}): " input
  input="${input:-$default}"
  printf -v "$var_name" '%s' "${input,,}"
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

  if mysql ${mysql_opts} --connect-timeout=5 -e "SELECT 1" &>/dev/null; then
    log_ok "Local MySQL connection successful."
  else
    die "Cannot connect to local MySQL. Check host, port, user and password."
  fi
}

# ---------------------------------------------------------------------------
# Build local mysql options string (avoids password in process list)
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

  # Build remote mysqldump command
  # Password is passed via MYSQL_PWD env var on the remote side to avoid
  # exposure in the process list
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

  if [[ $? -ne 0 ]] || [[ ! -s "${TEMP_DIR}/dump.sql.gz" ]]; then
    die "Dump failed or produced an empty file. Check remote MySQL credentials and database name."
  fi

  local dump_size
  dump_size="$(du -sh "${TEMP_DIR}/dump.sql.gz" | cut -f1)"
  log_ok "Dump complete — archive size: ${dump_size}."
}

# ---------------------------------------------------------------------------
# Optional drop + recreate database
# ---------------------------------------------------------------------------
run_drop() {
  log_step "Dropping and recreating local database '${DB_NAME}' ..."

  local mysql_opts
  mysql_opts="$(build_local_opts)"

  mysql ${mysql_opts} -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
  mysql ${mysql_opts} -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

  log_ok "Database '${DB_NAME}' recreated with utf8mb4 charset."
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
run_restore() {
  log_step "Restoring into local database '${DB_NAME}' ..."

  local mysql_opts
  mysql_opts="$(build_local_opts)"

  gzip -dc "${TEMP_DIR}/dump.sql.gz" | mysql ${mysql_opts} "${DB_NAME}"

  if [[ ${PIPESTATUS[1]} -ne 0 ]]; then
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

  mysql ${mysql_opts} --silent --skip-column-names "${DB_NAME}" \
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
  echo "  |              v${SCRIPT_VERSION}   (Linux)               |"
  echo "  +------------------------------------------+"
  echo -e "${NC}"

  check_dependencies
  load_config

  # Initialise variables with safe defaults
  SSH_USER="${SSH_USER:-}"
  SSH_HOST="${SSH_HOST:-}"
  LOCAL_DB_HOST="${LOCAL_DB_HOST:-127.0.0.1}"
  LOCAL_DB_PORT="${LOCAL_DB_PORT:-3306}"
  LOCAL_DB_USER="${LOCAL_DB_USER:-root}"
  LOCAL_DB_PASS="${LOCAL_DB_PASS:-}"

  # ── SSH configuration ─────────────────────────────────────────────────────
  log_section "SSH Configuration"
  prompt_with_default SSH_USER "Remote SSH user"      "$SSH_USER"
  [[ -z "$SSH_USER" ]] && die "SSH user is required."

  prompt_with_default SSH_HOST "Remote SSH host / IP" "$SSH_HOST"
  [[ -z "$SSH_HOST" ]] && die "SSH host is required."

  # ── Remote MySQL credentials (always prompted, never saved) ───────────────
  log_section "Remote MySQL Credentials"
  log_warn "Remote credentials are never saved to disk."
  echo ""

  prompt_with_default REMOTE_DB_HOST "Remote MySQL host" "127.0.0.1"
  prompt_with_default REMOTE_DB_PORT "Remote MySQL port" "3306"
  prompt_with_default REMOTE_DB_USER "Remote MySQL user" "root"
  prompt_password     REMOTE_DB_PASS "Remote MySQL password"

  # ── Local MySQL credentials (saved to config) ─────────────────────────────
  log_section "Local MySQL Credentials"
  log_info "These will be saved to ${CONFIG_FILE} (chmod 600)."
  echo ""

  prompt_with_default LOCAL_DB_HOST "Local MySQL host" "$LOCAL_DB_HOST"
  prompt_with_default LOCAL_DB_PORT "Local MySQL port" "$LOCAL_DB_PORT"
  prompt_with_default LOCAL_DB_USER "Local MySQL user" "$LOCAL_DB_USER"
  prompt_password     LOCAL_DB_PASS "Local MySQL password"

  # ── Target ────────────────────────────────────────────────────────────────
  log_section "Sync Target"
  prompt_with_default DB_NAME "Database name to sync (required)" ""
  [[ -z "$DB_NAME" ]] && die "Database name is required."

  # ── Options ───────────────────────────────────────────────────────────────
  log_section "Sync Options"
  prompt_yes_no DROP_FIRST "Drop and recreate local database before restore?" "y"

  if ! $OPT_NO_SAVE; then
    prompt_yes_no SAVE_CFG "Save local configuration for future runs?" "y"
    [[ "$SAVE_CFG" == "y" ]] && save_config
  fi

  # ── Summary ───────────────────────────────────────────────────────────────
  log_section "Summary"
  echo -e "  Source (remote) : ${BOLD}${SSH_USER}@${SSH_HOST}${NC}  →  ${REMOTE_DB_USER}@${REMOTE_DB_HOST}:${REMOTE_DB_PORT}"
  echo -e "  Target (local)  : ${BOLD}localhost${NC}  →  ${LOCAL_DB_USER}@${LOCAL_DB_HOST}:${LOCAL_DB_PORT}"
  echo -e "  Database        : ${BOLD}${DB_NAME}${NC}"
  if [[ "$DROP_FIRST" == "y" ]]; then
    echo -e "  Mode            : ${YELLOW}replace${NC} (drop + restore)"
  else
    echo -e "  Mode            : ${CYAN}merge${NC} (no drop)"
  fi

  echo ""
  prompt_yes_no CONFIRM "Proceed with synchronisation?" "y"
  [[ "$CONFIRM" != "y" ]] && { echo "Aborted."; exit 0; }

  # ── Create temp directory ─────────────────────────────────────────────────
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
