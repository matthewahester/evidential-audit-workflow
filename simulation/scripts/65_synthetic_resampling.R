# 65_synthetic_resampling.R - Synthetic resampling layer.
#
# Define-only on source. Sourcing installs functions and constants and
# nothing else: it reads no registry, fits nothing, calls no
# batch_fit(), writes no CSV, and never touches output_sim_v30 sidecars
# or generated / latent data. Work happens only when an explicit
# orchestrator call is made.
#
# Terminology contract:
#   * target cell / DGM cell -- the synthetic design cell known by
#     construction from sim_<effect>_<heterogeneity>_<bias>. Defined
#     by 10_sim_design.R + 20_sim_generate.R + 40_sim_run.R, NOT by
#     anything in this script.
#   * empirical fitted-cell assignment / fitted profile cell -- a
#     deterministic projection of an empirical outcome onto the
#     36-cell vocabulary using fitted audit outputs (|mu_BC|, tau_BC,
#     log10BF_bias) and the band thresholds in `.SC_EFFECT_BANDS` /
#     `.SC_HET_BANDS` / `.SC_BIAS_BANDS`. NOT a true generative label
#     and NOT evidence that the empirical outcome was generated from
#     the synthetic regimes.
#   * The internal column name `observed_cell_slug` is a technical
#     handle for the fitted profile cell. Public language in reports
#     and figure captions says "fitted-cell assignment" / "fitted
#     profile cell" instead.
#
# Scope:
#   * project every empirical outcome onto the 36-cell named v3
#     vocabulary via its fitted RoBMA estimates (|mu_BC|, tau_BC,
#     log10BF_bias) to produce fitted-cell assignments;
#   * build per-stratum fitted-cell mixture weights for the empirical
#     corpus (the empirical-Bayes corpus-shrunk weights used to draw
#     empirical-weighted synthetic samples);
#   * draw empirical-weighted synthetic stratum / corpus profiles from
#     the fitted simulation library and summarize them with the same v4
#     rigor-first reducers used for empirical resampling;
#   * compute target -> observed cell-recovery diagnostics + per-stratum
#     provenance / projection and synthetic-pool support;
#   * gate the orchestrator on the current generated + fitted library
#     (via sim_inventory_library() -- no hardcoded replicate-count
#     assumptions, no `expected_per_cell` argument).
#
# Q3 uses empirical fitted-cell mixtures to sample from the fitted
# synthetic library. The primary `pool_key = "target"` samples from the
# synthetic library indexed by its known DGM/target cell; `pool_key =
# "observed"` is a sensitivity slice that indexes the same library by
# its own *fitted* cell.
#
# Not in scope: this is not a DGM, fits no models, never calls RoBMA /
# batch_fit(), and never generates synthetic datasets. Summary
# definitions are NOT re-implemented here -- empirical-weighted
# synthetic draws are summarized with emp_stratum_summary() /
# emp_corpus_summary() from 60_empirical_resampling.R, so empirical
# and synthetic profiles share one definition and 70 agreement is a
# like-for-like comparison.
#
# Internal function-level mechanism nouns ("composition" in
# sim_validate_composition_inputs() etc., the `composition_id` row
# column, the .VIS_COLORS$resampling_source$synthetic_composition
# palette key) are retained where churn outweighs clarity. Public
# Q3 names and folder/figure/report names use empirical-weighted
# synthetic sampling everywhere.
#
# Public workflow (mirrors emp_run_resampling() in feel; B / n_grid /
# pool_key / smoothing / kappa / support live in row columns / report,
# never in filenames). Use sim_run_synthetic_resampling() by default;
# it runs:
#   Q1 known-cell synthetic size curve,
#   Q3 empirical-weighted synthetic sampling at observed stratum sizes,
#   Q3 empirical-weighted synthetic size curve,
# in one call:
#
#   source("simulation/scripts/65_synthetic_resampling.R")
#
#   # Default smoothing is "eb_corpus" (kappa = 4, support = "occupied"),
#   # the recommended empirical-Bayes support-masked weighting. Pass
#   # smoothing = "corpus_blend" / "additive" / "none" for sensitivity.
#   sim_run_synthetic_resampling(B = 5000, n_grid = c(5:30, 35, 40, 50),
#                                smoothing = "eb_corpus", kappa = 4,
#                                support = "occupied",
#                                workers = 5)
#
#
# Targeted / debug calls (lower-level entry points; still public, but
# use sim_run_synthetic_resampling() by default):
#
#   sim_run_cell_size_curve()                # Q1 known-cell n_outcomes curve
#   sim_run_empirical_weighted_synthetic()   # Q3 observed-size sampling
#   sim_run_empirical_weighted_size_curve()  # Q3 n_outcomes curve
#
# Provenance / registry-staleness contract:
#
#   65 loads output_sim_v30/overview/outcome_registry.csv via
#   sim_load_synthetic_registry(). If that registry is stale, every
#   downstream Q1/Q3 row will carry a stale n_pool / synthetic pool
#   index even though the underlying sidecars on disk may be newer.
#
#   As of 2026-05, sim_run_synthetic_resampling() rebuilds that
#   registry automatically before any subroutine runs (default
#   refresh_registry = TRUE; one call to sim_refresh_synthetic_registry()
#   which sentinel-sources scripts/60_estimand_tables.R if needed).
#   Pass refresh_registry = FALSE only when the registry is known fresh
#   from an earlier call in the same session, or when calling the
#   lower-level sim_run_cell_size_curve() / sim_run_empirical_weighted_*
#   runners directly. In those lower-level paths, rebuild the registry
#   manually beforehand:
#
#     source("scripts/60_estimand_tables.R")
#     build_estimand_tables(
#       root       = "output_sim_v30",
#       output_dir = "output_sim_v30/overview")
#
#   sim_run_cell_size_curve() performs a soft provenance check
#   (.sc_check_registry_freshness) that compares the per-cell pool
#   size to the per-cell n_fit reported by cell_diagnostics_rigor.csv
#   when that file exists, and emits a clear warning when the registry
#   appears stale. Stale-registry runs are not hard-failed (so dev /
#   partial work is possible), but the warning is replayed in the
#   per-run report.
#
# Stable output layout (no `_DEVPARTIAL` filename suffix; DEV/PARTIAL
# state is carried in row columns + the report). The cell_behavior/
# tree below carries Q1 outputs; empirical_weighted_synthetic/ carries
# Q3 outputs (renamed from synthetic_composition/ in 2026-05):
#
#   simulation/results/cell_behavior/
#   ├── synthetic_cell_size_curve_draws.csv
#   ├── synthetic_cell_size_curve_summary.csv
#   └── synthetic_cell_size_curve_report.md
#
#   simulation/results/empirical_weighted_synthetic/
#   ├── empirical_weighted_synthetic_report.md
#   ├── empirical_cell_assignments.csv
#   ├── empirical_stratum_cell_weights.csv
#   ├── empirical_stratum_coherence.csv
#   ├── empirical_weighted_synthetic_stratum_draws.csv
#   ├── empirical_weighted_synthetic_corpus_draws.csv
#   ├── empirical_weighted_synthetic_stratum_draw_summary.csv
#   ├── empirical_weighted_synthetic_corpus_draw_summary.csv
#   ├── empirical_weighted_synthetic_size_curve_draws.csv
#   ├── empirical_weighted_synthetic_size_curve_summary.csv
#   ├── empirical_weighted_synthetic_size_curve_report.md
#   ├── composition_validation_checks.csv
#   └── detail/
#       ├── synthetic_cell_transition.csv
#       ├── synthetic_axis_transition.csv
#       ├── stratum_target_provenance.csv
#       ├── stratum_observed_recovery.csv
#       └── synthetic_support_diagnostics.csv
#
# NOTE: simulation/results/cell_behavior/cell_behavior_effect_draws.csv
# in the same cell_behavior/ folder is written by 55 (not by 65) and
# feeds the Q1 attenuation atlas. simulation/results/cell_behavior/
# synthetic_cell_rigor_viability_min_n.csv is a derived visualization
# table written by 75 from synthetic_cell_size_curve_summary.csv (not
# an upstream 65 input).
#
# Optional parallelism. sim_compose_strata() / sim_compose_corpus() and
# the orchestrator accept a `workers` argument (default 1L = sequential;
# env override `SYNTHETIC_COMPOSITION_WORKERS`). Seeds are pre-computed
# per replicate before dispatch, so results are byte-identical
# regardless of worker count. workers > 1 uses a PSOCK cluster via the
# base `parallel` package; if `parallel` is unavailable the function
# falls back to sequential with a one-line note.
#
# Public entry points:
#   sim_load_empirical_registry()           sim_load_synthetic_registry()
#   sim_assign_observed_cell()              sim_parse_target_cell()
#   sim_build_empirical_cell_weights()
#   sim_build_empirical_fitted_cell_boundary()  - fitted-cell boundary
#                                                 sensitivity diagnostic
#   sim_validate_composition_inputs()
#   sim_compose_stratum_once()
#   sim_compose_strata()                    sim_compose_corpus()
#   sim_summarize_composition_draws()
#   sim_build_cell_transition()             sim_build_axis_transition()
#   sim_build_stratum_provenance_projection()
#   sim_build_synthetic_support_diagnostics()
#   sim_composition_validation_checks()
#   sim_write_composition_report()
#   sim_refresh_synthetic_registry()   - convenience wrapper around the
#                                        main pipeline's
#                                        build_estimand_tables() to
#                                        rebuild output_sim_v30/overview/
#                                        outcome_registry.csv between
#                                        55 (sidecar diagnostics) and
#                                        this script's resampling runs.
#                                        As of 2026-05, called
#                                        automatically by
#                                        sim_run_synthetic_resampling()
#                                        (default refresh_registry=TRUE);
#                                        also callable directly.
#   sim_run_synthetic_resampling()           - top-level workflow runner
#                                              (mirrors emp_run_resampling());
#                                              runs Q1 known-cell size curve
#                                              + Q3 empirical-weighted
#                                              synthetic sampling at observed
#                                              stratum sizes + Q3 empirical-
#                                              weighted synthetic size curve
#                                              in one call. Use this by
#                                              default.
#   sim_run_empirical_weighted_synthetic()   - Q3 empirical-weighted synthetic
#                                              sampling at observed stratum
#                                              sizes (lower-level; still
#                                              public). Pre-2026-05 alias:
#                                              sim_run_synthetic_composition.
#   sim_run_cell_size_curve()                - Q1 per-target-cell n_outcomes
#                                              stability curve (lower-level)
#   sim_run_empirical_weighted_size_curve()  - Q3 empirical-weighted
#                                              synthetic n_outcomes stability
#                                              curve (lower-level). Pre-2026-
#                                              05 alias:
#                                              sim_run_composition_size_curve.

