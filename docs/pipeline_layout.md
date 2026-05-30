# Pipeline Layout

What each top-level folder is for, and the operating rule for keeping the
nutrition workflow and the simulation study from entangling. The legacy
v2 `resampling/` sub-project has been retired (its active v4 successors
live in `simulation/scripts/`); see the retired-material notes below.

## Repository tree

```text
.
├── scripts/                 Active RoBMA 4.0 rigor pipeline (00–70) + README
├── data/                    Immutable analysis-ready CSVs + extraction .xlsx
│   ├── <path_stratum>/<source_article>/<dataset_id>.csv (+ .xlsx)
│   └── sim_<cell_slug>/sim2026/repNNNN.csv  generated SYNTHETIC CSVs
│                              (NOT shipped on GitHub; regenerable from
│                              simulation/config/design_v3_full36.csv
│                              + the fixed generation seed)
├── output/                  ACTIVE nutrition output root (one scheme/corpus)
│   ├── <stratum>/                       per-stratum sidecars + per-source fits
│   │   ├── <stratum>_robma_summary.csv
│   │   ├── <stratum>_zplot_diagnostics.csv
│   │   ├── plots/                       per-stratum manuscript figures (50)
│   │   └── <source_article>/{audit,plots}/ + fit/zplot .rds (rds IGNORED)
│   └── overview/            60 reporting tables + 70 corpus figures
├── output_sim_v30/          SEPARATE simulation output root (IGNORED;
│                            16 GB of regenerable sim sidecars + fits)
├── docs/                    This documentation set (Markdown)
├── simulation/              SEPARATE sub-project (own README/config/scripts)
│   ├── scripts/             active simulation source (00–75)
│   ├── config/              canonical 36-cell design grid
│   ├── manifests/, latent/  NOT shipped on GitHub; local generated
│                            artifacts; regenerated alongside data/sim_*/
│                            by sim_generate_library()
│   └── results/             IGNORED — sim diagnostics + raw draws
│                            (4 GB+; regenerable from scripts + design CSV)
├── archive/                 Retired / frozen material
│   ├── 55_orchard_visuals.R   small retired diagnostic (committed for provenance)
│   └── RoBMA_3_6/             IGNORED — 71 GB RoBMA-3.6 snapshot
├── Rigor_Manuscript/        Manuscript source (pdfLaTeX; 01_main, 02_supplement,
│                            03_exec_summary, 04_shared, 05_artifacts, 06_refs,
│                            docs, tools) — sibling working directory,
│                            not inside this repo
├── CITATION.cff, LICENSE, LICENSE-data, README.md
```

> Retired sub-projects (resampling v2, the inactive renv lockfile archive)
> were archived during cleanup and subsequently removed from the public
> tree. Provenance is preserved in commit history (search the log for
> `archive: remove inactive renv lockfile` and the surrounding
> `publication-cleanup:` commits).

## One scheme/corpus per output root (the operating rule)

The v4 sidecar carries `scheme` and `corpus_id` as metadata fields, so the
estimand layer is corpus-agnostic. We deliberately chose the **low-risk
Option A** for physical organisation:

> **One scheme/corpus per output root.** Do not nest by `(scheme, stratum)`.

The nutrition workflow stays physically organised as `output/<stratum>/...`
under a single root, `output/`. A different scheme/corpus uses its **own
output root**, e.g.:

```text
output/                     the current empirical nutrition workflow
output_sim_v30/             the active synthetic full36 cell library
                            (corpus_id = sim_library_v30, scheme = simulation_cell)
```

This keeps the simulation study physically beside the main nutrition
workflow without entangling it: each is a separate root with its own
sidecars and its own `overview/`, all consuming the same `00_utils.R`
estimand/schema layer. `simulation/` is a **separate sub-project** with
its own `README`, `config`, and `scripts`; it is out of scope for the
main nutrition pipeline scripts and must not be moved into `scripts/` or
`output/`. The legacy v2 resampling sub-project is **retired** and was
removed from the public tree during cleanup.

A future `(scheme, stratum)` directory refactor is explicitly **not** part of
the current contract; revisit only if multiple schemes must coexist in one
root.

Concrete output roots (illustrative — pick names per project):

```text
output/                       empirical nutrition corpus (current default)
output_sim_v30/               synthetic full36 cell library (active)
```

(The active empirical resampling / synthetic composition outputs are
diagnostics under `simulation/results/`, not a separate `output_*` root;
see `docs/output_contract.md` §6. The legacy v2 `output_resampling_*`
root names are retired with the archived resampling sub-project.)

## Simulation-ready main-pipeline convention

The main pipeline ingests and reports **simulated strata with no core code
change**. The shared *input* contract is reused; the *output* roots are kept
separate.

**1. Audit-ready synthetic CSVs live in the main `data/` tree**, matching the
existing audit loader structure `data/<path_stratum>/<source_article>/<dataset_id>.csv`:

```text
data/sim_<cell_slug>/sim2026/repNNNN.csv
e.g. data/sim_null_lowhet_clean/sim2026/rep0001.csv
```

`10_load_data.R` then parses this with no change:

| Field | Value for the example above |
|-------|------------------------------|
| `path_stratum` / `stratum` | `sim_null_lowhet_clean` |
| `source_article` / `source_key` | `sim2026` (→ `source_year` 2026) |
| `outcome_slug` | `rep0001` (the compact stem; **not** the dataset_id) |
| `dataset_id` | derived `<source_article>_<stratum>_<outcome_slug>` = `sim2026_sim_null_lowhet_clean_rep0001` |
| `analysis_id` | `<corpus>__<stratum>__<source>__<outcome>__<variant>` = `sim_library_v30__sim_null_lowhet_clean__sim2026__rep0001__main` |
| `corpus_id` / `scheme` | from `CONFIG` (see below) |

Synthetic CSVs must be the **same analysis-ready study-level shape** as
empirical ones (`g`/`se_g` or the `d`/`se_d` fallback; see
[`../data_dictionary.md`](../data_dictionary.md)). The on-disk stem is the
**compact** `repNNNN` (the replicate index) — the synthetic cell lives in
the folder path, not the filename. A cell-bearing stem must **not** be
used: it produced a doubled `dataset_id`
(`sim2026_sim_<cell>_<cell-tail>_rNNNN`), which is exactly why the stem is
compact.

**2. Simulation-specific latent / truth / manifest files stay OUT of
`data/`.** The audit loader must only ever see analysis-ready study-level
CSVs. Generators, true parameters, k-samplers, manifests, and results belong
under the simulation sub-project, e.g.:

```text
simulation/latent/...      true effect / heterogeneity / bias parameters
simulation/manifests/...   (cell, replicate) bookkeeping
simulation/results/...     simulation-specific diagnostics
```

**3. Set the corpus identity + a separate output root before fitting**, then
run every downstream stage against that root (verified argument names):

```r
source("scripts/00_utils.R"); source("scripts/10_load_data.R")
source("scripts/20_robma_fit.R"); source("scripts/40_batch_fit.R")

CONFIG$output_root <- "output_sim_v30"     # separate root: no mixing
CONFIG$corpus_id   <- "sim_library_v30"
CONFIG$scheme      <- "simulation_cell"

# Discover synthetic strata (no fitting):
subset(list_datasets(), grepl("^sim_", stratum))

# PER-STRATUM FITTING ONLY. Compact repNNNN stems are NOT unique across
# strata, and load_datasets() assigns each dataset to an R object named
# by the bare stem. A single batch_fit(source_article = "sim2026") over
# ALL sim strata collides every repK object and fits the WRONG data
# (Pass 4A: integrity_flag = FAIL_collision). Always loop one stratum at
# a time so load_datasets() holds only that stratum's 25 unique objects:
for (st in sim_load_design()$stratum)
  batch_fit(stratum = st, source_article = "sim2026", resume = TRUE)
# Canonical stratum-scoped fitter — derives the dataset list from the
# generated CSVs on disk (no replicate-count config), resume-safe:
#   sim_fit_library()   in simulation/scripts/40_sim_run.R
# Do NOT hand-roll an all-strata batch_fit() call.

# Single-stratum acceptance honors CONFIG$output_root (no output_root arg):
sidecar_acceptance(stratum = "sim_moderate_midhet_modbias")

# Corpus-wide acceptance takes an explicit root. For a lightweight root
# where .rds fits are intentionally omitted, relax the artifact check:
sidecar_acceptance_all(output_root = "output_sim_v30",
                       require_artifacts = FALSE)

# Reporting + visuals all take explicit root / output_dir args:
source("scripts/60_estimand_tables.R")
build_estimand_tables(root = "output_sim_v30",
                      output_dir = "output_sim_v30/overview",
                      write_tex = FALSE)
source("scripts/30_zplot.R")
build_zplots(stratum = "sim_moderate_midhet_modbias",
             output_root = "output_sim_v30")
source("scripts/50_stratum_visuals.R")
build_stratum_visuals(stratum = "sim_moderate_midhet_modbias",
                      root = "output_sim_v30",
                      output_dir = "output_sim_v30/overview")
source("scripts/70_corpus_visuals.R")
build_corpus_visuals(output_dir = "output_sim_v30/overview")
```

> The fit/acceptance/reporting calls above are the *post-fit* workflow
> and require the full36 × 25 library to be complete
> (`library_status = complete_clean`, `integrity_flag = ok`). They are
> shown here as the output-root contract, not as something to run while
> the fit is still in progress.

Argument-name summary (no core code change needed):

| Stage | How the output root is selected |
|-------|---------------------------------|
| `batch_fit()` / `fit_robma_models()` | `CONFIG$output_root` (read at call time) |
| `sidecar_acceptance(stratum=)` | `CONFIG$output_root` (consistent with fitting; no arg) |
| `sidecar_acceptance_all()` | `output_root =` (defaults to `CONFIG$output_root`); add `require_artifacts = FALSE` for lightweight roots |
| `build_zplots()` | `output_root =` (default `"output"`) |
| `build_estimand_tables()` | `root =` (read sidecars) + `output_dir =` (write tables) |
| `build_stratum_visuals()` / `build_source_visuals()` | `root =` (write plots) + `output_dir =` (read registry) |
| `build_corpus_visuals()` | `output_dir =` (read registry + write figures) |

No reporting or visual script assumes nutrition labels, the eight nutrition
strata, or a fixed root: they operate on whatever strata the chosen root /
registry contains.

## Define-only contract

Every `scripts/*.R` file is **define-only**: `source()`-ing installs functions
and a load sentinel and does nothing else (no package attach, no MCMC, no
disk I/O). Work is triggered only by calling an entry-point function. Runtimes
(RoBMA/JAGS, plotting) are armed lazily inside the entry points.
