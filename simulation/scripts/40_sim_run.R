# 40_sim_run.R — simulation workflow orchestrator.
#
# Define-only on source. Sourcing installs functions and (define-only)
# sources 10/20/30/50/55; it does NOT generate data, fit, or launch
# RoBMA. Real work happens only when one of the public entry points
# below is explicitly called.
#
# Public workflow (the canonical sequence):
#
#   source("simulation/scripts/40_sim_run.R")
#
#   sim_generate_library(n_reps = 150)   # 1. generate audit-ready CSVs
#   sim_run_study_geometry()             # 2. raw input-geometry check
#   sim_fit_library()                    # 3. fit the generated library
#   sim_scan_fit_progress()              # 4. monitor (read-only)
#   sim_build_cell_diagnostics()         # 5. cell diagnostics from fits
#   # then: emp_run_resampling()
#   #       / sim_run_synthetic_resampling()
#   #       / sim_run_empirical_synthetic_agreement()
#   #       / sim_run_all_analysis_visuals()
#
# Key design rule: the requested replicate count is defined only at
# generation time. Downstream scripts (fit, monitor, diagnostics,
# Q3 sampling, agreement, visuals) infer the current library size by
# counting generated CSVs and fitted sidecars via
# sim_inventory_library(); they do NOT hardcode 25, 150, or any other
# tier value.
#
# Public entry points:
#   * `sim_generate_library(n_reps, ...)` — primary generator. Writes
#     n_reps replicates per cell into
#     data/sim_<cell_slug>/sim<vintage>/repNNNN.csv (+ latent files).
#     Idempotent under overwrite=FALSE (existing reps preserved).
#   * `sim_run_design(...)`                — lower-level design runner;
#     still available, but `sim_generate_library()` is the supported
#     user-facing call.
#   * `sim_smoke_test()`                   — validate the design and
#     (optionally) generate a tiny test vintage with cleanup.
#   * `sim_fit_library(...)`               — fit every generated dataset
#     into the canonical simulation output root (per-stratum only).
#   * `sim_inventory_library(...)`         — re-export of the central
#     library inventory helper (lives in 50_sim_fit_monitor.R).
#   * `sim_scan_fit_progress()`            — re-export of the live-safe
#     fit monitor.
#   * `sim_build_cell_diagnostics()`       — re-export of the per-cell
#     rigor/component diagnostic builder.
#   * `sim_fit_config(...)`                — return / apply the CONFIG
#     overrides that pin the fit to the simulation output root.
#
# This file never calls RoBMA or batch_fit() on source; the fitter
# (`sim_fit_library()`) sources the main pipeline fit modules lazily,
# only when called.

if (!exists(".robma_sim_utils_loaded", inherits = TRUE) ||
    !isTRUE(.robma_sim_utils_loaded)) {
  source("simulation/scripts/00_sim_utils.R")
}
# Idempotent define-only re-source of the generator modules + the
# inventory / monitor / diagnostics layer, so the canonical workflow can
# be exercised from this single source().
source("simulation/scripts/10_sim_design.R")
source("simulation/scripts/20_sim_generate.R")
source("simulation/scripts/30_sim_export.R")
source("simulation/scripts/50_sim_fit_monitor.R")
source("simulation/scripts/55_sim_cell_diagnostics.R")
# Downstream analysis layers (60 Q2 empirical resampling, 65 synthetic
# resampling (Q1 + Q3), 70 Q3 agreement, 75 visuals). All define-only
# on source; sourcing here exposes emp_run_resampling(),
# sim_run_synthetic_resampling() (top-level synthetic runner),
# sim_run_synthetic_composition() / sim_run_cell_size_curve() /
# sim_run_composition_size_curve() (lower-level synthetic runners),
# sim_run_empirical_synthetic_agreement(),
# sim_run_composition_visuals(), and sim_run_all_analysis_visuals()
# from a single source("simulation/scripts/40_sim_run.R").
source("simulation/scripts/60_empirical_resampling.R")
source("simulation/scripts/65_synthetic_resampling.R")
source("simulation/scripts/70_empirical_synthetic_agreement.R")
source("simulation/scripts/75_analysis_visuals.R")

