# Per-Script Manual

This document is the per-script reference for the bias-robust Bayesian meta-analysis pipeline. It complements the high-level overview in [`../README.md`](../README.md), the input contract in [`../data_dictionary.md`](../data_dictionary.md), and the artifact catalog in [`../output_dictionary.md`](../output_dictionary.md). For each script it states the entry-point function(s), the inputs the script expects, the outputs it writes, and the assumptions a reuser should know about.

The seven scripts are numbered to be sourced in order. None of them takes command-line arguments; configuration is controlled by the `CONFIG` lists at the top of `20_robma_fit.R` and by named arguments to `build_overview()` (`60_overview.R`).

**Sourcing convention.** Every script is *define-only*: sourcing it installs functions and constants into the caller's environment but does not read or write anything on disk. Analysis is triggered by calling the entry-point function. This makes it safe to source the whole pipeline at the start of a session.

**Shared helpers.** A small set of utilities (`format_topic()`, `is_meta_basename()`, `.bf_evidence_transform()`, etc.) live in `00_utils.R` and are sourced idempotently by the downstream scripts via a sentinel guard, so loading them multiple times is a no-op.

---

## `00_utils.R` — Shared utilities

**Purpose.** Define helpers used by more than one downstream script and a load sentinel that lets later scripts source this file safely whether or not it has already been loaded.

**Inputs.** None.

**Outputs.** None on disk. Defines the following objects in the caller's environment:

- `%||%` — null-default operator (rlang-style, no rlang dependency).
- `format_topic(slug)` — convert a topic slug to a display label (e.g. `"vitamind"` → `"Vitamin D"`); vectorised, case-insensitive, with overrides for irregular slugs.
- `is_meta_basename(basename)` — TRUE for catalog/helper CSVs that should never be fitted (`*_original_effects`, `*_studies`, `*_excluded`).
- `.bf_evidence_transform(log10bf)` — piecewise-linear evidence-axis transform mapping signed log₁₀(BF) into equal-width evidence bins with a saturating terminal bin.
- `.bf_axis_spec(xlim_transformed)` — axis breaks and labels (`1/100`, `1/10`, `1/3`, `1`, `3`, `10`, `100`, `Inf`) for the transformed axis.
- `.compute_precision(df)` — derive a stabilised `prec` (1/SE) column from the bias-adjusted credible interval, falling back to the baseline RE interval; winsorised at the 10th/90th percentiles.
- `.robma_utils_loaded` — sentinel constant used by downstream scripts to skip re-sourcing.

**Sourced by.** `10_load_data.R`, `20_robma_fit.R`, `40_batch_fit.R`, `50_topic_analysis.R`, `60_overview.R`. (Not used by `30_robma_analysis.R`, which keeps its own small private helpers so it remains self-contained for one-off diagnostic use.)

---

## `10_load_data.R` — Discovery and loading

**Purpose.** Catalog the available analysis-ready CSVs and load selected ones into the calling environment.

**Inputs.** The `data/<topic>/<author>/<stem>.csv` tree as specified in `data_dictionary.md`. Files whose basename ends in `original_effects`, `studies`, or `excluded` are treated as helper / extraction-record files and are skipped (via `is_meta_basename()` from `00_utils.R`).

**Outputs.** None on disk. In R: a catalog data frame returned by `list_datasets()` and one data frame per loaded CSV bound into the calling environment by `load_datasets()`.

**Key entry points.**

- `list_datasets(root = "data", only_candidates = FALSE)` — returns a tibble with one row per discovered file, including topic, author, stem, and absolute path. With `only_candidates = TRUE`, meta files are excluded.
- `load_datasets(topic = NULL, author = NULL, file = NULL, envir = parent.frame())` — filter by any combination of these arguments and bind the matching CSVs into the caller's environment under the stem name.

**Assumptions.**

- The `<topic>/<author>/<stem>.csv` directory layout is the source of truth; nothing is registered manually.
- Author directories follow the `<lastname><year>` convention (e.g. `morton2018`, `saneei2014`).
- CSV schema is enforced downstream by `20_robma_fit.R`, not here.

---

## `20_robma_fit.R` — Core model fitting

**Purpose.** Fit two models on identical inputs: an unadjusted Bayesian random-effects baseline (NoBMA) and the RoBMA-PSMA bias-robust ensemble. Persist fitted objects, compute z-curve representations for diagnostics, and append a row to the per-topic summary CSV.

**Inputs.** A data frame with required columns `g` and `se_g` (see `data_dictionary.md` §3) and the `dataset_name` matching the stem of the CSV the data frame was loaded from.

