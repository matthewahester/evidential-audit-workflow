# Runbook — Canonical Run Order

Default commands for every stage of the active RoBMA v4 rigor
project. Each block is tagged:

- 🟢 **READ-ONLY** — no disk writes (safe anytime, even mid-fit)
- 🟡 **WRITES** — writes CSV/figures, no MCMC
- 🔴 **HEAVY MCMC** — runs RoBMA/JAGS; never run two fits at once

R is `C:/Program Files/R/R-4.6.0/bin/Rscript.exe` (JAGS 4.3.1, RoBMA
4.0.0; see `docs/environment.md`). All numbered scripts are define-only:
`source()` never executes work. Run from the repo root.

> One scheme/corpus per output root. Empirical → `output/`; synthetic
> full36 → `output_sim_v30/`. Never mix. See
> `docs/pipeline_layout.md` / `docs/output_contract.md`.

---

## A. Empirical nutrition pipeline (fit) 🔴 HEAVY MCMC

```r
source("scripts/00_utils.R"); source("scripts/10_load_data.R")
source("scripts/20_robma_fit.R"); source("scripts/40_batch_fit.R")
# CONFIG defaults to the empirical root (output/). Fit one stratum:
batch_fit(stratum = "fiber", source_article = NULL, resume = TRUE)
# Corpus-wide acceptance gate (READ-ONLY, refits nothing):
sidecar_acceptance_all(output_root = "output", require_artifacts = FALSE)
```

Several CPU-hours for a full rebuild. The committed sidecars already
encode the primitives; you rarely need to refit empirically.

## B. Simulation generation 🟡 WRITES (synthetic data only)

```r
source("simulation/scripts/40_sim_run.R")
sim_generate_library(n_reps = 150, dry_run = TRUE)   # 🟢 plan only
sim_generate_library(n_reps = 150)                   # 🟡 36 cells × 150 reps
# n_reps is the ONLY place the replicate count is set; idempotent under
# overwrite=FALSE (existing reps preserved, missing reps added).
```

Writes `data/sim_<cell_slug>/sim2026/repNNNN.csv`,
`simulation/latent/...`, `simulation/manifests/...`. Never touches
`output*`. Lower-level `sim_run_design()` is still available for
custom design subsets and smoke tests.

## C. Simulation fitting 🔴 HEAVY MCMC

The canonical simulation fitter is `sim_fit_library()` in
`simulation/scripts/40_sim_run.R`. There is no separate shell wrapper.

From R:

```r
source("simulation/scripts/40_sim_run.R")
sim_fit_library()
```

Or as a one-liner (e.g. for cron / CI):

```bash
"C:/Program Files/R/R-4.6.0/bin/Rscript.exe" -e \
  "source('simulation/scripts/40_sim_run.R'); sim_fit_library()" \
  > simulation/results/fit.log 2>&1
# optional concurrency:  set SIM_FIT_WORKERS=4   (Windows env var)
```

Stratum-scoped loop over all 36 sim strata (per-stratum `batch_fit`,
**never** an all-strata call — that collides `repNNNN` objects).
Fits whatever generated CSVs are on disk (no `TARGET_REPS_PER_CELL`).
Resume by re-running the same command — completed datasets are skipped.
Writes to `output_sim_v30/` + `simulation/results/fit_status.csv`.

## D. Simulation monitor / acceptance 🟢 READ-ONLY

```r
source("simulation/scripts/50_sim_fit_monitor.R")
inv  <- sim_inventory_library()        # per-cell generated + fit counts
prog <- sim_scan_fit_progress()        # per-cell + overall completeness
sim_write_fit_progress(prog)
# Writes simulation/results/fit_progress_{live,overall}.csv.
# Contract gate (refits/rewrites nothing):
source("scripts/00_utils.R"); source("scripts/10_load_data.R")
source("scripts/20_robma_fit.R"); source("scripts/40_batch_fit.R")
sidecar_acceptance_all(output_root = "output_sim_v30",
                       require_artifacts = FALSE)
```

Completeness target = each cell's `n_generated` (from
`sim_inventory_library()`); `library_status = "complete_clean"` means
every generated CSV is fitted with no failures.

## E. Overview rebuild (simulation) 🟡 WRITES (tables)

```r
source("scripts/00_utils.R"); source("scripts/60_estimand_tables.R")
build_estimand_tables(root = "output_sim_v30",
                      output_dir = "output_sim_v30/overview",
                      write_tex = FALSE)
```

Only after Pass 5F. Writes `output_sim_v30/overview/*.csv`. The
empirical analogue uses `root="output"`, `output_dir="output/overview"`.

