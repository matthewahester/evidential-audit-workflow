# 75_analysis_visuals.R - Visual layer for the analysis questions
# (Q1 known-cell behavior, Q2 empirical resampling stability,
# Q3 empirical-weighted synthetic sampling) plus profile-definition
# diagnostics.
#
# Renamed from 75_composition_visuals.R in the 2026-05 Q3 terminology
# pass: 75 has long covered Q1 + Q2 + Q3, so "composition_visuals"
# was misleading and the Q3 section is now named "empirical-weighted
# synthetic sampling" everywhere it is public-facing. Internal
# function-level mechanics that use "composition" as a technical noun
# (e.g. `sim_validate_composition_inputs()`, the `composition_id` row
# column) are retained where churn outweighs clarity.
#
# Define-only on source. Sourcing installs functions and constants and
# nothing else: no plotting, no CSV read, no CSV write, no figure
# write, no namespace attach, no RoBMA, no batch_fit(). ggplot2 is
# required lazily (call time only).
#
# Scope:
#   Reads the stable CSVs written upstream (55 cell diagnostics, 60
#   empirical resampling, 65 empirical-weighted synthetic sampling +
#   Q1/Q3 size curves, 70 empirical-vs-synthetic agreement), builds
#   vector PDF figures organized by question, and writes per-question
#   reports. Does NOT recompute anything and does NOT regenerate
#   missing analysis inputs; if an input CSV is missing the
#   corresponding figure is simply skipped. To rebuild inputs, run the
#   appropriate upstream script (see the run-order block below).
#
# Stable input layout (all produced upstream, never by 75):
#   simulation/results/                              (cell_diagnostics_*.csv, written by 55)
#   simulation/results/cell_behavior/
#     cell_behavior_effect_draws.csv                 (written by 55)
#     synthetic_cell_size_curve_summary.csv          (written by 65)
#     synthetic_cell_size_curve_draws.csv            (written by 65)
#   simulation/results/empirical_resampling/         (Q2 resampling, written by 60)
#   simulation/results/empirical_weighted_synthetic/
#     empirical_cell_assignments.csv                 (written by 65)
#     empirical_stratum_cell_weights.csv             (written by 65)
#     empirical_stratum_coherence.csv                (written by 65)
#     empirical_weighted_synthetic_size_curve_summary.csv (written by 65)
#     empirical_weighted_synthetic_size_curve_draws.csv   (written by 65)
#     ...and detail/ profile-definition diagnostics  (written by 65)
#   simulation/results/agreement/                    (Q3 agreement CSVs, written by 70)
#
# Stable output layout (no replicate-count, run-tier, or pass-era
# names; the library size used to produce the inputs is auditable in
# the input CSVs / upstream reports, never in the figure filenames).
# 75 writes figures + per-question reports, plus a small number of
# derived visualization tables (e.g. the Q1 viability table) that are
# computed from the upstream summary CSVs:
#
#   simulation/results/cell_behavior/
#     synthetic_cell_rigor_viability_min_n.csv             (DERIVED by 75)
#   simulation/results/figures/cell_behavior/              (Q1 figures)
#   simulation/results/figures/empirical_resampling/       (Q2 figures)
#   simulation/results/figures/empirical_weighted_synthetic/ (Q3 figures)
#
# Each folder gets its own report + deferred ledger.
#
# Style follows docs/visuals.md + scripts/70_corpus_visuals.R: vector
# PDFs, theme_minimal family, gray panel border, Inf shown at a
# terminal axis boundary and reported (never silently dropped).
#
# Color contract:
#   The simulation visual layer uses `.VIS_COLORS` from the base
#   pipeline utilities (`scripts/00_utils.R`). In normal runs, source
#   `scripts/00_utils.R` before this script:
#
#     source("scripts/00_utils.R")
#     source("simulation/scripts/75_analysis_visuals.R")
#
#   If `.VIS_COLORS` is missing, this script sentinel-sources
#   `scripts/00_utils.R` define-only at the top of the file. A handful
#   of module-level color constants (.CV_HEAT_LOW, .CV_HEAT_HIGH,
#   .CV_OK, .CV_FAIL, .CV_STATUS_COLORS) carry hex fallbacks so the
#   constants always exist; every plot function that touches richer
#   slices of `.VIS_COLORS` (e.g. $bias_burden, $method, $support)
#   calls `.cv_need_colors()` at the top, which fails with a clear
#   message if the sentinel could not find `scripts/00_utils.R`.
#
# Public workflow: use sim_run_all_analysis_visuals() by default; it
# runs the Q1, Q2, and Q3 wrappers in one call. The per-question
# wrappers (sim_run_cell_behavior_visuals(),
# sim_run_empirical_resampling_visuals(), sim_run_q3_visuals())
# remain public for targeted use.
#
# Public entry points (none run on source):
#   cv_cell_levels()
#   cv_read_inputs()
#   cv_plot_weight_heatmap()        cv_plot_axis_transition()
#
#   Q1 (cell behavior) -- 4 primary + 3 secondary. Central-trend +
#   convergence-error figures retired earlier in 2026-05; the rate-
#   variability companion and the per-cell operating-characteristics
#   atlas were retired later in 2026-05 (the secondary slot is now
#   the bias-evidence + attenuation component-variability pair):
#     cv_plot_cell_rigor_atlas()                       - primary
#     cv_plot_cell_attenuation_atlas()                 - primary
#     cv_plot_cell_rigor_variability_by_effect()       - primary
#     cv_write_cell_rigor_viability_table()            - derived table for min-n
#     cv_plot_cell_rigor_viability_min_n()             - primary
#     cv_plot_cell_rigor_width_heatmap_by_n()          - secondary
#     cv_plot_cell_bias_evidence_variability_by_effect() - secondary
#     cv_plot_cell_attenuation_variability_by_effect()   - secondary
#     sim_run_cell_behavior_visuals()                  - Q1 wrapper
#
#   Q2 (empirical resampling) -- 3 default figures focused on stability
#   and core audit metrics. The earlier primary-rigor (p_*) family
#   (rigor size curves, primary-rigor heatmap, primary-rigor intervals,
#   plus their corpus twins) was retired in 2026-05; stale PDFs are
#   scrubbed from the figure folder on every run:
#     cv_plot_empirical_resampling_rigor_variability_by_stratum() - Q2 primary
#     cv_plot_empirical_resampling_core_uncertainty_heatmap()     - Q2 primary
#     cv_plot_empirical_resampling_core_intervals()               - Q2 primary
#     sim_run_empirical_resampling_visuals()                      - Q2 wrapper
#
#   Q3 (empirical-weighted synthetic sampling) -- 3 primary/bridge +
#   3 profile-definition diagnostics. The earlier mean/median-level
#   composition size curves, the primary-rigor (p_*) overlay, the
#   stratum/corpus agreement figures, the 36x36 cell transition map,
#   the stratum target-provenance map, the support bars, and the
#   validation-status bar were retired in 2026-05; their stale PDFs
#   are scrubbed from both the new figures/empirical_weighted_synthetic/
#   folder and the legacy figures/composition/ folder on every run:
#     cv_plot_weight_heatmap()                                       - Q3 input map
#     cv_plot_empirical_weighted_rigor_variability_by_stratum()      - Q3 primary
#     cv_plot_emp_bootstrap_vs_empirical_weighted_core_metrics()     - Q3 bridge primary
#     cv_plot_axis_transition()                                      - profile-definition
#                                                                      diagnostic (effect,
#                                                                      heterogeneity, bias)
#     sim_run_q3_visuals()                                           - Q3 wrapper
#
#   sim_run_all_analysis_visuals()    - operator default: runs the
#                                       Q1/Q2/Q3 wrappers in one call


# --- canonical directory defaults ---------------------------------------
# Q3 folders were renamed in 2026-05:
#   synthetic_composition/     -> empirical_weighted_synthetic/
#   figures/composition/       -> figures/empirical_weighted_synthetic/
# The .CV_EWS_* names below are the active path constants; .CV_COMP_*
# are NOT retained as aliases -- callers should use the new names.
# The legacy figures/composition/ folder is scrubbed of retired PDFs
# at the top of sim_run_q3_visuals() so a stale folder cannot drift
# forward.
.CV_RESULTS_DIR           <- "simulation/results"
.CV_CELL_BEHAVIOR_DIR     <- "simulation/results/cell_behavior"
.CV_EMP_RESAMPLING_DIR    <- "simulation/results/empirical_resampling"
.CV_EWS_DIR               <- "simulation/results/empirical_weighted_synthetic"
.CV_EWS_DETAIL_DIR        <- "simulation/results/empirical_weighted_synthetic/detail"
.CV_AGREE_DIR             <- "simulation/results/agreement"

# Legacy Q3 folder (cleanup target only; never written to as default).
.CV_LEGACY_FIG_COMP_DIR   <- "simulation/results/figures/composition"

# Figure directories: one per question.
.CV_FIG_CELL_BEHAVIOR_DIR  <- "simulation/results/figures/cell_behavior"
.CV_FIG_EMP_RESAMPLING_DIR <- "simulation/results/figures/empirical_resampling"
.CV_FIG_EWS_DIR            <- "simulation/results/figures/empirical_weighted_synthetic"

# Primary-rigor metric ordering, mirrored from the composition layer so
# Q1/Q2/Q3 visuals never drift from the upstream definitions.
.CV_PRIMARY_RIGOR_METRICS <- c(
  "median_log10BF_rigor", "p_rigor_direction_effect",
  "p_clean_effect_supported", "p_clean_no_effect_supported",
  "p_clean_evidence_disfavored", "p_inconclusive_clean_evidence",
  "median_rigor_margin")

# Single source of truth for human-readable facet / strip / axis labels.
# CSV columns stay raw; only figure display text changes. The rate-of-
# selected-branch labels ("Selected branch = ...") describe stored
# branch-label metadata, not a standalone evidential conclusion; the
# headline evidential estimand is median_log10BF_rigor (selected log
# rigor BF). Branch labels are useful descriptors, but when
# log10BF_rigor <= 0 the better-supported clean resolved branch lost
# support relative to its complement, so a branch label alone should
# not be read as evidence either way.
.CV_METRIC_LABELS <- c(
  median_log10BF_rigor          = "Rigor evidence",
  p_rigor_direction_effect      = "Selected branch = effect",
  p_rigor_direction_no_effect   = "Selected branch = no_effect",
  p_clean_effect_supported      = "Clean effect support",
  p_clean_no_effect_supported   = "Clean no-effect support",
  p_clean_evidence_disfavored   = "Clean resolved evidence disfavored",
  p_inconclusive_clean_evidence = "Inconclusive clean evidence",
  median_rigor_margin           = "Rigor margin",
  median_mu_RE                  = "Baseline effect",
  median_mu_BC                  = "Bias-corrected effect",
  median_tau_RE                 = "Baseline heterogeneity",
  median_tau_BC                 = "Bias-corrected heterogeneity",
  median_log10BF_effect         = "Effect evidence",
  median_log10BF_het            = "Heterogeneity evidence",
  median_log10BF_bias           = "Bias evidence",
  median_attenuation_abs        = "Absolute attenuation",
  p_bias_moderate               = "Moderate+ bias evidence",
  p_het_moderate                = "Moderate+ heterogeneity evidence",
  p_effect_moderate             = "Moderate+ effect evidence")

# Display label for one or more raw metric names. Falls back to the raw
# name when no entry exists in .CV_METRIC_LABELS.
.cv_metric_label <- function(x) {
  s <- as.character(x)
  out <- unname(.CV_METRIC_LABELS[s])
  na <- is.na(out)
  out[na] <- s[na]
  out
}

# Build a factor whose internal levels are raw metric names (matching
# the metric column in the CSV) but whose display labels are the
# human-readable map. Preserves the ordering specified by `levels`.
.cv_metric_factor <- function(metric, levels) {
  lev <- as.character(levels)
  factor(as.character(metric),
         levels = lev,
         labels = .cv_metric_label(lev))
}

# Classify a metric name as "rate" (proportions, naming convention p_*)
# or "continuous" (medians of effects / BFs / margins). The size-curve
# summary stores synthetic_median and synthetic_mean for every metric;
# the right summary statistic depends on the metric class. For p_*
# rates the per-cell value being summarized is itself a discrete k/n
# proportion, so synthetic_median jumps in 1/n steps (a denominator
# artifact, not signal) -- synthetic_mean is the smooth Monte-Carlo
# estimator of the true rate. For continuous metrics the median is the
# robust summary we want.
.cv_metric_class <- function(metric) {
  ifelse(grepl("^p_", as.character(metric)), "rate", "continuous")
}

# Add `plot_value` + `plot_stat` columns picking the right summary
# column per metric class. Use this before plotting any size-curve
# panel that mixes (or could mix) rate and continuous metrics.
.cv_add_plot_value <- function(d) {
  m <- as.character(d$metric)
  is_rate <- grepl("^p_", m)
  mean_v   <- suppressWarnings(as.numeric(d$synthetic_mean))
  median_v <- suppressWarnings(as.numeric(d$synthetic_median))
  d$plot_value <- ifelse(is_rate, mean_v, median_v)
  d$plot_stat  <- ifelse(is_rate, "synthetic_mean", "synthetic_median")
  d
}

# Add sampling-variability widths (90% and 95%) computed from the
# already-summarized quantile columns. width90 = q95 - q05 is the
# canonical Q1 stability axis: width of the stratum-level summary's
# sampling distribution across B synthetic resamples. NOT a posterior
# uncertainty interval and NOT a Monte-Carlo standard error.
.cv_width_cols <- function(d) {
  for (cl in c("q05", "q95", "q025", "q975"))
    d[[cl]] <- suppressWarnings(as.numeric(d[[cl]]))
  d$width90      <- d$q95 - d$q05
  d$half_width90 <- d$width90 / 2
  d$width95      <- d$q975 - d$q025
  d
}

# Attach the (effect_slug, heterogeneity_slug, bias_slug) factors
# parsed from cell_slug, ordered by the canonical .CV_EFFECT / .CV_HET
# / .CV_BIAS levels.
.cv_cell_design_cols <- function(d) {
  sp <- .cv_split_slug(d$cell_slug)
  d$effect_slug        <- factor(sp$effect_slug, levels = .CV_EFFECT)
  d$heterogeneity_slug <- factor(sp$heterogeneity_slug, levels = .CV_HET)
  d$het_slug           <- d$heterogeneity_slug
  d$bias_slug          <- factor(sp$bias_slug, levels = .CV_BIAS)
  d
}

# Compact dev/partial sanity note for a Q1 cell-behavior input frame.
# Returns "" when nothing notable; otherwise a single bracketed string
# suitable for direct concatenation into a figure caption or report
# note. Triggers when dev_partial = TRUE on any row, when n_pool is
# materially smaller than max(n_outcomes_target), when n_pool < 50,
# when n_pool collapses to a common minimum across cells (a likely
# upstream registry-balance artifact), or when n_pool varies widely.
.cv_cell_behavior_warning <- function(d) {
  if (!is.data.frame(d) || !nrow(d)) return("")
  dp <- if ("dev_partial" %in% names(d))
    any(d$dev_partial %in% c(TRUE, "TRUE"), na.rm = TRUE) else FALSE
  np <- if ("n_pool" %in% names(d))
    suppressWarnings(as.integer(d$n_pool)) else integer(0)
  np <- np[is.finite(np) & np > 0L]
  nt <- if ("n_outcomes_target" %in% names(d))
    suppressWarnings(as.integer(d$n_outcomes_target)) else integer(0)
  nt <- nt[is.finite(nt) & nt > 0L]
  pool_min <- if (length(np)) min(np) else NA_integer_
  pool_max <- if (length(np)) max(np) else NA_integer_
  n_max_t  <- if (length(nt)) max(nt) else NA_integer_
  bits <- character(0)
  if (isTRUE(dp))
    bits <- c(bits, "dev_partial = TRUE on at least one input row")
  if (is.finite(pool_min) && is.finite(n_max_t) && pool_min < n_max_t)
    bits <- c(bits, sprintf(
      "n_pool = %s vs n_outcomes_target up to %d",
      if (pool_min == pool_max) as.character(pool_min)
      else sprintf("%d-%d", pool_min, pool_max),
      n_max_t))
  else if (is.finite(pool_min) && pool_min < 50L)
    bits <- c(bits, sprintf("n_pool = %s (small)",
      if (pool_min == pool_max) as.character(pool_min)
      else sprintf("%d-%d", pool_min, pool_max)))
  if (is.finite(pool_min) && is.finite(pool_max) &&
      pool_min == pool_max && pool_min <= 25L)
    bits <- c(bits, sprintf(
      "n_pool collapses to a common minimum (%d per cell); ",
      pool_min),
      "if cell_diagnostics_rigor.csv reports larger n_fit, the ",
      "upstream registry build is not propagating the larger ",
      "fitted library into output_sim_v30/overview/",
      "outcome_registry.csv consumed by 65_synthetic_resampling.")
  if (!length(bits)) return("")
  paste0("**DEV/PARTIAL**: ",
         paste(bits[1:min(length(bits), 2L)], collapse = "; "),
         if (length(bits) > 2L) paste0("; ",
           paste(bits[3:length(bits)], collapse = "")) else "",
         ".")
}

# v4 band orders (effect x heterogeneity x bias). Shared factor-level
# order so the composition diagonal is contiguous and readable.
.CV_EFFECT <- c("null", "small", "moderate", "large")
.CV_HET    <- c("lowhet", "midhet", "highhet")
.CV_BIAS   <- c("clean", "modbias", "highbias")

# --- visual-readability constants (2026-05 polish pass) ------------------
# Centralized so manuscript readability can be tuned in one place. The
# pre-polish defaults were base_size = 12 with hardcoded geom_text sizes
# of 2.8-3.4 and axis.text.x sizes of 7-8 in several plotters, which
# rendered too small once the PDFs were embedded in the manuscript.
.CV_THEME_BASE_SIZE     <- 14    # global theme base font size
.CV_HEATMAP_LABEL_SIZE  <- 3.8   # geom_text size on heatmap tiles
.CV_AXIS_TEXT_SMALL     <- 10    # rotated axis-text overrides (stratum / cell)

# Sentinel-source the base pipeline utilities if `.VIS_COLORS` is
# missing. Define-only: scripts/00_utils.R installs functions +
# constants and reads/writes nothing. Searched along the same relative
# paths the other sentinels use (in-repo, sibling, fallback). Failing
# to find the file is not a hard error here -- the module-level color
# constants below carry hex fallbacks so the constants always exist
# -- but richer slices of `.VIS_COLORS` (bias_burden, method, support,
# resampling_source, heat$diverging_*) are needed by individual
# plotters and are guarded inside `.cv_need_colors()` below.
if (!exists(".VIS_COLORS", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R",
               file.path("..", "scripts", "00_utils.R"),
               "00_utils.R")) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}

# Hard guard for plotters that depend on slices of `.VIS_COLORS`
# beyond the .CV_* module constants below. Call at the top of any plot
# function that does `.VIS_COLORS$<something>[[...]]` without a
# fallback.
.cv_need_colors <- function() {
  if (!exists(".VIS_COLORS", inherits = TRUE))
    stop("75_analysis_visuals: `.VIS_COLORS` not found. Source ",
         "scripts/00_utils.R before this script:\n",
         "  source(\"scripts/00_utils.R\")\n",
         "  source(\"simulation/scripts/75_analysis_visuals.R\")")
  invisible(TRUE)
}

# Continuous heat fill + categorical accents (color-blind-safe).
# Visual constants. All colors flow from scripts/00_utils.R::.VIS_COLORS
# (single source of truth; see docs/visual_color_contract.md). The
# .CV_* names below are stable so callers throughout this file are
# unaffected; only the underlying hex values change.
.CV_HEAT_LOW  <- if (exists(".VIS_COLORS", inherits = TRUE))
  .VIS_COLORS$heat$sequential_low else "#F7F4EF"
.CV_HEAT_HIGH <- if (exists(".VIS_COLORS", inherits = TRUE))
  .VIS_COLORS$heat$sequential_high else "#1B5E63"
.CV_OK   <- if (exists(".VIS_COLORS", inherits = TRUE))
  unname(.VIS_COLORS$bootstrap_mode[["outcome"]]) else "#0072B2"
.CV_FAIL <- if (exists(".VIS_COLORS", inherits = TRUE))
  unname(.VIS_COLORS$diagnostic[["fail"]]) else "#B2182B"
