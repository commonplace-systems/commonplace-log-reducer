# Spec gaps found by the second plugin author

> **Gap 1: RESOLVED 2026-08-23.** jes ruled "gap 1 should get fixed, reducer gets to
> decide how". Fixed **in the specification itself** as §12.2, not in a companion
> document — a normative rule living outside the normative document is what created the
> gap. The spec's hash changed deliberately; see its new §0 amendment record, which
> carries the old hash, the authorisation, and the reason.
>
> **Gap 2: RULED, not amended.** jes confirmed "'many authors per projection are
> expected' is true". That is a design fact; the spec text is unchanged and the
> amendment below remains open for its owner.

**Status:** Proposed amendments to the 2026-08-22 spec. **Not applied** — the
specification at `docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md`
is filed byte-identical to jes's original (sha256
`72828c72686f2ba9093bd9f2039e6630ef237a004c5f021e610a6b764f47594f`) and is not edited
here. These are for its owner to accept, reject, or reword.

**Provenance:** both were found by `commonplace-merkle-crdt` while building the second
reducer plugin against `docs/PLUGIN_AUTHORS.md` and the spec, without reading this
library's source. That is §42.10 working as intended: an outside implementer is the only
one who can distinguish a real boundary from one that merely looks like a boundary from
the inside.

---

## Gap 1 — the plugin-error → §21 code mapping is not derivable from the spec

**Where:** §12 defines the plugin callbacks; §21 defines the error codes. Nothing joins
them.

**The problem.** A plugin returns `{:error, reason}` from `init/2`, `apply/3`,
`restore/2`, or `checkpoint/1`. §21 declares `invalid_epoch_base`, `invalid_operation`,
and `invalid_checkpoint`, and describes them in terms an implementer can *infer* a
mapping from — but the spec never states it. `missing_resource` is worse: §13 requires a
reducer to "return an explicit missing-resource error rather than fetch a resource
itself" without giving that error a shape, so the engine cannot recognize one and no two
implementations would agree on it.

**Why it matters for §42.10.** §42.10 requires a second plugin to work "without changing
the core reducer API". It is silent on whether that API is *learnable from the normative
source*. Right now it is not, quite: a plugin author with only the spec must guess.
`commonplace-merkle-crdt` got the mapping from this library's `PLUGIN_AUTHORS.md`, and
observed — correctly — that it would rather the gap be fixed than quietly benefit from a
document a future plugin author might not be pointed at.

**Proposed amendment**, as a new subsection under §12:

> ### 12.2 Plugin error classification
>
> The engine classifies a plugin's `{:error, reason}` by the callback that produced it:
>
> | Callback | Error code |
> | --- | --- |
> | `init/2` | `invalid_epoch_base` |
> | `apply/3` | `invalid_operation` |
> | `restore/2` | `invalid_checkpoint` |
> | `checkpoint/1` | `invalid_checkpoint` |
>
> A reason of the form `{:missing_resource, key}` MUST be classified as
> `missing_resource` regardless of the callback that produced it.
>
> `{:missing_resource, key}` is the only reason shape the engine interprets. Every other
> reason is opaque: it MUST be carried into the error's structured details unexamined,
> and the engine MUST NOT branch on it. An error returned by `view/1` is not an error
> code under §21; it surfaces to the caller, because producing a view neither reduces an
> entry nor advances the head.

---

## Gap 2 — the number of distinct authors inside one projection is unconstrained

**Where:** §5.1, §6, §17 and §30 all constrain the **log's writer**. Nothing constrains
how many distinct *authoring identities* may appear inside the operations of one
projection.

**The problem.** These are different populations, and conflating them changes a plugin's
design. Version 1 pins one `writer_id` per log for its lifetime — that is a property of
who *appends*. It does not follow that the content appended was authored by one party. A
cell may funnel updates from several concurrent editors into its own single-writer log,
in which case the log has serialized **arrival**, not **authorship**, and genuine
upstream concurrency is present inside operations the engine sees as strictly ordered.

**Why it matters.** For an attribute map this is invisible — §30's last-write-wins is
over log order and the question never arises. For a CRDT plugin it is the whole design:

- if many authors per projection are expected, the plugin's merge is load-bearing and
  exercised on every multi-editor session;
- if exactly one, the same plugin is an expensive way to store a byte blob.

The spec gives an implementer no way to tell which, and this library's engine cannot
answer it either — it does not interpret operation contents by design.

**Also a correction to something this library told that author.** We initially said the
concurrency a CRDT resolves "does not occur here" because the profile is single-writer.
That was wrong, or at least unfounded: it reasoned from the log's writer to the
document's authors. The engine's ordering guarantees say nothing about how many parties
authored the operations it orders.

**Proposed amendment:** one sentence in §5.1 or §17 stating explicitly whether the
Cell-Owned Document Profile constrains authoring identity inside operations, or
deliberately leaves it to the plugin. Either answer is fine. The gap is that neither is
stated, and a plugin author's design turns on it.