# --- define-only, sentinel-guarded sourcing ------------------------------
# 60_empirical_resampling.R supplies the .emp_* v4 reducers, the
# emp_stratum_summary() / emp_corpus_summary() summarizers, and
# (transitively) scripts/00_utils.R. 10_sim_design.R supplies
# sim_load_design(). 50_sim_fit_monitor.R supplies sim_inventory_library()
# (consulted by the input gate). All are define-only.
if (!exists("emp_stratum_summary", inherits = TRUE)) {
  for (.p in c("simulation/scripts/60_empirical_resampling.R",
               "60_empirical_resampling.R",
               file.path("..", "scripts", "60_empirical_resampling.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}
if (!exists("sim_load_design", inherits = TRUE)) {
  for (.p in c("simulation/scripts/10_sim_design.R",
               "10_sim_design.R",
               file.path("scripts", "10_sim_design.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}
if (!exists("sim_inventory_library", inherits = TRUE)) {
  for (.p in c("simulation/scripts/50_sim_fit_monitor.R",
               "50_sim_fit_monitor.R",
               file.path("scripts", "50_sim_fit_monitor.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}

# --- band thresholds (constants; these ARE the contract) ----------------
# Cell-assignment cut points for FITTED RoBMA outputs (the same axes
# used to label the synthetic design cells). Effect reads abs(mu_BC);
# heterogeneity reads tau_BC; bias reads log10BF_bias. Inf bias falls
# in the highbias band (Inf is evidence, not missingness).
.SC_EFFECT_BANDS <- data.frame(
  band = c("e0", "e1", "e2", "e3"),
  slug = c("null", "small", "moderate", "large"),
  lo   = c(-Inf, 0.05, 0.175, 0.375),     # lower bound, inclusive
  hi   = c(0.05, 0.175, 0.375, Inf),      # upper bound, exclusive
  stringsAsFactors = FALSE)
.SC_HET_BANDS <- data.frame(
  band = c("h0", "h1", "h2"),
  slug = c("lowhet", "midhet", "highhet"),
  lo   = c(-Inf, 0.10, 0.275),
  hi   = c(0.10, 0.275, Inf),
  stringsAsFactors = FALSE)
.SC_BIAS_BANDS <- data.frame(
  band = c("b0", "b1", "b2"),
  slug = c("clean", "modbias", "highbias"),
  lo   = c(-Inf, 0.5, 1.0),               # clean: x <= 0.5
  hi   = c(0.5, 1.0, Inf),                # highbias: x > 1.0 or Inf
  stringsAsFactors = FALSE)

# Expected v4 identity carried by every simulation registry row. Single
# source of truth at run time when 50 is loaded.
.SC_SIM_IDENTITY <- if (exists(".SIM_FIT_IDENTITY", inherits = TRUE))
  .SIM_FIT_IDENTITY else
  c(corpus_id = "sim_library_v30", scheme = "simulation_cell",
    source_article = "sim2026", analysis_variant = "main")

# Rigor-first metric columns produced by emp_stratum_summary() that
# composition draws and 70 agreement focus on first.
.SC_PRIMARY_METRICS <- c(
  "median_log10BF_rigor", "p_rigor_direction_effect",
  "p_rigor_direction_no_effect", "p_clean_effect_supported",
  "p_clean_no_effect_supported", "p_clean_evidence_disfavored",
  "p_inconclusive_clean_evidence", "median_rigor_margin")
.SC_COMPONENT_METRICS <- c(
  "median_mu_BC", "median_tau_BC", "median_log10BF_effect",
  "median_log10BF_het", "median_log10BF_bias",
  "median_attenuation_abs",
  "p_bias_moderate", "p_het_moderate", "p_effect_moderate")

# Canonical 36-slug v4 cell grid (effect x heterogeneity x bias). Used
# for explicit-zero transition + support grids.
.SC_ALL_CELL_SLUGS <- local({
  g <- expand.grid(e = .SC_EFFECT_BANDS$slug,
                   h = .SC_HET_BANDS$slug,
                   b = .SC_BIAS_BANDS$slug,
                   stringsAsFactors = FALSE)
  paste(g$e, g$h, g$b, sep = "_")
})

# Default sample-size grid for the synthetic resampling layer (Q1
# per-cell + Q3 empirical-weighted composition). 75 and 100 are
# intentionally omitted from the default because the manuscript-facing
# convergence figures focus on n <= 50; callers can pass an extended
# grid explicitly when running diagnostics.
.SC_SIZE_GRID_DEFAULT <- c(5:30, 35L, 40L, 50L)

# Vectorized band cut. NA in -> NA out; the last band absorbs +Inf.
# `right_closed = FALSE` => half-open lo <= x < hi (effect, het axes:
# null < 0.05, small [0.05, 0.175), ...). `right_closed = TRUE` =>
# left-open lo < x <= hi (bias axis: clean x <= 0.5, modbias
# (0.5, 1.0], highbias > 1.0 or Inf). The boundary convention is part
# of the .SC_*_BANDS contract and differs by axis.
.sc_cut_band <- function(x, bands, right_closed = FALSE) {
  x <- suppressWarnings(as.numeric(x))
  out <- rep(NA_character_, length(x))
  for (i in seq_len(nrow(bands))) {
    last <- i == nrow(bands)
    if (isTRUE(right_closed)) {
      hit <- !is.na(x) & x > bands$lo[i] &
             (if (last) TRUE else x <= bands$hi[i])
    } else {
      hit <- !is.na(x) & x >= bands$lo[i] &
             (if (last) TRUE else x < bands$hi[i])
    }
    out[hit & is.na(out)] <- bands$slug[i]
  }
  out
}

# --- parallel dispatch (mirrors 60's .emp_lapply) ------------------------

# Deterministic seeds. .sc_seeds(B, base_seed) -> length-B integer
# vector. Each replicate's seed depends ONLY on b + base_seed.
.sc_seeds <- function(B, base_seed) {
  B <- as.integer(B); base_seed <- as.integer(base_seed)
  ((as.numeric(base_seed) + seq_len(B)) %% .Machine$integer.max) |>
    as.integer()
}

.sc_resolve_workers <- function(workers = NULL, B = 1L) {
  w <- if (!is.null(workers)) workers
       else suppressWarnings(as.integer(
              Sys.getenv("SYNTHETIC_COMPOSITION_WORKERS", "1")))
  w <- as.integer(w)
  if (length(w) != 1L || is.na(w) || w < 1L) w <- 1L
  min(w, max(1L, as.integer(B)))
}

# Dispatch B replicates either sequentially or via a PSOCK cluster.
# With workers > 1, every sim_/sc_/.sc_ helper plus the .emp_* / v4
# utility helpers are exported to each worker's global env so the
# dispatched closure can resolve its references.
.sc_lapply <- function(seq, fn, workers = 1L, ..., chunk_size = NULL) {
  workers <- as.integer(workers)
  if (workers <= 1L)
    return(lapply(seq, fn, ...))
  if (!requireNamespace("parallel", quietly = TRUE)) {
    message("[sc] 'parallel' namespace unavailable; falling back to ",
            "workers = 1.")
    return(lapply(seq, fn, ...))
  }
  src_env <- environment(sim_assign_observed_cell)
  if (is.null(src_env)) src_env <- .GlobalEnv
  syms_all <- ls(envir = src_env, all.names = TRUE)
  keep <- grepl("^(sim_|\\.sc_|\\.SC_|emp_|\\.emp_|\\.EMP_)", syms_all) |
          syms_all %in% c(".attenuation_pct", ".sign_flip", ".shrink50",
                          ".EVIDENCE_THRESHOLDS", ".robma_utils_loaded",
                          "%||%",
                          ".SIM_FIT_IDENTITY", ".SIM_DEFAULT_OUTPUT_ROOT",
                          ".SIM_DEFAULT_CORPUS_ID", ".SIM_DEFAULT_SCHEME",
                          ".SIM_DEFAULT_VINTAGE", ".SIM_DEFAULT_DESIGN_PATH",
                          ".SIM_DEFAULT_BASE_SEED")
  syms <- syms_all[keep]

  cl <- parallel::makePSOCKcluster(workers)
  on.exit(parallel::stopCluster(cl), add = TRUE)
  if (length(syms))
    parallel::clusterExport(cl, varlist = syms, envir = src_env)
  parallel::parLapplyLB(cl, seq, fn, ..., chunk.size = chunk_size)
}

# Symbols that need to land in every PSOCK worker so plan-level
# closures can resolve their references. Mirrors the symbol set
# .sc_lapply exports; centralized here so the plan-level engines and
# .sc_lapply stay in sync.
.sc_cluster_export_syms <- function() {
  src_env <- environment(sim_assign_observed_cell)
  if (is.null(src_env)) src_env <- .GlobalEnv
  syms_all <- ls(envir = src_env, all.names = TRUE)
  keep <- grepl("^(sim_|\\.sc_|\\.SC_|emp_|\\.emp_|\\.EMP_)", syms_all) |
          syms_all %in% c(".attenuation_pct", ".sign_flip", ".shrink50",
                          ".EVIDENCE_THRESHOLDS", ".robma_utils_loaded",
                          "%||%",
                          ".SIM_FIT_IDENTITY", ".SIM_DEFAULT_OUTPUT_ROOT",
                          ".SIM_DEFAULT_CORPUS_ID", ".SIM_DEFAULT_SCHEME",
                          ".SIM_DEFAULT_VINTAGE", ".SIM_DEFAULT_DESIGN_PATH",
                          ".SIM_DEFAULT_BASE_SEED")
  list(env = src_env, syms = syms_all[keep])
}

# --- registry loaders ----------------------------------------------------

#' Load + validate the EMPIRICAL v4 outcome registry.
#'
#' Thin wrapper over emp_read_outcome_registry() (which already refuses
#' an output_sim_* path and drops any sim_ rows) plus
#' emp_validate_registry() for the required v4 fields. Never reads a
#' simulation root.
sim_load_empirical_registry <- function(root = "output",
                                        overview_csv = NULL,
                                        require_ok = TRUE) {
  reg <- emp_read_outcome_registry(root = root, overview_csv = overview_csv)
  v   <- emp_validate_registry(reg, require_ok = require_ok)
  attr(reg, "validation") <- v
  reg
}

#' Load the final SYNTHETIC v4 outcome registry (output_sim_v30).
#'
#' Reads <root>/overview/outcome_registry.csv, KEEPS only sim_ strata,
#' refuses an empirical root, and recovers the synthetic identity by
#' joining the design crosswalk on stratum: target cell_slug,
#' legacy_cell_code, the design (DGM / target) effect / heterogeneity /
#' bias slugs + bands, and mu_true / tau_true. This is recovery of
#' design identity only -- it does NOT assign fitted-output cells (see
#' sim_assign_observed_cell()).
sim_load_synthetic_registry <- function(root = "output_sim_v30",
                                        overview_csv = NULL,
                                        design = NULL) {
  path <- overview_csv %||%
    file.path(root, "overview", "outcome_registry.csv")
  if (!grepl("output_sim", path))
    stop("Refusing to read a non-simulation root as the synthetic ",
         "registry: '", path, "'. Point this at output_sim_v30 ",
         "(or pass an explicit output_sim_* overview_csv).")
  if (!file.exists(path))
    stop("Simulation registry not found at '", path,
         "'. Build it with build_estimand_tables(root = \"", root,
         "\", output_dir = \"", root,
         "/overview\") only after the simulation library reaches ",
         "library_status = complete_clean / integrity_flag = ok.")
  reg <- utils::read.csv(path, stringsAsFactors = FALSE,
                         check.names = FALSE)
  if (!"stratum" %in% names(reg))
    stop("Synthetic registry has no 'stratum' column: '", path, "'.")
  n0 <- nrow(reg)
  reg <- reg[grepl("^sim_", reg$stratum), , drop = FALSE]
  if (nrow(reg) < n0)
    message(sprintf("[sc] dropped %d non-sim_ row(s) from synthetic registry",
                    n0 - nrow(reg)))
  if (nrow(reg) == 0L)
    stop("Synthetic registry contains no sim_ strata: '", path, "'.")

  if (is.null(design)) design <- sim_load_design()
  keep <- c("stratum", "cell_slug", "legacy_cell_code",
            "eff_band", "effect_slug", "mu_true",
            "het_band", "heterogeneity_slug", "tau_true",
            "bias_band", "bias_slug")
  dz <- design[, intersect(keep, names(design)), drop = FALSE]
  names(dz)[names(dz) == "eff_band"] <- "target_effect_band"
  names(dz)[names(dz) == "het_band"] <- "target_heterogeneity_band"
  names(dz)[names(dz) == "bias_band"] <- "target_bias_band"
  names(dz)[names(dz) == "effect_slug"] <- "target_effect_slug"
  names(dz)[names(dz) == "heterogeneity_slug"] <- "target_heterogeneity_slug"
  names(dz)[names(dz) == "bias_slug"] <- "target_bias_slug"
  names(dz)[names(dz) == "cell_slug"] <- "target_cell_slug"
  names(dz)[names(dz) == "legacy_cell_code"] <- "target_legacy_cell_code"

  reg$synthetic_stratum <- reg$stratum
  merged <- merge(reg, dz, by = "stratum", all.x = TRUE, sort = FALSE)
  unmatched <- unique(merged$stratum[is.na(merged$target_cell_slug)])
  if (length(unmatched))
    warning("Synthetic strata not present in design crosswalk: ",
            paste(unmatched, collapse = ", "),
            " (target identity will be NA for these rows).")
  attr(merged, "registry_path") <- path
  attr(merged, "design_n_strata") <- nrow(design)
  merged
}

# --- cell assignment -----------------------------------------------------

#' Assign FITTED / observed v3 cells from registry outputs.
#'
#' Cell-vocabulary contract (the same axes label synthetic design cells
#' and empirical fitted-cell assignments; the meaning differs):
#'
#'   Synthetic target cell (DGM cell, known by construction):
#'     effect_slug x heterogeneity_slug x bias_slug, encoded into the
#'     stratum slug as `sim_<effect>_<heterogeneity>_<bias>`.
#'
#'   Empirical fitted-cell assignment (deterministic projection,
#'   NOT a generative label):
#'     effect axis        = abs(mu_BC)
#'     heterogeneity axis = tau_BC
#'     bias axis          = log10BF_bias
#'
#' Current band thresholds (mirrored from `.SC_EFFECT_BANDS`,
#' `.SC_HET_BANDS`, `.SC_BIAS_BANDS` and the boundary conventions in
#' `.sc_cut_band()`):
#'
#'   Effect:
#'     null     : abs(mu_BC) <  0.05
#'     small    : 0.05  <= abs(mu_BC) <  0.175
#'     moderate : 0.175 <= abs(mu_BC) <  0.375
#'     large    : abs(mu_BC) >= 0.375
#'
#'   Heterogeneity:
#'     lowhet   : tau_BC <  0.10
#'     midhet   : 0.10  <= tau_BC <  0.275
#'     highhet  : tau_BC >= 0.275
#'
#'   Bias:
#'     clean    : log10BF_bias <= 0.5
#'     modbias  : 0.5 < log10BF_bias <= 1.0
#'     highbias : log10BF_bias > 1.0  (Inf is evidence, not missingness)
#'
#' Works for empirical or synthetic rows: the observed/fitted cell is
#' read off the fitted outputs only. For synthetic rows this is
#' deliberately the observed / fitted cell, NOT the DGM target cell,
#' and the two must be kept distinct (composition invariant: synthetic
#' fitted bias evidence is never coerced into target bins).
#'
#' The internal column `observed_cell_slug` is a technical handle for
#' the fitted profile cell; public reports / figure captions say
#' "fitted-cell assignment" or "fitted profile cell" instead.
sim_assign_observed_cell <- function(df) {
  need <- c("mu_BC", "tau_BC", "log10BF_bias")
  miss <- setdiff(need, names(df))
  if (length(miss))
    stop("sim_assign_observed_cell: registry missing column(s): ",
         paste(miss, collapse = ", "))
  df$observed_effect_slug <-
    .sc_cut_band(abs(suppressWarnings(as.numeric(df$mu_BC))),
                 .SC_EFFECT_BANDS)
  df$observed_heterogeneity_slug <-
    .sc_cut_band(df$tau_BC, .SC_HET_BANDS)
  df$observed_bias_slug <-
    .sc_cut_band(df$log10BF_bias, .SC_BIAS_BANDS, right_closed = TRUE)
  ok <- !is.na(df$observed_effect_slug) &
        !is.na(df$observed_heterogeneity_slug) &
        !is.na(df$observed_bias_slug)
  df$observed_cell_slug <- ifelse(ok,
    paste(df$observed_effect_slug, df$observed_heterogeneity_slug,
          df$observed_bias_slug, sep = "_"), NA_character_)
  df$observed_stratum <- ifelse(ok,
    paste0("sim_", df$observed_cell_slug), NA_character_)
  df
}

#' Empirical fitted-cell boundary-near diagnostic.
#'
#' Sensitivity check for the deterministic projection in
#' `sim_assign_observed_cell()`: for every empirical outcome, compute
#' the distance from its fitted axis value to the nearest band
#' boundary on each axis, plus a row-level boolean flag indicating
#' whether the outcome sits within `effect_boundary_eps` /
#' `het_boundary_eps` / `bias_boundary_eps` of any boundary on that
#' axis. Outputs are per-outcome; small per-stratum / per-axis
#' summaries are also returned as attributes.
#'
#' The defaults below are conservative and only flag genuinely
#' borderline rows; they are not used by any downstream weighting or
#' sampling step. The point is to make the boundary sensitivity
#' visible without introducing instability into the assignment.
#'
#' @param empirical_registry frame from sim_load_empirical_registry().
#' @param effect_boundary_eps absolute distance from {0.05, 0.175,
#'   0.375} on the effect axis below which the outcome is flagged.
#' @param het_boundary_eps absolute distance from {0.10, 0.275} on the
#'   heterogeneity axis below which the outcome is flagged.
#' @param bias_boundary_eps absolute distance from {0.5, 1.0} on the
#'   bias axis below which the outcome is flagged. `Inf` bias rows are
#'   not flagged.
#' @return per-outcome data.frame with: stratum, source_article,
#'   outcome_slug, observed_cell_slug, mu_BC, tau_BC, log10BF_bias,
#'   effect_dist_to_boundary, het_dist_to_boundary,
#'   bias_dist_to_boundary, near_effect_boundary, near_het_boundary,
#'   near_bias_boundary, near_any_boundary. Attributes carry
#'   per-axis and per-stratum summary counts.
sim_build_empirical_fitted_cell_boundary <- function(
    empirical_registry,
    effect_boundary_eps = 0.01,
    het_boundary_eps    = 0.02,
    bias_boundary_eps   = 0.10) {
  reg <- sim_assign_observed_cell(empirical_registry)
  effect_cuts <- c(0.05, 0.175, 0.375)
  het_cuts    <- c(0.10, 0.275)
  bias_cuts   <- c(0.5, 1.0)
  abs_mu <- abs(suppressWarnings(as.numeric(reg$mu_BC)))
  tau    <- suppressWarnings(as.numeric(reg$tau_BC))
  bias   <- suppressWarnings(as.numeric(reg$log10BF_bias))
  min_dist <- function(x, cuts) {
    if (!is.finite(x)) return(NA_real_)
    min(abs(x - cuts))
  }
  e_dist <- vapply(abs_mu, min_dist, numeric(1), cuts = effect_cuts)
  h_dist <- vapply(tau,    min_dist, numeric(1), cuts = het_cuts)
  b_dist <- vapply(bias,   min_dist, numeric(1), cuts = bias_cuts)
  near_e <- !is.na(e_dist) & e_dist <= effect_boundary_eps
  near_h <- !is.na(h_dist) & h_dist <= het_boundary_eps
  near_b <- !is.na(b_dist) & b_dist <= bias_boundary_eps
  identity_cols <- intersect(
    c("stratum", "source_article", "outcome_slug",
      "dataset_id", "analysis_id", "analysis_variant",
      "corpus_id", "scheme"),
    names(reg))
  out <- data.frame(
    reg[, identity_cols, drop = FALSE],
    mu_BC                   = suppressWarnings(as.numeric(reg$mu_BC)),
    tau_BC                  = tau,
    log10BF_bias            = bias,
    observed_effect_slug    = reg$observed_effect_slug,
    observed_heterogeneity_slug = reg$observed_heterogeneity_slug,
    observed_bias_slug      = reg$observed_bias_slug,
    observed_cell_slug      = reg$observed_cell_slug,
    effect_dist_to_boundary = e_dist,
    het_dist_to_boundary    = h_dist,
    bias_dist_to_boundary   = b_dist,
    near_effect_boundary    = near_e,
    near_het_boundary       = near_h,
    near_bias_boundary      = near_b,
    near_any_boundary       = near_e | near_h | near_b,
    effect_boundary_eps     = effect_boundary_eps,
    het_boundary_eps        = het_boundary_eps,
    bias_boundary_eps       = bias_boundary_eps,
    stringsAsFactors        = FALSE)
  n_total <- nrow(out)
  axis_counts <- c(
    near_effect = sum(near_e),
    near_het    = sum(near_h),
    near_bias   = sum(near_b),
    near_any    = sum(out$near_any_boundary))
  axis_props <- if (n_total > 0L) axis_counts / n_total
                else stats::setNames(rep(NA_real_, 4L), names(axis_counts))
  by_stratum <- if ("stratum" %in% names(out)) {
    sp <- split(out, out$stratum)
    do.call(rbind, lapply(names(sp), function(nm) {
      s <- sp[[nm]]
      data.frame(
        stratum             = nm,
        n_outcomes          = nrow(s),
        n_near_effect       = sum(s$near_effect_boundary, na.rm = TRUE),
        n_near_het          = sum(s$near_het_boundary, na.rm = TRUE),
        n_near_bias         = sum(s$near_bias_boundary, na.rm = TRUE),
        n_near_any          = sum(s$near_any_boundary, na.rm = TRUE),
        stringsAsFactors    = FALSE)
    }))
  } else NULL
  attr(out, "axis_counts")    <- axis_counts
  attr(out, "axis_proportions") <- axis_props
  attr(out, "by_stratum")     <- by_stratum
  attr(out, "n_total")        <- n_total
  out
}

#' Parse the SYNTHETIC target / DGM cell (design identity, not fitted).
#'
#' Refuses non-sim rows. The target cell comes from
#' sim_load_synthetic_registry()'s design join (target_cell_slug etc.);
#' if those columns are absent it falls back to parsing the stratum
#' slug (sim_<cell_slug>). Never inspects mu_BC / tau_BC / log10BF_bias.
sim_parse_target_cell <- function(df) {
  if (!"stratum" %in% names(df))
    stop("sim_parse_target_cell: no 'stratum' column.")
  if (any(!grepl("^sim_", df$stratum)))
    stop("sim_parse_target_cell: non-sim_ rows present; this is a ",
         "synthetic-only helper (use sim_assign_observed_cell for ",
         "fitted-output mapping).")
  if (!"target_cell_slug" %in% names(df) ||
      any(is.na(df$target_cell_slug))) {
    slug <- sub("^sim_", "", df$stratum)
    parts <- strsplit(slug, "_", fixed = TRUE)
    df$target_cell_slug <- slug
    df$target_effect_slug <- vapply(parts, `[`, "", 1L)
    df$target_heterogeneity_slug <- vapply(parts, `[`, "", 2L)
    df$target_bias_slug <- vapply(parts, `[`, "", 3L)
  }
  df
}

# --- empirical stratum cell weights + coherence --------------------------

#' Build empirical stratum fitted-cell mixture weights.
#'
#' For each empirical stratum, tabulate its outcomes over the fitted /
#' projected v3 cells (see `sim_assign_observed_cell()` for the
#' projection contract), then derive raw + smoothed weights and
#' per-stratum coherence scalars. The smoothed weight is what 65 uses
#' to sample empirical-weighted synthetic rows from the fitted
#' synthetic library; it is a posterior-style fitted-cell mixture, not
#' a generative claim.
#'
#' Default smoothing is "eb_corpus" with `kappa = 4`, `support =
#' "occupied"`: the recommended empirical-Bayes support-masked
#' weighting. For stratum s and fitted profile cell c:
#'
#'   w_sc = (n_sc + kappa * p0_{c|s}) / (n_s + kappa)
#'
#' where `n_sc` is the stratum count on cell c, `n_s` is the stratum's
#' assigned-outcome count, `kappa` is the prior pseudo-count, and
#' `p0_{c|s}` is the corpus fitted-cell distribution restricted and
#' renormalized over the cells the stratum occupies (i.e. cells where
#' `n_sc > 0`). The effective stratum-vs-corpus mixing weight is
#' `lambda_eff = n_s / (n_s + kappa)`; small strata shrink more
#' aggressively toward the corpus mix on their own occupied cells.
#' Sum of `w_sc` over a stratum's occupied cells is 1 by construction.
#'
#' Legacy smoothing options remain available for sensitivity:
#'   * "corpus_blend": `lambda * stratum_p + (1 - lambda) *
#'     overall_corpus_p`, blended only over the cells the stratum
#'     actually populates (then renormalized). Pre-2026-05 default.
#'   * "additive": Laplace smoothing over the full G-cell grid with
#'     pseudo-count `alpha`. Spreads mass onto unoccupied grid cells.
#'   * "none": raw proportions.
#'
#' @param empirical_registry frame from sim_load_empirical_registry().
#' @param smoothing One of "eb_corpus" (default), "corpus_blend",
#'   "additive", "none".
#' @param kappa empirical-Bayes prior pseudo-count (default 4;
#'   "eb_corpus" only). Larger kappa = stronger shrinkage toward the
#'   restricted corpus prior.
#' @param support Support scope for the empirical-Bayes prior, one of
#'   "occupied" (default; restrict + renormalize p0 over cells the
#'   stratum occupies). Currently the only supported scope.
#' @param alpha additive pseudo-count per grid cell (default 0.5;
#'   "additive" only).
#' @param lambda stratum-vs-corpus blend weight (default 0.75;
#'   "corpus_blend" only).
#' @param grid_cells full cell grid size used for entropy normalization
#'   (default 36).
#' @param drop_unassigned drop rows whose fitted cell is NA (default
#'   TRUE; per-stratum unassigned counts are kept in the output rows).
#' @return long data.frame: one row per (stratum, occupied fitted
#'   cell). Columns: stratum, cell_slug, effect_slug,
#'   heterogeneity_slug, bias_slug, n_outcomes (= `raw_count`),
#'   raw_count, raw_weight, corpus_weight (corpus marginal on this
#'   cell), prior_weight_restricted (the support-restricted prior
#'   `p0_{c|s}`; NA for non-"eb_corpus" smoothings), smoothed_weight,
#'   smoothing_method, smoothing, kappa, lambda_eff (= n_s / (n_s +
#'   kappa); NA for non-"eb_corpus" smoothings), support_scope,
#'   effective_n_cells, max_cell_share, normalized_entropy,
#'   dominant_cell, dominant_cell_share, n_assigned,
#'   n_occupied_cells, n_unassigned.
sim_build_empirical_cell_weights <- function(empirical_registry,
                                             smoothing = c("eb_corpus",
                                                           "corpus_blend",
                                                           "additive",
                                                           "none"),
                                             kappa = 4,
                                             support = c("occupied"),
                                             alpha = 0.5,
                                             lambda = 0.75,
                                             grid_cells = 36L,
                                             drop_unassigned = TRUE) {
  smoothing <- match.arg(smoothing)
  support   <- match.arg(support)
  kappa     <- as.numeric(kappa)
  if (smoothing == "eb_corpus" && (!is.finite(kappa) || kappa < 0))
    stop("sim_build_empirical_cell_weights: kappa must be a finite ",
         "non-negative number for smoothing = \"eb_corpus\".")
  reg <- sim_assign_observed_cell(empirical_registry)
  if (any(grepl("^sim_", reg$stratum)))
    stop("sim_build_empirical_cell_weights: synthetic sim_ strata ",
         "present in the empirical registry; refusing (weights must be ",
         "built from empirical outcomes only).")
  n_unassigned <- sum(is.na(reg$observed_cell_slug))
  unassigned_by_stratum <- tapply(is.na(reg$observed_cell_slug),
                                  reg$stratum, sum)
  if (isTRUE(drop_unassigned))
    reg <- reg[!is.na(reg$observed_cell_slug), , drop = FALSE]

  ov_tab <- table(reg$observed_cell_slug)
  overall_p <- as.numeric(ov_tab) / sum(ov_tab)
  names(overall_p) <- names(ov_tab)

  G  <- as.integer(grid_cells)
  out <- list()
  for (s in unique(reg$stratum)) {
    sd <- reg[reg$stratum == s, , drop = FALSE]
    n_s <- nrow(sd)
    tab <- table(sd$observed_cell_slug)
    cells <- names(tab); n_c <- as.integer(tab)
    raw <- n_c / n_s
    corpus_w <- as.numeric(overall_p[cells])
    prior_restricted <- rep(NA_real_, length(cells))
    lambda_eff_val <- NA_real_
    if (smoothing == "eb_corpus") {
      # support = "occupied": restrict p0 to cells the stratum occupies
      # and renormalize. (Other support scopes can be added later; only
      # "occupied" is exposed today.)
      p0_restricted <- corpus_w / sum(corpus_w)
      sm <- (n_c + kappa * p0_restricted) / (n_s + kappa)
      sm_method <- sprintf(
        "eb_corpus(kappa=%g, support=%s)", kappa, support)
      prior_restricted <- p0_restricted
      lambda_eff_val   <- n_s / (n_s + kappa)
    } else if (smoothing == "additive") {
      sm <- (n_c + alpha) / (n_s + alpha * G)
      sm_method <- sprintf("additive(alpha=%g, grid=%d)", alpha, G)
    } else if (smoothing == "corpus_blend") {
      sm <- lambda * raw + (1 - lambda) * corpus_w
      sm_method <- sprintf("corpus_blend(lambda=%g)", lambda)
    } else {
      sm <- raw
      sm_method <- "none"
    }
    sm <- sm / sum(sm)                       # renormalize occupied cells
    eff_n <- 1 / sum(sm^2)                   # inverse-Simpson (Hill q=2)
    max_share <- max(sm)
    ent <- -sum(sm * log(sm))
    norm_ent <- if (G > 1L) ent / log(G) else NA_real_
    dom_i <- which.max(sm)
    n_unassigned_s <- {
      u <- unassigned_by_stratum[[s]]
      if (is.null(u) || is.na(u)) 0L else as.integer(u)
    }
    sp <- strsplit(cells, "_", fixed = TRUE)
    out[[length(out) + 1L]] <- data.frame(
      stratum            = s,
      cell_slug          = cells,
      effect_slug        = vapply(sp, `[`, "", 1L),
      heterogeneity_slug = vapply(sp, `[`, "", 2L),
      bias_slug          = vapply(sp, `[`, "", 3L),
      n_outcomes         = n_c,
      raw_count          = n_c,
      raw_weight         = raw,
      corpus_weight      = corpus_w,
      prior_weight_restricted = prior_restricted,
      smoothed_weight    = sm,
      smoothing_method   = sm_method,
      smoothing          = smoothing,
      kappa              = if (smoothing == "eb_corpus") kappa
                           else NA_real_,
      lambda_eff         = lambda_eff_val,
      support_scope      = support,
      effective_n_cells  = eff_n,
      max_cell_share     = max_share,
      normalized_entropy = norm_ent,
      dominant_cell       = cells[dom_i],
      dominant_cell_share = sm[dom_i],
      n_assigned          = n_s,
      n_occupied_cells    = length(cells),
      n_unassigned        = n_unassigned_s,
      stringsAsFactors   = FALSE)
  }
  res <- do.call(rbind, out)
  attr(res, "n_unassigned")  <- n_unassigned
  attr(res, "grid_cells")    <- G
  attr(res, "smoothing")     <- smoothing
  attr(res, "kappa")         <- if (smoothing == "eb_corpus") kappa
                                else NA_real_
  attr(res, "support_scope") <- support
  res
}

#' Per-stratum coherence scalars distilled from the long weights frame.
#'
#' Returns one row per empirical stratum with the columns that are
#' constant within a stratum (n_assigned, n_occupied_cells, n_unassigned,
#' effective_n_cells, max_cell_share, normalized_entropy, dominant_cell,
#' dominant_cell_share, smoothing_method). Convenience view for humans
#' and the report; the long file is still the source of truth.
sim_stratum_coherence <- function(weights) {
  w <- weights[!duplicated(weights$stratum), , drop = FALSE]
  keep <- c("stratum", "n_assigned", "n_occupied_cells", "n_unassigned",
            "effective_n_cells", "max_cell_share", "normalized_entropy",
            "dominant_cell", "dominant_cell_share",
            "smoothing", "smoothing_method", "kappa", "lambda_eff",
            "support_scope")
  w[, intersect(keep, names(w)), drop = FALSE]
}

# --- composition input gate ----------------------------------------------

#' Hard completeness / identity gate on the current simulation library.
#'
#' Replicate-count agnostic: the per-cell target is each cell's own
#' `n_generated` from sim_inventory_library(), so the gate works at
#' 25/cell, 150/cell, or any future size without code edits. The gate
#' checks structural completeness only -- it does not look at any
#' row-count constant.
#'
#' Gate checks:
#'   * generated CSVs exist (n_generated_total > 0);
#'   * every design stratum has fitted rows in the registry;
#'   * every fitted cell has at least its generated-CSV count of rows
#'     (i.e. the fit covers the current generated library);
#'   * the generated library is uniform across cells;
#'   * uniform corpus_id / scheme / source_article / analysis_variant;
#'   * no missing required rigor fields.
#'
#' `allow_partial = TRUE` downgrades failures to a soft warning and
#' stamps every downstream output partial via the `dev_partial` column
#' and the report. Filenames stay stable regardless.
sim_validate_composition_inputs <- function(synthetic_registry,
                                             design        = NULL,
                                             inventory     = NULL,
                                             data_root     = "data",
                                             latent_root   = "simulation/latent",
                                             sim_output_root = "output_sim_v30",
                                             vintage       = "2026",
                                             allow_partial = FALSE) {
  if (is.null(design)) design <- sim_load_design()
  if (is.null(inventory))
    inventory <- sim_inventory_library(data_root   = data_root,
                                       latent_root = latent_root,
                                       output_root = sim_output_root,
                                       vintage     = vintage,
                                       design      = design)
  reg <- synthetic_registry
  strata_design <- sort(unique(design$stratum))
  n_strata_exp  <- length(strata_design)
  inv_per <- inventory$per_cell
  rownames(inv_per) <- inv_per$stratum
  n_total_generated <- as.integer(sum(inv_per$n_generated))

  problems <- character(0)
  add <- function(...) problems[[length(problems) + 1L]] <<- paste0(...)

  if (n_total_generated == 0L)
    add(sprintf("no generated CSVs under '%s/sim_*/%s/repNNNN.csv' ",
                data_root, paste0("sim", vintage)),
        "(run sim_generate_library() first)")

  strata_seen <- sort(unique(reg$stratum))
  if (!setequal(strata_seen, strata_design)) {
    add(sprintf("sim strata mismatch: %d seen vs %d design (missing: %s)",
                length(strata_seen), n_strata_exp,
                paste(setdiff(strata_design, strata_seen),
                      collapse = ",")))
  }

  per_cell_reg <- table(factor(reg$stratum, levels = strata_design))
  shortfall <- list()
  for (s in strata_design) {
    n_gen <- as.integer(inv_per[s, "n_generated"])
    n_seen <- as.integer(per_cell_reg[s])
    if (is.na(n_gen)) next
    if (n_gen == 0L) {
      shortfall[[length(shortfall) + 1L]] <-
        sprintf("%s: 0 generated CSVs", s)
    } else if (n_seen < n_gen) {
      shortfall[[length(shortfall) + 1L]] <-
        sprintf("%s: %d fitted < %d generated", s, n_seen, n_gen)
    }
  }
  if (length(shortfall))
    add(sprintf("%d cell(s) under-fitted vs generated library (e.g. %s)",
                length(shortfall),
                paste(utils::head(unlist(shortfall), 5), collapse = "; ")))

  generated_uniform <- inventory$overall$generated_reps_uniform
  if (!generated_uniform && n_total_generated > 0L)
    add(sprintf(paste0("generated library is uneven across cells ",
                       "(%d..%d/cell); composition gates expect a ",
                       "uniform library before claiming complete coverage"),
                inventory$overall$generated_reps_min,
                inventory$overall$generated_reps_max))

  for (k in names(.SC_SIM_IDENTITY)) {
    if (!k %in% names(reg)) { add(sprintf("identity column absent: %s", k))
      next }
    seen <- unique(as.character(reg[[k]]))
    if (length(seen) != 1L || seen[1] != .SC_SIM_IDENTITY[[k]])
      add(sprintf("identity %s = {%s}; expected '%s'", k,
                  paste(seen, collapse = ","), .SC_SIM_IDENTITY[[k]]))
  }

  rigor_req <- c("log10BF_rigor", "log10BF_rigor_effect",
                 "log10BF_rigor_no_effect", "rigor_direction",
                 "rigor_category", "mu_BC", "tau_BC",
                 "log10BF_bias", "log10BF_effect", "log10BF_het")
  miss_cols <- setdiff(rigor_req, names(reg))
  if (length(miss_cols))
    add(sprintf("required rigor field(s) absent: %s",
                paste(miss_cols, collapse = ",")))
  for (cl in intersect(rigor_req, names(reg))) {
    if (cl %in% c("rigor_direction", "rigor_category")) {
      nbad <- sum(is.na(reg[[cl]]) | !nzchar(as.character(reg[[cl]])))
    } else {
      nbad <- sum(is.na(suppressWarnings(as.numeric(reg[[cl]]))))
    }
    if (nbad > 0L)
      add(sprintf("required field %s has %d missing value(s)", cl, nbad))
  }

  ok <- length(problems) == 0L
  if (!ok && !isTRUE(allow_partial))
    stop("sim_validate_composition_inputs: simulation library is NOT ",
         "composition-ready:\n  - ",
         paste(problems, collapse = "\n  - "),
         "\nRe-run after the library is generated AND fitted ",
         "(library_status = complete_clean / integrity_flag = ok), or ",
         "pass allow_partial = TRUE to produce explicitly labelled ",
         "DEV / PARTIAL outputs (rows + report carry the partial flag; ",
         "filenames stay stable).")
  if (!ok && isTRUE(allow_partial))
    warning("sim_validate_composition_inputs: proceeding with ",
            "allow_partial = TRUE on an INCOMPLETE library; outputs ",
            "are DEV/PARTIAL (dev_partial = TRUE) and not operating ",
            "characteristics.")

  list(ok = ok,
       allow_partial = isTRUE(allow_partial),
       partial = !ok,
       problems = problems,
       summary = list(
         n_rows                 = nrow(reg),
         n_generated_total      = n_total_generated,
         n_strata               = length(strata_seen),
         n_strata_expected      = n_strata_exp,
         generated_reps_min     = inventory$overall$generated_reps_min,
         generated_reps_max     = inventory$overall$generated_reps_max,
         generated_reps_uniform = generated_uniform,
         library_status         = inventory$overall$library_status))
}

# --- composition draws ---------------------------------------------------
# Pool key. The empirical weights are over OBSERVED / fitted cells; the
# synthetic library is indexed by its TARGET / DGM cell (the regime it
# was generated under). Default matching draws library rows from the
# target-cell pool whose slug equals the empirical observed-cell slug
# ("can generic regime X reproduce outcomes that LOOK like cell X?").
# pool_key = "observed" is a sensitivity option only.
.sc_pool_index <- function(synthetic_registry, pool_key) {
  syn <- synthetic_registry
  if (pool_key == "target") {
    syn <- sim_parse_target_cell(syn)
    key <- syn$target_cell_slug
  } else {
    syn <- sim_assign_observed_cell(syn)
    key <- syn$observed_cell_slug
  }
  split(seq_len(nrow(syn)), key)
}

# Soft provenance check: compare the per-cell synthetic pool size that
# 65 will resample from (length(pidx[[cell]])) to the per-cell n_fit
# that 55 reports in cell_diagnostics_rigor.csv (which reads sidecars
# directly, no overview registry needed). If the diagnostics file
# reports materially larger n_fit than the registry-derived pool, that
# is a strong signal that output_sim_v30/overview/outcome_registry.csv
# is stale relative to the fitted sidecars on disk. Returns a single
# string (warning message) or "" when nothing notable. NEVER hard-
# fails; dev/partial runs need to be possible.
.sc_check_registry_freshness <- function(pool_index, results_dir,
                                          verbose = TRUE) {
  diag_path <- file.path(results_dir, "cell_diagnostics_rigor.csv")
  if (!file.exists(diag_path)) return("")
  diag <- tryCatch(
    utils::read.csv(diag_path, stringsAsFactors = FALSE,
                    check.names = FALSE),
    error = function(e) NULL)
  if (is.null(diag) || !nrow(diag) ||
      !all(c("cell_slug", "n_fit") %in% names(diag)))
    return("")
  diag$n_fit <- suppressWarnings(as.integer(diag$n_fit))
  pool_size <- vapply(diag$cell_slug, function(cs) {
    ix <- pool_index[[cs]]
    if (is.null(ix)) NA_integer_ else as.integer(length(ix))
  }, integer(1))
  delta <- diag$n_fit - pool_size
  delta[is.na(delta)] <- 0L
  short <- delta > 0L
  if (!any(short)) return("")
  n_short <- sum(short)
  worst_ix <- order(-delta)[1:min(3L, n_short)]
  worst_str <- paste(sprintf("%s (n_fit=%d > pool=%d)",
                              diag$cell_slug[worst_ix],
                              diag$n_fit[worst_ix],
                              pool_size[worst_ix]),
                      collapse = "; ")
  msg <- sprintf(paste0(
    "registry-freshness: cell_diagnostics_rigor.csv reports larger ",
    "n_fit than output_sim_v30/overview/outcome_registry.csv for ",
    "%d cell(s) (e.g. %s). Rebuild the simulation overview registry ",
    "before running Q1 size curves:\n",
    "  source(\"scripts/60_estimand_tables.R\")\n",
    "  build_estimand_tables(root = \"output_sim_v30\", ",
    "output_dir = \"output_sim_v30/overview\")"),
    n_short, worst_str)
  if (isTRUE(verbose)) warning(msg, call. = FALSE)
  msg
}

#' Refresh the simulation overview registry from current sidecars.
#'
#' Thin convenience wrapper around the main reporting pipeline's
#' `build_estimand_tables()`. Provided here because 65 consumes the
#' registry it writes (`output_sim_v30/overview/outcome_registry.csv`),
#' so after a fitted-library change the registry must be rebuilt
#' before the synthetic resampling layer reads from it.
#'
#' As of 2026-05 this is called automatically from
#' `sim_run_synthetic_resampling()` (default `refresh_registry = TRUE`)
#' so the canonical operator flow collapses to:
#'
#'   sim_build_cell_diagnostics()          # 55, reads sidecars directly
#'   sim_run_synthetic_resampling(...)     # 65, auto-refreshes then runs
#'
#' Call this directly only when you want the registry rebuild without
#' the resampling subroutines (e.g. to feed another consumer), or pass
#' `refresh_registry = FALSE` to `sim_run_synthetic_resampling()` to
#' skip it (when the registry is known fresh from an earlier call in
#' the same session). Sentinel-sources `scripts/60_estimand_tables.R`
#' define-only if needed.
#'
#' @param root        Simulation output root (default "output_sim_v30").
#' @param output_dir  Where the rebuilt overview tables live (default
#'   `<root>/overview`).
#' @param write_tex   Forwarded to `build_estimand_tables()`; default
#'   FALSE because the simulation flow only needs the CSV registry.
#' @return Whatever `build_estimand_tables()` returns (invisible).
sim_refresh_synthetic_registry <- function(
    root       = "output_sim_v30",
    output_dir = file.path(root, "overview"),
    write_tex  = FALSE) {
  if (!exists("build_estimand_tables", inherits = TRUE)) {
    for (.p in c("scripts/60_estimand_tables.R",
                 "60_estimand_tables.R",
                 file.path("..", "scripts", "60_estimand_tables.R"))) {
      if (file.exists(.p)) { source(.p); break }
    }
    if (exists(".p")) rm(.p)
  }
  if (!exists("build_estimand_tables", inherits = TRUE))
    stop("sim_refresh_synthetic_registry: could not find ",
         "build_estimand_tables(); source scripts/60_estimand_tables.R ",
         "first.")
  build_estimand_tables(root       = root,
                        output_dir = output_dir,
                        write_tex  = write_tex)
}

#' Compose one synthetic stratum draw for one empirical stratum.
#'
#' Samples n_outcomes synthetic library rows: draw a cell ~ smoothed
#' weights, then a row uniformly (with replacement) from that cell's
#' pool, relabel stratum to the empirical stratum, and summarize with
#' the shared emp_stratum_summary() reducer. Cells with no synthetic
#' pool are dropped and the weights renormalized (recorded in attr).
#'
#' @return one-row data.frame (emp_stratum_summary schema) + the
#'   empirical stratum label; attr "n_dropped_cells".
sim_compose_stratum_once <- function(stratum, weights, pool_index,
                                     synthetic_registry,
                                     n_outcomes, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)
  w <- weights[weights$stratum == stratum, , drop = FALSE]
  if (nrow(w) == 0L)
    stop("sim_compose_stratum_once: no weights for stratum '", stratum,
         "'.")
  have <- w$cell_slug %in% names(pool_index)
  n_dropped <- sum(!have)
  w <- w[have, , drop = FALSE]
  if (nrow(w) == 0L)
    stop("sim_compose_stratum_once: no synthetic pool for any weighted ",
         "cell of stratum '", stratum, "'.")
  pw <- w$smoothed_weight / sum(w$smoothed_weight)
  picks_cell <- sample(w$cell_slug, size = n_outcomes, replace = TRUE,
                       prob = pw)
  idx <- vapply(picks_cell, function(cs) {
    pool <- pool_index[[cs]]
    if (length(pool) == 1L) pool else sample(pool, 1L)
  }, integer(1))
  slice <- synthetic_registry[idx, , drop = FALSE]
  slice$stratum <- stratum
  summ <- emp_stratum_summary(slice)
  attr(summ, "n_dropped_cells") <- n_dropped
  summ
}

# Per-replicate worker (self-contained for PSOCK dispatch): one
# replicate's stratum-level composition draws across every empirical
# stratum.
.sc_replicate_strata <- function(b, empirical_registry, synthetic_registry,
                                 weights, pidx, strata, emp_n,
                                 n_outcomes_override, pool_key, seeds) {
  rows <- vector("list", length(strata))
  base <- seeds[b]
  for (si in seq_along(strata)) {
    s <- strata[si]
    n_s <- if (!is.null(n_outcomes_override))
      as.integer(n_outcomes_override) else as.integer(emp_n[[s]])
    sd <- as.integer((as.numeric(base) + si) %% .Machine$integer.max)
    r  <- sim_compose_stratum_once(s, weights, pidx,
                                   synthetic_registry, n_s, seed = sd)
    r$composition_id    <- b
    r$pool_key          <- pool_key
    r$seed              <- sd
    r$n_outcomes_target <- n_s
    rows[[si]] <- r
  }
  do.call(rbind, rows)
}

# Per-replicate worker: one replicate's corpus draw (all strata pooled).
.sc_replicate_corpus <- function(b, empirical_registry, synthetic_registry,
                                 weights, pidx, strata, emp_n,
                                 n_outcomes_override, pool_key, seeds) {
  pieces <- list()
  base <- seeds[b]
  for (si in seq_along(strata)) {
    s <- strata[si]
    n_s <- if (!is.null(n_outcomes_override))
      as.integer(n_outcomes_override) else as.integer(emp_n[[s]])
    sd <- as.integer((as.numeric(base) + si) %% .Machine$integer.max)
    set.seed(sd)
    w <- weights[weights$stratum == s, , drop = FALSE]
    w <- w[w$cell_slug %in% names(pidx), , drop = FALSE]
    if (nrow(w) == 0L) next
    pw <- w$smoothed_weight / sum(w$smoothed_weight)
    pc <- sample(w$cell_slug, n_s, replace = TRUE, prob = pw)
    ix <- vapply(pc, function(cs) {
      pool <- pidx[[cs]]
      if (length(pool) == 1L) pool else sample(pool, 1L)
    }, integer(1))
    sl <- synthetic_registry[ix, , drop = FALSE]
    sl$stratum <- s
    pieces[[length(pieces) + 1L]] <- sl
  }
  comp <- do.call(rbind, pieces)
  cs   <- emp_corpus_summary(comp)
  cs$composition_id <- b
  cs$pool_key       <- pool_key
  cs$seed           <- as.integer(base)
  cs
}

# Build n_grid plan list for the Q3 composition size curve. Each plan
# is one n_outcomes_target value plus enough metadata for its
# deterministic per-(plan, b) seed.
.sc_build_composition_curve_plans <- function(n_grid) {
  plans <- vector("list", length(n_grid))
  for (ni in seq_along(n_grid)) {
    plans[[ni]] <- list(
      plan_id    = ni,
      n_index    = ni,
      n_outcomes = as.integer(n_grid[ni]))
  }
  plans
}

# Run all B composition replicates for one (n_outcomes_target) plan
# sequentially. Seeds depend only on (plan_id, b, base_seed), so the
# result is identical regardless of which worker (or whether any
# worker) executes the plan.
.sc_run_composition_curve_plan <- function(plan_index, plans,
                                           empirical_registry,
                                           synthetic_registry,
                                           weights, pidx, strata,
                                           emp_n, pool_key, smoothing,
                                           B, base_seed) {
  p <- plans[[plan_index]]
  # Preserve the legacy per-n seed-offset formula so byte-equality with
  # the pre-refactor sequential path is maintained.
  seeds <- .sc_seeds(B, as.integer(base_seed + (p$n_index - 1L) * 1000L))
  rows <- lapply(seq_len(B), function(b)
    .sc_replicate_strata(b, empirical_registry, synthetic_registry,
                         weights, pidx, strata, emp_n,
                         n_outcomes_override = p$n_outcomes,
                         pool_key = pool_key, seeds = seeds))
  st <- do.call(rbind, rows)
  if (!is.null(st)) {
    st$n_outcomes_target <- as.integer(p$n_outcomes)
    st$smoothing         <- smoothing
  }
  st
}

#' Compose B synthetic stratum draws across every empirical stratum.
#'
#' Preserves each empirical stratum's observed outcome count unless
#' n_outcomes_override is given. Deterministic per (b, stratum) via
#' base_seed; results are byte-identical regardless of worker count.
#'
#' @param workers Optional integer (default 1L = sequential; env
#'   override `SYNTHETIC_COMPOSITION_WORKERS`).
#' @return data.frame of B*S stratum-summary rows (composition_id,
#'   seed, pool_key, n_outcomes_target columns added).
sim_compose_strata <- function(empirical_registry, synthetic_registry,
                               weights, B = 200L, pool_key = "target",
                               n_outcomes_override = NULL,
                               base_seed = 20260601L,
                               workers = NULL, verbose = TRUE) {
  pidx <- .sc_pool_index(synthetic_registry, pool_key)
  emp_n <- tapply(seq_len(nrow(empirical_registry)),
                  empirical_registry$stratum, length)
  strata <- intersect(unique(weights$stratum), names(emp_n))
  seeds <- .sc_seeds(B, base_seed)
  w_n   <- .sc_resolve_workers(workers, B)
  if (isTRUE(verbose))
    message(sprintf("[sc][strata] B=%d, workers=%d, strata=%d, ",
                    B, w_n, length(strata)),
            sprintf("pool_key=%s", pool_key))
  rows <- .sc_lapply(
    seq_len(B),
    function(b) .sc_replicate_strata(b, empirical_registry,
      synthetic_registry, weights, pidx, strata, emp_n,
      n_outcomes_override, pool_key, seeds),
    workers = w_n)
  do.call(rbind, rows)
}

#' Compose B synthetic CORPUS draws (all strata pooled per draw).
#'
#' Mirrors the empirical corpus = all strata pooled. Each draw rebuilds
#' the full composed corpus row via the shared emp_corpus_summary().
sim_compose_corpus <- function(empirical_registry, synthetic_registry,
                               weights, B = 200L, pool_key = "target",
                               n_outcomes_override = NULL,
                               base_seed = 20260701L,
                               workers = NULL, verbose = TRUE) {
  pidx <- .sc_pool_index(synthetic_registry, pool_key)
  emp_n <- tapply(seq_len(nrow(empirical_registry)),
                  empirical_registry$stratum, length)
  strata <- intersect(unique(weights$stratum), names(emp_n))
  seeds <- .sc_seeds(B, base_seed)
  w_n   <- .sc_resolve_workers(workers, B)
  if (isTRUE(verbose))
    message(sprintf("[sc][corpus] B=%d, workers=%d, strata=%d, ",
                    B, w_n, length(strata)),
            sprintf("pool_key=%s", pool_key))
  rows <- .sc_lapply(
    seq_len(B),
    function(b) .sc_replicate_corpus(b, empirical_registry,
      synthetic_registry, weights, pidx, strata, emp_n,
      n_outcomes_override, pool_key, seeds),
    workers = w_n)
  do.call(rbind, rows)
}

#' Collapse composition draws to median / q05 / q95 (and q025 / q975)
#' per (group, metric). Used as the synthetic side of 70 agreement.
sim_summarize_composition_draws <- function(draws,
                                            group_col = "stratum") {
  metrics <- intersect(
    c(.SC_PRIMARY_METRICS, .SC_COMPONENT_METRICS,
      "n_outcomes", "n_source_articles"), names(draws))
  out <- list()
  for (g in unique(draws[[group_col]])) {
    d <- draws[draws[[group_col]] == g, , drop = FALSE]
    for (mname in metrics) {
      v <- suppressWarnings(as.numeric(d[[mname]]))
      vv <- v[!is.na(v)]
      out[[length(out) + 1L]] <- data.frame(
        group = g, metric = mname,
        synthetic_median = if (length(vv)) stats::median(vv) else NA_real_,
        synthetic_q05  = .emp_qtl(vv, 0.05),
        synthetic_q95  = .emp_qtl(vv, 0.95),
        synthetic_q025 = .emp_qtl(vv, 0.025),
        synthetic_q975 = .emp_qtl(vv, 0.975),
        n_synthetic_draws = length(vv),
        stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

# --- target <-> observed transition + provenance -------------------------

#' 36x36 synthetic cell transition with explicit zeros.
#'
#' Joint count of (target_cell_slug, observed_cell_slug) over the
#' synthetic registry, expanded to the full .SC_ALL_CELL_SLUGS x
#' .SC_ALL_CELL_SLUGS grid, with row-normalized P(O | T) and
#' column-normalized P(T | O).
sim_build_cell_transition <- function(synthetic_registry) {
  syn <- sim_assign_observed_cell(sim_parse_target_cell(synthetic_registry))
  d <- syn[!is.na(syn$target_cell_slug) &
           !is.na(syn$observed_cell_slug), , drop = FALSE]
  joint <- as.data.frame(table(target_cell_slug = d$target_cell_slug,
                               observed_cell_slug = d$observed_cell_slug),
                          stringsAsFactors = FALSE)
  names(joint)[3] <- "n_rows"
  full <- expand.grid(target_cell_slug = .SC_ALL_CELL_SLUGS,
                      observed_cell_slug = .SC_ALL_CELL_SLUGS,
                      stringsAsFactors = FALSE)
  full <- merge(full, joint,
                by = c("target_cell_slug", "observed_cell_slug"),
                all.x = TRUE, sort = FALSE)
  full$n_rows[is.na(full$n_rows)] <- 0L
  rt <- tapply(full$n_rows, full$target_cell_slug, sum)
  ct <- tapply(full$n_rows, full$observed_cell_slug, sum)
  full$p_observed_given_target <- ifelse(
    rt[full$target_cell_slug] > 0,
    full$n_rows / rt[full$target_cell_slug], NA_real_)
  full$p_target_given_observed <- ifelse(
    ct[full$observed_cell_slug] > 0,
    full$n_rows / ct[full$observed_cell_slug], NA_real_)
  full[order(full$target_cell_slug, full$observed_cell_slug),
       c("target_cell_slug", "observed_cell_slug", "n_rows",
         "p_observed_given_target", "p_target_given_observed")]
}

#' Axis-level synthetic transition (collapses the cell transition).
#'
#' @param axis "effect" (4x4), "heterogeneity" (3x3) or "bias" (3x3).
sim_build_axis_transition <- function(synthetic_registry,
                                      axis = c("effect",
                                               "heterogeneity",
                                               "bias")) {
  axis <- match.arg(axis)
  syn <- sim_assign_observed_cell(sim_parse_target_cell(synthetic_registry))
  tcol <- paste0("target_", axis, "_slug")
  ocol <- paste0("observed_", axis, "_slug")
  lvl <- switch(axis,
                effect = .SC_EFFECT_BANDS$slug,
                heterogeneity = .SC_HET_BANDS$slug,
                bias = .SC_BIAS_BANDS$slug)
  d <- syn[!is.na(syn[[tcol]]) & !is.na(syn[[ocol]]), , drop = FALSE]
  joint <- as.data.frame(table(t = d[[tcol]], o = d[[ocol]]),
                          stringsAsFactors = FALSE)
  names(joint) <- c(paste0("target_", axis),
                    paste0("observed_", axis), "n_rows")
  full <- expand.grid(t = lvl, o = lvl, stringsAsFactors = FALSE)
  names(full) <- c(paste0("target_", axis), paste0("observed_", axis))
  full <- merge(full, joint, all.x = TRUE, sort = FALSE)
  full$n_rows[is.na(full$n_rows)] <- 0L
  rt <- tapply(full$n_rows, full[[paste0("target_", axis)]], sum)
  ct <- tapply(full$n_rows, full[[paste0("observed_", axis)]], sum)
  kt <- full[[paste0("target_", axis)]]
  ko <- full[[paste0("observed_", axis)]]
  full$p_observed_given_target <-
    ifelse(rt[kt] > 0, full$n_rows / rt[kt], NA_real_)
  full$p_target_given_observed <-
    ifelse(ct[ko] > 0, full$n_rows / ct[ko], NA_real_)
  full
}

#' Per-empirical-stratum target provenance + observed recovery.
#'
#' For each empirical stratum s with observed-cell weights w_s(o) from
#' sim_build_empirical_cell_weights():
#'   provenance  P_s(T = t) = sum_o w_s(o) * P(T = t | O = o)
#'   recovery    P_s(O = o') = sum_o w_s(o) * P(O = o' | T = o)
#'     [matched target = observed-slug pool, the composition assumption]
#' Both renormalized within stratum.
sim_build_stratum_provenance_projection <- function(empirical_weights,
                                                    cell_transition) {
  w  <- empirical_weights
  tr <- cell_transition
  prov <- list(); rec <- list()
  for (s in unique(w$stratum)) {
    ws <- w[w$stratum == s, , drop = FALSE]
    pv <- merge(ws[, c("cell_slug", "smoothed_weight")],
                tr[!is.na(tr$p_target_given_observed) &
                   tr$p_target_given_observed > 0,
                   c("observed_cell_slug", "target_cell_slug",
                     "p_target_given_observed")],
                by.x = "cell_slug", by.y = "observed_cell_slug")
    if (nrow(pv)) {
      pv$contrib <- pv$smoothed_weight * pv$p_target_given_observed
      ag <- tapply(pv$contrib, pv$target_cell_slug, sum)
      prov[[length(prov) + 1L]] <- data.frame(
        stratum = s, target_cell_slug = names(ag),
        p_target = as.numeric(ag) / sum(ag),
        stringsAsFactors = FALSE)
    }
    rv <- merge(ws[, c("cell_slug", "smoothed_weight")],
                tr[!is.na(tr$p_observed_given_target) &
                   tr$p_observed_given_target > 0,
                   c("target_cell_slug", "observed_cell_slug",
                     "p_observed_given_target")],
                by.x = "cell_slug", by.y = "target_cell_slug")
    if (nrow(rv)) {
      rv$contrib <- rv$smoothed_weight * rv$p_observed_given_target
      ag <- tapply(rv$contrib, rv$observed_cell_slug, sum)
      rec[[length(rec) + 1L]] <- data.frame(
        stratum = s, observed_cell_slug = names(ag),
        p_observed = as.numeric(ag) / sum(ag),
        stringsAsFactors = FALSE)
    }
  }
  list(provenance = do.call(rbind, prov),
       recovery   = do.call(rbind, rec))
}

#' Synthetic pool support diagnostics over the 36-cell grid.
#'
#' Per (basis, cell): n_rows_available, empty_flag, sparse_flag.
#'
#' @param basis "target" (DGM-cell pool) or "observed" (fitted-cell
#'   pool); the pool key the composition would sample from.
#' @param sparse_threshold rows at / below which a non-empty cell is
#'   "sparse" (default 5).
sim_build_synthetic_support_diagnostics <- function(synthetic_registry,
                                                    basis = c("target",
                                                              "observed"),
                                                    sparse_threshold = 5L) {
  basis <- match.arg(basis)
  if (basis == "target") {
    syn <- sim_parse_target_cell(synthetic_registry)
    key <- syn$target_cell_slug
  } else {
    syn <- sim_assign_observed_cell(synthetic_registry)
    key <- syn$observed_cell_slug
  }
  tab <- table(factor(key, levels = .SC_ALL_CELL_SLUGS))
  n_av <- as.integer(tab)
  data.frame(
    basis            = basis,
    cell_slug        = .SC_ALL_CELL_SLUGS,
    n_rows_available = n_av,
    empty_flag       = n_av == 0L,
    sparse_flag      = n_av > 0L & n_av <= as.integer(sparse_threshold),
    stringsAsFactors = FALSE)
}

# --- output validation checks --------------------------------------------

#' Validation-checks long audit frame for the composition outputs.
#'
#' Audits the OUTPUT objects (weights, transitions, provenance, support)
#' for structural correctness (sum-to-1, normalization, non-mixing).
#' Pure: reads / writes nothing.
sim_composition_validation_checks <- function(weights,
                                               synthetic_registry,
                                               empirical_registry,
                                               cell_transition = NULL,
                                               axis_transitions = NULL,
                                               provenance_projection = NULL,
                                               support = NULL,
                                               gate = NULL,
                                               tol = 1e-6) {
  rows <- list()
  add <- function(check, scope, status, detail, value = NA_real_)
    rows[[length(rows) + 1L]] <<- data.frame(
      check = check, scope = scope, status = status,
      detail = detail, value = as.numeric(value),
      stringsAsFactors = FALSE)

  for (wcol in c("smoothed_weight", "raw_weight")) {
    sums <- tapply(weights[[wcol]], weights$stratum, sum)
    worst <- max(abs(sums - 1))
    bad <- names(sums)[abs(sums - 1) > tol]
    add(paste0(wcol, "_sums_to_1"), "stratum",
        if (length(bad)) "FAIL" else "PASS",
        if (length(bad)) paste("strata off 1:", paste(bad, collapse = ","))
        else sprintf("all %d strata sum to 1", length(sums)), worst)
  }

  emp_sim <- sum(grepl("^sim_", empirical_registry$stratum))
  add("empirical_no_sim_strata", "registry",
      if (emp_sim == 0L) "PASS" else "FAIL",
      sprintf("%d sim_ rows in empirical registry", emp_sim), emp_sim)
  syn_nonsim <- sum(!grepl("^sim_", synthetic_registry$stratum))
  add("synthetic_all_sim_strata", "registry",
      if (syn_nonsim == 0L) "PASS" else "FAIL",
      sprintf("%d non-sim_ rows in synthetic registry", syn_nonsim),
      syn_nonsim)

  if (!is.null(cell_transition)) {
    rt  <- tapply(cell_transition$n_rows,
                  cell_transition$target_cell_slug, sum)
    chk <- tapply(cell_transition$p_observed_given_target,
                  cell_transition$target_cell_slug,
                  function(p) sum(p[!is.na(p)]))
    nz  <- names(rt)[rt > 0]
    werr <- if (length(nz)) max(abs(chk[nz] - 1)) else 0
    add("P_O_given_T_rows_sum_to_1", "cell_transition",
        if (werr <= tol) "PASS" else "FAIL",
        sprintf("%d non-empty target rows", length(nz)), werr)
    ctt  <- tapply(cell_transition$n_rows,
                   cell_transition$observed_cell_slug, sum)
    chk2 <- tapply(cell_transition$p_target_given_observed,
                    cell_transition$observed_cell_slug,
                    function(p) sum(p[!is.na(p)]))
    nz2  <- names(ctt)[ctt > 0]
    werr2 <- if (length(nz2)) max(abs(chk2[nz2] - 1)) else 0
    add("P_T_given_O_cols_sum_to_1", "cell_transition",
        if (werr2 <= tol) "PASS" else "FAIL",
        sprintf("%d non-empty observed cols", length(nz2)), werr2)
  }

  if (!is.null(axis_transitions)) {
    for (ax in names(axis_transitions)) {
      tr <- axis_transitions[[ax]]
      tcol <- paste0("target_", ax)
      rt  <- tapply(tr$n_rows, tr[[tcol]], sum)
      chk <- tapply(tr$p_observed_given_target, tr[[tcol]],
                    function(p) sum(p[!is.na(p)]))
      nz  <- names(rt)[rt > 0]
      werr <- if (length(nz)) max(abs(chk[nz] - 1)) else 0
      add(sprintf("axis_%s_P_O_given_T_sum_to_1", ax), "axis_transition",
          if (werr <= tol) "PASS" else "FAIL",
          sprintf("%d non-empty %s target levels", length(nz), ax), werr)
    }
  }

  if (!is.null(provenance_projection)) {
    pv <- provenance_projection$provenance
    rc <- provenance_projection$recovery
    if (!is.null(pv) && nrow(pv)) {
      s <- tapply(pv$p_target, pv$stratum, sum)
      add("provenance_p_target_sum_to_1", "stratum",
          if (max(abs(s - 1)) <= tol) "PASS" else "FAIL",
          sprintf("%d strata", length(s)), max(abs(s - 1)))
    }
    if (!is.null(rc) && nrow(rc)) {
      s <- tapply(rc$p_observed, rc$stratum, sum)
      add("recovery_p_observed_sum_to_1", "stratum",
          if (max(abs(s - 1)) <= tol) "PASS" else "FAIL",
          sprintf("%d strata", length(s)), max(abs(s - 1)))
    }
  }

  if (!is.null(support)) {
    for (bk in names(support)) {
      sp <- support[[bk]]
      add(sprintf("support_%s_empty_cells", bk), "support", "INFO",
          sprintf("%d/%d grid cells empty", sum(sp$empty_flag),
                  nrow(sp)), sum(sp$empty_flag))
      add(sprintf("support_%s_sparse_cells", bk), "support", "INFO",
          sprintf("%d/%d grid cells sparse (n<=5)", sum(sp$sparse_flag),
                  nrow(sp)), sum(sp$sparse_flag))
    }
  }

  if (!is.null(gate)) {
    add("input_gate", "registry",
        if (isTRUE(gate$ok)) "PASS"
        else if (isTRUE(gate$partial)) "WARN" else "FAIL",
        if (length(gate$problems)) paste(gate$problems, collapse = "; ")
        else "library composition-ready",
        gate$summary$n_rows %||% NA_real_)
  }
  do.call(rbind, rows)
}

# --- markdown report -----------------------------------------------------

.sc_md_table <- function(df, cols = names(df), digits = 4L) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0L)
    return("- (no rows)")
  df <- df[, intersect(cols, names(df)), drop = FALSE]
  head <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep  <- paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|")
  fmt <- function(v) {
    if (is.numeric(v))
      vapply(v, function(x) if (is.na(x)) "NA"
             else formatC(x, digits = digits, format = "g"),
             character(1))
    else as.character(v)
  }
  body <- vapply(seq_len(nrow(df)), function(i) {
    paste0("| ", paste(vapply(names(df), function(cl)
      fmt(df[[cl]][i]), character(1)), collapse = " | "), " |")
  }, character(1))
  paste(c(head, sep, body), collapse = "\n")
}

#' Write the concise plain-language synthetic-composition report.
#'
#' Descriptive only -- this layer makes no operating-characteristic
#' claim. 70_empirical_synthetic_agreement.R does the inferential
#' comparison.
sim_write_composition_report <- function(path,
                                         gate,
                                         empirical_validation,
                                         inventory,
                                         coherence,
                                         cell_transition = NULL,
                                         support  = NULL,
                                         vchecks  = NULL,
                                         B        = NA_integer_,
                                         pool_key = NA_character_,
                                         smoothing = NA_character_,
                                         kappa    = NA_real_,
                                         support_scope = NA_character_,
                                         workers  = NA_integer_,
                                         registry_paths = list(),
                                         results_dir = NA_character_,
                                         boundary_diagnostics = NULL) {
  L <- character(0); ad <- function(...) L <<- c(L, paste0(...))
  ad("# Synthetic composition report (Q3)")
  ad("")
  ad("Question: Given empirical-derived cell distributions, how do ",
     "synthetic samples with those distributions behave?")
  ad("")
  ad("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
     if (isTRUE(gate$partial)) "  **DEV/PARTIAL**" else "")
  ad("")
  ad("## What this report is")
  ad("Projects every empirical outcome onto the 36-cell named v3 ",
     "vocabulary via its fitted RoBMA estimates (|mu_BC|, tau_BC, ",
     "log10BF_bias) to produce a deterministic **fitted-cell ",
     "assignment** -- NOT a true generative label -- then builds ",
     "per-stratum fitted-cell mixture weights (empirical-Bayes ",
     "support-masked by default) and draws empirical-weighted ",
     "synthetic stratum / corpus profiles from the fitted simulation ",
     "library. This Q3 mechanism is the bridge between empirical ",
     "corpus structure and known-cell synthetic behavior; it is not ",
     "a calibration DGM and not evidence that the empirical outcomes ",
     "came from the synthetic regimes. Cell-recovery / provenance / ",
     "transition / fitted-cell boundary tables are diagnostic, not ",
     "primary.")
  ad("")
  ad("## Inputs")
  if (length(registry_paths)) {
    if (!is.null(registry_paths$empirical))
      ad("- Empirical registry: `", registry_paths$empirical, "`")
    if (!is.null(registry_paths$synthetic))
      ad("- Synthetic registry: `", registry_paths$synthetic, "`")
  }
  ad("- Empirical: ", empirical_validation$n_rows, " outcomes, ",
     empirical_validation$n_strata, " strata, ",
     empirical_validation$n_sources, " source_article x stratum clusters.")
  ad("- Synthetic library: ", inventory$overall$n_generated_total,
     " generated CSVs (n_reps per target cell: ",
     inventory$overall$generated_reps_min, "..",
     inventory$overall$generated_reps_max, "/cell, ",
     if (isTRUE(inventory$overall$generated_reps_uniform)) "uniform"
     else "uneven",
     "); ", inventory$overall$n_fit_total, " fitted sidecar rows; ",
     "library_status = `", inventory$overall$library_status, "`.")
  ad("- Run settings: B = ", B,
     ", smoothing = `", smoothing,
     "`, kappa = ",
     if (identical(smoothing, "eb_corpus") &&
         is.finite(suppressWarnings(as.numeric(kappa))))
       sprintf("%g", as.numeric(kappa)) else "n/a",
     ", support_scope = `", support_scope,
     "`, pool_key = `", pool_key,
     "`, workers = ", workers, ".")
  ad("- B / n_reps distinction: `B` is the empirical-weighted sampling ",
     "replicate count (Monte-Carlo precision of the resampling ",
     "summary); `n_reps` is the per-target-cell depth of the fitted ",
     "synthetic library (reported above). Increasing B reduces ",
     "Monte-Carlo noise but does not smooth away finite-support ",
     "roughness; that is a function of `n_reps`.")
  ad("")
  ad("## Input gate")
  gate_line <- if (isTRUE(gate$ok))
      "- Gate: **PASS** -- library is composition-ready."
    else if (isTRUE(gate$partial))
      paste0("- Gate: **DEV/PARTIAL** (allow_partial = TRUE) -- the ",
             "library is incomplete; every output row carries ",
             "`dev_partial = TRUE` and the headline numbers below ",
             "should not be read as operating characteristics.")
    else
      "- Gate: **FAIL** -- composition refused to run."
  ad(gate_line)
  if (length(gate$problems)) {
    ad("- Gate problems:")
    for (p in gate$problems) ad("  - ", p)
  }
  ad("")
  ad("## Per-stratum empirical-cell coherence")
  ad("Per empirical stratum: how concentrated is its observed / fitted ",
     "cell mixture? (Inverse-Simpson `effective_n_cells`, ",
     "`max_cell_share`, `normalized_entropy`, dominant cell.)")
  ad("")
  ad(.sc_md_table(coherence,
                  cols = c("stratum", "n_assigned", "n_occupied_cells",
                           "n_unassigned", "effective_n_cells",
                           "max_cell_share", "dominant_cell",
                           "normalized_entropy"),
                  digits = 3L))
  ad("")
  if (!is.null(cell_transition)) {
    tot  <- sum(cell_transition$n_rows)
    diag <- sum(cell_transition$n_rows[
      cell_transition$target_cell_slug ==
        cell_transition$observed_cell_slug])
    ad("## Synthetic target -> observed cell recovery")
    ad("- Exact-cell recovery (DGM/target cell == fitted/observed cell): ",
       sprintf("%d / %d = %.1f%%", diag, tot,
               100 * diag / max(tot, 1)))
    ad("- Full transition matrix: `detail/synthetic_cell_transition.csv` ",
       "(36x36 with explicit zeros). Axis collapses: ",
       "`detail/synthetic_axis_transition.csv`.")
    ad("")
  }
  if (!is.null(support)) {
    ad("## Synthetic pool support")
    for (bk in names(support)) {
      sp <- support[[bk]]
      ad("- ", bk, " basis: ", sum(sp$empty_flag), "/", nrow(sp),
         " grid cells empty, ", sum(sp$sparse_flag),
         " sparse (n <= 5).")
    }
    ad("- Full support table: `detail/synthetic_support_diagnostics.csv`.")
    ad("")
  }
  if (!is.null(boundary_diagnostics) && nrow(boundary_diagnostics)) {
    bd <- boundary_diagnostics
    n_total <- attr(bd, "n_total")
    if (is.null(n_total)) n_total <- nrow(bd)
    counts <- attr(bd, "axis_counts")
    if (is.null(counts)) counts <- c(
      near_effect = sum(bd$near_effect_boundary, na.rm = TRUE),
      near_het    = sum(bd$near_het_boundary,    na.rm = TRUE),
      near_bias   = sum(bd$near_bias_boundary,   na.rm = TRUE),
      near_any    = sum(bd$near_any_boundary,    na.rm = TRUE))
    pct <- function(n) if (n_total > 0L)
      sprintf("%d/%d (%.1f%%)", n, n_total, 100 * n / n_total)
      else sprintf("%d/0", n)
    ad("## Empirical fitted-cell boundary sensitivity")
    ad("Distance from each empirical outcome's fitted axis value to ",
       "the nearest band boundary (`detail/",
       "empirical_fitted_cell_boundary_diagnostics.csv`). Defaults ",
       "(`effect_boundary_eps = 0.01`, `het_boundary_eps = 0.02`, ",
       "`bias_boundary_eps = 0.10`) flag genuinely borderline rows ",
       "only; they do not affect the projection or any downstream ",
       "weight/sampling step.")
    ad("- Outcomes near any axis boundary: ", pct(counts[["near_any"]]))
    ad("- Near effect-axis boundary: ", pct(counts[["near_effect"]]))
    ad("- Near heterogeneity-axis boundary: ",
       pct(counts[["near_het"]]))
    ad("- Near bias-axis boundary: ", pct(counts[["near_bias"]]))
    ad("")
  }
  if (!is.null(vchecks)) {
    nfail <- sum(vchecks$status == "FAIL")
    npass <- sum(vchecks$status == "PASS")
    nio   <- sum(vchecks$status %in% c("INFO", "WARN"))
    ad("## Validation checks")
    ad("- ", nrow(vchecks), " checks total: ", npass, " PASS, ",
       nfail, " FAIL, ", nio, " INFO/WARN.")
    if (nfail) {
      ad("- FAILED:")
      ff <- vchecks[vchecks$status == "FAIL", , drop = FALSE]
      for (i in seq_len(nrow(ff)))
        ad("  - ", ff$check[i], " (", ff$scope[i], "): ", ff$detail[i])
    }
    ad("")
  }
  ad("## Files written")
  if (!is.na(results_dir))
    ad("All in `", results_dir, "/`:")
  ad("- `empirical_cell_assignments.csv`   ",
     "(per-empirical-outcome assigned observed cell)")
  ad("- `empirical_stratum_cell_weights.csv`  ",
     "(long: stratum x cell, raw + smoothed weights, coherence ",
     "scalars repeated)")
  ad("- `empirical_stratum_coherence.csv`     ",
     "(wide: one row per stratum with the coherence scalars)")
  ad("- `empirical_weighted_synthetic_stratum_draws.csv`     ",
     "(raw B*S empirical-weighted synthetic draws; carries ",
     "composition_id, seed, pool_key, n_outcomes_target)")
  ad("- `empirical_weighted_synthetic_corpus_draws.csv`      ",
     "(raw B corpus draws)")
  ad("- `empirical_weighted_synthetic_stratum_draw_summary.csv` ",
     "(collapsed to median / q05 / q95 per (stratum, metric))")
  ad("- `empirical_weighted_synthetic_corpus_draw_summary.csv` ",
     "(same shape, corpus level)")
  ad("- `composition_validation_checks.csv`   ",
     "(structural sum-to-1 / non-mixing audit)")
  ad("- `detail/synthetic_cell_transition.csv`   (36x36 P(O|T), P(T|O))")
  ad("- `detail/synthetic_axis_transition.csv`   ",
     "(effect / heterogeneity / bias collapses)")
  ad("- `detail/stratum_target_provenance.csv`   ",
     "(per stratum P(T = t) implied by its observed cell mix)")
  ad("- `detail/stratum_observed_recovery.csv`   ",
     "(per stratum P(O = o') recovered under matched sampling)")
  ad("- `detail/synthetic_support_diagnostics.csv` ",
     "(per-cell pool support for target + observed bases)")
  ad("- `detail/empirical_fitted_cell_boundary_diagnostics.csv` ",
     "(per-outcome distance to fitted-cell axis boundaries + ",
     "near-boundary flags)")
  ad("")
  ad("## Figure ledger")
  ad("")
  ad("Figures are built by 75_analysis_visuals.R from the CSVs above. ",
     "The default Q3 family is 3 primary/bridge + 3 profile-",
     "definition diagnostics; the corpus + stratum agreement PDFs, ",
     "the 36x36 cell-transition heatmap, the stratum target-",
     "provenance heatmap, the support bars, and the validation-",
     "status bar were retired in the 2026-05 Q3 cull.")
  ad("")
  ad("| figure | class | input_csv | what_it_answers |")
  ad("|---|---|---|---|")
  ad("| `empirical_stratum_cell_weights_heatmap.pdf` | Q3 input map | ",
     "`empirical_stratum_cell_weights.csv` | which observed cells ",
     "each empirical stratum populates (the corpus-blended empirical-",
     "weighted sampling weights that 65 samples synthetic rows ",
     "under) |")
  ad("| `synthetic_axis_transition_*_heatmap.pdf` | profile-",
     "definition diagnostic | `detail/synthetic_axis_transition.csv` ",
     "| axis-level recovery on synthetic side; justifies the fitted-",
     "cell assignment basis |")
  ad("")
  ad("## Scope")
  ad("- This layer is descriptive only. The composed stratum / corpus ",
     "summaries reuse `emp_stratum_summary()` / `emp_corpus_summary()` ",
     "from 60_empirical_resampling.R so synthetic and empirical ",
     "profiles are like-for-like.")
  ad("- The composition gate reads `sim_inventory_library()` to derive ",
     "the per-cell target from the on-disk generated library; there is ",
     "no replicate-count constant or filename suffix.")
  writeLines(L, path)
  invisible(path)
}

# --- orchestrator (gated; writes only when explicitly called) ------------

#' Run synthetic composition end to end.
#'
#' Refuses unless sim_validate_composition_inputs() passes
#' (allow_partial = FALSE by default). With `allow_partial = TRUE`,
#' every output row carries `dev_partial = TRUE`, the report is
#' stamped DEV/PARTIAL, and filenames stay stable -- a DEV run can
#' never be mistaken for an operating characteristic, but it lives in
#' the same filenames so downstream tooling does not branch on tier.
#'
#' Primary writes (under `results_dir`):
#'   * empirical_weighted_synthetic_report.md
#'   * empirical_cell_assignments.csv
#'   * empirical_stratum_cell_weights.csv
#'   * empirical_stratum_coherence.csv
#'   * empirical_weighted_synthetic_stratum_draws.csv
#'   * empirical_weighted_synthetic_corpus_draws.csv
#'   * empirical_weighted_synthetic_stratum_draw_summary.csv
#'   * empirical_weighted_synthetic_corpus_draw_summary.csv
#'   * composition_validation_checks.csv
#'
#' Detail writes (under `results_dir/detail/`):
#'   * synthetic_cell_transition.csv
#'   * synthetic_axis_transition.csv
#'   * stratum_target_provenance.csv
#'   * stratum_observed_recovery.csv
#'   * synthetic_support_diagnostics.csv
#'
#' Renamed from `sim_run_synthetic_composition()` in the 2026-05 Q3
#' terminology pass. A deprecation alias under the old name is kept
#' for one release cycle.
#'
#' @param empirical_root    Empirical output root (default "output").
#' @param sim_output_root   Simulation output root (default
#'   "output_sim_v30").
#' @param data_root / latent_root / vintage Forwarded to
#'   sim_inventory_library() for the gate.
#' @param results_dir       Output directory (default
#'   "simulation/results/empirical_weighted_synthetic").
#' @param B                 Q3 sampling replicate count. B = 500 is
#'   the dev / visual-tuning default; B = 5000 for high-precision
#'   internal checking; B = 15000 for final/publication runs when
#'   feasible. Lives in row columns + report, never in filenames.
#' @param pool_key          Primary "target" (default) or sensitivity
#'   "observed".
#' @param smoothing         One of "eb_corpus" (default; the
#'   recommended empirical-Bayes support-masked weighting),
#'   "corpus_blend", "additive", "none". See
#'   `sim_build_empirical_cell_weights()`.
#' @param kappa             Empirical-Bayes prior pseudo-count (default
#'   4; "eb_corpus" only).
#' @param support           Support scope for the empirical-Bayes
#'   prior, default "occupied".
#' @param allow_partial     If TRUE, run on an incomplete library and
#'   stamp every output partial via `dev_partial`.
#' @param workers           Optional integer (default 1L; env override
#'   `SYNTHETIC_COMPOSITION_WORKERS`).
#' @param write             If TRUE (default), writes the CSVs + report.
#' @param verbose           Per-mode + per-replicate progress messages.
#' @return invisible list of in-memory tables + written file paths.
sim_run_empirical_weighted_synthetic <- function(
    empirical_root   = "output",
    sim_output_root  = "output_sim_v30",
    data_root        = "data",
    latent_root      = "simulation/latent",
    vintage          = "2026",
    results_dir      = file.path("simulation", "results",
                                 "empirical_weighted_synthetic"),
    # B tiers: 500 dev / 5000 internal high-precision / 15000
    # final-publication. Pass B explicitly for final runs.
    B                = 500L,
    pool_key         = c("target", "observed"),
    smoothing        = c("eb_corpus", "corpus_blend",
                         "additive", "none"),
    kappa            = 4,
    support          = c("occupied"),
    allow_partial    = FALSE,
    workers          = NULL,
    write            = TRUE,
    verbose          = TRUE) {
  pool_key  <- match.arg(pool_key)
  smoothing <- match.arg(smoothing)
  support   <- match.arg(support)
  B         <- as.integer(B)
  if (B < 1L)
    stop("sim_run_empirical_weighted_synthetic: B must be >= 1.")

  design <- sim_load_design()
  emp <- sim_load_empirical_registry(root = empirical_root)
  syn <- sim_load_synthetic_registry(root = sim_output_root,
                                     design = design)
  inv <- sim_inventory_library(data_root   = data_root,
                               latent_root = latent_root,
                               output_root = sim_output_root,
                               vintage     = vintage,
                               design      = design)
  gate <- sim_validate_composition_inputs(
    syn, design = design, inventory = inv,
    data_root = data_root, latent_root = latent_root,
    sim_output_root = sim_output_root, vintage = vintage,
    allow_partial = allow_partial)
  emp_val <- attr(emp, "validation")
  reg_paths <- list(empirical = attr(emp, "registry_path"),
                    synthetic = attr(syn, "registry_path"))

  w   <- sim_build_empirical_cell_weights(
    emp, smoothing = smoothing, kappa = kappa, support = support)
  coh <- sim_stratum_coherence(w)

  # Per-empirical-outcome cell assignment (audit-friendly primary view).
  emp_cell <- sim_assign_observed_cell(emp)
  keep_emp <- c("stratum", "source_article", "outcome_slug",
                "dataset_id", "analysis_id", "analysis_variant",
                "corpus_id", "scheme",
                "mu_BC", "tau_BC", "log10BF_bias",
                "observed_effect_slug", "observed_heterogeneity_slug",
                "observed_bias_slug", "observed_cell_slug",
                "observed_stratum")
  emp_assign <- emp_cell[, intersect(keep_emp, names(emp_cell)),
                          drop = FALSE]

  # Fitted-cell boundary-near diagnostic (sensitivity check on the
  # deterministic projection; no effect on weights/sampling).
  emp_bd <- sim_build_empirical_fitted_cell_boundary(emp)

  w_n <- .sc_resolve_workers(workers, B)

  st <- sim_compose_strata(emp, syn, w, B = B, pool_key = pool_key,
                           workers = workers, verbose = verbose)
  co <- sim_compose_corpus(emp, syn, w, B = B, pool_key = pool_key,
                           workers = workers, verbose = verbose)
  st_s <- sim_summarize_composition_draws(st, "stratum")
  co_s <- sim_summarize_composition_draws(co, "stratum")

  ct  <- sim_build_cell_transition(syn)
  axt <- list(
    effect        = sim_build_axis_transition(syn, "effect"),
    heterogeneity = sim_build_axis_transition(syn, "heterogeneity"),
    bias          = sim_build_axis_transition(syn, "bias"))
  pp  <- sim_build_stratum_provenance_projection(w, ct)
  sup <- list(
    target   = sim_build_synthetic_support_diagnostics(syn, "target"),
    observed = sim_build_synthetic_support_diagnostics(syn, "observed"))
  vchecks <- sim_composition_validation_checks(
    weights = w, synthetic_registry = syn, empirical_registry = emp,
    cell_transition = ct, axis_transitions = axt,
    provenance_projection = pp, support = sup, gate = gate)

  axt_long <- do.call(rbind, lapply(names(axt), function(a) {
    d <- axt[[a]]
    names(d)[names(d) == paste0("target_", a)]   <- "target_slug"
    names(d)[names(d) == paste0("observed_", a)] <- "observed_slug"
    d$axis <- a
    d[, c("axis", "target_slug", "observed_slug", "n_rows",
          "p_observed_given_target", "p_target_given_observed")]
  }))
  prov <- pp$provenance; recov <- pp$recovery
  sup_long <- do.call(rbind, sup)

  # Stamp every row with dev_partial so partial state is auditable in
  # the data, not in the filename. Also stamp the smoothing / kappa /
  # support_scope / pool_key / B run-metadata onto every long-form
  # output that participates in downstream agreement / visual layers,
  # so 70 + 75 can detect stale or mismatched runs.
  meta_stamp <- function(d) {
    d$smoothing      <- smoothing
    d$kappa          <- if (smoothing == "eb_corpus") kappa else NA_real_
    d$support_scope  <- support
    d$pool_key       <- pool_key
    d$B              <- as.integer(B)
    d
  }
  for (nm in c("w", "coh", "emp_assign", "st", "co", "st_s", "co_s",
               "ct", "axt_long", "prov", "recov", "sup_long",
               "vchecks", "emp_bd")) {
    d <- get(nm)
    if (!is.null(d) && nrow(d)) {
      d$dev_partial <- isTRUE(gate$partial)
      if (nm %in% c("st", "co", "st_s", "co_s"))
        d <- meta_stamp(d)
      assign(nm, d)
    }
  }

  files <- character(0)
  if (isTRUE(write)) {
    if (!dir.exists(results_dir)) dir.create(results_dir, recursive = TRUE)
    detail_dir <- file.path(results_dir, "detail")
    if (!dir.exists(detail_dir)) dir.create(detail_dir, recursive = TRUE)
    wr <- function(d, p) { utils::write.csv(d, p, row.names = FALSE); p }

    files <- c(files,
      wr(emp_assign,
         file.path(results_dir, "empirical_cell_assignments.csv")),
      wr(w,
         file.path(results_dir, "empirical_stratum_cell_weights.csv")),
      wr(coh,
         file.path(results_dir, "empirical_stratum_coherence.csv")),
      wr(st,
         file.path(results_dir,
                   "empirical_weighted_synthetic_stratum_draws.csv")),
      wr(co,
         file.path(results_dir,
                   "empirical_weighted_synthetic_corpus_draws.csv")),
      wr(st_s,
         file.path(results_dir,
                   "empirical_weighted_synthetic_stratum_draw_summary.csv")),
      wr(co_s,
         file.path(results_dir,
                   "empirical_weighted_synthetic_corpus_draw_summary.csv")),
      wr(vchecks,
         file.path(results_dir, "composition_validation_checks.csv")),
      wr(ct,
         file.path(detail_dir, "synthetic_cell_transition.csv")),
      wr(axt_long,
         file.path(detail_dir, "synthetic_axis_transition.csv")),
      wr(sup_long,
         file.path(detail_dir, "synthetic_support_diagnostics.csv")),
      wr(emp_bd,
         file.path(detail_dir,
                   "empirical_fitted_cell_boundary_diagnostics.csv")))
    if (!is.null(prov) && nrow(prov))
      files <- c(files,
        wr(prov,
           file.path(detail_dir, "stratum_target_provenance.csv")))
    if (!is.null(recov) && nrow(recov))
      files <- c(files,
        wr(recov,
           file.path(detail_dir, "stratum_observed_recovery.csv")))

    rp <- file.path(results_dir, "empirical_weighted_synthetic_report.md")
    sim_write_composition_report(
      rp, gate = gate, empirical_validation = emp_val,
      inventory = inv, coherence = coh,
      cell_transition = ct, support = sup, vchecks = vchecks,
      B = B, pool_key = pool_key, smoothing = smoothing,
      kappa = kappa, support_scope = support,
      workers = w_n, registry_paths = reg_paths,
      results_dir = results_dir,
      boundary_diagnostics = emp_bd)
    files <- c(files, rp)
  }

  if (verbose)
    message(sprintf(
      "[sc] done: gate=%s, B=%d, smoothing=%s, kappa=%s, support=%s, pool_key=%s%s",
      if (isTRUE(gate$ok)) "PASS"
      else if (isTRUE(gate$partial)) "DEV/PARTIAL" else "FAIL",
      B, smoothing,
      if (smoothing == "eb_corpus") sprintf("%g", kappa) else "n/a",
      support, pool_key,
      if (length(files)) sprintf("; %d files -> %s",
                                  length(files), results_dir) else ""))

  invisible(list(
    gate                  = gate,
    inventory             = inv,
    empirical_validation  = emp_val,
    weights               = w,
    coherence             = coh,
    empirical_assignments = emp_assign,
    stratum_draws         = st,
    corpus_draws          = co,
    stratum_summary       = st_s,
    corpus_summary        = co_s,
    cell_transition       = ct,
    axis_transition       = axt_long,
    provenance            = prov,
    recovery              = recov,
    support               = sup_long,
    validation_checks     = vchecks,
    files                 = files,
    results_dir           = results_dir))
}

#' Deprecated alias for sim_run_empirical_weighted_synthetic().
#'
#' Renamed in the 2026-05 Q3 terminology pass. Emits a single soft
#' warning and forwards all arguments. New code should call
#' sim_run_empirical_weighted_synthetic() directly.
sim_run_synthetic_composition <- function(...) {
  warning("sim_run_synthetic_composition() is deprecated; use ",
          "sim_run_empirical_weighted_synthetic() (same arguments; ",
          "default results_dir was renamed to ",
          "simulation/results/empirical_weighted_synthetic). ",
          "Renamed in 2026-05 Q3 terminology pass.", call. = FALSE)
  sim_run_empirical_weighted_synthetic(...)
}

# --- Q1: per-cell synthetic n_outcomes stability curve -------------------

# One (target_cell_slug, n_outcomes, b) draw. Returns a one-row data.frame
# (stratum summary from a target-cell pool) with cell_slug, n_outcomes,
# size_curve_id, pool_key, n_pool, seed columns added.
.sc_cell_curve_one <- function(b, n_outcomes, cell_slug, pool_index,
                                synthetic_registry, pool_key, seeds) {
  sd <- seeds[b]
  set.seed(sd)
  pool <- pool_index[[cell_slug]]
  if (is.null(pool) || length(pool) == 0L) return(NULL)
  ix <- if (length(pool) == 1L)
          rep(pool, as.integer(n_outcomes))
        else sample(pool, size = as.integer(n_outcomes), replace = TRUE)
  slice <- synthetic_registry[ix, , drop = FALSE]
  slice$stratum <- paste0("simcell_", cell_slug)
  summ <- emp_stratum_summary(slice)
  summ$cell_slug         <- cell_slug
  summ$n_outcomes_target <- as.integer(n_outcomes)
  summ$size_curve_id     <- b
  summ$pool_key          <- pool_key
  summ$n_pool            <- length(pool)
  summ$seed              <- sd
  summ
}

# Build (cell_slug, n_outcomes_target) plan list for the Q1 size curve.
# Each plan carries everything its per-(b) worker needs.
.sc_build_cell_curve_plans <- function(cells, n_grid) {
  plans <- vector("list", length(cells) * length(n_grid))
  idx <- 0L
  for (ci in seq_along(cells)) {
    for (ni in seq_along(n_grid)) {
      idx <- idx + 1L
      plans[[idx]] <- list(
        plan_id     = idx,
        cell_index  = ci,
        n_index     = ni,
        cell_slug   = cells[ci],
        n_outcomes  = as.integer(n_grid[ni]))
    }
  }
  plans
}

# Run all B replicates for one (cell, n) plan sequentially. Seeds are
# derived from (plan_id, b, base_seed) so the result is identical
# regardless of which worker (or whether any worker) executes it.
.sc_run_cell_curve_plan <- function(plan_index, plans,
                                    pool_index, synthetic_registry,
                                    pool_key, B, base_seed,
                                    n_grid_len) {
  p <- plans[[plan_index]]
  # Preserve the legacy seed-offset formula so byte-equality with the
  # pre-refactor sequential path is maintained.
  offset <- ((p$cell_index - 1L) * n_grid_len + (p$n_index - 1L)) * 1000L
  seeds <- .sc_seeds(B, as.integer(base_seed + offset))
  rows <- lapply(seq_len(B), function(b)
    .sc_cell_curve_one(b, p$n_outcomes, p$cell_slug,
                       pool_index, synthetic_registry,
                       pool_key, seeds))
  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (length(rows)) do.call(rbind, rows) else NULL
}

#' Q1 synthetic per-cell n_outcomes stability curve.
#'
#' For each full36 target cell, sample n_outcomes synthetic library rows
#' (with replacement) from that cell's pool and recompute the rigor /
#' component summaries via emp_stratum_summary(). Repeat for every n in
#' n_grid, B replicates per (cell, n). Answers Q1: how does selected
#' rigor behave under each known full36 synthetic target cell, and how
#' stable are summaries as n_outcomes grows?
#'
#' Stable output filenames (no B / n_grid / pool_key in filenames; that
#' state lives in row columns):
#'   simulation/results/cell_behavior/synthetic_cell_size_curve_draws.csv
#'   simulation/results/cell_behavior/synthetic_cell_size_curve_summary.csv
#'   simulation/results/cell_behavior/synthetic_cell_size_curve_report.md
#'
#' @return invisible list(draws, summary, files).
sim_run_cell_size_curve <- function(
    # B tiers: 500 dev / 5000 internal high-precision / 15000
    # final-publication. Pass B explicitly for final runs.
    B                = 500L,
    n_grid           = .SC_SIZE_GRID_DEFAULT,
    pool_key         = c("target", "observed"),
    sim_output_root  = "output_sim_v30",
    data_root        = "data",
    latent_root      = "simulation/latent",
    vintage          = "2026",
    results_dir      = file.path("simulation", "results", "cell_behavior"),
    base_seed        = 20261001L,
    allow_partial    = FALSE,
    workers          = NULL,
    write            = TRUE,
    verbose          = TRUE) {
  pool_key <- match.arg(pool_key)
  B <- as.integer(B)
  n_grid <- sort(unique(as.integer(n_grid)))
  if (length(n_grid) == 0L || any(n_grid <= 0L))
    stop("sim_run_cell_size_curve: n_grid must be positive integers.")
  if (B < 1L) stop("sim_run_cell_size_curve: B must be >= 1.")

  design <- sim_load_design()
  syn <- sim_load_synthetic_registry(root = sim_output_root,
                                     design = design)
  inv <- sim_inventory_library(data_root   = data_root,
                               latent_root = latent_root,
                               output_root = sim_output_root,
                               vintage     = vintage,
                               design      = design)
  gate <- sim_validate_composition_inputs(
    syn, design = design, inventory = inv,
    data_root = data_root, latent_root = latent_root,
    sim_output_root = sim_output_root, vintage = vintage,
    allow_partial = allow_partial)

  pidx <- .sc_pool_index(syn, pool_key)
  if (pool_key == "target") {
    cells <- intersect(.SC_ALL_CELL_SLUGS, names(pidx))
  } else {
    cells <- intersect(.SC_ALL_CELL_SLUGS, names(pidx))
  }
  if (length(cells) == 0L)
    stop("sim_run_cell_size_curve: no cells with synthetic pool ",
         "(pool_key='", pool_key, "').")

  # Provenance check: warn (do not hard-fail) when the simulation
  # overview registry consumed by 65 is stale relative to the per-cell
  # n_fit that 55 reports in simulation/results/cell_diagnostics_rigor
  # .csv. See .sc_check_registry_freshness() definition for the
  # registry-rebuild recipe. The same string is stashed for the
  # per-run report so the warning is auditable after the fact.
  registry_warning <- .sc_check_registry_freshness(
    pool_index  = pidx,
    results_dir = dirname(results_dir),
    verbose     = isTRUE(verbose))

  # Build plan list (one plan per (cell, n_outcomes)) and resolve
  # workers against the number of plans, since the parallel unit is
  # now a plan rather than a single bootstrap replicate.
  plans <- .sc_build_cell_curve_plans(cells, n_grid)
  w <- .sc_resolve_workers(workers, length(plans))

  if (!is.null(workers) && as.integer(workers) > 1L &&
      (as.integer(B) < 200L || length(plans) < 50L) &&
      isTRUE(verbose))
    message("[sc] workers > 1 requested. Synthetic resampling jobs ",
            "are small; parallelism helps only for large B or large ",
            "grids.")

  if (isTRUE(verbose))
    message(sprintf(paste0(
      "[sc][cell_curve] cells=%d (of 36), n_grid=%d (%d..%d), B=%d, ",
      "workers=%d, pool_key=%s, plans=%d (parallel unit = plan)"),
      length(cells), length(n_grid), min(n_grid), max(n_grid), B, w,
      pool_key, length(plans)))

  if (w <= 1L) {
    draws_parts <- lapply(seq_along(plans), .sc_run_cell_curve_plan,
                          plans = plans, pool_index = pidx,
                          synthetic_registry = syn, pool_key = pool_key,
                          B = B, base_seed = base_seed,
                          n_grid_len = length(n_grid))
  } else if (!requireNamespace("parallel", quietly = TRUE)) {
    message("[sc] 'parallel' namespace unavailable; falling back to ",
            "workers = 1.")
    draws_parts <- lapply(seq_along(plans), .sc_run_cell_curve_plan,
                          plans = plans, pool_index = pidx,
                          synthetic_registry = syn, pool_key = pool_key,
                          B = B, base_seed = base_seed,
                          n_grid_len = length(n_grid))
  } else {
    if (isTRUE(verbose))
      message(sprintf(
        "[sc][cell_curve] launching PSOCK cluster (workers=%d) once for %d plans",
        w, length(plans)))
    exp <- .sc_cluster_export_syms()
    cl <- parallel::makePSOCKcluster(w)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    if (length(exp$syms))
      parallel::clusterExport(cl, varlist = exp$syms, envir = exp$env)
    # parLapplyLB returns results in input order, so deterministic
    # row order matches the sequential path.
    draws_parts <- parallel::parLapplyLB(
      cl, seq_along(plans), .sc_run_cell_curve_plan,
      plans = plans, pool_index = pidx,
      synthetic_registry = syn, pool_key = pool_key,
      B = B, base_seed = base_seed,
      n_grid_len = length(n_grid))
  }
  draws <- do.call(rbind, draws_parts)
  draws$dev_partial <- isTRUE(gate$partial)

  # Summarize draws by cell x n_outcomes x metric.
  metric_cols <- intersect(
    c(.SC_PRIMARY_METRICS, .SC_COMPONENT_METRICS), names(draws))
  summ_rows <- list()
  for (cs in cells) {
    for (n_o in n_grid) {
      sub <- draws[draws$cell_slug == cs &
                   draws$n_outcomes_target == n_o, , drop = FALSE]
      for (m in metric_cols) {
        v <- suppressWarnings(as.numeric(sub[[m]]))
        vv <- v[!is.na(v)]
        summ_rows[[length(summ_rows) + 1L]] <- data.frame(
          cell_slug         = cs,
          n_outcomes_target = as.integer(n_o),
          pool_key          = pool_key,
          metric            = m,
          synthetic_mean    = if (length(vv)) mean(vv) else NA_real_,
          synthetic_sd      = if (length(vv) > 1L) stats::sd(vv)
                                else NA_real_,
          synthetic_median  = if (length(vv)) stats::median(vv)
                                else NA_real_,
          q05  = .emp_qtl(vv, 0.05),  q95  = .emp_qtl(vv, 0.95),
          q025 = .emp_qtl(vv, 0.025), q975 = .emp_qtl(vv, 0.975),
          interval_width = if (length(vv))
            .emp_qtl(vv, 0.95) - .emp_qtl(vv, 0.05) else NA_real_,
          n_draws       = length(vv),
          B             = as.integer(B),
          n_pool        = length(pidx[[cs]]),
          dev_partial   = isTRUE(gate$partial),
          stringsAsFactors = FALSE)
      }
    }
  }
  summary_df <- do.call(rbind, summ_rows)

  files <- character(0)
  if (isTRUE(write)) {
    if (!dir.exists(results_dir)) dir.create(results_dir, recursive = TRUE)
    p_draws <- file.path(results_dir,
                         "synthetic_cell_size_curve_draws.csv")
    p_summ  <- file.path(results_dir,
                         "synthetic_cell_size_curve_summary.csv")
    p_rep   <- file.path(results_dir,
                         "synthetic_cell_size_curve_report.md")
    utils::write.csv(draws,      p_draws, row.names = FALSE)
    utils::write.csv(summary_df, p_summ,  row.names = FALSE)
    .sc_write_cell_curve_report(p_rep, gate = gate, B = B,
                                n_grid = n_grid, pool_key = pool_key,
                                cells_seen = length(cells),
                                results_dir = results_dir,
                                registry_warning = registry_warning)
    files <- c(p_draws, p_summ, p_rep)
  }

  if (isTRUE(verbose))
    message(sprintf("[sc][cell_curve] done: %d draw rows, %d summary rows%s",
                    nrow(draws), nrow(summary_df),
                    if (length(files))
                      paste0(" -> ", results_dir) else ""))

  invisible(list(
    gate = gate, B = B, n_grid = n_grid, pool_key = pool_key,
    cells = cells, draws = draws, summary = summary_df, files = files))
}

.sc_write_cell_curve_report <- function(path, gate, B, n_grid, pool_key,
                                        cells_seen, results_dir,
                                        registry_warning = "") {
  L <- character(0); ad <- function(...) L <<- c(L, paste0(...))
  ad("# Cell behavior report (Q1)")
  ad("")
  ad("Question: How does selected rigor behave under each known full36 ",
     "target cell, and how stable are summaries as n_outcomes grows?")
  ad("")
  ad("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
     if (isTRUE(gate$partial)) "  **DEV/PARTIAL**" else "")
  ad("")
  if (nzchar(registry_warning)) {
    ad("## Registry-freshness warning")
    ad("")
    ad("**STALE OVERVIEW REGISTRY DETECTED.** Resampling pool sizes ",
       "below are smaller than the fitted library 55 reports. Rebuild ",
       "the overview registry, then re-run.")
    ad("")
    ad("```")
    for (ln in unlist(strsplit(registry_warning, "\n", fixed = TRUE)))
      ad(ln)
    ad("```")
    ad("")
  }
  ad("## Inputs")
  ad("- Synthetic library: gated by sim_inventory_library() (",
     if (isTRUE(gate$ok)) "composition-ready"
     else if (isTRUE(gate$partial)) "DEV/PARTIAL"
     else "FAIL", ")")
  ad("- pool_key = `", pool_key,
     "` (target-cell pool is default; observed-cell pool is sensitivity)")
  ad("- B = ", B, " replicates per (cell, n_outcomes); n_grid = c(",
     paste(n_grid, collapse = ", "), "); cells seen = ", cells_seen, "/36")
  ad("")
  ad("## Files written")
  ad("All in `", results_dir, "/`:")
  ad("- `synthetic_cell_size_curve_draws.csv`   ",
     "(B per (cell, n_outcomes); carries cell_slug, n_outcomes_target, ",
     "size_curve_id, pool_key, n_pool, seed, dev_partial)")
  ad("- `synthetic_cell_size_curve_summary.csv` ",
     "(per (cell_slug, n_outcomes_target, metric) summary; q05/q95, ",
     "q025/q975, interval_width, n_pool, B)")
  ad("")
  ad("## Figure ledger")
  ad("")
  ad("Figures are built by 75_analysis_visuals.R from the summary ",
     "CSV above. The default Q1 family is 4 primary + 3 secondary; ",
     "central-trend and convergence-error figures were retired in ",
     "2026-05.")
  ad("")
  ad("| figure | class | input_csv | what_it_answers | what_it_does_not_answer |")
  ad("|---|---|---|---|---|")
  ad("| `cell_rigor_atlas.pdf` | primary | ",
     "`cell_diagnostics_rigor.csv` | known-cell median selected rigor ",
     "at the library's per-cell n_fit | the n_outcomes sweep (see ",
     "the variability figure) |")
  ad("| `cell_attenuation_atlas.pdf` | primary | ",
     "`cell_behavior_effect_draws.csv` | per-cell baseline vs RoBMA-",
     "PSMA effect recovery against the true mu | sampling variability ",
     "vs n_outcomes (see variability / viability) |")
  ad("| `synthetic_cell_rigor_variability_by_effect.pdf` | primary | ",
     "`synthetic_cell_size_curve_summary.csv` | how the 90% interval ",
     "width of stratum-level median rigor shrinks as n_outcomes grows ",
     "| absolute rigor level (see rigor atlas) |")
  ad("| `synthetic_cell_rigor_viability_min_n.pdf` | primary | ",
     "`synthetic_cell_rigor_viability_min_n.csv` (derived) | minimum ",
     "viable n per cell at width90 thresholds 1.0 / 0.5 / 0.25 | a ",
     "universal viability law -- this is threshold-dependent |")
  ad("| `synthetic_cell_rigor_width_heatmap_by_n.pdf` | secondary | ",
     "`synthetic_cell_size_curve_summary.csv` | width90 snapshots per ",
     "cell at selected n_outcomes (default 5,10,20,30,50) | the full ",
     "curve over n (see variability) |")
  ad("| `synthetic_cell_rate_variability_by_effect.pdf` | secondary | ",
     "`synthetic_cell_size_curve_summary.csv` | rate-metric width90 ",
     "across B draws | expected rate (deliberately retired) |")
  ad("| `full36_cell_operating_characteristics_primary_rigor.pdf` | ",
     "secondary | `cell_diagnostics_rigor.csv` | per-cell primary-",
     "rigor rates at the library's n_fit | the n_outcomes sweep |")
  ad("")
  ad("## Scope")
  ad("- Synthetic-only: this layer never reads the empirical registry. ",
     "It samples each target cell's own pool to expose how that cell's ",
     "selected-rigor estimands behave on its own design regime.")
  ad("- Stable filenames; B / n_grid / pool_key live in row columns.")
  writeLines(L, path)
  invisible(path)
}

# --- Q3: empirical-weighted synthetic n_outcomes stability curve --------

#' Q3 empirical-weighted synthetic n_outcomes stability curve.
#'
#' For each empirical stratum and each n in n_grid, compose B
#' empirical-weighted synthetic stratum draws of size n via
#' sim_compose_strata(..., n_outcomes_override = n), and summarize.
#' Answers Q3: given empirical-derived cell distributions, how do
#' synthetic samples with those distributions behave as n_outcomes
#' grows?
#'
#' Stable output filenames:
#'   simulation/results/empirical_weighted_synthetic/
#'     empirical_weighted_synthetic_size_curve_draws.csv
#'     empirical_weighted_synthetic_size_curve_summary.csv
#'     empirical_weighted_synthetic_size_curve_report.md
#'
#' Renamed from `sim_run_composition_size_curve()` in the 2026-05 Q3
#' terminology pass. A deprecation alias under the old name is kept
#' for one release cycle.
#'
#' @return invisible list(draws, summary, files).
sim_run_empirical_weighted_size_curve <- function(
    # B tiers: 500 dev / 5000 internal high-precision / 15000
    # final-publication. Pass B explicitly for final runs.
    B                = 500L,
    n_grid           = .SC_SIZE_GRID_DEFAULT,
    pool_key         = c("target", "observed"),
    smoothing        = c("eb_corpus", "corpus_blend",
                         "additive", "none"),
    kappa            = 4,
    support          = c("occupied"),
    empirical_root   = "output",
    sim_output_root  = "output_sim_v30",
    data_root        = "data",
    latent_root      = "simulation/latent",
    vintage          = "2026",
    results_dir      = file.path("simulation", "results",
                                 "empirical_weighted_synthetic"),
    base_seed        = 20261101L,
    allow_partial    = FALSE,
    workers          = NULL,
    write            = TRUE,
    verbose          = TRUE) {
  pool_key  <- match.arg(pool_key)
  smoothing <- match.arg(smoothing)
  support   <- match.arg(support)
  B <- as.integer(B)
  n_grid <- sort(unique(as.integer(n_grid)))
  if (length(n_grid) == 0L || any(n_grid <= 0L))
    stop("sim_run_empirical_weighted_size_curve: n_grid must be ",
         "positive integers.")
  if (B < 1L)
    stop("sim_run_empirical_weighted_size_curve: B must be >= 1.")

  design <- sim_load_design()
  emp <- sim_load_empirical_registry(root = empirical_root)
  syn <- sim_load_synthetic_registry(root = sim_output_root,
                                     design = design)
  inv <- sim_inventory_library(data_root   = data_root,
                               latent_root = latent_root,
                               output_root = sim_output_root,
                               vintage     = vintage,
                               design      = design)
  gate <- sim_validate_composition_inputs(
    syn, design = design, inventory = inv,
    data_root = data_root, latent_root = latent_root,
    sim_output_root = sim_output_root, vintage = vintage,
    allow_partial = allow_partial)
  weights <- sim_build_empirical_cell_weights(
    emp, smoothing = smoothing, kappa = kappa, support = support)

  # Precompute pool index, per-stratum sizes, and the stratum list once
  # so every plan reuses them. Parallel unit is now the plan, not the
  # bootstrap replicate inside a plan, so resolve workers against
  # length(plans).
  pidx_curve <- .sc_pool_index(syn, pool_key)
  emp_n_curve <- tapply(seq_len(nrow(emp)), emp$stratum, length)
  strata_curve <- intersect(unique(weights$stratum), names(emp_n_curve))
  plans <- .sc_build_composition_curve_plans(n_grid)
  w_n <- .sc_resolve_workers(workers, length(plans))

  if (!is.null(workers) && as.integer(workers) > 1L &&
      (as.integer(B) < 200L || length(plans) < 50L) &&
      isTRUE(verbose))
    message("[sc] workers > 1 requested. Synthetic resampling jobs ",
            "are small; parallelism helps only for large B or large ",
            "grids.")

  if (isTRUE(verbose))
    message(sprintf(paste0(
      "[sc][composition_curve] strata=%d, n_grid=%d (%d..%d), B=%d, ",
      "workers=%d, pool_key=%s, smoothing=%s, plans=%d ",
      "(parallel unit = plan)"),
      length(unique(emp$stratum)), length(n_grid),
      min(n_grid), max(n_grid), B, w_n, pool_key, smoothing,
      length(plans)))

  if (w_n <= 1L) {
    draws_parts <- lapply(seq_along(plans),
      .sc_run_composition_curve_plan,
      plans = plans, empirical_registry = emp,
      synthetic_registry = syn, weights = weights,
      pidx = pidx_curve, strata = strata_curve,
      emp_n = emp_n_curve, pool_key = pool_key,
      smoothing = smoothing, B = B, base_seed = base_seed)
  } else if (!requireNamespace("parallel", quietly = TRUE)) {
    message("[sc] 'parallel' namespace unavailable; falling back to ",
            "workers = 1.")
    draws_parts <- lapply(seq_along(plans),
      .sc_run_composition_curve_plan,
      plans = plans, empirical_registry = emp,
      synthetic_registry = syn, weights = weights,
      pidx = pidx_curve, strata = strata_curve,
      emp_n = emp_n_curve, pool_key = pool_key,
      smoothing = smoothing, B = B, base_seed = base_seed)
  } else {
    if (isTRUE(verbose))
      message(sprintf(
        "[sc][composition_curve] launching PSOCK cluster (workers=%d) once for %d plans",
        w_n, length(plans)))
    exp <- .sc_cluster_export_syms()
    cl <- parallel::makePSOCKcluster(w_n)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    if (length(exp$syms))
      parallel::clusterExport(cl, varlist = exp$syms, envir = exp$env)
    draws_parts <- parallel::parLapplyLB(
      cl, seq_along(plans), .sc_run_composition_curve_plan,
      plans = plans, empirical_registry = emp,
      synthetic_registry = syn, weights = weights,
      pidx = pidx_curve, strata = strata_curve,
      emp_n = emp_n_curve, pool_key = pool_key,
      smoothing = smoothing, B = B, base_seed = base_seed)
  }
  draws <- do.call(rbind, draws_parts)
  draws$dev_partial <- isTRUE(gate$partial)
  # Stamp full run-metadata on every draw so stale CSVs are detectable.
  draws$smoothing     <- smoothing
  draws$kappa         <- if (smoothing == "eb_corpus") kappa
                          else NA_real_
  draws$support_scope <- support
  draws$B             <- as.integer(B)

  metric_cols <- intersect(
    c(.SC_PRIMARY_METRICS, .SC_COMPONENT_METRICS), names(draws))
  strata <- sort(unique(draws$stratum))
  summ_rows <- list()
  for (s in strata) {
    for (n_o in n_grid) {
      sub <- draws[draws$stratum == s &
                   draws$n_outcomes_target == n_o, , drop = FALSE]
      for (m in metric_cols) {
        v <- suppressWarnings(as.numeric(sub[[m]]))
        vv <- v[!is.na(v)]
        summ_rows[[length(summ_rows) + 1L]] <- data.frame(
          stratum           = s,
          n_outcomes_target = as.integer(n_o),
          pool_key          = pool_key,
          smoothing         = smoothing,
          kappa             = if (smoothing == "eb_corpus") kappa
                                else NA_real_,
          support_scope     = support,
          metric            = m,
          synthetic_mean    = if (length(vv)) mean(vv) else NA_real_,
          synthetic_sd      = if (length(vv) > 1L) stats::sd(vv)
                                else NA_real_,
          synthetic_median  = if (length(vv)) stats::median(vv)
                                else NA_real_,
          q05  = .emp_qtl(vv, 0.05),  q95  = .emp_qtl(vv, 0.95),
          q025 = .emp_qtl(vv, 0.025), q975 = .emp_qtl(vv, 0.975),
          interval_width = if (length(vv))
            .emp_qtl(vv, 0.95) - .emp_qtl(vv, 0.05) else NA_real_,
          n_draws       = length(vv),
          B             = as.integer(B),
          dev_partial   = isTRUE(gate$partial),
          stringsAsFactors = FALSE)
      }
    }
  }
  summary_df <- do.call(rbind, summ_rows)

  files <- character(0)
  if (isTRUE(write)) {
    if (!dir.exists(results_dir)) dir.create(results_dir, recursive = TRUE)
    p_draws <- file.path(results_dir,
                         "empirical_weighted_synthetic_size_curve_draws.csv")
    p_summ  <- file.path(results_dir,
                         "empirical_weighted_synthetic_size_curve_summary.csv")
    p_rep   <- file.path(results_dir,
                         "empirical_weighted_synthetic_size_curve_report.md")
    utils::write.csv(draws,      p_draws, row.names = FALSE)
    utils::write.csv(summary_df, p_summ,  row.names = FALSE)
    .sc_write_composition_curve_report(
      p_rep, gate = gate, B = B, n_grid = n_grid, pool_key = pool_key,
      smoothing = smoothing, kappa = kappa, support_scope = support,
      n_strata = length(strata),
      results_dir = results_dir)
    files <- c(p_draws, p_summ, p_rep)
  }

  if (isTRUE(verbose))
    message(sprintf(paste0(
      "[sc][composition_curve] done: %d draw rows, %d summary rows%s"),
      nrow(draws), nrow(summary_df),
      if (length(files)) paste0(" -> ", results_dir) else ""))

  invisible(list(
    gate = gate, B = B, n_grid = n_grid, pool_key = pool_key,
    smoothing = smoothing, kappa = kappa, support_scope = support,
    draws = draws, summary = summary_df,
    files = files))
}

.sc_write_composition_curve_report <- function(path, gate, B, n_grid,
                                               pool_key, smoothing,
                                               kappa = NA_real_,
                                               support_scope = NA_character_,
                                               n_strata, results_dir) {
  L <- character(0); ad <- function(...) L <<- c(L, paste0(...))
  ad("# Empirical-weighted synthetic sampling size-curve report (Q3)")
  ad("")
  ad("Question: Given empirical-derived cell distributions, how do ",
     "synthetic samples with those distributions behave as n_outcomes ",
     "grows?")
  ad("")
  ad("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
     if (isTRUE(gate$partial)) "  **DEV/PARTIAL**" else "")
  ad("")
  ad("## Inputs")
  ad("- Empirical-weighted synthetic sampling gated by ",
     "sim_validate_composition_inputs() (",
     if (isTRUE(gate$ok)) "PASS"
     else if (isTRUE(gate$partial)) "DEV/PARTIAL"
     else "FAIL", ")")
  ad("- pool_key = `", pool_key, "`, smoothing = `", smoothing,
     "`, kappa = ", if (smoothing == "eb_corpus")
                       sprintf("%g", kappa) else "n/a",
     ", support_scope = `", support_scope,
     "`, B = ", B, ", n_grid = c(",
     paste(n_grid, collapse = ", "), "), strata = ", n_strata)
  ad("")
  ad("## Files written")
  ad("All in `", results_dir, "/`:")
  ad("- `empirical_weighted_synthetic_size_curve_draws.csv`   ",
     "(raw draws: stratum x n_outcomes_target x composition_id; ",
     "carries pool_key, smoothing, seed, dev_partial)")
  ad("- `empirical_weighted_synthetic_size_curve_summary.csv` ",
     "(per (stratum, n_outcomes_target, metric) summary; q05/q95, ",
     "q025/q975, interval_width)")
  ad("")
  ad("## Figure ledger")
  ad("")
  ad("Figures are built by 75_analysis_visuals.R from the summary ",
     "CSV above. The default Q3 family is 3 primary/bridge + 3 ",
     "profile-definition diagnostics; the mean/median-level / p_* ",
     "rigor curves and the corpus + stratum agreement PDFs were ",
     "retired in the 2026-05 Q3 cull.")
  ad("")
  ad("| figure | class | input_csv | what_it_answers |")
  ad("|---|---|---|---|")
  ad("| `empirical_weighted_synthetic_rigor_variability_by_stratum.pdf` ",
     "| Q3 primary | `empirical_weighted_synthetic_size_curve_summary",
     ".csv` | how the empirical-weighted synthetic sampling ",
     "stabilizes (width90 = q95 - q05 of stratum-level median ",
     "selected rigor) as n_outcomes grows, per stratum |")
  ad("| `empirical_bootstrap_vs_empirical_weighted_synthetic_core_metrics.pdf` ",
     "| Q3 bridge primary | ",
     "`empirical_resampling_observed_size_intervals.csv` + ",
     "this summary | whether the empirical resampling bands and the ",
     "empirical-weighted synthetic bands overlap at matched ",
     "n_outcomes, for core audit metrics (rigor, rigor margin, bias ",
     "evidence, absolute attenuation) |")
  ad("")
  ad("## Scope")
  ad("- Synthetic distribution is produced by empirical-weighted ",
     "synthetic sampling: for each draw, fitted synthetic rows are ",
     "sampled according to each empirical stratum's corpus-blended ",
     "fitted-cell weights, then summarized with ",
     "emp_stratum_summary().")
  ad("- This is a per-stratum n_outcomes sweep. To see how the same ",
     "sampling behaves at the strata's observed n_outcomes, see ",
     "empirical_weighted_synthetic_stratum_draw_summary.csv ",
     "(companion run).")
  writeLines(L, path)
  invisible(path)
}

#' Deprecated alias for sim_run_empirical_weighted_size_curve().
#'
#' Renamed in the 2026-05 Q3 terminology pass. Emits a single soft
#' warning and forwards all arguments. New code should call
#' sim_run_empirical_weighted_size_curve() directly.
sim_run_composition_size_curve <- function(...) {
  warning("sim_run_composition_size_curve() is deprecated; use ",
          "sim_run_empirical_weighted_size_curve() (same arguments; ",
          "default results_dir was renamed to ",
          "simulation/results/empirical_weighted_synthetic). ",
          "Renamed in 2026-05 Q3 terminology pass.", call. = FALSE)
  sim_run_empirical_weighted_size_curve(...)
}

# --- top-level synthetic resampling orchestrator ------------------------

#' Run the synthetic resampling layer end to end (Q1 + Q3).
#'
#' Default top-level workflow for `65_synthetic_resampling.R`. Runs
#' three subroutines in a single call so the sample-size range
#' (`n_grid`) is a first-class design parameter rather than an
#' optional extra. The mirror of `emp_run_resampling()` for the
#' synthetic side:
#'
#'   emp_run_resampling(B = 100, n_grid = c(5:30, 35, 40, 50))
#'   sim_run_synthetic_resampling(B = 100, n_grid = c(5:30, 35, 40, 50))
#'
#' Subroutines (any combination toggleable via `include_*`):
#'   0. `sim_refresh_synthetic_registry()` -- rebuild the simulation
#'      overview registry (`output_sim_v30/overview/outcome_registry.csv`)
#'      from current sidecars before any subroutine runs. Default ON
#'      (`refresh_registry = TRUE`). Skip with `refresh_registry = FALSE`
#'      when the registry is known fresh.
#'   A. `sim_run_cell_size_curve()` -- Q1 known-cell n_outcomes
#'      stability curve (synthetic-only).
#'   B. `sim_run_empirical_weighted_synthetic()` -- Q3 empirical-
#'      weighted synthetic sampling at observed stratum sizes.
#'   C. `sim_run_empirical_weighted_size_curve()` -- Q3 empirical-
#'      weighted synthetic n_outcomes stability curve.
#'
#' Lower-level runners are unchanged and remain useful targeted /
#' debug entry points; this orchestrator just sequences them.
#'
#' @param refresh_registry If TRUE (default), call
#'   `sim_refresh_synthetic_registry()` once before the include_*
#'   subroutines so the on-disk overview registry is rebuilt from
#'   the current sidecars. Set FALSE to skip (e.g. when the registry
#'   was just rebuilt by another call in the same session).
#'
#' @return invisible list(B, n_grid, pool_key, smoothing,
#'   cell_size_curve, empirical_weighted_synthetic,
#'   empirical_weighted_size_curve, files).
sim_run_synthetic_resampling <- function(
    # B tiers: 500 dev / 5000 internal high-precision / 15000
    # final-publication. Pass B explicitly for final runs.
    B                              = 500L,
    n_grid                         = .SC_SIZE_GRID_DEFAULT,
    empirical_root                 = "output",
    sim_output_root                = "output_sim_v30",
    data_root                      = "data",
    latent_root                    = "simulation/latent",
    vintage                        = "2026",
    pool_key                       = c("target", "observed"),
    smoothing                      = c("eb_corpus", "corpus_blend",
                                       "additive", "none"),
    kappa                          = 4,
    support                        = c("occupied"),
    allow_partial                  = FALSE,
    workers                        = NULL,
    write                          = TRUE,
    verbose                        = TRUE,
    refresh_registry               = TRUE,
    include_cell_size_curve        = TRUE,
    include_observed_composition   = TRUE,
    include_composition_size_curve = TRUE) {
  pool_key  <- match.arg(pool_key)
  smoothing <- match.arg(smoothing)
  support   <- match.arg(support)
  B <- as.integer(B)
  n_grid <- sort(unique(as.integer(n_grid)))
  if (B < 1L) stop("sim_run_synthetic_resampling: B must be >= 1.")
  if (length(n_grid) == 0L || any(n_grid <= 0L))
    stop("sim_run_synthetic_resampling: n_grid must be positive ",
         "integers.")
  if (!isTRUE(include_cell_size_curve) &&
      !isTRUE(include_observed_composition) &&
      !isTRUE(include_composition_size_curve))
    stop("sim_run_synthetic_resampling: at least one of ",
         "include_cell_size_curve / include_observed_composition / ",
         "include_composition_size_curve must be TRUE.")

  if (isTRUE(verbose))
    message(sprintf(paste0(
      "[sc][resampling] B=%d, n_grid=%d (%d..%d), pool_key=%s, ",
      "smoothing=%s, kappa=%s, support=%s; subruns: cell=%s, ",
      "observed_composition=%s, composition_curve=%s; ",
      "refresh_registry=%s"),
      B, length(n_grid), min(n_grid), max(n_grid), pool_key, smoothing,
      if (smoothing == "eb_corpus") sprintf("%g", kappa) else "n/a",
      support,
      isTRUE(include_cell_size_curve),
      isTRUE(include_observed_composition),
      isTRUE(include_composition_size_curve),
      isTRUE(refresh_registry)))

  # Rebuild the simulation overview registry from current sidecars
  # before any subroutine consumes it. This is the canonical sidecar ->
  # registry handoff that used to be a separate manual Phase B step
  # (build_estimand_tables(root = sim_output_root, ...)); folding it in
  # here makes the default workflow self-contained. Opt out with
  # refresh_registry = FALSE when the registry is known fresh.
  if (isTRUE(refresh_registry)) {
    if (isTRUE(verbose))
      message(sprintf(
        "[sc][resampling] refreshing overview registry: %s",
        file.path(sim_output_root, "overview", "outcome_registry.csv")))
    sim_refresh_synthetic_registry(
      root       = sim_output_root,
      output_dir = file.path(sim_output_root, "overview"),
      write_tex  = FALSE)
  }

  cell_res <- NULL
  obs_res  <- NULL
  comp_res <- NULL

  if (isTRUE(include_cell_size_curve))
    cell_res <- sim_run_cell_size_curve(
      B               = B,
      n_grid          = n_grid,
      pool_key        = pool_key,
      sim_output_root = sim_output_root,
      data_root       = data_root,
      latent_root     = latent_root,
      vintage         = vintage,
      allow_partial   = allow_partial,
      workers         = workers,
      write           = write,
      verbose         = verbose)

  if (isTRUE(include_observed_composition))
    obs_res <- sim_run_empirical_weighted_synthetic(
      empirical_root  = empirical_root,
      sim_output_root = sim_output_root,
      data_root       = data_root,
      latent_root     = latent_root,
      vintage         = vintage,
      B               = B,
      pool_key        = pool_key,
      smoothing       = smoothing,
      kappa           = kappa,
      support         = support,
      allow_partial   = allow_partial,
      workers         = workers,
      write           = write,
      verbose         = verbose)

  if (isTRUE(include_composition_size_curve))
    comp_res <- sim_run_empirical_weighted_size_curve(
      B               = B,
      n_grid          = n_grid,
      pool_key        = pool_key,
      smoothing       = smoothing,
      kappa           = kappa,
      support         = support,
      empirical_root  = empirical_root,
      sim_output_root = sim_output_root,
      data_root       = data_root,
      latent_root     = latent_root,
      vintage         = vintage,
      allow_partial   = allow_partial,
      workers         = workers,
      write           = write,
      verbose         = verbose)

  files <- c(if (!is.null(cell_res)) cell_res$files else character(0),
             if (!is.null(obs_res))  obs_res$files  else character(0),
             if (!is.null(comp_res)) comp_res$files else character(0))

  if (isTRUE(verbose))
    message(sprintf("[sc][resampling] done: %d total file(s) written%s",
                    length(files),
                    if (!isTRUE(write)) " (write=FALSE)" else ""))

  invisible(list(
    B                              = B,
    n_grid                         = n_grid,
    pool_key                       = pool_key,
    smoothing                      = smoothing,
    kappa                          = kappa,
    support_scope                  = support,
    cell_size_curve                = cell_res,
    empirical_weighted_synthetic   = obs_res,
    empirical_weighted_size_curve  = comp_res,
    files                          = files))
}
