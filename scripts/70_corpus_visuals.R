# 70_corpus_visuals.R
# ==============================================================================
# Corpus-level / cross-stratum manuscript figures (RoBMA 4.0 rigor pipeline).
#
# This is the cross-stratum visual counterpart to 60_estimand_tables.R. It
# consumes the canonical reporting outputs written by build_estimand_tables()
# and renders the corpus-wide component-evidence figures. It writes FIGURES
# ONLY; 60_estimand_tables.R is the single source of truth for every tabular
# schema and is never rebuilt or re-derived here.
#
# Inputs (read from <output_dir>, default "output/overview/"):
#   outcome_registry.csv   - one row per analyzed outcome/variant (REQUIRED)
# There is NO per-stratum sidecar rediscovery and NO silent fallback to an
# old schema: a missing or non-v4 registry is a hard error directing the
# caller to run build_estimand_tables() first.
#
# Outputs (written to <output_dir>):
#   corpus_effect_attenuation_boxplot_horizontal.pdf
#   corpus_effect_attenuation_strip.pdf
#   corpus_component_violin_effect.pdf
#   corpus_component_violin_heterogeneity.pdf
#   corpus_component_violin_bias.pdf
#   corpus_component_violin_stack.pdf
#   Rigor-first (Pass 2; include_rigor = TRUE, raw log10 axes):
#   corpus_rigor_violin_by_stratum.pdf
#   corpus_rigor_branch_scatter.pdf
#   corpus_rigor_direction_composition.pdf
#   corpus_rigor_category_composition.pdf
#   corpus_rigor_weighting_comparison.pdf
#   corpus_rigor_ranking_extremes.pdf
#   corpus_attenuation_vs_rigor.pdf
#   Optional QC / supplement (NOT default; include_bias_vs_rigor = TRUE):
#   corpus_bias_vs_rigor.pdf
#
# Orchard (evidence-axis transform) figures are RETIRED from the active
# pipeline. The active component-evidence displays are the DISPLAY-CAPPED
# raw-log10 violins below. A frozen copy of the old orchard module is
# kept under archive/ for provenance only; it is never sourced or called
# from here.
#
# The corpus-level component-BF VIOLINS and the rigor violin use raw
# log10(BF) axes with DISPLAY CAPPING at |log10(BF)| = LOG10_BF_DISPLAY_CAP
# (= 2): values beyond the cap, incl. +-Inf, are plotted AT the cap and feed
# the violin density/points/median/IQR/whiskers (a violin should represent
# the displayed distribution). The cap is display-only; raw registry/sidecar
# values are never mutated. The auxiliary rigor scatter/line figures (branch
# scatter, weighting, attenuation-vs-rigor, the optional bias-vs-rigor QC)
# still clamp Inf to a terminal axis boundary via .prep_rigor_axis() - they
# are not violins. See docs/visuals.md for the authoritative visual-scale
# contract.
#
# build_corpus_visuals() also returns an invisible lightweight diagnostics
# tibble ($diagnostics): one row per generated figure/component panel with
# scope, rows available/plotted/dropped, axis ranges used, the raw
# finite/+-Inf/NA distribution + per-cap counts (display-capped figures), and
# file-exists/size checks. It is returned only - no CSV is written here.
#
# DEFINE-ONLY: sourcing installs functions/constants and a load sentinel only.
# No package is attached, nothing is discovered, read, written, or plotted
# merely by sourcing. The plotting runtime is armed lazily inside the entry
# points (.ensure_visual_runtime()).
#
# Quick-Start
#   source("scripts/70_corpus_visuals.R")
#   build_corpus_visuals()                              # default output_dir
#   build_corpus_visuals(output_dir = "reports/figs")   # custom dir
#   build_corpus_visuals(verbose = FALSE)               # quieter run
# ==============================================================================


# ---- Shared contract + helpers (sentinel-guarded; 00_utils.R is define-only) -
# Provides format_stratum, %||%, .bf_evidence_transform, .bf_axis_spec,
# .compute_evidence_xlim, .compute_precision, .evidence_band_layers,
# .evidence_guide_layers.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}

# Plotting runtime, armed lazily so sourcing this file stays side-effect-free.
.ensure_visual_runtime <- function() {
  suppressPackageStartupMessages({
    library(tidyverse); library(fs); library(patchwork)
  })
}


# ==============================================================================
# Figure layout defaults  (edit sizes HERE, not in the plotting code)
# ==============================================================================
# Per-figure PDF save sizes, in inches. `height = NA` means the height scales
# with the stratum/row count and is supplied by the save site (the width is
# still taken from here). Tune a figure by changing one number below; the
# plotting logic does not hard-code sizes.
FIGURE_SIZES <- list(
  component_violin  = c(width =  6, height = NA),   # narrow; less dead space
  rigor_violin      = c(width =  6, height = NA),   # match component width
  violin_stack      = c(width = 9.5, height = NA),  # horizontal 3-panel; kept
                                                    # narrow so the figure is
                                                    # downscaled less at
                                                    # \linewidth => larger
                                                    # on-page text (matches the
                                                    # Section-4 sim visuals)
  attenuation_horiz = c(width = 10, height = NA),
  attenuation_strip = c(width = NA, height = NA)    # square; size from n
)

# One multiplier on every AUTO-computed (table `height = NA`) figure
# dimension, so the whole suite can be shifted with a single number. The
# per-stratum auto-scaling is good as-is for the ~8 nutrition strata; for a
# much larger corpus (e.g. ~20 strata) the figures would otherwise grow very
# tall/large, so drop this toward ~0.6–0.8 to compress them. 1 = current
# nutrition sizing (no change).
FIGURE_HEIGHT_SCALE <- 1

# Hard y-range (effect-size axis) for the attenuation strip boxplot. This is
# the pinned nutrition setting; `build_corpus_visuals(strip_ylim_override=)`
# defaults to it. Set to NULL here (or pass NULL) to auto-compute the range
# from the whisker span instead — auto works fine, this is just the pinned
# manuscript range.
ATTENUATION_STRIP_YLIM <- c(-0.05, 0.8)

# ggsave options shared by every corpus PDF (vector output, no dingbat font
# substitution, no size guard for tall faceted figures). Centralized so the
# save sites stay one-liners.
FIGURE_SAVE_DEFAULTS <- list(useDingbats = FALSE, limitsize = FALSE)

# Save a ggplot/patchwork as a corpus PDF using a FIGURE_SIZES key. width /
# height passed explicitly win over the table; a table NA must be resolved by
# the caller (used where the height scales with the stratum count).
save_corpus_plot <- function(plot, filename, size_key,
                             width = NA, height = NA, verbose = TRUE) {
  sz <- FIGURE_SIZES[[size_key]]
  if (is.null(sz))
    stop(sprintf("save_corpus_plot(): unknown FIGURE_SIZES key '%s'",
                 size_key), call. = FALSE)
  w <- if (!is.na(width))  width  else sz[["width"]]
  h <- if (!is.na(height)) height else sz[["height"]]
  if (is.na(w) || is.na(h))
    stop(sprintf("save_corpus_plot('%s'): unresolved width/height", size_key),
         call. = FALSE)
  do.call(ggplot2::ggsave,
          c(list(filename = filename, plot = plot, width = w, height = h),
            FIGURE_SAVE_DEFAULTS))
  if (verbose) message(sprintf("  ✓ Saved: %s", filename))
  invisible(filename)
}

# Auto figure dimension from the stratum/row count: max(min, per*n + base),
# then scaled by FIGURE_HEIGHT_SCALE so the whole suite shifts with one knob.
# Used wherever FIGURE_SIZES leaves a dimension NA (height scales with n).
auto_figure_dim <- function(n, per, base, min) {
  max(min, per * n + base) * FIGURE_HEIGHT_SCALE
}


# --- Module-level palette ----------------------------------------------------
# All color choices flow from `.VIS_COLORS` in scripts/00_utils.R (single
# source of truth; see docs/visual_color_contract.md). The names below
# are stable so callers throughout this file are unaffected.

# Categorical stratum palette: muted Tableau-inspired colors. Strata are
# mapped to colors in stable slug order inside build_corpus_visuals().
# The previously saturated plant-green entry has been muted to sage so
# the stratum violin family reads as one muted set.
.tableau10 <- .VIS_COLORS$stratum_palette

# rigor_direction is stored as effect / no_effect only (never "null").
# Both are POSITIVE evidential states; no_effect uses muted purple so
# it does not read as failure.
.RIGOR_DIR_COLORS <- .VIS_COLORS$rigor_direction

# Muted direction fills for the stacked composition bar -- now identical
# to the point-color map so the composition bar and the point scatter
# tell the same color story.
.RIGOR_DIR_BAR_COLORS <- .VIS_COLORS$rigor_direction

# Stable rigor_category plotting order (stored names unchanged) + readable
# legend labels. Any unexpected/uncategorized value sorts last as "other".
.RIGOR_CAT_ORDER <- c("clean_effect_supported", "clean_no_effect_supported",
                      "inconclusive_clean_evidence",
                      "clean_evidence_disfavored", "uncategorized")
.RIGOR_CAT_LABELS <- c(
  clean_effect_supported      = "Clean effect supported",
  clean_no_effect_supported   = "Clean no-effect supported",
  inconclusive_clean_evidence = "Inconclusive clean evidence",
  clean_evidence_disfavored   = "Clean evidence disfavored",
  uncategorized               = "Uncategorized / other")
# Category fills mirror rigor_direction for the two "clean supported"
# states; disfavored uses muted brown; inconclusive / uncategorized use
# neutral grays. (Pulled from .VIS_COLORS$rigor_category.)
.RIGOR_CAT_COLORS <- .VIS_COLORS$rigor_category


# ==============================================================================
# Lightweight visual diagnostics
# ==============================================================================
# One-row record per generated corpus figure (one per component panel for the
# faceted/stacked figures). Constructed AFTER ggsave() so the file checks
# reflect the written PDF. No CSV is written - build_corpus_visuals() returns
# the bound rows as an invisible tibble ($diagnostics). Kept local to this
# script (not shared) per the migration's "no new helper script" rule.
.diag_row <- function(plot_type, output_file,
                      scope_stratum = NA_character_,
                      scope_source_article = NA_character_,
                      scope_variant = NA_character_,
                      panel = NA_character_,
                      rows_available = NA_integer_,
                      rows_plotted = NA_integer_,
                      x_min = NA_real_, x_max = NA_real_,
                      y_min = NA_real_, y_max = NA_real_,
                      axis_override = "none",
                      n_outside_axis_override = NA_integer_,
                      n_inf = NA_integer_,
                      inf_disposition = NA_character_,
                      # --- violin-family display-cap accounting -------------
                      # Optional; default NA so non-violin callers (orchard,
                      # boxplot, composition, ...) keep a stable schema.
                      finite_n = NA_integer_,
                      pos_inf_n = NA_integer_,
                      neg_inf_n = NA_integer_,
                      missing_n = NA_integer_,
                      finite_min = NA_real_, finite_max = NA_real_,
                      capped_low_n = NA_integer_, capped_high_n = NA_integer_,
                      display_min = NA_real_, display_max = NA_real_,
                      display_cap = NA_real_) {
  fe <- file.exists(output_file)
  fs <- if (fe) suppressWarnings(file.size(output_file)) else NA_real_
  data.frame(
    plot_type = plot_type, panel = panel,
    scope_stratum = scope_stratum,
    scope_source_article = scope_source_article,
    scope_variant = scope_variant,
    output_file = output_file,
    rows_available = as.integer(rows_available),
    rows_plotted   = as.integer(rows_plotted),
    rows_dropped   = as.integer(rows_available) - as.integer(rows_plotted),
    x_min = x_min, x_max = x_max, y_min = y_min, y_max = y_max,
    axis_override = axis_override,
    n_outside_axis_override = as.integer(n_outside_axis_override),
    n_inf = as.integer(n_inf),
    inf_disposition = inf_disposition,
    finite_n  = as.integer(finite_n),
    pos_inf_n = as.integer(pos_inf_n),
    neg_inf_n = as.integer(neg_inf_n),
    missing_n = as.integer(missing_n),
    finite_min = finite_min, finite_max = finite_max,
    capped_low_n  = as.integer(capped_low_n),
    capped_high_n = as.integer(capped_high_n),
    display_min = display_min, display_max = display_max,
    display_cap = display_cap,
    file_exists  = fe,
    file_size_ok = isTRUE(fe) && !is.na(fs) && fs > 0,
    stringsAsFactors = FALSE
  )
}


