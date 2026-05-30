# 30_sim_export.R — write one generated dataset to disk; return its
#                   manifest row.
#
# Define-only on source. When called, writes the analysis-ready CSV
# into the existing data/<stratum>/<source_article>/<stem>.csv tree (so
# scripts/10_load_data.R::list_datasets() discovers it with no audit-
# pipeline change) and the latent/truth CSV into
# simulation/latent/<stratum>/<source_article>/ (so the audit loader
# never sees it). It RETURNS a 1-row manifest data.frame; the manifest
# CSV itself is written by the orchestrator 40_sim_run.R (this file
# does not write it).
#
# Canonical layout (readable cell slug; compact replicate stem):
#   data/sim_<cell_slug>/sim<vintage>/repNNNN.csv
#   simulation/latent/sim_<cell_slug>/sim<vintage>/repNNNN_latent.csv
#   stem = repNNNN  (see sim_make_stem in 00_sim_utils.R)
# The stem is intentionally compact: the synthetic cell lives in the
# folder path / dataset_id, never restated in the filename. The opaque
# legacy band code (e.g. e2_h1_b1) never appears in a path; it is
# retained only as the manifest's `legacy_cell_code` column.
#
# The manifest row carries the cell identity (cell, cell_slug, stratum,
# legacy_cell_code, eff/het/bias bands and slugs) plus the DGM
# descriptors (mu_true, tau_true, selection, w_sig01, w_sig05, w_ns,
# smallstudy_alpha, k, k_bucket, n_drawn, seed) so downstream summary
# scripts can join fitted RoBMA outputs back to the true DGM parameters.
#
# Stage: this is a generator-side writer. It runs only when called and
# is never part of the live-fit-monitoring path; it never calls RoBMA or
# batch_fit() and never reads output_sim_v30.
#
# Sourced by: 40_sim_run.R.

if (!exists(".robma_sim_utils_loaded", inherits = TRUE) ||
    !isTRUE(.robma_sim_utils_loaded)) {
  source("simulation/scripts/00_sim_utils.R")
}

