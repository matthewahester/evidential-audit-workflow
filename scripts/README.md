# Pipeline scripts (RoBMA 4.0 rigor-estimand layer)

Per-script manual for the `scripts/` directory. The conceptual framework,
estimand math, and sidecar contract live in the repository-root
[`README.md`](../README.md); this file documents the code layout and the
day-to-day fitting/acceptance workflow.

## Define-only contract

Every script is **define-only**: `source()`-ing a script installs functions
and constants and nothing else. No package is attached, no MCMC is run, no
file is read or written, and nothing is installed merely by sourcing. Work is
triggered only by calling an entry-point function. The full set of
entry points across the active pipeline:

| Script | Entry points |
|--------|--------------|
| `10_load_data.R` | `list_datasets()`, `load_datasets()` |
| `20_robma_fit.R` | `fit_robma_models()` |
| `30_zplot.R` | `build_zplots()` |
| `40_batch_fit.R` | `batch_fit()`, `backfill_sidecars()`, `sidecar_acceptance()`, `sidecar_acceptance_all()` |
| `60_estimand_tables.R` | `build_estimand_tables()` |
| `50_stratum_visuals.R` | `build_stratum_visuals()`, `build_source_visuals()` |
| `70_corpus_visuals.R` | `build_corpus_visuals()` |

The RoBMA/runjags runtime is armed lazily inside `fit_robma_models()`
(`.ensure_robma_runtime()`); `callr` is checked only when `batch_fit()`
actually needs a subprocess; the plotting runtime is armed lazily inside the
`30`/`50`/`70` entry points (`.ensure_visual_runtime()`).

## Script order and status

| Script | Role | Status |
|--------|------|--------|
| `00_utils.R` | Central contract + shared helpers: schema/estimand versions, allowed labels, `.SIDECAR_V4_COLS`, `.ZPLOT_DIAG_COLS`, baseline convention, BF/hash/parse helpers, identity parser, rigor-category. | **Active** |
| `10_load_data.R` | Dataset discovery (`list_datasets()`) and loading (`load_datasets()`); emits the v4 identity vocabulary. | **Active** |
| `20_robma_fit.R` | Single-dataset fitter + rigor sidecar extractor; writes the lean per-stratum sidecar and the model-summary audit artifacts. | **Active** |
| `30_zplot.R` | Artifact-driven z-plot renderer for fitted datasets, sources, or strata. | **Active** |
| `40_batch_fit.R` | Batch fit / contract-aware resume / backfill / sidecar-acceptance gate. | **Active** |
| `50_stratum_visuals.R` | Stratum-/source-level inspection figures: consumes 60's `outcome_registry.csv`, slices to one stratum (+ optional source article / variant), writes the effect-estimate comparison, effect forest, display-capped component violin stack, and rigor ranking. Figures only. | **Active** |
| `60_estimand_tables.R` | Canonical reporting / data-mart layer: consumes the lean v4 sidecars (+ optional zplot diagnostics), regenerates derived reporting columns, and writes the outcome registry, stratum estimands, article-balanced summaries, corpus/headline summaries, and rigor category/direction summaries (CSV + TeX). | **Active** |
| `70_corpus_visuals.R` | Corpus-level / cross-stratum figures: consumes 60's `outcome_registry.csv`, writes the display-capped component violins/stack, attenuation boxplots, and rigor suite. Figures only (evidence-axis orchards are retired; archived only). | **Active** |

> Evidence-axis orchard visuals (`build_corpus_orchards()` /
> `build_stratum_orchards()`) are retired and **not part of the active
> pipeline**. A frozen copy of the old module lives under
> `archive/55_orchard_visuals.R` for provenance only and is not sourced
> by any active script.

**Execution order**

1. `00 / 10 / 20 / 40` — fit (subprocess-isolated, contract-aware resume).
2. `30` — z-plots, *after* fit artifacts exist, only if z-plots are wanted.
3. `sidecar_acceptance(stratum = ...)` per stratum, then
   `sidecar_acceptance_all()` corpus-wide — the contract gate; must pass
   before any reporting.
4. `60` — tabular reporting layer, *after* sidecars exist and pass
   acceptance. Reads only the per-stratum sidecars + zplot diagnostics,
   never refits, and writes `output/overview/outcome_registry.csv`.