# ==============================================================================
# Registry consumer (60 output; no sidecar rediscovery, no legacy fallback)
# ==============================================================================
.consume_reporting_registry <- function(output_dir, verbose) {
  vmsg <- function(...) if (verbose) message(...)

  csv_path <- file.path(output_dir, "outcome_registry.csv")
  if (!file.exists(csv_path)) {
    stop(sprintf(paste0(
      "Reporting registry not found: %s\n",
      "  The corpus visual layer is downstream of 60_estimand_tables.R.\n",
      "  Run build_estimand_tables() (scripts/60_estimand_tables.R) first."),
      csv_path), call. = FALSE)
  }
  vmsg(sprintf("Reading reporting registry: %s", csv_path))
  reg <- read_csv(csv_path, show_col_types = FALSE, progress = FALSE)

  # v4 columns these figures need. Their absence means this is not a v4
  # outcome_registry.csv (we never silently remap legacy topic/author/effect).
  req <- c("stratum", "source_article", "source_year", "outcome_slug",
           "dataset_id", "analysis_variant",
           "mu_RE", "mu_BC", "mu_BC_lCI", "mu_BC_uCI",
           "log10BF_effect", "log10BF_het", "log10BF_bias",
           "log10BF_rigor", "log10BF_rigor_effect",
           "log10BF_rigor_no_effect", "rigor_direction", "rigor_category")
  miss <- setdiff(req, names(reg))
  if (length(miss)) {
    stop(sprintf(paste0(
      "Registry is missing required v4 column(s): %s\n",
      "  %s is not a v4 outcome_registry.csv. Re-run build_estimand_tables()\n",
      "  (scripts/60_estimand_tables.R)."),
      paste(miss, collapse = ", "), csv_path), call. = FALSE)
  }

  # Coerce defensively (an all-empty cached column can come back wrong-typed)
  # and attach the stratum display label. The registry `stratum` column is a
  # slug; format_stratum() is the single source of the display form.
  reg <- reg %>%
    mutate(
      stratum          = as.character(stratum),
      source_article   = as.character(source_article),
      dataset_id       = as.character(dataset_id),
      analysis_variant = as.character(analysis_variant),
      has_excl_variant = if ("has_excl_variant" %in% names(reg))
        as.logical(has_excl_variant)
      else analysis_variant == "exclusion_sensitivity",
      n_studies      = suppressWarnings(as.integer(n_studies)),
      mu_RE          = suppressWarnings(as.numeric(mu_RE)),
      mu_BC          = suppressWarnings(as.numeric(mu_BC)),
      mu_BC_lCI      = suppressWarnings(as.numeric(mu_BC_lCI)),
      mu_BC_uCI      = suppressWarnings(as.numeric(mu_BC_uCI)),
      log10BF_effect = suppressWarnings(as.numeric(log10BF_effect)),
      log10BF_het    = suppressWarnings(as.numeric(log10BF_het)),
      log10BF_bias   = suppressWarnings(as.numeric(log10BF_bias)),
      log10BF_rigor           = suppressWarnings(as.numeric(log10BF_rigor)),
      log10BF_rigor_effect    =
        suppressWarnings(as.numeric(log10BF_rigor_effect)),
      log10BF_rigor_no_effect =
        suppressWarnings(as.numeric(log10BF_rigor_no_effect)),
      rigor_direction = as.character(rigor_direction),
      rigor_category  = as.character(rigor_category),
      source_year     = suppressWarnings(as.integer(source_year)),
      outcome_slug    = as.character(outcome_slug),
      stratum_label   = format_stratum(stratum)
    )
  reg
}


# ==============================================================================
# File-scope helpers (define-only; no execution at source time)
# ==============================================================================

# NOTE: the cross-stratum orchard (evidence-axis transform) has been
# RETIRED from the active pipeline. Its implementation is archived only
# (frozen copy under archive/ for provenance) and is never sourced or
# called from here. The active corpus component-evidence displays are
# the display-capped raw-log10 violins below.


# ---- Violin hybrid helpers ---------------------------------------------------

# Display cap for the corpus violin family. log10(BF) = 2 already means
# BF = 100; for these corpus-level distribution figures nothing visual is
# gained by distinguishing +2.3, +4.5 and +Inf - those outcomes are simply in
# the "very strong or stronger" evidence pile. Values beyond +/-cap (incl.
# +/-Inf) are winsorized onto the cap FOR DISPLAY ONLY; raw registry / sidecar
# values are never mutated.
LOG10_BF_DISPLAY_CAP <- 2

# Winsorize a raw log10(BF) vector onto +/-cap for plotting:
#   finite x >  cap  -> +cap ;  +Inf -> +cap
#   finite x < -cap  -> -cap ;  -Inf -> -cap
#   NA / NaN         -> NA   (excluded from the plot by the geoms)
# This is a display coordinate only - callers keep the raw column intact.
.cap_log10_bf_for_violin <- function(x, cap = LOG10_BF_DISPLAY_CAP) {
  x <- suppressWarnings(as.numeric(x))
  d <- x
  d[!is.na(x) & x >  cap] <-  cap     # also catches +Inf
  d[!is.na(x) & x < -cap] <- -cap     # also catches -Inf
  d
}

# Raw vs display-cap accounting for the diagnostics record. Counts the raw
# distribution and how many values land on each cap once winsorized.
.summarize_violin_display_cap <- function(x, cap = LOG10_BF_DISPLAY_CAP) {
  x   <- suppressWarnings(as.numeric(x))
  fin <- x[is.finite(x)]
  d   <- .cap_log10_bf_for_violin(x, cap)
  d   <- d[!is.na(d)]
  list(
    display_cap   = cap,
    finite_n      = length(fin),
    pos_inf_n     = sum(is.infinite(x) & x > 0),
    neg_inf_n     = sum(is.infinite(x) & x < 0),
    missing_n     = sum(is.na(x)),
    finite_min    = if (length(fin)) min(fin) else NA_real_,
    finite_max    = if (length(fin)) max(fin) else NA_real_,
    capped_low_n  = sum(!is.na(x) & x <= -cap),   # raw <= -cap, incl. -Inf
    capped_high_n = sum(!is.na(x) & x >=  cap),   # raw >=  cap, incl. +Inf
    display_min   = if (length(d)) min(d) else NA_real_,
    display_max   = if (length(d)) max(d) else NA_real_
  )
}

# Pivot the registry into long form for the violin plots: one row per
# (outcome, bf_type), bf_type in {"effect","heterogeneity","bias","rigor"}. A
# display-capped plotting coordinate `logBF_disp` is attached (raw `logBF`
# kept for diagnostics); +/-Inf and |x| > cap collapse onto +/-cap, NA stays
# NA. Nothing is dropped upstream - the geoms drop NA.
#
# `rigor` (log10BF_rigor) is carried here so the Section-5 triptych stack can
# place selected rigor in the SAME violin grammar (cap, evidence bands, guide
# lines) as the marginal component panels. It is a JOINT model-family Bayes
# factor, not a marginal component BF; the stack labels its panel accordingly.
# The standalone per-component violin loop only requests effect/het/bias, so
# adding rigor here writes no extra standalone file.
.compute_stratum_bf_long <- function(dat, cap = LOG10_BF_DISPLAY_CAP) {
  dat %>%
    select(stratum_display = stratum_label,
           effect        = log10BF_effect,
           heterogeneity = log10BF_het,
           bias          = log10BF_bias,
           rigor         = log10BF_rigor) %>%
    pivot_longer(c(effect, heterogeneity, bias, rigor),
                 names_to = "bf_type", values_to = "logBF") %>%
    mutate(logBF_disp = .cap_log10_bf_for_violin(logBF, cap))
}

# Stratum-level summary stats for the violin overlay, computed from the
# DISPLAY-CAPPED values so the median / IQR / 10-90% bars match the plotted
# (winsorized) distribution. Only NA is excluded; capped values participate.
.compute_stratum_bf_summary <- function(long_dat) {
  long_dat %>%
    filter(!is.na(logBF_disp)) %>%
    group_by(stratum_display, bf_type) %>%
    summarize(
      n_outcomes   = n(),
      median_logBF = median(logBF_disp),
      q10_logBF    = quantile(logBF_disp, 0.10),
      q25_logBF    = quantile(logBF_disp, 0.25),
      q75_logBF    = quantile(logBF_disp, 0.75),
      q90_logBF    = quantile(logBF_disp, 0.90),
      .groups = "drop"
    )
}

# x-axis geometry for a display-capped violin. The axis is driven by the
# displayed (capped) values with ordinary padding, EXCEPT that when the
# displayed data reach a cap the axis is extended a small fixed amount past
# the cap so the winsorized pile is not flush with the panel border. The cap
# tick is labelled "<= -cap" / ">= cap" (plotmath relation, drawn from the
# pdf-safe Symbol font); ordinary numeric ticks elsewhere.
#
#   disp   display-capped numeric vector (NA/non-finite ignored here)
#   cap    the display cap (LOG10_BF_DISPLAY_CAP)
.violin_axis <- function(disp, cap = LOG10_BF_DISPLAY_CAP) {
  disp <- disp[is.finite(disp)]
  if (length(disp)) {
    rng  <- range(disp)
    span <- diff(rng)
    pad  <- if (span > 0) 0.04 * span else 0.1
  } else {
    rng <- c(-1, 1); pad <- 0.1
  }
  cap_pad <- 0.10                         # breathing room past a used cap
  hit_hi <- length(disp) && rng[2] >=  cap - 1e-9
  hit_lo <- length(disp) && rng[1] <= -cap + 1e-9
  x_hi <- if (hit_hi)  cap + cap_pad else rng[2] + pad
  x_lo <- if (hit_lo) -cap - cap_pad else rng[1] - pad

  fb <- suppressWarnings(scales::extended_breaks(n = 5)(c(rng[1], rng[2])))
  fb <- fb[is.finite(fb) & fb > x_lo & fb < x_hi]
  if (hit_hi) fb <- fb[fb <  cap - 1e-9]
  if (hit_lo) fb <- fb[fb > -cap + 1e-9]

  brk <- c(if (hit_lo) -cap, fb, if (hit_hi) cap)
  num_lbl <- lapply(format(fb, trim = TRUE), function(s) bquote(.(s)))
  lbl <- c(if (hit_lo) list(bquote("" <= .(-cap))),
           num_lbl,
           if (hit_hi) list(bquote("" >= .(cap))))

  list(x_lo = x_lo, x_hi = x_hi, breaks = brk, labels = lbl,
       hit_lo = hit_lo, hit_hi = hit_hi)
}

