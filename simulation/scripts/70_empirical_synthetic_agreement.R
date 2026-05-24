# 70_empirical_synthetic_agreement.R - Empirical-vs-synthetic agreement.
#
# Define-only on source. Sourcing installs functions and constants and
# nothing else: it reads no registry, fits nothing, calls no
# batch_fit(), writes no CSV. Work happens only when the public
# orchestrator is explicitly called.
#
# Scope:
#   Compare the observed empirical stratum / corpus rigor profile
#   against the distribution of empirical-weighted synthetic draws
#   produced by 65_synthetic_resampling.R.
#
# The empirical "observed" side and the synthetic "draw" side are both
# produced by 60_empirical_resampling.R's emp_stratum_summary() /
# emp_corpus_summary(), so every metric is a like-for-like comparison.
#
# Primary metrics are the selected-rigor estimands; component
# diagnostics are secondary. v4 vocabulary only (stratum, corpus).
#
# Empirical-weighted synthetic source resolution. The orchestrator
# can consume the Q3 sampling output in three ways, in priority
# order:
#   1. an in-memory object (the return value of
#      sim_run_empirical_weighted_synthetic(write = FALSE) -- preferred
#      when the Q3 sampling is being rebuilt in the same R session);
#   2. existing CSVs under `ews_dir` written by an earlier
#      sim_run_empirical_weighted_synthetic() run (the stable-workflow
#      path -- avoids re-running sampling);
#   3. a freshly computed sampling (when `run_composition_if_missing
#      = TRUE`, the default); otherwise stops with a clear message
#      telling the user to run sim_run_empirical_weighted_synthetic()
#      first.
#
# Stable output layout (no replicate-count or DEV/PARTIAL filename
# suffix; partial state lives in the `dev_partial` row column and is
# noted in the report header):
#
#   simulation/results/agreement/
#   ├── empirical_synthetic_agreement_report.md
#   ├── empirical_vs_synthetic_stratum_agreement.csv
#   └── empirical_vs_synthetic_corpus_agreement.csv
#
# Public entry points:
#   sim_agreement_one_metric()
#   sim_build_stratum_agreement()       sim_build_corpus_agreement()
#   sim_load_empirical_weighted_outputs() - read Q3 sampling CSVs as
#                                           the shape
#                                           sim_run_empirical_weighted_
#                                           synthetic(write = FALSE)
#                                           would have returned. Pre-
#                                           2026-05 alias:
#                                           sim_load_composition_outputs.
#   sim_write_agreement_report()
#   sim_run_empirical_synthetic_agreement()  - the only writer; runs
#                                              only when explicitly
#                                              called

