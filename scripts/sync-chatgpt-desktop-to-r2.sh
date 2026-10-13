#!/usr/bin/env bash
set -euo pipefail

# GitHub Actions is the only component that contacts OpenAI. Rabah Desktop
# clients consume the R2 catalog and R2 objects exclusively.
#
# Runs on a macOS runner: the DMG carries no version metadata, so its app is
# mounted to read the exact version and to check OpenAI's signature before
# anything is published.
for command_name in aws curl jq python3 shasum hdiutil codesign lipo; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "$command_name" >&2
    exit 1
  }
done
: "$R2_ACCOUNT_ID" "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" "$R2_BUCKET_NAME" "$DOWNLOAD_BASE_URL"
[[ "$R2_BUCKET_NAME" == "rabah-desktop-downloads" ]] || exit 1

endpoint="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
base_url="$(printf '%s' "$DOWNLOAD_BASE_URL" | sed 's:/*$::')"
work_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rabah-chatgpt-desktop-r2"
rm -rf "$work_dir"
mkdir -p "$work_dir/windows" "$work_dir/macos" "$work_dir/metadata"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto AWS_REGION=auto AWS_EC2_METADATA_DISABLED=true
official_base="https://persistent.oaistatic.com/codex-app-prod"
openai_team_id="2DC432GLL2"
version_pattern='^[0-9]+(\.[0-9]+){2,3}$'

size_of() { wc -c < "$1" | tr -d ' '; }
sha256() { shasum -a 256 "$1" | awk '{print tolower($1)}'; }
key_of() { printf '%s' "${1#"$base_url"/}"; }

# --- Upstream versions, from metadata only ----------------------------------
# Either lookup failing only means the version is unknown up front: the
# packages are then downloaded and their versions read from the files.
windows_upstream="$(curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  --connect-timeout 20 --max-time 30 -sSI "$official_base/ChatGPT-x64.msix" |
  awk -F': *' 'tolower($1) == "x-ms-meta-package_version" {print $2}' | tr -d '\r' | tail -n1)" || windows_upstream=""
mac_upstream="$(curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  --connect-timeout 20 --max-time 30 -sS "$official_base/appcast.xml" | python3 -c '
import re, sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
# Build numbers today ("10789"); compared part by part so a dotted build
# number would order correctly too. Items without one are ignored.
def build(item):
    return tuple(int(part) for part in re.findall(r"\d+", item.findtext("sparkle:version", "", ns)))
items = [item for item in ET.fromstring(sys.stdin.read()).findall("channel/item") if build(item)]
print(max(items, key=build).findtext("sparkle:shortVersionString", "", ns) if items else "")
')" || mac_upstream=""

# --- Skip only when both platforms are current and every object is intact --
previous_catalog="$work_dir/metadata/previous.json"
curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 \
  --max-time 30 -sS "$base_url/codex/latest.json" -o "$previous_catalog" || rm -f "$previous_catalog"

object_intact() {
  local key="$1" expected_size="$2" expected_sha256="$3" actual_size actual_sha256
  actual_size="$(aws s3api head-object --bucket "$R2_BUCKET_NAME" --key "$key" \
    --endpoint-url "$endpoint" --query ContentLength --output text 2>/dev/null)" || return 1
  [[ "$actual_size" == "$expected_size" ]] || return 1
  # Size alone cannot tell a same-sized damaged object from a good one. R2
  # charges no egress, so the stored bytes are streamed and hashed.
  actual_sha256="$(aws s3 cp "s3://$R2_BUCKET_NAME/$key" - --endpoint-url "$endpoint" \
    --only-show-errors | shasum -a 256 | awk '{print tolower($1)}')" || return 1
  [[ "$actual_sha256" == "$expected_sha256" ]]
}
mirror_is_current() {
  local catalog="$1" url size sha
  [[ "$windows_upstream" =~ $version_pattern && "$mac_upstream" =~ $version_pattern ]] || return 1
  [[ "$(jq -r '.platforms["windows-x86_64"].version // empty' "$catalog")" == "$windows_upstream" ]] || return 1
  [[ "$(jq -r '.platforms["darwin-aarch64"].version // empty' "$catalog")" == "$mac_upstream" ]] || return 1
  # An object deleted or damaged in R2 behind an unchanged version would
  # otherwise never be repaired by a scheduled run.
  while IFS=$'\t' read -r url size sha; do
    object_intact "$(key_of "$url")" "$size" "$sha" || {
      printf 'Mirrored object is missing or damaged, re-mirroring: %s\n' "$url" >&2
      return 1
    }
  done < <(jq -r '.platforms[] | ([.url, .size, .sha256] | @tsv), (select(.licenseUrl != null) | [.licenseUrl, .licenseSize, .licenseSha256] | @tsv)' "$catalog")
}
if [[ "${FORCE_CHATGPT_DESKTOP_SYNC:-false}" != "true" && -s "$previous_catalog" ]] &&
    mirror_is_current "$previous_catalog"; then
  printf 'ChatGPT Desktop Windows %s / macOS %s is already mirrored and intact.\n' \
    "$windows_upstream" "$mac_upstream"
  exit 0
