# pr-agents-config

A reusable repo configuration for **agentic programming**: open a GitHub issue,
and an AI coding agent running on your own machine implements it, pushes a
branch, and opens a pull request describing what it changed, what it tested, and
how you can test it.

It is **tool-independent** — the same setup drives Antigravity (`agy`), Claude Code, or
Qwen Code. You pick the CLI with one variable; all tool execution patterns are handled
automatically by the runner adapter script.


## How it works

```
Issue opened OR issue/PR comment starting with "/agent"
   └─> .github/workflows/agent-on-issue.yml   (runs on YOUR self-hosted runner)
         └─> scripts/run-agent.sh             (invokes antigravity | claude | qwen headlessly)
               ├─ builds prompt from .github/agent/prompt-template.md + issue details
               ├─ appends any follow-up feedback comment (minus "/agent" prefix)
               ├─ prepares the branch (fresh or checks out existing for follow-ups)
               ├─ the agent edits files and runs tests
               ├─ scripts/preview.sh          (optional per-repo host/preview hook)
               └─> scripts/open-pr.sh          (commits and pushes → opens PR or comments on existing PR)
```

The agent writes a structured summary that becomes the PR body (or a PR comment for follow-ups):
**What changed / What I tested / How you can test it**.

## Files

| Path | Purpose |
|------|---------|
| `.github/workflows/agent-on-issue.yml` | Trigger on issue opened/labeled or comment (`/agent`); run on self-hosted runner |
| `scripts/run-agent.sh` | Tool-independent adapter — dispatches to chosen CLI, manages runner `HOME` environment fallback |
| `scripts/open-pr.sh` | Git commit/push, opens a new PR or comments on an existing PR for follow-ups |
| `scripts/preview.sh` | Optional per-repo preview/host hook (opt-in: `chmod +x` to enable) |
| `.github/agent/prompt-template.md` | The task prompt + required output format |
| `AGENTS.md` / `CLAUDE.md` | Shared repo conventions every tool reads |
| `.github/PULL_REQUEST_TEMPLATE.md` | PR skeleton |
| `agent.config.example.env` | The variables/secrets to configure (defaults to `antigravity`) |

## Setup

### 1. Register a self-hosted runner on your machine
The agent runs where your CLIs are installed. In the target repo:
**Settings → Actions → Runners → New self-hosted runner**, then follow the
generated commands. Keep it running (e.g. as a service via `svc.sh`).

> The runner must have your agent CLI, `git`, `gh`, `jq`, and your project's
> toolchain installed.

### 2. Install and authenticate your agent CLI
Pick one and make sure it works non-interactively on the runner:
- **Antigravity** — `antigravity` (default, auth via `GEMINI_API_KEY` or standard Google API credentials). It runs the `agy` CLI with automated workspaces scoped to the repository checkout path.
- **Claude Code** — `claude` (auth via `ANTHROPIC_API_KEY` or a subscription
  `CLAUDE_CODE_OAUTH_TOKEN`).
- **Qwen Code** — `qwen` (auth via `QWEN_API_KEY`/`GEMINI_API_KEY`).

**Run against a local model (Ollama).** Ollama can launch Claude Code or Qwen
Code backed by a local model instead of a cloud API — no API key or network
calls. Set the variable `USE_OLLAMA=true` and `OLLAMA_MODEL` to a model you've
pulled (`ollama pull qwen2.5-coder:14b`); keep `AGENT_CLI` as `claude` or `qwen`.
The pipeline then runs `ollama launch <tool>` and the cloud `AGENT_MODEL` is
ignored. The runner must have `ollama` installed with the model pulled and the
server running.

### 3. Configure variables and secrets
In the repo: **Settings → Secrets and variables → Actions**.

- **Variables** (from `agent.config.example.env`): `AGENT_CLI` (defaults to `antigravity`),
  `AGENT_MODEL`, `AGENT_REQUIRE_LABEL`, `AGENT_TRIGGER_LABEL`, `AGENT_TIMEOUT_MINUTES`,
  and for local models `USE_OLLAMA`, `OLLAMA_MODEL`, `OLLAMA_HOST`.
- **Secrets**: the API key(s) your CLI needs (`GEMINI_API_KEY`, `ANTHROPIC_API_KEY`, etc.).
  Not needed when `USE_OLLAMA=true`.

### 4. Create the trigger label
If `AGENT_REQUIRE_LABEL=true` (default), create a label matching
`AGENT_TRIGGER_LABEL` (default `agent`). Add it to an issue to start a run. Set
`AGENT_REQUIRE_LABEL=false` to run on every new issue instead.

### 5. Copy this config into your project
Copy `.github/`, `scripts/`, `AGENTS.md`, and `CLAUDE.md` into the target repo,
then flesh out `AGENTS.md` and `scripts/preview.sh` for that project.

## Try it
1. Open an issue: *"Add a `--version` flag that prints the package version."*
2. Add the `agent` label (or skip if label-gating is off).
3. Watch the run under the **Actions** tab; a PR appears when it finishes.
4. You can also run manually: **Actions → Agent on issue → Run workflow**, and
   pass an issue number.
5. **Address feedback / iterate**: Post a comment starting with `/agent` (e.g., `/agent write tests for this too` or `/agent fix the typo in the import`) on the issue or the resulting PR. The agent will check out the existing branch, apply the feedback, and post its summary as a PR comment when finished.

## Security notes
A self-hosted runner executes agent-authored code and commands from issues.
- **Restrict who can trigger runs.** Prefer label-gating and only let
  maintainers apply the trigger label; anyone who can open a labeled issue can
  make the agent run code on your machine.
- **Comment-driven triggers.** The workflow triggers on issue/PR comments starting with `/agent` from users (excluding bot accounts). Ensure access control settings or environments align with who you trust to execute commands on the runner.
- Consider a dedicated/sandboxed machine or VM for the runner.
- The workflow uses the built-in `GITHUB_TOKEN` with least-privilege
  `permissions:`. Don't expose more secrets than the chosen CLI needs.
- Review every PR before merging — the agent's "What I tested" is a report, not
  a guarantee.
