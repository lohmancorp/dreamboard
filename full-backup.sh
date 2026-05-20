#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# full-backup.sh  —  Full CB-Next backup & restore
#
# Backup usage:
#   ./backup/full-backup.sh            # back up everything → single bundle
#   ./backup/full-backup.sh -o         # interactive: choose components,
#                                      #   produces individual files per item
#   ./backup/full-backup.sh --no-code  # skip the code tarball (faster)
#   ./backup/full-backup.sh --db-only  # database + config only
#
# Restore / install usage:
#   ./backup/full-backup.sh --install <archive.tar.gz>       # full setup
#   ./backup/full-backup.sh --install <archive> --me         # auto-fill keys
#   ./backup/full-backup.sh --retry                          # re-run key config
#
# Output (default — full run):
#   cb-next-full_YYYY-MM-DD_HH-MM.tar.gz   — single bundle of all components
#
# Output (-o mode — individual files, one per selected component):
#   cb-next-database_YYYY-MM-DD_HH-MM.tar.gz
#   cb-next-config_YYYY-MM-DD_HH-MM.tar.gz
#   cb-next-storage_YYYY-MM-DD_HH-MM.tar.gz
#   cb-next-code_YYYY-MM-DD_HH-MM.tar.gz
#
# Environment variables (all have sane defaults):
#   DB_URL             Postgres connection string
#   STORAGE_VOLUME     Docker volume name for Supabase Storage
#   PROJECT_ROOT       Path to CB-Next repo root (auto-detected)
#   SUPABASE_CONFIG    Path to supabase/config.toml (auto-detected)
#   ENV_FILE           Path to .env file (auto-detected)
#   KEEP_BACKUPS       Number of full backup sets to retain (default: 7)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
SUPABASE_CONFIG="${SUPABASE_CONFIG:-${PROJECT_ROOT}/supabase/config.toml}"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"
STAMP="$(date +'%Y-%m-%d_%H-%M')"

# Detect Supabase project_id from config.toml so we never hardcode "taylor".
# Override at the env level with PROJECT_ID=<name> if needed.
_detect_project_id() {
  local cfg="${1:-$SUPABASE_CONFIG}"
  if [[ -f "$cfg" ]]; then
    awk -F'=' '/^[[:space:]]*project_id[[:space:]]*=/ {
      gsub(/[[:space:]"]+/, "", $2); print $2; exit
    }' "$cfg"
  fi
}
PROJECT_ID="${PROJECT_ID:-$(_detect_project_id || true)}"
PROJECT_ID="${PROJECT_ID:-taylor}"

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
STORAGE_VOLUME="${STORAGE_VOLUME:-supabase_storage_${PROJECT_ID}}"
DB_VOLUME="${DB_VOLUME:-supabase_db_${PROJECT_ID}}"
REDIS_VOLUME="${REDIS_VOLUME:-cb-next_redisdata}"

# ── Flag Parsing ──────────────────────────────────────────────────────────────
SKIP_CODE=false
DB_ONLY=false
OPTIONS_MODE=false
INSTALL_MODE=false
INSTALL_ARCHIVE=""
ME_FLAG=false
RETRY_MODE=false
TEST_RESTORE_MODE=false
TEST_KEEP=false
TEST_ARCHIVE=""
PREREQS_ONLY=false
SKIP_PREREQS=false
DRY_RUN=false

i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --no-code)        SKIP_CODE=true ;;
    --db-only)        DB_ONLY=true; SKIP_CODE=true ;;
    -o|--options)     OPTIONS_MODE=true ;;
    --me)             ME_FLAG=true ;;
    --retry)          RETRY_MODE=true ;;
    --install)        INSTALL_MODE=true ;;
    --test-restore)   TEST_RESTORE_MODE=true ;;
    --keep)           TEST_KEEP=true ;;
    --archive)        i=$((i + 1)); TEST_ARCHIVE="${!i:-}" ;;
    --prereqs-only)   PREREQS_ONLY=true ;;
    --skip-prereqs)   SKIP_PREREQS=true ;;
    --dry-run)        DRY_RUN=true ;;
    --project-id)     i=$((i + 1)); PROJECT_ID="${!i:-$PROJECT_ID}"
                      STORAGE_VOLUME="supabase_storage_${PROJECT_ID}"
                      DB_VOLUME="supabase_db_${PROJECT_ID}" ;;
    -*)               ;; # ignore unknown flags
    *)                # positional arg → treat as archive path
      if [[ -z "$INSTALL_ARCHIVE" ]]; then
        INSTALL_ARCHIVE="$arg"
      fi
      ;;
  esac
  i=$((i + 1))
done

# ── Shared helpers (used by both backup and restore paths) ───────────────────

_sha256() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo ""
  fi
}

_supabase_cli_version() {
  local v=""
  if command -v supabase &>/dev/null; then
    v="$(supabase --version 2>/dev/null | head -1)"
  elif command -v npx &>/dev/null; then
    v="$(npx -y supabase --version 2>/dev/null | head -1)"
  fi
  # Strip any control chars / quotes so the value is JSON-safe.
  printf '%s' "${v:-unknown}" | tr -d '\r\n\t"' | tr -dc '[:print:]'
}

# Read a [section] key from a TOML file (best-effort, no nesting).
_toml_get() {
  local file="$1" section="$2" key="$3"
  [[ -f "$file" ]] || return
  awk -v sec="[$section]" -v k="$key" '
    $0 == sec { in_sec=1; next }
    /^\[/    { in_sec=0 }
    in_sec && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "")
      print; exit
    }' "$file"
}

# Write a MANIFEST.json describing this backup so a restore can know the
# project_id, ports, host, supabase CLI version, and per-component sha256.
# Args: $1 = output path, then any number of "label=path" pairs.
_write_manifest() {
  local out="$1"; shift
  local api_port db_port studio_port inbucket_port analytics_port
  api_port="$(_toml_get "$SUPABASE_CONFIG" api port)"
  db_port="$(_toml_get "$SUPABASE_CONFIG" db port)"
  studio_port="$(_toml_get "$SUPABASE_CONFIG" studio port)"
  inbucket_port="$(_toml_get "$SUPABASE_CONFIG" inbucket port)"
  analytics_port="$(_toml_get "$SUPABASE_CONFIG" analytics port)"
  api_port="${api_port:-54321}"; db_port="${db_port:-54322}"
  studio_port="${studio_port:-54323}"; inbucket_port="${inbucket_port:-54324}"
  analytics_port="${analytics_port:-54327}"

  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "created_at": "%s",\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '  "stamp": "%s",\n' "$STAMP"
    printf '  "source": {\n'
    printf '    "host": "%s",\n' "$(hostname -s 2>/dev/null || echo unknown)"
    printf '    "user": "%s",\n' "${USER:-unknown}"
    printf '    "os": "%s",\n' "$(uname -s)"
    printf '    "arch": "%s",\n' "$(uname -m)"
    printf '    "path": "%s"\n' "$PROJECT_ROOT"
    printf '  },\n'
    printf '  "supabase": {\n'
    printf '    "project_id": "%s",\n' "$PROJECT_ID"
    printf '    "cli_version": "%s",\n' "$(_supabase_cli_version | sed 's/"/\\"/g')"
    printf '    "storage_volume": "%s",\n' "$STORAGE_VOLUME"
    printf '    "db_volume": "%s"\n' "$DB_VOLUME"
    printf '  },\n'
    printf '  "ports": {\n'
    printf '    "supabase_api": %s,\n' "$api_port"
    printf '    "supabase_db": %s,\n' "$db_port"
    printf '    "supabase_studio": %s,\n' "$studio_port"
    printf '    "supabase_inbucket": %s,\n' "$inbucket_port"
    printf '    "supabase_analytics": %s,\n' "$analytics_port"
    printf '    "backend": 8000,\n'
    printf '    "frontend": 5173,\n'
    printf '    "proxy": 443\n'
    printf '  },\n'
    printf '  "components": {\n'
    local first=1
    for pair in "$@"; do
      local label="${pair%%=*}"
      local path="${pair#*=}"
      local size=0 hash=""
      if [[ -f "$path" ]]; then
        size="$(wc -c < "$path" | tr -d ' ')"
        hash="$(_sha256 "$path")"
      fi
      [[ $first -eq 1 ]] || printf ',\n'
      first=0
      printf '    "%s": { "file": "%s", "bytes": %s, "sha256": "%s" }' \
        "$label" "$(basename "$path")" "$size" "$hash"
    done
    printf '\n  }\n'
    printf '}\n'
  } > "$out"
}

# ══════════════════════════════════════════════════════════════════════════════
# ── INSTALL / RETRY MODE ─────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$INSTALL_MODE" == "true" || "$RETRY_MODE" == "true" ]]; then

# ── Ensure a valid CWD ───────────────────────────────────────────────────────
# Some terminals are started in a directory that gets deleted later (common
# when this script is run after a `rm -rf` somewhere in the parent path).
# `brew`, `sudo`, and many subshells refuse to launch from a non-existent
# cwd. Move to $HOME early so every later subprocess has a sane cwd.
if ! pwd -P >/dev/null 2>&1; then
  echo "  ⚠  Current working directory no longer exists — switching to \$HOME"
fi
cd "${HOME:-/tmp}" 2>/dev/null || cd /tmp

