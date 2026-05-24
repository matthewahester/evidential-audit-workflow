# Project Cleanup Ledger

> **HISTORICAL — not an active runbook.** This ledger records the
> coherence-audit / transition-cleanup passes that prepared the v4
> pipeline for public release. Live commit/ignore/defer policy is in
> [`output_commit_policy.md`](output_commit_policy.md); current
> layout is in [`pipeline_layout.md`](pipeline_layout.md); current
> environment description is in [`environment.md`](environment.md).
> The entries below are kept verbatim for provenance even where their
> targets were subsequently deleted from the public tree.

Record of the coherence-audit / transition-cleanup pass for the active
RoBMA v4 selected-rigor project. Conservative by design: no code logic
changed, no deletions performed, define-only behavior preserved
(re-validated — all 20 numbered scripts source clean in 0.08 s with no
MCMC and zero writes to `output/`, `output_sim_v30/`,
`simulation/results/`).

> **Update 2026-05-18 (resampling archive pass):** the root-level
> `resampling/` folder and `docs/resampling_migration_map.md` were
> moved to `archive/resampling_v2_legacy/`. The
> `archive/resampling_v2_legacy/` tree was **subsequently removed**
> from the public repo during pre-push cleanup; history is preserved
> in commits prior to that removal. Historical entries below that
> mention the old root paths or the intermediate archive path are
> retained as the original record.

## stale_text_removed (documentation only)

| File | Change |
|---|---|
| `simulation/README_simulation_v3_1.md` (renamed from `_v3_0.md`) | Status "Next: Pass 6/7" → "Pass 6/7/6.7 complete (full36 × 25)"; pass map updated (5F/6/7/6.7 marked ✅, Pass 8 = full36 × 150 next); removed the false "65 transition/provenance/support … **not wired** … recommended for Pass 6 wiring" → now states they are **wired** in `sim_run_synthetic_composition()`; "Pass 6S scaffold" header/inventory wording de-staled to "executed". x25-diagnostic-only caveat, full36×150-next, and information-axis deferral all **preserved**. |
| `docs/pipeline_layout.md` | Repository tree: added `output_sim_v30/overview`, `simulation/results/figures/composition_v30/`, the new `docs/*.md`; `resampling/` relabeled FROZEN legacy donor; corrected the optional `manuscript/` line to the real `Rigor_Manuscript/` tree. One-scheme-per-root rule unchanged. |
| `docs/output_contract.md` | Added §6 "Simulation sub-project outputs" (output_sim_v30 + simulation/results Pass 6/7/6.7 artifacts, generated/regenerable, x25 diagnostic-only); manuscript-figure note corrected to `Rigor_Manuscript/05_figures/` + naming-mismatch pointer. |

## active_script_comments_cleaned

| File | Change | Classification |
|---|---|---|
| `simulation/scripts/55_sim_cell_diagnostics.R` | Header title `… cell diagnostics scaffold.` → `… cell diagnostics module.` (one word, comment only; the module is fully implemented and wired). | `remove_stale` |

No other active-script comment was changed. `65`/`70` were **not
modified** (explicit constraint: do not modify 65/70 unless a
compatibility bug — none found). Their headers still say "scaffold";
classified `remove_stale` but **deferred** to respect the constraint —
see risks below.

## legacy_terms_remaining_and_why (intentionally retained)

Audited every occurrence of `topic, headline, archetype, legacy, v2,
TODO, FIXME, migrate, scaffold, "not wired", deprecated, old, partial`
across all 20 active scripts. None is dead transition-era code; all are
intentional:

| Term / locus | Classification | Why retained |
|---|---|---|
| `legacy_cell_code` column (`00/10/20/30/40/45/50/55_sim_*`) | `keep_as_lineage` | Live metadata field — readable slug is canonical; the opaque `e#_h#_b#` code is kept only as a join/audit column. |
| `build_topic_visuals()`, `build_topic_summary()`, `build_cross_topic_visuals()`, `build_overview()`, `analyze_robma_fit()` | `keep_as_lineage` | Active `.Deprecated()` back-compat shims that forward to v4 entry points; removing them would break old callers without benefit. |
| `.LEGACY_SCHEMA_COLS` / pre-v4 schema rejection (`60_estimand_tables.R`, `40_batch_fit.R`) | `keep_as_lineage` | Live guard logic that *rejects* old `topic/author/effect` sidecars — must keep to refuse stale inputs. |
| `legacy_v1` design fallback, `active28/active24_revised` aliases (`10_sim_design.R`, `40_sim_run.R`) | `removed_in_hygiene_pass` | Retired together with the historical v2 CSVs. No active caller depended on them. `sim_load_design()` now loads only the full36 v3 CSV; `sim_run_design()` takes a `design_path` directly (no alias system). |
| "Pass 4A collision" / "Pass 4B rewrite" rationale (canonical driver `sim_fit_library()` in `simulation/scripts/40_sim_run.R`, `50_sim_fit_monitor.R`) | `keep_as_lineage` | Explains why per-stratum fitting exists; the collision guard actively detects stray `sim_e#_h#_b#` dirs. The historical tier-specific name `run_v30_full36_x25_fit.R` was retained briefly as a deprecation shim, then a `run_v30_full36_fit.R` thin shell wrapper, both subsequently retired — `sim_fit_library()` is now the only entry point. |
| `migration`/`legacy` lineage comments (`45_study_geometry.R`) | `keep_as_lineage` | Names the documented Pass-6.5 successor relationship to the archived `archive/resampling_v2_legacy/resampling/scripts/40_study_geometry.R`. |
| `v1→v2` schema-promotion comments (`10_sim_design.R`) | `keep_as_lineage` | Documents non-obvious backward-compat promotion logic. |
| `"partial"` (`30_zplot.R`, `55_sim_cell_diagnostics.R`) | `keep_as_lineage` | Live run-state enum / `_partial` vs `_final` suffix — not stale. |
| RoBMA-3.6 / `archive/RoBMA_3_6/` references in `docs/output_contract.md` | `keep_as_lineage` | Documents the retired contract for readers; not active logic. |

