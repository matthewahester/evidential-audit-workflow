# Public-Release Checklist

A practical, human pre-flight for cutting a public release of the RoBMA
4.0 evidential-audit workflow. Not a CI spec.

The checklist is organized by milestone: **(A) before v1.0.0 tag**,
**(B) after the Zenodo release DOI is minted**, **(C) before posting an
arXiv preprint**, and **(D) before journal (e.g. RSM) submission**.

Companion documents: [`output_commit_policy.md`](output_commit_policy.md)
(what ships vs what stays local), [`pipeline_layout.md`](pipeline_layout.md)
(one-scheme-per-output-root rule, repository tree),
[`runbook.md`](runbook.md) (Phases A–K),
[`environment.md`](environment.md) (R / JAGS / package versions and the
fixed MCMC seed).

---

## A. Before v1.0.0 tag

These items must be done in the same commit that the v1.0.0 tag points
at. No literal `TODO_*` placeholders in public-facing metadata.

### A.1 Scratch / private hygiene

- [ ] `output/_scratch/` removed or excluded; no scratch CSVs beside
      trusted sidecars.
- [ ] No private notes, credentials, or internal release memos
      committed.
- [ ] `archive/RoBMA_3_6/` remains ignored (not committed). Other
      retired sub-projects (v2 resampling, the inactive renv lockfile)
      were removed from the public tree during cleanup; only
      `archive/55_orchard_visuals.R` is tracked under `archive/`.

### A.2 `.gitignore`

- [ ] Large fit objects (`*.rds`, `*.Rds`, `*.RData`, `*.rda`) excluded
      globally; force-add only specific fits that must ship.
- [ ] `output/_scratch/`, `output_sim_v30/`, `simulation/results/`, and
      `archive/RoBMA_3_6/` ignored.
- [ ] The three giant `*_size_curve_draws.csv` files (Q1, Q2, Q3) are
      ignored as belt-and-braces (each over GitHub's 100 MB per-file
      limit).
- [ ] Committed: per-stratum `*_robma_summary.csv`,
      `*_zplot_diagnostics.csv`,
      `output/<stratum>/<source>/{audit/,plots/}`,
      `output/<stratum>/plots/`, and `output/overview/` tables and
      figures.

### A.3 Simulation: what ships in the public GitHub release

Release decision (locked at v1.0.0): the public GitHub release ships
the **machinery and documentation** to regenerate the simulation
outputs locally. It does **not** ship generated simulation datasets,
fitted simulation outputs, raw resampling/sampling draws, or result
trees.

- [ ] The following remain untracked or ignored — verify they are NOT
      in the next commit:
        * `data/sim_<cell_slug>/sim2026/repNNNN.csv` (~18,000 files,
          ~57 MB; regenerable from
          `simulation/config/design_v3_full36.csv` + the fixed
          generation seed in `simulation/scripts/20_sim_generate.R`).
        * `simulation/latent/sim_*/sim2026/*_latent.csv` (~18,000 files,
          ~95 MB; provenance only, no active reader).
        * `simulation/results/` (entire tree; ignored).
        * `output_sim_v30/` (entire tree; ignored).
        * `simulation/manifests/*.csv` (untracked; per-run generation
          manifests, regenerable).
- [ ] The following ARE included and verified present:
        * `simulation/scripts/` — all numbered scripts.
        * `simulation/config/design_v3_full36.csv` — the 36-cell design grid.
        * `simulation/README.md` — public runbook.
        * `simulation/design_memo.md` — public ADEMP design memo.
- [ ] Do **not** run `git add -f simulation/results/...` or
      `git add -f data/sim_*/...` for the public release. The
      manuscript and supplement carry the reported simulation
      displays; the GitHub repo carries the machinery and the
      runbooks to regenerate them.
- [ ] (Internal manuscript build only.) The manuscript-side pinned
      tree under `Rigor_Manuscript/05_artifacts/current/` is a
      separate working directory, not part of the analysis repo; the
      sync tool
      `Rigor_Manuscript/tools/sync_simulation_artifacts.R` is the
      author-side mirror and does **not** stage anything into the
      public GitHub release.

### A.4 Outputs regenerate from scripts (smoke test)

Empirical side (cheap; minutes):

- [ ] From the committed sidecars,
      `build_estimand_tables()` (60) reproduces
      `output/overview/` tables.
- [ ] `build_zplots()` (30), `build_stratum_visuals()` (50),
      `build_corpus_visuals()` (70) reproduce the empirical figures
      from those tables.
- [ ] `sidecar_acceptance()` / `sidecar_acceptance_all()` passes on
      every empirical stratum (registry anti-join, rigor identities,
      schema/estimand versions, config hash, RoBMA major version ≥ v4).

Simulation side (heavy; requires a local rerun, no committed
intermediates):

- [ ] On a sufficiently sized workstation, the full simulation layer
      reproduces end-to-end from the included scripts and design grid:
      `sim_generate_library(n_reps = 500)` →
      `sim_fit_library()` (HEAVY MCMC; hours to days) →
      `emp_run_resampling(B = 15000, ...)` →
      `sim_run_synthetic_resampling(B = 15000, pool_key = "target",
      smoothing = "eb_corpus", kappa = 4, support = "occupied")` →
      `sim_run_empirical_synthetic_agreement()` →
      `sim_run_all_analysis_visuals()`. The phase-by-phase commands,
      parallelism settings, and B/n_reps tier table are in
      [`runbook.md`](runbook.md) and
      [`../simulation/README.md`](../simulation/README.md). The
      simulation displays in the manuscript and supplement reproduce
      from this sequence; no simulation outputs are shipped with the
      GitHub release.

