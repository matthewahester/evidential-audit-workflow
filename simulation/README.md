# Simulation / resampling layer

This folder builds the simulation and resampling layer for the RoBMA-PSMA rigor-estimand pipeline for systematic evidential auditing. The nutrition corpus is the worked empirical example. The simulation layer is general: it evaluates how the audit workflow behaves under constructed effect x heterogeneity x bias-burden regimes and how that behavior relates to empirical resampling and empirical-weighted synthetic sampling.

The v4 main pipeline remains the source of truth. Synthetic datasets are exported as audit-ready CSVs, then passed through the same loader, fitter, sidecar writer, registry builder, and summary reducers used by the empirical pipeline.

> **Public release note.** Generated simulation datasets, fitted simulation outputs, raw resampling/sampling draws, and the full simulation result trees are **not committed** to the public GitHub repository. They are regenerable from the scripts, design grid, and recorded R / JAGS environment documented here and in [`../docs/environment.md`](../docs/environment.md). The manuscript and supplement contain the reported displays; this folder provides the machinery and the runbook to reproduce them. See [`../docs/output_commit_policy.md`](../docs/output_commit_policy.md) for the full commit policy.

---

## The three analysis questions

| Question | What it asks | Main outputs | Main figures |
|---|---|---|---|
| **Q1. Known-cell behavior** | How does selected rigor behave under each 36-cell design cell, especially as `n_outcomes` grows through 5-30, and how stable are its core audit components (bias evidence, absolute attenuation)? | `cell_diagnostics_*`; `cell_behavior/synthetic_cell_size_curve_*` | per-cell rigor + attenuation atlases; rigor variability + viability; component variability for bias evidence and absolute attenuation |
| **Q2. Empirical resampling stability** | If the empirical nutrition registry is resampled, how stable are the observed stratum/corpus rigor summaries? | `empirical_resampling/*` | stratum rigor variability over `n_sampled`; observed-size core-metric uncertainty heatmap; observed-size core-metric intervals |
| **Q3. Empirical fitted-cell-weighted synthetic sampling** | Given empirical outcomes' deterministic fitted-cell assignments (`\|mu_BC\|`, `tau_BC`, `log10BF_bias`), how do synthetic samples drawn from the fitted synthetic library under each stratum's fitted-cell mixture behave? Default weighting is support-masked shrinkage weighting (code label `smoothing = "eb_corpus"`, `kappa = 4`, `support = "occupied"`); pool basis is `pool_key = "target"` (sensitivity: `"observed"`). | `empirical_weighted_synthetic/*`; `agreement/*` | empirical fitted-cell mixture map; empirical-weighted synthetic rigor variability; empirical-bootstrap vs empirical-weighted synthetic core-metrics overlay |

Diagnostic/provenance outputs are still useful, but they are not primary analysis questions: target-observed transitions, target provenance, observed recovery, and pool support are reported as diagnostics.

---

## Naming guardrail

Use these terms consistently in comments, reports, figure captions, and prose. Internal mechanism nouns (`composition_id`, `observed_cell_slug`, `sim_validate_composition_inputs`) are retained where churn outweighs clarity; public language should still use the right-hand column.

| Term | Meaning |
|---|---|
| `target_cell` / DGM cell | Synthetic design cell known by construction. Encoded as `sim_<effect>_<heterogeneity>_<bias>`. |
| `fitted_cell` / empirical fitted-cell assignment | Deterministic projection of an empirical outcome onto the 36-cell vocabulary using `\|mu_BC\|`, `tau_BC`, `log10BF_bias`. **Not a true generative label**; not evidence the outcome came from a synthetic regime. |
| `observed_cell_slug` | Internal column name for the fitted-cell assignment. Public language says "fitted-cell assignment" / "fitted profile cell". |
| `k` / `k_studies` | Number of studies inside one generated/fitted meta-analytic outcome. |
| `n_outcomes` | Number of outcome-level meta-analyses summarized inside a stratum/corpus draw. |
| `B` | Resampling/sampling replicate count (Monte-Carlo precision of the resampling summary). Lives in row columns + reports; never in filenames. |
| `n_reps` | Per-target-cell depth of the fitted synthetic library. Publication primary: 500/cell (the 18,000-outcome library is complete). `n_reps = 150` was the development/internal tier. |

The 5-30 stability range refers to `n_outcomes` unless the analysis explicitly says it is varying `k_studies` inside the DGM. `B` and `n_reps` are independent: increasing `B` reduces Monte-Carlo noise in the resampling summary; it does not smooth away finite-support roughness, which is a function of `n_reps`.

**Avoid in public language**: "empirical outcomes assigned to DGM cells" (they are projected into fitted profile cells, not assigned to DGM cells); "calibration DGM" / "empirical DGM" (Q3 is not a DGM); "Q3 proves the empirical corpus came from the synthetic regimes". Do say: "empirical fitted-cell-weighted synthetic sampling"; "fitted profile cell"; "Q3 bridges empirical corpus structure and known-cell synthetic behavior".

