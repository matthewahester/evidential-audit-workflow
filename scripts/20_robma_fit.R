# 20_robma_fit.R
# ------------------------------------------------------------------------------
# Single-dataset model fitting backbone for the audit pipeline.
#
# fit_robma_models() fits two ensembles on a single Hedges' g dataset:
#   * fit_RE     - NoBMA baseline random-effects (no publication-bias selection)
#   * fit_RoBMA  - RoBMA-PSMA bias-adjusted ensemble
# It also derives matched zcurve objects, persists *.rds artifacts, and updates
# the per-topic sidecar CSV (output/<topic>/<topic>_robma_summary.csv) used by
# 50_topic_analysis.R and 60_overview.R.
#
# Sourcing this file only defines the CONFIG list and helpers; nothing fits
# until fit_robma_models() is called.
#
# Quick-Start
#   source("scripts/00_utils.R")
#   source("scripts/10_load_data.R")
#   source("scripts/20_robma_fit.R")
#   load_datasets(topic = "Protein", author = "morton2018", file = "morton2018_protein_lean_body_mass")
#   res <- fit_robma_models(morton2018_protein_lean_body_mass, dataset_name = "morton2018_protein_lean_body_mass")
#
# Notes on side effects:
#   * Successful fits assign fit_RE_<basename>, fit_RoBMA_<basename>, and
#     matching zcurve_* objects into .GlobalEnv. This is a deliberate part of
#     the interactive workflow: 30_robma_analysis.R retrieves them by name.
#   * When CONFIG$save_outputs is TRUE (default), *.rds artifacts and the
#     sidecar CSV are written to CONFIG$output_root.
# ------------------------------------------------------------------------------

library(RoBMA)


# ---- Shared utilities ------------------------------------------------------
# Provides %||%. Sentinel-guarded: skipped if already loaded.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# ==== CONFIGURATION =========================================================
# Edit values here to change MCMC settings or output behavior. fit_robma_models
# reads from this list at call time, so updating CONFIG between calls is fine.

CONFIG <- list(
  # ---- MCMC ----
  algorithm = "ss",            # spike-and-slab sampler
  sample    = 100000,          # post-warmup samples per chain
  burnin    = 75000,
  adapt     = 75000,
  thin      = 5,
  chains    = 6,
  parallel  = TRUE,            # run chains in parallel within a fit
  seed      = 042626,          # random seed for reproducibility

  # ---- Data format ----
  measure   = "SMD_g",         # Hedges' g

  # ---- RoBMA effect direction ----
  effect_direction = "positive",   # "positive" or "negative"

  # ---- Output ----
  output_root    = "output",   # base output directory
  save_outputs   = TRUE,       # write *.rds files alongside CSV summaries
  nest_by_effect = FALSE       # if TRUE, nest output dir one level deeper
)


# ==== HELPERS ===============================================================

# Normalize a string to a lowercase slug with underscores. Used to derive
# safe directory and basename components.
norm_slug <- function(x) {
  gsub("[^a-z0-9_]+", "_", tolower(gsub("\\.", "_", x)))
}

# Extract coefficients (mu, tau, ...) from a fit as a list.
coeffs <- function(fit) {
  if (is.null(fit)) return(NULL)
  x <- fit$coefficients %||% fit$RoBMA$coefficients
  if (is.atomic(x)) as.list(x) else x
}

# Extract the inference table (Effect / Heterogeneity / Bias rows) as a
# data.frame.
infer <- function(fit) {
  if (is.null(fit)) return(NULL)
  inf <- fit$inference %||% fit$RoBMA$inference
  if (is.matrix(inf)) as.data.frame(inf) else inf
}

# Safe numeric extraction from an inference table row x column. Returns NA
# when the row or column is missing.
infer_num <- function(df, row, col) {
  if (is.null(df) || !row %in% rownames(df) || !col %in% colnames(df))
    return(NA_real_)
  as.numeric(df[row, col])
}

# Build the output directory and topic-level sidecar-CSV paths for a fit.
paths_for <- function(topic, author, effect) {
  topic_slug  <- norm_slug(topic)
  author_slug <- norm_slug(author)
  out_dir <- if (CONFIG$nest_by_effect) {
    file.path(CONFIG$output_root, topic_slug, author_slug, norm_slug(effect))
  } else {
    file.path(CONFIG$output_root, topic_slug, author_slug)
  }
  list(
    out_dir   = out_dir,
    topic_csv = file.path(CONFIG$output_root, topic_slug,
                          sprintf("%s_robma_summary.csv", topic_slug))
  )
}

