#!/bin/bash
set -e

# ============================================================
# Upstream codetitlan/openclaw-railway-template — original setup
# (preserved verbatim — DO NOT modify these lines)
# ============================================================
chown -R openclaw:openclaw /data
chmod 700 /data
if [ ! -d /data/.linuxbrew ]; then
  cp -a /home/linuxbrew/.linuxbrew /data/.linuxbrew
fi
rm -rf /home/linuxbrew/.linuxbrew
ln -sfn /data/.linuxbrew /home/linuxbrew/.linuxbrew

# ============================================================
# DashboardLim production hooks
# Scripts live in /app/infra (baked into image, version controlled)
# NOT in /data/.openclaw (which was the v1 stopgap location)
# Per-client opt-in scripts MAY live in /data/.openclaw with a
# file-guard so absence is a graceful no-op for other projects.
# ============================================================

# ============== BABYSITTER HOOK (begin) ==============
# Spawns WhatsApp bridge supervisor (PPID 1, user openclaw)
if [ -f /app/infra/bridge-babysitter.sh ]; then
  setsid gosu openclaw bash /app/infra/bridge-babysitter.sh \
    >/tmp/babysitter.boot.log 2>&1 < /dev/null &
fi
# ============== BABYSITTER HOOK (end) ================

# ============== GUARDIAN HOOK (begin) ==============
# Spawns bridge health-check loop, every 120s.
# sleep 30 at startup prevents race with babysitter on cold boot.
if [ -f /app/infra/bridge-guardian.sh ]; then
  setsid gosu openclaw bash -c \
    'sleep 30; while true; do bash /app/infra/bridge-guardian.sh >/dev/null 2>&1; sleep 120; done' \
    >/tmp/guardian.boot.log 2>&1 < /dev/null &
fi
# ============== GUARDIAN HOOK (end) ================

# ============== DRAFTER HOOK (begin) ==============
# Per-client opt-in: starts the OpenClaw drafter supervisor only if the
# client has installed it under /data/.openclaw/. Safe no-op for any
# project that doesn't ship the drafter (file simply isn't there).
# Drafter service: /data/.openclaw/drafter-service.js on :18791,
# backs the n8n /v1/draft endpoint with KB-aware reply drafts.
if [ -f /data/.openclaw/drafter-supervisor.sh ]; then
  setsid gosu openclaw bash /data/.openclaw/drafter-supervisor.sh \
    >/tmp/drafter.boot.log 2>&1 < /dev/null &
fi
# ============== DRAFTER HOOK (end) ================

# ============================================================
# Upstream's exec line — MUST be the last line of the script
# ============================================================
exec tini -- gosu openclaw node src/server.js