#' Build one *planned* manifest row for a (cell_row, rep_id) without
#' running the DGM or touching disk. Mirrors the path/identity logic of
#' `sim_export_dataset()` so a dry run reports exactly where outputs
#' would land. Internal; used by `sim_run_design(dry_run = TRUE)` and
#' by `sim_smoke_test()`.
.sim_planned_row <- function(cell_row, rep_id, vintage,
                             data_root = "data",
                             latent_root = "simulation/latent") {
  cell_slug   <- cell_row$cell_slug %||% cell_row$cell
  stratum_dir <- cell_row$stratum   %||% sim_stratum_dir(cell_slug)
  source_dir  <- sim_source_tag(vintage)
  stem        <- sim_make_stem(cell_slug, rep_id)
  csv_path    <- file.path(data_root, stratum_dir, source_dir,
                           paste0(stem, ".csv"))
  latent_path <- file.path(latent_root, stratum_dir, source_dir,
                           paste0(stem, "_latent.csv"))
  legacy <- cell_row$legacy_cell_code %||%
    paste(cell_row$eff_band  %||% NA, cell_row$het_band %||% NA,
          cell_row$bias_band %||% NA, sep = "_")
  data.frame(
    cell               = cell_row$cell,
    cell_slug          = cell_slug,
    stratum            = stratum_dir,
    synthetic_stratum  = stratum_dir,
    legacy_cell_code   = legacy,
    eff_band           = cell_row$eff_band           %||% NA_character_,
    effect_slug        = cell_row$effect_slug        %||% NA_character_,
    het_band           = cell_row$het_band           %||% NA_character_,
    heterogeneity_slug = cell_row$heterogeneity_slug %||% NA_character_,
    bias_band          = cell_row$bias_band          %||% NA_character_,
    bias_slug          = cell_row$bias_slug          %||% NA_character_,
    rep_id             = as.integer(rep_id),
    replicate_id       = as.integer(rep_id),
    stem               = stem,
    source_article     = source_dir,
    stratum_dir        = stratum_dir,
    source_dir         = source_dir,
    vintage            = vintage,
    csv_path           = csv_path,
    latent_path        = latent_path,
    mu_true            = cell_row$mu_true,
    tau_true           = cell_row$tau_true,
    selection          = cell_row$selection,
    w_sig01            = cell_row$w_sig01,
    w_sig05            = cell_row$w_sig05,
    w_ns               = cell_row$w_ns,
    smallstudy_alpha   = cell_row$smallstudy_alpha,
    status             = "planned",
    stringsAsFactors   = FALSE
  )
}

