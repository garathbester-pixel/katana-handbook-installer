#!/bin/bash
# Katana Handbook Sync
# Fetches Katana team instructions from a private GitHub repo and injects
# them as context into every Claude Code session.
#
# Security properties:
#   - PAT stored in macOS Keychain, never in env vars or shell config
#   - Pinned to GitHub Releases (not main branch) — a compromised push to
#     main does NOT reach users until you explicitly publish a new Release
#   - Cached locally — re-fetches only when a new Release is published
#   - Fails gracefully — session always continues using last cached instructions
#   - Full timestamped logging to ~/.claude/handbook-sync.log
#
# One-time setup per Mac:
#   1. Get the token from Dashlane (item: katana-handbook-pat)
#   2. security add-generic-password -s "katana-handbook" -a "github-pat" -w "PASTE_TOKEN_HERE"
#
# Useful commands:
#   cat ~/.claude/handbook-version                              — check current version
#   cat ~/.claude/handbook-sync.log                            — view sync history
#   rm ~/.claude/handbook-cache.json ~/.claude/handbook-version — force re-fetch next session

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
REPO="${KATANA_HANDBOOK_REPO:-katana-scm/katana-handbook}"
LOG_FILE="$HOME/.claude/handbook-sync.log"
CACHE_FILE="$HOME/.claude/handbook-cache.json"
VERSION_FILE="$HOME/.claude/handbook-version"
SETUP_FLAG="$HOME/.claude/analytics-setup-done"
KEYCHAIN_SERVICE="katana-handbook"
KEYCHAIN_ACCOUNT="github-pat"
GITHUB_API="https://api.github.com/repos/${REPO}"
CURL_OPTS=(--max-time 10 --retry 2 --retry-delay 2 --silent --fail)

# ── Logging ──────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >> "$LOG_FILE"; }

# Rotate log — keep last 500 lines
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

log INFO "Session start. Repo: ${REPO}"

# ── First-run analytics setup (runs once per Mac) ────────────────────────────
run_first_time_setup() {
    log INFO "First-run setup: installing analytics tools..."

    # Homebrew
    if ! command -v brew &>/dev/null; then
        log INFO "  Installing Homebrew..."
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
            </dev/null >> "$LOG_FILE" 2>&1 \
            && log INFO "  Homebrew installed." \
            || log WARN "  Homebrew install failed — skipping brew-dependent tools."
    else
        log INFO "  Homebrew: already installed."
    fi

    # GitHub CLI
    if ! command -v gh &>/dev/null; then
        if command -v brew &>/dev/null; then
            log INFO "  Installing GitHub CLI (gh)..."
            brew install gh >> "$LOG_FILE" 2>&1 \
                && log INFO "  gh installed." \
                || log WARN "  gh install failed."
        else
            log WARN "  Skipping gh — Homebrew not available."
        fi
    else
        log INFO "  gh: already installed."
    fi

    # Python packages (databricks-sdk, python-dotenv, requests)
    if command -v pip3 &>/dev/null; then
        log INFO "  Installing Python packages (databricks-sdk, python-dotenv, requests)..."
        pip3 install --quiet --upgrade databricks-sdk python-dotenv requests >> "$LOG_FILE" 2>&1 \
            && log INFO "  Python packages installed." \
            || log WARN "  pip3 install failed — some notebooks may not work."
    else
        log WARN "  pip3 not found — skipping Python packages."
    fi

    echo "$(date '+%Y-%m-%d')" > "$SETUP_FLAG"
    log INFO "First-run setup complete."
}

if [ ! -f "$SETUP_FLAG" ]; then
    run_first_time_setup
fi

# ── Emit cached content (used on cache-hit and on graceful failure) ───────────
emit_cached() {
    if [ -f "$CACHE_FILE" ]; then
        python3 -c "
import json, sys
try:
    cache = json.load(open('$CACHE_FILE'))
    print(json.dumps({'additionalContext': cache.get('content', '')}))
except Exception:
    print('{}')
" 2>/dev/null && return 0
    fi
    echo "{}"
}

fail_gracefully() {
    log WARN "$1 — using cached instructions (session unaffected)."
    emit_cached
    exit 0
}

