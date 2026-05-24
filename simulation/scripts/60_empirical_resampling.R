# 60_empirical_resampling.R - Q2 empirical resampling/scaling.
#
# Define-only on source. One workflow call:
#
#   emp_run_resampling(B = 5000, n_grid = c(5:30, 35, 40, 50), workers=5)
#                      
#
# This reads only the empirical v4 outcome registry under output/,
# never output_sim_v30, never synthetic sidecars, and never calls RoBMA.
#
# The output is the empirical resampling size curve: how stratum/corpus
# rigor profiles behave as the number of outcome-level meta-analyses
# summarized into the profile grows. Observed-size bootstrap intervals
# are derived from the same curve.
#
# Shared reducers kept for 65/70:
#   emp_stratum_summary()
#   emp_corpus_summary()
#
# Registry loaders kept for 65 (sim_load_empirical_registry):
#   emp_read_outcome_registry()
#   emp_validate_registry()

if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}

# --- constants ----------------------------------------------------------

# v4 thresholds, reused (never re-defined) so summaries cannot drift.
.EMP_TH <- if (exists(".EVIDENCE_THRESHOLDS", inherits = TRUE))
  .EVIDENCE_THRESHOLDS else
  list(inconclusive = 0.5, moderate = 0.5, strong = 1.0,
       moderate_null = -0.5, strong_null = -1.0,
       claimed_mu_threshold = 0.2)

.EMP_RIGOR_CATEGORIES <- c("clean_effect_supported",
                           "clean_no_effect_supported",
                           "clean_evidence_disfavored",
                           "inconclusive_clean_evidence")

# Canonical bootstrap mode tags.
.EMP_MODE_OUTCOME <- "outcome"
.EMP_MODE_CLUSTER <- "source_cluster"

# Default seed base. Per-replicate seeds depend ONLY on (plan, b,
# base_seed), so results are byte-identical regardless of worker count
# or worker order.
.EMP_DEFAULT_BASE_SEED <- 20260517L

# --- helpers ------------------------------------------------------------

# Per-replicate deterministic seeds.
.emp_seeds <- function(B, base_seed) {
  B <- as.integer(B); base_seed <- as.integer(base_seed)
  ((as.numeric(base_seed) + seq_len(B)) %% .Machine$integer.max) |>
    as.integer()
}

# Resolve worker count: explicit `workers` arg overrides; otherwise read
# env var EMP_RESAMPLING_WORKERS (default 1). Clamped to [1, max(1, B)].
.emp_resolve_workers <- function(workers = NULL, B = 1L) {
  w <- if (!is.null(workers)) workers
       else suppressWarnings(as.integer(
              Sys.getenv("EMP_RESAMPLING_WORKERS", "1")))
  w <- as.integer(w)
  if (length(w) != 1L || is.na(w) || w < 1L) w <- 1L
  min(w, max(1L, as.integer(B)))
}

# Dispatch B replicates either sequentially or via a PSOCK cluster.
# Exports every emp_* / .emp_* / .EMP_* symbol + the v4 utility
# helpers (.attenuation_pct etc.) to each worker so the dispatched
# closure can resolve its references. With pre-computed per-replicate
# seeds, results are byte-identical regardless of worker count.
.emp_lapply <- function(seq, fn, workers = 1L, ..., chunk_size = NULL) {
  workers <- as.integer(workers)
  if (workers <= 1L)
    return(lapply(seq, fn, ...))
  if (!requireNamespace("parallel", quietly = TRUE)) {
    message("[emp] 'parallel' namespace unavailable; falling back to ",
            "workers = 1.")
    return(lapply(seq, fn, ...))
  }
  src_env <- environment(emp_corpus_summary)
  if (is.null(src_env)) src_env <- .GlobalEnv
  syms_all <- ls(envir = src_env, all.names = TRUE)
  keep <- grepl("^(emp_|\\.emp_|\\.EMP_)", syms_all) |
          syms_all %in% c(".attenuation_pct", ".sign_flip", ".shrink50",
                          ".EVIDENCE_THRESHOLDS", ".robma_utils_loaded",
                          "%||%")
  syms <- syms_all[keep]
  cl <- parallel::makePSOCKcluster(workers)
  on.exit(parallel::stopCluster(cl), add = TRUE)
  if (length(syms))
    parallel::clusterExport(cl, varlist = syms, envir = src_env)
  parallel::parLapplyLB(cl, seq, fn, ..., chunk.size = chunk_size)
}

# --- v4-identical tiny reducers (mirror 60_estimand_tables.R) -----------
.emp_bf_avail <- function(x) !is.na(x)            # Inf counts as evidence
.emp_med <- function(x) { x <- x[!is.na(x)]
  if (!length(x)) NA_real_ else stats::median(x) }
