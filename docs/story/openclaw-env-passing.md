# OpenClaw: Environment Variable Passing to Exec

Research summary on how OpenClaw handles environment variable inheritance into exec subprocesses, what's blocked, what's allowed, and what mechanisms exist or are proposed for operator control.

## Core Problem

OpenClaw's security model blocks many environment variables (especially credential-shaped ones like `GITHUB_TOKEN`, `GH_TOKEN`, `AWS_SECRET_ACCESS_KEY`) from reaching exec subprocesses. Operators need a way to selectively allow specific env vars through to trusted exec children.

## Security Architecture (Layered)

There are five layered security boundaries, each filtering env vars at different stages:

### 1. host-env-security.ts + policy.json (Core Policy)

The foundational policy. Defines three key lists:

- **`blockedEverywhereKeys`** (~96 keys): `NODE_OPTIONS`, `PYTHONPATH`, `SHELL`, `CC`, `CXX`, `LD_*`, `DYLD_*`, `BASH_FUNC_*` — blocked in ALL contexts
- **`blockedOverrideOnlyKeys`** (~142 keys): `GITHUB_TOKEN`, `GH_TOKEN`, `GITLAB_TOKEN`, `AWS_*`, `DATABASE_URL`, `SSH_AUTH_SOCK`, `HOME` — blocked when used as agent request overrides
- **`allowedInheritedOverrideOnlyKeys`** (~40 keys): `HOME`, `SSH_AUTH_SOCK`, `DOCKER_HOST`, `KUBECONFIG`, `HTTP_PROXY`, `HTTPS_PROXY`, `XDG_*` — allowed to inherit from host despite being in blockedOverrideOnlyKeys

Key functions:
- `isDangerousHostEnvVarName(key)` — checks blockedEverywhereKeys + blockedPrefixes
- `isDangerousHostInheritedEnvVarName(key)` — checks blockedEverywhereKeys + blockedInheritedKeys (blockedOverrideOnlyKeys minus allowedInheritedOverrideOnlyKeys)
- `isDangerousHostEnvOverrideVarName(key)` — checks blockedOverrideOnlyKeys

**GITHUB_TOKEN** is in `blockedOverrideOnlyKeys` but NOT in `allowedInheritedOverrideOnlyKeys` — blocked from both inheritance and override.

### 2. sandbox/sanitize-env-vars.ts (Sandbox-Level Filter)

Two functions with very different strictness:

- **`sanitizeEnvVars()`** — Strict. Blocks by name pattern: `/^(GH|GITHUB)_TOKEN$/i`, `/_?(API_KEY|TOKEN|PASSWORD|PRIVATE_KEY|SECRET)$/i`, and specific provider keys. Accepts `customAllowedPatterns` option but **no callers ever pass it**.
- **`sanitizeExplicitSandboxEnvVars()`** — Permissive. Only validates values (null bytes, length, base64-like). No name-based blocking. Used for explicitly configured `sandbox.docker.env`.

### 3. skills/runtime/env-overrides.ts (Skill Env Override Layer)

`sanitizeSkillEnvOverrides()` builds `allowedSensitiveKeys` from skill metadata (`primaryEnv` + `requires.env`), then rescues blocked keys matching that set. User-configured `skills.entries.*.env` keys are NOT in `allowedSensitiveKeys` — they get blocked by the broad suffix patterns.

### 4. mcp-config-shared.ts (MCP-Specific Carve-Out)

`MCP_EXPLICIT_CREDENTIAL_ENV_KEYS` includes `GITHUB_TOKEN`, `GH_TOKEN`, `GITLAB_TOKEN`, etc. `isDangerousMcpStdioEnvVarName()` allows these through for MCP server env blocks. This is the only working mechanism that lets credential-named vars through today.

### 5. dotenv.ts (Workspace .env Filter)

`BLOCKED_PROVIDER_AUTH_WORKSPACE_DOTENV_KEYS` blocks `GITHUB_TOKEN` and `GH_TOKEN` from workspace `.env` files.

## Env Var Flow: Config to Docker Container

```
Config (openclaw.json)
  agents.defaults.sandbox.docker.env
       |
       v
buildSandboxCreateArgs() [docker.ts]
  sanitizeExplicitSandboxEnvVars() — only value validation, no name blocking
       |
       v
docker create --env KEY=VALUE (container creation)
       |
       v
buildSandboxEnv() [bash-tools.shared.ts]
  PATH + HOME → sandbox.docker.env → exec.env (per-call)
       |
       v
buildDockerExecArgs() → docker exec -e KEY=VALUE
```

