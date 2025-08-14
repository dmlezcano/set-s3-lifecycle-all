#!/usr/bin/env bash
# Delete ALL lifecycle rules from all S3 buckets.
# Creates JSON backups before deletion.
#
# Env:
#   DRY_RUN=0|1  # preview without deleting

set -u
export AWS_PAGER=""
DRY_RUN="${DRY_RUN:-0}"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="lifecycle-backups-$timestamp"
mkdir -p "$backup_dir"

echo "Listing buckets..."
BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || true)
[[ -z "${BUCKETS:-}" ]] && { echo "No buckets found or not authorised."; exit 0; }

ok=0; skipped=0; failed=0
for BUCKET in $BUCKETS; do
  printf "%-60s" "Processing: $BUCKET"

  # Access check
  if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo " skip (no access)"
    ((skipped++)); continue
  fi

  # If lifecycle exists, back it up then delete
  if EXISTING_JSON=$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" 2>/dev/null); then
    echo "$EXISTING_JSON" > "$backup_dir/${BUCKET}.json"
  else
    echo " skip (no lifecycle)"
    ((skipped++)); continue
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo " DRY-RUN (would delete lifecycle)"
    ((ok++)); continue
  fi

  if aws s3api delete-bucket-lifecycle --bucket "$BUCKET" >/dev/null 2>&1; then
    echo " ok"
    ((ok++))
  else
    echo " fail (delete error)"
    ((failed++))
  fi

  sleep 0.2
done

echo "----------------------------------------"
echo "Lifecycles deleted: $ok, Skipped: $skipped, Failed: $failed"
echo "Backups saved in: $backup_dir/"
echo "Restore example:"
echo "  aws s3api put-bucket-lifecycle-configuration --bucket <name> --lifecycle-configuration file://$backup_dir/<name>.json"
