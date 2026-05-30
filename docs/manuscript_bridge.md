# Manuscript Bridge — HISTORICAL / SUPERSEDED

> **Status: historical.** This file was last accurate before the 2026-05
> simulation refocus and Q3 terminology pass. It references RoBMA 3.6,
> the retired topic-world figure names (`orchard_*`, `violin_stack_fullpage`,
> `boxplot_strip_single`, `scatter_effect_vs_bias`), the 5,400-outcome
> (n_reps = 150) library tier, the legacy `synthetic_composition/` Q3
> folder, the placeholder treatment of the simulation section, and
> manuscript subtrees (`05_figures/`, `07_build/`, `BUILD_NOTES.md`) that
> no longer reflect the current `Rigor_Manuscript/` layout. The current
> manuscript ships RoBMA 4.0, the v4 `corpus_*` figure set, the
> 18,000-outcome (n_reps = 500) library, the `empirical_weighted_synthetic/`
> Q3 folder, and a worked Section 4 simulation/resampling characterization.
>
> **For current manuscript ↔ artifact alignment, see:**
>
> - [`docs/output_contract.md`](output_contract.md) — sidecar / registry / figure contract.
> - [`docs/pipeline_layout.md`](pipeline_layout.md) — repository tree and one-scheme-per-output-root rule.
> - [`docs/visuals.md`](visuals.md) — current figure family by axis and consumer.
> - `Rigor_Manuscript/docs/supplement_artifact_inventory.md` — what is pinned vs repository-only.
> - `Rigor_Manuscript/docs/simulation_artifacts.md` — pinned Section 4 / supplement simulation artifacts.
> - `simulation/README.md` — Q1/Q2/Q3 runners and outputs.
>
> The remainder of this file is kept for provenance; do not treat any
> claim below as current release documentation.

---

## Historical content (pre-2026-05; do not act on)

Maps the manuscript to the pipeline artifacts that support it. **Not a
rewrite plan.** The manuscript is `Rigor_Manuscript/` (pdfLaTeX; see
`Rigor_Manuscript/BUILD_NOTES.md`):
`01_main/main.tex`, `02_supplement/supplement.tex`,
`03_exec_summary/exec_summary.tex`; figures resolved from
`05_figures/{global,<domain>}/` via `04_shared/graphics_paths.tex`.

Status legend: **ready** (artifact exists, current, manuscript-grade) ·
**diagnostic-only** (exists but full36 × 25 tier, not
operating-characteristic) · **needs-full150** (blocked on the 5,400
library) · **needs-interpretation** (artifact exists; prose/analysis not
yet written).