# Build (and optionally save) a single violin hybrid plot. Returns the ggplot
# invisibly so the stacked figure can compose it. The component-BF violins
# use a RAW log10(BF) x-axis (not the evidence-axis transform) with DISPLAY
# CAPPING at +/-LOG10_BF_DISPLAY_CAP: a violin should represent the displayed
# density, so values beyond the cap (incl. +/-Inf) are winsorized onto the
# cap and participate in the density / points / summaries rather than being
# split into a separate rail. The same gray evidence bands / guide lines used
# by the rigor violin are reused here so the two families match.
#
# Visual contract: the display-capped value feeds the violin density, the
# median/IQR/10-90% summaries, the plotted points, and the auto x-range; the
# raw column is untouched; every value is accounted for in the returned info
# (raw finite/+Inf/-Inf/NA counts + how many landed on each cap).
.stratum_violin_plot <- function(long_dat, summary_dat, bf_type_filter,
                                 title, outfile = NULL,
                                 stratum_colors,
                                 show_x_axis = TRUE,
                                 show_x_title = TRUE,
                                 show_y_axis = TRUE,
                                 stratum_order = NULL,
                                 cap = LOG10_BF_DISPLAY_CAP,
                                 x_lab = expression(log[10](BF)),
                                 base_size = 13,
                                 subtitle = paste0(
                                   "Violin = outcome distribution; point = ",
                                   "median; thick bar = IQR; whiskers = 10–90%"
                                 ),
                                 save = TRUE,
                                 style = list(),
                                 verbose = TRUE) {

  default_style <- list(
    point_size        = 0.8,
    point_alpha       = 1.0,
    violin_alpha      = 0.28,
    iqr_linewidth     = 3.0,
    iqr_alpha         = 0.8,
    whisker_linewidth = 0.7,
    whisker_alpha     = 0.7,
    median_size_outer = 3.0,
    median_size_inner = 2.0,
    y_text_size       = 11,
    axis_text_size    = 10,
    title_size        = 12,
    plot_margin       = margin(12, 12, 6, 12)
  )
  st <- modifyList(default_style, as.list(style))

  vdat <- long_dat    %>% filter(bf_type == bf_type_filter)
  sdat <- summary_dat %>% filter(bf_type == bf_type_filter)

  # Raw vs display-cap accounting (corpus-level: every stratum, this BF type).
  scs <- .summarize_violin_display_cap(vdat$logBF, cap)

  if (nrow(vdat) == 0L) {
    if (verbose) message(sprintf("  Warning: no data for bf_type = %s",
                                 bf_type_filter))
    return(list(plot = NULL, info = c(list(
      rows_available = 0L, rows_plotted = 0L,
      x_min = NA_real_, x_max = NA_real_), scs)))
  }

  rows_available <- nrow(vdat)
  # Display-capped plotting coordinate (raw `logBF` untouched). NA drops out.
  vdat <- vdat %>% filter(!is.na(logBF_disp)) %>% mutate(x_disp = logBF_disp)
  n_plot <- nrow(vdat)

  sdat <- sdat %>% mutate(
    median_x = median_logBF,
    q10_x    = q10_logBF,
    q25_x    = q25_logBF,
    q75_x    = q75_logBF,
    q90_x    = q90_logBF
  )

  # Panel set = every stratum present. Two ordering modes:
  #  - stratum_order given (the horizontal stack): a SHARED order so rows line
  #    up across the three component panels; the y label is the plain stratum
  #    name (a per-component "(n=)" can't sit on one shared axis).
  #  - otherwise (standalone violin): order by ascending displayed median and
  #    annotate the plotted (non-missing, display-capped) n in the label.
  if (!is.null(stratum_order)) {
    label_map <- tibble(stratum_display = as.character(stratum_order)) %>%
      mutate(stratum_panel = stratum_display)
    panel_levels <- rev(label_map$stratum_panel)   # order[1] -> top row
  } else {
    n_plot_tbl <- vdat %>% count(stratum_display, name = "n_plot")
    med_tbl    <- sdat %>% select(stratum_display, median_x)
    label_map <- long_dat %>%
      filter(bf_type == bf_type_filter) %>%
      distinct(stratum_display) %>%
      left_join(n_plot_tbl, by = "stratum_display") %>%
      left_join(med_tbl,    by = "stratum_display") %>%
      mutate(n_plot = coalesce(n_plot, 0L),
             stratum_panel = paste0(stratum_display, " (n=", n_plot, ")")) %>%
      arrange(median_x)          # NA medians (no plotted value) sort last
    panel_levels <- label_map$stratum_panel
  }

  to_panel <- function(df) df %>%
    left_join(label_map %>% select(stratum_display, stratum_panel),
              by = "stratum_display") %>%
    mutate(stratum_panel = factor(stratum_panel, levels = panel_levels))
  vdat <- to_panel(vdat)
  sdat <- sdat %>%
    left_join(label_map %>% select(stratum_display, stratum_panel),
              by = "stratum_display") %>%
    mutate(stratum_panel = factor(stratum_panel, levels = panel_levels))

  n_strata <- length(panel_levels)

  # Axis driven by the displayed (capped) values; extended a touch past a
  # used cap so the winsorized pile is not flush with the border.
  ax <- .violin_axis(vdat$x_disp, cap)

  # Fill colour map keyed by stratum_panel.
  violin_fill_colors <- label_map %>%
    mutate(color = stratum_colors[as.character(stratum_display)]) %>%
    { setNames(.$color, .$stratum_panel) }

  p <- ggplot(vdat, aes(x = x_disp, y = stratum_panel)) +
    .rigor_evidence_bands(ax$x_lo, ax$x_hi) +
    .rigor_guide_lines(ax$x_lo, ax$x_hi, vertical = TRUE) +
    geom_violin(
      aes(fill = stratum_panel),
      color = "gray40", linewidth = 0.3,
      alpha = st$violin_alpha, scale = "width",
      trim = TRUE, adjust = 1.2,
      show.legend = FALSE
    ) +
    scale_fill_manual(values = violin_fill_colors)

  set.seed(3947)
  p <- p +
    geom_jitter(aes(color = stratum_panel),
                height = 0.12, width = 0,
                size = st$point_size, alpha = st$point_alpha,
                show.legend = FALSE) +
    scale_color_manual(values = violin_fill_colors)

  p <- p +
    geom_segment(data = sdat,
                 aes(x = q10_x, xend = q90_x,
                     y = stratum_panel, yend = stratum_panel),
                 color = "gray20",
                 linewidth = st$whisker_linewidth, alpha = st$whisker_alpha) +
    geom_segment(data = sdat,
                 aes(x = q25_x, xend = q75_x,
                     y = stratum_panel, yend = stratum_panel),
                 color = "gray15",
                 linewidth = st$iqr_linewidth, alpha = st$iqr_alpha) +
    geom_point(data = sdat,
               aes(x = median_x, y = stratum_panel),
               color = "white", size = st$median_size_outer, shape = 16) +
    geom_point(data = sdat,
               aes(x = median_x, y = stratum_panel),
               color = "gray10", size = st$median_size_inner, shape = 16)

  p <- p +
    coord_cartesian(xlim = c(ax$x_lo, ax$x_hi), clip = "off") +
    scale_x_continuous(expand = c(0, 0),
                       breaks = ax$breaks, labels = ax$labels) +
    scale_y_discrete(drop = FALSE) +
    labs(title = title, subtitle = subtitle,
         x = x_lab, y = NULL) +
    theme_minimal(base_size = base_size) +
    theme(
      panel.grid.minor   = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_blank(),
      axis.text.y  = element_text(face = "bold", size = st$y_text_size),
      axis.ticks.y = element_blank(),
      axis.text.x  = element_text(size = st$axis_text_size),
      axis.ticks.x = element_line(color = "gray60"),
      legend.position = "none",
      plot.title    = element_text(face = "bold", size = st$title_size),
      plot.subtitle = element_text(size = 9, color = "gray50"),
      plot.margin   = st$plot_margin,
      panel.border  = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line     = element_line(colour = "gray60", linewidth = 0.3)
    )

  # Horizontal stack: each component panel keeps its own display-capped x
  # axis; the shared stratum (y) labels are written only on the leftmost
  # panel, so show_x_axis / show_x_title / show_y_axis toggle accordingly.
  if (!show_x_axis) {
    p <- p + theme(
      axis.text.x  = element_blank(),
      axis.ticks.x = element_blank()
    )
  }
  if (!show_x_title) p <- p + theme(axis.title.x = element_blank())
  if (!show_y_axis)  p <- p + theme(axis.text.y  = element_blank())

  if (save && !is.null(outfile)) {
    plot_height <- auto_figure_dim(n_strata, 0.7, 1.5, 4.5)
    save_corpus_plot(p, outfile, "component_violin",
                     height = plot_height, verbose = verbose)
  }

  # rows_plotted = the plotted (display-capped, non-missing) count; the raw
  # finite/+Inf/-Inf/NA split and the per-cap counts live in `scs`.
  list(plot = p, info = c(list(
    rows_available = rows_available,
    rows_plotted   = n_plot,
    x_min = ax$x_lo, x_max = ax$x_hi), scs))
}


# ==============================================================================
# Rigor-first corpus figures (Pass 2)
# ==============================================================================
# These consume only 60 outputs and use RAW log10 axes (the same raw-log10
# family as the component violins; only the component ORCHARDS keep the
# evidence-axis transform). Rigor is defined as the larger of the
# effect-supporting and no-effect-supporting no-bias branch Bayes factors,
# max(log10BF_rigor_effect, log10BF_rigor_no_effect); it is not a Bayes factor
# for one fixed model family, and rigor_direction (effect / no_effect) records
# the winning branch. All helpers are local to this script.

# Wrap long caption/subtitle text (ggplot does not wrap text itself).
.wrap <- function(s, width = 105)
  paste(strwrap(s, width = width), collapse = "\n")

# Prepare a logBF-like vector for a RAW log10 axis. Finite values pass
# through; +Inf / -Inf are mapped to a symmetric terminal boundary so they
# are SHOWN (never silently dropped) at the axis edge; NA stays NA (geoms
# drop it). A user-supplied finite `cap` is the terminal boundary and finite
# values beyond it are pulled to the boundary and counted (n_outside). With
# the default (auto) cap nothing finite is ever pulled.
.prep_rigor_axis <- function(x, cap = NULL) {
  x   <- suppressWarnings(as.numeric(x))
  n_inf <- sum(is.infinite(x))
  n_na  <- sum(is.na(x))
  fin   <- x[is.finite(x)]
  user_cap <- !is.null(cap) && is.finite(cap) && cap > 0
  if (!user_cap) {
    m   <- if (length(fin)) max(abs(fin)) else 1
    cap <- if (is.finite(m) && m > 0) m * 1.08 + 0.1 else 1
  }
  n_outside <- if (user_cap) sum(is.finite(x) & abs(x) > cap) else 0L
  v <- x
  v[is.infinite(x) & x > 0] <-  cap
  v[is.infinite(x) & x < 0] <- -cap
  v[is.finite(x) & v >  cap] <-  cap
  v[is.finite(x) & v < -cap] <- -cap
  list(value = v, cap = cap, user_cap = user_cap,
       n_inf = n_inf, n_na = n_na, n_outside = n_outside,
       disposition = if (n_inf > 0L) "capped_terminal_axis" else "none")
}

# Reference/guide lines within [lo, hi]: 0 solid, +-0.5 / +-1 dashed.
.rigor_guide_lines <- function(lo, hi, vertical = TRUE,
                               thresholds = c(-1, -0.5, 0, 0.5, 1)) {
  if (!is.finite(lo) || !is.finite(hi)) return(list())
  th <- thresholds[thresholds >= lo & thresholds <= hi]
  lapply(th, function(t) {
    lt <- if (t == 0) "solid"  else "dashed"
    cl <- if (t == 0) "gray30" else "gray65"
    if (vertical)
      ggplot2::geom_vline(xintercept = t, linetype = lt, color = cl,
                          linewidth = 0.4)
    else
      ggplot2::geom_hline(yintercept = t, linetype = lt, color = cl,
                          linewidth = 0.4)
  })
}

# Evidence-style gray bands on a RAW log10(BF/statistic) axis: the same
# qualitative shading the component orchards get from .evidence_band_layers(),
# but placed at raw log10 thresholds (no evidence-axis transform of the
# data). This is the shared band helper for BOTH the rigor violin
# and the raw-log10 component violins, so the two violin families look
# identical. Band edges are the standard BF cut points |log10 BF| =
# log10(3), 1, 2 (BF = 1/3, 3, 1/10, 10, 1/100, 100); the neutral BF 1/3..3
# zone is left
# unshaded; darker = stronger evidence; symmetric on the negative side.
# Clamped to the visible [lo, hi] so finite edges never expand the scale
# (the caller pairs this with coord_cartesian(xlim = c(lo, hi))). Local to
# this script; 00_utils.R is not modified.
.rigor_evidence_bands <- function(lo, hi) {
  if (!is.finite(lo) || !is.finite(hi) || hi <= lo) return(list())
  e <- list(m2 = -2, m1 = -1, m05 = -log10(3),
            p05 =  log10(3), p1 = 1, p2 = 2)
  layers <- list()
  push <- function(a, b, fill) {
    a <- max(a, lo); b <- min(b, hi)
    if (b <= a) return(invisible(NULL))
    layers[[length(layers) + 1L]] <<- ggplot2::annotate(
      "rect", xmin = a, xmax = b, ymin = -Inf, ymax = Inf,
      fill = fill, alpha = 0.2)
  }
  push(-Inf,  e$m2,  "gray10")   # |log10 BF| > 2      (very strong, neg)
  push(e$m2,  e$m1,  "gray30")   # 1 .. 2              (strong, neg)
  push(e$m1,  e$m05, "gray70")   # log10(3) .. 1       (moderate, neg)
  # BF 1/3 .. 3 (|log10 BF| < log10(3)) intentionally left unshaded.
  push(e$p05, e$p1,  "gray70")   # log10(3) .. 1       (moderate, pos)
  push(e$p1,  e$p2,  "gray30")   # 1 .. 2              (strong, pos)
  push(e$p2,   Inf,  "gray10")   # |log10 BF| > 2      (very strong, pos)
  layers
}

