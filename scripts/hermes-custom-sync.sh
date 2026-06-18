#!/usr/bin/env bash
# hermes-custom-sync.sh — keep BOTH Hermes runtimes on the hermes-custom fork.
#
# Problem this solves: the stock `hermes update` does `git reset --hard origin/main`,
# which DESTROYS the local fork patches. So it cannot be used on custom runtimes. This
# script is the sanctioned replacement: reconstruct hermes-custom on new upstream once,
# then deploy that exact branch into every runtime (so they never diverge).
#
# Runtimes:
#   FORK  ~/hermes-agent          — dev checkout (origin=NousResearch, fork=yours),
#                                    branch hermes-custom. Also the WORK agent runtime.
#   METAL ~/.hermes/hermes-agent  — the live/metal Helm runtime (was a plain-upstream clone).
# Both end up on the SAME hermes-custom commit; only their CONFIG differs (metal: no
# hosts.life; work: hosts.life). Code is shared, config is not.
#
# Usage:
#   bash hermes-custom-sync.sh status        # read-only: where is each runtime?
#   bash hermes-custom-sync.sh reconstruct    # FORK: backup + fetch upstream + rebase custom
#   bash hermes-custom-sync.sh deploy [--yes]  # push hermes-custom into BOTH runtimes + reinstall
#   bash hermes-custom-sync.sh all [--yes]     # reconstruct then deploy
#
# NEVER run `hermes update` on these runtimes — it resets to upstream and wipes the fork.
set -euo pipefail

FORK="$HOME/hermes-agent"
METAL="$HOME/.hermes/hermes-agent"
RUNTIMES=("$FORK" "$METAL")
CUSTOM="hermes-custom"
UPSTREAM="origin"                       # NousResearch, in the fork checkout
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
TS="$(date +%Y%m%d-%H%M%S)"
CMD="${1:-status}"; FLAG="${2:-}"

has_custom() { [ -f "$1/scripts/npm-audit-min-age.js" ] || [ -d "$1/scripts/git-hooks" ]; }   # custom-feature fingerprint
gitc() { git -C "$1" "${@:2}"; }

status() {
  echo "== hermes runtime status =="
  for d in "${RUNTIMES[@]}"; do
    [ -d "$d/.git" ] || { echo "  $d  (not a git repo)"; continue; }
    local br head behind cust
    br="$(gitc "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    head="$(gitc "$d" rev-parse --short HEAD 2>/dev/null)"
    cust=$(has_custom "$d" && echo yes || echo NO)
    echo "  $d"
    echo "    branch=$br head=$head custom-features=$cust"
  done
  echo "  (custom-features=NO on the live runtime means it drifted to plain upstream)"
}

reconstruct() {
  echo "== reconstruct: rebase $CUSTOM onto latest upstream (in $FORK) =="
  gitc "$FORK" rev-parse --verify "$CUSTOM" >/dev/null 2>&1 || { echo "ERR: $CUSTOM missing in $FORK"; exit 1; }
  gitc "$FORK" checkout "$CUSTOM"
  local bk="backup/${CUSTOM}-pre-sync-${TS}"
  gitc "$FORK" branch "$bk" && echo "  backup branch: $bk"
  gitc "$FORK" fetch "$UPSTREAM" --prune
  echo "  rebasing $CUSTOM onto $UPSTREAM/main ..."
  if ! gitc "$FORK" rebase "$UPSTREAM/main"; then
    echo "  !! REBASE CONFLICT. Resolve in $FORK:"
    echo "       cd $FORK; git status; <fix>; git add -A; git rebase --continue"
    echo "     (or 'git rebase --abort' to bail — your work is safe on $bk)"
    echo "     then re-run: bash $0 deploy --yes"
    exit 2
  fi
  echo "  OK -> $CUSTOM now at $(gitc "$FORK" rev-parse --short HEAD) on top of upstream"
}

reinstall() {  # editable reinstall into a runtime's own venv (covers dep/entrypoint changes)
  local d="$1"
  if [ -x "$d/venv/bin/python" ] && [ -x "$UV" ]; then
    echo "    reinstall (uv) into $d/venv ..."
    "$UV" pip install -e "$d" --python "$d/venv/bin/python" >/dev/null 2>&1 \
      && echo "    reinstall OK" || echo "    WARN: reinstall failed — run 'hermes doctor' / manual uv pip install -e"
  else
    echo "    (no venv/uv at $d — skipping reinstall; editable code is still live)"
  fi
}

deploy() {
  [ "$FLAG" = "--yes" ] || { echo "deploy mutates the LIVE runtimes. Re-run: bash $0 deploy --yes"; exit 1; }
  local target; target="$(gitc "$FORK" rev-parse "$CUSTOM")"
  echo "== deploy $CUSTOM ($(gitc "$FORK" rev-parse --short "$CUSTOM")) into both runtimes =="

  # FORK is already the source-of-truth checkout — just ensure it's on hermes-custom + reinstall.
  gitc "$FORK" checkout "$CUSTOM"; reinstall "$FORK"

  # METAL: convert/refresh to hermes-custom from the local fork checkout (no GitHub needed).
  echo "  metal runtime: $METAL"
  gitc "$METAL" tag -f "pre-custom-sync-${TS}" >/dev/null 2>&1 || true   # snapshot current detached HEAD
  gitc "$METAL" remote add customsrc "$FORK" 2>/dev/null || gitc "$METAL" remote set-url customsrc "$FORK"
  gitc "$METAL" fetch customsrc "$CUSTOM" --prune
  gitc "$METAL" checkout -B "$CUSTOM" "customsrc/$CUSTOM"
  if has_custom "$METAL"; then echo "    metal now has custom features ✓"; else echo "    WARN: custom features missing after checkout"; fi
  reinstall "$METAL"

  echo "  restart gateways to load new code:"
  echo "    launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway        # metal"
  echo "    launchctl kickstart -k gui/$(id -u)/ai.hermes.work-gateway   # work (if installed)"
  echo "DONE. Both runtimes at $CUSTOM. Reminder: NEVER 'hermes update' here — use this script."
}

case "$CMD" in
  status)      status ;;
  reconstruct) reconstruct ;;
  deploy)      deploy ;;
  all)         reconstruct; deploy ;;
  *)           echo "usage: $0 {status|reconstruct|deploy [--yes]|all [--yes]}"; exit 1 ;;
esac
