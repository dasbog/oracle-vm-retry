#!/usr/bin/env bash
# Tries to launch the VM from the saved Oracle instance configuration.
# Exit 0 = VM created / already exists / just out of capacity (try again next run).
# Exit 1 = a real problem worth an email (bad key, wrong ID, free limit hit...).
set -u
ATTEMPTS="${ATTEMPTS:-100000}"  # effectively: keep trying until MAX_SECONDS
MAX_SECONDS="${MAX_SECONDS:-20400}"  # ~5h40m per run, inside the 6h job limit
PAUSE="${PAUSE:-60}"          # seconds between tries
CFG="${INSTANCE_CONFIG_ID:-}"

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }
msg() { python3 -c 'import json,sys
t=sys.stdin.read(); i=t.find("{")
try: d=json.loads(t[i:]); print(d.get("code",""), "-", d.get("message",""))
except Exception: print(t.strip().splitlines()[-1] if t.strip() else "no output")'; }

if [ -z "$CFG" ] || ! grep -q "PRIVATE KEY" ~/.oci/key.pem 2>/dev/null; then
  log "Secrets are not set up yet. Skipping this run."; echo "result=none" >> "$GITHUB_OUTPUT"; exit 0
fi

CFG_JSON=$(oci compute-management instance-configuration get --instance-configuration-id "$CFG" 2>/tmp/cfg.err) \
  || { log "Could not read the instance configuration (check the secrets):"; msg < /tmp/cfg.err; exit 1; }
CFG_JSON="{${CFG_JSON#*\{}"   # drop any warning text before the JSON
COMPARTMENT=$(echo "$CFG_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin)["data"];ld=(d.get("instance-details") or {}).get("launch-details") or {};print(ld.get("compartment-id") or d["compartment-id"])')
SHAPE=$(echo "$CFG_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin)["data"];ld=(d.get("instance-details") or {}).get("launch-details") or {};print(ld.get("shape") or "")')
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
COMPARTMENT="${COMPARTMENT:-$(grep "^tenancy" ~/.oci/config | cut -d= -f2)}"
log "Instance configuration found (shape: $SHAPE)."

already_exists() {
  oci compute instance list --compartment-id "$COMPARTMENT" --all \
    --query "length(data[?shape=='$SHAPE' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
    --raw-output 2>/dev/null | grep -qv '^0$'
}

if already_exists; then
  log "A $SHAPE VM already exists. Nothing to do."; echo "result=exists" >> "$GITHUB_OUTPUT"; exit 0
fi

START=$(date +%s)
for i in $(seq 1 "$ATTEMPTS"); do
  [ $(( $(date +%s) - START )) -gt "$MAX_SECONDS" ] && break
  log "Attempt $i/$ATTEMPTS..."
  OUT=$(oci --no-retry compute-management instance-configuration launch-compute-instance --instance-configuration-id "$CFG" 2>&1)
  if [ $? -eq 0 ]; then
    log "SUCCESS! The VM is being created."; echo "result=created" >> "$GITHUB_OUTPUT"; exit 0
  fi
  if   grep -q "Out of host capacity\|InternalError" <<<"$OUT"; then log "  Out of capacity."
  elif grep -q "TooManyRequests" <<<"$OUT"; then log "  Oracle says slow down."; sleep 60
  elif grep -q "LimitExceeded" <<<"$OUT"; then log "  Free limit reached:"; echo "$OUT" | msg; exit 1
  else log "  Error:"; echo "$OUT" | msg
       grep -q "NotAuthenticated\|NotAuthorizedOrNotFound\|InvalidParameter" <<<"$OUT" && exit 1
  fi
  [ "$i" -lt "$ATTEMPTS" ] && sleep "$PAUSE"
done
log "No capacity this run. Will try again on the next schedule."
echo "result=none" >> "$GITHUB_OUTPUT"
