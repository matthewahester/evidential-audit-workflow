# 40_batch_fit.R
# ------------------------------------------------------------------------------
# Batch orchestration: fit/resume/backfill/accept a whole stratum (RoBMA 4.0).
#
# batch_fit() wraps fit_robma_models() (20_robma_fit.R) with plan-then-execute,
# contract-aware resume, dry-run planning, optional dataset-level parallelism,
# subprocess isolation, backfill, and a strict sidecar-acceptance gate. The
# vocabulary is stratum / source_article / outcome_slug throughout; there is
# no `topic=` argument.
#
# Resume is contract-aware: a dataset is skipped only when both RoBMA 4.0 fit
# artifacts exist AND a sidecar row matches dataset_id, RoBMA major version
# >= .ROBMA_MAJOR_MIN, the current schema_version / estimand_version, and the
# current config_hash. Archived RoBMA 3.6.x artifacts, old effect-only-rigor
# sidecars, pilot scratch rows, and incompatible-config rows therefore never
# satisfy resume.
#
# Subprocess isolation (use_subprocess = TRUE, default): each fit runs in a
# short-lived callr::r() subprocess so PSOCK sockets leaked by RoBMA/runjags
# cannot exhaust R's 128-connection limit on long batches (~1-2s overhead).
# Concurrency (parallel = TRUE or concurrent_workers > 1) uses a callr::r_bg()
# worker pool; on a 12-thread CPU the sweet spot is 2 workers with chains = 6.
#
# All MCMC / measure / output settings are read from CONFIG (20_robma_fit.R)
# and forwarded to each subprocess. A single failing dataset never aborts the
# batch (recorded status = "error" with message + timing).
#
# Define-only: sourcing installs functions; callr is checked only at call time.
#
# Quick-Start
#   source("scripts/00_utils.R"); source("scripts/10_load_data.R")
#   source("scripts/20_robma_fit.R"); source("scripts/40_batch_fit.R")
#   batch_fit(stratum = "fiber", dry_run = TRUE)          # plan only
#   run <- batch_fit(stratum = "fiber", resume = FALSE)   # fit
#   backfill_sidecars(stratum = "fiber")                  # rebuild from RDS
#   sidecar_acceptance(stratum = "fiber")                 # gate
# ------------------------------------------------------------------------------


# ---- Shared utilities ------------------------------------------------------
# Provides %||%, is_meta_basename(), the v4 contract, and shared helpers.
# Sentinel-guarded.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# ---- Subprocess support ----------------------------------------------------
# callr lets each fit run in a short-lived R subprocess (use_subprocess =
# TRUE, the default). G7: sourcing this file installs NOTHING. The callr
# requirement is checked inside batch_fit() only when it is actually needed,
# and the user is asked to install it manually (or pass use_subprocess=FALSE).
.require_callr_or_stop <- function() {
  if (!requireNamespace("callr", quietly = TRUE)) {
    stop("batch_fit(use_subprocess=TRUE) needs the 'callr' package, which is ",
         "not installed. Either install it manually:\n",
         "  install.packages(\"callr\")\n",
         "or call batch_fit(..., use_subprocess = FALSE).", call. = FALSE)
  }
}


# ==== HELPERS ===============================================================

# RoBMA 4.0 fit-artifact prefixes considered authoritative for resume.
# (Archived 3.6.x names fit_RE_ / fit_RoBMA_ are deliberately excluded so a
# stale 3.6 world can never satisfy a 4.0 run.)
.V4_FIT_RE_PREFIX    <- "fit_RE4_"
.V4_FIT_ROBMA_PREFIX <- "fit_RoBMA4_"

# Read a CONFIG value with a safe fallback when 20_robma_fit.R has not been
# sourced yet.
.cfg <- function(key, default) {
  if (exists("CONFIG", envir = .GlobalEnv)) {
    get("CONFIG", envir = .GlobalEnv)[[key]] %||% default
  } else default
}

# output/<stratum>/<source_article>/ (+ /<outcome> when nest_by_outcome).
# Mirrors .paths_for() in 20_robma_fit.R (norm_slug, not bare tolower).
.out_dir_for <- function(stratum, source_article, dataset_stem) {
  output_root <- .cfg("output_root", "output")
  d <- file.path(output_root, norm_slug(stratum), norm_slug(source_article))
  if (isTRUE(.cfg("nest_by_outcome", FALSE)))
    d <- file.path(d, norm_slug(.outcome_slug_from_stem(dataset_stem)))
  d
}

# Version-aware artifact check: TRUE only when BOTH RoBMA 4.0 fit artifacts
# (fit_RE4_* and fit_RoBMA4_*) exist for the dataset. The distinguishing tail
# is the "repNNNN" slug for sim datasets or the full stem otherwise; within
# one (stratum, source_article) dir that tail is unique.
artifacts_exist_v4 <- function(dataset_stem, stratum, source_article) {
  out_dir <- .out_dir_for(stratum, source_article, dataset_stem)
  if (!dir.exists(out_dir)) return(FALSE)

  rep_match  <- regmatches(dataset_stem, regexpr("rep\\d+$", dataset_stem))
  tail_token <- if (length(rep_match) > 0) rep_match else dataset_stem

  pat_RE    <- sprintf("^%s.*%s\\.rds$", .V4_FIT_RE_PREFIX,    tail_token)
  pat_RoBMA <- sprintf("^%s.*%s\\.rds$", .V4_FIT_ROBMA_PREFIX, tail_token)

  length(list.files(out_dir, pattern = pat_RE))    > 0 &&
  length(list.files(out_dir, pattern = pat_RoBMA)) > 0
}

# Parse the leading integer (major version) from a package-version string,
# e.g. "4.0.0" -> 4L, "3.6.1" -> 3L. Vectorized and length-preserving; NA
# where the string does not start with digits.
.major_version <- function(v) {
  v   <- as.character(v)
  out <- suppressWarnings(as.integer(sub("^([0-9]+).*$", "\\1", v)))
  out[is.na(v) | !grepl("^[0-9]", v)] <- NA_integer_
  out
}