fi

# --- Download and inspect ---------------------------------------------------
download() {
  local url="$1" destination="$2"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors \
    --connect-timeout 20 --max-time 3600 --output "$destination" "$url"
  [[ -s "$destination" ]]
}
download "$official_base/ChatGPT-x64.msix" "$work_dir/windows/ChatGPT-x64.msix"
download "$official_base/ChatGPT-License.xml" "$work_dir/windows/ChatGPT-License.xml"
download "$official_base/Codex.dmg" "$work_dir/macos/Codex-arm64.dmg"

windows_version="$(python3 - "$work_dir/windows/ChatGPT-x64.msix" <<'PY'
import sys, zipfile, xml.etree.ElementTree as ET
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = set(archive.namelist())
    if "AppxManifest.xml" not in names or "AppxSignature.p7x" not in names:
        raise SystemExit("MSIX is missing manifest/signature")
    root = ET.fromstring(archive.read("AppxManifest.xml"))
identity = root.find("{http://schemas.microsoft.com/appx/manifest/foundation/windows10}Identity")
if identity is None or identity.attrib.get("Name") != "OpenAI.Codex":
    raise SystemExit("unexpected package identity")
if identity.attrib.get("ProcessorArchitecture") != "x64":
    raise SystemExit("unexpected package architecture")
print(identity.attrib["Version"])
PY
)"
[[ "$windows_version" =~ $version_pattern ]]

# The app inside the DMG must be OpenAI's, intact and Apple silicon; its own
# Info.plist is the only authoritative macOS version.
mount_point="$work_dir/macos/mount"
mkdir -p "$mount_point"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount_point" \
  "$work_dir/macos/Codex-arm64.dmg" >/dev/null
trap 'hdiutil detach -force "$mount_point" >/dev/null 2>&1 || true' EXIT
app="$(find "$mount_point" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$app" ]] || { printf 'DMG contains no app\n' >&2; exit 1; }
info="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "com.openai.codex" ]] || {
  printf 'unexpected macOS bundle identifier\n' >&2
  exit 1
}
codesign --verify --deep --strict "$app"
# Captured first: `grep -q` stops reading at its match, which pipefail would
# report as a failure of the writer.
signature="$(codesign -dv "$app" 2>&1)"
grep -qx "TeamIdentifier=$openai_team_id" <<< "$signature" || {
  printf 'macOS app is not signed by OpenAI (%s)\n' "$openai_team_id" >&2
  exit 1
}
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
architectures="$(lipo -archs "$app/Contents/MacOS/$executable")"
[[ " $architectures " == *" arm64 "* ]] || {
  printf 'macOS app has no arm64 slice\n' >&2
  exit 1
}
mac_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
hdiutil detach "$mount_point" >/dev/null
trap - EXIT
[[ "$mac_version" =~ $version_pattern ]]