## Host Gateway Exec Flow

```
process.env (gateway process)
       |
       v
sanitizeHostExecEnvWithDiagnostics() [host-env-security.ts]
  inherited: isDangerousHostInheritedEnvVarName() → block/allow
  overrides: isDangerousHostEnvVarName() + isDangerousHostEnvOverrideVarName()
  PATH overrides always blocked
       |
       v
filterPluginExecEnv() — blocks PATH, OPENCLAW CLI env, dangerous names
       |
       v
Child process
```

## Current Mechanisms

### Working Today

| Mechanism | Scope | How |
|-----------|-------|-----|
| `sandbox.docker.env` | Docker sandbox | Set in `openclaw.json` under `agents.defaults.sandbox.docker.env`. Goes through `sanitizeExplicitSandboxEnvVars()` which does NOT block by name. |
| MCP server env blocks | MCP servers | Set in `mcp.servers[].env`. Uses `MCP_EXPLICIT_CREDENTIAL_ENV_KEYS` carve-out. |
| Per-call `exec.env` | Sandbox exec only | Pass `env` parameter in exec tool call. Sandbox path has zero filtering. |
| `skills.entries.*.env` | Host-side skill exec | Set in `openclaw.json`. Only reaches host exec, not sandbox. |

### Proposed / Not Merged

| Issue/PR | Mechanism | Status |
|----------|-----------|--------|
| **PR #80453** | `OPENCLAW_SERVICE_MANAGED_ENV_KEYS` — trusted exec allowlist from `~/.openclaw/.env` | **OPEN** |
| **Issue #80329** | Per-call sandbox env injection via `x-openclaw-sandbox-env-*` HTTP headers | **OPEN** |
| **Issue #87668** | `BashSpawnHook` in plugin SDK for session-scoped env contribution | **OPEN** |
| **Issue #76493** | SecretRef objects in `mcp.servers[].env` | **OPEN** |
| **Issue #10659** | Masked secrets with `{{secret:VAR}}` syntax | **OPEN (P1)** |
| **Issue #8719** | Security Profile v1.1 (data-centric, secure-by-default) | **OPEN (P1)** |

### Not Possible Today

