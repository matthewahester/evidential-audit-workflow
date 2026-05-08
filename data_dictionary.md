# Data Dictionary — Input Side

This document is the canonical schema for the **inputs** consumed by the bias-robust Bayesian meta-analysis pipeline. It defines what an analysis-ready CSV must look like, where it lives in the repository, and how it relates to its companion extraction workbook. Reusers adapting the pipeline to a new literature should be able to satisfy this document without reading the underlying R code.

For a description of the artifacts the pipeline produces, see [`output_dictionary.md`](output_dictionary.md).

---

## 1. Directory layout

Each analysis-ready dataset lives at:

```
data/<topic>/<author>/<stem>.csv
```

with a paired extraction workbook at:

```
data/<topic>/<author>/<stem>.xlsx
```

- **`<topic>`** — short lowercase slug for the intervention domain (e.g., `fiber`, `protein`, `vitamind`). Topic slugs are stable across the repository and reused as filename prefixes for derived outputs.
- **`<author>`** — short lowercase token identifying the source synthesis, conventionally `<lastname><year>` (e.g., `jovanovski2019`, `morton2018`). One author folder corresponds to one published meta-analysis.
- **`<stem>`** — the dataset stem (see §2).

`10_load_data.R` discovers datasets by recursively scanning the `data/` tree and parsing this `<topic>/<author>/` structure. Files whose basename ends in `original_effects`, `studies`, or `excluded` are treated as helper / extraction-record files and are skipped during automatic discovery.

---

## 2. File naming convention

Each analysis-ready CSV uses the stem:

```
<author><year>_<topic>_<outcome>
```

For example:

- `jovanovski2019_fiber_hba1c.csv`
- `morton2018_protein_muscle_strength.csv`

Constraints:

- Lowercase only; words separated by `_`.
- The `<outcome>` segment may contain underscores (e.g., `lean_body_mass`).
- The stem is stable: it is propagated through every downstream artifact (`fit_RE_<stem>.rds`, `fit_RoBMA_<stem>.rds`, summary rows, etc.).

### The `_excl` suffix

A central design principle of the workflow is to **preserve the published meta-analytic constructions as much as possible**. The non-`_excl` CSV is therefore the full reconstructed study set, matching the source synthesis up to the standardization choices documented in §3.

`_excl` variants exist only when the full reconstructed dataset produced a clearly **pathological or uninterpretable RoBMA-PSMA fit** — most commonly when one or a few extreme positive outliers dominated the bias-adjusted ensemble and produced an implausible adjusted result or numerically unstable selection-model component. In those cases, studies were removed **sequentially**, beginning with the largest positive outlier, refitting after each removal, and stopping at the **first stable, interpretable fit reached within reason**. The procedure was intentionally minimal and conservative; no exclusion is made when the full-data fit is interpretable.

Concretely:

- `nunes2022_protein_lean_body_mass.csv` — full reconstructed study set (always retained).
- `nunes2022_protein_lean_body_mass_excl.csv` — minimally modified study set actually used for the bias-robust fit when the full-data fit was pathological.

`_excl` variants are treated as **distinct datasets** by the pipeline: they are fit independently, produce their own artifacts, and contribute their own row to the per-topic summary CSV. The paired extraction workbook (`<stem>.xlsx`) retains the full reconstructed study set and documents which rows were removed and in what order; nothing is deleted from the project record. When both a full and an `_excl` fit are present for the same outcome, the `_excl` row is the one used for the bias-robust comparator in topic- and overview-level summaries; the full-data row remains available for inspection.

---

## 3. Required columns

Every analysis-ready CSV must contain the following columns. `20_robma_fit.R` enforces these requirements and raises an error otherwise.