#' Run the simulation design.
#'
#' Lower-level entry point. Most callers should use
#' `sim_generate_library()` instead — this function is kept for
#' situations that need finer control (custom design subsets, smoke
#' tests, etc.).
#'
#' Generates every (cell, replicate) defined by the design and exports
#' them into `data/sim_<cell_slug>/sim<vintage>/<stem>.csv`. Replicate
#' count is resolved as: `n_replicates_override` first (applied uniformly
#' if supplied), else the design's `n_replicates_pilot` / `_full` column
#' for the chosen `mode`.
#'
#' Idempotent under `overwrite = FALSE`: existing CSVs are kept and the
#' manifest row is marked `status = "skipped"`.
#'
#' The manifest filename follows
#' `sim_<manifest_tag>_<timestamp>.csv`. The default `manifest_tag`
#' is `sim_v3_generation`; the row-level provenance (`simulation_run_id`,
#' `n_reps_requested`, mode) records the requested replicate count, so
#' filenames stay stable across tiers.
#'
#' @return The manifest data frame, invisibly. For `dry_run = TRUE` this
#'   is the planned manifest (every row `status = "planned"`).
sim_run_design <- function(design_path           = .SIM_DEFAULT_DESIGN_PATH,
                           design                = NULL,
                           data_root             = "data",
                           latent_root           = "simulation/latent",
                           manifest_dir          = "simulation/manifests",
                           vintage               = .SIM_DEFAULT_VINTAGE,
                           base_seed             = .SIM_DEFAULT_BASE_SEED,
                           overwrite             = FALSE,
                           verbose               = TRUE,
                           mode                  = c("pilot", "full"),
                           n_replicates_override = NULL,
                           keep_candidates       = FALSE,
                           manifest_tag          = NULL,
                           dry_run               = FALSE,
                           expect_full36         = TRUE) {

  mode <- match.arg(mode)

  if (is.null(design)) {
    design <- sim_load_design(design_path, expect_full36 = expect_full36)
  }
  if (is.null(manifest_tag))
    manifest_tag <- "sim_v3_generation"
  stopifnot(is.data.frame(design), nrow(design) >= 1L)

  if (!is.null(n_replicates_override)) {
    stopifnot(is.numeric(n_replicates_override),
              length(n_replicates_override) == 1L,
              n_replicates_override >= 1L)
    design$n_rep_resolved <- as.integer(n_replicates_override)
    rep_source <- sprintf("override (%d/cell)",
                          as.integer(n_replicates_override))
    n_reps_requested <- as.integer(n_replicates_override)
  } else if (mode == "pilot") {
    design$n_rep_resolved <- design$n_replicates_pilot
    rep_source <- "design$n_replicates_pilot"
    n_reps_requested <- NA_integer_
  } else {
    design$n_rep_resolved <- design$n_replicates_full
    rep_source <- "design$n_replicates_full"
    n_reps_requested <- NA_integer_
  }

  ts                <- format(Sys.time(), "%Y%m%d_%H%M%S")
  simulation_run_id <- paste0("simrun_", manifest_tag, "_", ts)

  if (!isTRUE(dry_run) && !dir.exists(manifest_dir)) {
    dir.create(manifest_dir, recursive = TRUE)
  }

  if (verbose && !grepl("[0-9]{4}$", sim_source_tag(vintage))) {
    message(sprintf(
      "[sim] note: source_article '%s' has no trailing 4-digit year, ",
      sim_source_tag(vintage)),
      "so source_year will be NA. Fine for a test vintage; for a ",
      "production library use a year vintage (e.g. \"2026\") and keep ",
      "the library version in CONFIG$corpus_id / CONFIG$output_root.")
  }

  if (verbose) {
    message(sprintf(
      "[sim] %sdesign tag='%s', mode='%s', vintage='%s', ",
      if (isTRUE(dry_run)) "DRY-RUN " else "",
      manifest_tag, mode, vintage),
      sprintf("replicate counts from %s. Cells: %d. Total target reps: %d.",
              rep_source, nrow(design), sum(design$n_rep_resolved)))
  }

  rows <- list()
  idx  <- 0L

  for (i in seq_len(nrow(design))) {
    cell_row <- design[i, , drop = FALSE]
    n_rep    <- cell_row$n_rep_resolved

    if (verbose) {
      message(sprintf("[sim] cell '%s' (%s/%s/%s): %d replicate(s) ...",
                      cell_row$cell,
                      cell_row$eff_band, cell_row$het_band, cell_row$bias_band,
                      n_rep))
    }

    for (rep_id in seq_len(n_rep)) {
      idx <- idx + 1L
      if (isTRUE(dry_run)) {
        rows[[idx]] <- .sim_planned_row(
          cell_row, rep_id, vintage,
          data_root = data_root, latent_root = latent_root
        )
        next
      }
      ds <- sim_generate_dataset(cell_row, rep_id,
                                  base_seed       = base_seed,
                                  keep_candidates = keep_candidates)
      rows[[idx]] <- sim_export_dataset(
        ds,
        data_root   = data_root,
        latent_root = latent_root,
        vintage     = vintage,
        overwrite   = overwrite
      )
    }
  }

  manifest <- do.call(rbind, rows)
  manifest$simulation_run_id <- simulation_run_id
  manifest$n_reps_requested  <- n_reps_requested
  manifest$mode              <- mode
  if (!"vintage" %in% names(manifest)) manifest$vintage <- vintage

  if (isTRUE(dry_run)) {
    if (verbose) {
      message(sprintf(
        "[sim] DRY-RUN: %d planned dataset(s), 0 written. run_id=%s",
        nrow(manifest), simulation_run_id))
    }
    return(invisible(manifest))
  }

  manifest_path <- file.path(
    manifest_dir,
    paste0("sim_", manifest_tag, "_", ts, ".csv")
  )
  utils::write.csv(manifest, manifest_path, row.names = FALSE)

  if (verbose) {
    n_written <- sum(manifest$status == "written")
    n_skipped <- sum(manifest$status == "skipped")
    message(sprintf("[sim] done: %d written, %d skipped. Manifest: %s",
                    n_written, n_skipped, manifest_path))
  }

  invisible(manifest)
}

