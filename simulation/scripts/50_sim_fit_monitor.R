# 50_sim_fit_monitor.R - Live-safe simulation fit monitor (read-only).
#
# Define-only on source: installs functions; reads/writes nothing on
# source. Designed to be run WHILE the canonical RoBMA fit driver
# (sim_fit_library()) is actively writing output_sim_v30 from another
# process. Replicate-count agnostic: there is no x25/x150 tier label;
# the current library size is inferred from generated CSVs under
# data/sim_<cell_slug>/sim<vintage>/repNNNN.csv and fitted sidecars
# under output_sim_v30/<stratum>/<stratum>_robma_summary.csv.
#
# Hard safety contract:
#   * NEVER launches fitting, NEVER calls batch_fit(), NEVER runs RoBMA.
#   * NEVER writes, renames, or deletes anything under output_sim_v30.
#     It only reads sidecar CSVs and stats file mtime.
#   * Tolerates a sidecar that is absent for an instant (the v4 writer is
#     an atomic temp->backup->rename; there is a sub-second window where
#     the canonical file is mid-rename) and any parse error: such a
#     sidecar is reported as unreadable for this scan, never fatal.
#   * Only ever reads the canonical "<stratum>_robma_summary.csv";
#     transient ".bak" / ".tmp-*" companions are explicitly ignored.
#
# Progress is derived from the sidecars themselves (the authoritative
# record), NOT from any fit log, so it is correct regardless of how the
# background driver was launched.
#
# Public entry points:
#   sim_inventory_library()         - central source of truth: per-cell
#                                     generated/latent/fit counts +
#                                     overall library coherence summary
#   sim_read_sidecars_safely()      - crash-tolerant sidecar reader
#   sim_scan_fit_progress()         - per-cell + overall progress tables
#                                     (completeness relative to generated)
#   sim_write_fit_progress()        - persist tables to simulation/results
#                                     under stable filenames
#   sim_check_generation_library()  - generation-library structural checker
#   sim_assert_stratum_scoped_fit() - safety guard for batch_fit() callers
#   sim_detect_fit_collision()      - Pass-4A collision integrity check
#
# Sourced design loader: simulation/scripts/10_sim_design.R (define-only).

if (!exists(".robma_sim_utils_loaded", inherits = TRUE) ||
    !isTRUE(.robma_sim_utils_loaded)) {
  source("simulation/scripts/00_sim_utils.R")
}
if (!exists("sim_load_design", inherits = TRUE)) {
  source("simulation/scripts/10_sim_design.R")
}

# Expected v4 identity for every simulation sidecar row.
.SIM_FIT_IDENTITY <- c(corpus_id        = .SIM_DEFAULT_CORPUS_ID,
                       scheme           = .SIM_DEFAULT_SCHEME,
                       source_article   = sim_source_tag(.SIM_DEFAULT_VINTAGE),
                       analysis_variant = "main")

# Canonical rigor_category levels (scripts/00_utils.R::.rigor_category).
.SIM_RIGOR_CATEGORIES <- c("clean_effect_supported",
                           "clean_no_effect_supported",
                           "clean_evidence_disfavored",
                           "inconclusive_clean_evidence")

#' Crash-tolerant read of one per-stratum sidecar CSV.
#'
#' @param path Canonical "<stratum>_robma_summary.csv" path.
#' @param expect_stratum Optional stratum the rows should carry.
#' @return list(ok, df, n_rows, note). ok = FALSE means treat as
#'   unreadable for this scan (absent / mid-rename / parse error); a
#'   later scan will pick it up. Never stops.
sim_read_one_sidecar <- function(path, expect_stratum = NULL) {
  if (!file.exists(path))
    return(list(ok = FALSE, df = NULL, n_rows = 0L, note = "absent"))
  rd <- function() utils::read.csv(path, stringsAsFactors = FALSE,
                                   check.names = FALSE)
  df <- tryCatch(rd(), warning = function(w) NULL, error = function(e) NULL)
  if (is.null(df)) {                       # atomic-rename window: retry once
    Sys.sleep(0.4)
    df <- tryCatch(rd(), warning = function(w) NULL, error = function(e) NULL)
  }
  if (is.null(df))
    return(list(ok = FALSE, df = NULL, n_rows = 0L,
                note = "unreadable (parse error / mid-rename)"))
  if (!is.data.frame(df) || nrow(df) == 0L ||
      !("dataset_id" %in% names(df)))
    return(list(ok = FALSE, df = NULL, n_rows = 0L,
                note = "no rows / missing dataset_id"))
  keep <- !is.na(df$dataset_id) & nzchar(as.character(df$dataset_id))
  dropped <- sum(!keep)
  df <- df[keep, , drop = FALSE]
  note <- if (dropped > 0L) sprintf("dropped %d incomplete row(s)", dropped)
          else ""
  if (!is.null(expect_stratum) && "stratum" %in% names(df) && nrow(df)) {
    bad <- df$stratum != expect_stratum
    if (any(bad)) note <- paste(c(note,
      sprintf("%d row(s) with unexpected stratum", sum(bad))),
      collapse = "; ")
  }
  list(ok = nrow(df) > 0L, df = df, n_rows = nrow(df), note = note)
}

