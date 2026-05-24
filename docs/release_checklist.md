# Public-Release Checklist

A short, practical checklist for cutting a public release of the RoBMA 4.0
selected-rigor pipeline. Not a CI spec — a human pre-flight.

## 1. Scratch / private hygiene

- [ ] `output/_scratch/` removed or excluded; no scratch CSVs beside trusted
      sidecars.
- [ ] No private notes, credentials, or internal release memos committed.
- [ ] `archive/RoBMA_3_6/` remains ignored (not committed). Other retired
      sub-projects (v2 resampling, the inactive renv lockfile) were removed
      from the public tree during cleanup; only
      `archive/55_orchard_visuals.R` is tracked under `archive/`.
- [ ] `simulation/scripts/` and `simulation/config/` are committed
      (active sub-project source). `simulation/manifests/`,
      `simulation/latent/`, and `data/sim_<cell_slug>/` are intentionally
      **deferred** until `B` and `n_reps` are manuscript-frozen — verify
      they are still untracked.

## 2. `.gitignore`

- [ ] Large fit objects (`*.rds`, `*.Rds`, `*.RData`, `*.rda`) excluded
      globally; force-add only specific fits that must ship.
- [ ] `output/_scratch/`, `output_sim_v30/`, `simulation/results/`,
      and `archive/RoBMA_3_6/` ignored.
- [ ] The three giant `*_size_curve_draws.csv` files explicitly listed
      as belt-and-braces ignores (each >100 MB).
- [ ] Committed: per-stratum `*_robma_summary.csv`,
      `*_zplot_diagnostics.csv`, `output/<stratum>/<source>/{audit/,plots/}`,
      `output/<stratum>/plots/`, and `output/overview/` tables/figures.

## 3. Outputs regenerate from scripts

- [ ] From the committed sidecars, `build_estimand_tables()` (60) reproduces
      `output/overview/` tables.
- [ ] `build_zplots()` (30), `build_stratum_visuals()` (50),
      `build_corpus_visuals()` (70) reproduce the figures from those tables.
- [ ] `sidecar_acceptance()` passes on every stratum (registry anti-join,
      rigor identities, schema/estimand versions, config hash, RoBMA major
      version ≥ v4 minimum).

## 4. Ship `.rds` fits?

- [ ] Decide: omit (default — scripts + CSVs reproduce everything, several
      CPU-hours) or include specific fits. Document the decision in the
      release notes.

## 5. README quick-start

- [ ] `README.md` run order works from a clean checkout.
- [ ] Examples use `batch_fit(stratum = ...)` (not `topic = ...`).
- [ ] Links to `docs/output_contract.md`, `docs/visuals.md`,
      `docs/pipeline_layout.md`, `data_dictionary.md` resolve.

## 6. Environment / versions

- [ ] [`docs/environment.md`](environment.md) is current: R / JAGS / Rtools /
      key package versions and the "date checked" reflect the shipped build.
      **`docs/environment.md` is the current reproducibility record.**
- [ ] renv is **intentionally inactive during active development** (plain user
      library). The stale RoBMA-3.6 renv lockfile was archived and then
      removed from the public tree in commit `3d47a06`; `.gitignore`
      blocks accidental re-tracking. Do not claim `renv::restore()` is the
      reproduction path.
- [ ] renv is reintroduced **only at release freeze, after an explicit
      decision and restore testing**, with a freshly regenerated lockfile
      (not the archived stale one). `renv::init/restore/snapshot` are not run
      during active development.
- [ ] RoBMA 4.0.0 + BayesTools 0.3.0 + JAGS 4.3.1 + the R version stated in
      the README reproducibility section and `docs/environment.md` agree.
- [ ] `CITATION.cff` manuscript/DOI fields are either real or explicit
      `TODO_*` placeholders (never fabricated).

## 7. Manuscript figures

- [ ] Manuscript-ready figures are copied/exported into `manuscript/` (or a
      `reports/` export dir); `output/overview/` stays the regenerable
      analysis surface, not the manuscript figure target.