.emp_qtl <- function(x, p) { x <- x[!is.na(x)]
  if (!length(x)) NA_real_
  else suppressWarnings(as.numeric(stats::quantile(x, p, names = FALSE))) }
.emp_prop <- function(num, denom)
  if (!is.na(denom) && denom > 0) num / denom else NA_real_
# Inf-safe rigor margin (companion to raw rigor_margin); mirrors
# 60_estimand_tables.R::.rigor_margin_safe.
.emp_margin_safe <- function(a, b) mapply(function(x, y) {
  if (is.na(x) || is.na(y)) return(NA_real_)
  xi <- is.infinite(x); yi <- is.infinite(y)
  if (xi && yi) return(if (sign(x) == sign(y)) 0 else Inf)
  if (xi || yi) return(Inf)
  abs(x - y)
}, a, b)

# --- registry I/O -------------------------------------------------------

#' Read the empirical v4 outcome registry (NOT output_sim_v30).
#'
#' Kept public for 65 (`sim_load_empirical_registry()` calls it).
emp_read_outcome_registry <- function(root = "output",
                                      overview_csv = NULL) {
  path <- overview_csv %||%
    file.path(root, "overview", "outcome_registry.csv")
  if (!file.exists(path))
    stop("Empirical outcome registry not found at '", path,
         "'. Build it with build_estimand_tables(root = \"", root,
         "\") first. (Do NOT point this at output_sim_v30.)")
  if (grepl("output_sim", path))
    stop("Refusing to read a simulation output root as the empirical ",
         "registry: '", path, "'.")
  reg <- utils::read.csv(path, stringsAsFactors = FALSE,
                         check.names = FALSE)
  if ("stratum" %in% names(reg)) {
    n0 <- nrow(reg)
    reg <- reg[!grepl("^sim_", reg$stratum), , drop = FALSE]
    if (nrow(reg) < n0)
      message(sprintf("[emp] dropped %d sim_ row(s) from empirical registry",
                      n0 - nrow(reg)))
  }
  attr(reg, "registry_path") <- path
  reg
}

#' Validate the v4 fields needed for empirical resampling.
#'
#' Kept public for 65 (`sim_load_empirical_registry()` calls it).
emp_validate_registry <- function(reg, require_ok = TRUE) {
  identity <- c("stratum","source_article","outcome_slug","dataset_id",
                "analysis_id","analysis_variant","corpus_id","scheme")
  core     <- c("mu_RE","mu_BC","tau_RE","tau_BC",
                "log10BF_effect","log10BF_het","log10BF_bias")
  rigor    <- c("log10BF_rigor","log10BF_rigor_effect",
                "log10BF_rigor_no_effect","rigor_direction",
                "rigor_category","rigor_margin")
  need <- c(identity, core, rigor)
  missing <- setdiff(need, names(reg))
  derivable <- character(0)
  if ("rigor_category" %in% missing &&
      all(c("log10BF_rigor_effect","log10BF_rigor_no_effect")
          %in% names(reg)))
    derivable <- c(derivable, "rigor_category")
  res <- list(
    ok        = length(missing) == 0L,
    present   = intersect(need, names(reg)),
    missing   = missing,
    derivable = derivable,
    n_rows    = nrow(reg),
    n_strata  = length(unique(reg$stratum)),
    n_sources = length(unique(paste(reg$stratum, reg$source_article,
                                    sep = "\r"))),
    has_sim   = any(grepl("^sim_", reg$stratum)))
  if (!res$ok && isTRUE(require_ok)) {
    stop("Empirical registry is missing required v4 column(s): ",
         paste(missing, collapse = ", "),
         if (length(derivable))
           paste0(" | derivable from existing outputs: ",
                  paste(derivable, collapse = ", ")) else
           " | none of these are derivable from existing v4 outputs.",
         ". Reporting and refusing to continue silently.")
  }
  res
}