#' Read every readable simulation sidecar under `output_root`.
#'
#' Read-only. Returns one combined data.frame of readable rows plus a
#' per-file status frame. Never touches non-canonical .bak/.tmp files.
#'
#' @return list(rows = <data.frame|NULL>, files = <data.frame>).
sim_read_sidecars_safely <- function(output_root = .SIM_DEFAULT_OUTPUT_ROOT,
                                     design = NULL) {
  if (is.null(design)) design <- sim_load_design()
  files <- vector("list", nrow(design))
  rows  <- list()
  for (i in seq_len(nrow(design))) {
    strat <- design$stratum[i]
    path  <- file.path(output_root, strat,
                        sprintf("%s_robma_summary.csv", strat))
    rs <- sim_read_one_sidecar(path, expect_stratum = strat)
    files[[i]] <- data.frame(
      stratum      = strat,
      sidecar_path = path,
      file_exists  = file.exists(path),
      readable     = isTRUE(rs$ok),
      n_rows       = rs$n_rows,
      note         = rs$note,
      stringsAsFactors = FALSE)
    if (isTRUE(rs$ok)) rows[[length(rows) + 1L]] <- rs$df
  }
  combined <- if (length(rows))
    do.call(function(...) rbind(..., make.row.names = FALSE), rows) else NULL
  list(rows = combined,
       files = do.call(rbind, files))
}