# ── Detect terminal dark/light mode ──────────────────────────────────────────
DARK_MODE=true
if command -v defaults &>/dev/null; then
  if [[ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" != "Dark" ]]; then
    [[ -z "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" ]] && DARK_MODE=false
  fi
fi
[[ -n "${COLORFGBG:-}" ]] && { bg="${COLORFGBG##*;}"; (( bg < 8 )) && DARK_MODE=false; }

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m'   G='\033[0;32m'   Y='\033[0;33m'   B='\033[0;34m'
C='\033[0;36m'   W='\033[1;37m'   N='\033[0m'
BLD='\033[1m'    UL='\033[4m'
[[ "$DARK_MODE" == "true" ]] && D='\033[0;37m' || D='\033[0;90m'

_ok()   { echo -e "  ${G}✓${N} $*"; }
_fail() { echo -e "  ${R}✗${N} $*"; }
_info() { echo -e "  ${B}→${N} $*"; }
_warn() { echo -e "  ${Y}⚠${N}  $*"; }
_head() { echo ""; echo -e "${C}${BLD}═══ $* ══════════════════════════════════════════════════${N}"; }
_ask()  { echo -en "  ${W}?${N} $*"; }
_dim()  { echo -e "  ${D}$*${N}"; }
_nl()   { echo ""; }

# Spinner for background tasks: _spin <pid> <message>
_spin() {
  local pid=$1 msg="$2"
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${B}%s${N} %s" "${frames:i%10:1}" "$msg"
    i=$((i + 1))
    sleep 0.1
  done
  printf "\r%*s\r" $((${#msg} + 6)) ""  # clear line
}

# ── Logging ───────────────────────────────────────────────────────────────────
INSTALL_PATH=""
ARCHIVE_BASE=""
if [[ "$INSTALL_MODE" == "true" && -n "$INSTALL_ARCHIVE" ]]; then
  ARCHIVE_BASE="$(basename "$INSTALL_ARCHIVE" .tar.gz)"
elif [[ "$RETRY_MODE" == "true" ]]; then
  ARCHIVE_BASE="retry-$(date +'%Y-%m-%d_%H-%M')"
fi
LOG_FILE="${SCRIPT_DIR}/restore-log-${ARCHIVE_BASE}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# ── Ctrl+C trap ──────────────────────────────────────────────────────────────
handle_interrupt() {
  echo ""
  echo ""
  echo -e "  ${Y}${BLD}⚠  Installation interrupted!${N}"
  echo ""
  if [[ -n "$INSTALL_PATH" && -d "$INSTALL_PATH" ]]; then
    echo -e "  ${W}?${N} Would you like to delete the partially installed files?"
    echo ""
    echo -e "      ${BLD}1) Delete${N} — remove everything at ${BLD}${INSTALL_PATH}${N}"
    echo -e "         ${D}Cleans up so you can start fresh next time.${N}"
    echo ""
    echo -e "      ${BLD}2) Keep${N} — leave files in place"
    echo -e "         ${D}You can resume later or inspect what was installed.${N}"
    echo ""
    echo -en "  ${W}?${N} Selection [2]: "
    stty echo 2>/dev/null
    read -r cleanup_choice
    cleanup_choice=${cleanup_choice:-2}
    echo ""
    if [[ "$cleanup_choice" == "1" ]]; then
      # Safety: only delete if path looks like a CB-Next install
      if [[ -f "${INSTALL_PATH}/dev.sh" || -f "${INSTALL_PATH}/.env" ]]; then
        rm -rf "$INSTALL_PATH"
        echo -e "  ${R}✗${N} Deleted: ${INSTALL_PATH}"
      else
        echo -e "  ${Y}⚠${N}  Path doesn't look like a CB-Next install — not deleting for safety."
      fi
    else
      echo -e "  ${G}✓${N} Files kept at: ${INSTALL_PATH}"
    fi
    echo ""
    echo -e "  ${D}To resume: bash backup/full-backup.sh --install <archive>${N}"
    echo -e "  ${D}Keys only: bash backup/full-backup.sh --retry${N}"
  else
    echo -e "  ${D}No files were created yet — nothing to clean up.${N}"
  fi
  echo ""
  exit 1
}
trap handle_interrupt INT TERM

# ── Helper: open URL cross-platform ──────────────────────────────────────────
_open_url() {
  local url="$1"
  if command -v open &>/dev/null; then
    open "$url" 2>/dev/null
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$url" 2>/dev/null
  elif command -v wslview &>/dev/null; then
    wslview "$url" 2>/dev/null
  fi
}

# ── Helper: check port ───────────────────────────────────────────────────────
_port_free() {
  ! lsof -iTCP:"$1" -sTCP:LISTEN &>/dev/null
}

# ── Helper: suggest next port (increment 2nd digit) ──────────────────────────
_next_port() {
  local p="$1"
  local len=${#p}
  if (( len >= 4 )); then
    local d2=${p:1:1}
    d2=$(( (d2 + 1) % 10 ))
    echo "${p:0:1}${d2}${p:2}"
  else
    echo $(( p + 100 ))
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# ── --retry MODE: jump straight to key config ────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$RETRY_MODE" == "true" ]]; then
  # Detect install dir: current directory or ask
  if [[ -f "./dev.sh" ]]; then
    INSTALL_PATH="$(pwd)"
  else
    _ask "Enter the CB-Next install directory: "
    read -r INSTALL_PATH
    INSTALL_PATH="${INSTALL_PATH/#\~/$HOME}"
  fi

  if [[ ! -f "${INSTALL_PATH}/dev.sh" ]]; then
    _fail "Not a valid CB-Next installation at: ${INSTALL_PATH}"
    exit 1
  fi

  cd "$INSTALL_PATH"
  _head "Key & OAuth Configuration (--retry)"

  # Fall through to Phase 11 logic below — set a flag
  RETRY_JUMP=true
fi

# ══════════════════════════════════════════════════════════════════════════════
# ── --install MODE: full interactive install ─────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$INSTALL_MODE" == "true" ]]; then

  # Validate archive
  if [[ -z "$INSTALL_ARCHIVE" ]]; then
    _fail "Usage: bash full-backup.sh --install <archive.tar.gz>"
    exit 1
  fi
  if [[ ! -f "$INSTALL_ARCHIVE" ]]; then
    # Try relative to script dir
    if [[ -f "${SCRIPT_DIR}/${INSTALL_ARCHIVE}" ]]; then
      INSTALL_ARCHIVE="${SCRIPT_DIR}/${INSTALL_ARCHIVE}"
    else
      _fail "Archive not found: ${INSTALL_ARCHIVE}"
      exit 1
    fi
  fi
  INSTALL_ARCHIVE="$(cd "$(dirname "$INSTALL_ARCHIVE")" && pwd)/$(basename "$INSTALL_ARCHIVE")"

  # ════════════════════════════════════════════════════════════════════════════
  # BANNER
  # ════════════════════════════════════════════════════════════════════════════
  clear
  echo ""
  echo -e "${C}${BLD}"
  echo "  ┌────────────────────────────────────────────────────────────┐"
  echo "  │                                                            │"
  echo "  │         CB-Next Installer  —  from Backup Archive          │"
  echo "  │                                                            │"
  echo "  └────────────────────────────────────────────────────────────┘"
  echo -e "${N}"
  echo -e "  ${D}Archive : $(basename "$INSTALL_ARCHIVE")${N}"
  echo -e "  ${D}Log     : $(basename "$LOG_FILE")${N}"
  echo -e "  ${D}Time    : $(date '+%Y-%m-%d %H:%M:%S')${N}"
  echo ""
  echo -e "  ${W}${BLD}What to expect:${N}"
  echo ""
  echo -e "  ${D}This installer will walk you through ${BLD}13 steps${N}${D} to set up the${N}"
  echo -e "  ${D}CB-Next platform on your machine. Estimated time: ${BLD}10–15 minutes${N}${D}.${N}"
  echo ""
  echo -e "  ${D}Steps:${N}"
  echo -e "  ${D} 0. Initialization       7. Storage restore${N}"
  echo -e "  ${D} 1. Prerequisites        8. SSL certificates${N}"
  echo -e "  ${D} 2. Extract archive      9. Domain configuration${N}"
  echo -e "  ${D} 3. Python environment  10. Port availability${N}"
  echo -e "  ${D} 4. Node.js deps        11. API keys & OAuth${N}"
  echo -e "  ${D} 5. Docker & Supabase   12. User account creation${N}"
  echo -e "  ${D} 6. Database restore    13. Validation & launch${N}"
  echo ""
  echo -e "  ${W}${BLD}Have ready (optional — can be configured later):${N}"
  echo ""
  echo -e "  ${D}  •  Stripe API keys (or use dummy keys for local dev)${N}"
  echo -e "  ${D}  •  Google OAuth credentials (for Google login)${N}"
  echo -e "  ${D}  •  Admin/sudo password (for hosts file & port 443)${N}"
  echo ""
  echo -e "  ${Y}⚠${N}  ${Y}Press Ctrl+C at any time to safely abort.${N}"
  echo -e "     ${D}You'll be asked if you want to clean up partial work.${N}"
  echo ""
  echo -en "  ${D}── press Enter to begin ──${N}"
  read -rs && echo ""

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 0 — INITIALIZATION
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 0 · Initialization"
  _nl
  _ask "What operating system are you on?

      ${BLD}1)${N} macOS
      ${BLD}2)${N} Linux
      ${BLD}3)${N} Windows

  Selection [1]: "
  read -r _os_choice
  _os_choice=${_os_choice:-1}
  case "$_os_choice" in
    1) INST_OS="macOS" ;;
    2) INST_OS="Linux" ;;
    3) INST_OS="Windows"
       _warn "Windows detected. CB-Next requires a Unix environment."
       _info "Checking for WSL (Windows Subsystem for Linux)..."
       if command -v wsl.exe &>/dev/null || grep -qi microsoft /proc/version 2>/dev/null; then
         _ok "WSL detected"
       else
         _fail "WSL not found. Please install WSL 2 first:"
         _dim "  https://learn.microsoft.com/en-us/windows/wsl/install"
         exit 1
       fi
       ;;
    *) INST_OS="macOS" ;;
  esac
  _ok "Operating system: ${BLD}${INST_OS}${N}"
  _nl

  _ask "Where would you like to install CB-Next?
  ${D}Default: ~/Development/CB-Next${N}

  Path [~/Development/CB-Next]: "
  read -r INSTALL_PATH
  INSTALL_PATH="${INSTALL_PATH:-$HOME/Development/CB-Next}"
  INSTALL_PATH="${INSTALL_PATH/#\~/$HOME}"

  if [[ -d "$INSTALL_PATH" && -f "${INSTALL_PATH}/dev.sh" ]]; then
    _warn "An existing CB-Next installation was found at ${INSTALL_PATH}"
    _ask "Overwrite it? This will delete the existing installation. [y/N]: "
    read -r _overwrite
    if [[ "$_overwrite" =~ ^[Yy] ]]; then
      rm -rf "$INSTALL_PATH"
      _ok "Existing installation removed"
    else
      _fail "Aborted — choose a different path or remove the existing install."
      exit 1
    fi
  fi
  _ok "Install path: ${BLD}${INSTALL_PATH}${N}"

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 1 — PREREQUISITES
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 1 · Checking Prerequisites"
  _nl
  if [[ "$SKIP_PREREQS" == "true" ]]; then
    _info "${BLD}--skip-prereqs${N} set — skipping detection and installs."
  fi
  _info "Scanning for required tools and host state..."
  MISSING=()
  # Host facts (used by later phases too)
  HOST_ARCH="$(uname -m)"
  HOST_OS_VER="$(sw_vers -productVersion 2>/dev/null || uname -r)"
  _info "Host: ${BLD}$(uname -s) ${HOST_OS_VER} (${HOST_ARCH})${N}"

  # Python
  PY_NEEDS_UPGRADE=false
  if command -v python3 &>/dev/null; then
    PY_VER="$(python3 --version 2>&1 | awk '{print $2}')"
    PY_MAJ="${PY_VER%%.*}"
    PY_MIN="${PY_VER#*.}"; PY_MIN="${PY_MIN%%.*}"
    if (( PY_MAJ >= 3 && PY_MIN >= 11 )); then
      _ok "python3     — ${G}${PY_VER}${N}  ≥3.11 ✓"
    else
      _warn "python3     — ${Y}${PY_VER}${N}  (need ≥3.11, will upgrade)"
      PY_NEEDS_UPGRADE=true
      MISSING+=("python3")
    fi
  else
    _warn "python3     — ${Y}not found${N}"
    MISSING+=("python3")
  fi

  # Node
  if command -v node &>/dev/null; then
    NODE_VER="$(node --version 2>&1)"
    NODE_MAJ="${NODE_VER#v}"; NODE_MAJ="${NODE_MAJ%%.*}"
    if (( NODE_MAJ >= 20 )); then
      _ok "node        — ${G}${NODE_VER}${N}  ≥20 ✓"
    else
      _warn "node        — ${Y}${NODE_VER}${N}  (need ≥20)"
      MISSING+=("node")
    fi
  else
    _warn "node        — ${Y}not found${N}"
    MISSING+=("node")
  fi

  # npm
  if command -v npm &>/dev/null; then
    _ok "npm         — ${G}$(npm --version)${N}"
  else
    _warn "npm         — ${Y}not found${N}"
    MISSING+=("npm")
  fi

  # Docker
  DOCKER_INSTALLED=false
  DOCKER_RUNNING=false
  if command -v docker &>/dev/null; then
    DOCKER_INSTALLED=true
    if docker info &>/dev/null 2>&1; then
      DOCKER_RUNNING=true
      _ok "docker      — ${G}$(docker --version | awk '{print $3}' | tr -d ,)${N}"
    else
      _warn "docker      — ${Y}installed but daemon not running${N}"
      MISSING+=("docker-start")  # needs starting, not installing
    fi
  else
    _warn "docker      — ${Y}not found${N}"
    MISSING+=("docker-install")  # needs installing
  fi

  # git
  if command -v git &>/dev/null; then
    _ok "git         — ${G}$(git --version | awk '{print $3}')${N}"
  else
    _warn "git         — ${Y}not found${N}"
    MISSING+=("git")
  fi

  # mkcert
  if command -v mkcert &>/dev/null; then
    _ok "mkcert      — ${G}$(mkcert --version 2>&1 | head -1)${N}"
  else
    _warn "mkcert      — ${Y}not found${N}"
    MISSING+=("mkcert")
  fi

  # mkcert root CA in trust store (only if mkcert is present)
  if command -v mkcert &>/dev/null; then
    if security find-certificate -c "mkcert" /Library/Keychains/System.keychain &>/dev/null || \
       security find-certificate -c "mkcert" ~/Library/Keychains/login.keychain-db &>/dev/null; then
      _ok "mkcert CA   — ${G}trusted${N}"
    else
      _warn "mkcert CA   — ${Y}not yet trusted (will run 'mkcert -install' in Phase 8)${N}"
    fi
  fi

  # supabase CLI (preferred over npx for speed)
  if command -v supabase &>/dev/null; then
    _ok "supabase    — ${G}$(supabase --version 2>/dev/null | head -1)${N}"
  else
    _warn "supabase    — ${Y}not found (will fall back to 'npx -y supabase')${N}"
    MISSING+=("supabase")
  fi

  # psql / pg_dump (libpq) — needed for DB dump replay
  if command -v psql &>/dev/null && command -v pg_dump &>/dev/null; then
    _ok "psql        — ${G}$(psql --version | awk '{print $NF}')${N}"
  else
    _warn "psql        — ${Y}not found (libpq missing)${N}"
    MISSING+=("libpq")
  fi

  # jq — needed for MANIFEST.json parsing
  if command -v jq &>/dev/null; then
    _ok "jq          — ${G}$(jq --version)${N}"
  else
    _warn "jq          — ${Y}not found${N}"
    MISSING+=("jq")
  fi

  # ── Host-level checks (informational; do not block install) ────────────────
  _nl
  _info "Host state:"

  # Free disk space (need at least 10 GB for code + node_modules + Docker images)
  FREE_GB="$(df -k "$HOME" | awk 'NR==2 {printf "%d", $4/1024/1024}')"
  if [[ -n "$FREE_GB" ]] && (( FREE_GB >= 10 )); then
    _ok "Disk space  — ${G}${FREE_GB} GB free${N} in \$HOME"
  else
    _warn "Disk space  — ${Y}${FREE_GB} GB free${N} (recommend ≥10 GB)"
  fi

  # /etc/hosts entries (informational — Phase 9 will offer to add them)
  if grep -q 'cloudblue.ai' /etc/hosts 2>/dev/null; then
    _ok "/etc/hosts  — ${G}cloudblue.ai entries present${N}"
  else
    _info "/etc/hosts  — cloudblue.ai entries will be added in Phase 9"
  fi

  # Port conflicts (look at default ports — Phase 10 will reassign if needed)
  _busy_ports=()
  for p in 443 5173 8000 54321 54322 54323; do
    if lsof -iTCP:"$p" -sTCP:LISTEN &>/dev/null; then
      _busy_ports+=("$p")
    fi
  done
  if [[ ${#_busy_ports[@]} -eq 0 ]]; then
    _ok "Default ports — ${G}all free${N}"
  else
    _warn "Default ports — ${Y}in use: ${_busy_ports[*]}${N} (Phase 10 will reassign)"
  fi

  # Existing CB-Next installation at target path
  if [[ -d "$INSTALL_PATH" && -f "${INSTALL_PATH}/dev.sh" ]]; then
    _warn "Existing CB-Next install at ${INSTALL_PATH} — Phase 2 will prompt before overwriting"
  fi

  # Existing Supabase project with same id (would share volumes/ports)
  if docker volume inspect "supabase_db_${PROJECT_ID:-taylor}" &>/dev/null; then
    _warn "Supabase project '${PROJECT_ID:-taylor}' already exists on this host — restore will reuse its volumes unless you choose a new project id"
  fi

  # Honor --prereqs-only: report, then exit without changing anything.
  if [[ "$PREREQS_ONLY" == "true" ]]; then
    _nl
    _info "${BLD}--prereqs-only${N} set — exiting after detection report."
    if [[ ${#MISSING[@]} -gt 0 ]]; then
      _warn "${#MISSING[@]} missing prerequisite(s): ${MISSING[*]}"
      exit 2
    else
      _ok "All prerequisites satisfied."
      exit 0
    fi
  fi

  if [[ "$SKIP_PREREQS" == "true" ]]; then
    MISSING=()  # don't enter the install loop
  fi

  if [[ ${#MISSING[@]} -gt 0 ]]; then
    _nl
    echo -e "  ${R}${BLD}${#MISSING[@]} missing prerequisite(s): ${MISSING[*]}${N}"
    _nl
    if [[ "$DRY_RUN" == "true" ]]; then
      _info "${BLD}--dry-run${N}: would install the following and stop:"
      for pkg in "${MISSING[@]}"; do _dim "  · ${pkg}"; done
      _info "Re-run without --dry-run to perform the install."
      exit 0
    fi
    for pkg in "${MISSING[@]}"; do
      case "$pkg" in
        docker-start)
          echo -e "  ${C}── Docker ──${N}"
          _info "Docker is installed but the daemon is not running."
          _nl
          _ask "Attempt to start Docker now? [Y/n]: "
          read -r _ds
          if [[ "${_ds:-Y}" =~ ^[Yy] ]]; then
            case "$INST_OS" in
              macOS)
                open -a Docker 2>/dev/null
                # Wait for Docker with spinner
                ( while ! docker info &>/dev/null 2>&1; do sleep 1; done ) &
                _spin $! "Starting Docker Desktop..."
                ;;
              Linux) sudo systemctl start docker 2>&1 | tail -3 ;;
            esac
            if docker info &>/dev/null 2>&1; then
              DOCKER_RUNNING=true
              _ok "Docker daemon is now running"
            else
              _warn "Docker daemon may still be starting. Will retry later."
            fi
          else
            _warn "Docker not started — Supabase will not be available until Docker is running"
          fi
          _nl ;;
        docker-install)
          echo -e "  ${C}── Docker ──${N}"
          _info "Docker is required to run Supabase (auth, database, storage)."
          case "$INST_OS" in
            macOS)  _dim "  Install: brew install --cask docker" ;;
            Linux)  _dim "  Install: sudo apt install docker.io docker-compose-plugin" ;;
            *)      _dim "  Install Docker Desktop with WSL 2 integration" ;;
          esac
          _nl
          _ask "Install Docker now? [Y/n]: "
          read -r _dc
          if [[ "${_dc:-Y}" =~ ^[Yy] ]]; then
            case "$INST_OS" in
              macOS) brew install --cask docker 2>&1 | tail -3; open -a Docker; _info "Waiting for Docker to start (this may take a minute)..."; sleep 15 ;;
              Linux) sudo apt-get install -y docker.io docker-compose-plugin 2>&1 | tail -3; sudo systemctl start docker ;;
            esac
            if docker info &>/dev/null 2>&1; then
              DOCKER_INSTALLED=true
              DOCKER_RUNNING=true
              _ok "Docker installed and running"
            else
              _warn "Docker installed but daemon may still be starting. Continuing..."
            fi
          else
            _warn "Docker not installed — see md-files/service_setup.md"
          fi
          _nl ;;
        mkcert)
          echo -e "  ${C}── mkcert ──${N}"
          _info "mkcert is required for trusted SSL certificates."
          case "$INST_OS" in
            macOS) _dim "  Install: brew install mkcert" ;;
            Linux) _dim "  Install: sudo apt install mkcert" ;;
          esac
          _nl
          _ask "Install mkcert now? [Y/n]: "
          read -r _mc
          if [[ "${_mc:-Y}" =~ ^[Yy] ]]; then
            case "$INST_OS" in
              macOS) brew install mkcert 2>&1 | tail -2 ;;
              Linux) sudo apt-get install -y mkcert 2>&1 | tail -2 ;;
            esac
            _ok "mkcert installed"
          else
            _warn "mkcert not installed — see md-files/service_setup.md"
          fi
          _nl ;;
        python3)
          if [[ "$PY_NEEDS_UPGRADE" == "true" ]]; then
            echo -e "  ${C}── Python Upgrade ──${N}"
            _info "Python ${PY_VER} is installed but the app requires ≥3.11."
          else
            echo -e "  ${C}── Python ──${N}"
            _info "Python is not installed."
          fi
          case "$INST_OS" in
            macOS) _dim "  Install: brew install python@3.12" ;;
            Linux) _dim "  Install: sudo apt install python3.12 python3.12-venv" ;;
          esac
          _nl
          _ask "Install/upgrade Python now? [Y/n]: "
          read -r _py
          if [[ "${_py:-Y}" =~ ^[Yy] ]]; then
            case "$INST_OS" in
              macOS) brew install python@3.12 2>&1 | tail -5 ;;
              Linux) sudo apt-get install -y python3.12 python3.12-venv 2>&1 | tail -5 ;;
            esac
            # Check if the new version is available
            if command -v python3.12 &>/dev/null; then
              _ok "Python 3.12 installed — will use python3.12 for venv"
              PY_CMD="python3.12"
            elif python3 --version 2>&1 | awk '{print $2}' | grep -qE '^3\.1[1-9]'; then
              _ok "Python upgraded successfully"
              PY_CMD="python3"
            else
              _warn "Python may have installed to a different path. Check: python3.12 --version"
              PY_CMD="python3"
            fi
          else
            _warn "Python not upgraded — venv may fail. See md-files/service_setup.md"
            PY_CMD="python3"
          fi
          _nl ;;
        node)
          echo -e "  ${C}── Node.js ──${N}"
          _info "Node.js ≥20 is required for the frontend build."
          case "$INST_OS" in
            macOS) _dim "  Install: brew install node@20" ;;
            Linux) _dim "  Install via NodeSource" ;;
          esac
          _nl
          _ask "Install Node.js now? [Y/n]: "
          read -r _nd
          if [[ "${_nd:-Y}" =~ ^[Yy] ]]; then
            case "$INST_OS" in
              macOS) brew install node@20 2>&1 | tail -5 ;;
              Linux) curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>&1 | tail -3; sudo apt-get install -y nodejs 2>&1 | tail -3 ;;
            esac
            if command -v node &>/dev/null; then
              _ok "Node.js $(node --version) installed"
            else
              _warn "Node.js installed but may need a new shell. Continuing..."
            fi
          else
            _warn "Node.js not installed — frontend build will fail. See md-files/service_setup.md"
          fi
          _nl ;;
        npm)
          _warn "npm is required (usually comes with Node.js)."
          _nl ;;
        supabase)
          echo -e "  ${C}── Supabase CLI ──${N}"
          _info "supabase CLI speeds up start/stop vs 'npx -y supabase'."
          _nl
          _ask "Install supabase CLI now? [Y/n]: "
          read -r _sb
          if [[ "${_sb:-Y}" =~ ^[Yy] ]]; then
            case "$INST_OS" in
              macOS) brew install supabase/tap/supabase 2>&1 | tail -3 ;;
              Linux) _warn "Install manually: https://github.com/supabase/cli#install-the-cli" ;;
            esac
            command -v supabase &>/dev/null && _ok "supabase CLI installed" || _warn "supabase CLI not on PATH yet — npx fallback will be used"
          fi
          _nl ;;
        libpq)
          echo -e "  ${C}── libpq (psql/pg_dump) ──${N}"
          _info "Needed to replay the database dump on restore."
          _nl
          _ask "Install libpq now? [Y/n]: "
          read -r _lpq
          if [[ "${_lpq:-Y}" =~ ^[Yy] ]]; then
            case "$INST_OS" in
              macOS)
                brew install libpq 2>&1 | tail -3
                # libpq is keg-only — add to PATH for the rest of this script.
                if [[ -d "$(brew --prefix libpq 2>/dev/null)/bin" ]]; then
                  export PATH="$(brew --prefix libpq)/bin:$PATH"
                  _info "Added libpq/bin to PATH for this install session"
                fi ;;
              Linux) sudo apt-get install -y postgresql-client 2>&1 | tail -3 ;;
            esac
            command -v psql &>/dev/null && _ok "psql installed" || _warn "psql not on PATH"
          fi
          _nl ;;
        jq)
          echo -e "  ${C}── jq ──${N}"
          _info "Needed to read MANIFEST.json from the backup archive."
          _nl
          _ask "Install jq now? [Y/n]: "
          read -r _jq
          if [[ "${_jq:-Y}" =~ ^[Yy] ]]; then
            case "$INST_OS" in
              macOS) brew install jq 2>&1 | tail -3 ;;
              Linux) sudo apt-get install -y jq 2>&1 | tail -3 ;;
            esac
            command -v jq &>/dev/null && _ok "jq installed" || _warn "jq not on PATH"
          fi
          _nl ;;
      esac
    done
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 2 — EXTRACT ARCHIVE
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 2 · Extracting Archive"
  _nl
  mkdir -p "$INSTALL_PATH"
  _ok "Directory created: ${INSTALL_PATH}"

  # Create temp dir for extraction
  EXTRACT_TMP="$(mktemp -d)"
  _info "Extracting outer archive: $(basename "$INSTALL_ARCHIVE")"
  tar xzf "$INSTALL_ARCHIVE" -C "$EXTRACT_TMP" 2>&1 | tail -5 || true
  _ok "Outer archive extracted"

  # Find inner archives
  _nl
  _info "Found components:"
  SQL_DUMP=""
  STORAGE_ARCHIVE=""
  REDIS_ARCHIVE=""
  CODE_ARCHIVE=""
  MANIFEST_PATH=""
  for f in "$EXTRACT_TMP"/*; do
    fname="$(basename "$f")"
    fsize="$(du -sh "$f" | awk '{print $1}')"
    _dim "  ${fname}  [${fsize}]"
    case "$fname" in
      *-MANIFEST.json)           MANIFEST_PATH="$f" ;;
      *-cbnext.sql)              SQL_DUMP="$f" ;;
      *-cbnext-storage.tar.gz)   STORAGE_ARCHIVE="$f" ;;
      *-cbnext-redis.tar.gz)     REDIS_ARCHIVE="$f" ;;
      *-cbnext-code.tar.gz)      CODE_ARCHIVE="$f" ;;
      *-cbnext.env)              cp "$f" "${INSTALL_PATH}/.env"; _log "Restored .env" ;;
      *-supabase-config.toml)    mkdir -p "${INSTALL_PATH}/supabase"; cp "$f" "${INSTALL_PATH}/supabase/config.toml"; _log "Restored config.toml" ;;
      *.env.*)                   cp "$f" "${INSTALL_PATH}/$(echo "$fname" | sed 's/^[0-9_-]*-//')"; _log "Restored extra env: $fname" ;;
    esac
  done

  # Read the manifest (if present) — it tells us project_id, ports, and lets us
  # verify component sha256 before restoring them.
  RESTORE_PROJECT_ID=""
  RESTORE_API_PORT=54321
  RESTORE_DB_PORT=54322
  if [[ -n "$MANIFEST_PATH" && -f "$MANIFEST_PATH" ]]; then
    _ok "MANIFEST.json found — reading restore parameters"
    if command -v jq &>/dev/null; then
      RESTORE_PROJECT_ID="$(jq -r '.supabase.project_id // empty' "$MANIFEST_PATH")"
      RESTORE_API_PORT="$(jq -r '.ports.supabase_api // 54321' "$MANIFEST_PATH")"
      RESTORE_DB_PORT="$(jq -r '.ports.supabase_db // 54322' "$MANIFEST_PATH")"
      _dim "  project_id: ${RESTORE_PROJECT_ID}, api: ${RESTORE_API_PORT}, db: ${RESTORE_DB_PORT}"

      # Verify component sha256 (best-effort — warn on mismatch, don't abort)
      while IFS=$'\t' read -r _label _file _sha; do
        [[ -z "$_file" || -z "$_sha" ]] && continue
        local_path="${EXTRACT_TMP}/${_file}"
        [[ -f "$local_path" ]] || continue
        actual="$(_sha256 "$local_path")"
        if [[ -n "$actual" && "$actual" != "$_sha" ]]; then
          _warn "Checksum mismatch for ${_label}: archive may be corrupted"
        fi
      done < <(jq -r '.components | to_entries[] | "\(.key)\t\(.value.file)\t\(.value.sha256)"' "$MANIFEST_PATH" 2>/dev/null)
    else
      _warn "jq missing — skipping manifest checksum verification"
    fi
    # Stash manifest in the install dir so --retry can find it later.
    cp "$MANIFEST_PATH" "${INSTALL_PATH}/.cbnext-manifest.json"
  else
    _warn "No MANIFEST.json in archive — restoring with defaults (older backup)"
  fi

  # Copy SQL dump and storage archive to install path so they survive temp cleanup
  if [[ -n "$SQL_DUMP" && -f "$SQL_DUMP" ]]; then
    cp "$SQL_DUMP" "${INSTALL_PATH}/$(basename "$SQL_DUMP")"
    SQL_DUMP="${INSTALL_PATH}/$(basename "$SQL_DUMP")"
    _log "Copied SQL dump to install path"
  fi
  if [[ -n "$STORAGE_ARCHIVE" && -f "$STORAGE_ARCHIVE" ]]; then
    cp "$STORAGE_ARCHIVE" "${INSTALL_PATH}/$(basename "$STORAGE_ARCHIVE")"
    STORAGE_ARCHIVE="${INSTALL_PATH}/$(basename "$STORAGE_ARCHIVE")"
    _log "Copied storage archive to install path"
  fi
  if [[ -n "$REDIS_ARCHIVE" && -f "$REDIS_ARCHIVE" ]]; then
    cp "$REDIS_ARCHIVE" "${INSTALL_PATH}/$(basename "$REDIS_ARCHIVE")"
    REDIS_ARCHIVE="${INSTALL_PATH}/$(basename "$REDIS_ARCHIVE")"
    _log "Copied redis archive to install path"
  fi

  # Extract code archive
  if [[ -n "$CODE_ARCHIVE" ]]; then
    _nl
    _info "Extracting code archive..."
    tar xzf "$CODE_ARCHIVE" -C "$INSTALL_PATH" --strip-components=1 2>&1 | tail -5 || true
    _ok "Code extracted to ${INSTALL_PATH}"
  else
    _fail "No code archive found in bundle!"
    rm -rf "$EXTRACT_TMP"
    exit 1
  fi

  # Validate structure
  _nl
  _info "Validating file structure..."
  REQUIRED_FILES=("frontend" "backend" "supabase" "dev.sh" "proxy443.js" "requirements.txt")
  ALL_VALID=true
  for req in "${REQUIRED_FILES[@]}"; do
    if [[ -e "${INSTALL_PATH}/${req}" ]]; then
      _ok "${req}  ✓"
    else
      _fail "${req}  ✗ MISSING"
      ALL_VALID=false
    fi
  done
  # Optional files — warn if missing
  for opt in "pf-dev.conf" "docker-compose.yml" "md-files" "frontend/certs"; do
    if [[ -e "${INSTALL_PATH}/${opt}" ]]; then
      _ok "${opt}  ✓"
    else
      _warn "${opt}  — not in archive (optional)"
    fi
  done

  if [[ "$ALL_VALID" == "false" ]]; then
    _fail "Some required files are missing. Archive may be incomplete."
  fi
  rm -rf "$EXTRACT_TMP"

  cd "$INSTALL_PATH"

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 3 — PYTHON VENV
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 3 · Python Virtual Environment"
  _nl
  PY_CMD="${PY_CMD:-python3}"
  if command -v "$PY_CMD" &>/dev/null; then
    _info "Using: $PY_CMD ($($PY_CMD --version 2>&1))"
    _info "Creating venv: .venv"
    "$PY_CMD" -m venv .venv 2>&1 | tail -3
    _ok "Virtual environment created"
    _info "Installing Python dependencies..."
    .venv/bin/pip install --upgrade pip -q >> "$LOG_FILE" 2>&1 &
    _spin $! "Upgrading pip..."
    _ok "pip upgraded"
    if [[ -f "requirements.txt" ]]; then
      .venv/bin/pip install -r requirements.txt -q >> "$LOG_FILE" 2>&1 &
      _spin $! "Installing requirements.txt..."
    fi
    if [[ -f "backend/requirements.txt" ]]; then
      .venv/bin/pip install -r backend/requirements.txt -q >> "$LOG_FILE" 2>&1 &
      _spin $! "Installing backend/requirements.txt..."
    fi
    _ok "Python dependencies installed"
    # Verify
    _info "Verifying key packages..."
    for pkg in strawberry fastapi uvicorn sqlalchemy; do
      if .venv/bin/python -c "import $pkg" 2>/dev/null; then
        _ok "${pkg}  ✓"
      else
        _warn "${pkg}  — not found"
      fi
    done
  else
    _warn "${PY_CMD} not available — skipping venv creation"
    _dim "  Install Python ≥3.11 and re-run --install"
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 4 — NODE.JS
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 4 · Node.js Dependencies"
  _nl
  if command -v npm &>/dev/null && [[ -d "frontend" ]]; then
    _info "Running: npm install in frontend/"
    (cd frontend && npm install >> "$LOG_FILE" 2>&1) &
    _spin $! "Installing node modules..."
    if [[ -d "frontend/node_modules" ]]; then
      _ok "node_modules/ created"
    else
      _warn "node_modules not found after npm install"
    fi
  else
    _warn "npm not available or frontend/ missing — skipping"
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 5 — DOCKER & SUPABASE
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 5 · Docker & Supabase"
  _nl
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    _ok "Docker daemon running"
    _nl
    _info "Starting Supabase local stack..."
    _info "Running: npx supabase start (this may take a few minutes on first run)"
    npx -y supabase start >> "$LOG_FILE" 2>&1 &
    _spin $! "Starting Supabase containers..."
    _nl
    _ok "Supabase started"

    # ── Sync JWT keys from running instance to .env ──────────────────────────
    _info "Syncing JWT keys from Supabase instance..."
    _SB_STATUS="$(npx supabase status 2>/dev/null || true)"
    _SB_ANON="$(echo "$_SB_STATUS" | grep -iE 'Publishable|anon' | head -1 | awk -F'│' '{print $3}' | xargs 2>/dev/null || true)"
    _SB_SECRET="$(echo "$_SB_STATUS" | grep -iE '^│.*Secret ' | head -1 | awk -F'│' '{print $3}' | xargs 2>/dev/null || true)"
    if [[ -n "$_SB_ANON" && -f "${INSTALL_PATH}/.env" ]]; then
      sed -i.bak "s|^SUPABASE_ANON_KEY=.*|SUPABASE_ANON_KEY=${_SB_ANON}|" "${INSTALL_PATH}/.env"
      sed -i.bak "s|^VITE_SUPABASE_ANON_KEY=.*|VITE_SUPABASE_ANON_KEY=${_SB_ANON}|" "${INSTALL_PATH}/.env"
      rm -f "${INSTALL_PATH}/.env.bak"
      _ok "Anon key synced to .env"
    fi
    if [[ -n "$_SB_SECRET" && -f "${INSTALL_PATH}/.env" ]]; then
      sed -i.bak "s|^SUPABASE_SERVICE_KEY=.*|SUPABASE_SERVICE_KEY=${_SB_SECRET}|" "${INSTALL_PATH}/.env"
      rm -f "${INSTALL_PATH}/.env.bak"
      _ok "Service key synced to .env"
    fi
  else
    _warn "Docker not running — Supabase cannot start."
    _dim "  Start Docker and run: npx supabase start"
    _dim "  See md-files/service_setup.md for help."
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 6 — DATABASE RESTORE
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 6 · Database"
  _nl
  DB_RESTORED=false
  if [[ -n "$SQL_DUMP" && -f "$SQL_DUMP" ]]; then
    SQL_SIZE="$(du -sh "$SQL_DUMP" | awk '{print $1}')"
    _info "A database dump was found: ${BLD}$(basename "$SQL_DUMP")${N} [${SQL_SIZE}]"
    _nl
    echo -e "  ${W}?${N} How would you like to set up the database?"
    echo ""
    echo -e "      ${BLD}1) Restore from backup${N} ${G}(recommended)${N}"
    echo -e "         ${D}Loads all existing data: accounts, customers, subscriptions,${N}"
    echo -e "         ${D}invoices, SKUs, offers, coupons, and billing history.${N}"
    echo -e "         ${D}You'll be able to log in with existing accounts immediately.${N}"
    echo ""
    echo -e "      ${BLD}2) Start fresh${N}"
    echo -e "         ${D}Creates empty tables via Alembic migrations. No data loaded.${N}"
    echo -e "         ${D}You'll need to create a new account and set up everything${N}"
    echo -e "         ${D}from scratch. Good for a clean development start.${N}"
    echo ""
    _ask "Selection [1]: "
    read -r _db_choice
    _db_choice=${_db_choice:-1}
    _nl
    if [[ "$_db_choice" == "1" ]]; then
      # Get Supabase DB port from config or default
      SB_DB_PORT=54322
      if grep -q 'port = ' supabase/config.toml 2>/dev/null; then
        SB_DB_PORT="$(grep -A0 '^\[db\]' supabase/config.toml | head -5 | grep 'port' | head -1 | awk '{print $3}' || echo 54322)"
        [[ -z "$SB_DB_PORT" || "$SB_DB_PORT" == "0" ]] && SB_DB_PORT=54322
      fi
      _RESTORE_DB_URL="postgresql://postgres:postgres@127.0.0.1:${SB_DB_PORT}/postgres"

      # Drop and recreate public schema to avoid "already exists" conflicts
      _info "Preparing database (clean public schema)..."
      psql "$_RESTORE_DB_URL" -c "
        DROP SCHEMA IF EXISTS public CASCADE;
        CREATE SCHEMA public;
        GRANT ALL ON SCHEMA public TO postgres;
        GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
        GRANT CREATE ON SCHEMA public TO postgres;
      " >> "$LOG_FILE" 2>&1
      _ok "Public schema reset"

      _info "Restoring database (auth/storage errors are expected)..."
      psql "$_RESTORE_DB_URL" -v ON_ERROR_STOP=0 -f "$SQL_DUMP" >> "$LOG_FILE" 2>&1 || true
      _ok "Database data restored"

      # Storage metadata requires supabase_admin (superuser) since postgres can't SET ROLE
      _ADMIN_DB_URL="postgresql://supabase_admin:postgres@127.0.0.1:${SB_DB_PORT}/postgres"
      _info "Restoring storage metadata..."
      psql "$_ADMIN_DB_URL" -v ON_ERROR_STOP=0 -f "$SQL_DUMP" >> "$LOG_FILE" 2>&1 || true
      _ok "Storage metadata restored"

      # ── Sanity check: did the public schema actually get populated? ────────
      # If no tables exist (or they're all empty) the dump replay failed in a
      # way ON_ERROR_STOP=0 hid. Fall back to migrations + seed.
      _PUB_TABLES="$(psql "$_RESTORE_DB_URL" -tA -c \
        "SELECT count(*) FROM pg_tables WHERE schemaname='public'" 2>/dev/null | tr -d '[:space:]')"
      _PUB_TABLES="${_PUB_TABLES:-0}"
      if (( _PUB_TABLES < 5 )); then
        _warn "Dump replay only produced ${_PUB_TABLES} public tables — falling back to migrations + seed"
        DB_FALLBACK=true
      else
        _ok "Public schema has ${_PUB_TABLES} tables"
        DB_FALLBACK=false
      fi

      if [[ "${DB_FALLBACK:-false}" == "true" ]]; then
        _info "Resetting public schema before fallback..."
        psql "$_RESTORE_DB_URL" -c "
          DROP SCHEMA IF EXISTS public CASCADE;
          CREATE SCHEMA public;
          GRANT ALL ON SCHEMA public TO postgres;
          GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
          GRANT CREATE ON SCHEMA public TO postgres;
        " >> "$LOG_FILE" 2>&1
        if [[ -d "backend" ]]; then
          _info "Running Alembic migrations..."
          (cd backend && ../.venv/bin/python -m alembic upgrade head 2>&1 | tail -8) || \
            _warn "alembic upgrade failed — schema may be partial"
        fi
        if [[ -f "supabase/seed.sql" ]]; then
          _info "Applying supabase/seed.sql..."
          psql "$_RESTORE_DB_URL" -v ON_ERROR_STOP=0 -f supabase/seed.sql >> "$LOG_FILE" 2>&1 || true
          _ok "Seed applied"
        fi
        _ok "Fallback path complete — schema rebuilt from migrations+seed"
      fi

      DB_RESTORED=true

      # Recreate auth users via Supabase Admin API to preserve original UUIDs
      _info "Recreating auth users via Supabase Admin API..."
      _SB_SVC_KEY="$(grep '^SUPABASE_SERVICE_KEY=' .env 2>/dev/null | cut -d= -f2- || echo "")"
      _SB_API="http://127.0.0.1:${SB_DB_PORT%2}1"  # API port = DB port with last digit changed
      _SB_API="http://127.0.0.1:54321"  # Default Supabase API port

      _AUTH_DATA="$(awk '
      BEGIN { in_copy=0 }
      /^COPY auth\.users \(/ {
          in_copy=1
          gsub(/^COPY auth\.users \(/, "")
          gsub(/\) FROM stdin;$/, "")
          n = split($0, cols, ",")
          for (i=1; i<=n; i++) { gsub(/^ +| +$/, "", cols[i]); if (cols[i]=="id") ic=i; if (cols[i]=="email") ec=i; if (cols[i]=="raw_user_meta_data") mc=i }
          next
      }
      in_copy && /^\\\.$/ { in_copy=0; next }
      in_copy {
          n = split($0, f, "\t")
          uid = (ic<=n) ? f[ic] : ""
          email = (ec<=n) ? f[ec] : ""
          meta = (mc<=n) ? f[mc] : "{}"
          if (meta == "\\N") meta = "{}"
          if (uid != "" && email != "" && email != "\\N") print uid "\t" email "\t" meta
      }
      ' "$SQL_DUMP" 2>/dev/null)"

      _AUTH_COUNT=0
      _AUTH_UIDS=()
      _AUTH_EMAILS=()
      if [[ -n "$_AUTH_DATA" && -n "$_SB_SVC_KEY" ]]; then
        while IFS=$'\t' read -r _uid _email _meta; do
          [[ -z "$_uid" || -z "$_email" ]] && continue
          _HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${_SB_API}/auth/v1/admin/users" \
            -H "apikey: ${_SB_SVC_KEY}" \
            -H "Authorization: Bearer ${_SB_SVC_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"${_uid}\",\"email\":\"${_email}\",\"email_confirm\":true,\"app_metadata\":{\"providers\":[\"google\"],\"provider\":\"google\"}}" \
            2>/dev/null || echo "000")
          if [[ "$_HTTP" == "200" || "$_HTTP" == "201" ]]; then
            _ok "Auth user: ${_email}"
            _AUTH_COUNT=$((_AUTH_COUNT + 1))
            _AUTH_UIDS+=("$_uid")
            _AUTH_EMAILS+=("$_email")
          fi
        done <<< "$_AUTH_DATA"
      fi
      _ok "${_AUTH_COUNT} auth user(s) recreated"

      # ── Demo-password reset ────────────────────────────────────────────────
      # Restored users have no password (GoTrue won't accept dumped hashes).
      # Offer to set a single demo password for ALL restored users so the demo
      # can log in immediately. Off by default — destructive if the original
      # hashes were ever recoverable.
      if (( _AUTH_COUNT > 0 )); then
        _nl
        _ask "Set a demo password for all ${_AUTH_COUNT} restored users? [y/N]: "
        read -r _set_pw
        if [[ "${_set_pw:-N}" =~ ^[Yy] ]]; then
          _ask "Demo password (min 6 chars): "
          read -rs _demo_pw
          echo ""
          if [[ ${#_demo_pw} -ge 6 ]]; then
            _info "Applying demo password to ${_AUTH_COUNT} user(s)..."
            _PW_OK=0
            for _i in "${!_AUTH_UIDS[@]}"; do
              _uid="${_AUTH_UIDS[$_i]}"
              _email="${_AUTH_EMAILS[$_i]}"
              _HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
                -X PUT "${_SB_API}/auth/v1/admin/users/${_uid}" \
                -H "apikey: ${_SB_SVC_KEY}" \
                -H "Authorization: Bearer ${_SB_SVC_KEY}" \
                -H "Content-Type: application/json" \
                -d "{\"password\":\"${_demo_pw}\"}" \
                2>/dev/null || echo "000")
              [[ "$_HTTP" == "200" ]] && _PW_OK=$((_PW_OK + 1))
            done
            _ok "Demo password set on ${_PW_OK}/${_AUTH_COUNT} user(s)"
          else
            _warn "Password too short — skipped"
          fi
          unset _demo_pw
        fi
      fi
    else
      _info "Running migrations..."
      if [[ -d "backend" && -f ".venv/bin/alembic" ]]; then
        (cd backend && ../.venv/bin/alembic upgrade head 2>&1 | tail -5)
        _ok "Migrations complete"
      elif [[ -d "backend" ]]; then
        (cd backend && ../.venv/bin/python -m alembic upgrade head 2>&1 | tail -5) || _warn "Alembic not found — run migrations manually"
      fi
    fi
  else
    _info "No database dump found in archive."
    _info "Running migrations for fresh database..."
    if [[ -d "backend" ]]; then
      (cd backend && ../.venv/bin/python -m alembic upgrade head 2>&1 | tail -5) 2>/dev/null || _warn "Could not run migrations — do so manually"
    fi
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 7 — STORAGE RESTORE
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 7 · Storage"
  _nl
  if [[ -n "$STORAGE_ARCHIVE" && -f "$STORAGE_ARCHIVE" ]]; then
    STOR_SIZE="$(du -sh "$STORAGE_ARCHIVE" | awk '{print $1}')"
    _info "A storage backup was found: ${BLD}$(basename "$STORAGE_ARCHIVE")${N} [${STOR_SIZE}]"
    _nl
    echo -e "  ${W}?${N} Would you like to restore the storage volume?"
    echo ""
    echo -e "      ${BLD}1) Restore storage${N} ${G}(recommended)${N}"
    echo -e "         ${D}Restores uploaded files: company logos, brand assets,${N}"
    echo -e "         ${D}login backgrounds, and any documents uploaded by users.${N}"
    echo -e "         ${D}The UI will display all branding and images immediately.${N}"
    echo ""
    echo -e "      ${BLD}2) Start with empty storage${N}"
    echo -e "         ${D}No files loaded. The application will work, but custom${N}"
    echo -e "         ${D}branding images, logos, and uploads won't be available.${N}"
    echo -e "         ${D}Users can re-upload files through the UI.${N}"
    echo ""
    _ask "Selection [1]: "
    read -r _stor_choice
    _stor_choice=${_stor_choice:-1}
    _nl
    if [[ "$_stor_choice" == "1" ]]; then
      _info "Extracting storage archive..."
      _STOR_TMP="$(mktemp -d)"
      tar xzf "$STORAGE_ARCHIVE" -C "$_STOR_TMP" 2>/dev/null || true

      # Normalise double-stub path (./stub/stub/... → use inner stub)
      _STOR_ROOT="$_STOR_TMP/stub"
      [[ -d "$_STOR_TMP/stub/stub" ]] && _STOR_ROOT="$_STOR_TMP/stub/stub"

      # Get service key for API calls
      _SB_SVC_KEY="$(grep '^SUPABASE_SERVICE_KEY=' .env 2>/dev/null | cut -d= -f2- || echo "")"
      _SB_API="http://127.0.0.1:54321"

      _info "Uploading storage files via Supabase API..."
      _TOTAL_UPLOADED=0
      for _bdir in "$_STOR_ROOT"/*/; do
        [[ ! -d "$_bdir" ]] && continue
        _bucket="$(basename "$_bdir")"

        # Create bucket (ignore 409 = already exists)
        curl -s -o /dev/null -X POST "${_SB_API}/storage/v1/bucket" \
          -H "apikey: ${_SB_SVC_KEY}" \
          -H "Authorization: Bearer ${_SB_SVC_KEY}" \
          -H "Content-Type: application/json" \
          -d "{\"id\":\"${_bucket}\",\"name\":\"${_bucket}\",\"public\":true}" 2>/dev/null || true

        # Upload each file via API (sets xattrs + metadata automatically)
        _bcount=0
        while IFS= read -r _fpath; do
          _relpath="${_fpath#${_bdir}}"
          _obj_path="${_relpath%/*}"   # everything except version UUID
          case "$_obj_path" in
            *.jpg|*.jpeg) _mime="image/jpeg" ;;
            *.png)        _mime="image/png" ;;
            *.webp)       _mime="image/webp" ;;
            *.ico)        _mime="image/vnd.microsoft.icon" ;;
            *.svg)        _mime="image/svg+xml" ;;
            *.gif)        _mime="image/gif" ;;
            *)            _mime="application/octet-stream" ;;
          esac
          curl -s -o /dev/null -X POST "${_SB_API}/storage/v1/object/${_bucket}/${_obj_path}" \
            -H "apikey: ${_SB_SVC_KEY}" \
            -H "Authorization: Bearer ${_SB_SVC_KEY}" \
            -H "Content-Type: ${_mime}" \
            -H "x-upsert: true" \
            --data-binary "@${_fpath}" 2>/dev/null || true
          _bcount=$((_bcount + 1))
        done < <(find "$_bdir" -type f)
        _TOTAL_UPLOADED=$((_TOTAL_UPLOADED + _bcount))
        _ok "Bucket '${_bucket}': ${_bcount} file(s) uploaded"
      done
      rm -rf "$_STOR_TMP"
      _ok "Storage restored: ${_TOTAL_UPLOADED} total file(s) via API"
    else
      _info "Skipping storage restore — starting empty"
    fi
  else
    _info "No storage backup found in archive — storage starts empty."
  fi

  # Clean up temp restore files from install path
  [[ -n "$SQL_DUMP" && -f "$SQL_DUMP" && "$SQL_DUMP" == "${INSTALL_PATH}/"* ]] && rm -f "$SQL_DUMP"
  [[ -n "$STORAGE_ARCHIVE" && -f "$STORAGE_ARCHIVE" && "$STORAGE_ARCHIVE" == "${INSTALL_PATH}/"* ]] && rm -f "$STORAGE_ARCHIVE"

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 8 — SSL CERTIFICATES
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 8 · SSL Certificates"
  _nl
  mkdir -p frontend/certs
  if command -v mkcert &>/dev/null; then
    _info "Installing local CA with mkcert..."
    mkcert -install 2>&1 | tail -3
    _ok "Local CA installed"
    _nl
    _info "Generating certificates for local domains..."
    mkcert -key-file frontend/certs/key.pem -cert-file frontend/certs/cert.pem \
      localhost 127.0.0.1 cloudblue.ai admin.cloudblue.ai portal.cloudblue.ai 2>&1 | tail -3
    _ok "frontend/certs/key.pem  — generated"
    _ok "frontend/certs/cert.pem — generated"
  else
    _warn "mkcert not available — cannot generate SSL certificates"
    _dim "  Install mkcert and run: mkcert -install && mkcert -key-file frontend/certs/key.pem -cert-file frontend/certs/cert.pem localhost 127.0.0.1 cloudblue.ai admin.cloudblue.ai portal.cloudblue.ai"
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 9 — HOSTS FILE
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 9 · Domain Configuration"
  _nl
  HOSTS_OK=false
  VITE_PORT=5173

  # Check if already configured
  if grep -q "cloudblue.ai" /etc/hosts 2>/dev/null; then
    _ok "cloudblue.ai already in /etc/hosts"
    HOSTS_OK=true
  else
    _info "The following entries need to be added to /etc/hosts:"
    echo ""
    _dim "  127.0.0.1   cloudblue.ai"
    _dim "  127.0.0.1   admin.cloudblue.ai"
    _dim "  127.0.0.1   portal.cloudblue.ai"
    _nl
    _ask "Attempt to add entries with sudo? [Y/n]: "
    read -r _hosts
    _nl
    if [[ "${_hosts:-Y}" =~ ^[Yy] ]]; then
      if echo -e "\n# CB-Next local development\n127.0.0.1   cloudblue.ai\n127.0.0.1   admin.cloudblue.ai\n127.0.0.1   portal.cloudblue.ai" | sudo tee -a /etc/hosts > /dev/null 2>&1; then
        _ok "Hosts file updated"
        HOSTS_OK=true
      else
        _warn "Could not write to /etc/hosts (no sudo access)"
      fi
    fi

    if [[ "$HOSTS_OK" == "false" ]]; then
      _warn "Hosts file not updated — falling back to localhost"
      _nl
      _info "Falling back to localhost path-based routing:"
      _dim "  Admin:    https://localhost:${VITE_PORT}/admin"
      _dim "  ISV:      https://localhost:${VITE_PORT}/isv"
      _dim "  Customer: https://localhost:${VITE_PORT}/platform"
      _nl
      _dim "  To use domain names later, run:"
      _dim "  sudo bash -c 'echo \"127.0.0.1 cloudblue.ai admin.cloudblue.ai portal.cloudblue.ai\" >> /etc/hosts'"
    fi
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 10 — PORT AVAILABILITY
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 10 · Port Availability"
  _nl
  _info "Checking default ports..."

  _port_label() {
    case "$1" in
      443)   echo "HTTPS proxy" ;;
      5173)  echo "Vite frontend" ;;
      8000)  echo "Backend API" ;;
      54321) echo "Supabase API" ;;
      54322) echo "Supabase DB" ;;
      54323) echo "Supabase Studio" ;;
      *)     echo "unknown" ;;
    esac
  }

  PORTS_CHANGED=false
  for port in 443 5173 8000 54321 54322 54323; do
    label="$(_port_label "$port")"
    if _port_free "$port"; then
      _ok "${port}  (${label}) — ${G}available${N}"
    else
      _warn "${port}  (${label}) — ${R}in use${N}"
      suggested="$(_next_port "$port")"
      # Find next free port
      while ! _port_free "$suggested"; do
        suggested="$(_next_port "$suggested")"
      done
      _ask "Use port ${suggested} instead, or enter your own [${suggested}]: "
      read -r _new_port
      _new_port="${_new_port:-$suggested}"
      _nl

      # Update VITE_PORT if it's the frontend port
      if [[ "$port" == "5173" ]]; then
        VITE_PORT="$_new_port"
        # Update Vite config
        if [[ -f "frontend/vite.config.js" ]]; then
          sed -i.bak "s/port: ${port}/port: ${_new_port}/" frontend/vite.config.js
          rm -f frontend/vite.config.js.bak
        fi
        # Update proxy443
        if [[ -f "proxy443.js" ]]; then
          sed -i.bak "s/port: ${port}/port: ${_new_port}/" proxy443.js
          rm -f proxy443.js.bak
        fi
      fi
      # Update backend port
      if [[ "$port" == "8000" && -f "dev.sh" ]]; then
        sed -i.bak "s/--port ${port}/--port ${_new_port}/" dev.sh
        rm -f dev.sh.bak
      fi
      _ok "Port ${port} → ${_new_port}"
      PORTS_CHANGED=true
    fi
  done

  if [[ "$PORTS_CHANGED" == "true" ]]; then
    _info "Port configs updated"
  fi

