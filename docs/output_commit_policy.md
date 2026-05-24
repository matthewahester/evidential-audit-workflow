# Output Commit Policy

What to commit to Git, what to leave on disk only, and how to override
either default. Companion to [`output_contract.md`](output_contract.md)
(which describes the *artifacts*); this file describes the *commit
policy* for those artifacts.

The authoritative ignore rules are in [`/.gitignore`](../.gitignore);
this document explains the rationale and lists the explicit force-add
exceptions.

## Principles

1. **Commit source + small reproducibility artifacts.** Anything an
   external reader needs to understand the pipeline, reproduce the
   reporting tables from the committed primitives, or read the
   manuscript figures.
2. **Ignore heavy generated artifacts.** RoBMA fit objects, full
   simulation output trees, multi-GB raw draws, and archived legacy
   trees stay out of GitHub. They are regenerable from the committed
   source, data, and design CSV.
3. **Prefer path-specific ignore rules over blanket extension rules.**
   The one global-extension rule is `*.rds` (every `.rds` in this repo
   is a regenerable MCMC fit object or zplot artifact). All other heavy
   data lives behind directory-scoped rules.
4. **`git add -f` is the override.** Any file blocked by an ignore
   rule can still be force-added; the policy is a default, not a wall.

## Commit (track in Git)

| Category | Examples | Why |
|---|---|---|
| Source code | `scripts/*.R`, `simulation/scripts/*.R` | The pipeline itself. |
| Public documentation | `README.md`, `scripts/README.md`, `docs/*.md`, `simulation/README*.md`, `simulation/design_memo*.md` | How to read + run the repo. |
| Reproducibility metadata | `CITATION.cff`, `LICENSE`, `LICENSE-data`, `.gitignore`, `nutrition_publication_bias.Rproj` | Standard repo skeleton. |
| Inputs (immutable) | `data/<stratum>/<source>/*.csv`, `data/<stratum>/<source>/*.xlsx`, `data/reference_sds.yml` | Analysis-ready empirical inputs. Never overwritten by the pipeline. |
| Simulation design | `simulation/config/design_v3_full36.csv` | Authoritative 36-cell design grid. |
| Lean v4 sidecars (the canonical reporting primitive) | `output/<stratum>/<stratum>_robma_summary.csv`, `output/<stratum>/<stratum>_zplot_diagnostics.csv` | Regenerates every overview table without rerunning MCMC. |
| Per-source audit artifacts | `output/<stratum>/<source>/audit/*.csv` (model_family_validation, models_individual, models_marginal) | First-class audit per [`output_contract.md`](output_contract.md) §1. (The `.bak` doubles are ignored.) |
| Per-source z-plot PDFs | `output/<stratum>/<source>/plots/*_z_plot.pdf`, `*_z_extrapolation.pdf` | Manuscript-relevant; small vector PDFs. |
| Overview tables | `output/overview/*.csv`, `output/overview/*.tex` | v4 reporting from `60_estimand_tables.R`. |
| Overview figures | `output/overview/corpus_*.pdf` | Corpus-level manuscript figures from `70_corpus_visuals.R`. |
| Stratum figures | `output/<stratum>/plots/*.pdf` | Stratum/source inspection figures from `50_stratum_visuals.R`. |
| Small archive metadata | `archive/55_orchard_visuals.R` (frozen retired diagnostic) | Sole archived item still tracked; retired v2 resampling sub-project and the inactive renv lockfile were removed from the public tree during cleanup. |

## Defer until manuscript freeze

These are real, useful local artifacts; they are **not** ignored
(`git status` will show them as untracked), but they are intentionally
**not** committed yet. Commit them in a single "simulation library
freeze" commit only when `B` (resampling/sampling replicate count) and
`n_reps` (per-cell synthetic-library depth) are settled for the
submission/preprint:

| Category | Examples | Why deferred |
|---|---|---|
| Synthetic data inputs | `data/sim_<cell_slug>/sim2026/repNNNN.csv` (~900–5,400 files, a few MB to ~17 MB total) | Library will be regenerated if `n_reps` changes (current 150 may move to 500 for the finite-library sensitivity tier). |
| Simulation provenance | `simulation/manifests/*.csv`, `simulation/latent/sim_*/sim2026/*_latent.csv` (< 30 MB total) | Pinned to the current generation run; regenerated atomically alongside `data/sim_*/`. The current 125-vs-150 latent/data mismatch is a concrete signal that the library is mid-state. |

## Ignore (out of Git, regenerable or archival)

