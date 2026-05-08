# 00_utils.R
# ------------------------------------------------------------------------------
# Shared helpers used by more than one script in the pipeline.
#
# Sourcing this file only defines functions and a load sentinel; there are no
# side effects on disk or in the global environment beyond those definitions.
#
# Sourced by: 10_load_data.R, 20_robma_fit.R, 40_batch_fit.R,
#             50_topic_analysis.R, 60_overview.R
# Not used by: 30_robma_analysis.R (defines its own helpers locally).
#
# Quick-Start
#   source("scripts/00_utils.R")
#   format_topic("vitamind")               # "Vitamin D"
#   .bf_evidence_transform(c(-2, 0, 2))    # piecewise-linear evidence axis
# ------------------------------------------------------------------------------


# ---- Null-default operator -------------------------------------------------
# Returns `a` if not NULL, otherwise `b`. Matches the rlang `%||%` semantics
# without requiring the rlang dependency.
`%||%` <- function(a, b) if (!is.null(a)) a else b


# ---- Topic-slug formatting -------------------------------------------------
# Convert a topic slug (e.g. "vitamind") to a display label (e.g. "Vitamin D").
# Uses overrides for irregular slugs and falls back to title-case with
# underscores replaced by spaces. Vectorized; case-insensitive on the slug.
format_topic <- function(slug) {
  overrides <- c(vitamind = "Vitamin D", omega3 = "Omega-3")
  out <- tools::toTitleCase(gsub("_", " ", slug))
  hit <- tolower(slug) %in% names(overrides)
  out[hit] <- overrides[tolower(slug)[hit]]
  out
}


# ---- Catalog/meta-file detection -------------------------------------------
# TRUE for helper / catalog CSVs that should never be fitted as a dataset
# (e.g. <author>_original_effects.csv, <author>_studies.csv, *_excluded.csv).
is_meta_basename <- function(basename) {
  grepl("(original_effects|studies|excluded)$", basename, ignore.case = TRUE)
}


# ---- Bayes-factor evidence-axis transform ----------------------------------
# Map signed log10(BF) to a piecewise-linear "evidence axis" with equal-width
# bins for the standard Bayes-factor evidence categories, plus a saturating
# terminal bin so extreme values stay on-canvas.
#
# Evidence categories (positive side):
#   BF 1-3      log10 [0, 0.477]    -> transformed [0, 1]    "anecdotal"
#   BF 3-10     log10 (0.477, 1]    -> transformed (1, 2]    "moderate"
#   BF 10-100   log10 (1, 2]        -> transformed (2, 3]    "strong-very strong"
#   BF 100-Inf  log10 (2, +Inf)     -> transformed (3, 3.4]  "extreme" (compressed)
#
# Negative side is the symmetric mirror (1/3, 1/10, 1/100, 0). The terminal
# bin uses 3 + 0.4 * (1 - exp(-1.5 * (a - b3))), which approaches 3.4 quickly
# but never exceeds it.
.bf_evidence_transform <- function(log10bf) {
  x <- log10bf
  a <- abs(x)
  b1 <- log10(3)   # ~ 0.4771
  b2 <- 1
  b3 <- 2

  z <- ifelse(a <= b1,
              a / b1,
              ifelse(a <= b2,
                     1 + (a - b1) / (b2 - b1),
                     ifelse(a <= b3,
                            2 + (a - b2) / (b3 - b2),
                            3 + 0.4 * (1 - exp(-1.5 * (a - b3))))))

  sign(x) * z
}


# ---- Bayes-factor axis breaks/labels ---------------------------------------
# For a transformed-space xlim, return the subset of canonical BF breaks
# (1/100, 1/10, 1/3, 1, 3, 10, 100, Inf) that fall inside the visible range.
# Endpoints map to the terminal asymptote position (~ +/- 3.4).
.bf_axis_spec <- function(xlim_transformed) {
  log10_vals <- c(-100, -2, -1, -log10(3), 0, log10(3), 1, 2, 100)
  bf_labels  <- c("0", "1/100", "1/10", "1/3", "1", "3", "10", "100", "Inf")

  t_vals <- .bf_evidence_transform(log10_vals)

  tol <- 0.05
  in_range <- t_vals >= (xlim_transformed[1] - tol) &
              t_vals <= (xlim_transformed[2] + tol)

  list(
    breaks = t_vals[in_range],
    labels = bf_labels[in_range]
  )
}


# ---- Per-row precision (1/SE) for orchard-style plots ----------------------
# Computes a precision column from credible-interval bounds, preferring the
# RoBMA-PSMA (BC) interval, falling back to the baseline RE interval, and
# imputing the median on rows without usable bounds. Final precision is
# winsorized at the 10th/90th percentiles for stable size-legend scaling.
#
# Requires dplyr (referenced via `dplyr::` so the helper works whether or not
# tidyverse is on the search path).
.compute_precision <- function(df) {
  df <- df %>%
    dplyr::mutate(
      se_bc = dplyr::if_else(is.finite(mu_BC_uCI) & is.finite(mu_BC_lCI),
                             (mu_BC_uCI - mu_BC_lCI) / (2 * 1.96), NA_real_),
      se_re = dplyr::if_else(is.finite(mu_RE_uCI) & is.finite(mu_RE_lCI),
                             (mu_RE_uCI - mu_RE_lCI) / (2 * 1.96), NA_real_),
      se    = dplyr::coalesce(se_bc, se_re),
      prec_raw = dplyr::if_else(is.finite(se) & se > 1e-10, 1/se, NA_real_)
    )

  if (all(is.na(df$prec_raw))) {
    df$prec <- 1
    message("  No CI info for precision; defaulting to 1 for all rows.")
    return(df)
  }

  df$prec_raw[!is.finite(df$prec_raw)] <- NA_real_
  medp <- median(df$prec_raw, na.rm = TRUE)
  df$prec_raw[is.na(df$prec_raw)] <- medp

  q10 <- suppressWarnings(quantile(df$prec_raw, 0.10, na.rm = TRUE))
  q90 <- suppressWarnings(quantile(df$prec_raw, 0.90, na.rm = TRUE))
  if (!is.finite(q10)) q10 <- min(df$prec_raw, na.rm = TRUE)
  if (!is.finite(q90)) q90 <- max(df$prec_raw, na.rm = TRUE)

  df$prec <- pmax(q10, pmin(q90, df$prec_raw))
  df
}


# ---- Sentinel ---------------------------------------------------------------
# Downstream scripts test for this to avoid re-sourcing 00_utils.R. The value
# itself is uninformative; only its existence matters.
.robma_utils_loaded <- TRUE