fi # end INSTALL_MODE

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 11 — KEY & OAUTH CONFIGURATION (shared by --install and --retry)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$INSTALL_MODE" == "true" || "$RETRY_MODE" == "true" ]]; then

  [[ "${RETRY_JUMP:-}" != "true" ]] && _head "Phase 11 · API Keys & OAuth"

  _nl

  # --me flag: check for Taylor Giddens
  if [[ "$ME_FLAG" == "true" ]]; then
    _ask "What is your name? "
    read -r _me_name
    if [[ "$_me_name" == "Taylor Giddens" ]]; then
      _ok "Welcome back, Taylor! Auto-configuring dev keys..."
      # Taylor's dev keys are already in the .env from the backup
      _ok "All keys configured from backup .env"
      _nl
      KEYS_CONFIGURED=true
    else
      _info "Name not recognized — continuing with manual key setup."
      ME_FLAG=false
    fi
  fi

  if [[ "$ME_FLAG" != "true" ]]; then
    KEYS_CONFIGURED=false
    _info "The application needs API keys for these services:"
    echo ""
    echo -e "    ${BLD}Service        Status        What it does${N}"
    echo -e "    ─────────────  ────────────  ───────────────────────────────────────"
    echo -e "    Supabase       ${G}Local stack${N}   Auth, database, file storage"
    echo -e "    Stripe         ${Y}Keys needed${N}   Payment processing (can use dummy)"
    echo -e "    Google OAuth   ${Y}Keys needed${N}   Google login, Gmail sending"
    echo ""
    _ask "Do you have your API keys and OAuth credentials ready? [y/N]: "
    read -r _keys_ready
    _nl

    if [[ "${_keys_ready:-N}" =~ ^[Yy] ]]; then
      ENV_FILE="${INSTALL_PATH:-.}/.env"

      # Stripe
      echo -e "  ${C}── Stripe ──${N}"
      _info "Stripe handles payment processing for subscriptions."
      _dim "  Press Enter on each prompt to use dummy keys (no real charges)."
      _nl
      _ask "Stripe Secret Key [sk_dummy_local]: "
      read -r _sk
      _sk="${_sk:-sk_dummy_local}"
      _ask "Stripe Publishable Key [pk_dummy_local]: "
      read -r _pk
      _pk="${_pk:-pk_dummy_local}"
      _ask "Stripe Webhook Secret [whsec_dummy_local]: "
      read -r _wh
      _wh="${_wh:-whsec_dummy_local}"

      if [[ -f "$ENV_FILE" ]]; then
        sed -i.bak "s|^STRIPE_SECRET_KEY=.*|STRIPE_SECRET_KEY=${_sk}|" "$ENV_FILE"
        sed -i.bak "s|^STRIPE_PUBLISHABLE_KEY=.*|STRIPE_PUBLISHABLE_KEY=${_pk}|" "$ENV_FILE"
        sed -i.bak "s|^STRIPE_WEBHOOK_SECRET=.*|STRIPE_WEBHOOK_SECRET=${_wh}|" "$ENV_FILE"
        sed -i.bak "s|^VITE_STRIPE_PUBLISHABLE_KEY=.*|VITE_STRIPE_PUBLISHABLE_KEY=${_pk}|" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
      fi

      if [[ "$_sk" == "sk_dummy_local" ]]; then
        _ok "Stripe set to ${Y}dummy mode${N} — no real charges"
      else
        _ok "Stripe keys saved to .env"
      fi

      _nl
      # Google OAuth
      echo -e "  ${C}── Google OAuth ──${N}"
      _ask "Google Client ID (or Enter to skip): "
      read -r _gid
      if [[ -n "$_gid" ]]; then
        _ask "Google Client Secret: "
        read -r _gsec
        _ask "Gmail Sender Address [noreply@cloudblue.ai]: "
        read -r _gmail
        _gmail="${_gmail:-noreply@cloudblue.ai}"

        if [[ -f "$ENV_FILE" ]]; then
          sed -i.bak "s|^GOOGLE_CLIENT_ID=.*|GOOGLE_CLIENT_ID=${_gid}|" "$ENV_FILE"
          sed -i.bak "s|^GOOGLE_CLIENT_SECRET=.*|GOOGLE_CLIENT_SECRET=${_gsec}|" "$ENV_FILE"
          sed -i.bak "s|^GMAIL_SENDER_ADDRESS=.*|GMAIL_SENDER_ADDRESS=${_gmail}|" "$ENV_FILE"
          rm -f "${ENV_FILE}.bak"
        fi
        # Update supabase config
        if [[ -f "supabase/config.toml" ]]; then
          sed -i.bak 's|^client_id = .*|client_id = "env(GOOGLE_CLIENT_ID)"|' supabase/config.toml
          sed -i.bak 's|^secret = .*|secret = "env(GOOGLE_CLIENT_SECRET)"|' supabase/config.toml
          rm -f supabase/config.toml.bak
        fi
        _ok "Google credentials saved"
      else
        _info "Google OAuth skipped — Google login won't work until configured"
        _dim "  See md-files/service_setup.md for setup instructions"
      fi

      KEYS_CONFIGURED=true

      # Restart Supabase to pick up config changes
      if command -v docker &>/dev/null && docker info &>/dev/null; then
        _nl
        _info "Restarting Supabase to apply config changes..."
        npx -y supabase stop 2>/dev/null || true
        npx -y supabase start 2>&1 | tail -3
        _ok "Supabase restarted"
      fi
    else
      # No keys — use defaults
      _info "No problem! Using default development keys."
      _dim "  The app will run with dummy Stripe keys and no Google login."
      _nl
      echo -e "  ${B}📄 Full setup guide:${N} ${UL}md-files/service_setup.md${N}"
      echo ""
      echo -e "  ${G}When you have your keys, run:${N}"
      echo -e "    ${BLD}bash backup/full-backup.sh --retry${N}"
      _nl
      KEYS_CONFIGURED=true  # defaults are fine
    fi
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 12 — USER ACCOUNT CREATION
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 12 · User Account"
  _nl

  if [[ "${DB_RESTORED:-false}" == "true" ]]; then
    _info "Database was restored from backup — existing user accounts are available."
    _dim "  You can log in with any previously created account."
    _nl
  fi

  echo -e "  ${W}?${N} Would you like to create a new user account so you can log in?"
  echo ""
  echo -e "      ${BLD}1) Yes, create an account${N} ${G}(recommended for new users)${N}"
  echo -e "         ${D}You'll be prompted for an email and password.${N}"
  echo -e "         ${D}The account will be created in Supabase and ready to use${N}"
  echo -e "         ${D}as soon as the application starts.${N}"
  echo ""
  echo -e "      ${BLD}2) No, skip${N}"
  echo -e "         ${D}You can create an account through the sign-up page later,${N}"
  echo -e "         ${D}or use an existing account if the database was restored.${N}"
  echo ""
  _ask "Selection [1]: "
  read -r _user_choice
  _user_choice=${_user_choice:-1}
  _nl

  USER_EMAIL=""
  if [[ "$_user_choice" == "1" ]]; then
    _ask "Email address: "
    read -r USER_EMAIL
    if [[ -z "$USER_EMAIL" ]]; then
      _warn "No email provided — skipping user creation"
    else
      _ask "Password (min 6 characters): "
      read -rs _user_pass
      echo ""
      _nl
      if [[ ${#_user_pass} -lt 6 ]]; then
        _warn "Password too short (min 6) — skipping user creation"
        USER_EMAIL=""
      else
        # Get Supabase API URL and service key
        SB_URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
        SB_KEY="${SUPABASE_SERVICE_KEY:-}"
        # Try to read from .env if not set
        if [[ -z "$SB_KEY" && -f ".env" ]]; then
          SB_KEY="$(grep '^SUPABASE_SERVICE_KEY=' .env 2>/dev/null | cut -d= -f2- || echo "")"
        fi
        if [[ -z "$SB_KEY" && -f ".env" ]]; then
          SB_URL="$(grep '^SUPABASE_URL=' .env 2>/dev/null | cut -d= -f2- || echo "$SB_URL")"
        fi

        if [[ -n "$SB_KEY" ]]; then
          _info "Creating user account in Supabase..."
          HTTP_CODE=$(curl -s -o /tmp/cb_user_resp.json -w "%{http_code}" \
            -X POST "${SB_URL}/auth/v1/admin/users" \
            -H "apikey: ${SB_KEY}" \
            -H "Authorization: Bearer ${SB_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"email\":\"${USER_EMAIL}\",\"password\":\"${_user_pass}\",\"email_confirm\":true}" 2>/dev/null || echo "000")

          if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
            _ok "User created: ${BLD}${USER_EMAIL}${N}"
            _info "Account confirmed — you can log in immediately"
          else
            _warn "Could not create user (HTTP ${HTTP_CODE})"
            _dim "  Response: $(cat /tmp/cb_user_resp.json 2>/dev/null | head -1)"
            _dim "  You can sign up through the app's registration page instead."
            USER_EMAIL=""
          fi
          rm -f /tmp/cb_user_resp.json
        else
          _warn "Supabase service key not found — cannot create user via API"
          _dim "  You can sign up through the app's registration page."
          USER_EMAIL=""
        fi
      fi
    fi
  else
    _info "Skipping user creation"
    if [[ "${DB_RESTORED:-false}" == "true" ]]; then
      _dim "  Use an existing account from the restored database."
    else
      _dim "  Sign up through the application's registration page."
    fi
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # PHASE 13 — VALIDATION & LAUNCH
  # ══════════════════════════════════════════════════════════════════════════
  _head "Phase 13 · Final Validation"
  _nl
  _info "Running final system checks..."
  _nl

  # Checklist
  [[ -d ".venv" ]]                                          && _ok "Python venv       ✓" || _warn "Python venv       — missing"
  [[ -d "frontend/node_modules" ]]                          && _ok "Node modules      ✓" || _warn "Node modules      — missing"
  command -v docker &>/dev/null && docker info &>/dev/null   && _ok "Docker            ✓" || _warn "Docker            — not running"
  [[ -f "frontend/certs/cert.pem" ]]                        && _ok "SSL certificates  ✓" || _warn "SSL certificates  — missing"
  [[ "$HOSTS_OK" == "true" ]] 2>/dev/null                   && _ok "Hosts file        ✓" || _ok "Hosts file        — localhost fallback"
  [[ -f ".env" ]]                                           && _ok ".env              ✓" || _warn ".env              — missing"
  [[ -n "$USER_EMAIL" ]]                                    && _ok "User account      — ${USER_EMAIL}" || _ok "User account      — skipped"

  # ── Live verification — probe the running services ──────────────────────────
  _nl
  _info "Live service probes:"

  _SB_API="${SB_URL:-http://127.0.0.1:${RESTORE_API_PORT:-54321}}"
  _SVC_KEY="$(grep '^SUPABASE_SERVICE_KEY=' .env 2>/dev/null | cut -d= -f2- || echo "")"

  # Supabase API health (returns 401 without apikey — that itself proves it's up)
  if curl -sf -o /dev/null -m 3 "${_SB_API}/auth/v1/settings" -H "apikey: ${_SVC_KEY}"; then
    _ok "Supabase API     — responding"
  elif curl -s -o /dev/null -m 3 "${_SB_API}/" -w '%{http_code}' | grep -qE '^(2|3|4)'; then
    _ok "Supabase API     — reachable (auth required)"
  else
    _warn "Supabase API     — no response at ${_SB_API}"
  fi

  # Storage buckets visible
  _BUCKETS_JSON="$(curl -sf -m 3 "${_SB_API}/storage/v1/bucket" \
    -H "apikey: ${_SVC_KEY}" -H "Authorization: Bearer ${_SVC_KEY}" 2>/dev/null || echo "[]")"
  _BUCKET_COUNT="$(echo "$_BUCKETS_JSON" | jq -r 'length // 0' 2>/dev/null || echo "0")"
  if (( _BUCKET_COUNT > 0 )); then
    _ok "Storage buckets  — ${_BUCKET_COUNT} bucket(s)"
  else
    _warn "Storage buckets  — none (was the dump restored?)"
  fi

  # Public schema row counts — pick a canonical table
  _DB_URL_PROBE="postgresql://postgres:postgres@127.0.0.1:${RESTORE_DB_PORT:-54322}/postgres"
  if command -v psql &>/dev/null; then
    _ROW_COUNT="$(psql "$_DB_URL_PROBE" -tA -c \
      "SELECT (SELECT count(*) FROM pg_tables WHERE schemaname='public')" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$_ROW_COUNT" && "$_ROW_COUNT" -gt 0 ]]; then
      _ok "Public schema    — ${_ROW_COUNT} table(s)"
    else
      _warn "Public schema    — empty"
    fi
  fi

  _nl

  echo -e "  ${G}${BLD}╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "  ${G}${BLD}║            ✅  Installation Complete!                    ║${N}"
  echo -e "  ${G}${BLD}╚══════════════════════════════════════════════════════════╝${N}"
  _nl

  echo -e "  ${BLD}Summary${N}"
  echo -e "    Install path  : ${INSTALL_PATH:-.}"
  echo -e "    Log file      : $(basename "$LOG_FILE")"
  [[ -n "$USER_EMAIL" ]] && echo -e "    User account  : ${USER_EMAIL}"
  _nl

  # Start dev server
  _info "Starting dev environment..."
  _nl
  echo -e "  ${D}=========================================${N}"
  echo -e "  ${D}  CloudBlue Dev Environment${N}"
  echo -e "  ${D}  Frontend: ${UL}https://localhost${N}"
  if [[ "${HOSTS_OK:-false}" == "true" ]]; then
    echo -e "  ${D}  Frontend: ${UL}https://cloudblue.ai${N}"
  fi
  echo -e "  ${D}  Backend:  ${UL}http://127.0.0.1:8000${N}"
  echo -e "  ${D}=========================================${N}"
  _nl

  # URL picker
  echo -e "  ${W}?${N} Which portal would you like to open in your browser?"
  echo ""
  if [[ "${HOSTS_OK:-false}" == "true" ]]; then
    echo -e "      ${BLD}1)${N} Admin portal     — ${UL}https://admin.cloudblue.ai${N}"
    echo -e "         ${D}Manage platform settings, customers, and teams${N}"
    echo ""
    echo -e "      ${BLD}2)${N} ISV portal       — ${UL}https://portal.cloudblue.ai${N}"
    echo -e "         ${D}Manage catalog, SKUs, offers, coupons, and billing${N}"
    echo ""
    echo -e "      ${BLD}3)${N} Customer portal  — ${UL}https://cloudblue.ai${N}"
    echo -e "         ${D}Customer-facing subscription and account management${N}"
  else
    echo -e "      ${BLD}1)${N} Admin portal     — ${UL}https://localhost:${VITE_PORT:-5173}/admin${N}"
    echo -e "         ${D}Manage platform settings, customers, and teams${N}"
    echo ""
    echo -e "      ${BLD}2)${N} ISV portal       — ${UL}https://localhost:${VITE_PORT:-5173}/isv${N}"
    echo -e "         ${D}Manage catalog, SKUs, offers, coupons, and billing${N}"
    echo ""
    echo -e "      ${BLD}3)${N} Customer portal  — ${UL}https://localhost:${VITE_PORT:-5173}/platform${N}"
    echo -e "         ${D}Customer-facing subscription and account management${N}"
  fi
  echo ""
  echo -e "      ${BLD}4)${N} Supabase Studio  — ${UL}http://127.0.0.1:54323${N}"
  echo -e "         ${D}Database admin, auth users, storage, and logs${N}"
  echo ""
  echo -e "      ${BLD}5)${N} Don't open       — ${D}I'll open it myself${N}"
  echo ""
  _ask "Selection [1]: "
  read -r _url_choice
  _url_choice=${_url_choice:-1}
  _nl

  if [[ "${HOSTS_OK:-false}" == "true" ]]; then
    case "$_url_choice" in
      1) OPEN_URL="https://admin.cloudblue.ai" ;;
      2) OPEN_URL="https://portal.cloudblue.ai" ;;
      3) OPEN_URL="https://cloudblue.ai" ;;
      4) OPEN_URL="http://127.0.0.1:54323" ;;
      *) OPEN_URL="" ;;
    esac
  else
    case "$_url_choice" in
      1) OPEN_URL="https://localhost:${VITE_PORT:-5173}/admin" ;;
      2) OPEN_URL="https://localhost:${VITE_PORT:-5173}/isv" ;;
      3) OPEN_URL="https://localhost:${VITE_PORT:-5173}/platform" ;;
      4) OPEN_URL="http://127.0.0.1:54323" ;;
      *) OPEN_URL="" ;;
    esac
  fi

  # Launch dev.sh (in background so we can open browser)
  if [[ -f "${INSTALL_PATH:-$(pwd)}/dev.sh" ]]; then
    cd "${INSTALL_PATH:-$(pwd)}"
    # Open browser after a short delay to let services start
    if [[ -n "$OPEN_URL" ]]; then
      ( sleep 5 && _open_url "$OPEN_URL" ) &
    fi
    exec bash dev.sh
  else
    _warn "dev.sh not found — start manually with: cd ${INSTALL_PATH} && ./dev.sh"
    [[ -n "${OPEN_URL:-}" ]] && _open_url "$OPEN_URL"
  fi

  exit 0
