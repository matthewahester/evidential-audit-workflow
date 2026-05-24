# 45_study_geometry.R — Empirical–synthetic input-geometry parity check.
#
# DEFINE-ONLY ON SOURCE. Sourcing installs functions/constants and does
# nothing else: it reads no dataset, fits nothing, calls no batch_fit(),
# writes no file, and never touches output_sim_v30, empirical output/,
# or simulation/latent/. Work happens only when sim_run_study_geometry()
# (or another entry point) is explicitly called.
#
# ── Purpose (single, focused) ────────────────────────────────────────────
# A calibration / plausibility gate that asks whether the synthetic full36
# datasets are close enough to the empirical datasets in RAW INPUT
# geometry — study count k, study-level standard errors / precision,
# total fixed-effect information, and inverse-variance weight
# concentration — that downstream RoBMA behavior on synthetic data can be
# read as plausible. The headline output is the empirical-vs-synthetic
# gate table with simple PASS/WATCH/FAIL flags; everything else is detail.
#
# In-scope questions:
#   * Are synthetic datasets close enough to empirical datasets in study count k?
#   * Are study-level SEs / precision in the right range?
#   * Is total fixed-effect information similar?
#   * Is inverse-variance weight concentration similar?
#   * Any obvious geometry mismatch that could make synthetic RoBMA
#     behavior misleading?
#
# Out-of-scope (do NOT broaden):
#   * Not a fitted-output diagnostic — never reads a sidecar, latent file,
#     output/, or output_sim_v30/.
#   * Not an information-axis expansion or a new DGM dimension.
#   * Not an operating-characteristic result — flags are heuristic
#     diagnostic labels, not manuscript claims.
#
# Stage / live-fit safety: this diagnostic is independent of the RoBMA
# fitting run; it walks only analysis-ready CSVs under data/ via the
# shared list_datasets() and is safe to run while a full36 fit is in
# progress.
#
# v4 vocabulary only (stratum, source_article, outcome_slug, dataset_id,
# analysis_id, analysis_variant, corpus_id, scheme); "topic/headline/
# author" appears only where a legacy lineage is named in a comment.
#
# Public entry points (none run on source):
#   sim_geometry_list_datasets()        sim_geometry_read_one()
#   sim_geometry_summarize_dataset()    sim_geometry_assign_synthetic_cell()
#   sim_geometry_build_summary()        sim_geometry_compare_empirical_synthetic()
#   sim_geometry_build_parity_gate()    sim_geometry_top_stratum_deviations()
#   sim_geometry_top_cell_deviations()
#   sim_run_study_geometry()            — explicit runner (only writer)

