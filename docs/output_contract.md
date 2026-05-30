# Output Contract — Active RoBMA 4.0 Rigor Pipeline

This is the canonical reference for the **outputs** produced by the active
RoBMA 4.0 rigor pipeline. It enumerates every artifact the pipeline
writes, where it is written, which script writes it, and whether it is
source-controlled or regenerated.

For the input-side schema (analysis-ready CSVs and extraction workbooks) see
[`../data_dictionary.md`](../data_dictionary.md). For the estimand math and
vocabulary see [`../README.md`](../README.md). For the figure-by-figure axis
contract see [`visuals.md`](visuals.md).

This document supersedes the old `output_dictionary.md`, which described the
retired RoBMA 3.6 / topic workflow (`50_topic_analysis.R`, `60_overview.R`,
`topic_summary.csv`, `orchard_*.pdf`, `violin_*.pdf`). Those names are no
longer produced by the active pipeline.

---

## 0. One scheme/corpus per output root

The v4 contract carries `scheme` and `corpus_id` as **metadata fields** on
every sidecar row. The practical operating rule, however, is simple:

> **One scheme/corpus per output root.**

The active nutrition workflow writes everything under `output/`, physically
organised as `output/<stratum>/...`. There is no `(scheme, stratum)`
directory nesting. A different scheme/corpus (e.g. a simulation target or a
resampling corpus) must use a **separate output root**
(`output_sim_target/`, `output_resampling_empirical/`, …), not a new subtree
inside `output/`. See [`pipeline_layout.md`](pipeline_layout.md).

`<stratum>` is the lowercase slug (`norm_slug(path_stratum)`); the physical
data folder name (`path_stratum`, e.g. `Caffeine`, `VitaminD`) may be
title-cased, but every `output/` path uses the lowercase slug.

**Simulation-ready.** Audit-ready *synthetic* CSVs may live in the main
`data/` tree (`data/sim_<cell_slug>/sim<vintage>/repNNNN.csv`; the stem
`repNNNN` is the compact `outcome_slug`, **not** the `dataset_id`) so the
standard loader/fitter treats them like any dataset — the *input*
contract is shared. Their *outputs* must go to a **separate output
root** so empirical and synthetic sidecars never mix: set
`CONFIG$output_root` / `CONFIG$corpus_id` / `CONFIG$scheme` before
fitting and pass the matching `root` / `output_dir` (and `output_root`
to `sidecar_acceptance_all()`) to every downstream stage. Simulation
latent/truth/manifest files stay **out of `data/`**.

The active full36 × 25 simulation library uses:

```r
CONFIG$output_root <- "output_sim_v30"   # never the empirical output/
CONFIG$corpus_id   <- "sim_library_v30"
CONFIG$scheme      <- "simulation_cell"
```

> **Per-stratum fitting only.** Compact `repNNNN` stems are not unique
> across strata; a single `batch_fit(source_article = "sim2026")` over
> all sim strata collides every `repK` object in `load_datasets()` and
> fits the wrong data. Fit one stratum per call (loop over
> `sim_load_design()$stratum`); the canonical driver is
> `sim_fit_library()` in `simulation/scripts/40_sim_run.R`. The fitter
> derives the dataset list from `sim_inventory_library()` — whatever
> generated CSVs exist on disk — and has no `TARGET_REPS_PER_CELL`
> config.

The per-stage argument-name table and worked example are in
[`pipeline_layout.md`](pipeline_layout.md); the simulation contract and
remaining-pass map are in
[`../simulation/README.md`](../simulation/README.md).

---

## 1. Per-dataset artifacts — written by `20_robma_fit.R` / `40_batch_fit.R`

Written into `output/<stratum>/<source_article>/` (the default; with
`CONFIG$nest_by_outcome = TRUE` an extra `/<outcome_slug>` level is added).
`<dataset_id>` is the stable compact stem, e.g.
`whelton2005_fiber_systolic_bp` (`_excl` appended for exclusion-sensitivity
variants).

