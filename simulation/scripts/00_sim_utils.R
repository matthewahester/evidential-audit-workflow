# 00_sim_utils.R — shared simulation constants and helpers.
#
# Define-only on source: installs constants/helpers into the caller's
# environment; reads/writes nothing on disk. Source-multiple-times safe
# via the `.robma_sim_utils_loaded` sentinel.
#
# Contents:
#   * central defaults (.SIM_VERSION_LABEL, .SIM_DEFAULT_* paths/ids);
#   * naming / path helpers (sim_make_stem, sim_stratum_dir, sim_source_tag);
#   * shared k sampler (.SIM_K_BUCKETS, sim_sample_k);
#   * DGM helpers (sim_sample_n, sim_se_from_n, sim_pub_weight,
#     sim_apply_smallstudy);
#   * per-(cell, replicate) seed function (sim_seed_for).
#
# Sourced by: 10_sim_design.R, 20_sim_generate.R, 30_sim_export.R,
#             40_sim_run.R, 45_study_geometry.R, 50_sim_fit_monitor.R.

if (!exists(".robma_sim_utils_loaded", inherits = TRUE) ||
    !isTRUE(.robma_sim_utils_loaded)) {

  # Null-default operator. Defined only if missing so we do not shadow the
  # one already provided by scripts/00_utils.R when both are sourced.
  if (!exists("%||%", inherits = TRUE)) {
    `%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a
  }

  # ---------------------------------------------------------------------------
  # Central defaults — single source of truth for the active sim_v3 layer.
  # ---------------------------------------------------------------------------
  # `sim_v3` = active simulation layer / human-facing prefix.
  # `output_sim_v30` / `sim_library_v30` / `simulation_cell` = fitted-output
  # identity contract; matched by sim_fit_config() in 40_sim_run.R.
  .SIM_VERSION_LABEL       <- "sim_v3"
  .SIM_DEFAULT_DESIGN_PATH <- "simulation/config/design_v3_full36.csv"
  .SIM_DEFAULT_VINTAGE     <- "2026"
  .SIM_DEFAULT_OUTPUT_ROOT <- "output_sim_v30"
  .SIM_DEFAULT_CORPUS_ID   <- "sim_library_v30"
  .SIM_DEFAULT_SCHEME      <- "simulation_cell"
  .SIM_DEFAULT_BASE_SEED   <- 20260509L

  # ---------------------------------------------------------------------------
  # Naming / path helpers
  # ---------------------------------------------------------------------------

  # Pad an integer replicate index to a fixed-width string for stems.
  sim_pad_rep <- function(i, width = 4L) {
    formatC(as.integer(i), width = width, flag = "0", format = "d")
  }

  # Canonical replicate stem: compact `repNNNN`, e.g. sim_make_stem(<any
  # cell>, 1) -> "rep0001". The stem deliberately does NOT restate the
  # synthetic stratum — the cell lives in the data folder / dataset_id,
  # not the filename. `cell_slug` is accepted but unused; callers may
  # still pass it for clarity.
  sim_make_stem <- function(cell_slug, rep_id, width = 4L) {
    paste0("rep", sim_pad_rep(rep_id, width = width))
  }

  # Synthetic stratum-directory name under data/: "sim_<cell_slug>"
  # (e.g. "sim_moderate_midhet_modbias"). The "sim_" prefix keeps
  # synthetic strata visually distinct from real ones in list_datasets().
  sim_stratum_dir <- function(cell_slug) paste0("sim_", cell_slug)

  # Source-article directory tag for a simulation vintage. The main
  # loader parses `source_year` from a trailing 4-digit run of
  # `source_article`, so a production vintage must end in a year
  # (`"2026"` -> `sim2026` -> source_year 2026). Keep the library version
  # in CONFIG$corpus_id / CONFIG$output_root, never in the vintage —
  # `"2026_v30"` would yield source_year NA.
  sim_source_tag <- function(vintage = .SIM_DEFAULT_VINTAGE)
    paste0("sim", vintage)

  # ---------------------------------------------------------------------------
  # Sampling-distribution helpers
  # ---------------------------------------------------------------------------

  # SE for a standardized mean difference (Cohen's d / Hedges' g) given
  # per-arm sample size. v1 approximation: equal arms, no g-dependent term.
  # se_g(n) = sqrt(2 / n_per_arm). Sufficient for diagnostic simulation.
  sim_se_from_n <- function(n_per_arm) {
    n_per_arm <- pmax(as.integer(n_per_arm), 4L)
    sqrt(2 / n_per_arm)
  }

  # Sample per-arm sample sizes from a lognormal distribution and clip.
  # Defaults give a median of 30 and ~95% mass in [10, 100].
  sim_sample_n <- function(k, meanlog = log(30), sdlog = 0.6,
                           n_min = 8L, n_max = 500L) {
    raw <- rlnorm(k, meanlog = meanlog, sdlog = sdlog)
    as.integer(pmin(pmax(round(raw), n_min), n_max))
  }

  # ---------------------------------------------------------------------------
  # Shared marginal k sampler
  # ---------------------------------------------------------------------------
  # Number of primary studies per synthetic meta-analysis. Shared across
  # all cells (does not vary with effect, heterogeneity, or bias band).
  # Four buckets cover the empirical nutrition-registry k distribution:
  # a small-meta floor, two central masses, and a high-information tail.

  .SIM_K_BUCKETS <- data.frame(
    bucket = c("xs",  "s",   "m",   "l"),
    k_lo   = c(8L,    11L,   21L,   41L),
    k_hi   = c(10L,   20L,   40L,   90L),
    prob   = c(0.10,  0.45,  0.35,  0.10),
    stringsAsFactors = FALSE
  )

  # Draw a single (target_k, bucket) pair from the shared marginal.
  # Returns list(k = <int>, bucket = <character in {xs, s, m, l}>).
  sim_sample_k <- function(buckets = .SIM_K_BUCKETS) {
    i  <- sample.int(nrow(buckets), size = 1L, prob = buckets$prob)
    lo <- buckets$k_lo[i]
    hi <- buckets$k_hi[i]
    k  <- if (lo == hi) lo else sample(lo:hi, size = 1L)
    list(k = as.integer(k), bucket = buckets$bucket[i])
  }

  # ---------------------------------------------------------------------------
  # Bias mechanisms
  # ---------------------------------------------------------------------------

  # Threshold-based selection weight given a one-sided z statistic.
  # Studies with p < 0.01 are always retained; 0.01 <= p < 0.05 are
  # retained with prob 0.5; p >= 0.05 are retained with prob 0.2.
  # Matches the kind of step-function selection RoBMA-PSMA is designed
  # to detect. Returns a probability in [0, 1].
  sim_pub_weight <- function(z,
                             weights = c(sig01 = 1.0,
                                         sig05 = 0.5,
                                         ns    = 0.2)) {
    p <- 1 - pnorm(z)
    out <- numeric(length(p))
    out[p < 0.01]                <- weights[["sig01"]]
    out[p >= 0.01 & p < 0.05]    <- weights[["sig05"]]
    out[p >= 0.05]               <- weights[["ns"]]
    out
  }

  # Apply a small-study additive bias proportional to SE, the canonical
  # funnel-asymmetry mechanism. alpha = 0 disables the effect.
  sim_apply_smallstudy <- function(g, se_g, alpha = 0) {
    g + alpha * se_g
  }

  # ---------------------------------------------------------------------------
  # Reproducibility
  # ---------------------------------------------------------------------------

  # Deterministic per-(cell, replicate) seed derived from a base seed.
  # `cell` is the canonical readable cell id (e.g. "moderate_midhet_modbias").
  # Stable across machines and dependency-free. Intermediates are promoted
  # to numeric to avoid integer overflow on long cell names; the final
  # value is reduced mod .Machine$integer.max and coerced to integer.
  sim_seed_for <- function(cell, rep_id,
                           base_seed = .SIM_DEFAULT_BASE_SEED) {
    cell <- as.character(cell)
    cell_hash <- sum(as.numeric(utf8ToInt(cell)) * seq_len(nchar(cell)))
    s <- (as.numeric(base_seed) + cell_hash * 1009 +
          as.numeric(rep_id) * 31) %% .Machine$integer.max
    as.integer(s)
  }

  .robma_sim_utils_loaded <- TRUE
  invisible(NULL)
}