---

## One public runner per numbered script

Each numbered simulation script has exactly one operator-facing public runner. Lower-level functions remain available for targeted/debug use, but the default flow is runner-based.

| Script | Default operator runner | Returns |
|---|---|---|
| `40_sim_run.R` | `sim_generate_library()`, `sim_run_study_geometry()`, `sim_fit_library()`, `sim_scan_fit_progress()` | generation + fit phase |
| `55_sim_cell_diagnostics.R` | `sim_build_cell_diagnostics()` | per-cell rigor/component diagnostics + Q1 effect draws |
| `scripts/60_estimand_tables.R` (main pipeline, not simulation) | `build_estimand_tables(root = "output_sim_v30", output_dir = "output_sim_v30/overview")` | overview registry consumed by 65 |
| `60_empirical_resampling.R` | `emp_run_resampling(B = 500, ...)` | Q2 empirical resampling |
| `65_synthetic_resampling.R` | `sim_run_synthetic_resampling(B = 500, ...)` | Q1 known-cell size curve + Q3 empirical-weighted synthetic sampling at observed stratum sizes + Q3 empirical-weighted synthetic size curve |
| `70_empirical_synthetic_agreement.R` | `sim_run_empirical_synthetic_agreement()` (config auto-adopted from loaded Q3 CSVs) | empirical-vs-synthetic agreement |
| `75_analysis_visuals.R` | `sim_run_all_analysis_visuals()` (after `source("scripts/00_utils.R")`) | Q1/Q2/Q3 figures + per-question reports + derived visualization tables |

`sim_generate_library(n_reps = ...)` is the only place the operator picks synthetic replicates per cell. Downstream scripts inventory the generated/fitted library on disk. Replicate counts, bootstrap counts, pool basis, smoothing, and partial/development state belong in row columns and reports, not in stable filenames.

---

## `simulation/latent/` is provenance only

`simulation/latent/sim_<cell_slug>/sim<vintage>/repNNNN_latent.csv` carries the per-study DGM truth for each generated dataset (`theta_true`, `g_pre_bias`, `n_per_arm`, candidate-selection columns). It is written by `sim_export_dataset()` alongside the audit-ready observed CSV.

**No active analysis reads latent files.** Q1 cell diagnostics (55), Q2 empirical resampling (60), Q3 empirical-weighted synthetic sampling (65), and the Q3 agreement layer (70) all read from the audit-ready CSVs under `data/sim_*/sim<vintage>/`, the fitted sidecars under `output_sim_v30/`, the overview registry under `output_sim_v30/overview/outcome_registry.csv`, and the analysis result CSVs under `simulation/results/`. `sim_inventory_library()` counts `_latent.csv` files for the `n_latent` column only; nothing opens them.

Implications:
- A latent-vs-data mismatch (e.g. 125 latent CSVs against 150 audit-ready CSVs in one cell) is a provenance signal. It can arise from interrupted earlier generation, prior runs under a different code path, or manual file movement.
- Latent mismatch does NOT block RoBMA fitting (`sim_fit_library()`), registry-based resampling (`sim_run_synthetic_resampling()`), or the agreement layer.
- The audit helper `sim_audit_latent_library()` reports per-cell `n_data_csv`, `n_latent_csv`, `n_missing_latent`, `n_extra_latent`, and optionally `n_fit_sidecars`. The repair helper `sim_repair_missing_latent()` regenerates the dataset deterministically from `(cell_row, rep_id, base_seed)` and writes the missing latent file ONLY when the regenerated observed table matches the existing audit-ready CSV on `study_id`/`g`/`se_g`. Default `repair = FALSE` is dry-run / report-only. Latent is never reconstructed from observed data alone (DGM-truth columns are not recoverable).
- `sim_export_dataset()` handles observed and latent independently. Under `overwrite = FALSE`: an existing observed CSV is always left in place; a missing latent file is filled in only when the freshly generated observed table matches the on-disk observed CSV on `study_id`/`g`/`se_g` (tolerance 1e-10), otherwise latent is left missing and the row is flagged. Each manifest row carries `observed_status` ("written" | "skipped") and `latent_status` ("written" | "skipped" | "filled" | "mismatch" | "error"); the legacy `status` column mirrors `observed_status` so existing summary counters keep working. As a consequence, re-running `sim_generate_library(...)` self-heals an observed-existing / latent-missing gap — `sim_repair_missing_latent()` is no longer strictly required for that scenario, but remains the targeted, auditable interface.

---

## Sidecars -> simulation outcome registry handoff

Different downstream layers read different products of the fitted library:

| Layer | Reads | Why |
|---|---|---|
| 55 diagnostics | simulation sidecars directly | live per-cell diagnostics, no registry needed |
| 65 synthetic resampling (Q1 + Q3) | `output_sim_v30/overview/outcome_registry.csv` | pooled fitted synthetic registry for Q1 known-cell sampling and Q3 empirical-weighted synthetic sampling |