| File | Contents | Role |
|------|----------|------|
| `fit_RE4_<dataset_id>.rds` | Serialized unadjusted Bayesian random-effects baseline (`brma()`; effect-present, heterogeneity-present, no modeled bias; not model-averaged). | Comparator on the same input scale/path as the bias-robust fit. |
| `fit_RoBMA4_<dataset_id>.rds` | Serialized RoBMA-PSMA product-space ensemble. | Primary bias-robust fit; source of component / family / rigor evidence. |
| `zplot_RE4_<dataset_id>.rds` | Saved `as_zplot()` artifact for the baseline. | Consumed by `30_zplot.R`. |
| `zplot_RoBMA4_<dataset_id>.rds` | Saved `as_zplot()` artifact for the PSMA ensemble. | Consumed by `30_zplot.R`. |

Audit artifacts under `output/<stratum>/<source_article>/audit/`:

| File | Contents |
|------|----------|
| `models_marginal_RoBMA4_<dataset_id>.csv` | Raw package marginal component summary. |
| `models_individual_RoBMA4_<dataset_id>.csv` | Raw individual model-combination summary (the joint μ×ω / rigor-branch masses are computed from this). |
| `model_family_validation_RoBMA4_<dataset_id>.csv` | Validation: component BFs recomputed from individual-model rows vs the package marginals. |

The individual-model summary is a **first-class audit artifact**, not scratch
output: the rigor estimand is computed from joint individual-model
prior/posterior mass.

---

## 2. Per-stratum sidecars — written by `20_robma_fit.R` / `40_batch_fit.R`

Written to `output/<stratum>/`:

| File | Contents |
|------|----------|
| `output/<stratum>/<stratum>_robma_summary.csv` | The **canonical lean v4 sidecar**: one row per analyzed dataset/variant. Exact column set/order is `.SIDECAR_V4_COLS` in `scripts/00_utils.R`. Identity/corpus metadata, baseline + PSMA posteriors, marginal component evidence, joint μ×ω family evidence, rigor branch + headline fields, validation, reproducibility. Deduplicated by `dataset_id` on append. |
| `output/<stratum>/<stratum>_zplot_diagnostics.csv` | Secondary non-blocking `as_zplot` diagnostics (`ODR`, `EDR`, `Soric_FDR`, `MissingN`), keyed by `dataset_id`. Schema is `.ZPLOT_DIAG_COLS`. Kept separate so the sidecar stays a lean primitive table. |

The sidecar is a **primitive/audit table, not a reporting dump**. Derived
reporting conveniences (Δμ, attenuation, shrink, sign-flip, CI-contains-zero,
μ|ω conditionals) are **not** stored here; `60_estimand_tables.R`
regenerates them from these primitives. The schema/estimand contract is the R
object in `scripts/00_utils.R` (`.SIDECAR_V4_COLS`, `.SCHEMA_VERSION`,
`.ESTIMAND_VERSION`, `.RIGOR_DIRECTION_LEVELS`, `.ANALYSIS_VARIANT_LEVELS`),
enforced by `sidecar_acceptance()` in `40_batch_fit.R`. There is no separate
`config/*.csv` contract file.

### 2.1 Acceptance — the contract gate between fitting and reporting

Acceptance is the **contract / reproducibility gate** between the fitting
layer (`00/10/20/40`) and the reporting layer (`60` → `50/70`). It asserts
that the sidecars are *structurally trustworthy v4 outputs*. It is **not a
scientific quality judgement** about any outcome's evidence — a PASS says
nothing about whether an effect is real, only that the sidecar is a current,
internally consistent v4 artifact safe for the reporting layer to consume.

| Function | Scope |
|----------|-------|
| `sidecar_acceptance(stratum, tol = 1e-3, verbose = TRUE)` | One stratum. Returns invisibly `list(ok, registry, checks)`; prints a per-check report. 17 checks; all must pass for `ok`. |
| `sidecar_acceptance_all(output_root = NULL, require_artifacts = TRUE, require_zplots = FALSE, fail_on_warning = FALSE, verbose = TRUE)` | All discovered strata. Runs the per-stratum logic corpus-wide, adds non-blocking artifact/zplot/audit warnings, prints a compact PASS/FAIL summary. Returns invisibly `list(ok, summary, checks, problems)` (base data.frames). |

Both **refit nothing, rewrite no sidecars, rebuild no tables, repair no
schema, and write no CSV.**

**Hard-fail checks (gate `ok`):**

