# Bias-Robust Bayesian Meta-Analysis Pipeline (RoBMA 4.0)

A reproducible R workflow for **bias-aware Bayesian evidence auditing of
meta-analytic datasets** using Robust Bayesian Meta-Analysis with
Publication-Selection Model Averaging (**RoBMA-PSMA**). The pipeline takes
study-level effect sizes and standard errors as input and returns
model-averaged posterior summaries, inclusion Bayes factors for the effect /
heterogeneity / bias-adjustment components, exact joint μ×ω model-family
probabilities, a branch-selected **rigor Bayes factor**, diagnostics, and
scheme/stratum-level summaries.

The repository accompanies a methods-focused evidential audit applied to
**published nutrition intervention meta-analyses** (≈175 outcomes across 8
domains). The nutrition corpus is the worked example; the workflow itself is
intended for any literature whose primary studies can be reduced to
standardized effect sizes and standard errors.

This is the **active RoBMA 4.0 rigor pipeline**. RoBMA 4.0's
product-space model representation supports exact extraction of
branch-specific rigor Bayes factors from individual model prior/posterior
probabilities. The completed RoBMA 3.6 analysis and its simulation/resampling
artifacts are retired and live under `archive/RoBMA_3_6/`; they are not used
by any active script and require the archived lockfile to reproduce.

## Vocabulary

The pipeline uses one identity vocabulary end to end (there is no `topic=`
argument anywhere):

- **`scheme`** — the analyst-declared stratification scheme
  (`nutrition_domain` here). A group is a **stratum** under a scheme;
  journals, journal-year cells, field-year windows, intervention classes,
  outcome families, and source-article clusters are other possible schemes.
- **`stratum`** — the substantive grouping within a scheme (the nutrition
  domain slug, e.g. `fiber`). `path_stratum` is the physical
  `data/<path_stratum>/` folder name (may be title-cased, e.g. `VitaminD`);
  `stratum` is its lowercase slug and every `output/` path uses the slug.
- **`source_article`** — the `<author><year>` token for one published
  meta-analysis; `source_key` is the per-source-article key used for
  article-balanced summaries; `source_year` is parsed from it.