#' Generate the synthetic full36 library at `n_reps` per cell.
#'
#' Primary user-facing generator. Wraps `sim_run_design()` with a single
#' obvious knob (`n_reps`) and stable default identity (full36 v3 design,
#' year vintage, sim_v3_generation manifest tag).
#'
#' `overwrite = FALSE` (default) is idempotent: existing CSVs for any
#' rep are kept and only missing reps are written. Bumping the library
#' from e.g. 25 reps/cell to 150 reps/cell is simply
#' `sim_generate_library(n_reps = 150)`.
#'
#' Use `dry_run = TRUE` to plan without writing anything: returns the
#' planned manifest (36 * n_reps rows for the default design).
#'
#' @param n_reps Required: number of replicates per cell (integer >= 1).
#' @param design_path Path to a design CSV.
#' @param vintage     Year-only vintage tag (default "2026"); the data
#'   path becomes data/sim_<cell_slug>/sim<vintage>/repNNNN.csv.
#' @param data_root / latent_root / manifest_dir Output roots.
#' @param overwrite If TRUE, existing CSVs are regenerated.
#' @param base_seed  Deterministic per-(cell, rep) seed base.
#' @param keep_candidates Latent file records rejected candidates too.
#' @param manifest_tag Stable tag for the manifest filename + run id;
#'   default "sim_v3_generation".
#' @param dry_run If TRUE, no disk writes; returns planned manifest.
#' @param verbose Print per-cell progress.
#'
#' @return The manifest data.frame (invisible).
sim_generate_library <- function(n_reps,
                                 design_path = .SIM_DEFAULT_DESIGN_PATH,
                                 vintage     = .SIM_DEFAULT_VINTAGE,
                                 data_root   = "data",
                                 latent_root = "simulation/latent",
                                 manifest_dir = "simulation/manifests",
                                 overwrite   = FALSE,
                                 base_seed   = .SIM_DEFAULT_BASE_SEED,
                                 keep_candidates = FALSE,
                                 manifest_tag = "sim_v3_generation",
                                 dry_run     = FALSE,
                                 verbose     = TRUE) {
  if (missing(n_reps) || is.null(n_reps))
    stop("sim_generate_library: 'n_reps' is required (replicates per cell).",
         call. = FALSE)
  n_reps <- suppressWarnings(as.integer(n_reps))
  if (length(n_reps) != 1L || is.na(n_reps) || n_reps < 1L)
    stop("sim_generate_library: 'n_reps' must be an integer scalar >= 1.",
         call. = FALSE)
  sim_run_design(
    design_path           = design_path,
    data_root             = data_root,
    latent_root           = latent_root,
    manifest_dir          = manifest_dir,
    vintage               = vintage,
    base_seed             = base_seed,
    overwrite             = overwrite,
    verbose               = verbose,
    mode                  = "full",
    n_replicates_override = n_reps,
    keep_candidates       = keep_candidates,
    manifest_tag          = manifest_tag,
    dry_run               = dry_run,
    expect_full36         = TRUE)
}

