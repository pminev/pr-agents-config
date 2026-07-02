#!/usr/bin/env bash
#
# run-agent.sh — tool-independent adapter that runs an agentic coding CLI
# headlessly against a GitHub issue.
#
# It reads the issue (ISSUE_JSON), builds a prompt from the template, and
# dispatches to whichever CLI is named in AGENT_CLI. The agent edits the working
# tree in place; open-pr.sh then branches, commits, pushes and opens the PR.
#
# Contract with the agent:
#   * It may edit files and run commands (tests, build) to complete the task.
#   * It MUST write a human-readable summary to $AGENT_SUMMARY_FILE using the
#     "What changed / What I tested / How you can test it" structure. open-pr.sh
#     uses that file verbatim as the PR body. If the file is missing we fall
#     back to a generic body.
#
# Required env:
#   AGENT_CLI        claude | qwen | antigravity
#   ISSUE_JSON       path to `gh issue view --json ...` output
#   ISSUE_NUMBER     the issue number
# Optional env:
#   AGENT_MODEL      model override passed to the CLI
#   AGENT_TIMEOUT    seconds before the agent run is killed (default 2400)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT_DIR/.github/agent/prompt-template.md"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-2400}"

# A runner installed as a service (launchd/systemd) often starts with no HOME.
# The agent CLIs (antigravity/agy, ollama) and git config need it for their
# config dir, so derive it from the passwd entry when it's missing.
if [ -z "${HOME:-}" ] || [ ! -d "${HOME:-}" ]; then
  HOME="$(eval echo "~$(id -un)" 2>/dev/null || true)"
  [ -n "$HOME" ] && [ -d "$HOME" ] || HOME="${RUNNER_TEMP:-/tmp}"
  export HOME
  echo "==> HOME was unset; using HOME=$HOME"
fi

: "${AGENT_CLI:?AGENT_CLI must be set (claude | qwen | antigravity)}"
: "${ISSUE_JSON:?ISSUE_JSON must be set}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER must be set}"

# Files shared with open-pr.sh via the workspace/temp dir.
WORK="${RUNNER_TEMP:-/tmp}"
export AGENT_SUMMARY_FILE="$WORK/agent-summary.md"
PROMPT_FILE="$WORK/agent-prompt.md"
: > "$AGENT_SUMMARY_FILE"

# ---------------------------------------------------------------------------
# Build the prompt: template + issue title/body, with the summary-file path
# substituted so the agent knows where to write its report.
# ---------------------------------------------------------------------------
issue_title="$(jq -r '.title' "$ISSUE_JSON")"
issue_body="$(jq -r '.body // ""' "$ISSUE_JSON")"
issue_url="$(jq -r '.url' "$ISSUE_JSON")"

{
  sed \
    -e "s#{{ISSUE_NUMBER}}#${ISSUE_NUMBER}#g" \
    -e "s#{{SUMMARY_FILE}}#${AGENT_SUMMARY_FILE}#g" \
    "$TEMPLATE"
  echo
  echo "## Issue #${ISSUE_NUMBER}: ${issue_title}"
  echo "URL: ${issue_url}"
  echo
  echo "### Description"
  echo "${issue_body}"
} > "$PROMPT_FILE"

# Follow-up run: prior changes are already in the working tree on this branch.
# Append the maintainer's feedback (minus the "/agent" marker) as the new task.
if [ "${IS_FOLLOWUP:-false}" = "true" ] && [ -n "${FEEDBACK:-}" ]; then
  {
    echo
    echo "### Follow-up feedback (address this)"
    echo "This is a follow-up run. Your earlier changes are ALREADY applied in the"
    echo "working tree on this branch — build on them, do not start over. Apply the"
    echo "feedback below:"
    echo
    echo "${FEEDBACK#/agent}"
  } >> "$PROMPT_FILE"
fi

PROMPT="$(cat "$PROMPT_FILE")"

echo "==> Running agent '$AGENT_CLI' on issue #$ISSUE_NUMBER"

