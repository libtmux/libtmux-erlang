#!/usr/bin/env python3
"""Build and consume exact Hex source artifacts through a private local registry."""

from __future__ import annotations

import argparse
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import threading
import time
import urllib.request
from urllib.parse import unquote

from check_package import exercise_consumer


ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "_build/source-package-tools"
PINS = json.loads((ROOT / "tools/package-tool.json").read_text())["packages"]
APPS = ("libtmux_erlang", "libtmux_erlang_workspace")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pinned_tarball(pin: dict) -> Path:
    return TOOLS / f"{pin['name']}-{pin['version']}.tar"


def runtime() -> dict:
    expression = (
        'R = erlang:system_info(otp_release), '
        '{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", R, "OTP_VERSION"])), '
        'io:format("~s", [json:encode(#{otp => string:trim(V), '
        'erts => list_to_binary(erlang:system_info(version)), '
        'architecture => list_to_binary(erlang:system_info(system_architecture))})]), halt().'
    )
    return json.loads(subprocess.check_output(
        ["erl", "-noshell", "-noinput", "-eval", expression], text=True, timeout=10))


def prepared_files() -> dict:
    return {p.relative_to(TOOLS).as_posix(): digest(p)
            for p in sorted((TOOLS / "hex_core").rglob("*")) if p.is_file()}


def source_identity() -> dict:
    def git(*args):
        result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    return {"head": git("rev-parse", "--verify", "HEAD"),
            "index_tree": git("write-tree"), "status": git("status", "--porcelain"),
            "artifact_identity": "Package SHA256 values bind the actual compiled source inputs"}