# ── Get PAT from macOS Keychain ───────────────────────────────────────────────
# Token is distributed via Dashlane (item: katana-handbook-pat) and stored
# locally in the Keychain once per Mac during setup.
PAT=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null || true)

if [ -z "$PAT" ]; then
    fail_gracefully "No PAT found in Keychain. Get the token from Dashlane (katana-handbook-pat) and run: security add-generic-password -s katana-handbook -a github-pat -w YOUR_TOKEN"
fi

AUTH=(-H "Authorization: Bearer $PAT")

# ── Check latest Release tag (pinned — NOT main branch) ──────────────────────
REMOTE_TAG=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" "${GITHUB_API}/releases/latest" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || true)

if [ -z "$REMOTE_TAG" ]; then
    fail_gracefully "Could not fetch latest Release from GitHub (network issue or no Releases published yet)"
fi

# ── Cache hit — no update needed ─────────────────────────────────────────────
LOCAL_TAG=$(cat "$VERSION_FILE" 2>/dev/null || echo "none")
if [ "$REMOTE_TAG" = "$LOCAL_TAG" ] && [ -f "$CACHE_FILE" ]; then
    log INFO "Up to date ($REMOTE_TAG). Using cache."
    emit_cached
    exit 0
fi

log INFO "Update available: $LOCAL_TAG → $REMOTE_TAG. Fetching handbook..."

# ── Fetch helper — always pinned to the release tag, never main ──────────────
fetch_file() {
    curl "${CURL_OPTS[@]}" "${AUTH[@]}" \
        -H "Accept: application/vnd.github.raw" \
        "${GITHUB_API}/contents/$1?ref=${REMOTE_TAG}" 2>/dev/null || true
}

# ── Fetch all handbook files ──────────────────────────────────────────────────
CLAUDE_MD=$(fetch_file "CLAUDE.md")
DATA_SOURCES=$(fetch_file ".claude/docs/data_sources.md")
BUSINESS_METRICS=$(fetch_file ".claude/docs/business_metrics.md")
SOURCE_SYSTEMS=$(fetch_file ".claude/docs/source_systems_and_data_syncs.md")
VECTOR_SEARCH=$(fetch_file ".claude/docs/vector_search_guidelines.md")
PROMPT_GUIDELINES=$(fetch_file ".claude/docs/prompt_guidelines.md")
REPORTING_BI=$(fetch_file ".claude/docs/reporting_and_bi_tools.md")
DATABRICKS_SETUP=$(fetch_file ".claude/docs/databricks_setup.md")

SKILL_ACCOUNT_REVIEW=$(fetch_file ".claude/skills/account-review/SKILL.md")
SKILL_CATALOG=$(fetch_file ".claude/skills/catalog-activity/SKILL.md")
SKILL_CREATE_TRACKER=$(fetch_file ".claude/skills/create-tracker/SKILL.md")
SKILL_DATA_HEALTH=$(fetch_file ".claude/skills/data-health/SKILL.md")
SKILL_DIGITAL_XP=$(fetch_file ".claude/skills/digital-experience-dashboard/SKILL.md")
SKILL_HOT_COLD=$(fetch_file ".claude/skills/hot-cold-leads/SKILL.md")
SKILL_INTEGRATION=$(fetch_file ".claude/skills/integration-dashboard/SKILL.md")
SKILL_MCM=$(fetch_file ".claude/skills/mcm-pipeline/SKILL.md")
SKILL_MONITOR=$(fetch_file ".claude/skills/monitor-run/SKILL.md")
SKILL_ROADMAP_OVERVIEW=$(fetch_file ".claude/skills/roadmap-overview/SKILL.md")
SKILL_ROADMAP_UPDATE=$(fetch_file ".claude/skills/roadmap-update/SKILL.md")
SKILL_WEEKLY=$(fetch_file ".claude/skills/weekly-update/SKILL.md")

# Abort if the core file is missing — don't cache a partial result
if [ -z "$CLAUDE_MD" ]; then
    fail_gracefully "Failed to fetch CLAUDE.md at tag $REMOTE_TAG — aborting to avoid partial state"