As of 2026-05, `sim_run_synthetic_resampling()` rebuilds the simulation overview registry automatically before the resampling subroutines (default `refresh_registry = TRUE`); the canonical operator flow is just:

```r
source("simulation/scripts/55_sim_cell_diagnostics.R")
sim_build_cell_diagnostics()

source("simulation/scripts/65_synthetic_resampling.R")
sim_run_synthetic_resampling(B = 500, n_grid = c(5:30, 35, 40, 50))
```

If you are calling the lower-level runners directly (`sim_run_cell_size_curve()`, `sim_run_empirical_weighted_synthetic()`, `sim_run_empirical_weighted_size_curve()`), or you want to refresh the registry without running any resampling, do it explicitly:

```r
source("scripts/60_estimand_tables.R")
build_estimand_tables(
  root       = "output_sim_v30",
  output_dir = "output_sim_v30/overview"
)
# or, equivalently, the convenience wrapper:
source("simulation/scripts/65_synthetic_resampling.R")
sim_refresh_synthetic_registry()
```

Pass `refresh_registry = FALSE` to `sim_run_synthetic_resampling()` to skip the auto-refresh when the registry is known fresh from an earlier call in the same session. **Diagnostic rule:** if `cell_diagnostics_rigor.csv` reports larger `n_fit` than 65's `n_pool`, the overview registry is stale; `sim_run_cell_size_curve()` already prints a soft warning when this mismatch is detected.

`sim_build_cell_diagnostics()` does **not** rebuild the registry automatically: 55 is a sidecar-diagnostic layer with its own contract (no registry dependency).

---

## Canonical workflow (Phases A-D)

Operator runs after a full simulation rebuild. Each phase has a single purpose.

### Phase A. Generate and fit simulation library

```r
source("simulation/scripts/40_sim_run.R")

sim_generate_library(n_reps = 500)
sim_run_study_geometry()
sim_fit_library()
sim_scan_fit_progress()   # optional progress check
```

`n_reps = 500` per cell is the publication target (the 18,000-outcome library is complete on disk). `n_reps = 150` was the development/internal tier. `n_reps` is the per-cell replication count for the fitted library and is a separate quantity from resampling `B`.

### Phase B. Refresh fitted-library diagnostics

```r
source("simulation/scripts/55_sim_cell_diagnostics.R")
sim_build_cell_diagnostics()
```

The overview-registry rebuild (`build_estimand_tables(root = "output_sim_v30", ...)`) used to be a manual step here, but as of 2026-05 it is folded into Phase C's `sim_run_synthetic_resampling()` (default `refresh_registry = TRUE`). Call `sim_refresh_synthetic_registry()` explicitly only when invoking the lower-level 65 runners directly, or when refreshing the registry without running any resampling. Pass `refresh_registry = FALSE` to Phase C if the registry was just rebuilt in the same session.

### Phase C. Run resampling / Q3 sampling analyses

**Development / visual-tuning run** (`B = 500`; default smoothing is the support-masked shrinkage weighting with code label `eb_corpus`):

```r
source("simulation/scripts/60_empirical_resampling.R")
emp_run_resampling(
  B      = 500,
  n_grid = c(5:30, 35, 40, 50)
)

source("simulation/scripts/65_synthetic_resampling.R")
sim_run_synthetic_resampling(
  B             = 500,
  n_grid        = c(5:30, 35, 40, 50),
  pool_key      = "target",
  smoothing     = "eb_corpus",
  kappa         = 4,
  support       = "occupied",
  allow_partial = FALSE,
  workers       = 3
)

source("simulation/scripts/70_empirical_synthetic_agreement.R")
# Auto-adopts B / pool_key / smoothing / kappa / support from the
# loaded Q3 CSVs and prints a [sa] message naming what was adopted.
# Pass any setting explicitly to assert it (guard fires on mismatch
# for that field only).
sim_run_empirical_synthetic_agreement()
```

**Final / publication run** (`B = 15000`; same primary settings; expect long wall time):

```r
emp_run_resampling(B = 15000, n_grid = c(5:30, 35, 40, 50))

sim_run_synthetic_resampling(
  B             = 15000,
  n_grid        = c(5:30, 35, 40, 50),
  pool_key      = "target",
  smoothing     = "eb_corpus",
  kappa         = 4,
  support       = "occupied",
  allow_partial = FALSE,
  workers       = 5
)

# Final run: assert every Q3 setting (engages stale-config guard for
# all five fields) and refuse any implicit Q3 recompute.
sim_run_empirical_synthetic_agreement(
  B                = 15000,
  pool_key         = "target",
  smoothing        = "eb_corpus",
  kappa            = 4,
  support          = "occupied",
  run_composition_if_missing = FALSE,
  allow_config_mismatch = FALSE
)
```

**B tiers (resampling Monte-Carlo precision):**

| Tier | B | Use |
|---|---|---|
| Development / visual tuning | 500 | Default; routine runs; quick iteration. |
| Internal high-precision check | 5000 | Verify stability of headline numbers before a final run. |
| Final / publication | 15000 | Final figures and reports when feasible. |