# Stale-artifact rejection: a sidecar row only counts toward resume when ALL
# hold:
#   * dataset_id matches EXACTLY (a pre-v4 sidecar's `basename` column is also
#     accepted only so such rows can be found and then rejected below),
#   * robma_version is non-empty AND its MAJOR version is >= .ROBMA_MAJOR_MIN
#     (archived RoBMA 3.6.x rows can never satisfy a 4.0 run),
#   * schema_version == .SCHEMA_VERSION and estimand_version ==
#     .ESTIMAND_VERSION when those columns exist; if BOTH are ABSENT the row
#     predates the v4 contract (e.g. an old effect-only-rigor sidecar) and is
#     rejected as stale,
#   * config_hash == the current CONFIG hash (which folds in schema/estimand
#     versions), or, when no config_hash column exists, every raw config
#     field matches.
# This stops tiny acceptance-test rows, RoBMA 3.6.x artifacts, old
# effect-only-rigor sidecars, pilot scratch rows, and incompatible-config
# rows from silently satisfying resume.
.matching_v4_sidecar_row <- function(dataset_id, stratum) {
  output_root  <- .cfg("output_root", "output")
  stratum_slug <- norm_slug(stratum)
  csv <- file.path(output_root, stratum_slug,
                    sprintf("%s_robma_summary.csv", stratum_slug))
  if (!file.exists(csv)) return(FALSE)
  df <- tryCatch(read.csv(csv, stringsAsFactors = FALSE, check.names = FALSE),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0L) return(FALSE)

  id_col <- if ("dataset_id" %in% names(df)) "dataset_id"
            else if ("basename" %in% names(df)) "basename" else NULL
  if (is.null(id_col) || !"robma_version" %in% names(df)) return(FALSE)

  hit <- df[df[[id_col]] == dataset_id, , drop = FALSE]
  if (nrow(hit) == 0L) return(FALSE)

  # RoBMA version present AND major-version compatible.
  ver_ok <- any(nzchar(as.character(hit$robma_version)) &
                !is.na(hit$robma_version) &
                !is.na(.major_version(hit$robma_version)) &
                .major_version(hit$robma_version) >= .ROBMA_MAJOR_MIN)
  if (!ver_ok) return(FALSE)

  # Schema/estimand contract gate. A current v4 row ALWAYS carries both
  # columns; a sidecar lacking BOTH predates the contract and is stale.
  has_schema   <- "schema_version"   %in% names(hit)
  has_estimand <- "estimand_version" %in% names(hit)
  if (!has_schema && !has_estimand) return(FALSE)
  schema_ok <- !has_schema ||
    any(as.character(hit$schema_version) == .SCHEMA_VERSION)
  estimand_ok <- !has_estimand ||
    any(as.character(hit$estimand_version) == .ESTIMAND_VERSION)
  if (!schema_ok || !estimand_ok) return(FALSE)
  # Restrict to rows that actually match the contract before the hash gate.
  if (has_schema)
    hit <- hit[as.character(hit$schema_version) == .SCHEMA_VERSION, ,
               drop = FALSE]
  if (has_estimand && nrow(hit) > 0L)
    hit <- hit[as.character(hit$estimand_version) == .ESTIMAND_VERSION, ,
               drop = FALSE]
  if (nrow(hit) == 0L) return(FALSE)

  # config_hash gate. .config_hash() is provided by 20_robma_fit.R; if the
  # sidecar predates config_hash, fall back to comparing the raw fields.
  cur_hash <- if (exists(".config_hash")) .config_hash() else NA_character_
  if ("config_hash" %in% names(hit) && !is.na(cur_hash)) {
    return(any(as.character(hit$config_hash) == cur_hash))
  }
  fields <- c("measure", "model_type", "effect_direction",
              "sample", "burnin", "adapt", "chains", "thin", "seed",
              "robma_version", "bayestools_version")
  if (!all(fields %in% names(hit)) || !exists("CONFIG", envir = .GlobalEnv))
    return(FALSE)
  cur <- get("CONFIG", envir = .GlobalEnv)
  want <- c(cur$measure, cur$model_type, cur$effect_direction,
            cur$sample, cur$burnin, cur$adapt, cur$chains, cur$thin, cur$seed,
            as.character(utils::packageVersion("RoBMA")),
            as.character(utils::packageVersion("BayesTools")))
  any(apply(hit[, fields, drop = FALSE], 1L, function(r)
    all(as.character(r) == as.character(want))))
}

# Strict resume gate. Default (resume_from_sidecar_only = FALSE): skip ONLY
# when BOTH the v4 fit artifacts exist AND a config-matched v4 sidecar row
# exists. resume_from_sidecar_only = TRUE relaxes to a config-matched sidecar
# row alone (artifacts may have been pruned).
is_resume_satisfied <- function(dataset_stem, dataset_id, stratum,
                                source_article,
                                resume_from_sidecar_only = FALSE) {
  row_ok <- .matching_v4_sidecar_row(dataset_id, stratum)
  if (isTRUE(resume_from_sidecar_only)) return(row_ok)
  artifacts_exist_v4(dataset_stem, stratum, source_article) && row_ok
}

# Truncate a value to a printable string for status messages.
safe_first <- function(x, default = "") {
  if (is.null(x) || length(x) == 0) return(default)
  substr(as.character(x[1]), 1, 200)
}


# ==== PLANNING ==============================================================

# Candidate dataset list: the v4 catalog filtered by stratum / source_article
# / file, plus a sanitized `object_name` matching what load_datasets()
# assigns. stratum / source_article / outcome_slug / dataset_id already come
# from the catalog identity parser (10_load_data.R).
plan_from_data <- function(stratum = NULL, source_article = NULL,
                           file = NULL) {
  ci <- function(x, v) tolower(x) == tolower(v)
  filtered <- list_datasets()

  if (!is.null(stratum))
    filtered <- filtered[ci(filtered$path_stratum, stratum) |
                         ci(filtered$stratum, stratum), , drop = FALSE]
  if (!is.null(source_article))
    filtered <- filtered[ci(filtered$path_article, source_article) |
                         ci(filtered$source_article, source_article), ,
                         drop = FALSE]
  if (!is.null(file)) {
    if (grepl("\\.csv$", file, ignore.case = TRUE)) {
      filtered <- filtered[ci(filtered$dataset_file, file), , drop = FALSE]
    } else {
      filtered <- filtered[ci(filtered$dataset_stem, file), , drop = FALSE]
    }
  }

  filtered$object_name <- if (nrow(filtered) > 0)
    make.names(filtered$dataset_stem) else character(0)
  filtered
}


# ==== VALIDATORS ============================================================

# TRUE if `obj_name` exists in `envir`, is a non-empty data.frame, and carries
# a complete effect-size input pair: g/se_g (preferred/default) or d/se_d
# (fallback). The accepted set is the shared .has_effect_input() (00_utils.R)
# so this runnable filter cannot drift from the fitter's resolver.
has_required_cols <- function(obj_name, envir = .GlobalEnv) {
  if (!exists(obj_name, envir = envir)) return(FALSE)
  .has_effect_input(get(obj_name, envir = envir))
}


# ==== BATCH FITTING =========================================================