# --- define-only, sentinel-guarded sourcing ------------------------------
# 65 brings the composition helpers, the shared emp_* summarizers, and
# the primary / component metric constants.
if (!exists("sim_summarize_composition_draws", inherits = TRUE)) {
  for (.p in c("simulation/scripts/65_synthetic_resampling.R",
               "65_synthetic_resampling.R",
               file.path("scripts", "65_synthetic_resampling.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}

# Metric ordering: selected-rigor estimands first, component
# diagnostics second (reuses 65's constants so the two layers cannot
# drift apart).
.SA_PRIMARY   <- .SC_PRIMARY_METRICS
.SA_COMPONENT <- .SC_COMPONENT_METRICS

# Empirical-weighted synthetic CSVs this layer can read (when the
# orchestrator is asked to consume an on-disk sampling rather than
# recompute). Filenames renamed in the 2026-05 Q3 terminology pass;
# the variable name `.SA_COMPOSITION_DRAWS` is kept because the
# input gate function name (`sim_validate_composition_inputs`) and
# the file's draw-row tag (`composition_id`) are still the technical
# mechanism nouns.
.SA_COMPOSITION_DRAWS <- list(
  stratum = "empirical_weighted_synthetic_stratum_draws.csv",
  corpus  = "empirical_weighted_synthetic_corpus_draws.csv")
.SA_COMPOSITION_OPTIONAL <- list(
  validation = "composition_validation_checks.csv",
  weights    = "empirical_stratum_cell_weights.csv",
  coherence  = "empirical_stratum_coherence.csv")

# --- agreement metric kernel --------------------------------------------

#' Agreement of one empirical value against a synthetic draw vector.
#'
#' @param empirical_value scalar observed estimate.
#' @param synthetic_draws numeric vector of composition draws for the
#'   same metric / group.
#' @return one-row data.frame: empirical estimate, synthetic median,
#'   q05 / q95 and q025 / q975, absolute + standardized difference,
#'   empirical percentile under the synthetic distribution, interval
#'   overlap flag, n_synthetic_draws, notes. Inf-safe; never stops.
sim_agreement_one_metric <- function(empirical_value, synthetic_draws,
                                     metric = NA_character_,
                                     group = NA_character_) {
  v  <- suppressWarnings(as.numeric(synthetic_draws))
  vv <- v[!is.na(v)]
  ev <- suppressWarnings(as.numeric(empirical_value))[1]
  n  <- length(vv)

  med <- if (n) stats::median(vv) else NA_real_
  q05 <- .emp_qtl(vv, 0.05);  q95 <- .emp_qtl(vv, 0.95)
  q025 <- .emp_qtl(vv, 0.025); q975 <- .emp_qtl(vv, 0.975)
  sd_syn <- if (n > 1L) stats::sd(vv[is.finite(vv)]) else NA_real_

  abs_diff <- if (is.na(ev) || is.na(med)) NA_real_ else abs(ev - med)
  std_diff <- if (is.na(ev) || is.na(med) || is.na(sd_syn) || sd_syn == 0)
    NA_real_ else (ev - med) / sd_syn
  pct <- if (is.na(ev) || !n) NA_real_ else mean(vv <= ev)
  overlap <- if (is.na(ev) || is.na(q05) || is.na(q95)) NA
             else (ev >= q05 & ev <= q95)

  note <- character(0)
  if (!n) note <- c(note, "no synthetic draws")
  if (is.na(ev)) note <- c(note, "empirical value NA")
  if (!is.na(ev) && is.infinite(ev)) note <- c(note, "empirical Inf")
  if (n && any(is.infinite(vv))) note <- c(note, "Inf in synthetic draws")

  data.frame(
    group = group, metric = metric,
    empirical_estimate = ev,
    synthetic_median = med,
    synthetic_q05 = q05, synthetic_q95 = q95,
    synthetic_q025 = q025, synthetic_q975 = q975,
    synthetic_sd = sd_syn,
    abs_difference = abs_diff,
    std_difference = std_diff,
    empirical_percentile = pct,
    interval_overlap_90 = overlap,
    n_synthetic_draws = n,
    notes = if (length(note)) paste(note, collapse = "; ") else "",
    stringsAsFactors = FALSE)
}

# Order metrics so selected-rigor estimands are reported before
# component diagnostics, and tag metric_class accordingly.
.sa_metric_order <- function(metrics) {
  cls <- ifelse(metrics %in% .SA_PRIMARY, "primary_rigor",
         ifelse(metrics %in% .SA_COMPONENT, "secondary_component",
                "other"))
  ord <- order(match(cls, c("primary_rigor", "secondary_component",
                            "other")),
               match(metrics, c(.SA_PRIMARY, .SA_COMPONENT)))
  list(metrics = metrics[ord], class = cls[ord])
}

#' Stratum-level empirical-vs-synthetic agreement.
#'
#' @param empirical_summary emp_stratum_summary() of the empirical
#'   registry (one row per stratum).
#' @param synthetic_draws long composition draws from sim_compose_strata()
#'   (B rows per stratum).
#' @return data.frame: one row per (stratum, metric) with metric_class
#'   ordered primary-rigor first.
sim_build_stratum_agreement <- function(empirical_summary,
                                        synthetic_draws,
                                        metrics = c(.SA_PRIMARY,
                                                    .SA_COMPONENT)) {
  metrics <- intersect(metrics,
                       intersect(names(empirical_summary),
                                 names(synthetic_draws)))
  mo <- .sa_metric_order(metrics)
  out <- list()
  for (s in unique(empirical_summary$stratum)) {
    eo <- empirical_summary[empirical_summary$stratum == s, ,
                            drop = FALSE][1, ]
    dd <- synthetic_draws[synthetic_draws$stratum == s, , drop = FALSE]
    for (j in seq_along(mo$metrics)) {
      m <- mo$metrics[j]
      row <- sim_agreement_one_metric(eo[[m]], dd[[m]], metric = m,
                                      group = s)
      row$level <- "stratum"
      row$metric_class <- mo$class[j]
      out[[length(out) + 1L]] <- row
    }
  }
  res <- do.call(rbind, out)
  res[, c("level", "group", "metric", "metric_class",
          setdiff(names(res), c("level", "group", "metric",
                                "metric_class")))]
}

#' Corpus-level empirical-vs-synthetic agreement (one group "Overall").
sim_build_corpus_agreement <- function(empirical_summary,
                                       synthetic_draws,
                                       metrics = c(.SA_PRIMARY,
                                                   .SA_COMPONENT)) {
  metrics <- intersect(metrics,
                       intersect(names(empirical_summary),
                                 names(synthetic_draws)))
  mo <- .sa_metric_order(metrics)
  eo <- empirical_summary[1, ]
  out <- list()
  for (j in seq_along(mo$metrics)) {
    m <- mo$metrics[j]
    row <- sim_agreement_one_metric(eo[[m]], synthetic_draws[[m]],
                                    metric = m, group = "Overall")
    row$level <- "corpus"
    row$metric_class <- mo$class[j]
    out[[length(out) + 1L]] <- row
  }
  res <- do.call(rbind, out)
  res[, c("level", "group", "metric", "metric_class",
          setdiff(names(res), c("level", "group", "metric",
                                "metric_class")))]
}

# --- empirical-weighted synthetic source resolver -----------------------

#' Load empirical-weighted synthetic outputs from disk into the shape
#' sim_run_empirical_weighted_synthetic(write = FALSE) would have
#' returned.
#'
#' Reads the long draws (stratum + corpus) and, when available, the
#' validation-checks CSV (to reconstruct a minimal input-gate object).
#' Never recomputes anything.
#'
#' Stops if either of the two required draws CSVs is missing.
#'
#' Renamed from `sim_load_composition_outputs()` in the 2026-05 Q3
#' terminology pass; an alias under the old name is kept for one
#' release cycle.
#'
#' @return list(stratum_draws, corpus_draws, gate, weights, coherence,
#'   validation_checks, source, source_dir).
sim_load_empirical_weighted_outputs <- function(ews_dir =
    file.path("simulation", "results", "empirical_weighted_synthetic")) {
  rd <- function(f) {
    p <- file.path(ews_dir, f)
    if (!file.exists(p)) return(NULL)
    utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE)
  }
  st <- rd(.SA_COMPOSITION_DRAWS$stratum)
  co <- rd(.SA_COMPOSITION_DRAWS$corpus)
  if (is.null(st) || is.null(co))
    stop("sim_load_empirical_weighted_outputs: required Q3 sampling ",
         "CSVs not found under '", ews_dir, "/' (need '",
         .SA_COMPOSITION_DRAWS$stratum, "' and '",
         .SA_COMPOSITION_DRAWS$corpus, "'). Run ",
         "sim_run_empirical_weighted_synthetic() first, or pass ",
         "run_composition_if_missing = TRUE to ",
         "sim_run_empirical_synthetic_agreement().",
         call. = FALSE)
  vchecks  <- rd(.SA_COMPOSITION_OPTIONAL$validation)
  weights  <- rd(.SA_COMPOSITION_OPTIONAL$weights)
  coh      <- rd(.SA_COMPOSITION_OPTIONAL$coherence)

  # Reconstruct a minimal gate. dev_partial is recorded per row in
  # every Q3 sampling output; a single TRUE means the sampling was
  # run with allow_partial = TRUE on an incomplete library.
  partial <- isTRUE(any(c(st$dev_partial, co$dev_partial)
                        %in% c(TRUE, "TRUE")))
  gate_problem <- NA_character_
  gate_value   <- NA_real_
  if (!is.null(vchecks) && "check" %in% names(vchecks)) {
    ig <- vchecks[vchecks$check == "input_gate", , drop = FALSE]
    if (nrow(ig)) {
      gate_problem <- ig$detail[1]
      gate_value   <- suppressWarnings(as.numeric(ig$value[1]))
    }
  }
  gate <- list(
    ok            = !partial,
    allow_partial = partial,
    partial       = partial,
    problems      = if (!is.na(gate_problem) && nzchar(gate_problem) &&
                        gate_problem != "library composition-ready")
                      gate_problem else character(0),
    summary       = list(
      n_rows                 = nrow(co) * 0L + nrow(st) + nrow(co),
      composition_dev_partial = partial,
      validation_gate_value  = gate_value))

  list(stratum_draws     = st,
       corpus_draws      = co,
       gate              = gate,
       weights           = weights,
       coherence         = coh,
       validation_checks = vchecks,
       source            = "csv",
       source_dir        = ews_dir)
}

#' Deprecated alias for sim_load_empirical_weighted_outputs().
sim_load_composition_outputs <- function(composition_dir =
    file.path("simulation", "results", "empirical_weighted_synthetic")) {
  warning("sim_load_composition_outputs() is deprecated; use ",
          "sim_load_empirical_weighted_outputs() (same shape; arg ",
          "renamed composition_dir -> ews_dir). Default path is now ",
          "simulation/results/empirical_weighted_synthetic. Renamed ",
          "in 2026-05 Q3 terminology pass.", call. = FALSE)
  sim_load_empirical_weighted_outputs(ews_dir = composition_dir)
}

# Resolve the Q3 sampling input (in-memory > CSVs > run > stop).
.sa_resolve_composition <- function(composition,
                                    composition_dir,
                                    run_composition_if_missing,
                                    run_args,
                                    verbose) {
  if (!is.null(composition)) {
    need <- c("stratum_draws", "corpus_draws", "gate")
    miss <- setdiff(need, names(composition))
    if (length(miss))
      stop("sim_run_empirical_synthetic_agreement: in-memory ",
           "`composition` argument missing element(s): ",
           paste(miss, collapse = ", "), ".", call. = FALSE)
    composition$source     <- composition$source     %||% "in_memory"
    composition$source_dir <- composition$source_dir %||% NA_character_
    if (isTRUE(verbose))
      message("[sa] Q3 sampling source: in-memory object.")
    return(composition)
  }
  st_p <- file.path(composition_dir, .SA_COMPOSITION_DRAWS$stratum)
  co_p <- file.path(composition_dir, .SA_COMPOSITION_DRAWS$corpus)
  if (file.exists(st_p) && file.exists(co_p)) {
    if (isTRUE(verbose))
      message(sprintf("[sa] Q3 sampling source: CSVs under '%s/'.",
                      composition_dir))
    return(sim_load_empirical_weighted_outputs(composition_dir))
  }
  if (isTRUE(run_composition_if_missing)) {
    if (isTRUE(verbose))
      message("[sa] Q3 sampling source: running ",
              "sim_run_empirical_weighted_synthetic() (missing CSVs).")
    comp <- do.call(sim_run_empirical_weighted_synthetic, run_args)
    comp$source     <- "fresh_run"
    comp$source_dir <- comp$results_dir %||% composition_dir
    return(comp)
  }
  stop("sim_run_empirical_synthetic_agreement: no Q3 empirical-",
       "weighted synthetic sampling available. Pass `composition = ",
       "sim_run_empirical_weighted_synthetic(write = FALSE)`, or ",
       "run sim_run_empirical_weighted_synthetic() first so '",
       composition_dir, "/' has the Q3 draw CSVs, or set ",
       "run_composition_if_missing = TRUE to recompute now.",
       call. = FALSE)
}

# --- markdown report -----------------------------------------------------

.sa_md_table <- function(df, cols = names(df), digits = 4L) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0L)
    return("- (no rows)")
  df <- df[, intersect(cols, names(df)), drop = FALSE]
  head <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep  <- paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|")
  fmt <- function(v) {
    if (is.logical(v))
      vapply(v, function(x) if (is.na(x)) "NA"
             else if (isTRUE(x)) "TRUE" else "FALSE", character(1))
    else if (is.numeric(v))
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

#' Write the concise empirical-vs-synthetic agreement report.
#'
#' Writes ONLY the single path the caller passes. Descriptive only.
sim_write_agreement_report <- function(path,
                                       composition,
                                       empirical_validation,
                                       inventory,
                                       stratum_agreement,
                                       corpus_agreement,
                                       B,
                                       pool_key,
                                       smoothing,
                                       kappa = NA_real_,
                                       support_scope = NA_character_,
                                       loaded_settings = list(),
                                       config_mismatches = character(0),
                                       allow_config_mismatch = FALSE,
                                       agreement_dir = NA_character_) {
  L <- character(0); ad <- function(...) L <<- c(L, paste0(...))
  gate <- composition$gate
  is_partial <- isTRUE(gate$partial)

  ad("# Empirical vs empirical-weighted synthetic composition report (Q3)")
  ad("")
  ad("Question: Given empirical-derived cell distributions, how do ",
     "synthetic samples with those distributions behave when compared ",
     "to each observed empirical stratum / corpus profile?")
  ad("")
  ad("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
     if (is_partial) "  **DEV/PARTIAL**" else "")
  ad("")
  ad("## What this report is")
  ad("The synthetic distribution is produced by empirical-weighted ",
     "composition: for each draw, fitted synthetic rows are sampled ",
     "according to each empirical stratum's fitted-cell weights, then ",
     "summarized with the same reducers used for empirical summaries. ",
     "Each observed empirical stratum / corpus rigor estimate is then ",
     "compared to that empirical-weighted synthetic composition ",
     "distribution. An empirical estimate inside the synthetic 90% band ",
     "is consistent with the empirical-weighted composition; outside ",
     "means the composition does not currently reproduce that observed ",
     "value at the requested precision.")
  ad("")
  ad("## Inputs")
  src <- composition$source %||% "unknown"
  src_human <- switch(src,
                       in_memory = "in-memory composition object",
                       csv       = sprintf("composition CSVs under `%s/`",
                                           composition$source_dir),
                       fresh_run = sprintf("freshly run composition (output dir `%s/`)",
                                           composition$source_dir),
                       src)
  ad("- Composition source: ", src_human, ".")
  if (!is.null(empirical_validation))
    ad("- Empirical: ", empirical_validation$n_rows, " outcomes, ",
       empirical_validation$n_strata, " strata, ",
       empirical_validation$n_sources, " source_article x stratum ",
       "clusters.")
  if (!is.null(inventory) && !is.null(inventory$overall))
    ad("- Synthetic library: ", inventory$overall$n_generated_total,
       " generated CSVs (", inventory$overall$generated_reps_min, "..",
       inventory$overall$generated_reps_max, "/cell, ",
       if (isTRUE(inventory$overall$generated_reps_uniform)) "uniform"
       else "uneven",
       "); ", inventory$overall$n_fit_total, " fitted sidecar rows; ",
       "library_status = `", inventory$overall$library_status, "`.")
  ad("- Run settings (requested): B = ", B,
     ", pool_key = `", pool_key,
     "`, smoothing = `", smoothing,
     "`, kappa = ",
     if (identical(smoothing, "eb_corpus") &&
         is.finite(suppressWarnings(as.numeric(kappa))))
       sprintf("%g", as.numeric(kappa)) else "n/a",
     ", support_scope = `", support_scope, "`.")
  if (length(loaded_settings)) {
    fmt_loaded <- function(v) {
      if (is.null(v) || (length(v) == 1L && is.na(v))) "n/a"
      else as.character(v)
    }
    ad("- Run settings (loaded from Q3 CSVs): B_stratum = ",
       fmt_loaded(loaded_settings$B_stratum),
       ", B_corpus = ", fmt_loaded(loaded_settings$B_corpus),
       ", pool_key = `", fmt_loaded(loaded_settings$pool_key),
       "`, smoothing = `", fmt_loaded(loaded_settings$smoothing),
       "`, kappa = ", fmt_loaded(loaded_settings$kappa),
       ", support_scope = `",
       fmt_loaded(loaded_settings$support_scope), "`.")
  }
  if (length(config_mismatches)) {
    ad("- **STALE-CONFIG GUARD**: requested Q3 settings differ from ",
       "the loaded Q3 CSVs",
       if (isTRUE(allow_config_mismatch))
         " (tolerated; `allow_config_mismatch = TRUE`)"
       else " (this should not happen; the guard stops by default)",
       ":")
    for (m in config_mismatches) ad("  - ", m)
  }
  ad("- B / n_reps distinction: `B` is the empirical-weighted ",
     "sampling replicate count (Monte-Carlo precision); `n_reps` is ",
     "the per-target-cell depth of the fitted synthetic library ",
     "(see Synthetic library line above). Increasing B reduces ",
     "Monte-Carlo noise but does not smooth away finite-support ",
     "roughness; that is a function of `n_reps`.")
  if (is_partial) {
    ad("- **DEV/PARTIAL**: the composition that produced these ",
       "agreement numbers was run with allow_partial = TRUE on an ",
       "incomplete library; every row carries `dev_partial = TRUE`. ",
       "Do not read these as operating characteristics.")
    if (length(gate$problems))
      for (p in gate$problems) ad("  - gate note: ", p)
  }
  ad("")
  ad("## Corpus-level agreement (primary-rigor metrics)")
  if (!is.null(corpus_agreement) && nrow(corpus_agreement)) {
    co_show <- corpus_agreement[
      (corpus_agreement$metric_class %||% "") == "primary_rigor", ,
      drop = FALSE]
    if (!nrow(co_show)) co_show <- corpus_agreement
    ad(.sa_md_table(co_show,
                    cols = c("metric", "empirical_estimate",
                             "synthetic_median",
                             "synthetic_q05", "synthetic_q95",
                             "abs_difference", "interval_overlap_90",
                             "n_synthetic_draws"),
                    digits = 4L))
  } else {
    ad("- (no corpus agreement rows)")
  }
  ad("")
  ad("## Stratum-level agreement (primary-rigor metric counts)")
  if (!is.null(stratum_agreement) && nrow(stratum_agreement)) {
    sa <- stratum_agreement
    if ("metric_class" %in% names(sa))
      sa <- sa[sa$metric_class == "primary_rigor", , drop = FALSE]
    if (nrow(sa)) {
      ovl <- ifelse(sa$interval_overlap_90 %in% c(TRUE, "TRUE"),
                    "within 90% band",
              ifelse(sa$interval_overlap_90 %in% c(FALSE, "FALSE"),
                    "outside 90% band", "undeterminable"))
      tab <- as.data.frame.matrix(
        table(metric = sa$metric, overlap = ovl))
      tab <- cbind(metric = rownames(tab), tab,
                   stringsAsFactors = FALSE)
      rownames(tab) <- NULL
      ad("Counts of (stratum, metric) cells by 90%-band membership ",
         "(rows = primary-rigor metrics):")
      ad("")
      ad(.sa_md_table(tab))
    } else {
      ad("- (no primary-rigor stratum rows)")
    }
  } else {
    ad("- (no stratum agreement rows)")
  }
  ad("")
  ad("## Files written")
  if (!is.na(agreement_dir))
    ad("All in `", agreement_dir, "/`:")
  ad("- `empirical_vs_synthetic_stratum_agreement.csv` ",
     "(per (stratum, metric) row; carries level, metric_class, ",
     "empirical / synthetic q05/q95 + q025/q975, abs_difference, ",
     "std_difference, empirical_percentile, interval_overlap_90, ",
     "n_synthetic_draws, comparison_family, composition_source, ",
     "pool_key, smoothing, B, empirical_n_outcomes, dev_partial)")
  ad("- `empirical_vs_synthetic_corpus_agreement.csv` (same shape ",
     "for the corpus row)")
  ad("")
  ad("## Figure ledger")
  ad("")
  ad("| figure | question | input_csv | what_it_answers | what_it_does_not_answer |")
  ad("|---|---|---|---|---|")
  ad("| `empirical_vs_synthetic_stratum_agreement_primary_rigor.pdf` | ",
     "Q3 | `empirical_vs_synthetic_stratum_agreement.csv` | per ",
     "(stratum, primary-rigor metric), where the empirical point sits ",
     "relative to the empirical-weighted synthetic composition band | ",
     "how either side behaves at sample sizes other than the ",
     "observed empirical_n_outcomes (use the size-curve figures) |")
  ad("| `empirical_vs_synthetic_corpus_agreement_primary_rigor.pdf` | ",
     "Q3 | `empirical_vs_synthetic_corpus_agreement.csv` | same at ",
     "corpus level | per-stratum structure |")
  ad("")
  ad("## Scope")
  ad("- Descriptive only. The agreement tables make no ",
     "operating-characteristic claim; an empirical point outside the ",
     "empirical-weighted synthetic composition band tells you the ",
     "composition does not currently reproduce that observed quantity ",
     "at the requested B / library size, not that anything is broken.")
  ad("- Empirical and synthetic summaries share one reducer (",
     "`emp_stratum_summary()` / `emp_corpus_summary()`); the gate that ",
     "lets composition run at all (in 65) is replicate-count agnostic ",
     "via `sim_inventory_library()`.")
  writeLines(L, path)
  invisible(path)
}

# --- orchestrator (the only writer; runs only when called) ---------------

#' Run empirical-vs-synthetic agreement end to end.
#'
#' Resolves the composition input (in-memory > CSVs > fresh run) and
#' writes the two stable agreement tables + the report. The only
#' function here that writes, and only when called.
#'
#' @param empirical_root    Empirical output root (default "output").
#' @param sim_output_root   Simulation output root (default
#'   "output_sim_v30"); used only when Q3 sampling is re-run.
#' @param data_root / latent_root / vintage Forwarded to Q3 sampling
#'   when re-run.
#' @param composition_dir   Where the Q3 empirical-weighted synthetic
#'   sampling CSVs live (default
#'   "simulation/results/empirical_weighted_synthetic"). The argument
#'   name retains the `composition_` prefix for one release cycle; new
#'   code should plumb through to this default unchanged.
#' @param agreement_dir     Where to write agreement outputs (default
#'   "simulation/results/agreement").
#' @param composition       Optional in-memory Q3 sampling object
#'   (return value of sim_run_empirical_weighted_synthetic(write =
#'   FALSE)). Takes priority over composition_dir.
#' @param run_composition_if_missing If TRUE (default) and no usable
#'   Q3 sampling is available, call
#'   sim_run_empirical_weighted_synthetic() with the supplied
#'   B / pool_key / smoothing / workers etc. and `write = FALSE`. If
#'   FALSE, stop with a clear message.
#' @param B / pool_key / smoothing / kappa / support / workers /
#'   allow_partial Forwarded to sim_run_empirical_weighted_synthetic()
#'   when re-run. Defaults match the recommended Q3 path: `smoothing =
#'   "eb_corpus"`, `kappa = 4`, `support = "occupied"`,
#'   `pool_key = "target"`.
#' @param allow_config_mismatch The Q3 **stale-config guard**. If
#'   FALSE (default), the function stops when the loaded Q3 CSVs
#'   report a B / pool_key / smoothing / kappa / support_scope that
#'   does not match the requested args. Set to TRUE to override (e.g.
#'   when reusing an existing CSV intentionally with a different B
#'   request). Loaded B is inferred from
#'   `length(unique(composition_id))` in the stratum + corpus draw
#'   CSVs.
#' @param allow_B_mismatch Deprecated alias for
#'   `allow_config_mismatch` (the guard now covers more than B);
#'   emits a soft warning when passed and forwards the value. Will be
#'   removed in a future cycle.
#' @param write             If TRUE (default), writes CSVs + report.
#' @param verbose           Per-stage progress messages.
#' @return invisible list(gate, stratum_agreement, corpus_agreement,
#'   composition_source, loaded_settings, files, agreement_dir).
sim_run_empirical_synthetic_agreement <- function(
    empirical_root   = "output",
    sim_output_root  = "output_sim_v30",
    data_root        = "data",
    latent_root      = "simulation/latent",
    vintage          = "2026",
    composition_dir  = file.path("simulation", "results",
                                 "empirical_weighted_synthetic"),
    agreement_dir    = file.path("simulation", "results", "agreement"),
    composition      = NULL,
    run_composition_if_missing = TRUE,
    # B tiers: 500 dev / 5000 internal high-precision / 15000
    # final-publication. Pass B explicitly for final runs.
    B                = 500L,
    pool_key         = "target",
    smoothing        = "eb_corpus",
    kappa            = 4,
    support          = "occupied",
    workers              = NULL,
    allow_partial        = FALSE,
    allow_config_mismatch = FALSE,
    allow_B_mismatch     = NULL,   # deprecated alias
    write                = TRUE,
    verbose              = TRUE) {
  if (!is.null(allow_B_mismatch)) {
    warning("`allow_B_mismatch` is deprecated; use ",
            "`allow_config_mismatch` (the Q3 stale-config guard now ",
            "covers B + pool_key + smoothing + kappa + support_scope).",
            call. = FALSE)
    allow_config_mismatch <- isTRUE(allow_B_mismatch)
  }
  B <- as.integer(B)
  run_args <- list(
    empirical_root   = empirical_root,
    sim_output_root  = sim_output_root,
    data_root        = data_root,
    latent_root      = latent_root,
    vintage          = vintage,
    results_dir      = composition_dir,
    B                = B,
    pool_key         = pool_key,
    smoothing        = smoothing,
    kappa            = kappa,
    support          = support,
    workers          = workers,
    allow_partial    = allow_partial,
    write            = FALSE,
    verbose          = verbose)
  comp <- .sa_resolve_composition(
    composition = composition,
    composition_dir = composition_dir,
    run_composition_if_missing = run_composition_if_missing,
    run_args = run_args,
    verbose = verbose)

  # --- stale-B / stale-config hardening -----------------------------------
  # Infer (B, pool_key, smoothing, kappa, support_scope) from the
  # loaded Q3 CSVs (or the in-memory object) and stop on any mismatch
  # against the requested args, unless allow_B_mismatch = TRUE.
  # Missing columns on legacy CSVs are treated as "unknown" and never
  # trigger a mismatch on their own.
  .infer_scalar <- function(df, col) {
    if (is.null(df) || !nrow(df) || !col %in% names(df)) return(NA)
    vals <- unique(df[[col]])
    vals <- vals[!is.na(vals)]
    if (!length(vals)) return(NA)
    if (length(vals) > 1L) return(paste(vals, collapse = "|"))
    vals[[1]]
  }
  .infer_B <- function(df) {
    if (is.null(df) || !nrow(df) ||
        !"composition_id" %in% names(df)) return(NA_integer_)
    cid <- suppressWarnings(as.integer(df$composition_id))
    cid <- cid[!is.na(cid)]
    if (!length(cid)) NA_integer_ else as.integer(length(unique(cid)))
  }
  .first_known <- function(...) {
    args <- list(...)
    for (v in args) if (length(v) == 1L && !is.na(v)) return(v)
    NA
  }
  loaded <- list(
    B_stratum     = .infer_B(comp$stratum_draws),
    B_corpus      = .infer_B(comp$corpus_draws),
    pool_key      = .first_known(
      .infer_scalar(comp$stratum_draws, "pool_key"),
      .infer_scalar(comp$corpus_draws,  "pool_key")),
    smoothing     = .first_known(
      .infer_scalar(comp$stratum_draws, "smoothing"),
      .infer_scalar(comp$corpus_draws,  "smoothing")),
    kappa         = .first_known(
      .infer_scalar(comp$stratum_draws, "kappa"),
      .infer_scalar(comp$corpus_draws,  "kappa")),
    support_scope = .first_known(
      .infer_scalar(comp$stratum_draws, "support_scope"),
      .infer_scalar(comp$corpus_draws,  "support_scope")))
  comp$loaded_settings <- loaded
  comp$requested_settings <- list(
    B = as.integer(B), pool_key = pool_key, smoothing = smoothing,
    kappa = if (identical(smoothing, "eb_corpus"))
              as.numeric(kappa) else NA_real_,
    support_scope = support)

  mismatches <- character(0)
  add <- function(field, requested, loaded_val) {
    if (is.null(loaded_val) || (length(loaded_val) == 1L &&
                                is.na(loaded_val))) return()
    if (!identical(as.character(requested), as.character(loaded_val)))
      mismatches[[length(mismatches) + 1L]] <<- sprintf(
        "%s: requested=%s, loaded=%s",
        field, as.character(requested), as.character(loaded_val))
  }
  if (!is.na(loaded$B_stratum) && loaded$B_stratum != as.integer(B))
    mismatches <- c(mismatches, sprintf(
      paste0("B (stratum draws): requested=%d, loaded=%d ",
             "(inferred from unique composition_id count)"),
      as.integer(B), as.integer(loaded$B_stratum)))
  if (!is.na(loaded$B_corpus) && loaded$B_corpus != as.integer(B))
    mismatches <- c(mismatches, sprintf(
      "B (corpus draws): requested=%d, loaded=%d",
      as.integer(B), as.integer(loaded$B_corpus)))
  add("pool_key",      pool_key,  loaded$pool_key)
  add("smoothing",     smoothing, loaded$smoothing)
  if (identical(smoothing, "eb_corpus") &&
      !is.na(suppressWarnings(as.numeric(loaded$kappa)))) {
    kl <- as.numeric(loaded$kappa)
    if (!identical(as.numeric(kappa), kl))
      mismatches <- c(mismatches, sprintf(
        "kappa: requested=%g, loaded=%g", as.numeric(kappa), kl))
  }
  add("support_scope", support,   loaded$support_scope)

  if (length(mismatches) && identical(comp$source, "csv") &&
      !isTRUE(allow_config_mismatch)) {
    stop("sim_run_empirical_synthetic_agreement: Q3 **stale-config ",
         "guard** tripped -- requested settings do not match the ",
         "loaded Q3 CSVs:\n  - ",
         paste(mismatches, collapse = "\n  - "),
         "\nEither rerun sim_run_empirical_weighted_synthetic() with ",
         "the requested settings, or pass allow_config_mismatch = ",
         "TRUE to proceed with the loaded CSVs.", call. = FALSE)
  } else if (length(mismatches) && isTRUE(verbose)) {
    message("[sa] WARNING: Q3 stale-config mismatch tolerated ",
            "(allow_config_mismatch = TRUE or source != csv):\n  - ",
            paste(mismatches, collapse = "\n  - "))
  }
  comp$config_mismatches <- mismatches

  emp <- sim_load_empirical_registry(root = empirical_root)
  obs_st <- emp_stratum_summary(emp)
  obs_co <- emp_corpus_summary(emp)
  emp_val <- attr(emp, "validation")

  st_ag <- sim_build_stratum_agreement(obs_st, comp$stratum_draws)
  co_ag <- sim_build_corpus_agreement(obs_co, comp$corpus_draws)
  partial <- isTRUE(comp$gate$partial)

  # Per-stratum empirical n_outcomes (observed sample size that the
  # composition preserves on each draw); attached to every stratum row.
  emp_n_by_strat <- tapply(obs_st$n_outcomes, obs_st$stratum,
                           function(x) suppressWarnings(as.integer(x[1])))
  emp_n_corpus   <- suppressWarnings(as.integer(obs_co$n_outcomes[1]))

  # Comparison family + provenance + composition settings. These live in
  # every row so any downstream join/visual knows the mechanism. The
  # `loaded_*` columns carry what was actually in the Q3 CSV; the bare
  # column carries the requested setting (they match unless allow_B_-
  # mismatch = TRUE was passed).
  .stamp <- function(df, level) {
    df$comparison_family   <- "empirical_weighted_synthetic_composition"
    df$composition_source  <- comp$source %||% NA_character_
    df$pool_key            <- pool_key
    df$smoothing           <- smoothing
    df$kappa               <- if (identical(smoothing, "eb_corpus"))
                                as.numeric(kappa) else NA_real_
    df$support_scope       <- support
    df$B                   <- as.integer(B)
    df$loaded_B_stratum    <- if (length(loaded$B_stratum) &&
                                  !is.na(loaded$B_stratum))
                                as.integer(loaded$B_stratum)
                              else NA_integer_
    df$loaded_B_corpus     <- if (length(loaded$B_corpus) &&
                                  !is.na(loaded$B_corpus))
                                as.integer(loaded$B_corpus)
                              else NA_integer_
    df$loaded_pool_key     <- as.character(loaded$pool_key)
    df$loaded_smoothing    <- as.character(loaded$smoothing)
    df$loaded_kappa        <- suppressWarnings(as.numeric(loaded$kappa))
    df$loaded_support_scope <- as.character(loaded$support_scope)
    df$config_mismatch_flag <- length(comp$config_mismatches) > 0L
    df$dev_partial         <- partial
    if (level == "stratum") {
      df$empirical_n_outcomes <- as.integer(emp_n_by_strat[df$group])
    } else {
      df$empirical_n_outcomes <- emp_n_corpus
    }
    df
  }
  st_ag <- .stamp(st_ag, "stratum")
  co_ag <- .stamp(co_ag, "corpus")

  files <- character(0)
  if (isTRUE(write)) {
    if (!dir.exists(agreement_dir))
      dir.create(agreement_dir, recursive = TRUE)
    wr <- function(d, f) { p <- file.path(agreement_dir, f)
      utils::write.csv(d, p, row.names = FALSE); p }
    files <- c(
      wr(st_ag, "empirical_vs_synthetic_stratum_agreement.csv"),
      wr(co_ag, "empirical_vs_synthetic_corpus_agreement.csv"))
    rp <- file.path(agreement_dir,
                    "empirical_synthetic_agreement_report.md")
    sim_write_agreement_report(
      rp, composition = comp, empirical_validation = emp_val,
      inventory = comp$inventory, stratum_agreement = st_ag,
      corpus_agreement = co_ag, B = B, pool_key = pool_key,
      smoothing = smoothing, kappa = kappa, support_scope = support,
      loaded_settings = loaded,
      config_mismatches = comp$config_mismatches,
      allow_config_mismatch = isTRUE(allow_config_mismatch),
      agreement_dir = agreement_dir)
    files <- c(files, rp)
  }

  if (isTRUE(verbose)) {
    n_strata          <- length(unique(st_ag$group))
    n_metrics_stratum <- length(unique(st_ag$metric))
    n_metrics_corpus  <- length(unique(co_ag$metric))
    mc <- if ("metric_class" %in% names(st_ag)) st_ag$metric_class
          else if ("metric_class" %in% names(co_ag)) co_ag$metric_class
          else character(0)
    n_primary   <- length(unique(st_ag$metric[mc == "primary_rigor"]))
    n_component <- length(unique(
      st_ag$metric[mc == "secondary_component"]))
    message(sprintf(paste0(
      "[sa] done: source=%s, partial=%s; stratum=%d rows ",
      "(%d strata x %d metrics), corpus=%d rows (1 x %d metrics); ",
      "primary=%d, component=%d%s"),
      comp$source %||% NA_character_, as.character(partial),
      nrow(st_ag), n_strata, n_metrics_stratum,
      nrow(co_ag), n_metrics_corpus,
      n_primary, n_component,
      if (length(files))
        sprintf(" -> %s", agreement_dir) else ""))
    if (isTRUE(partial))
      message("[sa] DEV/PARTIAL: rerun after the full simulation ",
              "library is complete for final figures.")
  }

  invisible(list(
    gate                = comp$gate,
    composition_source  = comp$source %||% NA_character_,
    requested_settings  = comp$requested_settings,
    loaded_settings     = loaded,
    config_mismatches   = comp$config_mismatches,
    stratum_agreement   = st_ag,
    corpus_agreement    = co_ag,
    files               = files,
    agreement_dir       = agreement_dir))
}
