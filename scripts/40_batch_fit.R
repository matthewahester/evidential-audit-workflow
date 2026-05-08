# 40_batch_fit.R
# ------------------------------------------------------------------------------
# Batch orchestration over many datasets.
#
# batch_fit() wraps fit_robma_models() (from 20_robma_fit.R) with a plan-then-
# execute loop, resume support (skip datasets whose four *.rds artifacts
# already exist), optional dry-run mode, and optional dataset-level parallel
# execution via parallel::mclapply on POSIX.
#
# All MCMC and output settings are read from the CONFIG list defined in
# 20_robma_fit.R; this script does not duplicate them. Datasets must expose
# columns 'g' and 'se_g' (Hedges' g format).
#
# Sourcing this file only defines functions; nothing is read or written.
#
# Quick-Start
#   source("scripts/00_utils.R")
#   source("scripts/10_load_data.R")
#   source("scripts/20_robma_fit.R")    # provides CONFIG and fit_robma_models()
#   source("scripts/40_batch_fit.R")
#
#   run <- batch_fit(topic = "Protein", author = "morton2018",
#                    resume = TRUE, dry_run = FALSE)
#   run$summary       # compact counts
#   head(run$status)  # per-dataset rows
# ------------------------------------------------------------------------------


# ---- Shared utilities ------------------------------------------------------
# Provides %||% and is_meta_basename(). Sentinel-guarded.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# ==== HELPERS ===============================================================

# Check whether all four *.rds artifacts already exist for a dataset, using
# the same path layout as fit_robma_models().
artifacts_exist <- function(basename, topic, author) {
  output_root <- if (exists("CONFIG", envir = .GlobalEnv)) {
    CONFIG$output_root %||% "output"
  } else {
    "output"
  }

  nest_by_effect <- if (exists("CONFIG", envir = .GlobalEnv)) {
    CONFIG$nest_by_effect %||% FALSE
  } else {
    FALSE
  }

  # Parse effect from the basename (matching the naming convention used in
  # 20_robma_fit.R: <author>_<topic>_<effect>).
  parts <- strsplit(basename, "_")[[1]]
  effect <- if (length(parts) >= 3)
    tolower(paste(parts[3:length(parts)], collapse = "_")) else "misc"

  out_dir <- if (nest_by_effect) {
    file.path(output_root, topic, author, effect)
  } else {
    file.path(output_root, topic, author)
  }

  files <- c(
    file.path(out_dir, paste0("fit_RE_", basename, ".rds")),
    file.path(out_dir, paste0("fit_RoBMA_", basename, ".rds")),
    file.path(out_dir, paste0("zcurve_RE_", basename, ".rds")),
    file.path(out_dir, paste0("zcurve_RoBMA_", basename, ".rds"))
  )

  all(file.exists(files))
}

# Truncate a value to a printable string for status messages.
safe_first <- function(x, default = "") {
  if (is.null(x) || length(x) == 0) return(default)
  substr(as.character(x[1]), 1, 120)
}


# ==== PLANNING ==============================================================

# Build the list of candidate datasets, applying the same topic / author /
# file filters as load_datasets(), and adding a sanitized `object_name`
# column matching what load_datasets() will assign in the global environment.
plan_from_data <- function(topic = NULL, author = NULL, file = NULL) {
  catalog <- list_datasets()
  filtered <- catalog

  if (!is.null(topic)) {
    filtered <- filtered[tolower(filtered$topic) == tolower(topic), , drop = FALSE]
  }
  if (!is.null(author)) {
    filtered <- filtered[tolower(filtered$author) == tolower(author), , drop = FALSE]
  }
  if (!is.null(file)) {
    if (grepl("\\.csv$", file, ignore.case = TRUE)) {
      filtered <- filtered[tolower(filtered$file) == tolower(file), , drop = FALSE]
    } else {
      filtered <- filtered[tolower(filtered$basename) == tolower(file), , drop = FALSE]
    }
  }

  if (nrow(filtered) > 0) {
    filtered$object_name <- make.names(filtered$basename)
  } else {
    filtered$object_name <- character(0)
  }

  filtered
}


# ==== VALIDATORS ============================================================

# TRUE if `obj_name` exists in `envir`, is a non-empty data.frame, and has
# the required Hedges' g columns.
has_required_cols <- function(obj_name, envir = .GlobalEnv) {
  if (!exists(obj_name, envir = envir)) return(FALSE)
  df <- get(obj_name, envir = envir)
  is.data.frame(df) && all(c("g", "se_g") %in% names(df)) && nrow(df) > 0
}


# ==== BATCH FITTING =========================================================

