"""Offline guards for irreversible package publication."""

import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

SPEC = importlib.util.spec_from_file_location("check_release", "tools/check_release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_tag_matches_semver_exactly(self):
        for version in ("0.0.1", "0.1.0-alpha.1", "1.0.0"):
            self.assertEqual(version, release.validate_version(version, "v" + version))
        for version, tag in (("0.0.0+development", "v0.0.0+development"),
                             ("01.0.0", "v01.0.0"), ("0.0.1", "v0.0.2"),
                             ("0.0.1", "refs/heads/master"),
                             ("0.0.1-alpha.01", "v0.0.1-alpha.01")):
            with self.subTest(version=version, tag=tag), self.assertRaises(ValueError):
                release.validate_version(version, tag)

    def test_tag_must_resolve_to_clean_checkout(self):
        with tempfile.TemporaryDirectory(prefix="erlang-release-test-") as directory:
            root = Path(directory)

            def git(*args):
                subprocess.run(["git", *args], cwd=root, check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

            git("init", "--quiet")
            (root / "source").write_text("first")
            git("add", "source")
            git("-c", "user.name=Release Test", "-c", "user.email=test@example.invalid",
                "commit", "--quiet", "-m", "fixture")
            git("tag", "v0.0.1")
            release.validate_checkout(root, "v0.0.1")
            (root / "source").write_text("dirty")
            with self.assertRaisesRegex(ValueError, "clean"):
                release.validate_checkout(root, "v0.0.1")
            git("add", "source")
            git("-c", "user.name=Release Test", "-c", "user.email=test@example.invalid",
                "commit", "--quiet", "-m", "second")
            with self.assertRaisesRegex(ValueError, "HEAD"):
                release.validate_checkout(root, "v0.0.1")

    def test_registry_absence_is_distinct_from_failure_and_mismatch(self):
        expected = b"qualified source artifact"
        with patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(expected)):
            self.assertTrue(release.published_artifact("0.0.1", expected))
        with patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(b"other")):
            with self.assertRaisesRegex(ValueError, "differs"):
                release.published_artifact("0.0.1", expected)
        for code in (404, 403, 500):
            error = HTTPError("https://repo.hex.pm", code, "fixture", {}, None)
            with patch.object(release.urllib.request, "urlopen", side_effect=error):
                if code == 404:
                    self.assertFalse(release.published_artifact("0.0.1", expected))
                else:
                    with self.assertRaises(HTTPError):
                        release.published_artifact("0.0.1", expected)

    def test_qualification_must_bind_the_same_clean_commit_and_bytes(self):
        proof = {"result": "PASS", "source": {"head": "commit", "status": ""},
                 "packages": {"libtmux_erlang": {"sha256": "digest"}}}
        release.validate_qualification(proof, "commit", "digest")
        for head, digest in (("other", "digest"), ("commit", "other")):
            with self.assertRaises(ValueError):
                release.validate_qualification(proof, head, digest)
        proof["source"]["status"] = " M src/changed.erl"
        with self.assertRaises(ValueError):
            release.validate_qualification(proof, "commit", "digest")
        proof["source"]["status"] = ""
        proof["result"] = "FAIL"
        with self.assertRaises(ValueError):
            release.validate_qualification(proof, "commit", "digest")


if __name__ == "__main__":
    unittest.main()
