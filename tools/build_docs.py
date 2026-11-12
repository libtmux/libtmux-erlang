#!/usr/bin/env python3
"""Build native EEP-48 API documentation with a pinned ExDoc escript."""

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import urllib.request
from urllib.parse import quote, unquote, urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true", help="download and verify the documentation tool")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    manifest = json.loads(Path("tools/docs-tool.json").read_text())
    executable = Path("_build/tools/ex_doc") / manifest["version"] / "ex_doc"

    def valid():
        return (not executable.is_symlink() and executable.is_file() and
                executable.stat().st_size <= 8 * 1024 * 1024 and
                hashlib.sha256(executable.read_bytes()).hexdigest() == manifest["sha256"])

    if args.prepare:
        if not valid():
            executable.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(manifest["url"], timeout=30) as response:
                data = response.read(8 * 1024 * 1024 + 1)
            if len(data) > 8 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != manifest["sha256"]:
                raise RuntimeError("ExDoc download does not match the pinned digest")
            temporary = executable.with_suffix(".download")
            with temporary.open("xb") as stream:
                stream.write(data)
            temporary.replace(executable)
        print("PASS: verified ExDoc " + manifest["version"] + " for OTP " + manifest["otp"])
        return
    if not valid():
        raise SystemExit("Prepare documentation tools first: python3 tools/build_docs.py --prepare")
    started = time.monotonic()

    def inputs():
        names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).decode().split("\0")
        return {name: hashlib.sha256(Path(name).read_bytes()).hexdigest()
                for name in sorted(set(names)) if name and Path(name).is_file()}

    input_files = inputs()
    env = dict(os.environ)
    env.setdefault("ERL_FLAGS", "+S 4:4")
    subprocess.run(["rebar3", "compile"], check=True, env=env, timeout=30)
    app_ebins = [Path("_build/default/lib/libtmux_erlang/ebin")]
    if any(not (path / (path.parent.name + ".app")).is_file() for path in app_ebins):
        raise SystemExit("Compile first: rebar3 compile")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], text=True)
    diff = subprocess.check_output(["git", "diff", "--binary", "HEAD"])
    dirty = bool(status)
    output = Path("_build/docs/core")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    beams = [beam for app_ebin in app_ebins for beam in sorted(app_ebin.glob("*.beam"))]
    if len(beams) != len({beam.name for beam in beams}):
        raise RuntimeError("Duplicate documentation module across applications")
    sources, media = {}, {}

    def image_url(target, page):
        url = urlsplit(html.unescape(target))
        if url.scheme or url.netloc or not url.path:
            return html.unescape(target)
        path = (page.parent / unquote(url.path)).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise RuntimeError("Missing documentation image: " + str(page) + " -> " + target)
        relative = path.relative_to(root).as_posix()
        destination = "media/" + relative
        media[destination] = {"source": relative,
                              "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        return quote(destination, safe="/") + ("?" + url.query if url.query else "") + (
            "#" + url.fragment if url.fragment else "")

    def image_tag(match, page):
        def attribute(found):
            name, delimiter, value = found.groups()
            if name == "srcset" and not value.lstrip().startswith("data:"):
                candidates = [part.strip().split() for part in value.split(",")]
                rendered = ", ".join(" ".join([image_url(parts[0], page), *parts[1:]])
                                     for parts in candidates if parts)
            else:
                rendered = image_url(value, page)
            return name + "=" + delimiter + html.escape(rendered, quote=True) + delimiter
        return re.sub(r'''\b(src|srcset)\s*=\s*(['"])(.*?)\2''', attribute, match[0])

    def source_page(path):
        path = path.resolve()
        if not path.is_relative_to(root) or not path.exists():
            raise RuntimeError("Source outside checkout or missing: " + str(path))
        relative = path.relative_to(root).as_posix()
        target = Path("source") / (relative + ("/index.html" if path.is_dir() else ".html"))
        if relative in sources:
            return target.as_posix()
        sources[relative] = {}
        destination = output / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        title = html.escape(relative)
        prefix = ('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
                  '<link rel="icon" href="data:,"><title>' + title + '</title>'
                  '<style>body{font:16px system-ui;max-width:100ch;margin:2rem auto;padding:0 1rem;overflow-wrap:anywhere}'
                  'h1{font-size:1.3rem}'
                  'pre{font-size:14px;line-height:1.5;white-space:pre-wrap;overflow-wrap:anywhere;counter-reset:line}'
                  'pre span::before{counter-increment:line;content:counter(line);display:inline-block;width:4em;color:#666}'
                  ':target{background:#fff4c2}</style><h1>' + title + '</h1>')
        if path.is_dir():
            entries = []
            for child in sorted(path.iterdir()):
                child_target = source_page(child)
                href = os.path.relpath(output / child_target, destination.parent)
                entries.append('<li><a href="' + html.escape(href, quote=True) + '">' + html.escape(child.name) + '</a></li>')
            destination.write_text(prefix + '<ul>' + ''.join(entries) + '</ul>')
        else:
            data = path.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            committed = subprocess.run(["git", "show", head + ":" + relative], capture_output=True)
            same = committed.returncode == 0 and committed.stdout == data
            sources[relative] = {"sha256": digest, "matches_head": same}
            provenance = ('<p><a href="https://github.com/libtmux/libtmux-erlang/blob/' + head + '/' + relative + '">Source at ' + head + '</a></p>') if same else '<p>Working tree preview. This content is not the source at HEAD.</p>'
            lines = ['<span id="L' + str(i) + '">' + html.escape(line) + '</span>'
                     for i, line in enumerate(data.decode("utf-8").splitlines(), 1)]
            destination.write_text(prefix + provenance + '<p>SHA-256: ' + digest + '</p><pre>' + '\n'.join(lines) + '</pre>')
        return target.as_posix()

    config = Path("_build/docs/ex_doc.config")
    config.parent.mkdir(parents=True, exist_ok=True)
    extras = [Path("README.md"), *sorted(Path("docs").glob("*.md")), Path("LICENSE")]
    staged = []
    extra_paths = {p.resolve() for p in extras}
    for path in extras:
        def rewrite(match):
            label, target = match.groups()
            if target.startswith(("http:", "https:", "mailto:", "#")):
                return match.group(0)
            filename, separator, fragment = target.partition("#")
            resolved = (path.parent / filename).resolve()
            if not resolved.is_relative_to(root) or not resolved.exists():
                raise RuntimeError("Broken documentation link: " + str(path) + " -> " + target)
            if resolved in extra_paths:
                return match.group(0)
            url = source_page(resolved)
            if fragment.startswith("L"):
                url += separator + fragment
            return "[" + label + "](" + url + ")"

        content = re.sub(r"(?<!!)\[([^\]]+)\]\(([^)]+)\)", rewrite, path.read_text())
        content = re.sub(r"<(?:img|source)\b[^>]*>",
                         lambda match: image_tag(match, path), content)
        destination = Path("_build/docs/pages") / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
        staged.append(destination)
    source = "https://source.invalid/%{path}#L%{line}"
    config.write_text(
        "{proglang, erlang}.\n{main, <<\"readme\">>}.\n" +
        "{source_url_pattern, <<" + json.dumps(source) + ">>}.\n" +
        "{extras, [" + ",".join("<<" + json.dumps(p.as_posix()) + ">>" for p in staged) + "]}.\n"
    )
    version = "0.0.0+working-tree" if dirty else "0.0.0+" + head[:12]
    command = ["escript", str(executable), "libtmux for Erlang", version, *map(str, app_ebins),
               "--config", str(config), "--formatter", "html", "--output", str(output),
               "--source-ref", head, "--warnings-as-errors"]
    subprocess.run(command, check=True, env=env, timeout=60)
    for destination, info in media.items():
        target = output / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / info["source"], target)
    # ExDoc requests this optional configuration even when no overrides exist.
    (output / "docs_config.js").write_text("// No runtime documentation overrides.\n")
    for page in output.glob("*.html"):
        def replace_source(match):
            path, line = unquote(match[1]), match[2]
            if path.startswith("_build/docs/pages/"):
                original = Path(path.removeprefix("_build/docs/pages/"))
            else:
                candidates = list(Path("apps").glob("*/src/" + path))
                if len(candidates) != 1:
                    raise RuntimeError("Ambiguous documentation source: " + path)
                original = candidates[0]
            return source_page(original) + "#L" + line
        rendered = re.sub(r'https://source\.invalid/([^"#]+)#L([0-9]+)', replace_source, page.read_text())
        page.write_text(rendered.replace("</head>", '<link rel="icon" href="data:,">\n</head>'))
    subprocess.run(["python3", "tools/check_docs.py", "--html-directory", str(output)], check=True, env=env, timeout=10)
    if inputs() != input_files or subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != head:
        raise RuntimeError("Documentation inputs changed during the build; rebuild the stable checkout")
    receipt = {"result": "PASS", "head": head, "ex_doc": manifest,
               "working_tree": "dirty preview" if dirty else "clean commit",
               "status": status.splitlines(), "diff_sha256": hashlib.sha256(diff).hexdigest(),
               "source_files": sources, "media": media,
               "input_files": input_files,
               "beams": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in beams},
               "seconds": round(time.monotonic() - started, 6), "output": output.as_posix(),
               "source": "compiler EEP-48 chunks; no legacy EDoc source extraction"}
    Path("_build/checks").mkdir(parents=True, exist_ok=True)
    Path("_build/checks/docs.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({key: receipt[key] for key in ("result", "head", "working_tree", "seconds", "output")}, indent=2))


if __name__ == "__main__":
    main()