5. `50 / 70` — *after* `60` has written `outcome_registry.csv`. Both consume
   `60` outputs and write **figures only**; they never rediscover sidecars,
   rebuild tabular schemas, or fall back to a pre-v4 schema. `50` is
   stratum-/source-level inspection; `70` is corpus-level / cross-stratum.

## Z-plots (`30_zplot.R`)

`30_zplot.R` is sourced *after* a batch fit. It discovers fitted outcomes
from the per-stratum sidecar and renders manuscript-clean z-distribution and
z-extrapolation PDFs from the saved RoBMA 4.0 artifacts
(`zplot_RE4_<dataset_id>.rds` / `zplot_RoBMA4_<dataset_id>.rds`, written by
`20_robma_fit.R`). It uses no global objects and requires no manual artifact
loading; sourcing it is define-only. Per-dataset PDFs are written under
`output/<stratum>/<source_article>/plots/` as
`<dataset_id>_z_plot.pdf` and `<dataset_id>_z_extrapolation.pdf`.
`build_zplots()` returns an invisible per-row log (status / message per
attempted dataset) so missing artifacts or plot failures never abort the run.

```r
source("scripts/30_zplot.R")

# Whole source article (all of its fitted outcomes):
build_zplots(stratum = "fiber", source_article = "nunes2022")

# One dataset by its stable stem:
build_zplots(stratum = "fiber", dataset_id = "nunes2022_fiber_lean_body_mass")

# Whole stratum:
build_zplots(stratum = "fiber")

# Filter to main / exclusion-sensitivity variants; inspect the log:
log <- build_zplots(stratum = "fiber", variant = "main")
log
```

`build_zplots_for_source(stratum, source_article, ...)` and
`build_zplots_for_dataset(stratum, dataset_id, ...)` are thin wrappers. The
old `analyze_robma_fit(basename)` global-object interface is removed; a
deprecated shim forwards by `dataset_id` to `build_zplots()`.

## Estimand tables (`60_estimand_tables.R`)

`60_estimand_tables.R` is the canonical reporting / data-mart layer. It is
artifact-driven and define-only: sourcing it only installs functions; it
discovers and reads the per-stratum sidecars
(`output/<stratum>/<stratum>_robma_summary.csv`) and the optional zplot
diagnostics (`output/<stratum>/<stratum>_zplot_diagnostics.csv`) only when
`build_estimand_tables()` is called, never refits, and fails loudly on an
old-schema sidecar rather than silently remapping legacy columns. Generated
reporting directories (overview / _scratch / the chosen `output_dir`) are
excluded from discovery. Rigor is the headline estimand; effect /
heterogeneity / bias component evidence is secondary.

```r
source("scripts/60_estimand_tables.R")
build_estimand_tables()                       # all strata
build_estimand_tables(stratum = "fiber")      # one stratum
tables <- build_estimand_tables(write_tex = FALSE)   # CSV only, return tibbles
```

It writes (to `output/overview/` by default):

- `outcome_registry.csv` / `outcome_registry_table.tex` — the complete
  audit / data-mart file: one row per analyzed outcome/variant, with the
  derived reporting columns regenerated from sidecar primitives;
- `outcome_registry_compact.csv` — a human-facing browsing view (column
  subset, sorted by descending selected `log10BF_rigor`); the full registry
  above stays the authoritative audit file;
- `stratum_estimands.csv` / `_table.tex` — per stratum + an `Overall` row,
  outcome-weighted;
- `article_balanced_estimands.csv` / `_table.tex` — per stratum + `Overall`,
  source-article-balanced (each source article weighted `1/m` within its
  stratum, so prolific meta-analyses do not dominate);
- `corpus_estimands.csv` / `_table.tex` — numerator/denominator headline
  claims, outcome-weighted and article-balanced;
- `rigor_category_summary.csv`, `rigor_direction_summary.csv`
  (+ `rigor_direction_summary_table.tex`) — rigor category and
  effect/no-effect direction composition by stratum and overall;
- `component_evidence_summary.csv` — secondary effect/het/bias/no-bias
  roll-up in long format (one row per stratum × component).

`build_estimand_tables()` returns invisibly a list of the in-memory tables
and the file paths written (`$files`). Genuine `Inf` / `-Inf` Bayes factors
are preserved end to end (kept in BF denominators; only `NA` / `NaN` are
missing); `log10BF_rigor` is the *selected* statistic
`max(log10BF_rigor_effect, log10BF_rigor_no_effect)`, not a Bayes factor for
one fixed model family. `50_stratum_visuals.R` / `70_corpus_visuals.R`
consume these outputs rather than deriving their own tabular schemas.