#' Central library inventory: generated / latent / fit counts per stratum.
#'
#' Single source of truth for "how big is the current library, and how
#' much of it has been fitted?" Downstream callers (fit driver preflight,
#' fit monitor, cell diagnostics, Q3 sampling / agreement gates) should
#' all derive their counts from this helper rather than baking in a
#' hardcoded replicate target.
#'
#' Reads only the on-disk listings + each per-stratum sidecar (via the
#' live-safe reader). Never fits, never writes.
#'
#' @return list(per_cell, overall):
#'   per_cell: data.frame with one row per design stratum, columns
#'     cell_slug, stratum, n_generated, n_latent, n_fit,
#'     sidecar_present, sidecar_readable, fit_fraction, n_missing_fits.
#'   overall: list with n_strata, n_generated_total, n_latent_total,
#'     n_fit_total, generated_reps_min, generated_reps_max,
#'     generated_reps_uniform, fit_fraction, library_status,
#'     vintage, data_root, latent_root, output_root.
sim_inventory_library <- function(data_root   = "data",
                                  latent_root = "simulation/latent",
                                  output_root = .SIM_DEFAULT_OUTPUT_ROOT,
                                  vintage     = .SIM_DEFAULT_VINTAGE,
                                  design      = NULL) {
  if (is.null(design)) design <- sim_load_design()
  src <- sim_source_tag(vintage)

  per <- lapply(seq_len(nrow(design)), function(i) {
    strat   <- design$stratum[i]
    cdir    <- file.path(data_root,   strat, src)
    ldir    <- file.path(latent_root, strat, src)
    fpath   <- file.path(output_root, strat,
                         sprintf("%s_robma_summary.csv", strat))
    n_csv <- if (dir.exists(cdir))
      length(list.files(cdir, pattern = "^rep[0-9]{4}\\.csv$")) else 0L
    n_lat <- if (dir.exists(ldir))
      length(list.files(ldir, pattern = "^rep[0-9]{4}_latent\\.csv$")) else 0L

    n_fit <- 0L
    sidecar_present  <- file.exists(fpath)
    sidecar_readable <- NA
    if (sidecar_present) {
      rs <- sim_read_one_sidecar(fpath, expect_stratum = strat)
      sidecar_readable <- isTRUE(rs$ok)
      if (sidecar_readable) n_fit <- as.integer(rs$n_rows)
    }
    data.frame(
      cell_slug         = design$cell_slug[i],
      stratum           = strat,
      n_generated       = as.integer(n_csv),
      n_latent          = as.integer(n_lat),
      n_fit             = as.integer(n_fit),
      sidecar_present   = sidecar_present,
      sidecar_readable  = sidecar_readable,
      fit_fraction      = if (n_csv > 0L) round(n_fit / n_csv, 4)
                          else NA_real_,
      n_missing_fits    = as.integer(max(0L, n_csv - n_fit)),
      stringsAsFactors  = FALSE)
  })
  per_df <- do.call(rbind, per)

  gen <- per_df$n_generated
  gen_min <- as.integer(min(gen))
  gen_max <- as.integer(max(gen))
  gen_uniform <- gen_min == gen_max
  n_gen_total <- as.integer(sum(gen))
  n_fit_total <- as.integer(sum(per_df$n_fit))

  lib_status <-
    if (n_gen_total == 0L) "not_started"
    else if (n_fit_total == 0L) "generated_no_fits"
    else if (n_fit_total < n_gen_total) "partial"
    else if (n_fit_total == n_gen_total) "complete"
    else "fit_exceeds_generated"

  list(per_cell = per_df,
       overall  = list(
         n_strata               = nrow(per_df),
         n_generated_total      = n_gen_total,
         n_latent_total         = as.integer(sum(per_df$n_latent)),
         n_fit_total            = n_fit_total,
         generated_reps_min     = gen_min,
         generated_reps_max     = gen_max,
         generated_reps_uniform = gen_uniform,
         fit_fraction           = if (n_gen_total > 0L)
                                    round(n_fit_total / n_gen_total, 4)
                                  else NA_real_,
         library_status         = lib_status,
         vintage                = vintage,
         data_root              = data_root,
         latent_root            = latent_root,
         output_root            = output_root))
}

#' Resolve the per-cell completeness target for a scan.
#'
#' Default operating path: the per-cell target IS each cell's own
#' generated CSV count (so completeness means "every generated dataset
#' has been fitted"). An explicit `expected_per_cell` is supported as an
#' optional override (uniform target across all cells) and is reflected
#' in the overall summary's `expected_source` column.
#'
#' Returns a vector of length nrow(design) with the per-stratum target,
#' plus provenance metadata. NA target for a stratum with no generated
#' CSVs.
.sim_resolve_targets <- function(inv,
                                 expected_per_cell = NULL,
                                 design            = NULL) {
  if (is.null(design)) design <- sim_load_design()
  per <- inv$per_cell
  if (!is.null(expected_per_cell)) {
    v <- suppressWarnings(as.integer(expected_per_cell))
    if (length(v) != 1L || is.na(v) || v < 0L)
      stop("expected_per_cell must be a non-negative integer scalar.")
    targets <- rep(v, nrow(per))
    source  <- "explicit"
    note    <- sprintf("explicit override: %d/cell", v)
  } else {
    targets <- per$n_generated
    source  <- "generated_csvs"
    note    <- if (inv$overall$n_generated_total == 0L)
      "no generated CSVs; targets are 0/cell"
    else if (inv$overall$generated_reps_uniform)
      sprintf("inferred from generated CSVs: %d/cell across all 36 strata",
              inv$overall$generated_reps_max)
    else
      sprintf("inferred from generated CSVs: uneven generation %d..%d/cell",
              inv$overall$generated_reps_min,
              inv$overall$generated_reps_max)
  }
  list(per_target = as.integer(targets),
       expected_source = source,
       expected_note   = note,
       generated_min   = inv$overall$generated_reps_min,
       generated_max   = inv$overall$generated_reps_max,
       generated_uniform = inv$overall$generated_reps_uniform)
}

