#!/usr/bin/env bash
# =============================================================================
#  mongodb-sync — Remote-to-local MongoDB synchronisation tool
#  MwSpace LLC — https://mwspace.com
#
#  MIT License — Copyright (c) 2025 MwSpace LLC
#
#  Usage:
#    ./mongodb-sync.sh [OPTIONS]
#    ./mongodb-sync.sh --help
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly CONFIG_FILE="${HOME}/.mongodb_sync_config"
readonly TEMP_BASE="/tmp/mongodb_sync"

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
log_info()    { echo -e "  ${BLUE}ℹ${NC}  $*"; }
log_ok()      { echo -e "  ${GREEN}✔${NC}  $*"; }
log_warn()    { echo -e "  ${YELLOW}⚠${NC}  $*" >&2; }
log_error()   { echo -e "  ${RED}✖${NC}  $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}▶  $*${NC}"; }
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
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF

${BOLD}${SCRIPT_NAME}${NC} v${SCRIPT_VERSION}
MongoDB remote-to-local database sync tool — MwSpace LLC

${BOLD}USAGE${NC}
  ${SCRIPT_NAME} [OPTIONS]

${BOLD}OPTIONS${NC}
  -h, --help              Show this help message and exit
  -v, --version           Print version and exit
      --no-color          Disable coloured output
      --no-save           Do not prompt to save configuration
      --reset-config      Delete saved configuration and exit

${BOLD}NOTES${NC}
  • Requires SSH key-based authentication (no password prompt).
  • Both mongodump and mongorestore must be installed locally.
  • mongodump must be installed on the remote host.
  • Saved configuration is stored in: ${CONFIG_FILE}

${BOLD}EXAMPLES${NC}
  # Interactive wizard
  ${SCRIPT_NAME}

  # Reset saved defaults
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
    echo -e "${GREEN}✔${NC}  Configuration reset: ${CONFIG_FILE} deleted."
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
  for cmd in ssh mongodump mongorestore; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    log_info  "Install the MongoDB Database Tools: https://www.mongodb.com/try/download/database-tools"
    exit 1
  fi

  # Detect local mongo/mongosh for post-import stats
  if command -v mongosh &>/dev/null; then
    MONGO_CLI="mongosh"
  elif command -v mongo &>/dev/null; then
    MONGO_CLI="mongo"
  else
    MONGO_CLI=""
    log_warn "mongo / mongosh not found — post-import document counts will be skipped."
  fi
}