## Visual layer (`50_stratum_visuals.R`, `70_corpus_visuals.R`)

The visual layer is strictly **downstream of `60`** and the canonical
reporting/data-mart owner stays `60_estimand_tables.R`. Both visual scripts
are define-only (sourcing attaches no package and does no work; the plotting
runtime is armed lazily inside the entry points), consume
`output/overview/outcome_registry.csv`, write **figures only**, and never
rediscover per-stratum sidecars, rebuild estimand tables, or fall back to a
pre-v4 schema. A missing or non-v4 registry is a hard error instructing the
caller to run `build_estimand_tables()` first. They are kept deliberately
separate: `50` is stratum-/source-level inspection, `70` is corpus-level /
cross-stratum.

```r
source("scripts/50_stratum_visuals.R")
build_stratum_visuals(stratum = "fiber")                       # whole stratum
build_stratum_visuals(stratum = "fiber", source_article = "nunes2022")
build_stratum_visuals(stratum = "fiber", variant = "main")
build_source_visuals("fiber", "nunes2022")                     # convenience

source("scripts/70_corpus_visuals.R")
build_corpus_visuals()                                         # all strata
```

`50` writes `<scope>_effect_estimate_comparison.pdf`,
`<scope>_effect_forest.pdf`, `<scope>_component_violin_stack.pdf`, and
`<scope>_rigor_ranking.pdf` under `output/<stratum>/plots/`
(or `output/<stratum>/<source_article>/plots/` when source-scoped). `70`
writes the component `corpus_component_violin_{effect,heterogeneity,bias}`,
`corpus_component_violin_stack`, `corpus_effect_attenuation_*` PDFs **and**
the rigor set — `corpus_rigor_violin_by_stratum`,
`corpus_rigor_branch_scatter`, `corpus_rigor_direction_composition`,
`corpus_rigor_category_composition`, `corpus_rigor_weighting_comparison`,
`corpus_rigor_ranking_extremes`, `corpus_attenuation_vs_rigor` — to
`output/overview/`. `corpus_bias_vs_rigor.pdf` is an **optional
QC/supplement** plot, **off by default** (it is too mechanically tied to the
rigor definition for the default descriptive suite); enable it with
`build_corpus_visuals(include_bias_vs_rigor = TRUE)`. The evidence-axis
**orchards are retired** and not part of the active visual pipeline
(archived only).

### Rigor-first vs component figures

`70_corpus_visuals.R` includes the **rigor corpus visuals**
(rigor distribution, branch scatter, direction/category
composition, outcome-weighted vs article-balanced comparison, ranking
extremes, attenuation-vs-rigor, modeled-bias-vs-rigor) and `50` adds a
stratum-level rigor ranking. **Rigor plots use raw
`log10` axes** (with reference lines at `-1, -0.5, 0, 0.5, 1`);
`log10BF_rigor` is `max(log10BF_rigor_effect, log10BF_rigor_no_effect)` —
the larger of the effect-supporting and no-effect-supporting no-bias branch
Bayes factors (not a Bayes factor for one fixed model family), with
`rigor_direction` (`effect` / `no_effect`) recording the winning branch.
**Corpus-level component-BF violins also use raw
`log10(BF)` axes and share the exact band/guide family of the rigor
violin. The evidence-axis transform and its terminal Inf bin are RETIRED
from the active visual pipeline** (archived only; never a default 50/70
output). The rigor *and* component violins are **display-capped at
`|log10(BF)| = 2`**: values beyond the cap (incl. `±Inf`) are plotted at the
cap and feed the violin geometry/summaries (raw registry/sidecar values
unchanged), recorded in `$diagnostics`; see
[`../docs/visuals.md`](../docs/visuals.md) for the authoritative contract.
`corpus_component_violin_stack.pdf` is a horizontal three-panel (Effect |
Heterogeneity | Modeled bias) figure; `50` writes a stratum-scoped
`<scope>_component_violin_stack.pdf`. The direction- and
category-composition plots prefer `rigor_direction_summary.csv` /
`rigor_category_summary.csv` and fall back to the registry (with a message)
only if those summaries are absent/incompatible; the weighting comparison
reads `stratum_estimands.csv` + `article_balanced_estimands.csv`.