batch_fit <- function(stratum = NULL, source_article = NULL, file = NULL,
                      resume = TRUE, dry_run = FALSE, parallel = FALSE,
                      verbose = TRUE,
                      resume_from_sidecar_only = FALSE,
                      study_col = NULL,
                      use_subprocess = TRUE,
                      scripts_dir = "scripts",
                      concurrent_workers = 1L,
                      poll_interval = 0.3) {
  # Fit fit_robma_models() across many datasets with contract-aware resume.
  # All MCMC settings are read from CONFIG.
  #
  # Args:
  #   stratum, source_article, file  Catalog filters (see plan_from_data()).
  #   resume               Skip datasets already done. STRICT by default:
  #                         needs BOTH v4 fit artifacts AND a contract-matched
  #                         v4 sidecar row (3.6 artifacts / different CONFIG /
  #                         stale schema or estimand version never count).
  #   resume_from_sidecar_only  TRUE: a contract-matched sidecar row alone
  #                         satisfies resume (artifacts may be pruned).
  #   dry_run              List the plan without fitting anything.
  #   parallel             TRUE -> subprocess worker pool (defaults
  #                         concurrent_workers to 2 if still 1).
  #   verbose              Print per-dataset progress lines.
  #   study_col            Optional column forwarded as the RoBMA4 `cluster`.
  #   use_subprocess       If TRUE (default) each fit runs in an isolated callr
  #                         subprocess. Required when running > 1 worker.
  #   scripts_dir          Where 00/20 live (sourced by subprocesses).
  #   concurrent_workers   Number of parallel subprocess fits. Default 1.
  #   poll_interval        Seconds between worker-pool polls.
  #
  # Returns invisibly: list(status = data.frame(dataset_stem, stratum,
  #   source_article, status, message, elapsed_sec, out_dir),
  #   summary = table(status), ran = character()).

  # `parallel = TRUE` is the friendly switch; map onto the worker pool.
  concurrent_workers <- as.integer(concurrent_workers)
  if (is.na(concurrent_workers) || concurrent_workers < 1L)
    stop("concurrent_workers must be a positive integer")
  if (isTRUE(parallel) && concurrent_workers == 1L) concurrent_workers <- 2L
  if (concurrent_workers > 1L && !use_subprocess) {
    warning("concurrent fits require use_subprocess = TRUE; forcing TRUE")
    use_subprocess <- TRUE
  }

  plan <- plan_from_data(stratum = stratum, source_article = source_article,
                         file = file)
  if (nrow(plan) == 0) {
    strata <- unique(list_datasets()$stratum)
    if (length(strata) > 10) strata <- c(strata[1:10], "...")
    stop("No datasets match filters. Available strata: ",
         paste(strata, collapse = ", "))
  }

  # Load data into the global environment unless dry-running.
  if (!dry_run)
    load_datasets(stratum = stratum, source_article = source_article,
                  file = file)

  # Identify runnable datasets (skip meta files and any without a complete
  # g/se_g or d/se_d effect-size pair).
  plan$should_run <- vapply(plan$object_name, function(bn) {
    !is_meta_basename(bn) && (dry_run || has_required_cols(bn))
  }, logical(1))

  if (verbose) {
    cat(sprintf(
      "\nValidated %d datasets: %d runnable, %d skipped (no g/se_g | d/se_d, or meta)\n",
      nrow(plan), sum(plan$should_run), sum(!plan$should_run)))
  }

  # ---- Subprocess prep ----
  scripts_dir_abs <- parent_config <- parent_wd <- NULL
  if (use_subprocess && !dry_run) {
    .require_callr_or_stop()   # G7: checked here, never installed at source
    scripts_dir_abs <- normalizePath(scripts_dir, mustWork = TRUE)
    utils_path <- file.path(scripts_dir_abs, "00_utils.R")
    fit_path   <- file.path(scripts_dir_abs, "20_robma_fit.R")
    if (!file.exists(utils_path) || !file.exists(fit_path)) {
      stop(sprintf("scripts_dir '%s' is missing 00_utils.R or 20_robma_fit.R",
                   scripts_dir_abs))
    }
    parent_config <- if (exists("CONFIG", envir = .GlobalEnv))
      get("CONFIG", envir = .GlobalEnv) else NULL
    parent_wd <- getwd()
  }

  # Closure run inside callr::r() (sync) and callr::r_bg() (pool). Re-sources
  # helpers, overrides CONFIG with the parent snapshot, then dispatches to
  # fit_robma_models which writes RDS + audit tables + sidecar to disk.
  subprocess_body <- function(fit_args, scripts_dir, parent_config, parent_wd) {
    setwd(parent_wd)
    source(file.path(scripts_dir, "00_utils.R"))
    source(file.path(scripts_dir, "20_robma_fit.R"))
    if (!is.null(parent_config))
      assign("CONFIG", parent_config, envir = .GlobalEnv)
    do.call(fit_robma_models, fit_args)
  }

  # ---- Stage 1: classify each plan row ------------------------------------
  prepare_one <- function(i) {
    row    <- plan[i, ]
    stem   <- row$object_name
    out_dir <- .out_dir_for(row$path_stratum, row$path_article, stem)

    skip_result <- function(msg) list(kind = "result", value = list(
      dataset_stem = stem, stratum = row$path_stratum,
      source_article = row$path_article, status = "skipped",
      message = msg, elapsed_sec = 0, out_dir = out_dir))

    if (!isTRUE(row$should_run)) {
      if (verbose) cat(sprintf("[%d/%d] SKIP %s (no g/se_g | d/se_d, or meta)\n",
                               i, nrow(plan), stem))
      return(skip_result("no g/se_g or d/se_d, or meta file"))
    }
    # dry_run is a pure planning preview: it takes precedence over resume so
    # the plan always reflects the full set of fittable datasets, regardless
    # of which already have v4 artifacts.
    if (dry_run) {
      if (verbose) cat(sprintf("[%d/%d] DRY  %s\n", i, nrow(plan), stem))
      return(skip_result("dry run"))
    }
    if (resume && is_resume_satisfied(stem, row$dataset_id, row$path_stratum,
                                      row$path_article,
                                      resume_from_sidecar_only)) {
      if (verbose) cat(sprintf(
        "[%d/%d] SKIP %s (contract-matched v4 %s)\n", i, nrow(plan), stem,
        if (resume_from_sidecar_only) "sidecar row" else "artifacts + sidecar"))
      return(skip_result("contract-matched v4 artifacts/sidecar exist"))
    }

    data_obj <- get(stem, envir = .GlobalEnv)
    # row$path_stratum / row$path_article are the physical folders;
    # row$outcome_slug is the parsed outcome (NOT the mu+ effect component).
    fit_args <- list(data = data_obj, dataset_name = stem,
                     stratum = row$path_stratum,
                     source_article = row$path_article,
                     outcome_slug = row$outcome_slug)
    if (!is.null(study_col)) fit_args$study_col <- study_col

    list(kind = "job", spec = list(
      dataset_stem = stem, stratum = row$path_stratum,
      source_article = row$path_article,
      out_dir = out_dir, fit_args = fit_args))
  }

  # ---- Stage 2a: synchronous executor (concurrent_workers = 1) ------------
  execute_sync <- function(spec, i, total) {
    if (verbose) cat(sprintf("[%d/%d] RUN  %s", i, total, spec$dataset_stem))
    t0 <- Sys.time()
    result <- tryCatch({
      if (use_subprocess) {
        callr::r(func = subprocess_body,
                 args = list(fit_args = spec$fit_args,
                             scripts_dir = scripts_dir_abs,
                             parent_config = parent_config,
                             parent_wd = parent_wd),
                 show = TRUE, spinner = FALSE,
                 user_profile = FALSE, system_profile = FALSE) -> res
      } else {
        res <- do.call(fit_robma_models, spec$fit_args)
      }
      list(dataset_stem = spec$dataset_stem, stratum = spec$stratum,
           source_article = spec$source_article,
           status = "ran", message = "success",
           elapsed_sec = as.numeric(Sys.time() - t0, units = "secs"),
           out_dir = res$out_dir %||% spec$out_dir)
    }, error = function(e) {
      list(dataset_stem = spec$dataset_stem, stratum = spec$stratum,
           source_article = spec$source_article,
           status = "error", message = safe_first(conditionMessage(e)),
           elapsed_sec = as.numeric(Sys.time() - t0, units = "secs"),
           out_dir = spec$out_dir)
    })
    if (verbose) cat(sprintf(" [%.1fs] %s\n", result$elapsed_sec, result$status))
    result
  }

  # ---- Stage 2b: concurrent worker pool (concurrent_workers > 1) ----------
  execute_pool <- function(specs, orig_indices, total) {
    n_jobs <- length(specs)
    out <- vector("list", n_jobs); names(out) <- as.character(orig_indices)
    active <- list(); next_ptr <- 1L

    while (next_ptr <= n_jobs || length(active) > 0L) {
      while (length(active) < concurrent_workers && next_ptr <= n_jobs) {
        spec     <- specs[[next_ptr]]
        orig_idx <- orig_indices[next_ptr]
        stdout_f <- tempfile(fileext = ".log")
        stderr_f <- tempfile(fileext = ".log")
        proc <- callr::r_bg(
          func = subprocess_body,
          args = list(fit_args = spec$fit_args, scripts_dir = scripts_dir_abs,
                      parent_config = parent_config, parent_wd = parent_wd),
          stdout = stdout_f, stderr = stderr_f, supervise = TRUE,
          user_profile = FALSE, system_profile = FALSE)
        key <- as.character(orig_idx)
        active[[key]] <- list(proc = proc, spec = spec, orig_idx = orig_idx,
                              t0 = Sys.time(), stdout_f = stdout_f,
                              stderr_f = stderr_f)
        if (verbose) cat(sprintf("[%d/%d] LAUNCH %s (%d/%d workers)\n",
                                 orig_idx, total, spec$dataset_stem,
                                 length(active), concurrent_workers))
        next_ptr <- next_ptr + 1L
      }

      Sys.sleep(poll_interval)
      finished <- character(0)
      for (key in names(active))
        if (!active[[key]]$proc$is_alive()) finished <- c(finished, key)

      for (key in finished) {
        slot    <- active[[key]]
        elapsed <- as.numeric(Sys.time() - slot$t0, units = "secs")
        res <- tryCatch(slot$proc$get_result(), error = function(e) e)

        if (inherits(res, "error") || inherits(res, "condition")) {
          tail_msg <- tryCatch({
            if (file.exists(slot$stderr_f) && file.size(slot$stderr_f) > 0)
              paste(tail(readLines(slot$stderr_f, warn = FALSE), 3),
                    collapse = " | ") else ""
          }, error = function(e) "")
          err_msg <- safe_first(conditionMessage(res))
          if (nzchar(tail_msg)) err_msg <- paste(err_msg, "::", tail_msg)
          out[[key]] <- list(dataset_stem = slot$spec$dataset_stem,
            stratum = slot$spec$stratum,
            source_article = slot$spec$source_article,
            status = "error", message = safe_first(err_msg),
            elapsed_sec = elapsed, out_dir = slot$spec$out_dir)
          if (verbose) cat(sprintf("[%d/%d] ERROR  %s [%.1fs] %s\n",
            slot$orig_idx, total, slot$spec$dataset_stem, elapsed,
            safe_first(err_msg)))
        } else {
          out[[key]] <- list(dataset_stem = slot$spec$dataset_stem,
            stratum = slot$spec$stratum,
            source_article = slot$spec$source_article,
            status = "ran", message = "success", elapsed_sec = elapsed,
            out_dir = res$out_dir %||% slot$spec$out_dir)
          if (verbose) cat(sprintf("[%d/%d] DONE   %s [%.1fs]\n",
            slot$orig_idx, total, slot$spec$dataset_stem, elapsed))
        }
        try(unlink(slot$stdout_f), silent = TRUE)
        try(unlink(slot$stderr_f), silent = TRUE)
        active[[key]] <- NULL
      }
    }
    out
  }

  # ---- Stage 3: classify, then dispatch -----------------------------------
  classified <- lapply(seq_len(nrow(plan)), prepare_one)

  results <- vector("list", nrow(plan))
  for (i in seq_along(classified))
    if (classified[[i]]$kind == "result")
      results[[i]] <- classified[[i]]$value

  job_idx <- which(vapply(classified, function(c) c$kind == "job", logical(1)))

  if (length(job_idx) > 0L) {
    job_specs <- lapply(job_idx, function(i) classified[[i]]$spec)
    if (concurrent_workers > 1L) {
      pool_results <- execute_pool(job_specs, job_idx, nrow(plan))
      for (i in job_idx) results[[i]] <- pool_results[[as.character(i)]]
    } else {
      for (k in seq_along(job_idx)) {
        i <- job_idx[k]
        results[[i]] <- execute_sync(job_specs[[k]], i, nrow(plan))
      }
    }
  }

  status <- do.call(rbind, lapply(results, function(r) data.frame(
    dataset_stem = r$dataset_stem, stratum = r$stratum,
    source_article = r$source_article,
    status = r$status, message = r$message, elapsed_sec = r$elapsed_sec,
    out_dir = r$out_dir, stringsAsFactors = FALSE)))

  summary_tbl <- table(status$status)
  ran_stems   <- status$dataset_stem[status$status == "ran"]

  # table[<absent name>] returns a *named NA*, not NULL, so %||% (NULL-only)
  # does not catch it. Coerce missing/NA counts to 0 explicitly.
  n_status <- function(nm) {
    v <- summary_tbl[nm]
    if (length(v) == 0L || is.na(v)) 0L else as.integer(v)
  }

  if (verbose) {
    cat("\n========== Batch Summary ==========\n")
    cat(sprintf("Ran: %d | Skipped: %d | Errors: %d\n",
                n_status("ran"), n_status("skipped"), n_status("error")))
    cat(sprintf("Total time: %.1fs\n", sum(status$elapsed_sec)))
    if (n_status("error") > 0) {
      cat("Errors (batch continued past these):\n")
      err <- status[status$status == "error",
                    c("dataset_stem", "message")]
      for (j in seq_len(nrow(err)))
        cat(sprintf("  - %s: %s\n", err$dataset_stem[j], err$message[j]))
    }
  }

  invisible(list(status = status, summary = summary_tbl, ran = ran_stems))
}