Increasing `B` reduces Monte-Carlo noise in the resampling summaries; it does **not** smooth away the empirical finite-support roughness driven by `n_reps`. `n_reps` (per-target-cell fitted-library depth) is a separate design quantity: the publication primary is **`n_reps = 500` per cell** (the 18,000-outcome library is complete on disk; `fit_progress_overall.csv` reports `library_status = complete_clean`). `n_reps = 150` was the earlier development/internal tier.

**Stale-config guard (Q3).** `B` / `pool_key` / `smoothing` / `kappa` / `support` all default to `NULL` in 70 — when NULL, the value is auto-adopted from the loaded Q3 CSVs (loaded `B` is inferred from `length(unique(composition_id))` in the stratum + corpus draw CSVs; the others are read as columns) and a `[sa]` message names what was adopted. The guard fires **only** for fields the caller passed explicitly: assert any setting that must hold to catch a mismatch with the on-disk CSVs, leave any field NULL to inherit it. For final runs assert every Q3 setting and set `run_composition_if_missing = FALSE` so you cannot silently kick off an implicit Q3 recompute against partial fitted-library state. Every output row carries both the resolved value and the inferred-loaded value (`loaded_B_stratum` / `loaded_pool_key` / etc.) regardless of which path resolved them. Pass `allow_config_mismatch = TRUE` only to deliberately reuse a Q3 CSV with a different B / smoothing / pool basis. The previous `allow_B_mismatch` argument is retained as a deprecated alias for one cycle (emits a soft warning and forwards through).

### Phase D. Build visuals

```r
source("scripts/00_utils.R")                              # palette: .VIS_COLORS
source("simulation/scripts/75_analysis_visuals.R")
sim_run_all_analysis_visuals()
```

75 depends on `.VIS_COLORS` from the base pipeline utilities (`scripts/00_utils.R`); source it first. 75 sentinel-sources `scripts/00_utils.R` if `.VIS_COLORS` is missing, and `.cv_need_colors()` fails with a clear message at call time if the sentinel cannot find the file. 75 only reads upstream CSVs and writes figures + per-question reports + a small number of derived visualization tables (e.g. `synthetic_cell_rigor_viability_min_n.csv`, derived from the size-curve summary). It does NOT regenerate missing analysis inputs. 75 was renamed from `75_composition_visuals.R` in the 2026-05 Q3 terminology pass.

### File provenance map

| File | Written by | Public runner |
|---|---|---|
| `simulation/results/cell_diagnostics_rigor.csv` | 55 | `sim_build_cell_diagnostics()` |
| `simulation/results/cell_diagnostics_component.csv` | 55 | `sim_build_cell_diagnostics()` |
| `simulation/results/cell_behavior/cell_behavior_effect_draws.csv` | 55 | `sim_build_cell_diagnostics()` |
| `output_sim_v30/overview/outcome_registry.csv` | `scripts/60_estimand_tables.R` | `build_estimand_tables()` (or `sim_refresh_synthetic_registry()`) |
| `simulation/results/cell_behavior/synthetic_cell_size_curve_draws.csv` | 65 (from registry) | `sim_run_cell_size_curve()` via `sim_run_synthetic_resampling()` |
| `simulation/results/cell_behavior/synthetic_cell_size_curve_summary.csv` | 65 (from registry) | `sim_run_cell_size_curve()` via `sim_run_synthetic_resampling()` |
| `simulation/results/cell_behavior/synthetic_cell_size_curve_report.md` | 65 | `sim_run_cell_size_curve()` via `sim_run_synthetic_resampling()` |
| `simulation/results/empirical_weighted_synthetic/*` (incl. `empirical_weighted_synthetic_{stratum,corpus}_draws.csv`, `..._draw_summary.csv`, `..._size_curve_draws.csv`, `..._size_curve_summary.csv`, `empirical_weighted_synthetic_report.md`, `..._size_curve_report.md`, `empirical_cell_assignments.csv`, `empirical_stratum_cell_weights.csv`, `empirical_stratum_coherence.csv`, `composition_validation_checks.csv`, `detail/`) | 65 | `sim_run_empirical_weighted_synthetic()`, `sim_run_empirical_weighted_size_curve()` via `sim_run_synthetic_resampling()` |
| `simulation/results/empirical_resampling/*` | 60 | `emp_run_resampling()` |
| `simulation/results/agreement/*` | 70 | `sim_run_empirical_synthetic_agreement()` |
| `simulation/results/cell_behavior/synthetic_cell_rigor_viability_min_n.csv` | 75 (derived from `synthetic_cell_size_curve_summary.csv`) | `sim_run_cell_behavior_visuals()` / `sim_run_all_analysis_visuals()` |
| `simulation/results/figures/**/*.pdf` | 75 (requires `.VIS_COLORS` from `scripts/00_utils.R`) | `sim_run_all_analysis_visuals()` |
| `simulation/results/figures/**/*_report.md` | 75 | `sim_run_all_analysis_visuals()` |

