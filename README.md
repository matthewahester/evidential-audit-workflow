# Evidential Audit Workflow (RoBMA-PSMA, RoBMA 4.0)

A reproducible R workflow for **corpus-scale evidential auditing of
meta-analytic datasets** using Robust Bayesian Meta-Analysis with
Publication-Selection Model Averaging (RoBMA-PSMA, RoBMA 4.0). The
pipeline takes study-level effect sizes and standard errors, fits a
matched Bayesian random-effects baseline and a bias-aware model-averaged
ensemble for each outcome, and reports paired posterior summaries,
component inclusion Bayes factors (effect / heterogeneity / modeled
bias), a joint model-family **selected rigor Bayes factor** with its
selected branch (effect-supporting or no-effect-supporting), and
stratum/corpus summaries under any declared grouping scheme.

## Associated manuscript

This is the **public companion repository** for the manuscript:

> *Quantifying Evidential Rigor in Meta-Analytic Corpora: A
> Simulation-Characterized, Bias-Robust Bayesian Workflow with a
> Nutrition Case Study.* Matt Hester, University of Arkansas at Little
> Rock.

A purposive corpus of 175 reconstructed nutrition intervention
meta-analyses across 8 intervention strata is the **worked example**;
the workflow, the rigor estimand, and the simulation/resampling
characterization are general and apply to any literature whose primary
studies can be reduced to standardized effect sizes and standard errors.

The full formal definition of the rigor estimand, the ADEMP-framed
simulation/resampling design, the nutrition case study, and the
discussion of portability live in the manuscript and its supplement.
This repository provides the executable workflow needed to inspect,
reproduce, and adapt the audit.

## What is included