- missing / unreadable per-stratum sidecar (or registry-build error);
- registry ↔ sidecar anti-join not clean (missing/extra `dataset_id`);
- columns not exactly `.SIDECAR_V4_COLS` (missing required v4 columns);
- `schema_version` not uniform + current;
- `estimand_version` not uniform + current (rejects effect-only-rigor);
- `config_hash` not uniform + current;
- RoBMA major version `< .ROBMA_MAJOR_MIN`;
- duplicate `analysis_id` (the `…__(main|excl)` variant slug is embedded, so
  this catches duplicate `analysis_id` + `analysis_variant`);
- invalid `analysis_variant` (not in `.ANALYSIS_VARIANT_LEVELS`), or
  `parent_dataset_id` / `exclusion_reason` inconsistent with the variant;
- invalid / blank `rigor_direction` (must be in `.RIGOR_DIRECTION_LEVELS`;
  never `"null"`);
- failed component/partition validation flags
  (`component_validation_ok`);
- unresolved model-family labels (would invalidate rigor extraction);
- broken rigor identities (`rigor_effect == muplus_omega0`,
  `rigor_no_effect == mu0_omega0`, `rigor == pmax(branches)`, direction,
  margin, `rigor_category`);
- `require_artifacts = TRUE` and a row lacks its `fit_RE4_` / `fit_RoBMA4_`
  `.rds` artifacts;
- `require_zplots = TRUE` and a stratum's zplot-diagnostics CSV is absent.

**Warning checks (non-blocking unless `fail_on_warning = TRUE`):**

- missing `.rds` fit artifacts when `require_artifacts = FALSE` (the public
  repo legitimately omits regenerable fits);
- missing zplot-diagnostics CSV when `require_zplots = FALSE`;
- `family_evidence_uncertain` rows (still reportable; flagged for audit);
- other non-fatal audit concerns surfaced in `$problems`.

For a lightweight / public / simulation output root where the regenerable
`.rds` fits are intentionally omitted, gate it with
`sidecar_acceptance_all(output_root = "output_sim_v30", require_artifacts = FALSE)`
so the missing-artifact check is a warning, not a hard fail. The wrapper
operates on whatever strata the chosen root contains — it assumes no
nutrition labels and no fixed stratum count, so it scales to many `sim_*`
strata under a simulation root unchanged.

`60_estimand_tables.R` is strictly **downstream** of this gate. It checks v4
column presence (so it cannot silently consume a pre-v4 sidecar) but it does
**not** re-run the full contract and **never repairs or remaps** a sidecar.
Run acceptance (all PASS) before `build_estimand_tables()`; a stale/old-schema
sidecar makes `60` stop loudly with a pointer to the acceptance gate.

---

## 3. Reporting outputs — written by `60_estimand_tables.R`

`build_estimand_tables()` consumes the per-stratum sidecars (+ optional zplot
diagnostics), regenerates the derived reporting columns, and writes to
`output/overview/` by default:

| File | Contents |
|------|----------|
| `outcome_registry.csv` | Complete audit / data-mart file: one row per analyzed outcome/variant, derived reporting columns regenerated from sidecar primitives. The authoritative table consumed by `50`/`70`. |
| `outcome_registry_compact.csv` | Human-facing browsing view (column subset, sorted by descending selected `log10BF_rigor`). |
| `outcome_registry_table.tex` | Supplement longtable companion. |
| `stratum_estimands.csv` / `stratum_estimands_table.tex` | Per stratum + an `Overall` row; outcome-weighted. |
| `article_balanced_estimands.csv` / `article_balanced_estimands_table.tex` | Per stratum + `Overall`; each source article weighted `1/m` within its stratum so prolific meta-analyses do not dominate. |
| `corpus_estimands.csv` / `corpus_estimands_table.tex` | Numerator/denominator headline claims, outcome-weighted and article-balanced. |
| `rigor_category_summary.csv` | Rigor category counts/proportions by stratum and overall. |
| `rigor_direction_summary.csv` / `rigor_direction_summary_table.tex` | `effect` vs `no_effect` direction composition by stratum and overall. |
| `component_evidence_summary.csv` | Secondary effect/het/bias/no-bias roll-up, long format (one row per stratum × component). |

Rigor is the headline estimand; the selected `log10BF_rigor` is never
reported without its `rigor_direction`. Genuine `±Inf` Bayes factors are
preserved end to end (only `NA`/`NaN` are missing).

---

## 4. Visual outputs

