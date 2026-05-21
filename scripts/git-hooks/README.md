# Git Hooks — Supply-Chain Policy

This directory holds tracked git hooks for the `hermes-custom` fork. They are tracked (not in `.git/hooks/`) so the policy is versioned alongside the code it enforces.

## Enable

Per-clone, one-time:

```bash
git config core.hooksPath scripts/git-hooks
```

After this, every commit in this clone runs the hooks in this directory.

## What runs

### `pre-commit` — supply-chain age containment gate

Runs whenever a commit touches `pyproject.toml` or any `package-lock.json` in the tree. Blocks the commit if any declared or locked dependency is younger than `MIN_AGE_DAYS` (default 21).

This is a **containment layer**, not an ingress block. By the time the hook fires, `npm install` / `pip install` has already run on this machine and any malicious install-time payload has already executed. What the hook actually prevents is *propagation* of a compromised lockfile to teammates, CI, and production. The primary ingress defenses live in `ui-tui/.npmrc` (`ignore-scripts=true`) and in the v4 handoff doc's Phase 4 (`uv pip install --exclude-newer --require-hashes`).

#### Bypass

For emergencies and post-review exceptions:

```bash
SKIP_SUPPLY_CHAIN=1 git commit ...
```

Document any bypassed commit in `SUPPLY_CHAIN_EXCEPTIONS.md` with reason, reviewer, and expiry.

#### Tunable knob

The minimum age is controlled by `MIN_AGE_DAYS`:

```bash
MIN_AGE_DAYS=14 git commit ...   # more permissive (one-shot)
MIN_AGE_DAYS=45 git commit ...   # more conservative (one-shot)
```

To change the default repo-wide, edit `MIN_AGE_DAYS="${MIN_AGE_DAYS:-21}"` in the hook.

## Dependencies

The hook expects these tools to be available; install them once per machine:

| Tool | Used for | Install |
|---|---|---|
| `uv` | Python age audit | `brew install uv` |
| `node` | npm age audit | nvm or `brew install node` |

If a required tool is missing the hook fails fast with an actionable message.
