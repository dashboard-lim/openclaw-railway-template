#!/usr/bin/env bash
# bridge-guardian.sh _ zero-AI-cost WhatsApp bridge health guardian.
#
# Replaces the AI-based `bridge-guardian-2min` OpenClaw cron with pure shell.
# Health-checks every ENABLED bridge in /data/.openclaw/whatsapp-bridges.yaml,
# restarts any that have crashed (via each home's start-bridge.sh _ the same
# primitive bridge-babysitter.sh uses), and records the result to a
# human-readable log + one machine-readable cron-pulse.jsonl line.
#
# Read-only consumers (NEVER modified here): whatsapp-bridges.yaml,
# bridge-babysitter.sh, start-bridge.sh, entrypoint.sh.
# No Anthropic/Claude/OpenClaw brain API is ever called -> zero AI cost.

set -euo pipefail

# ---- config ---------------------------------------------------------------
REG=/data/.openclaw/whatsapp-bridges.yaml
LOGDIR=/data/.openclaw/logs
LOG="$LOGDIR/bridge-guardian.log"
PULSE=/data/workspace/memory/cron-pulse.jsonl
MARKER=/data/.openclaw/bridge-guardian-migrated.marker
RESPAWN_LOGDIR=/tmp/openclaw-wa-bridge
CRON_NAME="bridge-guardian-2min"
HEALTH_TIMEOUT=5          # seconds per /status probe
WAIT_AFTER_RESTART=5      # single shared wait before re-checking
LOG_MAX_BYTES=10485760    # 10 MB
LOG_MAX_AGE=604800        # 7 days

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_ms() { date +%s%3N; }
START_MS=$(now_ms)
RUN_MARKER="FRESH-$(date +%s)"

mkdir -p "$LOGDIR" "$RESPAWN_LOGDIR"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bridge-guardian.XXXXXX")
RESULTS="$TMP/results"   # id|port|phone|status|action|circuit  (one line per enabled bridge)
: > "$RESULTS"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

logln() { printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG"; }

# ---- log rotation (size > 10MB OR mtime older than 7 days) ----------------
rotate_log() {
  [ -f "$LOG" ] || return 0
  local size now mtime age
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  now=$(date +%s)
  mtime=$(stat -c %Y "$LOG" 2>/dev/null || echo "$now")
  age=$(( now - mtime ))
  if [ "$size" -gt "$LOG_MAX_BYTES" ] || [ "$age" -gt "$LOG_MAX_AGE" ]; then
    mv "$LOG" "$LOGDIR/bridge-guardian-$(date -u +%Y%m%d).log" 2>/dev/null || true
  fi
}
rotate_log

# ---- pulse writer (superset: existing schema + requested fields) ----------
# Existing downstream fields kept: bridges[], duration_ms, marker.
# Requested fields added:          action, detail, status.
write_pulse() {
  local overall=$1 detail=$2 dur=$3 tsnow
  tsnow=$(ts)
  if command -v python3 >/dev/null 2>&1; then
    RESULTS_FILE="$RESULTS" TSNOW="$tsnow" CRON="$CRON_NAME" DETAIL="$detail" \
    OVERALL="$overall" DUR="$dur" MARK="$RUN_MARKER" PULSE_FILE="$PULSE" \
    python3 - <<'PY' || return 1
import json, os
bridges = []
rf = os.environ["RESULTS_FILE"]
try:
    with open(rf) as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if not ln:
                continue
            parts = ln.split("|")
            if len(parts) != 6:
                continue
            bid, port, phone, st, act, circ = parts
            try:
                port = int(port)
            except ValueError:
                pass
            bridges.append({"id": bid, "port": port, "status": st,
                            "phone": phone, "action": act, "circuit": circ})
except FileNotFoundError:
    pass
line = {
    "timestamp": os.environ["TSNOW"],
    "cron": os.environ["CRON"],
    "action": "health-check",
    "detail": os.environ["DETAIL"],
    "status": os.environ["OVERALL"],
    "bridges": bridges,
    "duration_ms": int(os.environ["DUR"]),
    "marker": os.environ["MARK"],
}
with open(os.environ["PULSE_FILE"], "a") as out:
    out.write(json.dumps(line) + "\n")
PY
  else
    # pure-shell fallback (detail/status contain no double quotes)
    local bjson="" id port phone st act circ obj
    while IFS='|' read -r id port phone st act circ; do
      [ -n "${id:-}" ] || continue
      obj="{\"id\":\"$id\",\"port\":$port,\"status\":\"$st\",\"phone\":\"$phone\",\"action\":\"$act\",\"circuit\":\"$circ\"}"
      bjson="${bjson:+$bjson,}$obj"
    done < "$RESULTS"
    printf '{"timestamp":"%s","cron":"%s","action":"health-check","detail":"%s","status":"%s","bridges":[%s],"duration_ms":%s,"marker":"%s"}\n' \
      "$tsnow" "$CRON_NAME" "$detail" "$overall" "$bjson" "$dur" "$RUN_MARKER" >> "$PULSE"
  fi
}

# ---- defensive: registry missing -> error pulse + exit 1 ------------------
if [ ! -f "$REG" ]; then
  logln "=== bridge-guardian run start ==="
  logln "ERROR: registry $REG missing _ cannot enumerate bridges"
  dur=$(( $(now_ms) - START_MS ))
  logln "=== run complete (status: error, duration: $(awk "BEGIN{printf \"%.1f\", $dur/1000}")s) ==="
  write_pulse "error" "registry $REG missing" "$dur" || true
  exit 1