## F. Final cell diagnostics 🟡 WRITES (diagnostic CSVs)

```r
source("simulation/scripts/55_sim_cell_diagnostics.R")
sim_build_cell_diagnostics(write = TRUE)
```

Read-only on `output_sim_v30`. Writes stable filenames
`simulation/results/cell_diagnostics_{rigor,component}.csv`. Each row
carries the cell identity, `n_generated` and `n_fit` (sample-size
context for the metric value), and the rigor / component point
estimates + MCSEs. Library-wide progress bookkeeping lives in
`fit_progress_{live,overall}.csv`, not duplicated here.

## G. Empirical resampling (Track A) 🟡 WRITES

```r
source("simulation/scripts/60_empirical_resampling.R")

# One public workflow call. Scaling curve + observed-size intervals
# from a single B replicates per (level, group, mode, n_sampled) run.
# B tiers: 500 dev / 5000 internal high-precision / 15000 final.
emp_run_resampling(B = 500,
                   n_grid = c(5:30, 35, 40, 50, 75, 100))
```

Outcome + `source_article`-cluster bootstrap over
`output/overview/outcome_registry.csv`. No MCMC. Optional parallelism
via `workers = N` (default 1L; env override `EMP_RESAMPLING_WORKERS`);
per-replicate seeds are pre-computed so results are byte-identical
regardless of worker count. Each group's observed `n_outcomes` and
`n_source_articles` are auto-inserted into the grid so the
observed-size interval slice is always present. Writes five stable
files under `simulation/results/empirical_resampling/`:
`empirical_resampling_observed.csv`,
`empirical_resampling_size_curve.csv`,
`empirical_resampling_size_curve_summary.csv`,
`empirical_resampling_observed_size_intervals.csv`, and
`empirical_resampling_report.md`. `B`, `bootstrap_mode`, `seed`,
`level`, `n_sampled` live in row columns, not filenames.

## H. Synthetic resampling (Q1 + Q3) 🟡 WRITES (gated)

```r
source("simulation/scripts/65_synthetic_resampling.R")

# Default top-level runner. Mirrors emp_run_resampling() in feel:
# B and n_grid are the primary design parameters. Runs Q1 known-cell
# size curve + Q3 empirical-weighted synthetic sampling at observed
# stratum sizes + Q3 empirical-weighted synthetic size curve in one
# call. Default Q3 weighting is empirical-Bayes support-masked
# (smoothing = "eb_corpus", kappa = 4, support = "occupied").
# B tiers: 500 dev / 5000 internal high-precision / 15000 final.
sim_run_synthetic_resampling(
  B         = 500,
  n_grid    = c(5:30, 35, 40, 50),
  pool_key  = "target",
  smoothing = "eb_corpus",
  kappa     = 4,
  support   = "occupied"
)

# Lower-level targeted / debug calls (still public):
#   sim_run_cell_size_curve()                # Q1 only
#   sim_run_empirical_weighted_synthetic()   # Q3 observed-size only
#   sim_run_empirical_weighted_size_curve()  # Q3 size-curve only

# Optional parallelism (any runner):
#   sim_run_synthetic_resampling(B = 500, workers = 4L)
# Or via env: Sys.setenv(SYNTHETIC_COMPOSITION_WORKERS = "4")
```

Gated on a clean generated+fitted library (`library_status =
complete_clean`); per-cell target = each cell's `n_generated` (from
`sim_inventory_library()`). Writes the stable layout under
`simulation/results/empirical_weighted_synthetic/` (renamed from
`synthetic_composition/` in 2026-05):

- primaries: `empirical_weighted_synthetic_report.md`,
  `empirical_cell_assignments.csv`,
  `empirical_stratum_cell_weights.csv`,
  `empirical_stratum_coherence.csv`,
  `empirical_weighted_synthetic_{stratum,corpus}_draws.csv`,
  `empirical_weighted_synthetic_{stratum,corpus}_draw_summary.csv`,
  `empirical_weighted_synthetic_size_curve_{draws,summary}.csv`,
  `empirical_weighted_synthetic_size_curve_report.md`,
  `composition_validation_checks.csv`;
- detail: `detail/{synthetic_cell_transition,synthetic_axis_transition,
  stratum_target_provenance,stratum_observed_recovery,
  synthetic_support_diagnostics}.csv`.

`B`, `pool_key`, `smoothing`, `composition_id`, `seed`, `dev_partial`
live in row columns; filenames are stable across all settings.
`allow_partial = TRUE` runs on an incomplete library and marks every
row with `dev_partial = TRUE` (filenames stay the same).

## I. Empirical-vs-synthetic agreement 🟡 WRITES (gated)

