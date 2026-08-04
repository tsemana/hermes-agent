# Supply-Chain Exceptions

## POLICY DECISION 2026-08-04: fork audit RETIRED — upstream's native gates govern

The fork-side 21-day age gate (`scripts/npm-audit-min-age.js`, the
`scripts/git-hooks/pre-commit` containment hook, and
`.github/workflows/dep-age-audit.yml`) was removed on 2026-08-04, decided by Tony
after the 0.20 upstream merge. Rationale: upstream now enforces the same
threat model natively, applied EARLIER (at install/resolve time, before any
lifecycle script could run) rather than at commit time, and running both gates
made every upstream merge trip the fork hook on upstream's own lockfile pins.

What governs now:

- **npm**: repo `.npmrc` → `min-release-age=14` with upstream's maintained
  per-package exclusion list (upstream-owned; we inherit their exclusions).
- **Python**: `pyproject.toml` `[tool.uv]` → `exclude-newer = "14 days"` with
  `exclude-newer-package` opt-outs (upstream-owned).
- **Lifecycle-script containment (still ours)**: `ui-tui/.npmrc` →
  `ignore-scripts=true`. Deliberately scoped to the TUI workspace only — a
  repo-root `ignore-scripts` would break the desktop's Electron native-dep
  postinstalls. This file is fork-owned and survives merges.

Tradeoffs accepted with this decision: the age floor drops 21 → 14 days, and
the per-package exclusion list is upstream's call, not ours. If either becomes
uncomfortable, the retired tooling is recoverable from git history
(`f99ba5e92`, `138a82d6d`, `419aeaa03`) — do not rebuild it from scratch.

The historical policy text below is retained for the audit trail.

---

Per-package exceptions to the publish-age policy formerly enforced by:

- `scripts/npm-audit-min-age.js` (auditor) — RETIRED
- `scripts/git-hooks/pre-commit` (containment gate) — RETIRED
- `.github/workflows/dep-age-audit.yml` (CI gate) — RETIRED
- v4 arm64 handoff doc (Phase 3.5 / 4 / 7 install gates)

Default policy was: every dependency must be at least `MIN_AGE_DAYS=21` days old at the time of install or commit. The threat model is per-package; **do not lower `MIN_AGE_DAYS` globally to bypass a single violation** — instead, document the specific package and version here.

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
| _(none currently)_ | | | | | | | |

## Retired exceptions

Move expired or no-longer-needed entries here for audit trail. Do not delete.

| Package | Ecosystem | Version | Approved | Retired | Why retired |
|---|---|---|---|---|---|
| upstream-merge npm set (js-yaml, ip-address, brace-expansion ×3, enhanced-resolve, flatted, acorn, minimatch, tar, eslint-utils, own-keys, p-map, typescript-eslint ×9, string-width-cjs, strip-ansi-cjs) | npm | as listed | 2026-08-03 | 2026-08-04 | Fork gate retired — upstream's native min-release-age=14 governs; entry no longer applies |

## Notes on the columns

- **Package**: canonical name (e.g., `mistralai`, `@esbuild/darwin-arm64`).
- **Ecosystem**: `pypi` or `npm`.
- **Version**: exact version being admitted (e.g., `2.4.7`). Not a range.
- **Reason**: 1–2 sentences. Link to CVE/advisory/upstream issue if applicable.
- **Reviewer**: a human who eyeballed the package's published code or its diff against the prior version. Self-review is fine on a single-developer fork; record yourself.
- **Approved**: date the exception was admitted, `YYYY-MM-DD`.
- **Expires**: date when this entry should be reconsidered. Past this date, CI should reject the package again.
- **Linked PR**: the PR that introduced the pin, for traceability.
