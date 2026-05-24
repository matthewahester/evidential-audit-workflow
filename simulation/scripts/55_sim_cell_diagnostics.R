# 55_sim_cell_diagnostics.R - Per-cell rigor / component diagnostics.
#
# Define-only on source. Builds per-cell rigor + component diagnostic
# tables from whatever simulation sidecars are currently readable under
# output_sim_v30. Safe to run at any library size while the background
# fit driver is still writing.
#
# Hard contract (mirrors 40_sim_run.R / 50_sim_fit_monitor.R):
#   * READ-ONLY on output_sim_v30; never fits, never calls batch_fit().
#   * Generated / fitted counts come from sim_inventory_library() so the
#     answer to "how big is the current library?" lives in exactly one
#     place. Each per-cell row carries n_generated + n_fit (the sample-
#     size context for that cell's metric value); library-wide progress
#     bookkeeping (library_status, fit_fraction, expected_source,
#     generated_reps_*, n_target, cell_status, ...) lives only in
#     simulation/results/fit_progress_{live,overall}.csv.
#   * Every one of the 36 design cells is retained, with n_fit = 0 for
#     cells that have no readable rows yet.
#   * Never crashes on zero-fit cells, missing columns, or NA/Inf values.
#   * Does NOT require the main outcome registry to be built.
#   * No replicate-count naming. Filenames are stable:
#       simulation/results/cell_diagnostics_rigor.csv
#       simulation/results/cell_diagnostics_component.csv
#       simulation/results/cell_behavior/cell_behavior_effect_draws.csv
#         (per-outcome long table feeding the Q1 attenuation atlas)
#
# IMPORTANT: cell_behavior_effect_draws.csv is the ONLY file in
# simulation/results/cell_behavior/ that 55 writes. The Q1 size-curve
# files in that same folder --
#   synthetic_cell_size_curve_draws.csv
#   synthetic_cell_size_curve_summary.csv
#   synthetic_cell_size_curve_report.md
# -- are produced by simulation/scripts/65_synthetic_resampling.R
# (via sim_run_cell_size_curve(), normally invoked through the
# operator-facing sim_run_synthetic_resampling() runner). If those
# files are missing but cell_behavior_effect_draws.csv exists, that
# is expected: 55 has run; 65 has not. Run 65 to produce them.
#
# Public entry point: sim_build_cell_diagnostics() (the only writer).

if (!exists("sim_read_sidecars_safely", inherits = TRUE)) {
  source("simulation/scripts/50_sim_fit_monitor.R")
}

# Near-zero guard for attenuation% and sign-flip (mirrors the spirit of
# the main pipeline's "safe NA near zero" rule for mu_RE).
.SIM_DIAG_EPS <- 0.01

# Binary-rate Monte Carlo SE; NA when n is too small to be meaningful.
.sim_mcse <- function(p, n, n_min = 5L) {
  if (is.na(p) || is.na(n) || n < n_min) return(NA_real_)
  sqrt(p * (1 - p) / n)
}

.sim_med <- function(x) {
  x <- suppressWarnings(as.numeric(x)); x <- x[is.finite(x)]
  if (!length(x)) NA_real_ else stats::median(x)
}
.sim_q <- function(x, p) {
  x <- suppressWarnings(as.numeric(x)); x <- x[is.finite(x)]
  if (!length(x)) NA_real_
  else unname(stats::quantile(x, probs = p, names = FALSE, type = 7))
}
.sim_p <- function(lgl) {
  lgl <- lgl[!is.na(lgl)]
  if (!length(lgl)) NA_real_ else mean(lgl)
}