# --- core summarizer ----------------------------------------------------
# Rigor-first stratum/corpus summary on an in-memory (possibly
# bootstrapped) registry slice. Mirrors v4 estimand semantics.
.emp_summarize_one <- function(df, level, group_label) {
  th  <- .EMP_TH
  ba  <- function(col) df[[col]][.emp_bf_avail(df[[col]])]
  R   <- ba("log10BF_rigor")
  Re  <- ba("log10BF_rigor_effect")
  Rn  <- ba("log10BF_rigor_no_effect")
  Le  <- ba("log10BF_effect")
  Lh  <- ba("log10BF_het")
  Lb  <- ba("log10BF_bias")
  dv  <- df$rigor_direction %in% c("effect","no_effect")
  rd  <- df$rigor_direction[dv]
  rc  <- df$rigor_category[!is.na(df$rigor_category)]
  marg <- .emp_margin_safe(df$log10BF_rigor_effect,
                           df$log10BF_rigor_no_effect)
  att_abs <- abs(df$mu_RE) - abs(df$mu_BC)
  att_pct <- if ("attenuation_pct" %in% names(df)) df$attenuation_pct else
    .attenuation_pct(df$mu_RE, df$mu_BC)
  sf <- if ("sign_flip" %in% names(df)) df$sign_flip else
    .sign_flip(df$mu_RE, df$mu_BC)
  sh <- if ("shrink50" %in% names(df)) df$shrink50 else
    .shrink50(df$mu_RE, df$mu_BC)
  sf <- sf[!is.na(sf)]; sh <- sh[!is.na(sh)]

  data.frame(
    level   = level,
    stratum = group_label,
    n_outcomes        = nrow(df),
    n_source_articles = length(unique(paste(df$stratum, df$source_article,
                                            sep = "\r"))),
    median_log10BF_rigor = .emp_med(R),
    q25_log10BF_rigor    = .emp_qtl(R, 0.25),
    q75_log10BF_rigor    = .emp_qtl(R, 0.75),
    median_log10BF_rigor_effect    = .emp_med(Re),
    median_log10BF_rigor_no_effect = .emp_med(Rn),
    median_rigor_margin  = .emp_med(marg),
    p_rigor_direction_effect    = .emp_prop(sum(rd == "effect"),
                                            length(rd)),
    p_rigor_direction_no_effect = .emp_prop(sum(rd == "no_effect"),
                                            length(rd)),
    p_clean_effect_supported      = .emp_prop(
      sum(rc == "clean_effect_supported"), length(rc)),
    p_clean_no_effect_supported   = .emp_prop(
      sum(rc == "clean_no_effect_supported"), length(rc)),
    p_clean_evidence_disfavored   = .emp_prop(
      sum(rc == "clean_evidence_disfavored"), length(rc)),
    p_inconclusive_clean_evidence = .emp_prop(
      sum(rc == "inconclusive_clean_evidence"), length(rc)),
    median_mu_RE  = .emp_med(df$mu_RE),
    median_mu_BC  = .emp_med(df$mu_BC),
    median_tau_RE = .emp_med(df$tau_RE),
    median_tau_BC = .emp_med(df$tau_BC),
    median_log10BF_effect = .emp_med(Le),
    median_log10BF_het    = .emp_med(Lh),
    median_log10BF_bias   = .emp_med(Lb),
    p_bias_moderate   = .emp_prop(sum(Lb > th$moderate), length(Lb)),
    p_het_moderate    = .emp_prop(sum(Lh > th$moderate), length(Lh)),
    p_effect_moderate = .emp_prop(sum(Le > th$moderate), length(Le)),
    median_attenuation_abs = .emp_med(att_abs),
    median_attenuation_pct = .emp_med(att_pct),
    p_sign_flip = .emp_prop(sum(sf %in% TRUE), length(sf)),
    p_shrink50  = .emp_prop(sum(sh %in% TRUE), length(sh)),
    stringsAsFactors = FALSE)
}

#' Per-stratum rigor-first summary of an (in-memory) registry.
#'
#' Public: 65 and 70 source this directly.
emp_stratum_summary <- function(reg) {
  parts <- split(reg, reg$stratum)
  do.call(rbind, lapply(names(parts), function(s)
    .emp_summarize_one(parts[[s]], "stratum", s)))
}

#' Corpus-level rigor-first summary (one row over all strata).
#'
#' Public: 65 and 70 source this directly.
emp_corpus_summary <- function(reg) {
  .emp_summarize_one(reg, "corpus", "Overall")
}

# Numeric metric columns that scaling-curve summaries cover.
.EMP_METRIC_COLS <- c(
  "n_outcomes","n_source_articles",
  "median_log10BF_rigor","q25_log10BF_rigor","q75_log10BF_rigor",
  "median_log10BF_rigor_effect","median_log10BF_rigor_no_effect",
  "median_rigor_margin","p_rigor_direction_effect",
  "p_rigor_direction_no_effect","p_clean_effect_supported",
  "p_clean_no_effect_supported","p_clean_evidence_disfavored",
  "p_inconclusive_clean_evidence","median_mu_RE","median_mu_BC",
  "median_tau_RE","median_tau_BC","median_log10BF_effect",
  "median_log10BF_het","median_log10BF_bias","p_bias_moderate",
  "p_het_moderate","p_effect_moderate","median_attenuation_abs",
  "median_attenuation_pct","p_sign_flip","p_shrink50")

# --- per-replicate worker -----------------------------------------------