# ---------------------------------------------------------------------------
# Configuration persistence
# ---------------------------------------------------------------------------
save_config() {
  cat > "$CONFIG_FILE" <<CFG
SSH_USER="${SSH_USER}"
SSH_HOST="${SSH_HOST}"
REMOTE_MONGO_URI="${REMOTE_MONGO_URI}"
LOCAL_MONGO_URI="${LOCAL_MONGO_URI}"
CFG
  chmod 600 "$CONFIG_FILE"
  log_ok "Configuration saved to ${CONFIG_FILE}"
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
# prompt_with_default <variable_name> <prompt_label> [default_value]
prompt_with_default() {
  local var_name="$1"
  local label="$2"
  local default="${3:-}"
  local prompt_str

  if [[ -n "$default" ]]; then
    prompt_str="${label} [${default}]: "
  else
    prompt_str="${label}: "
  fi

  local input
  read -rp "  $prompt_str" input
  printf -v "$var_name" '%s' "${input:-$default}"
}

# prompt_yes_no <variable_name> <prompt_label> [default y|n]
prompt_yes_no() {
  local var_name="$1"
  local label="$2"
  local default="${3:-y}"
  local options="y/n"
  [[ "$default" == "n" ]] && options="y/N" || options="Y/n"

  local input
  read -rp "  ${label} (${options}): " input
  input="${input:-$default}"
  printf -v "$var_name" '%s' "${input,,}"
}

# ---------------------------------------------------------------------------
# SSH validation
# ---------------------------------------------------------------------------
test_ssh_connection() {
  log_step "Testing SSH connection to ${SSH_USER}@${SSH_HOST} …"
  if ssh -o BatchMode=yes \
         -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=accept-new \
         "${SSH_USER}@${SSH_HOST}" true 2>/dev/null; then
    log_ok "SSH connection successful."
  else
    log_error "Cannot connect to ${SSH_USER}@${SSH_HOST} via SSH."
    cat >&2 <<EOF

  Possible causes:
    1. The host is unreachable (check firewall / VPN).
    2. No SSH key is configured (~/.ssh/id_rsa or id_ed25519).
    3. Your public key is not listed in the server's authorized_keys.

  Quick fix:
    ssh-copy-id ${SSH_USER}@${SSH_HOST}
EOF
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Remote mongodump availability check
# ---------------------------------------------------------------------------
test_remote_mongodump() {
  log_info "Checking mongodump on remote host …"
  if ! ssh "${SSH_USER}@${SSH_HOST}" "command -v mongodump" &>/dev/null; then
    die "mongodump is not installed on ${SSH_HOST}. Install MongoDB Database Tools on the server first."
  fi
  log_ok "mongodump found on remote host."
}

# ---------------------------------------------------------------------------
# Dump → transfer
# ---------------------------------------------------------------------------
run_dump() {
  log_step "Dumping remote database …"

  local dump_args=(
    --uri="$REMOTE_MONGO_URI"
    --db="$DB_NAME"
    --archive
    --gzip
  )
  [[ -n "$COLLECTION_NAME" ]] && dump_args+=(--collection="$COLLECTION_NAME")

  # Build the remote command as a single quoted string
  local remote_cmd
  remote_cmd="mongodump $(printf '%q ' "${dump_args[@]}")"

  ssh "${SSH_USER}@${SSH_HOST}" "$remote_cmd" > "$TEMP_DIR/dump.archive.gz"

  local dump_size
  dump_size="$(du -sh "$TEMP_DIR/dump.archive.gz" | cut -f1)"
  log_ok "Dump complete — archive size: ${dump_size}."
}

# ---------------------------------------------------------------------------
# Optional drop
# ---------------------------------------------------------------------------
run_drop() {
  log_step "Dropping local data before restore …"

  [[ -z "$MONGO_CLI" ]] && { log_warn "mongo CLI not found, skipping drop."; return; }

  if [[ -n "$COLLECTION_NAME" ]]; then
    "$MONGO_CLI" "$LOCAL_MONGO_URI/$DB_NAME" --quiet \
      --eval "db.getCollection('${COLLECTION_NAME}').drop()" &>/dev/null || true
    log_ok "Collection '${COLLECTION_NAME}' dropped (if it existed)."
  else
    "$MONGO_CLI" "$LOCAL_MONGO_URI/$DB_NAME" --quiet \
      --eval "db.dropDatabase()" &>/dev/null || true
    log_ok "Database '${DB_NAME}' dropped (if it existed)."
  fi
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
run_restore() {
  log_step "Restoring into local database …"

  local restore_args=(
    --uri="$LOCAL_MONGO_URI"
    --archive="$TEMP_DIR/dump.archive.gz"
    --gzip
  )

  if [[ -n "$COLLECTION_NAME" ]]; then
    restore_args+=(--nsInclude="${DB_NAME}.${COLLECTION_NAME}")
  else
    restore_args+=(--nsInclude="${DB_NAME}.*")
  fi

  mongorestore "${restore_args[@]}"
  log_ok "Restore complete."
}

# ---------------------------------------------------------------------------
# Post-import stats
# ---------------------------------------------------------------------------
print_stats() {
  [[ -z "$MONGO_CLI" ]] && return

  log_section "Import statistics"

  if [[ -n "$COLLECTION_NAME" ]]; then
    local count
    count="$("$MONGO_CLI" "$LOCAL_MONGO_URI/$DB_NAME" --quiet \
      --eval "db.getCollection('${COLLECTION_NAME}').countDocuments()" 2>/dev/null || echo '?')"
    echo -e "  Collection  ${BOLD}${COLLECTION_NAME}${NC}: ${count} documents"
  else
    "$MONGO_CLI" "$LOCAL_MONGO_URI/$DB_NAME" --quiet --eval "
      db.getCollectionNames().forEach(function(c) {
        var n = db.getCollection(c).countDocuments();
        print('  Collection  ' + c + ': ' + n + ' documents');
      });
    " 2>/dev/null || log_warn "Could not retrieve collection stats."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ╔════════════════════════════════════════╗"
  echo "  ║     MongoDB Sync Tool — MwSpace LLC    ║"
  echo "  ║              v${SCRIPT_VERSION}                     ║"
  echo "  ╚════════════════════════════════════════╝"
  echo -e "${NC}"

  check_dependencies
  load_config

  # ── SSH configuration ─────────────────────────────────────────────────────
  log_section "SSH Configuration"
  prompt_with_default SSH_USER "Remote SSH user"      "${SSH_USER:-}"
  [[ -z "$SSH_USER" ]] && die "SSH user is required."

  prompt_with_default SSH_HOST "Remote SSH host / IP" "${SSH_HOST:-}"
  [[ -z "$SSH_HOST" ]] && die "SSH host is required."

  # ── MongoDB URIs ──────────────────────────────────────────────────────────
  log_section "MongoDB Configuration"
  prompt_with_default REMOTE_MONGO_URI "Remote MongoDB URI" "${REMOTE_MONGO_URI:-mongodb://localhost:27017}"
  prompt_with_default LOCAL_MONGO_URI  "Local  MongoDB URI" "${LOCAL_MONGO_URI:-mongodb://localhost:27017}"

  # ── Target ────────────────────────────────────────────────────────────────
  log_section "Sync Target"
  prompt_with_default DB_NAME         "Database name (required)"      ""
  [[ -z "$DB_NAME" ]] && die "Database name is required."

  prompt_with_default COLLECTION_NAME "Collection name (leave empty for full DB)" ""

  # ── Options ───────────────────────────────────────────────────────────────
  log_section "Sync Options"
  prompt_yes_no DROP_FIRST "Drop local data before restore?" "y"

  if ! $OPT_NO_SAVE; then
    prompt_yes_no SAVE_CFG "Save configuration for future runs?" "y"
    [[ "$SAVE_CFG" == "y" ]] && save_config
  fi

  # Describe what will happen
  local target_desc="${DB_NAME}"
  [[ -n "$COLLECTION_NAME" ]] && target_desc="${DB_NAME}.${COLLECTION_NAME}"

  log_section "Summary"
  echo -e "  Source  : ${BOLD}${SSH_USER}@${SSH_HOST}${NC}  (${REMOTE_MONGO_URI})"
  echo -e "  Target  : ${BOLD}localhost${NC}  (${LOCAL_MONGO_URI})"
  echo -e "  Scope   : ${BOLD}${target_desc}${NC}"
  [[ "$DROP_FIRST" == "y" ]] && echo -e "  Mode    : ${YELLOW}replace${NC} (drop + restore)" \
                             || echo -e "  Mode    : ${CYAN}merge${NC} (no drop)"

  echo ""
  prompt_yes_no CONFIRM "Proceed with synchronisation?" "y"
  [[ "$CONFIRM" != "y" ]] && { echo "Aborted."; exit 0; }

  # ── Create temp directory ─────────────────────────────────────────────────
  TEMP_DIR="$(mktemp -d "${TEMP_BASE}_XXXXXX")"

  # ── Run pipeline ──────────────────────────────────────────────────────────
  test_ssh_connection
  test_remote_mongodump
  run_dump
  [[ "$DROP_FIRST" == "y" ]] && run_drop
  run_restore
  print_stats

  # ── Done ──────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}${GREEN}"
  echo "  ╔════════════════════════════════════════╗"
  echo "  ║     Synchronisation completed ✔        ║"
  echo "  ╚════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  Database : ${BOLD}${DB_NAME}${NC}"
  [[ -n "$COLLECTION_NAME" ]] && echo -e "  Collection: ${BOLD}${COLLECTION_NAME}${NC}"
  echo -e "  From     : ${BOLD}${SSH_USER}@${SSH_HOST}${NC}"
  echo -e "  To       : ${BOLD}localhost${NC}"
  echo ""
}

main "$@"