# Inf-aware caption fragment for the terminal-boundary note.
.inf_note <- function(pr) {
  if (pr$n_inf > 0L)
    sprintf(paste0(" Infinite values (n=%d) shown at the terminal axis ",
                   "boundary (±%.2f)."), pr$n_inf, pr$cap)
  else ""
}

# Hard read of a required 60 output (used where the spec gives no registry
# fallback). Missing / schema-incompatible -> clear run-60 error.
.read_60_output <- function(output_dir, name, required_cols, verbose) {
  p <- file.path(output_dir, name)
  if (!file.exists(p))
    stop(sprintf(paste0(
      "Required 60 output not found: %s\n",
      "  Run build_estimand_tables() (scripts/60_estimand_tables.R) first."),
      p), call. = FALSE)
  d <- read_csv(p, show_col_types = FALSE, progress = FALSE)
  miss <- setdiff(required_cols, names(d))
  if (length(miss))
    stop(sprintf(paste0(
      "60 output %s missing expected column(s): %s\n",
      "  Re-run build_estimand_tables() (scripts/60_estimand_tables.R)."),
      p, paste(miss, collapse = ", ")), call. = FALSE)
  if (verbose) message(sprintf("Reading 60 output: %s", p))
  d
}

# Soft read of a PREFERRED 60 summary: returns the data frame, or NULL (with
# a message) if absent or schema-incompatible so the caller can fall back to
# the registry. Never reconstructs a 60 schema silently.
.read_60_output_soft <- function(output_dir, name, required_cols, verbose) {
  p <- file.path(output_dir, name)
  if (!file.exists(p)) {
    message(sprintf(paste0(
      "Preferred 60 summary %s not found; computing this composition from ",
      "outcome_registry.csv instead."), p))
    return(NULL)
  }
  d <- tryCatch(read_csv(p, show_col_types = FALSE, progress = FALSE),
                error = function(e) NULL)
  if (is.null(d) || length(setdiff(required_cols, names(d)))) {
    message(sprintf(paste0(
      "Preferred 60 summary %s has an unexpected schema; computing this ",
      "composition from outcome_registry.csv instead."), p))
    return(NULL)
  }
  if (verbose) message(sprintf("Reading 60 output: %s", p))
  d
}

# Order strata (display labels) by ascending median rigor so the
# highest-median stratum sits at the TOP of the violin / first reading slot.
.rigor_stratum_order <- function(registry, cap) {
  v <- .prep_rigor_axis(registry$log10BF_rigor, cap)$value
  agg <- tapply(v, registry$stratum_label, function(z)
    if (all(is.na(z))) NA_real_ else median(z, na.rm = TRUE))
  names(sort(agg, na.last = TRUE))
}

# Common diagnostics shell for a single-ggplot rigor figure.
.rigor_info <- function(rows_available, rows_plotted, x_rng, y_rng, pr) {
  list(rows_available = rows_available, rows_plotted = rows_plotted,
       x_min = x_rng[1], x_max = x_rng[2],
       y_min = y_rng[1], y_max = y_rng[2],
       axis_override = if (isTRUE(pr$user_cap)) "rigor_cap" else "none",
       n_outside = if (isTRUE(pr$user_cap)) pr$n_outside else NA_integer_,
       n_inf = pr$n_inf, inf_disposition = pr$disposition)
}


# 1. corpus_rigor_violin_by_stratum.pdf -- flagship rigor distribution
# Visual contract (same as the component violins): rigor log10BF is
# DISPLAY-CAPPED at +/-LOG10_BF_DISPLAY_CAP. The capped value feeds the violin
# density, the median/IQR/10-90% summaries and the points; values beyond the
# cap (incl. -Inf / +Inf) pile onto the cap rather than going to a separate
# rail. The legacy `cap` arg (build's `rigor_axis_cap`) is intentionally
# unused here - the display cap is the fixed corpus convention; raw
# log10BF_rigor is never mutated. Strata keep the shared `rigor_levels`
# order so this figure stays consistent with the other rigor figures.
.rigor_violin_by_stratum <- function(registry, outfile, stratum_colors,
                                     rigor_levels, cap, verbose) {
  dcap <- LOG10_BF_DISPLAY_CAP
  raw  <- suppressWarnings(as.numeric(registry$log10BF_rigor))
  scs  <- .summarize_violin_display_cap(raw, dcap)

  base <- registry
  base$rig <- .cap_log10_bf_for_violin(raw, dcap)   # display coordinate only
  base$stratum_label <- factor(base$stratum_label, levels = rigor_levels)
  d <- base[!is.na(base$rig), , drop = FALSE]
  n_plot <- nrow(d)

  # Per-stratum summaries from the DISPLAY-CAPPED values.
  lab <- d %>%
    group_by(stratum_label) %>%
    summarize(n = n(), med = median(rig),
              q10 = quantile(rig, .10), q25 = quantile(rig, .25),
              q75 = quantile(rig, .75), q90 = quantile(rig, .90),
              .groups = "drop")
  panel_tbl <- base %>%
    distinct(stratum_label) %>%
    left_join(d %>% count(stratum_label, name = "n"),
              by = "stratum_label") %>%
    mutate(n = coalesce(as.integer(n), 0L),
           panel = paste0(as.character(stratum_label), " (n=", n, ")")) %>%
    arrange(stratum_label)               # shared rigor_levels order
  plev <- panel_tbl$panel

  attach_panel <- function(df) df %>%
    left_join(panel_tbl %>% select(stratum_label, panel),
              by = "stratum_label") %>%
    mutate(panel = factor(panel, levels = plev))
  d   <- attach_panel(d)
  lab <- lab %>%
    left_join(panel_tbl %>% select(stratum_label, panel),
              by = "stratum_label") %>%
    mutate(panel = factor(panel, levels = plev))

  # Axis driven by the displayed (capped) values; extended slightly past a
  # used cap so the winsorized pile is not flush with the border.
  ax <- .violin_axis(d$rig, dcap)

  # Compact subtitle matching the component-violin voice; it must fit the
  # narrow (width = 6) figure, so the display-cap convention is conveyed by
  # the ≤ -2 / ≥ 2 cap tick + docs/visuals.md rather than a subtitle clause.
  sub <- "Violin = outcomes; point = median; thick bar = IQR; whiskers = 10–90%."

  # Same gray evidence shading the component violins get, drawn at raw log10
  # BF thresholds, clamped to the displayed (capped) window.
  p <- ggplot(d, aes(x = rig, y = panel)) +
    .rigor_evidence_bands(ax$x_lo, ax$x_hi) +
    .rigor_guide_lines(ax$x_lo, ax$x_hi, vertical = TRUE) +
    geom_violin(aes(fill = stratum_label), color = "gray40",
                linewidth = 0.3, alpha = 0.28, scale = "width",
                trim = TRUE, adjust = 1.2, show.legend = FALSE) +
    geom_jitter(aes(color = stratum_label), height = 0.12, width = 0,
                size = 0.8, alpha = 1.0, show.legend = FALSE) +
    geom_segment(data = lab, aes(x = q10, xend = q90, y = panel,
                                 yend = panel),
                 color = "gray20", linewidth = 0.7, alpha = 0.7) +
    geom_segment(data = lab, aes(x = q25, xend = q75, y = panel,
                                 yend = panel),
                 color = "gray15", linewidth = 3.0, alpha = 0.8) +
    geom_point(data = lab, aes(x = med, y = panel), color = "white",
               size = 3.0, shape = 16) +
    geom_point(data = lab, aes(x = med, y = panel), color = "gray10",
               size = 2.0, shape = 16) +
    scale_fill_manual(values = stratum_colors) +
    scale_color_manual(values = stratum_colors) +
    scale_x_continuous(expand = c(0, 0),
                       breaks = ax$breaks, labels = ax$labels) +
    scale_y_discrete(drop = FALSE) +
    coord_cartesian(xlim = c(ax$x_lo, ax$x_hi), clip = "off") +
    labs(title = "Rigor across strata", subtitle = sub,
         x = expression(log[10](BF[rigor])), y = NULL) +
    theme_minimal(base_size = 13) +
    theme(
      panel.grid.minor   = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_blank(),
      axis.text.y  = element_text(face = "bold", size = 11),
      axis.ticks.y = element_blank(),
      axis.text.x  = element_text(size = 10),
      axis.ticks.x = element_line(color = "gray60"),
      legend.position = "none",
      plot.title    = element_text(face = "bold", size = 12),
      plot.subtitle = element_text(size = 9, color = "gray50"),
      plot.margin   = margin(12, 12, 6, 12),
      panel.border  = element_rect(colour = "gray30", fill = NA,
                                   linewidth = 0.4),
      axis.line     = element_line(colour = "gray60", linewidth = 0.3))

  save_corpus_plot(p, outfile, "rigor_violin",
                   height = auto_figure_dim(length(plev), 0.7, 1.5, 4.5),
                   verbose = verbose)

  n_nonfin <- scs$pos_inf_n + scs$neg_inf_n
  list(info = c(list(
    rows_available = nrow(registry), rows_plotted = n_plot,
    x_min = ax$x_lo, x_max = ax$x_hi,
    y_min = NA_real_, y_max = NA_real_,
    axis_override = "none", n_outside = NA_integer_,
    n_inf = n_nonfin,
    inf_disposition = if (n_nonfin == 0L) "none" else "display_capped"),
    scs))
}


# 2. corpus_rigor_branch_scatter.pdf -- branch-selection mechanism
.rigor_branch_scatter <- function(registry, outfile, cap, verbose) {
  prb <- .prep_rigor_axis(c(registry$log10BF_rigor_effect,
                            registry$log10BF_rigor_no_effect), cap)
  n  <- nrow(registry)
  xe <- .prep_rigor_axis(registry$log10BF_rigor_no_effect, prb$cap)$value
  ye <- .prep_rigor_axis(registry$log10BF_rigor_effect,    prb$cap)$value
  d  <- tibble(x = xe, y = ye,
               rigor_direction = registry$rigor_direction,
               analysis_variant = registry$analysis_variant)
  d  <- d[is.finite(d$x) & is.finite(d$y), , drop = FALSE]

  lim <- range(c(d$x, d$y), 0, na.rm = TRUE)
  sub <- .wrap(paste0("Points above the y = x line select the effect branch; ",
    "points below select no_effect (ties resolve to effect). Rigor ",
    "= max of the two branch log10 BFs.", .inf_note(prb)))

  p <- ggplot(d, aes(x = x, y = y)) +
    geom_abline(slope = 1, intercept = 0, color = "gray45",
                linetype = "dashed", linewidth = 0.5) +
    .rigor_guide_lines(lim[1], lim[2], vertical = TRUE,
                       thresholds = c(0, 0.5, 1)) +
    .rigor_guide_lines(lim[1], lim[2], vertical = FALSE,
                       thresholds = c(0, 0.5, 1)) +
    geom_point(aes(color = rigor_direction, shape = analysis_variant),
               size = 2.4, alpha = 0.8) +
    scale_color_manual(values = .RIGOR_DIR_COLORS, na.value = "gray70",
                       name = "Rigor direction") +
    scale_shape_manual(values = c(main = 16,
                                  exclusion_sensitivity = 17),
                       na.value = 4, name = "Analysis variant") +
    coord_equal() +
    labs(title = "Rigor branch scatter", subtitle = sub,
         x = expression("No-effect / no-bias branch " * log[10](BF)),
         y = expression("Effect / no-bias branch " * log[10](BF))) +
    theme_minimal(base_size = 13) +
    theme(panel.grid.minor = element_blank(),
          plot.title = element_text(face = "bold", size = 13),
          plot.subtitle = element_text(size = 8.5, color = "gray45"),
          legend.position = "right",
          panel.border = element_rect(colour = "gray30", fill = NA,
                                      linewidth = 0.4),
          axis.line = element_line(colour = "gray60", linewidth = 0.3))

  ggsave(outfile, p, width = 7.5, height = 6.5, useDingbats = FALSE)
  if (verbose) message(sprintf("  ✓ Saved: %s", outfile))
  list(info = .rigor_info(n, nrow(d), range(d$x, na.rm = TRUE),
                          range(d$y, na.rm = TRUE), prb))
}