Diagnostic rule: if `cell_behavior_effect_draws.csv` exists but `synthetic_cell_size_curve_summary.csv` is missing, 55 has run and 65 has not; run Phase C step 2. If `cell_diagnostics_rigor.csv` reports `n_fit = 150` but `synthetic_cell_size_curve_summary.csv` reports `n_pool = 25`, 65 was run against a stale overview registry; rebuild via Phase B step 2 and re-run Phase C.

Q3 folder migration (2026-05): the previous `simulation/results/synthetic_composition/` and `simulation/results/figures/composition/` were renamed to `simulation/results/empirical_weighted_synthetic/` and `simulation/results/figures/empirical_weighted_synthetic/`. The Q3 visual orchestrator scrubs retired PDFs from the legacy figure folder on every run; old `synthetic_composition_*` and `composition_visuals_*` files left in the old `synthetic_composition/` folder are not consumed by the active workflow.

---

## Current script inventory

```text
simulation/scripts/
├── 00_sim_utils.R                     # naming, seeding, k sampler helpers
├── 10_sim_design.R                    # design loader + validators
├── 20_sim_generate.R                  # single-dataset DGM
├── 30_sim_export.R                    # audit-ready export + latent writer
├── 40_sim_run.R                       # generate, fit, smoke, config wrappers
├── 45_study_geometry.R                # raw input-geometry parity check
├── 50_sim_fit_monitor.R               # inventory, progress, collision/leak checks
├── 55_sim_cell_diagnostics.R          # per-cell selected-rigor/component diagnostics
├── 60_empirical_resampling.R          # empirical Track A resampling (Q2)
├── 65_synthetic_resampling.R          # Q1 known-cell + Q3 empirical-weighted synthetic sampling
├── 70_empirical_synthetic_agreement.R # empirical-vs-synthetic agreement (Q3)
└── 75_analysis_visuals.R              # Q1/Q2/Q3 visual layer (figures + per-question reports + derived viz tables)
```

All numbered scripts remain define-only on source. Sourcing installs functions only; it does not generate data, fit models, read registries, or write files unless an explicit public entry point is called.

---

## Full36 cell library

The active synthetic grid is:

```text
4 effect levels x 3 heterogeneity levels x 3 bias-burden levels = 36 cells
```

| Axis | Slugs | Anchors |
|---|---|---|
| effect | `null`, `small`, `moderate`, `large` | `mu_true = 0.00, 0.10, 0.25, 0.50` |
| heterogeneity | `lowhet`, `midhet`, `highhet` | `tau_true = 0.05, 0.15, 0.40` |
| bias burden | `clean`, `modbias`, `highbias` | no selection / threshold selection plus increasing `smallstudy_alpha` |

Canonical synthetic stratum naming:

```text
cell_slug = <effect_slug>_<heterogeneity_slug>_<bias_slug>
stratum   = sim_<cell_slug>
```

Example:

```text
cell_slug      = moderate_midhet_modbias
stratum        = sim_moderate_midhet_modbias
source_article = sim2026
outcome_slug   = rep0001
dataset_id     = sim2026_sim_moderate_midhet_modbias_rep0001
```

Use `output_sim_v30` / `sim_library_v30` / `simulation_cell` for the fitted simulation identity unless intentionally starting a new major simulation library version.

---

## Q1. Known-cell behavior

Public runners:

```r
source("simulation/scripts/55_sim_cell_diagnostics.R")
sim_build_cell_diagnostics()

source("simulation/scripts/65_synthetic_resampling.R")
sim_run_synthetic_resampling(B = 500, n_grid = c(5:30, 35, 40, 50))
```

Outputs:

```text
simulation/results/cell_diagnostics_rigor.csv        # 55
simulation/results/cell_diagnostics_component.csv    # 55
simulation/results/cell_behavior/cell_behavior_effect_draws.csv          # 55
simulation/results/cell_behavior/synthetic_cell_size_curve_draws.csv     # 65
simulation/results/cell_behavior/synthetic_cell_size_curve_summary.csv   # 65
simulation/results/cell_behavior/synthetic_cell_size_curve_report.md     # 65
```

Each diagnostic row carries cell identity, generated/fitted counts, selected-rigor summaries, component summaries, and MCSEs for binary rates where available. Operating-characteristic claims require enough fitted rows per cell for acceptable Monte Carlo uncertainty.

Q1 default visual family (7 figures: 4 primary + 3 secondary). Built by 75 from the size-curve summary + `cell_diagnostics_rigor.csv`:

```text
simulation/results/figures/cell_behavior/
# primary
├── cell_rigor_atlas.pdf
├── cell_attenuation_atlas.pdf
├── synthetic_cell_rigor_variability_by_effect.pdf
├── synthetic_cell_rigor_viability_min_n.pdf
# secondary
├── synthetic_cell_rigor_width_heatmap_by_n.pdf
├── synthetic_cell_bias_evidence_variability_by_effect.pdf
└── synthetic_cell_attenuation_variability_by_effect.pdf
```

