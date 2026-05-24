# references/

Citation and provenance files for the empirical nutrition extractions
committed under [`data/`](../data/).

## What's here

| File | Role |
|---|---|
| [`manuscript_references.bib`](manuscript_references.bib) | Snapshot of the manuscript bibliography (`Rigor_Manuscript/06_refs/master.bib`) at this repo checkpoint. May contain methods, statistics, and policy references in addition to empirical nutrition sources. Citation keys and fields are preserved verbatim; entries are not reordered. |
| [`nutrition_source_articles.bib`](nutrition_source_articles.bib) | Filtered subset: only the empirical nutrition source articles that match a `data/<Stratum>/<source_article>/` extraction directory. Derived deterministically from `manuscript_references.bib` plus [`../data/source_article_registry.csv`](../data/source_article_registry.csv). |
| [`../data/source_article_registry.csv`](../data/source_article_registry.csv) | One row per `data/<Stratum>/<source_article>/` directory, with the matched BibTeX citation key, year, title, journal, DOI, PMID, URL, BibTeX entry type, the committed extraction files in that directory, and a `match_status` column. |

## What's not here

- **No article PDFs.** Full-text source-article PDFs are not redistributed — copyright belongs to the original publishers.
- **No publisher supplements / screenshots.** The published article tables, screenshots, and any supplementary PDFs/Word docs that the extractions were sourced from are not included.
- **No re-typeset article tables.** Only the analysis-ready effect sizes and standard errors actually used by the pipeline live under `data/`; the full statistical apparatus of each source article is in the article itself.

To obtain a source article, follow its DOI/URL in `source_article_registry.csv` and access via your institutional library or the publisher.

## How the matching was done

`data/source_article_registry.csv` matches each `<source_article>` directory name (a lowercase `<surname><year>` slug — e.g. `shen2019`, `lanhers2015`, `stockton2011`) to a BibTeX entry in `manuscript_references.bib` using:

1. Strict surname equality after Unicode/LaTeX accent normalization (`Raya-González` ↔ `rayagonzalez`).
2. Exact year first; ±1-year fallback for entries with print-vs-online-publication year drift.
3. Stratum-keyword title disambiguation when multiple BibTeX entries match the same surname+year (e.g. two different `chen2024` papers — one Caffeine, one Vitamin D).
4. A deterministic canonical-key tiebreaker when the bibliography contains true duplicate entries for the same paper.

The `match_status` column records the outcome:

| Status | Meaning |
|---|---|
| `exact` | Unique strict author + year match (after normalization / disambiguation). |
| `probable` | ±1-year offset; surname strictly matches. |
| `unmatched` | No suitable BibTeX entry found. Either the article isn't in the manuscript bibliography or the lead author of the cited paper differs from the `<source_article>` slug. |

No metadata is invented. Unmatched rows have empty `citation_key`/`year`/`title`/`doi`/`pmid`/`url`/`bibtex_entry_type` and a free-text `notes` value describing what was missing.

## Reproducing this layer

This layer is regenerable from the manuscript bibliography plus the on-disk `data/<Stratum>/<source_article>/` listing. The generator script is local-only (kept under `_repo_cleanup/` and ignored by `.gitignore`); the **inputs** (master bibliography + on-disk extraction directories) are the authoritative sources of truth, and `source_article_registry.csv` is the committed mapping.

If the manuscript bibliography changes — e.g. an entry is added for a currently-unmatched source article, or a citation key is renamed — regenerate this layer end-to-end (master.bib → manuscript_references.bib → nutrition_source_articles.bib → source_article_registry.csv) and commit the updated outputs in one "references: refresh source article registry" commit.