# Diagonal / target == observed highlight: keep the same hue as the
# "fail" diagnostic so reviewer attention is consistent across figures.
.CV_DIAG <- .CV_FAIL
# Diagnostic status palette: PASS is neutral blue-gray (no green),
# INFO is marine blue, WARN is amber, FAIL is muted red. Pulled from
# .VIS_COLORS$diagnostic.
.CV_STATUS_COLORS <- if (exists(".VIS_COLORS", inherits = TRUE)) c(
  PASS = unname(.VIS_COLORS$diagnostic[["pass"]]),
  INFO = unname(.VIS_COLORS$diagnostic[["info"]]),
  WARN = unname(.VIS_COLORS$diagnostic[["warning"]]),
  FAIL = unname(.VIS_COLORS$diagnostic[["fail"]])
) else c(PASS = "#37474F", INFO = "#0277BD",
         WARN = "#F9A825", FAIL = "#B2182B")

# Conceptual input layers. Each entry: list(layer, file). The figure
# that needs an input is skipped + reported when the file is missing.
.CV_INPUTS <- list(
  weights    = list(layer = "composition",
                    file  = "empirical_stratum_cell_weights.csv"),
  cell_trans = list(layer = "composition_detail",
                    file  = "synthetic_cell_transition.csv"),
  axis_trans = list(layer = "composition_detail",
                    file  = "synthetic_axis_transition.csv"),
  provenance = list(layer = "composition_detail",
                    file  = "stratum_target_provenance.csv"),
  recovery   = list(layer = "composition_detail",
                    file  = "stratum_observed_recovery.csv"),
  support    = list(layer = "composition_detail",
                    file  = "synthetic_support_diagnostics.csv"),
  st_agree   = list(layer = "agreement",
                    file  = "empirical_vs_synthetic_stratum_agreement.csv"),
  co_agree   = list(layer = "agreement",
                    file  = "empirical_vs_synthetic_corpus_agreement.csv"),
  validation = list(layer = "composition",
                    file  = "composition_validation_checks.csv"))

# Map a layer name to its directory (using the dirs the caller passed).
.cv_layer_dir <- function(layer, composition_dir, composition_detail_dir,
                          agreement_dir) {
  switch(layer,
         composition        = composition_dir,
         composition_detail = composition_detail_dir,
         agreement          = agreement_dir,
         stop("internal: unknown input layer '", layer, "'"))
}

.cv_or <- function(a, b) if (is.null(a) || length(a) == 0L ||
                             (length(a) == 1L && is.na(a))) b else a

# --- lazy ggplot2 + theme (call time only) -------------------------------

.cv_need_ggplot <- function() {
  if (!requireNamespace("ggplot2", quietly = TRUE))
    stop("75_analysis_visuals: ggplot2 is required at call time ",
         "(define-only on source; never attached when sourced).")
  invisible(TRUE)
}

.cv_theme <- function(base_size = .CV_THEME_BASE_SIZE) {
  g <- asNamespace("ggplot2")
  g$theme_minimal(base_size = base_size) +
    g$theme(
      panel.grid.minor = g$element_blank(),
      panel.grid.major = g$element_line(color = "gray92", linewidth = 0.3),
      strip.text       = g$element_text(face = "bold", size = base_size - 1),
      plot.title       = g$element_text(face = "bold", size = base_size + 1),
      plot.subtitle    = g$element_text(size = base_size - 1,
                                        color = "gray35",
                                        lineheight = 1.15),
      plot.caption     = g$element_text(size = base_size - 2,
                                        color = "gray45", hjust = 0,
                                        lineheight = 1.15),
      plot.margin      = g$margin(14, 16, 10, 14),
      panel.border     = g$element_rect(colour = "gray40", fill = NA,
                                        linewidth = 0.35),
      legend.position  = "bottom",
      legend.title     = g$element_text(size = base_size - 1),
      legend.text      = g$element_text(size = base_size - 2))
}

# --- run-metadata caption helpers ----------------------------------------
# Goal: every Q1/Q2/Q3 figure carries a compact, auto-loaded metadata
# footer reading something like
#   "B=5000; pool_key=target; smoothing=eb_corpus; kappa=4;
#    support_scope=occupied; n_pool=140-150; source=<csv>"
# so a reviewer never has to ask "what B / smoothing / pool_key was
# this rendered at?" Plot logic stays unchanged; the data frame +
# source CSV name flow in via `.cv_save(..., meta_df, meta_source)`.
# Fields that cannot be inferred fall back to "n/a" or are dropped.

# Pull a single scalar string from a column. Returns NA when the
# column is missing or holds only NA. Mixed values are joined with `|`.
.cv_meta_value <- function(df, col) {
  if (is.null(df) || !is.data.frame(df) || !nrow(df) ||
      !col %in% names(df)) return(NA_character_)
  v <- df[[col]]
  v <- v[!is.na(v)]
  if (!length(v)) return(NA_character_)
  vals <- unique(as.character(v))
  if (length(vals) == 1L) vals else paste(vals, collapse = "|")
}

# Infer B from a data frame. Prefers the explicit `B` column; falls
# back to counting unique values of replicate id columns
# (`composition_id` for Q3, `size_curve_id` for Q1, `bootstrap_id` for
# Q2). Returns NA when nothing usable is present (e.g. deterministic
# diagnostic figures keyed off cell_diagnostics_rigor.csv).
.cv_infer_B <- function(df) {
  if (is.null(df) || !is.data.frame(df) || !nrow(df)) return(NA_integer_)
  if ("B" %in% names(df)) {
    v <- suppressWarnings(as.integer(df$B))
    v <- v[!is.na(v) & v > 0L]
    if (length(v)) return(as.integer(max(v)))
  }
  for (col in c("composition_id", "size_curve_id", "bootstrap_id")) {
    if (col %in% names(df)) {
      vals <- unique(df[[col]])
      vals <- vals[!is.na(vals)]
      if (length(vals)) return(as.integer(length(vals)))
    }
  }
  NA_integer_
}

# Compact n_pool / n_fit / n_outcomes_observed range strings (one
# part per known column; missing columns return character(0)).
.cv_infer_pool_or_fit <- function(df) {
  if (is.null(df) || !is.data.frame(df) || !nrow(df))
    return(character(0))
  out <- character(0)
  range_part <- function(col, label) {
    if (!col %in% names(df)) return(character(0))
    v <- suppressWarnings(as.integer(df[[col]]))
    v <- v[!is.na(v) & v > 0L]
    if (!length(v)) return(character(0))
    if (min(v) == max(v)) sprintf("%s=%d", label, min(v))
    else sprintf("%s=%d-%d", label, min(v), max(v))
  }
  out <- c(out, range_part("n_pool",              "n_pool"))
  out <- c(out, range_part("n_fit",               "n_fit"))
  out <- c(out, range_part("n_outcomes_observed", "n_obs"))
  out
}

# Assemble the compact metadata line. `df` may be NULL for figures
# that have no resampling data frame (B=n/a). `source_csv` is the
# basename of the input CSV (or any short identifier). `extras` is a
# named list/character vector of `key=value` overrides; values that
# are NA, NULL, or empty are dropped.
.cv_meta_line <- function(df = NULL, source_csv = NULL,
                          extras = list(),
                          suppress = character(0)) {
  # Manuscript-conservative footer (2026-05-27 declutter pass).
  # Per Section 4 / docs/section4_visual_mcse_plan.md, the plot footer
  # carries the irreducible run-tier identity: B (only when meaningful),
  # bootstrap_mode (Q2-relevant), non-primary Q3 settings, and the
  # compact n_pool/n_fit/n_obs range. Source CSV is NOT printed on the
  # plot; it remains recorded in the per-question markdown reports and
  # the sync manifest. `source_csv` is accepted for backward
  # compatibility with callers (.cv_save passes it) but no longer
  # appended to the embedded plot caption.
  #
  # `suppress` is a character vector of field names to drop from the
  # metadata line. Callers that already include the equivalent
  # information in an interpretive note (e.g. .cv_fit_library_note()
  # supplies "n_fit"; .cv_resampling_note() supplies "B" and a
  # n_outcomes grid) should pass the matching key(s) to avoid a
  # double-print on the embedded plot footer.
  in_suppress <- function(k) any(tolower(k) == tolower(suppress))
  parts <- character(0)
  # B shown only when it represents an actual resampling/sampling tier.
  # Deterministic / input-map diagnostics return NA and are emitted
  # with no B token (avoids "B=n/a" clutter).
  if (!in_suppress("B")) {
    bv <- .cv_infer_B(df)
    if (!is.na(bv))
      parts <- c(parts, sprintf("B=%s", as.character(bv)))
  }
  # Section 4 of the manuscript defines the Q3 primary configuration
  # as pool_key=target, smoothing=eb_corpus, kappa=4, support_scope=
  # occupied. Suppressing these fields from per-figure footers when
  # they match the primary keeps Q3 metadata compact; non-primary
  # values (e.g. smoothing=corpus_blend in dev/legacy CSVs) remain
  # visible so the footer stays honest about run tier.
  .primary_defaults <- list(
    pool_key      = "target",
    smoothing     = "eb_corpus",
    kappa         = "4",
    support_scope = "occupied")
  .matches_default <- function(key, val) {
    def <- .primary_defaults[[key]]
    if (is.null(def)) return(FALSE)
    a <- suppressWarnings(as.character(val))
    if (key == "kappa") {
      # Loose numeric compare so "4" / "4.0" / "4L" all suppress.
      an <- suppressWarnings(as.numeric(a))
      dn <- suppressWarnings(as.numeric(def))
      return(is.finite(an) && is.finite(dn) && isTRUE(an == dn))
    }
    isTRUE(tolower(a) == tolower(def))
  }
  # bootstrap_mode is Q2-specific; never suppressed-by-default (it is
  # informative on every Q2 figure). It can still be force-suppressed
  # via the suppress argument if a caller asks.
  for (key in c("pool_key", "smoothing", "kappa", "support_scope",
                "bootstrap_mode")) {
    if (in_suppress(key)) next
    v <- .cv_meta_value(df, key)
    if (is.na(v) || !nzchar(v)) next
    if (.matches_default(key, v)) next   # suppress when matches primary
    parts <- c(parts, sprintf("%s=%s", key, v))
  }
  # n_pool / n_fit / n_obs tokens, filtered by the suppress list. The
  # underlying helper emits `key=value` strings, so filter by key prefix.
  pool_fit_parts <- .cv_infer_pool_or_fit(df)
  if (length(suppress) && length(pool_fit_parts)) {
    keep <- !vapply(pool_fit_parts, function(p) {
      k <- sub("=.*$", "", p)
      in_suppress(k)
    }, logical(1))
    pool_fit_parts <- pool_fit_parts[keep]
  }
  parts <- c(parts, pool_fit_parts)
  # Extras override / supplement the auto-inferred values. Values can
  # be scalar; NA / empty values are dropped.
  if (length(extras)) {
    for (nm in names(extras)) {
      v <- extras[[nm]]
      if (is.null(v) || length(v) != 1L) next
      vc <- suppressWarnings(as.character(v))
      if (is.na(vc) || !nzchar(vc)) next
      parts <- c(parts, sprintf("%s=%s", nm, vc))
    }
  }
  # `source_csv` intentionally NOT emitted on the plot footer; reports
  # carry the source provenance instead.
  paste(parts, collapse = "; ")
}

# Append a compact metadata line to the figure's existing caption.
# Idempotent on `meta_line = ""` (returns the plot unchanged). Long
# captions are soft-wrapped so they do not clip past the plot panel at
# the bumped global base size (2026-05 polish pass).
.cv_add_metadata_caption <- function(p, meta_line) {
  if (is.null(meta_line) || !length(meta_line) ||
      !nzchar(meta_line)) return(p)
  g <- asNamespace("ggplot2")
  existing <- p$labels$caption
  if (is.null(existing)) existing <- ""
  wrap <- function(s) paste(strwrap(s, width = 110L), collapse = "\n")
  existing_w <- if (nzchar(existing)) wrap(existing) else ""
  meta_w     <- wrap(meta_line)
  new_cap <- if (nzchar(existing_w))
               paste0(existing_w, "\n", meta_w)
             else meta_w
  p + g$labs(caption = new_cap)
}

# Vector-PDF saver: no Type-3 fonts. Writes ONLY the single path it is
# given. When `meta_df` / `meta_source` / `meta_extras` are supplied,
# appends a compact auto-loaded metadata footer to the figure caption
# so every plot carries B / pool_key / smoothing / kappa / source CSV.
.cv_save <- function(p, path, width = 9, height = 6, verbose = TRUE,
                     meta_df = NULL, meta_source = NULL,
                     meta_extras = list(),
                     meta_suppress = character(0)) {
  if (!is.null(meta_df) || !is.null(meta_source) ||
      length(meta_extras)) {
    p <- .cv_add_metadata_caption(
      p, .cv_meta_line(meta_df, source_csv = meta_source,
                       extras = meta_extras,
                       suppress = meta_suppress))
  }
  ggplot2::ggsave(path, p, width = width, height = height,
                  limitsize = FALSE, useDingbats = FALSE, device = "pdf")
  if (isTRUE(verbose)) message(sprintf("  wrote %s", path))
  invisible(path)
}

#' Canonical 36-slug cell order (effect block, then het, then bias).
#'
#' Pure in-memory; shared factor-level order for the target/observed
#' axes so the diagonal is contiguous and readable.
cv_cell_levels <- function() {
  g <- expand.grid(b = .CV_BIAS, h = .CV_HET, e = .CV_EFFECT,
                   stringsAsFactors = FALSE)
  g <- g[order(match(g$e, .CV_EFFECT), match(g$h, .CV_HET),
               match(g$b, .CV_BIAS)), ]
  paste(g$e, g$h, g$b, sep = "_")
}

.cv_split_slug <- function(slug) {
  p <- strsplit(as.character(slug), "_", fixed = TRUE)
  data.frame(
    effect_slug        = vapply(p, `[`, "", 1L),
    heterogeneity_slug = vapply(p, `[`, "", 2L),
    bias_slug          = vapply(p, `[`, "", 3L),
    stringsAsFactors   = FALSE)
}

# Compact resampling metadata for figure captions / subtitles. Reads
# B and the sample-size grid from the input data so callers do not
# have to plumb them through manually. Returns a short string like:
#   "Resampling: B = 100; n_outcomes = 5-30, 35, 40, 50."
# When B or the n column is absent / inconsistent, falls back gracefully.
.cv_resampling_note <- function(df, n_col = "n_outcomes_target") {
  parts <- character(0)
  if (is.data.frame(df) && nrow(df) && "B" %in% names(df)) {
    bv <- unique(suppressWarnings(as.integer(df$B)))
    bv <- bv[!is.na(bv)]
    if (length(bv) == 1L)
      parts <- c(parts, sprintf("B = %d", bv))
    else if (length(bv) > 1L)
      parts <- c(parts, sprintf("B in {%s}",
                                 paste(sort(bv), collapse = ", ")))
  }
  if (is.data.frame(df) && nrow(df) && n_col %in% names(df)) {
    nv <- sort(unique(suppressWarnings(as.integer(df[[n_col]]))))
    nv <- nv[!is.na(nv) & nv > 0L]
    if (length(nv))
      parts <- c(parts, sprintf("n_outcomes = %s",
                                 .cv_compact_int_grid(nv)))
  }
  if (!length(parts)) return("")
  paste0("Resampling: ", paste(parts, collapse = "; "), ".")
}

# Compress an integer vector to a compact human-readable form. Runs of
# consecutive integers collapse to "lo-hi"; isolated values stay
# discrete. e.g. c(5:30, 35, 40, 50) -> "5-30, 35, 40, 50".
.cv_compact_int_grid <- function(nv) {
  nv <- sort(unique(as.integer(nv)))
  if (!length(nv)) return("")
  if (length(nv) == 1L) return(as.character(nv))
  gaps <- which(diff(nv) != 1L)
  starts <- c(1L, gaps + 1L)
  ends   <- c(gaps, length(nv))
  pieces <- vapply(seq_along(starts), function(i) {
    s <- nv[starts[i]]; e <- nv[ends[i]]
    if (s == e) as.character(s) else sprintf("%d-%d", s, e)
  }, character(1))
  paste(pieces, collapse = ", ")
}

# Compact synthetic-fit-library metadata for non-resampling cell
# atlases. Reads n_fit per cell from a per-cell diagnostics frame and
# returns e.g.:
#   "Synthetic fit library: n_fit = 105-106 per cell."
# Falls back gracefully when n_fit is missing or constant.
.cv_fit_library_note <- function(df) {
  if (!is.data.frame(df) || !nrow(df) || !"n_fit" %in% names(df))
    return("")
  v <- suppressWarnings(as.integer(df$n_fit))
  v <- v[!is.na(v) & v > 0L]
  if (!length(v)) return("")
  rng <- range(v)
  fit_str <- if (rng[1] == rng[2]) as.character(rng[1])
             else sprintf("%d-%d", rng[1], rng[2])
  sprintf("Synthetic fit library: n_fit = %s per cell.", fit_str)
}

# Clamp non-finite values to a finite display range; return clamped
# vector + the +Inf / -Inf counts so the caller can report them
# (Inf-safe: never silently dropped, shown at a terminal boundary).
.cv_clamp_inf <- function(x, pad = 0.06) {
  x <- suppressWarnings(as.numeric(x))
  fin <- x[is.finite(x)]
  if (!length(fin)) return(list(v = x, lo = NA, hi = NA,
                                n_pos = sum(x == Inf, na.rm = TRUE),
                                n_neg = sum(x == -Inf, na.rm = TRUE)))
  rng <- range(fin)
  span <- diff(rng); if (span == 0) span <- max(abs(rng), 1)
  lo <- rng[1] - pad * span; hi <- rng[2] + pad * span
  v <- x
  v[x == Inf]  <- hi
  v[x == -Inf] <- lo
  list(v = v, lo = lo, hi = hi,
       n_pos = sum(x == Inf, na.rm = TRUE),
       n_neg = sum(x == -Inf, na.rm = TRUE))
}

# --- input reader (call time only) ---------------------------------------

#' Read the empirical-weighted synthetic sampling + agreement CSVs
#' this layer can plot.
#'
#' Each input declares which conceptual layer it belongs to
#' (empirical_weighted_synthetic / empirical_weighted_synthetic_detail /
#' agreement); the caller picks the directory for each layer. Returns
#' a structured list grouped by layer + a flat lookup so callers can
#' use either view.
#'
#' The `composition` / `composition_detail` keys are internal mechanism
#' nouns retained on the `.CV_INPUTS` layer tag (the input gate is
#' still `sim_validate_composition_inputs()`). Public-facing folder /
#' figure / report names use empirical-weighted synthetic sampling.
#'
#' Returns list with:
#'   * `composition` / `composition_detail` / `agreement`: named lists
#'     of data.frames (NULL when the file is missing);
#'   * `data`:   flat name -> data.frame lookup (NULL when missing);
#'   * `found`:  flat name -> logical;
#'   * `paths`:  flat name -> resolved file path;
#'   * `dirs`:   the three input directories used;
#'   * `report_present`: did the upstream empirical_weighted_synthetic_
#'     report.md exist alongside the Q3 primaries?
#'
#' Never writes.
cv_read_inputs <- function(ews_dir        = .CV_EWS_DIR,
                           ews_detail_dir = .CV_EWS_DETAIL_DIR,
                           agreement_dir  = .CV_AGREE_DIR) {
  layers <- list(composition = list(), composition_detail = list(),
                 agreement   = list())
  data   <- list(); found <- logical(0); paths <- character(0)
  for (k in names(.CV_INPUTS)) {
    spec <- .CV_INPUTS[[k]]
    dir_ <- .cv_layer_dir(spec$layer, ews_dir,
                          ews_detail_dir, agreement_dir)
    p <- file.path(dir_, spec$file)
    paths[k] <- p
    if (file.exists(p)) {
      d <- utils::read.csv(p, stringsAsFactors = FALSE,
                           check.names = FALSE)
      data[[k]] <- d
      found[k]  <- TRUE
      layers[[spec$layer]][[k]] <- d
    } else {
      data[[k]] <- NULL
      found[k]  <- FALSE
      layers[[spec$layer]][[k]] <- NULL
    }
  }
  rp <- file.path(ews_dir, "empirical_weighted_synthetic_report.md")
  c(layers,
    list(data = data, found = found, paths = paths,
         dirs = list(empirical_weighted_synthetic        = ews_dir,
                     empirical_weighted_synthetic_detail = ews_detail_dir,
                     agreement = agreement_dir),
         report_present = file.exists(rp)))
}

# --- A. empirical stratum cell-weight heatmap ----------------------------

