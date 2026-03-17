# Symphony Portless Plan

## Goal

Allow multiple Symphony issue workspaces with frontend code to run and validate at the same time on the same host without fighting over `localhost:3000`, `5173`, or other fixed ports.

## Key point

Symphony already supports concurrent issue execution. The missing piece for frontend repos is a stable per-workspace preview URL layer. Vercel's `portless` fits that gap because it assigns each local app a named `.localhost` URL and works well with Git worktrees.

The optimal design is not to bake Portless into the Symphony core runtime as a mandatory dependency. It should be an opt-in workflow capability for repos that actually need concurrent frontend previews.

## Recommended rollout

### 1. Treat Portless as host-level infrastructure

- Install `portless` on every Symphony worker host.
- Start one shared proxy per host with HTTPS enabled.
- Keep this outside the app repo lifecycle; it is worker infrastructure, not project build logic.

Example:

```bash
npm install -g portless
portless proxy start --https
```

### 2. Standardize frontend preview startup in repos

- Every frontend-capable repo should have one documented "bring up local preview" command.
- Symphony should use that command instead of inventing ad hoc `npm run dev` flows in each ticket.
- Repos that need this should add a helper such as `bin/symphony-preview up|status|down` so agents can start, inspect, and stop previews consistently.

Target behavior:

- starts the repo's frontend dev server through `portless`
- prints the chosen public local URL
- writes pid/log metadata somewhere repo-local or workspace-local
- can be re-run safely

### 3. Use worktree-aware naming

The existing workspace bootstrap creates one Git worktree branch per issue. `portless run` can use that to produce unique preview subdomains automatically, which is exactly what we want for parallel issue work.

Recommended default:

```bash
portless run --name <repo-name> <frontend-dev-command>
```

Expected outcome:

- main checkout gets a base name such as `<repo-name>.localhost`
- linked issue worktrees get branch-prefixed names, so two issue workspaces can stay live together

If branch-derived names ever become awkward, fall back to an explicit issue-safe name:

```bash
portless --name <repo-name>-<issue-slug> <frontend-dev-command>
```

### 4. Record preview details in the workpad

For any ticket that touches frontend:

- record the preview startup command
- record the resulting `PORTLESS_URL`
- record any required backend/API companion URL
- record whether the preview is detached and still expected to be running

That gives continuation turns and humans a reliable handoff surface.

### 5. Validate against the named URL, not raw localhost ports

- Browser automation should target the Portless URL.
- Manual testing instructions in agent comments should reference the Portless URL.
- Avoid hardcoding `localhost:<port>` in the workflow because two active workspaces will collide eventually.

### 6. Handle frontend-to-backend proxying explicitly

If the frontend dev server proxies to a local API server that also runs through Portless, make sure the frontend proxy rewrites the `Host` header. Without that, requests can loop back into the frontend route.

Common example for Vite:

```ts
server: {
  proxy: {
    "/api": {
      target: "http://api.<repo-name>.localhost:1355",
      changeOrigin: true,
      ws: true,
    },
  },
}
```

### 7. Separate worker bootstrap from repo workflow

Use Symphony hooks for repo bootstrap and cleanup, but do not rely on `WORKFLOW.md` hooks to install Portless globally each run. That should happen once per worker host.

Good split:

- worker image/bootstrap: install Node, Portless, browser deps
- repo `after_create`: clone/setup/install project deps
- repo `before_run` or repo helper script: ensure preview is up when a frontend stage needs it
- repo `after_run` or `before_remove`: stop stale preview processes if the repo chooses detached previews

## Recommended Symphony implementation order

1. Keep Symphony core unchanged at first.
2. Update the shared webdev `WORKFLOW.md` template so frontend repos can opt into Portless cleanly.
3. Encourage frontend repos to provide a single repo-local preview helper command.
4. Add browser validation steps that consume a preview URL written to the workpad.
5. Only consider first-class runtime support in Symphony itself if repeated workflow friction shows up across multiple repos.

## Optimal design choice

Prefer this layering:

- Symphony core:
  - knows nothing Portless-specific beyond allowing workflow instructions and hooks
  - continues to manage concurrency, workspaces, routing, and retries
- Workflow/template layer:
  - tells agents when to start a preview
  - tells agents to record the preview URL
  - tells agents to validate against that URL
- Repo layer:
  - provides the actual startup command and framework-specific proxy config
- Worker host layer:
  - installs Portless and keeps the shared proxy available

That gives you the benefit you want without coupling Symphony to a single frontend transport choice.

## Template implications

The shared webdev workflow template should:

- mention stage routing explicitly
- use current Symphony status names, especially `BLOCKED - requires human`
- instruct frontend stages to prefer Portless for preview URLs
- require the preview command and URL to be written to the workpad
- avoid assuming a single fixed localhost port
