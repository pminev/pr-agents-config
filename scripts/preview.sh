#!/usr/bin/env bash
#
# preview.sh — OPTIONAL, per-repo preview/host hook.
#
# This is a TEMPLATE. It is intentionally generic; customize (or delete) it in
# each real repo. If present and executable, the pipeline runs it after the
# agent finishes and appends its stdout to the PR body — so print a URL or clear
# instructions the reviewer can act on.
#
# Requirements:
#   * Non-interactive. Never block waiting for input.
#   * Exit non-zero on failure (the pipeline marks the preview as failed but
#     still opens the PR).
#   * Prefer a shareable preview (deploy) over a localhost server, since this
#     runs on your machine and the reviewer may be elsewhere.

set -euo pipefail

echo ""
echo "## Preview"

# --- Example: static site / built web app -------------------------------
# npm ci
# npm run build
# url=$(npx vercel deploy --prebuilt --yes 2>/dev/null | tail -1)
# echo "- Live preview: $url"

# --- Example: local dev server (reviewer must be on your network) --------
# npm run dev >/tmp/dev.log 2>&1 &
# echo "- Local server started on http://localhost:3000 (see /tmp/dev.log)"

echo "- No preview configured for this repo. Edit \`scripts/preview.sh\` to add one."
