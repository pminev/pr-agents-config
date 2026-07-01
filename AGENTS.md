# Agent instructions

Shared guidance for any coding agent (Claude Code, Qwen Code, Antigravity, …)
working in this repository. `CLAUDE.md` points here so every tool reads the same
rules.

## Working style
- Make the smallest change that fully solves the issue. Don't refactor unrelated
  code or reformat files you didn't need to touch.
- Match the surrounding code's style, naming, and structure.
- Prefer editing existing files over adding new ones unless the task needs them.

## Verification (required)
Before finishing, run whatever the repo provides and report results honestly:
- Tests (e.g. `npm test`, `pytest`, `cargo test`, `go test ./...`).
- Linters / type checks / formatters.
- A build, if there is one.

If a check fails and you can't fix it, leave the code in the best state you can
and describe the failure in your summary — never claim a passing state you
didn't observe.

## Per-repo customization
When you reuse this config in a real project, extend this file with:
- How to install deps, run tests, and build.
- Architecture notes and directories to know about.
- Anything the agent must NOT touch (generated files, secrets, migrations).

## Preview / hosting
If this project can be previewed (e.g. a web app), provide an executable
`scripts/preview.sh` that starts it or deploys a preview and prints a URL. The
pipeline runs it automatically after the agent finishes and folds its output
into the PR body so reviewers get a link. Keep it non-interactive.
