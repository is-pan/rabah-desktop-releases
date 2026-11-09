#!/usr/bin/env bash
set -euo pipefail

: "${R2_ACCOUNT_ID:?}"
: "${R2_ACCESS_KEY_ID:?}"
: "${R2_SECRET_ACCESS_KEY:?}"
: "${IOS_RELEASE_RECORD:?Path to the verified TestFlight release record}"

task_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/rabah-ios-update.XXXXXX")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto AWS_REGION=auto AWS_EC2_METADATA_DISABLED=true
endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
bucket='rabah-desktop-downloads'
key='ios/testflight/latest.json'

# Validate the local availability record before contacting the bucket.
python3 "$script_dir/ios-update-manifest.py" --record "$IOS_RELEASE_RECORD" --output "$task_dir/latest.json"
aws s3api list-objects-v2 --bucket "$bucket" --prefix "$key" --endpoint-url "$endpoint" --output json > "$task_dir/existing.json"
if jq -e --arg key "$key" 'any(.Contents[]?; .Key == $key)' "$task_dir/existing.json" >/dev/null; then
  aws s3 cp "s3://${bucket}/${key}" "$task_dir/previous.json" --endpoint-url "$endpoint" --only-show-errors
  python3 "$script_dir/ios-update-manifest.py" --record "$IOS_RELEASE_RECORD" --previous "$task_dir/previous.json" --output "$task_dir/latest.json"
fi
aws s3 cp "$task_dir/latest.json" "s3://${bucket}/${key}" --endpoint-url "$endpoint" --only-show-errors \
  --content-type 'application/json; charset=utf-8' --cache-control 'no-cache, no-store, must-revalidate'
aws s3 cp "s3://${bucket}/${key}" "$task_dir/readback.json" --endpoint-url "$endpoint" --only-show-errors
cmp "$task_dir/latest.json" "$task_dir/readback.json"
printf 'Published TestFlight release metadata: https://download.rabah.ai/%s\n' "$key"
