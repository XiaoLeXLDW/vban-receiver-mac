#!/usr/bin/env python3
"""Exercise real macOS bundles/signatures/archives in disposable Git repositories.

The fixture has a tiny Mach-O executable; no application or audio device is started.
Fixture commits/tags never change the project's Git index, branches, or tags.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
ARCH = platform.machine()


class PackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / ".build").mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix="packaging-tests-", dir=ROOT / ".build")
        cls.base = Path(cls.temp.name)
        source = cls.base / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        cls.binary = cls.base / "VBANReceiver"
        subprocess.run(["clang", "-arch", ARCH, "-mmacosx-version-min=13.0", str(source), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="repo-", dir=self.base))
        for directory in ["Scripts", "Resources", ".build"]:
            (self.repo / directory).mkdir()
        for filename in ["package-app.sh", "package-release.sh", "validate-app.sh", "build-metadata.py"]:
            shutil.copy2(ROOT / "Scripts" / filename, self.repo / "Scripts" / filename)
        shutil.copy2(ROOT / "Resources/AppIcon.icns", self.repo / "Resources/AppIcon.icns")
        shutil.copy2(ROOT / "LICENSE", self.repo / "LICENSE")
        shutil.copy2(self.binary, self.repo / ".build/VBANReceiver")
        (self.repo / "VERSION.env").write_text("DEFAULT_VERSION=0.3.13\nDEFAULT_BUILD_NUMBER=17\n")
        (self.repo / ".gitignore").write_text(".build/\ndist/\n")
        (self.repo / "README.md").write_text("fixture\n")
        # Keep inherited CI/release settings out of each isolated scenario.
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "EXPECTED_"))}
        for key in ["BUILD_KIND", "VERSION", "BUILD_NUMBER", "RELEASE_TAG", "APP_DIR", "APP_PATH", "BUILD_DIR", "BUILD_BIN", "ARCHIVE_DIR", "STRICT_RELEASE", "SIGN_IDENTITY", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]:
            self.env.pop(key, None)
        self.env.update(ARCH=ARCH, PYTHONDONTWRITEBYTECODE="1")
        self.command("git", "init", "-q")
        self.command("git", "config", "user.name", "Packaging Fixture")
        self.command("git", "config", "user.email", "fixture@example.invalid")
        self.commit()
        self.command("git", "tag", "v0.3.13")
        self.sha = self.command("git", "rev-parse", "HEAD").stdout.strip()
        self.app = self.repo / "dist/VBAN Receiver.app"

    def command(self, *args, env=None, failure=None):
        result = subprocess.run(args, cwd=self.repo, env=dict(self.env, **(env or {})), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if failure is None:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(failure, result.stdout)
        return result

    def commit(self):
        self.command("git", "add", "--all")
        self.command("git", "commit", "-qm", "fixture")

    def package(self, **env):
        return self.command("bash", "Scripts/package-app.sh", env=dict(SKIP_BUILD="1", **env))

    def info(self):
        return json.loads((self.app / "Contents/Resources/build-info.json").read_text())

    def plist(self):
        return plistlib.loads((self.app / "Contents/Info.plist").read_bytes())

    def validate(self, **env):
        return self.command("bash", "Scripts/validate-app.sh", str(self.app), env=env)

    def resign(self):
        self.command("codesign", "--force", "--deep", "--sign", "-", str(self.app))

    def archive(self, **env):
        self.command("bash", "Scripts/package-release.sh", env=env)
        return sorted((self.repo / "dist").glob("archive-check.*/*.zip"))

    def test_default_branch_build_is_visibly_development(self):
        self.package(GITHUB_REF_TYPE="branch", GITHUB_REF_NAME="main")
        info, plist = self.info(), self.plist()
        self.assertEqual((info["kind"], info["commit"], info["dirty"]), ("development", self.sha, False))
        self.assertEqual(plist["CFBundleShortVersionString"], "0.3.13")
        self.assertEqual(plist["CFBundleVersion"], "17")
        self.assertEqual(plist["CFBundleDisplayName"], "VBAN Receiver Dev")
        self.assertIn("DEVELOPMENT", plist["CFBundleGetInfoString"])
        self.assertIn(self.sha[:12], plist["CFBundleGetInfoString"])
        self.validate(EXPECTED_COMMIT=self.sha, EXPECTED_BUILD_KIND="development")
        archives = self.archive()
        self.assertEqual(len(archives), 1)
        self.assertEqual(archives[0].name, f"VBAN-Receiver-dev-{ARCH}-{self.sha[:12]}-macos.zip")
        self.assertTrue(Path(str(archives[0]) + ".sha256").exists())

    def test_dirty_tracked_and_untracked_builds_are_marked(self):
        for path in ["README.md", "untracked-note.txt"]:
            with self.subTest(path=path):
                (self.repo / path).write_text("local edit\n")
                self.package()
                self.assertTrue(self.info()["dirty"])
                self.assertIn("dirty", self.plist()["CFBundleGetInfoString"])
                self.assertIn("-dirty-macos.zip", self.archive()[-1].name)
                if path == "README.md":
                    self.command("git", "restore", path)

    def test_new_tag_release_and_archives_do_not_overwrite(self):
        (self.repo / "VERSION.env").write_text("DEFAULT_VERSION=0.3.14\nDEFAULT_BUILD_NUMBER=18\n")
        self.commit()
        self.command("git", "tag", "v0.3.14")
        release = dict(BUILD_KIND="release", RELEASE_TAG="v0.3.14", GITHUB_REF_TYPE="tag", GITHUB_REF_NAME="v0.3.14")
        self.package(**release)
        self.assertEqual(self.info()["kind"], "release")
        self.assertEqual(self.info()["releaseTag"], "v0.3.14")
        self.assertFalse(self.info()["dirty"])
        self.assertEqual(self.plist()["CFBundleGetInfoString"], "0.3.14 (18)")
        before = (self.app / "Contents/Info.plist").read_bytes()
        self.command("bash", "Scripts/package-app.sh", env=dict(SKIP_BUILD="1", **release), failure="Refusing to overwrite")
        self.command("bash", "Scripts/package-app.sh", env={"SKIP_BUILD": "1"}, failure="Refusing to overwrite")
        self.assertEqual(before, (self.app / "Contents/Info.plist").read_bytes())
        first = self.archive(**release)[0]
        checksum = hashlib.sha256(first.read_bytes()).hexdigest()
        self.assertEqual(first.name, f"VBAN-Receiver-v0.3.14-build18-{ARCH}-macos.zip")
        self.assertEqual(len(self.archive(**release)), 2)
        self.assertEqual(checksum, hashlib.sha256(first.read_bytes()).hexdigest())
        self.command("bash", "Scripts/validate-app.sh", str(self.app), env={"STRICT_RELEASE": "1", "EXPECTED_VERSION": "0.3.14", "EXPECTED_BUILD_NUMBER": "18"}, failure="ad-hoc signature")

    def test_release_requires_clean_matching_tag_and_committed_target(self):
        base = dict(SKIP_BUILD="1", BUILD_KIND="release", RELEASE_TAG="v0.3.13")
        self.command("bash", "Scripts/package-app.sh", env=dict(base, RELEASE_TAG="v0.3.14"), failure="tag must exactly match")
        self.command("bash", "Scripts/package-app.sh", env=dict(base, VERSION="0.3.14"), failure="committed VERSION.env")
        self.command("bash", "Scripts/package-app.sh", env=dict(base, GITHUB_REF_TYPE="tag", GITHUB_REF_NAME="v0.3.12"), failure="GitHub tag does not match")
        (self.repo / "README.md").write_text("changed\n")
        self.command("bash", "Scripts/package-app.sh", env=base, failure="clean Git worktree")
        self.commit()
        self.command("bash", "Scripts/package-app.sh", env=base, failure="does not point to the packaged commit")
        self.assertFalse(self.app.exists())

    def test_tag_environment_alone_does_not_promote_a_development_build(self):
        self.package(GITHUB_REF_TYPE="tag", GITHUB_REF_NAME="v0.3.13")
        self.assertEqual(self.info()["kind"], "development")
        self.command("bash", "Scripts/package-release.sh", env={"RELEASE_TAG": "v0.3.13"}, failure="cannot claim RELEASE_TAG")
        self.command("bash", "Scripts/package-release.sh", env={"BUILD_KIND": "release", "RELEASE_TAG": "v0.3.13"}, failure="EXPECTED_BUILD_KIND")

    def test_formal_versions_and_expected_metadata(self):
        self.command("bash", "Scripts/package-app.sh", env={"SKIP_BUILD": "1", "VERSION": "0.3.13-dev"}, failure="three numeric components")
        self.command("bash", "Scripts/package-app.sh", env={"SKIP_BUILD": "1", "BUILD_NUMBER": "17-dev"}, failure="integer from 1")
        self.package()
        for key, value in [("EXPECTED_VERSION", "0.3.14"), ("EXPECTED_BUILD_NUMBER", "18"), ("EXPECTED_COMMIT", "f" * 40), ("EXPECTED_BUILD_KIND", "release")]:
            self.command("bash", "Scripts/validate-app.sh", str(self.app), env={key: value}, failure=key)
        other = "x86_64" if ARCH == "arm64" else "arm64"
        self.command("bash", "Scripts/validate-app.sh", str(self.app), env={"ARCH": other}, failure="requested ARCH")

    def test_resigned_metadata_corruption_is_rejected(self):
        self.package()
        path = self.app / "Contents/Resources/build-info.json"
        original = path.read_bytes()
        plist_path = self.app / "Contents/Info.plist"
        original_plist = plist_path.read_bytes()
        for key, value, failure in [("commit", "f" * 40, "VBANBuildCommit"), ("dirty", 1, "dirty flag"), ("architectures", ["x86_64" if ARCH == "arm64" else "arm64"], "recorded architectures")]:
            info = json.loads(original)
            info[key] = value
            plist_path.write_bytes(original_plist)
            if key == "commit":
                # Keep the display field coherent to isolate the full commit cross-check.
                info["displayVersion"] = info["displayVersion"].replace(self.sha[:12], value[:12])
                plist = self.plist()
                plist["CFBundleGetInfoString"] = info["displayVersion"]
                plist_path.write_bytes(plistlib.dumps(plist))
            path.write_text(json.dumps(info))
            self.resign()
            self.command("bash", "Scripts/validate-app.sh", str(self.app), failure=failure)
        path.write_bytes(original)
        plist_path = self.app / "Contents/Info.plist"
        plist = self.plist()
        plist["CFBundleGetInfoString"] = "0.3.13 (17)"
        plist_path.write_bytes(plistlib.dumps(plist))
        self.resign()
        self.command("bash", "Scripts/validate-app.sh", str(self.app), failure="CFBundleGetInfoString")

    def test_signature_seals_build_information(self):
        self.package()
        path = self.app / "Contents/Resources/build-info.json"
        path.write_text(path.read_text() + "\n")  # Semantically valid, but no longer signed bytes.
        self.command("bash", "Scripts/validate-app.sh", str(self.app), failure="resource")

    def test_legacy_bundle_integrity_without_new_provenance(self):
        self.package()
        metadata = self.app / "Contents/Resources/build-info.json"
        metadata.unlink()
        # Partial removal is not treated as a historical bundle.
        self.command("bash", "Scripts/validate-app.sh", str(self.app), failure="build-info.json")
        plist_path = self.app / "Contents/Info.plist"
        plist = self.plist()
        for key in list(plist):
            if key.startswith("VBANBuild") or key in {"CFBundleGetInfoString", "VBANReleaseTag"}:
                del plist[key]
        plist["CFBundleDisplayName"] = "VBAN Receiver"
        plist_path.write_bytes(plistlib.dumps(plist))
        self.resign()
        result = self.validate(EXPECTED_VERSION="0.3.13", EXPECTED_BUILD_NUMBER="17")
        self.assertIn("Legacy bundle: no build provenance", result.stdout)
        self.command("bash", "Scripts/validate-app.sh", str(self.app), env={"EXPECTED_COMMIT": self.sha}, failure="build-info.json")
        self.command("bash", "Scripts/validate-app.sh", str(self.app), env={"STRICT_RELEASE": "1", "EXPECTED_VERSION": "0.3.13", "EXPECTED_BUILD_NUMBER": "17"}, failure="build-info.json")
        self.command("bash", "Scripts/package-release.sh", failure="build-info.json")

    def test_dev_rebuild_can_change_architecture_and_numeric_version(self):
        self.package()
        other_arch = "x86_64" if ARCH == "arm64" else "arm64"
        other = self.repo / ".build/other"
        self.command("clang", "-arch", other_arch, "-mmacosx-version-min=13.0", str(self.base / "main.c"), "-o", str(other))
        self.command("lipo", "-create", str(self.binary), str(other), "-output", str(self.repo / ".build/VBANReceiver"))
        self.package(ARCH="arm64 x86_64", VERSION="0.3.14", EXPECTED_VERSION="0.3.14")
        self.validate(ARCH="arm64 x86_64", EXPECTED_VERSION="0.3.14")
        self.assertEqual(self.info()["architectures"], ["arm64", "x86_64"])

    def test_archive_rejects_stale_source_identity(self):
        self.package()
        (self.repo / "README.md").write_text("changed\n")
        self.command("bash", "Scripts/package-release.sh", failure="commit/dirty state differs")
        self.commit()
        self.command("bash", "Scripts/package-release.sh", failure="commit/dirty state differs")


if __name__ == "__main__":
    unittest.main(verbosity=2)