#' Q3 input map: empirical fitted-cell mixtures used for synthetic
#' sampling.
#'
#' Heatmap: empirical stratum (rows) x observed (fitted) cell (cols),
#' fill = the empirical fitted-cell mixture weight (`smoothed_weight`)
#' that 65 samples synthetic rows under. The default smoothing is
#' `eb_corpus` (empirical-Bayes support-masked: `w_sc = (n_sc + kappa
#' * p0_{c|s}) / (n_s + kappa)` with the corpus prior `p0_{c|s}`
#' restricted to cells the stratum occupies); `corpus_blend`,
#' `additive`, and `none` remain available for sensitivity. The
#' weighting is NOT spatial smoothing over the 36-cell grid -- it
#' does not move weight onto cells the stratum does not occupy. The
#' full 36-cell grid is shown so unoccupied cells render at zero; the
#' per-stratum dominant cell is outlined.
cv_plot_weight_heatmap <- function(weights, path, verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  lvls <- cv_cell_levels()
  strata <- sort(unique(weights$stratum))
  full <- expand.grid(stratum = strata, cell_slug = lvls,
                       stringsAsFactors = FALSE)
  w <- weights[, c("stratum", "cell_slug", "smoothed_weight",
                   "dominant_cell")]
  full <- merge(full, w, by = c("stratum", "cell_slug"), all.x = TRUE,
                sort = FALSE)
  full$smoothed_weight[is.na(full$smoothed_weight)] <- 0
  sp <- .cv_split_slug(full$cell_slug)
  full$effect_slug <- factor(sp$effect_slug, levels = .CV_EFFECT)
  full$het_slug    <- factor(sp$heterogeneity_slug, levels = .CV_HET)
  full$bias_slug   <- factor(sp$bias_slug, levels = .CV_BIAS)
  dom <- weights[!duplicated(weights$stratum),
                 c("stratum", "dominant_cell")]
  dsp <- .cv_split_slug(dom$dominant_cell)
  dom$effect_slug <- factor(dsp$effect_slug, levels = .CV_EFFECT)
  dom$het_slug    <- factor(dsp$heterogeneity_slug, levels = .CV_HET)
  dom$bias_slug   <- factor(dsp$bias_slug, levels = .CV_BIAS)

  # Portrait orientation (2026-05 polish): 4 effect rows x 3 bias cols,
  # heterogeneity within each panel on x and stratum on y. All 36 cells
  # remain visible; stratum labels now repeat per row, which is the goal.
  p <- g$ggplot(full, g$aes(x = .data$het_slug, y = .data$stratum)) +
    g$geom_tile(g$aes(fill = .data$smoothed_weight),
                color = "gray90", linewidth = 0.15) +
    g$geom_tile(data = dom, fill = NA, color = .CV_DIAG,
                linewidth = 0.5) +
    g$facet_grid(effect_slug ~ bias_slug, switch = "y") +
    g$scale_fill_gradient(low = .CV_HEAT_LOW, high = .CV_HEAT_HIGH,
                          name = "empirical-weighted sampling weight") +
    g$labs(
      title = "Empirical fitted-cell mixtures used for synthetic sampling",
      subtitle = paste0(
        "Fill = empirical fitted-cell mixture weight; ",
        "orange outline = per-stratum dominant cell."),
      x = "heterogeneity band (within panel)  /  bias band (panel column)",
      y = "stratum  /  effect band (panel row)",
      caption = paste0(
        "Q3 input map, not an outcome result. ",
        "Mechanism + smoothing details in the Q3 report.")) +
    .cv_theme() +
    g$theme(axis.text.x = g$element_text(size = .CV_AXIS_TEXT_SMALL,
                                         angle = 35, vjust = 1, hjust = 1))
  .cv_save(p, path, width = 11, height = 14, verbose = verbose,
           meta_df = weights,
           meta_source = "empirical_stratum_cell_weights.csv")
}

# --- B. per-axis recovery heatmaps ---------------------------------------
# (The 36x36 cell-transition heatmap cv_plot_cell_transition() was
# retired in the 2026-05 Q3 cull -- superseded by the three axis-
# recovery heatmaps below, which collapse the same information onto
# the three design axes and are far more readable.)

#' One axis (effect | heterogeneity | bias): target band x observed
#' band, fill = P(observed | target).
cv_plot_axis_transition <- function(axis_trans, axis, path,
                                    verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  lvl <- switch(axis, effect = .CV_EFFECT, heterogeneity = .CV_HET,
                bias = .CV_BIAS,
                stop("cv_plot_axis_transition: unknown axis ", axis))
  d <- axis_trans[axis_trans$axis == axis, , drop = FALSE]
  if (!nrow(d)) stop("cv_plot_axis_transition: no rows for axis ", axis)
  d$target   <- factor(d$target_slug, levels = lvl)
  d$observed <- factor(d$observed_slug, levels = rev(lvl))
  d$p <- suppressWarnings(as.numeric(d$p_observed_given_target))
  diag <- d[as.character(d$target_slug) ==
            as.character(d$observed_slug), , drop = FALSE]
  p <- g$ggplot(d, g$aes(x = .data$target, y = .data$observed)) +
    g$geom_tile(g$aes(fill = .data$p), color = "gray85",
                linewidth = 0.25) +
    g$geom_text(g$aes(label = sprintf("%.2f", .data$p)),
                size = .CV_HEATMAP_LABEL_SIZE, color = "gray20") +
    g$geom_tile(data = diag, fill = NA, color = .CV_DIAG,
                linewidth = 0.5) +
    g$scale_fill_gradient(low = .CV_HEAT_LOW, high = .CV_HEAT_HIGH,
                          name = "P(observed | target)",
                          limits = c(0, 1)) +
    g$labs(
      title = sprintf("%s-axis recovery of fitted synthetic profiles",
                      .cv_axis_display_name(axis)),
      subtitle = "Fill/label = P(observed band | target/DGM band)",
      x = sprintf("target %s band", axis),
      y = sprintf("observed (fitted-profile) %s band", axis),
      caption = paste0(
        "Profile-definition diagnostic, not a Q3 outcome figure. ",
        "Basis details in the Q3 report.")) +
    .cv_theme()
  .cv_save(p, path, width = 8.5, height = 7.5, verbose = verbose,
           meta_df = axis_trans,
           meta_source = "synthetic_axis_transition.csv",
           meta_extras = list(axis = axis))
}

# Display name for an axis slug, used by chart titles. "het" ->
# "Heterogeneity", "bias" -> "Bias", etc.
.cv_axis_display_name <- function(axis) {
  switch(as.character(axis),
         effect        = "Effect",
         heterogeneity = "Heterogeneity",
         het           = "Heterogeneity",
         bias          = "Bias",
         tools::toTitleCase(as.character(axis)))
}

# The following composition diagnostics were retired in the 2026-05
# Q3 cull and are no longer surfaced as default PDFs:
#   * cv_plot_support_bars()                      -> .pdf retired;
#                                                    support coverage
#                                                    is reported as
#                                                    text inside
#                                                    composition_visuals_report.md
#                                                    from
#                                                    synthetic_support_diagnostics.csv.
#   * cv_plot_stratum_provenance() /              -> retired (interesting
#     cv_plot_stratum_recovery() (+ shared           but not necessary once
#     .cv_stratum_cell_heat() helper)                we have the fitted-cell
#                                                    mixture map + axis
#                                                    recovery diagnostics).
#   * cv_plot_agreement() (stratum + corpus)      -> retired; the
#                                                    empirical-bootstrap vs
#                                                    synthetic-composition
#                                                    core-metrics overlay
#                                                    replaces this story.
#   * cv_plot_validation_status()                 -> .pdf retired;
#                                                    PASS/INFO/WARN/FAIL
#                                                    counts are reported
#                                                    as text inside
#                                                    composition_visuals_report.md
#                                                    from
#                                                    composition_validation_checks.csv.
#
# Stale PDFs from those families are scrubbed by .CV_Q3_RETIRED_PDFS
# at the top of every sim_run_composition_visuals() run.

# --- deferred-family ledger ---------------------------------------------
# Plot families that the current composition + agreement outputs do NOT
# support directly (the upstream layers do not produce the required
# inputs). Recorded as a small CSV so callers can audit what is missing,
# never silently faked. Not exposed as a top-of-report section -- the
# report references the CSV instead.

.CV_DEFERRED <- data.frame(
  plot_family = c(
    "basis_comparison_curves",
    "cell_occupancy_by_source",
    "axis_marginals_by_source",
    "claimed_denominator_diagnostics",
    "log10bf_infinite_behavior_facets",
    "stratum_observed_recovery_overlay"),
  status = "deferred-future-extension",
  reason = c(
    "v4 uses a single gated composition + agreement pair, not a 3-folder basis suite; no by-n basis-comparison long table exists.",
    "synthetic corpus is a single source_article (sim2026); the per-source split degenerates. Pool occupancy is covered by synthetic_support_diagnostics_bars.",
    "same single-source reason; target / observed axis marginals are covered by the axis-transition heatmaps.",
    "claimed-effect / claimed-denominator metrics are not part of the v4 rigor-first composition summary schema.",
    "Inf is preserved as evidence (no *_capped axis) and handled in-figure (clamped + reported), not as a dedicated capped-behavior facet.",
    "recovery heatmap (P(observed) under matched composition) is dropped from the primary set; if a successor is needed it should plot delta = recovered_weight - empirical_weight, not the raw recovery."),
  required_input = c(
    "basis-suite per-n long summary (not produced)",
    "per-source pool diagnostics (single synthetic source)",
    "per-source axis marginals (single synthetic source)",
    "claimed_* denominator columns (not in v4 schema)",
    "*_capped log10BF columns (not produced)",
    "delta_recovery_vs_observed (not produced; trivial to build from existing weights and recovery csvs)"),
  stringsAsFactors = FALSE)

#' Write composition_visuals_deferred.csv. Writes ONLY the given path.
cv_write_deferred <- function(path) {
  utils::write.csv(.CV_DEFERRED, path, row.names = FALSE)
  invisible(path)
}

# --- plain-language report ----------------------------------------------

# A short guidance block keyed off the figure file name; rendered in the
# report so a reader picking up the figure folder knows how to read it.
.CV_FIGURE_GUIDE <- list(
  empirical_stratum_cell_weights_heatmap.pdf =
    "Q3 input map: empirical fitted-cell mixtures used for synthetic sampling. Fill = empirical fitted-cell mixture weight (default smoothing = eb_corpus, support = occupied); orange outline = per-stratum dominant cell. Not spatial smoothing over the 36-cell grid.",
  synthetic_axis_transition_effect_heatmap.pdf =
    "Profile-definition diagnostic: effect-axis recovery of fitted synthetic profiles. Fill/label = P(observed band | target band).",
  synthetic_axis_transition_het_heatmap.pdf =
    "Profile-definition diagnostic: heterogeneity-axis recovery of fitted synthetic profiles. Fill/label = P(observed band | target band).",
  synthetic_axis_transition_bias_heatmap.pdf =
    "Profile-definition diagnostic: bias-axis recovery of fitted synthetic profiles. Fill/label = P(observed band | target band).",
  cell_rigor_atlas.pdf =
    "Q1 manuscript-facing primary: known-cell rigor atlas. Fill = median selected rigor (log10 BF) at each design cell.",
  cell_attenuation_atlas.pdf =
    "Q1 manuscript-facing primary: known-cell attenuation / effect recovery atlas. Boxplots of baseline vs RoBMA-PSMA, with true-effect reference line in each cell.",
  synthetic_cell_rigor_variability_by_effect.pdf =
    "Q1 manuscript-facing primary: per-cell rigor variability (width90 = q95-q05 across B resamples) vs n_outcomes, faceted by effect band.",
  synthetic_cell_rigor_viability_min_n.pdf =
    "Q1 manuscript-facing primary: minimum-viable-n per cell to meet width90 thresholds; 36-cell heatmap faceted by (threshold x bias band).",
  synthetic_cell_rigor_width_heatmap_by_n.pdf =
    "Q1 secondary: rigor width90 snapshots at selected n_outcomes; 36-cell heatmap faceted by (n x bias band).",
  synthetic_cell_bias_evidence_variability_by_effect.pdf =
    "Q1 secondary: per-cell bias-evidence variability (width90 = q95-q05 of median_log10BF_bias across B resamples) vs n_outcomes, faceted by effect band. Component-stability companion to the rigor width90 figure.",
  synthetic_cell_attenuation_variability_by_effect.pdf =
    "Q1 secondary: per-cell absolute-attenuation variability (width90 of median_attenuation_abs across B resamples) vs n_outcomes, faceted by effect band. Component-stability diagnostic for effect recovery.",
  empirical_resampling_rigor_variability_by_stratum.pdf =
    "Q2 primary: empirical resampling variability of rigor. One line per stratum; y = width90 = q95 - q05 of stratum-level median selected rigor across B empirical resamples; faceted by bootstrap mode (outcome, source_cluster). Lower = more stable.",
  empirical_resampling_core_uncertainty_heatmap.pdf =
    "Q2 primary: observed-size empirical bootstrap uncertainty (width90 = q95 - q05) per (stratum, core metric, mode). Core metrics: rigor evidence, bias evidence, absolute attenuation. Lower = more stable. Inf widths are clamped to the terminal fill color and labeled Inf.",
  empirical_resampling_core_intervals.pdf =
    "Q2 primary: observed-size interval profiles per (stratum, core metric, mode). Filled point = observed empirical estimate; thick bar = q05-q95; thin bar = q025-q975. Non-finite endpoints are clamped to the per-facet terminal axis boundary and reported in the markdown report.",
  empirical_weighted_synthetic_rigor_variability_by_stratum.pdf =
    "Q3 primary: empirical-weighted synthetic sampling variability of rigor. One line per empirical stratum; y = width90 = q95 - q05 of stratum-level median selected rigor across B empirical-weighted synthetic draws; lower = more stable.",
  empirical_bootstrap_vs_empirical_weighted_synthetic_core_metrics.pdf =
    "Q3 bridge primary: empirical bootstrap (blue) vs empirical-weighted synthetic sampling (purple) for core audit metrics (rigor evidence, bias evidence, absolute attenuation), matched to each stratum's empirical n_outcomes. Directional/thresholded p_* rate metrics are deliberately excluded."
)

#' Write the empirical-weighted synthetic sampling visuals report
#' (Q3 primary/bridge + profile-definition diagnostics +
#' validation/support text).
#'
#' Validation status counts and pool-support coverage now live as text
#' inside this report (the standalone `composition_validation_status
#' .pdf` and `synthetic_support_diagnostics_bars.pdf` PDFs were retired
#' in the 2026-05 Q3 cull). The function still writes ONLY `path`.
cv_write_visuals_report <- function(path, inputs, figures_written,
                                    inf_notes = list(),
                                    dev_partial = NA,
                                    fig_dir = NA_character_,
                                    deferred_path = NA_character_,
                                    validation = NULL,
                                    support    = NULL) {
  L <- character(0); ad <- function(...) L <<- c(L, paste0(...))
  ad("# Empirical-weighted synthetic sampling visuals report (Q3)")
  ad("")
  ad("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
     if (isTRUE(dev_partial)) "  **DEV/PARTIAL**" else "")
  ad("")
  ad("## What this report is")
  ad("Q3 visual layer for empirical-weighted synthetic sampling. ",
     "Reads stable CSVs written by ",
     "`sim_run_empirical_weighted_synthetic()`, ",
     "`sim_run_empirical_weighted_size_curve()`, and ",
     "`emp_run_resampling()`; builds vector PDFs; surfaces ",
     "validation/support coverage as text. Does NOT recompute Q3 ",
     "outputs, agreement, or empirical resampling. If an input CSV ",
     "is missing, the corresponding figure is simply skipped.")
  ad("")
  ad("## Inputs read")
  # The `.CV_INPUTS` table tags layers with the internal mechanism
  # nouns (composition / composition_detail / agreement); render the
  # public-facing folder name from inputs$dirs for the section
  # heading.
  layer_display <- c(
    composition        = "empirical_weighted_synthetic",
    composition_detail = "empirical_weighted_synthetic/detail",
    agreement          = "agreement")
  layer_dir_key <- c(
    composition        = "empirical_weighted_synthetic",
    composition_detail = "empirical_weighted_synthetic_detail",
    agreement          = "agreement")
  for (layer in c("composition", "composition_detail", "agreement")) {
    dir_path <- inputs$dirs[[layer_dir_key[[layer]]]]
    if (is.null(dir_path)) dir_path <- inputs$dirs[[layer]]
    ad(sprintf("**%s** -> `%s/`",
               layer_display[[layer]], dir_path))
    keys <- names(.CV_INPUTS)[
      vapply(.CV_INPUTS, function(s) s$layer == layer, logical(1))]
    for (k in keys)
      ad("- `", basename(inputs$paths[[k]]), "` -> ",
         if (isTRUE(inputs$found[[k]])) "read"
         else "MISSING (figure(s) needing it skipped)")
    ad("")
  }

  # Classify figures into Q3 primary/bridge vs profile-definition
  # diagnostic by filename. Anything else lands in "other figures" so
  # nothing is silently dropped.
  fig_basenames <- basename(figures_written)
  primary_files <- c(
    "empirical_stratum_cell_weights_heatmap.pdf",
    "empirical_weighted_synthetic_rigor_variability_by_stratum.pdf",
    "empirical_bootstrap_vs_empirical_weighted_synthetic_core_metrics.pdf")
  diagnostic_files <- c(
    "synthetic_axis_transition_effect_heatmap.pdf",
    "synthetic_axis_transition_het_heatmap.pdf",
    "synthetic_axis_transition_bias_heatmap.pdf")
  primary_paths    <- figures_written[fig_basenames %in% primary_files]
  diagnostic_paths <- figures_written[fig_basenames %in% diagnostic_files]
  other_paths      <- setdiff(figures_written,
                              c(primary_paths, diagnostic_paths))

  .write_section <- function(header, paths) {
    if (!length(paths)) return(invisible())
    ad("## ", header)
    for (f in paths) {
      base <- basename(f)
      guide <- .CV_FIGURE_GUIDE[[base]]
      ad("- `", base, "`",
         if (!is.null(guide)) paste0("  -- ", guide) else "")
    }
    ad("")
  }
  if (!length(figures_written)) {
    ad("## Figures written")
    ad("- (none -- all required inputs were missing)")
    ad("")
  } else {
    .write_section("Q3 primary / bridge figures", primary_paths)
    .write_section("Profile-definition diagnostics", diagnostic_paths)
    .write_section("Other figures", other_paths)
  }
  # Validation status as text (replaces the retired
  # composition_validation_status.pdf bar). Counts shown when the
  # validation CSV is available; nothing forced if missing.
  ad("## Validation / support checks (text)")
  if (is.null(validation) || !nrow(validation)) {
    ad("- composition_validation_checks.csv missing or empty.")
  } else {
    tb <- table(factor(validation$status,
                       levels = unique(c("PASS", "INFO", "WARN", "FAIL",
                                         unique(validation$status)))))
    tb <- tb[tb > 0L]
    ad("- composition_validation_checks.csv status counts:")
    for (nm in names(tb))
      ad("  - ", nm, " x ", as.integer(tb[[nm]]))
    if ("WARN" %in% names(tb) || "FAIL" %in% names(tb)) {
      ad("- non-PASS rows (first 6):")
      bad <- validation[!validation$status %in% c("PASS", "INFO"), ,
                        drop = FALSE]
      cols_show <- intersect(c("check", "status", "detail",
                                "metric", "n", "value"),
                              names(bad))
      bad_h <- utils::head(bad[, cols_show, drop = FALSE], 6L)
      for (i in seq_len(nrow(bad_h)))
        ad("  - ", paste(sprintf("%s=%s", names(bad_h),
                                   as.character(bad_h[i, ])),
                          collapse = "; "))
    }
  }
  if (!is.null(support) && nrow(support)) {
    # Per pool basis, count empty / sparse / supported cells out of 36.
    sup <- support
    sup$class <- ifelse(sup$empty_flag %in% c(TRUE, "TRUE", "True"),
                        "empty",
                  ifelse(sup$sparse_flag %in% c(TRUE, "TRUE", "True"),
                         "sparse", "supported"))
    by_basis <- as.data.frame(table(basis = sup$basis,
                                     class = sup$class),
                               stringsAsFactors = FALSE)
    by_basis <- by_basis[by_basis$Freq > 0L, , drop = FALSE]
    if (nrow(by_basis)) {
      ad("- synthetic_support_diagnostics.csv coverage per pool basis ",
         "(out of 36 cells):")
      for (bs in sort(unique(by_basis$basis))) {
        sub <- by_basis[by_basis$basis == bs, , drop = FALSE]
        parts <- sprintf("%s=%d", sub$class, as.integer(sub$Freq))
        ad("  - ", bs, ": ", paste(parts, collapse = ", "))
      }
    }
  }
  ad("")

  if (length(inf_notes)) {
    ad("## Inf handling")
    ad("Non-finite estimates were clamped to a terminal axis boundary ",
       "for finite scaling (never silently dropped):")
    for (nm in names(inf_notes)) {
      v <- inf_notes[[nm]]
      ad("- metric `", nm, "`: +Inf x", .cv_or(v["pos"], 0),
         ", -Inf x", .cv_or(v["neg"], 0))
    }
    ad("")
  }

  ad("## How to read the figures")
  ad("- The empirical fitted-cell mixture heatmap is the Q3 input ",
     "map; rows are empirical strata, fill is the empirical ",
     "fitted-cell mixture weight (default smoothing = `eb_corpus`, ",
     "support = `occupied`) that 65 samples synthetic rows under. ",
     "It is NOT spatial smoothing over the 36-cell grid.")
  ad("- The empirical-weighted synthetic rigor-variability plot ",
     "shows sampling variability (width90 = q95 - q05) of the ",
     "stratum-level median selected rigor across B empirical-",
     "weighted synthetic draws; lower is more stable. One line per ",
     "empirical stratum.")
  ad("- The empirical-bootstrap-vs-empirical-weighted-synthetic ",
     "core-metrics overlay contrasts empirical bootstrap uncertainty ",
     "(blue) with empirical-weighted synthetic uncertainty (purple) ",
     "at each stratum's observed n_outcomes, for rigor evidence, ",
     "bias evidence, and absolute attenuation.")
  ad("- The three axis-recovery heatmaps are profile-definition ",
     "diagnostics: they show P(observed band | target/DGM band) for ",
     "each axis and help interpret whether the fitted cell-",
     "assignment basis recovers the intended design axes.")
  ad("")
  ad("## Scope")
  if (isTRUE(dev_partial))
    ad("- The Q3 sampling that produced these figures was run with ",
       "`allow_partial = TRUE` on an incomplete simulation library; ",
       "every input row carries `dev_partial = TRUE` and figures are ",
       "DEV / PARTIAL only.")
  ad("- 2026-05 Q3 cull: the corpus + stratum agreement figures, the ",
     "mean/median-level Q3 size curves, the primary-rigor (p_*) ",
     "overlay, the 36x36 cell transition heatmap, the stratum ",
     "target-provenance heatmap, the support bars, and the ",
     "validation-status bar are all retired from the default Q3 ",
     "family. Validation/support information is surfaced in this ",
     "report as text rather than as separate PDFs.")
  ad("- 2026-05 Q3 terminology rename: the public Q3 section is ",
     "**empirical-weighted synthetic sampling**. Folder names, ",
     "figure names, and report names use that terminology; internal ",
     "mechanism nouns (`sim_validate_composition_inputs`, ",
     "`composition_id` row column, palette key ",
     "`.VIS_COLORS$resampling_source$synthetic_composition`) were ",
     "kept where churn outweighed clarity.")
  ad("- v4 vocabulary throughout (stratum, corpus, cell_slug, ",
     "target_cell, observed_cell). The set of plot families this ",
     "layer supports vs the legacy families that cannot be rebuilt ",
     "from current outputs is recorded in ",
     if (!is.na(deferred_path)) sprintf("`%s`.", basename(deferred_path))
     else "`empirical_weighted_synthetic_visuals_deferred.csv`.")
  writeLines(L, path)
  invisible(path)
}

