#!/usr/bin/env python3
"""Tests for nano/conductor/symphonyctl.py"""

import json
import os
import sys
from pathlib import Path
from unittest import mock

import pytest

# Import the module under test
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import symphonyctl


@pytest.fixture
def tmp_root(tmp_path):
    conductor = tmp_path / "nano" / "conductor"
    conductor.mkdir(parents=True)
    elixir = tmp_path / "elixir" / "bin"
    elixir.mkdir(parents=True)
    runtime = tmp_path / "nano" / ".runtime"
    runtime.mkdir(parents=True)
    return tmp_path


@pytest.fixture
def sample_registry(tmp_root):
    wf_dir = tmp_root / "projects" / "testproj" / ".symphony"
    wf_dir.mkdir(parents=True)
    wf_path = wf_dir / "WORKFLOW.md"
    wf_path.write_text("# Test\n", encoding="utf-8")

    reg = {
        "projects": {
            "testproj": {
                "repoPath": str(tmp_root / "projects" / "testproj"),
                "workflowPath": str(wf_path),
                "projectSlug": "test-slug",
                "port": 19876,
            }
        }
    }
    local_dir = tmp_root / "nano" / ".local"
    local_dir.mkdir(parents=True)
    reg_path = local_dir / "symphony-registry.json"
    reg_path.write_text(json.dumps(reg), encoding="utf-8")
    return reg_path


@pytest.fixture
def patch_paths(tmp_root, sample_registry):
    with mock.patch.object(symphonyctl, "REPO_ROOT", tmp_root), \
         mock.patch.object(symphonyctl, "NANO_ROOT", tmp_root / "nano"), \
         mock.patch.object(symphonyctl, "LOCAL_CONFIG_DIR", tmp_root / "nano" / ".local"), \
         mock.patch.object(symphonyctl, "DEFAULT_REGISTRY_PATH", sample_registry), \
         mock.patch.object(symphonyctl, "EXAMPLE_REGISTRY_PATH", tmp_root / "nano" / "conductor" / "symphony-registry.example.json"), \
         mock.patch.object(symphonyctl, "STATE_DIR", tmp_root / "nano" / ".runtime"), \
         mock.patch.object(symphonyctl, "BIN_PATH", tmp_root / "elixir" / "bin" / "symphony"):
        yield


class TestIsPortListening:
    def test_returns_false_for_unused_port(self):
        assert symphonyctl.is_port_listening(59999) is False

    def test_returns_true_for_listening_port(self):
        import socket

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        port = s.getsockname()[1]
        try:
            assert symphonyctl.is_port_listening(port) is True
        finally:
            s.close()


class TestPidAlive:
    def test_current_process_is_alive(self):
        assert symphonyctl.pid_alive(os.getpid()) is True

    def test_bogus_pid_is_not_alive(self):
        assert symphonyctl.pid_alive(99999999) is False


class TestLoadRegistry:
    def test_loads_valid_registry(self, patch_paths):
        reg = symphonyctl.load_registry()
        assert "projects" in reg
        assert "testproj" in reg["projects"]

    def test_raises_on_missing_file(self, tmp_root):
        with mock.patch.object(symphonyctl, "DEFAULT_REGISTRY_PATH", tmp_root / "nope.json"):
            with pytest.raises(FileNotFoundError):
                symphonyctl.load_registry()

    def test_uses_env_override(self, patch_paths, tmp_root):
        override = tmp_root / "custom-registry.json"
        override.write_text(json.dumps({"projects": {}}), encoding="utf-8")

        with mock.patch.dict(os.environ, {"SYMPHONY_REGISTRY_PATH": str(override)}):
            assert symphonyctl.registry_path() == override