#' Scan live fit progress (per-cell + overall). Read-only.
#'
#' Default operating path: completeness is relative to the generated
#' library (each cell's target IS its generated CSV count). An optional
#' `expected_per_cell` integer overrides with a uniform target across
#' all cells and is reflected in `expected_source` provenance — it does
#' NOT affect filenames.
#'
#' @return list(cell = <df>, overall = <df>, identity_ok = <logical>,
#'   leak = <character>, collision = <list>, inventory = <list>,
#'   expected = <list>).
sim_scan_fit_progress <- function(output_root       = .SIM_DEFAULT_OUTPUT_ROOT,
                                  vintage           = .SIM_DEFAULT_VINTAGE,
                                  expected_per_cell = NULL,
                                  data_root         = "data",
                                  latent_root       = "simulation/latent",
                                  design            = NULL) {
  if (is.null(design)) design <- sim_load_design()
  inv <- sim_inventory_library(data_root = data_root,
                               latent_root = latent_root,
                               output_root = output_root,
                               vintage = vintage,
                               design = design)
  tgt <- .sim_resolve_targets(inv, expected_per_cell, design = design)
  sc   <- sim_read_sidecars_safely(output_root, design)
  rows <- sc$rows
  scan_time <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")

  # ---- empirical-leak / identity guard (whole tree) ----------------------
  leak <- character(0)
  if (!is.null(rows)) {
    if ("corpus_id" %in% names(rows)) {
      bad_corpus <- unique(rows$corpus_id[
        rows$corpus_id != .SIM_FIT_IDENTITY[["corpus_id"]]])
      if (length(bad_corpus))
        leak <- c(leak, paste0("non-sim corpus_id: ",
                               paste(bad_corpus, collapse = ",")))
    }
    if ("scheme" %in% names(rows)) {
      bad_scheme <- unique(rows$scheme[
        rows$scheme != .SIM_FIT_IDENTITY[["scheme"]]])
      if (length(bad_scheme))
        leak <- c(leak, paste0("non-sim scheme: ",
                               paste(bad_scheme, collapse = ",")))
    }
    if ("stratum" %in% names(rows)) {
      bad_st <- unique(rows$stratum[!grepl("^sim_", rows$stratum)])
      if (length(bad_st))
        leak <- c(leak, paste0("non-sim stratum: ",
                               paste(bad_st, collapse = ",")))
    }
  }

  succ_col <- "rigor_direction"
  cell <- do.call(rbind, lapply(seq_len(nrow(design)), function(i) {
    strat <- design$stratum[i]
    fr    <- sc$files[sc$files$stratum == strat, ]
    rr    <- if (!is.null(rows)) rows[rows$stratum == strat, , drop = FALSE]
             else rows[0, , drop = FALSE]
    n_read <- if (is.null(rr)) 0L else nrow(rr)
    if (is.null(rr) || n_read == 0L) {
      n_succ <- 0L; n_fail <- 0L
    } else {
      ok_dir <- succ_col %in% names(rr) &
                !is.na(rr[[succ_col]]) &
                rr[[succ_col]] %in% c("effect", "no_effect")
      n_succ <- sum(ok_dir)
      n_fail <- n_read - n_succ
    }
    n_unread <- if (isTRUE(fr$file_exists) && !isTRUE(fr$readable)) 1L else 0L
    mt <- if (isTRUE(fr$file_exists))
      format(file.info(fr$sidecar_path)$mtime, "%Y-%m-%dT%H:%M:%S")
      else NA_character_
    idnote <- ""
    if (n_read > 0L) {
      mm <- c()
      for (k in names(.SIM_FIT_IDENTITY))
        if (k %in% names(rr) && any(rr[[k]] != .SIM_FIT_IDENTITY[[k]]))
          mm <- c(mm, k)
      if (length(mm)) idnote <- paste0("identity mismatch: ",
                                       paste(mm, collapse = ","))
    }
    n_gen <- inv$per_cell$n_generated[i]
    n_lat <- inv$per_cell$n_latent[i]
    tg    <- tgt$per_target[i]
    cell_target_known <- !is.na(tg) && tg > 0L
    cell_status <-
      if (n_read == 0L)                "not_started"
      else if (!cell_target_known)     "observed"
      else if (n_read < as.integer(tg)) "partial"
      else                              "complete"
    data.frame(
      cell_slug             = design$cell_slug[i],
      synthetic_stratum     = strat,
      legacy_cell_code      = design$legacy_cell_code[i],
      effect_band           = design$eff_band[i],
      heterogeneity_band    = design$het_band[i],
      bias_band             = design$bias_band[i],
      n_generated           = as.integer(n_gen),
      n_latent              = as.integer(n_lat),
      n_fit                 = as.integer(n_read),
      n_target              = if (is.na(tg)) NA_integer_ else as.integer(tg),
      fit_fraction          = if (is.na(tg) || tg <= 0L) NA_real_
                              else round(n_read / as.integer(tg), 4),
      n_missing             = if (is.na(tg)) NA_integer_
                              else max(0L, as.integer(tg) - n_read),
      n_success             = n_succ,
      n_failed              = n_fail,
      n_readable_sidecars   = n_read,
      n_unreadable_sidecars = n_unread,
      cell_status           = cell_status,
      last_modified_max     = mt,
      notes                 = paste(c(fr$note, idnote)[
                               nzchar(c(fr$note, idnote))], collapse = "; "),
      stringsAsFactors      = FALSE)
  }))

  coll <- sim_detect_fit_collision(rows = rows, design = design)
  integrity_flag <- if (isTRUE(coll$collision)) "FAIL_collision"
                    else if (isTRUE(coll$checked)) "ok"
                    else "insufficient_data"

  n_gen_total <- as.integer(inv$overall$n_generated_total)
  read_total  <- sum(cell$n_fit)
  fail_total  <- sum(cell$n_failed)
  unr_total   <- sum(cell$n_unreadable_sidecars)
  target_total <- if (all(is.na(cell$n_target))) NA_integer_
                  else as.integer(sum(cell$n_target, na.rm = TRUE))
  per_cell_min <- as.integer(min(cell$n_fit))

  target_known <- !any(is.na(cell$n_target)) &&
                  all(cell$n_target > 0L)
  lib_status <-
    if (read_total == 0L && n_gen_total == 0L) "not_started"
    else if (read_total == 0L)                 "generated_no_fits"
    else if (!target_known)                    "observed"
    else if (any(cell$n_fit < cell$n_target))  "partial"
    else if (fail_total > 0L || unr_total > 0L) "complete_with_failures"
    else                                       "complete_clean"

  pct_overall <- if (is.na(target_total) || target_total <= 0L) NA_real_
                 else round(100 * read_total / target_total, 1)

  overall <- data.frame(
    expected_source         = tgt$expected_source,
    expected_note           = tgt$expected_note,
    n_generated_total       = n_gen_total,
    n_fit_total             = as.integer(read_total),
    generated_reps_min      = as.integer(inv$overall$generated_reps_min),
    generated_reps_max      = as.integer(inv$overall$generated_reps_max),
    generated_reps_uniform  = inv$overall$generated_reps_uniform,
    target_total            = target_total,
    sidecars_observed_total = as.integer(sum(cell$n_readable_sidecars) +
                                          sum(cell$n_unreadable_sidecars)),
    readable_sidecars_total = as.integer(read_total),
    success_total           = as.integer(sum(cell$n_success)),
    failed_total            = as.integer(fail_total),
    unreadable_total        = as.integer(unr_total),
    missing_total           = if (is.na(target_total)) NA_integer_
                              else as.integer(sum(cell$n_missing, na.rm = TRUE)),
    fit_fraction            = inv$overall$fit_fraction,
    pct_complete            = pct_overall,
    scan_time               = scan_time,
    library_status          = lib_status,
    leak_flag               = if (length(leak)) paste(leak, collapse = " | ")
                              else "none",
    integrity_flag          = integrity_flag,
    integrity_note          = coll$note,
    integrity_frac_collided = coll$frac_collided,
    stringsAsFactors        = FALSE)

  list(cell = cell, overall = overall,
       identity_ok = length(leak) == 0L, leak = leak,
       collision = coll, inventory = inv, expected = tgt)
}

