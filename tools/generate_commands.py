#!/usr/bin/env python3
"""Generate native command metadata and capability floors from pinned sources."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "schema/commands.json"
MODULE = ROOT / "apps/libtmux_erlang/src/tmux_capability_data.erl"
REFERENCE = ROOT / "docs/commands-reference.md"
STRING = r'"(?:[^"\\]|\\.)*"'
FEATURES = {
    "native_list_filter": {
        "description": "Native -f filters on session, window and pane list commands.",
        "commands": ["list-sessions", "list-windows", "list-panes"],
    },
    "send_client_keys": {
        "description": "Native send-keys -K and -c for client-directed key input.",
        "commands": ["send-keys"],
    },
    "key_list_format": {
        "description": "Native list-keys -F custom formatting.",
        "commands": ["list-keys"],
    },
    "layout_json": {
        "description": "Native JSON layout parsing, including the v2 layout representation.",
        "commands": ["select-layout"],
    },
}
FIELDS = {
    "version", "sources", "commands", "features", "commit", "files", "sha256",
    "alias", "argument_spec", "min_args", "max_args", "file", "metadata",
    "versions", "minimum", "description",
}


def number(version: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)[a-z]?", version)
    if match is None:
        raise ValueError(f"unsupported release spelling: {version}")
    return int(match[1]), int(match[2])


def refresh(tree: Path) -> dict:
    pins = json.loads((ROOT / "tools/ci/tmux-sources.json").read_text())["versions"]
    sources, commands = {}, {}
    availability = {name: [] for name in FEATURES}
    for version, pin in pins.items():
        def read(path: str) -> bytes:
            return subprocess.check_output(
                ["git", "-C", str(tree), "show", f"{pin['commit']}:{path}"])

        table_source = read("cmd.c")
        table = re.search(rb"cmd_table\[\]\s*=\s*\{(.*?)\n\};", table_source, re.S)[1]
        symbols = re.findall(rb"&(cmd_\w+_entry)", table)
        remainder = re.sub(rb"&(cmd_\w+_entry)|NULL|[\s,]", b"", table)
        if remainder or len(symbols) != len(set(symbols)) or not symbols:
            raise ValueError(f"unrecognized command table: {version}")
        paths = subprocess.check_output(
            ["git", "-C", str(tree), "ls-tree", "--name-only", pin["commit"]],
            text=True).splitlines()
        files = {p: read(p) for p in paths if re.fullmatch(r"cmd-[a-z-]+\.c", p)}
        files.update({"cmd.c": table_source, "layout-custom.c": read("layout-custom.c")})
        entries = {}
        for path, source in files.items():
            for match in re.finditer(
                r"const struct cmd_entry (cmd_\w+_entry)\s*=\s*\{(.*?)\n\};",
                source.decode(), re.S
            ):
                symbol, body = match.groups()
                if re.search(r"^\s*#", body, re.M):
                    raise ValueError(f"conditional command initializer: {symbol}")
                name = re.search(r"\.name\s*=\s*(" + STRING + r")\s*,", body)
                alias = re.search(r"\.alias\s*=\s*(" + STRING + r"|NULL)\s*,", body)
                if alias is None and re.search(r"\.alias\b", body):
                    raise ValueError(f"unrecognized explicit command alias: {symbol}")
                args = re.search(
                    r"\.args\s*=\s*\{\s*(" + STRING + r")\s*,\s*(\d+)\s*,"
                    r"\s*(-?\d+)\s*,\s*(?:NULL|[a-z_]+)\s*\}", body)
                if name is None or args is None or symbol in entries:
                    raise ValueError(f"unrecognized command initializer: {symbol}")
                canonical = ast.literal_eval(name[1])
                if not re.fullmatch(r"[a-z]+(?:-[a-z]+)+", canonical):
                    raise ValueError(f"invalid canonical command: {canonical}")
                low, high = int(args[2]), int(args[3])
                if high < -1 or (high >= 0 and low > high):
                    raise ValueError(f"invalid argument bounds: {canonical}")
                entries[symbol.encode()] = (canonical, {
                    "alias": None if alias is None or alias[1] == "NULL"
                    else ast.literal_eval(alias[1]),
                    "argument_spec": ast.literal_eval(args[1]),
                    "min_args": low, "max_args": None if high == -1 else high,
                    "file": path,
                })
        current = {}
        for symbol in symbols:
            name, metadata = entries[symbol]
            if name in current:
                raise ValueError(f"duplicate canonical command: {name}")
            current[name] = metadata
            variants = commands.setdefault(name, [])
            for variant in variants:
                if variant["metadata"] == metadata:
                    variant["versions"].append(version)
                    break
            else:
                variants.append({"versions": [version], "metadata": metadata})
        sources[version] = {"commit": pin["commit"], "files": {
            path: hashlib.sha256(value).hexdigest() for path, value in sorted(files.items())}}
        supported = {
            "native_list_filter": all("f:" in current[c]["argument_spec"]
                for c in FEATURES["native_list_filter"]["commands"]),
            "send_client_keys": "K" in current["send-keys"]["argument_spec"]
                and "c:" in current["send-keys"]["argument_spec"],
            "key_list_format": "F:" in current["list-keys"]["argument_spec"],
            "layout_json": b"layout_parse_json(" in files["layout-custom.c"],
        }
        for name, present in supported.items():
            if present:
                availability[name].append(version)
    features = {}
    for name, metadata in FEATURES.items():
        versions = availability[name]
        minimum = min(map(number, versions))
        if versions != [v for v in pins if number(v) >= minimum]:
            raise ValueError(f"capability needs a non-monotonic policy: {name}")
        features[name] = metadata | {"minimum": list(minimum), "versions": versions}
    return {"version": 1, "versions": list(pins), "sources": sources, "features": features,
            "commands": dict(sorted(commands.items()))}


def erlang(value) -> str:
    if value is None:
        return "none"
    if isinstance(value, str):
        return "<<" + json.dumps(value, ensure_ascii=True) + ">>"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(map(erlang, value)) + "]"
    if isinstance(value, dict):
        return "#{" + ",\n".join(
            (key if key in FIELDS else erlang(key)) + " => " + erlang(item)
            for key, item in value.items()) + "}"
    raise ValueError(f"unsupported generated value: {value!r}")


def generated(data: dict) -> dict[Path, str]:
    module = ("%% Generated by tools/generate_commands.py; do not edit.\n"
              "-module(tmux_capability_data).\n-moduledoc false.\n"
              "-export([all/0]).\n-spec all() -> map().\nall() ->\n"
              + erlang(data) + ".\n")
    lines = ["# Native commands and capability floors\n\n",
        "Generated from the same pinned tmux commits as CI. These are native\n",
        "parser declarations, not an inventory of implemented Erlang facades,\n",
        "complete argument validation or runtime qualification. Canonical names\n",
        "are lookup keys; aliases are reported as metadata. The\n",
        "`m:tmux_capability` performs pure lookups. Trusted raw commands remain\n",
        "available through `tmux_command:raw/2`.\n\n",
        "## Capability minimums\n\n",
        "Minimums match the sampled release matrix. They do not qualify other\n",
        "releases, tracking builds, platforms or new typed API options.\n\n",
        "| Capability | Minimum tmux | Native behavior |\n",
        "| --- | --- | --- |\n"]
    for name, metadata in sorted(data["features"].items()):
        minimum = ".".join(map(str, metadata["minimum"]))
        lines.append(f"| `{name}` | {minimum} | {metadata['description']} |\n")
    lines += ["\n## Source profiles\n\n",
        "Exact parser discovery rejects profiles absent from this table.\n\n",
        "| Profile | Pinned command table | Commands |\n| --- | --- | --- |\n"]
    for version, source in data["sources"].items():
        count = sum(any(version in variant["versions"] for variant in variants)
                    for variants in data["commands"].values())
        url = f"https://github.com/tmux/tmux/blob/{source['commit']}/cmd.c"
        lines.append(f"| {version} | [Source]({url}) | {count} |\n")
    lines += ["\n## Parser declarations\n\n",
        "The argument spec is tmux's native flag declaration. Positional bounds\n",
        "exclude flags; an unlimited upper bound is shown as unbounded. Callbacks\n",
        "and command bodies can impose additional constraints. This catalogue\n",
        "does not interpret formats, shell commands or stored command syntax.\n\n",
        "| Command | Alias | Profiles | Argument spec | Positionals | Source |\n",
        "| --- | --- | --- | --- | --- | --- |\n"]
    for name, variants in data["commands"].items():
        for variant in variants:
            metadata = variant["metadata"]
            profiles = ", ".join(variant["versions"])
            source = data["sources"][variant["versions"][-1]]
            url = f"https://github.com/tmux/tmux/blob/{source['commit']}/{metadata['file']}"
            high = metadata["max_args"] if metadata["max_args"] is not None else "unbounded"
            lines.append(f"| `{name}` | {metadata['alias'] or '—'} | {profiles} | "
                         f"`{metadata['argument_spec']}` | {metadata['min_args']}..{high} | "
                         f"[Declaration]({url}) |\n")
    return {MODULE: module, REFERENCE: "".join(lines)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh-from", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.refresh_from and args.check:
        parser.error("refresh and drift checking are separate operations")
    if args.refresh_from:
        data = refresh(args.refresh_from)
        SCHEMA.write_text(json.dumps(data, indent=2) + "\n")
    else:
        data = json.loads(SCHEMA.read_text())
    pins = json.loads((ROOT / "tools/ci/tmux-sources.json").read_text())["versions"]
    if data["version"] != 1 or data["versions"] != list(pins):
        raise ValueError("command catalogue profiles differ from CI pins")
    if {v: s["commit"] for v, s in data["sources"].items()} != {
        v: p["commit"] for v, p in pins.items()
    }:
        raise ValueError("command catalogue source commits differ from CI pins")
    if set(data["features"]) != set(FEATURES):
        raise ValueError("unknown or missing capability policy")
    for name, feature in data["features"].items():
        minimum = feature["minimum"]
        if (len(minimum) != 2 or any(type(n) is not int or n < 0 for n in minimum)
                or feature["versions"] != [v for v in pins if number(v) >= tuple(minimum)]):
            raise ValueError(f"invalid capability minimum/profile policy: {name}")
    for name, variants in data["commands"].items():
        seen = set()
        for variant in variants:
            profiles = variant["versions"]
            if not profiles or seen.intersection(profiles) or set(profiles) - set(pins):
                raise ValueError(f"invalid command profiles: {name}")
            seen.update(profiles)
            for profile in profiles:
                digest = data["sources"][profile]["files"][variant["metadata"]["file"]]
                if re.fullmatch(r"[a-f0-9]{64}", digest) is None:
                    raise ValueError(f"invalid command source digest: {name}")
    for path, content in generated(data).items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f"generated file drift: {path.relative_to(ROOT)}")
        else:
            path.write_text(content)


if __name__ == "__main__":
    main()
