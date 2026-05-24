# Diagnostic Interpretation Guide

How to read every major diagnostic table/figure: what it is for, its
input, its output, what "good" looks like, what is concerning, and
whether it is **diagnostic-only** or **manuscript/supplement-facing**.

For axis conventions see `docs/visuals.md`; for the file contract see
`docs/output_contract.md`.

---

## Empirical pipeline figures

### z-plots — `<id>_z_plot.pdf`, `<id>_z_extrapolation.pdf`
- **Purpose**: per-dataset publication-selection / small-study diagnostic (observed vs RoBMA-extrapolated z-distribution).
- **Input**: saved `zplot_RoBMA4_<id>.rds` / `zplot_RE4_<id>.rds` (written by `20_robma_fit.R`); rendered by `30_zplot.R`.
- **Output**: `output/<stratum>/<source_article>/plots/`.
- **Good**: observed z-density tracks the model extrapolation; no gross discontinuity at the significance threshold.
- **Concerning**: sharp pile-up just above |z|≈1.96 with a hole below it (selection signature); extreme extrapolation divergence.
- **Facing**: manuscript/supplement (flagship case studies, e.g. Creatine/Lanhers2017, Protein/Nunes2022).

### Component violins — `corpus_component_violin_{effect,heterogeneity,bias}.pdf`, `corpus_component_violin_stack.pdf`
- **Purpose**: corpus distribution of effect/heterogeneity/bias inclusion BFs on a **raw `log₁₀(BF)` axis, display-capped at ±2** (the stack is the horizontal three-component view; `50` writes a stratum-scoped `<scope>_component_violin_stack.pdf`).
- **Input**: `output/overview/outcome_registry.csv`; `70_corpus_visuals.R` (stratum: `50_stratum_visuals.R`).
- **Output**: `output/overview/` (stratum: `output/<stratum>/plots/`).
- **Good**: interpretable spread across the raw-log10 evidence bands; bias-component mass consistent with the corpus narrative.
- **Concerning**: all mass collapsed at one cap with no finite spread (data issue, not display) — remember mass at `±2` means "at least this strong" (incl. `±Inf`), **not** raw `= ±2`; check `outcome_registry.csv` / `60` tables (or `$diagnostics` `capped_*`/`pos_inf_n`/`neg_inf_n`) for exact extremity. No overflow rail / `±Inf` count label.
- **Retired orchard**: the old evidence-axis `corpus_orchard_*.pdf` / `<scope>_component_orchard.pdf` is retired and not part of the active visual pipeline (archived only; never produced by a default run).
- **Facing**: manuscript.

### Attenuation boxplots / scatter — `corpus_boxplot_attenuation_{horizontal,strip}.pdf`, `corpus_attenuation_vs_rigor.pdf`, `corpus_bias_vs_rigor.pdf`
- **Purpose**: shrinkage of |μ| from baseline-RE to RoBMA-PSMA; joint bias-vs-rigor structure.
- **Input**: `output/overview/outcome_registry.csv`; `70_corpus_visuals.R`.
- **Output**: `output/overview/`.
- **Good**: coherent attenuation gradient; conventionally-nontrivial baselines shrinking under joint modeling (the corpus story).
- **Concerning**: implausible negative attenuation everywhere; sign flips uncorrelated with bias evidence.
- **Facing**: manuscript (`bias_vs_rigor` is QC/supplement, off by default).

### Rigor figures — `corpus_rigor_violin_by_stratum.pdf`, `corpus_rigor_ranking_extremes.pdf`, `corpus_rigor_{direction,category}_composition.pdf`, `corpus_rigor_branch_scatter.pdf` (stratum: `<scope>_rigor_ranking.pdf`)
- **Purpose**: headline estimand — distribution and direction/category composition of `log10BF_rigor`.
- **Input**: `outcome_registry.csv` + `rigor_{direction,category}_summary.csv`.
- **Output**: `output/overview/`.
- **Good**: rigor BF on raw `log₁₀(BF_rigor)` axis with shared bands; direction always shown with the selected value.
- **Reading the cap**: violins are **display-capped at `|log₁₀(BF)| = 2`** (a `≤ -2` / `≥ 2` tick marks it). Capped mass means "at least this strong on the displayed log10BF scale" — *not* that the raw value equals exactly ±2; check `outcome_registry.csv` / `60`'s tables (or the `$diagnostics` `capped_*`/`pos_inf_n`/`neg_inf_n` fields) when exact extremity matters. There is no overflow rail/gutter and no `±Inf` count label.
- **Concerning**: rigor reported without direction; category proportions not summing within stratum.
- **Facing**: manuscript (flagship rigor figure).

---

## Simulation cell diagnostics (table)