- **Empirical inputs** (`data/<stratum>/<source_article>/`):
  analysis-ready study-level CSVs (one row per primary study, with
  Hedges' *g* and `se_g`) plus the extraction workbooks (`.xlsx`) that
  document how each value was derived from the source meta-analysis.
- **Per-stratum sidecars** (`output/<stratum>/<stratum>_robma_summary.csv`,
  `_zplot_diagnostics.csv`) — the canonical fitted-output records, one
  row per outcome.
- **Outcome registry and reporting tables**
  (`output/overview/outcome_registry.csv` + per-stratum,
  article-balanced, corpus, rigor-direction, rigor-category, and
  component-evidence summary CSVs / LaTeX fragments).
- **Per-source audit artifacts and z-plot PDFs**
  (`output/<stratum>/<source_article>/audit/`, `.../plots/`).
- **Corpus, stratum, and source figures** under `output/overview/` and
  `output/<stratum>/plots/`.
- **Simulation source, design grid, and runbooks** (`simulation/scripts/`,
  `simulation/config/design_v3_full36.csv`,
  `simulation/README.md`,
  `simulation/design_memo.md`). The publication-tier Q1/Q2/Q3 settings
  (`n_fit = 500` per cell, `B = 15000`; Q3 uses support-masked shrinkage
  weighting with code label `eb_corpus`, `kappa = 4`, `support = occupied`,
  `pool_key = target`) are documented in those files and reproducible
  from the included scripts and configuration.
- **Documentation set** under `docs/` (data dictionary, output
  contract, pipeline layout, runbook, visuals contract, diagnostic
  interpretation guide, environment record, release checklist, commit
  policy, script index).
- **Citation, license, and contact metadata** (`CITATION.cff`,
  `LICENSE`, `LICENSE-data`, `references/`).

## What is omitted

The committed empirical sidecars + reporting tables are sufficient to
regenerate every empirical manuscript table and figure without
rerunning MCMC. The simulation side ships the **machinery and
configuration** to regenerate the simulation outputs locally; the
generated simulation datasets and result trees themselves are
intentionally not committed to GitHub:

- All fitted RoBMA / RE model objects (`*.rds`, several CPU-hours each).
- The full `output_sim_v30/` simulation fit tree (~54 GB; 36 cells × 500
  fits each plus per-rep audit CSVs).
- The full `simulation/results/` tree (small summary CSVs, `*_report.md`
  files, and final-tier figures, *plus* the multi-GB raw resampling /
  sampling draw CSVs). Regenerable end-to-end from
  `simulation/scripts/` + `simulation/config/design_v3_full36.csv` +
  the recorded R / JAGS environment (see
  [`docs/environment.md`](docs/environment.md)).
- The 18,000 synthetic input CSVs under `data/sim_<cell_slug>/` and the
  18,000 latent provenance files under `simulation/latent/`.
  Regenerable from the same scripts and design grid; latent files have
  no active reader.
- The `archive/RoBMA_3_6/` legacy snapshot (a prior-pipeline
  preservation, not required for any active step).

The manuscript and supplement contain the reported displays; this
repository provides the executable machinery and runbooks needed to
regenerate them. See
[`docs/output_commit_policy.md`](docs/output_commit_policy.md) for the
full commit policy and
[`docs/release_checklist.md`](docs/release_checklist.md) for the
v1.0.0 packaging rules.

## Quick inspection guide

| Looking for | Path |
|---|---|
| Empirical study-level inputs | [`data/<stratum>/<source_article>/`](data/) |
| Per-stratum fitted-output records | [`output/<stratum>/<stratum>_robma_summary.csv`](output/) |
| Canonical outcome registry | [`output/overview/outcome_registry.csv`](output/overview/) |
| Manuscript-ready summary tables | `output/overview/*_estimands_table.tex`, `*_summary*.csv` |
| Corpus and stratum figures | `output/overview/corpus_*.pdf`, `output/<stratum>/plots/` |
| Simulation source, design, and runbooks | [`simulation/scripts/`](simulation/scripts/), [`simulation/config/`](simulation/config/), [`simulation/README.md`](simulation/README.md), [`simulation/design_memo.md`](simulation/design_memo.md) |
| Reported simulation displays | manuscript and supplement (PDF) — generated locally by re-running the simulation layer |
| Field-by-field schema | [`docs/data_dictionary.md`](docs/data_dictionary.md), [`docs/output_contract.md`](docs/output_contract.md) |
| Operational run order | [`docs/runbook.md`](docs/runbook.md) |
| Adapting to a new corpus | [`docs/pipeline_layout.md`](docs/pipeline_layout.md) |

## Reproduction guide

**Cheap empirical rebuilds (seconds to minutes; no MCMC).** From the
committed empirical sidecars, regenerate every empirical
manuscript-facing table and figure without rerunning model fits:

```r
source("scripts/00_utils.R")
source("scripts/60_estimand_tables.R"); build_estimand_tables()
source("scripts/30_zplot.R");           build_zplots(stratum = "fiber")
source("scripts/50_stratum_visuals.R"); build_stratum_visuals(stratum = "fiber")
source("scripts/70_corpus_visuals.R");  build_corpus_visuals()
```

**Regenerating the simulation/resampling layer (heavy; MCMC).** The
public repo ships the simulation scripts, design grid, and runbooks
but not the generated datasets, fitted simulation library, or result
trees. To reproduce the simulation displays locally, regenerate the
library, fit it, and then run the resampling and visuals layers:

```r
# Phase A — generate synthetic library (writes data/sim_*/sim2026/*.csv
# and simulation/latent/...; both regenerable from the design grid):
source("simulation/scripts/40_sim_run.R")
sim_generate_library(n_reps = 500)

# Phase B — fit the synthetic library (HEAVY MCMC; hours to days):
sim_fit_library()

# Phase C — Q1/Q3 resampling/sampling layer (also rebuilds the
# simulation overview registry by default; see runbook §H/§I):
source("simulation/scripts/60_empirical_resampling.R")
emp_run_resampling(B = 15000, n_grid = c(5:30, 35, 40, 50))

source("simulation/scripts/65_synthetic_resampling.R")
sim_run_synthetic_resampling(
  B = 15000, n_grid = c(5:30, 35, 40, 50),
  pool_key = "target", smoothing = "eb_corpus",
  kappa = 4, support = "occupied")

source("simulation/scripts/70_empirical_synthetic_agreement.R")
sim_run_empirical_synthetic_agreement()

# Phase D — visuals (CSV → PDF; no MCMC):
source("simulation/scripts/75_analysis_visuals.R")
sim_run_all_analysis_visuals()
```

Full phase-by-phase commands, the readiness gate, parallelism
settings, and B/n_reps tier table are in
[`docs/runbook.md`](docs/runbook.md) and
[`simulation/README.md`](simulation/README.md).

> **Do not casually rerun MCMC.** A full nutrition empirical refit is
> several CPU-hours; a full 18,000-outcome simulation
> regenerate+fit+resample is on the order of days on a typical
> workstation. The committed empirical sidecars carry every primitive
> needed for empirical reporting; the simulation displays in the
> manuscript and supplement are reproducible from the included
> simulation scripts and configuration.

**Environment.** R (≥ 4.2 recommended), JAGS (≥ 4.3.1), RoBMA 4.0,
BayesTools 0.3.0. Verified versions and the fixed MCMC seed are in
[`docs/environment.md`](docs/environment.md). `renv` is intentionally
inactive during development; reproduction uses the plain user library
against the pinned package versions.

## Adapting the workflow to a new corpus

The workflow is not specific to nutrition. To apply it to another
literature (a journal window, a funder portfolio, an intervention
class, a prospective evidence stream):

1. **Standardize each outcome to the input contract**: one CSV per
   reconstructed outcome with `g` and `se_g` (sign-aligned so positive
   is the intervention-favored direction). The full input-side
   specification is in [`docs/data_dictionary.md`](docs/data_dictionary.md).
2. **Use a separate output root** (one scheme/corpus per output root —
   do not nest a new corpus inside the nutrition `output/` tree). The
   physical-organization rule and the per-stage argument-name table are
   in [`docs/pipeline_layout.md`](docs/pipeline_layout.md).
3. **Run the fitting layer** (`00 → 10 → 20 → 40`), then
   `sidecar_acceptance()`, then the reporting layer (`60`) and the
   visual layer (`50` / `70`).
4. **Reuse the rigor estimand and the sidecar/output contract**
   unchanged. The schema and estimand contract is a single versioned R
   object in [`scripts/00_utils.R`](scripts/00_utils.R)
   (`.SCHEMA_VERSION`, `.ESTIMAND_VERSION`); the file-by-file output
   contract is in [`docs/output_contract.md`](docs/output_contract.md).

The simulation/resampling sub-project under `simulation/` reuses the
same estimand/schema layer and writes to its own output root; it is the
template for any future synthetic-library evaluation of the workflow.

## Documentation index

- [`docs/data_dictionary.md`](docs/data_dictionary.md) — input CSV contract, identity fields, `_excl` variant policy.
- [`docs/output_contract.md`](docs/output_contract.md) — every output artifact, what writes it, and whether it is source-controlled.
- [`docs/pipeline_layout.md`](docs/pipeline_layout.md) — repository tree, one-scheme-per-output-root rule, per-stage argument-name table.
- [`docs/runbook.md`](docs/runbook.md) — canonical run order (Phases A–K).
- [`docs/visuals.md`](docs/visuals.md) and [`docs/visual_color_contract.md`](docs/visual_color_contract.md) — visual contract.
- [`docs/diagnostic_interpretation_guide.md`](docs/diagnostic_interpretation_guide.md) — how to read every major figure.
- [`docs/environment.md`](docs/environment.md) — reproducibility record (R, JAGS, package versions, MCMC seed).
- [`docs/release_checklist.md`](docs/release_checklist.md) — pre-release pre-flight.
- [`docs/output_commit_policy.md`](docs/output_commit_policy.md) — what ships, what stays local, what is force-added at freeze.
- [`docs/script_index.md`](docs/script_index.md) — script inventory and entry points.
- [`simulation/README.md`](simulation/README.md) — simulation/resampling sub-project runbook.
- [`simulation/design_memo.md`](simulation/design_memo.md) — ADEMP design memo.

## Citation

If you use this pipeline, please cite both the repository and the
associated manuscript. Structured metadata is in
[`CITATION.cff`](CITATION.cff).

- **Repository (archived release):** Hester, M. (2026). *Evidential
  Audit Workflow (RoBMA-PSMA, RoBMA 4.0)*, v1.0.0.
  DOI: [10.5281/zenodo.20467258](https://doi.org/10.5281/zenodo.20467258).
  An archived snapshot of v1.0.0 is available on Zenodo at
  <https://doi.org/10.5281/zenodo.20467258>. The live development
  repository is at
  <https://github.com/matthewahester/evidential-audit-workflow>.
- **Manuscript:** Hester, M. *Quantifying Evidential Rigor in
  Meta-Analytic Corpora: A Simulation-Characterized, Bias-Robust
  Bayesian Workflow with a Nutrition Case Study.* Manuscript DOI and
  journal will be added after acceptance.

## License

- **Code.** Source under `scripts/` and `simulation/scripts/` is
  released under the **MIT License** ([`LICENSE`](LICENSE)).
- **Data, derived summary tables, and figures.** Analysis-ready
  datasets, extraction workbooks, derived summary tables, and figures
  (under `data/`, `output/`, and the equivalent simulation-side
  subtrees) are released under **CC BY 4.0**
  ([`LICENSE-data`](LICENSE-data)). The exact file globs are listed in
  `LICENSE-data`; follow the attribution guidance in `CITATION.cff`.

## Contact

Please open a GitHub issue for bug reports, reproduction problems, or
questions about adapting the workflow to a new corpus. Substantive
methodological correspondence can be directed to the corresponding
author of the associated manuscript.