All visual scripts are **strictly downstream of `60`**: they consume
`output/overview/outcome_registry.csv` (50/70) or the saved zplot artifacts
(30) and write **figures only**. They never rediscover sidecars or rebuild
tabular schemas; a missing/non-v4 registry is a hard error.

### 4.1 `30_zplot.R` — per-dataset z-plots

Written under `output/<stratum>/<source_article>/plots/`:

- `<dataset_id>_z_plot.pdf` — z-distribution.
- `<dataset_id>_z_extrapolation.pdf` — z-extrapolation.

`build_zplots()` returns an invisible per-row status log; missing artifacts
never abort the run.

### 4.2 `50_stratum_visuals.R` — stratum/source inspection figures

Written under `output/<stratum>/plots/` (or
`output/<stratum>/<source_article>/plots/` for a source-scoped run).
`<scope>` is the stratum slug or `<stratum>_<source_article>`:

- `<scope>_effect_estimate_comparison.pdf` — paired baseline-RE vs RoBMA-PSMA.
- `<scope>_effect_forest.pdf` — forest plot (RE vs PSMA).
- `<scope>_component_violin_stack.pdf` — 3-panel effect/het/bias distributions, **raw `log₁₀(BF)` display-capped ±2**.
- `<scope>_rigor_ranking.pdf` — outcome-level rigor ranking, **raw `log₁₀(BF_rigor)` display-capped ±2** (when `include_rigor = TRUE`).

Orchards are **retired** — `<scope>_component_orchard.pdf` is no longer
produced by `build_stratum_visuals()`. The evidence-axis transform is
**not part of the active visual pipeline**; a frozen copy is kept under
`archive/` for provenance only.

### 4.3 `70_corpus_visuals.R` — corpus / cross-stratum figures

Written to `output/overview/`:

| File | Axis | Default |
|------|------|---------|
| `corpus_effect_attenuation_boxplot_horizontal.pdf` / `corpus_effect_attenuation_strip.pdf` | effect-size scale | yes |
| `corpus_component_violin_effect.pdf` / `_heterogeneity.pdf` / `_bias.pdf` | **raw `log₁₀(BF)` (display-capped ±2)** | yes |
| `corpus_component_violin_stack.pdf` | **raw `log₁₀(BF)` (display-capped ±2)** | yes |
| `corpus_rigor_violin_by_stratum.pdf` | **raw `log₁₀(BF_rigor)` (display-capped ±2)** | yes |
| `corpus_rigor_branch_scatter.pdf` | raw `log₁₀` | yes |
| `corpus_rigor_direction_composition.pdf` | composition (muted palette) | yes |
| `corpus_rigor_category_composition.pdf` | composition (muted palette) | yes |
| `corpus_rigor_weighting_comparison.pdf` | raw `log₁₀` | yes |
| `corpus_rigor_ranking_extremes.pdf` | **raw `log₁₀(BF_rigor)` (display-capped ±2)** | yes |
| `corpus_attenuation_vs_rigor.pdf` | raw `log₁₀` | yes |
| `corpus_bias_vs_rigor.pdf` | raw `log₁₀` | **off** (`include_bias_vs_rigor = TRUE`; QC/supplement) |
| `corpus_orchard_*.pdf` (evidence-axis transform) | evidence-axis transform | **retired** — not part of the active visual pipeline (archived only) |

**Axis-scale contract** (authoritative detail in
[`visuals.md`](visuals.md)). Corpus-level component-BF **violins** and the
rigor violin use raw `log₁₀(BF)` / `log₁₀(BF_rigor)` source values
with **display capping at `|log₁₀(BF)| = 2`**: values beyond the cap,
including `±Inf`, are plotted *at* the cap and feed the violin density /
points / median / IQR / whiskers (the violin represents the displayed
distribution). The cap is a visualization convention only — raw
registry/sidecar values are unchanged (genuine `±Inf` is preserved end to
end, per §3). `corpus_component_violin_stack.pdf` is a **horizontal
three-panel** figure (Effect | Heterogeneity | Modeled bias, strata listed
once, aligned rows, component-specific free x-axes); `50` writes a
stratum-scoped counterpart `<scope>_component_violin_stack.pdf`. **Orchards
(evidence-axis transform) are retired** from the active visual pipeline —
they are archived only and never produced by any default run.
`build_corpus_visuals()` / `build_stratum_visuals()` return an
invisible `$diagnostics` tibble recording the raw distribution and the
capping; **no diagnostics CSV is written.**