# One bootstrap replicate.
#
# Inputs:
#   b               : replicate index (1..B)
#   seed            : deterministic per-replicate seed
#   level           : "stratum" or "corpus"
#   group_label     : empirical stratum name or "Overall"
#   mode_tag        : "outcome" or "source_cluster"
#   n_sampled       : n to draw (with replacement) from the pool
#   reg_subset      : registry slice that defines the pool's row data
#   rows_by_cluster : list(cluster_key -> integer row idx of reg_subset)
#                     (cluster mode only; NULL otherwise)
#   cluster_keys    : character vector of cluster keys in this pool
#                     (cluster mode only; NULL otherwise)
#   n_pool / n_outcomes_observed / n_sources_observed : metadata stamped
#     onto every output row.
#
# Returns: one-row data.frame with the rigor/component summary +
# bookkeeping columns. NULL when the pool is empty.
.emp_resample_one <- function(b, seed, level, group_label, mode_tag,
                              n_sampled, reg_subset,
                              rows_by_cluster = NULL,
                              cluster_keys = NULL,
                              n_pool = NA_integer_,
                              n_outcomes_observed = NA_integer_,
                              n_sources_observed = NA_integer_) {
  set.seed(seed)
  if (mode_tag == .EMP_MODE_OUTCOME) {
    if (nrow(reg_subset) == 0L) return(NULL)
    ix <- sample(seq_len(nrow(reg_subset)),
                 size = as.integer(n_sampled), replace = TRUE)
    bs <- reg_subset[ix, , drop = FALSE]
  } else {
    if (length(cluster_keys) == 0L) return(NULL)
    pick <- sample(cluster_keys, size = as.integer(n_sampled),
                   replace = TRUE)
    pieces <- vector("list", length(pick))
    instances <- integer(0)
    for (j in seq_along(pick)) {
      ix <- rows_by_cluster[[pick[j]]]
      pieces[[j]] <- ix
      instances <- c(instances, rep.int(j, length(ix)))
    }
    bs <- reg_subset[unlist(pieces, use.names = FALSE), , drop = FALSE]
    bs$boot_cluster_instance <- instances
  }
  if (level == "stratum") {
    bs$stratum <- group_label
    summ <- emp_stratum_summary(bs)
  } else {
    summ <- emp_corpus_summary(bs)
  }
  summ$level               <- level
  summ$stratum             <- group_label
  summ$bootstrap_mode      <- mode_tag
  summ$n_sampled           <- as.integer(n_sampled)
  summ$n_pool              <- as.integer(n_pool)
  summ$n_outcomes_observed <- as.integer(n_outcomes_observed)
  summ$n_sources_observed  <- as.integer(n_sources_observed)
  summ$bootstrap_id        <- as.integer(b)
  summ$seed                <- as.integer(seed)
  summ
}

# --- scaling curve engine -----------------------------------------------

# Build one plan row per (level, group, mode, n_sampled). The plan is
# what the curve loop iterates over; n_outcomes_observed and
# n_sources_observed for the group are auto-inserted into n_grid if
# missing. Returns a list of plan slots and the precomputed pool data
# (reg_subset + cluster index) per (level, group, mode).
.emp_build_curve_plans <- function(reg, n_grid, modes, strata) {
  plans <- list()
  pools <- list()
  idx <- 0L

  # Per-stratum pool data (outcome rows + cluster index).
  reg$.k <- paste(reg$stratum, reg$source_article, sep = "\r")
  for (s in strata) {
    rs <- reg[reg$stratum == s, , drop = FALSE]
    if (!nrow(rs)) next
    rows_by_cluster <- split(seq_len(nrow(rs)), rs$.k)
    cluster_keys <- unique(rs$.k)
    n_out_obs <- as.integer(nrow(rs))
    n_src_obs <- length(cluster_keys)
    for (mode_tag in modes) {
      pool_size <- if (mode_tag == .EMP_MODE_OUTCOME) n_out_obs
                   else n_src_obs
      n_obs_for_mode <- if (mode_tag == .EMP_MODE_OUTCOME) n_out_obs
                       else n_src_obs
      n_set <- sort(unique(c(as.integer(n_grid), n_obs_for_mode)))
      n_set <- n_set[n_set > 0L]
      key <- paste("stratum", s, mode_tag, sep = "::")
      pools[[key]] <- list(
        reg_subset = rs, rows_by_cluster = rows_by_cluster,
        cluster_keys = cluster_keys, n_pool = pool_size,
        n_outcomes_observed = n_out_obs,
        n_sources_observed = n_src_obs)
      for (n_v in n_set) {
        idx <- idx + 1L
        plans[[length(plans) + 1L]] <- list(
          plan_id = idx, pool_key = key,
          level = "stratum", group_label = s, mode_tag = mode_tag,
          n_sampled = as.integer(n_v),
          is_observed_n = identical(as.integer(n_v),
                                    as.integer(n_obs_for_mode)))
      }
    }
  }

  # Corpus pool: full registry; cluster index over the full corpus.
  rows_by_cluster_corp <- split(seq_len(nrow(reg)), reg$.k)
  cluster_keys_corp <- unique(reg$.k)
  n_out_obs_corp <- as.integer(nrow(reg))
  n_src_obs_corp <- length(cluster_keys_corp)
  for (mode_tag in modes) {
    pool_size <- if (mode_tag == .EMP_MODE_OUTCOME) n_out_obs_corp
                 else n_src_obs_corp
    n_obs_for_mode <- if (mode_tag == .EMP_MODE_OUTCOME) n_out_obs_corp
                     else n_src_obs_corp
    n_set <- sort(unique(c(as.integer(n_grid), n_obs_for_mode)))
    n_set <- n_set[n_set > 0L]
    key <- paste("corpus", "Overall", mode_tag, sep = "::")
    pools[[key]] <- list(
      reg_subset = reg, rows_by_cluster = rows_by_cluster_corp,
      cluster_keys = cluster_keys_corp, n_pool = pool_size,
      n_outcomes_observed = n_out_obs_corp,
      n_sources_observed = n_src_obs_corp)
    for (n_v in n_set) {
      idx <- idx + 1L
      plans[[length(plans) + 1L]] <- list(
        plan_id = idx, pool_key = key,
        level = "corpus", group_label = "Overall",
        mode_tag = mode_tag,
        n_sampled = as.integer(n_v),
        is_observed_n = identical(as.integer(n_v),
                                  as.integer(n_obs_for_mode)))
    }
  }

  list(plans = plans, pools = pools)
}

