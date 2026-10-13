"""Exercise the release pipeline using local GitHub and R2 substitutes."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("sync-latest-release-to-r2.sh")


class ReleaseSyncTest(unittest.TestCase):
    def test_complete_desktop_release_is_published_and_old_updater_is_untouched(self):
        self.run_sync()

    def test_wrong_archive_root_stops_before_upload(self):
        self.run_sync(root="Other.app", fail=True)

    def test_bad_signature_checksum_stops_before_upload(self):
        self.run_sync(bad_signature=True, fail=True)

    def test_readback_failure_keeps_manifests_unchanged(self):
        self.run_sync(corrupt_readback=True, fail=True)

    def test_unexpected_bucket_is_rejected_without_writes(self):
        self.run_sync(bucket_name="unrelated-bucket", fail=True)

    def run_sync(self, root="Rabah Desktop.app", bad_signature=False,
                 corrupt_readback=False, fail=False, bucket_name="rabah-desktop-downloads"):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            assets, bucket, bins = [base / name for name in ("assets", "bucket", "bin")]
            for directory in (assets, bucket, bins):
                directory.mkdir()
            names = ["Rabah-Desktop-Windows-x64-v0.2.0-setup.exe",
                     "Rabah-Desktop-Windows-x64-v0.2.0-setup.exe.sig",
                     "Rabah-Desktop-macOS-arm64-v0.2.0.dmg",
                     "Rabah-Desktop-macOS-arm64-v0.2.0.app.tar.gz",
                     "Rabah-Desktop-macOS-arm64-v0.2.0.app.tar.gz.sig"]
            for name in names:
                (assets / name).write_bytes(name.encode())
            with tarfile.open(assets / names[3], "w:gz") as archive:
                entry = tarfile.TarInfo(root)
                entry.type = tarfile.DIRTYPE
                archive.addfile(entry)
                content = b"app"
                entry = tarfile.TarInfo(root + "/Contents/app")
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
            hashes = [hashlib.sha256((assets / name).read_bytes()).hexdigest() for name in names]
            if bad_signature:
                hashes[1] = "0" * 64
            (assets / "SHA256SUMS.txt").write_text("".join(f"{digest}  {name}\n" for digest, name in zip(hashes, names)))
            release = {"draft": False, "tag_name": "desktop-v0.2.0",
                       "html_url": "https://github.com/is-pan/rabah-desktop-releases/releases/tag/desktop-v0.2.0",
                       "published_at": "2026-10-13T00:00:00Z", "body": "Desktop",
                       "assets": [{"name": name} for name in names + ["SHA256SUMS.txt"]]}
            (base / "releases.json").write_text(json.dumps([release]))
            # The old updater and a previous Desktop version both exist.
            old = bucket / "updater/latest.json"
            old.parent.mkdir()
            old.write_text("old Companion updater")
            stale = bucket / "versions/desktop-v0.1.66/file"
            stale.parent.mkdir(parents=True)
            stale.write_text("old Desktop")
            (bins / "gh").write_text("""#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
base = Path(os.environ['FIXTURE'])
args = sys.argv[1:]
if args[0] == 'api': print((base/'releases.json').read_text())
else:
    out = Path(args[args.index('--dir')+1])
    for i, value in enumerate(args):
        if value == '--pattern': shutil.copyfile(base/'assets'/args[i+1], out/args[i+1])
""")
            (bins / "aws").write_text("""#!/usr/bin/env python3
import os, sys
from pathlib import Path
base = Path(os.environ['FIXTURE']); bucket=base/'bucket'; args=sys.argv[1:]
with (base/'calls').open('a') as log: log.write(' '.join(args)+'\\n')
if args[:2] == ['s3','cp']:
    source, target = args[2:4]
    if source.startswith('s3://'):
        data=(bucket/source.split('/',3)[3]).read_bytes()
        if os.environ.get('CORRUPT_READBACK'): data=b'wrong bytes'
        sys.stdout.buffer.write(data)
    else:
        path=bucket/target.split('/',3)[3]; path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(Path(source).read_bytes())
elif args[1] == 'list-objects-v2':
    print('\\t'.join(str(p.relative_to(bucket)) for p in bucket.rglob('*') if p.is_file() and str(p.relative_to(bucket)).startswith('versions/')))
elif args[1] == 'delete-object': (bucket/args[args.index('--key')+1]).unlink()
""")
            (bins / "sha256sum").write_text("""#!/usr/bin/env python3
import hashlib, sys
from pathlib import Path
data=Path(sys.argv[1]).read_bytes() if len(sys.argv)>1 else sys.stdin.buffer.read()
print(hashlib.sha256(data).hexdigest()+'  file')
""")
            (bins / "stat").write_text("""#!/usr/bin/env python3
import sys
from pathlib import Path
print(Path(sys.argv[-1]).stat().st_size)
""")
            for path in bins.iterdir():
                path.chmod(0o755)
            env = {**os.environ, "PATH": str(bins) + os.pathsep + os.environ["PATH"],
                   "FIXTURE": tmp, "RUNNER_TEMP": tmp, "GITHUB_REPOSITORY": "is-pan/rabah-desktop-releases",
                   "R2_ACCOUNT_ID": "fixture", "R2_ACCESS_KEY_ID": "fixture",
                   "R2_SECRET_ACCESS_KEY": "fixture", "R2_BUCKET_NAME": bucket_name,
                   "DOWNLOAD_BASE_URL": "https://download.rabah.ai"}
            if corrupt_readback:
                env["CORRUPT_READBACK"] = "1"
            result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, not fail, result.stderr + result.stdout)
            self.assertEqual(old.read_text(), "old Companion updater")
            manifest = bucket / "desktop/latest.json"
            if fail:
                self.assertFalse(manifest.exists())
                self.assertTrue(stale.exists())
            else:
                self.assertEqual(json.loads(manifest.read_text())["version"], "0.2.0")
                self.assertFalse((bucket/"desktop/index.html").exists())
                self.assertEqual(json.loads((bucket/"desktop/updater/latest.json").read_text())["version"], "0.2.0")
                self.assertFalse(stale.exists())


if __name__ == "__main__":
    unittest.main()
