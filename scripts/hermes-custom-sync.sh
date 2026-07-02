#!/usr/bin/env bash
# hermes-custom-sync.sh — keep the Hermes runtime on the hermes-custom fork.
#
# Problem this solves: the stock `hermes update` does `git reset --hard origin/main`,
# which DESTROYS the local fork commits. So it cannot be used on a custom runtime. This
# script is the sanctioned replacement: reconstruct hermes-custom on new upstream, push
# it to your GitHub fork for durability, and editable-reinstall it into the venv.
#
# TOPOLOGY (post Aegis re-home, 2026-06-22) — ONE shared checkout, two daemons:
#   ~/hermes-agent  — the single source-of-truth checkout, branch hermes-custom.
#       remotes: origin = NousResearch (upstream)   fork = github.com/tsemana (backup)
#       venv: ~/hermes-agent/venv  (editable install — code edits are live)
#   BOTH agents run THIS checkout's venv python; only their CONFIG differs:
#       Aegis  (life/cloud)  runs as hermes-metal, system daemon ai.hermes.metal-gateway,
#                            HERMES_HOME=/Users/hermes-metal/.hermes  (no hosts.life)
#       Helm   (work/local)  runs as hermes-work,  system daemon ai.hermes.work-gateway,
#                            HERMES_HOME=/Users/hermes-work/.hermes   (hosts.life set)
#   So code is shared, config+identity are per-daemon. There is NO separate metal code
#   checkout anymore (the old ~/.hermes/hermes-agent is deprecated and unused by the
#   daemons — do not deploy into it).
#
# POLICY (2026-07-01): the checkout is WRITABLE by two identities — tonysemana (owner) and
#   hermes-metal (Aegis), the latter via an inherited FS ACL (macOS `chmod +a`). Helm
#   (hermes-work) is deliberately NOT granted write and stays read-only. So EITHER you (in
#   your own shell) OR Aegis (in its own session, running as hermes-metal) can run this and
#   self-update the shared fork. The guard below refuses only callers with no write access
#   (e.g. Helm) instead of the confusing git/permission error.
#   One-time git setup for a NEW writer identity (Aegis does this once, as itself, no sudo):
#     git config --global --add safe.directory /Users/tonysemana/hermes-agent
#     git config --global user.name  "Aegis" ; git config --global user.email "aegis@hermes.local"
#   (safe.directory is required because .git is owned by tonysemana; user.name/email are
#    needed so `git rebase --continue` can commit conflict resolutions.)
#
# Usage:
#   bash hermes-custom-sync.sh status                 # read-only: where is the checkout + GitHub?
#   bash hermes-custom-sync.sh reconstruct            # backup branch + fetch upstream + rebase custom
#   bash hermes-custom-sync.sh backup [--yes]         # push hermes-custom to GitHub fork (force-w/-lease)
#   bash hermes-custom-sync.sh deploy [--yes]         # reinstall venv + print daemon restart commands
#   bash hermes-custom-sync.sh all [--yes]            # reconstruct -> backup -> deploy
#
# NEVER run `hermes update` here — it resets to upstream and wipes the fork.
set -euo pipefail

FORK="$HOME/hermes-agent"                # the single shared checkout
CUSTOM="hermes-custom"
UPSTREAM="origin"                        # NousResearch
BACKUP_REMOTE="fork"                     # github.com/tsemana/hermes-agent
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
TS="$(date +%Y%m%d-%H%M%S)"
CMD="${1:-status}"; FLAG="${2:-}"

has_custom() { [ -f "$1/scripts/npm-audit-min-age.js" ] || [ -d "$1/scripts/git-hooks" ]; }  # custom-feature fingerprint
gitc() { git -C "$1" "${@:2}"; }

# --- writer guard -------------------------------------------------------------------
# Writers = tonysemana (owner) + hermes-metal (Aegis, via inherited ACL). Helm
# (hermes-work) has no write and is refused here by design. Two checks: (1) can this
# user actually write .git; (2) does git accept the repo (dubious-ownership needs a
# one-time safe.directory in the caller's own git config — see header).
require_writer() {
  local me; me="$(id -un)"
  if [ ! -w "$FORK/.git" ]; then
    echo "REFUSING: '$1' — '$me' has no write access to $FORK/.git." >&2
    echo "  Writers: tonysemana (owner) + hermes-metal (Aegis, via ACL). NOT hermes-work (Helm)." >&2
    echo "  If '$me' SHOULD write, grant it: chmod +a \"$me allow ...,file_inherit,directory_inherit\" $FORK" >&2
    exit 3
  fi
  if ! gitc "$FORK" rev-parse --git-dir >/dev/null 2>&1; then
    echo "REFUSING: git won't operate on $FORK as '$me' (likely dubious ownership)." >&2
    echo "  One-time fix, run as '$me' (no sudo): git config --global --add safe.directory $FORK" >&2
    exit 3
  fi
}

