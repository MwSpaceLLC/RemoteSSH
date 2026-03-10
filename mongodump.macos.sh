#!/usr/bin/env bash
# =============================================================================
#  mongodb-sync — Remote-to-local MongoDB synchronisation tool (macOS)
#  MwSpace LLC — https://mwspace.com
#
#  MIT License — Copyright (c) 2025 MwSpace LLC
#
#  Requirements (install via Homebrew):
#    brew tap mongodb/brew
#    brew install mongodb/brew/mongodb-database-tools
#    brew install mongodb/brew/mongosh          # optional, for stats
#
#  Usage:
#    ./mongodb-sync-macos.sh [OPTIONS]
#    ./mongodb-sync-macos.sh --help
# =============================================================================

# macOS ships Bash 3.2 — avoid bashisms that require Bash 4+
# (no ${var,,}, no ${var^^}, no associative arrays)
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
readonly CONFIG_FILE="${HOME}/.mongodb_sync_config"
readonly TEMP_BASE="${TMPDIR:-/tmp}/mongodb_sync"

# ---------------------------------------------------------------------------
# Homebrew PATH injection (Intel + Apple Silicon)
# ---------------------------------------------------------------------------
for brew_prefix in /opt/homebrew /usr/local; do
  [[ -d "${brew_prefix}/bin" ]] && export PATH="${brew_prefix}/bin:${PATH}"
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
MongoDB remote-to-local database sync tool — MwSpace LLC

${BOLD}USAGE${NC}
  ${SCRIPT_NAME} [OPTIONS]

${BOLD}OPTIONS${NC}
  -h, --help              Show this help message and exit
  -v, --version           Print version and exit
      --no-color          Disable coloured output
      --no-save           Do not prompt to save configuration
      --reset-config      Delete saved configuration and exit

${BOLD}REQUIREMENTS${NC}
  Install MongoDB tools via Homebrew:
    brew tap mongodb/brew
    brew install mongodb/brew/mongodb-database-tools
    brew install mongodb/brew/mongosh    # optional, for post-import stats

${BOLD}NOTES${NC}
  • Requires SSH key-based authentication (no password prompt).
  • mongodump must also be installed on the remote host.
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
    echo -e "${GREEN}v${NC}  Configuration reset: ${CONFIG_FILE} deleted."
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
    mongodump|mongorestore)
      log_info "Install via: brew tap mongodb/brew && brew install mongodb/brew/mongodb-database-tools"
      ;;
    mongosh)
      log_info "Install via: brew install mongodb/brew/mongosh"
      ;;
    ssh)
      log_info "ssh should be built-in on macOS. Try: xcode-select --install"
      ;;
  esac
}

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
    for t in "${missing[@]}"; do suggest_brew_install "$t"; done
    exit 1
  fi

  # Prefer mongosh, fall back to legacy mongo CLI
  if command -v mongosh &>/dev/null; then
    MONGO_CLI="mongosh"
  elif command -v mongo &>/dev/null; then
    MONGO_CLI="mongo"
  else
    MONGO_CLI=""
    log_warn "mongosh not found — post-import document counts will be skipped."
    suggest_brew_install "mongosh"
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
# Prompt helpers (Bash 3.2 safe — no printf -v with nameref)
# ---------------------------------------------------------------------------
# Returns value via stdout; caller captures with $()
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
    1. The host is unreachable (check firewall / VPN).
    2. No SSH key configured (~/.ssh/id_rsa or id_ed25519).
    3. Your public key is not in the server's authorized_keys.

  Quick fix:
    ssh-copy-id ${SSH_USER}@${SSH_HOST}

  Or manually:
    cat ~/.ssh/id_ed25519.pub | ssh ${SSH_USER}@${SSH_HOST} "cat >> ~/.ssh/authorized_keys"
EOF
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Remote mongodump availability check
# ---------------------------------------------------------------------------
test_remote_mongodump() {
  log_info "Checking mongodump on remote host ..."
  if ! ssh "${SSH_USER}@${SSH_HOST}" "command -v mongodump" &>/dev/null; then
    die "mongodump not found on ${SSH_HOST}. Install MongoDB Database Tools on the server."
  fi
  log_ok "mongodump found on remote host."
}

# ---------------------------------------------------------------------------
# Dump → transfer
# ---------------------------------------------------------------------------
run_dump() {
  log_step "Dumping remote database ..."

  # Build remote command safely (no array quoting issues across SSH)
  local remote_cmd="mongodump"
  remote_cmd="${remote_cmd} --uri=\"${REMOTE_MONGO_URI}\""
  remote_cmd="${remote_cmd} --db=\"${DB_NAME}\""
  remote_cmd="${remote_cmd} --archive"
  remote_cmd="${remote_cmd} --gzip"
  [[ -n "$COLLECTION_NAME" ]] && remote_cmd="${remote_cmd} --collection=\"${COLLECTION_NAME}\""

  ssh "${SSH_USER}@${SSH_HOST}" "$remote_cmd" > "${TEMP_DIR}/dump.archive.gz"

  # macOS-compatible file size (no 'du -sh --si')
  local dump_size
  dump_size="$(du -sh "${TEMP_DIR}/dump.archive.gz" | awk '{print $1}')"
  log_ok "Dump complete — archive size: ${dump_size}."
}

