# Visuals — Axis-Scale Contract

Every figure the pipeline produces, the script that writes it, its input, its
default/optional status, its **x-axis scale**, and its manuscript vs
supplement/QC role.

## Axis-scale decision

- **Corpus-level component-BF violins** use raw `log₁₀(BF)` source values
  with **display capping at ±2** (see below). A violin is a distribution
  figure; distributional fidelity is the point, so the evidence-axis
  transform is not used for headline violin geometry.
- **Rigor violin/ranking** use raw `log₁₀(BF_rigor)` source values
  with the same display capping.
- The corpus component violins and the rigor violin share **one
  visual family** (same raw-log10 gray evidence bands and guide lines).
- **Orchards are retired** from the active visual pipeline. The
  evidence-axis transform (and its terminal Inf bin) is **not used by
  any default 50/70 build**; a frozen copy of the old orchard module
  is kept under `archive/` for provenance only. The active
  component-evidence displays are the display-capped raw-log10 violins.
- Axis labels use a real subscript 10: `log₁₀(BF)` in docs,
  `expression(log[10](BF))` / `expression(log[10](BF[rigor]))` in ggplot.

### Display capping on the violin family

- The corpus component-BF violins and the rigor violin use raw
  `log₁₀(BF)` / `log₁₀(BF_rigor)` source values with **display capping at
  `|log₁₀(BF)| = 2`** (`LOG10_BF_DISPLAY_CAP`, in `70_corpus_visuals.R`).
  `log₁₀(BF) = 2` already means `BF = 100`; nothing visual is gained at the
  corpus level by distinguishing `+2.3`, `+4.5`, `+Inf` — they are all in
  the "very strong or stronger" evidence pile.
- A value is winsorized for plotting: finite `x > +2` → `+2`; finite
  `x < -2` → `-2`; `+Inf` → `+2`; `-Inf` → `-2`; `NA`/`NaN` stay missing and
  are excluded. **The cap is a visualization convention only — raw
  registry/sidecar values are never mutated.**
- The violin **density, points, median, IQR, and 10–90% whiskers are all
  computed from the display-capped values**, so mass beyond the cap (incl.
  `±Inf`) fills the violin at `±2` instead of being split into a separate
  bin/rail. There are no overflow rails and no external `±Inf` count labels.
- The x-axis is driven by the displayed (capped) values with ordinary
  padding; when the displayed data reach a cap the axis is extended a small
  fixed amount past it so the winsorized pile is not flush with the border.
  Plots are **not** forced to show the full `[-2, +2]` range when the data
  do not need it, and limits are not forced symmetric.
- The cap tick is labelled `≤ -2` (left) and/or `≥ 2` (right) when capped
  values exist, never `±∞`, since finite values beyond the cap are collapsed
  there too. Other ticks are ordinary numbers.
- `corpus_component_violin_stack.pdf` is a **three-component horizontal
  panel** figure (Effect | Heterogeneity | Modeled bias, left-to-right). One
  shared stratum order (the corpus slug order) is used so rows line up across
  panels, and the stratum labels are written once (leftmost panel only). Each
  panel keeps its own **component-specific** display-capped `log₁₀(BF)`
  x-axis (free x per panel), so a narrow-spread component is not stretched to
  a wide shared axis; values beyond the cap, including `±Inf`, are plotted at
  the cap and the footer states the convention. The stratum-level counterpart
  (`<scope>_component_violin_stack.pdf`, written by `50`) uses the same
  grammar for a single stratum/source scope (one distribution per panel).
- The **evidence-axis transform** is retired (frozen under `archive/`
  for provenance only); it is never used for violin geometry or any
  default 50/70 output.
