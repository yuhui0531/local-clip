#!/usr/bin/env python3
"""临时 ad-hoc 应用验证辅助进程成功安装、回滚、取消、验签拒绝、补偿清理与旧辅助程序兼容，by AI.Coding。

所有应用、进程、历史、锁和偏好都位于 /private/tmp 下本次创建的隔离根；不触碰已安装的 LocalClip 或用户数据。
LOCALCLIP_LEGACY_UPDATERS（冒号分隔的旧版 Debug 辅助程序路径）存在时额外验证“旧辅助程序 → 新补偿”。
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / ".build/debug"
FIXTURE = '''// 隔离测试应用，只读写 fixture 目录，by AI.Coding。
import AppKit
let info = Bundle.main.infoDictionary!
let base = URL(fileURLWithPath: info["FixtureRoot"] as! String)
let mode = info["FixtureMode"] as! String
let pid = String(ProcessInfo.processInfo.processIdentifier)
try! pid.write(to: base.appendingPathComponent(mode + ".pid"), atomically: true, encoding: .utf8)
try! pid.write(to: base.appendingPathComponent("pids/" + pid), atomically: true, encoding: .utf8)
if mode == "fail" {
    try! "failed-new-data".write(to: base.appendingPathComponent("Application Support/LocalClip-LocalEdition/history"), atomically: true, encoding: .utf8)
    exit(1)
}
if let index = CommandLine.arguments.firstIndex(of: "--localclip-update-receipt") {
    try! (info["CFBundleVersion"] as! String).write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
}
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
'''


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


class Fixture:
    """一个隔离根：真实 Mach-O fixture、ad-hoc 签名、Ed25519 清单与独立数据/缓存/会话目录。"""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="localclip-update-test-", dir="/private/tmp"))
        self.processes = []
        self.key = self.root / "keys/private"
        self.public = run(str(BIN / "LocalClipUpdateTool"), "keygen", str(self.key))
        self.support = self.root / "Application Support"
        self.data = self.support / "LocalClip-LocalEdition"
        self.data.mkdir(parents=True)
        (self.data / "history").write_text("existing-history")
        (self.data / "settings").write_text("existing-settings")
        (self.root / "pids").mkdir()
        self.cache = self.root / "Caches/Updates"
        self.cache.mkdir(parents=True)
        self.sessions = self.support / "LocalClip-UpdateSessions"
        self.backups = self.support / "LocalClip-UpdateBackups"
        source = self.root / "Fixture.swift"
        source.write_text(FIXTURE)
        self.executable = self.root / "Fixture"
        run("/usr/bin/swiftc", "-module-cache-path", str(ROOT / ".cache/update-fixture"), str(source), "-o", str(self.executable))
        self.target = self.root / "Applications/LocalClip.app"
        self.make_app(self.target, 100, "old")
        self.env = dict(os.environ, LOCALCLIP_UPDATER_TEST_ROOT=str(self.root))
        self.sentinel = self.root / "outside-sentinel"
        self.sentinel.write_text("keep")

    def make_app(self, app, build, mode):
        """用真实 Mach-O 和 ad-hoc 签名覆盖代码签名/LaunchServices 路径。"""
        (app / "Contents/MacOS").mkdir(parents=True)
        shutil.copy2(self.executable, app / "Contents/MacOS/LocalClip")
        info = dict(CFBundleIdentifier="local.localclip.dev", CFBundleExecutable="LocalClip", CFBundleName="LocalClip Update Fixture", CFBundlePackageType="APPL", CFBundleShortVersionString=f"1.0.{build}", CFBundleVersion=str(build), LSMinimumSystemVersion="15.0", LSUIElement=True, LocalClipUpdatePublicKey=self.public, FixtureRoot=str(self.root), FixtureMode=mode)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run("/usr/bin/codesign", "--force", "--sign", "-", str(app))

    def build(self):
        return int(plistlib.loads((self.target / "Contents/Info.plist").read_bytes())["CFBundleVersion"])

    def package(self, build, mode):
        """生成与发布流程同格式的下载会话目录：缓存根下的 UUID 子目录。"""
        new = self.root / f"package-{uuid.uuid4()}/LocalClip.app"
        self.make_app(new, build, mode)
        download = self.cache / str(uuid.uuid4()).upper()
        download.mkdir()
        archive = download / f"LocalClip-v1.0.{build}.zip"
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(new), str(archive))
        run(str(BIN / "LocalClipUpdateTool"), "manifest", str(new), str(archive), str(download), env=dict(os.environ, LOCALCLIP_UPDATE_PRIVATE_KEY=self.key.read_text()))
        shutil.rmtree(new.parent)
        return download, archive

    def start(self, download, helper=BIN / "LocalClipUpdater"):
        """与主程序一致：辅助程序复制到下载目录后从那里运行。"""
        parent = subprocess.Popen(["/bin/sleep", "120"])
        self.processes.append(parent)
        request = dict(target=self.target.as_uri(), downloadDirectory=download.as_uri(), parentPID=parent.pid, currentBuild=self.build())
        (download / "request.json").write_text(json.dumps(request))
        shutil.copy2(helper, download / "LocalClipUpdater")
        process = subprocess.Popen([str(download / "LocalClipUpdater"), str(download / "request.json")], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(process)
        return parent, process

    def janitor(self, *exclude, quiet=None):
        env = dict(self.env) if quiet is None else dict(self.env, LOCALCLIP_JANITOR_QUIET=str(quiet))
        return run(str(BIN / "LocalClipUpdateTool"), "janitor", *[str(path) for path in exclude], env=env)

    def records(self):
        return [json.loads(path.read_text()) for path in self.sessions.glob("*.json")] if self.sessions.exists() else []

    def workspaces(self):
        return list(self.target.parent.glob(".LocalClip-update-*"))

    def stop_fixture_apps(self):
        for pid_file in (self.root / "pids").glob("*"):
            try:
                os.kill(int(pid_file.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
            pid_file.unlink()

    def lock_paths(self):
        """T-02：测试锁身份随隔离根变化，文件必须落在隔离根而不是用户临时目录。"""
        digest = hashlib.sha256(("localclip-update-test-" + self.root.name).encode()).hexdigest()
        name = f"localclip-{os.getuid()}-{digest}.lock"
        return self.root / name, Path(tempfile.gettempdir()) / name

    def assert_data_intact(self):
        assert (self.data / "history").read_text() == "existing-history"
        assert (self.data / "settings").read_text() == "existing-settings"
        assert self.sentinel.read_text() == "keep"

    def close(self, legacy_lock=False):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        time.sleep(0.2)
        self.stop_fixture_apps()
        _, outside = self.lock_paths()
        # 旧版辅助程序（T-02 修复前）会在临时目录留下此精确路径的测试锁；只删这一确定文件，不做通配删除。
        if legacy_lock and outside.exists() and outside.stat().st_size == 0:
            outside.unlink()
        applications = self.root / "Applications"
        if applications.exists():
            applications.chmod(0o755)
        shutil.rmtree(self.root)


def finish(download, parent, helper):
    """安装器就绪后模拟旧进程退出，等待辅助程序结束。"""
    wait_for(lambda: (download / "installer-ready").exists() or helper.poll() is not None)
    parent.terminate()
    parent.wait(timeout=5)
    helper.wait(timeout=60)


def scenario(mode):
    fixture = Fixture()
    try:
        if mode == "snapshot-failure":
            fixture.backups.write_text("blocked snapshot destination")
        if mode == "success":
            # 带旧成功标记的快照按旧语义淘汰；无标记救援快照保留。名称与真实会话一致（UUID）。
            old_success, rescue = (f".LocalClip-update-{str(uuid.uuid4()).upper()}" for _ in range(2))
            for name in [old_success, rescue]:
                (fixture.backups / name).mkdir(parents=True)
                (fixture.backups / name / "data").write_text("rescue-data")
            (fixture.backups / old_success / "update-succeeded").write_text("startup-confirmed")
        download, archive = fixture.package(101, "fail" if mode == "fail" else "success")
        if mode == "tampered":
            with archive.open("ab") as stream:
                stream.write(b"invalid")
        if mode == "unwritable":
            fixture.target.parent.chmod(0o555)
        parent, helper = fixture.start(download)
        result = download / "result.txt"
        if mode in ["tampered", "unwritable"]:
            helper.wait(timeout=20)
            assert not (download / "installer-ready").exists()
            assert "更新失败" in result.read_text()
            assert parent.poll() is None
            # 父进程仍在读取结果：下载目录保留给主程序；未产生工作区。
            assert download.exists() and not fixture.workspaces()
            if mode == "unwritable":
                assert [r["phase"] for r in fixture.records()] == ["abortedBeforeSwap"]
        else:
            wait_for(lambda: (download / "installer-ready").exists() or result.exists())
            assert not result.exists(), result.read_text() if result.exists() else ""
            assert fixture.build() == 100
            parent.terminate()
            parent.wait(timeout=5)
            helper.wait(timeout=60)
            records = [r for r in fixture.records() if not r["legacy"]]
            assert len(records) == 1, records
            record = records[0]
            if mode == "success":
                assert record["phase"] == "succeeded" and record["result"].startswith("更新成功"), record
                assert not fixture.workspaces() and not download.exists()
                assert not (fixture.backups / old_success).exists()
                assert (fixture.backups / rescue / "data").read_text() == "rescue-data"
                assert (fixture.backups / record["id"] / "data/history").read_text() == "existing-history"
            else:
                assert record["result"].startswith("更新失败") and "自动恢复失败" not in record["result"], record
                wait_for(lambda: (fixture.root / "old.pid").exists())
                assert not fixture.workspaces(), fixture.workspaces()
                assert not download.exists()
                if mode == "fail":
                    assert record["phase"] == "rolledBack"
                    snapshots = list(fixture.backups.glob("*/data/history"))
                    assert len(snapshots) == 1 and snapshots[0].read_text() == "failed-new-data"
                else:
                    assert record["phase"] == "abortedBeforeSwap"
        expected_build = 101 if mode == "success" else 100
        assert fixture.build() == expected_build
        fixture.assert_data_intact()
        inside, outside = fixture.lock_paths()
        if mode in ["success", "fail", "snapshot-failure"]:
            assert inside.exists() and not outside.exists(), (inside, outside)
        print(f"PASS: {mode}; installed build={expected_build}; history/settings preserved")
    finally:
        fixture.close()


def cancel():
    """取消退出：辅助程序被终止且父进程仍在，补偿回收工作区，包恢复就绪后可原样复用安装。"""
    fixture = Fixture()
    try:
        download, archive = fixture.package(101, "success")
        parent, helper = fixture.start(download)
        wait_for(lambda: (download / "installer-ready").exists())
        assert len(fixture.workspaces()) == 1
        helper.send_signal(signal.SIGTERM)
        helper.wait(timeout=10)
        # 主程序在确认退出后删除本次尝试文件并把目录设为就绪（排除）。
        for name in ["LocalClipUpdater", "installer-ready", "startup-ok", "result.txt", "request.json"]:
            (download / name).unlink(missing_ok=True)
        fixture.janitor(download)
        assert not fixture.workspaces() and archive.exists()
        record = fixture.records()[0]
        assert record["phase"] == "abortedBeforeSwap" and "download" not in record, record
        parent.terminate()
        parent.wait(timeout=5)
        parent, helper = fixture.start(download)
        finish(download, parent, helper)
        assert fixture.build() == 101 and not download.exists() and not fixture.workspaces()
        fixture.assert_data_intact()
        print("PASS: cancel; package reused without re-download; workspace reclaimed")
    finally:
        fixture.close()


def repeated():
    """连续 10 轮成功/回滚/取消混合：可删除产物不随轮次增长，回滚快照单独计数保留。"""
    fixture = Fixture()
    rollbacks = 0
    try:
        for round_index in range(10):
            fixture.stop_fixture_apps()
            current = fixture.build()
            kind = ["success", "fail", "cancel"][round_index % 3]
            download, _ = fixture.package(current + 1, "fail" if kind == "fail" else "success")
            parent, helper = fixture.start(download)
            if kind == "cancel":
                wait_for(lambda: (download / "installer-ready").exists())
                helper.send_signal(signal.SIGTERM)
                helper.wait(timeout=10)
                parent.terminate()
                parent.wait(timeout=5)
            else:
                finish(download, parent, helper)
                rollbacks += kind == "fail"
            fixture.janitor()
        downloads = list(fixture.cache.iterdir())
        snapshots = list(fixture.backups.iterdir())
        records = fixture.records()
        success = [r for r in records if r["phase"] == "succeeded" and (fixture.backups / r["id"]).exists()]
        assert not fixture.workspaces(), fixture.workspaces()
        assert not downloads, downloads
        assert len(success) <= 1 and len(snapshots) == rollbacks + len(success), (snapshots, records)
        assert len(records) <= rollbacks + 2, records
        fixture.assert_data_intact()
        print(f"PASS: repeated; 10 rounds; build={fixture.build()}; workspaces=0 downloads=0 success-snapshots={len(success)} rollback-snapshots={rollbacks} records={len(records)}")
    finally:
        fixture.close()


def legacy(helper_path):
    """旧辅助程序执行本次升级：其运行期间新补偿不碰；结束并过静默期后按旧结果回收。"""
    fixture = Fixture()
    try:
        download, archive = fixture.package(101, "success")
        parent, helper = fixture.start(download, Path(helper_path))
        wait_for(lambda: (download / "installer-ready").exists())
        workspaces = fixture.workspaces()
        fixture.janitor(quiet=0)
        assert fixture.workspaces() == workspaces and archive.exists(), "活跃旧辅助程序的文件不能因新锁空闲被清理"
        parent.terminate()
        parent.wait(timeout=5)
        helper.wait(timeout=60)
        assert (download / "result.txt").read_text().startswith("更新成功")
        fixture.janitor(quiet=0)
        records = fixture.records()
        assert not fixture.workspaces() and not download.exists(), (fixture.workspaces(), records)
        assert [r["phase"] for r in records] == ["succeeded"] and records[0]["result"].startswith("更新成功"), records
        assert (fixture.backups / records[0]["id"] / "data/history").read_text() == "existing-history"
        assert fixture.build() == 101
        fixture.assert_data_intact()
        print(f"PASS: legacy helper {Path(helper_path).parents[3].name}; migrated and reclaimed")
    finally:
        fixture.close(legacy_lock=True)


if __name__ == "__main__":
    for case in ["success", "fail", "tampered", "unwritable", "snapshot-failure"]:
        scenario(case)
    cancel()
    repeated()
    for path in filter(None, os.environ.get("LOCALCLIP_LEGACY_UPDATERS", "").split(":")):
        legacy(path)