fi

# ---- parse ENABLED bridges (awk, same shape babysitter uses) --------------
# emits: id|port|home|enabled|phone   then we keep enabled==true
parse_registry() {
  awk '
    /^[[:space:]]*-[[:space:]]*id:/      { if(have) print id"|"port"|"home"|"en"|"phone; id=$3; port=""; home=""; en="false"; phone=""; have=1 }
    /^[[:space:]]*port:/                 { port=$2 }
    /^[[:space:]]*home:/                 { home=$2 }
    /^[[:space:]]*enabled:/              { en=$2 }
    /^[[:space:]]*expected_jid_phone:/   { phone=$2 }
    END { if(have) print id"|"port"|"home"|"en"|"phone }
  ' "$REG"
}

# parse a /status JSON body -> value of "status" field
status_field() {
  local j=$1
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$j" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")' 2>/dev/null || true
  else
    printf '%s' "$j" | grep -o "\"status\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
      | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' || true
  fi
}

# probe a single port; writes "<body>\n<http_code>" to $1
probe() {
  local outfile=$1 port=$2
  curl -s -m "$HEALTH_TIMEOUT" -w $'\n%{http_code}' "http://localhost:$port/status" \
    > "$outfile" 2>/dev/null || printf '\n000' > "$outfile"
}

logln "=== bridge-guardian run start ==="

# collect enabled bridges into arrays
declare -a B_ID B_PORT B_HOME B_PHONE
while IFS='|' read -r id port home en phone; do
  [ "${en:-}" = "true" ] || continue
  [ -n "${port:-}" ] || continue
  phone=$(printf '%s' "${phone:-}" | tr -d '"')
  B_ID+=("$id"); B_PORT+=("$port"); B_HOME+=("$home"); B_PHONE+=("$phone")
done < <(parse_registry)

N=${#B_PORT[@]}
if [ "$N" -eq 0 ]; then
  logln "Enabled bridges: (none)"
  dur=$(( $(now_ms) - START_MS ))
  logln "=== run complete (status: ok, duration: $(awk "BEGIN{printf \"%.1f\", $dur/1000}")s) ==="
  write_pulse "ok" "0 bridges enabled, nothing to check" "$dur" || true
  [ -f "$MARKER" ] || touch "$MARKER" 2>/dev/null || true
  exit 0
fi

PORTS_CSV=$(IFS=, ; echo "${B_PORT[*]}")
logln "Enabled bridges: ${PORTS_CSV//,/, }"

# ---- phase 1: parallel health checks --------------------------------------
hc_pids=()
for i in "${!B_PORT[@]}"; do
  probe "$TMP/check_${B_PORT[$i]}" "${B_PORT[$i]}" &
  hc_pids+=("$!")
done
for p in "${hc_pids[@]}"; do wait "$p" 2>/dev/null || true; done

declare -a UNHEALTHY_IDX=()
declare -a FINAL_STATUS FINAL_ACTION FINAL_CIRCUIT
for i in "${!B_PORT[@]}"; do
  port=${B_PORT[$i]}
  raw=$(cat "$TMP/check_$port" 2>/dev/null || printf '\n000')
  code=$(printf '%s' "$raw" | tail -n1)
  body=$(printf '%s' "$raw" | sed '$d')
  sfield=$(status_field "$body")
  if [ "$code" = "200" ] && [ "$sfield" = "connected" ]; then
    logln "[$port] Health check... HTTP 200, status:connected -> HEALTHY"
    FINAL_STATUS[$i]="connected"; FINAL_ACTION[$i]="none"; FINAL_CIRCUIT[$i]="closed"
  else
    if [ "$code" = "000" ]; then
      logln "[$port] Health check... HTTP 000 (timeout/unreachable) -> UNHEALTHY"
    else
      logln "[$port] Health check... HTTP $code, status:${sfield:-none} -> UNHEALTHY"
    fi
    FINAL_STATUS[$i]="${sfield:-unreachable}"; FINAL_ACTION[$i]="restart-failed"; FINAL_CIRCUIT[$i]="open"
    UNHEALTHY_IDX+=("$i")
  fi
