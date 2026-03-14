# TODO

## Shared BEAM VM for multi-project orchestration

**Status:** Deferred — document and design forward, implement later.

Right now each project gets its own BEAM VM via `symphonyctl ensure <project>`, which spawns a separate `./bin/symphony` OS process. This works but scales linearly in memory (~50MB per VM) and operational complexity (N processes to monitor).

The BEAM is built to run many isolated supervision trees in a single node. The change would:

- Add a `ProjectManager` (DynamicSupervisor) and `ProjectRegistry` (Registry) at the top level
- Wrap the existing per-project children (WorkflowStore, Orchestrator, HttpServer, StatusDashboard) in a `ProjectSupervisor`
- Replace all `name: __MODULE__` registrations with `{:via, Registry, {ProjectRegistry, {project_id, __MODULE__}}}`
- Thread `project_id` through `Config.settings!()` resolution (~30 call sites)

### What stays the same

- `symphonyctl.py` external interface: `ensure`, `stop`, `status` commands and their JSON output
- WORKFLOW.md format and per-project config
- Codex/Claude session lifecycle (these are separate OS processes regardless)

### What changes internally

- `symphonyctl ensure` sends an HTTP/RPC call to the running node instead of `subprocess.Popen`
- `symphonyctl stop` sends an RPC instead of `os.kill`
- `symphonyctl status` queries the Registry instead of checking PID/port liveness
- One BEAM boots at system start; projects are added/removed dynamically

### Why not now

The memory savings (~40MB per additional project) aren't significant on dev machines. The real cost is touching ~30 `Config.settings!()` call sites in upstream code. Worth doing when operational complexity of managing N processes becomes the bottleneck, or when deploying to a shared server where memory matters.