`corpus_rigor_violin_by_stratum` uses the **same broad visual style
as the component violins** (subdued gray panel, panel border, matching font
sizing, and the same median/IQR/whisker + jitter/violin overlay feel) on a
raw `log10` axis, with a compact subtitle (the rigor definition
lives in this README / the manuscript caption, not in the plot). The
direction- and category-composition bars use the **muted corpus/stratum
Tableau palette** (stable `effect`/`no_effect` and `rigor_category`→colour
mappings; inconclusive / uncategorized are neutral gray) so they match the
violin figure family; stored `rigor_direction` / `rigor_category` values are
unchanged.

`build_corpus_visuals()` gains `include_rigor = TRUE`, `top_n = 12`,
`rigor_axis_cap = NULL`, `include_bias_vs_rigor = FALSE`;
`build_stratum_visuals()` gains `include_rigor = TRUE`,
`rigor_axis_cap = NULL`. Existing public entry points and deprecated aliases
are unchanged. By default `build_corpus_visuals()` returns one fewer
diagnostics row than the full rigor build because `corpus_bias_vs_rigor` is
optional/off; `include_bias_vs_rigor = TRUE` adds the plot and its
diagnostics row back.

Both entry points return an invisible **`$diagnostics`** tibble — one row
per generated plot/panel (covering **both** the component plots and
the rigor plots) with the output path, plot type, scope, rows
available/plotted/dropped, axis ranges used, points outside any fixed axis
override/cap, `n_inf` / `inf_disposition`, and file-exists/size checks. It
is returned only; **no diagnostics CSV is written**. Fixed-axis overrides
that clip plotted values raise a `warning()`. The pre-v4 entry points
(`build_topic_visuals()`, `build_topic_summary()`,
`build_cross_topic_visuals()`, `build_overview()`) survive only as
deprecated aliases that warn and forward.

## Vocabulary

The pipeline uses one identity vocabulary end to end; there is no `topic=`
argument anywhere.

- **`stratum`** — the substantive grouping under a stratification `scheme`
  (nutrition domains here; `scheme = "nutrition_domain"`). `path_stratum` is
  the physical `data/<stratum>/` folder name.
- **`source_article`** — the `<author><year>` token; `source_key` is the
  per-source-article key used for article-balanced summaries; `source_year`
  is parsed from it.
- **`outcome_slug`** — the outcome token (NOT the RoBMA `mu+` effect
  component).
- **`dataset_id`** — the stable compact stem, e.g.
  `whelton2005_fiber_systolic_bp` (unchanged; never renamed).
- **`analysis_id`** — the portable canonical id, e.g.
  `nutrition_v4__fiber__whelton2005__systolic_bp__main`. An `_excl`
  companion shares everything but the trailing variant slug.
- **`analysis_variant`** — `main` or `exclusion_sensitivity` (a formal
  variant; `_excl` rows carry `parent_dataset_id` and a transparent
  `exclusion_reason` placeholder).

The physical layout stays `data/<stratum>/<source_article>/*.csv` and
`output/<stratum>/...`.

The same vocabulary covers **simulated strata**: an audit-ready synthetic CSV
at `data/sim_<cell>/sim<vintage>/<stem>.csv` parses to `stratum = sim_<cell>`,
`source_article = sim<vintage>`, `dataset_id` = the stem, with
`corpus_id`/`scheme` taken from `CONFIG`. No `topic=` anywhere; current
examples and quick-starts use `stratum=`.

## Non-default output roots (simulation-ready)

The main pipeline ingests/reports a separate (e.g. simulation) corpus **with
no core code change** — one scheme/corpus per output root. Set the corpus
identity + a separate root in `CONFIG` before fitting, then pass the matching
root/output_dir to each downstream stage. Verified argument names:

| Stage | Output-root selector |
|-------|----------------------|
| `batch_fit()` / `fit_robma_models()` | `CONFIG$output_root` (read at call time) |
| `sidecar_acceptance(stratum=)` | `CONFIG$output_root` (consistent with fitting; no arg) |
| `sidecar_acceptance_all()` | `output_root =` (defaults to `CONFIG$output_root`); add `require_artifacts = FALSE` for lightweight roots that omit `.rds` fits |
| `build_zplots()` | `output_root =` (default `"output"`) |
| `build_estimand_tables()` | `root =` (read sidecars) + `output_dir =` (write tables) |
| `build_stratum_visuals()` / `build_source_visuals()` | `root =` (write plots) + `output_dir =` (read registry) |
| `build_corpus_visuals()` | `output_dir =` (read registry + write figures) |