- No global toggle to allow all env vars through to exec
- No per-agent env scoping (issue #80698 closed as stale)
- No config-level `customAllowedPatterns` (TypeScript interface exists but no callers pass it)
- No way to override `blockedEverywhereKeys` (hardcoded)
- No way to allow `OPENCLAW_*` keys through trusted exec allowlist (explicitly excluded)

## PR #80453: The Toggle Mechanism

This PR introduces exactly the operator control needed. Key changes:

### New File: `src/agents/bash-tools.exec-trusted-env.ts`

```typescript
export function resolveTrustedExecAllowlist(params: {
  host: ExecHost;
  security: ExecSecurity;
  ask: ExecAsk;
  env?: Record<string, string | undefined>;
}): Set<string> | undefined {
  // Only active in trusted posture: host=gateway, security=full, ask=off
  if (params.host !== "gateway" || params.security !== "full" || params.ask !== "off") {
    return undefined;
  }
  return readOperatorInheritedEnvAllowlist(params.env ?? process.env);
}
```

### Modified: `src/infra/host-env-security.ts`

Adds `allowInheritedKeys` parameter to `sanitizeHostExecEnv()`:

```typescript
export function sanitizeHostExecEnvWithDiagnostics(params?: {
  baseEnv?: Record<string, string | undefined>;
  overrides?: Record<string, string> | null;
  blockPathOverrides?: boolean;
  allowInheritedKeys?: Iterable<string>;  // NEW — bypasses inherited-block list
}): HostExecEnvSanitizationResult
```

### Modified: `src/config/state-dir-dotenv.ts`

Changes `isBlockedServiceEnvVar()` to only block everywhere-dangerous keys:

```typescript
// Before: blocked both everywhere-dangerous AND override-only keys
function isBlockedServiceEnvVar(key: string): boolean {
  return isDangerousHostEnvVarName(key) || isDangerousHostEnvOverrideVarName(key);
}

// After: only blocks everywhere-dangerous keys
function isBlockedServiceEnvVar(key: string): boolean {
  return isDangerousHostEnvVarName(key);
}
```

### How to Use (Once Merged)

```bash
# 1. Add token to durable service env
echo "GH_TOKEN=ghp_xxx" >> ~/.openclaw/.env
chmod 600 ~/.openclaw/.env

# 2. Reinstall gateway to regenerate OPENCLAW_SERVICE_MANAGED_ENV_KEYS
openclaw gateway install --force
openclaw gateway start

# 3. Ensure exec posture is trusted
# In openclaw.json:
# tools.exec.security: "full"
# tools.exec.ask: "off"
```

### Security Constraints

- Only works with `host=gateway, security=full, ask=off`
- `OPENCLAW_*` keys are always excluded from the allowlist
- Everywhere-dangerous keys (`LD_PRELOAD`, `NODE_OPTIONS`, etc.) are always blocked
- Non-trusted exec postures (`security=allowlist`, `ask=on-miss`, etc.) do not inherit

## Practical Workarounds (Today)

### Docker Sandbox: `sandbox.docker.env`

```json5
// openclaw.json
{
  agents: {
    defaults: {
      sandbox: {
        docker: {
          env: {
            GITHUB_TOKEN: "ghp_xxx",
            GH_TOKEN: "ghp_xxx"
          }
        }
      }
    }
  }
}
```

Works because `sandbox.docker.env` goes through `sanitizeExplicitSandboxEnvVars()` which only validates values, not names.

### MCP Servers

```json5
// openclaw.json
{
  mcp: {
    servers: {
      "my-server": {
        env: {
          GITHUB_TOKEN: "ghp_xxx"  // Allowed by MCP_EXPLICIT_CREDENTIAL_ENV_KEYS
        }
      }
    }
  }
}
```

### Host Gateway Exec: Config `env.vars`

```json5
// openclaw.json
{
  env: {
    vars: {
      GITHUB_TOKEN: "ghp_xxx"
    }
  }
}
```

Note: These are non-overriding (only applied if not already set). They affect the gateway process env, which is the base for host exec. However, `GITHUB_TOKEN` may still be stripped by `isDangerousHostInheritedEnvVarName()` depending on the exec posture.

## Related Issues

| # | Title | State | Notes |
|---|-------|-------|-------|
| 80329 | Per-call sandbox env injection from operator-trusted callers | OPEN | Proposes `x-openclaw-sandbox-env` headers |
| 31583 | exec tool does not inherit skills.entries.*.env | OPEN (P1) | Regression, skill env vars blocked by sanitizeEnvVars |
| 87668 | Expose BashSpawnHook to plugin SDK | OPEN | Would allow session-scoped env via plugins |
| 76493 | Allow SecretRef objects in mcp.servers[].env | OPEN | Forces plaintext secrets in config today |
| 78528 | Skill SecretRef API keys leak into exec | OPEN | PR #82512 exists but not merged |
| 82695 | Sandbox Docker env only partially injects | CLOSED (fixed) | Fixed by PR #82763 |
| 25951 | Sandbox env sanitizer blocks skill primaryEnv | CLOSED (stale) | Still real per comments |
| 80698 | Per-agent env-var scoping | CLOSED (stale) | No implementation path accepted |
| 82154 | Subagents do not inherit env vars from gateway | CLOSED | Not planned |
| 11829 | Security Roadmap: Protecting API Keys from Agent Access | OPEN (P1) | Three-layer approach |
| 8719 | Security Profile v1.1 (Data-centric, secure-by-default) | OPEN (P1) | Three data security levels |

## Key Source Files

- `src/infra/host-env-security.ts` — Core policy predicates
- `src/infra/host-env-security-policy.json` — Blocked/allowed key lists
- `src/agents/sandbox/sanitize-env-vars.ts` — Sandbox env sanitizers
- `src/agents/sandbox/docker.ts` — Docker container creation
- `src/agents/bash-tools.exec.ts` — Exec tool factory/routing
- `src/agents/bash-tools.shared.ts` — `buildSandboxEnv()`, `buildDockerExecArgs()`
- `src/skills/runtime/env-overrides.ts` — Skill env override layer
- `src/mcp/mcp-config-shared.ts` — MCP credential key carve-out
- `src/config/dotenv.ts` — Workspace .env filter
- `src/agents/bash-tools.exec-trusted-env.ts` (PR #80453) — Trusted exec allowlist
- `src/daemon/service-managed-env.ts` (PR #80453) — `OPENCLAW_SERVICE_MANAGED_ENV_KEYS` parsing