#' Build per-cell rigor + component diagnostics from fitted sidecars.
#'
#' Each per-cell row carries the cell's identity, n_generated (sample-
#' size context for the metric value), n_fit (how many sidecars were
#' used), and the rigor / component point estimates + MCSEs. Progress
#' bookkeeping for the library (fit_fraction, library_status, etc.) is
#' not duplicated here -- it lives in fit_progress_{live,overall}.csv.
#'
#' @param output_root Simulation output root (default
#'   `.SIM_DEFAULT_OUTPUT_ROOT` = "output_sim_v30").
#' @param vintage     Vintage tag (default "2026" -> source_article
#'   "sim2026").
#' @param data_root / latent_root Where the generated + latent files
#'   live; used by sim_inventory_library() for the per-cell n_generated.
#' @param results_dir Where to write the diagnostic CSVs.
#' @param design Optional sim_load_design() frame.
#' @param write If TRUE (default), writes the two stable CSVs.
#' @return list(rigor, component, files, inventory).
sim_build_cell_diagnostics <- function(output_root = .SIM_DEFAULT_OUTPUT_ROOT,
                                       vintage     = .SIM_DEFAULT_VINTAGE,
                                       data_root   = "data",
                                       latent_root = "simulation/latent",
                                       results_dir = "simulation/results",
                                       design      = NULL,
                                       write       = TRUE) {
  if (is.null(design)) design <- sim_load_design()
  inv <- sim_inventory_library(data_root   = data_root,
                               latent_root = latent_root,
                               output_root = output_root,
                               vintage     = vintage,
                               design      = design)

  sc   <- sim_read_sidecars_safely(output_root, design)
  rows <- sc$rows

  num <- function(df, col) if (col %in% names(df))
    suppressWarnings(as.numeric(df[[col]])) else rep(NA_real_, nrow(df))

  rig <- list(); cmp <- list()
  for (i in seq_len(nrow(design))) {
    strat <- design$stratum[i]
    r <- if (!is.null(rows)) rows[rows$stratum == strat, , drop = FALSE]
         else NULL
    n_fit <- if (is.null(r)) 0L else nrow(r)
    n_gen <- inv$per_cell$n_generated[i]
    base <- list(
      cell_slug          = design$cell_slug[i],
      synthetic_stratum  = strat,
      legacy_cell_code   = design$legacy_cell_code[i],
      effect_band        = design$eff_band[i],
      heterogeneity_band = design$het_band[i],
      bias_band          = design$bias_band[i],
      n_generated        = as.integer(n_gen),
      n_fit              = as.integer(n_fit))

    if (n_fit == 0L) {
      rig[[i]] <- data.frame(c(base, list(
        median_log10BF_rigor = NA_real_, q05_log10BF_rigor = NA_real_,
        q95_log10BF_rigor = NA_real_, median_log10BF_rigor_effect = NA_real_,
        median_log10BF_rigor_no_effect = NA_real_,
        median_rigor_margin = NA_real_,
        p_rigor_direction_effect = NA_real_,
        p_rigor_direction_no_effect = NA_real_,
        p_clean_effect_supported = NA_real_,
        p_clean_no_effect_supported = NA_real_,
        p_clean_evidence_disfavored = NA_real_,
        p_inconclusive_clean_evidence = NA_real_,
        mcse_p_rigor_direction_effect = NA_real_,
        mcse_p_clean_effect_supported = NA_real_,
        mcse_p_clean_no_effect_supported = NA_real_,
        mcse_p_clean_evidence_disfavored = NA_real_)),
        stringsAsFactors = FALSE)
      cmp[[i]] <- data.frame(c(base, list(
        median_mu_RE = NA_real_, median_mu_BC = NA_real_,
        median_tau_RE = NA_real_, median_tau_BC = NA_real_,
        median_log10BF_effect = NA_real_, median_log10BF_het = NA_real_,
        median_log10BF_bias = NA_real_, median_attenuation_abs = NA_real_,
        median_attenuation_pct = NA_real_, p_sign_flip = NA_real_,
        p_bias_moderate = NA_real_, p_het_moderate = NA_real_,
        p_effect_moderate = NA_real_)),
        stringsAsFactors = FALSE)
      next
    }

    dir   <- if ("rigor_direction" %in% names(r)) r$rigor_direction else NA
    cat_  <- if ("rigor_category"  %in% names(r)) r$rigor_category  else NA
    bfR   <- num(r, "log10BF_rigor")
    bfRe  <- num(r, "log10BF_rigor_effect")
    bfRn  <- num(r, "log10BF_rigor_no_effect")
    marg  <- num(r, "rigor_margin")
    muRE  <- num(r, "mu_RE");  muBC <- num(r, "mu_BC")
    tauRE <- num(r, "tau_RE"); tauBC <- num(r, "tau_BC")
    bfE   <- num(r, "log10BF_effect")
    bfH   <- num(r, "log10BF_het")
    bfB   <- num(r, "log10BF_bias")

    p_eff  <- .sim_p(dir == "effect")
    p_neff <- .sim_p(dir == "no_effect")
    p_cs   <- .sim_p(cat_ == "clean_effect_supported")
    p_cns  <- .sim_p(cat_ == "clean_no_effect_supported")
    p_cd   <- .sim_p(cat_ == "clean_evidence_disfavored")
    p_inc  <- .sim_p(cat_ == "inconclusive_clean_evidence")

    rig[[i]] <- data.frame(c(base, list(
      median_log10BF_rigor           = .sim_med(bfR),
      q05_log10BF_rigor              = .sim_q(bfR, 0.05),
      q95_log10BF_rigor              = .sim_q(bfR, 0.95),
      median_log10BF_rigor_effect    = .sim_med(bfRe),
      median_log10BF_rigor_no_effect = .sim_med(bfRn),
      median_rigor_margin            = .sim_med(marg),
      p_rigor_direction_effect       = p_eff,
      p_rigor_direction_no_effect    = p_neff,
      p_clean_effect_supported       = p_cs,
      p_clean_no_effect_supported    = p_cns,
      p_clean_evidence_disfavored    = p_cd,
      p_inconclusive_clean_evidence  = p_inc,
      mcse_p_rigor_direction_effect    = .sim_mcse(p_eff, n_fit),
      mcse_p_clean_effect_supported    = .sim_mcse(p_cs,  n_fit),
      mcse_p_clean_no_effect_supported = .sim_mcse(p_cns, n_fit),
      mcse_p_clean_evidence_disfavored = .sim_mcse(p_cd,  n_fit))),
      stringsAsFactors = FALSE)

    att_abs <- abs(muBC - muRE)
    big     <- is.finite(muRE) & abs(muRE) > .SIM_DIAG_EPS
    att_pct <- ifelse(big, 100 * (muBC - muRE) / abs(muRE), NA_real_)
    both_big <- is.finite(muRE) & is.finite(muBC) &
                abs(muRE) > .SIM_DIAG_EPS & abs(muBC) > .SIM_DIAG_EPS
    flip <- ifelse(both_big, sign(muRE) != sign(muBC), NA)

    cmp[[i]] <- data.frame(c(base, list(
      median_mu_RE           = .sim_med(muRE),
      median_mu_BC           = .sim_med(muBC),
      median_tau_RE          = .sim_med(tauRE),
      median_tau_BC          = .sim_med(tauBC),
      median_log10BF_effect  = .sim_med(bfE),
      median_log10BF_het     = .sim_med(bfH),
      median_log10BF_bias    = .sim_med(bfB),
      median_attenuation_abs = .sim_med(att_abs),
      median_attenuation_pct = .sim_med(att_pct),
      p_sign_flip            = .sim_p(flip),
      p_bias_moderate        = .sim_p(bfB > 0.5),
      p_het_moderate         = .sim_p(bfH > 0.5),
      p_effect_moderate      = .sim_p(bfE > 0.5))),
      stringsAsFactors = FALSE)
  }

  rigor_df <- do.call(rbind, rig)
  comp_df  <- do.call(rbind, cmp)

  # Per-outcome effect draws (Q1 attenuation atlas). Long table:
  # one row per fitted simulation outcome with the cell identity, the
  # design truth (mu_true), and the matched-baseline (mu_RE) +
  # bias-corrected (mu_BC) effect estimates. Empty cells contribute no
  # rows. Filenames stable; nothing about the run lives in the name.
  draw_cols <- c("cell_slug", "effect_slug", "heterogeneity_slug",
                 "bias_slug", "mu_true", "tau_true",
                 "mu_RE", "mu_BC", "n_fit", "dataset_id",
                 "stratum")
  if (!is.null(rows) && nrow(rows)) {
    # Resolve design identity (effect/heterogeneity/bias slugs + mu_true)
    # per stratum, then join onto the per-outcome rows.
    keep_design <- c("stratum", "cell_slug", "effect_slug",
                     "heterogeneity_slug", "bias_slug",
                     "mu_true", "tau_true")
    miss_design <- setdiff(keep_design, names(design))
    if (length(miss_design)) {
      # Heterogeneity slug column is "heterogeneity_slug" in some
      # vintages and "het_slug" in others; .SC_HET_BANDS uses
      # "heterogeneity_slug" — try both.
      if ("het_slug" %in% names(design) &&
          !"heterogeneity_slug" %in% names(design))
        design$heterogeneity_slug <- design$het_slug
      miss_design <- setdiff(keep_design, names(design))
    }
    d_id <- design[, intersect(keep_design, names(design)),
                    drop = FALSE]
    draws <- merge(rows, d_id, by = "stratum", all.x = TRUE,
                   sort = FALSE)
    # Attach n_fit per cell so reviewers can see the sample-size
    # context inside the long table itself.
    n_fit_by_strat <- setNames(rigor_df$n_fit, rigor_df$synthetic_stratum)
    draws$n_fit <- as.integer(n_fit_by_strat[draws$stratum])
    if (!"dataset_id" %in% names(draws)) draws$dataset_id <- NA_character_
    draws$mu_RE <- num(draws, "mu_RE")
    draws$mu_BC <- num(draws, "mu_BC")
    draws_df <- draws[, intersect(draw_cols, names(draws)), drop = FALSE]
  } else {
    draws_df <- data.frame(
      cell_slug = character(0), effect_slug = character(0),
      heterogeneity_slug = character(0), bias_slug = character(0),
      mu_true = numeric(0), tau_true = numeric(0),
      mu_RE = numeric(0), mu_BC = numeric(0),
      n_fit = integer(0), dataset_id = character(0),
      stratum = character(0), stringsAsFactors = FALSE)
  }

  files <- character(0)
  if (isTRUE(write)) {
    if (!dir.exists(results_dir)) dir.create(results_dir, recursive = TRUE)
    rp <- file.path(results_dir, "cell_diagnostics_rigor.csv")
    cp <- file.path(results_dir, "cell_diagnostics_component.csv")
    utils::write.csv(rigor_df, rp, row.names = FALSE)
    utils::write.csv(comp_df,  cp, row.names = FALSE)
    cb_dir <- file.path(results_dir, "cell_behavior")
    if (!dir.exists(cb_dir)) dir.create(cb_dir, recursive = TRUE)
    dp <- file.path(cb_dir, "cell_behavior_effect_draws.csv")
    utils::write.csv(draws_df, dp, row.names = FALSE)
    files <- c(rp, cp, dp)
  }

  list(rigor = rigor_df, component = comp_df,
       effect_draws = draws_df, files = files, inventory = inv)
}
