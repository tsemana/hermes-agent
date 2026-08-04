#!/usr/bin/env bash
# Docker health monitor for the Hermes fleet (Phase 3 decision 9, 2026-08-04).
#
# Why this exists: on 2026-08-04 all four Honcho Postgres containers were
# found PANIC-crash-looping because the Docker VM disk had silently filled
# (test-run debris). The agents fail open when memory dies, so nothing
# surfaced for hours. These two checks would have caught it days earlier:
#
#   1. Docker VM disk usage — measured INSIDE the VM (df in a container,
#      using an image that is already present so nothing is pulled).
#   2. Any container reporting (unhealthy) — the honcho databases carry
#      healthchecks; unhealthy == memory subsystem degraded.
#
# Alerting: macOS user notification + one line per run in the log.
# State file prevents spam: alert on ok->bad transition, re-alert at most
# every REALERT_SECONDS while bad, and announce recovery on bad->ok.
#
# Installed as a gui-domain LaunchAgent (no sudo):
#   ~/Library/LaunchAgents/ai.hermes.docker-health.plist  (StartInterval 1800)
#
# Read-only by design: this script never prunes, restarts, or fixes —
# it only observes and notifies. (Remediation is a human/agent decision.)

set -u

DISK_PCT_THRESHOLD="${DISK_PCT_THRESHOLD:-85}"
REALERT_SECONDS="${REALERT_SECONDS:-21600}"   # 6h
STATE_FILE="${HOME}/.hermes-unified/logs/docker-health.state"
LOG_FILE="${HOME}/.hermes-unified/logs/docker-health.log"
# An image guaranteed present on this host (honcho databases run it).
DF_IMAGE="${DF_IMAGE:-pgvector/pgvector:pg15}"
DOCKER=/usr/local/bin/docker
[ -x "$DOCKER" ] || DOCKER="$(command -v docker || echo /usr/local/bin/docker)"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

now() { /bin/date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(now) $*" >> "$LOG_FILE"; }

notify() {
  # $1 = title, $2 = body
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" 2>/dev/null || true
}

problems=""

# ── Check 0: is Docker itself up? ───────────────────────────────────────────
if ! "$DOCKER" info >/dev/null 2>&1; then
  problems="docker daemon unreachable"
else
  # ── Check 1: VM disk usage (df inside the VM) ─────────────────────────────
  pct="$("$DOCKER" run --rm --pull=never --entrypoint /bin/df "$DF_IMAGE" -P / 2>/dev/null \
        | /usr/bin/awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  if [ -z "${pct:-}" ]; then
    problems="disk probe failed (df container did not run)"
  elif [ "$pct" -ge "$DISK_PCT_THRESHOLD" ]; then
    problems="Docker VM disk at ${pct}% (threshold ${DISK_PCT_THRESHOLD}%)"
  fi

  # ── Check 2: unhealthy containers ─────────────────────────────────────────
  unhealthy="$("$DOCKER" ps --format '{{.Names}} {{.Status}}' 2>/dev/null \
              | /usr/bin/grep '(unhealthy)' | /usr/bin/awk '{print $1}' | /usr/bin/tr '\n' ' ')"
  if [ -n "${unhealthy:-}" ]; then
    [ -n "$problems" ] && problems="$problems; "
    problems="${problems}unhealthy: ${unhealthy% }"
  fi
fi

# ── State + alerting ────────────────────────────────────────────────────────
prev_state="ok"; prev_alert_ts=0
if [ -f "$STATE_FILE" ]; then
  prev_state="$(/usr/bin/awk 'NR==1' "$STATE_FILE" 2>/dev/null || echo ok)"
  prev_alert_ts="$(/usr/bin/awk 'NR==2' "$STATE_FILE" 2>/dev/null || echo 0)"
fi
epoch="$(/bin/date +%s)"

if [ -n "$problems" ]; then
  log "BAD: $problems"
  if [ "$prev_state" = "ok" ] || [ $((epoch - ${prev_alert_ts:-0})) -ge "$REALERT_SECONDS" ]; then
    notify "Hermes fleet: Docker health" "$problems"
    printf 'bad\n%s\n' "$epoch" > "$STATE_FILE"
  else
    printf 'bad\n%s\n' "$prev_alert_ts" > "$STATE_FILE"
  fi
  exit 0   # LaunchAgent: a failed check is a reported condition, not a crash
else
  log "ok (disk ${pct:-?}%)"
  if [ "$prev_state" = "bad" ]; then
    notify "Hermes fleet: Docker health" "Recovered — disk ${pct:-?}%, no unhealthy containers"
  fi
  printf 'ok\n0\n' > "$STATE_FILE"
fi