# ---------------------------------------------------------------------------
# Optional drop
# ---------------------------------------------------------------------------
run_drop() {
  log_step "Dropping local data before restore ..."

  if [[ -z "$MONGO_CLI" ]]; then
    log_warn "mongo CLI not found, skipping drop step."
    return
  fi

  if [[ -n "$COLLECTION_NAME" ]]; then
    "$MONGO_CLI" "${LOCAL_MONGO_URI}/${DB_NAME}" --quiet \
      --eval "db.getCollection('${COLLECTION_NAME}').drop()" &>/dev/null || true
    log_ok "Collection '${COLLECTION_NAME}' dropped (if it existed)."
  else
    "$MONGO_CLI" "${LOCAL_MONGO_URI}/${DB_NAME}" --quiet \
      --eval "db.dropDatabase()" &>/dev/null || true
    log_ok "Database '${DB_NAME}' dropped (if it existed)."
  fi
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
run_restore() {
  log_step "Restoring into local database ..."

  local ns_include="${DB_NAME}.*"
  [[ -n "$COLLECTION_NAME" ]] && ns_include="${DB_NAME}.${COLLECTION_NAME}"

  mongorestore \
    --uri="${LOCAL_MONGO_URI}" \
    --archive="${TEMP_DIR}/dump.archive.gz" \
    --gzip \
    --nsInclude="${ns_include}"

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
    count="$("$MONGO_CLI" "${LOCAL_MONGO_URI}/${DB_NAME}" --quiet \
      --eval "db.getCollection('${COLLECTION_NAME}').countDocuments()" 2>/dev/null || echo '?')"
    echo -e "  Collection  ${BOLD}${COLLECTION_NAME}${NC}: ${count} documents"
  else
    "$MONGO_CLI" "${LOCAL_MONGO_URI}/${DB_NAME}" --quiet --eval "
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
  echo "  +------------------------------------------+"
  echo "  |     MongoDB Sync Tool -- MwSpace LLC      |"
  echo "  |              v${SCRIPT_VERSION}   (macOS)             |"
  echo "  +------------------------------------------+"
  echo -e "${NC}"

  check_dependencies
  load_config

  # Initialise variables (avoid unbound errors with set -u)
  SSH_USER="${SSH_USER:-}"
  SSH_HOST="${SSH_HOST:-}"
  REMOTE_MONGO_URI="${REMOTE_MONGO_URI:-mongodb://localhost:27017}"
  LOCAL_MONGO_URI="${LOCAL_MONGO_URI:-mongodb://localhost:27017}"
  DB_NAME=""
  COLLECTION_NAME=""

  # ── SSH configuration ─────────────────────────────────────────────────────
  log_section "SSH Configuration"
  SSH_USER="$(_prompt_read "Remote SSH user"      "$SSH_USER")"
  [[ -z "$SSH_USER" ]] && die "SSH user is required."

  SSH_HOST="$(_prompt_read "Remote SSH host / IP" "$SSH_HOST")"
  [[ -z "$SSH_HOST" ]] && die "SSH host is required."

  # ── MongoDB URIs ──────────────────────────────────────────────────────────
  log_section "MongoDB Configuration"
  REMOTE_MONGO_URI="$(_prompt_read "Remote MongoDB URI" "$REMOTE_MONGO_URI")"
  LOCAL_MONGO_URI="$(_prompt_read  "Local  MongoDB URI" "$LOCAL_MONGO_URI")"

  # ── Target ────────────────────────────────────────────────────────────────
  log_section "Sync Target"
  DB_NAME="$(_prompt_read "Database name (required)" "")"
  [[ -z "$DB_NAME" ]] && die "Database name is required."

  COLLECTION_NAME="$(_prompt_read "Collection name (leave empty for full DB)" "")"

  # ── Options ───────────────────────────────────────────────────────────────
  log_section "Sync Options"
  local drop_ans
  drop_ans="$(_prompt_read "Drop local data before restore? (y/n)" "y")"
  DROP_FIRST="$(to_lower "$drop_ans")"

  if ! $OPT_NO_SAVE; then
    local save_ans
    save_ans="$(_prompt_read "Save configuration for future runs? (y/n)" "y")"
    [[ "$(to_lower "$save_ans")" == "y" ]] && save_config
  fi

  # ── Summary ───────────────────────────────────────────────────────────────
  local target_desc="${DB_NAME}"
  [[ -n "$COLLECTION_NAME" ]] && target_desc="${DB_NAME}.${COLLECTION_NAME}"

  log_section "Summary"
  echo -e "  Source  : ${BOLD}${SSH_USER}@${SSH_HOST}${NC}  (${REMOTE_MONGO_URI})"
  echo -e "  Target  : ${BOLD}localhost${NC}  (${LOCAL_MONGO_URI})"
  echo -e "  Scope   : ${BOLD}${target_desc}${NC}"
  if [[ "$DROP_FIRST" == "y" ]]; then
    echo -e "  Mode    : ${YELLOW}replace${NC} (drop + restore)"
  else
    echo -e "  Mode    : ${CYAN}merge${NC} (no drop)"
  fi

  echo ""
  local confirm_ans
  confirm_ans="$(_prompt_read "Proceed with synchronisation? (y/n)" "y")"
  [[ "$(to_lower "$confirm_ans")" != "y" ]] && { echo "Aborted."; exit 0; }

  # ── Create temp directory (macOS mktemp requires trailing Xs) ─────────────
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
  echo "  +------------------------------------------+"
  echo "  |     Synchronisation completed  v         |"
  echo "  +------------------------------------------+"
  echo -e "${NC}"
  echo -e "  Database   : ${BOLD}${DB_NAME}${NC}"
  [[ -n "$COLLECTION_NAME" ]] && echo -e "  Collection : ${BOLD}${COLLECTION_NAME}${NC}"
  echo -e "  From       : ${BOLD}${SSH_USER}@${SSH_HOST}${NC}"
  echo -e "  To         : ${BOLD}localhost${NC}"
  echo ""
}

main "$@"
