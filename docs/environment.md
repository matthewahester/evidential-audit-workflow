# Environment

The R / JAGS / package environment the RoBMA 4.0 selected-rigor pipeline was
last verified against. This is a **record of the working environment**, not an
auto-activated lockfile — `renv` is **intentionally inactive** during active
development (see below).

**Date checked:** 2026-05-17 (post-R-4.6-upgrade verification pass).

## System layer

| Component | Version / location | Notes |
|-----------|--------------------|-------|
| R | **4.6.0 (2026-04-24 ucrt)**, `x86_64-w64-mingw32` | Manually upgraded from 4.5.1. Meets RoBMA 4.0's R ≥ 4.2. |
| JAGS | 4.3.1 (`C:\Program Files\JAGS\JAGS-4.3.1`) | Current **stable** release (not beta). Meets RoBMA 4.0's JAGS ≥ 4.3.1. Unaffected by the R upgrade; `rjags::jags.version()` returns `4.3.1` under R 4.6. |
| Rtools | **Rtools46 NOT installed** — only `rtools43` / `rtools45` present (`RTOOLS45_HOME` set; `make` resolves to `C:\rtools45\usr\bin\make.exe`). | Rtools45 is **mismatched** to R 4.6 for *source* builds. **Non-blocking**: all pipeline packages were installed as CRAN **binaries** under R 4.6 and load correctly (RoBMA's compiled code links fine). Install **Rtools46** only if source compilation under R 4.6 is later required. |
| User library | `C:/Users/Matt/AppData/Local/R/win-library/4.6` | Fresh R-4.6 user library, created during this pass; now `.libPaths()[1]`. The old `…/win-library/4.5` library is not on R 4.6's path. |

## renv status — intentionally inactive

`renv` is **inactive** and (under R 4.6) not even installed: no `.Rprofile`,
no `renv/activate.R`, `RENV_PROJECT` unset; the plain R user library is used.

The stale RoBMA-3.6-era `renv.lock` and the renv infra (`.Rprofile`,
`renv/.gitignore`, `renv/activate.R`, `renv/settings.json`) were **archived**
to `archive/renv_inactive_2026-05-17/` (moved, not deleted; `renv.lock` via
`git mv` so history is preserved). `.gitignore` now ignores any
accidentally-regenerated root `renv/`, `renv.lock`, `.Rprofile` so a stray
renv run is never silently tracked.

renv is intentionally inactive during active development. The current
reproducibility record is **this file** (`docs/environment.md`). renv may be
reintroduced **only at release freeze, after an explicit decision and restore
testing** — and with a freshly regenerated lockfile, not the archived stale
one. Do not run `renv::init()`, `renv::restore()`, or `renv::snapshot()`
during active development.

## Key package versions

Verified loading under **R 4.6.0**, 2026-05-17. The full pipeline stack was
**reinstalled** into the fresh R-4.6 user library (the R minor-version bump
means the 4.5 library is not reused). All installs were CRAN Windows
**binaries**; versions match the previously verified set, with `processx`
now at the current CRAN release.

| Package | Version | Role |
|---------|---------|------|
| RoBMA | 4.0.0 | Product-space ensemble; rigor estimand source |
| BayesTools | 0.3.0 | RoBMA model-family machinery |
| runjags | 2.2.2.5 | JAGS interface |
| rjags | 4.17 | JAGS bindings (binds JAGS 4.3.1 under R 4.6) |
| callr | 3.7.6 | Subprocess isolation for `batch_fit()` |
| processx | **3.9.0** | callr transitive dep (now current — see note) |
| ps | 1.9.3 | callr transitive dep |
| tidyverse | 2.0.0 | Data wrangling (reporting/visual layer) |
| readr | 2.2.0 | CSV I/O |
| fs | 2.1.0 | Path handling (70) |
| stringr | 1.6.0 | String handling (50) |
| patchwork | 1.3.2 | Figure composition (50/70) |
| ggplot2 | 4.0.3 | Plotting (50/70) |
| knitr | 1.51 | (optional) reporting |
| rmarkdown | 2.31 | (optional) reporting |
| tinytex | 0.59 | (optional) TeX rendering |
| digest | 0.6.39 | Stable hashing in `00_utils.R` (optional; never auto-installed) |

Key transitive deps verified present under R 4.6: `dplyr` 1.2.1,
`tibble` 3.3.1, plus the usual Rcpp/RcppArmadillo/coda/etc. pulled as RoBMA
dependencies.

## Reinstall / update note (2026-05-17, post-R-4.6)

- The R 4.6 user library started empty; the pipeline-critical stack was
  reinstalled from CRAN as binaries. Reproducibility-critical versions are
  unchanged: **RoBMA 4.0.0 / BayesTools 0.3.0** (CRAN latest still equals the
  previously verified versions — no estimand-numerics change).
- `processx` 3.8.7 → **3.9.0**: the earlier locked-DLL blocker (under R 4.5)
  is **resolved** — in the fresh R-4.6 library it installed cleanly. `callr`
  remains 3.7.6.
- No broad ecosystem update was performed; only the required pipeline stack
  (and its unavoidable dependencies) was installed.

## Reproducibility note

Numeric reproducibility of the selected-rigor estimand is defined by
**RoBMA 4.0.0 + BayesTools 0.3.0 + JAGS 4.3.1**, plus the fixed seed in the
`CONFIG` block of `scripts/20_robma_fit.R`. Posterior summaries and inclusion
Bayes factors reproduce up to small numerical variation across `RoBMA` / JAGS
releases and R minor versions. To reproduce on a fresh machine: install
R ≥ 4.2 (with the matching Rtools if building from source; CRAN binaries
otherwise), JAGS ≥ 4.3.1, then `RoBMA` 4.0.0 / `BayesTools` 0.3.0 and the
plotting/reporting packages above into a plain user library — **no renv step
needed**. The archived `renv.lock` is **not** the v4 reference.

## Smoke test (2026-05-17, under R 4.6.0)

Non-destructive checks, no MCMC, committed `output/overview` untouched
(scratch output only):

- All 17 pipeline packages `requireNamespace()` TRUE; `library(RoBMA)`
  attaches 4.0.0; `rjags::jags.version()` → 4.3.1.
- All 8 active scripts (`00`–`70`) `parse()` cleanly.
- Define-only source of `00`→`70` in a fresh env: load sentinel set, all 11
  entry points present, **no heavy namespace** (RoBMA/rjags/runjags/ggplot2/
  tidyverse) attached merely by sourcing — the define-only contract holds
  under R 4.6.
- `list_datasets()` → 175 datasets across all 8 strata.
- `sidecar_acceptance(stratum = "fiber")` → **all 17 checks PASS**
  (`config_hash` unchanged at `7011227781d1`; schema/estimand contract
  intact under R 4.6).
- `build_estimand_tables(stratum = "fiber", write_tex = FALSE)` to a scratch
  dir → full table set returned, 22-row outcome registry, no errors/warnings.