```r
source("simulation/scripts/70_empirical_synthetic_agreement.R")
# Default Q3 settings match the recommended primary path:
# smoothing = "eb_corpus", kappa = 4, support = "occupied",
# pool_key = "target". B tiers: 500 dev / 5000 / 15000 final.
sim_run_empirical_synthetic_agreement(
  B         = 500,
  pool_key  = "target",
  smoothing = "eb_corpus",
  kappa     = 4,
  support   = "occupied",
  run_composition_if_missing = FALSE,   # final runs: no implicit recompute
  allow_config_mismatch      = FALSE)   # stale-config guard

# If the Q3 empirical-weighted synthetic sampling was just run in this
# session, hand its return value in:
# comp <- sim_run_empirical_weighted_synthetic(B = 500, write = FALSE)
# sim_run_empirical_synthetic_agreement(composition = comp)
```

Resolves the Q3 input in priority order: (1) in-memory
`composition` argument; (2) existing CSVs under `composition_dir`
(default `simulation/results/empirical_weighted_synthetic/`); (3)
fresh Q3 sampling run (when `run_composition_if_missing = TRUE`, the
default). For final runs pass `run_composition_if_missing = FALSE`
to make missing CSVs a hard error and `allow_config_mismatch = FALSE`
(the default) to keep the Q3 **stale-config guard** active — it
compares the requested `B` / `pool_key` / `smoothing` / `kappa` /
`support_scope` against what was actually written into the loaded
Q3 CSVs (loaded `B` is inferred from
`length(unique(composition_id))`) and stops on any mismatch. The
previous `allow_B_mismatch` argument is retained as a deprecated
alias for one cycle. Writes
`simulation/results/agreement/empirical_vs_synthetic_{stratum,corpus}_agreement.csv`
plus `empirical_synthetic_agreement_report.md`.

## J. Analysis visuals (Q1 + Q2 + Q3) 🟡 WRITES (figures)

```r
source("scripts/00_utils.R")
source("simulation/scripts/75_analysis_visuals.R")
sim_run_all_analysis_visuals()
```

Read-only on the result CSVs. Reads Q3 primaries from
`simulation/results/empirical_weighted_synthetic/`, detail from
`.../empirical_weighted_synthetic/detail/`, agreement tables from
`simulation/results/agreement/`, and Q1/Q2 inputs from their own
folders. Writes vector PDFs +
`empirical_weighted_synthetic_visuals_report.md` +
`empirical_weighted_synthetic_visuals_deferred.csv` into
`simulation/results/figures/empirical_weighted_synthetic/`. Never
recomputes Q3 outputs or agreement: missing inputs cause the
corresponding figure to be skipped and noted in the report. Requires
ggplot2 (lazy at call time). 75 was renamed from
`75_composition_visuals.R` to `75_analysis_visuals.R` in the 2026-05
terminology pass; the Q3 wrapper was renamed
`sim_run_composition_visuals()` → `sim_run_q3_visuals()`.
`sim_run_composition_visuals()` and `cv_run_composition_visuals()`
remain as deprecation aliases that emit a soft warning and forward.

## K. Scaling up the library (e.g. 25 → 150 reps/cell) 🔴 HEAVY MCMC

1. **Generate** 🟡 — `sim_generate_library(n_reps = 150)`. `overwrite =
   FALSE` is the default: existing reps are skipped/preserved, missing
   reps are written.
2. **Fit** 🔴 — `sim_fit_library()` (see C). Per-stratum loop,
   resume-safe, `SIM_FIT_WORKERS` concurrency. **Never** an all-strata
   `batch_fit`.
3. **Monitor / acceptance** 🟢 — D, with the larger library.
4. **Overview rebuild** 🟡 — E against `output_sim_v30`.
5. **Cell diagnostics** 🟡 — F.
6. **Composition / agreement / visuals** 🟡 — H → I → J (the gate uses
   the on-disk generated library size).

Operating-characteristic claims require enough fitted replicates per
cell to give acceptable Monte Carlo SE on the metric of interest; the
cell-level diagnostics report `n_fit` alongside every estimate.

---

### Quick safety map

| Stage | Tag | Writes to |
|---|---|---|
| A empirical fit / B gen / C sim fit / K | 🔴/🟡 | `output/`, `data/`, `latent/`, `output_sim_v30/` |
| D monitor, acceptance, dry-run plans | 🟢 | progress CSVs only |
| E overview / F diag / G–J | 🟡 | `output*/overview/`, `simulation/results/` |

Never run A, C, or K concurrently with each other. D–J are safe to run
while a fit is in progress (read-only on the fit root).
