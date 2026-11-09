import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("manifest", Path(__file__).with_name("android-update-manifest.py"))
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class AndroidManifestTest(unittest.TestCase):
    def metadata(self, code=2, previous=None, **changes):
        values = dict(badging=f"package: name='ai.rabah.chat' versionCode='{code}' versionName='0.1.1'\nsdkVersion:'26'\n",
                      release=dict(tag_name="android-v0.1.1", published_at="2026-11-09T00:00:00Z", draft=False, body="Changes"),
                      tag="android-v0.1.1", asset="Rabah-Android-0.1.1.apk", sha256="a" * 64, size=123, previous=previous)
        values.update(changes)
        return manifest.build(**values)

    def test_manifest_uses_real_apk_version_and_immutable_url(self):
        result = self.metadata()
        self.assertEqual(result["version_code"], 2)
        self.assertEqual(result["min_sdk"], 26)
        self.assertEqual(result["url"], "https://download.rabah.ai/android/android-v0.1.1/Rabah-Android-0.1.1.apk")
        self.assertEqual(result["notes"], "Changes")

    def test_idempotent_publication_allows_exact_same_apk(self):
        first = self.metadata()
        self.assertEqual(self.metadata(previous=first), first)

    def test_same_version_different_bytes_and_downgrade_are_rejected(self):
        first = self.metadata()
        with self.assertRaises(ValueError): self.metadata(previous=first, sha256="b" * 64)
        with self.assertRaises(ValueError): self.metadata(code=1, previous=first)

    def test_unpublished_wrong_package_and_mismatched_tag_are_rejected(self):
        for changes in [dict(release=dict(draft=True)), dict(badging="package: name='other' versionCode='2' versionName='0.1.1'\nsdkVersion:'26'"),
                        dict(tag="android-v0.2.0"), dict(asset="../Rabah-Android.apk")]:
            with self.subTest(changes=changes), self.assertRaises(ValueError): self.metadata(**changes)


if __name__ == "__main__": unittest.main()