# Shared stacked-proportional bar (direction / category composition).
.rigor_composition_bar <- function(long_df, fill_levels, fill_labels,
                                    fill_colors, title, outfile,
                                    stratum_order, n_strata, verbose) {
  long_df$stratum_label <- factor(long_df$stratum_label,
                                  levels = stratum_order)
  long_df$fill <- factor(long_df$fill, levels = fill_levels)

  p <- ggplot(long_df, aes(x = stratum_label, y = prop, fill = fill)) +
    geom_col(width = 0.78, color = "white", linewidth = 0.2) +
    scale_fill_manual(values = fill_colors, labels = fill_labels,
                      breaks = fill_levels, drop = FALSE, name = NULL) +
    scale_y_continuous(labels = function(z) paste0(round(100 * z), "%"),
                       expand = expansion(mult = c(0, 0.02))) +
    labs(title = title, x = NULL, y = "Proportion of outcomes") +
    theme_minimal(base_size = 13) +
    theme(panel.grid.major.x = element_blank(),
          panel.grid.minor = element_blank(),
          plot.title = element_text(face = "bold", size = 13),
          axis.text.x = element_text(face = "bold", angle = 45,
                                     hjust = 1, vjust = 1),
          legend.position = "bottom",
          panel.border = element_rect(colour = "gray30", fill = NA,
                                      linewidth = 0.4),
          axis.line = element_line(colour = "gray60", linewidth = 0.3))

  ggsave(outfile, p, width = max(6, 0.9 * n_strata + 2), height = 6,
         limitsize = FALSE, useDingbats = FALSE)
  if (verbose) message(sprintf("  ✓ Saved: %s", outfile))
}


# 3. corpus_rigor_direction_composition.pdf
.rigor_direction_composition <- function(registry, output_dir, outfile,
                                         stratum_order, verbose) {
  s <- .read_60_output_soft(
    output_dir, "rigor_direction_summary.csv",
    c("stratum", "prop_effect", "prop_no_effect"), verbose)
  if (!is.null(s)) {
    s <- s[s$stratum != "Overall", , drop = FALSE]
    long <- bind_rows(
      tibble(stratum = s$stratum, fill = "effect",
             prop = suppressWarnings(as.numeric(s$prop_effect))),
      tibble(stratum = s$stratum, fill = "no_effect",
             prop = suppressWarnings(as.numeric(s$prop_no_effect))))
    n_avail <- nrow(s)
  } else {
    g <- registry[registry$rigor_direction %in% c("effect", "no_effect"), ,
                  drop = FALSE]
    tab <- g %>% group_by(stratum, rigor_direction) %>%
      summarize(nn = n(), .groups = "drop_last") %>%
      mutate(prop = nn / sum(nn)) %>% ungroup()
    long <- tibble(stratum = tab$stratum, fill = tab$rigor_direction,
                   prop = tab$prop)
    n_avail <- n_distinct(g$stratum)
  }
  long$stratum_label <- format_stratum(long$stratum)
  long <- long[!is.na(long$prop), , drop = FALSE]

  .rigor_composition_bar(
    long, fill_levels = c("effect", "no_effect"),
    fill_labels = c(effect = "Effect", no_effect = "No effect"),
    fill_colors = .RIGOR_DIR_BAR_COLORS,
    title = "Rigor direction composition by stratum",
    outfile = outfile, stratum_order = stratum_order,
    n_strata = n_distinct(long$stratum_label), verbose = verbose)

  list(info = list(rows_available = n_avail,
                   rows_plotted = n_distinct(long$stratum_label),
                   x_min = NA_real_, x_max = NA_real_,
                   y_min = 0, y_max = 1, axis_override = "none",
                   n_outside = NA_integer_, n_inf = 0L,
                   inf_disposition = "none"))
}


# 4. corpus_rigor_category_composition.pdf
.rigor_category_composition <- function(registry, output_dir, outfile,
                                        stratum_order, verbose) {
  cats <- .RIGOR_CAT_ORDER
  prop_cols <- paste0("prop_", cats)
  s <- .read_60_output_soft(
    output_dir, "rigor_category_summary.csv",
    c("stratum", prop_cols[1]), verbose)
  if (!is.null(s)) {
    s <- s[s$stratum != "Overall", , drop = FALSE]
    long <- bind_rows(lapply(cats, function(ct) {
      col <- paste0("prop_", ct)
      tibble(stratum = s$stratum, fill = ct,
             prop = if (col %in% names(s))
               suppressWarnings(as.numeric(s[[col]])) else 0)
    }))
    n_avail <- nrow(s)
  } else {
    rc <- registry$rigor_category
    rc[is.na(rc) | !(rc %in% cats)] <- "uncategorized"
    tab <- tibble(stratum = registry$stratum, rc = rc) %>%
      group_by(stratum, rc) %>% summarize(nn = n(), .groups = "drop_last") %>%
      mutate(prop = nn / sum(nn)) %>% ungroup()
    long <- tibble(stratum = tab$stratum, fill = tab$rc, prop = tab$prop)
    n_avail <- n_distinct(registry$stratum)
  }
  long$stratum_label <- format_stratum(long$stratum)
  long <- long[!is.na(long$prop) & long$prop > 0, , drop = FALSE]

  .rigor_composition_bar(
    long, fill_levels = cats, fill_labels = .RIGOR_CAT_LABELS,
    fill_colors = .RIGOR_CAT_COLORS,
    title = "Rigor category composition by stratum",
    outfile = outfile, stratum_order = stratum_order,
    n_strata = n_distinct(long$stratum_label), verbose = verbose)

  list(info = list(rows_available = n_avail,
                   rows_plotted = n_distinct(long$stratum_label),
                   x_min = NA_real_, x_max = NA_real_,
                   y_min = 0, y_max = 1, axis_override = "none",
                   n_outside = NA_integer_, n_inf = 0L,
                   inf_disposition = "none"))
}


# 5. corpus_rigor_weighting_comparison.pdf -- outcome-weighted vs article-bal.
.rigor_weighting_comparison <- function(output_dir, outfile, cap,
                                        stratum_order, verbose) {
  se <- .read_60_output(output_dir, "stratum_estimands.csv",
                        c("stratum", "median_log10BF_rigor"), verbose)
  ab <- .read_60_output(output_dir, "article_balanced_estimands.csv",
                        c("stratum", "article_balanced_median_log10BF_rigor"),
                        verbose)
  se <- se[se$stratum != "Overall", c("stratum", "median_log10BF_rigor")]
  ab <- ab[ab$stratum != "Overall",
           c("stratum", "article_balanced_median_log10BF_rigor")]
  m <- merge(se, ab, by = "stratum", all = TRUE)
  pr <- .prep_rigor_axis(c(m$median_log10BF_rigor,
                           m$article_balanced_median_log10BF_rigor), cap)
  half <- length(pr$value) / 2
  m$ow <- pr$value[seq_len(half)]
  m$ab <- pr$value[(half + 1):(2 * half)]
  m$stratum_label <- format_stratum(m$stratum)
  m$stratum_label <- factor(m$stratum_label, levels = stratum_order)

  long <- bind_rows(
    tibble(stratum_label = m$stratum_label, weighting = "Outcome-weighted",
           y = m$ow),
    tibble(stratum_label = m$stratum_label, weighting = "Article-balanced",
           y = m$ab))
  yr <- range(long$y, 0, na.rm = TRUE)
  sub <- .wrap(paste0("Median selected log10 rigor per stratum: ",
    "outcome-weighted (stratum_estimands.csv) vs article-balanced ",
    "(article_balanced_estimands.csv). Overall excluded.", .inf_note(pr)))

  p <- ggplot() +
    .rigor_guide_lines(yr[1], yr[2], vertical = FALSE) +
    geom_segment(data = m, aes(x = stratum_label, xend = stratum_label,
                               y = ow, yend = ab),
                 color = "gray55", linewidth = 0.6) +
    geom_point(data = long, aes(x = stratum_label, y = y,
                                color = weighting),
               size = 3) +
    scale_color_manual(values = c(
      "Outcome-weighted" = .VIS_COLORS$bootstrap_mode[["outcome"]],
      "Article-balanced" = .VIS_COLORS$bootstrap_mode[["source_cluster"]]),
      name = NULL) +
    labs(title = "Rigor: outcome-weighted vs article-balanced",
         subtitle = sub, x = NULL,
         y = expression("Median selected " * log[10](BF[rigor]))) +
    theme_minimal(base_size = 13) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank(),
          plot.title = element_text(face = "bold", size = 13),
          plot.subtitle = element_text(size = 8.5, color = "gray45"),
          axis.text.x = element_text(face = "bold", angle = 45,
                                     hjust = 1, vjust = 1),
          legend.position = "bottom",
          panel.border = element_rect(colour = "gray30", fill = NA,
                                      linewidth = 0.4),
          axis.line = element_line(colour = "gray60", linewidth = 0.3))

  ggsave(outfile, p, width = max(6, 0.9 * nrow(m) + 2), height = 6,
         limitsize = FALSE, useDingbats = FALSE)
  if (verbose) message(sprintf("  ✓ Saved: %s", outfile))
  list(info = list(rows_available = nrow(m),
                   rows_plotted = sum(!is.na(m$ow) | !is.na(m$ab)),
                   x_min = NA_real_, x_max = NA_real_,
                   y_min = yr[1], y_max = yr[2],
                   axis_override = if (isTRUE(pr$user_cap)) "rigor_cap"
                                   else "none",
                   n_outside = if (isTRUE(pr$user_cap)) pr$n_outside
                               else NA_integer_,
                   n_inf = pr$n_inf, inf_disposition = pr$disposition))
}


# Forest-plot-style two-line outcome label (shared style with the 50 forest):
#   OUTCOME NAME (REDUCED SET)
#   Author Year  n=k
# Robust to a compact registry that may lack source_year / n_studies.
.forest_style_label <- function(df) {
  sa       <- as.character(df$source_article)
  src_name <- sub("[0-9]+$", "", sa)
  yr <- if ("source_year" %in% names(df))
    suppressWarnings(as.integer(df$source_year)) else rep(NA_integer_, nrow(df))
  src_label <- ifelse(
    !is.na(yr) & nzchar(src_name),
    paste0(tools::toTitleCase(src_name), " ", yr),
    tools::toTitleCase(sa))
  excl  <- !is.na(df$analysis_variant) &
           df$analysis_variant == "exclusion_sensitivity"
  base  <- .strip_excl_suffix(as.character(df$outcome_slug))
  oname <- stringr::str_to_title(gsub("_", " ", base))
  suffix <- ifelse(excl, " (reduced set)", "")
  nval <- if ("n_studies" %in% names(df))
    suppressWarnings(as.integer(df$n_studies)) else rep(NA_integer_, nrow(df))
  n_label <- ifelse(!is.na(nval), paste0("  n=", nval), "")
  paste0(toupper(oname), toupper(suffix), "\n", src_label, n_label)
}

