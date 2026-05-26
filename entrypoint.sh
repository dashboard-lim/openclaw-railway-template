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

# ============================================================
# Upstream's exec line — MUST be the last line of the script
# ============================================================
exec tini -- gosu openclaw node src/server.js
