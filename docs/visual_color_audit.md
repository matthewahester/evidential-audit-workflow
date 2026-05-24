# Visual color audit (RoBMA v4)

Snapshot of the pre-pass color usage across the visual layer, the
inconsistencies it surfaced, and what changed.

The semantic contract that this audit was driven by is in
[`visual_color_contract.md`](visual_color_contract.md).

## Summary of changes

- New `.VIS_COLORS` semantic palette added to `scripts/00_utils.R`
  (define-only; no ggplot2 dependency).
- `scripts/50_stratum_visuals.R`, `scripts/70_corpus_visuals.R`, and
  `simulation/scripts/75_composition_visuals.R` now read every color
  through `.VIS_COLORS` rather than inlined hexes.
- **Load-bearing fix**: cell attenuation atlas now uses RED for
  RoBMA-PSMA (was saturated green). Baseline RE stays blue.
- Saturated green removed from large fills (rigor atlas, weight
  heatmap, support bars, status PASS, bias-burden "clean"). Replaced
  by muted teal / sage where the semantic role is "positive" and by
  neutral slate where the role is "diagnostic PASS / clean / no
  anomaly".
- `rigor_direction` `no_effect` recolored from red-orange (`#D55E00`,
  which read as failure) to muted purple (`#7A5195`).
- Synthetic composition overlays switched from orange-red to muted
  purple, so they no longer conflict with the "fail" diagnostic color
  and `source_cluster` bootstrap mode.

## Audit table

| file | function | figure/output | current color(s) before pass | semantic role | problem/inconsistency | recommended change | implemented change |
|---|---|---|---|---|---|---|---|
| scripts/50_stratum_visuals.R | (module constant) | stratum mu_RE vs mu_BC overlays | `COLOR_ORIGINAL = #2166ac`, `COLOR_CORRECTED = #b2182b` | method comparison | already correct (Baseline=blue, RoBMA-PSMA=red); just inlined | route through `.VIS_COLORS$method` | rewired |
| scripts/50_stratum_visuals.R | (module constant) | rigor-direction point colors | `effect = #0072B2, no_effect = #D55E00` | rigor direction | `no_effect` orange reads as failure | `no_effect → muted purple` | rewired to `.VIS_COLORS$rigor_direction` |
| scripts/50_stratum_visuals.R | `.stratum_component_violin_stack` | component panel triad | `effect=#0072B2`, `het=#009E73`, `bias=#D55E00` | component identity | heterogeneity green is mid-saturated | `het → muted teal #1B5E63` | rewired to `.VIS_COLORS$component` |
| scripts/70_corpus_visuals.R | `.tableau10` | corpus / stratum violin family | 9 entries including `#1B5E20` plant green | categorical stratum | saturated green stands out from otherwise-muted set | mute green to sage | rewired to `.VIS_COLORS$stratum_palette` (sage `#557755`) |
| scripts/70_corpus_visuals.R | (module constant) | rigor direction point/bar colors | `effect = #0072B2, no_effect = #D55E00` (points), `effect = #0277BD, no_effect = #EF6C00` (bars) | rigor direction | `no_effect` orange reads as failure; bars and points used different hues | one consistent mapping; `no_effect → muted purple` | rewired (bars and points now identical) |
| scripts/70_corpus_visuals.R | (module constant) | rigor category fills | `clean_effect_supported = #1B5E20`, `clean_no_effect_supported = #0277BD`, `clean_evidence_disfavored = #6D4C41`, `inconclusive = #B0BEC5`, `uncategorized = #9E9E9E` | rigor category | category fills did not match rigor_direction colors; clean_effect was green | match rigor_direction (`effect=blue`, `no_effect=purple`); `disfavored → muted brown` | rewired to `.VIS_COLORS$rigor_category` |
| scripts/70_corpus_visuals.R | `corpus_rigor_weighting_comparison` | outcome- vs article-balanced weighting | `Outcome-weighted = #1F78B4, Article-balanced = #E6550D` | weighting mode | inlined; not in any palette | use `.VIS_COLORS$bootstrap_mode` (outcome blue, source_cluster amber) | rewired |
| simulation/scripts/75_composition_visuals.R | module constants | heatmap ramps / OK / FAIL / DIAG / STATUS | `low=#F7F4EF, high=#1B5E20, OK=#0072B2, FAIL=#D55E00, DIAG=#D55E00, PASS=#1B5E20, INFO=#0277BD, WARN=#F9A825, FAIL=#D55E00` | mixed (diagnostic + heat) | saturated green for high heat and PASS; FAIL orange-red instead of muted red | sequential high → muted teal; PASS → blue-gray; FAIL → muted red | rewired to `.VIS_COLORS$heat / $diagnostic`, w/ defensive fallback |
| simulation/scripts/75_composition_visuals.R | `cv_plot_support_bars` | synthetic pool support | `empty=#D55E00, sparse=#F9A825, supported=#1B5E20` | support coverage | saturated green for supported | supported → neutral blue-gray | rewired to `.VIS_COLORS$support` |
| simulation/scripts/75_composition_visuals.R | `cv_plot_cell_rigor_atlas` | diverging rigor atlas | `low=#D55E00, mid=#F7F4EF, high=#1B5E20` | diverging rigor | saturated green high | high → muted sage `#1B6B5E` | rewired to `.VIS_COLORS$heat` |
| simulation/scripts/75_composition_visuals.R | `cv_plot_cell_attenuation_atlas` | Baseline vs RoBMA-PSMA boxplots | `Baseline=#0072B2, RoBMA-PSMA=#1B5E20` | **method comparison** | **RoBMA-PSMA was GREEN, not RED** (most important defect) | RoBMA-PSMA → red | **rewired to `.VIS_COLORS$method`; Baseline=blue, RoBMA-PSMA=red** |
| simulation/scripts/75_composition_visuals.R | `cv_plot_cell_rigor_size_curve_by_effect`, `cv_plot_cell_rigor_convergence_error_by_effect`, `cv_plot_cell_threshold_rates_by_effect` (all three retired 2026-05; rewire preserved in current `cv_plot_cell_rigor_variability_by_effect` + `cv_plot_cell_rate_variability_by_effect`) | bias_cols triad | `clean=#1B5E20, modbias=#0072B2, highbias=#D55E00` | bias-burden severity | clean = saturated green; modbias = blue clashes with rigor_direction; ordering not ordinal | slate → amber → red ordered ramp | rewired to `.VIS_COLORS$bias_burden` |
| simulation/scripts/75_composition_visuals.R | Q2 size-curve / interval plots | bootstrap mode colors | `outcome=#0072B2, source_cluster=#D55E00` | bootstrap mode | source_cluster red reads as failure | source_cluster → amber | rewired to `.VIS_COLORS$bootstrap_mode` |
| simulation/scripts/75_composition_visuals.R | `cv_plot_composition_size_curve_primary_rigor` | composition ribbon + line | `fill/color=#0072B2` | synthetic composition | conflicts with empirical bootstrap blue elsewhere | use `.VIS_COLORS$resampling_source$synthetic_composition` (muted purple) | rewired |
| simulation/scripts/75_composition_visuals.R | `cv_plot_emp_bootstrap_vs_composition` | empirical bootstrap + synthetic composition overlay | `emp=#0072B2, syn=#D55E00` | resampling source | syn red conflicts with `fail` and with `source_cluster` | syn → muted purple | rewired to `.VIS_COLORS$resampling_source`; subtitle text updated to "purple" |