# --- orchestrator (the only writer; runs only when called) ---------------

#' Build the Q3 empirical-weighted synthetic sampling visuals.
#'
#' Reads from the stable layout by default:
#'   simulation/results/empirical_weighted_synthetic/        (Q3 primaries)
#'   simulation/results/empirical_weighted_synthetic/detail/ (Q3 detail)
#'   simulation/results/agreement/                           (agreement tables)
#' Override any of those via the *_dir arguments. Writes vector-PDF
#' figures + the deferred-family ledger + a short markdown report into
#' `figure_dir`. The ONLY function here that writes, and only when
#' explicitly invoked with `write = TRUE` (default).
#'
#' Does NOT recompute Q3 outputs or agreement. If a required input is
#' missing, the corresponding figure is simply skipped (and noted as
#' missing in the report). To rebuild the inputs, run
#' `sim_run_empirical_weighted_synthetic()` /
#' `sim_run_empirical_weighted_size_curve()` (via
#' `sim_run_synthetic_resampling()`) and
#' `sim_run_empirical_synthetic_agreement()` first.
#'
#' @return invisible list(figures, deferred, report, found, skipped,
#'   dev_partial, figure_dir).
sim_run_q3_visuals <- function(
    ews_dir            = .CV_EWS_DIR,
    ews_detail_dir     = .CV_EWS_DETAIL_DIR,
    agreement_dir      = .CV_AGREE_DIR,
    emp_resampling_dir = .CV_EMP_RESAMPLING_DIR,
    figure_dir         = .CV_FIG_EWS_DIR,
    legacy_fig_dir     = .CV_LEGACY_FIG_COMP_DIR,
    write              = TRUE,
    verbose            = TRUE) {
  .cv_need_ggplot()
  inp <- cv_read_inputs(ews_dir        = ews_dir,
                        ews_detail_dir = ews_detail_dir,
                        agreement_dir  = agreement_dir)
  d <- inp$data

  # Infer DEV/PARTIAL from any input that carries dev_partial.
  dev_partial <- NA
  for (k in names(d)) if (!is.null(d[[k]]) &&
                          "dev_partial" %in% names(d[[k]])) {
    vv <- unique(d[[k]]$dev_partial)
    dev_partial <- any(vv %in% c(TRUE, "TRUE"))
    break
  }

  if (isTRUE(write) && !dir.exists(figure_dir))
    dir.create(figure_dir, recursive = TRUE)
  fp <- function(f) file.path(figure_dir, f)

  # Retired Q3 PDFs (2026-05 Q3 cull + 2026-05 terminology rename).
  # Includes the two pre-rename filenames so stale copies are scrubbed
  # when an operator upgrades. Cleaned from BOTH the active figure
  # folder and the legacy figures/composition/ folder so neither can
  # drift forward.
  .CV_Q3_RETIRED_PDFS <- c(
    # 2026-05 Q3 cull
    "synthetic_composition_rigor_size_curve.pdf",
    "synthetic_composition_size_curve_primary_rigor.pdf",
    "empirical_bootstrap_vs_synthetic_composition_primary_rigor.pdf",
    "empirical_vs_synthetic_corpus_agreement_primary_rigor.pdf",
    "empirical_vs_synthetic_stratum_agreement_primary_rigor.pdf",
    "synthetic_target_observed_transition_heatmap.pdf",
    "stratum_target_provenance_heatmap.pdf",
    "synthetic_support_diagnostics_bars.pdf",
    "composition_validation_status.pdf",
    # 2026-05 terminology rename: pre-rename names of the two active
    # Q3 primary/bridge figures
    "synthetic_composition_rigor_variability_by_stratum.pdf",
    "empirical_bootstrap_vs_synthetic_composition_core_metrics.pdf")
  .scrub_retired <- function(dir_path) {
    if (!nzchar(dir_path) || !dir.exists(dir_path)) return(invisible())
    for (.rp in .CV_Q3_RETIRED_PDFS) {
      .rpath <- file.path(dir_path, .rp)
      if (file.exists(.rpath)) {
        file.remove(.rpath)
        if (isTRUE(verbose))
          message(sprintf("  removed retired %s", .rpath))
      }
    }
  }
  if (isTRUE(write)) {
    .scrub_retired(figure_dir)
    .scrub_retired(legacy_fig_dir)
  }

  figs <- character(0); skipped <- character(0)
  do <- function(cond, fn) {
    if (!isTRUE(cond)) return(invisible(NULL))
    tryCatch(fn(), error = function(e) {
      skipped <<- c(skipped, conditionMessage(e))
      if (isTRUE(verbose)) message("  [skip] ", conditionMessage(e))
    })
  }

  # EWS size-curve summary + empirical intervals are inputs for the
  # two Q3 primaries (rigor variability + core-metric overlay).
  # Loaded once here so a missing CSV produces one clear skip per
  # figure instead of repeated reads.
  csc <- .cv_read_ews_size_curve(ews_dir = ews_dir)
  emp_iv <- .cv_read_emp_resampling_inputs(
    emp_resampling_dir = emp_resampling_dir)

  if (isTRUE(write)) {
    # Q3 primary / bridge figures.
    do(!is.null(d$weights), function()
      figs <<- c(figs, cv_plot_weight_heatmap(d$weights,
        fp("empirical_stratum_cell_weights_heatmap.pdf"), verbose)))
    do(!is.null(csc$summary), function()
      figs <<- c(figs,
        cv_plot_empirical_weighted_rigor_variability_by_stratum(
          csc$summary,
          fp("empirical_weighted_synthetic_rigor_variability_by_stratum.pdf"),
          metric = "median_log10BF_rigor", n_max = 50L,
          verbose = verbose)))
    do(!is.null(emp_iv$intervals) && !is.null(csc$summary), function()
      figs <<- c(figs,
        cv_plot_emp_bootstrap_vs_empirical_weighted_core_metrics(
          emp_iv$intervals, csc$summary,
          fp("empirical_bootstrap_vs_empirical_weighted_synthetic_core_metrics.pdf"),
          verbose = verbose)))

    # Profile-definition diagnostics (kept as active diagnostics, not
    # Q3 outcome figures).
    for (ax in c("effect", "heterogeneity", "bias")) {
      lab <- switch(ax, effect = "effect", heterogeneity = "het",
                    bias = "bias")
      local({
        a <- ax; l <- lab
        do(!is.null(d$axis_trans), function()
          figs <<- c(figs, cv_plot_axis_transition(d$axis_trans, a,
            fp(sprintf("synthetic_axis_transition_%s_heatmap.pdf", l)),
            verbose)))
      })
    }
    # Changelog (2026-05):
    #   * Q3 cull: the old composition agreement figures, the multi-
    #     primary-rigor / mean-level composition size curves, the
    #     36x36 cell transition heatmap, the stratum target-provenance
    #     heatmap, the support bars, and the validation-status bar
    #     were retired from the default Q3 family.
    #   * Q3 terminology rename: the two active primary/bridge files
    #     were renamed from synthetic_composition_* to
    #     empirical_weighted_synthetic_* alongside the section name.
    #     Stale copies are scrubbed from both the active Q3 figure
    #     folder and the legacy figures/composition/ folder.
  }

  deferred_path <- NULL; report_path <- NULL
  if (isTRUE(write)) {
    deferred_path <- cv_write_deferred(
      fp("empirical_weighted_synthetic_visuals_deferred.csv"))
    report_path <- cv_write_visuals_report(
      fp("empirical_weighted_synthetic_visuals_report.md"), inp, figs,
      inf_notes = list(), dev_partial = dev_partial,
      fig_dir = figure_dir, deferred_path = deferred_path,
      validation = d$validation,
      support    = d$support)
  }

  if (isTRUE(verbose))
    message(sprintf("[cv] done: %d figures, %d skipped%s",
                    length(figs), length(skipped),
                    if (length(figs))
                      sprintf(" -> %s", figure_dir) else ""))

  invisible(list(figures = figs, deferred = deferred_path,
                 report = report_path, found = inp$found,
                 skipped = skipped, dev_partial = dev_partial,
                 figure_dir = figure_dir))
}

#' Deprecated alias for sim_run_q3_visuals().
#'
#' Kept only so external code that calls the previous orchestrator
#' name keeps working through one cycle. Emits a single soft warning
#' and forwards all arguments. New code MUST use sim_run_q3_visuals().
sim_run_composition_visuals <- function(...) {
  warning("sim_run_composition_visuals() is deprecated; use ",
          "sim_run_q3_visuals() (same arguments, new *_dir names). ",
          "The Q3 section was renamed to empirical-weighted synthetic ",
          "sampling in 2026-05.", call. = FALSE)
  sim_run_q3_visuals(...)
}

#' Deprecated alias for sim_run_q3_visuals() (legacy cv_* prefix).
#'
#' Kept only so external code that calls the original `cv_*`
#' orchestrator name keeps working through one cycle. Emits a single
#' soft warning and forwards all arguments. New code MUST use
#' sim_run_q3_visuals().
cv_run_composition_visuals <- function(...) {
  warning("cv_run_composition_visuals() is deprecated; use ",
          "sim_run_q3_visuals() (same arguments, new *_dir names). ",
          "The Q3 section was renamed to empirical-weighted synthetic ",
          "sampling in 2026-05.", call. = FALSE)
  sim_run_q3_visuals(...)
}

# ========================================================================
# Q1: cell behavior visuals
# ========================================================================

# Read inputs for Q1 (cell behavior). Returns list(rigor, size_summary,
# effect_draws, dirs, found).
.cv_read_cell_behavior_inputs <- function(
    cell_behavior_dir = .CV_CELL_BEHAVIOR_DIR,
    results_dir       = .CV_RESULTS_DIR) {
  rd <- function(p) {
    if (!file.exists(p)) return(NULL)
    utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE)
  }
  p_rigor  <- file.path(results_dir, "cell_diagnostics_rigor.csv")
  p_summ   <- file.path(cell_behavior_dir,
                        "synthetic_cell_size_curve_summary.csv")
  p_draws  <- file.path(cell_behavior_dir,
                        "cell_behavior_effect_draws.csv")
  list(
    rigor        = rd(p_rigor),
    size_summary = rd(p_summ),
    effect_draws = rd(p_draws),
    paths        = list(rigor        = p_rigor,
                        size_summary = p_summ,
                        effect_draws = p_draws),
    found        = c(rigor        = file.exists(p_rigor),
                     size_summary = file.exists(p_summ),
                     effect_draws = file.exists(p_draws)),
    dirs         = list(cell_behavior = cell_behavior_dir,
                        results = results_dir))
}

#' Q1 primary: known-cell rigor atlas (median selected rigor per cell).
#'
#' Manuscript-facing Q1 rigor figure. 36-cell layout (effect x
#' heterogeneity, faceted by bias band). Fill = median selected rigor
#' (log10 BF) at each cell. Cells with n_fit = 0 render as white tiles
#' with NA labels so reviewers can see coverage gaps.
cv_plot_cell_rigor_atlas <- function(rigor_df, path, verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  d <- rigor_df
  needed <- c("cell_slug", "median_log10BF_rigor")
  miss <- setdiff(needed, names(d))
  if (length(miss))
    stop("cv_plot_cell_rigor_atlas: rigor_df missing column(s): ",
         paste(miss, collapse = ", "))
  sp <- .cv_split_slug(d$cell_slug)
  d$effect_slug <- factor(sp$effect_slug, levels = .CV_EFFECT)
  d$het_slug    <- factor(sp$heterogeneity_slug, levels = .CV_HET)
  d$bias_slug   <- factor(sp$bias_slug, levels = .CV_BIAS)
  d$rigor <- suppressWarnings(as.numeric(d$median_log10BF_rigor))

  # Diverging fill centered at 0 keeps the rigor sign legible: positive
  # = clean resolved evidence supported, negative = clean resolved
  # evidence disfavored (the better-supported branch lost support
  # relative to its complement; not "rigor favors no_effect").
  finv <- d$rigor[is.finite(d$rigor)]
  lim <- if (length(finv)) max(abs(finv), na.rm = TRUE) else 1
  if (!is.finite(lim) || lim == 0) lim <- 1

  p <- g$ggplot(d, g$aes(x = .data$het_slug, y = .data$effect_slug)) +
    g$geom_tile(g$aes(fill = .data$rigor), color = "gray85",
                linewidth = 0.25) +
    g$geom_text(g$aes(label = ifelse(is.na(.data$rigor), "NA",
                                     sprintf("%.2f", .data$rigor))),
                size = .CV_HEATMAP_LABEL_SIZE, color = "gray15") +
    g$facet_wrap(~ bias_slug, nrow = 1L) +
    # Diverging fill: muted red (negative) -> cream (zero) -> muted
    # sage (positive). Avoids saturated green; pulled from
    # .VIS_COLORS$heat.
    g$scale_fill_gradient2(
      low = .VIS_COLORS$heat$diverging_neg,
      mid = .VIS_COLORS$heat$diverging_zero,
      high = .VIS_COLORS$heat$diverging_pos,
      midpoint = 0, limits = c(-lim, lim),
      name = "median log10 BF rigor", na.value = "white") +
    g$labs(
      title = "Known-cell rigor atlas",
      subtitle = paste0("Fill = median selected rigor (log10 BF). ",
                        "Positive = clean resolved evidence supported; ",
                        "negative = clean resolved evidence disfavored."),
      x = "heterogeneity band", y = "effect band",
      caption = .cv_fit_library_note(rigor_df)) +
    .cv_theme()
  # Caption already carries .cv_fit_library_note(rigor_df) ("Synthetic
  # fit library: n_fit = ... per cell."); suppress the matching n_fit
  # token from the compact metadata line to avoid a double-print.
  .cv_save(p, path, width = 13, height = 6.5, verbose = verbose,
           meta_df = rigor_df,
           meta_source = "cell_diagnostics_rigor.csv",
           meta_suppress = "n_fit")
}

#' Q1 primary: known-cell attenuation / effect recovery atlas.
#'
#' Manuscript-facing Q1 attenuation figure. 36-cell layout (effect x
#' heterogeneity, faceted by bias band). Each mini-panel shows the
#' distribution of matched-baseline (mu_RE) and bias-corrected (mu_BC)
#' effect estimates as paired boxplots, with a horizontal line marking
#' the true effect (mu_true). No tracing / before-after lines -- each
#' cell shows distributions, not paired traces.
#' @param y_limits "auto" (default) computes a global y-range from
#'   `y_quantile` and pads it with `y_pad`; "none" lets ggplot pick
#'   automatically; "fixed" passes through `y_fixed` (a numeric c(lo,
#'   hi) pair).
#' @param y_quantile two-element numeric quantile range used when
#'   `y_limits = "auto"` (default c(0.01, 0.99) clips the extreme
#'   tails so true-effect lines stay visible without being squeezed).
#' @param y_pad fractional pad added on each side of the auto y-range.
#' @param y_fixed optional c(lo, hi) used when `y_limits = "fixed"`.
cv_plot_cell_attenuation_atlas <- function(effect_draws, path,
                                           y_limits = c("auto", "fixed",
                                                        "none"),
                                           y_quantile = c(0.01, 0.99),
                                           y_pad = 0.05,
                                           y_fixed = NULL,
                                           verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  y_limits <- match.arg(y_limits)
  d <- effect_draws
  needed <- c("cell_slug", "effect_slug", "heterogeneity_slug",
              "bias_slug", "mu_true", "mu_RE", "mu_BC")
  miss <- setdiff(needed, names(d))
  if (length(miss))
    stop("cv_plot_cell_attenuation_atlas: effect_draws missing ",
         "column(s): ", paste(miss, collapse = ", "))
  for (cl in c("mu_true", "mu_RE", "mu_BC"))
    d[[cl]] <- suppressWarnings(as.numeric(d[[cl]]))
  # Reshape to long form: one row per (cell, outcome, method).
  re <- data.frame(cell_slug = d$cell_slug, effect_slug = d$effect_slug,
                   heterogeneity_slug = d$heterogeneity_slug,
                   bias_slug = d$bias_slug,
                   mu_true = d$mu_true,
                   method  = "Baseline",
                   estimate = d$mu_RE, stringsAsFactors = FALSE)
  bc <- data.frame(cell_slug = d$cell_slug, effect_slug = d$effect_slug,
                   heterogeneity_slug = d$heterogeneity_slug,
                   bias_slug = d$bias_slug,
                   mu_true = d$mu_true,
                   method  = "RoBMA-PSMA",
                   estimate = d$mu_BC, stringsAsFactors = FALSE)
  long <- rbind(re, bc)
  long <- long[is.finite(long$estimate), , drop = FALSE]
  long$effect_slug <- factor(long$effect_slug, levels = .CV_EFFECT)
  long$het_slug    <- factor(long$heterogeneity_slug, levels = .CV_HET)
  long$bias_slug   <- factor(long$bias_slug, levels = .CV_BIAS)
  long$method      <- factor(long$method,
                              levels = c("Baseline", "RoBMA-PSMA"))
  # mu_true is constant within each (effect_slug) row by design; the
  # geom_hline layer uses one truth value per cell.
  truth <- unique(d[, c("cell_slug", "effect_slug",
                        "heterogeneity_slug", "bias_slug",
                        "mu_true")])
  truth$effect_slug <- factor(truth$effect_slug, levels = .CV_EFFECT)
  truth$het_slug    <- factor(truth$heterogeneity_slug, levels = .CV_HET)
  truth$bias_slug   <- factor(truth$bias_slug, levels = .CV_BIAS)

  # Resolve global y-limits.
  ylim <- NULL
  if (y_limits == "auto") {
    qrng <- stats::quantile(long$estimate, probs = y_quantile,
                            names = FALSE, na.rm = TRUE,
                            type = 7)
    # Include the full mu_true range so design truth is never clipped.
    tr <- range(truth$mu_true, na.rm = TRUE)
    lo <- min(qrng[1], tr[1])
    hi <- max(qrng[2], tr[2])
    span <- hi - lo
    if (!is.finite(span) || span == 0) span <- max(abs(c(lo, hi)), 1)
    ylim <- c(lo - y_pad * span, hi + y_pad * span)
  } else if (y_limits == "fixed") {
    if (is.null(y_fixed) || length(y_fixed) != 2L ||
        !is.numeric(y_fixed))
      stop("cv_plot_cell_attenuation_atlas: y_limits='fixed' requires ",
           "y_fixed = c(lo, hi).")
    ylim <- as.numeric(y_fixed)
  }

  p <- g$ggplot(long, g$aes(x = .data$method, y = .data$estimate,
                            fill = .data$method)) +
    g$geom_hline(data = truth,
                 g$aes(yintercept = .data$mu_true),
                 color = "gray35", linewidth = 0.4,
                 linetype = "33") +
    g$geom_boxplot(outlier.size = 0.2, outlier.alpha = 0.25,
                   linewidth = 0.3, width = 0.6,
                   color = "gray25") +
    # Portrait orientation (2026-05 polish): rows = bias x het (9),
    # cols = effect (4), so the figure reads as a tall full-page atlas.
    g$facet_grid(bias_slug + het_slug ~ effect_slug,
                  switch = "y") +
    # Method palette: Baseline RE = BLUE, RoBMA-PSMA = RED. This
    # mapping is load-bearing -- every figure that names these methods
    # uses the same hex pair (.VIS_COLORS$method, single source of
    # truth in scripts/00_utils.R).
    g$scale_fill_manual(values = c(
      Baseline      = unname(.VIS_COLORS$method[["baseline_re"]]),
      `RoBMA-PSMA`  = unname(.VIS_COLORS$method[["robma_psma"]])),
      guide = "none") +
    g$labs(
      title = "Known-cell attenuation / effect recovery atlas",
      subtitle = paste0(
        "Per-cell boxplots of baseline vs bias-corrected fitted ",
        "effects;\n",
        "horizontal dashed line = true effect."),
      x = NULL, y = "fitted effect estimate (mu)",
      caption = paste(c("Distributions only (no paired traces); shared y-axis.",
                        .cv_fit_library_note(effect_draws)),
                       collapse = " ")) +
    .cv_theme() +
    g$theme(strip.text.x = g$element_text(size = .CV_THEME_BASE_SIZE - 2),
            strip.text.y = g$element_text(size = .CV_THEME_BASE_SIZE - 3,
                                          angle = 0),
            axis.text.x  = g$element_text(size = .CV_AXIS_TEXT_SMALL,
                                          angle = 35, hjust = 1, vjust = 1))
  if (!is.null(ylim))
    p <- p + g$coord_cartesian(ylim = ylim)
  # Caption already carries .cv_fit_library_note(effect_draws); suppress
  # the matching n_fit token from the metadata line.
  .cv_save(p, path, width = 11, height = 13.5, verbose = verbose,
           meta_df = effect_draws,
           meta_source = "cell_behavior_effect_draws.csv",
           meta_suppress = "n_fit")
}

