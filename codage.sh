#!/usr/bin/env sh
set -eu

say() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

OS_NAME="$(uname -s 2>/dev/null || printf unknown)"

case "$OS_NAME" in
  Darwin|Linux)
    ;;
  *)
    fail "Unsupported OS: $OS_NAME. This installer supports macOS and Linux."
    ;;
esac

DISTRO_ID=""
DISTRO_LIKE=""
if [ "$OS_NAME" = "Linux" ] && [ -r /etc/os-release ]; then
  DISTRO_ID="$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)"
  DISTRO_LIKE="$(awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)"
fi

if [ "$OS_NAME" = "Linux" ]; then
  case " $DISTRO_ID $DISTRO_LIKE " in
    *" ubuntu "*|*" debian "*|*" arch "*|*" cachyos "*)
      ;;
    *)
      warn "Linux distro detected as '${DISTRO_ID:-unknown}'. Installer is generic and should still work."
      ;;
  esac
fi

AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
SKILL_DIR="$AGENTS_HOME/skills/usage"
SCRIPT_DIR="$SKILL_DIR/scripts"
AGENT_DIR="$SKILL_DIR/agents"
BIN_DIR="${CODEX_USAGE_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$SCRIPT_DIR" "$AGENT_DIR" "$BIN_DIR"

cat > "$SCRIPT_DIR/show_usage_bar.sh" <<'CODAGE_SHOW_USAGE_BAR_SH'
#!/usr/bin/env bash
set -euo pipefail

title="${CODEX_USAGE_TITLE:-Codex Usage}"
if [ "${CODEX_USAGE_FORCE_DUMMY:-0}" = "1" ]; then
  detail="${CODEX_USAGE_DETAIL:-Dummy data}"
else
  detail="${CODEX_USAGE_DETAIL:-Live limits}"
fi

five_percent="${CODEX_USAGE_5H_PERCENT:-64}"
weekly_percent="${CODEX_USAGE_WEEKLY_PERCENT:-38}"

five_value="${CODEX_USAGE_5H_VALUE:-}"
weekly_value="${CODEX_USAGE_WEEKLY_VALUE:-}"

five_reset="${CODEX_USAGE_5H_RESET:-resets in 4h 12m}"
weekly_reset="${CODEX_USAGE_WEEKLY_RESET:-resets Monday}"

live_json=""
if [ "${CODEX_USAGE_FORCE_DUMMY:-0}" != "1" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  live_json="$(python3 "$script_dir/read_rate_limits.py" 2>/dev/null || true)"
fi

if [ -n "$live_json" ]; then
  five_percent="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["primary_used_percent"])')"
  weekly_percent="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secondary_used_percent"])')"
  five_reset="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["primary_reset"])')"
  weekly_reset="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secondary_reset"])')"
  plan_type="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("plan_type") or "unknown")')"
  credits="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("credits_balance") or "0")')"
  detail="plan: ${plan_type}, credits: ${credits}"
fi

cols="$(tput cols 2>/dev/null || printf '80')"
if [ "$cols" -ge 78 ]; then
  width=74
else
  width=64
fi

content_width=$((width - 4))
bar_width=18

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  while [ "$count" -gt 0 ]; do
    out="${out}${char}"
    count=$((count - 1))
  done
  printf '%s' "$out"
}

normalize_percent() {
  local raw="${1%\%}"
  awk -v value="$raw" 'BEGIN {
    if (value !~ /^-?[0-9]+([.][0-9]+)?$/) value = 0
    value = int(value + 0.5)
    if (value < 0) value = 0
    if (value > 100) value = 100
    print value
  }'
}

bar() {
  local percent="$1"
  local filled=$((bar_width * percent / 100))
  local empty=$((bar_width - filled))
  printf '%s%s' "$(repeat_char '█' "$filled")" "$(repeat_char '░' "$empty")"
}

line() {
  local text="$1"
  local len="${#text}"
  local pad=$((content_width - len))
  if [ "$pad" -lt 0 ]; then
    text="${text:0:content_width}"
    pad=0
  fi
  printf '│ %s%s │\n' "$text" "$(repeat_char ' ' "$pad")"
}

rule() {
  printf '├%s┤\n' "$(repeat_char '─' $((width - 2)))"
}

