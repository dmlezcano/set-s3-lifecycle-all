#!/usr/bin/env bash
# Find all objects (and versions) stored as GLACIER (Glacier Flexible Retrieval)
# across ALL buckets, and request a restore so they become temporarily readable.
#
# After that, run Phase 2 to COPY each object to itself with StorageClass=STANDARD.
#
# Env:
#   RESTORE_DAYS=7             # how many days the temporary restored copy stays available
#   RESTORE_TIER=Bulk          # Bulk|Standard|Expedited (Expedited costs more; account must be enabled)
#   DRY_RUN=0|1                # 1 = show actions, don't call AWS
#   MAX_KEYS=1000              # page size for list calls
#   SCOPE="all|bucket:NAME"    # limit to one bucket if desired
#   CONCURRENCY=4              # number of parallel head/restore calls (best-effort)
#
# Notes:
# - For versioned buckets we restore each GLACIER version by VersionId.
# - For unversioned buckets we restore the GLACIER object by Key.
# - Deep Archive (DEEP_ARCHIVE) is NOT included here; add it if you need it.
# - Restores incur retrieval and request costs.

set -u
export AWS_PAGER=""

RESTORE_DAYS="${RESTORE_DAYS:-7}"
RESTORE_TIER="${RESTORE_TIER:-Bulk}"
DRY_RUN="${DRY_RUN:-0}"
MAX_KEYS="${MAX_KEYS:-1000}"
SCOPE="${SCOPE:-all}"
CONCURRENCY="${CONCURRENCY:-4}"

echo "Restore window: ${RESTORE_DAYS} days, tier: ${RESTORE_TIER}"

# Ensure jq present
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install it and rerun."; exit 1
fi

# Gather buckets
if [[ "$SCOPE" == bucket:* ]]; then
  BUCKETS="${SCOPE#bucket:}"
else
  BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || true)
fi

[[ -z "${BUCKETS:-}" ]] && { echo "No buckets found or not authorised."; exit 0; }

ok=0; skipped=0; failed=0

restore_object() {
  local bucket="$1" key="$2" version_id="$3"
  local restore_req; restore_req=$(jq -nc --argjson d "$RESTORE_DAYS" --arg t "$RESTORE_TIER" \
    '{Days:$d, GlacierJobParameters:{Tier:$t}}')
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN restore: s3://$bucket/$key${version_id:+?versionId=$version_id}"
    return 0
  fi
  if [[ -n "$version_id" ]]; then
    aws s3api restore-object --bucket "$bucket" --key "$key" --version-id "$version_id" --restore-request "$restore_req" >/dev/null 2>&1
  else
    aws s3api restore-object --bucket "$bucket" --key "$key" --restore-request "$restore_req" >/dev/null 2>&1
  fi
}

for BUCKET in $BUCKETS; do
  echo "------ Bucket: $BUCKET ------"

  # Access check
  if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo " skip (no access)"; ((skipped++)); continue
  fi

  # Determine if versioned
  VSTAT=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text 2>/dev/null || true)
  if [[ "$VSTAT" == "Enabled" || "$VSTAT" == "Suspended" ]]; then
    # Versioned: list-object-versions to capture storage class per version
    NEXTKEY=""; NEXTVER=""; NEXTDELMARKER=""
    while :; do
      RESP=$(aws s3api list-object-versions --bucket "$BUCKET" --max-items "$MAX_KEYS" \
              ${NEXTKEY:+--starting-token "$NEXTKEY"} 2>/dev/null) || { echo " fail (list versions)"; ((failed++)); break; }

      # Current versions
      echo "$RESP" | jq -r '
        (.Versions // [])[]
        | select(.StorageClass=="GLACIER")
        | [.Key, .VersionId] | @tsv
      ' | while IFS=$'\t' read -r KEY VID; do
          echo " restore request (versioned GLACIER): $KEY  VersionId=$VID"
          if restore_object "$BUCKET" "$KEY" "$VID"; then ((ok++)); else echo "  -> restore failed"; ((failed++)); fi
          sleep 0.02
        done

      # Pagination
      NEXTKEY=$(echo "$RESP" | jq -r '."NextToken" // empty')
      [[ -z "$NEXTKEY" ]] && break
    done
  else
    # Unversioned: list-objects-v2 to get storage class
    TOKEN=""
    while :; do
      LRESP=$(aws s3api list-objects-v2 --bucket "$BUCKET" --max-keys "$MAX_KEYS" ${TOKEN:+--starting-token "$TOKEN"} 2>/dev/null) || { echo " fail (list)"; ((failed++)); break; }
      echo "$LRESP" | jq -r '
        (.Contents // [])[]
        | select(.StorageClass=="GLACIER")
        | .Key
      ' | while IFS= read -r KEY; do
          echo " restore request (GLACIER): $KEY"
          if restore_object "$BUCKET" "$KEY" ""; then ((ok++)); else echo "  -> restore failed"; ((failed++)); fi
          sleep 0.02
        done
      TOKEN=$(echo "$LRESP" | jq -r '."NextToken" // empty')
      [[ -z "$TOKEN" ]] && break
    done
  fi
done

echo "----------------------------------------"
echo "Restore requests placed: $ok, Skipped: $skipped, Failed: $failed"
echo "Next: run Phase 2 *after* restore completes (can take hours for Bulk/Standard)."