---

## 5. Source-controlled vs generated

| Category | Examples | Policy |
|----------|----------|--------|
| **Immutable inputs (committed)** | `data/**/<dataset_id>.csv`, `data/**/<dataset_id>.xlsx` | Never written by the pipeline. |
| **Committed derived primitives** | `output/<stratum>/<stratum>_robma_summary.csv`, `output/<stratum>/<stratum>_zplot_diagnostics.csv` | Carry the outcome-level primitives needed to regenerate every table/figure without rerunning MCMC. |
| **Committed reporting tables / figures** | `output/overview/*.csv`, `output/overview/*.tex`, `output/overview/*.pdf`, per-stratum `plots/` | Regenerable from the committed sidecars via `60` then `30/50/70`. |
| **Large fit objects (optional)** | `fit_RE4_*.rds`, `fit_RoBMA4_*.rds`, `zplot_*_*.rds` | **May be omitted** from the public repo; `.gitignore` excludes them by default. Force-add with `git add -f` only if a specific fit must ship. A full nutrition rebuild is several CPU-hours. |
| **Audit artifacts** | `output/<stratum>/<source_article>/audit/*.csv` | Regenerable; keep for traceability, not required to ship. |
| **Scratch / legacy** | `output/_scratch/`, `archive/RoBMA_3_6/**` | Never beside trusted sidecars; ignored / archived. |

**Manuscript figures.** Manuscript-ready figures should be **copied/exported**
into the manuscript tree (`Rigor_Manuscript/05_figures/`) rather than
treating `output/overview/` as the manuscript figure target. `output/` is
the regenerable analysis surface; the manuscript pins a specific
revision. (Note: the active `70_corpus_visuals.R` writes
`corpus_`-prefixed filenames; the pinned figures currently under
`Rigor_Manuscript/05_figures/` use the older un-prefixed naming
generation — a future manuscript revision must re-export, see
[`manuscript_bridge.md`](manuscript_bridge.md).)

---

## 6. Simulation sub-project outputs

The `simulation/` sub-project has its **own** output surfaces, separate
from the empirical `output/`. They are all **generated / regenerable**
(never source-of-truth inputs). Replicate count is set only at
generation time via `sim_generate_library(n_reps = ...)`; downstream
outputs report the current library size in their rows rather than in
filenames. See
[`../simulation/README.md`](../simulation/README.md)
for the canonical workflow.