| Manuscript section / claim | Pipeline artifact | Table/figure candidate | Status | Notes |
|---|---|---|---|---|
| **Rigor definition** (abstract; §rigor-estimand: larger of effect-supporting/no-bias vs no-effect-supporting/no-bias branch BFs, het marginalized, direction retained) | `scripts/00_utils.R` (`.ESTIMAND_VERSION="rigor_selected_v1"`, `.rigor_category()`); `README.md` §rigor | prose only (definition) | **ready** | Manuscript notation matches `README.md` and the sidecar contract exactly (`log10BF_rigor` = max of the two branch BFs + `rigor_direction`). No conflict. |
| **Empirical nutrition stratum summaries** (8 domains, 175 outcomes; outcome-weighted) | `scripts/60_estimand_tables.R` → `output/overview/stratum_estimands.csv` / `_table.tex` | `stratum_estimands_table.tex` | **ready** | Corpus-level abstract numbers (11/175 = 6.3 %, 66/175 = 37.7 %, 75/174 = 43.1 %) derive from `outcome_registry.csv` + `corpus_estimands.csv`. |
| **Article-balanced summaries** (each source article 1/m within stratum) | `60_estimand_tables.R` → `output/overview/article_balanced_estimands.csv` / `_table.tex` | `article_balanced_estimands_table.tex` | **ready** | Companion to stratum summaries; same gate. |
| **Component evidence summaries** (effect/het/bias/no-bias inclusion BFs) | `60_estimand_tables.R` → `output/overview/component_evidence_summary.csv`; `70_corpus_visuals.R` component violins | `corpus_component_violin_{effect,heterogeneity,bias}.pdf`, `corpus_component_violin_stack.pdf` | **ready** (artifact) / **stale-path** (figure names) | ⚠ Manuscript `\includegraphics` uses legacy names (`orchard_bias.pdf`, `violin_stack_fullpage.pdf`, `boxplot_strip_single.pdf`, `scatter_effect_vs_bias.pdf`); the v4 pipeline now emits the renamed `corpus_component_violin_*` set (orchards are retired and archived only). The committed copies under `05_figures/` are the pinned old-naming generation — see manuscript-integration findings. |
| **Per-domain case studies / z-curve diagnostics** (Creatine, Protein flagship; others in supplement) | `20_robma_fit.R` zplot `.rds` → `30_zplot.R`; `50_stratum_visuals.R` | `<id>_z_plot.pdf`, `<scope>_effect_estimate_comparison.pdf`, `_effect_forest.pdf`, `_component_violin_stack.pdf`, `_rigor_ranking.pdf` | **ready** (artifact) / **stale-path** (figure names) | Active `50` now emits these renamed figures (legacy names: `_bias_correction_comparison` / `_forest_plot_comparison` / `_component_orchard` / `_rigor_outcome_ranking`). BUILD_NOTES "Flagship Topic Selection" uses legacy *topic* wording (`supp:topic-*`); prose uses v4 *stratum/domain*. |
| **Simulation section** (§simulation — "placeholder for planned simulation-based validation") | current full36 library (size set by `sim_generate_library(n_reps=...)`) + Q3 empirical-weighted synthetic sampling / agreement / visuals outputs | (none placed yet) | **needs-interpretation** | Manuscript explicitly carries a *placeholder*; abstract says "ongoing simulation work, indicated by a placeholder". Manuscript-grade validation depends on the per-cell library size in the current run (see each output CSV's `n_fit` / `library_status` columns). |
| **Simulation cell diagnostics** | `55_sim_cell_diagnostics.R` → `simulation/results/cell_diagnostics_{rigor,component}.csv` | candidate supplement table | **diagnostic-only at small reps/cell; precision improves with library size** | All 36 cells; each row carries `n_generated` and `n_fit` (per-cell sample-size context) plus the metric estimates + MCSEs. Library-wide completeness lives in `fit_progress_*.csv`. |
| **Empirical-weighted synthetic sampling** (Q3) | `65_synthetic_resampling.R` → `simulation/results/empirical_weighted_synthetic/` (primaries + `detail/`) including `empirical_weighted_synthetic_report.md`, `empirical_stratum_cell_weights.csv`, `empirical_weighted_synthetic_{stratum,corpus}_draws.csv`, `composition_validation_checks.csv` | candidate supplement table/figure | **diagnostic-only** | Gated on a clean generated+fitted library via `sim_inventory_library()` (per-cell target = `n_generated`). Recovery rate is in the on-disk CSVs. Folder renamed from `synthetic_composition/` in 2026-05. |
| **Empirical-vs-empirical-weighted-synthetic agreement** | `70_empirical_synthetic_agreement.R` → `simulation/results/agreement/empirical_vs_synthetic_{stratum,corpus}_agreement.csv` | agreement interval figure (J) | **diagnostic-only** → **needs-full150** | Primary-rigor + component metrics; interval-overlap flags. Operating-characteristic claims require 150/cell. |
| **Q3 visuals** | `75_analysis_visuals.R::sim_run_q3_visuals()` (via `sim_run_all_analysis_visuals()`) → `simulation/results/figures/empirical_weighted_synthetic/*.pdf` + `empirical_weighted_synthetic_visuals_report.md` | empirical fitted-cell mixture map + Q3 variability + empirical-bootstrap-vs-empirical-weighted-synthetic overlay + axis-recovery diagnostics | **diagnostic-only** | Vector PDFs + short report + deferred-family ledger. Reads Q3 primaries / detail / agreement from their stable dirs; never recomputes upstream. 75 renamed from `75_composition_visuals.R` in 2026-05. |
| **Future full36 × 150 results** | not yet produced | operating-characteristic tables/figures | **needs-full150** | The 5,400 tier replaces every diagnostic-only row above with manuscript-precision evidence. Runbook §K. |

## Manuscript-integration findings (report only — do not rewrite)

1. **Manuscript dir**: `Rigor_Manuscript/` (not `manuscript/`).
   `docs/pipeline_layout.md` lists an optional `manuscript/` — the real
   tree is `Rigor_Manuscript/{01_main,02_supplement,03_exec_summary,
   04_shared,05_figures,06_refs,07_build}`. Build: pdfLaTeX
   (`pdflatex → bibtex → pdflatex ×2`), `06_refs/master.bib`.
2. **Build system**: clearly pdfLaTeX per `BUILD_NOTES.md`; no
   XeLaTeX/LuaLaTeX. `07_build/` is empty (no automated build script).
3. **Referenced figures exist** under `05_figures/` (`global/` +
   per-domain), so the manuscript compiles. But the **filenames are the
   legacy RoBMA-3.6 / topic-world names** (`boxplot_strip_single.pdf`,
   `violin_stack_fullpage.pdf`, `orchard_{effect,heterogeneity,bias}.pdf`,
   `scatter_effect_vs_bias.pdf`, `boxplot_combined_horizontal.pdf`) — the
   active `70_corpus_visuals.R` now writes the renamed `corpus_`-prefixed
   set (`corpus_component_violin_stack.pdf`,
   `corpus_component_violin_bias.pdf`, `corpus_effect_attenuation_strip.pdf`,
   `corpus_rigor_violin_by_stratum.pdf`, …; orchards are retired and
   archived only). The committed `05_figures/`
   PDFs are a *pinned snapshot from the old naming generation*; they are
   not auto-overwritten by a v4 rebuild. **Figure paths are therefore
   stale relative to the current pipeline** — a future manuscript
   revision must re-export the `corpus_*` figures into `05_figures/` (or
   add a copy step). Not fixed here (no manuscript rewrite).
4. **Terminology**: manuscript *prose* is v4-aligned ("nutrition-domain
   strata", "stratification scheme", "rigor Bayes factor", "rigor
   direction"). Residual legacy *topic* vocabulary survives only in the
   LaTeX **label namespace** (`\ref{supp:topic-*}`) and
   `BUILD_NOTES.md` ("Flagship Topic Selection"). Cosmetic /
   non-blocking; flagged for the revision pass, not changed now.
5. **Rigor notation matches `README.md`** (max of two
   pre-specified no-bias branch BFs, heterogeneity marginalized,
   direction retained). No estimand conflict.
6. **Simulation is a declared placeholder** — no simulation artifact is
   wired into the manuscript yet; this is intentional. Whether and when
   to surface a synthetic figure depends on the per-cell library size of
   the next generation/fit cycle (see each result CSV's `n_fit` and
   `library_status` columns).