done

# ---- phase 2: restart all unhealthy (parallel spawn) ----------------------
declare -a RESTART_RC
if [ "${#UNHEALTHY_IDX[@]}" -gt 0 ]; then
  for i in "${UNHEALTHY_IDX[@]}"; do
    port=${B_PORT[$i]}; home=${B_HOME[$i]}
    logln "[$port] Attempting restart via babysitter primitive (start-bridge.sh)..."
    if [ -x "$home/start-bridge.sh" ]; then
      setsid nohup "$home/start-bridge.sh" >> "$RESPAWN_LOGDIR/bridge-$port.log" 2>&1 < /dev/null &
      disown 2>/dev/null || true
      RESTART_RC[$i]=0
      logln "[$port] Restart returned exit 0, waiting ${WAIT_AFTER_RESTART}s..."
    else
      RESTART_RC[$i]=1
      logln "[$port] Restart returned exit 1 (no executable start-bridge.sh at $home), waiting ${WAIT_AFTER_RESTART}s..."
    fi
  done

  # ---- single shared wait, then phase 3: parallel re-check ----------------
  sleep "$WAIT_AFTER_RESTART"
  rc_pids=()
  for i in "${UNHEALTHY_IDX[@]}"; do
    probe "$TMP/recheck_${B_PORT[$i]}" "${B_PORT[$i]}" &
    rc_pids+=("$!")
  done
  for p in "${rc_pids[@]}"; do wait "$p" 2>/dev/null || true; done

  for i in "${UNHEALTHY_IDX[@]}"; do
    port=${B_PORT[$i]}
    raw=$(cat "$TMP/recheck_$port" 2>/dev/null || printf '\n000')
    code=$(printf '%s' "$raw" | tail -n1)
    body=$(printf '%s' "$raw" | sed '$d')
    sfield=$(status_field "$body")
    if [ "$code" = "200" ] && [ "$sfield" = "connected" ]; then
      logln "[$port] Re-check... HTTP 200, status:connected -> RECOVERED"
      FINAL_STATUS[$i]="connected"; FINAL_ACTION[$i]="restarted"; FINAL_CIRCUIT[$i]="closed"
    else
      if [ "$code" = "000" ]; then
        logln "[$port] Re-check... HTTP 000 (timeout/unreachable) -> STILL UNHEALTHY"
      else
        logln "[$port] Re-check... HTTP $code, status:${sfield:-none} -> STILL UNHEALTHY"
      fi
      logln "[$port] FAILED _ manual intervention needed"
      FINAL_STATUS[$i]="${sfield:-unreachable}"; FINAL_ACTION[$i]="restart-failed"; FINAL_CIRCUIT[$i]="open"
    fi
  done
fi

# ---- tally + build results file for pulse ---------------------------------
recovered=0; failed=0
for i in "${!B_PORT[@]}"; do
  case "${FINAL_ACTION[$i]}" in
    restarted)       recovered=$((recovered+1)) ;;
    restart-failed)  failed=$((failed+1)) ;;
  esac
  printf '%s|%s|%s|%s|%s|%s\n' \
    "${B_ID[$i]}" "${B_PORT[$i]}" "${B_PHONE[$i]}" \
    "${FINAL_STATUS[$i]}" "${FINAL_ACTION[$i]}" "${FINAL_CIRCUIT[$i]}" >> "$RESULTS"
done

# overall status + detail
plural=""; [ "$N" -ne 1 ] && plural="s"
prefix="$N bridge$plural enabled ($PORTS_CSV)"
if [ "$failed" -gt 0 ]; then
  OVERALL="error";    DETAIL="$prefix, $failed restart attempt$([ "$failed" -ne 1 ] && echo s) failed"
elif [ "$recovered" -gt 0 ]; then
  OVERALL="degraded"; DETAIL="$prefix, $recovered restarted and recovered"
else
  OVERALL="ok";       DETAIL="$prefix, all healthy"
fi

DUR=$(( $(now_ms) - START_MS ))
DUR_S=$(awk "BEGIN{printf \"%.1f\", $DUR/1000}")
logln "=== run complete (status: $OVERALL, duration: ${DUR_S}s) ==="

write_pulse "$OVERALL" "$DETAIL" "$DUR" || logln "WARN: failed to write cron-pulse line"

# migration marker on first successful (non-error) run
if [ "$OVERALL" != "error" ] && [ ! -f "$MARKER" ]; then
  touch "$MARKER" 2>/dev/null || true
fi

# exit 0 if all healthy/recovered, 1 if any restart failed
[ "$OVERALL" = "error" ] && exit 1 || exit 0