No `TODO`/`FIXME`/`"not wired"`/`archetype` token exists in any active
script. (The only `TODO` is in `Rigor_Manuscript/BUILD_NOTES.md` —
manuscript scope, untouched.)

## untracked_or_scratch_files

- `output/_scratch/defineonly_probe.R` — throwaway validation probe
  created this pass. **Safe to delete manually**; not deleted (scratch
  is `.gitignore`d and never beside trusted outputs). The earlier
  `output/_scratch/pass6_validate.R` and `pass6_run.R` named in the task
  are **no longer present** (already removed); `viz75_probe.R` likewise
  gone. Only `defineonly_probe.R` remains.
- Large untracked trees (expected, not cleanup targets): `data/sim_*/`
  (900-dataset synthetic library), `output_sim_v30/`,
  `simulation/{latent,manifests,results}/`, `Rigor_Manuscript/`,
  `archive/`, `.claude/`. These are generated/working artifacts, not
  clutter.

## deletion_candidates (NOT deleted this pass)

| Candidate | Recommendation |
|---|---|
| `output/_scratch/defineonly_probe.R` | Delete manually anytime (probe only). |
| Stale-named manuscript figures under `Rigor_Manuscript/05_figures/global/` (`boxplot_strip_single.pdf`, `violin_stack_fullpage.pdf`, `orchard_*.pdf`, `scatter_effect_vs_bias.pdf`, `boxplot_combined_horizontal.pdf`) | Do **not** delete — the manuscript pins them. Replace only during a deliberate manuscript-figure re-export (see `manuscript_bridge.md`). |

No empirical/synthetic data, sidecar, overview, or result file is a
deletion candidate.

## archive_candidates

- `resampling/` + `docs/resampling_migration_map.md` — **ARCHIVED
  2026-05-18** (this pass) to `archive/resampling_v2_legacy/`
  (`README_ARCHIVE.md` + `resampling/` + `resampling_migration_map.md`).
  Both moved (not deleted; both were untracked so a plain filesystem
  move, no history loss). The migration map is now described purely as
  archived provenance, no longer a current operational document. Root
  no longer carries `resampling/` or `docs/resampling_migration_map.md`.
  All active doc/script references updated to the archive path or
  removed.
- `archive/RoBMA_3_6/` — still on disk and ignored via `.gitignore`;
  never committed.
- `archive/renv_inactive_2026-05-17/` — was archived during this pass,
  then **subsequently removed** from the public tree in commit
  `3d47a06` (`archive: remove inactive renv lockfile`). The git history
  retains the original lockfile through the intermediate commit.

## deferred_extensions

- **full36 × 150** operating-characteristic tier (Pass 8) — next compute
  target; not started this pass. Runbook §K.
- Composition-visual families with retired inputs (logged in
  `simulation/results/figures/composition_v30/composition_visuals_deferred.csv`):
  `stability_curves_vs_n_outcomes`, `threshold_probability_curves_vs_n_outcomes`,
  `basis_comparison_curves` (need an n_outcomes sweep / 3-folder basis
  suite that v4 does not produce); per-source / capped-BF facets
  (degenerate in v4 — single synthetic source, Inf preserved).
- Information axis / information-ladder library / Fisher-information
  diagnostic — deferred and out of scope by project decision.
- Pass 7 *agreement* plain-language report (composition has one;
  agreement does not yet) — minor future item.

## risks_or_open_questions

1. **Manuscript figure-path staleness** (highest-value finding). The
   manuscript `\includegraphics` uses pre-v4 figure names; the active
   `70_corpus_visuals.R` emits `corpus_`-prefixed names. The committed
   `05_figures/` PDFs are a pinned old-naming snapshot, so the manuscript
   still compiles, but a v4 rebuild will not refresh them. Resolve in a
   dedicated manuscript-revision pass (out of scope here).
2. **Manuscript `topic` label namespace** (`\ref{supp:topic-*}`,
   `BUILD_NOTES.md` "Flagship Topic Selection"). Prose is v4-aligned;
   labels are cosmetic legacy. Non-blocking; flag for the revision pass.
3. **`65`/`70` headers** still read "scaffold" though Pass 6/7 executed.
   Left unchanged to honor the do-not-modify-65/70 constraint; the
   simulation README now states the correct executed/wired status, so
   the stale word is contained to the script header comment only.
4. **Simulation manuscript section is a placeholder** — intentional and
   consistent with x25 being diagnostic-only; becomes actionable after
   full36 × 150.

## Coherence verdict

The active project is internally coherent: define-only contract holds
codebase-wide, vocabulary is v4 throughout active logic, the
code→outputs→manuscript map is now documented (`script_index.md`,
`runbook.md`, `manuscript_bridge.md`,
`diagnostic_interpretation_guide.md`), and the only material
inconsistency (manuscript figure naming) is documented, not silently
"fixed". Safe to proceed to full36 × 150, a deeper diagnostic
walkthrough, and a scoped manuscript-revision pass.