Plus a derived visualization table written by 75 alongside the size-curve summary:

```text
simulation/results/cell_behavior/synthetic_cell_rigor_viability_min_n.csv
```

Q1 is framed as sampling variability / viability of the stratum-level selected-rigor summary as `n_outcomes` changes. The three secondary figures support the primary rigor-variability claim by showing component variability in:

- bias evidence (`median_log10BF_bias`) — width90 by effect band
- absolute attenuation / effect recovery (`median_attenuation_abs`) — width90 by effect band
- rigor width90 snapshots at selected n_outcomes — 36-cell heatmap

`cell_attenuation_atlas.pdf` (primary) shows the per-cell distributional comparison of Baseline vs RoBMA-PSMA effect estimates, with the true effect marked; the secondary `synthetic_cell_attenuation_variability_by_effect.pdf` complements it by showing how variable the per-stratum absolute-attenuation summary is across B resamples.

The central-trend + convergence-error figures (`synthetic_cell_rigor_size_curve_by_effect.pdf`, `synthetic_cell_rigor_convergence_error_by_effect.pdf`, `synthetic_cell_threshold_rates_by_effect.pdf`, `synthetic_cell_size_curve_primary_rigor.pdf`, `synthetic_cell_size_curve_threshold_rates.pdf`) were retired earlier in 2026-05; the rate-metric variability companion (`synthetic_cell_rate_variability_by_effect.pdf`) and the per-cell operating-characteristics atlas (`full36_cell_operating_characteristics_primary_rigor.pdf`) were retired later in 2026-05 — the selected-rigor estimand is designed to abstract away from per-cell directional rate bookkeeping, and the operating-characteristics atlas no longer added enough beyond the rigor atlas + variability family to justify its slot.

**Rerun required for attenuation:** `median_attenuation_abs` was added to 65's `.SC_COMPONENT_METRICS` in 2026-05. `synthetic_cell_size_curve_summary.csv` only contains `metric == "median_attenuation_abs"` rows after rerunning `sim_run_synthetic_resampling()`; older summary CSVs will skip the attenuation variability figure with a clear "metric not found" error message.

---

## Q2. Empirical resampling stability

Public runner:

```r
source("simulation/scripts/60_empirical_resampling.R")
emp_run_resampling(B = 500,
                   n_grid = c(5:30, 35, 40, 50, 75, 100))
```

`n_grid` is the operator knob; each group's observed `n_outcomes` /
`n_source_articles` is auto-inserted so the observed-size interval
slice is always present. There is no separate
`emp_run_resampling_curve()` / `emp_run_stratum_size_curve()` call;
the scaling curve and observed-size intervals come from this single
run.

Outputs:

```text
simulation/results/empirical_resampling/
├── empirical_resampling_observed.csv
├── empirical_resampling_size_curve.csv
├── empirical_resampling_size_curve_summary.csv
├── empirical_resampling_observed_size_intervals.csv
└── empirical_resampling_report.md
```

Modes:

| Mode | Sampling unit | Interpretation |
|---|---|---|
| `outcome` | outcome rows within each stratum / corpus | baseline empirical stability |
| `source_cluster` | `source_article` clusters within each stratum / corpus | sensitivity to multiple outcomes from the same source |

Q2 visual layer (`sim_run_empirical_resampling_visuals()` in 75) reads `empirical_resampling_size_curve_summary.csv` (sampling variability over `n_sampled`) and `empirical_resampling_observed_size_intervals.csv` (observed-size uncertainty) and writes exactly three default PDFs:

```text
simulation/results/figures/empirical_resampling/
├── empirical_resampling_rigor_variability_by_stratum.pdf   # selected-rigor width90 over n_sampled, per stratum, faceted by bootstrap mode
├── empirical_resampling_core_uncertainty_heatmap.pdf       # observed-size width90 heatmap across core audit metrics
└── empirical_resampling_core_intervals.pdf                 # observed-size q05-q95 / q025-q975 intervals across core audit metrics
```

Default Q2 visuals focus on (1) selected-rigor sampling variability over `n_sampled`, (2) observed-size empirical bootstrap uncertainty for the manuscript-facing core audit metrics (selected rigor, bias evidence, absolute attenuation), and (3) observed-size interval profiles for those same core metrics. `median_rigor_margin` remains an available diagnostic/support field in the Q2 size-curve and observed-size CSVs but is not part of the manuscript-facing core metric set. Directional/thresholded `p_*` rate metrics remain in `empirical_resampling_size_curve_summary.csv` for ad-hoc inspection but are not default Q2 visual targets.

Corpus-level Q2 information is retained as a markdown core-metric summary table inside `empirical_resampling_visuals_report.md` rather than as default PDFs (a one-row Overall figure is less informative than the stratum-level stability story). Non-finite widths / endpoints are preserved and reported.