def prepare() -> None:
    """Provision test-only tooling separately from the measured outer check."""
    TOOLS.mkdir(parents=True, exist_ok=True)
    for pin in PINS:
        path = pinned_tarball(pin)
        if path.is_file() and digest(path) == pin["sha256"]:
            continue
        with urllib.request.urlopen("https://repo.hex.pm/tarballs/" + path.name,
                                    timeout=30) as response:
            data = response.read(8 * 1024 * 1024 + 1)
        if hashlib.sha256(data).hexdigest() != pin["sha256"]:
            raise RuntimeError(f"tool checksum mismatch: {path.name}")
        path.write_bytes(data)
    core = TOOLS / "hex_core"
    if core.exists():
        shutil.rmtree(core)
    with tarfile.open(pinned_tarball(PINS[1])) as outer:
        packed = outer.extractfile("contents.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(packed), mode="r:gz") as source:
        source.extractall(core, filter="data")
    ebin = core / "ebin"
    ebin.mkdir(exist_ok=True)
    subprocess.run(["erlc", "-o", str(core / "src"),
                    str(core / "src/safe_erl_term.xrl")], check=True)
    subprocess.run(["erlc", "-Werror", "-pa", str(ebin),
                    "-I", str(core / "src"), "-o", str(ebin),
                    *map(str, sorted((core / "src").glob("*.erl")))], check=True)
    manifest = {"pins_sha256": digest(ROOT / "tools/package-tool.json"),
                "runtime": runtime(), "files": prepared_files()}
    (TOOLS / "prepared.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Prepared pinned Hex tooling; no project package was published.")


def check_contents(path: Path, app: str) -> dict:
    with tarfile.open(path) as outer:
        packed = outer.extractfile("contents.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(packed), mode="r:gz") as source:
        names = source.getnames()
        forbidden = [n for n in names if n.startswith(("priv/", "ebin/", "_build/"))
                     or n.endswith((".beam", ".o", ".so"))]
        if forbidden:
            raise RuntimeError(f"prebuilt files in {app}: {forbidden}")
        required = {"LICENSE", "CHANGELOG.md", "rebar.config", f"src/{app}.app.src"}
        if app == APPS[0]:
            required.update({"c_src/owned_io.c", "c_src/Makefile", "c_src/LICENSE",
                             "c_src/provenance.json"})
        if missing := required - set(names):
            raise RuntimeError(f"missing source-package files in {app}: {sorted(missing)}")
        return {"sha256": digest(path), "files": names}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    args = parser.parse_args()
    if args.prepare:
        prepare()
        return
    hex_ebin = TOOLS / "hex_core/ebin"
    started = time.monotonic()
    output = ROOT / "_build/source-package-check"
    attempt = output / f"run-{time.time_ns()}"
    attempt.mkdir(parents=True)
    (output / "receipt.json").unlink(missing_ok=True)
    receipt = {"result": "FAIL", "platform": platform.platform(),
               "machine": platform.machine(), "tools": PINS, "commands": [],
               "source_sha256": {name: digest(ROOT / name) for name in (
                   "tools/check_source_package.py", "tools/source_package_registry.escript",
                   "tools/check_package.py", "tools/package-tool.json", ".tool-versions")},
               "packages": {}, "publication": "UNVERIFIED; local artifacts only"}
    env = dict(os.environ, ERL_FLAGS=os.environ.get("ERL_FLAGS", "+S 4:4"))
    for key in ("ERL_LIBS", "TMUX", "TMUX_PANE", "REBAR_CONFIG", "HEX_CDN",
                "HEX_UNSAFE_REGISTRY", "HEX_NO_VERIFY_REPO_ORIGIN",
                "HEX_TRUSTED_MIRROR_URL", "HEX_MIRROR_URL"):
        env.pop(key, None)

    def run(command, cwd, environment=env, *, expected_failure=False):
        before = time.monotonic()
        timeout_error = None
        try:
            result = subprocess.run(command, cwd=cwd, env=environment, capture_output=True,
                                    text=True, timeout=30)
            code, text = result.returncode, result.stdout + result.stderr
        except subprocess.TimeoutExpired as error:
            timeout_error = error
            code = 124
            text = (error.stdout or b"").decode(errors="replace")
            text += (error.stderr or b"").decode(errors="replace")
        log = attempt / f"command-{len(receipt['commands']) + 1}.log"
        log.write_text(text)
        receipt["commands"].append({"command": command, "seconds": time.monotonic() - before,
                                    "exit_status": code, "timed_out": timeout_error is not None,
                                    "expected_failure": expected_failure,
                                    "log": log.relative_to(ROOT).as_posix()})
        if timeout_error is not None:
            raise timeout_error
        if bool(code) != expected_failure:
            raise RuntimeError(text[-8000:])
        return text if expected_failure else result.stdout

    try:
        for pin in PINS:
            if not pinned_tarball(pin).is_file() or digest(pinned_tarball(pin)) != pin["sha256"]:
                raise RuntimeError("Run tools/check_source_package.py --prepare first")
        manifest = json.loads((TOOLS / "prepared.json").read_text())
        current_runtime = runtime()
        expected = {"pins_sha256": digest(ROOT / "tools/package-tool.json"),
                    "runtime": current_runtime, "files": prepared_files()}
        if manifest != expected or not (hex_ebin / "hex_registry.beam").is_file():
            raise RuntimeError("Prepared tool source/BEAM/runtime mismatch; repeat --prepare")
        receipt["prepared_tool_sha256"] = digest(TOOLS / "prepared.json")
        receipt["runtime"] = current_runtime
        receipt["source"] = source_identity()
        with tempfile.TemporaryDirectory(prefix="erlang-source-consumer-") as directory:
            temp = Path(directory)
            public = temp / "registry/public"
            tarballs = public / "tarballs"
            tarballs.mkdir(parents=True)
            for pin in PINS:
                shutil.copyfile(pinned_tarball(pin), tarballs / pinned_tarball(pin).name)

            def registry():
                return json.loads(run(["escript", str(ROOT / "tools/source_package_registry.escript"),
                                       str(hex_ebin), str(public.parent)], temp))

            registry()
            requests = []

            class Handler(SimpleHTTPRequestHandler):
                def log_message(self, *_args):
                    pass

                def end_headers(self):
                    path = Path(self.translate_path(self.path))
                    if path.is_file():
                        self.send_header("ETag", '"' + digest(path) + '"')
                    super().end_headers()

                def do_GET(self):
                    if len(requests) >= 256:
                        self.send_error(429)
                        return
                    requests.append(self.path)
                    super().do_GET()

            server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(public)))
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
            thread.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}"
                # Rebar3 3.28 overrides the hexpm URL after reading repo config.
                env["HEX_CDN"] = url
                pem = (public / "public_key").read_text()
                repo_config = ('{rebar_packages_cdn, ' + json.dumps(url) + '}.\n'
                               '{hex, [{repos, replace, [#{name => <<"hexpm">>, '
                               f'repo_url => <<"{url}">>, repo_public_key => <<'
                               + json.dumps(pem) + '>>}]}]}.\n')
                build_config = temp / "build-config"
                config_file = build_config / ".config/rebar3/rebar.config"
                config_file.parent.mkdir(parents=True)
                config_file.write_text(
                    '{plugins, [{rebar3_hex, "7.5.0"}]}.\n' + repo_config)
                env.update(REBAR_GLOBAL_CONFIG_DIR=str(build_config),
                           REBAR_CACHE_DIR=str(temp / "build-cache"),
                           REBAR_GLOBAL_CACHE_DIR=str(temp / "build-cache"))
                for app in APPS:
                    stage = temp / "build" / app
                    shutil.copytree(ROOT / "apps" / app, stage,
                                    ignore=shutil.ignore_patterns("_build", "priv", "test", "ebin"))
                    run(["rebar3", "hex", "build", "package"], stage)
                    artifacts = list((stage / "_build/default/lib" / app / "hex").glob("*.tar"))
                    if len(artifacts) != 1:
                        raise RuntimeError(f"expected one actual Hex artifact for {app}")
                    artifact = attempt / artifacts[0].name
                    shutil.copyfile(artifacts[0], artifact)
                    receipt["packages"][app] = check_contents(artifact, app)
                    shutil.copyfile(artifact, tarballs / artifact.name)
                    metadata = registry()
                    current = next(m for m in metadata if m["name"] == app)
                    receipt["packages"][app]["metadata"] = current
                    if app == APPS[1]:
                        requirements = current["requirements"]
                        if set(requirements) != {APPS[0]}:
                            raise RuntimeError("workspace package must depend on core only")
                        if requirements[APPS[0]]["requirement"] != current["version"]:
                            raise RuntimeError("workspace/core version mismatch")
                    elif current["requirements"]:
                        raise RuntimeError("core must have no Hex runtime dependencies")

                # This consumer has no source checkout, plugin or build cache.
                consumer = temp / "consumer"
                consumer.mkdir()
                config = temp / "consumer-config"
                config_file = config / ".config/rebar3/rebar.config"
                config_file.parent.mkdir(parents=True)
                config_file.write_text(repo_config)
                version = receipt["packages"][APPS[1]]["metadata"]["version"]
                (consumer / "rebar.config").write_text(
                    '{deps, [{libtmux_erlang_workspace, ' + json.dumps(version) + '}]}.\n')
                env.update(REBAR_GLOBAL_CONFIG_DIR=str(config),
                           REBAR_CACHE_DIR=str(temp / "consumer-cache"),
                           REBAR_GLOBAL_CACHE_DIR=str(temp / "consumer-cache"))
                first_request = len(requests)
                failed_env = dict(env, CC=str(temp / "missing-c-compiler"))
                failure = run(["rebar3", "compile"], consumer, failed_env, expected_failure=True)
                helper = consumer / "_build/default/lib" / APPS[0] / "priv/tmux_owned_io"
                if "missing-c-compiler" not in failure or helper.exists():
                    raise RuntimeError("missing compiler did not fail before helper installation")
                receipt["missing_compiler_rejected"] = True
                run(["rebar3", "compile"], consumer)
                receipt["installed"] = json.loads(run([
                    "escript", str(ROOT / "tools/source_package_registry.escript"),
                    "installed", str(consumer)], consumer))
                shutil.copyfile(consumer / "rebar.lock", attempt / "consumer-rebar.lock")
                installed = consumer / "_build/default/lib"
                for app in APPS:
                    if not (installed / app / "ebin" / (app + ".app")).is_file():
                        raise RuntimeError(f"dependency not compiled: {app}")
                    name = next(a.name for a in attempt.glob(app + "-*.tar"))
                    if "/tarballs/" + name not in map(unquote, requests[first_request:]):
                        raise RuntimeError(f"consumer did not fetch source artifact: {app}")
                receipt["consumer"] = exercise_consumer(
                    ROOT, consumer, installed / APPS[0] / "ebin", installed / APPS[1] / "ebin")
                receipt["requests"] = requests
                receipt["helper_built_from_source"] = True
                receipt["source_only_consumer"] = True
            finally:
                receipt["requests"] = requests
                server.shutdown()
                thread.join(timeout=1)
                server.server_close()
                receipt["registry_retired"] = not thread.is_alive()
                if thread.is_alive():
                    raise RuntimeError("registry did not retire")
        receipt["temporary_consumer_removed"] = not temp.exists()
        receipt["result"] = "PASS"
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        receipt["error"] = str(error)
        if isinstance(error, subprocess.TimeoutExpired):
            receipt["owned_cleanup"] = "UNVERIFIED after forced check-runner timeout"
    finally:
        receipt["seconds"] = time.monotonic() - started
        text = json.dumps(receipt, indent=2) + "\n"
        (attempt / "receipt.json").write_text(text)
        (output / "receipt.json").write_text(text)
    print(text)
    raise SystemExit(0 if receipt["result"] == "PASS" else 1)


if __name__ == "__main__":
    main()