#' Q1 primary: known-cell rigor VARIABILITY vs n, split by effect band.
#'
#' Y-axis = `width90 = q95 - q05` of the stratum-level median selected
#' rigor across B synthetic resamples (sampling variability of the
#' stratum-level summary; NOT posterior uncertainty, NOT MCSE). Lower
#' width is more stable. One line per cell, faceted by effect band.
#'
#' @param size_summary `synthetic_cell_size_curve_summary.csv` data.
#' @param n_max Cap on `n_outcomes_target` (default 50).
#' @param metric Metric (default `median_log10BF_rigor`); only
#'   continuous metrics are allowed.
#' @param ref_widths Horizontal reference widths (default
#'   c(1.0, 0.5, 0.25)).
cv_plot_cell_rigor_variability_by_effect <- function(
    size_summary, path,
    n_max      = 50L,
    metric     = "median_log10BF_rigor",
    ref_widths = c(1.0, 0.5, 0.25),
    verbose    = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  if (.cv_metric_class(metric) != "continuous")
    stop("cv_plot_cell_rigor_variability_by_effect: metric='", metric,
         "' is a rate (p_*) metric; use ",
         "cv_plot_cell_rate_variability_by_effect() for rate metrics.")
  d <- size_summary
  d <- d[d$metric == metric, , drop = FALSE]
  d$n_outcomes_target <- suppressWarnings(as.numeric(d$n_outcomes_target))
  d <- d[is.finite(d$n_outcomes_target) &
         d$n_outcomes_target <= as.numeric(n_max), , drop = FALSE]
  if (!nrow(d))
    stop("cv_plot_cell_rigor_variability_by_effect: no rows for ",
         "metric='", metric, "', n_max=", n_max, ".")
  d <- .cv_width_cols(d)
  d <- .cv_cell_design_cols(d)

  bias_cols <- c(
    clean    = unname(.VIS_COLORS$bias_burden[["clean"]]),
    modbias  = unname(.VIS_COLORS$bias_burden[["modbias"]]),
    highbias = unname(.VIS_COLORS$bias_burden[["highbias"]]))
  metric_label <- .cv_metric_label(metric)

  p <- g$ggplot(d, g$aes(x = .data$n_outcomes_target,
                         y = .data$width90,
                         group = .data$cell_slug,
                         color = .data$bias_slug,
                         linetype = .data$het_slug)) +
    g$geom_line(linewidth = 0.55, alpha = 0.9)
  if (length(ref_widths))
    p <- p + g$geom_hline(yintercept = as.numeric(ref_widths),
                          color = "gray55", linewidth = 0.25,
                          linetype = "33")
  p <- p +
    g$facet_wrap(~ effect_slug, ncol = 2L) +
    g$scale_color_manual(values = bias_cols, name = "bias band") +
    g$scale_linetype_manual(
      values = c(lowhet = "solid", midhet = "22", highhet = "44"),
      name = "heterogeneity band") +
    g$labs(
      title = "Known-cell rigor variability by effect size",
      subtitle = paste0(
        "Y-axis is the 90% interval width (q95-q05) of the ",
        "stratum-level median ", metric_label,
        " across B synthetic resamples. Lower is more stable."),
      x = "n_outcomes (synthetic resample size per cell)",
      y = sprintf("width90(%s) = q95 - q05", metric_label),
      caption = paste(
        c(.cv_resampling_note(d), .cv_cell_behavior_warning(d)),
        collapse = " ")) +
    .cv_theme() +
    g$guides(color = g$guide_legend(order = 1L),
             linetype = g$guide_legend(order = 2L))
  # Caption already carries .cv_resampling_note(d) ("Resampling: B =
  # ...; n_outcomes = ..."); suppress the matching B token from the
  # metadata line to avoid a double-print.
  .cv_save(p, path, width = 12, height = 8, verbose = verbose,
           meta_df = d,
           meta_source = "synthetic_cell_size_curve_summary.csv",
           meta_suppress = "B")
}

#' Q1 primary support: minimum-viable-n table for a continuous metric.
#'
#' Computes, for each cell and each threshold, the smallest
#' `n_outcomes_target` at which `width90 = q95 - q05` is at or below
#' the threshold. Cells that never meet the threshold within the
#' available grid are marked with `min_n = NA` and
#' `meets_within_grid = FALSE`. Writes (only) the requested path.
#'
#' @return invisible data.frame with one row per (cell_slug,
#'   threshold).
cv_write_cell_rigor_viability_table <- function(
    size_summary, path,
    thresholds = c(1.0, 0.5, 0.25),
    metric     = "median_log10BF_rigor",
    verbose    = TRUE) {
  if (.cv_metric_class(metric) != "continuous")
    stop("cv_write_cell_rigor_viability_table: metric='", metric,
         "' is a rate metric; use width90 only on continuous metrics.")
  d <- size_summary
  d <- d[d$metric == metric, , drop = FALSE]
  if (!nrow(d))
    stop("cv_write_cell_rigor_viability_table: no rows for metric='",
         metric, "'.")
  d$n_outcomes_target <- suppressWarnings(as.numeric(d$n_outcomes_target))
  d <- .cv_width_cols(d)
  n_grid_max <- max(d$n_outcomes_target, na.rm = TRUE)
  cells <- sort(unique(d$cell_slug))
  out <- list()
  for (cs in cells) {
    sub <- d[d$cell_slug == cs, , drop = FALSE]
    sub <- sub[order(sub$n_outcomes_target), ]
    for (th in as.numeric(thresholds)) {
      meets <- is.finite(sub$width90) & sub$width90 <= th
      if (any(meets)) {
        n_hit <- sub$n_outcomes_target[which(meets)[1]]
        w_hit <- sub$width90[which(meets)[1]]
        meets_within <- TRUE
      } else {
        n_hit <- NA_real_
        w_hit <- if (any(is.finite(sub$width90)))
          min(sub$width90, na.rm = TRUE) else NA_real_
        meets_within <- FALSE
      }
      out[[length(out) + 1L]] <- data.frame(
        cell_slug          = cs,
        metric             = metric,
        threshold_width90  = th,
        min_n              = as.integer(n_hit),
        width90_at_min_n   = w_hit,
        meets_within_grid  = meets_within,
        n_grid_max         = as.integer(n_grid_max),
        n_pool             = if ("n_pool" %in% names(sub))
          suppressWarnings(as.integer(sub$n_pool[1])) else NA_integer_,
        B                  = if ("B" %in% names(sub))
          suppressWarnings(as.integer(sub$B[1])) else NA_integer_,
        dev_partial        = if ("dev_partial" %in% names(sub))
          isTRUE(sub$dev_partial[1] %in% c(TRUE, "TRUE")) else NA,
        stringsAsFactors   = FALSE)
    }
  }
  tbl <- do.call(rbind, out)
  utils::write.csv(tbl, path, row.names = FALSE)
  if (isTRUE(verbose)) message(sprintf("  wrote %s", path))
  invisible(tbl)
}

#' Q1 primary: minimum-viable-n heatmap (full36, faceted by threshold).
#'
#' Reads the viability table written by
#' [cv_write_cell_rigor_viability_table()] and renders a full36 heatmap:
#' rows = effect band, columns = heterogeneity band, fill = minimum
#' viable `n_outcomes_target`, faceted by (bias_slug, threshold). Cells
#' that never meet the threshold within the available grid render as
#' a distinct color with an explicit ">N" label so reviewers can see
#' the failures.
cv_plot_cell_rigor_viability_min_n <- function(
    viability_tbl, path,
    size_summary = NULL,
    verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  d <- viability_tbl
  d <- .cv_cell_design_cols(d)
  d$threshold_label <- factor(
    sprintf("width90 <= %.2f", as.numeric(d$threshold_width90)),
    levels = sprintf("width90 <= %.2f",
                     sort(unique(as.numeric(d$threshold_width90)),
                          decreasing = TRUE)))
  d$is_miss <- !isTRUE(all(d$meets_within_grid)) &
                !d$meets_within_grid
  d$min_n_plot <- ifelse(d$meets_within_grid,
                         as.numeric(d$min_n), NA_real_)
  n_grid_max <- max(suppressWarnings(as.integer(d$n_grid_max)),
                    na.rm = TRUE)
  d$label <- ifelse(d$meets_within_grid,
                    sprintf("%d", as.integer(d$min_n)),
                    sprintf(">%d", n_grid_max))
  p <- g$ggplot(d, g$aes(x = .data$het_slug, y = .data$effect_slug)) +
    g$geom_tile(g$aes(fill = .data$min_n_plot),
                color = "gray85", linewidth = 0.25) +
    g$geom_tile(data = d[!d$meets_within_grid, , drop = FALSE],
                fill = .CV_FAIL, alpha = 0.32,
                color = "gray85", linewidth = 0.25) +
    g$geom_text(g$aes(label = .data$label),
                size = .CV_HEATMAP_LABEL_SIZE, color = "gray15") +
    g$facet_grid(threshold_label ~ bias_slug) +
    g$scale_fill_gradient(low = .CV_HEAT_LOW, high = .CV_HEAT_HIGH,
                          name = "min viable n",
                          na.value = NA, trans = "identity") +
    g$labs(
      title = "Minimum viable n_outcomes per cell (rigor width90)",
      subtitle = paste0(
        "Each tile is the smallest n at which width90 = q95-q05 of ",
        "the stratum-level median selected rigor falls at or below ",
        "the row's threshold; tinted red = never meets within ",
        "n <= ", n_grid_max, "."),
      x = "heterogeneity band", y = "effect band",
      caption = paste0(
        "Viability is threshold-dependent; treat as a design ",
        "diagnostic. ",
        .cv_cell_behavior_warning(d))) +
    .cv_theme() +
    g$theme(strip.text.y = g$element_text(angle = 0,
                                           size = .CV_THEME_BASE_SIZE - 3))
  # Derived figure: inherit B + the full n_outcomes grid from the
  # parent size-curve summary when available; the viability table
  # itself only carries n_grid_max. Source string lists both files
  # ("parent (derived: viability)") so a reviewer can find either.
  parent_df <- if (!is.null(size_summary) && is.data.frame(size_summary))
                 size_summary else viability_tbl
  n_grid_extra <- if (!is.null(size_summary) &&
                      "n_outcomes_target" %in% names(size_summary)) {
    g0 <- sort(unique(suppressWarnings(as.integer(
      size_summary$n_outcomes_target))))
    g0 <- g0[is.finite(g0) & g0 > 0L]
    if (length(g0)) list(n_outcomes = .cv_compact_int_grid(g0))
    else list()
  } else list()
  .cv_save(p, path, width = 12, height = 8, verbose = verbose,
           meta_df = parent_df,
           meta_source = paste0(
             "synthetic_cell_size_curve_summary.csv ",
             "(derived: synthetic_cell_rigor_viability_min_n.csv)"),
           meta_extras = n_grid_extra)
}

#' Q1 diagnostic: rigor width90 heatmap snapshots at selected n_outcomes.
#'
#' Full36 heatmap: rows = effect band, columns = heterogeneity band,
#' fill = `width90 = q95 - q05` of stratum-level median selected rigor,
#' faceted by (bias_slug, n_outcomes_target). Use selected snapshot n
#' values (default c(5, 10, 20, 30, 50)).
cv_plot_cell_rigor_width_heatmap_by_n <- function(
    size_summary, path,
    n_snapshots = c(5L, 10L, 20L, 30L, 50L),
    metric      = "median_log10BF_rigor",
    verbose     = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  if (.cv_metric_class(metric) != "continuous")
    stop("cv_plot_cell_rigor_width_heatmap_by_n: metric='", metric,
         "' is a rate metric; width90 here is defined for continuous ",
         "metrics only.")
  d <- size_summary
  d <- d[d$metric == metric, , drop = FALSE]
  d$n_outcomes_target <- suppressWarnings(as.integer(d$n_outcomes_target))
  snaps <- sort(intersect(as.integer(n_snapshots),
                           unique(d$n_outcomes_target)))
  if (!length(snaps))
    stop("cv_plot_cell_rigor_width_heatmap_by_n: no requested ",
         "n_snapshots present in the summary; available: ",
         paste(sort(unique(d$n_outcomes_target)), collapse = ","))
  d <- d[d$n_outcomes_target %in% snaps, , drop = FALSE]
  d <- .cv_width_cols(d)
  d <- .cv_cell_design_cols(d)
  d$n_label <- factor(sprintf("n = %d", d$n_outcomes_target),
                       levels = sprintf("n = %d", snaps))
  metric_label <- .cv_metric_label(metric)

  p <- g$ggplot(d, g$aes(x = .data$het_slug, y = .data$effect_slug)) +
    g$geom_tile(g$aes(fill = .data$width90), color = "gray85",
                linewidth = 0.25) +
    g$geom_text(g$aes(label = ifelse(is.na(.data$width90), "NA",
                                     sprintf("%.2f", .data$width90))),
                size = .CV_HEATMAP_LABEL_SIZE - 0.4, color = "gray15") +
    g$facet_grid(n_label ~ bias_slug) +
    g$scale_fill_gradient(low = .CV_HEAT_LOW, high = .CV_HEAT_HIGH,
                          name = sprintf("width90(%s)", metric_label),
                          na.value = "white") +
    g$labs(
      title = sprintf("Per-cell rigor width90 snapshots (n in {%s})",
                      paste(snaps, collapse = ", ")),
      subtitle = paste0(
        "Fill = q95 - q05 of stratum-level ", metric_label,
        " across B synthetic resamples; lower = more stable."),
      x = "heterogeneity band", y = "effect band",
      caption = .cv_cell_behavior_warning(d)) +
    .cv_theme() +
    g$theme(strip.text.y = g$element_text(angle = 0,
                                           size = .CV_THEME_BASE_SIZE - 3))
  .cv_save(p, path, width = 12, height = 9, verbose = verbose,
           meta_df = size_summary,
           meta_source = "synthetic_cell_size_curve_summary.csv",
           meta_extras = list(metric = metric))
}

#' Internal: width90-by-effect line family for a single continuous
#' metric.
#'
#' Shared engine behind the Q1 secondary bias-evidence and attenuation
#' variability figures. Mirrors the visual grammar of
#' [cv_plot_cell_rigor_variability_by_effect()] (x = n_outcomes_target,
#' y = width90, facet = effect band, color = bias band, linetype =
#' heterogeneity band, n_max default 50) but omits the rigor-specific
#' viability reference lines because the threshold semantics differ
#' for non-rigor components. NOT public.
.cv_plot_cell_component_variability_by_effect <- function(
    size_summary, path,
    metric, title, y_label, caption_role,
    n_max   = 50L,
    verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  if (.cv_metric_class(metric) != "continuous")
    stop(".cv_plot_cell_component_variability_by_effect: metric='",
         metric, "' is a rate (p_*) metric; this engine plots ",
         "width90 of a continuous component only.")
  d <- size_summary
  d <- d[d$metric == metric, , drop = FALSE]
  d$n_outcomes_target <- suppressWarnings(as.numeric(d$n_outcomes_target))
  d <- d[is.finite(d$n_outcomes_target) &
         d$n_outcomes_target <= as.numeric(n_max), , drop = FALSE]
  if (!nrow(d))
    stop(".cv_plot_cell_component_variability_by_effect: no rows for ",
         "metric='", metric, "', n_max=", n_max,
         ". If this is a freshly added metric (e.g. ",
         "median_attenuation_abs), rerun ",
         "sim_run_synthetic_resampling() so the summary CSV picks it ",
         "up.")
  d <- .cv_width_cols(d)
  d <- .cv_cell_design_cols(d)

  bias_cols <- c(
    clean    = unname(.VIS_COLORS$bias_burden[["clean"]]),
    modbias  = unname(.VIS_COLORS$bias_burden[["modbias"]]),
    highbias = unname(.VIS_COLORS$bias_burden[["highbias"]]))

  p <- g$ggplot(d, g$aes(x = .data$n_outcomes_target,
                         y = .data$width90,
                         group = .data$cell_slug,
                         color = .data$bias_slug,
                         linetype = .data$het_slug)) +
    g$geom_line(linewidth = 0.55, alpha = 0.9) +
    g$facet_wrap(~ effect_slug, ncol = 2L) +
    g$scale_color_manual(values = bias_cols, name = "bias band") +
    g$scale_linetype_manual(
      values = c(lowhet = "solid", midhet = "22", highhet = "44"),
      name = "heterogeneity band") +
    g$labs(
      title = title,
      subtitle = paste0(
        "Y-axis is the 90% interval width (q95-q05) of the ",
        "stratum-level ", .cv_metric_label(metric),
        " across B synthetic resamples. Lower is more stable."),
      x = "n_outcomes (synthetic resample size per cell)",
      y = y_label,
      caption = paste(
        c(.cv_resampling_note(d), .cv_cell_behavior_warning(d)),
        collapse = " ")) +
    .cv_theme() +
    g$guides(color = g$guide_legend(order = 1L),
             linetype = g$guide_legend(order = 2L))
  # Caption already carries .cv_resampling_note(d); suppress the
  # matching B token from the metadata line.
  .cv_save(p, path, width = 12, height = 8, verbose = verbose,
           meta_df = d,
           meta_source = "synthetic_cell_size_curve_summary.csv",
           meta_extras = list(metric = metric),
           meta_suppress = "B")
}

