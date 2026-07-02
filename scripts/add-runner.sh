#!/usr/bin/env bash
#
# add-runner.sh — set up ONE self-hosted runner in its own folder with an
# isolated HOME, so multiple runners on the same machine can process agent jobs
# in parallel without sharing tool state (agy workspace/auth, caches, logs).
# Run it once per parallel slot: ./add-runner.sh 1, ./add-runner.sh 2, ...
#
# Each runner gets:
#   * its own install dir + its own _work checkout (GitHub gives this for free)
#   * its own HOME (via the runner's .env) so agy/claude/qwen state is isolated
#
# Usage:
#   REPO=owner/name GH_PAT=ghp_xxx ./scripts/add-runner.sh <slot-number>
# Optional env:
#   RUNNER_BASE     parent dir for runner folders (default: $HOME/agent-runners)
#   RUNNER_VERSION  actions runner version (default below)
#   RUNNER_LABELS   labels for the runner (default: self-hosted,agent)

set -euo pipefail

: "${REPO:?set REPO=owner/name}"
: "${GH_PAT:?set GH_PAT (admin PAT for REPO) to fetch a registration token}"
SLOT="${1:?usage: add-runner.sh <slot-number>}"

RUNNER_VERSION="${RUNNER_VERSION:-2.319.1}"
RUNNER_NAME="agent-runner-${SLOT}"
# A UNIQUE label equal to the runner name lets the workflow pin a follow-up to
# this exact runner (so it can resume a session that lives in this HOME).
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,agent},${RUNNER_NAME}"
BASE="${RUNNER_BASE:-$HOME/agent-runners}"
DIR="$BASE/runner-$SLOT"
RUNNER_HOME="$DIR/home"   # isolated HOME for this runner's agent CLIs

# Detect platform for the runner download.
case "$(uname -s)" in
  Linux)  os=linux ;;
  Darwin) os=osx ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64)         arch=x64 ;;
  arm64|aarch64)  arch=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$DIR" "$RUNNER_HOME"
cd "$DIR"

# Download the runner into this slot's folder if it isn't there yet.
if [ ! -x ./run.sh ]; then
  echo "==> Downloading actions runner v${RUNNER_VERSION} ($os-$arch)"
  curl -fsSL -o runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-${os}-${arch}-${RUNNER_VERSION}.tar.gz"
  tar xzf runner.tar.gz && rm runner.tar.gz
fi

# Short-lived registration token from the PAT.
echo "==> Fetching registration token for ${REPO}"
REG_TOKEN="$(curl -fsSL -X POST \
  -H "Authorization: Bearer ${GH_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/runners/registration-token" | jq -r .token)"

./config.sh --unattended \
  --url "https://github.com/${REPO}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --work "_work" \
  --replace

# The runner applies this .env to every job it runs — isolate HOME here so each
# slot's agent CLI keeps its own config/auth and they never step on each other.
if ! grep -q '^HOME=' .env 2>/dev/null; then
  echo "HOME=${RUNNER_HOME}" >> .env
fi

cat <<EOF

==> Runner ${SLOT} ready in ${DIR}
    isolated HOME: ${RUNNER_HOME}

Next:
  1. Authenticate your agent CLI ONCE for this HOME, e.g.:
       HOME=${RUNNER_HOME} agy      # (or claude / qwen) — do the login
     (Skip if you authenticate via an API-key secret instead.)
  2. Start it:
       (cd ${DIR} && ./run.sh)          # foreground, or
       (cd ${DIR} && sudo ./svc.sh install && sudo ./svc.sh start)   # as a service

Repeat with a new slot number for each additional parallel runner.
EOF