metric_line() {
  local label="$1"
  local percent="$2"
  local value="$3"
  local reset_label="$4"
  local usage_bar
  usage_bar="$(bar "$percent")"
  printf -v text '%-14s %s %3s%%  %-10s %s' "$label" "$usage_bar" "$percent" "$value" "$reset_label"
  line "$text"
}

five_percent="$(normalize_percent "$five_percent")"
weekly_percent="$(normalize_percent "$weekly_percent")"

if [ -z "$five_value" ]; then
  five_value="$((100 - five_percent))% left"
fi

if [ -z "$weekly_value" ]; then
  weekly_value="$((100 - weekly_percent))% left"
fi

printf '╭%s╮\n' "$(repeat_char '─' $((width - 2)))"
printf -v header '%-34s %s' "$title" "$detail"
line "$header"
rule
metric_line "5 hour limit" "$five_percent" "$five_value" "$five_reset"
metric_line "weekly limit" "$weekly_percent" "$weekly_value" "$weekly_reset"
printf '╰%s╯\n' "$(repeat_char '─' $((width - 2)))"
CODAGE_SHOW_USAGE_BAR_SH

cat > "$SCRIPT_DIR/read_rate_limits.py" <<'CODAGE_READ_RATE_LIMITS_PY'
#!/usr/bin/env python3
import json
import os
import pty
import select
import subprocess
import sys
import time
from datetime import datetime


def send(master_fd, payload):
    os.write(master_fd, (json.dumps(payload) + "\r").encode())


def read_until(master_fd, target_id, timeout_seconds=10):
    deadline = time.time() + timeout_seconds
    buffer = b""
    while time.time() < deadline:
        ready, _, _ = select.select([master_fd], [], [], 0.25)
        if not ready:
            continue
        chunk = os.read(master_fd, 8192)
        if not chunk:
            continue
        buffer += chunk
        lines = buffer.splitlines(keepends=True)
        if lines and not lines[-1].endswith((b"\n", b"\r")):
            buffer = lines.pop()
        else:
            buffer = b""
        for raw_line in lines:
            line = raw_line.decode(errors="ignore").strip()
            if not line or not line.startswith("{"):
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("id") == target_id and (
                "result" in message or "error" in message
            ):
                return message
    raise TimeoutError(f"no response for id {target_id}")


def reset_text(timestamp):
    if not timestamp:
        return "reset unknown"
    reset_value = int(timestamp)
    if reset_value > 10_000_000_000:
        reset_value = reset_value // 1000
    reset_at = datetime.fromtimestamp(reset_value)
    now = datetime.now()
    delta_seconds = max(0, int((reset_at - now).total_seconds()))
    minutes = delta_seconds // 60
    if minutes < 60:
        return f"resets in {minutes}m"
    if minutes < 24 * 60:
        return f"resets in {minutes // 60}h {minutes % 60:02d}m"
    return "resets " + reset_at.strftime("%a %H:%M")


