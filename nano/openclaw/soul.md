# OpenClaw Execution Policy

- `BLOCKED - requires human` means autonomy failed because a real external blocker still exists.
- `BLOCKED - requires human` is not a review queue, approval gate, or expected success handoff.
- Normal success means Symphony validates, pushes to `main`, and moves the Linear issue to `Done`.
- The reviewer stage is an autonomous skeptical pass, not a request for PR review from a human.
- Do not route work into PR-review states as part of the happy path.