# One plan's B replicates, run sequentially. Deterministic seeds depend
# only on (plan_id, b, base_seed) so the result is identical regardless
# of which worker (or whether any worker) executes the plan.
.emp_run_plan <- function(plan_index, plans, pools, B, base_seed) {
  p    <- plans[[plan_index]]
  pool <- pools[[p$pool_key]]
  base  <- as.integer(base_seed + (p$plan_id - 1L) * 100000L)
  seeds <- .emp_seeds(B, base)
  rows <- lapply(seq_len(B), function(b) {
    .emp_resample_one(
      b, seeds[b], p$level, p$group_label, p$mode_tag,
      p$n_sampled,
      reg_subset          = pool$reg_subset,
      rows_by_cluster     = pool$rows_by_cluster,
      cluster_keys        = pool$cluster_keys,
      n_pool              = pool$n_pool,
      n_outcomes_observed = pool$n_outcomes_observed,
      n_sources_observed  = pool$n_sources_observed)
  })
  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (length(rows)) do.call(rbind, rows) else NULL
}

# Symbols that need to land in every PSOCK worker so the plan closure
# can resolve its references (same set .emp_lapply previously exported,
# kept consistent here so the two parallel paths stay aligned).
.emp_cluster_export_syms <- function() {
  src_env <- environment(emp_corpus_summary)
  if (is.null(src_env)) src_env <- .GlobalEnv
  syms_all <- ls(envir = src_env, all.names = TRUE)
  keep <- grepl("^(emp_|\\.emp_|\\.EMP_)", syms_all) |
          syms_all %in% c(".attenuation_pct", ".sign_flip", ".shrink50",
                          ".EVIDENCE_THRESHOLDS", ".robma_utils_loaded",
                          "%||%")
  list(env = src_env, syms = syms_all[keep])
}

# Run all plans, B replicates each. Parallelizes over PLANS rather than
# over bootstrap replicates inside a plan, so cluster creation happens
# once per emp_run_resampling() call instead of once per plan. Returns
# a long draws data.frame in plan order.
.emp_run_size_curve <- function(reg, n_grid, modes, B, base_seed,
                                workers, verbose) {
  strata <- sort(unique(reg$stratum))
  built  <- .emp_build_curve_plans(reg, n_grid, modes, strata)
  plans  <- built$plans
  pools  <- built$pools
  # Parallel unit is now the plan, so resolve workers against
  # length(plans), not B.
  w <- .emp_resolve_workers(workers, length(plans))

  # Lightweight note when the user asks for parallelism on a small job.
  # Do not override the explicit workers argument.
  if (!is.null(workers) && as.integer(workers) > 1L &&
      (as.integer(B) < 200L || length(plans) < 50L) &&
      isTRUE(verbose))
    message("[emp] workers > 1 requested. Empirical resampling jobs ",
            "are small; parallelism helps only for large B or large ",
            "grids.")

  if (isTRUE(verbose))
    message(sprintf(paste0(
      "[emp][curve] plans=%d (strata=%d + corpus, modes={%s}, ",
      "n_grid len=%d (%d..%d)), B=%d, workers=%d (parallel unit = plan)"),
      length(plans), length(strata), paste(modes, collapse = ","),
      length(n_grid), min(n_grid), max(n_grid), B, w))

  if (w <= 1L) {
    if (isTRUE(verbose) && length(plans) >= 50L)
      message(sprintf("[emp][curve] sequential over %d plans...",
                      length(plans)))
    draws_parts <- lapply(seq_along(plans), .emp_run_plan,
                          plans = plans, pools = pools,
                          B = B, base_seed = base_seed)
  } else {
    if (!requireNamespace("parallel", quietly = TRUE)) {
      message("[emp] 'parallel' namespace unavailable; falling back ",
              "to workers = 1.")
      draws_parts <- lapply(seq_along(plans), .emp_run_plan,
                            plans = plans, pools = pools,
                            B = B, base_seed = base_seed)
    } else {
      if (isTRUE(verbose))
        message(sprintf(
          "[emp][curve] launching PSOCK cluster (workers=%d) once for %d plans",
          w, length(plans)))
      exp <- .emp_cluster_export_syms()
      cl <- parallel::makePSOCKcluster(w)
      on.exit(parallel::stopCluster(cl), add = TRUE)
      if (length(exp$syms))
        parallel::clusterExport(cl, varlist = exp$syms, envir = exp$env)
      # parLapplyLB load-balances plans across workers; output order
      # follows the input (seq_along(plans)) so byte-equality with the
      # sequential path is preserved.
      draws_parts <- parallel::parLapplyLB(
        cl, seq_along(plans), .emp_run_plan,
        plans = plans, pools = pools, B = B, base_seed = base_seed)
    }
  }

  draws <- do.call(rbind, draws_parts)
  if (!is.null(draws)) draws$B <- as.integer(B)
  draws
}