#' Lightweight smoke / dry-run check.
#'
#' Always validates the full36 design. With `generate = TRUE` also writes
#' a tiny test vintage and (by default) cleans it up afterwards.
sim_smoke_test <- function(cells   = c("null_lowhet_clean",
                                       "moderate_midhet_modbias"),
                           vintage = "test_smoke",
                           generate = FALSE,
                           n_rep    = 1L,
                           cleanup  = TRUE,
                           design_path = .SIM_DEFAULT_DESIGN_PATH,
                           data_root   = "data",
                           latent_root = "simulation/latent",
                           verbose  = TRUE) {

  design <- sim_load_design(design_path, expect_full36 = TRUE)
  if (verbose) {
    message(sprintf("[smoke] full36 design OK: %d cells from %s",
                    nrow(design), design_path))
  }

  bad <- setdiff(cells, design$cell)
  if (length(bad)) {
    stop("Unknown smoke cell(s): ", paste(bad, collapse = ", "),
         ". Available e.g.: ",
         paste(utils::head(design$cell, 4L), collapse = ", "), ", ...")
  }
  sub <- design[design$cell %in% cells, , drop = FALSE]

  plan <- do.call(rbind, lapply(seq_len(nrow(sub)), function(i) {
    do.call(rbind, lapply(seq_len(n_rep), function(r)
      .sim_planned_row(sub[i, , drop = FALSE], r, vintage,
                       data_root = data_root, latent_root = latent_root)))
  }))
  if (verbose) {
    message("[smoke] planned outputs:")
    for (p in plan$csv_path) message("  ", p)
  }

  if (!isTRUE(generate)) {
    return(invisible(list(design = design, plan = plan,
                          manifest = NULL, cleaned = FALSE)))
  }

  manifest <- sim_run_design(
    design          = sub,
    data_root       = data_root,
    latent_root     = latent_root,
    vintage         = vintage,
    n_replicates_override = as.integer(n_rep),
    manifest_tag    = "sim_v3_smoke",
    verbose         = verbose
  )

  cleaned <- FALSE
  if (isTRUE(cleanup)) {
    src_dir <- sim_source_tag(vintage)
    for (slug in unique(plan$stratum)) {
      for (root in c(data_root, latent_root)) {
        leaf <- file.path(root, slug, src_dir)
        if (dir.exists(leaf)) unlink(leaf, recursive = TRUE, force = TRUE)
        parent <- file.path(root, slug)
        if (dir.exists(parent) &&
            length(list.files(parent, recursive = TRUE)) == 0L) {
          unlink(parent, recursive = TRUE, force = TRUE)
        }
      }
    }
    cleaned <- TRUE
    if (verbose) {
      message(sprintf("[smoke] cleaned test vintage '%s' under %d stratum/strata",
                      src_dir, length(unique(plan$stratum))))
    }
  }

  invisible(list(design = design, plan = plan,
                 manifest = manifest, cleaned = cleaned))
}

#' Canonical main-pipeline CONFIG for fitting a simulation library.
#'
#' Define-only: returns (and, with `verbose`, prints) the CONFIG
#' overrides to set on the MAIN pipeline before fitting synthetic
#' datasets. With default args returns the central constants
#' (`.SIM_DEFAULT_OUTPUT_ROOT` / `.SIM_DEFAULT_CORPUS_ID` /
#' `.SIM_DEFAULT_SCHEME`); pass a non-default `library_version` only
#' when standing up a new library vintage. Does NOT touch the global
#' CONFIG unless `apply = TRUE`.
sim_fit_config <- function(library_version = "v30",
                           apply   = FALSE,
                           verbose = TRUE) {
  cfg <- if (identical(library_version, "v30"))
    list(output_root = .SIM_DEFAULT_OUTPUT_ROOT,
         corpus_id   = .SIM_DEFAULT_CORPUS_ID,
         scheme      = .SIM_DEFAULT_SCHEME)
  else
    list(output_root = paste0("output_sim_", library_version),
         corpus_id   = paste0("sim_library_", library_version),
         scheme      = .SIM_DEFAULT_SCHEME)
  if (isTRUE(verbose)) {
    message("# --- Simulation fitting CONFIG (set on the MAIN pipeline) ---")
    message(sprintf('CONFIG$output_root <- "%s"', cfg$output_root))
    message(sprintf('CONFIG$corpus_id   <- "%s"', cfg$corpus_id))
    message(sprintf('CONFIG$scheme      <- "%s"', cfg$scheme))
    message("# WARNING: never mix empirical nutrition sidecars and ",
            "synthetic sidecars in one output root.")
    message("# Use a SEPARATE output_root (and corpus_id) for every ",
            "major simulation library vintage; bumping library_version ",
            "keeps old fitted libraries intact.")
  }
  if (isTRUE(apply)) {
    if (exists("CONFIG", envir = .GlobalEnv) &&
        is.list(get("CONFIG", envir = .GlobalEnv))) {
      g <- get("CONFIG", envir = .GlobalEnv)
      g$output_root <- cfg$output_root
      g$corpus_id   <- cfg$corpus_id
      g$scheme      <- cfg$scheme
      assign("CONFIG", g, envir = .GlobalEnv)
      if (isTRUE(verbose)) message("[sim] applied to global CONFIG.")
      return(invisible(g))
    }
    warning("apply = TRUE but no global CONFIG list found; ",
            "returning the recommended block without applying.")
  }
  invisible(cfg)
}

# Source main pipeline fit modules lazily (only when sim_fit_library
# actually runs). The numbered scripts under scripts/ are define-only,
# but they only need to be loaded when fitting is requested.
.sim_lazy_source_fit_deps <- function() {
  needed <- list(
    .robma_utils_loaded            = "scripts/00_utils.R",
    list_datasets                   = "scripts/10_load_data.R",
    fit_robma_models                = "scripts/20_robma_fit.R",
    batch_fit                       = "scripts/40_batch_fit.R")
  for (sym in names(needed)) {
    if (!exists(sym, inherits = TRUE)) source(needed[[sym]])
  }
  invisible(TRUE)
}

