# Data Dictionary — Input Side

This document is the canonical schema for the **inputs** consumed by the
RoBMA 4.0 selected-rigor pipeline. It defines what an analysis-ready CSV must
look like, where it lives, and how it relates to its companion extraction
workbook. A reuser adapting the pipeline to a new literature should be able to
satisfy this document without reading the R code.

For the artifacts the pipeline produces, see
[`docs/output_contract.md`](docs/output_contract.md). For the estimand math
and the full identity vocabulary, see [`README.md`](README.md).

---

## 1. Directory layout

Each analysis-ready dataset lives at:

```
data/<path_stratum>/<source_article>/<dataset_id>.csv
```

with a paired extraction workbook at:

```
data/<path_stratum>/<source_article>/<dataset_id>.xlsx
```

- **`<path_stratum>`** — the physical stratum folder. For the nutrition
  corpus this is the intervention domain (e.g. `Caffeine`, `Fiber`,
  `VitaminD`). It may be title-cased on disk; the v4 identity parser
  lowercases it to the **`stratum`** slug (`caffeine`, `fiber`, `vitamind`),
  and every `output/` path uses the slug. A stratum is one group under the
  active stratification **`scheme`** (`nutrition_domain`).
- **`<source_article>`** — short lowercase token identifying the source
  synthesis, conventionally `<lastname><year>` (e.g., `jovanovski2019`,
  `morton2018`). One folder = one published meta-analysis. The trailing
  4-digit year is parsed into `source_year`; the token itself is the
  per-article grouping key `source_key` used for article-balanced summaries.
- **`<dataset_id>`** — the stable compact stem (see §2).

`10_load_data.R` (`list_datasets()`) discovers datasets by recursively
scanning `data/` and parsing this `<path_stratum>/<source_article>/`
structure once via the shared identity parser
(`.build_identity_fields()` in `00_utils.R`), so the catalog's `analysis_id`
/ `dataset_id` agree exactly with what `20_robma_fit.R` writes to the
sidecar. Files whose stem ends in `original_effects`, `studies`, or
`excluded` are helper / extraction-record files and are skipped during
discovery.

> **Vocabulary note.** Earlier versions of this repository called these
> `topic` (now `stratum` / `path_stratum`), `author` (now `source_article` /
> `source_key` / `source_year`), `effect` (now `outcome_slug`), and treated
> the filename `basename`/`stem` as the only identity (now the stable
> `dataset_id`, with a portable `analysis_id` generated alongside it). The
> old vocabulary is no longer canonical; the explanations below keep the
> existing nutrition file names legible under the v4 parser.

### Simulated audit-ready datasets

Audit-ready **synthetic** datasets may live in this same tree so the standard
loader/fitter treats them like any dataset:

```
data/sim_<cell_slug>/sim<vintage>/repNNNN.csv
e.g. data/sim_null_lowhet_clean/sim2026/rep0001.csv
```

They must satisfy the **same input contract** as empirical CSVs (the §3
columns; same study-level shape). The parser reads them with no change.
The on-disk stem is the **compact** `repNNNN` token (the replicate
index): it is the `outcome_slug`, **not** the full `dataset_id`. The
synthetic cell lives in the folder path, not the filename; the v4
identity is derived from the folders + stem:

```
path_stratum / stratum = sim_<cell_slug>   e.g. sim_null_lowhet_clean
source_article         = sim<vintage>      e.g. sim2026  (source_year 2026)
outcome_slug           = repNNNN           e.g. rep0001
dataset_id             = <source_article>_<stratum>_<outcome_slug>
                         e.g. sim2026_sim_null_lowhet_clean_rep0001
analysis_id            = <corpus_id>__<stratum>__<source_article>__<outcome>__<variant>
                         e.g. sim_library_v30__sim_null_lowhet_clean__sim2026__rep0001__main
```

`corpus_id`/`scheme` come from `CONFIG` (active simulation library:
`corpus_id = sim_library_v30`, `scheme = simulation_cell`). A
cell-bearing stem must **not** be used — it produced a doubled
`dataset_id`, which is why the stem is compact (see
`simulation/README_simulation_v3_1.md`).