fi
# ══════════════════════════════════════════════════════════════════════════════
# ── END OF INSTALL / RETRY MODE ──────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

fi # end outer INSTALL_MODE || RETRY_MODE guard

# ══════════════════════════════════════════════════════════════════════════════
# ── --test-restore MODE ──────────────────────────────────────────────────────
# Sandboxed backup → restore loop on the current machine. Uses a different
# Supabase project_id and shifted ports so the live 'taylor' stack is untouched.
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$TEST_RESTORE_MODE" == "true" ]]; then
  TS="${STAMP}"
  SANDBOX="/tmp/cbnext-test-${TS}"
  TEST_PROJECT_ID="${PROJECT_ID}_test"
  # Shift all ports +1000 so we don't collide with the live stack.
  T_API_PORT=$((54321 + 1000))      # 55321
  T_DB_PORT=$((54322 + 1000))       # 55322
  T_STUDIO_PORT=$((54323 + 1000))   # 55323
  T_INBUCKET_PORT=$((54324 + 1000)) # 55324
  T_SHADOW_PORT=$((54320 + 1000))   # 55320
  T_ANALYTICS_PORT=$((54327 + 1000)) # 55327
  T_POOLER_PORT=$((54329 + 1000))   # 55329

  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║       CB-Next Backup/Restore Test — sandbox      ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo "  Sandbox       : ${SANDBOX}"
  echo "  Test project  : ${TEST_PROJECT_ID}"
  echo "  Ports         : api ${T_API_PORT} / db ${T_DB_PORT} / studio ${T_STUDIO_PORT}"
  echo "  Keep on exit  : ${TEST_KEEP}"
  echo ""

  # ── Defensive cleanup of any leftover test volumes from a prior crashed run
  for v in "supabase_db_${TEST_PROJECT_ID}" "supabase_storage_${TEST_PROJECT_ID}" "supabase_config_${TEST_PROJECT_ID}"; do
    if docker volume inspect "$v" &>/dev/null; then
      echo "  → removing leftover volume: $v"
      docker volume rm -f "$v" &>/dev/null || true
    fi
  done

  mkdir -p "${SANDBOX}/archive" "${SANDBOX}/restore"

  # ── Get an archive (either user-provided or a fresh backup) ────────────────
  if [[ -n "$TEST_ARCHIVE" && -f "$TEST_ARCHIVE" ]]; then
    echo "→ Using existing archive: $TEST_ARCHIVE"
    cp "$TEST_ARCHIVE" "${SANDBOX}/archive/"
    ARCHIVE_FILE="${SANDBOX}/archive/$(basename "$TEST_ARCHIVE")"
  else
    echo "→ Creating a fresh backup first..."
    bash "$0" 2>&1 | tail -5
    ARCHIVE_FILE="$(ls -1t "${SCRIPT_DIR}/cb-next-full_"*.tar.gz 2>/dev/null | head -1)"
    if [[ -z "$ARCHIVE_FILE" ]]; then
      echo "✗ No archive produced by backup — aborting"
      exit 1
    fi
    echo "  archive: $ARCHIVE_FILE"
  fi

  # ── Extract into sandbox ──────────────────────────────────────────────────
  echo "→ Extracting bundle to ${SANDBOX}/restore/"
  tar xzf "$ARCHIVE_FILE" -C "${SANDBOX}/restore"

  # Find inner components
  T_MANIFEST=""; T_SQL=""; T_STORAGE=""; T_REDIS=""; T_CODE=""; T_ENV=""; T_TOML=""
  for f in "${SANDBOX}/restore"/*; do
    case "$(basename "$f")" in
      *-MANIFEST.json)           T_MANIFEST="$f" ;;
      *-cbnext.sql)              T_SQL="$f" ;;
      *-cbnext-storage.tar.gz)   T_STORAGE="$f" ;;
      *-cbnext-redis.tar.gz)     T_REDIS="$f" ;;
      *-cbnext-code.tar.gz)      T_CODE="$f" ;;
      *-cbnext.env)              T_ENV="$f" ;;
      *-supabase-config.toml)    T_TOML="$f" ;;
    esac
  done
  echo "  manifest: $(basename "${T_MANIFEST:-(none)}")"
  echo "  sql     : $(basename "${T_SQL:-(none)}")"
  echo "  storage : $(basename "${T_STORAGE:-(none)}")"
  echo "  code    : $(basename "${T_CODE:-(none)}")"

  # ── Extract code (just so we get supabase/migrations/ + seed.sql for fallback)
  CODE_DIR="${SANDBOX}/restore/code"
  mkdir -p "$CODE_DIR"
  if [[ -n "$T_CODE" ]]; then
    tar xzf "$T_CODE" -C "$CODE_DIR" --strip-components=1
  fi
  # Replace the bundled config.toml with a port-shifted, renamed version
  if [[ -n "$T_TOML" ]]; then
    mkdir -p "${CODE_DIR}/supabase"
    cp "$T_TOML" "${CODE_DIR}/supabase/config.toml"
  fi

  # ── Rewrite config.toml: project_id + every port ──────────────────────────
  TOML="${CODE_DIR}/supabase/config.toml"
  if [[ -f "$TOML" ]]; then
    sed -i.bak \
      -e "s/^project_id *= *\".*\"/project_id = \"${TEST_PROJECT_ID}\"/" \
      -e "s/^port *= *54321/port = ${T_API_PORT}/" \
      -e "s/^port *= *54322/port = ${T_DB_PORT}/" \
      -e "s/^port *= *54323/port = ${T_STUDIO_PORT}/" \
      -e "s/^port *= *54324/port = ${T_INBUCKET_PORT}/" \
      -e "s/^port *= *54327/port = ${T_ANALYTICS_PORT}/" \
      -e "s/^port *= *54329/port = ${T_POOLER_PORT}/" \
      -e "s/^shadow_port *= *54320/shadow_port = ${T_SHADOW_PORT}/" \
      "$TOML"
    rm -f "${TOML}.bak"
    echo "→ Rewrote config.toml → project_id=${TEST_PROJECT_ID}, api=${T_API_PORT}, db=${T_DB_PORT}"
  fi

  # ── Rewrite .env to point at shifted ports ────────────────────────────────
  if [[ -n "$T_ENV" ]]; then
    cp "$T_ENV" "${CODE_DIR}/.env"
    sed -i.bak \
      -e "s|http://127.0.0.1:54321|http://127.0.0.1:${T_API_PORT}|g" \
      -e "s|http://localhost:54321|http://localhost:${T_API_PORT}|g" \
      -e "s|127.0.0.1:54322|127.0.0.1:${T_DB_PORT}|g" \
      -e "s|localhost:54322|localhost:${T_DB_PORT}|g" \
      "${CODE_DIR}/.env"
    rm -f "${CODE_DIR}/.env.bak"
    echo "→ Rewrote .env → SUPABASE_URL on ${T_API_PORT}, DATABASE_URL on ${T_DB_PORT}"
  fi

  # ── Boot the sandbox Supabase stack ───────────────────────────────────────
  echo "→ Starting sandbox Supabase stack (this can take a minute)..."
  if ! (cd "$CODE_DIR" && npx -y supabase start 2>&1 | tail -10); then
    echo "✗ supabase start failed — aborting test"
    [[ "$TEST_KEEP" == "true" ]] || rm -rf "$SANDBOX"
    exit 1
  fi
  echo "✓ Sandbox Supabase started"

  # Sync JWT keys from the sandbox stack into the sandbox .env so storage
  # uploads (and our verification probes) actually authenticate.
  SB_STATUS="$(cd "$CODE_DIR" && npx -y supabase status 2>/dev/null || true)"
  SB_ANON="$(echo "$SB_STATUS"  | grep -iE 'Publishable|anon' | head -1 | awk -F'│' '{print $3}' | xargs 2>/dev/null || true)"
  SB_SVC="$(echo "$SB_STATUS"   | grep -iE '^│.*Secret '       | head -1 | awk -F'│' '{print $3}' | xargs 2>/dev/null || true)"
  if [[ -n "$SB_ANON" ]]; then
    sed -i.bak "s|^SUPABASE_ANON_KEY=.*|SUPABASE_ANON_KEY=${SB_ANON}|;s|^VITE_SUPABASE_ANON_KEY=.*|VITE_SUPABASE_ANON_KEY=${SB_ANON}|" "${CODE_DIR}/.env"
  fi
  if [[ -n "$SB_SVC" ]]; then
    sed -i.bak "s|^SUPABASE_SERVICE_KEY=.*|SUPABASE_SERVICE_KEY=${SB_SVC}|" "${CODE_DIR}/.env"
  fi
  rm -f "${CODE_DIR}/.env.bak"

  T_DB_URL="postgresql://postgres:postgres@127.0.0.1:${T_DB_PORT}/postgres"
  T_API_URL="http://127.0.0.1:${T_API_PORT}"

  # ── Restore the database into the sandbox ─────────────────────────────────
  if [[ -n "$T_SQL" ]]; then
    echo "→ Restoring database into sandbox..."
    psql "$T_DB_URL" -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO postgres; GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role; GRANT CREATE ON SCHEMA public TO postgres;" > /dev/null 2>&1
    psql "$T_DB_URL" -v ON_ERROR_STOP=0 -f "$T_SQL" > "${SANDBOX}/psql-restore.log" 2>&1 || true
    PUB_TABLES="$(psql "$T_DB_URL" -tA -c "SELECT count(*) FROM pg_tables WHERE schemaname='public'" 2>/dev/null | tr -d '[:space:]')"
    echo "  public tables restored: ${PUB_TABLES:-0}"
  fi

  # ── Restore storage into the sandbox via the API ──────────────────────────
  if [[ -n "$T_STORAGE" && -n "$SB_SVC" ]]; then
    echo "→ Restoring storage into sandbox..."
    STMP="$(mktemp -d)"
    tar xzf "$T_STORAGE" -C "$STMP" 2>/dev/null || true
    STR_ROOT="$STMP/stub"; [[ -d "$STMP/stub/stub" ]] && STR_ROOT="$STMP/stub/stub"
    UPLOADED=0
    for bdir in "$STR_ROOT"/*/; do
      [[ -d "$bdir" ]] || continue
      bucket="$(basename "$bdir")"
      curl -s -o /dev/null -X POST "${T_API_URL}/storage/v1/bucket" \
        -H "apikey: ${SB_SVC}" -H "Authorization: Bearer ${SB_SVC}" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"${bucket}\",\"name\":\"${bucket}\",\"public\":true}" 2>/dev/null || true
      while IFS= read -r fpath; do
        relpath="${fpath#${bdir}}"; obj_path="${relpath%/*}"
        curl -s -o /dev/null -X POST "${T_API_URL}/storage/v1/object/${bucket}/${obj_path}" \
          -H "apikey: ${SB_SVC}" -H "Authorization: Bearer ${SB_SVC}" \
          -H "x-upsert: true" --data-binary "@${fpath}" 2>/dev/null || true
        UPLOADED=$((UPLOADED + 1))
      done < <(find "$bdir" -type f)
    done
    rm -rf "$STMP"
    echo "  uploaded: ${UPLOADED} file(s)"
  fi

  # ── Verification ───────────────────────────────────────────────────────────
  echo ""
  echo "── Verification ──────────────────────────────────────────"
  PASS=0; FAIL=0
  _check() {
    local name="$1"; shift
    if "$@"; then printf "  ✓ %s\n" "$name"; PASS=$((PASS+1))
    else          printf "  ✗ %s\n" "$name"; FAIL=$((FAIL+1)); fi
  }
  _check "Sandbox Supabase API reachable"     curl -sfo /dev/null -m 3 -H "apikey: ${SB_SVC}" "${T_API_URL}/auth/v1/settings"
  _check "Sandbox Supabase DB queryable"      bash -c "psql '$T_DB_URL' -tAc 'SELECT 1' >/dev/null 2>&1"
  _check "Public schema populated"            bash -c "[[ \$(psql '$T_DB_URL' -tAc \"SELECT count(*) FROM pg_tables WHERE schemaname='public'\" | tr -d '[:space:]') -gt 0 ]]"
  _check "Studio responds"                    curl -sfo /dev/null -m 3 "http://127.0.0.1:${T_STUDIO_PORT}"
  _check "Storage buckets present"            bash -c "[[ \$(curl -sf -m 3 '${T_API_URL}/storage/v1/bucket' -H 'apikey: ${SB_SVC}' -H 'Authorization: Bearer ${SB_SVC}' | jq -r 'length // 0') -gt 0 ]]"
  _check "Live 'taylor' stack untouched"      bash -c "docker volume inspect 'supabase_db_${PROJECT_ID}' >/dev/null 2>&1"

  echo ""
  if (( FAIL == 0 )); then
    echo "╔══════════════════════════════════════════════════╗"
    echo "║      ✅  TEST RESTORE: PASS (${PASS}/${PASS} checks)         ║"
    echo "╚══════════════════════════════════════════════════╝"
    RC=0
  else
    echo "╔══════════════════════════════════════════════════╗"
    echo "║      ❌  TEST RESTORE: FAIL (${FAIL}/$((PASS+FAIL)) failures)        ║"
    echo "╚══════════════════════════════════════════════════╝"
    RC=1
  fi

  # ── Teardown ───────────────────────────────────────────────────────────────
  if [[ "$TEST_KEEP" == "true" ]]; then
    echo ""
    echo "  --keep set — leaving sandbox in place:"
    echo "    ${SANDBOX}"
    echo "  Tear down later with:"
    echo "    (cd ${CODE_DIR} && npx -y supabase stop)"
    echo "    docker volume rm -f supabase_db_${TEST_PROJECT_ID} supabase_storage_${TEST_PROJECT_ID}"
    echo "    rm -rf ${SANDBOX}"
  else
    echo ""
    echo "→ Tearing down sandbox..."
    (cd "$CODE_DIR" && npx -y supabase stop --no-backup 2>&1 | tail -3) || true
    for v in "supabase_db_${TEST_PROJECT_ID}" "supabase_storage_${TEST_PROJECT_ID}" "supabase_config_${TEST_PROJECT_ID}"; do
      docker volume rm -f "$v" &>/dev/null || true
    done
    rm -rf "$SANDBOX"
    echo "✓ Sandbox removed"
  fi
  exit $RC