#' Hard guard against the Pass-4A all-strata fitting bug.
#'
#' Compact v3 stems (`repNNNN`) are NOT unique across strata, and
#' load_datasets() assigns datasets to R objects by bare stem. Fitting
#' must therefore be STRATUM-SCOPED: a single batch_fit() call must load
#' exactly one synthetic stratum so the `repNNNN` objects are locally
#' unique. Calling batch_fit(source_article = "sim2026") with no stratum
#' loads all 36 strata at once, collides every `repK` object, and fits
#' the wrong data for ~all datasets.
#'
#' Call this immediately before every simulation batch_fit(). It stop()s
#' on an unscoped/all-strata call. Define-only; no side effects.
#'
#' @param stratum The stratum being fitted (must be a non-empty scalar).
#' @param source_article Optional; if it is the library-wide "sim2026"
#'   it must be paired with a concrete stratum.
sim_assert_stratum_scoped_fit <- function(stratum = NULL,
                                          source_article = NULL) {
  bad <- is.null(stratum) || length(stratum) != 1L ||
         is.na(stratum) || !nzchar(as.character(stratum))
  if (bad) {
    stop("UNSAFE simulation fit: batch_fit() must be STRATUM-SCOPED. ",
         "Compact repNNNN stems are not unique across strata, so an ",
         "all-strata call (e.g. batch_fit(source_article = \"sim2026\") ",
         "with no stratum) collides every repK R object via ",
         "load_datasets() and fits the wrong data. Loop one stratum at ",
         "a time: for (st in sim_load_design()$stratum) ",
         "batch_fit(stratum = st, source_article = \"sim2026\", ",
         "resume = TRUE).", call. = FALSE)
  }
  if (!is.null(source_article) && length(source_article) == 1L &&
      identical(as.character(source_article), "sim2026") &&
      bad) {
    stop("UNSAFE: source_article = \"sim2026\" without a stratum.",
         call. = FALSE)
  }
  invisible(TRUE)
}