#' Q1 secondary: known-cell bias-evidence variability vs n, by effect.
#'
#' Y-axis = `width90 = q95 - q05` of the stratum-level median bias
#' evidence (`median_log10BF_bias`) across B synthetic resamples.
#' Supports the primary rigor-variability claim by showing how stable
#' the bias-evidence component is at each n_outcomes; central-tendency
#' is intentionally not the question.
#'
#' @param size_summary `synthetic_cell_size_curve_summary.csv` data.
#' @param n_max Cap on `n_outcomes_target` (default 50).
cv_plot_cell_bias_evidence_variability_by_effect <- function(
    size_summary, path,
    n_max   = 50L,
    verbose = TRUE) {
  .cv_plot_cell_component_variability_by_effect(
    size_summary = size_summary,
    path         = path,
    metric       = "median_log10BF_bias",
    title        = "Known-cell bias-evidence variability by effect size",
    y_label      = "width90(Bias evidence) = q95 - q05",
    caption_role = paste0(
      "Component-stability companion to the rigor width90 figure. ",
      "Q1 secondary"),
    n_max        = n_max,
    verbose      = verbose)
}

#' Q1 secondary: known-cell attenuation variability vs n, by effect.
#'
#' Y-axis = `width90 = q95 - q05` of the stratum-level absolute
#' attenuation (`median_attenuation_abs`) across B synthetic
#' resamples. This is a component-stability diagnostic for effect
#' recovery; the viability thresholds used for selected rigor are not
#' reused here because the threshold semantics differ.
#'
#' Requires `synthetic_cell_size_curve_summary.csv` to contain rows
#' with `metric == "median_attenuation_abs"`. That column was added to
#' 65's component metric set in 2026-05; older summary CSVs will need
#' a 65 rerun.
#'
#' @param size_summary `synthetic_cell_size_curve_summary.csv` data.
#' @param n_max Cap on `n_outcomes_target` (default 50).
cv_plot_cell_attenuation_variability_by_effect <- function(
    size_summary, path,
    n_max   = 50L,
    verbose = TRUE) {
  .cv_plot_cell_component_variability_by_effect(
    size_summary = size_summary,
    path         = path,
    metric       = "median_attenuation_abs",
    title        = "Known-cell attenuation variability by effect size",
    y_label      = "width90(absolute attenuation) = q95 - q05",
    caption_role = paste0(
      "Component-stability diagnostic for effect recovery; does not ",
      "reuse rigor viability thresholds. Q1 secondary"),
    n_max        = n_max,
    verbose      = verbose)
}

#' Q1 orchestrator: cell-behavior figures.
#'
#' Reads cell_diagnostics_rigor.csv from `results_dir` and the synthetic
#' per-cell size-curve summary from `cell_behavior_dir`. Writes figures
#' into `figure_dir`. Missing inputs simply skip their figure.
sim_run_cell_behavior_visuals <- function(
    cell_behavior_dir = .CV_CELL_BEHAVIOR_DIR,
    results_dir       = .CV_RESULTS_DIR,
    figure_dir        = .CV_FIG_CELL_BEHAVIOR_DIR,
    write             = TRUE,
    verbose           = TRUE) {
  .cv_need_ggplot()
  inp <- .cv_read_cell_behavior_inputs(cell_behavior_dir = cell_behavior_dir,
                                       results_dir = results_dir)
  if (isTRUE(write) && !dir.exists(figure_dir))
    dir.create(figure_dir, recursive = TRUE)
  fp <- function(f) file.path(figure_dir, f)
  # Retired Q1 PDFs: five central-trend + convergence-error figures
  # removed in the 2026-05 cleanup pass, plus two more retired later
  # in 2026-05 (rate-variability companion + operating-characteristics
  # atlas). Cleared from the output folder on every run so stale files
  # cannot drift forward.
  .CV_Q1_RETIRED_PDFS <- c(
    "synthetic_cell_rigor_size_curve_by_effect.pdf",
    "synthetic_cell_rigor_convergence_error_by_effect.pdf",
    "synthetic_cell_threshold_rates_by_effect.pdf",
    "synthetic_cell_size_curve_primary_rigor.pdf",
    "synthetic_cell_size_curve_threshold_rates.pdf",
    "synthetic_cell_rate_variability_by_effect.pdf",
    "full36_cell_operating_characteristics_primary_rigor.pdf")
  if (isTRUE(write) && dir.exists(figure_dir)) {
    for (.rp in .CV_Q1_RETIRED_PDFS) {
      .rpath <- file.path(figure_dir, .rp)
      if (file.exists(.rpath)) {
        file.remove(.rpath)
        if (isTRUE(verbose))
          message(sprintf("  removed retired %s", .rpath))
      }
    }
  }
  figs <- character(0); skipped <- character(0)
  do <- function(cond, fn) {
    if (!isTRUE(cond)) return(invisible(NULL))
    tryCatch(fn(), error = function(e) {
      skipped <<- c(skipped, conditionMessage(e))
      if (isTRUE(verbose)) message("  [skip] ", conditionMessage(e))
    })
  }
  # Viability table is written alongside the figures so the heatmap
  # has data to read; the path is also exposed via the wrapper return
  # value for downstream consumers.
  viability_path <- NULL; viability_tbl <- NULL
  if (isTRUE(write)) {
    # Manuscript-facing Q1 primaries (rendered first, so they sit at
    # the top of the output folder listing).
    do(!is.null(inp$rigor), function()
      figs <<- c(figs, cv_plot_cell_rigor_atlas(inp$rigor,
        fp("cell_rigor_atlas.pdf"), verbose = verbose)))
    do(!is.null(inp$effect_draws), function()
      figs <<- c(figs, cv_plot_cell_attenuation_atlas(inp$effect_draws,
        fp("cell_attenuation_atlas.pdf"), verbose = verbose)))
    do(!is.null(inp$size_summary), function()
      figs <<- c(figs, cv_plot_cell_rigor_variability_by_effect(
        inp$size_summary,
        path = fp("synthetic_cell_rigor_variability_by_effect.pdf"),
        n_max = 50L, verbose = verbose)))
    # Viability table feeds the min-n heatmap. The table is written to
    # cell_behavior_dir (lives with the summary CSV) and the figure is
    # written to figure_dir.
    do(!is.null(inp$size_summary), function() {
      viability_path <<- file.path(cell_behavior_dir,
        "synthetic_cell_rigor_viability_min_n.csv")
      viability_tbl <<- cv_write_cell_rigor_viability_table(
        inp$size_summary, path = viability_path,
        thresholds = c(1.0, 0.5, 0.25), verbose = verbose)
      figs <<- c(figs, cv_plot_cell_rigor_viability_min_n(
        viability_tbl,
        path = fp("synthetic_cell_rigor_viability_min_n.pdf"),
        size_summary = inp$size_summary,
        verbose = verbose))
    })
    # Q1 secondary figures: width-snapshot heatmap, bias-evidence
    # width90, attenuation width90. The rate-variability plot and the
    # per-cell operating-characteristics atlas were retired in 2026-05
    # (see .CV_Q1_RETIRED_PDFS below for stale-PDF cleanup).
    do(!is.null(inp$size_summary), function()
      figs <<- c(figs, cv_plot_cell_rigor_width_heatmap_by_n(
        inp$size_summary,
        path = fp("synthetic_cell_rigor_width_heatmap_by_n.pdf"),
        verbose = verbose)))
    do(!is.null(inp$size_summary), function()
      figs <<- c(figs, cv_plot_cell_bias_evidence_variability_by_effect(
        inp$size_summary,
        path = fp("synthetic_cell_bias_evidence_variability_by_effect.pdf"),
        n_max = 50L, verbose = verbose)))
    do(!is.null(inp$size_summary), function()
      figs <<- c(figs, cv_plot_cell_attenuation_variability_by_effect(
        inp$size_summary,
        path = fp("synthetic_cell_attenuation_variability_by_effect.pdf"),
        n_max = 50L, verbose = verbose)))
    # Changelog (2026-05): the central-trend + convergence-error Q1
    # figures (synthetic_cell_rigor_size_curve_by_effect.pdf,
    # synthetic_cell_rigor_convergence_error_by_effect.pdf,
    # synthetic_cell_threshold_rates_by_effect.pdf,
    # synthetic_cell_size_curve_primary_rigor.pdf,
    # synthetic_cell_size_curve_threshold_rates.pdf), the rate-
    # variability companion (synthetic_cell_rate_variability_by_effect
    # .pdf), and the operating-characteristics atlas
    # (full36_cell_operating_characteristics_primary_rigor.pdf) were
    # retired. Their generators were deleted. Stale PDFs are removed
    # at the top of every run via .CV_Q1_RETIRED_PDFS.
  }
  rp <- NULL
  if (isTRUE(write)) {
    rp <- file.path(figure_dir, "cell_behavior_visuals_report.md")
    # Figure classification: 4 primary (manuscript-facing) + 3
    # secondary (review/diagnostic). Central-trend and convergence-
    # error figures were retired in 2026-05; no diagnostic figures
    # remain in the Q1 default family.
    fig_classes <- c(
      cell_rigor_atlas.pdf                                       = "primary",
      cell_attenuation_atlas.pdf                                 = "primary",
      synthetic_cell_rigor_variability_by_effect.pdf             = "primary",
      synthetic_cell_rigor_viability_min_n.pdf                   = "primary",
      synthetic_cell_rigor_width_heatmap_by_n.pdf                = "secondary",
      synthetic_cell_bias_evidence_variability_by_effect.pdf     = "secondary",
      synthetic_cell_attenuation_variability_by_effect.pdf       = "secondary")
    # Compact metadata note for resampling-over-n figures.
    res_note <- if (!is.null(inp$size_summary))
      .cv_resampling_note(inp$size_summary) else ""
    fit_note <- if (!is.null(inp$rigor))
      .cv_fit_library_note(inp$rigor) else ""
    # NOTE: the per-metric (mean-vs-median) statistic note that used
    # to live here was retired in 2026-05 along with the p_* rate
    # figures. The current Q1 default family uses only continuous
    # metrics (rigor, bias evidence, absolute attenuation), all
    # summarized as median across B draws by 65, so no rate-vs-
    # continuous caveat is needed.
    # Dev/partial banner: warn when the inputs are not full simulation
    # behavior. Inputs are dev/partial when dev_partial = TRUE on any
    # row, or when n_pool is materially smaller than n_outcomes_target.
    dev_note <- ""
    ss <- inp$size_summary
    if (!is.null(ss) && nrow(ss)) {
      dp_vals <- ss$dev_partial
      is_dev  <- any(dp_vals %in% c(TRUE, "TRUE"), na.rm = TRUE)
      np  <- suppressWarnings(as.integer(ss$n_pool))
      np  <- np[is.finite(np) & np > 0L]
      nt  <- suppressWarnings(as.integer(ss$n_outcomes_target))
      nt  <- nt[is.finite(nt) & nt > 0L]
      pool_min <- if (length(np)) min(np) else NA_integer_
      pool_max <- if (length(np)) max(np) else NA_integer_
      n_max_t  <- if (length(nt)) max(nt) else NA_integer_
      pool_short <- is.finite(pool_min) && is.finite(n_max_t) &&
                    pool_min < n_max_t
      pool_tiny  <- is.finite(pool_min) && pool_min < 50L
      if (isTRUE(is_dev) || isTRUE(pool_short) || isTRUE(pool_tiny)) {
        bits <- character(0)
        if (isTRUE(is_dev))
          bits <- c(bits, "dev_partial = TRUE on at least one input row")
        if (isTRUE(pool_short))
          bits <- c(bits, sprintf(
            "n_pool = %s per cell vs n_outcomes_target up to %d",
            if (is.finite(pool_min) && pool_min == pool_max)
              as.character(pool_min)
            else sprintf("%d-%d", pool_min, pool_max),
            n_max_t))
        else if (isTRUE(pool_tiny))
          bits <- c(bits, sprintf("n_pool = %s per cell (small)",
            if (pool_min == pool_max) as.character(pool_min)
            else sprintf("%d-%d", pool_min, pool_max)))
        dev_note <- paste0(
          "**DEV/PARTIAL**: Q1 cell-behavior inputs are not final ",
          "simulation behavior (", paste(bits, collapse = "; "),
          "). These curves summarize resampling from the current ",
          "fitted pool and should be read as development diagnostics ",
          "until the larger fitted library is complete.")
      }
    }
    # Viability summary note (how many cells meet each width90
    # threshold within the available grid). Built only when the table
    # was written successfully.
    viab_note <- ""
    if (!is.null(viability_tbl) && nrow(viability_tbl)) {
      vt <- viability_tbl
      vt$threshold_width90 <- as.numeric(vt$threshold_width90)
      vt$min_n <- suppressWarnings(as.integer(vt$min_n))
      n_cells <- length(unique(vt$cell_slug))
      n_grid_max <- max(suppressWarnings(as.integer(vt$n_grid_max)),
                        na.rm = TRUE)
      th_lines <- character(0)
      for (th in sort(unique(vt$threshold_width90), decreasing = TRUE)) {
        sub <- vt[vt$threshold_width90 == th, , drop = FALSE]
        met <- sum(isTRUE(sub$meets_within_grid) |
                   sub$meets_within_grid %in% c(TRUE, "TRUE"))
        # Tier counts at common n breakpoints.
        n_min <- sub$min_n[sub$meets_within_grid %in% c(TRUE, "TRUE")]
        c_le10 <- sum(n_min <= 10L, na.rm = TRUE)
        c_le20 <- sum(n_min <= 20L, na.rm = TRUE)
        c_le30 <- sum(n_min <= 30L, na.rm = TRUE)
        c_le50 <- sum(n_min <= 50L, na.rm = TRUE)
        th_lines <- c(th_lines, sprintf(
          paste0("width90 <= %.2f: %d/%d cells meet within n <= %d ",
                 "(by n=10: %d; n=20: %d; n=30: %d; n=50: %d)."),
          th, met, n_cells, n_grid_max,
          c_le10, c_le20, c_le30, c_le50))
      }
      viab_note <- paste("Viability summary (rigor width90):",
                         paste(th_lines, collapse = " "))
    }
    pivot_note <- paste0(
      "Q1 pivot: the primary visual object is now **sampling ",
      "variability** of the stratum-level rigor summary across B ",
      "synthetic resamples (width90 = q95 - q05). Lower width = more ",
      "stable. Minimum viable n is threshold-dependent (treat as a ",
      "design diagnostic, not a universal law). B tiers: 500 dev / ",
      "5000 internal high-precision / 15000 final-publication. ",
      "Increasing B reduces Monte-Carlo noise but cannot compensate ",
      "for a small fitted pool (n_reps).")
    .cv_write_question_report(
      rp, question = "Q1",
      title = "Cell behavior visuals (Q1)",
      question_text = paste0(
        "As n_outcomes increases, how variable is the stratum-level ",
        "summary for each 36-cell design cell, and what stratum ",
        "sizes appear viable for estimating highly specific cells? ",
        "Secondary figures show component variability in bias ",
        "evidence (median_log10BF_bias) and absolute attenuation ",
        "(median_attenuation_abs)."),
      inputs = inp$paths, found = inp$found,
      figures = figs, figure_dir = figure_dir,
      figure_classes = fig_classes,
      notes = c(dev_note, pivot_note, viab_note,
                res_note, fit_note)[
        nzchar(c(dev_note, pivot_note, viab_note,
                 res_note, fit_note))])
  }
  if (isTRUE(verbose))
    message(sprintf("[cv][Q1] done: %d figures, %d skipped%s",
                    length(figs), length(skipped),
                    if (length(figs))
                      sprintf(" -> %s", figure_dir) else ""))
  invisible(list(question = "Q1", figures = figs, skipped = skipped,
                 report = rp, found = inp$found,
                 figure_dir = figure_dir,
                 viability_path = viability_path,
                 viability_tbl  = viability_tbl))
}

# ========================================================================
# Q2: empirical resampling visuals
# ========================================================================

.cv_read_emp_resampling_inputs <- function(
    emp_resampling_dir = .CV_EMP_RESAMPLING_DIR) {
  rd <- function(p) {
    if (!file.exists(p)) return(NULL)
    utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE)
  }
  p_int   <- file.path(emp_resampling_dir,
              "empirical_resampling_observed_size_intervals.csv")
  p_curve <- file.path(emp_resampling_dir,
                       "empirical_resampling_size_curve_summary.csv")
  list(intervals    = rd(p_int),
       size_curve   = rd(p_curve),
       paths = list(intervals = p_int, size_curve = p_curve),
       found = c(intervals  = file.exists(p_int),
                 size_curve = file.exists(p_curve)),
       dirs  = list(empirical_resampling = emp_resampling_dir))
}

# Core audit metric set (Q2 default; mirrors the Q3 core-metric overlay
# so the two questions report on the same metric family). The order
# defines facet/column order. 2026-05-27 trim: rigor margin removed
# from the manuscript-facing core-metric set (still a valid sidecar
# field in .CV_PRIMARY_RIGOR_METRICS / .CV_METRIC_LABELS, but not a
# main Q2/Q3 dashboard panel).
.CV_Q2_CORE_METRICS <- c(
  "median_log10BF_rigor",
  "median_log10BF_bias",
  "median_attenuation_abs")

# Retired Q2 PDFs (2026-05 directional-rigor cull). Scrubbed from the
# active figure folder on every Q2 run so stale copies cannot drift
# forward into the manuscript.
.CV_Q2_RETIRED_PDFS <- c(
  "empirical_resampling_rigor_size_curve.pdf",
  "empirical_resampling_corpus_rigor_size_curve.pdf",
  "empirical_resampling_uncertainty_heatmap_primary_rigor.pdf",
  "empirical_resampling_corpus_uncertainty_heatmap_primary_rigor.pdf",
  "empirical_resampling_size_curve_primary_rigor.pdf",
  "empirical_resampling_stratum_size_curve_primary_rigor.pdf",
  "empirical_resampling_intervals_primary_rigor.pdf",
  "empirical_resampling_corpus_intervals_primary_rigor.pdf")

#' Q2 primary: empirical resampling variability of rigor by stratum.
#'
#' Mirrors the Q1 / Q3 rigor variability framing at the Q2 empirical
#' resampling level: x = `n_sampled`, y = `width90 = q95 - q05` of the
#' stratum-level median selected rigor across B empirical resamples;
#' one line per empirical stratum; faceted by bootstrap mode (`outcome`
#' and `source_cluster`). Lower is more stable. Reads
#' `empirical_resampling_size_curve_summary.csv`. Default `n_max = 50`
#' matches the rest of the stability figures.
cv_plot_empirical_resampling_rigor_variability_by_stratum <- function(
    size_summary, path,
    metric  = "median_log10BF_rigor",
    n_max   = 50L,
    verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  d <- size_summary
  if ("level" %in% names(d))
    d <- d[d$level == "stratum", , drop = FALSE]
  d <- d[d$metric == metric, , drop = FALSE]
  if (!nrow(d))
    stop("cv_plot_empirical_resampling_rigor_variability_by_stratum: ",
         "no stratum rows for metric='", metric,
         "' in empirical resampling size-curve summary.")
  for (cl in c("q05", "q95", "n_sampled"))
    d[[cl]] <- suppressWarnings(as.numeric(d[[cl]]))
  d <- d[is.finite(d$n_sampled) &
         d$n_sampled <= as.numeric(n_max), , drop = FALSE]
  if (!nrow(d))
    stop("cv_plot_empirical_resampling_rigor_variability_by_stratum: ",
         "no rows after n_max <= ", n_max, ".")
  d$width90 <- d$q95 - d$q05
  d <- d[is.finite(d$width90), , drop = FALSE]
  metric_label <- .cv_metric_label(metric)

  p <- g$ggplot(d, g$aes(x = .data$n_sampled, y = .data$width90,
                         group = .data$stratum,
                         color = .data$stratum)) +
    g$geom_line(linewidth = 0.55, alpha = 0.9) +
    g$facet_wrap(~ bootstrap_mode, ncol = 2L) +
    g$labs(
      title = "Empirical resampling variability of rigor",
      subtitle = paste0(
        "Y = width90 (q95 - q05) of stratum-level median ",
        metric_label, " across B empirical resamples. ",
        "Lower is more stable."),
      x = "n_sampled (resampled units; outcome rows or source clusters)",
      y = sprintf("width90(%s) = q95 - q05", metric_label),
      caption = NULL) +
    .cv_theme() +
    g$theme(legend.position = if (length(unique(d$stratum)) > 12L)
                                "none" else "right") +
    g$guides(color = g$guide_legend(title = "stratum", ncol = 1L))
  .cv_save(p, path, width = 12, height = 6, verbose = verbose,
           meta_df = d,
           meta_source = "empirical_resampling_size_curve_summary.csv",
           meta_extras = list(metric = metric))
}