### A.5 README and documentation links

- [ ] `README.md` is the public front door (purpose, manuscript
      connection, what's included, what's omitted, quick inspection,
      reproduction, adaptation, citation, license).
- [ ] No literal `$...$` LaTeX math, no fenced `math` / `tex` blocks,
      no broken Markdown tables in `README.md`.
- [ ] All links from `README.md` to `docs/*.md`, `LICENSE`,
      `LICENSE-data`, `CITATION.cff`, `data/`, `output/`,
      `simulation/` resolve from a clean checkout.

### A.6 Environment / versions

- [ ] [`docs/environment.md`](environment.md) is current: R / JAGS /
      Rtools / key package versions and the "date checked" reflect the
      shipped build. `docs/environment.md` is the reproducibility
      record.
- [ ] `renv` is intentionally inactive during active development (plain
      user library). Do not claim `renv::restore()` is the reproduction
      path.
- [ ] RoBMA 4.0.0 + BayesTools 0.3.0 + JAGS 4.3.1 + the R version
      stated in [`docs/environment.md`](environment.md) agree.

### A.7 `CITATION.cff` and license files

- [ ] `CITATION.cff` has `repository-code` and `url` set to the
      GitHub URL (already done).
- [ ] `CITATION.cff` `preferred-citation.title` matches the current
      manuscript title (already done).
- [ ] **`orcid:` fields** — paste the author's ORCID iD into both
      `authors[0].orcid` and `preferred-citation.authors[0].orcid` in
      `CITATION.cff`. Do not leave `TODO_ORCID` in the public v1.0.0
      tag; if the ORCID is genuinely not yet registered, remove the
      `orcid:` field entirely rather than leaving a TODO value.
- [ ] **`version:` and `date-released:`** — set `version: "1.0.0"`
      and `date-released: "YYYY-MM-DD"` (the date the tag is pushed)
      in the same commit the tag will point at.
- [ ] **`identifiers:` (DOI block)** — leave the block out of
      v1.0.0, or set the entire block to be commented out, until
      Zenodo mints the release DOI. Do not commit literal
      `TODO_ZENODO_DOI`.
- [ ] **`preferred-citation` manuscript fields**
      (`year`, `journal`, `doi`, `url`) — comment them out or remove
      them for v1.0.0; they will be filled in milestone B/C.
- [ ] `LICENSE` (MIT) and `LICENSE-data` (CC BY 4.0) carry the correct
      copyright year and author name.

### A.8 Decide: ship `.rds` fits?

- [ ] Decide and document: omit all `.rds` fits (default — scripts +
      CSVs reproduce everything, several CPU-hours) or include
      specific representative fits. Record the decision in the release
      notes.

---

## B. After the Zenodo release DOI is minted

Push these as a follow-up commit after the v1.0.0 tag has been minted
on Zenodo and the DOI is known:

- [ ] Add the Zenodo DOI back into `CITATION.cff` under `identifiers:`
      with `type: doi`, `value: "10.5281/zenodo.<id>"`,
      `description: "Archived release DOI (Zenodo)"`.
- [ ] Update the **Citation** section of `README.md` to name the DOI
      and link `https://doi.org/10.5281/zenodo.<id>` instead of the
      placeholder sentence about the DOI being added after v1.0.0.
- [ ] (Optional) tag a follow-up `v1.0.1` if any other text changed in
      the same commit; otherwise the DOI is the only change and the
      tag is unnecessary.

---

## C. Before posting an arXiv preprint

- [ ] arXiv PDF is built from the canonical `Rigor_Manuscript/01_main/`
      source against the pinned final-tier artifacts (the same source
      that built the most recent committed `main.pdf`).
- [ ] arXiv supplement built from `Rigor_Manuscript/02_supplement/`
      against the same pinned artifacts.
- [ ] The arXiv URL is added to the **Associated manuscript** section
      of `README.md` and to `CITATION.cff`
      `preferred-citation.url:`.

---

## D. Before journal (RSM) submission

- [ ] The manuscript title in `CITATION.cff` `preferred-citation.title`
      matches the journal-submitted title verbatim.
- [ ] The corresponding-author block in `CITATION.cff` matches the
      journal submission portal.
- [ ] When the manuscript is accepted, populate
      `preferred-citation.year`, `journal`, and `doi`, and update
      `README.md` to name the published article.

---

## Quick links

- Output / commit policy: [`output_commit_policy.md`](output_commit_policy.md)
- Repository tree and root rule: [`pipeline_layout.md`](pipeline_layout.md)
- Run order: [`runbook.md`](runbook.md)
- Environment: [`environment.md`](environment.md)
- Sync manifest: `Rigor_Manuscript/docs/manifests/SIMULATION_ARTIFACT_MANIFEST.csv`
- Sync tool: `Rigor_Manuscript/tools/sync_simulation_artifacts.R`
