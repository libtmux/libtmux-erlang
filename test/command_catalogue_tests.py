"""Keep source refresh from silently discarding explicit command aliases."""

import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("commands", "tools/generate_commands.py")
commands = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(commands)


class CommandCatalogueTests(unittest.TestCase):
    def test_unrecognized_explicit_alias_fails_closed(self):
        names = ["attach-session", "list-sessions", "list-windows", "list-panes",
                 "send-keys", "list-keys", "select-layout"]
        symbols = ["cmd_" + name.replace("-", "_") + "_entry" for name in names]
        table = "const struct cmd_entry *cmd_table[] = {\n" + "".join(
            "&" + symbol + ",\n" for symbol in symbols) + "NULL\n};"
        entries = []
        for name, symbol in zip(names, symbols):
            alias = '.alias = "att" "ach",\n' if name == "attach-session" else ""
            entries.append("const struct cmd_entry " + symbol + " = {\n"
                + '.name = "' + name + '",\n' + alias
                + '.args = { "c:f:F:K", 0, 0, NULL },\n};\n')
        files = {"cmd.c": table.encode(), "cmd-fixture.c": "".join(entries).encode(),
                 "layout-custom.c": b"layout_parse_json()"}

        def source(arguments, **_):
            if "ls-tree" in arguments:
                return "cmd-fixture.c\n"
            return files[arguments[-1].split(":", 1)[1]]

        with patch.object(commands.subprocess, "check_output", side_effect=source):
            original = files["cmd-fixture.c"]
            for alias in [b'.alias = "att" "ach",',
                          b'.alias /* field comment */ = "attach",']:
                with self.subTest(alias=alias):
                    files["cmd-fixture.c"] = original.replace(
                        b'.alias = "att" "ach",', alias)
                    with self.assertRaisesRegex(ValueError, "alias"):
                        commands.refresh(Path("unused-fixture-tree"))


if __name__ == "__main__":
    unittest.main()
