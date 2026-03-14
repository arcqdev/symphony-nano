# Symphony Nano

Symphony Nano is a fork of [openai/symphony](https://github.com/openai/symphony) focused on making
the runtime more pluggable without drifting too far from upstream.

The goal is straightforward:

- stay as close as possible to the upstream `openai/symphony` codebase
- add more connectors and stronger multi-project support
- keep changes as unintrusive as possible so rebases stay manageable
- take inspiration from `nanoclaw` by favoring composable, swappable integration points over heavy rewrites

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## What This Fork Is For

The point of this repo is not to reinvent Symphony from scratch. The point is to keep a version of
Symphony that is easier to adapt to real operating environments where you may need:

- more than one connector surface
- more than one project or repository in play
- backend-specific routing and orchestration hooks
- a cleaner way to extend behavior without carrying a large permanent diff

That makes this repo a practical base for experimentation, but the design constraint remains the
same: prefer minimal seams over invasive rewrites.

If you want the closest reference implementation, use the upstream repo:
[openai/symphony](https://github.com/openai/symphony)

If you want the fork that is intentionally optimized for pluggability and multi-project operation,
use this repo:
[arcqdev/symphony-nano](https://github.com/arcqdev/symphony-nano)

## Used By

[`symphonyclaw`](https://github.com/arcqdev/symphonyclaw) is built on top of Symphony Nano. That
project uses this fork as the execution substrate while adding higher-level project-specific
workflow and orchestration behavior.

## Running Symphony Nano

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use the Elixir implementation in this fork

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based implementation in this repository. You can also ask your favorite coding
agent to help with the setup:

> Set up Symphony Nano for my repository based on
> https://github.com/arcqdev/symphony-nano/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