The earlier primary-rigor (`p_*`) Q2 figure family (`empirical_resampling_rigor_size_curve.pdf`, `empirical_resampling_corpus_rigor_size_curve.pdf`, `empirical_resampling_uncertainty_heatmap_primary_rigor.pdf`, `empirical_resampling_corpus_uncertainty_heatmap_primary_rigor.pdf`, `empirical_resampling_size_curve_primary_rigor.pdf`, `empirical_resampling_stratum_size_curve_primary_rigor.pdf`, `empirical_resampling_intervals_primary_rigor.pdf`, `empirical_resampling_corpus_intervals_primary_rigor.pdf`) was retired in 2026-05; stale copies are scrubbed from `simulation/results/figures/empirical_resampling/` on every Q2 run via the orchestrator's retired-PDF cleanup vector.

`n_sampled` counts outcome-level meta-analyses (or source clusters when `mode = source_cluster`); it does NOT count primary studies inside a meta-analysis. The k-studies dimension belongs elsewhere.

---

## Q3. Empirical-weighted synthetic sampling

Public runners:

```r
source("simulation/scripts/65_synthetic_resampling.R")
sim_run_synthetic_resampling(
  B      = 500,
  n_grid = c(5:30, 35, 40, 50)
)

source("simulation/scripts/70_empirical_synthetic_agreement.R")
sim_run_empirical_synthetic_agreement()    # adopts B etc. from loaded CSVs
```

Q3 outputs (renamed in the 2026-05 terminology pass):

```text
simulation/results/empirical_weighted_synthetic/
├── empirical_weighted_synthetic_report.md
├── empirical_cell_assignments.csv
├── empirical_stratum_cell_weights.csv
├── empirical_stratum_coherence.csv
├── empirical_weighted_synthetic_stratum_draws.csv
├── empirical_weighted_synthetic_corpus_draws.csv
├── empirical_weighted_synthetic_stratum_draw_summary.csv
├── empirical_weighted_synthetic_corpus_draw_summary.csv
├── empirical_weighted_synthetic_size_curve_draws.csv
├── empirical_weighted_synthetic_size_curve_summary.csv
├── empirical_weighted_synthetic_size_curve_report.md
├── composition_validation_checks.csv
└── detail/
    ├── synthetic_cell_transition.csv
    ├── synthetic_axis_transition.csv
    ├── stratum_target_provenance.csv
    ├── stratum_observed_recovery.csv
    └── synthetic_support_diagnostics.csv
```

Agreement outputs:

```text
simulation/results/agreement/
├── empirical_synthetic_agreement_report.md
├── empirical_vs_synthetic_stratum_agreement.csv
└── empirical_vs_synthetic_corpus_agreement.csv
```

### Interpretation

`empirical_stratum_cell_weights.csv` is the Q3 empirical-weighted sampling input map. It describes where each empirical stratum sits on the fitted 36-cell grid. The default `smoothed_weight` column is corpus-blended (`lambda * stratum_p + (1 - lambda) * corpus_p`, blended only over the cells the stratum actually populates, then renormalized) — it is **not** spatial smoothing over the 36-cell grid and does not extend weight to unobserved neighboring cells. The `additive` smoothing option does the full grid-Laplace spread when needed.

`empirical_weighted_synthetic_stratum_draws.csv` and `empirical_weighted_synthetic_corpus_draws.csv` are the core Q3 empirical-weighted synthetic draws. They sample fitted synthetic rows according to the empirical-derived corpus-blended sampling weights.

`empirical_vs_synthetic_*_agreement.csv` compares the observed empirical estimate to the empirical-weighted synthetic distribution. The CSVs are kept for downstream reporting, but the corpus + stratum agreement PDFs were retired in 2026-05 in favor of the empirical-bootstrap-vs-empirical-weighted-synthetic core-metrics overlay (see below).

The Q3 size-curve sweep keeps each empirical stratum's fitted-cell weights fixed and varies `n_outcomes` to expose how the empirical-weighted synthetic sampling behaves across plausible stratum sizes.

### Q3 default visual family (6 figures: 3 primary/bridge + 3 profile-definition diagnostics)

Built by `sim_run_q3_visuals()` / `sim_run_all_analysis_visuals()` from the Q3 outputs above plus `empirical_resampling_observed_size_intervals.csv`:

```text
simulation/results/figures/empirical_weighted_synthetic/
# Q3 primary / bridge
├── empirical_stratum_cell_weights_heatmap.pdf
├── empirical_weighted_synthetic_rigor_variability_by_stratum.pdf
└── empirical_bootstrap_vs_empirical_weighted_synthetic_core_metrics.pdf
# profile-definition diagnostics
├── synthetic_axis_transition_effect_heatmap.pdf
├── synthetic_axis_transition_het_heatmap.pdf
└── synthetic_axis_transition_bias_heatmap.pdf
```

Read in this sequence:

