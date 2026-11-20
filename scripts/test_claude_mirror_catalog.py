"""Offline regression tests for the Claude mirror's catalog and retention."""

import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).with_name("sync-claude-desktop-to-r2.sh")
BASE_URL = "https://downloads.example.invalid"
WIN_VERSION = "5.11492.5"
MAC_VERSION = "6.28899.2"
WIN_KEY = f"claude/windows/{WIN_VERSION}.0/Claude-x64.msix"
MAC_KEY = f"claude/macos/{MAC_VERSION}/Claude-universal.dmg"
NEXT_WIN = "claude/windows/7.1.2.0/Claude-x64.msix"
NEXT_MAC = "claude/macos/7.1.2/Claude-universal.dmg"
STALE_WIN = "claude/windows/4.1.2.0/Claude-x64.msix"
STALE_MAC = "claude/macos/4.1.2/Claude-universal.dmg"
SHA = "a" * 64


class ClaudeMirrorCatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = SOURCE.read_text(encoding="utf-8")
        patterns = re.findall(r"(?m)^(?:windows|macos)_key_pattern=.*$", script)
        if len(patterns) != 2:
            raise ValueError("Missing Claude catalog key patterns")
        helpers = []
        for name in ("normalize_version", "catalog_rows", "mirror_is_current", "prune_old_packages"):
            match = re.search(rf"(?ms)^{name}\(\) \{{(?:[^\n]*\}}$|.*?^\}}$)", script)
            if match is None:
                raise ValueError(f"Missing shell function {name}")
            helpers.append(match.group())
        cls.harness = "\n".join([
            "set -euo pipefail",
            'mode="$1" catalog="$2" base_url="$3" windows_version="$4" macos_release_version="$5"',
            'damaged_key="$6" windows_key="$7" macos_key="$8" listing_file="$9"',
            'R2_BUCKET_NAME=fixture endpoint=https://r2.example.invalid',
            "unset macos_version",
            *patterns,
            *helpers,
            'object_intact() { printf "check %s %s %s\n" "$1" "$2" "$3"; [[ "$1" != "$damaged_key" ]]; }',
            """aws() {
  case "$1 $2" in
    's3api list-objects-v2') cat "$listing_file" ;;
    's3api delete-object') printf "delete %s\n" "$6" >&2 ;;
    *) return 99 ;;
  esac
}""",
            'rows="$(catalog_rows "$catalog")" || rows=""',
            'case "$mode" in',
            '  current) [[ -n "$rows" ]] && mirror_is_current "$rows" ;;',
            '  prune) prune_old_packages "$rows" ;;',
            'esac',
        ])

    def catalog(self, win_version=WIN_VERSION + ".0", mac_version=MAC_VERSION):
        return {"platforms": {
            platform: {"version": version, "url": f"{BASE_URL}/{key}", "size": size, "sha256": SHA}
            for platform, version, key, size in (
                ("windows-x86_64", win_version, WIN_KEY, 10),
                ("darwin-universal", mac_version, MAC_KEY, 20),
            )
        }}

    def run_probe(self, catalog, mode="current", damaged="", current=(NEXT_WIN, NEXT_MAC), listing=()):
        with tempfile.TemporaryDirectory() as tmp:
            catalog_path = Path(tmp) / "catalog.json"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            listing_path = Path(tmp) / "objects.txt"
            listing_path.write_text("\t".join(listing), encoding="utf-8")
            return subprocess.run(
                ["bash", "-c", self.harness, "test", mode, str(catalog_path), BASE_URL,
                 WIN_VERSION, MAC_VERSION, damaged, *current, str(listing_path)],
                capture_output=True, text=True, timeout=10,
            )

    def test_current_checks_both_objects_using_independent_upstream_versions(self):
        result = self.run_probe(self.catalog())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [f"check {WIN_KEY} 10 {SHA}", f"check {MAC_KEY} 20 {SHA}"])

    def test_stale_platform_does_not_skip_the_sync(self):
        for catalog in (self.catalog(win_version="5.11492.4"), self.catalog(mac_version="6.28899.1")):
            with self.subTest(catalog=catalog):
                result = self.run_probe(catalog)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (1, "", ""))

    def test_damaged_object_does_not_skip_the_sync(self):
        for key in (WIN_KEY, MAC_KEY):
            with self.subTest(key=key):
                result = self.run_probe(self.catalog(), damaged=key)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertTrue(result.stdout.splitlines()[-1].startswith(f"check {key} "))

    def test_invalid_catalog_neither_skips_nor_prunes(self):
        for changes in (
            None, {"sha256": None}, {"size": 0}, {"url": "https://other.example/Claude.dmg"},
            {"url": f"{BASE_URL}/{WIN_KEY}"},
        ):
            with self.subTest(changes=changes):
                catalog = self.catalog()
                if changes is None:
                    del catalog["platforms"]["darwin-universal"]
                else:
                    catalog["platforms"]["darwin-universal"].update(changes)
                probe = self.run_probe(catalog)
                self.assertEqual((probe.returncode, probe.stdout), (1, ""))
                prune = self.run_probe(catalog, mode="prune", listing=(STALE_WIN, STALE_MAC))
                self.assertEqual(prune.returncode, 0, prune.stderr)
                self.assertNotIn("delete ", prune.stderr)

    def test_prune_keeps_each_current_and_previous_package(self):
        result = self.run_probe(
            self.catalog(), mode="prune",
            listing=(WIN_KEY, MAC_KEY, NEXT_WIN, NEXT_MAC, STALE_WIN, STALE_MAC,
                     "claude/latest.json", "claude/notes.txt"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.splitlines(), [f"delete {STALE_WIN}", f"delete {STALE_MAC}"])

    def test_same_version_repair_preserves_previous_release(self):
        result = self.run_probe(
            self.catalog(), mode="prune", current=(WIN_KEY, MAC_KEY),
            listing=(WIN_KEY, MAC_KEY, STALE_WIN, STALE_MAC),
        )
        self.assertEqual((result.returncode, result.stderr), (0, ""))