# Compute the per-row width90 used by the Q2 core-metric heatmap and
# table summaries. Returns a numeric vector (Inf preserved, never
# coerced to NA).
.cv_q2_width90 <- function(d) {
  q05 <- suppressWarnings(as.numeric(d$q05))
  q95 <- suppressWarnings(as.numeric(d$q95))
  if ("interval_width_90" %in% names(d)) {
    w0 <- suppressWarnings(as.numeric(d$interval_width_90))
    # Prefer the precomputed column where finite; recompute when NA so
    # we never miss a row.
    ifelse(is.finite(w0), w0, q95 - q05)
  } else {
    q95 - q05
  }
}

#' Q2 primary: observed-size empirical bootstrap uncertainty heatmap
#' across the core audit metrics.
#'
#' Rows = empirical strata; columns = core audit metrics (selected
#' rigor, rigor margin, bias evidence, absolute attenuation); facets =
#' bootstrap mode (`outcome`, `source_cluster`); fill / text label =
#' width90 = q95 - q05 at each stratum's observed sample size.
#'
#' Inf handling: non-finite widths are clamped to a terminal fill (the
#' largest finite width across the plot) so the scale stays usable;
#' the tile label still prints `Inf` so the cell is not silently
#' rewritten. The orchestrator's report lists the affected
#' (group, mode, metric) cells. Reads
#' `empirical_resampling_observed_size_intervals.csv`.
cv_plot_empirical_resampling_core_uncertainty_heatmap <- function(
    intervals, path,
    metrics     = .CV_Q2_CORE_METRICS,
    text_labels = TRUE,
    verbose     = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  d <- intervals
  if ("level" %in% names(d))
    d <- d[d$level == "stratum", , drop = FALSE]
  metrics <- intersect(metrics, unique(d$metric))
  if (length(metrics) == 0L)
    stop("cv_plot_empirical_resampling_core_uncertainty_heatmap: no ",
         "core audit metrics present in intervals.")
  d <- d[d$metric %in% metrics, , drop = FALSE]
  d$width90 <- .cv_q2_width90(d)
  d$metric  <- .cv_metric_factor(d$metric, metrics)

  # Terminal cap for Inf so the fill scale stays usable. NA stays NA
  # (renders as white via na.value). Inf -> finite_max so the cell sits
  # at the terminal fill color; the tile label still prints "Inf".
  finite_max <- suppressWarnings(max(d$width90[is.finite(d$width90)],
                                     na.rm = TRUE))
  if (!is.finite(finite_max)) finite_max <- 0
  d$width90_fill <- ifelse(is.infinite(d$width90), finite_max, d$width90)
  d$width90_label <- ifelse(
    is.na(d$width90), "",
    ifelse(is.infinite(d$width90), "Inf",
           sprintf("%.2f", d$width90)))

  # Stable row ordering: keep the upstream order of stratum appearances
  # so neighbouring strata stay together.
  stratum_lev <- unique(as.character(d$stratum))
  d$stratum <- factor(d$stratum, levels = rev(stratum_lev))

  p <- g$ggplot(d, g$aes(x = .data$metric, y = .data$stratum,
                         fill = .data$width90_fill)) +
    g$geom_tile(color = "gray92", linewidth = 0.2)
  if (isTRUE(text_labels)) {
    p <- p + g$geom_text(
      g$aes(label = .data$width90_label),
      size = .CV_HEATMAP_LABEL_SIZE, color = "gray20")
  }
  p <- p +
    # 1-row x 2-mode dashboard (2026-05-27 layout flip): with only 3
    # metric columns after the rigor-margin retirement, the two
    # bootstrap modes sit side-by-side instead of stacking vertically.
    g$facet_wrap(~ bootstrap_mode, nrow = 1L) +
    g$scale_fill_gradient(
      low = .CV_HEAT_LOW, high = .CV_HEAT_HIGH,
      name = "width90 = q95 - q05",
      na.value = "white") +
    g$labs(
      title = "Observed-size empirical bootstrap uncertainty",
      subtitle = paste0(
        "Fill / label = width90 = q95 - q05 at each stratum's ",
        "observed sample size; lower = more stable. Inf clamped."),
      x = NULL, y = "stratum",
      caption = "Outcome mode = outcome rows; source-cluster mode = source_article clusters.") +
    .cv_theme() +
    g$theme(axis.text.x = g$element_text(angle = 30, hjust = 1,
                                         vjust = 1,
                                         size = .CV_AXIS_TEXT_SMALL + 1))
  # Manuscript-conservative footer (mirrors Q2 core_intervals):
  # compact modes=... label, n_pool suppressed; full provenance is in
  # the Q2 markdown report. Height no longer multiplies by the number
  # of bootstrap modes because the modes are now side-by-side.
  modes_str <- paste(sort(unique(as.character(d$bootstrap_mode))),
                     collapse = ", ")
  .cv_save(p, path, width = 13,
           height = max(6, 2.4 + length(unique(d$stratum)) * 0.42),
           verbose = verbose,
           meta_df = d,
           meta_source = "empirical_resampling_observed_size_intervals.csv",
           meta_extras = list(modes = modes_str),
           meta_suppress = c("bootstrap_mode", "n_pool"))
}

#' Q2 primary: observed-size empirical resampling intervals for the
#' core audit metrics.
#'
#' Forest / range plot: rows = empirical strata; facets = core audit
#' metrics; color = bootstrap mode (`outcome` vs `source_cluster`);
#' filled point = observed empirical estimate; thick bar = q05-q95;
#' thin bar = q025-q975.
#'
#' Inf handling: non-finite interval endpoints are clamped to a
#' per-facet terminal axis boundary (1.2 x finite max half-width on
#' each side of the panel's observed median) so the row remains
#' visible and is not silently dropped; the orchestrator's report
#' lists the affected (group, mode, metric) cells. Reads
#' `empirical_resampling_observed_size_intervals.csv`.
cv_plot_empirical_resampling_core_intervals <- function(
    intervals, path,
    metrics = .CV_Q2_CORE_METRICS,
    verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  d <- intervals
  if ("level" %in% names(d))
    d <- d[d$level == "stratum", , drop = FALSE]
  metrics <- intersect(metrics, unique(d$metric))
  if (length(metrics) == 0L)
    stop("cv_plot_empirical_resampling_core_intervals: no core audit ",
         "metrics present in intervals.")
  d <- d[d$metric %in% metrics, , drop = FALSE]
  for (cl in c("observed_value", "bootstrap_mean", "q05", "q95",
               "q025", "q975"))
    d[[cl]] <- suppressWarnings(as.numeric(d[[cl]]))

  # Per-facet (metric) terminal cap so Inf endpoints render at the
  # panel boundary instead of breaking the scale. The cap is set to
  # 1.2 x the largest finite |endpoint - observed| within the facet,
  # which keeps finite intervals visually unchanged.
  cap_endpoint <- function(x, center, half_max) {
    if (length(x) == 0L) return(x)
    out <- x
    inf_pos <- is.infinite(x) & x > 0
    inf_neg <- is.infinite(x) & x < 0
    out[inf_pos] <- center[inf_pos] + 1.2 * half_max
    out[inf_neg] <- center[inf_neg] - 1.2 * half_max
    out
  }
  d$q05_p   <- d$q05;  d$q95_p   <- d$q95
  d$q025_p  <- d$q025; d$q975_p  <- d$q975
  for (m in metrics) {
    sel <- d$metric == m
    sub <- d[sel, , drop = FALSE]
    obs_center <- ifelse(is.finite(sub$observed_value),
                         sub$observed_value, 0)
    finite_half <- c(
      abs(sub$q05[is.finite(sub$q05)] - obs_center[is.finite(sub$q05)]),
      abs(sub$q95[is.finite(sub$q95)] - obs_center[is.finite(sub$q95)]),
      abs(sub$q025[is.finite(sub$q025)] - obs_center[is.finite(sub$q025)]),
      abs(sub$q975[is.finite(sub$q975)] - obs_center[is.finite(sub$q975)]))
    half_max <- if (length(finite_half))
      suppressWarnings(max(finite_half, na.rm = TRUE)) else 1
    if (!is.finite(half_max) || half_max <= 0) half_max <- 1
    d$q05_p[sel]  <- cap_endpoint(sub$q05,  obs_center, half_max)
    d$q95_p[sel]  <- cap_endpoint(sub$q95,  obs_center, half_max)
    d$q025_p[sel] <- cap_endpoint(sub$q025, obs_center, half_max)
    d$q975_p[sel] <- cap_endpoint(sub$q975, obs_center, half_max)
  }
  # Detect whether the source intervals contained any non-finite
  # endpoint; the in-plot clamping note only appears when at least one
  # endpoint was clamped. Full per-cell detail is in the Q2 report.
  .had_clamp <- any(!is.finite(c(d$q05, d$q95, d$q025, d$q975)))
  d$metric <- .cv_metric_factor(d$metric, metrics)

  p <- g$ggplot(d, g$aes(y = .data$stratum,
                         color = .data$bootstrap_mode)) +
    g$geom_linerange(g$aes(xmin = .data$q025_p, xmax = .data$q975_p),
                     position = g$position_dodge(width = 0.6),
                     linewidth = 0.3, alpha = 0.25) +
    g$geom_linerange(g$aes(xmin = .data$q05_p, xmax = .data$q95_p),
                     position = g$position_dodge(width = 0.6),
                     linewidth = 1.0) +
    g$geom_point(g$aes(x = .data$observed_value),
                 position = g$position_dodge(width = 0.6),
                 size = 1.9, fill = "white", shape = 21,
                 stroke = 0.7) +
    # 1-row x 4-cols compact horizontal dashboard (2026-05 polish).
    g$facet_wrap(~ metric, scales = "free_x", nrow = 1L) +
    g$scale_color_manual(values = c(
      outcome        = unname(.VIS_COLORS$bootstrap_mode[["outcome"]]),
      source_cluster = unname(.VIS_COLORS$bootstrap_mode[["source_cluster"]])),
      name = "bootstrap mode") +
    g$labs(
      title = "Observed-size empirical resampling intervals",
      subtitle = "Points = observed estimates; bars = q05-q95 and q025-q975 intervals.",
      x = "metric value (per-facet scale)", y = "stratum",
      caption = if (.had_clamp)
        "Non-finite endpoints are clamped; details in report." else NULL) +
    .cv_theme()
  # Manuscript-conservative footer: replace verbose
  # `bootstrap_mode=outcome|source_cluster` with compact
  # `modes=outcome, source_cluster`, and suppress n_pool (not central
  # to the observed-size interval display). bootstrap_mode + n_pool are
  # therefore suppressed from the default metadata line and the modes
  # token is injected via meta_extras. Full bootstrap_mode / n_pool /
  # source CSV remain in the Q2 markdown report.
  modes_str <- paste(sort(unique(as.character(d$bootstrap_mode))),
                     collapse = ", ")
  # Width reduced 13 -> 11 because the dashboard is now 1 row x 3 cols
  # (rigor margin retired from the core-metric set, 2026-05-27).
  .cv_save(p, path, width = 11,
           height = max(5.5, 1.8 + length(unique(d$stratum)) * 0.40),
           verbose = verbose,
           meta_df = d,
           meta_source = "empirical_resampling_observed_size_intervals.csv",
           meta_extras = list(modes = modes_str),
           meta_suppress = c("bootstrap_mode", "n_pool"))
}

# ---- Q2 report writer (corpus core-metric table + Inf diagnostics) ----

# Format a numeric for the Q2 report; "Inf"/"-Inf" preserved.
.cv_q2_fmt <- function(x, digits = 3L) {
  if (is.na(x))           return("NA")
  if (is.infinite(x))     return(if (x > 0) "Inf" else "-Inf")
  formatC(as.numeric(x), digits = digits, format = "g")
}

# Compact corpus core-metric summary table, derived from the observed-
# size intervals at level == "corpus". Returns a data.frame with the
# columns the report renders directly.
.cv_q2_corpus_summary <- function(intervals,
                                  metrics = .CV_Q2_CORE_METRICS) {
  if (is.null(intervals) || !nrow(intervals)) return(NULL)
  d <- intervals[intervals$level == "corpus", , drop = FALSE]
  d <- d[d$metric %in% metrics, , drop = FALSE]
  if (!nrow(d)) return(NULL)
  d$width90 <- .cv_q2_width90(d)
  d$non_finite_flag <- ifelse(
    is.na(d$width90), "NA width",
    ifelse(is.infinite(d$width90), "Inf width",
           ifelse(is.infinite(suppressWarnings(as.numeric(d$q05))) |
                  is.infinite(suppressWarnings(as.numeric(d$q95))) |
                  is.infinite(suppressWarnings(as.numeric(d$q025))) |
                  is.infinite(suppressWarnings(as.numeric(d$q975))),
                  "Inf endpoint", "")))
  # Preserve canonical core-metric ordering.
  d$metric <- factor(d$metric, levels = metrics)
  d <- d[order(d$metric, d$bootstrap_mode), , drop = FALSE]
  data.frame(
    metric           = .cv_metric_label(as.character(d$metric)),
    bootstrap_mode   = d$bootstrap_mode,
    observed_value   = vapply(d$observed_value, .cv_q2_fmt,
                              character(1), digits = 3L),
    width90          = vapply(d$width90, .cv_q2_fmt,
                              character(1), digits = 3L),
    non_finite_flag  = d$non_finite_flag,
    stringsAsFactors = FALSE)
}

# Non-finite diagnostic table (stratum-level). Returns a data.frame of
# (level, stratum, bootstrap_mode, metric, q05, q95, width90) for every
# cell whose width90 or interval endpoint is non-finite. Empty data
# frame when nothing is flagged.
.cv_q2_nonfinite_cells <- function(intervals,
                                   metrics = .CV_Q2_CORE_METRICS) {
  if (is.null(intervals) || !nrow(intervals))
    return(intervals[0, , drop = FALSE])
  d <- intervals[intervals$metric %in% metrics, , drop = FALSE]
  if (!nrow(d)) return(d[0, , drop = FALSE])
  d$width90 <- .cv_q2_width90(d)
  bad <- !is.finite(d$width90) |
         !is.finite(suppressWarnings(as.numeric(d$q05))) |
         !is.finite(suppressWarnings(as.numeric(d$q95))) |
         !is.finite(suppressWarnings(as.numeric(d$q025))) |
         !is.finite(suppressWarnings(as.numeric(d$q975)))
  flagged <- d[bad, , drop = FALSE]
  if (!nrow(flagged)) return(flagged)
  flagged$metric_label <- .cv_metric_label(as.character(flagged$metric))
  flagged
}