**Outputs.** Under `output/<topic>/<author>/`:

- `fit_RE_<stem>.rds`, `fit_RoBMA_<stem>.rds` — fitted model objects (large; excluded from version control by default).
- `zcurve_RE_<stem>.rds`, `zcurve_RoBMA_<stem>.rds` — z-curve diagnostic objects (excluded by default).

Under `output/<topic>/`:

- `<topic>_robma_summary.csv` — appended-to with one row per fit, deduplicated by `basename` so re-fits replace prior rows.

In R, on success, `fit_robma_models()` also stamps `fit_RE_<basename>`, `fit_RoBMA_<basename>`, `zcurve_RE_<basename>`, and `zcurve_RoBMA_<basename>` into `.GlobalEnv`. This is a deliberate part of the interactive workflow — `30_robma_analysis.R` retrieves these by name.

**Key entry point.**

- `fit_robma_models(dataset, dataset_name = NULL)` — runs both fits and writes all of the above. If `dataset_name` is omitted, the deparsed name of `dataset` is used.

**Configuration.** The `CONFIG` list at the top of the script sets MCMC chains, post-burnin samples, seed, effect direction, effect-size measure, and `output_root`. `save_outputs` (default `TRUE`) gates whether `.rds` artifacts and the sidecar CSV are written. The defaults shipped with the repository are the values used to generate the manuscript figures.

**Assumptions.**

- `effect_direction = "positive"` requires that input effects be sign-aligned per `data_dictionary.md` §3.
- Datasets with fewer than 3 finite `(g, se_g)` rows are skipped with a warning.

---

## `30_robma_analysis.R` — Per-fit diagnostics

**Purpose.** Inspect a single fitted dataset interactively. Looks up the four objects (`fit_RE_<basename>`, `fit_RoBMA_<basename>`, `zcurve_RE_<basename>`, `zcurve_RoBMA_<basename>`) that `20_robma_fit.R` stamps into the global environment, prints concise console summaries, and (optionally) writes a posterior-predictive z-distribution PDF, a pre-publication-bias z-extrapolation PDF, and a captured-text console summary.

**Inputs.** The four `fit_*` / `zcurve_*` objects in the calling environment for the dataset of interest. These are produced by `fit_robma_models()` (or by re-loading the corresponding `.rds` artifacts).

**Outputs.** Under `output/<topic>/<authoryear>/`, when `write_files = TRUE` (default):

- `plots/<basename>_z_plot.pdf` — posterior-predictive z-distribution.
- `plots/<basename>_z_extrapolation.pdf` — pre-publication-bias extrapolation.
- `summary/<basename>_console.txt` — captured console summary.

When `write_files = FALSE`, only console output is produced; the plot-drawer closures are still returned in `$plots` for on-screen replay.

**Key entry point.**

- `analyze_robma_fit(basename, write_files = TRUE, output_root = "output", ...)` — see roxygen header in the script for the full argument list.

**Use.** Optional. Source after a fit completes when you want to look at one outcome closely. `40_batch_fit.R` and the topic/overview scripts do **not** depend on this file. Unlike the other downstream scripts, this one keeps its own small private helpers and does not source `00_utils.R`, so it remains self-contained for ad-hoc inspection use.

---

## `40_batch_fit.R` — Batch orchestration

**Purpose.** Run `fit_robma_models()` over a filtered set of datasets, with dry-run, resume, and optional parallel modes.

**Inputs.** Same as `20_robma_fit.R`, plus a `topic` / `author` / `file` filter applied to the catalog returned by `list_datasets()`. All MCMC and output settings are read from the `CONFIG` list defined in `20_robma_fit.R`; this script does not duplicate them.

**Outputs.** Whatever `20_robma_fit.R` writes for each dataset processed. Returns an in-memory list with two elements:

- `$summary` — compact counts (planned, run, skipped, failed).
- `$status` — one row per planned dataset with timing and any error messages.

Local batch logs (e.g. `batch_status_*.csv`) are excluded from version control.

**Key entry point.**

- `batch_fit(topic = NULL, author = NULL, file = NULL, resume = TRUE, dry_run = FALSE, parallel = FALSE)`.

**Assumptions.**

- `resume = TRUE` skips a dataset if all four of its `fit_*` / `zcurve_*` `.rds` artifacts already exist. To force a refit, delete the artifacts first.
- `parallel = TRUE` uses `parallel::mclapply` and is only available on POSIX systems.

---

## `50_topic_analysis.R` — Topic-level synthesis

**Purpose.** Produce the per-topic figures and update the per-topic accumulator summary.

