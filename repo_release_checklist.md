# Repository Release Checklist

A short, ordered checklist for flipping this repository public alongside the manuscript submission. Items are grouped by phase. Each item should be verifiable in one to a few minutes.

---

## A. Content alignment

- [ ] **README ↔ manuscript title.** The title quoted in `README.md` (Associated Manuscript section) matches the manuscript exactly.
- [ ] **Pipeline overview ↔ scripts.** The script descriptions in `README.md` and in `documentation/scripts_readme.md` match the actual current behavior of `10_load_data.R` through `60_overview.R`.
- [ ] **Output dictionary ↔ files on disk.** Every artifact named in `output_dictionary.md` either exists in the repository or is explicitly noted as omitted (e.g., fitted `.rds` objects).
- [ ] **Data dictionary ↔ CSV columns.** A spot check on at least one CSV per topic confirms the `g` / `se_g` schema and any optional columns described in `data_dictionary.md`.
- [ ] **`_excl` policy ↔ data.** For every `_excl` CSV present, the paired `.xlsx` retains the full reconstructed study set and documents which rows were removed and in what order, consistent with the `_excl` description in `data_dictionary.md`.

## B. Citation and licensing

- [ ] `CITATION.cff` placeholders resolved: `TODO_ORCID`, `TODO_REPOSITORY_URL`, `TODO_RELEASE_VERSION`, `TODO_RELEASE_DATE`, `TODO_ZENODO_DOI`, `TODO_PUBLICATION_YEAR`, `TODO_JOURNAL`, `TODO_MANUSCRIPT_DOI`, `TODO_MANUSCRIPT_URL`.
- [ ] `LICENSE` (MIT) is present at the repo root and the copyright line names the correct holder and year.
- [ ] `LICENSE-data` (CC BY 4.0) is present at the repo root and the file globs it covers match the actual layout of `data/` and `output/`.
- [ ] The README's *Citation* and *License* sections point to these two files.

## C. Reproducibility

- [ ] `renv.lock` is committed and reflects the environment that produced the manuscript figures.
- [ ] `renv::restore()` runs cleanly on a fresh checkout.
- [ ] A working JAGS installation is documented as a system requirement (already noted in the README; verify wording).
- [ ] The `CONFIG` block in `20_robma_fit.R` records the seed actually used for the manuscript run.

## D. What is included vs. omitted

- [ ] `.gitignore` excludes `output/**/fit_*.rds` and `output/**/zcurve_*.rds`.
- [ ] Per-topic `*_robma_summary.csv` files **are** committed.
- [ ] All per-topic plot PDFs under `output/<topic>/plots/` **are** committed.
- [ ] All cross-topic artifacts under `output/overview/` **are** committed.
- [ ] `output/topic_summary.csv` (per-topic accumulator) **is** committed.
- [ ] The `data/` tree (CSVs + extraction workbooks) **is** committed.
- [ ] No accidentally-tracked large `.rds` objects remain. (`git ls-files | grep -E '\\.rds$'` returns nothing unexpected.)
- [ ] **`output/` tree contains only documented artifacts.** Every file remaining under `output/` matches a path described in `output_dictionary.md` (per-topic summary CSV, per-topic plots, `output/topic_summary.csv`, or `output/overview/` artifacts). Ad hoc exploratory files (one-off `.csv`, `.pdf`, `.rds`, batch status logs, etc.) have been removed from version control.

## E. Quick-start verification

On a fresh clone, on a machine with R, JAGS, and a restored `renv` environment:

- [ ] `source("scripts/10_load_data.R"); list_datasets()` returns the expected catalog.
- [ ] A single-dataset reproduction (the example in the README's Quick Start) completes without error.
- [ ] `source("scripts/50_topic_analysis.R"); topic_analysis(topic = "<one_topic>")` regenerates the three per-topic PDFs from the committed summary CSV (no MCMC needed).
- [ ] `source("scripts/60_overview.R")` regenerates all overview artifacts without error.
- [ ] At least one manuscript figure regenerated from the committed summaries is visually identical to the figure in the manuscript.

## F. Manuscript bundle (if shipped with repo)

- [ ] `manuscript/` contains the LaTeX source (or equivalent) and the compiled PDF used for submission.
- [ ] LaTeX build artifacts (`.aux`, `.log`, `.bbl`, etc.) are not tracked (covered by `.gitignore`).
- [ ] Any standalone supplementary PDF is included.

## G. Tagging and archiving

- [ ] A Git tag corresponding to the manuscript submission is created (e.g., `v1.0-submission`).
- [ ] The tagged release is archived (e.g., via Zenodo) to mint a citable DOI.
- [ ] The Zenodo DOI is written back into `CITATION.cff` (`identifiers` block) and committed.
- [ ] The README's *Citation* section is updated to reference the archived DOI in addition to the manuscript citation.

## H. Final repository hygiene

- [ ] No private notes, draft text, or personal files outside the documented directories.
- [ ] No hard-coded absolute paths in any committed script.
- [ ] No credentials, API keys, or institutional identifiers in committed files.
- [ ] Repository description and topics on GitHub are set (e.g., `meta-analysis`, `RoBMA`, `bayesian-statistics`, `evidence-synthesis`, `r`).
- [ ] Repository is flipped from private to public.

---

After H, the repository is releasable. Items in B and G that depend on preprint posting or journal acceptance can be completed in a follow-up commit once those events occur; in that case, leave a clearly-marked TODO in `CITATION.cff` rather than fabricating values.