#' Fit every generated simulation dataset.
#'
#' Per-stratum loop only (compact `repNNNN` stems are not unique across
#' strata, so a single all-strata `batch_fit()` collides the dataset
#' objects loaded by `load_datasets()` and fits the wrong data).
#' `sim_assert_stratum_scoped_fit()` is called immediately before each
#' `batch_fit()`.
#'
#' Replicate-count agnostic. The set of datasets to fit is derived from
#' `sim_inventory_library()` (whatever generated CSVs are on disk
#' under `data/sim_<cell_slug>/<source>/repNNNN.csv`). No
#' TARGET_REPS_PER_CELL config block. Resume- and restart-safe: the
#' canonical fitter logic skips datasets whose contract-matched v4
#' artifacts + sidecar already exist.
#'
#' Writes:
#'   * `output_sim_v30/<stratum>/...`              (via `batch_fit`)
#'   * `simulation/results/fit_status.csv`         (cumulative status)
#'   * `simulation/results/fit_progress_live.csv`
#'   * `simulation/results/fit_progress_overall.csv`
#'
#' @param data_root   Where the generated CSVs live (default "data").
#' @param output_root Simulation output root (default
#'   `.SIM_DEFAULT_OUTPUT_ROOT` = "output_sim_v30").
#' @param vintage     Vintage tag (default "2026"; -> source_article
#'   "sim2026").
#' @param results_dir Where to write status / progress CSVs
#'   (default "simulation/results").
#' @param resume      If TRUE (default), already-fit datasets are skipped
#'   on this run.
#' @param workers     Per-stratum concurrent worker count. Default
#'   reads the env var `SIM_FIT_WORKERS` and falls back to 1.
#' @param verbose     Per-stratum progress messages.
#'
#' @return invisible list(status, final) where `final` is the most
#'   recent `sim_scan_fit_progress()` result.
sim_fit_library <- function(data_root   = "data",
                            latent_root = "simulation/latent",
                            output_root = .SIM_DEFAULT_OUTPUT_ROOT,
                            vintage     = .SIM_DEFAULT_VINTAGE,
                            results_dir = "simulation/results",
                            resume      = TRUE,
                            workers     = NULL,
                            verbose     = TRUE) {
  if (is.null(workers)) {
    w <- suppressWarnings(as.integer(Sys.getenv("SIM_FIT_WORKERS", "1")))
    workers <- if (is.na(w) || w < 1L) 1L else w
  }
  workers <- as.integer(workers)

  .sim_lazy_source_fit_deps()

  # Pin the main-pipeline CONFIG to the simulation output root before any
  # fit attempt (also guards against accidental empirical co-mingling).
  sim_fit_config(apply = TRUE, verbose = verbose)
  if (!exists("CONFIG", envir = .GlobalEnv))
    stop("sim_fit_library: global CONFIG list not found after ",
         "sim_fit_config(apply=TRUE).")
  CFG <- get("CONFIG", envir = .GlobalEnv)
  stopifnot(identical(CFG$output_root, output_root),
            identical(CFG$corpus_id,   .SIM_DEFAULT_CORPUS_ID),
            identical(CFG$scheme,      .SIM_DEFAULT_SCHEME))

  design <- sim_load_design()
  strata <- design$stratum
  if (length(strata) != 36L || length(unique(strata)) != 36L)
    stop(sprintf("sim_fit_library: expected 36 unique sim strata, got %d.",
                 length(strata)))
  if (!all(grepl("^sim_", strata)))
    stop("sim_fit_library: design carries a non-sim_ stratum; aborting ",
         "to protect empirical data.")

  inv <- sim_inventory_library(data_root   = data_root,
                               latent_root = latent_root,
                               output_root = output_root,
                               vintage     = vintage,
                               design      = design)
  if (inv$overall$n_generated_total == 0L)
    stop(sprintf(
      "sim_fit_library: no generated CSVs under '%s/sim_*/%s/repNNNN.csv'. ",
      data_root, sim_source_tag(vintage)),
      "Run sim_generate_library(n_reps = N) first.", call. = FALSE)
  empty <- inv$per_cell$stratum[inv$per_cell$n_generated == 0L]
  if (length(empty))
    stop(sprintf(
      "sim_fit_library preflight FAILED: %d stratum/strata have 0 generated ",
      length(empty)),
      sprintf("CSVs (e.g. %s). Run sim_generate_library() first.",
              paste(utils::head(empty, 5), collapse = ", ")),
      call. = FALSE)

  if (verbose)
    message(sprintf(paste0(
      "[sim_fit] preflight OK: 36 strata, %d generated CSVs ",
      "(%d..%d/cell%s); workers=%d; output_root=%s; ",
      "library_status=%s"),
      inv$overall$n_generated_total,
      inv$overall$generated_reps_min, inv$overall$generated_reps_max,
      if (inv$overall$generated_reps_uniform) "" else " (uneven)",
      workers, output_root, inv$overall$library_status))

  if (!dir.exists(results_dir)) dir.create(results_dir, recursive = TRUE)
  status_csv <- file.path(results_dir, "fit_status.csv")

  t0 <- Sys.time()
  fit_source_article <- sim_source_tag(vintage)
  all_status <- list()
  for (i in seq_along(strata)) {
    st <- strata[i]
    if (verbose)
      message(sprintf("[%02d/%02d] fitting %s", i, length(strata), st))

    sim_assert_stratum_scoped_fit(stratum = st,
                                  source_article = fit_source_article)
    res <- tryCatch(
      batch_fit(stratum = st, source_article = fit_source_article,
                resume = resume, verbose = verbose,
                concurrent_workers = workers),
      error = function(e) list(status = data.frame(
        dataset_stem = NA_character_, stratum = st,
        source_article = fit_source_article,
        status = "driver_error", message = conditionMessage(e),
        elapsed_sec = NA_real_, out_dir = NA_character_,
        stringsAsFactors = FALSE)))
    s <- res$status
    s$cell_index <- i
    all_status[[i]] <- s
    utils::write.csv(do.call(rbind, all_status), status_csv,
                     row.names = FALSE)
    pr <- sim_scan_fit_progress(output_root = output_root,
                                vintage     = vintage,
                                data_root   = data_root,
                                latent_root = latent_root,
                                design      = design)
    sim_write_fit_progress(pr, results_dir = results_dir,
                           output_root = output_root,
                           vintage     = vintage,
                           data_root   = data_root,
                           latent_root = latent_root)
    if (verbose) {
      message(sprintf(paste0(
        "    -> %s | overall fit=%d/%d (%.1f%%) | integrity=%s"),
        paste(sprintf("%s:%d", names(table(s$status)),
                      table(s$status)), collapse = " "),
        pr$overall$readable_sidecars_total,
        pr$overall$n_generated_total,
        if (is.na(pr$overall$pct_complete)) NA_real_
        else pr$overall$pct_complete,
        pr$overall$integrity_flag))
    }
  }
  status <- do.call(rbind, all_status)
  utils::write.csv(status, status_csv, row.names = FALSE)

  final <- sim_scan_fit_progress(output_root = output_root,
                                 vintage     = vintage,
                                 data_root   = data_root,
                                 latent_root = latent_root,
                                 design      = design)
  sim_write_fit_progress(final, results_dir = results_dir,
                         output_root = output_root,
                         vintage     = vintage,
                         data_root   = data_root,
                         latent_root = latent_root)

  if (verbose) {
    message("\n==== FIT RUN SUMMARY ====")
    print(table(status$status))
    message(sprintf(paste0(
      "readable %d/%d (%.1f%%)  library_status=%s  integrity=%s"),
      final$overall$readable_sidecars_total,
      final$overall$n_generated_total,
      if (is.na(final$overall$pct_complete)) NA_real_
      else final$overall$pct_complete,
      final$overall$library_status,
      final$overall$integrity_flag))
    if (!identical(final$overall$integrity_flag, "ok") &&
        !identical(final$overall$integrity_flag, "insufficient_data"))
      message("WARNING: integrity_flag != ok -> ",
              final$overall$integrity_note)
    message(sprintf("elapsed: %.1f min   status: %s",
                    as.numeric(Sys.time() - t0, units = "mins"),
                    status_csv))
    message("Resume: call sim_fit_library() again; completed datasets ",
            "are skipped.")
  }
  invisible(list(status = status, final = final))
}