def main():
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        ["codex", "app-server", "--listen", "stdio://"],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )
    os.close(slave_fd)

    try:
        send(
            master_fd,
            {
                "id": 0,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "usage_skill",
                        "title": "Usage Skill",
                        "version": "0.1.0",
                    }
                },
            },
        )
        read_until(master_fd, 0)
        send(master_fd, {"method": "initialized", "params": {}})
        send(master_fd, {"id": 1, "method": "account/rateLimits/read", "params": {}})
        response = read_until(master_fd, 1)
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except Exception:
            proc.kill()
        os.close(master_fd)

    if "error" in response:
        raise RuntimeError(response["error"])

    rate_limits = response["result"]["rateLimits"]
    primary = rate_limits.get("primary") or {}
    secondary = rate_limits.get("secondary") or {}
    credits = rate_limits.get("credits") or {}

    output = {
        "primary_used_percent": int(primary.get("usedPercent") or 0),
        "secondary_used_percent": int(secondary.get("usedPercent") or 0),
        "primary_reset": reset_text(primary.get("resetsAt")),
        "secondary_reset": reset_text(secondary.get("resetsAt")),
        "plan_type": rate_limits.get("planType"),
        "credits_balance": str(credits.get("balance", "0")),
    }
    print(json.dumps(output, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"failed to read rate limits: {exc}", file=sys.stderr)
        sys.exit(1)
CODAGE_READ_RATE_LIMITS_PY

cat > "$SKILL_DIR/SKILL.md" <<CODAGE_SKILL_MD
---
name: usage
description: Show a terminal-style Codex usage bar with live local Codex rate-limit data when available.
---

# Usage

Render a compact terminal UI for Codex usage status. Prefer live Codex rate-limit data from the local app-server, falling back to dummy values when unavailable.

## Workflow

Run the bundled script and show only its output:

\`\`\`bash
bash "$SCRIPT_DIR/show_usage_bar.sh"
\`\`\`

The script supports variable inputs through environment variables:

- \`CODEX_USAGE_5H_PERCENT\`
- \`CODEX_USAGE_WEEKLY_PERCENT\`
- \`CODEX_USAGE_5H_VALUE\`
- \`CODEX_USAGE_WEEKLY_VALUE\`
- \`CODEX_USAGE_5H_RESET\`
- \`CODEX_USAGE_WEEKLY_RESET\`
- \`CODEX_USAGE_FORCE_DUMMY=1\`

Do not add analysis, explanation, or follow-up text after the bar unless the user asks.
CODAGE_SKILL_MD

cat > "$AGENT_DIR/openai.yaml" <<'CODAGE_OPENAI_YAML'
interface:
  display_name: "Usage"
  short_description: "Show a terminal Codex usage bar"
  default_prompt: "Show the usage bar"
CODAGE_OPENAI_YAML

cat > "$BIN_DIR/codage" <<CODAGE_BIN
#!/usr/bin/env sh
exec bash "$SCRIPT_DIR/show_usage_bar.sh" "\$@"
CODAGE_BIN

chmod +x "$SCRIPT_DIR/show_usage_bar.sh" "$SCRIPT_DIR/read_rate_limits.py" "$BIN_DIR/codage"

BEGIN_MARKER="# >>> codage usage skill >>>"
END_MARKER="# <<< codage usage skill <<<"

remove_managed_block() {
  rc_file="$1"
  [ -f "$rc_file" ] || return 0
  tmp_file="${rc_file}.codage.$$"
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$rc_file" > "$tmp_file"
  mv "$tmp_file" "$rc_file"
}

add_posix_rc() {
  rc_file="$1"
  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"
  remove_managed_block "$rc_file"
  cat >> "$rc_file" <<CODAGE_POSIX_RC

$BEGIN_MARKER
export PATH="$BIN_DIR:\$PATH"
codage() {
  bash "$SCRIPT_DIR/show_usage_bar.sh" "\$@"
}
$END_MARKER
CODAGE_POSIX_RC
}

add_fish_rc() {
  rc_file="$1"
  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"
  remove_managed_block "$rc_file"
  cat >> "$rc_file" <<CODAGE_FISH_RC

$BEGIN_MARKER
if test -d "$BIN_DIR"
  if type -q fish_add_path
    fish_add_path -g "$BIN_DIR"
  else
    set -gx PATH "$BIN_DIR" \$PATH
  end
end

function codage
  bash "$SCRIPT_DIR/show_usage_bar.sh" \$argv
end
$END_MARKER
CODAGE_FISH_RC
}

add_posix_rc "$HOME/.zshrc"
add_posix_rc "$HOME/.bashrc"

if [ "$OS_NAME" = "Darwin" ]; then
  add_posix_rc "$HOME/.bash_profile"
else
  add_posix_rc "$HOME/.profile"
fi

if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  FISH_CONFIG="$XDG_CONFIG_HOME/fish/config.fish"
else
  FISH_CONFIG="$HOME/.config/fish/config.fish"
fi
add_fish_rc "$FISH_CONFIG"

if ! command -v bash >/dev/null 2>&1; then
  warn "bash was not found. Install bash for the codage command to run."
fi

if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 was not found. Live Codex limits need python3; dummy display will still work if forced."
fi

if ! command -v codex >/dev/null 2>&1; then
  warn "codex command was not found in PATH. Live limits will work after Codex CLI is installed and logged in."
fi

say "codage installed."
say "Skill directory: $SKILL_DIR"
say "Command: $BIN_DIR/codage"
say ""
say "To use it now in this terminal, run one of these depending on your shell:"
say "  zsh:  source ~/.zshrc"
say "  bash: source ~/.bashrc"
say "  fish: source $FISH_CONFIG"
say ""
say "Then run:"
say "  codage"
