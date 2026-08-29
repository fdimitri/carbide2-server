# JWT claims — control plane → workspace

This file is **mirrored from [carbide2-control](https://github.com/fdimitri/carbide2-control)**.
Keep both copies in sync by hand. If the wire format ever changes, both repos
must be updated and redeployed in lockstep.

## Algorithm

`HS256` against a shared secret stored in the Kubernetes Secret `workspace-jwt`.
The carbide2-control operator mirrors this secret into every `ws-N` namespace
at provision time, where this workspace reads it as `WORKER_JWT_SECRET`.

## Required claims

| Claim        | Type    | Example                  | Notes                                                     |
| ------------ | ------- | ------------------------ | --------------------------------------------------------- |
| `iss`        | string  | `carbide-control`        | Constant. Workspace rejects tokens with any other issuer. |
| `sub`        | string  | `user:42`                | `user:<control_plane_user_id>`.                           |
| `aud`        | string  | `workspace:42`           | `workspace:<project_id>`. Workspace rejects mismatch.     |
| `exp`        | integer | `1733184000`             | Unix seconds. TTL: 5 minutes.                             |
| `iat`        | integer | `1733183700`             | Unix seconds.                                             |
| `user_id`    | integer | `42`                     | Control-plane DB primary key.                             |
| `user_email` | string  | `alice@example.com`      | Denormalized for display + audit.                         |
| `project_id` | integer | `42`                     | Must match `aud` suffix and `WORKSPACE_PROJECT_ID`.       |
| `scope`      | string  | `workspace:rw`           | Currently always `workspace:rw`.                          |

## Validation rules

The worker verifies, in order:

1. Signature valid against `WORKER_JWT_SECRET`.
2. `iss == "carbide-control"`.
3. `aud == "workspace:#{ENV['WORKSPACE_PROJECT_ID']}"`.
4. `exp > now`.
5. `project_id == ENV['WORKSPACE_PROJECT_ID'].to_i`.
6. `scope` is in the allowlist `[workspace:rw]`.

## Future claims (reserved)

- `agent_id` — when an agent (not a human) is connecting on the user's behalf.
- `terminal_ids` — allowlist of terminal IDs the agent may attach to.
- `expires_after_idle` — kill the WS if no traffic for N seconds.