# ---------------------------------------------------------------------------
# Optional local-model launcher. `ollama launch <tool>` starts the SAME agent
# CLI (claude / qwen) but backed by a local Ollama model instead of a cloud API.
# It's orthogonal to AGENT_CLI: set USE_OLLAMA=true to run whichever CLI you
# chose against a local model. When on, the cloud --model flag is dropped (the
# model comes from Ollama; select it via OLLAMA_MODEL).
# ---------------------------------------------------------------------------
launch=()
use_cloud_model=true
if [ "${USE_OLLAMA:-false}" = "true" ]; then
  launch=(ollama launch)
  use_cloud_model=false
  [ -n "${OLLAMA_HOST:-}" ] && export OLLAMA_HOST
  # Which local model Ollama serves for the session. Exported so `ollama launch`
  # (and the tool it wraps) can pick it up.
  [ -n "${OLLAMA_MODEL:-}" ] && export OLLAMA_MODEL
fi

# ---------------------------------------------------------------------------
# Build the command for the configured CLI as an array. Each tool runs in its
# non-interactive / headless mode with edits auto-accepted (there is no human in
# the loop). Add a new tool by adding a case here — nothing else changes.
# ---------------------------------------------------------------------------
cmd=()
case "$AGENT_CLI" in
  claude)
    # --print runs headlessly; acceptEdits applies file changes unattended.
    cmd=("${launch[@]}" claude --print --permission-mode acceptEdits)
    [ "$use_cloud_model" = true ] && [ -n "${AGENT_MODEL:-}" ] && cmd+=(--model "$AGENT_MODEL")
    cmd+=("$PROMPT")
    ;;
  qwen)
    # Qwen Code (Gemini-CLI fork) non-interactive mode. -y auto-approves actions.
    cmd=("${launch[@]}" qwen --prompt "$PROMPT" -y)
    [ "$use_cloud_model" = true ] && [ -n "${AGENT_MODEL:-}" ] && cmd+=(--model "$AGENT_MODEL")
    ;;
  antigravity)
    # Google Antigravity CLI headless mode.
    # agy must operate on THIS checkout, not a workspace it has configured
    # elsewhere. Set AGENT_WORKDIR_FLAG to the flag your `agy --help` uses for
    # the project/working directory (e.g. "--workspace", "--cwd", "-C"); we pass
    # the current checkout ($PWD) as its value. Leave empty to omit.
    cmd=(agy --prompt "$PROMPT")
    [ -n "${AGENT_MODEL:-}" ] && cmd+=(--model "$AGENT_MODEL")
    [ -n "${AGENT_WORKDIR_FLAG:-}" ] && cmd+=("$AGENT_WORKDIR_FLAG" "$PWD")
    ;;
  *)
    echo "ERROR: unknown AGENT_CLI '$AGENT_CLI'" >&2; exit 2 ;;
esac

# Diagnostic: which directory should the edits land in? Compare this to the
# paths the agent reports. They MUST match, or open-pr.sh will see no changes.
echo "==> Checkout / working directory: $PWD"
echo "==> git status BEFORE agent:"; git status --porcelain || true

# Run with a hard timeout so a stuck agent can't hold the runner forever.
if command -v timeout >/dev/null 2>&1; then
  timeout "$AGENT_TIMEOUT" "${cmd[@]}"
else
  "${cmd[@]}"
fi

echo "==> git status AFTER agent (changes must appear here to be committed):"
git status --porcelain || true

# ---------------------------------------------------------------------------
# Optional per-repo preview/host step (e.g. start a dev server, deploy a
# preview). Runs only if the repo provides it, keeping this config reusable.
# ---------------------------------------------------------------------------
if [ -x "$ROOT_DIR/scripts/preview.sh" ]; then
  echo "==> Running repo preview hook"
  # Non-fatal: a failed preview shouldn't block the PR.
  "$ROOT_DIR/scripts/preview.sh" >> "$AGENT_SUMMARY_FILE" 2>&1 || \
    echo "(preview hook failed — see run logs)" >> "$AGENT_SUMMARY_FILE"
fi

echo "==> Agent run complete"
