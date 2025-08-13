# S3 Lifecycle Compliance Scripts

This repository contains **two AWS CLI shell scripts** for applying a compliance-oriented lifecycle policy to Amazon S3 buckets.

The policy transitions both **current** and **noncurrent** object versions:

1. **30 days** → Glacier Flexible Retrieval (`GLACIER`)
2. **180 days** → Deep Archive (`DEEP_ARCHIVE`)
3. **730 days (~2 years)** → Permanent deletion

The rules also enable **versioning** on each bucket so that noncurrent transitions are effective.

---

## 📜 Scripts

### 1. `set-lifecycle-all-buckets.sh` (Replace-All Version)
- **What it does**: Applies the compliance rule to **all buckets** in the AWS account and **replaces any existing lifecycle policy**.
- **Use case**:  
  Use when you want to ensure *every* bucket has the same lifecycle rule, and you don’t need to preserve any existing lifecycle configurations.
- **Warning**: Any pre-existing lifecycle rules on the bucket will be overwritten.

### 2. `set-lifecycle-all-buckets-merge-safe.sh` (Merge-Safe Version)
- **What it does**: Applies the compliance rule to all buckets **without deleting other lifecycle rules**.  
  If a rule with the same ID already exists (`Compliance-GLACIER-DA-2Y`), it is updated; otherwise, it is appended.
- **Use case**:  
  Use when buckets may already have custom lifecycle policies you want to preserve.
- **Dependencies**: Requires [`jq`](https://stedolan.github.io/jq/) to merge JSON.  
  The script can auto-install `jq` in AWS CloudShell.

---

## 🔧 Prerequisites
- **AWS CLI v2** configured with permissions:
  - `s3:ListAllMyBuckets`
  - `s3:GetBucketVersioning`, `s3:PutBucketVersioning`
  - `s3:GetLifecycleConfiguration`, `s3:PutLifecycleConfiguration`
  - `s3:HeadBucket`
- For the merge-safe script: `jq` must be installed (auto-installed on most systems via `yum` or `apt` if missing).

---

## ▶️ Usage

### Replace-All Version
```bash
chmod +x set-lifecycle-all-buckets.sh
./set-lifecycle-all-buckets.sh