# 6. corpus_rigor_ranking_extremes.pdf -- strongest/weakest outcomes
# Display-capped at |log10(BF_rigor)| = 2 (same convention as the violins);
# forest-plot-style labels; no terminal-boundary Inf language.
.rigor_top_bottom_outcomes <- function(output_dir, registry, outfile,
                                       top_n, cap, verbose) {
  dcap <- LOG10_BF_DISPLAY_CAP
  comp_path <- file.path(output_dir, "outcome_registry_compact.csv")
  if (file.exists(comp_path)) {
    d <- read_csv(comp_path, show_col_types = FALSE, progress = FALSE)
    src <- "outcome_registry_compact.csv"
  } else {
    d <- registry
    src <- "outcome_registry.csv"
  }
  if (verbose) message(sprintf("Reading 60 output: %s/%s", output_dir, src))
  d <- d[!is.na(suppressWarnings(as.numeric(d$log10BF_rigor))), ,
         drop = FALSE]
  raw <- suppressWarnings(as.numeric(d$log10BF_rigor))
  ord <- order(-raw)              # +Inf first, -Inf last, ties stable
  k   <- min(top_n, ceiling(nrow(d) / 2))
  idx <- unique(c(head(ord, k), tail(ord, k)))
  d   <- d[idx, , drop = FALSE]

  scs <- .summarize_violin_display_cap(d$log10BF_rigor, dcap)
  d$val <- .cap_log10_bf_for_violin(d$log10BF_rigor, dcap)
  d$dir <- d$rigor_direction
  d$lab <- .forest_style_label(d)
  if (anyDuplicated(d$lab))
    d$lab <- paste0(d$lab, "  (", d$dataset_id, ")")
  d <- d[order(d$val), , drop = FALSE]
  d$lab <- factor(d$lab, levels = d$lab)

  ax  <- .violin_axis(d$val, dcap)
  sub <- sprintf(paste0("Top and bottom %d outcomes by rigor; ",
                        "colour = rigor direction."), k)

  p <- ggplot(d, aes(x = val, y = lab, color = dir)) +
    .rigor_guide_lines(ax$x_lo, ax$x_hi, vertical = TRUE) +
    geom_segment(aes(x = 0, xend = val, y = lab, yend = lab),
                 color = "gray70", linewidth = 0.4) +
    geom_point(size = 2.6) +
    scale_color_manual(values = .RIGOR_DIR_COLORS, na.value = "gray60",
                       name = "Rigor direction") +
    scale_x_continuous(expand = c(0, 0),
                       breaks = ax$breaks, labels = ax$labels) +
    coord_cartesian(xlim = c(ax$x_lo, ax$x_hi), clip = "off") +
    labs(title = "Outcome-level rigor — strongest & weakest",
         subtitle = sub, x = expression(log[10](BF[rigor])), y = NULL) +
    theme_minimal(base_size = 11) +
    theme(panel.grid.minor = element_blank(),
          panel.grid.major.y = element_blank(),
          plot.title = element_text(face = "bold", size = 13),
          plot.subtitle = element_text(size = 8.5, color = "gray45"),
          legend.position = "bottom",
          axis.text.y = element_text(size = 7.5, lineheight = 0.9),
          panel.border = element_rect(colour = "gray30", fill = NA,
                                      linewidth = 0.4),
          axis.line = element_line(colour = "gray60", linewidth = 0.3))

  ggsave(outfile, p, width = 9, height = max(4, 0.42 * nrow(d) + 1.6),
         limitsize = FALSE, useDingbats = FALSE)
  if (verbose) message(sprintf("  ✓ Saved: %s", outfile))
  n_nonfin <- scs$pos_inf_n + scs$neg_inf_n
  list(info = c(list(
    rows_available = nrow(d), rows_plotted = nrow(d),
    x_min = ax$x_lo, x_max = ax$x_hi,
    y_min = NA_real_, y_max = NA_real_,
    axis_override = "none", n_outside = NA_integer_,
    n_inf = n_nonfin,
    inf_disposition = if (n_nonfin == 0L) "none" else "display_capped"),
    scs))
}


# 7. corpus_attenuation_vs_rigor.pdf
.attenuation_vs_rigor <- function(registry, outfile, stratum_colors,
                                   cap, verbose) {
  pr <- .prep_rigor_axis(registry$log10BF_rigor, cap)
  d  <- registry
  d$rig <- pr$value
  d$att <- abs(d$mu_RE) - abs(d$mu_BC)
  d <- d[is.finite(d$att) & !is.na(d$rig), , drop = FALSE]
  xr <- range(d$rig, na.rm = TRUE); yr <- range(c(d$att, 0), na.rm = TRUE)
  sub <- .wrap(paste0("attenuation_abs = |mu_RE| - |mu_BC| (positive = ",
    "RoBMA-PSMA smaller in magnitude than baseline RE).", .inf_note(pr)))

  p <- ggplot(d, aes(x = rig, y = att)) +
    geom_hline(yintercept = 0, color = "gray30", linewidth = 0.4) +
    .rigor_guide_lines(xr[1], xr[2], vertical = TRUE) +
    geom_point(aes(color = stratum_label, shape = rigor_direction),
               size = 2.3, alpha = 0.8) +
    scale_color_manual(values = stratum_colors, name = "Stratum") +
    scale_shape_manual(values = c(effect = 16, no_effect = 17),
                       na.value = 4, name = "Rigor direction") +
    labs(title = "Effect attenuation vs rigor", subtitle = sub,
         x = expression(log[10](BF[rigor])),
         y = "Attenuation (|mu_RE| - |mu_BC|)") +
    theme_minimal(base_size = 13) +
    theme(panel.grid.minor = element_blank(),
          plot.title = element_text(face = "bold", size = 13),
          plot.subtitle = element_text(size = 8.5, color = "gray45"),
          legend.position = "right",
          panel.border = element_rect(colour = "gray30", fill = NA,
                                      linewidth = 0.4),
          axis.line = element_line(colour = "gray60", linewidth = 0.3))

  ggsave(outfile, p, width = 8.5, height = 6, useDingbats = FALSE)
  if (verbose) message(sprintf("  ✓ Saved: %s", outfile))
  list(info = .rigor_info(nrow(registry), nrow(d), xr, yr, pr))
}


# 8. corpus_bias_vs_rigor.pdf
.bias_vs_rigor <- function(registry, outfile, stratum_colors, cap,
                           verbose) {
  prb <- .prep_rigor_axis(registry$log10BF_bias)            # auto cap (bias)
  prr <- .prep_rigor_axis(registry$log10BF_rigor, cap)      # rigor cap
  d <- registry
  d$bx <- prb$value
  d$ry <- prr$value
  d <- d[!is.na(d$bx) & !is.na(d$ry), , drop = FALSE]
  xr <- range(d$bx, na.rm = TRUE); yr <- range(d$ry, na.rm = TRUE)
  n_inf <- prb$n_inf + prr$n_inf
  disp  <- if (n_inf > 0L) "capped_terminal_axis" else "none"
  sub <- .wrap(paste0("Modeled bias evidence vs rigor; both raw ",
    "log10 axes.",
    if (n_inf > 0L) sprintf(paste0(" Infinite values (n=%d) shown at the ",
      "terminal axis boundary."), n_inf) else ""))

  p <- ggplot(d, aes(x = bx, y = ry)) +
    .rigor_guide_lines(xr[1], xr[2], vertical = TRUE) +
    .rigor_guide_lines(yr[1], yr[2], vertical = FALSE) +
    geom_point(aes(color = stratum_label, shape = rigor_direction),
               size = 2.3, alpha = 0.8) +
    scale_color_manual(values = stratum_colors, name = "Stratum") +
    scale_shape_manual(values = c(effect = 16, no_effect = 17),
                       na.value = 4, name = "Rigor direction") +
    labs(title = "Modeled bias evidence vs rigor",
         subtitle = sub, x = expression("Modeled bias " * log[10](BF)),
         y = expression(log[10](BF[rigor]))) +
    theme_minimal(base_size = 13) +
    theme(panel.grid.minor = element_blank(),
          plot.title = element_text(face = "bold", size = 13),
          plot.subtitle = element_text(size = 8.5, color = "gray45"),
          legend.position = "right",
          panel.border = element_rect(colour = "gray30", fill = NA,
                                      linewidth = 0.4),
          axis.line = element_line(colour = "gray60", linewidth = 0.3))

  ggsave(outfile, p, width = 8.5, height = 6, useDingbats = FALSE)
  if (verbose) message(sprintf("  ✓ Saved: %s", outfile))
  list(info = list(rows_available = nrow(registry), rows_plotted = nrow(d),
                   x_min = xr[1], x_max = xr[2],
                   y_min = yr[1], y_max = yr[2],
                   axis_override = if (isTRUE(prr$user_cap)) "rigor_cap"
                                   else "none",
                   n_outside = if (isTRUE(prr$user_cap)) prr$n_outside
                               else NA_integer_,
                   n_inf = n_inf, inf_disposition = disp))
}