### `cell_diagnostics_{rigor,component}.csv`
- **Purpose**: per-design-cell recovery of rigor & component evidence across all 36 DGM cells.
- **Input**: `output_sim_v30/<stratum>/*_robma_summary.csv` via `55_sim_cell_diagnostics.R`.
- **Output**: `simulation/results/` (stable filenames; no replicate-count or tier suffix).
- **Good**: every cell `n_fit == n_generated` (library is fully fitted; cross-check via `fit_progress_overall.csv`); medians ordered monotonically with the designed effect/het/bias gradient; MCSE reported.
- **Concerning**: cells with `n_fit = 0`; non-monotone recovery against the design ladder; large MCSE on direction/category proportions.
- **Facing**: each row carries `n_generated` (the cell's library size) and `n_fit` (how many were used), the per-cell sample-size context for every metric. Library-wide completeness lives in `fit_progress_{live,overall}.csv`. Operating-characteristic claims require enough fitted replicates per cell to give acceptable MCSE.

---

## Q3 figures — `simulation/results/figures/empirical_weighted_synthetic/`

### Empirical fitted-cell mixture map — `empirical_stratum_cell_weights_heatmap.pdf`
- **Purpose**: where each empirical nutrition stratum sits on the 36-cell observed/fitted grid (the corpus-blended empirical-weighted sampling weights that 65 draws synthetic rows under).
- **Input**: `empirical_weighted_synthetic/empirical_stratum_cell_weights.csv` (fill = `smoothed_weight`).
- **Good**: plausible concentration (dominant cell outlined) consistent with the empirical narrative (e.g. clean/null mass); weights sum to 1 per stratum.
- **Concerning**: uniform smear (no signal) or a single cell at ~1.0 with no support; `n_unassigned` large.
- **Facing**: Q3 input map (supplement candidate at full150).

### Axis transition heatmaps — `synthetic_axis_transition_{effect,het,bias}_heatmap.pdf`
- **Purpose**: P(observed band | target/DGM band) for each design axis — profile-definition diagnostic that justifies the fitted-cell assignment basis used in Q3 empirical-weighted synthetic sampling.
- **Input**: `empirical_weighted_synthetic/detail/synthetic_axis_transition.csv`.
- **Good**: strong diagonal per axis; monotone smear into neighboring bands; row sums = 1.
- **Concerning**: a band that never recovers itself; mass jumping to a non-adjacent band.
- **Facing**: profile-definition diagnostic → supplement at full150.

### Q3 rigor variability — `empirical_weighted_synthetic_rigor_variability_by_stratum.pdf`
- **Purpose**: sampling variability (width90 = q95 - q05) of the stratum-level median selected rigor across B empirical-weighted synthetic draws, by `n_outcomes_target`. One line per empirical stratum.
- **Input**: `empirical_weighted_synthetic/empirical_weighted_synthetic_size_curve_summary.csv`.
- **Good**: width90 decreases as `n_outcomes` grows; ordering across strata is interpretable.
- **Concerning**: width90 flat or increasing as n grows (signals a thin pool or unstable estimand).
- **Facing**: Q3 primary; precision improves with the per-cell library size in the input CSV.

### Empirical bootstrap vs empirical-weighted-synthetic overlay — `empirical_bootstrap_vs_empirical_weighted_synthetic_core_metrics.pdf`
- **Purpose**: forest/range plot per (stratum, core metric) contrasting the empirical bootstrap q05-q95 with the empirical-weighted synthetic q05-q95 at each stratum's observed `n_outcomes`. Core metrics = `median_log10BF_rigor`, `median_rigor_margin`, `median_log10BF_bias`, `median_attenuation_abs`. Directional/thresholded `p_*` rate metrics are deliberately excluded.
- **Input**: `empirical_resampling/empirical_resampling_observed_size_intervals.csv` + `empirical_weighted_synthetic/empirical_weighted_synthetic_size_curve_summary.csv`.
- **Good**: empirical bootstrap (blue) overlaps the empirical-weighted synthetic band (purple); systematic discrepancies have a plausible DGM explanation.
- **Concerning**: many strata where empirical bootstrap sits well outside the empirical-weighted synthetic band (workflow not reproducing observed audit-component values).
- **Facing**: Q3 bridge primary.

### Validation / support coverage — text in `empirical_weighted_synthetic_visuals_report.md`
- **Purpose**: PASS / INFO / WARN / FAIL counts from `composition_validation_checks.csv`, and per-pool-basis empty/sparse/supported cell counts from `detail/synthetic_support_diagnostics.csv`.
- **Good**: all PASS + INFO, **0 FAIL**; target basis 0 empty / 0 sparse; observed basis few sparse.
- **Concerning**: any FAIL (weights not summing to 1, empirical/synthetic mixing, transition rows not normalized, provenance not renormalized) or sparse / empty target cells.
- **Facing**: diagnostic-only (auditability gate; must be clean before trusting any other Q3 figure). Reported as text inside the Q3 visuals report; the standalone validation-status / support-bars PDFs were retired in the 2026-05 Q3 cull.

---

## How to use this guide

1. Always confirm `composition_validation_status` is **0 FAIL** before
   reading any other composition / agreement figure.
2. Confirm `synthetic_support_diagnostics` shows no empty target cells —
   otherwise transition/agreement figures rest on thin pools.
3. At small per-cell library sizes read **direction and structure, not
   precision** — composition/agreement figures' precision improves with
   the per-cell library size reported in their input CSVs.
4. Empirical-side figures (z-plots, component violins, attenuation,
   rigor violin/ranking) are the manuscript-facing layer and are
   not subject to the per-cell-library-size caveat.