batch_fit <- function(topic = NULL, author = NULL, file = NULL,
                      resume = TRUE, dry_run = FALSE,
                      verbose = TRUE, parallel_over_datasets = FALSE,
                      study_col = NULL) {
  # Fit fit_robma_models() across many datasets with resume and parallel
  # support. All MCMC settings are read from CONFIG (in 20_robma_fit.R).
  #
  # Args:
  #   topic, author, file       Filters passed to plan_from_data().
  #   resume                    Skip datasets where all four artifacts exist.
  #   dry_run                   List the plan without fitting anything.
  #   verbose                   Print per-dataset progress lines.
  #   parallel_over_datasets    If TRUE on POSIX, fan out via mclapply.
  #   study_col                 Optional column name forwarded to
  #                             fit_robma_models() for study-level random effects.
  #
  # Returns: invisibly, list(status = data.frame(...),
  #                          summary = table(status),
  #                          ran = character vector of basenames actually fit)

  plan <- plan_from_data(topic = topic, author = author, file = file)

  if (nrow(plan) == 0) {
    catalog <- list_datasets()
    topics <- unique(catalog$topic)
    if (length(topics) > 10) topics <- c(topics[1:10], "...")
    stop("No datasets match filters. Available topics: ",
         paste(topics, collapse = ", "))
  }

  # Load data into the global environment unless dry-running.
  if (!dry_run) {
    load_datasets(topic = topic, author = author, file = file)
  }

  output_root <- if (exists("CONFIG", envir = .GlobalEnv)) {
    CONFIG$output_root %||% "output"
  } else {
    "output"
  }

  # Identify datasets that are runnable (skip meta files and any candidates
  # missing the required g / se_g columns).
  plan$should_run <- vapply(plan$object_name, function(bn) {
    !is_meta_basename(bn) && has_required_cols(bn)
  }, logical(1))

  if (verbose) {
    cat(sprintf(
      "\nValidated %d datasets: %d runnable, %d skipped (no g/se_g or meta)\n",
      nrow(plan), sum(plan$should_run), sum(!plan$should_run)
    ))
  }

  # Worker for a single plan row.
  fit_one <- function(i) {
    row <- plan[i, ]
    basename <- row$object_name

    # Hard skip: meta files or datasets missing g/se_g.
    if (!isTRUE(row$should_run)) {
      if (verbose) {
        cat(sprintf("[%d/%d] SKIP %s (no g/se_g or meta)\n", i, nrow(plan), basename))
      }
      return(list(
        basename = basename,
        topic = row$topic,
        author = row$author,
        status = "skipped",
        message = "no g/se_g or meta file",
        elapsed_sec = 0,
        out_dir = file.path(output_root, row$topic, row$author)
      ))
    }

    # Resume check.
    if (resume && artifacts_exist(basename, row$topic, row$author)) {
      if (verbose) {
        cat(sprintf("[%d/%d] SKIP %s (artifacts exist)\n",
                    i, nrow(plan), basename))
      }
      return(list(
        basename = basename,
        topic = row$topic,
        author = row$author,
        status = "skipped",
        message = "artifacts exist",
        elapsed_sec = 0,
        out_dir = file.path(output_root, row$topic, row$author)
      ))
    }

    # Dry-run.
    if (dry_run) {
      if (verbose) {
        cat(sprintf("[%d/%d] DRY  %s\n", i, nrow(plan), basename))
      }
      return(list(
        basename = basename,
        topic = row$topic,
        author = row$author,
        status = "skipped",
        message = "dry run",
        elapsed_sec = 0,
        out_dir = file.path(output_root, row$topic, row$author)
      ))
    }

    # Run the fit.
    if (verbose) {
      cat(sprintf("[%d/%d] RUN  %s", i, nrow(plan), basename))
    }

    t0 <- Sys.time()
    result <- tryCatch({
      data_obj <- get(basename, envir = .GlobalEnv)

      fit_args <- list(
        data = data_obj,
        dataset_name = basename,
        topic = row$topic,
        author = row$author,
        effect = row$effect
      )

      if (!is.null(study_col)) {
        fit_args$study_col <- study_col
      }

      res <- do.call(fit_robma_models, fit_args)

      list(
        basename = basename,
        topic = row$topic,
        author = row$author,
        status = "ran",
        message = "success",
        elapsed_sec = as.numeric(Sys.time() - t0, units = "secs"),
        out_dir = res$out_dir %||% file.path(output_root, row$topic, row$author)
      )
    }, error = function(e) {
      list(
        basename = basename,
        topic = row$topic,
        author = row$author,
        status = "error",
        message = safe_first(e$message),
        elapsed_sec = as.numeric(Sys.time() - t0, units = "secs"),
        out_dir = file.path(output_root, row$topic, row$author)
      )
    })

    if (verbose) {
      cat(sprintf(" [%.1fs]\n", result$elapsed_sec))
    }

    result
  }

  # Execute fits (parallel or sequential).
  if (parallel_over_datasets && .Platform$OS.type != "windows") {
    if (!requireNamespace("parallel", quietly = TRUE)) {
      warning("Parallel requested but 'parallel' package not available")
      results <- lapply(seq_len(nrow(plan)), fit_one)
    } else {
      mc_cores <- getOption("mc.cores", 2)
      results <- parallel::mclapply(seq_len(nrow(plan)), fit_one,
                                    mc.cores = mc_cores)
    }
  } else {
    if (parallel_over_datasets && .Platform$OS.type == "windows") {
      warning("Parallel processing not supported on Windows, using sequential")
    }
    results <- lapply(seq_len(nrow(plan)), fit_one)
  }

  # Build status data.frame.
  status <- do.call(rbind, lapply(results, function(r) {
    data.frame(
      basename = r$basename,
      topic = r$topic,
      author = r$author,
      status = r$status,
      message = r$message,
      elapsed_sec = r$elapsed_sec,
      out_dir = r$out_dir,
      stringsAsFactors = FALSE
    )
  }))

  # Summary counts.
  summary <- table(status$status)
  ran_basenames <- status$basename[status$status == "ran"]

  if (verbose) {
    cat("\n========== Batch Summary ==========\n")
    cat(sprintf("Ran: %d | Skipped: %d | Errors: %d\n",
                summary["ran"] %||% 0,
                summary["skipped"] %||% 0,
                summary["error"] %||% 0))
    cat(sprintf("Total time: %.1fs\n", sum(status$elapsed_sec)))
  }

  invisible(list(
    status = status,
    summary = summary,
    ran = ran_basenames
  ))
}
