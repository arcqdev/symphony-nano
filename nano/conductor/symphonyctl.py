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

REPO_ROOT = Path(__file__).resolve().parents[2]
NANO_ROOT = REPO_ROOT / "nano"
REGISTRY_PATH = NANO_ROOT / "conductor" / "symphony-registry.json"
STATE_DIR = NANO_ROOT / ".runtime"
BIN_PATH = REPO_ROOT / "elixir" / "bin" / "symphony"


def load_linear_api_key_from_zshrc() -> str | None:
    zshrc = Path.home() / ".zshrc"
    if not zshrc.exists():
        return None
    text = zshrc.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"^\s*export\s+LINEAR_API_KEY=['\"]?([^'\"\n]+)", text, flags=re.MULTILINE)
    if not m:
        return None
    key = m.group(1).strip()
    return key or None


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


def print_json(payload: dict) -> None:
    print(json.dumps(payload))


def load_state(project: str) -> dict:
    sp = state_path(project)
    if not sp.exists():
        return {}
    return json.loads(sp.read_text(encoding="utf-8"))


def save_state(project: str, state: dict) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    sp = state_path(project)
    sp.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    return sp


def load_project_entry(project: str) -> dict | None:
    return load_registry()["projects"].get(project)


def build_process_env() -> dict[str, str]:
    env = os.environ.copy()
    if env.get("LINEAR_API_KEY"):
        return env

    zshrc_key = load_linear_api_key_from_zshrc()
    if zshrc_key:
        env["LINEAR_API_KEY"] = zshrc_key
    return env


def status(project: str) -> int:
    project_entry = load_project_entry(project)
    if project_entry is None:
        print_json({"ok": False, "error": f"Unknown project: {project}"})
        return 1

    workflow_path = Path(project_entry["workflowPath"]).expanduser()
    port = project_entry.get("port")
    state = load_state(project)
    pid = state.get("pid")
    alive = bool(pid and pid_alive(int(pid)))
    listening = isinstance(port, int) and is_port_listening(port)

    print_json({
        "ok": True,
        "project": project,
        "repoPath": project_entry["repoPath"],
        "workflowPath": str(workflow_path),
        "projectSlug": project_entry.get("projectSlug"),
        "port": port,
        "pid": pid,
        "pidAlive": alive,
        "portListening": listening,
        "status": "running" if listening else "stopped",
    })
    return 0


def ensure(project: str) -> int:
    project_entry = load_project_entry(project)
    if project_entry is None:
        print_json({"ok": False, "error": f"Unknown project: {project}"})
        return 1

    if not BIN_PATH.exists():
        print_json({"ok": False, "error": f"Missing binary: {BIN_PATH}"})
        return 1

    workflow_path = Path(project_entry["workflowPath"]).expanduser()
    port = project_entry.get("port")
    project_slug = project_entry.get("projectSlug")

    if not isinstance(port, int):
        print_json({
            "ok": False,
            "error": "port missing from registry",
            "workflowPath": str(workflow_path),
            "registryPath": str(REGISTRY_PATH),
        })
        return 1

    if is_port_listening(port):
        print_json({
            "ok": True,
            "project": project,
            "action": "reused",
            "port": port,
            "projectSlug": project_slug,
            "workflowPath": str(workflow_path),
        })
        return 0

    log_path = STATE_DIR / f"{project}.log"
    env = build_process_env()
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    with log_path.open("ab") as logf:
        proc = subprocess.Popen(
            [
                str(BIN_PATH),
                "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
                str(workflow_path),
            ],
            cwd=REPO_ROOT / "elixir",
            stdout=logf,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=env,
        )

    state = {
        "project": project,
        "pid": proc.pid,
        "port": port,
        "workflowPath": str(workflow_path),
        "projectSlug": project_slug,
        "startedAt": datetime.now().isoformat(),
    }
    state_file = save_state(project, state)

    print_json({
        "ok": True,
        "project": project,
        "action": "started",
        "pid": proc.pid,
        "port": port,
        "projectSlug": project_slug,
        "statePath": str(state_file),
        "logPath": str(log_path),
    })
    return 0


def stop(project: str) -> int:
    state = load_state(project)
    if not state:
        print_json({"ok": True, "project": project, "action": "noop", "reason": "no_state"})
        return 0

    pid = state.get("pid")
    if pid and pid_alive(int(pid)):
        os.kill(int(pid), signal.SIGTERM)

    print_json({"ok": True, "project": project, "action": "stopped", "pid": pid})
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="Deterministic Symphony launcher")
    sub = ap.add_subparsers(dest="cmd", required=True)

    commands = {"status": status, "ensure": ensure, "stop": stop}
    for cmd, handler in commands.items():
        p = sub.add_parser(cmd)
        p.add_argument("project")
        p.set_defaults(handler=handler)
    return ap


def main() -> int:
    args = build_parser().parse_args()
    return args.handler(args.project)


if __name__ == "__main__":
    sys.exit(main())
