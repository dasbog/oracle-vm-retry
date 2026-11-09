#!/usr/bin/env bash
# Run in Oracle Cloud Shell. Registers an Oracle API key and stores everything the
# GitHub job needs as GitHub secrets, so nothing has to be copied by hand.
# Usage: bash setup-secrets.sh [owner/repo]
set -euo pipefail
REPO="${1:-dasbog/oracle-vm-retry}"
KEYDIR="$HOME/apikey"
say() { echo; echo ">>> $*"; }

# 1. API key pair (reuses the one from earlier if it exists)
mkdir -p "$KEYDIR"
if [ ! -f "$KEYDIR/key.pem" ]; then
  say "Creating API key pair"
  openssl genrsa -out "$KEYDIR/key.pem" 2048 2>/dev/null
fi
openssl rsa -pubout -in "$KEYDIR/key.pem" -out "$KEYDIR/key_public.pem" 2>/dev/null

# 2. Account details
TENANCY="${OCI_TENANCY:?OCI_TENANCY not set - are you in Cloud Shell?}"
USER_OCID="${OCI_CS_USER_OCID:-}"
if [ -z "$USER_OCID" ]; then
  read -rp "Paste your user OCID (Profile > My profile > OCID > Copy): " USER_OCID
fi
REGION=$(oci iam region-subscription list --tenancy-id "$TENANCY" \
  --query 'data[?"is-home-region"]."region-name" | [0]' --raw-output)
say "Home region: $REGION"

# 3. Register the public key with Oracle (skip if already there).
# Fingerprint comes from Oracle itself (Cloud Shell's FIPS mode blocks MD5 locally).
PUB=$(tr -d '\n\r' < "$KEYDIR/key_public.pem")
FP=$(oci iam user api-key list --user-id "$USER_OCID" --output json | PUB="$PUB" python3 -c '
import json,os,sys
pub=os.environ["PUB"]
for k in (json.load(sys.stdin) or {}).get("data",[]):
    if k.get("key-value","").replace("\n","").replace("\r","")==pub: print(k["fingerprint"]); break')
if [ -n "$FP" ]; then
  say "API key already registered with Oracle"
else
  say "Registering API key with Oracle"
  FP=$(oci iam user api-key upload --user-id "$USER_OCID" --key-file "$KEYDIR/key_public.pem" \
    --query 'data.fingerprint' --raw-output)
fi
[ -n "$FP" ] || { echo "Could not get the key fingerprint."; exit 1; }
say "Key fingerprint: $FP"

# 4. Pick the instance configuration
say "Looking for your instance configurations"
mapfile -t CFGS < <(oci search resource structured-search \
  --query-text "query instanceconfiguration resources where lifeCycleState = 'ACTIVE'" \
  --query 'data.items[].[identifier, "display-name"]' --output json \
  | python3 -c 'import json,sys
for i,n in json.load(sys.stdin) or []: print(i+"\t"+n)')
if [ ${#CFGS[@]} -eq 0 ]; then echo "No instance configuration found."; exit 1; fi
if [ ${#CFGS[@]} -eq 1 ]; then CHOICE=1; else
  for k in "${!CFGS[@]}"; do echo "  $((k+1)). ${CFGS[$k]#*$'\t'}"; done
  read -rp "Which one? Type its number: " CHOICE
fi
CFG_LINE="${CFGS[$((CHOICE-1))]}"
CFG_ID="${CFG_LINE%%$'\t'*}"
say "Using instance configuration: ${CFG_LINE#*$'\t'}"

# 5. GitHub CLI (downloaded locally, no install rights needed)
if ! command -v gh >/dev/null; then
  ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; esac
  URL=$(curl -s https://api.github.com/repos/cli/cli/releases/latest \
    | python3 -c "import json,sys; print([a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].endswith('linux_$ARCH.tar.gz')][0])")
  say "Downloading GitHub CLI"
  mkdir -p "$HOME/ghcli" && curl -sL "$URL" | tar xz -C "$HOME/ghcli" --strip-components=1
  export PATH="$HOME/ghcli/bin:$PATH"
fi

echo
read -rsp "Paste your GitHub token (it stays hidden) and press Enter: " GH_TOKEN; echo
export GH_TOKEN

# 6. Store secrets
say "Saving secrets to $REPO"
gh secret set OCI_USER               --repo "$REPO" --body "$USER_OCID"
gh secret set OCI_TENANCY            --repo "$REPO" --body "$TENANCY"
gh secret set OCI_FINGERPRINT        --repo "$REPO" --body "$FP"
gh secret set OCI_REGION             --repo "$REPO" --body "$REGION"
gh secret set OCI_INSTANCE_CONFIG_ID --repo "$REPO" --body "$CFG_ID"
gh secret set OCI_KEY                --repo "$REPO" < "$KEYDIR/key.pem"

# 7. First run right away
say "Starting a first run"
gh workflow run retry.yml --repo "$REPO" && echo "Started. Check the Actions tab: https://github.com/$REPO/actions"
say "All done. Oracle may take a minute or two to accept a brand-new API key; if the first run says NotAuthenticated, just wait - the next scheduled run will work."
