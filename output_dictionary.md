# Output Dictionary

This document is the canonical reference for the **outputs** produced by the bias-robust Bayesian meta-analysis pipeline. It enumerates every artifact the pipeline writes, where it is written, which script writes it, and what role it plays in the workflow.

For the input-side schema (analysis-ready CSVs and the extraction workbooks they derive from), see [`data_dictionary.md`](data_dictionary.md).

The output system has three layers, each driven by a different script:

1. **Per-dataset** — fitted models and z-curve objects, written by `20_robma_fit.R` (or by `40_batch_fit.R` running the same routine).
2. **Per-topic** — comparative figures and a topic-level row of shrinkage / evidence metrics, written by `50_topic_analysis.R`.
3. **Cross-topic (overview)** — figures and summary tables that span all topics, written by `60_overview.R`.

> **Two files share the name `topic_summary.csv`.** They are different artifacts with different schemas:
>
> - `output/topic_summary.csv` — written by `50_topic_analysis.R`, accumulates one row per topic, focused on shrinkage and evidence-threshold counts.
> - `output/overview/topic_summary.csv` — written by `60_overview.R`, contains one row per topic plus an aggregated `Overall` row, focused on log₁₀ Bayes-factor threshold counts and proportions.
>
> Both are described in detail in §3 and §4 below.

---

## 1. Per-dataset artifacts

Written by `20_robma_fit.R` to `output/<topic>/<author>/`. Stems follow the analysis-ready CSV convention `<author><year>_<topic>_<outcome>` (with `_excl` appended for the minimally modified study sets used when the full reconstructed data produced a pathological RoBMA-PSMA fit; see [`data_dictionary.md`](data_dictionary.md)).

| File | Contents | Role |
|------|----------|------|
| `fit_RE_<stem>.rds` | Serialized fitted RoBMA object configured as an unadjusted Bayesian random-effects baseline (no bias-adjustment components). | Comparator on the same input scale and computational path as the bias-adjusted fit. |
| `fit_RoBMA_<stem>.rds` | Serialized fitted RoBMA-PSMA object: the full model-averaged ensemble across effect, heterogeneity, and bias-adjustment components. | Primary bias-robust fit; source of model-averaged posteriors and inclusion Bayes factors. |
| `zcurve_RE_<stem>.rds` | Z-curve representation of the baseline RE fit. | Diagnostic; consumed by `30_robma_analysis.R` for the posterior-predictive z-plot. |
| `zcurve_RoBMA_<stem>.rds` | Z-curve representation of the RoBMA-PSMA fit. | Diagnostic; same role on the bias-adjusted side. |

**Repository inclusion.** These `.rds` files are large and **may be omitted** from the public repository when the included data, configuration, and scripts are sufficient to reproduce the reported summaries and figures. They can be regenerated from the analysis-ready CSV and the `CONFIG` block in `20_robma_fit.R` (including its fixed seed) by running `40_batch_fit.R`, up to small numerical variation across `RoBMA` and JAGS releases. The `.gitignore` excludes them by default; force-add with `git add -f` if a specific fit needs to ship with the repo.

In addition, every successful fit appends a row to the per-topic summary CSV described in §2.

---

## 2. Per-topic artifacts

Written by `20_robma_fit.R` (the summary CSV) and `50_topic_analysis.R` (the figures and the per-topic row of `output/topic_summary.csv`). All paths under `output/<topic>/`.

### 2.1 `output/<topic>/<topic>_robma_summary.csv`

Written / appended-to by `20_robma_fit.R`. **One row per analyzed dataset.** This is the input to `50_topic_analysis.R` and to `60_overview.R`.

Each row records the identity of the dataset, posterior summaries from both models, inclusion Bayes factors for the three structural components, and run metadata. Confirmed columns referenced by downstream scripts include:

| Column | Description |
|--------|-------------|
| `author`, `effect`, `topic`, `basename`, `timestamp` | Identity and provenance metadata. |
| `mu_RE`, `mu_RE_lCI`, `mu_RE_uCI` | Posterior mean and 95% credible interval bounds for the overall effect under the unadjusted Bayesian random-effects baseline. |
| `mu_BC`, `mu_BC_lCI`, `mu_BC_uCI` | Posterior mean and 95% credible interval bounds for the overall effect under the RoBMA-PSMA bias-adjusted ensemble. (`BC` is retained as a column suffix for "bias-corrected".) |
| `eff_bf_BC`, `eff_bf_BC_numeric` | Inclusion Bayes factor for the effect component (RoBMA-PSMA). The `_numeric` variant is the numeric form used for thresholding; the unsuffixed form may include non-numeric encodings of extreme values. |
| `het_bf_BC`, `het_bf_BC_numeric` | Inclusion Bayes factor for between-study heterogeneity. |
| `bias_bf_BC`, `bias_bf_BC_numeric` | Inclusion Bayes factor for the bias-adjustment component. |
| `n_studies` | Number of studies in the dataset (when available). |

