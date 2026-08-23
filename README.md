# commonplace-log-reducer

Generic projection engine over [commonplace-log](https://github.com/commonplace-systems/commonplace-log),
plus the `commonplace-attribute-map` reducer plugin **in this same repo** (jes, 2026-08-23).

Dependency direction: `commonplace-log` → `commonplace-log-reducer` → reducer plugins.
This library consumes validated entries from commonplace-log; it does not own log
persistence, BEAM process lifecycle, Document messaging, Cell authority, capabilities,
Realm placement, or replica synchronization.

## Status

**New repo, 2026-08-23. Nothing implemented yet.**

The direction document is filed byte-identical at
[`docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md`](docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md)
(sha256 `248cf8f44eff61ea37ff0e05e660ddc2b95d86d363f24d249bcad5dfbe24a038`).
It is the source of truth for scope; this README summarizes and does not extend it.

## Writing a plugin in another repo

See **[`docs/PLUGIN_AUTHORS.md`](docs/PLUGIN_AUTHORS.md)** — the seven callbacks, the
context, registration, the plugin-error mapping, and a conformance checklist. It is
written to be sufficient on its own: if you have to read `lib/` to build a plugin, that
is a defect in the document, and we want to hear about it.

That is not politeness. Every plugin in this repo shares an author with the engine,
which is the arrangement that hides accidental coupling rather than exposing it — so
acceptance criterion §42.10 ("a second plugin can implement the same behaviour without
changing the core API") is recorded as **not demonstrated**. An independently written
plugin is the only thing that can change that.

## What is planned

Per the spec: projection engine, epoch protocol, reducer behavior + registry,
deterministic replay, checkpoint format — and the attribute-map plugin (put / delete /
patch over a JSON attribute map, last-write-in-log-order wins) shipped alongside it.

A task plan should be written against the spec's own required-tests list before code.
