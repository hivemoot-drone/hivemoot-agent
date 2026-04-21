# ADR-003: Plugin Config v2 — Typed Configuration via Pydantic + hivemoot.yaml

**Status:** Accepted
**Date:** 2026-04-20
**Implemented:** PR [#595](https://github.com/hivemoot/hivemoot-agent/pull/595) (foundation + messaging/cron/github),
PR [#597](https://github.com/hivemoot/hivemoot-agent/pull/597) (browser),
PR [#598](https://github.com/hivemoot/hivemoot-agent/pull/598) (hivemoot-github + hivemoot-task)

## Context

Before ADR-003, every plugin read its configuration directly from environment variables at
runtime:

```python
# pre-ADR-003: env vars read ad-hoc, no central validation
repos = config.get("GITHUB_REPOS", "").split(",")
poll_interval = int(os.environ.get("GITHUB_WATCH_POLL_INTERVAL", "300"))
schedules = json.loads(os.environ.get("CRON_SCHEDULES_JSON", "[]"))
```

This produced four concrete failure modes:

1. **Late failures.** Misconfigured values (wrong type, impossible cron expression, missing
   required field) are discovered only when the relevant code path executes — often during a
   scheduled run, not at startup.

2. **Silent misconfiguration.** A typo in an env var name (`MESSAGING_ALLOWED_CHAT_ID` instead
   of `MESSAGING_ALLOWED_CHAT_IDS`) produces a silent empty value, not an error message that
   points at the typo.

3. **No schema.** Operators have no machine-readable contract for what values a plugin accepts.
   The only documentation is README prose, which drifts from the code.

4. **Scattered config surface.** Operators set env vars per-plugin, per-instance, with no
   single file representing the full agent configuration. Operators reviewing their setup have
   to diff env vars across shell files and `.env` fragments.

## Decision

**Plugins declare typed Pydantic schemas. The engine reads `hivemoot.yaml` at startup,
validates each plugin's config section against its schema, and hands each plugin a
fully-validated `config.typed` instance at `setup()` time.**

### Config file layout

```
/run/agent/
  hivemoot.yaml           # plugin activation + config values
  hivemoot.secrets.yaml   # secret values referenced by !secret tags
```

`hivemoot.yaml` structure:

```yaml
plugins:
  github:
    repos:
      - owner/repo
    token_file: /run/secrets/github_token
    watch_mentions: true
    watch_poll_interval_secs: 300

  cron:
    schedules:
      - name: autonomous
        schedule: "@every 1h"
        jitter_secs: 300
        prompt: "Make meaningful contributions to the repository."
```

### Plugin manifest

Each plugin ships a `plugin.yaml` alongside its `__init__.py`:

```yaml
name: github
version: 0.2.0
description: >
  GitHub repository management and event triggers.
schema_class: hivemoot_agent.plugins_builtin.github.config:GitHubConfig
```

`schema_class` points at a Pydantic model that inherits from `StrictPluginConfig` (which sets
`model_config = ConfigDict(extra="forbid")` so unknown keys are rejected rather than silently
ignored).

### Resolution order

Config loading happens in five steps inside `ConfigLoader.load()`:

1. Parse `hivemoot.yaml` with a custom YAML loader. `!secret <name>` tags produce
   `SecretRef` placeholder objects (not strings).
2. Parse `hivemoot.secrets.yaml` into a plain dict (or skip if absent).
3. Walk the parsed tree and resolve `${env:VAR}` occurrences. This runs **before**
   secret resolution so secret values (high-entropy tokens, URL-encoded strings) that
   happen to contain `${...}` are never subject to string rewriting.
4. Walk again and swap `SecretRef` nodes for their values from the secrets dict. Unresolved
   refs raise `UnresolvedRefError` with a JSON-path-like breadcrumb (`plugins.github.token_file:
   !secret 'github_token' not found`) so the operator can find the offending line immediately.
5. Return a `LoadedConfig` with per-plugin raw dicts. Pydantic validation happens later,
   per-plugin, in the registry — keeping the loader plugin-agnostic.

### Type safety and strict validation

`StrictPluginConfig` is the base class for all plugin config schemas:

```python
class StrictPluginConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
```

`extra="forbid"` catches typos at startup. Example: `alloweed_chat_ids` in
`hivemoot.yaml` raises a validation error naming the field rather than silently producing an
empty allowlist.

Pydantic validators add semantic checks beyond type checking:

- **Cron:** schedule expressions are parsed and probed for reachability at load time.
  An expression like `0 9 31 2 *` (Feb 31 at 09:00) is impossible and fails with an
  actionable error instead of silently never firing.
- **Cron:** schedule names must be unique within the list; duplicates are rejected by a
  cross-field validator.
- **Cron:** schedule names must match `[A-Za-z0-9_-]+` to prevent injection through
  session keys.

### One instance per plugin type (for now)

Under ADR-003 the YAML key is the plugin type; one instance per type is permitted.
The YAML structure `github/prod:` (multi-instance notation) is explicitly rejected at load
time rather than silently producing unexpected behavior. Multi-instance support is a planned
follow-up — the engine would need to instantiate a fresh plugin object per instance, which
requires restructuring how plugin state (repo caches, sockets, etc.) is owned.

### Dual consumption path for incremental migration

`PluginConfig` carries both:

- `config.typed` — the Pydantic-validated instance (for migrated plugins)
- `config.settings` — `os.environ` merged with raw config values (legacy access via `config.get()`)

Plugins that haven't migrated yet continue reading from `config.settings`. This enables
incremental migration without a big-bang rewrite.

## Consequences

### Better operator experience

- Typos in config keys are caught at startup with actionable error messages.
- Impossible values (bad types, invalid cron expressions, duplicate names) fail fast with
  the offending config path.
- `hivemoot.yaml` is a single file representing the agent's full plugin configuration.

### Plugin author contract

Every plugin that wants typed config must:

1. Add a `plugin.yaml` manifest with a `schema_class` pointer.
2. Implement a `StrictPluginConfig` subclass with Pydantic fields.
3. Read `config.typed` in `setup()` and downstream hooks instead of `config.get()`.

Plugins with no config (pure trigger plugins) may set `schema_class: null` in their manifest.

### Known limitations

- **One instance per plugin type.** Running two independent GitHub plugins (e.g., two
  different org tokens) requires two separate containers with separate configs.
- **AGENT_PLUGINS env var is deprecated.** The YAML `plugins:` section is the activation
  source of truth. `AGENT_PLUGINS` is logged as a deprecation warning and ignored.
- **No hot reload.** Config is read once at startup. A config change requires a container
  restart.