class TestStatus:
    def test_missing_registry(self, patch_paths, tmp_root, capsys):
        with mock.patch.object(symphonyctl, "DEFAULT_REGISTRY_PATH", tmp_root / "missing.json"):
            rc = symphonyctl.status("testproj")
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert out["ok"] is False
        assert "Missing registry file" in out["error"]

    def test_unknown_project(self, patch_paths, capsys):
        rc = symphonyctl.status("nonexistent")
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert out["ok"] is False
        assert "Unknown project" in out["error"]

    def test_known_project_stopped(self, patch_paths, capsys):
        rc = symphonyctl.status("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["ok"] is True
        assert out["project"] == "testproj"
        assert out["status"] == "stopped"
        assert out["port"] == 19876
        assert out["projectSlug"] == "test-slug"

    def test_reads_state_file(self, patch_paths, tmp_root, capsys):
        state_file = tmp_root / "nano" / ".runtime" / "testproj.json"
        state_file.write_text(json.dumps({"pid": os.getpid()}), encoding="utf-8")
        rc = symphonyctl.status("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["pid"] == os.getpid()
        assert out["pidAlive"] is True


class TestStop:
    def test_noop_when_no_state(self, patch_paths, capsys):
        rc = symphonyctl.stop("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["action"] == "noop"

    def test_stops_running_process(self, patch_paths, tmp_root, capsys):
        state_file = tmp_root / "nano" / ".runtime" / "testproj.json"
        state_file.write_text(json.dumps({"pid": 99999999}), encoding="utf-8")
        rc = symphonyctl.stop("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["action"] == "stopped"


class TestEnsure:
    def test_missing_registry(self, patch_paths, tmp_root, capsys):
        with mock.patch.object(symphonyctl, "DEFAULT_REGISTRY_PATH", tmp_root / "missing.json"):
            rc = symphonyctl.ensure("testproj")
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert "Missing registry file" in out["error"]

    def test_unknown_project(self, patch_paths, capsys):
        rc = symphonyctl.ensure("nonexistent")
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert out["ok"] is False

    def test_missing_binary(self, patch_paths, capsys):
        rc = symphonyctl.ensure("testproj")
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert "Missing binary" in out["error"]

    def test_reuses_if_port_listening(self, patch_paths, tmp_root, capsys):
        bin_path = tmp_root / "elixir" / "bin" / "symphony"
        bin_path.write_text("#!/bin/sh\n", encoding="utf-8")
        bin_path.chmod(0o755)

        with mock.patch.object(symphonyctl, "is_port_listening", return_value=True):
            rc = symphonyctl.ensure("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["action"] == "reused"

    def test_starts_process(self, patch_paths, tmp_root, capsys):
        bin_path = tmp_root / "elixir" / "bin" / "symphony"
        bin_path.write_text("#!/bin/sh\nsleep 60\n", encoding="utf-8")
        bin_path.chmod(0o755)

        with mock.patch.object(symphonyctl, "is_port_listening", return_value=False):
            rc = symphonyctl.ensure("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["action"] == "started"
        assert out["pid"] is not None
        assert out["port"] == 19876

        state_file = tmp_root / "nano" / ".runtime" / "testproj.json"
        assert state_file.exists()
        state = json.loads(state_file.read_text(encoding="utf-8"))
        assert state["project"] == "testproj"

        try:
            os.kill(out["pid"], 9)
        except OSError:
            pass

    def test_missing_port_in_registry(self, patch_paths, sample_registry, tmp_root, capsys):
        bin_path = tmp_root / "elixir" / "bin" / "symphony"
        bin_path.write_text("#!/bin/sh\n", encoding="utf-8")
        bin_path.chmod(0o755)

        reg = json.loads(sample_registry.read_text(encoding="utf-8"))
        reg["projects"]["testproj"].pop("port")
        sample_registry.write_text(json.dumps(reg), encoding="utf-8")

        rc = symphonyctl.ensure("testproj")
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert "port missing from registry" in out["error"]


class TestMain:
    def test_status_via_main(self, patch_paths, capsys):
        with mock.patch("sys.argv", ["symphonyctl", "status", "testproj"]):
            rc = symphonyctl.main()
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["project"] == "testproj"

    def test_unknown_command_exits(self):
        with mock.patch("sys.argv", ["symphonyctl"]):
            with pytest.raises(SystemExit):
                symphonyctl.main()


class TestStatePath:
    def test_returns_correct_path(self, patch_paths):
        sp = symphonyctl.state_path("myproj")
        assert sp.name == "myproj.json"
        assert sp.parent == symphonyctl.STATE_DIR
