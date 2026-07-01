# Agent Skills

Portable [Agent Skills](https://github.com/agentskills/agentskills) (open `SKILL.md`
format) that ship with JuLS-app. They're agent-agnostic — usable from Claude Code,
Cursor, Codex CLI, Gemini CLI, and any tool that supports the format — not tied to a
single vendor.

## Skills

- **[`juls-opt-problem-builder`](juls-opt-problem-builder/SKILL.md)** — guides you to
  translate a new constrained optimization problem into JuLS's CBLS invariant-DAG
  building blocks, register it as an experiment, add a sample and test, build the
  image, and verify it from Python. It explains the reasoning at each step, since the
  hard part is mapping the math (objective + constraints) onto the incremental DAG.

## Install

With the [`npx skills`](https://github.com/vercel-labs/skills) tool (hub at
[skills.sh](https://skills.sh)):

```bash
npx skills add stelong/JuLS-app
```

This pulls the skill(s) from this repo into your agent's skills directory; your agent
then invokes one automatically when a task matches its `description`. You can also just
copy a skill folder into your agent's skills path manually.
