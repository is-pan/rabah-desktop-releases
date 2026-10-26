#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${R2_ACCOUNT_ID:?}"
: "${R2_ACCESS_KEY_ID:?}"
: "${R2_SECRET_ACCESS_KEY:?}"
: "${ANDROID_RELEASE_TAG:?}"
: "${ANDROID_ASSET_NAME:?}"
: "${ANDROID_SHA256:?}"
: "${ANDROID_SIZE_BYTES:?}"

if [[ ! "$ANDROID_RELEASE_TAG" =~ ^android-v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] ||
   [[ ! "$ANDROID_ASSET_NAME" =~ ^Rabah-Android-[A-Za-z0-9.-]+\.apk$ ]] ||
   [[ ! "$ANDROID_SHA256" =~ ^[a-f0-9]{64}$ ]] ||
   [[ ! "$ANDROID_SIZE_BYTES" =~ ^[1-9][0-9]{0,9}$ ]] ||
   (( ANDROID_SIZE_BYTES > 1073741824 )); then
  printf 'Invalid Android release inputs.\n' >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_REGION=auto
export AWS_EC2_METADATA_DISABLED=true
endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
bucket="rabah-desktop-downloads"
work_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/rabah-android-publish.XXXXXX")"

gh release download "$ANDROID_RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  --pattern "$ANDROID_ASSET_NAME" --dir "$work_dir"
apk="$work_dir/$ANDROID_ASSET_NAME"

verify_file() {
  local file="$1"
  [[ "$(stat -c '%s' "$file")" == "$ANDROID_SIZE_BYTES" ]] &&
    [[ "$(sha256sum "$file" | awk '{print $1}')" == "$ANDROID_SHA256" ]]
}

if ! verify_file "$apk"; then
  printf 'APK does not match the original size and SHA-256.\n' >&2
  exit 1
fi
unzip -tqq "$apk"
unzip -Z1 "$apk" | awk '$0 == "AndroidManifest.xml" { found=1 } END { exit !found }'

upload_and_verify() {
  local key="$1" cache_control="$2"
  aws s3 cp "$apk" "s3://${bucket}/${key}" --endpoint-url "$endpoint" \
    --only-show-errors --content-type application/vnd.android.package-archive \
    --cache-control "$cache_control" \
    --content-disposition "attachment; filename=\"${ANDROID_ASSET_NAME}\""
  aws s3 cp "s3://${bucket}/${key}" "$work_dir/readback.apk" \
    --endpoint-url "$endpoint" --only-show-errors
  if ! verify_file "$work_dir/readback.apk"; then
    printf 'R2 readback failed: %s\n' "$key" >&2
    exit 1
  fi
}

version_key="android/${ANDROID_RELEASE_TAG}/${ANDROID_ASSET_NAME}"
# Never replace different bytes at an immutable version URL.
aws s3api list-objects-v2 --bucket "$bucket" --prefix "$version_key" \
  --endpoint-url "$endpoint" --output json > "$work_dir/existing.json"
if jq -e --arg key "$version_key" 'any(.Contents[]?; .Key == $key)' "$work_dir/existing.json" >/dev/null; then
  aws s3 cp "s3://${bucket}/${version_key}" "$work_dir/readback.apk" \
    --endpoint-url "$endpoint" --only-show-errors
  if ! verify_file "$work_dir/readback.apk"; then
    printf 'Immutable version URL already contains a different APK.\n' >&2
    exit 1
  fi
else
  upload_and_verify "$version_key" 'public, max-age=31536000, immutable'
fi
upload_and_verify 'latest/Rabah-Android.apk' 'public, max-age=60, must-revalidate'

printf 'Published and verified:\nhttps://download.rabah.ai/%s\nhttps://download.rabah.ai/latest/Rabah-Android.apk\n' "$version_key"