# ==== v4 SIDECAR BACKFILL ===================================================
# Rebuild output/<stratum>/<stratum>_robma_summary.csv (and the separate
# zplot-diagnostics artifact) from saved fit_RE4_*.rds / fit_RoBMA4_*.rds
# WITHOUT refitting -- use after a schema change. Each dataset is resolved to
# the same out_dir fit_robma_models() writes to; rows are rebuilt via the v4
# extractor so the registry anti-join in sidecar_acceptance() stays exact.
#
# Quick-Start
#   source("scripts/00_utils.R"); source("scripts/10_load_data.R")
#   source("scripts/20_robma_fit.R"); source("scripts/40_batch_fit.R")
#   res <- backfill_sidecars(stratum = "fiber"); res$summary
backfill_sidecars <- function(stratum = NULL, source_article = NULL,
                              file = NULL, verbose = TRUE) {
  required <- c(".build_sidecar_row_v4", ".append_sidecar_v4",
                ".append_zplot_diagnostics", ".paths_for", ".SIDECAR_V4_COLS",
                "extract_model_family_evidence", ".extract_zplot_diagnostics")
  if (!all(vapply(required, exists, logical(1)))) {
    for (.p in c("scripts/20_robma_fit.R", "20_robma_fit.R",
                 file.path("..", "scripts", "20_robma_fit.R"))) {
      if (file.exists(.p)) { source(.p); break }
    }
  }

  plan <- plan_from_data(stratum = stratum, source_article = source_article,
                         file = file)
  plan <- plan[!vapply(plan$object_name, is_meta_basename, logical(1)), ,
               drop = FALSE]
  if (nrow(plan) == 0) stop("No (non-meta) datasets match filters.")

  results <- vector("list", nrow(plan))

  for (i in seq_len(nrow(plan))) {
    row       <- plan[i, ]
    stem      <- row$object_name                  # on-disk stem
    outcome_s <- norm_slug(.outcome_slug_from_stem(stem))
    stratum_s <- norm_slug(row$path_stratum)
    article_s <- norm_slug(row$path_article)
    dataset_id_v <- sprintf("%s_%s_%s", article_s, stratum_s, outcome_s)

    paths    <- .paths_for(stratum_s, article_s, outcome_s)
    fit_RE_p <- file.path(paths$out_dir, paste0(.V4_FIT_RE_PREFIX,    stem, ".rds"))
    fit_BC_p <- file.path(paths$out_dir, paste0(.V4_FIT_ROBMA_PREFIX, stem, ".rds"))
    zp_BC_p  <- file.path(paths$out_dir, paste0("zplot_RoBMA4_",       stem, ".rds"))

    if (!file.exists(fit_RE_p) && !file.exists(fit_BC_p)) {
      if (verbose) cat(sprintf("[%d/%d] SKIP   %s (no v4 fit RDS)\n",
                               i, nrow(plan), stem))
      results[[i]] <- list(dataset_stem = stem, stratum = row$path_stratum,
        source_article = row$path_article, status = "skipped",
        message = "no v4 fits")
      next
    }

    fit_RE    <- if (file.exists(fit_RE_p)) tryCatch(readRDS(fit_RE_p),
                   error = function(e) NULL) else NULL
    fit_RoBMA <- if (file.exists(fit_BC_p)) tryCatch(readRDS(fit_BC_p),
                   error = function(e) NULL) else NULL
    zplot_BC  <- if (file.exists(zp_BC_p)) tryCatch(readRDS(zp_BC_p),
                   error = function(e) NULL) else NULL

    if (is.null(fit_RE) && is.null(fit_RoBMA)) {
      results[[i]] <- list(dataset_stem = stem, stratum = row$path_stratum,
        source_article = row$path_article, status = "error",
        message = "readRDS failed")
      next
    }

    # Recover n_studies from the fit's data slot (best effort).
    n_studies <- NA_integer_
    for (fit in list(fit_RoBMA, fit_RE)) {
      if (is.null(fit)) next
      yi <- tryCatch(fit$data$outcome$yi, error = function(e) NULL)
      if (is.numeric(yi) && length(yi) > 0L) { n_studies <- length(yi); break }
      d <- fit$data %||% fit$input$data
      if (is.data.frame(d) && nrow(d) > 0L) { n_studies <- nrow(d); break }
    }

    evidence <- if (!is.null(fit_RoBMA)) {
      tryCatch(extract_model_family_evidence(
        fit_RoBMA, audit_dir = paths$audit_dir, stem = stem,
        verbose = verbose),
        error = function(e) list(uncertain = TRUE))
    } else list(uncertain = TRUE)

    zdiag <- .extract_zplot_diagnostics(zp = zplot_BC, fit = fit_RoBMA,
                                        verbose = FALSE)

    meta <- list(corpus_id      = .cfg("corpus_id", "nutrition_v4"),
                 scheme         = .cfg("scheme", "nutrition_domain"),
                 stratum        = stratum_s,
                 dataset_id     = dataset_id_v,
                 source_article = article_s,
                 outcome_slug   = outcome_s,
                 path_stratum   = stratum_s)
    new_row <- tryCatch(
      .build_sidecar_row_v4(fit_RE, fit_RoBMA, n_studies, meta,
                            evidence = evidence),
      error = function(e) {
        message(sprintf("  [%s] .build_sidecar_row_v4 failed: %s",
                        stem, conditionMessage(e))); NULL })
    if (is.null(new_row)) {
      results[[i]] <- list(dataset_stem = stem, stratum = row$path_stratum,
        source_article = row$path_article, status = "error",
        message = "build row failed")
      next
    }

    .append_sidecar_v4(new_row, paths$sidecar_csv)
    .append_zplot_diagnostics(dataset_id_v, new_row$analysis_id, stratum_s,
                              zdiag, paths$zplot_csv)
    if (verbose) cat(sprintf("[%d/%d] WROTE  %s (uncertain=%s)\n",
      i, nrow(plan), stem, isTRUE(evidence$uncertain)))
    results[[i]] <- list(dataset_stem = stem, stratum = row$path_stratum,
      source_article = row$path_article, status = "ok",
      message = "rewrote v4 sidecar row")
  }

  status <- do.call(rbind, lapply(results, function(r) data.frame(
    dataset_stem = r$dataset_stem, stratum = r$stratum,
    source_article = r$source_article,
    status = r$status, message = r$message, stringsAsFactors = FALSE)))

  if (verbose) {
    cat("\n========== Backfill Summary ==========\n")
    cat(sprintf("Wrote: %d | Skipped: %d | Errors: %d\n",
                sum(status$status == "ok"),
                sum(status$status == "skipped"),
                sum(status$status == "error")))
  }
  invisible(list(status = status, summary = table(status$status)))
}