- The returned `$diagnostics` tibble records the raw distribution and the
  capping (`finite_n`, `pos_inf_n`, `neg_inf_n`, `missing_n`, `finite_min`,
  `finite_max`, `capped_low_n`, `capped_high_n`, `display_min`,
  `display_max`, `display_cap`). No diagnostics CSV is written. Raw `±Inf`
  Bayes factors remain intact in `outcome_registry.csv` / the sidecars —
  consult those (or `60`'s tables) when exact extremity matters.

### Figure layout controls

`scripts/70_corpus_visuals.R` has an explicit, editable **Figure layout
defaults** block near the top so sizes can be tuned without reading the
plotting code:

- `FIGURE_SIZES` — per-figure width/height (in); `height = NA` ⇒ the save
  site scales it from the stratum count. Standalone component violins and the
  rigor violin default to **width 6**;
  `corpus_component_violin_stack.pdf` is wider (horizontal 3-panel).
- `FIGURE_SAVE_DEFAULTS` / `save_corpus_plot()` — one shared `ggsave` path.
- `auto_figure_dim()` × `FIGURE_HEIGHT_SCALE` — global multiplier to shrink/
  grow every auto-sized figure at once (e.g. many strata).
- `ATTENUATION_STRIP_YLIM` — pinned effect-size y-range for the attenuation
  strip boxplot; defaults to `c(-0.05, 0.7)` (the nutrition figure). Set it
  (or pass `strip_ylim_override`) to `NULL` to auto-compute from the whisker
  span. Display/layout only — it does not change any data.

## Color contract

Every visual script reads colors from a single semantic palette,
`scripts/00_utils.R :: .VIS_COLORS`. The full role-by-role mapping
(method comparison, rigor direction, rigor category, bias burden,
heterogeneity encoding, resampling source, diagnostic status, heat
ramps, stratum palette, component triad) is documented in
[`visual_color_contract.md`](visual_color_contract.md).

Load-bearing invariants:

- Baseline RE / unadjusted estimate = BLUE.
- RoBMA-PSMA / bias-adjusted estimate = RED.
- `no_effect` is a positive evidential state, not failure: it uses
  muted purple, not red.
- Saturated green is avoided as a default; sage / teal are used only
  where a "positive" semantic role is needed and large green fills
  would dominate.
- Diagnostics: gray neutral, amber warning, muted red failure;
  PASS is neutral blue-gray, never green.

See [`visual_color_audit.md`](visual_color_audit.md) for the
pre-/post-pass diff.

## Output roots (corpus-agnostic)

No reporting/visual script assumes nutrition labels, the eight nutrition
strata, or a fixed root. `50` takes `root` + `output_dir`, `70` takes
`output_dir`, `30` takes `output_root`; they operate on whatever strata the
chosen registry/root contains. The same figures are produced for a
simulation output root (e.g. `output_sim_v23/overview`) — see
[`pipeline_layout.md`](pipeline_layout.md) for the argument-name table.

## Figure table

| Figure | Script | Input | Default | x-axis | Role |
|--------|--------|-------|---------|--------|------|
| `<dataset_id>_z_plot.pdf` | 30 | saved `zplot_*` `.rds` | yes | z-score | inspection/supplement |
| `<dataset_id>_z_extrapolation.pdf` | 30 | saved `zplot_*` `.rds` | yes | z-score | inspection/supplement |
| `<scope>_effect_estimate_comparison.pdf` | 50 | `outcome_registry.csv` | yes | effect-size | inspection |
| `<scope>_effect_forest.pdf` | 50 | `outcome_registry.csv` | yes | effect-size | inspection |
| `<scope>_component_violin_stack.pdf` | 50 | `outcome_registry.csv` | yes | **raw `log₁₀(BF)` (display-capped ±2)** | inspection / manuscript-candidate |
| `<scope>_rigor_ranking.pdf` | 50 | `outcome_registry.csv` | `include_rigor` (on) | **raw `log₁₀(BF_rigor)` (display-capped ±2)** | manuscript-candidate |
| `corpus_effect_attenuation_boxplot_horizontal/strip.pdf` | 70 | `outcome_registry.csv` | yes | effect-size | manuscript/supplement |
| `corpus_component_violin_effect/heterogeneity/bias.pdf` | 70 | `outcome_registry.csv` | yes | **raw `log₁₀(BF)` (display-capped ±2)** | manuscript |
| `corpus_component_violin_stack.pdf` | 70 | `outcome_registry.csv` | yes | **raw `log₁₀(BF)` (display-capped ±2)** | manuscript |
| `corpus_rigor_violin_by_stratum.pdf` | 70 | `outcome_registry.csv` | yes | **raw `log₁₀(BF_rigor)` (display-capped ±2)** | manuscript (flagship) |
| `corpus_rigor_branch_scatter.pdf` | 70 | `outcome_registry.csv` | yes | raw `log₁₀` | manuscript/supplement |
| `corpus_rigor_direction_composition.pdf` | 70 | `rigor_direction_summary.csv` → registry | yes | composition (muted palette) | manuscript |
| `corpus_rigor_category_composition.pdf` | 70 | `rigor_category_summary.csv` → registry | yes | composition (muted palette) | manuscript |
| `corpus_rigor_weighting_comparison.pdf` | 70 | `stratum_estimands.csv` + `article_balanced_estimands.csv` | yes | raw `log₁₀` | manuscript |
| `corpus_rigor_ranking_extremes.pdf` | 70 | `outcome_registry.csv` | yes | **raw `log₁₀(BF_rigor)` (display-capped ±2)** | manuscript/supplement |
| `corpus_attenuation_vs_rigor.pdf` | 70 | `outcome_registry.csv` | yes | raw `log₁₀` | supplement |
| `corpus_bias_vs_rigor.pdf` | 70 | `outcome_registry.csv` | **off** (`include_bias_vs_rigor`) | raw `log₁₀` | QC/supplement |
| `corpus_orchard_*.pdf` / `<scope>_component_orchard.pdf` | **55 (retired)** | `outcome_registry.csv` | **off** (explicit `build_*_orchards()`) | **evidence-axis transform** | retired diagnostic |

`<scope>` = stratum slug, or `<stratum>_<source_article>` for a source-scoped
`50` run. "manuscript-candidate / manuscript/supplement" roles are editorial;
the pipeline writes every non-retired row above to `output/` and the
manuscript copies the chosen subset into `manuscript/`. The orchard row is
**retired** and not part of the active visual pipeline — it is never
produced by a default run (the old orchard module is archived only).
