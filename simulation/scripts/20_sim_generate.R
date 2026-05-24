# 20_sim_generate.R — generate one synthetic meta-analytic dataset.
#
# Define-only on source. No disk I/O. The export step
# (30_sim_export.R) writes the audit-ready observed and latent/truth
# layers; this file only builds them in memory.
#
# DGM (one replicate within a cell):
#   target_k    drawn from the shared 4-bucket marginal
#                 (xs[8,10] s[11,20] m[21,40] l[41,90];
#                  see .SIM_K_BUCKETS in 00_sim_utils.R);
#   theta_i  ~ N(mu_true, tau_true^2);
#   g_i      ~ N(theta_i, se_i^2)        # per-arm n -> se_g;
#   small-study overlay (composite bias):
#       g_obs = g_i + smallstudy_alpha * se_i
#       (b0 -> 0, b1 -> 0.25, b2 -> 0.50);
#   threshold selection:
#       accept with prob sim_pub_weight(z; w_sig01, w_sig05, w_ns).
#       b0 weights are (1, 1, 1), so the acceptance step is a no-op.
#
# The bias axis is an ordered composite-burden axis. Fitted
# `log10BF_bias` is NOT a generative input: it is computed downstream
# by RoBMA-PSMA on the resulting g/se_g table, and synthetic datasets
# are never redrawn to force fitted bias evidence into a target band.

if (!exists(".robma_sim_utils_loaded", inherits = TRUE) ||
    !isTRUE(.robma_sim_utils_loaded)) {
  source("simulation/scripts/00_sim_utils.R")
}

# Idempotent define-only re-source of the design module so we can call
# sim_row_weights() without forcing callers to remember the source order.
if (!exists("sim_row_weights", inherits = TRUE)) {
  source("simulation/scripts/10_sim_design.R")
}

