"""Generate a TestFlight release pointer only after the build is available to testers."""
import argparse
import datetime
import json
import re
from pathlib import Path


def components(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,18}(?:\.[0-9]{1,18}){0,2}", value):
        raise ValueError("Expected a numeric version or build with one to three components")
    return tuple(int(x) for x in value.split(".")) + (0,) * (3 - len(value.split(".")))


def build(record, previous=None):
    if record.get("available_to_testers") is not True:
        raise ValueError("Confirm Apple processing/review and tester-group availability before publishing")
    if record.get("bundle_id") != "com.rabah.chat" or record.get("channel") != "testflight":
        raise ValueError("Expected the Rabah TestFlight distribution channel")
    version, number = components(record.get("version")), components(record.get("build"))
    components(record.get("minimum_os_version"))
    target = record.get("testflight_url", "")
    if not isinstance(target, str) or not re.fullmatch(r"https://testflight\.apple\.com/join/[A-Za-z0-9]{8}", target):
        raise ValueError("Use the verified HTTPS public invitation link for this TestFlight group")
    published = record.get("published_at", "")
    datetime.datetime.strptime(published, "%Y-%m-%dT%H:%M:%SZ")
    notes = record.get("notes", "")
    if not isinstance(notes, str) or len(notes.encode()) > 24_000:
        raise ValueError("Release notes exceed the client limit")
    result = dict(schema_version=1, channel="testflight", bundle_id="com.rabah.chat",
                  version=record["version"], build=record["build"], notes=notes,
                  published_at=published, testflight_url=target, minimum_os_version=record["minimum_os_version"])
    if previous:
        if previous.get("bundle_id") != result["bundle_id"] or previous.get("channel") != result["channel"]:
            raise ValueError("Previous manifest belongs to a different distribution channel")
        old = components(previous.get("version")), components(previous.get("build"))
        if (version, number) < old:
            raise ValueError("Refusing to move TestFlight users to an older release")
        if (version, number) == old and previous != result:
            raise ValueError("A released build is immutable; publish a new build for changed metadata")
    if len(json.dumps(result, ensure_ascii=False).encode()) > 64 * 1024:
        raise ValueError("Manifest exceeds the client size limit")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    previous = json.loads(args.previous.read_text()) if args.previous and args.previous.exists() else None
    value = build(json.loads(args.record.read_text()), previous)
    args.output.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
