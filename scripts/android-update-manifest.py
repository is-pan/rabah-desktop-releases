"""Build Android update metadata from a verified final APK, never from its filename alone."""
import argparse
import json
import re
from pathlib import Path


def build(badging, release, tag, asset, sha256, size, previous=None):
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
    sdk = re.search(r"^sdkVersion:'(\d+)'", badging, re.M)
    if not package or not sdk or package[1] != "ai.rabah.chat":
        raise ValueError("APK identity or minimum SDK is invalid")
    code, version, minimum = int(package[2]), package[3], int(sdk[1])
    if not 1 <= code <= 2_100_000_000 or not 1 <= minimum <= 100:
        raise ValueError("Invalid APK version code or minimum SDK")
    if not re.fullmatch(r"[a-f0-9]{64}", sha256) or not 0 < size <= 1_073_741_824:
        raise ValueError("Invalid APK digest or size")
    if not re.fullmatch(r"android-v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", tag):
        raise ValueError("Invalid Android release tag")
    if not re.fullmatch(r"Rabah-Android-[A-Za-z0-9.-]+\.apk", asset):
        raise ValueError("Invalid APK asset name")
    if not (tag == "android-v" + version or tag.startswith("android-v" + version + "-")):
        raise ValueError("Release tag does not match the actual APK version")
    if release.get("draft") or release.get("tag_name") != tag or not release.get("published_at"):
        raise ValueError("Expected a published Android release")
    url = f"https://download.rabah.ai/android/{tag}/{asset}"
    if previous:
        old_code = previous.get("version_code")
        if not isinstance(old_code, int) or previous.get("package_name") != package[1]:
            raise ValueError("Previous update manifest is invalid")
        if code < old_code:
            raise ValueError("Refusing to publish a lower version code")
        if code == old_code and any(previous.get(k) != v for k, v in
                                    (("sha256", sha256), ("size", size), ("url", url), ("version", version))):
            raise ValueError("A different APK must increase versionCode")
    notes = release.get("body") or ""
    if len(notes) > 24_000:
        raise ValueError("Release notes exceed the client limit")
    return dict(schema_version=1, package_name=package[1], version_code=code,
                version=version, url=url, sha256=sha256, size=size, min_sdk=minimum,
                notes=notes, pub_date=release["published_at"])


def main():
    parser = argparse.ArgumentParser()
    for field in ("badging", "release", "tag", "asset", "sha256", "size", "previous", "output"):
        parser.add_argument("--" + field, required=True, type=int if field == "size" else str)
    args = parser.parse_args()
    previous = Path(args.previous)
    result = build(Path(args.badging).read_text(), json.loads(Path(args.release).read_text()),
                   args.tag, args.asset, args.sha256, args.size,
                   json.loads(previous.read_text()) if previous.exists() else None)
    raw = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if len(raw.encode()) > 64 * 1024:
        raise ValueError("Update manifest exceeds the client size limit")
    Path(args.output).write_text(raw)


if __name__ == "__main__":
    main()
