# hkrc bug investigation

> [!NOTE]
> This is a blameless bug report. PRs are cited to trace how the code evolved, not to assign fault. Bugs like these are a natural consequence of incremental development across many changes.

## Steps to reproduce

```bash
git clone https://github.com/ivy/tmp-2026-02-28-hkrc-bug && cd tmp-2026-02-28-hkrc-bug
./reproduce.sh
```

The script sets up a minimal project with a `hk.pkl` (trailing-whitespace step) and a `global-hkrc.pkl` that amends `Config.pkl` with a gitleaks step. It runs pre-commit twice:

1. **Without hkrc** — works fine
2. **With `--hkrc global-hkrc.pkl`** — panics: `invalid type: string "gitleaks git ...", expected a boolean`

Requires [hk](https://github.com/jdx/hk) and git. Run `mise install` to install hk via the included `mise.toml`.

## Summary

The hkrc feature has two bugs:

1. **Deserialization panic**: hkrc files that amend `Config.pkl` (as shown in the docs) panic because hk deserializes them as `UserConfig`, where `check` is `Option<bool>`, not a string command.
2. **Default path is CWD-relative**: The default hkrc path is `PathBuf::from(".hkrc.pkl")` (relative to CWD), not `~/.hkrc.pkl` as the docs state.

Additionally, the `UserConfig`, `UserDefaults`, `UserHookConfig`, and `UserStepConfig` types are dead code — they are never used in the current execution path.

## Timeline

### [PR #117](https://github.com/jdx/hk/pull/117) — original implementation

`feat: Add support for .hkrc.pkl user configuration file`

Introduced `UserConfig` as a deliberately separate, simpler type for overlaying settings on existing project steps. The implementation supported:

- Global environment variables (`environment`)
- Global defaults (`defaults.jobs`, `defaults.fail_fast`, `defaults.profiles`, `defaults.all`, `defaults.fix`, `defaults.check`) — these called `Settings::set_jobs()`, `Settings::set_fail_fast()`, etc.
- Per-hook environment variables and per-step overrides (glob, exclude, profiles)

The docs in this PR showed hkrc amending `Config.pkl` with full hooks containing steps with `check`/`fix` string commands, while the implementation used a separate `UserConfig` type where those fields are `Option<bool>`. This gap between the documented format and the deserialization target went unnoticed.

### [PR #266](https://github.com/jdx/hk/pull/266) — config unification refactor

`feat: comprehensive configuration unification with proper precedence and union semantics`

Added `exclude` to `UserDefaults` and plumbed it through `apply_user_config` via `Settings::add_exclude()`. The `Settings::set_*()` methods and `defaults` handling remained intact after this PR.

### [PR #284](https://github.com/jdx/hk/pull/284) — settings codegen

`feat: centralized settings registry with codegen`

Overhauled `settings.rs` from a mutex/static-variable model to a codegen-based system (`settings.toml` → `build/generate_settings.rs`). As part of this migration, the `Settings::set_*()` methods were removed. The `UserDefaults` struct was left in place but became dead code — deserialized but never read. The defaults feature silently stopped working.

### [PR #442](https://github.com/jdx/hk/pull/442) — stage field

`feat: Plumb stage through CLI and PKL`

Added `stage` to `UserConfig`.

## Current state of `apply_user_config`

The method (`src/config.rs:155`) can only overlay settings on **existing** project steps. It:

- Copies top-level settings (`display_skip_reasons`, `hide_warnings`, `warnings`, `stage`) from user config to project config (user wins)
- Inserts user environment variables (user takes precedence over project for env)
- Iterates over existing project hooks/steps and applies per-hook env vars, per-step env/glob/exclude/profiles from the user config

It **cannot**:
- Add new hooks that the project doesn't define
- Add new steps to existing hooks
- Set global defaults (jobs, fail_fast, etc.) — the `UserDefaults` struct is deserialized but never read

## Failing tests

Five new tests added in `test/hkrc.bats` (commit [`3d7393a`](https://github.com/ivy/hk/commit/3d7393a)):

| Test | Failure |
|------|---------|
| Config-format hkrc with steps runs without panic | Panic: `string "echo 'eslint check'", expected a boolean` |
| Config-format hkrc adds hook the project doesn't have | Same panic |
| Project step overrides same-named hkrc step | Same panic |
| Merges different steps from same hook | Same panic |
| Default path loads from home directory | `~/.hkrc.pkl` never discovered; path is CWD-relative |

## Key files

- `src/cli/mod.rs:92-94` — default path: `PathBuf::from(".hkrc.pkl")`
- `src/config.rs:240-256` — `UserConfig::load()` deserializes as `UserConfig`
- `src/config.rs:155-237` — `apply_user_config()` overlay logic
- `src/config.rs:460-519` — `UserConfig`, `UserDefaults`, `UserHookConfig`, `UserStepConfig` structs (dead code)
- `pkl/UserConfig.pkl` — Pkl schema for UserConfig
- `docs/configuration.md:175-208` — hkrc docs (show `Config.pkl` format)
- `docs/configuration.md:255-267` — settings docs (show `UserConfig.pkl` format)

## Proposed fix

### One schema everywhere

Drop `UserConfig.pkl`. The hkrc uses the same `Config.pkl` schema as project config. This eliminates the deserialization panic — `UserConfig::load()` becomes a plain `run_pkl::<Config>()`.

### mise-style load order

mise resolves config by walking up the directory tree and merging files with "closer wins" semantics. hk can adopt the same principle with a simpler two-level model:

| Precedence | File | Purpose |
|------------|------|---------|
| 1 (lowest) | `~/.config/hk/config.pkl` | Global user defaults |
| 2 | `hk.pkl` | Project config |
| 3 (highest) | CLI flags, env vars, git config | Runtime overrides |

The global path follows XDG conventions (`~/.config/hk/`) instead of a dotfile in `$HOME`. The `--hkrc` flag overrides the global path for one-off use.

### Merge behavior

Following mise's pattern, different sections merge differently:

- **Settings** (jobs, fail_fast, etc.): project overrides global — same as mise's additive-with-override model
- **Environment variables**: project overrides global (`or_insert` semantics)
- **Hooks/steps**: additive with project-wins on collision — global config can add hooks/steps the project doesn't define, but the project's definition wins when both define the same hook or step

This matches the settings precedence table already in the docs (lines 213–221), where project config (6) has higher precedence than user rc (5) in a "1 is highest" ordering. It contradicts lines 204–207 ("User configuration takes precedence over project configuration"), which should be corrected.

### Cleanup

- Remove `UserConfig`, `UserDefaults`, `UserHookConfig`, `UserStepConfig` structs (dead code)
- Remove `pkl/UserConfig.pkl`
- Update `docs/configuration.md` to remove the `UserConfig.pkl` example (lines 255–267) and fix the precedence statement (lines 204–207)
