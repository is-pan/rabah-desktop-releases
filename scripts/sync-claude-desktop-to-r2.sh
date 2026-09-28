#!/usr/bin/env bash
set -euo pipefail

for command_name in aws curl jq python3 shasum hdiutil codesign lipo; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "$command_name" >&2
    exit 1
  }
done
: "${R2_ACCOUNT_ID:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" "${R2_BUCKET_NAME:?}" "${DOWNLOAD_BASE_URL:?}"
[[ "$R2_BUCKET_NAME" == "rabah-companion-downloads" ]] || exit 1

endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
base_url="${DOWNLOAD_BASE_URL%/}"
work_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rabah-claude-desktop-r2"
rm -rf "$work_dir"
mkdir -p "$work_dir/windows" "$work_dir/macos" "$work_dir/metadata"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto AWS_REGION=auto AWS_EC2_METADATA_DISABLED=true

windows_redirect="https://api.anthropic.com/api/desktop/win32/x64/msix/latest/redirect"
macos_redirect="https://api.anthropic.com/api/desktop/darwin/universal/dmg/latest/redirect"
team_id="Q6L2SF6YDW"
version_pattern='^[0-9]+(\.[0-9]+){1,3}$'

size_of() { wc -c < "$1" | tr -d ' '; }
sha256() { shasum -a 256 "$1" | awk '{print tolower($1)}'; }
key_of() { printf '%s' "${1#"$base_url"/}"; }

download() {
  local url="$1" destination="$2"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors \
    --connect-timeout 30 --max-time 3600 \
    -A 'Rabah-Claude-Desktop-R2-Mirror/1.0' \
    -H 'Accept: application/octet-stream' --output "$destination" "$url"
  [[ -s "$destination" ]]
}

release_location="$(curl --silent --show-error --proto '=https' \
  --max-redirs 0 --connect-timeout 30 --max-time 60 \
  -A 'Rabah-Claude-Desktop-R2-Mirror/1.0' \
  -D - -o /dev/null "$windows_redirect" 2>/dev/null \
  | awk 'tolower($1) == "location:" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' | tr -d '\r')"