Simulation-specific **latent / truth / manifest** files must **not** live in
`data/` — the audit loader must only ever see analysis-ready study-level
CSVs. They belong under the simulation sub-project
(`simulation/latent|manifests|results/`). Synthetic *outputs* go to a
**separate output root** (one scheme/corpus per root); see
[`docs/pipeline_layout.md`](docs/pipeline_layout.md).

---

## 2. File naming convention

Each analysis-ready CSV uses the compact stem:

```
<source_article>_<stratum>_<outcome_slug>
```

For example:

- `jovanovski2019_fiber_hba1c.csv`
- `morton2018_protein_muscle_strength.csv`

Constraints:

- Lowercase only; words separated by `_`.
- The `<outcome_slug>` segment may contain underscores
  (e.g., `lean_body_mass`).
- The stem is stable: it is the `dataset_id`, propagated through every
  downstream artifact (`fit_RE4_<dataset_id>.rds`,
  `fit_RoBMA4_<dataset_id>.rds`, the sidecar row, figures). It is never
  renamed.

The v4 identity parser turns each stem (plus its folder path) into explicit
metadata, all carried on the sidecar row:

```
corpus_id  scheme  stratum  path_stratum
source_article  source_key  source_year
outcome_slug  dataset_id  analysis_id
analysis_variant  parent_dataset_id  has_excl_variant
```

`dataset_id` stays the compact stem; `analysis_id` is the portable canonical
id, e.g. `nutrition_v4__fiber__whelton2005__systolic_bp__main` (the `_excl`
companion shares everything but the trailing variant slug, making the pair
relationship explicit). `dataset_id` is the human-readable join key for the
nutrition corpus; `analysis_id` is the preferred key for cross-corpus joins.

### The `_excl` suffix → `analysis_variant = exclusion_sensitivity`

A central design principle is to **preserve the published meta-analytic
constructions as much as possible**. The non-`_excl` CSV is the full
reconstructed study set (the analysis of record by default), matching the
source synthesis up to the standardization choices in §3.

An `_excl` companion exists only when the full reconstructed dataset produced
a clearly **pathological or uninterpretable RoBMA-PSMA fit** — most commonly
when one or a few extreme positive outliers dominated the bias-adjusted
ensemble. In those cases studies were removed **sequentially**, beginning
with the largest positive outlier, refitting after each removal, and stopping
at the **first stable, interpretable fit reached within reason**. The
procedure is intentionally minimal and conservative; no exclusion is made
when the full-data fit is interpretable.

Concretely:

- `nunes2022_protein_lean_body_mass.csv` — full reconstructed study set
  (always retained; `analysis_variant = "main"`).
- `nunes2022_protein_lean_body_mass_excl.csv` — minimally modified study set
  actually used when the full-data fit was pathological
  (`analysis_variant = "exclusion_sensitivity"`).

`_excl` variants are **distinct, explicitly linked datasets**: they are fit
independently, produce their own artifacts, and contribute their own sidecar
row carrying `analysis_variant = "exclusion_sensitivity"`, a
`parent_dataset_id` pointing at the full reconstructed stem, and an
`exclusion_reason` placeholder (the per-dataset narrative reason lives in the
extraction workbook, not in machine metadata). The paired workbook
(`<dataset_id>.xlsx`) retains the full reconstructed study set and records
which rows were removed and in what order; nothing is deleted from the
project record.

---

## 3. Required columns

Every analysis-ready CSV must supply one standardized-mean-difference
effect-size pair. `20_robma_fit.R` enforces this via the shared
`.resolve_effect_input()` (`00_utils.R`) and raises a clear error otherwise.

| Column | Type    | Required | Description |
|--------|---------|----------|-------------|
| `g`    | numeric | preferred | Standardized mean difference (Hedges' *g*) for one primary study. Must be finite. |
| `se_g` | numeric | preferred | Standard error of `g`. Must be finite and strictly positive. |

**Effect-size input contract.** The preferred/default pair is `g` + `se_g`.
As a **no-rename compatibility fallback**, a dataset that instead carries
Cohen's *d* as `d` + `se_d` is accepted (`g`/`se_g` and `d`/`se_d` share the
SMD scale; the pipeline does not distinguish them downstream). The fixed,
non-configurable preference order is: `g`/`se_g` if present, else `d`/`se_d`,
preferring `g`/`se_g` if both are present. The same finite-estimate /
finite-positive-SE validation is applied to whichever pair is selected. A
minimum of **3 finite rows (studies)** is required; smaller datasets are
skipped with a warning.

