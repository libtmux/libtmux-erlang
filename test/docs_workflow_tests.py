"""Exercise preview cleanup against current PR state without remote writes."""

import json
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


WORKFLOW = Path(".github/workflows/docs-preview-cleanup.yml")


class PreviewCleanupTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(WORKFLOW.is_file(), "close cleanup workflow is missing")
        self.directory = tempfile.TemporaryDirectory(prefix="erlang-docs-cleanup-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name, script in {
            "gh": 'printf "%s\\n" "$@" > "$GH_ARGS"\nprintf "%s\\n" "$GH_RESPONSE"\nexit "${GH_EXIT:-0}"\n',
            "aws": 'printf "%s\\n" "$@" > "$AWS_ARGS"\n',
        }.items():
            tool = self.root / name
            tool.write_text("#!/bin/sh\n" + script)
            tool.chmod(0o755)
        self.env = {
            "PATH": f"{self.root}:/usr/bin:/bin",
            "PR": "42",
            "REPOSITORY": "libtmux/libtmux-erlang",
            "BUCKET": "docs-test",
            "GITHUB_OUTPUT": str(self.root / "outputs"),
            "GH_ARGS": str(self.root / "gh-args"),
            "AWS_ARGS": str(self.root / "aws-args"),
        }

    def run_step(self, name, **env):
        source = WORKFLOW.read_text().split(f"name: {name}\n", 1)[1]
        match = re.search(r"        run: \|\n((?: {10}[^\n]*\n|\n)+)", source)
        self.assertIsNotNone(match, f"{name} has a shell body")
        return subprocess.run(
            ["/bin/bash", "-c", textwrap.dedent(match[1])],
            env=self.env | env, capture_output=True, text=True, timeout=1,
        )

    def test_current_closed_pr_is_eligible_and_reopened_pr_is_not(self):
        for state, expected in [("closed", "true"), ("open", "false")]:
            with self.subTest(state=state):
                Path(self.env["GITHUB_OUTPUT"]).unlink(missing_ok=True)
                result = self.run_step(
                    "Check current cleanup eligibility",
                    GH_RESPONSE=json.dumps({"number": 42, "state": state}),
                )
                self.assertEqual(0, result.returncode, result.stderr)
                output = Path(self.env["GITHUB_OUTPUT"]).read_text().splitlines()
                self.assertEqual(f"should_cleanup={expected}", output[-1])
                self.assertEqual(
                    ["api", "--method", "GET", "repos/libtmux/libtmux-erlang/pulls/42"],
                    Path(self.env["GH_ARGS"]).read_text().splitlines(),
                )

    def test_invalid_current_response_cannot_authorize_cleanup(self):
        for response in [
            '{"number":43,"state":"closed"}',
            '{"number":42,"state":"unknown"}',
            '[{"number":42,"state":"closed"}]',
            '{"number":42,"state":"closed"}\n{"number":42,"state":"closed"}',
            "not json",
        ]:
            with self.subTest(response=response):
                Path(self.env["GITHUB_OUTPUT"]).unlink(missing_ok=True)
                result = self.run_step("Check current cleanup eligibility", GH_RESPONSE=response)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual("should_cleanup=false\n", Path(self.env["GITHUB_OUTPUT"]).read_text())

    def test_api_failure_cannot_authorize_cleanup(self):
        result = self.run_step("Check current cleanup eligibility", GH_RESPONSE="", GH_EXIT="1")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("should_cleanup=false\n", Path(self.env["GITHUB_OUTPUT"]).read_text())

    def test_deletion_is_scoped_to_one_erlang_preview(self):
        result = self.run_step("Delete this Erlang preview")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            ["s3", "rm", "s3://docs-test/en/erlang/pr-42/", "--recursive"],
            Path(self.env["AWS_ARGS"]).read_text().splitlines(),
        )
        for pr in ["", "0", "-1", "42/../../latest", "42;exit 0"]:
            with self.subTest(pr=pr):
                Path(self.env["AWS_ARGS"]).unlink(missing_ok=True)
                result = self.run_step("Delete this Erlang preview", PR=pr)
                self.assertNotEqual(0, result.returncode)
                self.assertFalse(Path(self.env["AWS_ARGS"]).exists())


if __name__ == "__main__":
    unittest.main()
