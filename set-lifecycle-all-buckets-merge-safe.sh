#!/usr/bin/env bash
# Merge-safe lifecycle rollout to ALL S3 buckets.
# Compliance rule:
#   - Current versions:   30d -> GLACIER, 180d -> DEEP_ARCHIVE, delete at 730d
#   - Noncurrent versions:30d -> GLACIER, 180d -> DEEP_ARCHIVE, delete at 730d
#
# This script PRESERVES existing rules. If a rule with the same ID exists,
# it is replaced; otherwise, the rule is appended.
#
# Requirements:
#   - AWS CLI v2
#   - jq (auto-installs on Amazon Linux / CloudShell if missing)
# Permissions:
#   s3:ListAllMyBuckets, s3:PutLifecycleConfiguration, s3:GetLifecycleConfiguration,
#   s3:GetBucketVersioning, s3:PutBucketVersioning, s3:HeadBucket

set -u
export AWS_PAGER=""

RULE_ID="Compliance-GLACIER-DA-2Y"
INSTALL_JQ_IF_MISSING="${INSTALL_JQ_IF_MISSING:-1}"   # set to 0 to skip auto-install
DRY_RUN="${DRY_RUN:-0}"                               # set to 1 for dry-run (prints but doesn't apply)

# Ensure jq exists (CloudShell usually has it)
if ! command -v jq >/dev/null 2>&1; then
  if [[ "$INSTALL_JQ_IF_MISSING" == "1" ]]; then
    echo "jq not found, attempting to install..."
    if command -v yum >/dev/null 2>&1; then
      sudo yum -y install jq >/dev/null || { echo "Failed to install jq via yum."; exit 1; }
    elif command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null && sudo apt-get install -y jq >/dev/null || { echo "Failed to install jq via apt-get."; exit 1; }
    else
      echo "Package manager not found. Please install jq and re-run."; exit 1
    fi
  else
    echo "jq is required. Please install it and re-run."; exit 1
  fi
fi

# The compliance rule we want to merge/ensure per bucket
read -r -d '' NEW_RULE <<'JSON'
{
  "ID": "__RULE_ID__",
  "Status": "Enabled",
  "Filter": {},
  "Transitions": [
    { "Days": 30,  "StorageClass": "GLACIER" },
    { "Days": 180, "StorageClass": "DEEP_ARCHIVE" }
  ],
  "Expiration": { "Days": 730 },
  "NoncurrentVersionTransitions": [
    { "NoncurrentDays": 30,  "StorageClass": "GLACIER" },
    { "NoncurrentDays": 180, "StorageClass": "DEEP_ARCHIVE" }
  ],
  "NoncurrentVersionExpiration": { "NoncurrentDays": 730 },
  "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
}
JSON
NEW_RULE="${NEW_RULE/__RULE_ID__/$RULE_ID}"

# Fetch all buckets
echo "Fetching buckets..."
BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || true)

if [[ -z "${BUCKETS:-}" ]]; then
  echo "No buckets found or not authorised to list."
  exit 0
fi

ok=0; skipped=0; failed=0
for BUCKET in $BUCKETS; do
  printf "%-60s" "Processing: $BUCKET"

  # Check access to bucket
  if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo " skip (no access)"
    ((skipped++))
    continue
  fi

  # Enable versioning if needed (non-fatal if it fails)
  VERS_STATUS=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text 2>/dev/null || true)
  if [[ "$VERS_STATUS" != "Enabled" ]]; then
    aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled >/dev/null 2>&1 || true
  fi

  # Get existing lifecycle; if none, start with empty rules
  if ! EXISTING_JSON=$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" 2>/dev/null); then
    EXISTING_JSON='{"Rules":[]}'
  fi

  # Merge/replace our rule by ID, preserving all others
  MERGED_JSON=$(jq \
    --arg rid "$RULE_ID" \
    --argjson new "$NEW_RULE" \
    '
    . as $root
    | ( .Rules // [] ) as $rules
    | if ($rules | map(.ID == $rid) | any)
      then { Rules: ( $rules | map( if .ID == $rid then $new else . end ) ) }
      else { Rules: ( $rules + [ $new ] ) }
      end
    ' <<<"$EXISTING_JSON")

  # If nothing changed, still attempt put (idempotent), but we could short-circuit by comparing
  if [[ "$DRY_RUN" == "1" ]]; then
    echo " DRY-RUN"
    echo "$MERGED_JSON"
    ((ok++))
    continue
  fi

  if aws s3api put-bucket-lifecycle-configuration \
        --bucket "$BUCKET" \
        --lifecycle-configuration "$MERGED_JSON" >/dev/null 2>&1; then
    echo " ok"
    ((ok++))
  else
    echo " fail (policy not applied)"
    ((failed++))
  fi

  # Gentle pacing
  sleep 0.2
done

echo "----------------------------------------"
echo "Done. Applied/Merged: $ok, Skipped: $skipped, Failed: $failed"
echo "Verify a bucket with:"
echo "  aws s3api get-bucket-lifecycle-configuration --bucket <name> | jq"
echo "Dry-run mode: run with DRY_RUN=1 ./set-lifecycle-all-buckets-merge-safe.sh"
