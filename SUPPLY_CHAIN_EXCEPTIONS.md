# Supply-Chain Exceptions

Per-package exceptions to the publish-age policy enforced by:

- `scripts/npm-audit-min-age.js` (auditor)
- `scripts/git-hooks/pre-commit` (containment gate)
- `.github/workflows/dep-age-audit.yml` (CI gate)
- v4 arm64 handoff doc (Phase 3.5 / 4 / 7 install gates)

Default policy: every dependency must be at least `MIN_AGE_DAYS=21` days old at the time of install or commit. The threat model is per-package; **do not lower `MIN_AGE_DAYS` globally to bypass a single violation** — instead, document the specific package and version here.

## When to add an entry

You need an exception when one of these is true:

1. A package legitimately requires a recent version for a security fix that landed inside the policy window (e.g., a CVE patched 5 days ago).
2. A package was recently quarantined upstream and `uv`/npm cannot resolve any older version that satisfies constraints, but you have a verified-clean alternative pin to fall back to.
3. The publish-age signal is being applied to a package where it doesn't fit the threat model (e.g., a workspace-internal package mistakenly being checked — though the auditor should already skip these).

What does NOT justify an entry:

- Convenience / "I want the latest"
- A pattern of repeated bypasses across many packages — that's a signal to revisit the global `MIN_AGE_DAYS` setting, not to accumulate exceptions
- Anything the v4 doc's Remediation Appendix A or B can resolve without an exception (pin to an older version, add `overrides`, etc. — try those first)

## How to add an entry

1. Add a row to the table below.
2. Open a PR with the exception entry and the corresponding `pyproject.toml` / `package.json` change in the same commit. CI will still run the age audit but the entry serves as the documented justification when the human reviewer approves.
3. Set an `Expires` date — typically 30–90 days out. When the entry expires, either remove the pin (the package version should be old enough by then) or open a new PR justifying the renewal.

To temporarily bypass a single commit's check (only for emergencies after eyes-open review):

```bash
SKIP_SUPPLY_CHAIN=1 git commit ...
```

If you use `SKIP_SUPPLY_CHAIN=1`, add a retroactive entry here within 24 hours.

## Active exceptions

| Package | Ecosystem | Version | Reason | Reviewer | Approved | Expires | Linked PR |
|---|---|---|---|---|---|---|---|
| js-yaml@4.3.1, ip-address@10.4.0, brace-expansion@{1.1.18, 2.1.4, 5.0.9}, enhanced-resolve@5.24.5, flatted@3.4.4, acorn@8.18.0, minimatch@10.2.6, tar@7.5.22, @eslint-community/eslint-utils@4.10.1, own-keys@1.0.2, p-map@7.0.6, typescript-eslint@8.65.0 (+8 @typescript-eslint/* @8.65.0), string-width-cjs@4.2.3, strip-ansi-cjs@6.0.1 | npm | as listed | Upstream merge 2026-08-03 (origin/main @ 91937a6dc): versions come from upstream's `nix/node-gyp-11-4-0-package-lock.json`, not our choices; all are desktop/build tooling, none run in the Python daemons. Re-pinning inside the merge would diverge from upstream. Desktop rebuild is deferred (Node 26) — revisit before that build. | Tony (pending) | 2026-08-03 | 2026-09-03 | upstream merge, see UPSTREAM-UPDATE-PLAN.md |

## Retired exceptions

Move expired or no-longer-needed entries here for audit trail. Do not delete.

| Package | Ecosystem | Version | Approved | Retired | Why retired |
|---|---|---|---|---|---|
| _(none)_ | | | | | |

## Notes on the columns

- **Package**: canonical name (e.g., `mistralai`, `@esbuild/darwin-arm64`).
- **Ecosystem**: `pypi` or `npm`.
- **Version**: exact version being admitted (e.g., `2.4.7`). Not a range.
- **Reason**: 1–2 sentences. Link to CVE/advisory/upstream issue if applicable.
- **Reviewer**: a human who eyeballed the package's published code or its diff against the prior version. Self-review is fine on a single-developer fork; record yourself.
- **Approved**: date the exception was admitted, `YYYY-MM-DD`.
- **Expires**: date when this entry should be reconsidered. Past this date, CI should reject the package again.
- **Linked PR**: the PR that introduced the pin, for traceability.
