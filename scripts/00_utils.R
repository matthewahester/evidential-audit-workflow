# 00_utils.R
# ------------------------------------------------------------------------------
# Central contract + shared helpers for the RoBMA 4.0 rigor-estimand pipeline.
#
# This is the single source of truth for the versioned sidecar schema, the
# selected-rigor estimand definition, allowed categorical labels, identity
# parsing, and the shared Bayes-factor / hashing helpers used by 20 and 40.
#
# Define-only: sourcing installs functions/constants and a load sentinel;
# nothing is read or written and no package is attached.
#
# Sourced (sentinel-guarded) by every active script: 10/20/40 (fitting
# layer), 30_zplot.R, 60_estimand_tables.R (reporting layer), and
# 50_stratum_visuals.R / 70_corpus_visuals.R (visual layer).
#
# Layout
#   * %||%, format_stratum(), is_meta_basename()
#   * BF evidence-axis transform/axes + .compute_precision() -- used by the
#     component ORCHARDS in 50/70 (the corpus-level component violins and the
#     selected-rigor figures use raw log10 axes instead)
#   * single-row estimand derivers (.delta_mu, .attenuation_pct, .shrink50,
#     .sign_flip, .bc_ci_includes_zero, .safe_log10_bf) -- used by
#     60_estimand_tables.R to regenerate derived reporting columns from
#     sidecar primitives
#   * v4 schema/estimand contract: versions, allowed labels, baseline
#     convention, .SIDECAR_V4_COLS, .ZPLOT_DIAG_COLS
#   * shared evidence/parse/identity utils: .stable_hash(), norm_slug(),
#     .safe_div(), .bf_from_odds(), same_bf(), .build_identity_fields(),
#     .rigor_category()
#   * LaTeX/threshold helpers (reporting layer); load sentinel
# ------------------------------------------------------------------------------


# ---- Null-default operator -------------------------------------------------
# Returns `a` if not NULL, otherwise `b` (rlang `%||%` semantics, no dep).
`%||%` <- function(a, b) if (!is.null(a)) a else b


# ---- Stratum-slug formatting -----------------------------------------------
# Convert a stratum slug (e.g. "vitamind") to a display label ("Vitamin D").
# Overrides for irregular slugs; otherwise title-case with underscores ->
# spaces. Vectorized; case-insensitive. (Consumed by the reporting layer.)
format_stratum <- function(slug) {
  overrides <- c(vitamind = "Vitamin D", omega3 = "Omega-3")
  out <- tools::toTitleCase(gsub("_", " ", slug))
  hit <- tolower(slug) %in% names(overrides)
  out[hit] <- overrides[tolower(slug)[hit]]
  out
}


# ---- Catalog/meta-file detection -------------------------------------------
# TRUE for helper / extraction-record CSVs that must never be fitted as a
# dataset (stems ending original_effects / studies / excluded).
is_meta_basename <- function(basename) {
  grepl("(original_effects|studies|excluded)$", basename, ignore.case = TRUE)
}


# ==== BAYES-FACTOR EVIDENCE AXIS ============================================

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


# ---- Compute padded transformed-axis x-limits from a log10(BF) vector ------
# Used to produce a stable, padded xlim that fits all observed values into
# the visible portion of the piecewise evidence transform. Clamped to the
# piecewise terminal bounds (+- 3.65) and defaulted to c(-1, 1) when the
# input is degenerate.
.compute_evidence_xlim <- function(log10bf_values) {
  log10bf_values <- log10bf_values[is.finite(log10bf_values)]
  if (length(log10bf_values) == 0L) return(c(-1, 1))

  all_t <- .bf_evidence_transform(log10bf_values)
  data_range <- range(all_t, na.rm = TRUE)
  range_width <- diff(data_range)
  padding <- max(0.15, range_width * 0.06)
  t_xlim <- c(data_range[1] - padding, data_range[2] + padding)
  t_xlim[1] <- max(t_xlim[1], -3.65)
  t_xlim[2] <- min(t_xlim[2],  3.65)
  if (!all(is.finite(t_xlim))) t_xlim <- c(-1, 1)
  t_xlim
}


# ---- Evidence-band background layers (ggplot) ------------------------------
# Return a list of ggplot annotate() layers that render the standard
# anecdotal / moderate / strong / very-strong evidence bands behind a plot.
# The list can be `+`-added to a ggplot. Used by the component ORCHARD
# figures in 50_stratum_visuals.R and 70_corpus_visuals.R (the corpus-level
# component violins and the selected-rigor figures use raw log10 axes and
# their own raw-log10 band helper instead).
.evidence_band_layers <- function(t_xlim) {
  band_edges <- .bf_evidence_transform(c(-2, -1, -log10(3), log10(3), 1, 2))
  be <- setNames(band_edges, c("m2", "m1", "m05", "p05", "p1", "p2"))

  layers <- list()
  push <- function(lo, hi, fill, alpha = 0.2) {
    if (hi <= lo) return(invisible(NULL))
    layers[[length(layers) + 1L]] <<- ggplot2::annotate(
      "rect", xmin = lo, xmax = hi,
      ymin = -Inf, ymax = Inf,
      fill = fill, alpha = alpha
    )
  }

  if (t_xlim[1] < be["m2"]) {
    push(t_xlim[1], min(t_xlim[2], be["m2"]), "gray10")
  }
  if (t_xlim[1] < be["m1"] && t_xlim[2] > be["m2"]) {
    push(max(t_xlim[1], be["m2"]), min(t_xlim[2], be["m1"]), "gray30")
  }
  if (t_xlim[1] < be["m05"] && t_xlim[2] > be["m1"]) {
    push(max(t_xlim[1], be["m1"]), min(t_xlim[2], be["m05"]), "gray70")
  }
  # Skip the white/neutral region from BF=1/3 to BF=3 by design.
  if (t_xlim[1] < be["p1"] && t_xlim[2] > be["p05"]) {
    push(max(t_xlim[1], be["p05"]), min(t_xlim[2], be["p1"]), "gray70")
  }
  if (t_xlim[1] < be["p2"] && t_xlim[2] > be["p1"]) {
    push(max(t_xlim[1], be["p1"]), min(t_xlim[2], be["p2"]), "gray30")
  }
  if (t_xlim[2] > be["p2"]) {
    push(max(t_xlim[1], be["p2"]), t_xlim[2], "gray10")
  }

  layers
}