| Path | Written by | Contents | Policy |
|------|-----------|----------|--------|
| `output_sim_v30/<stratum>/...` | `sim_fit_library()` → `batch_fit` (20/40) | Synthetic per-stratum sidecars + fits (`corpus_id = sim_library_v30`, `scheme = simulation_cell`) — same structure as `output/`, a **separate root** (one scheme/corpus per root). | Generated; `.rds` fits omittable. |
| `output_sim_v30/overview/*.csv` | `60_estimand_tables.R` (`root=output_sim_v30`) | Simulation registry + estimand tables (same schema as `output/overview/`). | Regenerable from sim sidecars. |
| `simulation/results/fit_status.csv` | `sim_fit_library()` (status flushed after each stratum) | Per-stratum fit status across the current library. Stable filename (no replicate-count suffix). | Generated; resume-safe. |
| `simulation/results/fit_progress_{live,overall}.csv` | `50_sim_fit_monitor.R::sim_write_fit_progress()` | Replicate-count-agnostic live fit progress. Per-cell row carries `n_generated`, `n_fit`, `n_target`, `fit_fraction`, `cell_status`. Overall row carries `n_generated_total`, `n_fit_total`, `generated_reps_{min,max,uniform}`, `library_status`, `expected_source`, `integrity_flag`. | Generated diagnostics. |
| `simulation/results/cell_diagnostics_{rigor,component}.csv` | `55_sim_cell_diagnostics.R::sim_build_cell_diagnostics()` | Per-cell rigor / component diagnostics (stable filenames). Each row carries the cell identity, `n_generated` and `n_fit` (sample-size context for the metric), and the metric estimates + MCSEs. Library-wide progress bookkeeping lives only in `fit_progress_*.csv` (not duplicated here). | Generated diagnostics. |
| `simulation/results/study_geometry_v30/*` | `45_study_geometry.R` | Raw-input k/SE/information geometry rollups (emp + sim). | Generated diagnostics. |
| `simulation/results/empirical_resampling/empirical_resampling_{observed,size_curve,size_curve_summary,observed_size_intervals}.csv` + `empirical_resampling_report.md` | `60_empirical_resampling.R::emp_run_resampling()` | Q2 empirical resampling/scaling: observed stratum + corpus summaries; raw scaling-curve draws (per `level` / `stratum` / `bootstrap_mode` / `n_sampled` / replicate); per (`level`, `stratum`, `mode`, `n_sampled`, metric) interval-style summary (`q025/q05/q050/q95/q975`, `interval_width_{90,95}`, `bias_vs_observed`, `bootstrap_mean/sd`); observed-size slice of that summary at each group's observed `n_outcomes` / `n_sources`. Stable filenames; `B`, `bootstrap_mode`, `seed`, `level`, `stratum`, `n_sampled` live in row columns. | Generated diagnostics. |
| `simulation/results/empirical_weighted_synthetic/{empirical_weighted_synthetic_report.md, empirical_cell_assignments.csv, empirical_stratum_{cell_weights,coherence}.csv, empirical_weighted_synthetic_{stratum,corpus}_{draws,draw_summary}.csv, empirical_weighted_synthetic_size_curve_{draws,summary}.csv, empirical_weighted_synthetic_size_curve_report.md, composition_validation_checks.csv}` | `65_synthetic_resampling.R::sim_run_empirical_weighted_synthetic()` + `sim_run_empirical_weighted_size_curve()` | Q3 empirical-weighted synthetic sampling primaries. Stable filenames; `B`, `pool_key`, `smoothing`, `composition_id`, `seed`, `dev_partial` live in row columns. Gated on a clean generated+fitted library via `sim_inventory_library()`. Folder + files renamed from `synthetic_composition/` in 2026-05 (deprecation aliases `sim_run_synthetic_composition` / `sim_run_composition_size_curve` kept for one cycle). | Generated; gated. |
| `simulation/results/empirical_weighted_synthetic/detail/{synthetic_cell_transition.csv, synthetic_axis_transition.csv, stratum_target_provenance.csv, stratum_observed_recovery.csv, synthetic_support_diagnostics.csv}` | `65_synthetic_resampling.R::sim_run_empirical_weighted_synthetic()` | Profile-definition / calibration detail: target↔observed transition matrices, per-stratum provenance / recovery, synthetic-pool support. | Generated; gated. |
| `simulation/results/agreement/empirical_vs_synthetic_{stratum,corpus}_agreement.csv` + `empirical_synthetic_agreement_report.md` | `70_empirical_synthetic_agreement.R::sim_run_empirical_synthetic_agreement()` | Empirical-vs-empirical-weighted-synthetic agreement (primary-rigor + component). Stable filenames; `dev_partial` and `composition_source` in row columns. Resolves Q3 input in priority order: in-memory `composition` arg, then Q3 sampling CSVs under `simulation/results/empirical_weighted_synthetic/`, then a fresh run (gated by `run_composition_if_missing`). | Generated; gated. |
| `simulation/results/figures/empirical_weighted_synthetic/*.pdf` + `empirical_weighted_synthetic_visuals_{deferred.csv,report.md}` | `75_analysis_visuals.R::sim_run_q3_visuals()` (via `sim_run_all_analysis_visuals()`) | Vector-PDF Q3 figures + deferred-family ledger. Reads from `empirical_weighted_synthetic/`, `empirical_weighted_synthetic/detail/`, and `agreement/`. Never recomputes upstream layers; missing inputs cause the relevant figure to be skipped and noted in the report. Renamed from `figures/composition/` in 2026-05; `sim_run_composition_visuals()` / `cv_run_composition_visuals()` retained as deprecated aliases. | Generated figures. |
| `simulation/latent/...`, `simulation/manifests/...` | `30_sim_export.R`, `40_sim_run.R` | True parameters / (cell,replicate) bookkeeping. **Never** in `data/`. | Generated; not loaded by the fitter. |

`simulation/results/_scratch/` (if present) is throwaway probe scratch —
never beside trusted results; safe to delete (see
[`project_cleanup_ledger.md`](project_cleanup_ledger.md)).
