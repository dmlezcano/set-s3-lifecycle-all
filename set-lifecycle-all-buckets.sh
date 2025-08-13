#!/usr/bin/env bash
# Apply a lifecycle policy to all S3 buckets in the account.
# Current and noncurrent versions:
#   30 days  -> GLACIER (Glacier Flexible Retrieval)
#   180 days -> DEEP_ARCHIVE
#   730 days -> permanent delete
#
# Notes:
# - Requires permissions: s3:ListAllMyBuckets, s3:GetBucketVersioning,
#   s3:PutBucketVersioning, s3:PutLifecycleConfiguration
# - This overwrites existing lifecycle configs. See the MERGE variant if needed.

set -u  # no set -e, to avoid killing the shell on a single failure
export AWS_PAGER=""

RULE_ID="Compliance-GLACIER-DA-2Y"

# Multiline JSON using single quotes to avoid the read -d '' pitfall
LIFECYCLE_JSON='{
  "Rules": [
    {
      "ID": "'"$RULE_ID"'",
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
  ]
}'

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

  # Enable versioning if not enabled
  VERS_STATUS=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text 2>/dev/null || true)
  if [[ "$VERS_STATUS" != "Enabled" ]]; then
    if ! aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled >/dev/null 2>&1; then
      echo " fail (cannot enable versioning)"
      ((failed++))
      continue
    fi
  fi

  # Apply lifecycle configuration
  if aws s3api put-bucket-lifecycle-configuration \
        --bucket "$BUCKET" \
        --lifecycle-configuration "$LIFECYCLE_JSON" >/dev/null 2>&1; then
    echo " ok"
    ((ok++))
  else
    echo " fail (policy not applied)"
    ((failed++))
  fi

  # Small pause to avoid API bursts
  sleep 0.2
done

echo "Done. Applied: $ok, Skipped: $skipped, Failed: $failed"
echo "Verify a bucket with: aws s3api get-bucket-lifecycle-configuration --bucket <name>"