# ==== SIDECAR ACCEPTANCE / REGISTRY RECONCILIATION ==========================
# sidecar_acceptance(stratum) runs the post-backfill acceptance gate for a
# stratum, INCLUDING a registry-vs-sidecar anti-join so a missing or extra
# dataset_id is reported explicitly before the stratum is claimed trusted.
# Define-only; reads the on-disk sidecar, fits nothing. The registry is the
# non-meta catalog dataset_id set for the stratum (built exactly the way
# fit_robma_models() builds dataset_id).
#
# Checks (returned in $checks; all must pass for $ok):
#   1  row count == registry (anti-join clean)
#   2  no unresolved labels
#   3  direct package components (effect/het/bias) validate
#   4  log10BF_no_bias == -log10BF_bias (finite; derived transparency)
#   5-7  SELECTED rigor identities: rigor_effect == muplus_omega0,
#        rigor_no_effect == mu0_omega0, rigor == pmax(branches) -- branch
#        fields never collapsed into the headline
#   8-9  rigor_direction agrees with selected branch; rigor_margin exact
#   10 columns exactly == .SIDECAR_V4_COLS (the lean contract; set + order)
#   11 rigor_direction populated and in .RIGOR_DIRECTION_LEVELS (never "null")
#   12 schema_version uniform + current
#   13 estimand_version uniform + current (rejects effect-only-rigor)
#   14 analysis_id well-formed + unique
#   15 analysis_variant structured; parent_dataset_id/exclusion_reason
#      consistent with exclusion_sensitivity
#   16 rigor_category matches the centralized derivation
#   17 config_hash uniform+current & RoBMA major-version compatible
# Returns invisibly list(ok, registry, checks); prints a report when verbose.
sidecar_acceptance <- function(stratum, tol = 1e-3, verbose = TRUE) {
  # Numeric equality robust to NA / +-Inf (both NA -> TRUE = "not applicable";
  # matched +-Inf same sign -> TRUE; one Inf one finite -> FALSE).
  eq_num <- function(a, b, tol = 1e-6) {
    mapply(function(x, y) {
      if (is.na(x) && is.na(y)) return(TRUE)
      if (is.na(x) || is.na(y)) return(FALSE)
      if (is.infinite(x) || is.infinite(y))
        return(is.infinite(x) && is.infinite(y) && sign(x) == sign(y))
      abs(x - y) <= tol
    }, a, b)
  }

  output_root  <- .cfg("output_root", "output")
  stratum_slug <- norm_slug(stratum)
  csv <- file.path(output_root, stratum_slug,
                    sprintf("%s_robma_summary.csv", stratum_slug))
  if (!file.exists(csv)) stop("sidecar not found: ", csv)
  df <- read.csv(csv, check.names = FALSE, stringsAsFactors = FALSE)

  # ---- Registry (expected dataset_id set) --------------------------------
  plan <- plan_from_data(stratum = stratum)
  plan <- plan[!vapply(plan$object_name, is_meta_basename, logical(1)), ,
               drop = FALSE]
  expected_ids <- sort(unique(as.character(plan$dataset_id)))
  sidecar_ids  <- sort(unique(as.character(df$dataset_id)))
  missing_ids <- setdiff(expected_ids, sidecar_ids)  # in registry, not sidecar
  extra_ids   <- setdiff(sidecar_ids, expected_ids)  # in sidecar, not registry

  chk <- list()
  add <- function(name, pass, detail = "") {
    chk[[length(chk) + 1L]] <<- data.frame(
      check = name, pass = isTRUE(pass), detail = detail,
      stringsAsFactors = FALSE)
  }

  L <- function(v) suppressWarnings(as.logical(v))
  N <- function(v) suppressWarnings(as.numeric(v))

  # 1. row count == registry count (anti-join must be empty both ways)
  add("1 row_count == registry_count (anti-join clean)",
      nrow(df) == length(expected_ids) &&
        length(missing_ids) == 0 && length(extra_ids) == 0,
      sprintf("sidecar=%d registry=%d missing={%s} extra={%s}",
              nrow(df), length(expected_ids),
              paste(missing_ids, collapse = ","),
              paste(extra_ids, collapse = ",")))

  # 2. no unresolved labels
  ul <- suppressWarnings(as.integer(df$unresolved_labels))
  add("2 no unresolved labels",
      all(!is.na(ul) & ul == 0L),
      sprintf("max=%s n_bad=%d", max(ul, na.rm = TRUE),
              sum(is.na(ul) | ul != 0L)))

  # 3. all direct package components validate
  cvo <- L(df$component_validation_ok)
  add("3 all direct package components validate",
      all(!is.na(cvo) & cvo),
      sprintf("n_fail=%d {%s}", sum(is.na(cvo) | !cvo),
              paste(df$dataset_id[is.na(cvo) | !cvo], collapse = ",")))

  # 4. log10BF_no_bias == -log10BF_bias when finite
  lb  <- N(df$log10BF_bias); lnb <- N(df$log10BF_no_bias)
  finb <- is.finite(lb) & is.finite(lnb)
  add("4 log10BF_no_bias == -log10BF_bias (finite)",
      !any(finb) || all(abs(lnb[finb] + lb[finb]) <= tol),
      sprintf("checked=%d max_abs=%.3e", sum(finb),
              if (any(finb)) max(abs(lnb[finb] + lb[finb])) else 0))

  # 5. log10BF_rigor_effect == log10BF_muplus_omega0
  add("5 log10BF_rigor_effect == log10BF_muplus_omega0",
      all(eq_num(N(df$log10BF_rigor_effect), N(df$log10BF_muplus_omega0), tol)),
      "")

  # 6. log10BF_rigor_no_effect == log10BF_mu0_omega0
  add("6 log10BF_rigor_no_effect == log10BF_mu0_omega0",
      all(eq_num(N(df$log10BF_rigor_no_effect), N(df$log10BF_mu0_omega0),
                 tol)),
      "")

  # 7. log10BF_rigor == pmax(effect, no_effect)  (SELECTED, never collapsed)
  sel <- pmax(N(df$log10BF_rigor_effect), N(df$log10BF_rigor_no_effect),
              na.rm = FALSE)
  add("7 log10BF_rigor == pmax(rigor_effect, rigor_no_effect)",
      all(eq_num(N(df$log10BF_rigor), sel, tol)), "")

  # 8. rigor_direction agrees with the selected branch (stored no-effect
  # label is "no_effect", never "null"; ties resolve to "effect").
  want_dir <- ifelse(N(df$log10BF_rigor_effect) >=
                       N(df$log10BF_rigor_no_effect),
                      "effect", "no_effect")
  dir_ok <- (as.character(df$rigor_direction) == want_dir) |
            (is.na(df$rigor_direction) & is.na(want_dir))
  add("8 rigor_direction agrees with selected branch",
      all(!is.na(dir_ok) & dir_ok),
      sprintf("n_bad=%d", sum(is.na(dir_ok) | !dir_ok)))

  # 9. rigor_margin == abs(rigor_effect - rigor_no_effect)
  want_margin <- abs(N(df$log10BF_rigor_effect) -
                       N(df$log10BF_rigor_no_effect))
  add("9 rigor_margin == abs(rigor_effect - rigor_no_effect)",
      all(eq_num(N(df$rigor_margin), want_margin, tol)), "")

  # 10. columns exactly match .SIDECAR_V4_COLS (set and order)
  add("10 columns exactly == .SIDECAR_V4_COLS",
      identical(names(df), .SIDECAR_V4_COLS),
      if (identical(names(df), .SIDECAR_V4_COLS)) "exact" else
        sprintf("missing={%s} extra={%s}",
                paste(setdiff(.SIDECAR_V4_COLS, names(df)), collapse = ","),
                paste(setdiff(names(df), .SIDECAR_V4_COLS), collapse = ",")))

  # 11. rigor_direction MUST be populated and valid (only the parser-safe
  # .RIGOR_DIRECTION_LEVELS, never "null") whenever BOTH branch BFs exist.
  both_present <- !is.na(N(df$log10BF_rigor_effect)) &
                  !is.na(N(df$log10BF_rigor_no_effect))
  rd <- as.character(df$rigor_direction)
  rd_blank <- both_present & (is.na(rd) | !nzchar(trimws(rd)))
  rd_bad_val <- both_present & !rd_blank &
                !(rd %in% .RIGOR_DIRECTION_LEVELS)
  add("11 rigor_direction populated + in .RIGOR_DIRECTION_LEVELS",
      !any(rd_blank) && !any(rd_bad_val),
      sprintf("n_present=%d n_blank=%d n_badval=%d {%s}",
              sum(both_present), sum(rd_blank), sum(rd_bad_val),
              paste(df$dataset_id[rd_blank | rd_bad_val], collapse = ",")))

  # 12. schema_version is uniform and current (rejects stale-schema rows).
  sv <- as.character(df$schema_version)
  add("12 schema_version == .SCHEMA_VERSION (uniform)",
      all(!is.na(sv) & sv == .SCHEMA_VERSION),
      sprintf("expected=%s observed={%s}", .SCHEMA_VERSION,
              paste(sort(unique(sv)), collapse = ",")))

  # 13. estimand_version is uniform and current (rejects archived
  # effect-only-rigor / older estimand outputs).
  ev <- as.character(df$estimand_version)
  add("13 estimand_version == .ESTIMAND_VERSION (uniform)",
      all(!is.na(ev) & ev == .ESTIMAND_VERSION),
      sprintf("expected=%s observed={%s}", .ESTIMAND_VERSION,
              paste(sort(unique(ev)), collapse = ",")))

  # 14. analysis_id well-formed and unique: corpus__stratum__article__
  # outcome__variantslug, with variant slug in {main, excl}.
  aid <- as.character(df$analysis_id)
  aid_ok <- grepl("^[^_].*__.*__.*__.*__(main|excl)$", aid) &
            !is.na(aid) & nzchar(aid)
  add("14 analysis_id well-formed + unique",
      all(aid_ok) && !any(duplicated(aid)),
      sprintf("n_bad=%d n_dup=%d {%s}",
              sum(!aid_ok), sum(duplicated(aid)),
              paste(df$dataset_id[!aid_ok], collapse = ",")))

  # 15. analysis_variant is a structured value; parent_dataset_id and
  # exclusion_reason are populated iff exclusion_sensitivity.
  av <- as.character(df$analysis_variant)
  av_ok  <- av %in% .ANALYSIS_VARIANT_LEVELS
  is_ex  <- av == "exclusion_sensitivity"
  pid    <- as.character(df$parent_dataset_id)
  exr    <- as.character(df$exclusion_reason)
  pid_ok <- (is_ex  & !is.na(pid) & nzchar(pid)) |
            (!is_ex & (is.na(pid) | !nzchar(pid)))
  exr_ok <- (is_ex  & !is.na(exr) & nzchar(exr)) |
            (!is_ex & (is.na(exr) | !nzchar(exr)))
  add("15 analysis_variant structured + parent/exclusion consistent",
      all(av_ok) && all(pid_ok) && all(exr_ok),
      sprintf("n_badvariant=%d n_badparent=%d n_badreason=%d",
              sum(!av_ok), sum(!pid_ok), sum(!exr_ok)))

  # 16. rigor_category matches the centralized derivation (no overwrite).
  want_cat <- .rigor_category(N(df$log10BF_rigor_effect),
                              N(df$log10BF_rigor_no_effect),
                              N(df$log10BF_rigor),
                              as.character(df$rigor_direction))
  got_cat  <- as.character(df$rigor_category)
  cat_ok   <- (got_cat == want_cat) | (is.na(got_cat) & is.na(want_cat))
  add("16 rigor_category == .rigor_category(branches)",
      all(!is.na(cat_ok) & cat_ok),
      sprintf("n_bad=%d {%s}", sum(is.na(cat_ok) | !cat_ok),
              paste(df$dataset_id[is.na(cat_ok) | !cat_ok], collapse = ",")))

  # 17. reproducibility: config_hash uniform AND current, RoBMA major
  # version >= .ROBMA_MAJOR_MIN (no 3.6.x / mixed-config rows).
  ch       <- as.character(df$config_hash)
  cur_hash <- if (exists(".config_hash")) .config_hash() else NA_character_
  ch_ok    <- length(unique(ch)) == 1L &&
              (is.na(cur_hash) || all(ch == cur_hash))
  rv_major <- .major_version(df$robma_version)
  rv_ok    <- all(!is.na(rv_major) & rv_major >= .ROBMA_MAJOR_MIN)
  add("17 config_hash uniform+current & RoBMA major >= min",
      ch_ok && rv_ok,
      sprintf("n_config=%d cur=%s robma_major_ok=%d/%d",
              length(unique(ch)),
              if (is.na(cur_hash)) "NA" else substr(cur_hash, 1, 12),
              sum(!is.na(rv_major) & rv_major >= .ROBMA_MAJOR_MIN), nrow(df)))

  checks <- do.call(rbind, chk)
  ok_all <- all(checks$pass)

  if (verbose) {
    cat(sprintf("\n===== sidecar_acceptance(%s) =====\n", stratum))
    cat(sprintf("registry=%d  sidecar_rows=%d  missing=%d  extra=%d\n",
                length(expected_ids), nrow(df),
                length(missing_ids), length(extra_ids)))
    if (length(missing_ids))
      cat("  MISSING dataset_id(s):", paste(missing_ids, collapse = ", "), "\n")
    if (length(extra_ids))
      cat("  EXTRA   dataset_id(s):", paste(extra_ids, collapse = ", "), "\n")
    for (i in seq_len(nrow(checks))) {
      cat(sprintf("  [%s] %s%s\n",
                  if (checks$pass[i]) "PASS" else "FAIL",
                  checks$check[i],
                  if (nzchar(checks$detail[i]))
                    paste0("  -- ", checks$detail[i]) else ""))
    }
    cat(sprintf("RESULT: %s\n", if (ok_all) "ALL PASS" else "FAILURES PRESENT"))
  }

  invisible(list(
    ok       = ok_all,
    registry = list(expected = expected_ids, sidecar = sidecar_ids,
                    missing = missing_ids, extra = extra_ids),
    checks   = checks
  ))
}


