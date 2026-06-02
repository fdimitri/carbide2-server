# JWT claims — control plane → workspace

This file is **mirrored from [carbide2-control](https://github.com/fdimitri/carbide2-control)**.
Keep both copies in sync by hand. If the wire format ever changes, both repos
must be updated and redeployed in lockstep.

## Algorithm

`HS256` against a shared secret stored in the Kubernetes Secret `workspace-jwt`.
The carbide2-control operator mirrors this secret into every `ws-N` namespace
at provision time, where this workspace reads it as `WORKER_JWT_SECRET`.

## Required claims (new format, control-plane-minted)

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
2. `iss == "carbide-control"` (new format) OR no `iss` claim (legacy format — accepted while we transition).
3. If new format: `aud == "workspace:#{ENV['WORKSPACE_PROJECT_ID']}"`.
4. `exp > now`.
5. If new format: `project_id == ENV['WORKSPACE_PROJECT_ID'].to_i`.

## Legacy format (server-minted by `WorkerTokenIssuer`)

For backward compatibility while the control plane is being adopted, the
worker also accepts tokens with these claim names:

| Claim     | Type    | Notes                                           |
| --------- | ------- | ----------------------------------------------- |
| `sub`     | integer | user id                                         |
| `user`    | integer | user id                                         |
| `name`    | string  | display name                                    |
| `project` | integer | project id                                      |
| `exp`     | integer | required                                        |

When the control plane is fully in production, `WorkerTokenIssuer` and the
legacy claim names will be removed.