# Q2-specific report writer. Writes ONLY `path`. Sections:
#   1. Inputs read
#   2. Q2 primary figures
#   3. Corpus core-metric summary table
#   4. Non-finite interval/width diagnostics
#   5. Scope / interpretation notes
.cv_write_q2_report <- function(path, inputs, found,
                                figures, figure_dir,
                                size_curve, intervals,
                                metrics = .CV_Q2_CORE_METRICS) {
  L <- character(0); ad <- function(...) L <<- c(L, paste0(...))
  ad("# Empirical resampling visuals (Q2)")
  ad("")
  ad("Question (Q2): If the empirical nutrition registry is ",
     "resampled, how stable are the observed stratum/corpus rigor ",
     "summaries?")
  ad("")
  ad("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  ad("")

  # 1. Inputs read.
  ad("## 1. Inputs read")
  for (k in names(inputs)) {
    ok <- isTRUE(found[[k]])
    ad("- `", inputs[[k]], "` -> ", if (ok) "read" else "MISSING")
  }
  ad("")

  # 2. Q2 primary figures.
  ad("## 2. Q2 primary figures")
  if (!length(figures)) {
    ad("- (none -- all required inputs were missing)")
  } else {
    for (f in figures) {
      base  <- basename(f)
      guide <- .CV_FIGURE_GUIDE[[base]]
      ad("- `", base, "`",
         if (!is.null(guide)) paste0("  -- ", guide) else "")
    }
  }
  ad("")
  ad("Figures written: ", length(figures), ".")
  ad("")

  # 3. Corpus core-metric summary table. Markdown table because the
  # corpus is one row per (metric, mode); inefficient as a PDF, useful
  # as text in the report.
  ad("## 3. Corpus core-metric summary (markdown table; not a PDF)")
  if (is.null(intervals) || !nrow(intervals)) {
    ad("- (empirical_resampling_observed_size_intervals.csv missing ",
       "or empty)")
  } else {
    corpus_tbl <- .cv_q2_corpus_summary(intervals, metrics = metrics)
    if (is.null(corpus_tbl) || !nrow(corpus_tbl)) {
      ad("- No corpus-level rows matched the core audit metric set.")
    } else {
      ad("| metric | bootstrap mode | observed | width90 | flag |")
      ad("|---|---|---|---|---|")
      for (i in seq_len(nrow(corpus_tbl))) {
        ad(sprintf("| %s | %s | %s | %s | %s |",
                   corpus_tbl$metric[i],
                   corpus_tbl$bootstrap_mode[i],
                   corpus_tbl$observed_value[i],
                   corpus_tbl$width90[i],
                   if (nzchar(corpus_tbl$non_finite_flag[i]))
                     corpus_tbl$non_finite_flag[i] else ""))
      }
    }
  }
  ad("")

  # 4. Non-finite interval/width diagnostics (stratum-level).
  ad("## 4. Non-finite interval / width diagnostics")
  nf <- .cv_q2_nonfinite_cells(intervals, metrics = metrics)
  if (is.null(nf) || !nrow(nf)) {
    ad("- No non-finite widths or interval endpoints across the core ",
       "audit metrics. (Inf-handling code paths are inactive on this ",
       "run.)")
  } else {
    ad("- ", nrow(nf), " (level, stratum, mode, metric) cell(s) with ",
       "non-finite width or endpoint:")
    ad("")
    ad("| level | stratum | bootstrap mode | metric | q05 | q95 | width90 |")
    ad("|---|---|---|---|---|---|---|")
    for (i in seq_len(nrow(nf))) {
      ad(sprintf("| %s | %s | %s | %s | %s | %s | %s |",
                 nf$level[i],
                 nf$stratum[i],
                 nf$bootstrap_mode[i],
                 nf$metric_label[i],
                 .cv_q2_fmt(suppressWarnings(as.numeric(nf$q05[i]))),
                 .cv_q2_fmt(suppressWarnings(as.numeric(nf$q95[i]))),
                 .cv_q2_fmt(nf$width90[i])))
    }
    ad("")
    ad("Heatmap: Inf widths are shown at the terminal fill color and ",
       "labeled Inf. Intervals: non-finite endpoints are clamped to ",
       "a per-facet terminal axis boundary so the row stays visible. ",
       "Values are preserved in the CSV.")
  }
  ad("")

  # 5. Scope / interpretation notes.
  ad("## 5. Scope / interpretation notes")
  ad("- Q2 evaluates **empirical resampling stability**, not a new ",
     "synthetic data-generating model.")
  ad("- Outcome mode resamples outcome rows. Source-cluster mode ",
     "resamples `source_article` clusters; cluster multiplicity is ",
     "preserved by `boot_cluster_instance`.")
  ad("- `width90 = q95 - q05` is the primary stability scale. ",
     "Lower = more stable. This is sampling variability across B ",
     "empirical resamples; NOT posterior uncertainty and NOT a ",
     "Monte-Carlo standard error.")
  ad("- Default Q2 figures use the core audit metric set: ",
     "rigor evidence, bias evidence, absolute attenuation. ",
     "Rigor margin is retained as a sidecar field for diagnostic ",
     "inspection but is not a default Q2 visual target. ",
     "Directional / thresholded `p_*` rate metrics are available in ",
     "`empirical_resampling_size_curve_summary.csv` for ad-hoc ",
     "inspection but are deliberately not default Q2 visual targets.")
  ad("- B tiers: 500 (dev / visual tuning; default), 5000 (internal ",
     "high-precision check), 15000 (final / publication when ",
     "feasible). Pass B explicitly to `emp_run_resampling()` for ",
     "non-default runs.")
  ad("- Non-finite widths / endpoints are preserved in the CSV and ",
     "reported above; the figures clamp them to terminal axis ",
     "boundaries for renderability rather than dropping the row.")
  ad("- Corpus-level information is provided here as a markdown ",
     "table rather than as default PDFs (a one-row Overall figure is ",
     "less informative than the stratum-level stability story).")

  writeLines(L, path)
  invisible(path)
}

#' Q2 orchestrator: empirical resampling figures.
#'
#' Writes exactly three default Q2 PDFs (rigor variability by stratum,
#' core uncertainty heatmap, core intervals) and a markdown report
#' that carries the corpus core-metric summary table + non-finite
#' diagnostics. Retired primary-rigor (p_*) figures are scrubbed from
#' the figure folder on every run.
sim_run_empirical_resampling_visuals <- function(
    emp_resampling_dir = .CV_EMP_RESAMPLING_DIR,
    figure_dir         = .CV_FIG_EMP_RESAMPLING_DIR,
    write              = TRUE,
    verbose            = TRUE) {
  .cv_need_ggplot()
  inp <- .cv_read_emp_resampling_inputs(emp_resampling_dir =
                                         emp_resampling_dir)
  if (isTRUE(write) && !dir.exists(figure_dir))
    dir.create(figure_dir, recursive = TRUE)
  fp <- function(f) file.path(figure_dir, f)

  # Stale-PDF cleanup: retired primary-rigor (p_*) Q2 figures. Cleared
  # from the figure folder on every run so stale copies cannot drift
  # forward into the manuscript.
  if (isTRUE(write) && dir.exists(figure_dir)) {
    for (.rp in .CV_Q2_RETIRED_PDFS) {
      .rpath <- file.path(figure_dir, .rp)
      if (file.exists(.rpath)) {
        file.remove(.rpath)
        if (isTRUE(verbose))
          message(sprintf("  removed retired %s", .rpath))
      }
    }
  }

  figs <- character(0); skipped <- character(0)
  do <- function(cond, fn) {
    if (!isTRUE(cond)) return(invisible(NULL))
    tryCatch(fn(), error = function(e) {
      skipped <<- c(skipped, conditionMessage(e))
      if (isTRUE(verbose)) message("  [skip] ", conditionMessage(e))
    })
  }
  if (isTRUE(write)) {
    # Figure 1: empirical resampling variability of rigor by stratum.
    do(!is.null(inp$size_curve), function()
      figs <<- c(figs,
        cv_plot_empirical_resampling_rigor_variability_by_stratum(
          inp$size_curve,
          fp("empirical_resampling_rigor_variability_by_stratum.pdf"),
          metric = "median_log10BF_rigor", n_max = 50L,
          verbose = verbose)))
    # Figure 2: core-metric observed-size uncertainty heatmap.
    do(!is.null(inp$intervals), function()
      figs <<- c(figs,
        cv_plot_empirical_resampling_core_uncertainty_heatmap(
          inp$intervals,
          fp("empirical_resampling_core_uncertainty_heatmap.pdf"),
          verbose = verbose)))
    # Figure 3: core-metric observed-size intervals.
    do(!is.null(inp$intervals), function()
      figs <<- c(figs,
        cv_plot_empirical_resampling_core_intervals(
          inp$intervals,
          fp("empirical_resampling_core_intervals.pdf"),
          verbose = verbose)))
  }
  rp <- NULL
  if (isTRUE(write)) {
    rp <- file.path(figure_dir, "empirical_resampling_visuals_report.md")
    .cv_write_q2_report(
      rp, inputs = inp$paths, found = inp$found,
      figures = figs, figure_dir = figure_dir,
      size_curve = inp$size_curve, intervals = inp$intervals,
      metrics = .CV_Q2_CORE_METRICS)
  }
  if (isTRUE(verbose))
    message(sprintf("[cv][Q2] done: %d figures, %d skipped%s",
                    length(figs), length(skipped),
                    if (length(figs))
                      sprintf(" -> %s", figure_dir) else ""))
  invisible(list(question = "Q2", figures = figs, skipped = skipped,
                 report = rp, found = inp$found,
                 figure_dir = figure_dir))
}

# ========================================================================
# Q3: composition input map + variability / bridge primaries
# ========================================================================
# Retired 2026-05:
#   * cv_plot_composition_size_curve_primary_rigor() -- old multi-
#     primary-rigor (p_*) curve; jagged and not central to the
#     selected-rigor workflow.
#   * cv_plot_composition_rigor_size_curve() -- mean/median-level
#     rigor size curve; replaced by
#     cv_plot_composition_rigor_variability_by_stratum() (defined
#     below), which plots width90 instead of the mean/median level.
#   * cv_plot_emp_bootstrap_vs_composition() -- primary-rigor (p_*)
#     overlay; replaced by
#     cv_plot_emp_bootstrap_vs_composition_core_metrics(), which
#     scopes the overlay to four core audit metrics (selected rigor,
#     rigor margin, bias evidence, absolute attenuation) and drops
#     directional/thresholded p_* rates.

# Reader for the Q3 empirical-weighted synthetic size-curve summary
# (lives in the same Q3 output directory). Renamed from
# .cv_read_composition_size_curve() in the 2026-05 terminology pass.
.cv_read_ews_size_curve <- function(
    ews_dir = .CV_EWS_DIR) {
  p <- file.path(ews_dir,
                 "empirical_weighted_synthetic_size_curve_summary.csv")
  if (!file.exists(p)) return(list(summary = NULL, path = p,
                                   found = FALSE))
  list(summary = utils::read.csv(p, stringsAsFactors = FALSE,
                                 check.names = FALSE),
       path = p, found = TRUE)
}

#' Q3 primary: empirical-weighted synthetic sampling rigor VARIABILITY
#' by stratum.
#'
#' Mirrors the Q1 rigor variability framing but at the Q3 empirical-
#' weighted synthetic sampling level: x = `n_outcomes_target`, y =
#' `width90 = q95 - q05` of the stratum-level median selected rigor
#' across B empirical-weighted synthetic draws, one line per empirical
#' stratum. Lower is more stable. Reads
#' `empirical_weighted_synthetic_size_curve_summary.csv`. Replaces
#' the earlier mean/median-level rigor size curve.
#'
#' Renamed from cv_plot_composition_rigor_variability_by_stratum() in
#' the 2026-05 Q3 terminology pass.
#'
#' @param summary_df `empirical_weighted_synthetic_size_curve_summary.csv` data.
#' @param metric Metric to plot (default `median_log10BF_rigor`).
#' @param n_max Cap on `n_outcomes_target` (default 50).
cv_plot_empirical_weighted_rigor_variability_by_stratum <- function(
    summary_df, path,
    metric  = "median_log10BF_rigor",
    n_max   = 50L,
    verbose = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  d <- summary_df
  d <- d[d$metric == metric, , drop = FALSE]
  if (!nrow(d))
    stop("cv_plot_empirical_weighted_rigor_variability_by_stratum: ",
         "no rows for metric='", metric,
         "' in empirical-weighted synthetic size-curve summary.")
  for (cl in c("q05", "q95", "n_outcomes_target"))
    d[[cl]] <- suppressWarnings(as.numeric(d[[cl]]))
  d <- d[is.finite(d$n_outcomes_target) &
         d$n_outcomes_target <= as.numeric(n_max), , drop = FALSE]
  if (!nrow(d))
    stop("cv_plot_empirical_weighted_rigor_variability_by_stratum: ",
         "no rows after n_max <= ", n_max, ".")
  d$width90 <- d$q95 - d$q05
  d <- d[is.finite(d$width90), , drop = FALSE]
  metric_label <- .cv_metric_label(metric)

  # `.VIS_COLORS$resampling_source$synthetic_composition` remains the
  # canonical resampling-source category key for Q3 (the palette
  # contract; muted purple). Public-facing labels say "empirical-
  # weighted synthetic" everywhere.
  syn_col <- .VIS_COLORS$resampling_source[["synthetic_composition"]]
  p <- g$ggplot(d, g$aes(x = .data$n_outcomes_target,
                         y = .data$width90,
                         group = .data$stratum,
                         color = .data$stratum)) +
    g$geom_line(linewidth = 0.55, alpha = 0.9) +
    g$labs(
      title = "Empirical-weighted synthetic sampling variability of rigor",
      subtitle = paste0(
        "Y = width90 (q95 - q05) of stratum-level median ",
        metric_label, ".\n",
        "Lower values are more stable. One line per empirical ",
        "fitted-profile cell mixture."),
      x = paste0("n_outcomes (empirical-weighted synthetic resample ",
                 "size per stratum)"),
      y = sprintf("width90(%s) = q95 - q05", metric_label),
      caption = NULL) +
    .cv_theme() +
    g$theme(legend.position = if (length(unique(d$stratum)) > 12L)
                                "none" else "right") +
    g$guides(color = g$guide_legend(title = "stratum", ncol = 1L))
  # Use the synthetic-composition color as the single default when the
  # legend is suppressed for large stratum counts.
  if (length(unique(d$stratum)) > 12L)
    p <- p + g$scale_color_manual(
      values = setNames(rep(syn_col, length(unique(d$stratum))),
                        unique(d$stratum)),
      guide = "none")
  .cv_save(p, path, width = 11, height = 6, verbose = verbose,
           meta_df = d,
           meta_source = "empirical_weighted_synthetic_size_curve_summary.csv",
           meta_extras = list(metric = metric))
}

#' Q3 bridge primary: empirical bootstrap vs synthetic composition for
#' core audit metrics.
#'
#' Forest/range plot per (stratum, core metric):
#' - blue interval = empirical bootstrap q05-q95 with observed point
#'   (read from `empirical_resampling_observed_size_intervals.csv`)
#' - purple interval = empirical-weighted synthetic q05-q95 with
#'   median (read from
#'   `empirical_weighted_synthetic_size_curve_summary.csv` at the
#'   `n_outcomes_target` nearest to the stratum's empirical
#'   `n_outcomes_observed`)
#'
#' Core metrics = c("median_log10BF_rigor", "median_rigor_margin",
#' "median_log10BF_bias", "median_attenuation_abs") by default.
#' Directional / thresholded `p_*` rate metrics are deliberately
#' excluded from this default overlay; the selected-rigor estimand is
#' designed to abstract away from per-cell directional rate
#' bookkeeping.
#'
#' Requires `median_attenuation_abs` rows in the Q3 summary; that
#' metric was added to 65's `.SC_COMPONENT_METRICS` in 2026-05, so
#' older summary CSVs need a 65 rerun before the attenuation facet
#' will appear.
#'
#' Renamed from cv_plot_emp_bootstrap_vs_composition_core_metrics()
#' in the 2026-05 Q3 terminology pass.
cv_plot_emp_bootstrap_vs_empirical_weighted_core_metrics <- function(
    intervals_df, ews_summary, path,
    metrics        = c("median_log10BF_rigor",
                       "median_log10BF_bias",
                       "median_attenuation_abs"),
    bootstrap_mode = "outcome",
    verbose        = TRUE) {
  .cv_need_ggplot(); .cv_need_colors(); g <- asNamespace("ggplot2")
  iv <- intervals_df
  iv <- iv[iv$level == "stratum" &
           iv$bootstrap_mode == bootstrap_mode &
           iv$metric %in% metrics, , drop = FALSE]
  if (!nrow(iv))
    stop("cv_plot_emp_bootstrap_vs_empirical_weighted_core_metrics:",
         " no empirical interval rows for mode '", bootstrap_mode,
         "' and the requested core metrics. Available metrics in ",
         "intervals_df: ",
         paste(sort(unique(intervals_df$metric)), collapse = ","))
  cs <- ews_summary
  if (!"n_outcomes_target" %in% names(cs))
    stop("cv_plot_emp_bootstrap_vs_empirical_weighted_core_metrics:",
         " empirical-weighted synthetic summary missing ",
         "n_outcomes_target.")
  for (cl in c("q05", "q95", "synthetic_median",
               "n_outcomes_target"))
    cs[[cl]] <- suppressWarnings(as.numeric(cs[[cl]]))
  for (cl in c("q05", "q95", "observed_value",
               "n_outcomes_observed"))
    if (cl %in% names(iv))
      iv[[cl]] <- suppressWarnings(as.numeric(iv[[cl]]))

  # Match each (stratum, metric) empirical row to the empirical-
  # weighted synthetic n_outcomes_target nearest to the empirical
  # n_outcomes_observed.
  match_row <- function(stratum, metric, n_target) {
    sub <- cs[cs$stratum == stratum & cs$metric == metric, ,
              drop = FALSE]
    if (!nrow(sub) || is.na(n_target)) return(NULL)
    sub[which.min(abs(sub$n_outcomes_target - n_target)), ,
        drop = FALSE]
  }
  rows <- list()
  for (i in seq_len(nrow(iv))) {
    cr <- match_row(iv$stratum[i], iv$metric[i],
                    iv$n_outcomes_observed[i])
    if (is.null(cr) || !nrow(cr)) next
    rows[[length(rows) + 1L]] <- data.frame(
      stratum = iv$stratum[i],
      metric  = iv$metric[i],
      empirical_q05  = iv$q05[i],
      empirical_q95  = iv$q95[i],
      observed_value = iv$observed_value[i],
      n_outcomes     = iv$n_outcomes_observed[i],
      synthetic_q05  = cr$q05,
      synthetic_q95  = cr$q95,
      synthetic_median = cr$synthetic_median,
      stringsAsFactors = FALSE)
  }
  if (!length(rows))
    stop("cv_plot_emp_bootstrap_vs_empirical_weighted_core_metrics:",
         " no overlapping (stratum, metric, n) cells. Check that ",
         "the empirical-weighted synthetic summary contains all ",
         "four core metrics; if median_attenuation_abs is missing, ",
         "rerun sim_run_synthetic_resampling().")
  d <- do.call(rbind, rows)
  # Order facets in canonical core-metric order, falling back to
  # alphabetical for anything outside the requested list.
  metric_lev <- intersect(metrics, unique(d$metric))
  metric_lev <- c(metric_lev, setdiff(unique(d$metric), metric_lev))
  d$metric <- .cv_metric_factor(d$metric, metric_lev)

  # `.VIS_COLORS$resampling_source$synthetic_composition` remains the
  # palette-contract key for the Q3 resampling-source category.
  emp_col <- .VIS_COLORS$resampling_source[["empirical_bootstrap"]]
  syn_col <- .VIS_COLORS$resampling_source[["synthetic_composition"]]
  p <- g$ggplot(d, g$aes(y = .data$stratum)) +
    g$geom_linerange(g$aes(xmin = .data$empirical_q05,
                           xmax = .data$empirical_q95),
                     color = emp_col, linewidth = 1.0,
                     position = g$position_nudge(y = 0.18)) +
    g$geom_linerange(g$aes(xmin = .data$synthetic_q05,
                           xmax = .data$synthetic_q95),
                     color = syn_col, linewidth = 1.0,
                     position = g$position_nudge(y = -0.18)) +
    g$geom_point(g$aes(x = .data$observed_value), color = emp_col,
                 size = 1.9,
                 position = g$position_nudge(y = 0.18)) +
    g$geom_point(g$aes(x = .data$synthetic_median),
                 shape = 21, fill = "white", color = syn_col,
                 size = 1.9,
                 position = g$position_nudge(y = -0.18)) +
    # 1-row x 4-cols compact horizontal dashboard (2026-05 polish);
    # mirrors the Q2 core-intervals layout for visual symmetry.
    g$facet_wrap(~ metric, scales = "free_x", nrow = 1L) +
    g$labs(
      title = paste0("Empirical bootstrap vs empirical-weighted ",
                     "synthetic sampling"),
      subtitle = paste0(
        "Blue = empirical bootstrap (q05-q95 + observed).\n",
        "Purple = empirical-weighted synthetic (q05-q95 + median), ",
        "matched to each stratum's empirical n_outcomes."),
      x = "metric value (per-facet scale)", y = "stratum",
      caption = "Directional/thresholded p_* rate metrics excluded by design.") +
    .cv_theme()
  # Width reduced 13 -> 11; Q3 bridge is now 1 row x 3 cols
  # (rigor margin retired from the core-metric set, 2026-05-27).
  .cv_save(p, path, width = 11,
           height = max(5.5, 1.8 + length(unique(d$stratum)) * 0.40),
           verbose = verbose,
           meta_df = ews_summary,
           meta_source = paste(
             "empirical_resampling_observed_size_intervals.csv",
             "empirical_weighted_synthetic_size_curve_summary.csv",
             sep = " + "))
}

# ========================================================================
# Shared report writer for the per-question wrappers
# ========================================================================

.cv_write_question_report <- function(path, question, title,
                                      question_text, inputs, found,
                                      figures, figure_dir,
                                      figure_classes = NULL,
                                      notes = character(0)) {
  L <- character(0); ad <- function(...) L <<- c(L, paste0(...))
  ad("# ", title)
  ad("")
  ad("Question (", question, "): ", question_text)
  ad("")
  ad("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  ad("")
  ad("## Inputs read")
  for (k in names(inputs)) {
    ok <- isTRUE(found[[k]])
    ad("- `", inputs[[k]], "` -> ", if (ok) "read" else "MISSING")
  }
  ad("")
  if (length(figures) && !is.null(figure_classes) &&
      length(figure_classes)) {
    cls <- figure_classes[basename(figures)]
    cls[is.na(cls)] <- "other"
    primary    <- figures[cls == "primary"]
    secondary  <- figures[cls == "secondary"]
    diagnostic <- figures[cls == "diagnostic"]
    other      <- figures[cls == "other"]
    if (length(primary)) {
      ad("## Q1 primary figures")
      for (f in primary) ad("- `", basename(f), "`")
      ad("")
    }
    if (length(secondary)) {
      ad("## Q1 secondary figures")
      for (f in secondary) ad("- `", basename(f), "`")
      ad("")
    }
    if (length(diagnostic)) {
      ad("## Q1 diagnostic figures")
      for (f in diagnostic) ad("- `", basename(f), "`")
      ad("")
    }
    if (length(other)) {
      ad("## Other figures")
      for (f in other) ad("- `", basename(f), "`")
      ad("")
    }
  } else {
    ad("## Figures written")
    if (length(figures)) {
      for (f in figures) ad("- `", basename(f), "`")
    } else {
      ad("- (none -- all required inputs were missing)")
    }
    ad("")
  }
  if (length(notes)) {
    ad("## Notes")
    for (n in notes) ad("- ", n)
    ad("")
  }
  ad("## Scope")
  ad("- Primary figures are manuscript-facing; secondary / ",
     "diagnostic figures are retained for review and debugging.")
  ad("- B / library size / smoothing / pool_key live in the input ",
     "CSVs and upstream reports, never in figure filenames.")
  writeLines(L, path)
  invisible(path)
}

# ========================================================================
# All-analysis orchestrator
# ========================================================================

#' Run the Q1, Q2, Q3 visual wrappers in one call. Each wrapper
#' writes into its own figure folder; figures live in stable
#' directories so the question they answer is implicit in the path.
#'
#' Returns invisible list with one element per wrapper.
sim_run_all_analysis_visuals <- function(
    cell_behavior_dir          = .CV_CELL_BEHAVIOR_DIR,
    emp_resampling_dir         = .CV_EMP_RESAMPLING_DIR,
    ews_dir                    = .CV_EWS_DIR,
    ews_detail_dir             = .CV_EWS_DETAIL_DIR,
    agreement_dir              = .CV_AGREE_DIR,
    results_dir                = .CV_RESULTS_DIR,
    figure_cell_behavior_dir   = .CV_FIG_CELL_BEHAVIOR_DIR,
    figure_emp_resampling_dir  = .CV_FIG_EMP_RESAMPLING_DIR,
    figure_ews_dir             = .CV_FIG_EWS_DIR,
    legacy_fig_comp_dir        = .CV_LEGACY_FIG_COMP_DIR,
    write   = TRUE,
    verbose = TRUE) {
  q1 <- sim_run_cell_behavior_visuals(
    cell_behavior_dir = cell_behavior_dir,
    results_dir       = results_dir,
    figure_dir        = figure_cell_behavior_dir,
    write             = write, verbose = verbose)
  q2 <- sim_run_empirical_resampling_visuals(
    emp_resampling_dir = emp_resampling_dir,
    figure_dir         = figure_emp_resampling_dir,
    write              = write, verbose = verbose)
  # Q3 orchestrator (sim_run_q3_visuals) now covers the entire
  # 6-figure default Q3 family (3 primary/bridge + 3 profile-
  # definition diagnostics). The old `q3_extras` block (separate
  # rigor-only + primary-rigor size curves + earlier overlay) and the
  # standalone diagnostics drawer were both retired in the 2026-05
  # Q3 cull; everything Q3 needs now lives inside sim_run_q3_visuals().
  q3 <- sim_run_q3_visuals(
    ews_dir            = ews_dir,
    ews_detail_dir     = ews_detail_dir,
    agreement_dir      = agreement_dir,
    emp_resampling_dir = emp_resampling_dir,
    figure_dir         = figure_ews_dir,
    legacy_fig_dir     = legacy_fig_comp_dir,
    write              = write, verbose = verbose)

  if (isTRUE(verbose))
    message(sprintf(paste0("[cv][all] done: Q1=%d figs, Q2=%d figs, ",
                            "Q3=%d figs"),
                    length(q1$figures), length(q2$figures),
                    length(q3$figures)))

  invisible(list(
    cell_behavior        = q1,
    empirical_resampling = q2,
    empirical_weighted_synthetic = q3))
}