# ---- Evidence-threshold guide lines (ggplot) -------------------------------
# Return a list of ggplot geom_vline() layers that draw the BF=1 solid line
# and the BF=1/100, 1/10, 1/3, 3, 10, 100 reference lines (dotted/dashed),
# clipped to the visible transformed range.
.evidence_guide_layers <- function(t_xlim) {
  layers <- list(
    ggplot2::geom_vline(xintercept = .bf_evidence_transform(0),
                        linetype = "solid", linewidth = 1.0, color = "gray20")
  )

  for (lbf in c(-log10(3), log10(3))) {
    tv <- .bf_evidence_transform(lbf)
    if (tv >= t_xlim[1] && tv <= t_xlim[2]) {
      layers[[length(layers) + 1L]] <- ggplot2::geom_vline(
        xintercept = tv, linetype = "dashed",
        linewidth = 0.8, color = "gray40"
      )
    }
  }
  for (lbf in c(-2, -1, 1, 2)) {
    tv <- .bf_evidence_transform(lbf)
    if (tv >= t_xlim[1] && tv <= t_xlim[2]) {
      layers[[length(layers) + 1L]] <- ggplot2::geom_vline(
        xintercept = tv, linetype = "dotted",
        linewidth = 0.8, color = "gray50"
      )
    }
  }
  layers
}


