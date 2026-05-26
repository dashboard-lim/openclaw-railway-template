#!/usr/bin/env bash
# bridge-babysitter.sh - zero-cost persistent supervisor for WhatsApp bridges.
# Respawns ONLY a bridge whose HTTP port is fully unreachable, via each
# bridge own start-bridge.sh (saved /data session -> no re-pair). No API
# tokens, no cron-pulse writes. Survives gateway restart (reparents to tini).
REG=/data/.openclaw/whatsapp-bridges.yaml
LOGDIR=/tmp/openclaw-wa-bridge
LOG="$LOGDIR/babysitter.log"
INTERVAL="${BABYSITTER_INTERVAL:-15}"
mkdir -p "$LOGDIR"
exec 9>/data/.openclaw/bridge-babysitter.lock
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { echo "$(date -u +%FT%TZ) already_running exit" >>"$LOG"; exit 0; }
fi
echo $$ > /data/.openclaw/bridge-babysitter.pid
echo "$(date -u +%FT%TZ) babysitter_start pid=$$ interval=${INTERVAL}s" >>"$LOG"
while true; do
  if [ -f "$REG" ]; then
    while read -r home port en; do
      [ "$en" = "true" ] || continue
      [ -n "$home" ] && [ -n "$port" ] || continue
      st=$(curl -s --max-time 3 "http://localhost:$port/status" 2>/dev/null)
      if [ -z "$st" ]; then
        if [ -x "$home/start-bridge.sh" ]; then
          nohup "$home/start-bridge.sh" >>"$LOGDIR/bridge-$port.log" 2>&1 &
          echo "$(date -u +%FT%TZ) respawn port=$port home=$home pid=$!" >>"$LOG"
        else
          echo "$(date -u +%FT%TZ) WARN no start-bridge.sh for $home port=$port" >>"$LOG"
        fi
      fi
    done < <(awk '
      /^[[:space:]]*-[[:space:]]*id:/ { if(have)print home" "port" "en; home="";port="";en="false"; have=1 }
      /^[[:space:]]*port:/ {port=$2}
      /^[[:space:]]*home:/ {home=$2}
      /^[[:space:]]*enabled:/ {en=$2}
      END{ if(have)print home" "port" "en }
    ' "$REG")
  fi
  # Keep the n8n API forwarder (18790 -> gateway 18789) alive too.
  FWD=/data/.openclaw/api-forwarder.js
  if [ -f "$FWD" ]; then
    fcode=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://localhost:18790/v1/models" 2>/dev/null)
    if [ -z "$fcode" ] || [ "$fcode" = "000" ]; then
      setsid node "$FWD" >/data/.openclaw/api-forwarder.log 2>&1 </dev/null &
      echo "$(date -u +%FT%TZ) respawn forwarder pid=$!" >>"$LOG"
    fi
  fi
  sleep "$INTERVAL"
done