Simulation-specific latent/truth/manifest files stay **out of `data/`** (the
loader must only see analysis-ready study-level CSVs). The full step-by-step
convention and worked example are in
[`../docs/pipeline_layout.md`](../docs/pipeline_layout.md); the empirical and
simulation roots must never be mixed.

## Effect-size input contract

Each analysis-ready CSV supplies one standardized-mean-difference effect-size
pair, fed to RoBMA as `yi`/`sei` under `CONFIG$measure = "SMD"`:

- **Preferred / default:** `g` + `se_g` (Hedges' *g*).
- **Fallback (no rename needed):** `d` + `se_d` (Cohen's *d*) — accepted as a
  close SMD approximation; the pipeline does not distinguish *d* from *g*
  downstream.

Resolution is the shared `.resolve_effect_input()` (`00_utils.R`), with a
**fixed, non-configurable** preference order:

- `g`/`se_g` present → use `g`/`se_g`.
- `g`/`se_g` absent but `d`/`se_d` present → use `d`/`se_d` (a message notes
  the fallback).
- Both pairs present → use `g`/`se_g` (a message notes the preferred pair).
- Neither complete pair present → stop with a clear error: the dataset needs
  either `g` + `se_g` or `d` + `se_d`.

The same finite-estimate / finite-positive-SE validation is applied to
whichever pair is selected; `< 3` finite rows are skipped. `40_batch_fit.R`
uses the same accepted set (`.has_effect_input()`) to decide which datasets
are runnable, so the runnable filter cannot drift from the fitter. Which pair
was used is reported in the fit log (`effect_input=g_se_g`/`d_se_d`); it is
not added to the lean sidecar schema (that would bump `schema_version` and
invalidate every prior row for resume — see *Resume / stale-artifact
rejection*).

## The lean sidecar

`20_robma_fit.R` appends one row per dataset to the canonical per-stratum
sidecar `output/<stratum>/<stratum>_robma_summary.csv`. The exact column set
and order is `.SIDECAR_V4_COLS` (00_utils.R) — a **lean primitive/audit
table**, not a reporting dump. It carries:

1. identity / corpus metadata (incl. `schema_version`, `estimand_version`);
2. source/dataset metadata (`n_studies`);
3. baseline (`brma`) + RoBMA-PSMA posterior estimates (`mu_*`, `tau_*`);
4. marginal component evidence (effect / het / bias / no-bias);
5. joint μ×ω model-family evidence (the four cells);
6. **rigor evidence** — both branch fields plus the headline:
   - `log10BF_rigor_effect`  = BF for `M_{mu+ . omega0}`
   - `log10BF_rigor_no_effect` = BF for `M_{mu0 . omega0}`
   - `log10BF_rigor` = `max(rigor_effect, rigor_no_effect)` (selected; never
     collapsed away from its branches)
   - `rigor_direction` ∈ {`effect`, `no_effect`} (parser-safe; never
     `"null"`; ties → `effect`)
   - `rigor_margin`, `rigor_category`
7. validation/status (component validation gates, partition, failure reason);
8. fit configuration + reproducibility (`config_hash`, `script_hash`,
   `robma_version`, `run_id`, ...).

Derived reporting conveniences (Δμ / attenuation / shrink / sign-flip /
CI-contains-zero and the μ|ω conditionals) are **not** stored; they will be
regenerated from these primitives by `60_estimand_tables.R`. Secondary
as_zplot bias diagnostics (`ODR`/`EDR`/`Soric_FDR`/`MissingN`) are written to
a separate `output/<stratum>/<stratum>_zplot_diagnostics.csv`
(`.ZPLOT_DIAG_COLS`), keyed by `dataset_id`, so the canonical sidecar stays
lean. The per-dataset raw model summaries and the model-family validation
table are first-class audit artifacts under
`output/<stratum>/<source_article>/audit/`.

## Fiber-only workflow (pilot / verification)

```r
source("scripts/00_utils.R")
source("scripts/10_load_data.R")
source("scripts/20_robma_fit.R")   # provides CONFIG + fit_robma_models()
source("scripts/40_batch_fit.R")

# Plan only (no fitting):
batch_fit(stratum = "fiber", dry_run = TRUE)

# Fit the stratum (subprocess-isolated; contract-aware resume):
batch_fit(stratum = "fiber", resume = FALSE)

# Rebuild the sidecar from saved RDS artifacts without refitting:
backfill_sidecars(stratum = "fiber")

# Acceptance gate (registry anti-join + rigor identities + version checks):
ac <- sidecar_acceptance(stratum = "fiber")   # one stratum
stopifnot(ac$ok)

# Corpus-wide contract gate (all discovered strata):
acc <- sidecar_acceptance_all()               # defaults: require_artifacts=TRUE
stopifnot(acc$ok)
```

### Acceptance is a contract gate, not a quality judgement

`sidecar_acceptance(stratum = ...)` checks **one** stratum;
`sidecar_acceptance_all()` discovers every per-stratum sidecar under the
output root and runs the same per-stratum logic corpus-wide, adding a few
non-blocking artifact/zplot/audit warnings and a compact PASS/FAIL summary.
Acceptance is the **contract / reproducibility gate between fitting
(00/10/20/40) and reporting (60 → 50/70)**: PASS means the sidecars are
structurally trustworthy v4 outputs. It is **not** a scientific
quality judgement about any outcome's evidence.

`sidecar_acceptance_all(output_root = NULL, require_artifacts = TRUE,
require_zplots = FALSE, fail_on_warning = FALSE, verbose = TRUE)` returns
invisibly `list(ok, summary, checks, problems)` (base data.frames). It
refits nothing, rewrites no sidecars, rebuilds no tables, repairs no schema,
and writes no CSV.

**Hard failures (gate `$ok`):** missing/unreadable sidecar for a discovered
stratum; any of the 17 `sidecar_acceptance()` checks failing (registry
anti-join, exact `.SIDECAR_V4_COLS`, current `schema_version` /
`estimand_version`, uniform+current `config_hash`, RoBMA major ≥ the v4
minimum, unique `analysis_id` incl. variant slug, valid `analysis_variant`,
valid `rigor_direction`, component/partition validation flags, unresolved
labels that would invalidate rigor extraction, and the rigor
identities); missing `.rds` fit artifacts when `require_artifacts = TRUE`;
missing zplot-diagnostics CSV when `require_zplots = TRUE`.

**Warnings (non-blocking unless `fail_on_warning = TRUE`):** missing `.rds`
fit artifacts when `require_artifacts = FALSE` (the public repo legitimately
omits regenerable fits); missing zplot diagnostics when
`require_zplots = FALSE`; `family_evidence_uncertain` rows (still
reportable, flagged for audit).

Run a single stratum (fiber) end to end and require all acceptance checks to
pass before running `sidecar_acceptance_all()` over the full corpus.
`60_estimand_tables.R` is strictly **downstream** of this gate: it checks v4
column presence so it cannot silently consume a pre-v4 sidecar, but it never
re-runs the full contract and **never repairs/remaps** a sidecar — run the
acceptance gate (all PASS) before `build_estimand_tables()`.

## Resume / stale-artifact rejection

`batch_fit(resume = TRUE)` skips a dataset only when **both** the RoBMA 4.0
fit artifacts exist **and** a sidecar row matches on `dataset_id`, RoBMA
major version ≥ the v4 minimum, the current `schema_version` /
`estimand_version`, and the current `config_hash`. Archived RoBMA 3.6.x
artifacts, old effect-only-rigor sidecars, pilot scratch rows, and
incompatible-config rows therefore never satisfy resume. Bumping
`.SCHEMA_VERSION` or `.ESTIMAND_VERSION` in `00_utils.R` changes the
`config_hash` and invalidates every prior row for resume by construction.

## Reproducibility notes

- Analysis-ready CSVs and extraction workbooks are immutable inputs; all
  derived products live under `output/`.
- A schema/contract change is a `00_utils.R` edit (versions + column vector);
  it propagates to 20/40 with no per-script column lists to keep in sync.
- See [`../data_dictionary.md`](../data_dictionary.md) for the input data
  contract and the `_excl` policy, [`../docs/output_contract.md`](../docs/output_contract.md)
  for the file-by-file output contract, [`../docs/visuals.md`](../docs/visuals.md)
  for the figure axis contract, and the [root README](../README.md) for the
  estimand math.