### Effect-size scale and conventions

- **Primary scale.** Hedges' *g* with its standard error; the small-sample
  correction is applied at extraction time when sample sizes are reported.
- **Cohen's *d* fallback.** When sample sizes are unavailable but an SMD is
  otherwise extractable, Cohen's *d* may be retained as a close
  approximation; recorded in the extraction workbook.
- **Ratio measures.** Odds-ratio / log-ratio effects are mapped at
  extraction time via the standard logistic-to-normal transform
  (`d ≈ log(OR) / 1.81`); the CSV contains the resulting *g* / *SE_g* pair.
- **Crossover / repeated-measures designs.** Variances use the within-subject
  correlation reported (or implied) by the source when recoverable; otherwise
  a documented working assumption is applied and recorded in the workbook.

### Sign convention

Effects are sign-aligned at extraction time so that **a positive value
reflects the direction favored by the intervention hypothesis** for the given
outcome (e.g., a reduction in HbA1c is encoded positive even though the raw
mean difference is negative). When the original synthesis reported the
opposite sign, extracted values are multiplied by −1.

This is required because RoBMA-PSMA is fit with
`effect_direction = "positive"` (set in the `CONFIG` block of
`20_robma_fit.R`), which orients the one-sided selection components on a
common scale across datasets. It orients selection adjustment; it does not
constrain the sign of the fitted pooled effect. Because an `effect` rigor
direction means evidence for the modeled effect branch (not necessarily a
*beneficial* effect), a human-readable `positive_effect_interpretation` field
is reserved on the registry.

---

## 4. Optional columns

Optional columns are tolerated and pass through to the loaded data frame and
summary tables where applicable:

| Column   | Type      | Description |
|----------|-----------|-------------|
| `study`  | character | Study label (e.g., `"Smith 2010"`). Cosmetic; does not enter the model. |
| `n1`, `n2` | integer | Group sample sizes when available. Not required; useful for downstream auditing. |
| Other extraction-provenance columns | any | Reported CI bounds, *p*-values used to reconstruct `se_g`, etc., retained for traceability. |

Columns matching helper-file patterns (`original_effects`, `studies`,
`excluded`) must not appear at the top level of an analysis-ready CSV.

---

## 5. Relationship to the extraction workbook

Each analysis-ready CSV is paired with an extraction workbook
(`<dataset_id>.xlsx`) in the same folder. The workbook is the **primary
extraction record**: originally reported study-level values (means, SDs,
sample sizes, CIs, *p*-values), the formulas/transformations used to obtain
`g` and `se_g`, and any working assumptions.

Conventions:

- The CSV is derived from the workbook, not vice versa. Edits to the
  analysis-ready data are made in the workbook and re-exported.
- Studies removed for an `exclusion_sensitivity` variant are retained in the
  workbook (typically a separate sheet), with the order of removal recorded
  so the exclusion is auditable.
- The workbook holds source-paper page references, extraction notes, and any
  per-study comments that do not fit the minimal CSV schema.

The pipeline never reads the workbook; it reads only the CSV. The workbook is
included to support traceability and reuse.

---

## 6. Assumptions a reuser should be aware of

1. **Independence within a dataset.** Outcomes within one CSV are treated as
   independent. Hierarchical / multi-arm structures are reduced upstream
   before producing the analysis-ready CSV.
2. **One outcome per CSV.** A single CSV is a single intervention–outcome
   pairing; multi-outcome syntheses are split into multiple CSVs, each with
   its own `dataset_id`.
3. **Sign-aligned effects.** The §3 convention is assumed. If a new domain
   has no obvious favored direction, the convention may be set arbitrarily
   but must be applied consistently within each dataset.
4. **Effect scale.** The pipeline fits with `CONFIG$measure = "SMD"`
   (RoBMA 4.0 `yi`/`sei` interface). Other scales require changing the fit
   call in `20_robma_fit.R`.
5. **Minimum study count.** Datasets with fewer than 3 finite effect-size
   rows are skipped.
6. **MCMC defaults.** The default `CONFIG` (fixed seed; sampling settings in
   `20_robma_fit.R`) is appropriate for typical meta-analyses (≈10–50
   studies). Larger or harder datasets may need expanded sampling;
   convergence is monitored via the potential scale reduction statistic.