# Collapse draws to per (level, group, mode, n_sampled, metric) summary.
.emp_summarize_size_curve <- function(draws, observed) {
  if (is.null(draws) || !nrow(draws)) return(NULL)
  metrics <- intersect(.EMP_METRIC_COLS, names(draws))
  combos <- unique(draws[, c("level", "stratum", "bootstrap_mode",
                              "n_sampled", "n_pool",
                              "n_outcomes_observed",
                              "n_sources_observed"),
                          drop = FALSE])
  out <- vector("list", nrow(combos) * length(metrics))
  k <- 0L
  for (i in seq_len(nrow(combos))) {
    cb <- combos[i, , drop = FALSE]
    sub <- draws[draws$level == cb$level &
                 draws$stratum == cb$stratum &
                 draws$bootstrap_mode == cb$bootstrap_mode &
                 draws$n_sampled == cb$n_sampled, , drop = FALSE]
    obs_row <- if (!is.null(observed))
      observed[observed$level == cb$level &
               observed$stratum == cb$stratum, , drop = FALSE]
      else NULL
    for (m in metrics) {
      v  <- suppressWarnings(as.numeric(sub[[m]]))
      vv <- v[!is.na(v)]
      obs_val <- if (!is.null(obs_row) && nrow(obs_row) &&
                     m %in% names(obs_row))
        suppressWarnings(as.numeric(obs_row[[m]][1])) else NA_real_
      bmean <- if (length(vv)) mean(vv) else NA_real_
      bsd   <- if (length(vv) > 1L) stats::sd(vv) else NA_real_
      q025v <- .emp_qtl(vv, 0.025); q05v <- .emp_qtl(vv, 0.05)
      q050v <- .emp_qtl(vv, 0.5)
      q95v  <- .emp_qtl(vv, 0.95); q975v <- .emp_qtl(vv, 0.975)
      iw90  <- if (length(vv)) q95v - q05v else NA_real_
      iw95  <- if (length(vv)) q975v - q025v else NA_real_
      bias  <- if (!is.na(obs_val) && !is.na(bmean))
        bmean - obs_val else NA_real_
      k <- k + 1L
      out[[k]] <- data.frame(
        level               = cb$level,
        stratum             = cb$stratum,
        bootstrap_mode      = cb$bootstrap_mode,
        n_sampled           = as.integer(cb$n_sampled),
        n_pool              = as.integer(cb$n_pool),
        n_outcomes_observed = as.integer(cb$n_outcomes_observed),
        n_sources_observed  = as.integer(cb$n_sources_observed),
        metric              = m,
        observed_value      = obs_val,
        bootstrap_mean      = bmean,
        bootstrap_sd        = bsd,
        q025 = q025v, q05 = q05v, q050 = q050v,
        q95  = q95v,  q975 = q975v,
        interval_width_90   = iw90,
        interval_width_95   = iw95,
        bias_vs_observed    = bias,
        n_bootstrap         = length(vv),
        B                   = as.integer(max(sub$B, na.rm = TRUE)),
        stringsAsFactors    = FALSE)
    }
  }
  out <- out[!vapply(out, is.null, logical(1))]
  do.call(rbind, out)
}

# Filter the curve summary to each group's observed sample size.
.emp_observed_size_intervals <- function(summary_df) {
  if (is.null(summary_df) || !nrow(summary_df)) return(NULL)
  obs_n <- ifelse(summary_df$bootstrap_mode == .EMP_MODE_OUTCOME,
                  summary_df$n_outcomes_observed,
                  summary_df$n_sources_observed)
  keep <- !is.na(obs_n) &
          as.integer(summary_df$n_sampled) == as.integer(obs_n)
  summary_df[keep, , drop = FALSE]
}