# ==============================================================================
# Entry point: build_corpus_visuals()
# ==============================================================================
# Reads the canonical reporting registry from <output_dir> and writes every
# corpus-level figure to <output_dir>. No tabular outputs, no refitting.
#
# Args:
#   output_dir          - directory holding 60's outputs / receiving figures
#   strip_ylim_override - c(lo, hi) hard y-range for the strip boxplot;
#                         NULL = auto from whisker span. Defaults to the
#                         ATTENUATION_STRIP_YLIM constant (top of file).
#   horiz_xlim_override - c(lo, hi) hard x-range for the horizontal combined
#                         boxplot; NULL = auto.
#   verbose             - print per-step progress messages
#   include_rigor       - also write the Pass-2 rigor-first corpus figures
#                         (raw log10 axes). Default TRUE.
#   top_n               - top/bottom N for corpus_rigor_ranking_extremes.
#   rigor_axis_cap      - fixed terminal boundary for rigor axes
#                         (NULL = auto from finite data; Inf is always shown
#                         at the boundary, never dropped).
#   include_bias_vs_rigor - optional QC / supplement scatter
#                         (corpus_bias_vs_rigor.pdf). OFF by default: it is
#                         too mechanically tied to the rigor
#                         definition for the default descriptive suite.
#                         Only honoured when include_rigor = TRUE.
build_corpus_visuals <- function(output_dir = "output/overview",
                                  strip_ylim_override = ATTENUATION_STRIP_YLIM,
                                  horiz_xlim_override = NULL,
                                  verbose = TRUE,
                                  include_rigor = TRUE,
                                  top_n = 12,
                                  rigor_axis_cap = NULL,
                                  include_bias_vs_rigor = FALSE,
                                  ...) {

  .ensure_visual_runtime()
  vmsg <- function(...) if (verbose) message(...)

  dir_create(output_dir)
  vmsg("=== Corpus (cross-stratum) visualizations ===\n")

  registry <- .consume_reporting_registry(output_dir, verbose)
  if (nrow(registry) == 0L)
    stop("Outcome registry is empty; nothing to visualize.", call. = FALSE)

  vmsg(sprintf("Loaded %d outcomes from %d strata\n",
               nrow(registry), n_distinct(registry$stratum)))

  # Deterministic stratum colours: map display labels in stable slug order so
  # the violin / boxplot panels share one colour assignment.
  stratum_levels <- registry %>%
    distinct(stratum, stratum_label) %>%
    arrange(stratum) %>%
    pull(stratum_label)

  stratum_colors <- setNames(
    .tableau10[seq_along(stratum_levels) %% length(.tableau10) + 1],
    stratum_levels
  )

  # Corpus figures span every stratum; the scope column records that.
  diag_list <- list()
  scope_all <- "ALL_STRATA"

  # --- Orchard plots: RETIRED ------------------------------------------------
  # The cross-stratum orchards (evidence-axis transform) are retired and
  # not part of the active corpus suite. A frozen copy of the old module
  # is kept under archive/ for provenance only and is never invoked by
  # this script. The active component-evidence displays are the
  # display-capped raw-log10 violins below.

  # --- Combined horizontal attenuation boxplot -------------------------------
  vmsg("\nCreating combined baseline-vs-RoBMA-PSMA boxplot...")

  box_data <- registry %>%
    filter(is.finite(mu_RE) & is.finite(mu_BC))

  if (nrow(box_data) == 0L) {
    vmsg("  Warning: no finite (mu_RE, mu_BC) pairs; skipping boxplots.")
  } else {

    # Paired long format. Factor levels: "RoBMA-PSMA" first so position_dodge
    # puts Baseline RE on top.
    box_long <- box_data %>%
      select(stratum_label, mu_RE, mu_BC) %>%
      pivot_longer(c(mu_RE, mu_BC), names_to = "Method",
                   values_to = "Estimate") %>%
      mutate(Method = factor(
        ifelse(Method == "mu_RE", "Baseline RE", "RoBMA-PSMA"),
        levels = c("RoBMA-PSMA", "Baseline RE")))

    # Order strata alphabetically by display label (consistent with orchards).
    stratum_order_box <- sort(unique(box_data$stratum_label))

    box_long <- box_long %>%
      mutate(stratum_label = factor(stratum_label,
                                    levels = stratum_order_box))
    box_data <- box_data %>%
      mutate(stratum_label = factor(stratum_label,
                                    levels = stratum_order_box))

    set.seed(9182)
    box_data <- box_data %>% mutate(jitter = runif(n(), -0.08, 0.08))

    n_strata_box <- length(stratum_order_box)

    whisker_extremes <- box_long %>%
      group_by(stratum_label, Method) %>%
      summarize(
        q1   = quantile(Estimate, 0.25, na.rm = TRUE),
        q3   = quantile(Estimate, 0.75, na.rm = TRUE),
        iqr  = q3 - q1,
        w_lo = min(Estimate[Estimate >= q1 - 1.5 * iqr], na.rm = TRUE),
        w_hi = max(Estimate[Estimate <= q3 + 1.5 * iqr], na.rm = TRUE),
        .groups = "drop"
      )
    whisker_lo   <- min(whisker_extremes$w_lo, na.rm = TRUE)
    whisker_hi   <- max(whisker_extremes$w_hi, na.rm = TRUE)
    whisker_span <- whisker_hi - whisker_lo
    es_lim <- c(whisker_lo - 0.025 * whisker_span,
                whisker_hi + 0.025 * whisker_span)

    horiz_xlim <- if (is.null(horiz_xlim_override)) es_lim
                  else horiz_xlim_override
    strip_ylim <- if (is.null(strip_ylim_override)) es_lim
                  else strip_ylim_override

    # Numeric y positions for paired segments (must match the reversed
    # scale_y_discrete ordering below).
    stratum_nums <- setNames(seq_along(rev(stratum_order_box)),
                             rev(stratum_order_box))

    box_data_h <- box_data %>%
      mutate(
        y_orig = stratum_nums[as.character(stratum_label)] + 0.15 +
                 jitter * 0.8,
        y_bc   = stratum_nums[as.character(stratum_label)] - 0.15 +
                 jitter * 0.8
      )

    box_long <- box_long %>%
      mutate(stratum_method = interaction(stratum_label, Method,
                                          sep = "___"))

    stratum_method_colors <- box_long %>%
      distinct(stratum_label, stratum_method) %>%
      mutate(color = stratum_colors[as.character(stratum_label)]) %>%
      { setNames(.$color, .$stratum_method) }

    p_box_h <- ggplot() +
      geom_vline(xintercept = 0, linetype = "dashed",
                 color = "grey30", linewidth = 0.5) +
      geom_boxplot(
        data = box_long,
        aes(y = stratum_label, x = Estimate, fill = stratum_method,
            alpha = Method, group = stratum_method),
        width = 0.55, outlier.shape = NA,
        position = position_dodge(width = 0.7)
      ) +
      geom_segment(
        data = box_data_h,
        aes(y = y_orig, yend = y_bc, x = mu_RE, xend = mu_BC),
        color = "gray40", alpha = 0.35, linewidth = 0.3
      ) +
      geom_point(data = box_data_h, aes(y = y_orig, x = mu_RE),
                 color = "black", size = 1.2, alpha = 0.5) +
      geom_point(data = box_data_h, aes(y = y_bc, x = mu_BC),
                 color = "black", size = 1.2, alpha = 0.5) +
      scale_fill_manual(values = stratum_method_colors, guide = "none") +
      scale_alpha_manual(
        values = c("Baseline RE" = 0.75, "RoBMA-PSMA" = 0.45),
        labels = c("Baseline RE", "RoBMA-PSMA"),
        guide  = guide_legend(override.aes = list(fill = "gray50"))
      ) +
      scale_y_discrete(limits = rev(stratum_order_box)) +
      scale_x_continuous(expand = c(0, 0)) +
      coord_cartesian(xlim = horiz_xlim) +
      labs(
        title    = "Meta-analysis effect sizes — Corpus (all strata)",
        subtitle = "Baseline RE vs RoBMA-PSMA; solid = baseline RE, faded = RoBMA-PSMA",
        x = "Standardized effect size",
        y = NULL,
        alpha = NULL
      ) +
      theme_minimal(base_size = 13) +
      theme(
        plot.title    = element_text(face = "bold", size = 13),
        plot.subtitle = element_text(color = "gray40", size = 10),
        axis.text.y   = element_text(face = "bold", size = 11),
        legend.position  = "bottom",
        legend.direction = "horizontal",
        legend.text   = element_text(size = 10),
        panel.border  = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
        axis.line     = element_line(colour = "gray60", linewidth = 0.3)
      )

    box_h_height <- auto_figure_dim(n_strata_box, 1.0, 2, 5)
    box_h_path <- file.path(output_dir,
                            "corpus_effect_attenuation_boxplot_horizontal.pdf")
    save_corpus_plot(p_box_h, box_h_path, "attenuation_horiz",
                     height = box_h_height, verbose = verbose)

    has_xov <- !is.null(horiz_xlim_override)
    h_pts <- c(box_data$mu_RE, box_data$mu_BC)
    h_pts <- h_pts[is.finite(h_pts)]
    n_out_h <- if (has_xov)
      sum(h_pts < horiz_xlim[1] | h_pts > horiz_xlim[2]) else NA_integer_
    if (has_xov && !is.na(n_out_h) && n_out_h > 0L)
      warning(sprintf(paste0("Fixed x-axis override [%.3g, %.3g] clips %d ",
                             "plotted value(s) in %s"),
                      horiz_xlim[1], horiz_xlim[2], n_out_h, box_h_path),
              call. = FALSE)
    diag_list[[length(diag_list) + 1L]] <- .diag_row(
      plot_type = "effect_attenuation_boxplot_horizontal",
      output_file = box_h_path,
      scope_stratum = scope_all,
      rows_available = nrow(registry), rows_plotted = nrow(box_data),
      x_min = horiz_xlim[1], x_max = horiz_xlim[2],
      axis_override = if (has_xov) "x" else "none",
      n_outside_axis_override = n_out_h,
      n_inf = sum(is.infinite(c(box_data$mu_RE, box_data$mu_BC))),
      inf_disposition = "none")

    # --- Single-strip boxplot (descending median baseline RE) --------------
    vmsg("\nCreating strip boxplot (strata ordered by descending median baseline RE)...")

    stratum_median_es <- box_data %>%
      group_by(stratum_label) %>%
      summarize(med_es = median(mu_RE, na.rm = TRUE), .groups = "drop") %>%
      arrange(desc(med_es))

    stratum_order_desc <- as.character(stratum_median_es$stratum_label)

    box_long_desc <- box_long %>%
      mutate(
        stratum_label = factor(stratum_label, levels = stratum_order_desc),
        Method = factor(Method, levels = c("Baseline RE", "RoBMA-PSMA"))
      )

    stratum_nums_v <- setNames(seq_along(stratum_order_desc),
                               stratum_order_desc)

    # position_dodge(width = 0.7) with 2 groups offsets each +-0.175.
    box_data_v <- box_data %>%
      mutate(
        stratum_label = factor(stratum_label, levels = stratum_order_desc),
        x_orig = stratum_nums_v[as.character(stratum_label)] - 0.175 +
                 jitter * 0.8,
        x_bc   = stratum_nums_v[as.character(stratum_label)] + 0.175 +
                 jitter * 0.8
      )

    p_box_strip <- ggplot() +
      geom_hline(yintercept = 0, linetype = "dashed",
                 color = "grey30", linewidth = 0.5) +
      geom_boxplot(
        data = box_long_desc,
        aes(x = stratum_label, y = Estimate, fill = stratum_label,
            alpha = Method, group = interaction(stratum_label, Method)),
        width = 0.6, outlier.shape = NA,
        position = position_dodge(width = 0.7)
      ) +
      geom_segment(
        data = box_data_v,
        aes(x = x_orig, xend = x_bc, y = mu_RE, yend = mu_BC),
        color = "gray40", alpha = 0.35, linewidth = 0.3
      ) +
      geom_point(data = box_data_v, aes(x = x_orig, y = mu_RE),
                 color = "black", size = 1.2, alpha = 0.5) +
      geom_point(data = box_data_v, aes(x = x_bc, y = mu_BC),
                 color = "black", size = 1.2, alpha = 0.5) +
      scale_fill_manual(values = stratum_colors, guide = "none") +
      scale_alpha_manual(
        values = c("Baseline RE" = 0.75, "RoBMA-PSMA" = 0.40),
        labels = c("Baseline RE", "RoBMA-PSMA"),
        guide  = guide_legend(override.aes = list(fill = "gray50"))
      ) +
      scale_y_continuous(expand = c(0, 0)) +
      coord_cartesian(ylim = strip_ylim) +
      labs(
        title    = "Meta-analysis effect sizes — Corpus (all strata)",
        subtitle = "Strata ordered by descending median baseline RE estimate; solid = baseline RE, faded = RoBMA-PSMA",
        y = "Standardized effect size",
        x = NULL,
        alpha = NULL
      ) +
      theme_minimal(base_size = 13) +
      theme(
        plot.title       = element_text(face = "bold", size = 13),
        plot.subtitle    = element_text(color = "gray40", size = 10),
        axis.text.x      = element_text(face = "bold", size = 10,
                                        angle = 45, hjust = 1, vjust = 1),
        legend.position  = "bottom",
        legend.direction = "horizontal",
        legend.text      = element_text(size = 10),
        panel.border     = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
        axis.line        = element_line(colour = "gray60", linewidth = 0.3)
      )

    strip_w <- auto_figure_dim(n_strata_box, 0.9, 1.5, 6)
    strip_h <- strip_w                       # keep the strip square
    box_strip_path <- file.path(output_dir,
                                "corpus_effect_attenuation_strip.pdf")
    save_corpus_plot(p_box_strip, box_strip_path, "attenuation_strip",
                     width = strip_w, height = strip_h, verbose = verbose)

    has_yov <- !is.null(strip_ylim_override)
    s_pts <- c(box_data$mu_RE, box_data$mu_BC)
    s_pts <- s_pts[is.finite(s_pts)]
    n_out_s <- if (has_yov)
      sum(s_pts < strip_ylim[1] | s_pts > strip_ylim[2]) else NA_integer_
    if (has_yov && !is.na(n_out_s) && n_out_s > 0L)
      warning(sprintf(paste0("Fixed y-axis override [%.3g, %.3g] clips %d ",
                             "plotted value(s) in %s"),
                      strip_ylim[1], strip_ylim[2], n_out_s, box_strip_path),
              call. = FALSE)
    diag_list[[length(diag_list) + 1L]] <- .diag_row(
      plot_type = "effect_attenuation_strip", output_file = box_strip_path,
      scope_stratum = scope_all,
      rows_available = nrow(registry), rows_plotted = nrow(box_data),
      y_min = strip_ylim[1], y_max = strip_ylim[2],
      axis_override = if (has_yov) "y" else "none",
      n_outside_axis_override = n_out_s,
      n_inf = sum(is.infinite(c(box_data$mu_RE, box_data$mu_BC))),
      inf_disposition = "none")
  }

  # --- Violin hybrid plots ---------------------------------------------------
  vmsg("\nCreating cross-stratum violin hybrid plots...")

  violin_long    <- .compute_stratum_bf_long(registry)
  violin_summary <- .compute_stratum_bf_summary(violin_long)

  # Diagnostics row from a violin-family $info (display-cap accounting).
  vdiag <- function(plot_type, panel, file, info) {
    nnf <- (info$pos_inf_n %||% 0L) + (info$neg_inf_n %||% 0L)
    .diag_row(
      plot_type = plot_type, panel = panel, output_file = file,
      scope_stratum = scope_all,
      rows_available = info$rows_available, rows_plotted = info$rows_plotted,
      x_min = info$x_min, x_max = info$x_max,
      axis_override = "none",
      n_inf = nnf,
      inf_disposition = if (nnf == 0L) "none" else "display_capped",
      finite_n = info$finite_n, pos_inf_n = info$pos_inf_n,
      neg_inf_n = info$neg_inf_n, missing_n = info$missing_n,
      finite_min = info$finite_min, finite_max = info$finite_max,
      capped_low_n = info$capped_low_n,
      capped_high_n = info$capped_high_n,
      display_min = info$display_min, display_max = info$display_max,
      display_cap = info$display_cap)
  }

  violin_specs <- list(
    list(comp = "effect",        col = "log10BF_effect",
         title = "Distribution of effect evidence across strata",
         file  = "corpus_component_violin_effect.pdf"),
    list(comp = "heterogeneity", col = "log10BF_het",
         title = "Distribution of heterogeneity evidence across strata",
         file  = "corpus_component_violin_heterogeneity.pdf"),
    list(comp = "bias",          col = "log10BF_bias",
         title = "Distribution of modeled bias evidence across strata",
         file  = "corpus_component_violin_bias.pdf"))
  for (sp in violin_specs) {
    vf <- file.path(output_dir, sp$file)
    vp <- .stratum_violin_plot(violin_long, violin_summary, sp$comp,
                               sp$title, vf,
                               stratum_colors = stratum_colors,
                               verbose = verbose)
    diag_list[[length(diag_list) + 1L]] <-
      vdiag("component_violin", sp$comp, vf, vp$info)
  }

  # --- Section-5 evidence triptych (rigor | effect | modeled bias) -----------
  # Selected rigor | Effect evidence | Modeled bias laid out LEFT-TO-RIGHT so
  # the same stratum row lines up across panels and the stratum labels are
  # written once (leftmost panel only). All three share ONE stratum order (the
  # corpus slug order, `stratum_levels`) so rows align; each panel keeps its own
  # display-capped x axis (cap tick ≤ -2 / ≥ 2).
  #
  # Panel A is selected rigor (log10BF_rigor), the JOINT model-family Bayes
  # factor for the better-supported clean (no-explicit-bias) effect-or-no-effect
  # branch -- NOT a marginal component BF. It uses the same violin grammar but a
  # rigor-specific axis label (log10 BF^R). Heterogeneity is deliberately not a
  # panel here; it remains in Table 1 / the standalone component violins and the
  # supplement. The standalone corpus_component_violin_heterogeneity.pdf and the
  # per-stratum component stacks are unchanged.
  vmsg("\nCreating Section-5 evidence triptych (rigor | effect | bias)...")

  # Typography bumped (2026-05 polish) to match the Section-4 simulation
  # visuals (.cv_theme base_size = 14, title = base+1, axis text ~10). The
  # figure is also saved narrower (FIGURE_SIZES$violin_stack width = 9.5) so it
  # is downscaled less when embedded at \linewidth; together these raise the
  # apparent on-page text size to the Section-4 standard.
  compact_style <- list(
    point_size        = 1.6,
    point_alpha       = 0.85,
    violin_alpha      = 0.42,
    iqr_linewidth     = 1.8,
    iqr_alpha         = 0.55,
    whisker_linewidth = 0.6,
    whisker_alpha     = 0.7,
    median_size_outer = 2.8,
    median_size_inner = 1.7,
    y_text_size       = 13,
    axis_text_size    = 11,
    title_size        = 15,
    plot_margin       = margin(8, 8, 6, 8)
  )

  p_panel_rigor <- .stratum_violin_plot(
    violin_long, violin_summary, "rigor",
    title = "A. Selected rigor", outfile = NULL, save = FALSE,
    stratum_colors = stratum_colors, stratum_order = stratum_levels,
    show_x_axis = TRUE, show_x_title = TRUE, show_y_axis = TRUE,
    x_lab = expression(log[10](BF^R)), base_size = 14,
    subtitle = NULL, style = compact_style, verbose = verbose
  )
  p_panel_eff <- .stratum_violin_plot(
    violin_long, violin_summary, "effect",
    title = "B. Effect evidence", outfile = NULL, save = FALSE,
    stratum_colors = stratum_colors, stratum_order = stratum_levels,
    show_x_axis = TRUE, show_x_title = TRUE, show_y_axis = FALSE,
    base_size = 14,
    subtitle = NULL, style = compact_style, verbose = verbose
  )
  p_panel_bias <- .stratum_violin_plot(
    violin_long, violin_summary, "bias",
    title = "C. Modeled bias evidence", outfile = NULL, save = FALSE,
    stratum_colors = stratum_colors, stratum_order = stratum_levels,
    show_x_axis = TRUE, show_x_title = TRUE, show_y_axis = FALSE,
    base_size = 14,
    subtitle = NULL, style = compact_style, verbose = verbose
  )

  # Leftmost panel a touch wider so its stratum labels do not steal plotting
  # width from its violins.
  violin_stack <- (p_panel_rigor$plot | p_panel_eff$plot |
                   p_panel_bias$plot) +
    plot_layout(widths = c(1.30, 1, 1)) +
    plot_annotation(
      # Keep only the display-cap convention here (the rigor-vs-component
      # explanation lives in the LaTeX caption); avoids a cluttered footer.
      caption = paste0("Raw log10(BF) axes, display-capped at +/-2; values ",
                        "beyond the cap (incl. +/-Inf) are plotted at the cap."),
      theme = theme(plot.caption = element_text(hjust = 0.5, size = 10,
                                                color = "gray40")))

  stack_pdf <- file.path(output_dir, "corpus_component_violin_stack.pdf")
  stack_h   <- auto_figure_dim(length(stratum_levels), 0.55, 2.8, 5)
  save_corpus_plot(violin_stack, stack_pdf, "violin_stack",
                   height = stack_h, verbose = verbose)

  for (sp in list(list("rigor",  p_panel_rigor),
                  list("effect", p_panel_eff),
                  list("bias",   p_panel_bias))) {
    diag_list[[length(diag_list) + 1L]] <-
      vdiag("component_violin_stack", sp[[1]], stack_pdf, sp[[2]]$info)
  }

  # --- Rigor-first corpus figures (Pass 2) -----------------------------------
  if (isTRUE(include_rigor)) {
    vmsg("\nCreating rigor-first corpus figures (raw log10 axes)...")

    # Shared rigor terminal boundary + stratum order so every rigor
    # figure agrees on where Inf sits and how strata are ranked.
    cap_rigor    <- .prep_rigor_axis(registry$log10BF_rigor,
                                     rigor_axis_cap)$cap
    rigor_levels <- .rigor_stratum_order(registry, cap_rigor)

    add_rigor_diag <- function(plot_type, path, info) {
      force(info)   # run the helper (incl. ggsave) BEFORE the file checks
      diag_list[[length(diag_list) + 1L]] <<- .diag_row(
        plot_type = plot_type, output_file = path,
        scope_stratum = scope_all,
        rows_available = info$rows_available,
        rows_plotted = info$rows_plotted,
        x_min = info$x_min, x_max = info$x_max,
        y_min = info$y_min, y_max = info$y_max,
        axis_override = info$axis_override,
        n_outside_axis_override = info$n_outside,
        n_inf = info$n_inf, inf_disposition = info$inf_disposition,
        # Violin-family display-cap accounting (NA for the other rigor
        # figures, whose $info does not carry these fields).
        finite_n  = info$finite_n  %||% NA_integer_,
        pos_inf_n = info$pos_inf_n %||% NA_integer_,
        neg_inf_n = info$neg_inf_n %||% NA_integer_,
        missing_n = info$missing_n %||% NA_integer_,
        finite_min = info$finite_min %||% NA_real_,
        finite_max = info$finite_max %||% NA_real_,
        capped_low_n  = info$capped_low_n  %||% NA_integer_,
        capped_high_n = info$capped_high_n %||% NA_integer_,
        display_min = info$display_min %||% NA_real_,
        display_max = info$display_max %||% NA_real_,
        display_cap = info$display_cap %||% NA_real_)
    }

    f <- file.path(output_dir, "corpus_rigor_violin_by_stratum.pdf")
    add_rigor_diag("rigor_violin_by_stratum", f,
      .rigor_violin_by_stratum(registry, f, stratum_colors, rigor_levels,
                               rigor_axis_cap, verbose)$info)

    f <- file.path(output_dir, "corpus_rigor_branch_scatter.pdf")
    add_rigor_diag("rigor_branch_scatter", f,
      .rigor_branch_scatter(registry, f, rigor_axis_cap, verbose)$info)

    f <- file.path(output_dir, "corpus_rigor_direction_composition.pdf")
    add_rigor_diag("rigor_direction_composition", f,
      .rigor_direction_composition(registry, output_dir, f,
                                   rigor_levels, verbose)$info)

    f <- file.path(output_dir, "corpus_rigor_category_composition.pdf")
    add_rigor_diag("rigor_category_composition", f,
      .rigor_category_composition(registry, output_dir, f,
                                  rigor_levels, verbose)$info)

    f <- file.path(output_dir, "corpus_rigor_weighting_comparison.pdf")
    add_rigor_diag("rigor_weighting_comparison", f,
      .rigor_weighting_comparison(output_dir, f, rigor_axis_cap,
                                  rigor_levels, verbose)$info)

    f <- file.path(output_dir, "corpus_rigor_ranking_extremes.pdf")
    add_rigor_diag("rigor_ranking_extremes", f,
      .rigor_top_bottom_outcomes(output_dir, registry, f, top_n,
                                 rigor_axis_cap, verbose)$info)

    f <- file.path(output_dir, "corpus_attenuation_vs_rigor.pdf")
    add_rigor_diag("attenuation_vs_rigor", f,
      .attenuation_vs_rigor(registry, f, stratum_colors, rigor_axis_cap,
                            verbose)$info)

    # Optional QC / supplement scatter: too mechanically tied to the
    # rigor definition to be a default descriptive figure. Off
    # unless include_bias_vs_rigor = TRUE; when off it is neither written
    # nor added to diagnostics (stale on-disk copies are left untouched).
    if (isTRUE(include_bias_vs_rigor)) {
      f <- file.path(output_dir, "corpus_bias_vs_rigor.pdf")
      add_rigor_diag("bias_vs_rigor", f,
        .bias_vs_rigor(registry, f, stratum_colors, rigor_axis_cap,
                       verbose)$info)
    } else {
      vmsg("  (corpus_bias_vs_rigor: optional QC plot, off by default; ",
           "set include_bias_vs_rigor = TRUE to generate it.)")
    }
  } else {
    vmsg("\n(include_rigor = FALSE: skipping the Pass-2 rigor-first figures.)")
  }

  # --- Final summary ---------------------------------------------------------
  vmsg("\n=== Corpus visualizations complete ===")
  vmsg(sprintf("Total outcomes visualized: %d", nrow(registry)))
  vmsg(sprintf("Strata included: %d", n_distinct(registry$stratum)))
  vmsg(sprintf("\nAll figures saved to: %s/", output_dir))
  vmsg("(Tabular summaries are owned by 60_estimand_tables.R; this script ",
       "writes figures only.)")

  diagnostics <- tibble::as_tibble(dplyr::bind_rows(diag_list))
  vmsg(sprintf("Diagnostics: %d plot record(s) (invisible $diagnostics; ",
               nrow(diagnostics)),
       "no CSV written)")

  invisible(list(
    output_dir = output_dir,
    n_outcomes = nrow(registry),
    n_strata   = n_distinct(registry$stratum),
    diagnostics = diagnostics
  ))
}