## Diagnostics that were NOT changed

The `cv_plot_validation_status` bar uses `.CV_STATUS_COLORS` which
now reads from `.VIS_COLORS$diagnostic`, so PASS / INFO / WARN / FAIL
inherit the new neutral PASS automatically. No call-site change was
needed.

The legend wiring in the agreement plot (`within 90% band` blue,
`outside 90% band` red, `undeterminable` gray) is semantically
correct as-is and now flows through `.CV_OK` / `.CV_FAIL` from the
palette.

## Files not touched in this pass

- `scripts/30_zplot.R` is monochrome / point-only and uses no
  hardcoded categorical hexes.
- The simulation computation scripts (`simulation/scripts/55_…`,
  `60_…`, `65_…`, `70_…`) write CSVs only, no figures.
- `scripts/55_orchard_visuals.R` is retired and not present.

## Unresolved items / human review

- The new `no_effect = muted purple` choice is colorblind-safe but
  worth a manuscript-side eyeball check against the blue `effect`
  direction in side-by-side composition bars.
- The diverging rigor-atlas ramp (muted red ↔ muted sage) is muted
  by design; if reviewers want stronger separation, swap
  `.VIS_COLORS$heat$diverging_pos` for a slightly more saturated
  teal (e.g. `#0F766E`).
- 70's `.tableau10` 9th slot (`#37474F` slate) is a filler that
  duplicates the diagnostic `pass` color. Not used in practice
  because there are 8 strata, but worth a check if strata are ever
  added.
