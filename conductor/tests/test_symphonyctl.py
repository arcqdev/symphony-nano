#!/usr/bin/env python3
"""Tests for conductor/symphonyctl.py"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

import pytest

# Import the module under test
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import symphonyctl


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def tmp_root(tmp_path):
    """Create a temporary project root with conductor/ and elixir/ layout."""
    conductor = tmp_path / "conductor"conductor.mkdir()
    elixir = tmp_path / "elixir" / "bin"
    elixir.mkdir(parents=True)
    runtime = tmp_path / ".runtime"
    runtime.mkdir()
    return tmp_path


@pytest.fixture
def sample_registry(tmp_root):
    """Write a minimal registry and return its path."""
    wf_dir = tmp_root / "projects" / "testproj" / ".symphony"
    wf_dir.mkdir(parents=True)
    wf_path = wf_dir / "WORKFLOW.md"
    wf_path.write_text(
        "---\nserver:\n  port: 19876\ntracker:\n  project_slug: test-slug\n---\n# Test\n",
        encoding="utf-8",
    )

    reg = {
        "projects": {
            "testproj": {
                "repoPath": str(tmp_root / "projects" / "testproj"),
                "workflowPath": str(wf_path),
            }
        }
    }
    reg_path = tmp_root / "conductor"/ "symphony-registry.json"
    reg_path.write_text(json.dumps(reg), encoding="utf-8")
    return reg_path


@pytest.fixture
def patch_paths(tmp_root, sample_registry):
    """Monkey-patch module-level paths to point at the temp root."""
    with mock.patch.object(symphonyctl, "ROOT", tmp_root), \
         mock.patch.object(symphonyctl, "REGISTRY_PATH", sample_registry), \
         mock.patch.object(symphonyctl, "STATE_DIR", tmp_root / ".runtime"), \
         mock.patch.object(symphonyctl, "BIN_PATH", tmp_root / "elixir" / "bin" / "symphony"):
        yield


# ---------------------------------------------------------------------------
# parse_frontmatter
# ---------------------------------------------------------------------------

class TestParseFrontmatter:
    def test_parses_server_and_tracker(self, tmp_path):
        p = tmp_path / "wf.md"
        p.write_text(
            "---\nserver:\n  port: 4000\ntracker:\n  project_slug: my-proj\n---\n# body\n",
            encoding="utf-8",
        )
        result = symphonyctl.parse_frontmatter(p)
        assert result["server"]["port"] == 4000
        assert result["tracker"]["project_slug"] == "my-proj"

    def test_returns_empty_without_frontmatter(self, tmp_path):
        p = tmp_path / "wf.md"
        p.write_text("# No frontmatter here\n", encoding="utf-8")
        assert symphonyctl.parse_frontmatter(p) == {}

    def test_returns_empty_for_unclosed_frontmatter(self, tmp_path):
        p = tmp_path / "wf.md"
        p.write_text("---\nserver:\n  port: 4000\n# never closed\n", encoding="utf-8")
        assert symphonyctl.parse_frontmatter(p) == {}

    def test_ignores_unknown_sections(self, tmp_path):
        p = tmp_path / "wf.md"
        p.write_text(
            "---\nrandom:\n  key: val\nserver:\n  port: 8080\n---\n",
            encoding="utf-8",
        )
        result = symphonyctl.parse_frontmatter(p)
        assert result["server"]["port"] == 8080
        assert "random" not in result or result.get("random") is None

    def test_handles_quoted_values(self, tmp_path):
        p = tmp_path / "wf.md"
        p.write_text(
            '---\ntracker:\n  project_slug: "quoted-slug"\n---\n',
            encoding="utf-8",
        )
        result = symphonyctl.parse_frontmatter(p)
        assert result["tracker"]["project_slug"] == "quoted-slug"

    def test_port_non_numeric_stays_string(self, tmp_path):
        p = tmp_path / "wf.md"
        p.write_text(
            "---\nserver:\n  port: auto\n---\n",
            encoding="utf-8",
        )
        result = symphonyctl.parse_frontmatter(p)
        assert result["server"]["port"] == "auto"

    def test_skips_comments_and_blanks(self, tmp_path):
        p = tmp_path / "wf.md"
        p.write_text(
            "---\nserver:\n  # this is a comment\n\n  port: 3000\n---\n",
            encoding="utf-8",
        )
        result = symphonyctl.parse_frontmatter(p)
        assert result["server"]["port"] == 3000


# ---------------------------------------------------------------------------
# is_port_listening
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# pid_alive
# ---------------------------------------------------------------------------

class TestPidAlive:
    def test_current_process_is_alive(self):
        assert symphonyctl.pid_alive(os.getpid()) is True

    def test_bogus_pid_is_not_alive(self):
        assert symphonyctl.pid_alive(99999999) is False


# ---------------------------------------------------------------------------
# load_registry
# ---------------------------------------------------------------------------

class TestLoadRegistry:
    def test_loads_valid_registry(self, patch_paths, sample_registry):
        reg = symphonyctl.load_registry()
        assert "projects" in reg
        assert "testproj" in reg["projects"]

    def test_raises_on_missing_file(self, tmp_root):
        with mock.patch.object(symphonyctl, "REGISTRY_PATH", tmp_root / "nope.json"):
            with pytest.raises(FileNotFoundError):
                symphonyctl.load_registry()


# ---------------------------------------------------------------------------
# status command
# ---------------------------------------------------------------------------

class TestStatus:
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
        state_file = tmp_root / ".runtime" / "testproj.json"
        state_file.write_text(json.dumps({"pid": os.getpid()}), encoding="utf-8")
        rc = symphonyctl.status("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["pid"] == os.getpid()
        assert out["pidAlive"] is True


# ---------------------------------------------------------------------------
# stop command
# ---------------------------------------------------------------------------

class TestStop:
    def test_noop_when_no_state(self, patch_paths, capsys):
        rc = symphonyctl.stop("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["action"] == "noop"

    def test_stops_running_process(self, patch_paths, tmp_root, capsys):
        state_file = tmp_root / ".runtime" / "testproj.json"
        # use a fake pid that we won't actually kill
        state_file.write_text(json.dumps({"pid": 99999999}), encoding="utf-8")
        rc = symphonyctl.stop("testproj")
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["action"] == "stopped"


# ---------------------------------------------------------------------------
# ensure command
# ---------------------------------------------------------------------------

class TestEnsure:
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
        # create fake binary so it passes that check
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

        # verify state file was written
        state_file = tmp_root / ".runtime" / "testproj.json"
        assert state_file.exists()
        state = json.loads(state_file.read_text(encoding="utf-8"))
        assert state["project"] == "testproj"

        # cleanup spawned process
        try:
            os.kill(out["pid"], 9)
        except OSError:
            pass

    def test_missing_port_in_workflow(self, patch_paths, tmp_root, capsys):
        bin_path = tmp_root / "elixir" / "bin" / "symphony"
        bin_path.write_text("#!/bin/sh\n", encoding="utf-8")
        bin_path.chmod(0o755)

        # rewrite workflow without port
        reg = symphonyctl.load_registry()
        wf_path = Path(reg["projects"]["testproj"]["workflowPath"])
        wf_path.write_text("---\nserver:\n  host: localhost\n---\n", encoding="utf-8")

        rc = symphonyctl.ensure("testproj")
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert "server.port missing" in out["error"]


# ---------------------------------------------------------------------------
# CLI main() via argparse
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# state_path
# ---------------------------------------------------------------------------

class TestStatePath:
    def test_returns_correct_path(self, patch_paths):
        sp = symphonyctl.state_path("myproj")
        assert sp.name == "myproj.json"
        assert sp.parent == symphonyctl.STATE_DIR
