import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("ios_manifest", Path(__file__).with_name("ios-update-manifest.py"))
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class IOSManifestTests(unittest.TestCase):
    def record(self, **changes):
        value = dict(channel="testflight", bundle_id="com.rabah.chat", version="0.2.0", build="2026111001",
                     minimum_os_version="18.0", testflight_url="https://testflight.apple.com/join/AbCd1234",
                     notes="Changes", published_at="2026-11-10T00:00:00Z", available_to_testers=True)
        value.update(changes)
        return value

    def test_ready_build_and_idempotent_metadata(self):
        value = manifest.build(self.record())
        self.assertEqual(value["build"], "2026111001")
        self.assertNotIn("available_to_testers", value)
        self.assertEqual(manifest.build(self.record(), value), value)

    def test_upload_alone_or_wrong_channel_is_not_a_release(self):
        for change in [dict(available_to_testers=False), dict(channel="appstore"), dict(bundle_id="other")]:
            with self.subTest(change=change), self.assertRaises(ValueError): manifest.build(self.record(**change))

    def test_downgrade_and_same_build_metadata_mutation_are_rejected(self):
        previous = manifest.build(self.record())
        for change in [dict(build="2026110801"), dict(version="0.1.9", build="999999999999"), dict(notes="Changed")]:
            with self.subTest(change=change), self.assertRaises(ValueError): manifest.build(self.record(**change), previous)

    def test_new_marketing_version_can_restart_build_number(self):
        previous = manifest.build(self.record())
        self.assertEqual(manifest.build(self.record(version="0.3.0", build="1"), previous)["version"], "0.3.0")

    def test_invalid_link_version_and_notes_are_rejected(self):
        for change in [dict(testflight_url="https://evil.example/join/AbCd1234"), dict(testflight_url="https://testflight.apple.com/join/AbCd1234?x=1"),
                       dict(build="2026abc"), dict(build="1.2.3.4"), dict(notes="a" * 24_001), dict(published_at="invalid")]:
            with self.subTest(change=change), self.assertRaises(ValueError): manifest.build(self.record(**change))

    def test_invitation_link_is_validated_before_url_normalization(self):
        for url in ["https://testflight.apple.com/join/AbCd\n1234", "https://testflight.apple.com/join/AbCd\t1234",
                    "\nhttps://testflight.apple.com/join/AbCd1234", "https://testflight.apple.com/join/AbCd1234\n",
                    "https://testflight.apple.com:443/join/AbCd1234", "https://user@testflight.apple.com/join/AbCd1234",
                    "https://testflight.apple.com/join/AbCd%3134", None]:
            with self.subTest(url=url), self.assertRaises(ValueError): manifest.build(self.record(testflight_url=url))


if __name__ == "__main__": unittest.main()
