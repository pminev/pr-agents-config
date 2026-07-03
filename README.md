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
| `scripts/add-runner.sh` | Set up an extra self-hosted runner (own folder + isolated `HOME`) for parallel issues |
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

### Parallel issues (N runners, N folders)
A single runner processes one job at a time, so issues queue and run serially.
To run several issues **in parallel**, add more runners — one per parallel slot,
each in its own folder with its own `HOME`:

```bash
REPO=owner/name GH_PAT=ghp_xxx ./scripts/add-runner.sh 1
REPO=owner/name GH_PAT=ghp_xxx ./scripts/add-runner.sh 2   # and so on
```

Each slot gets its own install dir, its own `_work` checkout (so branches and
files never collide), and an isolated `HOME` written to the runner's `.env` (so
each `agy`/`claude`/`qwen` keeps its own config/auth and they don't step on each
other). Authenticate the CLI once per slot's `HOME`, then start each runner. The
per-issue branch (`agent/issue-N`) and the workflow's per-issue `concurrency`
group keep parallel runs isolated at the Git/workflow level; separate folders +
`HOME` isolate them on disk.

Two folder concepts, don't conflate them:
- **Runner install folder** (`runner-1`, `runner-2`, …) — persistent, one per
  parallel *slot*, not tied to any issue. It picks up whatever job comes next.
- **Per-run working folder** (`issue_<n>`) — where each run checks out and edits.
  The workflow checks out into a folder named for the issue (via the `ISSUE_DIR`
  env + `actions/checkout` `path:`), so each run's workspace is clearly named
  and isolated. These accumulate under a runner's workspace; delete old
  `issue_*` folders periodically if disk matters.

### Session continuity & follow-ups
When you comment `/agent <feedback>`, the agent doesn't just re-read the branch —
it **resumes the same CLI session**, so it keeps its earlier reasoning, not only
the diff. Here's the flow:

```
first run                          follow-up (/agent …)
  agent job (any runner)             route job (any runner)
   └ claude --session-id <uuid>       └ reads newest session marker on the issue
     agy  → capture brain/<id>/         → recovers { runner, session id, cli }
   └ open-pr posts a marker on        agent job → runs-on [self-hosted, <that runner>]
     the ISSUE:                        └ claude --resume <id>  /  agy --conversation <id>
     🧠 runner=… session=… cli=…
     <!-- agent-session … -->
```

Two mechanisms make this work:
- **Pinning.** Sessions live in the runner's `HOME`, so a follow-up must run on
  the *same* runner. Each runner has a unique label equal to its name
  (`agent-runner-N`, set by `add-runner.sh`); the `route` job recovers it from
  the marker and the `agent` job targets it via `runs-on`. Fresh runs (no
  marker) run on any `self-hosted` runner.
- **Session capture.** `claude` gets a generated `--session-id` we can
  `--resume`. `agy` logs each conversation under
  `~/.gemini/antigravity-cli/brain/<id>/`, so we read the newest dir after the
  run and later `agy --conversation <id>`.

The **session marker** is a comment on the original issue (human-readable info
plus a hidden `<!-- agent-session … -->` line). It's also your manual handle:
it prints the exact `claude --resume …` / `agy --conversation …` command to
attach to that session yourself on the runner.

Notes and limits:
- **Exact resume works for `claude` and `agy`.** `qwen` has no headless resume,
  so its follow-ups fall back to branch-diff + feedback (still fine, just no
  conversation memory).
- If the recovered runner is offline, the pinned follow-up **queues** until it's
  back (it won't fall back to another runner, which wouldn't have the session).
- Switching `AGENT_CLI` mid-issue breaks resume — the saved session belongs to
  the original CLI.

## CLI and Model Selection

You can select the CLI and model used by the agent either globally (for all runs) or dynamically on-the-fly (for a specific issue or PR).

### 1. Global Selection (Default)
Set the default CLI and model for all runs via GitHub repository variables (**Settings → Secrets and variables → Actions**):
- **`AGENT_CLI`**: The CLI tool to run. Supported options: `antigravity`, `claude`, or `qwen`.
- **`AGENT_MODEL`**: The cloud model override to pass to the CLI. Leave empty to use the CLI's default model.
- **`USE_OLLAMA`**: Set to `true` to run against a local model via Ollama instead of a cloud API.
- **`OLLAMA_MODEL`**: The Ollama model to serve (e.g., `qwen2.5-coder:14b`).

For a full list of configuration variables and secrets, see [agent.config.example.env](file:///root/repos/actions-runner/_work/pr-agents-config/pr-agents-config/issue_3/agent.config.example.env).

### 2. On-the-fly Overrides in Issues and PRs
You can override the default CLI, model, or Ollama settings for a specific run directly in the issue description or in a comment on the issue or PR.

To do this, start the **very first line** of your issue description or comment with `/agent` followed by any of these override flags:
- `--cli <cli_name>` — dynamically switch the CLI tool (`antigravity`, `claude`, or `qwen`).
- `--model <model_name>` — dynamically change the model.
- `--ollama` — dynamically switch to running against a local model via Ollama.

The flags are only parsed if they appear on the very first line of the issue description or comment. Any text on subsequent lines is treated as instructions for the agent.

#### Examples:

- **Specify CLI and model when opening a new issue:**
  Start the issue description with:
  ```text
  /agent --cli qwen --model gemini-2.5-pro
  Please implement a custom parser for the input CSV files.
  ```

- **Specify CLI when commenting to iterate on an issue/PR:**
  Post a comment starting with:
  ```text
  /agent --cli claude
  Add unit tests for the newly added parser module.
  ```

- **Use a local Ollama model:**
  Start the description or comment with:
  ```text
  /agent --cli qwen --ollama --model qwen2.5-coder:14b
  Fix the type signature in server.py.
  ```

## Try it
1. Open an issue: *"Add a `--version` flag that prints the package version."*
2. Add the `agent` label (or skip if label-gating is off).
3. Watch the run under the **Actions** tab; a PR appears when it finishes.
4. You can also run manually: **Actions → Agent on issue → Run workflow**, and
   pass an issue number.
5. **Address feedback / iterate**: Post a comment starting with `/agent` (e.g., `/agent write tests for this too` or `/agent fix the typo in the import`) on the issue or the resulting PR. The agent will check out the existing branch, apply the feedback, and post its summary as a PR comment when finished.
6. **Override model or CLI**: You can override the default CLI or model for a specific run directly in the issue description or in a comment. See the [CLI and Model Selection](#cli-and-model-selection) section above for details and examples.

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