**Inputs.** `output/<topic>/<topic>_robma_summary.csv` produced by `20_robma_fit.R`.

**Outputs.**

- `output/<topic>/plots/<topic>_bias_correction_comparison.pdf` — paired baseline-RE vs RoBMA-PSMA boxplot.
- `output/<topic>/plots/<topic>_forest_plot_comparison.pdf` — forest plot with both posterior credible intervals.
- `output/<topic>/plots/<topic>_orchard_combined.pdf` — three-panel orchard of log₁₀ Bayes factors (effect / heterogeneity / bias).
- `output/topic_summary.csv` — accumulated one row per topic with shrinkage, sign-flip, and evidence-threshold counts. Re-running a topic refreshes its row in place.

**Key entry point.**

- `build_topic_summary(topic = "protein")`.

**Command-line use.** A small `if (!interactive())` block at the bottom of the script lets it be invoked non-interactively for a single topic:

```sh
Rscript scripts/50_topic_analysis.R --topic Fiber
```

This is purely a convenience wrapper around `build_topic_summary()`; sourcing the script in an interactive session does not trigger it.

**Notes.** The figures are built from the summary CSV alone and require no fitted `.rds` objects.

---

## `60_overview.R` — Cross-topic aggregation

**Purpose.** Combine all per-topic summary CSVs into a unified outcome-level table and produce cross-topic figures and the supplement-ready dataset listing.

**Inputs.** Every `*_robma_summary.csv` discovered under `output/` (excluding `output/overview/` itself).

**Outputs.** Under `output/overview/` (or whatever `output_dir` is passed):

- `topic_summary.csv` — cross-topic evidence-bin summary (one row per topic plus an `Overall` row); schema is **distinct** from `output/topic_summary.csv` (see `output_dictionary.md` §3.1).
- `intervention_outcome_datasets.csv` and `intervention_outcome_datasets_table.tex` — supplement listing of every analyzed dataset.
- `orchard_effect.pdf`, `orchard_heterogeneity.pdf`, `orchard_bias.pdf` — outcome-level orchard plots faceted by topic.
- `violin_effect.pdf`, `violin_heterogeneity.pdf`, `violin_bias.pdf` — topic-level evidence distributions.
- `violin_stack_fullpage.pdf` (with optional `.png` companion) — manuscript-ready combined three-panel figure.
- `boxplot_combined_horizontal.pdf`, `boxplot_strip_single.pdf` — cross-topic shrinkage boxplots.
- `scatter_effect_vs_bias.pdf` — joint effect-vs-bias-adjustment evidence scatter.

**Key entry point.**

- `build_overview(output_dir = "output/overview", strip_ylim_override = c(-0.05, 0.7), horiz_xlim_override = NULL, verbose = TRUE)`.

Returns the key tables (`topic_summary`, `intervention_outcome_datasets`) invisibly. The `*_override` arguments hard-code the boxplot effect-size axis ranges; leaving them at their defaults reproduces the manuscript layout. Setting `verbose = FALSE` suppresses the per-step progress messages.

**Note on sourcing.** Sourcing the script with `source("scripts/60_overview.R")` only **defines** `build_overview()` and its helpers; it does not run the analysis. To produce the overview deliverables, call `build_overview()` explicitly. To make the script self-running (e.g. in a Makefile or CI), add `if (sys.nframe() == 0L) build_overview()` to the bottom — left commented out by default to keep `source()` purely declarative.

**Notes.** The script auto-discovers any directory containing a `*_robma_summary.csv`, so adding a new topic requires no edit here.

---

## Summary CSVs at a glance

There are **two** files named `topic_summary.csv` in different directories with **different schemas**:

| Path | Written by | Schema | One row per |
|------|-----------|--------|-------------|
| `output/topic_summary.csv` | `50_topic_analysis.R` | shrinkage / sign-flips / evidence-threshold counts | topic |
| `output/overview/topic_summary.csv` | `60_overview.R` | log₁₀ BF threshold counts and proportions, plus `\|μ_RE\| ≥ 0.2` joint signatures | topic + an `Overall` aggregated row |

Both are described in detail in `output_dictionary.md` (§2.3 and §3.1).

---

## Function naming reference

For anyone migrating from an earlier version of these scripts, the key entry-point names changed during the cleanup pass:

| Earlier name | Current name |
|---|---|
| `analyze_robma_min()` | `analyze_robma_fit()` |
| `topic_analysis()` | `build_topic_summary()` |
| (sourcing `60_overview.R` ran the build) | `build_overview()` (must be called explicitly) |

The CLI invocation `Rscript scripts/50_topic_analysis.R --topic <topic>` still works unchanged.
