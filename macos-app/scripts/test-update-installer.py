#!/usr/bin/env python3
"""临时 ad-hoc 应用验证辅助进程成功安装、启动失败回滚和验签拒绝，by AI.Coding。"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / ".build/debug"


def run(*args, **kwargs):
    """不输出环境变量或私钥，只记录测试结果。"""
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def wait_for(predicate, seconds=20):
    """等待明确条件，超时即失败，不将进程启动当作业务成功。"""
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("installer condition timed out")
        time.sleep(0.05)


def scenario(mode):
    """所有应用、进程、历史和偏好都属于本次临时 fixture。"""
    root = Path(tempfile.mkdtemp(prefix="localclip-update-test-", dir="/private/tmp"))
    parent = helper = None
    try:
        key = root / "keys/private"
        public = run(str(BIN / "LocalClipUpdateTool"), "keygen", str(key))
        data = root / "Application Support/LocalClip-LocalEdition"
        data.mkdir(parents=True)
        (data / "history").write_text("existing-history")
        (data / "settings").write_text("existing-settings")
        source = root / "Fixture.swift"
        source.write_text('''// 隔离测试应用，只读写 fixture 目录，by AI.Coding。
import AppKit
let info = Bundle.main.infoDictionary!
let base = URL(fileURLWithPath: info["FixtureRoot"] as! String)
let mode = info["FixtureMode"] as! String
try! String(ProcessInfo.processInfo.processIdentifier).write(to: base.appendingPathComponent(mode + ".pid"), atomically: true, encoding: .utf8)
if mode == "fail" {
    try! "failed-new-data".write(to: base.appendingPathComponent("Application Support/LocalClip-LocalEdition/history"), atomically: true, encoding: .utf8)
    exit(1)
}
if let index = CommandLine.arguments.firstIndex(of: "--localclip-update-receipt") {
    try! (info["CFBundleVersion"] as! String).write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
}
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
''')
        executable = root / "Fixture"
        run("/usr/bin/swiftc", "-module-cache-path", str(ROOT / ".cache/update-fixture"), str(source), "-o", str(executable))

        def make_app(app, build, fixture_mode):
            """用真实 Mach-O 和 ad-hoc 签名覆盖代码签名/LaunchServices 路径。"""
            (app / "Contents/MacOS").mkdir(parents=True)
            shutil.copy2(executable, app / "Contents/MacOS/LocalClip")
            info = dict(CFBundleIdentifier="local.localclip.dev", CFBundleExecutable="LocalClip", CFBundleName="LocalClip Update Fixture", CFBundlePackageType="APPL", CFBundleShortVersionString=f"1.0.{build}", CFBundleVersion=str(build), LSMinimumSystemVersion="15.0", LSUIElement=True, LocalClipUpdatePublicKey=public, FixtureRoot=str(root), FixtureMode=fixture_mode)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            run("/usr/bin/codesign", "--force", "--sign", "-", str(app))

        target = root / "Applications/LocalClip.app"
        new = root / "package/LocalClip.app"
        make_app(target, 100, "old")
        make_app(new, 101, "fail" if mode == "fail" else "success")
        download = root / "download"
        download.mkdir()
        archive = download / "LocalClip-v1.0.101.zip"
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(new), str(archive))
        env = dict(os.environ, LOCALCLIP_UPDATE_PRIVATE_KEY=key.read_text())
        run(str(BIN / "LocalClipUpdateTool"), "manifest", str(new), str(archive), str(download), env=env)
        if mode == "tampered":
            with archive.open("ab") as stream:
                stream.write(b"invalid")
        if mode == "unwritable":
            target.parent.chmod(0o555)
        if mode == "snapshot-failure":
            (root / "Application Support/LocalClip-UpdateBackups").write_text("blocked snapshot destination")
        if mode == "success":
            # 只淘汰有成功标记的快照；失败或旧版无标记备份不能被顺带删除。
            snapshots = root / "Application Support/LocalClip-UpdateBackups"
            for name in [".LocalClip-update-old-success", ".LocalClip-update-failed-rescue"]:
                folder = snapshots / name
                folder.mkdir(parents=True)
                (folder / "data").write_text("rescue-data")
            (snapshots / ".LocalClip-update-old-success/update-succeeded").write_text("startup-confirmed")
            shutil.copy2(BIN / "LocalClipUpdater", download / "LocalClipUpdater")
        parent = subprocess.Popen(["/bin/sleep", "60"])
        request = dict(target=target.as_uri(), downloadDirectory=download.as_uri(), parentPID=parent.pid, currentBuild=100)
        (download / "request.json").write_text(json.dumps(request))
        helper = subprocess.Popen([str(BIN / "LocalClipUpdater"), str(download / "request.json")], env=dict(os.environ, LOCALCLIP_UPDATER_TEST_ROOT=str(root)), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        result = download / "result.txt"
        if mode in ["tampered", "unwritable"]:
            helper.wait(timeout=20)
            assert not (download / "installer-ready").exists()
            assert "更新失败" in result.read_text()
            assert parent.poll() is None
        else:
            wait_for(lambda: (download / "installer-ready").exists() or result.exists())
            assert not result.exists(), result.read_text() if result.exists() else ""
            assert plistlib.loads((target / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "100"
            parent.terminate()
            parent.wait(timeout=5)
            helper.wait(timeout=60)
            message = result.read_text()
            if mode == "success":
                assert message.startswith("更新成功"), message
                assert not list(target.parent.glob(".LocalClip-update-*"))
                assert not archive.exists()
                assert not (download / "LocalClipUpdater").exists()
                snapshots = root / "Application Support/LocalClip-UpdateBackups"
                assert not (snapshots / ".LocalClip-update-old-success").exists()
                assert (snapshots / ".LocalClip-update-failed-rescue/data").read_text() == "rescue-data"
                confirmed = list(snapshots.glob("*/update-succeeded"))
                assert len(confirmed) == 1
                assert (confirmed[0].parent / "data/history").read_text() == "existing-history"
            else:
                assert message.startswith("更新失败"), message
                assert "自动恢复失败" not in message, message
                wait_for(lambda: (root / "old.pid").exists())
                if mode == "fail":
                    snapshots = list((root / "Application Support/LocalClip-UpdateBackups").glob("*/data/history"))
                    assert len(snapshots) == 1 and snapshots[0].read_text() == "failed-new-data"
        expected_build = "101" if mode == "success" else "100"
        assert plistlib.loads((target / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == expected_build
        assert (data / "history").read_text() == "existing-history"
        assert (data / "settings").read_text() == "existing-settings"
        print(f"PASS: {mode}; installed build={expected_build}; history/settings preserved")
    finally:
        for process in [helper, parent]:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        for pid_file in root.glob("*.pid"):
            try:
                os.kill(int(pid_file.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
        # 撤销只读故障注入，再清理自己的临时安装目录。
        applications = root / "Applications"
        if applications.exists():
            applications.chmod(0o755)
        shutil.rmtree(root)


if __name__ == "__main__":
    for case in ["success", "fail", "tampered", "unwritable", "snapshot-failure"]:
        scenario(case)