for file in "$work_dir"/windows/* "$work_dir"/macos/*.dmg; do
  size="$(size_of "$file")"
  (( size > 0 && size <= 1200000000 ))
done
wx="$(sha256 "$work_dir/windows/ChatGPT-x64.msix")"
li="$(sha256 "$work_dir/windows/ChatGPT-License.xml")"; ma="$(sha256 "$work_dir/macos/Codex-arm64.dmg")"
wxs="$(size_of "$work_dir/windows/ChatGPT-x64.msix")"; lis="$(size_of "$work_dir/windows/ChatGPT-License.xml")"; mas="$(size_of "$work_dir/macos/Codex-arm64.dmg")"
windows_key="codex/windows/$windows_version/ChatGPT-x64.msix"
license_key="codex/windows/$windows_version/ChatGPT-License.xml"
mac_key="codex/macos/$mac_version/Codex-arm64.dmg"

# --- Publish ----------------------------------------------------------------
upload() {
  aws s3 cp "$1" "s3://$R2_BUCKET_NAME/$2" --endpoint-url "$endpoint" --only-show-errors --content-type "$3" --cache-control "$4"
}
upload "$work_dir/windows/ChatGPT-x64.msix" "$windows_key" "application/vnd.ms-appx" "public, max-age=31536000, immutable"
upload "$work_dir/windows/ChatGPT-License.xml" "$license_key" "application/xml; charset=utf-8" "public, max-age=31536000, immutable"
upload "$work_dir/macos/Codex-arm64.dmg" "$mac_key" "application/x-apple-diskimage" "public, max-age=31536000, immutable"

verify_object() {
  local file="$1" key="$2" expected_size="$3" expected_sha256="$4"
  actual_size="$(aws s3api head-object --bucket "$R2_BUCKET_NAME" --key "$key" \
    --endpoint-url "$endpoint" --query ContentLength --output text)"
  [[ "$actual_size" == "$expected_size" ]] || {
    printf 'R2 readback size mismatch for %s: %s != %s\n' "$key" "$actual_size" "$expected_size" >&2
    exit 1
  }
  [[ "$(sha256 "$file")" == "$expected_sha256" ]] || {
    printf 'Local checksum changed during publish: %s\n' "$file" >&2
    exit 1
  }
  readback="$work_dir/metadata/readback-$(basename "$file")"
  aws s3 cp "s3://$R2_BUCKET_NAME/$key" "$readback" \
    --endpoint-url "$endpoint" --only-show-errors
  [[ "$(size_of "$readback")" == "$expected_size" ]] || {
    printf 'R2 readback byte count mismatch for %s\n' "$key" >&2
    exit 1
  }
  [[ "$(sha256 "$readback")" == "$expected_sha256" ]] || {
    printf 'R2 readback checksum mismatch for %s\n' "$key" >&2
    exit 1
  }
  rm -f "$readback"
}
verify_object "$work_dir/windows/ChatGPT-x64.msix" "$windows_key" "$wxs" "$wx"
verify_object "$work_dir/windows/ChatGPT-License.xml" "$license_key" "$lis" "$li"
verify_object "$work_dir/macos/Codex-arm64.dmg" "$mac_key" "$mas" "$ma"

catalog="$work_dir/metadata/latest.json"
jq -n --arg wv "$windows_version" --arg mv "$mac_version" --arg t "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg wu "$base_url/$windows_key" --arg lu "$base_url/$license_key" --arg mu "$base_url/$mac_key" \
  --arg wh "$wx" --argjson ws "$wxs" --arg lh "$li" --argjson ls "$lis" --arg mh "$ma" --argjson ms "$mas" \
  '{schemaVersion:1,product:"ChatGPT Desktop",publishedAt:$t,platforms:{"windows-x86_64":{version:$wv,url:$wu,sha256:$wh,size:$ws,licenseUrl:$lu,licenseSha256:$lh,licenseSize:$ls},"darwin-aarch64":{version:$mv,url:$mu,sha256:$mh,size:$ms}}}' > "$catalog"
upload "$catalog" "codex/latest.json" "application/json; charset=utf-8" "no-cache, no-store, must-revalidate"

# --- Retain the current and the previous version ---------------------------
# A Rabah Desktop that read the previous catalog moments ago may still be
# downloading from it, so its objects survive one more publish. Without a
# readable previous catalog nothing is deleted this run.
if [[ ! -s "$previous_catalog" ]]; then
  printf 'Previous catalog unavailable; keeping every existing object this run.\n'
else
  keep="$work_dir/metadata/keep.txt"
  {
    printf '%s\n' codex/latest.json "$windows_key" "$license_key" "$mac_key"
    jq -r '.platforms[] | .url, (.licenseUrl // empty)' "$previous_catalog" | while IFS= read -r url; do
      key_of "$url"
      printf '\n'
    done
  } > "$keep"
  while IFS= read -r key; do
    [[ -z "$key" || "$key" == "None" ]] && continue
    grep -qxF "$key" "$keep" && continue
    aws s3api delete-object --bucket "$R2_BUCKET_NAME" --key "$key" --endpoint-url "$endpoint" >/dev/null
    printf 'Removed superseded object: %s\n' "$key"
  done < <(aws s3api list-objects-v2 --bucket "$R2_BUCKET_NAME" --prefix codex/ --endpoint-url "$endpoint" --query 'Contents[].Key' --output text | tr '\t' '\n')
fi
printf 'ChatGPT Desktop R2 mirror published: Windows %s, macOS %s\n' "$windows_version" "$mac_version"
