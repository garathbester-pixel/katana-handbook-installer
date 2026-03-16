#\!/bin/bash
# Katana Handbook — one-time installer
# Downloads the sync script and wires it into Claude Code automatically.
set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPT_PATH="$CLAUDE_DIR/fetch-handbook.sh"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
SCRIPT_URL="https://raw.githubusercontent.com/garathbester-pixel/katana-handbook-installer/main/fetch-handbook.sh"

echo "Setting up Katana Handbook sync..."

# 1. Create ~/.claude if it does not exist
mkdir -p "$CLAUDE_DIR"

# 2. Download the sync script
curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
echo "  ✓ Sync script downloaded"

# 3. Wire up the SessionStart hook in ~/.claude/settings.json
python3 - <<'PYEOF'
import json, os

settings_file = os.path.expanduser("~/.claude/settings.json")

try:
    with open(settings_file) as f:
        settings = json.load(f)
except Exception:
    settings = {}

hook_command = "~/.claude/fetch-handbook.sh"
hook_entry = {"hooks": [{"type": "command", "command": hook_command}]}

existing_hooks = settings.get("hooks", {}).get("SessionStart", [])
already_configured = any(
    any(h.get("command") == hook_command for h in e.get("hooks", []))
    for e in existing_hooks
)

if not already_configured:
    if "hooks" not in settings:
        settings["hooks"] = {}
    settings["hooks"].setdefault("SessionStart", []).append(hook_entry)
    with open(settings_file, "w") as f:
        json.dump(settings, f, indent=2)
    print("  ✓ SessionStart hook configured")
else:
    print("  ✓ Hook already configured — skipping")
PYEOF

echo ""
echo "Done\! Open Claude Code and it will fetch the Katana Handbook automatically on first launch."