# Append (or replace, by basename) one summary row in the topic-level sidecar
# CSV. Atomic via temp-file rename.
append_sidecar <- function(row_df, csv_path, expected_cols) {
  dir.create(dirname(csv_path), recursive = TRUE, showWarnings = FALSE)

  if (file.exists(csv_path)) {
    old <- try(read.csv(csv_path, stringsAsFactors = FALSE), silent = TRUE)
    if (!inherits(old, "try-error") && identical(sort(colnames(old)), sort(expected_cols))) {
      old <- old[old$basename != row_df$basename, , drop = FALSE]
      new <- rbind(old, row_df)
    } else {
      new <- row_df
    }
  } else {
    new <- row_df
  }

  new <- new[order(as.POSIXct(new$timestamp), new$author, new$effect), ]
  new <- new[, expected_cols]

  tmp <- paste0(csv_path, ".tmp")
  write.csv(new, tmp, row.names = FALSE)
  file.rename(tmp, csv_path)
}

# Posterior credible interval for mu (default: 95%).
mu_ci <- function(fit, probs = c(0.025, 0.975)) {
  if (is.null(fit)) return(c(NA_real_, NA_real_))
  smp <- tryCatch(RoBMA::extract_posterior(fit, parameter = "mu"),
                  error = function(e) NULL)
  if (is.null(smp)) return(c(NA_real_, NA_real_))
  smp <- as.numeric(smp)
  if (!length(smp)) return(c(NA_real_, NA_real_))
  as.numeric(stats::quantile(smp, probs = probs, na.rm = TRUE))
}

# Build one row of the per-topic sidecar CSV from a (fit_RE, fit_RoBMA) pair.
build_sidecar_row <- function(fit_RE, fit_RoBMA, n_studies, meta) {
  cRE <- coeffs(fit_RE)
  cBC <- coeffs(fit_RoBMA)
  ci_RE  <- mu_ci(fit_RE)
  ci_BC  <- mu_ci(fit_RoBMA)
  iRE <- infer(fit_RE)
  iBC <- infer(fit_RoBMA)

  data.frame(
    topic = meta$topic, author = meta$author, effect = meta$effect,
    measure = CONFIG$measure,
    effect_direction = meta$effect_direction,
    basename = meta$basename, out_dir = meta$out_dir,
    n_studies = as.integer(n_studies),
    mu_RE = if (!is.null(cRE)) as.numeric(cRE[["mu"]][1]) else NA_real_,
    tau_RE = if (!is.null(cRE)) as.numeric(cRE[["tau"]][1]) else NA_real_,
    mu_RE_lCI = ci_RE[1],
    mu_RE_uCI = ci_RE[2],
    eff_prior_RE = infer_num(iRE, "Effect", "prior_prob"),
    eff_post_RE = infer_num(iRE, "Effect", "post_prob"),
    eff_bf_RE = infer_num(iRE, "Effect", "inclusion_BF"),
    het_prior_RE = infer_num(iRE, "Heterogeneity", "prior_prob"),
    het_post_RE = infer_num(iRE, "Heterogeneity", "post_prob"),
    het_bf_RE = infer_num(iRE, "Heterogeneity", "inclusion_BF"),
    mu_BC = if (!is.null(cBC)) as.numeric(cBC[["mu"]][1]) else NA_real_,
    tau_BC = if (!is.null(cBC)) as.numeric(cBC[["tau"]][1]) else NA_real_,
    mu_BC_lCI = ci_BC[1],
    mu_BC_uCI = ci_BC[2],
    eff_prior_BC = infer_num(iBC, "Effect", "prior_prob"),
    eff_post_BC = infer_num(iBC, "Effect", "post_prob"),
    eff_bf_BC = infer_num(iBC, "Effect", "inclusion_BF"),
    het_prior_BC = infer_num(iBC, "Heterogeneity", "prior_prob"),
    het_post_BC = infer_num(iBC, "Heterogeneity", "post_prob"),
    het_bf_BC = infer_num(iBC, "Heterogeneity", "inclusion_BF"),
    bias_prior_BC = infer_num(iBC, "Bias", "prior_prob"),
    bias_post_BC = infer_num(iBC, "Bias", "post_prob"),
    bias_bf_BC = infer_num(iBC, "Bias", "inclusion_BF"),
    algorithm = meta$algorithm, sample = meta$sample, burnin = meta$burnin,
    adapt = meta$adapt, chains = meta$chains, parallel = meta$parallel,
    seed = meta$seed,
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    stringsAsFactors = FALSE
  )
}


# ==== MAIN FUNCTION =========================================================

