# commonplace-log-reducer

Generic projection engine over [commonplace-log](https://github.com/commonplace-systems/commonplace-log),
plus the `commonplace-attribute-map` reducer plugin **in this same repo** (jes, 2026-08-23).

Dependency direction: `commonplace-log` → `commonplace-log-reducer` → reducer plugins.
This library consumes validated entries from commonplace-log; it does not own log
persistence, BEAM process lifecycle, Document messaging, Cell authority, capabilities,
Realm placement, or replica synchronization.

## Where the code is

⚠️ **`main` is documentation only. The implementation lives on branch `sol/impl`**
(worktree `.worktrees/impl`) and is merged back when the plan completes. Checking `main`
alone gives the false impression that nothing is built.

As of 2026-08-23 that branch has the engine through the §16 processing algorithm —
error codes, envelope validation, registry, plugin behaviour, chain validation, and
epoch/operation routing — at 133 passing tests.

## Status

**New repo, 2026-08-23. Nothing implemented yet.**

The direction document is filed byte-identical at
[`docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md`](docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md)
(sha256 `248cf8f44eff61ea37ff0e05e660ddc2b95d86d363f24d249bcad5dfbe24a038`).
It is the source of truth for scope; this README summarizes and does not extend it.

## What is planned

Per the spec: projection engine, epoch protocol, reducer behavior + registry,
deterministic replay, checkpoint format — and the attribute-map plugin (put / delete /
patch over a JSON attribute map, last-write-in-log-order wins) shipped alongside it.

A task plan should be written against the spec's own required-tests list before code.