Additional columns may be present: MCMC configuration fields, output paths, optional diagnostic indicators (e.g., `ODR`, `EDR`, `Soric_FDR`, `MissingN`) when computed upstream, and other run metadata. The full column set is determined by `20_robma_fit.R`; consult that script for the authoritative list.

The CSV is deduplicated by `basename` on every append, so re-fitting a dataset replaces its previous row rather than producing duplicates.

### 2.2 `output/<topic>/plots/`

Written by `50_topic_analysis.R`. Three PDFs per topic.

| File | Contents |
|------|----------|
| `<topic>_bias_correction_comparison.pdf` | Paired boxplot of baseline RE vs. RoBMA-PSMA point estimates across all outcomes in the topic, with connecting lines for paired comparisons. |
| `<topic>_forest_plot_comparison.pdf` | Forest plot showing both baseline RE and RoBMA-PSMA estimates with their 95% credible intervals, one row per outcome (`_excl` variants flagged). |
| `<topic>_orchard_combined.pdf` | Three-panel orchard plot of log₁₀ Bayes factors for the effect, heterogeneity, and bias components, on a piecewise evidence-category x-axis with overflow handling for extreme values. |

### 2.3 `output/topic_summary.csv` (per-topic accumulator)

Written / updated by `50_topic_analysis.R`. **One row per topic**, accumulated across all topics analyzed so far. This file is *not* the cross-topic evidence summary; that file lives at `output/overview/topic_summary.csv` (see §3).

Confirmed columns include:

| Column | Description |
|--------|-------------|
| `topic` | Topic slug. |
| `n_outcomes` | Number of analyzed datasets for the topic. |
| `median_g_rel_change_pct` | Median percent change from `mu_RE` to `mu_BC` across outcomes. |
| `share_reduction_50pct` | Share of outcomes where `mu_BC` shrank by ≥ 50% relative to `mu_RE`. |
| `share_BC_CI_includes_zero` | Share of outcomes whose RoBMA-PSMA 95% credible interval includes zero. |
| `n_sign_flips` | Count of outcomes where `mu_RE` and `mu_BC` have opposite signs (and both are non-trivial). |
| `median_se_rel_change_pct` | Median percent change in posterior standard error from RE to BC. |
| `share_eff_BF_lt1`, `n_eff_BF_lt1` | Share / count of outcomes with effect Bayes factor < 1. |
| `share_eff_BF_gt3`, `n_eff_BF_gt3` | Moderate effect-favoring evidence threshold (BF > 3). |
| `share_eff_BF_gt10`, `n_eff_BF_gt10` | Strong effect-favoring evidence threshold (BF > 10). |
| `share_bias_BF_gt3`, `n_bias_BF_gt3`, `share_bias_BF_gt10`, `n_bias_BF_gt10` | Bias-adjustment evidence at moderate / strong thresholds. |
| `share_het_BF_gt3`, `n_het_BF_gt3`, `share_het_BF_gt10`, `n_het_BF_gt10` | Heterogeneity evidence at moderate / strong thresholds. |
| `n_offscale_log10_BF` | Count of outcomes where any of the three log₁₀ BFs has absolute value > 3. |
| `median_log10_BF_effect`, `q25_log10_BF_effect`, `q75_log10_BF_effect` | Distribution summary for log₁₀ effect BF. |
| `median_log10_BF_bias`, `median_log10_BF_heterogeneity` | Median log₁₀ BFs for the other two components. |
| `mean_ODR`, `mean_EDR`, `mean_Soric_FDR`, `mean_MissingN` | Optional means of upstream diagnostics, when those columns are present in the per-topic summary CSV. |

The file is rewritten on every call to `topic_analysis()`: the existing row for the current topic is removed and the new row is appended, so re-running a topic refreshes its summary in place without affecting other topics.

---

## 3. Cross-topic (overview) artifacts

Written by `60_overview.R` to `output/overview/`. The script auto-discovers every `*_robma_summary.csv` under `output/`, merges them into a unified outcome-level table, and produces the artifacts below.

### 3.1 `output/overview/topic_summary.csv` (cross-topic evidence-bin summary)

Schema is **disjoint from `output/topic_summary.csv`**. One row per topic plus an aggregated `Overall` row. Counts and proportions are computed on log₁₀ BF axes (denominators are finite values on each axis), with thresholds keyed to standard Bayes-factor evidence categories: `|log₁₀ BF| ≤ 0.5` ≈ inconclusive (BF in [1/3, 3]); `> 0.5` ≈ moderate (BF > 3); `> 1` ≈ strong (BF > 10).