# ---- All-strata acceptance wrapper -----------------------------------------
# sidecar_acceptance_all() is the corpus-wide CONTRACT GATE between the
# fitting layer (00/10/20/40) and the reporting layer (60 -> 50/70). It
# discovers every per-stratum sidecar under the output root and runs the
# existing per-stratum sidecar_acceptance() stratum-by-stratum, then layers a
# few non-blocking artifact / zplot / audit WARNINGS on top and a compact
# PASS/FAIL summary.
#
# Acceptance is a CONTRACT / REPRODUCIBILITY gate, NOT a scientific
# quality judgement: PASS means the sidecars are structurally trustworthy v4
# outputs (current schema/estimand/config, internally consistent rigor
# identities, registry reconciled), so the reporting layer may consume them.
# It does NOT assert anything about the substantive evidence in any outcome.
#
# It refits NOTHING, rewrites no sidecars, rebuilds no tables, repairs no
# schema, and writes no CSV. Define-only; reads on-disk artifacts only.
#
# HARD-FAIL (gates $ok) -- per stratum:
#   * the per-stratum sidecar is missing/unreadable, OR plan/registry build
#     errors (surfaced as an acceptance_error problem),
#   * ANY of the 17 sidecar_acceptance() checks fails. Those 17 already cover
#     the structural contract: registry anti-join, required v4 columns
#     present + exact (.SIDECAR_V4_COLS), schema_version current,
#     estimand_version current, config_hash uniform+current, RoBMA major >=
#     .ROBMA_MAJOR_MIN, analysis_id unique (variant slug embedded -> dup
#     analysis_id+variant caught), analysis_variant valid, rigor_direction
#     valid, component/partition validation flags, unresolved-label =>
#     rigor-extraction validity, and the selected-rigor identities,
#   * require_artifacts = TRUE and a row lacks its RoBMA 4.0 .rds fits,
#   * require_zplots = TRUE and a stratum's zplot-diagnostics CSV is absent.
#
# WARNING (non-blocking unless fail_on_warning = TRUE):
#   * missing .rds fit artifacts when require_artifacts = FALSE (the public
#     repo legitimately omits regenerable fits),
#   * missing zplot diagnostics when require_zplots = FALSE,
#   * family_evidence_uncertain rows (still reportable; flagged for audit).
#
# Returns invisibly list(ok, summary, checks, problems) -- base data.frames
# matching sidecar_acceptance()'s style; no new package dependency.
sidecar_acceptance_all <- function(output_root = NULL,
                                   require_artifacts = TRUE,
                                   require_zplots = FALSE,
                                   fail_on_warning = FALSE,
                                   verbose = TRUE) {
  output_root <- output_root %||% .cfg("output_root", "output")
  if (!dir.exists(output_root))
    stop("output root not found: ", output_root)

  # Discover strata: a subdir <s> that contains <s>/<s>_robma_summary.csv.
  # This naturally excludes overview/_scratch/reports (no such sidecar).
  subdirs <- list.dirs(output_root, recursive = FALSE, full.names = FALSE)
  strata  <- character(0)
  for (s in subdirs) {
    if (tolower(s) %in% c("overview", "_scratch", "reports", "tables")) next
    csv <- file.path(output_root, s, sprintf("%s_robma_summary.csv", s))
    if (file.exists(csv)) strata <- c(strata, s)
  }
  strata <- sort(unique(strata))
  if (length(strata) == 0L)
    stop(sprintf(paste0(
      "No per-stratum v4 sidecars found under %s/. Expected ",
      "%s/<stratum>/<stratum>_robma_summary.csv (run batch_fit() / ",
      "backfill_sidecars() first)."), output_root, output_root))

  summ_rows <- list(); chk_rows <- list(); prob_rows <- list()
  add_problem <- function(stratum, severity, kind, detail) {
    prob_rows[[length(prob_rows) + 1L]] <<- data.frame(
      stratum = stratum, severity = severity, kind = kind,
      detail = detail, stringsAsFactors = FALSE)
  }

  for (s in strata) {
    res <- tryCatch(sidecar_acceptance(stratum = s, verbose = FALSE),
                    error = function(e)
                      list(ok = FALSE, .error = conditionMessage(e),
                           checks = NULL))
    err     <- res$.error %||% NA_character_
    hard_ok <- isTRUE(res$ok) && is.na(err)

    slug <- norm_slug(s)
    csv  <- file.path(output_root, slug,
                       sprintf("%s_robma_summary.csv", slug))
    df <- tryCatch(read.csv(csv, check.names = FALSE,
                            stringsAsFactors = FALSE),
                   error = function(e) NULL)
    n_rows <- if (is.null(df)) NA_integer_ else nrow(df)

    if (!is.null(res$checks) && nrow(res$checks)) {
      chk_rows[[length(chk_rows) + 1L]] <-
        data.frame(stratum = s, res$checks, stringsAsFactors = FALSE)
      for (i in which(!res$checks$pass))
        add_problem(s, "hard", "acceptance_check",
                    sprintf("%s -- %s", res$checks$check[i],
                            res$checks$detail[i]))
    }
    if (!is.na(err)) add_problem(s, "hard", "acceptance_error", err)

    # ---- .rds fit-artifact presence (hard iff require_artifacts) ----------
    n_missing_art <- NA_integer_
    if (!is.null(df) &&
        all(c("dataset_id", "source_article") %in% names(df))) {
      miss_art <- !mapply(function(id, sa)
        isTRUE(artifacts_exist_v4(id, s, sa)),
        df$dataset_id, df$source_article)
      n_missing_art <- sum(miss_art)
      if (n_missing_art > 0L)
        add_problem(s,
          if (isTRUE(require_artifacts)) "hard" else "warn",
          "missing_rds_artifacts",
          sprintf("%d row(s) lack fit_RE4_/fit_RoBMA4_ .rds {%s}",
                  n_missing_art,
                  paste(utils::head(df$dataset_id[miss_art], 8),
                        collapse = ",")))
    }

    # ---- zplot diagnostics presence (hard iff require_zplots) ------------
    zp    <- file.path(output_root, slug,
                        sprintf("%s_zplot_diagnostics.csv", slug))
    zp_ok <- file.exists(zp)
    if (!zp_ok)
      add_problem(s, if (isTRUE(require_zplots)) "hard" else "warn",
                  "missing_zplot_diagnostics", sprintf("absent: %s", zp))

    # ---- family_evidence_uncertain (non-blocking, still reportable) ------
    n_unc <- NA_integer_
    if (!is.null(df) && "family_evidence_uncertain" %in% names(df)) {
      fu    <- suppressWarnings(as.logical(df$family_evidence_uncertain))
      n_unc <- sum(!is.na(fu) & fu)
      if (n_unc > 0L)
        add_problem(s, "warn", "family_evidence_uncertain",
                    sprintf("%d row(s) flagged family_evidence_uncertain",
                            n_unc))
    }

    meta1 <- function(col) if (!is.null(df) && col %in% names(df))
      paste(sort(unique(as.character(df[[col]]))), collapse = ",")
      else NA_character_
    rvm <- if (!is.null(df) && "robma_version" %in% names(df))
      .major_version(df$robma_version) else NA_integer_
    rv_major <- if (all(is.na(rvm))) NA_integer_ else max(rvm, na.rm = TRUE)

    art_hard <- isTRUE(require_artifacts) && !is.na(n_missing_art) &&
                n_missing_art > 0L
    zp_hard  <- isTRUE(require_zplots) && !zp_ok

    summ_rows[[length(summ_rows) + 1L]] <- data.frame(
      stratum            = s,
      n_rows             = n_rows,
      acceptance_ok      = isTRUE(res$ok),
      n_checks_failed    = if (is.null(res$checks)) NA_integer_
                           else sum(!res$checks$pass),
      n_missing_rds      = n_missing_art,
      zplot_diag_present = zp_ok,
      n_family_uncertain = n_unc,
      schema_version     = meta1("schema_version"),
      estimand_version   = meta1("estimand_version"),
      config_hash        = meta1("config_hash"),
      robma_major        = rv_major,
      status             = if (hard_ok && !art_hard && !zp_hard)
                             "PASS" else "FAIL",
      stringsAsFactors   = FALSE)
  }

  summary  <- do.call(rbind, summ_rows)
  checks   <- if (length(chk_rows)) do.call(rbind, chk_rows) else
    data.frame(stratum = character(), check = character(),
               pass = logical(), detail = character(),
               stringsAsFactors = FALSE)
  problems <- if (length(prob_rows)) do.call(rbind, prob_rows) else
    data.frame(stratum = character(), severity = character(),
               kind = character(), detail = character(),
               stringsAsFactors = FALSE)
  rownames(summary) <- NULL
  rownames(checks)  <- NULL
  rownames(problems) <- NULL

  n_hard <- sum(problems$severity == "hard")
  n_warn <- sum(problems$severity == "warn")
  ok <- all(summary$status == "PASS") && n_hard == 0L &&
        (!isTRUE(fail_on_warning) || n_warn == 0L)

  if (verbose) {
    uval <- function(v) {
      v <- unique(stats::na.omit(v))
      if (!length(v)) "NA" else paste(v, collapse = ",")
    }
    cat(sprintf("\nSidecar acceptance: %s\n", if (ok) "PASS" else "FAIL"))
    cat(sprintf("Strata checked: %d\n", nrow(summary)))
    cat(sprintf("Rows checked: %s\n",
                if (all(is.na(summary$n_rows))) "NA"
                else sum(summary$n_rows, na.rm = TRUE)))
    cat(sprintf("Schema version: %s\n", uval(summary$schema_version)))
    cat(sprintf("Estimand version: %s\n", uval(summary$estimand_version)))
    cat(sprintf("Config hashes: %d\n",
                length(unique(stats::na.omit(summary$config_hash)))))
    cat(sprintf("RoBMA major: %s\n", uval(summary$robma_major)))
    if (n_warn > 0L)
      cat(sprintf("Warnings: %d (non-blocking%s)\n", n_warn,
                  if (isTRUE(fail_on_warning))
                    "; fail_on_warning=TRUE -> gates" else ""))
    if (!ok) {
      hp <- problems[problems$severity == "hard", , drop = FALSE]
      if (nrow(hp)) {
        cat("\nHard failures:\n")
        for (i in seq_len(nrow(hp)))
          cat(sprintf("  %s: %s -- %s\n",
                      hp$stratum[i], hp$kind[i], hp$detail[i]))
      }
    }
    if (n_warn > 0L) {
      wp <- problems[problems$severity == "warn", , drop = FALSE]
      cat("\nWarnings:\n")
      for (i in seq_len(nrow(wp)))
        cat(sprintf("  %s: %s -- %s\n",
                    wp$stratum[i], wp$kind[i], wp$detail[i]))
    }
  }

  invisible(list(ok = ok, summary = summary,
                 checks = checks, problems = problems))
}