status() {
  echo "== hermes runtime status =="
  if [ ! -d "$FORK/.git" ]; then echo "  $FORK  (not a git repo)"; return; fi
  local br head cust ahead behind fork_head sync
  br="$(gitc "$FORK" rev-parse --abbrev-ref HEAD)"
  head="$(gitc "$FORK" rev-parse --short HEAD)"
  cust=$(has_custom "$FORK" && echo yes || echo NO)
  echo "  checkout: $FORK"
  echo "    branch=$br head=$head custom-features=$cust"
  # vs upstream
  if gitc "$FORK" rev-parse --verify "$UPSTREAM/main" >/dev/null 2>&1; then
    read -r behind ahead < <(gitc "$FORK" rev-list --left-right --count "$UPSTREAM/main...$CUSTOM" 2>/dev/null | awk '{print $1, $2}')
    echo "    vs $UPSTREAM/main: ahead $ahead (custom commits), behind $behind"
  fi
  # vs GitHub backup
  fork_head="$(gitc "$FORK" rev-parse --short "$BACKUP_REMOTE/$CUSTOM" 2>/dev/null || echo '<none>')"
  if [ "$fork_head" = "$head" ]; then sync="in sync ✓"; else sync="OUT OF SYNC — run: bash $0 backup --yes"; fi
  echo "    GitHub $BACKUP_REMOTE/$CUSTOM: $fork_head  ($sync)"
  echo "    (custom-features=NO means the checkout drifted to plain upstream — reconstruct)"
  echo
  echo "  daemons running this code (restart after deploy):"
  echo "    sudo launchctl kickstart -k system/ai.hermes.metal-gateway   # Aegis  :8642"
  echo "    sudo launchctl kickstart -k system/ai.hermes.work-gateway    # Helm   :8652"
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
    echo "     then re-run: bash $0 backup --yes && bash $0 deploy --yes"
    exit 2
  fi
  echo "  OK -> $CUSTOM now at $(gitc "$FORK" rev-parse --short HEAD) on top of upstream"
  echo "  NOTE: rebase rewrote history; back it up with: bash $0 backup --yes"
}

backup() {  # push hermes-custom to the GitHub fork for durability
  [ "$FLAG" = "--yes" ] || { echo "backup pushes to GitHub ($BACKUP_REMOTE). Re-run: bash $0 backup --yes"; exit 1; }
  gitc "$FORK" rev-parse --verify "$CUSTOM" >/dev/null 2>&1 || { echo "ERR: $CUSTOM missing"; exit 1; }
  echo "== backup: push $CUSTOM -> $BACKUP_REMOTE =="
  # --force-with-lease: safe after a reconstruct rebase; refuses if the remote moved unexpectedly.
  gitc "$FORK" push --force-with-lease "$BACKUP_REMOTE" "$CUSTOM:$CUSTOM"
  echo "  GitHub $BACKUP_REMOTE/$CUSTOM now at $(gitc "$FORK" rev-parse --short "$BACKUP_REMOTE/$CUSTOM" 2>/dev/null)"
}

reinstall() {  # editable reinstall into the runtime venv (covers dep/entrypoint changes)
  local d="$FORK"
  [ -x "$d/venv/bin/python" ] || { echo "    (no venv at $d — skipping reinstall; editable code is still live)"; return; }
  if [ -x "$UV" ]; then                          # prefer uv when the caller has it (tonysemana)
    echo "    reinstall (uv) into $d/venv ..."
    "$UV" pip install -e "$d" --python "$d/venv/bin/python" >/dev/null 2>&1 \
      && { echo "    reinstall OK (uv)"; return; } || echo "    uv reinstall failed — falling back to venv pip"
  fi
  echo "    reinstall (venv pip) into $d/venv ..."  # fallback so Aegis (hermes-metal, no uv) still works
  "$d/venv/bin/python" -m pip install -e "$d" >/dev/null 2>&1 \
    && echo "    reinstall OK (pip)" || echo "    WARN: reinstall failed — run 'hermes doctor' / manual pip install -e"
}

deploy() {
  [ "$FLAG" = "--yes" ] || { echo "deploy reinstalls the LIVE venv both daemons share. Re-run: bash $0 deploy --yes"; exit 1; }
  echo "== deploy $CUSTOM ($(gitc "$FORK" rev-parse --short "$CUSTOM")) =="
  gitc "$FORK" checkout "$CUSTOM"
  if has_custom "$FORK"; then echo "  custom features present ✓"; else echo "  WARN: custom features missing — run reconstruct"; fi
  reinstall
  echo
  echo "  restart BOTH daemons to load the new code (need sudo):"
  echo "    sudo launchctl kickstart -k system/ai.hermes.metal-gateway   # Aegis"
  echo "    sudo launchctl kickstart -k system/ai.hermes.work-gateway    # Helm"
  echo "DONE. Reminder: NEVER 'hermes update' here — use this script."
}

case "$CMD" in
  status)      require_writer "$CMD"; status ;;
  reconstruct) require_writer "$CMD"; reconstruct ;;
  backup)      require_writer "$CMD" "$FLAG"; backup ;;
  deploy)      require_writer "$CMD" "$FLAG"; deploy ;;
  all)         require_writer "$CMD" "$FLAG"
               [ "$FLAG" = "--yes" ] || { echo "all mutates GitHub + the live venv. Re-run: bash $0 all --yes"; exit 1; }
               reconstruct; backup; deploy ;;
  *)           echo "usage: $0 {status|reconstruct|backup [--yes]|deploy [--yes]|all [--yes]}"; exit 1 ;;
esac