| Category | Pattern | Why |
|---|---|---|
| Fit / zplot RDS objects | `*.rds` (anywhere) | Several CPU-hours to regenerate; 16 GB+ in `output_sim_v30/`. |
| Other R binary objects | `*.Rds`, `*.RData`, `*.rda` | Same. |
| Active simulation output root | `output_sim_v30/` | 16 GB of regenerable sim sidecars + audit + RDS. |
| Active simulation results | `simulation/results/` | 4 GB+ of raw draws and figures; regenerable. |
| Heavy simulation raw draws | `simulation/results/**/*_size_curve_draws.csv`, `simulation/results/empirical_resampling/empirical_resampling_size_curve.csv` | Belt-and-braces — each exceeds GitHub's 100 MB per-file limit. |
| Local probe scratch | `output*/_scratch/` | Throwaway. |
| Heavy archive: RoBMA 3.6 snapshot | `archive/RoBMA_3_6/` | 71 GB vendored library + retired output tree. |
| Generic archive guards | `archive/**/output*/`, `archive/**/results*/`, `archive/**/library/`, `archive/**/staging/` | Future-proofing if more archive folders are added. |
| renv runtime infra | `/renv/`, `/renv.lock`, `/.Rprofile`, `**/renv/library/`, `**/renv/staging/` | renv is intentionally inactive during active development; see [`environment.md`](environment.md). |
| R caches | `.Rcache/`, `.cache/`, `*_cache/` | Local-only. |
| Atomic-rename leftovers | `*.bak`, `*.tmp`, `*.swp`, `*.swo`, `*~` | Editor / atomic-rename detritus. |
| Editor / IDE | `.Rproj.user/`, `.vscode/`, `.idea/`, `*.code-workspace` | Per-user state. |
| OS noise | `.DS_Store`, `Thumbs.db`, `Desktop.ini` | Per-machine. |
| R session | `.Rhistory`, `.Rapp.history`, `.RData`, `.Ruserdata` | Per-session. |
| Logs | `*.log`, `batch_status_*.csv` | Run logs. |
| Manuscript LaTeX build | `manuscript/**/*.{aux,log,out,toc,lof,lot,bbl,blg,fls,fdb_latexmk,synctex.gz,run.xml}` | Regenerable from `.tex`. |

## Heavy-file watchlist

These files exist on disk now and **must never be committed**:

| Path | Size |
|---|---|
| `simulation/results/cell_behavior/synthetic_cell_size_curve_draws.csv` | 2.4 GB |
| `simulation/results/empirical_resampling/empirical_resampling_size_curve.csv` | 1.3 GB |
| `simulation/results/empirical_weighted_synthetic/empirical_weighted_synthetic_size_curve_draws.csv` | 563 MB |
| `archive/RoBMA_3_6/output/...` (58 GB) | 58 GB tree |
| `archive/RoBMA_3_6/results/...` (13 GB) | 13 GB tree |
| `output_sim_v30/sim_*/sim2026/*.rds` (21,600 files) | ~10–15 GB |
| Various RoBMA 3.6 snapshot RDS files in `archive/RoBMA_3_6/` | up to ~100 MB each |

All are covered by the rules in `.gitignore`.

## Overriding the default (force-add)

If a normally-ignored file must be committed (e.g. a pinned
representative fit object, or a sim summary CSV the manuscript will
cite), force-add it explicitly:

```bash
git add -f output/<stratum>/<source>/fit_RoBMA4_<dataset_id>.rds
git add -f simulation/results/cell_diagnostics_rigor.csv
git add -f output_sim_v30/<stratum>/<stratum>_robma_summary.csv
```

Once a file is tracked, the `.gitignore` rule no longer applies to it
(git ignore-rules only affect untracked files). Document any force-add
in the release notes so future readers know why an outlier ships.

## Sim overview / summary CSVs (deferred until manuscript freeze)

The simulation sub-project produces several small, manuscript-candidate
summary CSVs that live inside the ignored `simulation/results/` and
`output_sim_v30/overview/` trees:

- `simulation/results/cell_diagnostics_{rigor,component}.csv`
- `simulation/results/fit_progress_{live,overall}.csv`
- `simulation/results/empirical_resampling/empirical_resampling_observed.csv` (+ `_observed_size_intervals.csv`, `_report.md`)
- `simulation/results/empirical_weighted_synthetic/*.csv` (excluding `*_size_curve_draws.csv`) + `*_report.md`
- `simulation/results/agreement/*.csv` + `_report.md`
- `simulation/results/figures/**/*.pdf` + `*_report.md`
- `output_sim_v30/overview/*.csv`, `*.tex`

**Decision (resolved)**: defer until `B` and `n_reps` are
manuscript-frozen. When the freeze commit lands, force-add the specific
small files the manuscript cites; do **not** relax the directory ignore
rules (the multi-GB raw-draws CSVs share those directories).