1. **Empirical fitted-cell mixture input** (`empirical_stratum_cell_weights_heatmap.pdf`). Fill = corpus-blended empirical-weighted sampling weight; orange outline marks the per-stratum dominant cell.
2. **Empirical-weighted synthetic sampling variability over `n_outcomes`** (`empirical_weighted_synthetic_rigor_variability_by_stratum.pdf`). One line per empirical stratum; y = `width90 = q95 - q05` of stratum-level median selected rigor across B empirical-weighted synthetic draws; lower = more stable.
3. **Empirical bootstrap vs empirical-weighted synthetic** (`empirical_bootstrap_vs_empirical_weighted_synthetic_core_metrics.pdf`). Forest/range plot per (stratum, core metric): blue = empirical bootstrap; purple = empirical-weighted synthetic; matched to each stratum's empirical `n_outcomes`. Manuscript-facing core metrics = `median_log10BF_rigor`, `median_log10BF_bias`, `median_attenuation_abs`. `median_rigor_margin` is also written to the same CSVs as an available diagnostic/support field but is not in the manuscript-facing core set. Directional/thresholded `p_*` rate metrics are deliberately excluded.
4. **Axis recovery diagnostics** (`synthetic_axis_transition_{effect,het,bias}_heatmap.pdf`). `P(observed band | target/DGM band)` per axis; help diagnose whether the fitted cell-assignment basis recovers the intended design axes.

Visual grammar: heatmaps for cell / axis grids (36-cell mixture, 3-or-4-band axis recovery); forest/range plots for stratum-by-metric uncertainty comparisons; line/width plots for stability over `n_outcomes`.

**Validation status and pool support are reported as text inside `empirical_weighted_synthetic_visuals_report.md`** — the earlier `composition_validation_status.pdf` and `synthetic_support_diagnostics_bars.pdf` were retired in the 2026-05 Q3 cull, along with `synthetic_composition_rigor_size_curve.pdf`, `synthetic_composition_size_curve_primary_rigor.pdf`, `empirical_bootstrap_vs_synthetic_composition_primary_rigor.pdf`, `empirical_vs_synthetic_corpus_agreement_primary_rigor.pdf`, `empirical_vs_synthetic_stratum_agreement_primary_rigor.pdf`, `synthetic_target_observed_transition_heatmap.pdf`, and `stratum_target_provenance_heatmap.pdf`. The two active Q3 primary/bridge figures were additionally renamed from `synthetic_composition_*` to `empirical_weighted_synthetic_*` in the 2026-05 terminology pass. Stale copies of all retired/renamed files are scrubbed from both the active `simulation/results/figures/empirical_weighted_synthetic/` folder and the legacy `simulation/results/figures/composition/` folder on every run via the orchestrator's retired-PDF cleanup vector.

**Rerun required for attenuation overlay:** the empirical-bootstrap-vs-empirical-weighted-synthetic core-metrics overlay needs `median_attenuation_abs` rows in `empirical_weighted_synthetic_size_curve_summary.csv`. `median_attenuation_abs` is already in 65's `.SC_COMPONENT_METRICS` (added 2026-05); a 65 rerun is required for older summary CSVs to pick it up.

---

## Stable output layout

```text
simulation/results/
├── fit_status.csv
├── fit_progress_live.csv
├── fit_progress_overall.csv
├── cell_diagnostics_rigor.csv
├── cell_diagnostics_component.csv
├── study_geometry_v30/
├── cell_behavior/
│   ├── cell_behavior_effect_draws.csv               # 55
│   ├── synthetic_cell_size_curve_draws.csv          # 65
│   ├── synthetic_cell_size_curve_summary.csv        # 65
│   ├── synthetic_cell_size_curve_report.md          # 65
│   └── synthetic_cell_rigor_viability_min_n.csv     # 75 (derived)
├── empirical_resampling/
├── empirical_weighted_synthetic/                    # renamed from synthetic_composition/ in 2026-05
├── agreement/
└── figures/
    ├── cell_behavior/
    ├── empirical_resampling/
    └── empirical_weighted_synthetic/                # renamed from figures/composition/ in 2026-05
```

Do not encode `B`, `n_reps`, `n_grid`, `pool_key`, `smoothing`, or dev/partial status in stable filenames. Put those values in row columns and reports.

---

## Current non-goals

Out of scope for this pass:

- journal-specific DGM dimensions;
- source-clustered synthetic generation;
- signed-effect DGM variants;
- mechanism-specific bias axes beyond the composite burden schedule;
- fixed-`k_studies` DGM ladder requiring new generation and refitting;
- treating observed-cell transition/provenance plots as primary results.

---

## Acceptance checklist

The focused runbook is successful when:

1. the three questions are visible at the top of the docs and figure reports;
2. empirical resampling has its own interval figures;
3. known-cell behavior includes `n_outcomes = 5..30` size curves;
4. empirical-weighted synthetic sampling has clear labels explaining the draw mechanism;
5. diagnostic transition/provenance figures are separated from primary figures;
6. `k` and `n_outcomes` are not conflated;
7. all scripts remain define-only on source;
8. output filenames remain stable and tier-free;
9. the sidecar -> registry handoff is explicit and the rebuild is part of the canonical workflow.
