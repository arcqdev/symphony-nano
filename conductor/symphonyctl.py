#!/usr/bin/env python3
import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = ROOT / "conductor" / "symphony-registry.json"
STATE_DIR = ROOT / ".runtime"
BIN_PATH = ROOT / "elixir" / "bin" / "symphony"


def parse_frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    fm = text[3:end]
    data = {"server": {}, "tracker": {}}
    section = None
    for raw in fm.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        if re.match(r"^[a-zA-Z_]+:\s*$", line):
            section = line.split(":", 1)[0].strip()
            continue
        m = re.match(r"^\s{2,}([a-zA-Z_]+):\s*(.+?)\s*$", line)
        if m and section in ("server", "tracker"):
            key, val = m.group(1), m.group(2)
            val = val.strip().strip('"').strip("'")
            if key == "port":
                try:
                    val = int(val)
                except ValueError:
                    pass
            data.setdefault(section, {})[key] = val
    return data


def is_port_listening(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.35)
        return s.connect_ex(("127.0.0.1", port)) == 0


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def load_registry() -> dict:
    return json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))


def state_path(project: str) -> Path:
    return STATE_DIR / f"{project}.json"


def status(project: str) -> int:
    reg = load_registry()["projects"].get(project)
    if not reg:
        print(json.dumps({"ok": False, "error": f"Unknown project: {project}"}))
        return 1

    wf = Path(reg["workflowPath"]).expanduser()
    meta = parse_frontmatter(wf)
    port = meta.get("server", {}).get("port")
    slug = meta.get("tracker", {}).get("project_slug")

    state = {}
    sp = state_path(project)
    if sp.exists():
        state = json.loads(sp.read_text(encoding="utf-8"))

    pid = state.get("pid")
    alive = bool(pid and pid_alive(int(pid)))
    listening = bool(port and is_port_listening(int(port)))

    print(json.dumps({
        "ok": True,
        "project": project,
        "repoPath": reg["repoPath"],
        "workflowPath": str(wf),
        "projectSlug": slug,
        "port": port,
        "pid": pid,
        "pidAlive": alive,
        "portListening": listening,
        "status": "running" if listening else "stopped"
    }))
    return 0


def ensure(project: str) -> int:
    reg = load_registry()["projects"].get(project)
    if not reg:
        print(json.dumps({"ok": False, "error": f"Unknown project: {project}"}))
        return 1

    if not BIN_PATH.exists():
        print(json.dumps({"ok": False, "error": f"Missing binary: {BIN_PATH}"}))
        return 1

    wf = Path(reg["workflowPath"]).expanduser()
    meta = parse_frontmatter(wf)
    port = meta.get("server", {}).get("port")
    slug = meta.get("tracker", {}).get("project_slug")

    if not isinstance(port, int):
        print(json.dumps({"ok": False, "error": "server.port missing from workflow", "workflowPath": str(wf)}))
        return 1

    if is_port_listening(port):
        print(json.dumps({
            "ok": True,
            "project": project,
            "action": "reused",
            "port": port,
            "projectSlug": slug,
            "workflowPath": str(wf)
        }))
        return 0

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log_path = STATE_DIR / f"{project}.log"
    env = os.environ.copy()

    with log_path.open("ab") as logf:
        proc = subprocess.Popen(
            [
                str(BIN_PATH),
                "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
                str(wf),
            ],
            cwd=ROOT / "elixir",
            stdout=logf,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=env,
        )

    state = {
        "project": project,
        "pid": proc.pid,
        "port": port,
        "workflowPath": str(wf),
        "projectSlug": slug,
        "startedAt": datetime.now().isoformat()
    }
    state_path(project).write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")

    print(json.dumps({
        "ok": True,
        "project": project,
        "action": "started",
        "pid": proc.pid,
        "port": port,
        "projectSlug": slug,
        "statePath": str(state_path(project)),
        "logPath": str(log_path)
    }))
    return 0


def stop(project: str) -> int:
    sp = state_path(project)
    if not sp.exists():
        print(json.dumps({"ok": True, "project": project, "action": "noop", "reason": "no_state"}))
        return 0
    state = json.loads(sp.read_text(encoding="utf-8"))
    pid = state.get("pid")
    if pid and pid_alive(int(pid)):
        os.kill(int(pid), signal.SIGTERM)
    print(json.dumps({"ok": True, "project": project, "action": "stopped", "pid": pid}))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Deterministic Symphony launcher")
    sub = ap.add_subparsers(dest="cmd", required=True)

    for cmd in ("status", "ensure", "stop"):
        p = sub.add_parser(cmd)
        p.add_argument("project")

    args = ap.parse_args()
    if args.cmd == "status":
        return status(args.project)
    if args.cmd == "ensure":
        return ensure(args.project)
    if args.cmd == "stop":
        return stop(args.project)
    return 1


if __name__ == "__main__":
    sys.exit(main())