#' Detect the cross-stratum object-name collision corruption.
#'
#' Read-only. Returns a verdict + the offending replicate indices.
sim_detect_fit_collision <- function(rows = NULL,
                                      output_root = .SIM_DEFAULT_OUTPUT_ROOT,
                                      design = NULL) {
  if (is.null(rows)) {
    if (is.null(design)) design <- sim_load_design()
    rows <- sim_read_sidecars_safely(output_root, design)$rows
  }
  base <- list(checked = FALSE, collision = NA, n_groups = 0L,
               n_collided = 0L, frac_collided = NA_real_,
               examples = character(0),
               note = "insufficient data (need >=2 strata sharing a replicate)")
  if (is.null(rows) || !all(c("outcome_slug","stratum","n_studies")
                            %in% names(rows)))
    return(base)
  rows$n_studies <- suppressWarnings(as.integer(rows$n_studies))
  groups <- split(rows, rows$outcome_slug)
  n_grp <- 0L; n_col <- 0L; ex <- character(0)
  for (g in names(groups)) {
    sub <- groups[[g]]
    nst <- length(unique(sub$stratum))
    if (nst < 2L) next
    n_grp <- n_grp + 1L
    if (length(unique(sub$n_studies[!is.na(sub$n_studies)])) == 1L) {
      n_col <- n_col + 1L
      if (length(ex) < 3L)
        ex <- c(ex, sprintf("%s: %d strata all n_studies=%s", g, nst,
                            unique(sub$n_studies)[1]))
    }
  }
  if (n_grp == 0L) return(base)
  frac <- n_col / n_grp
  list(checked = TRUE,
       collision = frac >= 0.5,
       n_groups = n_grp, n_collided = n_col,
       frac_collided = round(frac, 4),
       examples = ex,
       note = if (frac >= 0.5)
         paste0("CORRUPTION: fitted n_studies is identical across strata ",
                "for ", n_col, "/", n_grp, " shared replicate indices ",
                "(load_datasets object-name collision on compact stems).")
         else "ok: fitted n_studies varies across strata as expected")
}