# --- define-only, sentinel-guarded sourcing ------------------------------
# scripts/00_utils.R   -> %||%, .EFFECT_INPUT_PAIRS (g/se_g-then-d/se_d order)
# scripts/10_load_data.R -> list_datasets() (v4 catalog)
# 00_sim_utils.R       -> .SIM_K_BUCKETS (shared k-sampler buckets)
# 10_sim_design.R      -> sim_load_design() (synthetic cell -> slug/band crosswalk)
# All four are define-only; sourcing installs functions only.
if (!exists("list_datasets", inherits = TRUE)) {
  for (.p in c("scripts/10_load_data.R", "10_load_data.R",
               file.path("..", "scripts", "10_load_data.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}
if (!exists(".robma_sim_utils_loaded", inherits = TRUE)) {
  for (.p in c("simulation/scripts/00_sim_utils.R",
               "00_sim_utils.R",
               file.path("scripts", "00_sim_utils.R"))) {
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

if (!exists("%||%", inherits = TRUE)) {
  `%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a
}

# --- constants -----------------------------------------------------------

# k buckets: REUSE the shared sim sampler constant; never redefine.
.SG_K_BUCKETS <- if (exists(".SIM_K_BUCKETS", inherits = TRUE)) {
  .SIM_K_BUCKETS
} else {
  warning("45_study_geometry: .SIM_K_BUCKETS not found; falling back to ",
          "the hardcoded v3.0 bucket edges. Source 00_sim_utils.R to use ",
          "the canonical constant.")
  data.frame(bucket = c("xs", "s", "m", "l"),
             k_lo = c(8L, 11L, 21L, 41L),
             k_hi = c(10L, 20L, 40L, 90L),
             prob = c(0.10, 0.45, 0.35, 0.10),
             stringsAsFactors = FALSE)
}

# Effect-size input pairs in the FIXED v4 preference order (reused from
# 00_utils.R so the accepted column set cannot drift from the fitter).
.SG_EFFECT_PAIRS <- if (exists(".EFFECT_INPUT_PAIRS", inherits = TRUE))
  .EFFECT_INPUT_PAIRS else
  list(g_se_g = c(est = "g", se = "se_g"),
       d_se_d = c(est = "d", se = "se_d"))

# Canonical sim identity values for synthetic rows in the dataset summary
# (matches sim_fit_config() defaults). Set on synthetic rows so the
# summary does not carry NA scheme/corpus_id where the correct value is
# known (the loader does not parse these from path; they are CONFIG-time).
.SG_SIM_SCHEME    <- "simulation_cell"
.SG_SIM_CORPUS_ID <- "sim_library_v30"

# --- heuristic empirical-vs-synthetic parity thresholds ------------------
#
# Diagnostic flags only, not manuscript claims. PASS = within tight band;
# WATCH = within wider band; FAIL = outside both. Difference rules use
# |empirical - synthetic|; ratio rules use empirical / synthetic.
#
# These are deliberately conservative starting heuristics, exposed as a
# single constant near the top so they are easy to read and tune.
.SG_HEADLINE_METRICS <- c(
  "median_k", "q25_k", "q75_k",
  "median_se_median", "median_fixed_info_se",
  "median_max_weight_share", "median_effective_n_weights",
  "median_log_se_sd")

.SG_THRESHOLDS <- list(
  median_k                   = list(mode = "diff",
                                    pass = 2,  watch = 5),
  q25_k                      = list(mode = "diff",
                                    pass = 2,  watch = 5),
  q75_k                      = list(mode = "diff",
                                    pass = 5,  watch = 10),
  median_se_median           = list(mode = "ratio",
                                    pass  = c(0.80, 1.25),
                                    watch = c(0.67, 1.50)),
  median_fixed_info_se       = list(mode = "ratio",
                                    pass  = c(0.80, 1.25),
                                    watch = c(0.67, 1.50)),
  median_max_weight_share    = list(mode = "ratio",
                                    pass  = c(0.80, 1.25),
                                    watch = c(0.67, 1.50)),
  median_effective_n_weights = list(mode = "ratio",
                                    pass  = c(0.80, 1.25),
                                    watch = c(0.67, 1.50)),
  median_log_se_sd           = list(mode = "ratio",
                                    pass  = c(0.80, 1.25),
                                    watch = c(0.67, 1.50)))

# Canonical dataset-summary column order. scheme / corpus_id are
# populated correctly for both empirical and synthetic rows (synthetic
# rows get the sim CONFIG identity; see sim_geometry_assign_synthetic_cell).
.SG_DATASET_COLS <- c(
  "dataset_type", "scheme", "corpus_id", "path_stratum", "stratum",
  "source_article", "source_year", "outcome_slug", "dataset_id",
  "analysis_id", "analysis_variant", "csv_path",
  "cell_slug", "synthetic_stratum", "legacy_cell_code",
  "effect_slug", "heterogeneity_slug", "bias_slug",
  "effect_band", "heterogeneity_band", "bias_band",
  "n_studies", "k", "k_bucket",
  "preferred_effect_col", "preferred_se_col",
  "effect_mean", "effect_median", "effect_sd", "effect_min", "effect_max",
  "se_min", "se_q10", "se_q25", "se_median", "se_q75", "se_q90",
  "se_max", "se_iqr", "log_se_sd",
  "inv_var_sum", "fixed_info_se",
  "max_weight_share", "top2_weight_share", "effective_n_weights",
  "weight_entropy",
  "n_nonfinite_effect", "n_nonfinite_se", "n_nonpositive_se",
  "geometry_status", "notes")

.SG_ROLLUP_STAT_COLS <- c(
  "n_datasets", "n_studies_total", "median_k", "q25_k", "q75_k",
  "min_k", "max_k", "median_se_median", "q25_se_median", "q75_se_median",
  "median_fixed_info_se", "q25_fixed_info_se", "q75_fixed_info_se",
  "median_max_weight_share", "median_top2_weight_share",
  "median_effective_n_weights", "median_log_se_sd", "n_skipped", "notes")

# --- tiny base-R reducers (NA-safe; no tidyverse attach) -----------------
.sg_num  <- function(x) suppressWarnings(as.numeric(x))
.sg_med  <- function(x) { x <- x[is.finite(x)]
  if (!length(x)) NA_real_ else stats::median(x) }
.sg_q    <- function(x, p) { x <- x[is.finite(x)]
  if (!length(x)) NA_real_
  else unname(stats::quantile(x, p, names = FALSE, type = 7)) }
.sg_minf <- function(x) { x <- x[is.finite(x)]
  if (!length(x)) NA_real_ else min(x) }
.sg_maxf <- function(x) { x <- x[is.finite(x)]
  if (!length(x)) NA_real_ else max(x) }

#' k-bucket assignment using the shared sim sampler edges; k outside the
#' design (which the synthetic generator never produces) is labelled
#' below_xs / above_l so empirical datasets stay visible.
.sg_k_bucket <- function(k, buckets = .SG_K_BUCKETS) {
  kk  <- suppressWarnings(as.integer(k))
  out <- rep(NA_character_, length(kk))
  for (i in seq_len(nrow(buckets))) {
    hit <- !is.na(kk) & kk >= buckets$k_lo[i] & kk <= buckets$k_hi[i]
    out[hit & is.na(out)] <- buckets$bucket[i]
  }
  lo <- min(buckets$k_lo); hi <- max(buckets$k_hi)
  out[is.na(out) & !is.na(kk) & kk < lo] <- "below_xs"
  out[is.na(out) & !is.na(kk) & kk > hi] <- "above_l"
  out
}

# --- dataset discovery ---------------------------------------------------

#' Discover analysis-ready study-level CSVs under data/ (v4 catalog).
#'
#' Thin wrapper over scripts/10_load_data.R::list_datasets(only_candidates
#' = TRUE): helper files are skipped by the shared is_meta_basename(), and
#' the v4 identity vocabulary is parsed once. Adds dataset_type =
#' "synthetic" when stratum starts with "sim_", else "empirical". Reads
#' NOTHING beyond the directory listing.
sim_geometry_list_datasets <- function(data_root = "data",
                                       include_empirical = TRUE,
                                       include_synthetic = TRUE) {
  cat0 <- list_datasets(root = data_root, only_candidates = TRUE)
  if (nrow(cat0) == 0L) {
    cat0$dataset_type <- character(0)
    cat0$csv_path <- character(0)
    return(cat0)
  }
  cat0$dataset_type <- ifelse(grepl("^sim_", cat0$stratum %||% ""),
                              "synthetic", "empirical")
  cat0$csv_path <- cat0$path
  keep <- rep(TRUE, nrow(cat0))
  if (!isTRUE(include_empirical))
    keep <- keep & cat0$dataset_type != "empirical"
  if (!isTRUE(include_synthetic))
    keep <- keep & cat0$dataset_type != "synthetic"
  cat0[keep, , drop = FALSE]
}

# --- one-CSV read + column standardization -------------------------------

#' Read one study-level CSV and standardize the effect/SE columns.
#'
#' Resolves the effect-size pair with the FIXED v4 preference order
#' (g/se_g first, then d/se_d). NON-FATAL by design: invalid rows are
#' counted, never error. Reads ONLY the given data/ CSV.
sim_geometry_read_one <- function(csv_path) {
  fail <- function(status, note) list(
    ok = FALSE, df = NULL, effect_value = numeric(0),
    se_value = numeric(0), preferred_effect_col = NA_character_,
    preferred_se_col = NA_character_, n_rows = 0L,
    n_nonfinite_effect = NA_integer_, n_nonfinite_se = NA_integer_,
    n_nonpositive_se = NA_integer_, status = status, note = note)

  if (!file.exists(csv_path)) return(fail("skipped", "file not found"))
  df <- tryCatch(
    utils::read.csv(csv_path, stringsAsFactors = FALSE, check.names = FALSE),
    warning = function(w) NULL, error = function(e) NULL)
  if (is.null(df) || !is.data.frame(df))
    return(fail("skipped", "unreadable (parse error)"))
  if (nrow(df) == 0L) return(fail("skipped", "empty (0 rows)"))

  nm <- names(df)
  ecol <- NA_character_; scol <- NA_character_
  for (p in .SG_EFFECT_PAIRS) {              # fixed order: g_se_g, d_se_d
    if (all(p %in% nm)) { ecol <- p[["est"]]; scol <- p[["se"]]; break }
  }
  # SE-only fallback: a recognized SE column without its estimate still
  # yields valid SE/weight geometry (effect_* become NA).
  if (is.na(scol)) {
    for (p in .SG_EFFECT_PAIRS)
      if (p[["se"]] %in% nm) { scol <- p[["se"]]; break }
  }
  if (is.na(scol))
    return(fail("skipped",
                "no usable SE column (need se_g [g/se_g] or se_d [d/se_d])"))

  se  <- .sg_num(df[[scol]])
  eff <- if (!is.na(ecol)) .sg_num(df[[ecol]]) else rep(NA_real_, nrow(df))
  n_nf_se  <- sum(!is.finite(se))
  n_np_se  <- sum(is.finite(se) & se <= 0)
  n_nf_eff <- if (!is.na(ecol)) sum(!is.finite(eff)) else NA_integer_

  good <- is.finite(se) & se > 0
  if (!is.na(ecol)) good <- good & is.finite(eff)
  if (!any(good))
    return(fail("skipped", "no finite positive-SE rows"))

  note <- if (is.na(ecol))
    sprintf("SE-only geometry (no g/d effect column); SE col '%s'", scol)
  else "ok"
  list(ok = TRUE, df = df,
       effect_value = eff[good], se_value = se[good],
       preferred_effect_col = ecol, preferred_se_col = scol,
       n_rows = nrow(df),
       n_nonfinite_effect = n_nf_eff, n_nonfinite_se = n_nf_se,
       n_nonpositive_se = n_np_se, status = "ok", note = note)
}

# --- one-dataset geometry summary ----------------------------------------

#' Compute the dataset-level input geometry from a standardized read.
sim_geometry_summarize_dataset <- function(rd) {
  base <- data.frame(
    n_studies = NA_integer_, k = NA_integer_, k_bucket = NA_character_,
    preferred_effect_col = rd$preferred_effect_col,
    preferred_se_col = rd$preferred_se_col,
    effect_mean = NA_real_, effect_median = NA_real_, effect_sd = NA_real_,
    effect_min = NA_real_, effect_max = NA_real_,
    se_min = NA_real_, se_q10 = NA_real_, se_q25 = NA_real_,
    se_median = NA_real_, se_q75 = NA_real_, se_q90 = NA_real_,
    se_max = NA_real_, se_iqr = NA_real_, log_se_sd = NA_real_,
    inv_var_sum = NA_real_, fixed_info_se = NA_real_,
    max_weight_share = NA_real_, top2_weight_share = NA_real_,
    effective_n_weights = NA_real_, weight_entropy = NA_real_,
    n_nonfinite_effect = rd$n_nonfinite_effect %||% NA_integer_,
    n_nonfinite_se = rd$n_nonfinite_se %||% NA_integer_,
    n_nonpositive_se = rd$n_nonpositive_se %||% NA_integer_,
    geometry_status = rd$status, notes = rd$note %||% "",
    stringsAsFactors = FALSE)
  base$n_studies <- as.integer(rd$n_rows %||% NA_integer_)
  if (!isTRUE(rd$ok)) return(base)

  se  <- rd$se_value
  eff <- rd$effect_value
  k   <- length(se)
  base$k <- as.integer(k)
  base$k_bucket <- .sg_k_bucket(k)

  qs <- stats::quantile(se, c(0.10, 0.25, 0.50, 0.75, 0.90),
                        names = FALSE, type = 7)
  base$se_min    <- min(se)
  base$se_q10    <- qs[1]; base$se_q25 <- qs[2]; base$se_median <- qs[3]
  base$se_q75    <- qs[4]; base$se_q90 <- qs[5]
  base$se_max    <- max(se)
  base$se_iqr    <- qs[4] - qs[2]
  base$log_se_sd <- if (k >= 2L) stats::sd(log(se)) else NA_real_

  inv  <- 1 / se^2
  isum <- sum(inv)
  w    <- inv / isum
  ws   <- sort(w, decreasing = TRUE)
  base$inv_var_sum         <- isum
  base$fixed_info_se       <- 1 / sqrt(isum)
  base$max_weight_share    <- ws[1]
  base$top2_weight_share   <- if (k >= 2L) sum(ws[1:2]) else ws[1]
  base$effective_n_weights <- 1 / sum(w^2)
  base$weight_entropy      <- -sum(w[w > 0] * log(w[w > 0]))

  if (any(is.finite(eff))) {
    ee <- eff[is.finite(eff)]
    base$effect_mean   <- mean(ee)
    base$effect_median <- stats::median(ee)
    base$effect_sd     <- if (length(ee) >= 2L) stats::sd(ee) else NA_real_
    base$effect_min    <- min(ee)
    base$effect_max    <- max(ee)
  }
  base
}

# --- synthetic cell identity --------------------------------------------

#' Attach synthetic cell identity for sim_ strata; empirical -> NA.
#'
#' cell_slug = stratum without the "sim_" prefix; effect/heterogeneity/
#' bias slugs split from it. legacy_cell_code + the e/h/b bands are joined
#' from sim_load_design() when available (else NA, with a note attr).
#' Also sets scheme/corpus_id to the canonical sim identity on synthetic
#' rows so the dataset summary does not carry NA where the correct value
#' is known (the loader parses these from CONFIG, not path).
sim_geometry_assign_synthetic_cell <- function(df) {
  is_syn <- grepl("^sim_", df$stratum %||% "")
  slug   <- ifelse(is_syn, sub("^sim_", "", df$stratum), NA_character_)
  sp     <- strsplit(slug, "_", fixed = TRUE)
  pick   <- function(i) vapply(seq_along(sp), function(j)
    if (!is.na(slug[j]) && length(sp[[j]]) >= i) sp[[j]][i] else NA_character_,
    character(1))
  df$cell_slug          <- slug
  df$synthetic_stratum  <- ifelse(is_syn, df$stratum, NA_character_)
  df$effect_slug        <- pick(1L)
  df$heterogeneity_slug <- pick(2L)
  df$bias_slug          <- pick(3L)
  df$legacy_cell_code   <- NA_character_
  df$effect_band        <- NA_character_
  df$heterogeneity_band <- NA_character_
  df$bias_band          <- NA_character_

  # Populate scheme/corpus_id for synthetic rows so dataset_type =
  # synthetic carries the canonical sim identity (matches sim_fit_config
  # defaults) instead of NA.
  if ("scheme" %in% names(df))
    df$scheme[is_syn] <- .SG_SIM_SCHEME
  if ("corpus_id" %in% names(df))
    df$corpus_id[is_syn] <- .SG_SIM_CORPUS_ID

  design <- tryCatch(
    if (exists("sim_load_design", inherits = TRUE)) sim_load_design()
    else NULL, error = function(e) NULL)
  if (is.null(design)) {
    attr(df, "design_note") <-
      "sim_load_design() unavailable; legacy_cell_code/bands left NA"
    return(df)
  }
  dz <- design[, intersect(c("stratum", "legacy_cell_code", "eff_band",
                             "het_band", "bias_band"), names(design)),
               drop = FALSE]
  m <- match(df$stratum, dz$stratum)
  if ("legacy_cell_code" %in% names(dz))
    df$legacy_cell_code <- dz$legacy_cell_code[m]
  if ("eff_band"  %in% names(dz)) df$effect_band        <- dz$eff_band[m]
  if ("het_band"  %in% names(dz)) df$heterogeneity_band <- dz$het_band[m]
  if ("bias_band" %in% names(dz)) df$bias_band          <- dz$bias_band[m]
  df
}

# --- rollups (detail/) ---------------------------------------------------

# Robust descriptive rollup over a set of dataset rows (valid + invalid).
# Stats use the valid (geometry_status == "ok") subset; n_skipped counts
# the rest. group_cols are carried through (constant within the group).
.sg_rollup_one <- function(all_rows, group_vals = NULL, note = "") {
  v <- all_rows[all_rows$geometry_status == "ok", , drop = FALSE]
  base <- data.frame(
    n_datasets = nrow(v),
    n_studies_total = if (nrow(v)) sum(.sg_num(v$n_studies), na.rm = TRUE)
                      else 0L,
    median_k = .sg_med(.sg_num(v$k)),
    q25_k = .sg_q(.sg_num(v$k), 0.25), q75_k = .sg_q(.sg_num(v$k), 0.75),
    min_k = .sg_minf(.sg_num(v$k)),    max_k = .sg_maxf(.sg_num(v$k)),
    median_se_median = .sg_med(v$se_median),
    q25_se_median = .sg_q(v$se_median, 0.25),
    q75_se_median = .sg_q(v$se_median, 0.75),
    median_fixed_info_se = .sg_med(v$fixed_info_se),
    q25_fixed_info_se = .sg_q(v$fixed_info_se, 0.25),
    q75_fixed_info_se = .sg_q(v$fixed_info_se, 0.75),
    median_max_weight_share = .sg_med(v$max_weight_share),
    median_top2_weight_share = .sg_med(v$top2_weight_share),
    median_effective_n_weights = .sg_med(v$effective_n_weights),
    median_log_se_sd = .sg_med(v$log_se_sd),
    n_skipped = nrow(all_rows) - nrow(v),
    notes = note, stringsAsFactors = FALSE)
  if (!is.null(group_vals))
    base <- cbind(as.data.frame(as.list(group_vals),
                                stringsAsFactors = FALSE), base)
  base
}

# Group an all-rows frame by `by` and rollup each level; `extra` carries
# additional constant identity columns into synthetic-cell rollups.
.sg_rollup_by <- function(all_rows, by, extra = character(0)) {
  cols <- c(by, extra)
  empty <- .sg_rollup_one(all_rows[0, , drop = FALSE],
                          stats::setNames(rep(list(NA), length(cols)), cols))
  if (nrow(all_rows) == 0L || !all(by %in% names(all_rows)))
    return(empty[0, , drop = FALSE])
  rows <- all_rows[!is.na(all_rows[[by]]), , drop = FALSE]
  if (nrow(rows) == 0L) return(empty[0, , drop = FALSE])
  parts <- split(rows, rows[[by]], drop = TRUE)
  out <- lapply(parts, function(g) {
    gv <- as.list(g[1, cols, drop = FALSE])
    .sg_rollup_one(g, gv)
  })
  do.call(rbind, out)
}

# --- empirical vs synthetic global comparison (2-row helper) -------------

#' Empirical vs synthetic raw-input geometry comparison (wide, 2 rows).
#' Internal helper for the parity-gate builder. dataset_type = synthetic
#' when stratum starts with "sim_".
sim_geometry_compare_empirical_synthetic <- function(dataset_geometry) {
  ds <- dataset_geometry
  one <- function(label) {
    d <- ds[ds$dataset_type == label & ds$geometry_status == "ok", ,
            drop = FALSE]
    data.frame(
      dataset_type = label,
      n_datasets = nrow(d),
      median_k = .sg_med(.sg_num(d$k)),
      q25_k = .sg_q(.sg_num(d$k), 0.25),
      q75_k = .sg_q(.sg_num(d$k), 0.75),
      median_se_median = .sg_med(d$se_median),
      median_fixed_info_se = .sg_med(d$fixed_info_se),
      median_max_weight_share = .sg_med(d$max_weight_share),
      median_effective_n_weights = .sg_med(d$effective_n_weights),
      median_log_se_sd = .sg_med(d$log_se_sd),
      stringsAsFactors = FALSE)
  }
  rbind(one("empirical"), one("synthetic"))
}

# --- headline parity gate (PRIMARY output) -------------------------------

# Apply one rule (PASS / WATCH / FAIL) and short interpretation text.
.sg_apply_rule <- function(diff_, ratio, rule) {
  if (is.null(rule))
    return(list(flag = NA_character_, interp = "no rule"))
  if (rule$mode == "diff") {
    d <- abs(diff_)
    if (!is.finite(d))
      return(list(flag = "WATCH",
                  interp = "non-finite difference"))
    if (d <= rule$pass)
      return(list(flag = "PASS",
                  interp = sprintf("|emp - syn| = %.2f <= %g", d, rule$pass)))
    if (d <= rule$watch)
      return(list(flag = "WATCH",
                  interp = sprintf("|emp - syn| = %.2f within WATCH (<= %g)",
                                   d, rule$watch)))
    return(list(flag = "FAIL",
                interp = sprintf("|emp - syn| = %.2f exceeds WATCH (> %g)",
                                 d, rule$watch)))
  }
  if (rule$mode == "ratio") {
    r <- ratio
    if (!is.finite(r))
      return(list(flag = "WATCH",
                  interp = "non-finite ratio (synthetic value 0/NA)"))
    if (r >= rule$pass[1]  && r <= rule$pass[2])
      return(list(flag = "PASS",
                  interp = sprintf("ratio = %.3f within PASS [%g, %g]",
                                   r, rule$pass[1], rule$pass[2])))
    if (r >= rule$watch[1] && r <= rule$watch[2])
      return(list(flag = "WATCH",
                  interp = sprintf("ratio = %.3f within WATCH [%g, %g]",
                                   r, rule$watch[1], rule$watch[2])))
    return(list(flag = "FAIL",
                interp = sprintf("ratio = %.3f outside WATCH [%g, %g]",
                                 r, rule$watch[1], rule$watch[2])))
  }
  list(flag = NA_character_, interp = "unknown rule mode")
}

#' Build the headline empirical-vs-synthetic input-geometry gate (long form).
#'
#' One row per metric. Columns: metric, empirical_value, synthetic_value,
#' difference (= empirical - synthetic), ratio_empirical_to_synthetic,
#' flag (PASS/WATCH/FAIL), interpretation (short text), rule (machine-
#' readable summary of the heuristic that fired). Flags are diagnostic
#' heuristics from .SG_THRESHOLDS, NOT manuscript claims.
#'
#' @param dataset_geometry the per-dataset frame (.SG_DATASET_COLS shape).
#' @param thresholds named list of per-metric rules (default .SG_THRESHOLDS).
#' @return data.frame: one row per metric in .SG_HEADLINE_METRICS.
sim_geometry_build_parity_gate <- function(dataset_geometry,
                                           thresholds = .SG_THRESHOLDS) {
  ev <- sim_geometry_compare_empirical_synthetic(dataset_geometry)
  emp <- ev[ev$dataset_type == "empirical", , drop = FALSE]
  syn <- ev[ev$dataset_type == "synthetic", , drop = FALSE]
  n_emp <- if (nrow(emp)) as.integer(emp$n_datasets) else 0L
  n_syn <- if (nrow(syn)) as.integer(syn$n_datasets) else 0L

  out <- lapply(.SG_HEADLINE_METRICS, function(m) {
    ev_val <- if (m %in% names(emp)) suppressWarnings(as.numeric(emp[[m]]))
              else NA_real_
    sv_val <- if (m %in% names(syn)) suppressWarnings(as.numeric(syn[[m]]))
              else NA_real_
    diff_  <- ev_val - sv_val
    ratio  <- if (isTRUE(is.finite(sv_val) && sv_val != 0))
                ev_val / sv_val else NA_real_
    rule   <- thresholds[[m]]
    eval_  <- .sg_apply_rule(diff_, ratio, rule)
    rule_text <-
      if (is.null(rule)) "no rule"
      else if (rule$mode == "diff")
        sprintf("diff: PASS<=%g, WATCH<=%g", rule$pass, rule$watch)
      else
        sprintf("ratio: PASS [%g, %g], WATCH [%g, %g]",
                rule$pass[1], rule$pass[2],
                rule$watch[1], rule$watch[2])
    data.frame(
      metric = m,
      n_empirical = n_emp,
      n_synthetic = n_syn,
      empirical_value = ev_val,
      synthetic_value = sv_val,
      difference = diff_,
      ratio_empirical_to_synthetic = ratio,
      flag = eval_$flag,
      interpretation = eval_$interp,
      rule = rule_text,
      stringsAsFactors = FALSE)
  })
  do.call(rbind, out)
}

# --- top deviations (for the report) -------------------------------------

# Compute per-stratum / per-cell median geometry and rank by absolute log
# ratio against a reference (the opposite-side global median). Used to
# surface the small set of strata / cells most likely to drive a WATCH or
# FAIL flag, without flooding the report with every group.
.sg_group_geometry <- function(rows) {
  v <- rows[rows$geometry_status == "ok", , drop = FALSE]
  data.frame(
    n_datasets = nrow(v),
    median_k = .sg_med(.sg_num(v$k)),
    median_se_median = .sg_med(v$se_median),
    median_fixed_info_se = .sg_med(v$fixed_info_se),
    median_max_weight_share = .sg_med(v$max_weight_share),
    median_effective_n_weights = .sg_med(v$effective_n_weights),
    stringsAsFactors = FALSE)
}

.sg_abs_log_ratio <- function(a, b) {
  if (!isTRUE(is.finite(a) && is.finite(b) && a > 0 && b > 0))
    return(NA_real_)
  abs(log(a / b))
}

#' Top-N empirical strata whose geometry is farthest from the synthetic
#' global. Ranked by |log(ratio)| on median_fixed_info_se (information
#' scale; precision-driven). Robust to NA.
sim_geometry_top_stratum_deviations <- function(dataset_geometry,
                                                n = 5L) {
  syn <- dataset_geometry[dataset_geometry$dataset_type == "synthetic" &
                          dataset_geometry$geometry_status == "ok", ,
                          drop = FALSE]
  syn_g <- .sg_group_geometry(syn)
  emp <- dataset_geometry[dataset_geometry$dataset_type == "empirical" &
                          dataset_geometry$geometry_status == "ok", ,
                          drop = FALSE]
  if (nrow(emp) == 0L) return(emp[0, , drop = FALSE])
  parts <- split(emp, emp$stratum)
  rows <- do.call(rbind, lapply(names(parts), function(s) {
    g <- .sg_group_geometry(parts[[s]])
    g$stratum <- s
    g$ratio_fixed_info_se <- if (isTRUE(is.finite(syn_g$median_fixed_info_se) &&
                                       syn_g$median_fixed_info_se > 0))
      g$median_fixed_info_se / syn_g$median_fixed_info_se else NA_real_
    g$abs_log_ratio_fixed_info_se <- .sg_abs_log_ratio(
      g$median_fixed_info_se, syn_g$median_fixed_info_se)
    g$diff_median_k <- g$median_k - syn_g$median_k
    g
  }))
  rows <- rows[order(-rows$abs_log_ratio_fixed_info_se), , drop = FALSE]
  rows[seq_len(min(as.integer(n), nrow(rows))),
       c("stratum", "n_datasets", "median_k", "diff_median_k",
         "median_fixed_info_se", "ratio_fixed_info_se",
         "abs_log_ratio_fixed_info_se"),
       drop = FALSE]
}

#' Top-N synthetic cells whose geometry is farthest from the empirical
#' global. Same scale as the stratum version.
sim_geometry_top_cell_deviations <- function(dataset_geometry, n = 5L) {
  emp <- dataset_geometry[dataset_geometry$dataset_type == "empirical" &
                          dataset_geometry$geometry_status == "ok", ,
                          drop = FALSE]
  emp_g <- .sg_group_geometry(emp)
  syn <- dataset_geometry[dataset_geometry$dataset_type == "synthetic" &
                          dataset_geometry$geometry_status == "ok", ,
                          drop = FALSE]
  if (nrow(syn) == 0L) return(syn[0, , drop = FALSE])
  parts <- split(syn, syn$cell_slug)
  rows <- do.call(rbind, lapply(names(parts), function(s) {
    g <- .sg_group_geometry(parts[[s]])
    g$cell_slug <- s
    g$ratio_fixed_info_se <- if (isTRUE(is.finite(emp_g$median_fixed_info_se) &&
                                       emp_g$median_fixed_info_se > 0))
      g$median_fixed_info_se / emp_g$median_fixed_info_se else NA_real_
    g$abs_log_ratio_fixed_info_se <- .sg_abs_log_ratio(
      g$median_fixed_info_se, emp_g$median_fixed_info_se)
    g$diff_median_k <- g$median_k - emp_g$median_k
    g
  }))
  rows <- rows[order(-rows$abs_log_ratio_fixed_info_se), , drop = FALSE]
  rows[seq_len(min(as.integer(n), nrow(rows))),
       c("cell_slug", "n_datasets", "median_k", "diff_median_k",
         "median_fixed_info_se", "ratio_fixed_info_se",
         "abs_log_ratio_fixed_info_se"),
       drop = FALSE]
}

# --- full builder (per-dataset frame + gate + detail rollups) ------------

#' Build the full study-geometry result (per-dataset frame + headline
#' gate + detail rollups).
#'
#' @return list:
#'   * dataset_geometry          — per-dataset frame (.SG_DATASET_COLS)
#'   * skipped_files             — rows that could not be summarized
#'   * empirical_vs_synthetic    — headline parity gate (long form, with flags)
#'   * top_stratum_deviations    — top empirical strata vs synthetic global
#'   * top_cell_deviations       — top synthetic cells vs empirical global
#'   * overall_summary           — detail/ rollup (Overall + per k_bucket)
#'   * by_stratum                — detail/ rollup
#'   * by_synthetic_cell         — detail/ rollup (synthetic rows only)
#'   * by_bias_slug              — detail/ rollup (synthetic rows only;
#'                                 retained because threshold selection
#'                                 can shift accepted-study geometry)
#'   * empirical_vs_synthetic_wide — the 2-row helper used to build the gate
#'
#' Removed vs prior versions (low value or misleading for the parity gate):
#'   * by_scheme              — scheme is empirical-only metadata; the
#'                              right primary grouping is dataset_type
#'   * by_source_article      — too noisy for a calibration gate
#'   * by_effect_slug         — raw geometry should not be driven by
#'                              effect-axis truth, so the rollup is
#'                              low-signal for a parity check
#'   * by_heterogeneity_slug  — same reason
sim_geometry_build_summary <- function(data_root = "data",
                                       include_empirical = TRUE,
                                       include_synthetic = TRUE,
                                       max_files = Inf,
                                       verbose = TRUE) {
  cat0 <- sim_geometry_list_datasets(data_root, include_empirical,
                                     include_synthetic)
  if (nrow(cat0) == 0L)
    stop("sim_geometry_build_summary: no analysis-ready CSVs under '",
         data_root, "'.")
  if (is.finite(max_files) && nrow(cat0) > max_files)
    cat0 <- cat0[seq_len(as.integer(max_files)), , drop = FALSE]

  rows <- vector("list", nrow(cat0))
  for (i in seq_len(nrow(cat0))) {
    rd <- sim_geometry_read_one(cat0$csv_path[i])
    g  <- sim_geometry_summarize_dataset(rd)
    idc <- cat0[i, , drop = FALSE]
    id <- data.frame(
      dataset_type = idc$dataset_type,
      scheme = idc$scheme %||% NA_character_,
      corpus_id = idc$corpus_id %||% NA_character_,
      path_stratum = idc$path_stratum %||% NA_character_,
      stratum = idc$stratum %||% NA_character_,
      source_article = idc$source_article %||% NA_character_,
      source_year = idc$source_year %||% NA_integer_,
      outcome_slug = idc$outcome_slug %||% NA_character_,
      dataset_id = idc$dataset_id %||% NA_character_,
      analysis_id = idc$analysis_id %||% NA_character_,
      analysis_variant = idc$analysis_variant %||% NA_character_,
      csv_path = idc$csv_path, stringsAsFactors = FALSE)
    rows[[i]] <- cbind(id, g)
    if (verbose && i %% 200L == 0L)
      message(sprintf("[sg] geometry %d/%d", i, nrow(cat0)))
  }
  ds <- do.call(rbind, rows)
  ds <- sim_geometry_assign_synthetic_cell(ds)
  for (cl in setdiff(.SG_DATASET_COLS, names(ds))) ds[[cl]] <- NA
  ds <- ds[, .SG_DATASET_COLS, drop = FALSE]

  skipped <- ds[ds$geometry_status != "ok",
                c("dataset_type", "stratum", "source_article",
                  "dataset_id", "csv_path", "geometry_status", "notes"),
                drop = FALSE]

  ev_wide <- sim_geometry_compare_empirical_synthetic(ds)
  gate    <- sim_geometry_build_parity_gate(ds)
  top_s   <- sim_geometry_top_stratum_deviations(ds, n = 5L)
  top_c   <- sim_geometry_top_cell_deviations(ds, n = 5L)

  ov_all <- .sg_rollup_one(ds, list(group = "Overall"))
  ov_bkt <- do.call(rbind, lapply(
    split(ds, factor(ds$k_bucket)), function(g)
      .sg_rollup_one(g, list(group = paste0("k_bucket=", g$k_bucket[1])))))
  overall <- rbind(ov_all, ov_bkt)

  list(
    dataset_geometry        = ds,
    skipped_files           = skipped,
    empirical_vs_synthetic  = gate,
    top_stratum_deviations  = top_s,
    top_cell_deviations     = top_c,
    overall_summary         = overall,
    by_stratum              = .sg_rollup_by(ds, "stratum"),
    by_synthetic_cell       = .sg_rollup_by(
      ds[ds$dataset_type == "synthetic", , drop = FALSE], "cell_slug",
      extra = c("synthetic_stratum", "legacy_cell_code", "effect_slug",
                "heterogeneity_slug", "bias_slug")),
    by_bias_slug            = .sg_rollup_by(
      ds[ds$dataset_type == "synthetic", , drop = FALSE], "bias_slug"),
    empirical_vs_synthetic_wide = ev_wide)
}

# --- markdown report -----------------------------------------------------
.sg_fmt <- function(x, d = 4) {
  if (is.null(x) || length(x) == 0L || all(is.na(x))) return("NA")
  formatC(x, digits = d, format = "g")
}

# Render a small data.frame to a markdown table (selected columns; numeric
# columns formatted compactly). NA-safe; never errors.
.sg_md_table <- function(df, cols = names(df), digits = 4L) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0L)
    return("- (no rows)")
  df <- df[, intersect(cols, names(df)), drop = FALSE]
  head <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep  <- paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|")
  fmt <- function(v) {
    if (is.numeric(v)) vapply(v, .sg_fmt, character(1), d = digits)
    else as.character(v)
  }
  body <- vapply(seq_len(nrow(df)), function(i) {
    paste0("| ", paste(vapply(names(df), function(cl)
      fmt(df[[cl]][i]), character(1)), collapse = " | "), " |")
  }, character(1))
  paste(c(head, sep, body), collapse = "\n")
}

#' Rewritten study-geometry report — single-purpose parity gate.
.sg_write_report <- function(res, data_root, out_dir, max_files) {
  ds <- res$dataset_geometry
  n_disc <- nrow(ds)
  n_ok   <- sum(ds$geometry_status == "ok")
  n_skip <- nrow(res$skipped_files)
  n_emp  <- sum(ds$dataset_type == "empirical")
  n_syn  <- sum(ds$dataset_type == "synthetic")
  kt <- table(ds$k_bucket[ds$geometry_status == "ok"], useNA = "ifany")
  kb <- if (length(kt))
    paste0("- `", names(kt), "`: ", as.integer(kt), collapse = "\n")
    else "- (no valid datasets)"
  gate <- res$empirical_vs_synthetic
  n_pass  <- sum(gate$flag == "PASS",  na.rm = TRUE)
  n_watch <- sum(gate$flag == "WATCH", na.rm = TRUE)
  n_fail  <- sum(gate$flag == "FAIL",  na.rm = TRUE)
  headline <- if (n_fail > 0L) "FAIL"
              else if (n_watch > 0L) "WATCH"
              else "PASS"

  gate_md <- .sg_md_table(
    gate[, c("metric", "empirical_value", "synthetic_value",
             "difference", "ratio_empirical_to_synthetic",
             "flag", "interpretation"), drop = FALSE], digits = 4L)

  top_s_md <- if (!is.null(res$top_stratum_deviations) &&
                  nrow(res$top_stratum_deviations))
    .sg_md_table(res$top_stratum_deviations) else "- (none)"
  top_c_md <- if (!is.null(res$top_cell_deviations) &&
                  nrow(res$top_cell_deviations))
    .sg_md_table(res$top_cell_deviations) else "- (none)"

  reasons <- if (n_skip)
    paste0("- `", names(sort(table(res$skipped_files$notes),
           decreasing = TRUE)), "`: ",
           as.integer(sort(table(res$skipped_files$notes),
           decreasing = TRUE)), collapse = "\n")
    else NULL

  lines <- c(
    "# Empirical–synthetic input-geometry parity check (v4)",
    "",
    "## Purpose",
    "",
    paste0("A calibration / plausibility gate on the **raw input** ",
           "geometry of the synthetic full36 library, compared against ",
           "the empirical evidence corpus. The question is whether the ",
           "synthetic datasets are close enough to the empirical ",
           "datasets in study count (k), study-level standard errors / ",
           "precision, total fixed-effect information, and inverse-",
           "variance weight concentration that downstream synthetic ",
           "RoBMA behavior can be read as plausible."),
    "",
    paste0("This is **raw-input geometry only**: it reads only the ",
           "analysis-ready (g, se_g) / (d, se_d) CSVs under `data/`. ",
           "It never touches a fitted sidecar, a latent/truth file, ",
           "`output/`, or `output_sim_v30/`. It does not call RoBMA or ",
           "`batch_fit()`. The flags below are conservative heuristic ",
           "labels — diagnostic only, not manuscript claims."),
    "",
    sprintf("- Run timestamp : %s",
            format(Sys.time(), "%Y-%m-%dT%H:%M:%S")),
    sprintf("- data_root     : `%s`", data_root),
    sprintf("- max_files     : %s", as.character(max_files)),
    "",
    "## Counts",
    "",
    sprintf("- Datasets discovered : %d", n_disc),
    sprintf("- Summarized (geometry_status == ok) : %d", n_ok),
    sprintf("- Skipped : %d", n_skip),
    sprintf("- Empirical datasets : %d", n_emp),
    sprintf("- Synthetic datasets : %d", n_syn),
    "",
    "### k_bucket distribution (valid datasets)",
    "",
    kb,
    "",
    sprintf("## Headline parity gate — overall flag: **%s**", headline),
    "",
    sprintf("Per-metric flag counts: %d PASS, %d WATCH, %d FAIL.",
            n_pass, n_watch, n_fail),
    "",
    gate_md,
    "",
    paste0("Thresholds are conservative heuristics defined as constants ",
           "near the top of `simulation/scripts/45_study_geometry.R` ",
           "(`.SG_THRESHOLDS`); tune there, not in callers."),
    "",
    "## Interpretation",
    "",
    paste0("PASS rows indicate the synthetic library matches the ",
           "empirical corpus within the tight band on that metric. ",
           "WATCH rows are within the wider band and warrant a quick ",
           "look at the top-deviations tables below. FAIL rows indicate ",
           "the synthetic library is materially off the empirical input ",
           "geometry on that metric — synthetic RoBMA behavior on that ",
           "axis should be interpreted cautiously until the mismatch is ",
           "understood. Single metrics rarely tell the whole story; ",
           "read the gate as a vector, not as one number."),
    "",
    "## Top empirical strata deviating from the synthetic global",
    "",
    "Ranked by `|log(empirical_stratum / synthetic_global)|` on `median_fixed_info_se`.",
    "",
    top_s_md,
    "",
    "## Top synthetic cells deviating from the empirical global",
    "",
    "Ranked by `|log(synthetic_cell / empirical_global)|` on `median_fixed_info_se`.",
    "",
    top_c_md,
    "")
  if (n_skip) {
    lines <- c(lines,
               "## Skipped files",
               "",
               reasons,
               "")
  }
  lines <- c(lines,
             "## Scope",
             "",
             paste0("- This is RAW INPUT geometry only: study-level ",
                    "(g, se_g) / (d, se_d) shape — **not** a RoBMA ",
                    "result. No fitted sidecar, no latent/truth file, ",
                    "and neither `output/` nor `output_sim_v30/` is ",
                    "read."),
             paste0("- The diagnostic walks only analysis-ready CSVs ",
                    "under `data/` via the shared `list_datasets()` and ",
                    "is independent of the fitting run; safe to run ",
                    "while a full36 fit is in progress."),
             paste0("- Headline output: `study_geometry_empirical_vs_",
                    "synthetic.csv` (this report's gate table)."),
             paste0("- Per-dataset detail: `study_geometry_dataset_",
                    "summary.csv` — used to recompute any grouping."),
             paste0("- Secondary rollups live under `detail/` and are ",
                    "for follow-up only."),
             "")
  writeLines(lines, file.path(out_dir, "study_geometry_report.md"))
}

# --- explicit runner (the ONLY writer; never runs on source) -------------

#' Run the empirical–synthetic input-geometry parity check.
#'
#' Reads ONLY analysis-ready CSVs under data_root. Never fits, never
#' reads a sidecar/latent file, never touches output/ or output_sim_v30/.
#'
#' Primary outputs (default; in `out_dir`):
#'   * study_geometry_report.md
#'   * study_geometry_empirical_vs_synthetic.csv   <- headline gate
#'   * study_geometry_dataset_summary.csv          <- per-dataset detail
#'
#' Detail/provenance outputs (in `out_dir/detail/`):
#'   * overall_summary.csv          (Overall + per k_bucket)
#'   * by_stratum.csv               (per empirical/synthetic stratum)
#'   * by_synthetic_cell.csv        (synthetic cells only)
#'   * by_bias_slug.csv             (synthetic; bias selection can shift
#'                                   accepted-study geometry)
#'   * top_stratum_deviations.csv   (top empirical deviations)
#'   * top_cell_deviations.csv      (top synthetic deviations)
#'   * skipped_files.csv            (only written if any skipped)
#'
#' Removed vs prior versions: by_scheme.csv (misleading — scheme is
#' empirical-only metadata; primary grouping is `dataset_type`),
#' by_source_article.csv (too noisy for a calibration gate),
#' by_effect_slug.csv / by_heterogeneity_slug.csv (raw geometry should
#' not be driven by truth-axis grouping, so they are low-signal).
#'
#' @return invisible list(result, files, out_dir).
sim_run_study_geometry <- function(
    data_root        = "data",
    out_dir          = "simulation/results/study_geometry_v30",
    include_empirical = TRUE,
    include_synthetic = TRUE,
    synthetic_only   = FALSE,
    empirical_only   = FALSE,
    max_files        = Inf,
    write_outputs    = TRUE,
    write_report     = TRUE,
    verbose          = TRUE) {

  if (isTRUE(synthetic_only)) { include_empirical <- FALSE
    include_synthetic <- TRUE }
  if (isTRUE(empirical_only)) { include_synthetic <- FALSE
    include_empirical <- TRUE }

  res <- sim_geometry_build_summary(
    data_root = data_root, include_empirical = include_empirical,
    include_synthetic = include_synthetic, max_files = max_files,
    verbose = verbose)

  files <- character(0)
  if (isTRUE(write_outputs)) {
    if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
    detail_dir <- file.path(out_dir, "detail")
    if (!dir.exists(detail_dir)) dir.create(detail_dir, recursive = TRUE)

    wr <- function(d, p) {
      utils::write.csv(d, p, row.names = FALSE); p }

    # Primary outputs (top of out_dir).
    files <- c(
      wr(res$empirical_vs_synthetic,
         file.path(out_dir, "study_geometry_empirical_vs_synthetic.csv")),
      wr(res$dataset_geometry,
         file.path(out_dir, "study_geometry_dataset_summary.csv")))

    # Detail/provenance outputs (detail/ subfolder).
    files <- c(files,
      wr(res$overall_summary,
         file.path(detail_dir, "overall_summary.csv")),
      wr(res$by_stratum,
         file.path(detail_dir, "by_stratum.csv")),
      wr(res$by_synthetic_cell,
         file.path(detail_dir, "by_synthetic_cell.csv")),
      wr(res$by_bias_slug,
         file.path(detail_dir, "by_bias_slug.csv")),
      wr(res$top_stratum_deviations,
         file.path(detail_dir, "top_stratum_deviations.csv")),
      wr(res$top_cell_deviations,
         file.path(detail_dir, "top_cell_deviations.csv")))

    # Skipped only if any.
    if (nrow(res$skipped_files))
      files <- c(files, wr(res$skipped_files,
        file.path(detail_dir, "skipped_files.csv")))

    if (isTRUE(write_report)) {
      .sg_write_report(res, data_root, out_dir, max_files)
      files <- c(files, file.path(out_dir, "study_geometry_report.md"))
    }
  }
  if (verbose) {
    gate <- res$empirical_vs_synthetic
    n_pass  <- sum(gate$flag == "PASS",  na.rm = TRUE)
    n_watch <- sum(gate$flag == "WATCH", na.rm = TRUE)
    n_fail  <- sum(gate$flag == "FAIL",  na.rm = TRUE)
    message(sprintf("[sg] done: %d datasets, %d ok, %d skipped | gate %d/%d/%d (PASS/WATCH/FAIL)%s",
            nrow(res$dataset_geometry),
            sum(res$dataset_geometry$geometry_status == "ok"),
            nrow(res$skipped_files),
            n_pass, n_watch, n_fail,
            if (length(files)) sprintf(" -> %s", out_dir) else
              " (no files written)"))
  }
  invisible(list(result = res, files = files, out_dir = out_dir))
}