if [[ ! "$release_location" =~ ^https://downloads\.claude\.ai/releases/win32/x64/([^/]+)/Claude-([0-9a-f]{40})\.msix$ ]]; then
  printf 'Claude Windows redirect did not expose a versioned release location.\n' >&2
  exit 1
fi
windows_version="${BASH_REMATCH[1]}"
[[ "$windows_version" =~ $version_pattern ]]
windows_source="$release_location"

macos_location="$(curl --silent --show-error --proto '=https' \
  --max-redirs 0 --connect-timeout 30 --max-time 60 \
  -A 'Rabah-Claude-Desktop-R2-Mirror/1.0' \
  -D - -o /dev/null "$macos_redirect" 2>/dev/null \
  | awk 'tolower($1) == "location:" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' | tr -d '\r')"
if [[ ! "$macos_location" =~ ^https://downloads\.claude\.ai/releases/darwin/universal/([^/]+)/Claude-([0-9a-f]{40})\.dmg$ ]]; then
  printf 'Claude macOS redirect did not expose a versioned release location.\n' >&2
  exit 1
fi
macos_release_version="${BASH_REMATCH[1]}"
[[ "$macos_release_version" =~ $version_pattern ]]
macos_source="$macos_location"

# Read the current catalog before downloading ~GB-sized installers.  If both
# objects are still present and unchanged, a scheduled run is a no-op.  A
# manual force run is the escape hatch for repairing or revalidating objects.
previous_catalog="$work_dir/metadata/previous.json"
curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 30 -sS \
  "$base_url/claude/latest.json" -o "$previous_catalog" || rm -f "$previous_catalog"

object_intact() {
  local key="$1" expected_size="$2" expected_sha="$3" actual_size actual_sha
  actual_size="$(aws s3api head-object --bucket "$R2_BUCKET_NAME" --key "$key" \
    --endpoint-url "$endpoint" --query ContentLength --output text 2>/dev/null)" || return 1
  [[ "$actual_size" == "$expected_size" ]] || return 1
  actual_sha="$(aws s3 cp "s3://$R2_BUCKET_NAME/$key" - --endpoint-url "$endpoint" \
    --only-show-errors | shasum -a 256 | awk '{print tolower($1)}')" || return 1
  [[ "$actual_sha" == "$expected_sha" ]]
}

mirror_is_current() {
  local catalog="$1" url size sha key
  [[ "$(jq -r '.platforms["windows-x86_64"].version // empty' "$catalog")" == "$windows_version" ]] || return 1
  [[ "$(jq -r '.platforms["darwin-universal"].version // empty' "$catalog")" == "$macos_version" ]] || return 1
  while IFS=$'\t' read -r url size sha; do
    [[ -n "$url" && -n "$size" && -n "$sha" ]] || return 1
    key="$(key_of "$url")"
    object_intact "$key" "$size" "$sha" || return 1
  done < <(jq -r '.platforms[] | [.url, .size, .sha256] | @tsv' "$catalog")
}

if [[ "${FORCE_CLAUDE_DESKTOP_SYNC:-false}" != "true" && -s "$previous_catalog" ]] &&
    mirror_is_current "$previous_catalog"; then
  printf 'Claude Desktop %s is already mirrored and intact.\n' "$windows_version"
  exit 0
fi

download "$windows_source" "$work_dir/windows/Claude-x64.msix"
download "$macos_source" "$work_dir/macos/Claude-universal.dmg"

manifest_version="$(python3 - "$work_dir/windows/Claude-x64.msix" <<'PY2'
import sys
import zipfile
import xml.etree.ElementTree as ET

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = set(archive.namelist())
    if "AppxManifest.xml" not in names or "AppxSignature.p7x" not in names:
        raise SystemExit("MSIX is missing manifest/signature")
    root = ET.fromstring(archive.read("AppxManifest.xml"))
identity = root.find("{http://schemas.microsoft.com/appx/manifest/foundation/windows10}Identity")
if identity is None or identity.attrib.get("Name") != "Claude":
    raise SystemExit("unexpected Claude package identity")
if identity.attrib.get("ProcessorArchitecture") != "x64":
    raise SystemExit("unexpected Claude package architecture")
print(identity.attrib["Version"])
PY2
)"
[[ "$manifest_version" =~ $version_pattern ]]
[[ "$manifest_version" == "$windows_version" ]] || {
  printf 'Claude Windows redirect version and MSIX manifest version differ: %s != %s\n' "$windows_version" "$manifest_version" >&2
  exit 1
}

mount_point="$work_dir/macos/mount"
mkdir -p "$mount_point"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount_point" \
  "$work_dir/macos/Claude-universal.dmg" >/dev/null
trap 'hdiutil detach -force "$mount_point" >/dev/null 2>&1 || true' EXIT
app="$(find "$mount_point" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$app" ]] || { printf 'Claude DMG contains no app\n' >&2; exit 1; }
info="$app/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle_id" == "com.anthropic.claudefordesktop" || "$bundle_id" == "com.anthropic.claude" ]] || {
  printf 'unexpected Claude bundle identifier: %s\n' "$bundle_id" >&2
  exit 1
}
codesign --verify --deep --strict "$app"
signature="$(codesign -dv "$app" 2>&1)"
grep -qx "TeamIdentifier=$team_id" <<< "$signature" || {
  printf 'Claude app is not signed by Anthropic (%s)\n' "$team_id" >&2
  exit 1
}
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
architectures="$(lipo -archs "$app/Contents/MacOS/$executable")"
[[ " $architectures " == *x86_64* && " $architectures " == *arm64* ]] || {
  printf 'Claude universal app is missing x86_64 or arm64\n' >&2
  exit 1
}
macos_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
hdiutil detach "$mount_point" >/dev/null
trap - EXIT
[[ "$macos_version" =~ $version_pattern ]]
[[ "$macos_version" == "$macos_release_version" ]] || {
  printf 'Claude macOS redirect version and app version differ: %s != %s\n' "$macos_release_version" "$macos_version" >&2
  exit 1
}