# ==============================================================================
# Deprecated alias: build_cross_topic_visuals()
# ==============================================================================
# Pre-v4 callers used build_cross_topic_visuals() (topic vocabulary, optional
# per-topic sidecar rediscovery). It now forwards to build_corpus_visuals(),
# which consumes 60's outcome_registry.csv only.
build_cross_topic_visuals <- function(output_dir = "output/overview", ...) {
  .Deprecated("build_corpus_visuals",
              msg = paste("build_cross_topic_visuals() is deprecated; use",
                          "build_corpus_visuals()."))
  build_corpus_visuals(output_dir = output_dir, ...)
}


# ==============================================================================
# Deprecated wrapper: build_overview()
# ==============================================================================
# Pre-refactor build_overview() owned both tables and figures. The v4
# architecture splits those: 60_estimand_tables.R OWNS every tabular output;
# 70_corpus_visuals.R OWNS the corpus figures. This wrapper runs
# build_estimand_tables() then build_corpus_visuals() for backward
# compatibility, but is deprecated - call the two stages explicitly.
# build_estimand_tables() must be available (source 60_estimand_tables.R).
build_overview <- function(output_dir = "output/overview",
                           strip_ylim_override = ATTENUATION_STRIP_YLIM,
                           horiz_xlim_override = NULL,
                           verbose = TRUE) {

  .Deprecated("build_estimand_tables(); build_corpus_visuals()",
              old = "build_overview")

  if (!exists("build_estimand_tables")) {
    stop(paste(
      "build_estimand_tables() is not available; source",
      "scripts/60_estimand_tables.R first (60 owns the tables, 70 the",
      "figures)."), call. = FALSE)
  }

  tables <- build_estimand_tables(output_dir = output_dir, verbose = verbose)
  figs   <- build_corpus_visuals(
    output_dir          = output_dir,
    strip_ylim_override = strip_ylim_override,
    horiz_xlim_override = horiz_xlim_override,
    verbose             = verbose
  )

  invisible(list(
    output_dir              = output_dir,
    outcome_registry        = tables$outcome_registry,
    stratum_estimands       = tables$stratum_estimands,
    article_balanced_estimands = tables$article_balanced_estimands,
    corpus_estimands        = tables$corpus_estimands,
    figures                 = figs
  ))
}


# Sentinel for symmetry with the rest of the pipeline.
.corpus_visuals_loaded <- TRUE