| Column | Description |
|--------|-------------|
| `topic` | Topic display label, or `"Overall"` for the aggregated row. |
| `n_outcomes` | Number of outcomes contributing to the row. |
| `n_log10BF_effect_abs_le_0.5` / `prop_log10BF_effect_abs_le_0.5` | Count / proportion of outcomes with weak or inconclusive evidence for an effect component. |
| `n_log10BF_effect_gt_0.5` / `prop_log10BF_effect_gt_0.5` | At least moderate evidence favoring a nonzero effect. |
| `n_log10BF_effect_lt_m0.5` / `prop_log10BF_effect_lt_m0.5` | At least moderate evidence favoring a null-effect component. |
| `n_log10BF_effect_gt_1` / `prop_log10BF_effect_gt_1` | Strong evidence favoring a nonzero effect. |
| `n_log10BF_effect_lt_m1` / `prop_log10BF_effect_lt_m1` | Strong evidence favoring a null-effect component. |
| `n_log10BF_bias_gt_0.5` / `prop_log10BF_bias_gt_0.5` | At least moderate evidence for bias-adjustment components. |
| `n_log10BF_bias_gt_1` / `prop_log10BF_bias_gt_1` | Strong evidence for bias-adjustment components. |
| `n_log10BF_het_gt_0.5` / `prop_log10BF_het_gt_0.5` | At least moderate evidence for between-study heterogeneity. |
| `n_log10BF_het_gt_1` / `prop_log10BF_het_gt_1` | Strong evidence for heterogeneity. |
| `n_abs_muRE_ge_0.2` / `prop_abs_muRE_ge_0.2` | Count / share of outcomes whose baseline RE estimate has \|μ_RE\| ≥ 0.2 (the conventionally-meaningful magnitude anchor). |
| `prop_claimed_shrink50` | Within the \|μ_RE\| ≥ 0.2 subset, the share of outcomes where \|μ_BC\| ≤ 0.5 · \|μ_RE\| (≥ 50% shrinkage). |
| `prop_claimed_log10BF_effect_abs_le_0.5` | Within the \|μ_RE\| ≥ 0.2 subset, the share of outcomes whose effect evidence remains inconclusive. |
| `prop_sig_log10BF_bias_gt_0.5_and_log10BF_effect_abs_le_0.5` | Joint signature: share of outcomes with at least moderate bias-adjustment evidence *and* weak/inconclusive effect evidence. |

### 3.2 `output/overview/intervention_outcome_datasets.csv` and `…_table.tex`

Supplement-ready listing of every analyzed intervention–outcome dataset. One row per `(topic, meta-analysis, outcome)`. Foregrounds the Bayes-factor trio (effect, heterogeneity, bias) and the bias-adjusted effect estimate; the `.tex` companion is a LaTeX-formatted version of the same table. Full column list is determined by `60_overview.R`; consult that script if the supplement needs an exact schema.

### 3.3 Cross-topic figures

| File | Contents |
|------|----------|
| `orchard_effect.pdf` | Outcome-level orchard plot of log₁₀ effect BF, faceted by topic, with shared evidence-category x-axis. |
| `orchard_heterogeneity.pdf` | Same structure for log₁₀ heterogeneity BF. |
| `orchard_bias.pdf` | Same structure for log₁₀ bias-adjustment BF. |
| `violin_effect.pdf` | Topic-level violin distribution of log₁₀ effect BF, with median / IQR / 10–90% range overlays. |
| `violin_heterogeneity.pdf` | Same for heterogeneity BF. |
| `violin_bias.pdf` | Same for bias-adjustment BF. |
| `violin_stack_fullpage.pdf` | Manuscript-ready combined three-panel figure stacking the effect / heterogeneity / bias violins on a single page. |
| `violin_stack_fullpage.png` | Optional rasterized companion to the PDF (best-effort; may be absent if the PNG device is unavailable). |
| `boxplot_combined_horizontal.pdf` | Cross-topic shrinkage from baseline RE to RoBMA-PSMA, all topics on one panel. |
| `boxplot_strip_single.pdf` | Single-strip presentation of the same cross-topic shrinkage comparison. |
| `scatter_effect_vs_bias.pdf` | Joint scatter of log₁₀ BF<sub>effect</sub> against log₁₀ BF<sub>bias</sub>, with the "bias without robust effect" region shaded (\|log₁₀ BF<sub>effect</sub>\| ≤ 0.5 and log₁₀ BF<sub>bias</sub> > 0.5). |

---

## 4. Regeneration

Because every figure is built from a summary CSV rather than from session state, the figure layer can be regenerated without rerunning the underlying MCMC:

- Per-topic figures regenerate from `output/<topic>/<topic>_robma_summary.csv` via `topic_analysis(topic = "<topic>")`.
- Cross-topic figures and the overview summary regenerate from the per-topic summary CSVs via `source("scripts/60_overview.R")`.

If the `.rds` model objects are absent (the default for the public repository), the only step that requires recomputation is the per-dataset fit itself, which is invoked via `40_batch_fit.R` with `resume = TRUE`.