for file in "$work_dir/windows/Claude-x64.msix" "$work_dir/macos/Claude-universal.dmg"; do
  size="$(size_of "$file")"
  (( size > 0 && size <= 1200000000 ))
done
windows_sha="$(sha256 "$work_dir/windows/Claude-x64.msix")"
macos_sha="$(sha256 "$work_dir/macos/Claude-universal.dmg")"
windows_size="$(size_of "$work_dir/windows/Claude-x64.msix")"
macos_size="$(size_of "$work_dir/macos/Claude-universal.dmg")"
windows_key="claude/windows/$windows_version/Claude-x64.msix"
macos_key="claude/macos/$macos_version/Claude-universal.dmg"

upload() {
  aws s3 cp "$1" "s3://$R2_BUCKET_NAME/$2" --endpoint-url "$endpoint" --only-show-errors \
    --content-type "$3" --cache-control "$4"
}
upload "$work_dir/windows/Claude-x64.msix" "$windows_key" "application/vnd.ms-appx" "public, max-age=31536000, immutable"
upload "$work_dir/macos/Claude-universal.dmg" "$macos_key" "application/x-apple-diskimage" "public, max-age=31536000, immutable"

verify_object() {
  local file="$1" key="$2" expected_size="$3" expected_sha="$4"
  local actual_size readback
  actual_size="$(aws s3api head-object --bucket "$R2_BUCKET_NAME" --key "$key" \
    --endpoint-url "$endpoint" --query ContentLength --output text)"
  [[ "$actual_size" == "$expected_size" ]] || exit 1
  readback="$work_dir/metadata/readback-$(basename "$file")"
  aws s3 cp "s3://$R2_BUCKET_NAME/$key" "$readback" --endpoint-url "$endpoint" --only-show-errors
  [[ "$(size_of "$readback")" == "$expected_size" ]] || exit 1
  [[ "$(sha256 "$readback")" == "$expected_sha" ]] || exit 1
  rm -f "$readback"
}
verify_object "$work_dir/windows/Claude-x64.msix" "$windows_key" "$windows_size" "$windows_sha"
verify_object "$work_dir/macos/Claude-universal.dmg" "$macos_key" "$macos_size" "$macos_sha"

catalog="$work_dir/metadata/latest.json"
jq -n --arg wv "$windows_version" --arg mv "$macos_version" --arg t "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg wu "$base_url/$windows_key" --arg mu "$base_url/$macos_key" \
  --arg wh "$windows_sha" --argjson ws "$windows_size" --arg mh "$macos_sha" --argjson ms "$macos_size" \
  '{schemaVersion:1,product:"Claude Desktop",publishedAt:$t,platforms:{"windows-x86_64":{version:$wv,url:$wu,sha256:$wh,size:$ws},"darwin-universal":{version:$mv,url:$mu,sha256:$mh,size:$ms}}}' > "$catalog"
upload "$catalog" "claude/latest.json" "application/json; charset=utf-8" "no-cache, no-store, must-revalidate"

if [[ -s "$previous_catalog" ]]; then
  keep="$work_dir/metadata/keep.txt"
  {
    printf '%s\n' claude/latest.json "$windows_key" "$macos_key"
    jq -r '.platforms[] | .url' "$previous_catalog" | while IFS= read -r url; do key_of "$url"; done
  } > "$keep"
  while IFS= read -r key; do
    [[ -z "$key" || "$key" == "None" ]] && continue
    grep -qxF "$key" "$keep" && continue
    aws s3api delete-object --bucket "$R2_BUCKET_NAME" --key "$key" --endpoint-url "$endpoint" >/dev/null
  done < <(aws s3api list-objects-v2 --bucket "$R2_BUCKET_NAME" --prefix claude/ \
    --endpoint-url "$endpoint" --query 'Contents[].Key' --output text | tr '\t' '\n')
fi
printf 'Claude Desktop R2 mirror published: Windows %s, macOS %s\n' "$windows_version" "$macos_version"