#' Persist the progress tables. Writes ONLY to simulation/results.
#'
#' Stable filenames (no replicate-count or tier suffix):
#'   fit_progress_live.csv      (per-cell)
#'   fit_progress_overall.csv   (overall)
#' All counts needed to interpret completeness (n_generated, n_fit,
#' n_target, fit_fraction, library_status, expected_source) are carried
#' inside the rows themselves.
sim_write_fit_progress <- function(progress     = NULL,
                                   results_dir  = "simulation/results",
                                   output_root  = .SIM_DEFAULT_OUTPUT_ROOT,
                                   vintage      = .SIM_DEFAULT_VINTAGE,
                                   expected_per_cell = NULL,
                                   data_root    = "data",
                                   latent_root  = "simulation/latent") {
  if (is.null(progress))
    progress <- sim_scan_fit_progress(output_root = output_root,
                                      vintage = vintage,
                                      expected_per_cell = expected_per_cell,
                                      data_root = data_root,
                                      latent_root = latent_root)
  if (!dir.exists(results_dir))
    dir.create(results_dir, recursive = TRUE)
  live_csv <- file.path(results_dir, "fit_progress_live.csv")
  ovr_csv  <- file.path(results_dir, "fit_progress_overall.csv")
  utils::write.csv(progress$cell,    live_csv, row.names = FALSE)
  utils::write.csv(progress$overall, ovr_csv,  row.names = FALSE)
  invisible(list(live = live_csv, overall = ovr_csv,
                 progress = progress))
}

#' Generation-library structural checker. Read-only; never regenerates.
#'
#' Confirms each stratum has at least one generated CSV and that every
#' generated CSV has a matching latent file. Per-cell `complete` flags
#' check that n_latent == n_csv and n_csv > 0. Optional `expected_per_cell`
#' adds an additional minimum-per-cell check (n_csv >= expected_per_cell).
sim_check_generation_library <- function(data_root        = "data",
                                         latent_root      = "simulation/latent",
                                         vintage          = .SIM_DEFAULT_VINTAGE,
                                         expected_per_cell = NULL,
                                         design           = NULL) {
  if (is.null(design)) design <- sim_load_design()
  inv <- sim_inventory_library(data_root = data_root,
                               latent_root = latent_root,
                               vintage = vintage,
                               design = design)
  exp_pc <- if (!is.null(expected_per_cell))
    suppressWarnings(as.integer(expected_per_cell)) else NA_integer_
  src <- sim_source_tag(vintage)
  rep_rx <- "^rep[0-9]{4}$"
  per <- do.call(rbind, lapply(seq_len(nrow(design)), function(i) {
    strat   <- design$stratum[i]
    cdir    <- file.path(data_root,   strat, src)
    csvs <- if (dir.exists(cdir))
      list.files(cdir, pattern = "\\.csv$") else character(0)
    stems <- tools::file_path_sans_ext(csvs)
    n_csv <- inv$per_cell$n_generated[i]
    n_lat <- inv$per_cell$n_latent[i]
    complete_flag <- n_csv > 0L && n_lat == n_csv &&
      (is.na(exp_pc) || n_csv >= exp_pc)
    data.frame(
      cell_slug         = design$cell_slug[i],
      synthetic_stratum = strat,
      n_csv             = as.integer(n_csv),
      n_latent          = as.integer(n_lat),
      stems_ok          = length(csvs) > 0 &&
                           all(grepl(rep_rx, stems)),
      complete          = complete_flag,
      stringsAsFactors  = FALSE)
  }))
  legacy_dirs <- list.dirs(data_root, recursive = FALSE)
  legacy_hit  <- grep("sim_e[0-9]_h[0-9]_b[0-9]", basename(legacy_dirs),
                       value = TRUE)
  res <- list(
    per_cell               = per,
    n_strata               = sum(per$n_csv > 0),
    n_csv_total            = sum(per$n_csv),
    n_latent_total         = sum(per$n_latent),
    generated_reps_min     = inv$overall$generated_reps_min,
    generated_reps_max     = inv$overall$generated_reps_max,
    generated_reps_uniform = inv$overall$generated_reps_uniform,
    all_complete           = all(per$complete),
    all_stems_ok           = all(per$stems_ok),
    legacy_code_dirs       = legacy_hit,
    expected_per_cell      = if (is.na(exp_pc)) NA_integer_ else exp_pc)
  res$ok <- isTRUE(res$all_complete) && res$all_stems_ok &&
            length(legacy_hit) == 0L &&
            res$n_csv_total > 0L
  res
}