#' Export one generated dataset.
#'
#' @param dataset_obj Output of `sim_generate_dataset()`.
#' @param data_root   Root of the audit data tree (default `"data"`).
#' @param latent_root Root of the simulation latent tree
#'   (default `"simulation/latent"`).
#' @param vintage     Vintage tag used for the source-article directory
#'   (default `.SIM_DEFAULT_VINTAGE`); the second path component becomes
#'   `sim<vintage>`.
#' @param overwrite   If FALSE (default), an existing analysis-ready CSV
#'   is left in place. Latent files are handled independently of the
#'   observed CSV: a missing latent file is filled in even when the
#'   observed CSV exists, provided the freshly generated observed table
#'   matches the on-disk observed CSV on `study_id`/`g`/`se_g` (within
#'   `tolerance`). This closes the historical observed-existing /
#'   latent-missing gap left by earlier exporter versions.
#' @param tolerance  Numeric tolerance for the observed-vs-on-disk
#'   match check used when filling a missing latent against an existing
#'   observed CSV (default 1e-10). `study_id` is compared exactly.
#'
#' @return A 1-row data frame with manifest fields:
#'   cell, cell_slug, stratum, synthetic_stratum, legacy_cell_code,
#'   eff_band, effect_slug, het_band, heterogeneity_slug,
#'   bias_band, bias_slug, rep_id, replicate_id, stem, source_article,
#'   stratum_dir, source_dir, vintage, csv_path, latent_path,
#'   k, k_bucket, mu_true, tau_true, selection,
#'   w_sig01, w_sig05, w_ns, smallstudy_alpha,
#'   n_per_arm_median, n_drawn, n_accepted, seed,
#'   observed_status, latent_status, status, generated_at.
#'   `csv_path` / `latent_path` are repo-relative. `simulation_run_id` is
#'   added by `sim_run_design()` (one id per run).
#'
#'   `observed_status` is "written" | "skipped" (observed CSV side only).
#'   `latent_status`   is "written" | "skipped" | "filled" | "mismatch"
#'                     | "error":
#'     * "written"  -- latent written as part of a fresh write
#'     * "skipped"  -- latent already present and not regenerated
#'     * "filled"   -- observed existed, latent was missing, and the
#'                     generated observed matched the on-disk CSV, so
#'                     the latent was written without touching observed
#'     * "mismatch" -- observed existed, latent was missing, but the
#'                     generated observed did NOT match the on-disk CSV;
#'                     latent is NOT written (warns)
#'     * "error"    -- the on-disk observed CSV could not be read or
#'                     was malformed; latent is NOT written (warns)
#'   `status` is retained for backward compatibility: it mirrors
#'   `observed_status` ("written" or "skipped").
sim_export_dataset <- function(dataset_obj,
                                data_root   = "data",
                                latent_root = "simulation/latent",
                                vintage     = .SIM_DEFAULT_VINTAGE,
                                overwrite   = FALSE,
                                tolerance   = 1e-10) {

  meta     <- dataset_obj$meta
  observed <- dataset_obj$observed
  latent   <- dataset_obj$latent

  # Readable identity. `meta$cell_slug` / `meta$stratum` come from the
  # design (carried through 20_sim_generate.R); fall back to the canonical
  # helpers if a caller passes a hand-built `meta`.
  cell_slug   <- meta$cell_slug %||% meta$cell
  stratum_dir <- meta$stratum   %||% sim_stratum_dir(cell_slug)
  source_dir  <- sim_source_tag(vintage)
  stem        <- sim_make_stem(cell_slug, meta$rep_id)

  csv_dir     <- file.path(data_root, stratum_dir, source_dir)
  csv_path    <- file.path(csv_dir, paste0(stem, ".csv"))

  # Latent/truth layer mirrors the data layout but stays outside data/:
  # simulation/latent/sim_<cell_slug>/sim<vintage>/<stem>_latent.csv
  latent_dir  <- file.path(latent_root, stratum_dir, source_dir)
  latent_path <- file.path(latent_dir, paste0(stem, "_latent.csv"))

  observed_exists <- file.exists(csv_path)
  latent_exists   <- file.exists(latent_path)

  observed_status <- NA_character_
  latent_status   <- NA_character_

  if (!observed_exists || isTRUE(overwrite)) {
    # Fresh write of both sides.
    if (!dir.exists(csv_dir))    dir.create(csv_dir,    recursive = TRUE)
    if (!dir.exists(latent_dir)) dir.create(latent_dir, recursive = TRUE)
    utils::write.csv(observed, csv_path,    row.names = FALSE)
    utils::write.csv(latent,   latent_path, row.names = FALSE)
    observed_status <- "written"
    latent_status   <- "written"
  } else {
    # Observed already on disk and overwrite = FALSE: do not touch the
    # observed CSV. Handle latent independently.
    observed_status <- "skipped"
    if (latent_exists) {
      latent_status <- "skipped"
    } else {
      # Fill the missing latent ONLY if the freshly generated observed
      # table matches the on-disk observed CSV; never reconstruct latent
      # from observed alone.
      on_disk <- tryCatch(
        utils::read.csv(csv_path, stringsAsFactors = FALSE,
                        check.names = FALSE),
        error = function(e) NULL)
      if (is.null(on_disk)) {
        latent_status <- "error"
        warning(sprintf(
          "sim_export_dataset: latent missing and on-disk observed ",
          "CSV unreadable: %s", csv_path), call. = FALSE)
      } else {
        want_cols <- c("study_id", "g", "se_g")
        if (!all(want_cols %in% names(on_disk)) ||
            nrow(on_disk) != nrow(observed)) {
          latent_status <- "error"
          warning(sprintf(
            "sim_export_dataset: latent missing and on-disk observed ",
            "CSV shape mismatch (path=%s, ncol_match=%s, nrow_disk=%d, ",
            "nrow_gen=%d).",
            csv_path,
            all(want_cols %in% names(on_disk)),
            nrow(on_disk), nrow(observed)), call. = FALSE)
        } else {
          id_ok <- isTRUE(all(as.integer(on_disk$study_id) ==
                                as.integer(observed$study_id)))
          g_ok  <- isTRUE(all(abs(as.numeric(on_disk$g) -
                                    as.numeric(observed$g)) <= tolerance))
          se_ok <- isTRUE(all(abs(as.numeric(on_disk$se_g) -
                                    as.numeric(observed$se_g)) <= tolerance))
          if (id_ok && g_ok && se_ok) {
            if (!dir.exists(latent_dir))
              dir.create(latent_dir, recursive = TRUE)
            utils::write.csv(latent, latent_path, row.names = FALSE)
            latent_status <- "filled"
          } else {
            latent_status <- "mismatch"
            warning(sprintf(
              "sim_export_dataset: latent missing and generated observed ",
              "does not match on-disk CSV (path=%s, study_id_ok=%s, ",
              "g_ok=%s, se_g_ok=%s). Latent NOT written.",
              csv_path, id_ok, g_ok, se_ok), call. = FALSE)
          }
        }
      }
    }
  }

  # Back-compat: `status` mirrors observed_status so existing manifest
  # summaries (sum(status == "written") / sum(status == "skipped")) keep
  # working. The new latent-side outcome lives in `latent_status`.
  status <- observed_status

  data.frame(
    cell               = meta$cell,
    cell_slug          = cell_slug,
    stratum            = stratum_dir,
    # synthetic_stratum is the v4-vocabulary alias of the stratum folder;
    # kept explicitly because Track-B summaries key on it by that name.
    synthetic_stratum  = stratum_dir,
    legacy_cell_code   = meta$legacy_cell_code %||%
      paste(meta$eff_band %||% NA, meta$het_band %||% NA,
            meta$bias_band %||% NA, sep = "_"),
    eff_band           = meta$eff_band           %||% NA_character_,
    effect_slug        = meta$effect_slug        %||% NA_character_,
    het_band           = meta$het_band           %||% NA_character_,
    heterogeneity_slug = meta$heterogeneity_slug %||% NA_character_,
    bias_band          = meta$bias_band          %||% NA_character_,
    bias_slug          = meta$bias_slug          %||% NA_character_,
    rep_id             = meta$rep_id,
    replicate_id       = meta$rep_id,
    stem               = stem,
    source_article     = source_dir,
    stratum_dir        = stratum_dir,
    source_dir         = source_dir,
    vintage            = vintage,
    csv_path           = csv_path,
    latent_path        = latent_path,
    k                  = meta$k,
    k_bucket           = meta$k_bucket           %||% NA_character_,
    mu_true            = meta$mu_true,
    tau_true           = meta$tau_true,
    selection          = meta$selection,
    w_sig01            = meta$w_sig01            %||% NA_real_,
    w_sig05            = meta$w_sig05            %||% NA_real_,
    w_ns               = meta$w_ns               %||% NA_real_,
    smallstudy_alpha   = meta$smallstudy_alpha,
    n_per_arm_median   = meta$n_per_arm_median   %||% NA_real_,
    n_drawn            = meta$n_drawn,
    n_accepted         = meta$n_accepted         %||% NA_integer_,
    seed               = meta$seed,
    observed_status    = observed_status,
    latent_status      = latent_status,
    status             = status,
    generated_at       = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    stringsAsFactors   = FALSE
  )
}