fi

# ── Interactive component selection (-o mode) ──────────────────────────────────
# Available components and their labels
COMPONENT_KEYS=(database config storage code)
COMPONENT_LABELS=(
  "Database      — Postgres full SQL dump"
  "Config        — .env, supabase/config.toml, and .env.* files"
  "Storage       — Supabase Storage Docker volume"
  "Code          — Source code snapshot (excludes node_modules, .git, backup/)"
)

# Which components are selected (defaults: all enabled)
SEL_DATABASE=true
SEL_CONFIG=true
SEL_STORAGE=true
SEL_CODE=true

if [[ "$OPTIONS_MODE" == "true" ]]; then
  echo ""
  echo "┌─────────────────────────────────────────────────────────┐"
  echo "│           CB-Next Backup — Select Components            │"
  echo "└─────────────────────────────────────────────────────────┘"
  echo ""
  echo "  Enter the numbers of the components to back up,"
  echo "  separated by spaces (e.g. 1 3), or press Enter for all."
  echo ""
  for i in "${!COMPONENT_KEYS[@]}"; do
    printf "  [%d] %s\n" "$(( i + 1 ))" "${COMPONENT_LABELS[$i]}"
  done
  echo ""
  read -r -p "  Selection [all]: " raw_selection

  if [[ -n "$raw_selection" ]]; then
    # Disable all first, then re-enable chosen ones
    SEL_DATABASE=false; SEL_CONFIG=false; SEL_STORAGE=false; SEL_CODE=false
    for tok in $raw_selection; do
      case "$tok" in
        1) SEL_DATABASE=true ;;
        2) SEL_CONFIG=true ;;
        3) SEL_STORAGE=true ;;
        4) SEL_CODE=true ;;
        *) echo "  ⚠  Unknown option '$tok' — ignored" ;;
      esac
    done
  fi

  echo ""
  echo "  Selected components:"
  [[ "$SEL_DATABASE" == "true" ]] && echo "    ✓ Database"
  [[ "$SEL_CONFIG"   == "true" ]] && echo "    ✓ Config"
  [[ "$SEL_STORAGE"  == "true" ]] && echo "    ✓ Storage"
  [[ "$SEL_CODE"     == "true" ]] && echo "    ✓ Code"
  echo ""
