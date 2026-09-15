#!/usr/bin/env python3
"""Write and check the provenance sealed by the application's code signature."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "VBAN Receiver"
BINARY_NAME = "VBANReceiver"


def fail(message):
    raise ValueError(message)


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def source_state():
    return git("rev-parse", "HEAD"), bool(git("status", "--porcelain", "--untracked-files=all"))


def version_values(version, build):
    if not isinstance(version, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        fail("version must contain three numeric components (x.y.z)")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]{0,3}", build):
        fail("build number must be an integer from 1 through 9999")


def architectures(value):
    result = value.split()
    if not result or len(set(result)) != len(result) or any(item not in {"arm64", "x86_64"} for item in result):
        fail("ARCH must contain arm64 and/or x86_64 exactly once")
    return sorted(result)


def defaults():
    values = {}
    for line in (ROOT / "VERSION.env").read_text().splitlines():
        if line.startswith("DEFAULT_VERSION=") or line.startswith("DEFAULT_BUILD_NUMBER="):
            key, value = line.split("=", 1)
            values[key] = value
    version_values(values.get("DEFAULT_VERSION"), values.get("DEFAULT_BUILD_NUMBER"))
    return values["DEFAULT_VERSION"], values["DEFAULT_BUILD_NUMBER"]


def release_context(version, build, tag, commit, dirty):
    if dirty:
        fail("release mode requires a clean Git worktree, including untracked files")
    if (version, build) != defaults():
        fail("release version/build must match the committed VERSION.env target")
    if tag != f"v{version}":
        fail("release tag must exactly match vVERSION")
    try:
        tagged_commit = git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    except subprocess.CalledProcessError:
        fail(f"release tag {tag} does not exist; create the reviewed tag first")
    if tagged_commit != commit:
        fail(f"release tag {tag} does not point to the packaged commit")
    if os.environ.get("GITHUB_REF_TYPE") == "tag" and os.environ.get("GITHUB_REF_NAME") != tag:
        fail("GitHub tag does not match the intended release tag")


def display(info):
    value = f"{info['version']} ({info['buildNumber']})"
    if info["kind"] == "development":
        value += f" — DEVELOPMENT {'+'.join(info['architectures'])} {info['commit'][:12]}"
        if info["dirty"]:
            value += " dirty"
    return value


def info_from_environment():
    default_version, default_build = defaults()
    kind = os.environ.get("BUILD_KIND", "development")
    if kind not in {"development", "release"}:
        fail("BUILD_KIND must be development or release")
    version = os.environ.get("VERSION") or default_version
    build = os.environ.get("BUILD_NUMBER") or default_build
    version_values(version, build)
    arch = architectures(os.environ.get("ARCH", "arm64"))
    commit, dirty = source_state()
    tag = os.environ.get("RELEASE_TAG") or None
    if kind == "release":
        release_context(version, build, tag, commit, dirty)
    elif tag:
        fail("RELEASE_TAG is only allowed with explicit BUILD_KIND=release")
    info = dict(schemaVersion=1, kind=kind, version=version, buildNumber=build,
                commit=commit, dirty=dirty, architectures=arch, releaseTag=tag)
    info["displayVersion"] = display(info)
    return info


def write(app):
    info = info_from_environment()
    plist = {
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": BINARY_NAME,
        "CFBundleDisplayName": APP_NAME + (" Dev" if info["kind"] == "development" else ""),
        "CFBundleIdentifier": "local.codex.vban-receiver", "CFBundleIconFile": "AppIcon",
        "CFBundleIconName": "AppIcon", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": APP_NAME, "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": info["version"], "CFBundleVersion": info["buildNumber"],
        "CFBundleGetInfoString": info["displayVersion"], "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        "NSLocalNetworkUsageDescription": "Receive VBAN audio streams from VoiceMeeter on your local network.",
        "VBANBuildKind": info["kind"], "VBANBuildCommit": info["commit"],
        "VBANBuildDirty": info["dirty"], "VBANBuildArchitectures": info["architectures"],
    }
    if info["releaseTag"]:
        plist["VBANReleaseTag"] = info["releaseTag"]
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(plist, handle, sort_keys=False)
    (app / "Contents/Resources/build-info.json").write_text(json.dumps(info, indent=2) + "\n")


def validate(app, current_source=False, allow_legacy=False):
    with (app / "Contents/Info.plist").open("rb") as handle:
        plist = plistlib.load(handle)
    metadata_path = app / "Contents/Resources/build-info.json"
    provenance_keys = {"CFBundleGetInfoString", "VBANBuildKind", "VBANBuildCommit", "VBANBuildDirty", "VBANBuildArchitectures", "VBANReleaseTag"}
    provenance_expected = any(os.environ.get(key) for key in ("EXPECTED_BUILD_KIND", "EXPECTED_COMMIT", "EXPECTED_RELEASE_TAG"))
    if allow_legacy and not current_source and not provenance_expected and not metadata_path.exists() and not provenance_keys.intersection(plist):
        return None
    info = json.loads(metadata_path.read_text())
    if not isinstance(info, dict) or type(info.get("schemaVersion")) is not int or info["schemaVersion"] != 1:
        fail("unsupported build-info.json schema")
    version_values(info.get("version"), info.get("buildNumber"))
    if info.get("kind") not in {"development", "release"} or type(info.get("dirty")) is not bool:
        fail("invalid build kind or dirty flag")
    if not isinstance(info.get("commit"), str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", info["commit"]):
        fail("build commit must be a full Git object ID")
    arch = info.get("architectures")
    if not isinstance(arch, list) or not all(isinstance(a, str) for a in arch) or architectures(" ".join(arch)) != arch:
        fail("invalid build architecture list")
    actual_arch = sorted(subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS" / BINARY_NAME)], text=True).split())
    if arch != actual_arch:
        fail("recorded architectures do not match the executable")
    if os.environ.get("ARCH") and arch != architectures(os.environ["ARCH"]):
        fail("artifact architectures do not match requested ARCH")
    expected_pairs = {
        "EXPECTED_VERSION": "version", "EXPECTED_BUILD_NUMBER": "buildNumber",
        "EXPECTED_BUILD_KIND": "kind", "EXPECTED_COMMIT": "commit", "EXPECTED_RELEASE_TAG": "releaseTag",
    }
    for variable, key in expected_pairs.items():
        if os.environ.get(variable) and info.get(key) != os.environ[variable]:
            fail(f"{key} does not match {variable}")
    if info["kind"] == "release":
        if info["dirty"] or info.get("releaseTag") != f"v{info['version']}":
            fail("release metadata must be clean and have a matching release tag")
    elif info.get("releaseTag") is not None:
        fail("development metadata must not claim a release tag")
    expected_plist = {
        "CFBundleShortVersionString": info["version"], "CFBundleVersion": info["buildNumber"],
        "CFBundleGetInfoString": display(info), "VBANBuildKind": info["kind"],
        "VBANBuildCommit": info["commit"], "VBANBuildDirty": info["dirty"],
        "VBANBuildArchitectures": arch,
        "CFBundleDisplayName": APP_NAME + (" Dev" if info["kind"] == "development" else ""),
    }
    for key, expected in expected_plist.items():
        if type(plist.get(key)) is not type(expected) or plist[key] != expected:
            fail(f"{key} disagrees with build-info.json")
    if plist.get("VBANReleaseTag") != info.get("releaseTag") or info.get("displayVersion") != display(info):
        fail("release tag or visible version disagrees with build-info.json")
    if current_source:
        commit, dirty = source_state()
        if info["commit"] != commit or info["dirty"] != dirty:
            fail("artifact commit/dirty state differs from the current Git worktree; rebuild before archiving")
        if info["kind"] == "release":
            release_context(info["version"], info["buildNumber"], info["releaseTag"], commit, dirty)
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check-inputs", "write", "validate", "archive-name"])
    parser.add_argument("app", nargs="?", type=Path)
    parser.add_argument("--current-source", action="store_true")
    parser.add_argument("--allow-legacy", action="store_true")
    args = parser.parse_args()
    if args.command == "check-inputs":
        info_from_environment()
        return
    if args.app is None:
        parser.error("app path is required")
    if args.command == "write":
        write(args.app)
        return
    info = validate(args.app, args.current_source, args.allow_legacy and args.command == "validate")
    if info is None:
        print("Legacy bundle: no build provenance; checking historical bundle integrity only.")
        return
    if args.command == "archive-name":
        arch = "-".join(info["architectures"])
        if info["kind"] == "development":
            identity = f"dev-{arch}-{info['commit'][:12]}" + ("-dirty" if info["dirty"] else "")
        else:
            identity = f"{info['releaseTag']}-build{info['buildNumber']}-{arch}"
        print(f"VBAN-Receiver-{identity}-macos.zip")
    else:
        print(f"Build identity verified: {info['displayVersion']}; commit {info['commit']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Build metadata validation failed: {error}", file=sys.stderr)
        sys.exit(2)
