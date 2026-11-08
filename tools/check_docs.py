#!/usr/bin/env python3
"""Check guide links, source excerpts, configuration terms and example output."""

import argparse
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import unquote, urlsplit
from check_example_width import columns


class PageLinks(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.links, self.resources, self.anchors = [], [], set()
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            self.anchors.add(attrs["id"])
        if tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])
        if tag in {"img", "script"} and attrs.get("src"):
            self.resources.append(attrs["src"])
        if tag == "link" and attrs.get("href"):
            self.resources.append(attrs["href"])
        if tag in {"img", "source"} and attrs.get("srcset"):
            if not attrs["srcset"].startswith("data:"):
                self.resources.extend(part.strip().split()[0]
                    for part in attrs["srcset"].split(",") if part.strip())


def check_html(directory, root):
    pages = {p.resolve(): PageLinks(p.read_text()) for p in directory.rglob("*.html")}
    checked = 0
    for path, page in pages.items():
        for target in page.links + page.resources:
            url = urlsplit(target)
            if url.netloc == "github.com" and url.path.startswith("/libtmux/libtmux-erlang/blob/"):
                revision, _, source = url.path.removeprefix("/libtmux/libtmux-erlang/blob/").partition("/")
                result = subprocess.run(["git", "cat-file", "-e", revision + ":" + unquote(source)],
                                        cwd=root, capture_output=True)
                assert result.returncode == 0, (path.name, target, "missing source at revision")
                checked += 1
            elif not url.scheme and not url.netloc:
                resolved = (path.parent / unquote(url.path)).resolve() if url.path else path
                assert resolved.exists(), (path.name, target, "missing rendered target")
                if url.fragment and resolved in pages:
                    assert unquote(url.fragment) in pages[resolved].anchors, (path.name, target, "missing anchor")
                checked += 1
    return {"pages": len(pages), "links": checked,
            "resources": sum(len(page.resources) for page in pages.values())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples-receipt", type=Path)
    parser.add_argument("--html-directory", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    started = time.monotonic()
    files = [Path("README.md"), *sorted(Path("docs").glob("*.md")),
             *sorted(Path("apps").glob("*/README.md"))]
    outputs = {}
    if args.examples_receipt:
        result = json.loads(args.examples_receipt.read_text())
        assert result["result"] == "PASS"
        for example in result["examples"]:
            assert example["owned_cleanup"] == "complete" and example["sessions_removed"]
            outputs[example["module"]] = example["output"]
    programs, terms, displayed_outputs, inputs, console = [], [], [], [], 0
    native_lines = 0
    for path in sorted(Path("apps").glob("*/src/*.erl")):
        for block in re.finditer(r"^```erlang\n(.*?)^```", path.read_text(), re.M | re.S):
            for line in block[1].splitlines():
                # ct_doctest uses numbered prompts; replies are compared output.
                if re.match(r"^\s*(?:[0-9]+|\.\.\.)> ", line):
                    assert columns(line) <= 80, (path, "native example wider than 80", line)
                    native_lines += 1
    for path in files:
        text = path.read_text()
        for target in re.findall(r"(?<!!)\[[^\]]+\]\(([^)]+)\)", text):
            if target.startswith(("https:", "http:", "mailto:", "#")):
                continue
            name, _, fragment = target.partition("#")
            resolved = (path.parent / name).resolve()
            assert resolved.is_relative_to(root) and resolved.exists(), (path, target)
            if fragment and resolved.suffix == ".md":
                headings = re.findall(r"^#{1,6}\s+(.+)$", resolved.read_text(), re.M)
                slugs = [re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-") for h in headings]
                assert fragment in slugs, (path, target, slugs)
        for block in re.finditer(r"^```([^\n]*)\n(.*?)^```", text, re.M | re.S):
            language, body = block.groups()
            before = text[:block.start()].rstrip()
            if language == "erlang":
                marker = re.search(r"<!-- example: ([^ ]+) -->$", before)
                if marker:
                    source = Path(marker[1])
                    assert source.is_file() and body.rstrip() == source.read_text().rstrip(), (path, source, "example drift")
                    programs.append(source.as_posix())
                else:
                    assert before.endswith("<!-- erlang-term -->"), (path, "unclassified Erlang block")
                    terms.append(body)
            elif language == "json":
                source = re.search(r"<!-- example-input: ([^ ]+) -->$", before)
                if source:
                    input_path = Path(source[1])
                    assert body.rstrip() == input_path.read_text().rstrip(), (path, "input drift")
                    json.loads(body)
                    inputs.append(input_path.as_posix())
                    continue
                marker = re.search(r"<!-- example-output: ([^ ]+) -->$", before)
                assert marker, (path, "unclassified JSON block")
                expected = json.loads(body)
                if args.examples_receipt:
                    assert outputs[marker[1]] == expected, (path, marker[1], "output drift")
                displayed_outputs.append(marker[1])
            elif language == "console":
                assert body.startswith("$ ") and len(re.findall(r"^\$ ", body, re.M)) == 1, (path, "console unit")
                console += 1
            else:
                raise AssertionError((path, "unclassified code block", language))
    check = Path("_build/checks")
    check.mkdir(parents=True, exist_ok=True)
    (check / "doc-terms.config").write_text("\n".join(terms))
    env = dict(os.environ)
    env.setdefault("ERL_FLAGS", "+S 4:4")
    subprocess.run(["erl", "-noshell", "-noinput", "-eval",
        'case file:consult("_build/checks/doc-terms.config") of {ok,_}->halt(0); E->io:format("~p~n",[E]),halt(1) end.'],
        check=True, timeout=5, env=env)
    receipt = {"result": "PASS", "files": len(files), "programs": sorted(set(programs)),
               "configuration_blocks": len(terms), "console_units": console,
               "native_code_lines": native_lines,
               "input_files": sorted(set(inputs)),
               "displayed_outputs": displayed_outputs,
               "runtime_output": "PASS" if args.examples_receipt else "UNVERIFIED in this static check",
               "seconds": round(time.monotonic() - started, 6)}
    if args.html_directory:
        receipt["rendered"] = check_html(args.html_directory, root)
        receipt["seconds"] = round(time.monotonic() - started, 6)
    name = "docs-rendered.json" if args.html_directory else (
        "docs-corpus-runtime.json" if args.examples_receipt else "docs-corpus.json")
    (check / name).write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