fit_robma_models <- function(
    data,                  # data.frame with columns g, se_g
    dataset_name = NULL,   # e.g. "morton2018_protein_lean_body_mass"; defaults to deparsed data
    topic        = NULL,   # optional override; otherwise parsed from name
    author       = NULL,   # optional override
    effect       = NULL,   # optional override
    study_col    = NULL    # optional column name for study IDs
) {

  if (!is.data.frame(data)) {
    stop("data must be a data.frame")
  }

  # If no name was passed, deparse the call site to recover the variable
  # name so we can split it into (author, topic, effect) tokens.
  if (is.null(dataset_name)) {
    dataset_name <- deparse(substitute(data))
  }

  parts <- strsplit(dataset_name, "_")[[1]]
  author <- norm_slug(author %||% (if (length(parts) >= 1) parts[1] else "misc"))
  topic <- norm_slug(topic %||% (if (length(parts) >= 2) parts[2] else "misc"))
  effect <- norm_slug(effect %||%
                        (if (length(parts) >= 3) paste(parts[3:length(parts)], collapse = "_") else "misc"))

  basename <- sprintf("%s_%s_%s", author, topic, effect)
  paths <- paths_for(topic, author, effect)

  # ---- Validate required columns and data quality --------------------------
  if (!all(c("g", "se_g") %in% colnames(data))) {
    stop("Required columns 'g' and 'se_g' not found in data")
  }

  bad_g <- which(!is.finite(data$g))
  bad_se_g <- which(!is.finite(data$se_g) | data$se_g <= 0)

  if (length(bad_g) > 0) {
    stop(sprintf("Non-finite g values in %d rows. First few: %s",
                 length(bad_g), paste(head(bad_g, 5), collapse = ", ")))
  }
  if (length(bad_se_g) > 0) {
    stop(sprintf("Invalid se_g values in %d rows. First few: %s",
                 length(bad_se_g), paste(head(bad_se_g, 5), collapse = ", ")))
  }

  if (nrow(data) < 3) {
    stop("Minimum 3 studies required")
  }

  if (!is.null(study_col) && !study_col %in% colnames(data)) {
    stop(sprintf("Study column '%s' not found", study_col))
  }

  message(sprintf("Fitting models for '%s' (n=%d studies)", basename, nrow(data)))
  message(sprintf("Using: algorithm=%s, sample=%d, burnin=%d, adapt=%d, chains=%d",
                  CONFIG$algorithm, CONFIG$sample, CONFIG$burnin, CONFIG$adapt, CONFIG$chains))

  # ---- Baseline random-effects (no publication-bias selection) -------------
  message("Fitting NoBMA model (unadjusted)...")
  fit_RE <- tryCatch(
    NoBMA(
      y = data$g,
      se = data$se_g,
      study_ids = if (!is.null(study_col)) data[[study_col]] else NULL,
      priors_effect_null = NULL,
      priors_heterogeneity_null = NULL,
      algorithm = CONFIG$algorithm,
      sample = CONFIG$sample,
      burnin = CONFIG$burnin,
      adapt = CONFIG$adapt,
      chains = CONFIG$chains,
      parallel = CONFIG$parallel,
      seed = CONFIG$seed
    ),
    error = function(e) {
      warning(sprintf("NoBMA fit failed: %s", e$message))
      NULL
    }
  )

  # ---- RoBMA-PSMA (bias-adjusted) ------------------------------------------
  message("Fitting RoBMA model (bias-adjusted)...")
  fit_RoBMA <- tryCatch(
    RoBMA(
      y = data$g,
      se = data$se_g,
      study_ids = if (!is.null(study_col)) data[[study_col]] else NULL,
      effect_direction = CONFIG$effect_direction,
      algorithm = CONFIG$algorithm,
      sample = CONFIG$sample,
      burnin = CONFIG$burnin,
      adapt = CONFIG$adapt,
      chains = CONFIG$chains,
      parallel = CONFIG$parallel,
      seed = CONFIG$seed
    ),
    error = function(e) {
      warning(sprintf("RoBMA fit failed: %s", e$message))
      NULL
    }
  )

  # Convert fits to zcurve objects (best-effort; failure is non-fatal).
  zcurve_RE <- tryCatch(as_zcurve(fit_RE),
                        error = function(e) { message("zcurve_RE: ", e$message); NULL })
  zcurve_RoBMA <- tryCatch(as_zcurve(fit_RoBMA),
                           error = function(e) { message("zcurve_RoBMA: ", e$message); NULL })

  # ---- Stamp objects into the global environment ---------------------------
  # The interactive workflow expects fit_RE_<basename> etc. to be retrievable
  # by name from later scripts (notably 30_robma_analysis.R).
  assign_with_notice <- function(name, obj) {
    if (!is.null(obj)) {
      if (exists(name, envir = .GlobalEnv)) {
        message(sprintf("Overwriting: %s", name))
      }
      assign(name, obj, envir = .GlobalEnv)
    }
  }

  assign_with_notice(paste0("fit_RE_", basename), fit_RE)
  assign_with_notice(paste0("fit_RoBMA_", basename), fit_RoBMA)
  assign_with_notice(paste0("zcurve_RE_", basename), zcurve_RE)
  assign_with_notice(paste0("zcurve_RoBMA_", basename), zcurve_RoBMA)

  # ---- Persist *.rds artifacts ---------------------------------------------
  if (CONFIG$save_outputs) {
    dir.create(paths$out_dir, recursive = TRUE, showWarnings = FALSE)

    if (!is.null(fit_RE)) {
      saveRDS(fit_RE, file.path(paths$out_dir, paste0("fit_RE_", basename, ".rds")))
    }
    if (!is.null(fit_RoBMA)) {
      saveRDS(fit_RoBMA, file.path(paths$out_dir, paste0("fit_RoBMA_", basename, ".rds")))
    }
    if (!is.null(zcurve_RE)) {
      saveRDS(zcurve_RE, file.path(paths$out_dir, paste0("zcurve_RE_", basename, ".rds")))
    }
    if (!is.null(zcurve_RoBMA)) {
      saveRDS(zcurve_RoBMA, file.path(paths$out_dir, paste0("zcurve_RoBMA_", basename, ".rds")))
    }

    message(sprintf("Saved outputs to: %s/", paths$out_dir))
  }

  # ---- Update topic-level sidecar CSV --------------------------------------
  if (!is.null(fit_RE) || !is.null(fit_RoBMA)) {
    meta <- list(
      topic = topic, author = author, effect = effect,
      effect_direction = CONFIG$effect_direction,
      basename = basename, out_dir = paths$out_dir,
      algorithm = CONFIG$algorithm, sample = CONFIG$sample,
      burnin = CONFIG$burnin, adapt = CONFIG$adapt,
      chains = CONFIG$chains, parallel = CONFIG$parallel,
      seed = CONFIG$seed
    )

    row <- build_sidecar_row(fit_RE, fit_RoBMA, nrow(data), meta)

    expected_cols <- c("topic", "author", "effect", "measure", "effect_direction",
                       "basename", "out_dir", "n_studies",
                       "mu_RE", "tau_RE", "mu_RE_lCI", "mu_RE_uCI",
                       "eff_prior_RE", "eff_post_RE", "eff_bf_RE",
                       "het_prior_RE", "het_post_RE", "het_bf_RE",
                       "mu_BC", "tau_BC", "mu_BC_lCI", "mu_BC_uCI",
                       "eff_prior_BC", "eff_post_BC", "eff_bf_BC",
                       "het_prior_BC", "het_post_BC", "het_bf_BC",
                       "bias_prior_BC", "bias_post_BC", "bias_bf_BC",
                       "algorithm", "sample", "burnin", "adapt", "chains",
                       "parallel", "seed", "timestamp")

    append_sidecar(row, paths$topic_csv, expected_cols)
    message(sprintf("Updated summary: %s", paths$topic_csv))
  } else {
    warning(sprintf("Both fits failed for %s", basename))
  }

  # ---- Console-friendly summary --------------------------------------------
  cat("\n=== RESULTS ===\n")
  cat(sprintf("Dataset: %s (n=%d studies)\n", basename, nrow(data)))
  if (!is.null(fit_RE)) {
    cat(sprintf("NoBMA mu: %.3f\n", coeffs(fit_RE)$mu[1]))
  }
  if (!is.null(fit_RoBMA)) {
    cat(sprintf("RoBMA mu: %.3f\n", coeffs(fit_RoBMA)$mu[1]))
  }
  cat(sprintf("\nObjects created: fit_RE_%s, fit_RoBMA_%s, zcurve_RE_%s, zcurve_RoBMA_%s\n",
              basename, basename, basename, basename))
  cat("===============\n\n")

  invisible(list(
    fit_RE = fit_RE,
    fit_RoBMA = fit_RoBMA,
    zcurve_RE = zcurve_RE,
    zcurve_RoBMA = zcurve_RoBMA,
    basename = basename,
    topic = topic,
    author = author,
    effect = effect,
    measure = CONFIG$measure,
    out_dir = paths$out_dir
  ))
}