fi

# Apply legacy flags on top of selection
[[ "$SKIP_CODE" == "true" ]] && SEL_CODE=false
[[ "$DB_ONLY"   == "true" ]] && { SEL_STORAGE=false; SEL_CODE=false; }

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo "  → $*"; }
success() { echo "  ✓ $*"; }
warn()    { echo "  ⚠  $*"; }
header()  { echo ""; echo "━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║         CB-Next Full Backup — ${STAMP}    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Project root : ${PROJECT_ROOT}"
echo "  Backup dir   : ${SCRIPT_DIR}"
echo "  Timestamp    : ${STAMP}"
echo "  Project ID   : ${PROJECT_ID}"
echo "  Storage vol  : ${STORAGE_VOLUME}"

# ── Pre-flight checks ────────────────────────────────────────────────────────
header "0. Pre-flight checks"
_preflight_ok=true

# pg_dump available and DB reachable (only matters if we're dumping the DB)
if [[ "$SEL_DATABASE" == "true" ]]; then
  if ! command -v pg_dump &>/dev/null; then
    warn "pg_dump not on PATH — install libpq (brew install libpq) and re-try"
    _preflight_ok=false
  elif ! psql "$DB_URL" -tA -c 'SELECT 1' &>/dev/null; then
    warn "Cannot connect to ${DB_URL%/*}/… — is Supabase running? (npx supabase status)"
    _preflight_ok=false
  else
    success "Database reachable"
  fi
fi

# Storage volume exists (warn-only — backup will skip if missing)
if [[ "$SEL_STORAGE" == "true" ]]; then
  if docker volume inspect "$STORAGE_VOLUME" &>/dev/null; then
    success "Docker volume ${STORAGE_VOLUME} present"
  else
    warn "Docker volume ${STORAGE_VOLUME} not found — storage backup will be skipped"
  fi
fi

# Disk space: at least 2 GB free in SCRIPT_DIR
_free_kb="$(df -k "$SCRIPT_DIR" | awk 'NR==2 {print $4}')"
if [[ -n "$_free_kb" ]] && (( _free_kb < 2 * 1024 * 1024 )); then
  warn "Less than 2 GB free in ${SCRIPT_DIR} — backup may fail"
else
  success "Disk space OK ($(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $4}') free)"
fi

if [[ "$_preflight_ok" != "true" ]]; then
  echo ""
  warn "Pre-flight checks failed. Fix the issues above and re-run."
  exit 1
fi

# ── 1. Database dump ──────────────────────────────────────────────────────────
if [[ "$SEL_DATABASE" == "true" ]]; then
  header "1. Database"
  if [[ "$OPTIONS_MODE" == "true" ]]; then
    # -o mode: write directly to a named individual archive
    DB_TMP="${SCRIPT_DIR}/${STAMP}-cbnext.sql"
    DB_OUT="${SCRIPT_DIR}/cb-next-database_${STAMP}.tar.gz"
    info "Dumping public schema to temporary SQL file..."
    pg_dump "$DB_URL" --schema=public --no-owner --no-acl -f "$DB_TMP"
    # Append storage metadata (buckets + objects) with elevated role
    info "Appending storage metadata..."
    {
      echo ""
      echo "-- CB-NEXT: Storage metadata (requires supabase_storage_admin role)"
      echo "SET ROLE supabase_storage_admin;"
      echo "ALTER TABLE storage.objects DISABLE TRIGGER ALL;"
      echo "ALTER TABLE storage.buckets DISABLE TRIGGER ALL;"
      echo "TRUNCATE storage.objects CASCADE;"
      echo "TRUNCATE storage.buckets CASCADE;"
      pg_dump "$DB_URL" --table=storage.buckets --table=storage.objects --data-only --no-owner --no-acl 2>/dev/null || true
      echo "ALTER TABLE storage.buckets ENABLE TRIGGER ALL;"
      echo "ALTER TABLE storage.objects ENABLE TRIGGER ALL;"
      echo "RESET ROLE;"
      echo ""
      echo "-- CB-NEXT: Auth schema row data (identities, mfa_factors)"
      pg_dump "$DB_URL" \
        --table=auth.users \
        --table=auth.identities \
        --table=auth.mfa_factors \
        --table=auth.sessions \
        --data-only --no-owner --no-acl 2>/dev/null || true
    } >> "$DB_TMP"
    ( cd "$SCRIPT_DIR"; tar czf "$(basename "$DB_OUT")" "$(basename "$DB_TMP")" )
    rm -f "$DB_TMP"
    SIZE=$(du -sh "$DB_OUT" | awk '{print $1}')
    success "Database backup: $(basename "$DB_OUT") [${SIZE}]"
  else
    SQL_FILE="${SCRIPT_DIR}/${STAMP}-cbnext.sql"
    info "Dumping public schema to: $(basename "$SQL_FILE")"
    pg_dump "$DB_URL" --schema=public --no-owner --no-acl -f "$SQL_FILE"
    # Append storage metadata (buckets + objects) with elevated role
    info "Appending storage metadata..."
    {
      echo ""
      echo "-- CB-NEXT: Storage metadata (requires supabase_storage_admin role)"
      echo "SET ROLE supabase_storage_admin;"
      echo "ALTER TABLE storage.objects DISABLE TRIGGER ALL;"
      echo "ALTER TABLE storage.buckets DISABLE TRIGGER ALL;"
      echo "TRUNCATE storage.objects CASCADE;"
      echo "TRUNCATE storage.buckets CASCADE;"
      pg_dump "$DB_URL" --table=storage.buckets --table=storage.objects --data-only --no-owner --no-acl 2>/dev/null || true
      echo "ALTER TABLE storage.buckets ENABLE TRIGGER ALL;"
      echo "ALTER TABLE storage.objects ENABLE TRIGGER ALL;"
      echo "RESET ROLE;"
    } >> "$SQL_FILE"
    # Append auth rows (identities, mfa_factors, sso state). Users still come back
    # via the Admin API on restore so the GoTrue invariants hold — but identities
    # preserve OAuth linking for restored users.
    info "Appending auth schema data..."
    {
      echo ""
      echo "-- CB-NEXT: Auth schema row data (identities, mfa_factors)"
      pg_dump "$DB_URL" \
        --table=auth.users \
        --table=auth.identities \
        --table=auth.mfa_factors \
        --table=auth.sessions \
        --data-only --no-owner --no-acl 2>/dev/null || true
    } >> "$SQL_FILE"
    SIZE=$(du -sh "$SQL_FILE" | awk '{print $1}')
    success "Database backup complete: $(basename "$SQL_FILE") [${SIZE}]"
  fi
else
  header "1. Database"
  info "Skipped (not selected)"
fi

# ── 2. Config files ───────────────────────────────────────────────────────────
if [[ "$SEL_CONFIG" == "true" ]]; then
  header "2. Config Files"
  CONFIG_TMP_FILES=()

  if [[ -f "$ENV_FILE" ]]; then
    ENV_DEST="${SCRIPT_DIR}/${STAMP}-cbnext.env"
    info "Copying .env → $(basename "$ENV_DEST")"
    cp "$ENV_FILE" "$ENV_DEST"
    CONFIG_TMP_FILES+=("$ENV_DEST")
    success ".env backed up"
  else
    warn ".env not found at ${ENV_FILE} — skipping"
  fi

  if [[ -f "$SUPABASE_CONFIG" ]]; then
    TOML_DEST="${SCRIPT_DIR}/${STAMP}-supabase-config.toml"
    info "Copying supabase/config.toml → $(basename "$TOML_DEST")"
    cp "$SUPABASE_CONFIG" "$TOML_DEST"
    CONFIG_TMP_FILES+=("$TOML_DEST")
    success "Supabase config backed up"
  else
    warn "supabase/config.toml not found at ${SUPABASE_CONFIG} — skipping"
  fi

  for extra_env in "${PROJECT_ROOT}"/.env.*; do
    if [[ -f "$extra_env" ]]; then
      base="$(basename "$extra_env")"
      extra_dest="${SCRIPT_DIR}/${STAMP}-${base}"
      info "Copying ${base} → $(basename "$extra_dest")"
      cp "$extra_env" "$extra_dest"
      CONFIG_TMP_FILES+=("$extra_dest")
      success "Extra config backed up: $(basename "$extra_dest")"
    fi
  done

  if [[ "$OPTIONS_MODE" == "true" && ${#CONFIG_TMP_FILES[@]} -gt 0 ]]; then
    CFG_OUT="${SCRIPT_DIR}/cb-next-config_${STAMP}.tar.gz"
    ( cd "$SCRIPT_DIR"; tar czf "$(basename "$CFG_OUT")" "${CONFIG_TMP_FILES[@]##*/}" )
    for f in "${CONFIG_TMP_FILES[@]}"; do rm -f "$f"; done
    SIZE=$(du -sh "$CFG_OUT" | awk '{print $1}')
    success "Config archive: $(basename "$CFG_OUT") [${SIZE}]"
  fi
else
  header "2. Config Files"
  info "Skipped (not selected)"
fi

# ── 3. Supabase Storage volume (S3-compatible object store) ───────────────────
if [[ "$SEL_STORAGE" == "true" ]]; then
  header "3. Supabase Storage (S3)"
  if [[ "$OPTIONS_MODE" == "true" ]]; then
    STORAGE_FILE="${SCRIPT_DIR}/cb-next-storage_${STAMP}.tar.gz"
  else
    STORAGE_FILE="${SCRIPT_DIR}/${STAMP}-cbnext-storage.tar.gz"
  fi
  info "Checking Docker volume: ${STORAGE_VOLUME}"

  if ! docker volume inspect "$STORAGE_VOLUME" &>/dev/null; then
    warn "Volume '${STORAGE_VOLUME}' not found — skipping storage backup."
    warn "If using a different volume name, set: STORAGE_VOLUME=<name>"
  else
    info "Compressing volume contents → $(basename "$STORAGE_FILE")"
    docker run --rm \
      -v "${STORAGE_VOLUME}:/mnt:ro" \
      -v "${SCRIPT_DIR}:/backup" \
      alpine \
      tar czf "/backup/$(basename "$STORAGE_FILE")" -C /mnt .
    STORAGE_SIZE=$(du -sh "$STORAGE_FILE" | awk '{print $1}')
    success "Storage backup complete: $(basename "$STORAGE_FILE") [${STORAGE_SIZE}]"
  fi
else
  header "3. Supabase Storage (S3)"
  info "Skipped (not selected)"
fi

# ── 3b. Redis snapshot (best-effort — only if volume exists) ─────────────────
if [[ "$SEL_STORAGE" == "true" ]]; then
  header "3b. Redis snapshot"
  if docker volume inspect "$REDIS_VOLUME" &>/dev/null; then
    if [[ "$OPTIONS_MODE" == "true" ]]; then
      REDIS_FILE="${SCRIPT_DIR}/cb-next-redis_${STAMP}.tar.gz"
    else
      REDIS_FILE="${SCRIPT_DIR}/${STAMP}-cbnext-redis.tar.gz"
    fi
    info "Compressing Redis volume → $(basename "$REDIS_FILE")"
    docker run --rm \
      -v "${REDIS_VOLUME}:/mnt:ro" \
      -v "${SCRIPT_DIR}:/backup" \
      alpine \
      tar czf "/backup/$(basename "$REDIS_FILE")" -C /mnt . 2>/dev/null || true
    if [[ -f "$REDIS_FILE" ]]; then
      REDIS_SIZE=$(du -sh "$REDIS_FILE" | awk '{print $1}')
      success "Redis snapshot complete: $(basename "$REDIS_FILE") [${REDIS_SIZE}]"
    else
      info "Redis snapshot empty or skipped"
    fi
  else
    info "Volume ${REDIS_VOLUME} not present — skipping Redis snapshot"
  fi
fi

# ── 4. Source code snapshot ───────────────────────────────────────────────────
if [[ "$SEL_CODE" == "true" ]]; then
  header "4. Source Code"
  if [[ "$OPTIONS_MODE" == "true" ]]; then
    CODE_FILE="${SCRIPT_DIR}/cb-next-code_${STAMP}.tar.gz"
  else
    CODE_FILE="${SCRIPT_DIR}/${STAMP}-cbnext-code.tar.gz"
  fi
  info "Archiving project to: $(basename "$CODE_FILE")"

  PROJ_BASE="$(basename "$PROJECT_ROOT")"
  tar czf "$CODE_FILE" \
    --exclude="${PROJ_BASE}/.git" \
    --exclude="${PROJ_BASE}/.venv" \
    --exclude="${PROJ_BASE}/node_modules" \
    --exclude="${PROJ_BASE}/frontend/node_modules" \
    --exclude="${PROJ_BASE}/frontend/dist" \
    --exclude="${PROJ_BASE}/frontend/.vite" \
    --exclude="${PROJ_BASE}/__pycache__" \
    --exclude="${PROJ_BASE}/.mypy_cache" \
    --exclude="${PROJ_BASE}/.pytest_cache" \
    --exclude="${PROJ_BASE}/backup" \
    -C "$(dirname "$PROJECT_ROOT")" \
    "${PROJ_BASE}"

  CODE_SIZE=$(du -sh "$CODE_FILE" | awk '{print $1}')
  success "Code snapshot complete: $(basename "$CODE_FILE") [${CODE_SIZE}]"
else
  header "4. Source Code"
  info "Skipped (not selected)"
fi

# ── 4b. Manifest ──────────────────────────────────────────────────────────────
header "4b. Writing MANIFEST.json"
MANIFEST_FILE="${SCRIPT_DIR}/${STAMP}-MANIFEST.json"
_manifest_args=()
[[ -f "${SCRIPT_DIR}/${STAMP}-cbnext.sql" ]]             && _manifest_args+=("database=${SCRIPT_DIR}/${STAMP}-cbnext.sql")
[[ -f "${SCRIPT_DIR}/${STAMP}-cbnext.env" ]]             && _manifest_args+=("env=${SCRIPT_DIR}/${STAMP}-cbnext.env")
[[ -f "${SCRIPT_DIR}/${STAMP}-supabase-config.toml" ]]   && _manifest_args+=("supabase_config=${SCRIPT_DIR}/${STAMP}-supabase-config.toml")
[[ -f "${SCRIPT_DIR}/${STAMP}-cbnext-storage.tar.gz" ]]  && _manifest_args+=("storage=${SCRIPT_DIR}/${STAMP}-cbnext-storage.tar.gz")
[[ -f "${SCRIPT_DIR}/${STAMP}-cbnext-redis.tar.gz" ]]    && _manifest_args+=("redis=${SCRIPT_DIR}/${STAMP}-cbnext-redis.tar.gz")
[[ -f "${SCRIPT_DIR}/${STAMP}-cbnext-code.tar.gz" ]]     && _manifest_args+=("code=${SCRIPT_DIR}/${STAMP}-cbnext-code.tar.gz")
_write_manifest "$MANIFEST_FILE" "${_manifest_args[@]}"
success "Manifest written: $(basename "$MANIFEST_FILE")"

# ── 5. Bundle (default mode only) ─────────────────────────────────────────────
BUNDLE_FILE=""
if [[ "$OPTIONS_MODE" == "false" ]]; then
  header "5. Bundling into single archive"

  BUNDLE_FILE="${SCRIPT_DIR}/cb-next-full_${STAMP}.tar.gz"
  info "Creating bundle: $(basename "$BUNDLE_FILE")"

  INDIVIDUAL_FILES=()
  for f in "${SCRIPT_DIR}/${STAMP}"-*; do
    [[ -f "$f" ]] && INDIVIDUAL_FILES+=("$f")
  done

  if [[ ${#INDIVIDUAL_FILES[@]} -eq 0 ]]; then
    warn "No files to bundle — skipping."
    BUNDLE_FILE=""
  else
    ( cd "$SCRIPT_DIR"; tar czf "$(basename "$BUNDLE_FILE")" "${INDIVIDUAL_FILES[@]##*/}" )
    BUNDLE_SIZE=$(du -sh "$BUNDLE_FILE" | awk '{print $1}')
    success "Bundle complete: $(basename "$BUNDLE_FILE") [${BUNDLE_SIZE}]"
    info "Removing individual component files..."
    for f in "${INDIVIDUAL_FILES[@]}"; do
      rm -f "$f"
      info "  Removed: $(basename "$f")"
    done
  fi
fi

# ── 6. Prune old backups ──────────────────────────────────────────────────────
header "6. Pruning Old Backups (keeping last ${KEEP_BACKUPS})"

prune_type() {
  local pattern="$1"
  local label="$2"
  local files=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && files+=("$line")
  done < <(ls -1t "${SCRIPT_DIR}"/${pattern} 2>/dev/null)
  local count=${#files[@]}
  if (( count > KEEP_BACKUPS )); then
    local to_delete=$(( count - KEEP_BACKUPS ))
    info "Removing ${to_delete} old ${label} backup(s)..."
    for (( i=KEEP_BACKUPS; i<count; i++ )); do
      rm -f "${files[$i]}"
      info "  Deleted: $(basename "${files[$i]}")"
    done
  else
    info "${label}: ${count} backup(s) found — nothing to prune"
  fi
}

prune_type "cb-next-full_*.tar.gz"     "Full bundle"
prune_type "cb-next-database_*.tar.gz" "Database"
prune_type "cb-next-config_*.tar.gz"   "Config"
prune_type "cb-next-storage_*.tar.gz"  "Storage"
prune_type "cb-next-code_*.tar.gz"     "Code"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║                  ✅  Backup Complete              ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Timestamp : ${STAMP}"
echo "  Mode      : $([ "$OPTIONS_MODE" == "true" ] && echo "Individual (-o)" || echo "Full bundle")"
echo "  Output    :"
for f in "${SCRIPT_DIR}/cb-next-"*"_${STAMP}.tar.gz"; do
  if [[ -f "$f" ]]; then
    SIZE=$(du -sh "$f" | awk '{print $1}')
    printf "    %-52s %s\n" "$(basename "$f")" "[${SIZE}]"
  fi
done
echo ""