- **`outcome_slug`** — the outcome token. (Distinct from the RoBMA `μ+`
  effect component; `log10BF_effect`'s "effect" refers to that component.)
- **`dataset_id`** — the stable compact stem, e.g.
  `whelton2005_fiber_systolic_bp`. The human-readable join key; never
  renamed.
- **`analysis_id`** — the portable canonical id, e.g.
  `nutrition_v4__fiber__whelton2005__systolic_bp__main`. An `_excl`
  companion shares everything but the trailing variant slug.
- **`analysis_variant`** — `main` or `exclusion_sensitivity` (a formal
  variant; `_excl` rows carry `parent_dataset_id` and an `exclusion_reason`).

**Terminology.** "Bias" means publication-bias / small-study /
selection-mechanism structure broadly, not publication bias alone.
"Rigor direction" takes only the values `effect` / `no_effect` (the literal
string `null` is avoided — common CSV/JSON parsers treat it as missing).

**One scheme/corpus per output root.** `scheme` and `corpus_id` are metadata
fields on every sidecar row, but the practical operating rule is: one
scheme/corpus per output root. The nutrition workflow stays physically
organised as `output/<stratum>/...` under a single `output/` root. A
different scheme/corpus (a simulation target, a resampling corpus) uses a
separate output root — see [`docs/pipeline_layout.md`](docs/pipeline_layout.md).

## Methodological Contribution

Conventional meta-analytic summaries report pooled estimates, confidence
intervals, and *p*-values. These describe an estimator under a chosen model;
they do not directly quantify how strongly the data support an effect,
support its absence, or support the absence/presence of bias-adjustment
structure, and they rarely fold publication selection, small-study effects,
and model uncertainty into one inferential object.

For each reconstructed meta-analytic outcome the pipeline fits RoBMA
4.0-compatible Bayesian meta-analytic models on identical inputs:

1. an **unadjusted Bayesian baseline** for the pooled effect (`brma()`), and
2. a **RoBMA-PSMA product-space ensemble**, averaging over the
   presence/absence of an effect, of heterogeneity, and of a family of
   publication-bias / small-study-effect mechanisms.

It reports component inclusion Bayes factors for effect, heterogeneity, and
modeled bias. The central methodological estimand is the **rigor Bayes
factor**, defined from two pre-specified no-bias model-family branches: one
with the effect component present and one with the null-effect component
present, each marginalizing over heterogeneity. The reported rigor BF is the
stronger of these two branch-specific Bayes factors, with its selected
direction retained.

**Primary contribution.** The repository's primary contribution is the
**reusable evidential-audit workflow and estimand layer**: an end-to-end
pipeline that turns the standard meta-analytic data structure (study-level
*g* and *SE_g*) into bias-aware posterior summaries, component inclusion Bayes
factors, exact branch/model-family probability summaries, \(BF_k^R\), rigor
direction labels, diagnostics, and scheme/stratum-level summaries under a
single configuration. The nutrition application is the fully worked
demonstration.

## Rigor Bayes Factor: Primary Evidence Estimand

The pipeline treats **rigor** as the headline evidential-audit estimand.
Rigor is not a thresholded quality score, not a study-validity label, and not
an informal average of marginal component Bayes factors. It is a
branch-selected statistic built from two pre-specified model-family Bayes
factors inside the RoBMA product-space ensemble:

1. an **effect-supporting no-bias branch**, and
2. a **null-supporting no-bias branch**.

This rewards both clean evidence for an effect and clean evidence for a
null/no-effect result, while still requiring that the evidence point toward
models without an explicit publication-bias or small-study-effect adjustment
component.

For reconstructed meta-analytic outcome \(k\), let

\[
\mathcal{Y}_k=\{(y_{ki},SE_{ki}): i=1,\ldots,m_k\}
\]

denote the study-level effect-size data, with \(y_{ki}\) corresponding to the
input column `g` and \(SE_{ki}\) to `se_g`. Let

\[
\mathcal{M}_k = \{M_{k1}, \ldots, M_{kL}\}
\]

denote the RoBMA model ensemble, with prior model probabilities
\(\pi_{k\ell}=p(M_{k\ell})\), marginal likelihoods
\(m_{k\ell}(\mathcal{Y}_k)=p(\mathcal{Y}_k\mid M_{k\ell})\), and posterior
model probabilities

\[
p(M_{k\ell}\mid \mathcal{Y}_k)=
\frac{\pi_{k\ell}m_{k\ell}(\mathcal{Y}_k)}
{\sum_{h=1}^{L}\pi_{kh}m_{kh}(\mathcal{Y}_k)}.
\]

For any model family \(\mathcal{A}_k\subset\mathcal{M}_k\), define

\[
p(\mathcal{A}_k) = \sum_{M_{k\ell}\in\mathcal{A}_k} \pi_{k\ell},
\qquad
p(\mathcal{A}_k\mid \mathcal{Y}_k) =
\sum_{M_{k\ell}\in\mathcal{A}_k} p(M_{k\ell}\mid \mathcal{Y}_k).
\]

The corresponding model-family inclusion Bayes factor is

\[
BF_{\mathcal{A}_k:\overline{\mathcal{A}}_k}
=
\frac{
p(\mathcal{A}_k\mid \mathcal{Y}_k)/p(\overline{\mathcal{A}}_k\mid \mathcal{Y}_k)
}{
p(\mathcal{A}_k)/p(\overline{\mathcal{A}}_k)
}.
\]

The top-level RoBMA components are \(\mu\) (effect), \(\tau\)
(heterogeneity), and \(\omega\) (publication-bias / small-study-effect
adjustment). \(\omega+\) denotes models with an explicit modeled-bias
component and \(\omega_0\) those without one; the dot indicates heterogeneity
is marginalized over.

The two **rigor branches** are

\[
\mathcal{R}_k^{+}
=
\mathcal{M}_{k,\mu+\cdot\omega_0}
=
\mathcal{M}_{k,\mu+\tau_0\omega_0}
\cup
\mathcal{M}_{k,\mu+\tau+\omega_0},
\]

and

\[
\mathcal{R}_k^{0}
=
\mathcal{M}_{k,\mu_0\cdot\omega_0}
=
\mathcal{M}_{k,\mu_0\tau_0\omega_0}
\cup
\mathcal{M}_{k,\mu_0\tau+\omega_0}.
\]

The branch-specific rigor Bayes factors are

\[
BF_k^{R,+}=BF_{\mathcal{R}_k^{+}:\overline{\mathcal{R}_k^{+}}},
\qquad
BF_k^{R,0}=BF_{\mathcal{R}_k^{0}:\overline{\mathcal{R}_k^{0}}}.
\]

The **rigor direction** is the better-supported no-bias branch:

\[
d_k^R
=
\arg\max_{d\in\{+,0\}}
\log_{10}BF_k^{R,d}.
\]

The headline **rigor Bayes factor** is then

\[
\log_{10}BF_k^R
=
\log_{10}BF_k^{R,d_k^R}
=
\max\{\log_{10}BF_k^{R,+},\log_{10}BF_k^{R,0}\}.
\]

Thus \(d_k^R=+\) indicates effect-supporting rigor and \(d_k^R=0\)
null-supporting rigor. The reported \(BF_k^R\) is comparable across outcomes
as a rigor magnitude; the direction field records what kind of rigorous
evidence the outcome supplies. In machine-readable sidecars the direction
field stores `effect` for \(d_k^R=+\) and `no_effect` for \(d_k^R=0\).

This differs from the marginal effect Bayes factor and the marginal no-bias
Bayes factor. The usual marginal bias-adjustment Bayes factor is

\[
BF_k^\omega
=
BF_{\mathcal{M}_{k,\omega+}:\mathcal{M}_{k,\omega_0}},
\]

so the marginal no-bias Bayes factor is

\[
BF_k^{\bar{\omega}}
=
BF_{\mathcal{M}_{k,\omega_0}:\mathcal{M}_{k,\omega+}}
=(BF_k^\omega)^{-1},
\qquad
\log_{10}BF_k^{\bar{\omega}}=-\log_{10}BF_k^\omega.
\]

Neither \(BF_k^{R,+}\) nor \(BF_k^{R,0}\) is generally a product of marginal
effect/null and no-bias Bayes factors; exact branch-specific rigor requires
joint model-family prior/posterior mass from the individual model summaries.
\(BF_k^{R,+}\) and \(BF_k^{R,0}\) are ordinary model-family Bayes factors for
pre-specified families; the selected \(BF_k^R\) is the larger of those two,
reported with its direction. It is **not** the Bayes factor for the union
\(\mathcal{R}_k^+\cup\mathcal{R}_k^0\), which collapses to the no-bias family
and loses the effect/null resolution.

The aggregation layer is defined over **strata**. Let \(S\) be a scheme and
\(S(k)\) the stratum label of outcome \(k\); write
\(\mathcal{K}_{s,S}=\{k:S(k)=s\}\), \(n_{s,S}=|\mathcal{K}_{s,S}|\). The
stratum-level finite-corpus rigor summary is the mean log rigor Bayes factor

\[
\Theta_{s,S}^R =
\frac{1}{n_{s,S}}\sum_{k\in\mathcal{K}_{s,S}}\log_{10} BF_k^R,
\]

with typical rigor Bayes factor \(10^{\Theta_{s,S}^R}\), plus direction
composition

\[
\pi_{s,S}^{R,+}
=
\frac{1}{n_{s,S}}\sum_{k\in\mathcal{K}_{s,S}}\mathbf{1}(d_k^R=+),
\qquad
\pi_{s,S}^{R,0}
=
\frac{1}{n_{s,S}}\sum_{k\in\mathcal{K}_{s,S}}\mathbf{1}(d_k^R=0).
\]

Because one source meta-analysis can contribute many reconstructed outcomes,
the reporting layer also produces **article-balanced** summaries

\[
\Theta_{s,S}^{R,w}
=
\frac{\sum_{k\in \mathcal{K}_{s,S}} w_k\log_{10}BF_k^R}
{\sum_{k\in \mathcal{K}_{s,S}} w_k},
\]

with default weight \(w_k=1/m_{a(k),s,S}\), where \(a(k)\) identifies the
source article and \(m_{a(k),s,S}\) is the number of outcomes it contributes
within the stratum. Outcome-weighted and article-balanced summaries answer
different audit questions and are reported together when outcome multiplicity
is uneven. The same outcome-level \(BF_k^R\) / direction values support
multiple schemes (`journal`, `field_year`, …) without refitting.

### Component vs rigor Bayes factors

- **Component inclusion BFs** (`log10BF_effect`, `log10BF_het`,
  `log10BF_bias`, `log10BF_no_bias`) are the marginal RoBMA-PSMA component
  evidence. `no_bias` is the complementary no-modeled-bias family within the
  ensemble — it does not prove the underlying literature is bias-free.
- **Rigor BFs** (`log10BF_rigor_effect`, `log10BF_rigor_no_effect`, and the
  selected `log10BF_rigor` with `rigor_direction`) are the pre-specified
  joint μ×ω no-bias branch statistics above. Rigor is the headline estimand;
  component evidence is secondary.

### Rigor categories

`60_estimand_tables.R` derives a `rigor_category` keyed off the **selected**
statistic + direction (threshold `.RIGOR_NEARZERO_THRESHOLD = 0.5` on the
log10 axis, BF ≈ [1/3, 3]):

| Category | Rule |
|----------|------|
| `clean_effect_supported` | `rigor_direction == "effect"` and `log10BF_rigor > 0.5` |
| `clean_no_effect_supported` | `rigor_direction == "no_effect"` and `log10BF_rigor > 0.5` |
| `clean_evidence_disfavored` | selected `log10BF_rigor < -0.5` (both branches clearly negative) |
| `inconclusive_clean_evidence` | finite `|log10BF_rigor| <= 0.5` |

## Schema and Estimand Contract

The rigor-estimand layer is a **versioned contract**, and it is a single R
object — not scattered column checks and not a `config/*.csv` file. It lives
in [`scripts/00_utils.R`](scripts/00_utils.R):

| Constant | Purpose |
|----------|---------|
| `.SIDECAR_V4_COLS` | The exact on-disk sidecar column set and order. |
| `.SCHEMA_VERSION` (`sidecar_v4.0`) | Reject sidecars written under an incompatible column contract. |
| `.ESTIMAND_VERSION` (`rigor_selected_v1`) | Reject outputs written under an older rigor definition (e.g. the archived effect-only prototype). |
| `.RIGOR_DIRECTION_LEVELS`, `.ANALYSIS_VARIANT_LEVELS` | Allowed categorical values (parser-safe; `null` disallowed). |
| `.BASELINE_CONVENTION` | The `brma()` baseline provenance fields. |
| `.bf_from_odds()`, `.rigor_category()`, `.build_identity_fields()` | The estimand/identity math, shared by `20` and `40` so labels/formulas cannot drift. |

Bumping `.SCHEMA_VERSION` or `.ESTIMAND_VERSION` changes the `config_hash`
and invalidates every prior sidecar row for resume by construction.
`sidecar_acceptance()` in `40_batch_fit.R` enforces the contract before any
reporting script consumes a sidecar: it fails loudly on a non-clean registry
anti-join, unresolved labels, component-validation failure, broken
rigor identities, an invalid `rigor_direction`, a stale
schema/estimand version, a non-current `config_hash`, or a RoBMA major
version below the v4 minimum.

The full per-field sidecar listing and every other artifact is documented in
[`docs/output_contract.md`](docs/output_contract.md).

## Pipeline Overview

Every script is **define-only**: sourcing installs functions and a load
sentinel and does nothing else (no package attach, no MCMC, no disk I/O).
Work is triggered only by calling an entry-point function; runtimes are armed
lazily inside those entry points.

| Script | Role | Key entry points |
|--------|------|------------------|
| `00_utils.R` | Shared contract/helpers: schema/estimand versions, allowed labels, `.SIDECAR_V4_COLS`, BF/hash/identity helpers, evidence-axis transform, rigor-category. | (constants/helpers) |
| `10_load_data.R` | Dataset discovery + loading; emits the v4 identity vocabulary. | `list_datasets()`, `load_datasets()` |
| `20_robma_fit.R` | Single-dataset fitter + rigor sidecar extractor; writes the lean per-stratum sidecar and model-summary audit artifacts. | `fit_robma_models()` |
| `30_zplot.R` | Artifact-driven z-plot renderer (saved `as_zplot()` artifacts). | `build_zplots()` |
| `40_batch_fit.R` | Batch fit / contract-aware resume / backfill / acceptance gate. | `batch_fit()`, `backfill_sidecars()`, `sidecar_acceptance()` |
| `50_stratum_visuals.R` | Stratum-/source-level inspection figures; consumes `60`'s registry; figures only. | `build_stratum_visuals()`, `build_source_visuals()` |
| `60_estimand_tables.R` | Canonical reporting / data-mart layer; regenerates derived columns from sidecar primitives. | `build_estimand_tables()` |
| `70_corpus_visuals.R` | Corpus-level / cross-stratum figures; consumes `60`'s outputs; figures only. | `build_corpus_visuals()` |

**Dependency graph**

```text
00_utils.R  (contract + helpers; sourced by all)
   │
10_load_data.R ─► 20_robma_fit.R ─► 40_batch_fit.R ─► sidecar_acceptance()
                         │                                   │
                         ▼ (saved zplot/fit .rds)            ▼
                    30_zplot.R                       60_estimand_tables.R
                                                            │
                                          ┌─────────────────┴─────────────────┐
                                          ▼                                   ▼
                              50_stratum_visuals.R                 70_corpus_visuals.R
```

**Run order**

1. `00 / 10 / 20 / 40` — fit (subprocess-isolated, contract-aware resume).
2. `30` — z-plots, after fit artifacts exist (optional).
3. `sidecar_acceptance()` — must pass before reporting.
4. `60` — reporting/data-mart tables, after sidecars pass acceptance.
   Writes `output/overview/outcome_registry.csv` (the registry consumed
   downstream).
5. `50 / 70` — figures only, after `60` has written
   `outcome_registry.csv`.

### Visual-scale contract

- Corpus-level component-BF **violins** and the rigor
  violin/ranking use **raw `log₁₀(BF)`** axes and share one visual family.
- **Orchards are retired** from the default 50/70 suite: the
  evidence-axis transform is **not part of the active visual
  pipeline**. A frozen copy of the old orchard module is kept under
  `archive/` for provenance only; it is not sourced or called by any
  default build.
- Axis labels use a real subscript 10 (`log₁₀(BF)`,
  `expression(log[10](BF))`). The violins are **display-capped at
  `|log₁₀(BF)| = 2`**: values beyond the cap (incl. `±Inf`) are plotted at
  the cap and feed the violin geometry/summaries; raw registry/sidecar values
  are unchanged. `corpus_component_violin_stack.pdf` is a horizontal
  three-panel (Effect | Heterogeneity | Modeled bias) figure; `50` writes a
  stratum-scoped `<scope>_component_violin_stack.pdf`. The raw distribution
  and capping are recorded in the returned `$diagnostics` tibble; no
  diagnostics
  CSV is written. Full per-figure detail:
  [`docs/visuals.md`](docs/visuals.md).

## Quick Start

**Requirements.** R (≥ 4.2 recommended), a working JAGS installation
(≥ 4.3.1), and RoBMA 4.0. Plotting/aggregation use `tidyverse`, `patchwork`,
`fs`, `readr`, `stringr`; `digest` is used for hashing if present (never
auto-installed). The exact verified versions (R, JAGS, Rtools, packages) are
in [`docs/environment.md`](docs/environment.md) — the current reproducibility
record. `renv` is **intentionally inactive** during active development (plain
user library); the stale RoBMA-3.6-era `renv.lock` and renv infra are
archived under `archive/renv_inactive_<date>/`, not at the repo root.

```r
source("scripts/00_utils.R")
source("scripts/10_load_data.R")
source("scripts/20_robma_fit.R")   # provides CONFIG + fit_robma_models()
source("scripts/40_batch_fit.R")

catalog <- list_datasets(only_candidates = TRUE)
catalog[, c("stratum", "source_article", "dataset_id", "analysis_variant")]

# Plan only (no fitting):
batch_fit(stratum = "fiber", dry_run = TRUE)

# Fit one stratum (subprocess-isolated; contract-aware resume):
batch_fit(stratum = "fiber", resume = FALSE)

# Rebuild the sidecar from saved RDS without refitting:
backfill_sidecars(stratum = "fiber")

# Trust gate — must pass before reporting:
ac <- sidecar_acceptance(stratum = "fiber")
stopifnot(ac$ok)

# Reporting + figures (after acceptance):
source("scripts/60_estimand_tables.R"); build_estimand_tables()
source("scripts/30_zplot.R");           build_zplots(stratum = "fiber")
source("scripts/50_stratum_visuals.R"); build_stratum_visuals(stratum = "fiber")
source("scripts/70_corpus_visuals.R");  build_corpus_visuals()
```

Run one stratum (fiber) end to end and require all acceptance checks to pass
before running the full corpus.

## Input Data Structure

Each analysis-ready CSV is one intervention–outcome pairing reduced to a
minimal effect-size representation:

| Column | Description |
|--------|-------------|
| `g` | Standardized effect size (Hedges' *g*; Cohen's *d* via `d`/`se_d` is an accepted no-rename fallback). |
| `se_g` | Standard error of the effect size (finite, strictly positive). |

A minimum of three studies is required. Effects are sign-aligned so a
positive value reflects the direction favored by the intervention
hypothesis; RoBMA-PSMA is fit with `effect_direction = "positive"`, which
orients the one-sided selection components but does not constrain the sign of
the fitted pooled effect. Files use the stem
`<source_article>_<stratum>_<outcome_slug>.csv`; the v4 identity parser turns
this into `corpus_id`, `scheme`, `stratum`, `path_stratum`, `source_article`,
`source_key`, `source_year`, `outcome_slug`, `dataset_id`, `analysis_id`,
`analysis_variant`, `parent_dataset_id`, `has_excl_variant`. `_excl`
companions are formal exclusion-sensitivity variants. The complete
input-side specification (including the `_excl` policy) is in
[`data_dictionary.md`](data_dictionary.md).

## Outputs

The active run writes only v4-compatible outputs under `output/` (legacy
RoBMA 3.6 outputs are under `archive/RoBMA_3_6/`). In brief:

- **Per dataset** (`20`/`40`): `fit_RE4_*.rds`, `fit_RoBMA4_*.rds`,
  `zplot_*_*.rds`, and `audit/` model-summary + validation CSVs.
- **Per stratum** (`20`/`40`): `output/<stratum>/<stratum>_robma_summary.csv`
  (canonical lean sidecar) and `output/<stratum>/<stratum>_zplot_diagnostics.csv`.
- **Reporting** (`60`): `output/overview/` registry, stratum / article-balanced
  / corpus estimands, rigor category/direction summaries, component-evidence
  summary (CSV + TeX).
- **Figures** (`30`/`50`/`70`): per-dataset z-plots, stratum/source
  inspection figures, corpus component violins/attenuation, and the
  rigor suite. (Evidence-axis orchards are retired and archived only;
  they are not part of the active visual pipeline.)

The authoritative, file-by-file contract — including which files are
source-controlled vs generated and whether large `.rds` fits should ship — is
[`docs/output_contract.md`](docs/output_contract.md).

## Worked Example: Nutrition Intervention Meta-Analyses

The included application reanalyzes a purposive corpus of published nutrition
intervention meta-analyses under the `nutrition_domain` scheme, spanning
eight strata: **caffeine, creatine, diet, fasting, fiber, omega-3, protein,
vitamin D** (≈175 outcomes). For each intervention–outcome pairing,
study-level effect sizes were extracted from the published synthesis,
standardized to Hedges' *g* with standard errors, and refit under the unified
pipeline. The published meta-analytic constructions are **preserved as much
as possible**: the full reconstructed study set is the analysis of record by
default. `_excl` variants exist only when the full reconstructed dataset
produced a clearly pathological RoBMA-PSMA fit (typically a few extreme
positive outliers dominating the bias-adjusted ensemble); studies are then
removed sequentially from the largest positive outlier until the first
stable, interpretable fit, with the full set always preserved in the paired
extraction workbook. See [`data_dictionary.md`](data_dictionary.md).

## Adapting to a New Evidence Corpus

The workflow is not specific to nutrition. To apply it to another literature,
journal window, or field-level corpus:

1. **Define the evidence corpus** (e.g. all reconstructable meta-analytic
   outcomes in a target journal over a defined window).
2. **Standardize each meta-analysis** to the input contract: one CSV per
   reconstructed intervention–outcome pairing with `g` and `se_g`,
   sign-aligned so positive is the favored direction.
3. **Record metadata for stratification** — at minimum the source-article
   identifier; ideally journal, year, field, intervention class, outcome
   family. The same outcome-level rigor values aggregate under several
   schemes.
4. **Use a separate output root** for the new corpus (one scheme/corpus per
   root) — do not nest it inside the nutrition `output/` tree.
5. **Run the fitting layer** (`00`/`10`/`20`/`40`), pilot before full corpus,
   then `60` and the visual layer.

The `simulation/` directory is a **separate sub-project** (own
README/config/scripts) that reuses the `00_utils.R` estimand/schema
layer and writes to its own output root. It sits beside the nutrition
workflow and must not be moved into `scripts/` or `output/`. The legacy
v2 `resampling/` sub-project has been **archived** to
[`archive/resampling_v2_legacy/`](archive/resampling_v2_legacy/README_ARCHIVE.md)
(frozen provenance; not part of the active workflow — its active v4
successors live in `simulation/scripts/45,60,65,70,75`). See
[`docs/pipeline_layout.md`](docs/pipeline_layout.md).

### Simulation-ready main-pipeline convention

The main pipeline can ingest and report **simulated strata with no core code
change**. Shared input contract is intended; mixed output roots are not.

- **Audit-ready synthetic CSVs live in `data/`**, reusing the audit loader
  structure: `data/sim_<cell_slug>/sim<vintage>/repNNNN.csv` →
  `stratum = sim_<cell_slug>`, `source_article = sim<vintage>`,
  `outcome_slug = repNNNN` (compact; **not** the dataset_id),
  `dataset_id = <source_article>_<stratum>_<outcome_slug>`,
  `analysis_id` = parsed identity, `corpus_id`/`scheme` from `CONFIG`.
- **Simulation-specific latent/truth/manifest files stay OUT of `data/`**
  (the audit loader must only see analysis-ready study-level CSVs); keep them
  under `simulation/latent|manifests|results/`.
- **Use a separate output root** so empirical and synthetic sidecars never
  mix (one scheme/corpus per output root):

  ```r
  CONFIG$output_root <- "output_sim_v30"
  CONFIG$corpus_id   <- "sim_library_v30"
  CONFIG$scheme      <- "simulation_cell"
  # PER-STRATUM ONLY: compact repNNNN stems are NOT unique across strata.
  # batch_fit(source_article = "sim2026") over ALL sim strata collides
  # every repK R object in load_datasets() and fits the wrong data.
  # Always loop one stratum at a time:
  for (st in sim_load_design()$stratum)
    batch_fit(stratum = st, source_article = "sim2026", resume = TRUE)
  sidecar_acceptance_all(output_root = "output_sim_v30",
                         require_artifacts = FALSE)   # lightweight root
  build_estimand_tables(root = "output_sim_v30",
                        output_dir = "output_sim_v30/overview")
  build_corpus_visuals(output_dir = "output_sim_v30/overview")
  ```
  The simulation sub-project's canonical fitter is `sim_fit_library()`
  in `simulation/scripts/40_sim_run.R`. It fits every generated dataset
  on disk (no `TARGET_REPS_PER_CELL` config), per-stratum, resume-safe.

The full step-by-step convention, the per-stage argument-name table, and the
concrete output-root names are in
[`docs/pipeline_layout.md`](docs/pipeline_layout.md). The implementation of
the simulation layer itself is out of scope for the main pipeline and
lives in its own sub-project (`simulation/`).

## Reproducibility and Repository Notes

- **Reproducibility.** Given the analysis-ready CSVs, the `00_utils.R`
  schema/estimand contract, and the `CONFIG` block in `20_robma_fit.R`
  (including the fixed seed), posterior summaries and inclusion Bayes factors
  reproduce up to small numerical variation across `RoBMA` and JAGS releases.
  The verified R / JAGS / package versions are recorded in
  [`docs/environment.md`](docs/environment.md) (numeric reproducibility is
  defined by RoBMA 4.0.0 + BayesTools 0.3.0 + JAGS 4.3.1 + the fixed seed).
  `renv` is intentionally inactive during active development; the stale
  `renv.lock` is archived under `archive/renv_inactive_<date>/` and is not
  the v4 reproduction path (it may be reintroduced only at release freeze
  after explicit decision and restore testing).
- **Resume safety.** `40_batch_fit.R` does not skip a dataset merely because
  an `.rds` file exists. Resume is configuration-, version-, and
  estimand-aware via `config_hash`, package versions, schema/estimand
  versions, and expected artifact names; RoBMA 3.6 artifacts, pilot scratch,
  and old effect-only-rigor sidecars never satisfy a current run.
- **Immutable raw inputs.** Extraction workbooks and analysis-ready CSVs are
  never overwritten; all derived products live under `output/`.
- **Regenerable artifacts.** Large fitted `.rds` objects **may be omitted**
  from the public repository; the committed v4 sidecars carry the
  outcome-level primitives needed to regenerate every table and figure
  without rerunning MCMC. A full nutrition rebuild of the fits is several
  CPU-hours on a multi-core workstation.
- **Release.** A practical pre-flight is in
  [`docs/release_checklist.md`](docs/release_checklist.md) (scratch hygiene,
  `.gitignore`, regenerate-from-scripts, whether to ship `.rds` fits,
  environment/version checks against [`docs/environment.md`](docs/environment.md)).

## Associated Manuscript

This repository accompanies a methods-focused manuscript with the working
title:

> **A Model-Family Bayes Factor for Evidential Rigor in Meta-Analysis: A
> Bias-Aware Nutrition Case Study.**

The nutrition corpus is the worked example; the framework and the rigor
estimand are general. When bundled with a public release, manuscript files
live under `manuscript/` and release versioning tags the corresponding
commit.

## Citation

`CITATION.cff` provides structured citation metadata (a software citation and
a `preferred-citation` entry for the manuscript). Manuscript-side fields
(DOI, journal, year, URL) and the archived-release DOI are populated at
preprint posting and release tagging respectively; until then they carry
explicit `TODO_*` placeholders rather than fabricated values. For now, cite
the repository by reference to the *Associated Manuscript* section above.

## License

- **Code.** Source under `scripts/` is licensed under the **MIT License**
  ([`LICENSE`](LICENSE)).
- **Data and figures.** Analysis-ready datasets, extraction workbooks,
  derived summary tables, and figures (under `data/` and the relevant
  subtrees of `output/`) are licensed under **CC BY 4.0**
  ([`LICENSE-data`](LICENSE-data)). `LICENSE-data` lists the exact file
  globs; follow the attribution guidance in `CITATION.cff`.

## Contact

Issues and questions: please open a GitHub issue. Substantive correspondence
about the methods or the nutrition application can be directed to the
corresponding author of the associated manuscript.