# --- report writer ------------------------------------------------------

.emp_md_table <- function(df, cols = names(df), digits = 4L) {
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

.emp_write_report <- function(path, B, n_grid, modes, validation,
                              registry_path, inserted_observed,
                              observed_intervals) {
  L <- character(0); ad <- function(...) L <<- c(L, paste0(...))
  ad("# Empirical resampling report (Q2)")
  ad("")
  ad("Question: If we resample the empirical nutrition corpus, how ",
     "stable are the observed rigor profiles as n_outcomes grows?")
  ad("")
  ad("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  ad("")
  ad("## What was run")
  ad("- Registry: `", registry_path, "`")
  ad("- Outcomes: ", validation$n_rows, " | strata: ",
     validation$n_strata, " | source_article x stratum clusters: ",
     validation$n_sources)
  ad("- Bootstrap modes: ", paste(modes, collapse = ", "))
  ad("- B = ", B,
     " replicates per (level, group, mode, n_sampled)")
  ad("- Requested n_grid = c(", paste(n_grid, collapse = ", "), ")")
  ad("- Observed n values inserted into the grid for each (group, ",
     "mode) so the observed-size interval slice is always present: ",
     if (isTRUE(inserted_observed)) "yes" else "no")
  ad("")
  ad("## Headline corpus observed-size intervals (primary rigor)")
  head_metrics <- c("median_log10BF_rigor",
                    "p_rigor_direction_effect",
                    "p_clean_effect_supported",
                    "p_inconclusive_clean_evidence")
  show <- if (!is.null(observed_intervals))
    observed_intervals[observed_intervals$level == "corpus" &
                       observed_intervals$metric %in% head_metrics, ,
                       drop = FALSE] else NULL
  ad(.emp_md_table(
    show[, c("bootstrap_mode", "metric", "observed_value",
             "bootstrap_mean", "bootstrap_sd",
             "q05", "q95", "n_sampled", "B"), drop = FALSE]))
  ad("")
  ad("## Files written")
  ad("- `empirical_resampling_observed.csv`            ",
     "(un-resampled empirical stratum + corpus summaries)")
  ad("- `empirical_resampling_size_curve.csv`          ",
     "(raw draws: level, stratum, bootstrap_mode, n_sampled, ",
     "n_pool, n_outcomes_observed, n_sources_observed, ",
     "bootstrap_id, seed, B + rigor/component metric columns)")
  ad("- `empirical_resampling_size_curve_summary.csv`  ",
     "(per (level, stratum, mode, n_sampled, metric) interval-style ",
     "summary: observed_value, bootstrap_mean/sd, q025/q05/q050/q95/",
     "q975, interval_width_{90,95}, bias_vs_observed, n_bootstrap, ",
     "B, n_pool, n_outcomes_observed, n_sources_observed)")
  ad("- `empirical_resampling_observed_size_intervals.csv` ",
     "(observed-size slice of the curve: ",
     "n_sampled == n_outcomes_observed in `outcome` mode, ",
     "n_sampled == n_sources_observed in `source_cluster` mode)")
  ad("- `empirical_resampling_report.md`               (this file)")
  ad("")
  ad("## Scope")
  ad("- Empirical only. Reads only the empirical v4 outcome registry; ",
     "never touches output_sim_v30/, never calls RoBMA / batch_fit().")
  ad("- Bootstrap with replacement. `outcome` mode resamples outcome ",
     "rows within each stratum / across the corpus; `source_cluster` ",
     "mode resamples source_article clusters, preserving cluster ",
     "multiplicity via `boot_cluster_instance`.")
  ad("- `n_sampled` counts outcome-level meta-analyses (or source ",
     "clusters when mode = `source_cluster`); it does NOT count ",
     "primary studies inside a meta-analysis. The k-studies dimension ",
     "lives elsewhere.")
  writeLines(L, path)
  invisible(path)
}

# --- public workflow ----------------------------------------------------

#' Q2 empirical resampling / scaling. The only public workflow call.
#'
#' Loads the empirical v4 outcome registry, computes observed
#' stratum + corpus summaries, runs an outcome-level and
#' source_article-cluster bootstrap scaling curve across `n_grid`
#' (with each (group, mode)'s observed n auto-inserted), summarizes
#' the curve, slices out the observed-size intervals, and writes
#' five stable files + a Q2 report.
#'
#' Stable filenames (no `_pilot`, no `B` / `n_grid` / `mode` suffix;
#' state lives in row columns):
#'
#'   simulation/results/empirical_resampling/
#'   ├── empirical_resampling_observed.csv
#'   ├── empirical_resampling_size_curve.csv
#'   ├── empirical_resampling_size_curve_summary.csv
#'   ├── empirical_resampling_observed_size_intervals.csv
#'   └── empirical_resampling_report.md
#'
#' @param B Bootstrap replicate count (default 1000).
#' @param n_grid Sample sizes to evaluate (default dense 5..30 plus
#'   c(35, 40, 50, 75, 100)). Each (group, mode)'s observed n is
#'   auto-inserted.
#' @param modes Bootstrap modes ("outcome" and / or "source_cluster";
#'   default both).
#' @param root Empirical output root (default "output").
#' @param results_dir Output directory (default
#'   "simulation/results/empirical_resampling").
#' @param workers Optional integer; default reads
#'   EMP_RESAMPLING_WORKERS env var (default 1). Pre-computed
#'   per-replicate seeds keep results byte-identical regardless of
#'   worker count.
#' @param base_seed Seed base; per-(plan, b) seeds are derived from
#'   this so results are byte-identical across worker counts.
#' @param write If TRUE (default), writes the five stable files.
#' @param verbose Per-plan progress messages.
#' @return invisible list(observed, size_curve_draws,
#'   size_curve_summary, observed_size_intervals, validation, files).
emp_run_resampling <- function(
    # B tiers: 500 dev / 5000 internal high-precision / 15000
    # final-publication. Pass B explicitly for final runs.
    B           = 500L,
    n_grid      = c(5:30, 35L, 40L, 50L, 75L, 100L),
    modes       = c("outcome", "source_cluster"),
    root        = "output",
    results_dir = file.path("simulation", "results",
                            "empirical_resampling"),
    workers     = NULL,
    base_seed   = .EMP_DEFAULT_BASE_SEED,
    write       = TRUE,
    verbose     = TRUE) {
  B      <- as.integer(B)
  n_grid <- sort(unique(as.integer(n_grid)))
  modes  <- match.arg(modes,
                      choices = c(.EMP_MODE_OUTCOME, .EMP_MODE_CLUSTER),
                      several.ok = TRUE)
  if (B < 1L) stop("emp_run_resampling: B must be >= 1.")
  if (length(n_grid) == 0L || any(n_grid <= 0L))
    stop("emp_run_resampling: n_grid must be positive integers.")
  if (length(modes) == 0L)
    stop("emp_run_resampling: at least one mode required.")

  reg <- emp_read_outcome_registry(root = root)
  v   <- emp_validate_registry(reg, require_ok = TRUE)
  if (isTRUE(verbose))
    message(sprintf("[emp] registry: %s | %d rows, %d strata, %d sources",
                    attr(reg, "registry_path"), v$n_rows, v$n_strata,
                    v$n_sources))

  # Observed (un-resampled) stratum + corpus summaries.
  obs_st <- emp_stratum_summary(reg)
  obs_co <- emp_corpus_summary(reg)
  observed <- rbind(obs_st, obs_co)

  # Scaling curve (covers stratum + corpus, both modes).
  draws <- .emp_run_size_curve(reg, n_grid = n_grid, modes = modes,
                                B = B, base_seed = base_seed,
                                workers = workers, verbose = verbose)
  summary_df <- .emp_summarize_size_curve(draws, observed)
  intervals  <- .emp_observed_size_intervals(summary_df)

  files <- character(0)
  if (isTRUE(write)) {
    if (!dir.exists(results_dir)) dir.create(results_dir, recursive = TRUE)
    wr <- function(d, f) { p <- file.path(results_dir, f)
      utils::write.csv(d, p, row.names = FALSE); p }
    files <- c(files,
      wr(observed,   "empirical_resampling_observed.csv"),
      wr(draws,      "empirical_resampling_size_curve.csv"),
      wr(summary_df, "empirical_resampling_size_curve_summary.csv"),
      wr(intervals,  "empirical_resampling_observed_size_intervals.csv"))
    rp <- file.path(results_dir, "empirical_resampling_report.md")
    .emp_write_report(rp, B = B, n_grid = n_grid, modes = modes,
                      validation = v,
                      registry_path = attr(reg, "registry_path"),
                      inserted_observed = TRUE,
                      observed_intervals = intervals)
    files <- c(files, rp)
  }

  if (isTRUE(verbose))
    message(sprintf(
      "[emp] done: B=%d, modes={%s}, %d draw rows, %d summary rows%s",
      B, paste(modes, collapse = ","),
      if (is.null(draws)) 0L else nrow(draws),
      if (is.null(summary_df)) 0L else nrow(summary_df),
      if (length(files)) paste0(" -> ", results_dir) else ""))

  invisible(list(
    registry_path           = attr(reg, "registry_path"),
    validation              = v,
    B                       = B,
    n_grid                  = n_grid,
    modes                   = modes,
    observed                = observed,
    size_curve_draws        = draws,
    size_curve_summary      = summary_df,
    observed_size_intervals = intervals,
    files                   = files))
}