# ---- Per-row precision (1/SE) for orchard-style plots ----------------------
# Computes a precision column from credible-interval bounds, preferring the
# RoBMA-PSMA (BC) interval, falling back to the baseline RE interval when
# present, and imputing the median on rows without usable bounds. Final
# precision is winsorized at the 10th/90th percentiles for stable size-legend
# scaling.
#
# Defensive: works whether or not the input frame has the mu_RE_lCI/uCI cols
# (e.g. when reading the cleaned outcome_registry.csv, which exposes only the
# BC credible interval).
#
# Requires dplyr (referenced via `dplyr::` so the helper works whether or not
# tidyverse is on the search path).
.compute_precision <- function(df) {
  has_re_ci <- all(c("mu_RE_lCI", "mu_RE_uCI") %in% names(df))

  df <- df %>%
    dplyr::mutate(
      se_bc = dplyr::if_else(is.finite(mu_BC_uCI) & is.finite(mu_BC_lCI),
                             (mu_BC_uCI - mu_BC_lCI) / (2 * 1.96), NA_real_)
    )

  if (has_re_ci) {
    df <- df %>%
      dplyr::mutate(
        se_re = dplyr::if_else(is.finite(mu_RE_uCI) & is.finite(mu_RE_lCI),
                               (mu_RE_uCI - mu_RE_lCI) / (2 * 1.96), NA_real_),
        se    = dplyr::coalesce(se_bc, se_re)
      )
  } else {
    df <- df %>% dplyr::mutate(se = se_bc)
  }

  df <- df %>%
    dplyr::mutate(
      prec_raw = dplyr::if_else(is.finite(se) & se > 1e-10, 1 / se, NA_real_)
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


# ==== ESTIMAND-FIELD DERIVERS (per-row) =====================================
# Single-source-of-truth functions for derived sidecar / table fields. Used
# by 20_robma_fit.R when building each sidecar row, and by 60_estimand_tables.R
# when migrating legacy sidecars to the canonical schema.
#
# All derivers are vectorized over their numeric inputs and return NA_*
# values in degenerate cases. The "near-zero" epsilon used for sign/shrink
# safeguards is 1e-6 by default.

# Extract a trailing 4-digit year from an author slug (e.g. "morton2018" -> 2018).
# Returns NA_integer_ when no trailing 4-digit run is present.
.parse_year_from_author <- function(author) {
  ifelse(is.na(author), NA_integer_, {
    m <- regmatches(author, regexpr("\\d{4}$", author))
    out <- suppressWarnings(as.integer(m))
    if (length(out) == 0L) out <- NA_integer_
    out
  })
}

# TRUE when an effect slug ends in "_ex" or "_excl" (case-insensitive).
# These are sensitivity-variant outcomes (e.g. with low-quality studies removed).
.detect_excl_variant <- function(effect) {
  grepl("_(ex|excl)$", effect, ignore.case = TRUE)
}

# Baseline-RE -> RoBMA-PSMA effect-size delta.
.delta_mu <- function(mu_RE, mu_BC) mu_BC - mu_RE

# Percent attenuation from baseline RE to RoBMA-PSMA. NA when |mu_RE| is
# below `eps` (the "safe NA near zero" rule, since dividing by a near-zero
# baseline produces meaningless percentages).
.attenuation_pct <- function(mu_RE, mu_BC, eps = 1e-6) {
  ifelse(is.finite(mu_RE) & is.finite(mu_BC) & abs(mu_RE) > eps,
         100 * (mu_BC - mu_RE) / abs(mu_RE),
         NA_real_)
}

# Indicator: bias-adjusted estimate is at most half the baseline magnitude.
# NA when either input is non-finite, or when |mu_RE| is below eps (no
# meaningful "half" of a baseline that is effectively zero).
.shrink50 <- function(mu_RE, mu_BC, eps = 1e-6) {
  ifelse(is.finite(mu_RE) & is.finite(mu_BC) & abs(mu_RE) > eps,
         abs(mu_BC) <= 0.5 * abs(mu_RE),
         NA)
}

# Indicator: sign of bias-adjusted estimate differs from sign of baseline.
# NA when either input is non-finite; FALSE when either is within eps of zero
# (where the "sign" is not meaningfully defined).
.sign_flip <- function(mu_RE, mu_BC, eps = 1e-6) {
  ifelse(is.finite(mu_RE) & is.finite(mu_BC) &
           abs(mu_RE) > eps & abs(mu_BC) > eps,
         sign(mu_RE) != sign(mu_BC),
         NA)
}

# Indicator: bias-adjusted 95% credible interval contains zero.
.bc_ci_includes_zero <- function(lo, hi) {
  ifelse(is.finite(lo) & is.finite(hi),
         lo <= 0 & 0 <= hi,
         NA)
}

# Inf-preserving log10 of a Bayes factor.
#
# Bayes factors of Inf and 0 are MEANINGFUL (overwhelming evidence for / against
# inclusion respectively); the corresponding log10 values Inf and -Inf carry
# the same information and downstream tables must not collapse them to NA.
# Only NA / NaN / negative inputs become NA_real_ (a negative BF is impossible
# and indicates an upstream bug worth surfacing).
.safe_log10_bf <- function(bf) {
  bf  <- suppressWarnings(as.numeric(bf))
  out <- rep(NA_real_, length(bf))

  bad_neg <- !is.na(bf) & bf < 0
  if (any(bad_neg)) {
    warning(sprintf("Negative Bayes factor(s) coerced to NA: %s",
                    paste(bf[bad_neg], collapse = ", ")))
  }

  ok <- !is.na(bf) & !is.nan(bf) & bf >= 0
  out[ok] <- suppressWarnings(log10(bf[ok]))   # log10(0) = -Inf, log10(Inf) = Inf
  out
}

# Backward-compat alias: prior code calls .log10_bf(); the floor-at-1e-10
# behaviour was wrong (it silently converted Inf to NA). Route both names to
# the Inf-preserving implementation.
.log10_bf <- function(bf, ...) .safe_log10_bf(bf)


# ==== SCHEMA & ESTIMAND CONTRACT (v4) =======================================
# Single source of truth for the versioned rigor-estimand contract. 20/40 read
# these constants instead of redefining them, so the sidecar schema, allowed
# categorical values, and estimand definition cannot drift between scripts.
# Bumping a version string here makes every old sidecar row fail resume and
# acceptance (the version also feeds .config_signature() in 20_robma_fit.R).

# Sidecar column contract. Bump on ANY change to the column set/order/types.
.SCHEMA_VERSION   <- "sidecar_v4.0"

# Rigor estimand definition. "rigor_selected_v1" == the SELECTED statistic
# log10BF_rigor = max(branch effect/no-bias, branch no-effect/no-bias) with a
# retained direction. This deliberately supersedes the archived effect-only
# rigor prototype; any sidecar lacking this exact string is stale/incompatible.
.ESTIMAND_VERSION <- "rigor_selected_v1"

# Parser-safe stored values. "null" is intentionally NOT allowed for
# rigor_direction (it is a missing-value sentinel for pandas/Excel/JSON).
.RIGOR_DIRECTION_LEVELS  <- c("effect", "no_effect")
.ANALYSIS_VARIANT_LEVELS <- c("main", "exclusion_sensitivity")

# Minimum RoBMA major version whose product-space artifacts may satisfy a v4
# run. Archived RoBMA 3.6.x outputs (major < 4) are always stale.
.ROBMA_MAJOR_MIN  <- 4L
.FIT_ENGINE_FAMILY <- "RoBMA4"

# Unadjusted baseline provenance convention (README "Implementation target").
# brma() is a single Bayesian random-effects model: an effect-present,
# heterogeneity-present, no-modeled-bias model family; it is NOT model-averaged
# and is NOT bias-adjusted. model-family grammar matches the mu/tau/omega names.
.BASELINE_CONVENTION <- list(
  baseline_engine         = "brma",
  baseline_model_family   = "muplus_tauplus_omega0",
  baseline_model_averaged = FALSE,
  baseline_bias_adjusted  = FALSE
)

# Component key -> the rowname RoBMA 4.0 uses in
# summary()$inclusion_components and summary_models()$marginal. Centralized for
# a one-line future relabel. NOTE: "Publication Bias" here is the modeled
# publication-bias / small-study-effect component (omega+); omega0 (no modeled
# bias) is its complement and does NOT prove the literature is bias-free.
.RoBMA4_COMPONENT <- c(
  effect = "Effect",
  het    = "Heterogeneity",
  bias   = "Publication Bias"
)

# README rigor-category reporting threshold. Selected rigor whose magnitude is
# within this on the log10 axis (BF roughly in [1/3, 3]) is reported as
# inconclusive clean evidence rather than supported/disfavored.
.RIGOR_NEARZERO_THRESHOLD <- 0.5

# Canonical v4 sidecar columns: this exact vector is the on-disk order and
# the lean primitive/audit contract every downstream script must expect.
# This is a PRIMITIVE table, not a reporting dump: derived reporting
# conveniences (delta_mu / attenuation / shrink / sign-flip / CI-zero, the
# mu|omega conditionals) are NOT stored here -- 60_estimand_tables.R
# regenerates them from these primitives. Non-core as_zplot bias diagnostics
# live in a separate per-stratum artifact (see .ZPLOT_DIAG_COLS), not here.
# Bump .SCHEMA_VERSION on ANY change to this set/order.
.SIDECAR_V4_COLS <- c(
  # ---- identity & corpus metadata ----
  "corpus_id", "scheme", "stratum", "dataset_id", "analysis_id",
  "source_key", "source_article", "source_year", "outcome_slug",
  "analysis_variant", "parent_dataset_id", "exclusion_reason",
  "path_stratum", "legacy_basename", "has_excl_variant",
  "positive_effect_interpretation", "schema_version", "estimand_version",
  # ---- source/dataset + baseline + posterior summaries ----
  "n_studies",
  "baseline_engine", "baseline_model_family",
  "baseline_model_averaged", "baseline_bias_adjusted",
  "mu_RE", "mu_RE_lCI", "mu_RE_uCI",
  "mu_BC", "mu_BC_lCI", "mu_BC_uCI",
  "tau_RE", "tau_RE_lCI", "tau_RE_uCI",
  "tau_BC", "tau_BC_lCI", "tau_BC_uCI",
  # ---- marginal component evidence ----
  "prior_p_effect",  "post_p_effect",  "log10BF_effect",
  "prior_p_het",     "post_p_het",     "log10BF_het",
  "prior_p_bias",    "post_p_bias",    "log10BF_bias",
  "prior_p_no_bias", "post_p_no_bias", "log10BF_no_bias",
  # ---- joint mu x omega model-family evidence ----
  "prior_p_muplus_omega0",     "post_p_muplus_omega0",     "log10BF_muplus_omega0",
  "prior_p_mu0_omega0",        "post_p_mu0_omega0",        "log10BF_mu0_omega0",
  "prior_p_muplus_omegaplus",  "post_p_muplus_omegaplus",  "log10BF_muplus_omegaplus",
  "prior_p_mu0_omegaplus",     "post_p_mu0_omegaplus",     "log10BF_mu0_omegaplus",
  # ---- selected rigor evidence ----
  # log10BF_rigor is the SELECTED max of the two branch BFs (NOT a single
  # fixed-family BF), so there is no single prior_p_rigor/post_p_rigor: the
  # explicit branch fields are authoritative. The no-effect branch is named
  # `_no_effect` (parser-safe), never `_null`.
  "prior_p_rigor_effect",    "post_p_rigor_effect",    "log10BF_rigor_effect",
  "prior_p_rigor_no_effect", "post_p_rigor_no_effect", "log10BF_rigor_no_effect",
  "log10BF_rigor", "rigor_direction", "rigor_margin", "rigor_category",
  # ---- validation & reproducibility ----
  "family_evidence_uncertain", "partition_ok", "unresolved_labels",
  "component_probability_validation_ok", "component_bf_validation_ok",
  "component_validation_ok", "validation_failure_reason",
  "max_abs_diff_component_prior",
  "max_abs_diff_component_post", "max_abs_diff_component_bf",
  "sample", "burnin", "adapt", "chains", "thin", "seed",
  "model_type", "effect_direction", "config_hash", "script_hash",
  "robma_version", "bayestools_version", "measure", "fit_engine",
  "run_id"
)

# Separate per-stratum bias-diagnostics artifact schema. The as_zplot ODR /
# EDR / Soric FDR / Missing-N values are secondary, non-blocking diagnostics;
# they are written to output/<stratum>/<stratum>_zplot_diagnostics.csv keyed
# by dataset_id so the canonical sidecar stays a lean primitive table.
.ZPLOT_DIAG_COLS <- c(
  "dataset_id", "analysis_id", "stratum",
  "ODR", "EDR", "Soric_FDR", "MissingN", "run_id"
)


# ==== SHARED EVIDENCE / PARSE / IDENTITY UTILITIES ==========================
# One implementation shared by 20 (extractor + sidecar row) and 40 (resume +
# sidecar_acceptance), so the math/labels cannot drift between scripts.

# Stable, comparable hash of an arbitrary value. Uses digest::xxhash64 when
# available but NEVER auto-installs it; otherwise the filename-safe collapsed
# string IS the hash. Backs both .config_hash() and .script_hash() in 20.
.stable_hash <- function(x) {
  s <- paste(as.character(x), collapse = "|")
  if (requireNamespace("digest", quietly = TRUE)) {
    digest::digest(s, algo = "xxhash64")
  } else {
    paste0("nodigest:", gsub("[^A-Za-z0-9|=._-]+", "_", s))
  }
}

# Normalize a string to a lowercase slug with underscores.
norm_slug <- function(x) {
  gsub("[^a-z0-9_]+", "_", tolower(gsub("\\.", "_", x)))
}

# Parse the outcome slug out of a dataset stem
# (<source_article>_<stratum>_<outcome_slug...>). Centralized so the catalog
# (10), the batch driver (40), and the registry anti-join all agree.
#
# Empirical stems always carry >= 3 underscore tokens
# (<author>_<stratum>_<outcome...>), so the >= 3 branch is the empirical
# contract and is unchanged. The short-stem branch previously collapsed
# to a constant "misc", which makes every short-stem dataset in a given
# (stratum, source_article) folder share one dataset_id -- a latent
# uniqueness bug. Returning the (lowercased) stem itself instead keeps
# the outcome slug unique per file. This is what lets the simulation
# layer use a compact, folder-disambiguated stem such as "rep0001"
# (the synthetic stratum is already carried by the data/<stratum>/
# folder, so the stem must NOT restate it). Verified: no empirical data
# stem has < 3 tokens, so this changes nothing for the real corpus.
.outcome_slug_from_stem <- function(stem) {
  parts <- strsplit(stem, "_")[[1]]
  if (length(parts) >= 3) tolower(paste(parts[3:length(parts)], collapse = "_"))
  else tolower(stem)
}

# ---- Effect-size input contract --------------------------------------------
# Preferred/default input is Hedges' g as `g`/`se_g`. As a no-rename
# compatibility fallback, datasets that instead carry Cohen's d as `d`/`se_d`
# are accepted. Both feed RoBMA as yi/sei under CONFIG$measure = "SMD" (g and
# d share the SMD scale / unit-information-SD interface; the pipeline does not
# distinguish them downstream). Preference order is FIXED, never configurable:
# g/se_g first, then d/se_d. Shared by 20 (fitter) and 40 (runnable filter) so
# the accepted column set cannot drift between scripts.
.EFFECT_INPUT_PAIRS <- list(
  g_se_g = c(est = "g", se = "se_g"),
  d_se_d = c(est = "d", se = "se_d")
)

# TRUE if `df` is a non-empty data.frame carrying at least one COMPLETE
# effect-size input pair (used by 40_batch_fit.R's runnable filter).
.has_effect_input <- function(df) {
  if (!is.data.frame(df) || nrow(df) == 0L) return(FALSE)
  any(vapply(.EFFECT_INPUT_PAIRS,
             function(p) all(p %in% names(df)), logical(1)))
}

# Resolve the effect-size columns for a fit and validate the selected pair.
#   * g/se_g present                 -> use g/se_g (preferred/default)
#   * only d/se_d present            -> use d/se_d (fallback; message)
#   * both pairs present             -> prefer g/se_g (message)
#   * neither complete pair present  -> stop() with a clear contract message
# The same finite-estimate / finite-positive-SE validation is applied to
# whichever pair is selected. Returns
#   list(yi, sei, effect_input = "g_se_g"|"d_se_d", est_col, se_col).
.resolve_effect_input <- function(data) {
  if (!is.data.frame(data)) stop("data must be a data.frame")
  has_pair <- function(p) all(p %in% colnames(data))
  g_ok <- has_pair(.EFFECT_INPUT_PAIRS$g_se_g)
  d_ok <- has_pair(.EFFECT_INPUT_PAIRS$d_se_d)

  if (!g_ok && !d_ok)
    stop("No usable effect-size columns: the dataset needs either ",
         "'g' + 'se_g' (preferred) or 'd' + 'se_d' (fallback).")

  if (g_ok) {
    pair <- .EFFECT_INPUT_PAIRS$g_se_g; tag <- "g_se_g"
    if (d_ok)
      message("Both g/se_g and d/se_d present; using preferred g/se_g.")
  } else {
    pair <- .EFFECT_INPUT_PAIRS$d_se_d; tag <- "d_se_d"
    message("g/se_g absent; using fallback effect-size columns d/se_d.")
  }

  est <- data[[pair[["est"]]]]
  se  <- data[[pair[["se"]]]]
  bad_est <- which(!is.finite(est))
  bad_se  <- which(!is.finite(se) | se <= 0)
  if (length(bad_est) > 0)
    stop(sprintf("Non-finite %s values in %d rows. First few: %s",
                 pair[["est"]], length(bad_est),
                 paste(utils::head(bad_est, 5), collapse = ", ")))
  if (length(bad_se) > 0)
    stop(sprintf("Invalid %s values in %d rows. First few: %s",
                 pair[["se"]], length(bad_se),
                 paste(utils::head(bad_se, 5), collapse = ", ")))

  list(yi = as.numeric(est), sei = as.numeric(se),
       effect_input = tag,
       est_col = pair[["est"]], se_col = pair[["se"]])
}

# Safe division: NA if denominator is 0, missing, or non-finite.
.safe_div <- function(num, den) {
  num <- suppressWarnings(as.numeric(num))
  den <- suppressWarnings(as.numeric(den))
  if (length(num) == 0L || length(den) == 0L) return(NA_real_)
  if (!is.finite(num) || !is.finite(den) || den == 0) return(NA_real_)
  num / den
}

# Inclusion Bayes factor from a prior/posterior family mass pair.
#   BF = posterior odds / prior odds
# Inf / 0 are MEANINGFUL and preserved; a degenerate prior family mass
# (<=0 or >=1) yields NA (inclusion BF undefined there). This joint-mass form
# is used for EVERY component / family / rigor-branch BF -- never a product
# of marginal BFs.
.bf_from_odds <- function(prior_p, post_p) {
  prior_p <- suppressWarnings(as.numeric(prior_p))
  post_p  <- suppressWarnings(as.numeric(post_p))
  if (!is.finite(prior_p) || !is.finite(post_p))      return(NA_real_)
  if (prior_p <= 0 || prior_p >= 1)                   return(NA_real_)
  if (post_p  >= 1)                                   return(Inf)
  if (post_p  <= 0)                                   return(0)
  (post_p / (1 - post_p)) / (prior_p / (1 - prior_p))
}

# Robust Bayes-factor equality, safe at the post -> 0/1 saturation boundary.
#   * NA in        -> NA out (uncomparable; caller decides)
#   * both +/-Inf same sign -> match (overwhelming evidence, same direction)
#   * one Inf vs a same-sign finite value AT the .bf_from_odds saturation
#     scale (|x| >= 1/.Machine$double.eps) -> match. This is NOT a weakening:
#     .bf_from_odds() is discontinuous at the posterior boundary (post = 1
#     -> Inf, but post = 1 - ~1e-16 -> a huge finite ~9e15), so two posteriors
#     equal within fp-eps can map to {Inf, ~9e15}. Both are the SAME
#     overwhelming evidence and the v4 contract treats Inf BFs as valid
#     evidence, not a contradiction. Only fires at that exact knife-edge.
#   * any OTHER one-Inf case (ordinary-magnitude finite vs Inf) -> mismatch
#   * both exactly 0        -> match
#   * exactly one 0         -> mismatch
#   * both finite > 0       -> equal on the log10 scale within `tol`
# Callers must compare BFs computed under the SAME definition (recompute the
# package BF from the package's own prior/post so identical inputs give
# identical saturation).
same_bf <- function(a, b, tol = 1e-3) {
  if (is.na(a) || is.na(b)) return(NA)
  if (is.infinite(a) || is.infinite(b)) {
    if (is.infinite(a) && is.infinite(b)) return(sign(a) == sign(b))
    # exactly one Inf: a same-sign finite value at the odds-form saturation
    # scale is the post->{0,1} image of the other side (see note above).
    fin <- if (is.infinite(a)) b else a
    inf <- if (is.infinite(a)) a else b
    return(is.finite(fin) && fin != 0 && sign(fin) == sign(inf) &&
           abs(fin) >= 1 / .Machine$double.eps)
  }
  if (a == 0 || b == 0) {
    return(a == 0 && b == 0)
  }
  abs(log10(a) - log10(b)) <= tol
}

# Strip a trailing _ex / _excl token (case-insensitive). The non-stripped
# stem/outcome is the parent (full reconstructed) analysis of record.
.strip_excl_suffix <- function(x) {
  sub("_(ex|excl)$", "", x, ignore.case = TRUE)
}

# Structured analysis-variant label for one analysis. An `_excl` CSV is a
# formal exclusion-sensitivity variant, NOT a filename accident. Returns one
# of .ANALYSIS_VARIANT_LEVELS.
.analysis_variant_for <- function(outcome_slug, dataset_id = NULL) {
  is_excl <- isTRUE(.detect_excl_variant(outcome_slug)) ||
    (!is.null(dataset_id) &&
       grepl("_(ex|excl)$", dataset_id, ignore.case = TRUE))
  if (is_excl) "exclusion_sensitivity" else "main"
}

# Build the explicit identity/corpus metadata for one analysis from already-
# slugged parts. This is the single parser used by BOTH list_datasets()
# (10_load_data.R) and the v4 sidecar row builder (20_robma_fit.R), so the
# portable analysis_id and the legacy dataset_id stem can never disagree.
#
#   * dataset_id stays the compact legacy stem (e.g.
#     "whelton2005_fiber_systolic_bp"); it remains the stable join key.
#   * analysis_id is the portable canonical id, e.g.
#     "nutrition_v4__fiber__whelton2005__systolic_bp__main" (the _excl
#     companion shares everything but the trailing variant slug, making the
#     pair relationship explicit).
#   * source_key is the per-source-article grouping key (a(k) in the README
#     article-balanced summaries); currently the <author><year> token.
#   * exclusion_reason: a transparent placeholder for exclusion-sensitivity
#     rows (the per-dataset reason is not in machine metadata; see
#     data_dictionary.md), NA for main analyses. No specific reason invented.
#   * positive_effect_interpretation: not recoverable from the g/se_g CSVs ->
#     NA placeholder rather than an invented meaning (see effect_direction).
.build_identity_fields <- function(corpus_id, scheme, stratum,
                                    source_article, outcome_slug,
                                    dataset_id, path_stratum) {
  variant       <- .analysis_variant_for(outcome_slug, dataset_id)
  is_excl       <- identical(variant, "exclusion_sensitivity")
  parent_outcome <- .strip_excl_suffix(outcome_slug)
  variant_slug  <- if (is_excl) "excl" else "main"

  list(
    corpus_id        = corpus_id,
    scheme           = scheme,
    stratum          = stratum,
    dataset_id       = dataset_id,
    analysis_id      = sprintf("%s__%s__%s__%s__%s",
                               corpus_id, stratum, source_article,
                               parent_outcome, variant_slug),
    source_key       = source_article,
    source_article   = source_article,
    source_year      = .parse_year_from_author(source_article),
    outcome_slug     = outcome_slug,
    analysis_variant = variant,
    parent_dataset_id = if (is_excl)
      sprintf("%s_%s_%s", source_article, stratum, parent_outcome)
      else NA_character_,
    exclusion_reason = if (is_excl)
      "unspecified__see_data_dictionary" else NA_character_,
    path_stratum     = path_stratum,
    legacy_basename  = dataset_id,
    has_excl_variant = is_excl,
    positive_effect_interpretation = NA_character_
  )
}

# Derived categorical interpretation of the SELECTED rigor evidence (README
# "rigor_category" table). Keyed off the SELECTED statistic + direction, NOT
# the non-selected branch, so an infinite non-selected branch (e.g. one
# branch = -Inf, hence rigor_margin = Inf) does not force NA. Because
# log10BF_rigor is the max of the two branches, R < -near_zero already implies
# BOTH branches are clearly negative ("disfavored"), and that test is robust
# to a -Inf branch. The near-zero (inconclusive) band is tested first so a
# selected rigor inside the reporting threshold is never called
# supported/disfavored. Vectorized. NA only when the selected statistic itself
# is genuinely missing (R is NA), or R is supported-magnitude but direction is
# absent.
#
#   inconclusive_clean_evidence : finite |log10BF_rigor| <= near_zero
#   clean_evidence_disfavored   : log10BF_rigor < -near_zero  (incl. -Inf)
#   clean_effect_supported      : direction "effect"    & rigor >  near_zero
#   clean_no_effect_supported   : direction "no_effect" & rigor >  near_zero
.rigor_category <- function(log10BF_rigor_effect, log10BF_rigor_no_effect,
                            log10BF_rigor   = NULL,
                            rigor_direction = NULL,
                            near_zero = .RIGOR_NEARZERO_THRESHOLD) {
  e <- suppressWarnings(as.numeric(log10BF_rigor_effect))
  n <- suppressWarnings(as.numeric(log10BF_rigor_no_effect))
  if (is.null(log10BF_rigor)) {
    R <- pmax(e, n, na.rm = FALSE)
  } else {
    R <- suppressWarnings(as.numeric(log10BF_rigor))
  }
  if (is.null(rigor_direction)) {
    rigor_direction <- ifelse(is.na(e) | is.na(n), NA_character_,
                              ifelse(e >= n, "effect", "no_effect"))
  } else {
    rigor_direction <- as.character(rigor_direction)
  }

  out     <- rep(NA_character_, length(R))
  have_R  <- !is.na(R)                       # selected rigor present (may be Inf)
  inc  <- have_R & is.finite(R) & abs(R) <= near_zero
  dis  <- have_R & !inc & R < -near_zero     # max < -near_zero => both clearly < 0
  eff  <- have_R & !inc & !dis & !is.na(rigor_direction) &
          rigor_direction == "effect"    & R >  near_zero
  neff <- have_R & !inc & !dis & !is.na(rigor_direction) &
          rigor_direction == "no_effect" & R >  near_zero
  out[inc]  <- "inconclusive_clean_evidence"
  out[dis]  <- "clean_evidence_disfavored"
  out[eff]  <- "clean_effect_supported"
  out[neff] <- "clean_no_effect_supported"
  out
}


# ==== EVIDENCE-THRESHOLD CONSTANTS ==========================================
# Centralized thresholds used by 60_estimand_tables.R to compute proportions
# on the log10(BF) axis. Changing the values here changes every downstream
# table consistently. The user-facing names (prop_effect_inconclusive,
# prop_bias_moderate, etc.) describe meaning, not threshold values; the
# numeric boundaries live here.
#
#   inconclusive  : |log10 BF| <= 0.5    (BF in [~1/3, ~3])
#   moderate      :  log10 BF  >  0.5    (BF >  ~3)
#   strong        :  log10 BF  >  1.0    (BF > 10)
#   moderate_null :  log10 BF  < -0.5    (BF <  ~1/3)
#   strong_null   :  log10 BF  < -1.0    (BF <  1/10)
#
# Claimed-effect anchor:
#   |mu_RE| >= claimed_mu_threshold   (default 0.2, "small-to-moderate" effect)
.EVIDENCE_THRESHOLDS <- list(
  inconclusive          = 0.5,
  moderate              = 0.5,
  strong                = 1.0,
  moderate_null         = -0.5,
  strong_null           = -1.0,
  claimed_mu_threshold  = 0.2
)


# ==== LATEX HELPERS =========================================================

# Escape characters with LaTeX-special meaning. The backslash replacement
# `\textbackslash{}` itself contains braces, which the later { / } passes
# would double-escape, so we route backslashes through a sentinel that
# contains no LaTeX-special characters and restore them at the end.
.latex_escape <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  BSL <- "\001BACKSLASH\001"
  x <- gsub("\\", BSL,                    x, fixed = TRUE)
  x <- gsub("&",  "\\&",                  x, fixed = TRUE)
  x <- gsub("%",  "\\%",                  x, fixed = TRUE)
  x <- gsub("$",  "\\$",                  x, fixed = TRUE)
  x <- gsub("#",  "\\#",                  x, fixed = TRUE)
  x <- gsub("_",  "\\_",                  x, fixed = TRUE)
  x <- gsub("{",  "\\{",                  x, fixed = TRUE)
  x <- gsub("}",  "\\}",                  x, fixed = TRUE)
  x <- gsub("~",  "\\textasciitilde{}",   x, fixed = TRUE)
  x <- gsub("^",  "\\textasciicircum{}",  x, fixed = TRUE)
  x <- gsub(BSL,  "\\textbackslash{}",    x, fixed = TRUE)
  x
}

# Format a numeric vector to fixed decimals; non-finite/NA -> "---".
.fmt_num <- function(x, digits) {
  if (is.null(x)) return(character(0))
  ifelse(is.na(x) | !is.finite(x), "---",
         formatC(x, format = "f", digits = digits))
}

# Format a proportion (0..1) as a "NN.N\%" string with one decimal; NA -> "---".
# Output is LaTeX-safe: the trailing percent is emitted as "\%" so the rendered
# tables don't treat it as the LaTeX comment character. Only consumed by the
# TeX renderers in 60_estimand_tables.R.
.fmt_pct <- function(x, digits = 1L) {
  ifelse(is.na(x) | !is.finite(x), "---",
         paste0(formatC(100 * x, format = "f", digits = digits), "\\%"))
}


# ==== SEMANTIC VISUAL PALETTE ===============================================
# Single source of truth for color choices across the v4 visual layer
# (50_stratum_visuals.R, 70_corpus_visuals.R, simulation/scripts/
# 75_analysis_visuals.R; pre-2026-05 path was 75_composition_visuals.R).
# Colors are chosen by semantic role, NOT by
# scale convenience: every figure that talks about the same concept reads
# from the same key here, so a single edit propagates through the whole
# manuscript figure family.
#
# Design constraints (see docs/visual_color_contract.md for the spec):
#   * Baseline RE / unadjusted estimate = BLUE.
#   * RoBMA-PSMA / bias-adjusted estimate = RED. Never swap these.
#   * No saturated green as a default. Sage/teal greens are allowed when
#     they carry a clear semantic role; large green fills are avoided.
#   * `no_effect` is a positive evidential state, NOT a failure/warning.
#   * Diagnostics: gray = neutral/reference; amber = warning; muted red
#     = failure; light gray = missing/unavailable.
#
# Hex values only; no ggplot2 dependency. Plotting scripts pull keys via
# `.VIS_COLORS$<role>` so this file can be sourced as a pure utility.
.VIS_COLORS <- list(
  # Neutral structural colors: panels, gridlines, reference lines, NAs.
  neutral = c(
    ink         = "#212121",   # primary marks / dark points
    text        = "#37474F",   # axis text / dark slate
    panel_bg    = "gray92",    # panel fill
    grid        = "gray85",    # gridlines
    border      = "gray40",    # panel border
    reference   = "gray35",    # truth / reference lines (e.g. mu_true)
    missing     = "#CFD8DC",   # NA / unavailable tiles
    sparse      = "#9E9E9E"    # sparse-but-non-empty cells
  ),

  # Method comparison: baseline RE vs RoBMA-PSMA. THIS MAPPING IS
  # LOAD-BEARING. Do not reverse without updating every caption that
  # names "Baseline" / "RoBMA-PSMA".
  method = c(
    baseline_re = "#2166AC",   # Baseline RE / unadjusted = BLUE
    robma_psma  = "#B2182B"    # RoBMA-PSMA / bias-adjusted = RED
  ),

  # Selected-rigor direction. Both are POSITIVE evidential states; no
  # red here so `no_effect` does not read as failure.
  rigor_direction = c(
    effect    = "#0072B2",     # Okabe-Ito blue
    no_effect = "#7A5195"      # muted purple (calm partner to blue)
  ),

  # Selected-rigor category. Effect / no-effect mirror rigor_direction;
  # disfavored = muted brown; inconclusive / uncategorized = neutral
  # grays of increasing lightness.
  rigor_category = c(
    clean_effect_supported      = "#0072B2",  # matches effect
    clean_no_effect_supported   = "#7A5195",  # matches no_effect
    clean_evidence_disfavored   = "#8B5A3C",  # muted brown
    inconclusive_clean_evidence = "#B0BEC5",  # light slate
    uncategorized               = "#9E9E9E"   # neutral gray
  ),

  # Bias-burden severity (ordered). Clean is neutral; do NOT use
  # traffic-light green for clean. Severity ramps slate -> amber -> red.
  bias_burden = c(
    clean    = "#5C6B73",      # neutral slate (no green)
    modbias  = "#EF6C00",      # amber/orange
    highbias = "#B2182B"       # muted red
  ),

  # Heterogeneity ordering. When a figure already encodes bias by color
  # (the common case), use linetype/shape for heterogeneity to free up
  # the color channel and stay grayscale-readable.
  heterogeneity_linetype = c(
    lowhet = "solid", midhet = "22", highhet = "44"
  ),
  heterogeneity_shape = c(
    lowhet = 16L, midhet = 17L, highhet = 15L
  ),

  # Effect-band ordering (null/small/moderate/large). Most figures
  # facet by effect band; if color is still needed, use this restrained
  # sequential ramp instead of categorical hues.
  effect_level = c(
    null     = "#CFD8DC",
    small    = "#90A4AE",
    moderate = "#546E7A",
    large    = "#263238"
  ),

  # Empirical vs synthetic overlays.
  resampling_source = c(
    empirical_observed    = "#212121",  # ink point
    empirical_bootstrap   = "#2166AC",  # muted blue
    synthetic_composition = "#7A5195"   # muted purple
  ),

  # Empirical bootstrap modes (within Q2). Outcome / source-cluster
  # are paired alternatives, not severity; choose visually distinct
  # but non-loaded hues. Amber instead of red so source_cluster does
  # not read as "failure".
  bootstrap_mode = c(
    outcome        = "#0072B2",
    source_cluster = "#EF6C00"
  ),

  # Diagnostic status. PASS is neutral (no green). Amber/red for
  # increasing concern; light gray for unavailable.
  diagnostic = c(
    pass        = "#37474F",   # muted blue-gray (neutral)
    info        = "#0277BD",   # marine blue
    warning     = "#F9A825",   # amber
    fail        = "#B2182B",   # muted red
    unavailable = "#CFD8DC"    # light gray
  ),

  # Synthetic-library support coverage (empty / sparse / supported).
  # `supported` is neutral blue-gray rather than green; the figure
  # rewards reviewers' attention with the orange/red anomalies.
  support = c(
    empty     = "#B2182B",
    sparse    = "#F9A825",
    supported = "#37474F"
  ),

  # Heatmap ramps. Sequential ramps go cream -> deep teal (no
  # saturated green). Diverging ramps span muted red <- cream -> muted
  # sage so the zero band is the visual anchor.
  heat = list(
    sequential_low  = "#F7F4EF",
    sequential_high = "#1B5E63",
    diverging_neg   = "#B2182B",
    diverging_zero  = "#F7F4EF",
    diverging_pos   = "#1B6B5E"
  ),

  # Three-component triad for the stratum-level component panels
  # (effect / heterogeneity / bias). Used by the vertical three-panel
  # stack in 50_stratum_visuals.R. Heterogeneity uses muted teal
  # instead of saturated Okabe-Ito green.
  component = c(
    effect        = "#0072B2",   # Okabe-Ito blue
    heterogeneity = "#1B5E63",   # muted teal (replaces #009E73)
    bias          = "#D55E00"    # Okabe-Ito vermilion
  ),

  # Categorical stratum palette for the corpus / stratum violin family.
  # Order matches the manuscript figure order; the previously saturated
  # plant-green entry is muted to sage so it sits inside the rest of
  # the muted palette.
  stratum_palette = c(
    "#263238",   # base charcoal
    "#557755",   # plant sage (was #1B5E20)
    "#1B5E63",   # deep teal
    "#6D4C41",   # grain brown
    "#F9A825",   # micronutrient gold
    "#EF6C00",   # supplement orange
    "#8E24AA",   # metabolic purple
    "#0277BD",   # marine blue
    "#37474F"    # slate (filler)
  )
)

# ---- Sentinel ---------------------------------------------------------------
# Downstream scripts test for this to avoid re-sourcing 00_utils.R. The value
# itself is uninformative; only its existence matters.
.robma_utils_loaded <- TRUE