#' Generate a single synthetic meta-analytic dataset.
#'
#' @param cell_row A single-row data frame from `sim_load_design()`,
#'   carrying the DGM + identity columns (cell, cell_slug, stratum,
#'   legacy_cell_code, eff/het/bias bands and slugs, mu_true, tau_true,
#'   selection, w_sig01/w_sig05/w_ns, smallstudy_alpha, n_meanlog,
#'   n_sdlog). The identity columns are passed straight through onto
#'   `meta` so the export/manifest layer needs no second design lookup.
#' @param rep_id   Replicate index within the cell (1, 2, ...).
#' @param base_seed Base seed combined deterministically with cell + rep_id
#'   via `sim_seed_for()`.
#' @param max_draws_per_accept Safety cap on resampling attempts under
#'   selection. With severe selection weights a multiplier of 100 is
#'   typically enough; cells that exceed the cap emit a warning.
#' @param keep_candidates If TRUE, the latent table also records the
#'   *rejected* candidate studies (with `accepted = FALSE`). Useful for
#'   selection-mechanism diagnostics. Default FALSE keeps the latent
#'   table limited to accepted studies.
#'
#' @return A list with:
#'   * `meta` : named list of cell, cell_slug, stratum, legacy_cell_code,
#'              rep_id, k, k_bucket, eff/het/bias bands and slugs,
#'              mu_true, tau_true, selection, w_sig01/w_sig05/w_ns,
#'              smallstudy_alpha, n_per_arm_median, seed, n_drawn,
#'              n_accepted.
#'   * `latent`  : data frame with one row per study (accepted by default,
#'                 or per candidate when `keep_candidates = TRUE`).
#'                 Columns: study_id, n_per_arm, se_g, theta_true,
#'                 g_pre_bias, g_observed, z, p_one_sided, sel_weight,
#'                 accepted.
#'   * `observed`: audit-ready data frame with study_id, g, se_g.
sim_generate_dataset <- function(cell_row,
                                  rep_id,
                                  base_seed = .SIM_DEFAULT_BASE_SEED,
                                  max_draws_per_accept = 100L,
                                  keep_candidates = FALSE) {

  stopifnot(is.data.frame(cell_row), nrow(cell_row) == 1L)

  cell      <- cell_row$cell
  eff_band  <- cell_row$eff_band  %||% NA_character_
  het_band  <- cell_row$het_band  %||% NA_character_
  bias_band <- cell_row$bias_band %||% NA_character_
  mu        <- cell_row$mu_true
  tau       <- cell_row$tau_true
  selection <- cell_row$selection
  alpha     <- cell_row$smallstudy_alpha %||% 0
  n_meanlog <- cell_row$n_meanlog %||% .SIM_DEFAULT_N_MEANLOG
  n_sdlog   <- cell_row$n_sdlog   %||% .SIM_DEFAULT_N_SDLOG

  # Readable-slug identity (carried by every full36 v3 row). The %||%
  # fallbacks are defensive and only reconstruct identity if a caller
  # hands in a row that is missing those columns.
  cell_slug        <- cell_row$cell_slug %||% cell
  stratum          <- cell_row$stratum   %||% paste0("sim_", cell_slug)
  legacy_cell_code <- cell_row$legacy_cell_code %||%
    paste(eff_band, het_band, bias_band, sep = "_")
  effect_slug        <- cell_row$effect_slug        %||% NA_character_
  heterogeneity_slug <- cell_row$heterogeneity_slug %||% NA_character_
  bias_slug          <- cell_row$bias_slug          %||% NA_character_

  # Row-specific publication-selection weights. b0 rows resolve to
  # (1, 1, 1), so the acceptance test below becomes a no-op.
  row_weights <- sim_row_weights(cell_row)

  seed <- sim_seed_for(cell, rep_id, base_seed = base_seed)
  set.seed(seed)

  # Shared 4-bucket marginal k sampler. The bucket name lands on the
  # manifest as `k_bucket` so downstream diagnostics can audit the
  # realized share against .SIM_K_BUCKETS$prob.
  ks       <- sim_sample_k()
  target_k <- ks$k
  k_bucket <- ks$bucket
  cap      <- max_draws_per_accept * target_k

  accepted_records  <- vector("list", target_k)
  candidate_records <- if (isTRUE(keep_candidates)) list() else NULL
  accepted <- 0L
  drawn    <- 0L

  while (accepted < target_k && drawn < cap) {
    drawn <- drawn + 1L

    n_i     <- sim_sample_n(1L, meanlog = n_meanlog, sdlog = n_sdlog)
    se_i    <- sim_se_from_n(n_i)
    theta_i <- rnorm(1L, mean = mu, sd = tau)
    g_pre   <- rnorm(1L, mean = theta_i, sd = se_i)
    g_obs   <- sim_apply_smallstudy(g_pre, se_i, alpha = alpha)

    z       <- g_obs / se_i
    p_one   <- 1 - pnorm(z)

    if (selection == "threshold") {
      w_i <- sim_pub_weight(z, weights = row_weights)
      keep <- runif(1L) <= w_i
    } else {
      w_i  <- 1
      keep <- TRUE
    }

    cand_row <- data.frame(
      study_id    = drawn,
      n_per_arm   = n_i,
      se_g        = se_i,
      theta_true  = theta_i,
      g_pre_bias  = g_pre,
      g_observed  = g_obs,
      z           = z,
      p_one_sided = p_one,
      sel_weight  = w_i,
      accepted    = isTRUE(keep),
      stringsAsFactors = FALSE
    )
    if (isTRUE(keep_candidates)) {
      candidate_records[[length(candidate_records) + 1L]] <- cand_row
    }

    if (!isTRUE(keep)) next

    accepted <- accepted + 1L
    # When latent is "accepted-only" we rewrite the study_id to a compact
    # 1..k index so downstream tools see a contiguous sequence.
    cand_row$study_id <- accepted
    accepted_records[[accepted]] <- cand_row
  }

  if (accepted < target_k) {
    warning(sprintf(
      "Cell '%s' rep %d: only %d/%d studies accepted within draw cap (%d).",
      cell, rep_id, accepted, target_k, cap
    ))
    accepted_records <- accepted_records[seq_len(accepted)]
  }

  if (isTRUE(keep_candidates)) {
    latent <- do.call(rbind, candidate_records)
  } else {
    latent <- do.call(rbind, accepted_records)
  }

  observed_df <- do.call(rbind, accepted_records)
  observed <- data.frame(
    study_id = observed_df$study_id,
    g        = observed_df$g_observed,
    se_g     = observed_df$se_g,
    stringsAsFactors = FALSE
  )

  meta <- list(
    cell               = cell,
    cell_slug          = cell_slug,
    stratum            = stratum,
    legacy_cell_code   = legacy_cell_code,
    rep_id             = as.integer(rep_id),
    k                  = nrow(observed),
    k_bucket           = k_bucket,
    eff_band           = eff_band,
    effect_slug        = effect_slug,
    het_band           = het_band,
    heterogeneity_slug = heterogeneity_slug,
    bias_band          = bias_band,
    bias_slug          = bias_slug,
    mu_true            = mu,
    tau_true           = tau,
    selection          = selection,
    w_sig01            = unname(row_weights[["sig01"]]),
    w_sig05            = unname(row_weights[["sig05"]]),
    w_ns               = unname(row_weights[["ns"]]),
    smallstudy_alpha   = alpha,
    n_per_arm_median   = stats::median(observed_df$n_per_arm),
    seed               = seed,
    n_drawn            = drawn,
    n_accepted         = accepted
  )

  list(meta = meta, latent = latent, observed = observed)
}