fi

# Log per-file status
for name in "data_sources" "business_metrics" "source_systems" "vector_search" "prompt_guidelines"; do
    varname=$(echo "$name" | tr '[:lower:]' '[:upper:]')
    eval "val=\$${varname}"
    [ -z "$val" ] && log WARN "  Missing: ${name}.md (skipped)" || log INFO "  Fetched: ${name}.md"
done

# ── Combine into a single context block ──────────────────────────────────────
FULL_CONTENT="$CLAUDE_MD

---
# docs/data_sources.md
$DATA_SOURCES

---
# docs/business_metrics.md
$BUSINESS_METRICS

---
# docs/source_systems_and_data_syncs.md
$SOURCE_SYSTEMS

---
# docs/vector_search_guidelines.md
$VECTOR_SEARCH

---
# docs/prompt_guidelines.md
$PROMPT_GUIDELINES

---
# docs/reporting_and_bi_tools.md
$REPORTING_BI

---
# docs/databricks_setup.md
$DATABRICKS_SETUP

---
# skills/account-review/SKILL.md
$SKILL_ACCOUNT_REVIEW

---
# skills/catalog-activity/SKILL.md
$SKILL_CATALOG

---
# skills/create-tracker/SKILL.md
$SKILL_CREATE_TRACKER

---
# skills/data-health/SKILL.md
$SKILL_DATA_HEALTH

---
# skills/digital-experience-dashboard/SKILL.md
$SKILL_DIGITAL_XP

---
# skills/hot-cold-leads/SKILL.md
$SKILL_HOT_COLD

---
# skills/integration-dashboard/SKILL.md
$SKILL_INTEGRATION

---
# skills/mcm-pipeline/SKILL.md
$SKILL_MCM

---
# skills/monitor-run/SKILL.md
$SKILL_MONITOR

---
# skills/roadmap-overview/SKILL.md
$SKILL_ROADMAP_OVERVIEW

---
# skills/roadmap-update/SKILL.md
$SKILL_ROADMAP_UPDATE

---
# skills/weekly-update/SKILL.md
$SKILL_WEEKLY"

# ── Write cache + version, emit context ──────────────────────────────────────
export HANDBOOK_TAG="$REMOTE_TAG"
export HANDBOOK_VERSION_FILE="$VERSION_FILE"
export HANDBOOK_CACHE_FILE="$CACHE_FILE"

python3 -c "
import json, sys, os

tag        = os.environ['HANDBOOK_TAG']
ver_file   = os.environ['HANDBOOK_VERSION_FILE']
cache_file = os.environ['HANDBOOK_CACHE_FILE']
content    = sys.stdin.read()

# Write cache (used as fallback on future network failures)
with open(cache_file, 'w') as f:
    json.dump({'tag': tag, 'content': content}, f)

# Write human-readable version file
with open(ver_file, 'w') as f:
    f.write(tag)

# Emit as Claude Code session context
print(json.dumps({'additionalContext': content}))
" <<< "$FULL_CONTENT"

log INFO "Sync complete. Now at ${REMOTE_TAG}."

# ── Merge permissions from handbook into local settings.json ─────────────────
# Fetches setup/permissions.json from the release and additively merges the
# allow list into ~/.claude/settings.json. Existing entries are never removed.
PERMS_JSON=$(fetch_file "setup/permissions.json")
if [ -n "$PERMS_JSON" ]; then
    export HANDBOOK_PERMS="$PERMS_JSON"
    python3 -c "
import json, os

settings_file = os.path.expanduser('~/.claude/settings.json')
new_allow = set(json.loads(os.environ['HANDBOOK_PERMS']).get('allow', []))

try:
    with open(settings_file) as f:
        settings = json.load(f)
except Exception:
    settings = {}

existing = set(settings.get('permissions', {}).get('allow', []))
merged = sorted(existing | new_allow)

if 'permissions' not in settings:
    settings['permissions'] = {}
settings['permissions']['allow'] = merged

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)
" && log INFO "Permissions merged (${#PERMS_JSON} chars)." \
  || log WARN "Permissions merge failed — settings.json unchanged."
fi
