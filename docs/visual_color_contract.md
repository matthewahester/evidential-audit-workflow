# Visual color contract (RoBMA v4 evidential audit)

Single source of truth for the manuscript-facing visual layer. Every
plotting script reads from one shared list:

```r
scripts/00_utils.R :: .VIS_COLORS
```

Hex constants live there only; plotting scripts never invent their
own. The list is define-only and carries no ggplot2 dependency, so
`source("scripts/00_utils.R")` from any consumer (50/70 empirical
visuals, 75 simulation visuals) installs the palette without
side-effects.

## Why a single shared palette

This pipeline has two visual subsystems (empirical 50/70 and
simulation 75) that share the same conceptual vocabulary:
Baseline / RoBMA-PSMA, rigor direction, rigor category, bias burden,
heterogeneity, empirical vs synthetic, diagnostic pass/warn/fail.
The same vocabulary in two places had ended up with divergent hexes
(plant green in one figure, vermilion in another, etc.). Centralizing
keeps the figure family coherent and lets a single edit propagate.

## Required semantic mappings

### Method comparison — load-bearing
- **Baseline RE / unadjusted estimate → BLUE** (`#2166AC`).
- **RoBMA-PSMA / bias-adjusted estimate → RED** (`#B2182B`).

This mapping must not be reversed. Every figure that names "Baseline"
and "RoBMA-PSMA" (the cell attenuation atlas, the stratum-level
forest plots, the corpus attenuation diagnostics) uses the same hex
pair.

### Rigor direction — both positive
- `effect → #0072B2` (Okabe-Ito blue)
- `no_effect → #7A5195` (muted purple)

`no_effect` is a positive evidential state, not failure. It must not
read as a red/orange "warning"; the previous `#D55E00` mapping made
that mistake.

### Rigor category — mirrors direction
- `clean_effect_supported → #0072B2` (matches `effect`)
- `clean_no_effect_supported → #7A5195` (matches `no_effect`)
- `clean_evidence_disfavored → #8B5A3C` (muted brown)
- `inconclusive_clean_evidence → #B0BEC5` (light slate)
- `uncategorized → #9E9E9E` (neutral gray)

### Bias burden — ordered severity, no traffic green
- `clean → #5C6B73` (neutral slate)
- `modbias → #EF6C00` (amber/orange)
- `highbias → #B2182B` (muted red)

Traffic-light green for "clean" is explicitly avoided.

### Heterogeneity — off the color channel
When a figure already encodes bias via color (typical in Q1 by-effect
plots), heterogeneity uses linetype/shape so the figure stays
grayscale-readable:

- linetype: `lowhet = "solid", midhet = "22", highhet = "44"`
- shape:    `lowhet = 16, midhet = 17, highhet = 15`

### Effect level — ordered slate ramp
Reserved for the rare case where effect band must be encoded by
color in a single panel (most figures facet by effect band instead):

- `null → #CFD8DC`
- `small → #90A4AE`
- `moderate → #546E7A`
- `large → #263238`

### Resampling source — empirical vs synthetic overlay
- `empirical_observed → #212121` (ink)
- `empirical_bootstrap → #2166AC` (muted blue)
- `synthetic_composition → #7A5195` (muted purple)

Overlays that contrast empirical and synthetic also use linetype /
shape in addition to color (`emp = solid + filled point`, `syn =
dashed + hollow point`).

### Bootstrap mode — paired alternatives
- `outcome → #0072B2` (blue)
- `source_cluster → #EF6C00` (amber)

Amber rather than red, so `source_cluster` does not read as failure.

### Diagnostic status — no green PASS
- `pass → #37474F` (neutral muted blue-gray)
- `info → #0277BD` (marine blue)
- `warning → #F9A825` (amber)
- `fail → #B2182B` (muted red)
- `unavailable → #CFD8DC` (light gray)

Reviewers' attention is drawn by warning/fail, not by PASS. PASS
sits as neutral structure.

### Support — synthetic-library coverage
- `empty → #B2182B` (muted red anomaly)
- `sparse → #F9A825` (amber)
- `supported → #37474F` (neutral blue-gray, NOT green)

### Heat ramps
Sequential ramps: cream → muted teal.

- `sequential_low = #F7F4EF`
- `sequential_high = #1B5E63`

Diverging ramps: muted red ← cream → muted sage.

- `diverging_neg = #B2182B`
- `diverging_zero = #F7F4EF`
- `diverging_pos = #1B6B5E`

Saturated green (e.g. `#1B5E20`, `#009E73`) is not used for large
fills. Where a "positive" semantic was previously carried by
saturated green, it now flows through muted sage / teal so the rest
of the figure family stays calm.

### Stratum palette — muted categorical
A 9-entry muted Tableau-inspired palette used for the corpus / stratum
violin family. Order matters: strata are assigned in slug order.

```r
.VIS_COLORS$stratum_palette
#> c("#263238", "#557755", "#1B5E63", "#6D4C41", "#F9A825",
#>   "#EF6C00", "#8E24AA", "#0277BD", "#37474F")
```

The previously saturated `#1B5E20` plant-green entry is muted to
sage so the figure family is consistent. All other entries are kept
as-is.

### Component triad — 50's three-panel stack
Only used by 50's `.stratum_component_violin_stack()`:

- `effect → #0072B2` (Okabe-Ito blue)
- `heterogeneity → #1B5E63` (muted teal, replaces `#009E73`)
- `bias → #D55E00` (Okabe-Ito vermilion)

## Categorical vs sequential vs diverging

- **Categorical**: stratum (9 muted hues), rigor direction (2),
  rigor category (5), bootstrap mode (2), method (2).
- **Sequential**: bias burden (3, ordered slate → amber → red),
  effect level (4, ordered slate ramp), support coverage (3,
  ordered worst → best).
- **Diverging**: rigor atlas median log10 BF rigor (negative ←
  zero → positive), heat ramps.

## Print / grayscale / colorblind notes

- Method blue / red is high-contrast in grayscale.
- Rigor direction blue / purple is colorblind-readable and
  distinguishable in grayscale by luminosity.
- Bias burden slate / amber / red has clear luminosity ordering.
- Where two encodings overlap (e.g. bias × heterogeneity in the same
  panel), heterogeneity moves to linetype/shape so the color channel
  alone carries the bias signal.
- Reference / mu_true lines use a dark neutral gray (`#37474F` or
  `gray35`) and a dashed pattern.

## Where palette constants live

- `scripts/00_utils.R :: .VIS_COLORS` — single source of truth.
- `scripts/50_stratum_visuals.R` and `scripts/70_corpus_visuals.R`
  pull through their own `COLOR_*`, `.RIGOR_*`, `.tableau10` names
  so call sites are unchanged.
- `simulation/scripts/75_analysis_visuals.R` (renamed from
  `75_composition_visuals.R` in 2026-05) pulls through its own
  `.CV_*` constants which now read from `.VIS_COLORS` with a
  defensive fallback for the (impossible) case where
  `00_utils.R` was not sourced first.

## Adding a new semantic role

1. Add the role + hex values to `.VIS_COLORS` in `00_utils.R`.
2. Reference the role by name (e.g. `.VIS_COLORS$<role>[["<key>"]]`)
   from the plotting script.
3. Update the relevant section of this contract.
4. Never inline raw hex codes inside plot functions, except for
   one-off transparent annotation colors with comments explaining
   why they are not generic.
