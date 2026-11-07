"""Validate reuse and rejection of owned native CI cache prefixes."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("build_tmux", "tools/ci/build_tmux.py")
build_tmux = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_tmux)


class CacheTests(unittest.TestCase):
    def test_reuse_and_corruption_rebuild(self):
        native = Path(os.environ.get("LIBTMUX_TEST_TMUX") or shutil.which("tmux")).resolve()
        version = subprocess.check_output([str(native), "-V"], text=True).strip().removeprefix("tmux ")
        identity = {"version": version, "source": "fixture"}
        with tempfile.TemporaryDirectory(prefix="erlang-cache-") as directory:
            root = Path(directory)
            prefix = root / "owned"
            sibling = root / "borrowed"
            sibling.write_text("preserve")

            def compile_fresh(destination, _):
                self.assertFalse(destination.exists())
                (destination / "bin").mkdir(parents=True)
                shutil.copy2(native, destination / "bin/tmux")

            with patch.object(build_tmux, "build", side_effect=compile_fresh) as compiler:
                self.assertTrue(build_tmux.prepare(prefix, identity))
                self.assertFalse(build_tmux.prepare(prefix, identity))
                self.assertEqual(1, compiler.call_count)
                with (prefix / "bin/tmux").open("ab") as binary:
                    binary.write(b"changed")
                self.assertFalse(build_tmux.valid(prefix, identity))
                self.assertTrue(build_tmux.prepare(prefix, identity))
                self.assertEqual(2, compiler.call_count)
                self.assertEqual("preserve", sibling.read_text())

    def test_symlink_prefix_preserves_target(self):
        native = Path(os.environ.get("LIBTMUX_TEST_TMUX") or shutil.which("tmux")).resolve()
        version = subprocess.check_output([str(native), "-V"], text=True).strip().removeprefix("tmux ")
        with tempfile.TemporaryDirectory(prefix="erlang-cache-") as directory:
            root = Path(directory)
            target = root / "borrowed"
            target.mkdir()
            marker = target / "preserve"
            marker.write_text("untouched")
            prefix = root / "owned"
            prefix.symlink_to(target, target_is_directory=True)

            def compile_fresh(destination, _):
                self.assertFalse(destination.exists())
                (destination / "bin").mkdir(parents=True)
                shutil.copy2(native, destination / "bin/tmux")

            with patch.object(build_tmux, "build", side_effect=compile_fresh):
                self.assertTrue(build_tmux.prepare(prefix, {"version": version}))
            self.assertFalse(prefix.is_symlink())
            self.assertEqual("untouched", marker.read_text())


if __name__ == "__main__":
    unittest.main()