| Column | Type    | Required | Description |
|--------|---------|----------|-------------|
| `g`    | numeric | yes      | Standardized mean difference (Hedges' *g*) for one primary study contributing to the meta-analysis. Must be finite. |
| `se_g` | numeric | yes      | Standard error of `g` for the same study. Must be finite and strictly positive. |

A minimum of **3 rows (studies)** is required for fitting; smaller datasets are skipped with a warning.

### Effect-size scale and conventions

- **Primary scale.** Hedges' *g* with its standard error. Hedges' small-sample correction is applied at extraction time when sample sizes are reported.
- **Cohen's *d* fallback.** When sample sizes are not available but a standardized mean difference is otherwise extractable, Cohen's *d* may be retained as a close approximation to *g*. The pipeline does not distinguish between *d* and *g* downstream; this approximation is recorded in the extraction workbook.
- **Ratio measures.** When a source synthesis reports odds ratios or related log-ratio effects, the standard logistic-to-normal transform (`d ≈ log(OR) / 1.81`) is applied at extraction time. The CSV contains the resulting *g* / *SE_g* pair, not the original ratio.
- **Crossover / repeated-measures designs.** Variances are computed using the within-subject correlation reported (or implied) by the source meta-analysis when recoverable; otherwise a documented working assumption is applied and recorded in the extraction workbook.

### Sign convention

Effects are sign-aligned at extraction time so that **a positive value reflects the direction favored by the intervention hypothesis** for the given outcome (e.g., reduction in HbA1c is encoded with a positive sign, even though the raw mean difference is negative). When the original synthesis reported the opposite sign, extracted values are multiplied by −1.

This convention is required because RoBMA-PSMA is fit with `effect_direction = "positive"` (set in the `CONFIG` block of `20_robma_fit.R`), which orients the one-sided selection components on a common scale across all datasets. The convention orients selection adjustment; it does not constrain the sign of the fitted pooled effect.

---

## 4. Optional columns

Optional columns are tolerated. They are passed through to the loaded data frame and to summary tables where applicable. Common optional columns include:

| Column   | Type      | Description |
|----------|-----------|-------------|
| `study`  | character | Study label (e.g., `"Smith 2010"`). Used cosmetically; does not enter the model. |
| `n1`, `n2` | integer | Group sample sizes, when available from the source. Not required by the pipeline but useful for downstream auditing. |
| Other extraction-provenance columns | any | Additional columns documenting the source-of-record for `g` and `se_g` (e.g., reported confidence interval bounds, *p*-values from which `se_g` was reconstructed) may be retained for traceability. |

Columns with names matching helper-file patterns (`original_effects`, `studies`, `excluded`) should not appear at the top level of an analysis-ready CSV.

---

## 5. Relationship to the extraction workbook

Each analysis-ready CSV is paired with an extraction workbook (`<stem>.xlsx`) in the same folder. The workbook is the **primary extraction record**: it contains the originally reported study-level values (means, SDs, sample sizes, confidence intervals, *p*-values, etc.), the spreadsheet formulas or transformations used to obtain `g` and `se_g`, and any working assumptions (e.g., assumed within-subject correlation for crossover designs).

Workbook conventions:

- The CSV is derived from the workbook, not vice versa. Edits to the analysis-ready data are made in the workbook and then re-exported.
- Studies removed for an `_excl` variant are retained in the workbook (typically on a separate sheet), with the order of removal recorded so the exclusion can be audited.
- The workbook is the natural location for source-paper page references, extraction notes, and any per-study comments that do not fit the minimal CSV schema.

The pipeline never reads the workbook; it reads only the CSV. The workbook is included in the public repository to support traceability and reuse.

---

## 6. Assumptions a reuser should be aware of

A reuser bringing this pipeline to a new literature should be aware of the following pipeline-level assumptions:

1. **Independence within a dataset.** Outcomes within a single CSV are treated as independent. Hierarchical or multi-arm structures should be reduced upstream (e.g., by combining arms or selecting a representative comparison) before producing the analysis-ready CSV.
2. **One outcome per CSV.** A single CSV represents a single intervention–outcome pairing. Multi-outcome syntheses are split into multiple CSVs, each with its own stem.
3. **Sign-aligned effects.** The pipeline assumes the convention in §3. If a new domain has no obvious "favored direction", the convention can be set arbitrarily but must be applied consistently within each dataset.
4. **Effect scale.** The pipeline assumes `measure = "SMD_g"` (set in `CONFIG`). Other scales would require modification of the call to `RoBMA::RoBMA()`; see `20_robma_fit.R`.
5. **Minimum study count.** Datasets with fewer than 3 finite `(g, se_g)` rows are skipped.
6. **MCMC defaults.** The default `CONFIG` (6 chains, 100k post-burnin samples, fixed seed) is appropriate for typical meta-analyses (≈10–50 studies). Larger or harder-to-fit datasets may require expanded sampling settings; convergence is monitored via the potential scale reduction statistic.
