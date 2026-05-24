# 20_robma_fit.R
# ------------------------------------------------------------------------------
# Single-dataset fitting backbone + rigor sidecar extractor (RoBMA 4.0).
#
# Per dataset this fits an unadjusted Bayesian baseline (brma()) and the
# RoBMA-PSMA product-space ensemble (RoBMA(model_type="PSMA")), extracts the
# selected-rigor estimand from JOINT individual-model mass, validates it
# against the package's own marginal summaries, and appends one row to the
# lean per-stratum v4 sidecar. Individual/marginal model summaries and the
# model-family validation table are written as first-class audit artifacts.
#
# Operational RoBMA 4.0 caveats:
#   * Inputs use the 4.0 effect-size interface (yi/sei/slab/measure). Preferred/
#     default input columns are Hedges' g as g/se_g (-> yi=g, sei=se_g); d/se_d
#     (Cohen's d) is accepted as a no-rename fallback. .resolve_effect_input()
#     (00_utils.R) picks the pair (g/se_g first) and validates it.
#   * `measure` is REQUIRED. Hedges' g is an SMD with a known unit-information
#     SD, so CONFIG$measure = "SMD" ("GEN" would be the weaker, wrong choice).
#   * Baseline = brma(); ensemble = RoBMA(model_type="PSMA"). Estimates from
#     summary(fit)$estimates; model-family mass from summary_models(); bias
#     diagnostics from as_zplot().
#
# Selected-rigor estimand (estimand_version = .ESTIMAND_VERSION):
#   log10BF_rigor_effect    = BF for M_{k, mu+ . omega0}  (README d_k^R=+)
#   log10BF_rigor_no_effect = BF for M_{k, mu0 . omega0}  (README d_k^R=0)
#   log10BF_rigor           = max(rigor_effect, rigor_no_effect)   [SELECTED]
#   rigor_direction         = "effect" / "no_effect" (parser-safe; never
#                             "null"; ties resolve to "effect")
# Each branch BF is an ORDINARY model-family inclusion BF for a pre-specified
# no-bias family, computed from JOINT individual-model prior/posterior mass --
# never a product/average of marginal BFs. omega0 means NO modeled
# publication-bias / small-study-effect component is included; it does NOT
# prove the literature is bias-free. log10BF_no_bias is the MARGINAL no-bias
# inclusion BF (== -log10BF_bias for finite rows); it is NOT the rigor BF. The
# headline rigor is never reported without rigor_direction.
#
# Identity vocabulary (parsed once by .build_identity_fields(), 00_utils.R):
# corpus_id / scheme / stratum / source_article / outcome_slug, the stable
# legacy stem dataset_id, and the portable analysis_id. The physical tree
# stays data/<stratum>/<source_article>/; that folder name is path_stratum.
# "effect" in math names (log10BF_effect, mu+) is the RoBMA effect component
# and is unchanged.
#
# DEFINE-ONLY: sourcing defines CONFIG/helpers only. No package attach, fit,
# install, or disk write happens until fit_robma_models() is called; the
# RoBMA/runjags runtime is armed lazily by .ensure_robma_runtime().
#
# Quick-Start
#   source("scripts/00_utils.R"); source("scripts/10_load_data.R")
#   source("scripts/20_robma_fit.R")
#   load_datasets(stratum="fiber", source_article="post2012",
#                 file="post2012_fiber_hba1c")
#   res <- fit_robma_models(post2012_fiber_hba1c,
#                           dataset_name = "post2012_fiber_hba1c")
# ------------------------------------------------------------------------------


# ---- Shared contract + helpers (sentinel-guarded) --------------------------
# 00_utils.R provides the v4 schema/estimand contract (.SIDECAR_V4_COLS,
# .ZPLOT_DIAG_COLS, .SCHEMA_VERSION, .ESTIMAND_VERSION, .BASELINE_CONVENTION,
# .RoBMA4_COMPONENT), the shared BF/parse helpers (.bf_from_odds, same_bf,
# norm_slug, .safe_div, .stable_hash), and the identity/rigor-category
# derivers (.build_identity_fields, .rigor_category).
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# ---- RoBMA 4.0 runtime (armed at call time, never at source time) ----------
# Loads the RoBMA/runjags namespaces (NOT attaching them -- RoBMA:: prefixes
# are used everywhere and RoBMA's S3 methods register on namespace load) and
# sets runjags' own parallel method so PSOCK workers are not leaked in fresh
# library setups. Idempotent; cheap to call before every fit.
.ensure_robma_runtime <- function() {
  for (pkg in c("RoBMA", "runjags")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop(sprintf(paste0("Package '%s' is required for fitting but is not ",
                          "installed. Install it manually; sourcing this ",
                          "script intentionally does not."), pkg),
           call. = FALSE)
    }
  }
  runjags::runjags.options(
    method         = "parallel",
    silent.jags    = TRUE,
    silent.runjags = TRUE
  )
  invisible(TRUE)
}


# ==== CONFIGURATION =========================================================
# fit_robma_models() reads from this list at call time, so updating CONFIG
# between calls (or from a parent batch session) is fine.

CONFIG <- list(
  # ---- Corpus / scheme identity (v4 vocabulary) ----
  corpus_id = "nutrition_v4",        # logical corpus tag
  scheme    = "nutrition_domain",    # metadata partitioning scheme

  # ---- MCMC (RoBMA4: product-space is a single JAGS model) ----
  sample   = 5000,
  burnin   = 2000,
  adapt    = 500,
  thin     = 1,
  chains   = 6,
  parallel = TRUE,
  seed     = 050926,

  # ---- RoBMA 4.0 product-space ensemble ----
  model_type = "PSMA",   ## RoBMA4: full RoBMA-PSMA (6 wf + PET + PEESE)

  # ---- Effect-size measure (RoBMA4: explicit + REQUIRED) ----
  ## RoBMA4: Hedges' g IS an SMD with a known unit-information SD -> "SMD".
  ## "GEN" is documented (?RoBMA) only for generic effects WITHOUT a known
  ## UISD and would be the wrong, weaker choice here.
  measure = "SMD",

  # ---- RoBMA effect direction ----
  effect_direction = "positive",

  # ---- as_zplot bias diagnostics (secondary, non-blocking) ----
  zplot = TRUE,

  # ---- Output ----
  output_root     = "output",
  save_outputs    = TRUE,
  nest_by_outcome = FALSE   # one out_dir per source_article (TRUE: per outcome)
)


# The v4 schema/estimand contract (.SIDECAR_V4_COLS, .ZPLOT_DIAG_COLS,
# .RoBMA4_COMPONENT, versions, .BASELINE_CONVENTION) lives in 00_utils.R so
# 20 and 40 cannot drift; referenced here unchanged.


# ==== BAYESTOOLS-TABLE HELPERS ==============================================
# RoBMA/BayesTools-table specific helpers (the generic BF/parse helpers are
# in 00_utils.R).

# Robust cell access for a BayesTools_table (row/col labels may be
# non-syntactic, e.g. "0.025", "Publication Bias"). Matched trimmed + case-
# insensitive so a cosmetic relabel does not silently return NA.
.bt_cell <- function(tbl, row, col) {
  if (is.null(tbl) || (!is.data.frame(tbl) && !is.matrix(tbl))) return(NA_real_)
  if (is.matrix(tbl)) tbl <- as.data.frame(tbl, stringsAsFactors = FALSE,
                                           check.names = FALSE)
  rn <- rownames(tbl); cn <- colnames(tbl)
  rid <- which(tolower(trimws(rn)) == tolower(trimws(row)))
  cid <- which(tolower(trimws(cn)) == tolower(trimws(col)))
  if (length(rid) == 0L || length(cid) == 0L) return(NA_real_)
  suppressWarnings(as.numeric(tbl[rid[1], cid[1]]))
}

# Drop BayesTools / RoBMA S3 classes so write.csv() uses the plain data.frame
# method.
.as_plain_df <- function(x) {
  if (is.null(x)) return(NULL)
  d <- as.data.frame(x, stringsAsFactors = FALSE, check.names = FALSE)
  for (a in c("type", "parameters", "title", "footnotes",
              "partition_ok", "unresolved_labels"))
    attr(d, a) <- NULL
  rownames(d) <- NULL
  d
}

# Checked, Windows-safe atomic CSV write. write.csv() to a unique temp file,
# verify it, back up any existing target to <path>.bak, then rename/copy the
# temp into place. Stops with a clear error if the replacement fails (never
# leaves a half-written target).
atomic_write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- sprintf("%s.tmp-%d-%s", path, Sys.getpid(),
                 format(as.numeric(Sys.time()) * 1000, scientific = FALSE))
  write.csv(df, tmp, row.names = FALSE)
  if (!file.exists(tmp) || file.size(tmp) <= 0) {
    stop(sprintf("atomic_write_csv: temp write failed for '%s'", path))
  }
  # Windows file.rename() fails when the destination exists; back it up first.
  if (file.exists(path)) {
    bak <- paste0(path, ".bak")
    if (file.exists(bak)) unlink(bak)
    if (!file.rename(path, bak)) {
      if (!file.copy(path, bak, overwrite = TRUE)) {
        unlink(tmp)
        stop(sprintf("atomic_write_csv: could not back up existing '%s'", path))
      }
      unlink(path)
    }
  }
  ok <- file.rename(tmp, path)
  if (!ok) {
    ok <- file.copy(tmp, path, overwrite = TRUE)
    unlink(tmp)
  }
  if (!ok || !file.exists(path)) {
    stop(sprintf("atomic_write_csv: failed to write '%s'", path))
  }
  invisible(path)
}

# ==== CONFIG SIGNATURE / HASH ===============================================
# config_hash gates resume compatibility: a fit run under different MCMC /
# measure / software / schema / estimand is NOT interchangeable with the
# current CONFIG. The schema_version and estimand_version are folded into the
# signature so that bumping the v4 contract automatically invalidates every
# old sidecar row for resume (old effect-only-rigor / 3.6.x rows can never
# satisfy a current run). .stable_hash() (00_utils.R) uses digest when
# available but NEVER auto-installs it.

.config_signature <- function() {
  paste(
    "corpus_id",        CONFIG$corpus_id,
    "scheme",           CONFIG$scheme,
    "schema_version",   .SCHEMA_VERSION,
    "estimand_version", .ESTIMAND_VERSION,
    "RoBMA",            as.character(utils::packageVersion("RoBMA")),
    "BayesTools",       as.character(utils::packageVersion("BayesTools")),
    "measure",          CONFIG$measure,
    "model_type",       CONFIG$model_type,
    "effect_direction", CONFIG$effect_direction,
    "sample",           CONFIG$sample,
    "burnin",           CONFIG$burnin,
    "adapt",            CONFIG$adapt,
    "chains",           CONFIG$chains,
    "thin",             CONFIG$thin,
    "seed",             CONFIG$seed,
    sep = "|"
  )
}

.config_hash <- function() {
  .stable_hash(.config_signature())
}

# Provenance hash of the pipeline source that defines the estimand/extractor.
# Recorded in the sidecar (`script_hash`) so a row whose numbers were produced
# by a different 00/20 source can be detected even when CONFIG is unchanged.
# Hashes whichever of the canonical scripts can be located; "unsourced" when
# none are (e.g. helpers defined ad hoc in a session). Best-effort and never
# fatal -- script provenance must not block fitting.
.script_hash <- function(scripts_dir = "scripts") {
  cand <- c(
    file.path(scripts_dir, "00_utils.R"), "00_utils.R",
    file.path("..", scripts_dir, "00_utils.R"),
    file.path(scripts_dir, "20_robma_fit.R"), "20_robma_fit.R",
    file.path("..", scripts_dir, "20_robma_fit.R")
  )
  src <- character(0)
  for (nm in c("00_utils.R", "20_robma_fit.R")) {
    hit <- cand[basename(cand) == nm & file.exists(cand)]
    if (length(hit) > 0L) {
      txt <- tryCatch(readLines(hit[1], warn = FALSE),
                      error = function(e) character(0))
      src <- c(src, nm, txt)
    }
  }
  if (length(src) == 0L) return("unsourced")
  .stable_hash(src)
}


# ==== PATHS =================================================================
# Output tree: output/<stratum>/<source_article>/ (+ /<outcome_slug> when
# CONFIG$nest_by_outcome). The per-stratum sidecar and the per-stratum
# zplot-diagnostics artifact sit at output/<stratum>/. `audit_dir` holds the
# first-class model-summary audit artifacts (not scratch debug).
.paths_for <- function(stratum, source_article, outcome_slug) {
  stratum_slug <- norm_slug(stratum)
  article_slug <- norm_slug(source_article)
  out_dir <- if (isTRUE(CONFIG$nest_by_outcome)) {
    file.path(CONFIG$output_root, stratum_slug, article_slug,
              norm_slug(outcome_slug))
  } else {
    file.path(CONFIG$output_root, stratum_slug, article_slug)
  }
  list(
    out_dir     = out_dir,
    audit_dir   = file.path(out_dir, "audit"),
    sidecar_csv = file.path(CONFIG$output_root, stratum_slug,
                            sprintf("%s_robma_summary.csv", stratum_slug)),
    zplot_csv   = file.path(CONFIG$output_root, stratum_slug,
                            sprintf("%s_zplot_diagnostics.csv",
                                    stratum_slug))
  )
}


# ==== ESTIMATE EXTRACTION (RoBMA 4.0) =======================================
# RoBMA4: estimates come from summary(fit, probs=c(.025,.5,.975))$estimates,
# a BayesTools_table whose rows include "mu"/"tau" and columns "Mean",
# "0.025", "0.975". extract_posterior() was removed in 4.0. Strict
# separation: fit_RE for RE estimates, fit_RoBMA for BC estimates.
.estimate_triplet <- function(fit, param) {
  out <- c(est = NA_real_, lCI = NA_real_, uCI = NA_real_)
  if (is.null(fit)) return(out)
  s <- tryCatch(summary(fit, probs = c(0.025, 0.5, 0.975)),
                error = function(e) {
                  message(sprintf("  [estimate] summary() failed for %s: %s",
                                  param, conditionMessage(e))); NULL })
  if (is.null(s)) return(out)
  est <- s$estimates %||% s$Estimates
  if (is.null(est)) return(out)
  c(est = .bt_cell(est, param, "Mean"),
    lCI = .bt_cell(est, param, "0.025"),
    uCI = .bt_cell(est, param, "0.975"))
}


# ==== BIAS DIAGNOSTICS (RoBMA 4.0 as_zplot) =================================
# RoBMA4: as_zcurve() removed; replacement is as_zplot() whose
# summary()$estimates is a BayesTools_table with rows {EDR, "Soric FDR",
# "Missing N"} and ODR in attr(.,"footnotes"). Secondary + NON-BLOCKING:
# any failure -> all-NA, never propagates to the fit.
.parse_odr_from_footnote <- function(tbl) {
  if (is.null(tbl)) return(NA_real_)
  fn <- attr(tbl, "footnotes")
  if (is.null(fn)) return(NA_real_)
  fn_str <- paste(fn, collapse = " ")
  m <- regmatches(fn_str, regexpr("ODR\\s*=\\s*[0-9]*\\.?[0-9]+", fn_str))
  if (length(m) == 0L || !nzchar(m)) return(NA_real_)
  num <- regmatches(m, regexpr("[0-9]*\\.?[0-9]+", m))
  if (length(num) == 0L) return(NA_real_)
  suppressWarnings(as.numeric(num))
}

.extract_zplot_diagnostics <- function(zp = NULL, fit = NULL, verbose = FALSE) {
  na_out <- list(ODR = NA_real_, EDR = NA_real_,
                 Soric_FDR = NA_real_, MissingN = NA_real_)
  if (is.null(zp) && !is.null(fit)) {
    zp <- tryCatch(RoBMA::as_zplot(fit),
                    error = function(e) {
                      if (verbose) message("  [zplot-diag] as_zplot failed: ",
                                            conditionMessage(e)); NULL })
  }
  if (is.null(zp)) return(na_out)
  s <- tryCatch(summary(zp), error = function(e) {
    if (verbose) message("  [zplot-diag] summary(zplot) failed: ",
                          conditionMessage(e)); NULL })
  if (is.null(s)) return(na_out)
  est <- s$estimates %||% s$Estimates
  if (is.null(est)) return(na_out)
  list(
    ODR       = .parse_odr_from_footnote(est),
    EDR       = .bt_cell(est, "EDR",       "Median"),
    Soric_FDR = .bt_cell(est, "Soric FDR", "Median"),
    MissingN  = .bt_cell(est, "Missing N", "Median")
  )
}


# ==== MODEL-FAMILY EVIDENCE EXTRACTOR =======================================
# extract_model_family_evidence(fit_RoBMA, ...)
#
#   1-2. summary_models(fit, type = "marginal" / "individual")
#   3.   ALWAYS save both raw summaries to the per-dataset audit dir first
#   4.   classify each individual row via the package's own marginal
#        label -> Hypothesis ("Null"/"Alternative") map (no guessing)
#   5.   compute prior/posterior mass for: effect+, het+, bias+, no-bias,
#        the four joint mu x omega cells, and the two SELECTED rigor branches
#        (effect: mu+ . omega0; no_effect: mu0 . omega0; het marginalized)
#   6.   inclusion BFs from prior/posterior odds (joint, not BF products)
#   7.   validate individual-row sums reproduce the package's marginal
#        PRIOR, POSTERIOR, and inclusion BF for effect/het/bias
#   8.   write the model-family validation audit table
#   9.   strict gate: classification must be EXPLICITLY validated. If not
#        (unresolved labels, non-partitioned mass, or any component prior/
#        post/BF mismatch / unavailable), set uncertain = TRUE, NA the
#        trusted numeric fields, still write the raw audit tables, and WARN.
extract_model_family_evidence <- function(fit_RoBMA,
                                          audit_dir = NULL,
                                          stem      = "dataset",
                                          tol_prob  = 1e-3,
                                          verbose   = TRUE) {

  num_fields <- c(
    "prior_p_effect","post_p_effect","log10BF_effect",
    "prior_p_het","post_p_het","log10BF_het",
    "prior_p_bias","post_p_bias","log10BF_bias",
    "prior_p_no_bias","post_p_no_bias","log10BF_no_bias",
    "prior_p_mu0_omega0","post_p_mu0_omega0","log10BF_mu0_omega0",
    "prior_p_muplus_omega0","post_p_muplus_omega0","log10BF_muplus_omega0",
    "prior_p_mu0_omegaplus","post_p_mu0_omegaplus","log10BF_mu0_omegaplus",
    "prior_p_muplus_omegaplus","post_p_muplus_omegaplus","log10BF_muplus_omegaplus",
    "prior_p_rigor_effect","post_p_rigor_effect","log10BF_rigor_effect",
    "prior_p_rigor_no_effect","post_p_rigor_no_effect","log10BF_rigor_no_effect",
    "log10BF_rigor","rigor_margin"
  )
  na_list <- setNames(as.list(rep(NA_real_, length(num_fields))), num_fields)
  na_list$rigor_direction                     <- NA_character_
  na_list$rigor_category                      <- NA_character_
  na_list$uncertain                           <- TRUE
  na_list$partition_ok                        <- NA
  na_list$unresolved_labels                   <- NA_integer_
  na_list$component_probability_validation_ok <- FALSE
  na_list$component_bf_validation_ok          <- FALSE
  na_list$component_validation_ok             <- FALSE
  na_list$validation_failure_reason           <- "unknown"
  na_list$max_abs_diff_component_prior        <- NA_real_
  na_list$max_abs_diff_component_post         <- NA_real_
  na_list$max_abs_diff_component_bf           <- NA_real_
  na_list$validation                          <- NULL

  if (is.null(fit_RoBMA)) {
    warning("extract_model_family_evidence: fit_RoBMA is NULL; returning NA.")
    return(na_list)
  }

  write_audit <- function(df, suffix) {
    if (is.null(audit_dir) || is.null(df)) return(invisible(NULL))
    f <- file.path(audit_dir, sprintf("%s_RoBMA4_%s.csv", suffix, stem))
    atomic_write_csv(.as_plain_df(df), f)
    if (verbose) message(sprintf("  [evidence] wrote %s", f))
  }

  sm_marg <- tryCatch(RoBMA::summary_models(fit_RoBMA, type = "marginal"),
                      error = function(e) {
                        message("  [evidence] summary_models(marginal) failed: ",
                                conditionMessage(e)); NULL })
  sm_ind  <- tryCatch(RoBMA::summary_models(fit_RoBMA, type = "individual"),
                      error = function(e) {
                        message("  [evidence] summary_models(individual) failed: ",
                                conditionMessage(e)); NULL })

  marg <- if (!is.null(sm_marg)) sm_marg$marginal   else NULL
  ind  <- if (!is.null(sm_ind))  sm_ind$individual  else NULL

  # (3) ALWAYS save the raw audit tables first so a later failure still
  # leaves an audit trail.
  if (!is.null(marg)) {
    marg_long <- do.call(rbind, lapply(names(marg), function(nm) {
      tb <- .as_plain_df(marg[[nm]])
      data.frame(component = nm,
                 label     = rownames(as.data.frame(marg[[nm]])),
                 tb, stringsAsFactors = FALSE, check.names = FALSE)
    }))
    write_audit(marg_long, "models_marginal")
  }
  if (!is.null(ind)) write_audit(ind, "models_individual")

  if (is.null(marg) || is.null(ind)) {
    warning("extract_model_family_evidence: summary_models() unavailable; ",
            "raw audit tables saved where possible, returning NA + uncertain.")
    na_list$validation_failure_reason <- "missing_package_component"
    return(na_list)
  }

  ind <- as.data.frame(ind, stringsAsFactors = FALSE, check.names = FALSE)

  # (4) classify via the package's own marginal label -> Hypothesis map.
  build_map <- function(component_key) {
    nm <- .RoBMA4_COMPONENT[[component_key]]
    tb <- marg[[nm]]
    if (is.null(tb)) return(NULL)
    tb_df <- as.data.frame(tb, stringsAsFactors = FALSE, check.names = FALSE)
    labs  <- trimws(rownames(tb_df))
    hyp   <- as.character(tb_df[["Hypothesis"]])
    if (is.null(hyp) || length(hyp) != length(labs)) return(NULL)
    setNames(hyp, labs)
  }
  map_effect <- build_map("effect")
  map_het    <- build_map("het")
  map_bias   <- build_map("bias")

  classify_present <- function(labels, map) {
    if (is.null(map) || is.null(labels)) return(rep(NA, length(labels)))
    hyp <- map[trimws(as.character(labels))]
    out <- rep(NA, length(labels))
    out[hyp == "Alternative"] <- TRUE
    out[hyp == "Null"]        <- FALSE
    out                                   # NA = label not in package map
  }
  eff_present  <- classify_present(ind[["Effect"]],           map_effect)
  het_present  <- classify_present(ind[["Heterogeneity"]],    map_het)
  bias_present <- classify_present(ind[["Publication Bias"]], map_bias)

  unresolved <- sum(is.na(eff_present)) + sum(is.na(het_present)) +
                sum(is.na(bias_present))

  # (8-readability) explicit family labels in the annotated individual CSV so
  # debugging does not depend on visually blank "None" cells.
  fam_lab <- function(present, pos, neg)
    ifelse(is.na(present), NA_character_, ifelse(present, pos, neg))
  ind_dbg <- data.frame(
    ind,
    effect_present = eff_present,
    het_present    = het_present,
    bias_present   = bias_present,
    mu_family      = fam_lab(eff_present,  "muplus",    "mu0"),
    tau_family     = fam_lab(het_present,  "tauplus",   "tau0"),
    omega_family   = fam_lab(bias_present, "omegaplus", "omega0"),
    rigor_family   = (eff_present & !bias_present),
    stringsAsFactors = FALSE, check.names = FALSE
  )
  write_audit(ind_dbg, "models_individual")   # overwrite with annotated frame

  prior_p <- suppressWarnings(as.numeric(ind[["prior_prob"]]))
  post_p  <- suppressWarnings(as.numeric(ind[["post_prob"]]))

  prior_sum <- sum(prior_p, na.rm = TRUE)
  post_sum  <- sum(post_p,  na.rm = TRUE)
  partition_ok <- is.finite(prior_sum) && is.finite(post_sum) &&
                  abs(prior_sum - 1) < 1e-3 && abs(post_sum - 1) < 1e-3

  # (5) family + joint-cell masses
  fam_mass <- function(keep) {
    keep <- keep & !is.na(keep)
    c(prior = sum(prior_p[keep], na.rm = TRUE),
      post  = sum(post_p[keep],  na.rm = TRUE))
  }
  muplus <- eff_present;  mu0 <- !eff_present
  omegap <- bias_present; omega0 <- !bias_present

  m_effect  <- fam_mass(muplus)
  m_het     <- fam_mass(het_present)
  m_bias    <- fam_mass(omegap)
  m_nobias  <- fam_mass(omega0)
  c_00 <- fam_mass(mu0    & omega0)   # mu0,    omega0
  c_p0 <- fam_mass(muplus & omega0)   # mu+,    omega0  == rigor
  c_0p <- fam_mass(mu0    & omegap)   # mu0,    omega+
  c_pp <- fam_mass(muplus & omegap)   # mu+,    omega+

  # (6) inclusion BFs (joint odds; never products of marginal BFs)
  bf_effect <- .bf_from_odds(m_effect[["prior"]], m_effect[["post"]])
  bf_het    <- .bf_from_odds(m_het[["prior"]],    m_het[["post"]])
  bf_bias   <- .bf_from_odds(m_bias[["prior"]],   m_bias[["post"]])

  # Joint mu x omega cell inclusion BFs: each cell family vs the rest of the
  # product space, via the SAME robust .bf_from_odds() helper.
  bf_c00 <- .bf_from_odds(c_00[["prior"]], c_00[["post"]])  # mu0,  omega0
  bf_cp0 <- .bf_from_odds(c_p0[["prior"]], c_p0[["post"]])  # mu+,  omega0
  bf_c0p <- .bf_from_odds(c_0p[["prior"]], c_0p[["post"]])  # mu0,  omega+
  bf_cpp <- .bf_from_odds(c_pp[["prior"]], c_pp[["post"]])  # mu+,  omega+

  log10BF_effect <- .safe_log10_bf(bf_effect)
  log10BF_het    <- .safe_log10_bf(bf_het)
  log10BF_bias   <- .safe_log10_bf(bf_bias)
  log10BF_mu0_omega0       <- .safe_log10_bf(bf_c00)
  log10BF_muplus_omega0    <- .safe_log10_bf(bf_cp0)
  log10BF_mu0_omegaplus    <- .safe_log10_bf(bf_c0p)
  log10BF_muplus_omegaplus <- .safe_log10_bf(bf_cpp)
  # MARGINAL no-bias BF = 1 / BF_bias exactly (exact complement of bias).
  log10BF_no_bias <- if (is.finite(log10BF_bias)) {
    -log10BF_bias
  } else {
    .safe_log10_bf(.bf_from_odds(m_nobias[["prior"]], m_nobias[["post"]]))
  }

  # SELECTED rigor (estimand_version = .ESTIMAND_VERSION). Rigor contrasts the
  # two NO-BIAS (omega0) branches: the effect-present branch (mu+ . omega0,
  # README d_k^R=+) vs the no-effect branch (mu0 . omega0, README d_k^R=0),
  # heterogeneity marginalized inside each branch. The headline
  # `log10BF_rigor` is the SELECTED max of the two branch inclusion BFs - a
  # selected statistic, NOT a single fixed-family BF (hence no single
  # prior_p_rigor / post_p_rigor; the branch fields are authoritative). These
  # are ordinary model-family BFs computed from JOINT individual-model mass;
  # the math/identities are UNCHANGED by the v4 vocabulary reset -- only the
  # `_null` -> `_no_effect` field name changes (README contract).
  log10BF_rigor_effect    <- log10BF_muplus_omega0
  log10BF_rigor_no_effect <- log10BF_mu0_omega0
  log10BF_rigor           <- pmax(log10BF_rigor_effect,
                                  log10BF_rigor_no_effect, na.rm = FALSE)
  # rigor_direction: ALWAYS populated whenever BOTH branch BFs are available
  # (NA only when a branch BF is itself NA). Base-R mirror of the required
  # dplyr::case_when(): a tie (effect == no-effect) resolves to "effect"; the
  # explicit `no_effect > effect` clause makes the no-effect branch win
  # explicit. The manuscript notation may write the no-effect branch as
  # d_k^R=0, but the STORED literal is "no_effect" on purpose: the string
  # "null" is a missing-value sentinel in some CSV/JSON parsers (pandas,
  # Excel) and would render blank downstream. Allowed stored values are
  # exactly .RIGOR_DIRECTION_LEVELS = c("effect", "no_effect").
  rigor_direction <-
    if (is.na(log10BF_rigor_effect) || is.na(log10BF_rigor_no_effect)) {
      NA_character_
    } else if (log10BF_rigor_effect >= log10BF_rigor_no_effect) {
      "effect"
    } else if (log10BF_rigor_no_effect > log10BF_rigor_effect) {
      "no_effect"
    } else {
      NA_character_   # unreachable for non-NA reals (total order)
    }
  rigor_margin <- abs(log10BF_rigor_effect - log10BF_rigor_no_effect)
  # Derived conservative interpretation (README rigor_category table). Pure
  # function of the two branch BFs + direction; affects no fitting.
  rigor_category <- .rigor_category(log10BF_rigor_effect,
                                    log10BF_rigor_no_effect,
                                    log10BF_rigor, rigor_direction)


  # (7) validation against the package's own marginal summaries.
  # G1: ONLY effect/het/bias have a direct package marginal row in
  # summary()$inclusion_components. no_bias and rigor are DERIVED from joint
  # individual-model mass and have no package analogue; they are written to
  # the validation CSV for transparency (validation_class =
  # "derived_no_package_analogue") but NEVER gate trust.
  s_ic <- tryCatch(summary(fit_RoBMA)$inclusion_components,
                   error = function(e) NULL)

  # log10|BF| difference robust at the post -> 0/1 saturation boundary:
  # 0 for matched Inf/Inf or 0/0, NA for a genuine Inf-vs-finite mismatch.
  bf_logdiff <- function(a, b) {
    if (is.na(a) || is.na(b)) return(NA_real_)
    if (is.infinite(a) || is.infinite(b)) {
      if (is.infinite(a) && is.infinite(b) && sign(a) == sign(b)) return(0)
      return(NA_real_)
    }
    if (a == 0 || b == 0) return(if (a == 0 && b == 0) 0 else NA_real_)
    abs(log10(a) - log10(b))
  }

  val_row <- function(name, comp_key, ip, ipost, ibf) {
    is_pkg  <- !is.null(comp_key)
    pp <- ppost <- pbf_rep <- NA_real_
    if (is_pkg && !is.null(s_ic)) {
      rlab    <- .RoBMA4_COMPONENT[[comp_key]]
      pp      <- .bt_cell(s_ic, rlab, "prior_prob")
      ppost   <- .bt_cell(s_ic, rlab, "post_prob")
      pbf_rep <- .bt_cell(s_ic, rlab, "inclusion_BF")
    }
    has_pkg <- is_pkg && is.finite(pp) && is.finite(ppost)
    # G2: the gate compares the individual BF against the package BF
    # RECOMPUTED from the package's OWN prior/post with the SAME
    # .bf_from_odds() the individual side uses. RoBMA's reported
    # inclusion_BF can be a large finite number where our odds form
    # saturates to Inf at post ~ 1 (e.g. reported 29999 vs Inf); validating
    # against one consistent definition with identical prior/post removes
    # that artifact. The RoBMA-reported value is still recorded.
    pbf_chk <- if (has_pkg) .bf_from_odds(pp, ppost) else NA_real_
    bf_ok   <- if (has_pkg) same_bf(ibf, pbf_chk)    else NA

    data.frame(
      quantity            = name,
      validation_class    = if (is_pkg) "package_marginal" else
                              "derived_no_package_analogue",
      individual_prior    = ip, individual_post = ipost, individual_BF = ibf,
      package_prior       = pp, package_post    = ppost,
      package_BF_reported = pbf_rep,
      package_BF_check    = pbf_chk,
      abs_diff_prior   = if (has_pkg) abs(ip - pp)       else NA_real_,
      within_tol_prior = if (has_pkg) abs(ip - pp) < tol_prob else NA,
      abs_diff_post    = if (has_pkg) abs(ipost - ppost) else NA_real_,
      within_tol_post  = if (has_pkg) abs(ipost - ppost) < tol_prob else NA,
      bf_log10_diff    = if (has_pkg) bf_logdiff(ibf, pbf_chk) else NA_real_,
      bf_match         = bf_ok,
      stringsAsFactors = FALSE
    )
  }

  validation <- rbind(
    val_row("effect",       "effect", m_effect[["prior"]], m_effect[["post"]], bf_effect),
    val_row("het",          "het",    m_het[["prior"]],    m_het[["post"]],    bf_het),
    val_row("bias",         "bias",   m_bias[["prior"]],   m_bias[["post"]],   bf_bias),
    val_row("no_bias",       NULL,    m_nobias[["prior"]], m_nobias[["post"]],
            .bf_from_odds(m_nobias[["prior"]], m_nobias[["post"]])),
    # SELECTED rigor branches (derived; no direct package marginal analogue).
    val_row("rigor_effect",    NULL,  c_p0[["prior"]],     c_p0[["post"]],     bf_cp0),
    val_row("rigor_no_effect", NULL,  c_00[["prior"]],     c_00[["post"]],     bf_c00)
  )
  attr(validation, "partition_ok")      <- partition_ok
  attr(validation, "unresolved_labels") <- unresolved
  write_audit(validation, "model_family_validation")

  # G1/G3: gate uses ONLY the package-marginal rows (effect/het/bias).
  comp <- validation[validation$validation_class == "package_marginal" &
                      validation$quantity %in% c("effect", "het", "bias"), ]

  pkg_present <- nrow(comp) == 3L &&
    all(is.finite(comp$package_prior)) && all(is.finite(comp$package_post))

  # G3: probability validation and BF validation are separate gates.
  component_probability_validation_ok <-
    pkg_present &&
    all(!is.na(comp$within_tol_prior) & comp$within_tol_prior) &&
    all(!is.na(comp$within_tol_post)  & comp$within_tol_post)

  bf_has_na <- pkg_present && any(is.na(comp$bf_match))
  component_bf_validation_ok <-
    pkg_present && !bf_has_na &&
    all(!is.na(comp$bf_match) & comp$bf_match)

  # G3: overall component validation requires BOTH to pass.
  component_validation_ok <-
    component_probability_validation_ok && component_bf_validation_ok

  validation_failure_reason <-
    if (unresolved > 0L)                            "unresolved_labels"
    else if (!partition_ok)                          "partition_not_one"
    else if (!pkg_present)                           "missing_package_component"
    else if (!component_probability_validation_ok)   "probability_mismatch"
    else if (bf_has_na)                              "nonfinite_bf_comparison"
    else if (!component_bf_validation_ok)            "bf_mismatch"
    else if (component_validation_ok)                "ok"
    else                                             "unknown"

  max_abs_diff_component_prior <- suppressWarnings(
    max(comp$abs_diff_prior, na.rm = TRUE))
  max_abs_diff_component_post <- suppressWarnings(
    max(comp$abs_diff_post, na.rm = TRUE))
  max_abs_diff_component_bf <- suppressWarnings(
    max(comp$bf_log10_diff, na.rm = TRUE))
  if (!is.finite(max_abs_diff_component_prior)) max_abs_diff_component_prior <- NA_real_
  if (!is.finite(max_abs_diff_component_post))  max_abs_diff_component_post  <- NA_real_
  if (!is.finite(max_abs_diff_component_bf))    max_abs_diff_component_bf    <- NA_real_

  # G5: strict safety for REAL failures only (unresolved labels, mass not a
  # partition, genuine prior/post mismatch, genuine BF mismatch, or a missing
  # package component). A pure Inf-vs-finite saturation artifact where the
  # probabilities match exactly is NO LONGER treated as a failure.
  uncertain <- (unresolved > 0L) || !partition_ok || !component_validation_ok

  status <- list(
    uncertain                           = uncertain,
    partition_ok                        = partition_ok,
    unresolved_labels                   = as.integer(unresolved),
    component_probability_validation_ok = component_probability_validation_ok,
    component_bf_validation_ok          = component_bf_validation_ok,
    component_validation_ok             = component_validation_ok,
    validation_failure_reason           = validation_failure_reason,
    max_abs_diff_component_prior        = max_abs_diff_component_prior,
    max_abs_diff_component_post         = max_abs_diff_component_post,
    max_abs_diff_component_bf           = max_abs_diff_component_bf,
    validation                          = validation
  )

  if (uncertain) {
    warning(sprintf(
      paste0("extract_model_family_evidence: classification UNCERTAIN for '%s' ",
             "(reason=%s, unresolved=%d, partition_ok=%s, prob_ok=%s, bf_ok=%s). ",
             "Raw debug written; trusted BF/family fields set NA."),
      stem, validation_failure_reason, unresolved, partition_ok,
      component_probability_validation_ok, component_bf_validation_ok))
    out <- na_list
    out[names(status)] <- status
    return(out)
  }

  if (verbose) {
    message(sprintf(
      "  [evidence] %s: log10BF effect=%.3f het=%.3f bias=%.3f no_bias=%.3f rigor=%.3f",
      stem, log10BF_effect, log10BF_het, log10BF_bias,
      log10BF_no_bias, log10BF_rigor))
  }

  c(list(
    prior_p_effect  = m_effect[["prior"]],  post_p_effect  = m_effect[["post"]],
    log10BF_effect  = log10BF_effect,
    prior_p_het     = m_het[["prior"]],     post_p_het     = m_het[["post"]],
    log10BF_het     = log10BF_het,
    prior_p_bias    = m_bias[["prior"]],    post_p_bias    = m_bias[["post"]],
    log10BF_bias    = log10BF_bias,
    prior_p_no_bias = m_nobias[["prior"]],  post_p_no_bias = m_nobias[["post"]],
    log10BF_no_bias = log10BF_no_bias,

    prior_p_mu0_omega0       = c_00[["prior"]], post_p_mu0_omega0       = c_00[["post"]],
    log10BF_mu0_omega0       = log10BF_mu0_omega0,
    prior_p_muplus_omega0    = c_p0[["prior"]], post_p_muplus_omega0    = c_p0[["post"]],
    log10BF_muplus_omega0    = log10BF_muplus_omega0,
    prior_p_mu0_omegaplus    = c_0p[["prior"]], post_p_mu0_omegaplus    = c_0p[["post"]],
    log10BF_mu0_omegaplus    = log10BF_mu0_omegaplus,
    prior_p_muplus_omegaplus = c_pp[["prior"]], post_p_muplus_omegaplus = c_pp[["post"]],
    log10BF_muplus_omegaplus = log10BF_muplus_omegaplus,

    # SELECTED rigor: effect-present vs no-effect NO-BIAS branches
    # (heterogeneity marginalized within each branch); log10BF_rigor is the
    # selected max, NOT a single-family BF. The no-effect branch fields use
    # the parser-safe `_no_effect` suffix (README contract), never `_null`.
    prior_p_rigor_effect    = c_p0[["prior"]], post_p_rigor_effect    = c_p0[["post"]],
    log10BF_rigor_effect    = log10BF_rigor_effect,
    prior_p_rigor_no_effect = c_00[["prior"]], post_p_rigor_no_effect = c_00[["post"]],
    log10BF_rigor_no_effect = log10BF_rigor_no_effect,
    log10BF_rigor   = log10BF_rigor,
    rigor_direction = rigor_direction,
    rigor_margin    = rigor_margin,
    rigor_category  = rigor_category
  ), status)
}


# ==== v4 SIDECAR ROW CONSTRUCTION ===========================================
# Builds exactly one lean .SIDECAR_V4_COLS row. `meta` carries the identity
# vocabulary: corpus_id, scheme, stratum, dataset_id, source_article,
# outcome_slug, path_stratum. Derived reporting conveniences (attenuation,
# conditionals) are deliberately NOT stored -- 60_estimand_tables.R
# regenerates them from these primitives; as_zplot diagnostics go to the
# separate per-stratum zplot artifact.
.build_sidecar_row_v4 <- function(fit_RE, fit_RoBMA, n_studies, meta,
                                   evidence, run_id = NULL) {

  mu_RE  <- .estimate_triplet(fit_RE,    "mu")
  tau_RE <- .estimate_triplet(fit_RE,    "tau")
  mu_BC  <- .estimate_triplet(fit_RoBMA, "mu")
  tau_BC <- .estimate_triplet(fit_RoBMA, "tau")

  pick <- function(name) {
    v <- evidence[[name]]
    if (is.null(v) || length(v) == 0L) NA_real_ else as.numeric(v[1])
  }
  pick_lgl <- function(name, default = NA) {
    v <- evidence[[name]]
    if (is.null(v) || length(v) == 0L) default else as.logical(v[1])
  }
  pick_chr <- function(name, default = NA_character_) {
    v <- evidence[[name]]
    if (is.null(v) || length(v) == 0L) default else as.character(v[1])
  }

  # Single parsed identity (00_utils.R): analysis_id, source_key, structured
  # analysis_variant, parent_dataset_id, exclusion_reason, legacy_basename,
  # and the positive_effect_interpretation placeholder all come from here so
  # the catalog (10) and this sidecar row can never disagree.
  ident <- .build_identity_fields(
    corpus_id      = meta$corpus_id,
    scheme         = meta$scheme,
    stratum        = meta$stratum,
    source_article = meta$source_article,
    outcome_slug   = meta$outcome_slug,
    dataset_id     = meta$dataset_id,
    path_stratum   = meta$path_stratum
  )

  data.frame(
    # ---- identity & corpus metadata ----
    corpus_id        = ident$corpus_id,
    scheme           = ident$scheme,
    stratum          = ident$stratum,
    dataset_id       = ident$dataset_id,
    analysis_id      = ident$analysis_id,
    source_key       = ident$source_key,
    source_article   = ident$source_article,
    source_year      = ident$source_year,
    outcome_slug     = ident$outcome_slug,
    analysis_variant = ident$analysis_variant,
    parent_dataset_id = ident$parent_dataset_id,
    exclusion_reason = ident$exclusion_reason,
    path_stratum     = ident$path_stratum,
    legacy_basename  = ident$legacy_basename,
    has_excl_variant = ident$has_excl_variant,
    positive_effect_interpretation = ident$positive_effect_interpretation,
    schema_version   = .SCHEMA_VERSION,
    estimand_version = .ESTIMAND_VERSION,
    n_studies        = as.integer(n_studies),

    mu_RE  = mu_RE[["est"]],  mu_RE_lCI = mu_RE[["lCI"]],  mu_RE_uCI = mu_RE[["uCI"]],
    mu_BC  = mu_BC[["est"]],  mu_BC_lCI = mu_BC[["lCI"]],  mu_BC_uCI = mu_BC[["uCI"]],
    tau_RE = tau_RE[["est"]], tau_RE_lCI = tau_RE[["lCI"]], tau_RE_uCI = tau_RE[["uCI"]],
    tau_BC = tau_BC[["est"]], tau_BC_lCI = tau_BC[["lCI"]], tau_BC_uCI = tau_BC[["uCI"]],

    prior_p_effect  = pick("prior_p_effect"),
    post_p_effect   = pick("post_p_effect"),
    log10BF_effect  = pick("log10BF_effect"),
    prior_p_het     = pick("prior_p_het"),
    post_p_het      = pick("post_p_het"),
    log10BF_het     = pick("log10BF_het"),
    prior_p_bias    = pick("prior_p_bias"),
    post_p_bias     = pick("post_p_bias"),
    log10BF_bias    = pick("log10BF_bias"),
    prior_p_no_bias = pick("prior_p_no_bias"),
    post_p_no_bias  = pick("post_p_no_bias"),
    log10BF_no_bias = pick("log10BF_no_bias"),

    prior_p_mu0_omega0       = pick("prior_p_mu0_omega0"),
    post_p_mu0_omega0        = pick("post_p_mu0_omega0"),
    log10BF_mu0_omega0       = pick("log10BF_mu0_omega0"),
    prior_p_muplus_omega0    = pick("prior_p_muplus_omega0"),
    post_p_muplus_omega0     = pick("post_p_muplus_omega0"),
    log10BF_muplus_omega0    = pick("log10BF_muplus_omega0"),
    prior_p_mu0_omegaplus    = pick("prior_p_mu0_omegaplus"),
    post_p_mu0_omegaplus     = pick("post_p_mu0_omegaplus"),
    log10BF_mu0_omegaplus    = pick("log10BF_mu0_omegaplus"),
    prior_p_muplus_omegaplus = pick("prior_p_muplus_omegaplus"),
    post_p_muplus_omegaplus  = pick("post_p_muplus_omegaplus"),
    log10BF_muplus_omegaplus = pick("log10BF_muplus_omegaplus"),

    # SELECTED rigor branch fields (no ambiguous single prior_p_rigor /
    # post_p_rigor: log10BF_rigor is a selected max, not a single-family BF).
    # The no-effect branch uses the parser-safe `_no_effect` suffix.
    prior_p_rigor_effect    = pick("prior_p_rigor_effect"),
    post_p_rigor_effect     = pick("post_p_rigor_effect"),
    log10BF_rigor_effect    = pick("log10BF_rigor_effect"),
    prior_p_rigor_no_effect = pick("prior_p_rigor_no_effect"),
    post_p_rigor_no_effect  = pick("post_p_rigor_no_effect"),
    log10BF_rigor_no_effect = pick("log10BF_rigor_no_effect"),
    log10BF_rigor           = pick("log10BF_rigor"),
    rigor_direction         = pick_chr("rigor_direction",
                                       default = NA_character_),
    rigor_margin            = pick("rigor_margin"),
    rigor_category          = pick_chr("rigor_category",
                                       default = NA_character_),

    family_evidence_uncertain   = pick_lgl("uncertain", default = TRUE),
    partition_ok                = pick_lgl("partition_ok", default = NA),
    unresolved_labels           = {
      v <- evidence[["unresolved_labels"]]
      if (is.null(v) || length(v) == 0L) NA_integer_ else as.integer(v[1])
    },
    component_probability_validation_ok = pick_lgl(
      "component_probability_validation_ok", default = FALSE),
    component_bf_validation_ok  = pick_lgl("component_bf_validation_ok",
                                           default = FALSE),
    component_validation_ok     = pick_lgl("component_validation_ok",
                                           default = FALSE),
    validation_failure_reason   = pick_chr("validation_failure_reason",
                                           default = "unknown"),
    max_abs_diff_component_prior = pick("max_abs_diff_component_prior"),
    max_abs_diff_component_post = pick("max_abs_diff_component_post"),
    max_abs_diff_component_bf   = pick("max_abs_diff_component_bf"),

    robma_version      = as.character(utils::packageVersion("RoBMA")),
    bayestools_version = as.character(utils::packageVersion("BayesTools")),
    measure            = CONFIG$measure,
    fit_engine         = sprintf("%s::RoBMA(model_type=%s)+brma",
                                 .FIT_ENGINE_FAMILY, CONFIG$model_type),
    # Single unadjusted baseline convention (00_utils.R .BASELINE_CONVENTION):
    # brma() is one Bayesian random-effects model -> effect-present,
    # heterogeneity-present, no modeled-bias family (muplus_tauplus_omega0);
    # NOT model-averaged and NOT bias-adjusted.
    baseline_engine         = .BASELINE_CONVENTION$baseline_engine,
    baseline_model_family   = .BASELINE_CONVENTION$baseline_model_family,
    baseline_model_averaged = .BASELINE_CONVENTION$baseline_model_averaged,
    baseline_bias_adjusted  = .BASELINE_CONVENTION$baseline_bias_adjusted,
    sample             = CONFIG$sample,
    burnin             = CONFIG$burnin,
    adapt              = CONFIG$adapt,
    chains             = CONFIG$chains,
    thin               = CONFIG$thin,
    seed               = CONFIG$seed,
    model_type         = CONFIG$model_type,
    effect_direction   = CONFIG$effect_direction,
    config_hash        = .config_hash(),
    script_hash        = .script_hash(),
    run_id             = run_id %||% format(Sys.time(), "%Y%m%dT%H%M%S"),

    stringsAsFactors = FALSE
  )[, .SIDECAR_V4_COLS, drop = FALSE]
}


# Append (or replace, by dataset_id) one row in the per-stratum v4 sidecar.
# Atomic + checked. An existing file whose columns do not match the current
# .SIDECAR_V4_COLS is moved aside to <name>_pre_v4.bak.csv (never silently
# migrated or overwritten), so a stale-schema sidecar cannot be appended to.
.append_sidecar_v4 <- function(row_df, csv_path) {
  dir.create(dirname(csv_path), recursive = TRUE, showWarnings = FALSE)
  new <- row_df

  if (file.exists(csv_path)) {
    old <- try(read.csv(csv_path, stringsAsFactors = FALSE,
                        check.names = FALSE), silent = TRUE)
    if (!inherits(old, "try-error") && is.data.frame(old) && nrow(old) > 0L) {
      if (identical(sort(colnames(old)), sort(.SIDECAR_V4_COLS))) {
        old <- old[old$dataset_id != row_df$dataset_id, , drop = FALSE]
        new <- rbind(old[, .SIDECAR_V4_COLS, drop = FALSE], row_df)
      } else {
        bak <- sub("\\.csv$", "_pre_v4.bak.csv", csv_path)
        if (file.exists(bak)) unlink(bak)
        file.rename(csv_path, bak)
        warning(sprintf(
          "Existing sidecar '%s' is not current v4 schema; moved to '%s'.",
          csv_path, bak))
      }
    }
  }

  new <- new[order(new$stratum, new$source_article, new$outcome_slug), ,
             drop = FALSE]
  new <- new[, .SIDECAR_V4_COLS, drop = FALSE]
  atomic_write_csv(new, csv_path)
  .print_sidecar_validation(new, csv_path)
}


# Compact post-write validation summary. Non-missing (not finite) checks for
# log10BF_* so Inf counts as a real value.
.print_sidecar_validation <- function(df, csv_path = NULL) {
  if (is.null(df) || nrow(df) == 0L) return(invisible(NULL))
  pop <- function(x) sum(!is.na(x) & !is.nan(x))
  n <- nrow(df)
  cat("\nv4 sidecar validation:\n")
  if (!is.null(csv_path)) cat(sprintf("  file: %s\n", csv_path))
  cat(sprintf("  rows: %d\n", n))
  for (col in c("mu_RE","mu_BC","tau_RE","tau_BC",
                "log10BF_effect","log10BF_bias","log10BF_no_bias",
                "log10BF_rigor_effect","log10BF_rigor_no_effect",
                "log10BF_rigor")) {
    cat(sprintf("  %-24s populated: %d / %d\n", col, pop(df[[col]]), n))
  }
  if ("rigor_direction" %in% names(df)) {
    rd <- table(factor(df$rigor_direction,
                       levels = .RIGOR_DIRECTION_LEVELS),
                useNA = "ifany")
    cat("  rigor_direction:",
        paste(sprintf("%s=%d", names(rd), as.integer(rd)),
              collapse = " "), "\n")
  }
  if ("rigor_category" %in% names(df)) {
    rc <- sort(table(as.character(df$rigor_category), useNA = "ifany"),
               decreasing = TRUE)
    cat("  rigor_category:",
        paste(sprintf("%s=%d", names(rc), as.integer(rc)),
              collapse = " "), "\n")
  }
  fin <- is.finite(df$log10BF_bias) & is.finite(df$log10BF_no_bias)
  if (any(fin)) {
    mism <- sum(abs(df$log10BF_no_bias[fin] + df$log10BF_bias[fin]) > 1e-9)
    cat(sprintf("  log10BF_no_bias == -log10BF_bias (finite): %s\n",
                if (mism == 0L) "OK" else sprintf("MISMATCH x%d", mism)))
  }
  unc <- sum(isTRUE(df$family_evidence_uncertain) |
             df$family_evidence_uncertain %in% c(TRUE, "TRUE"), na.rm = TRUE)
  cat(sprintf("  family_evidence_uncertain rows: %d / %d\n", unc, n))
  if ("validation_failure_reason" %in% names(df)) {
    tb <- sort(table(as.character(df$validation_failure_reason)),
               decreasing = TRUE)
    cat("  validation_failure_reason:",
        paste(sprintf("%s=%d", names(tb), as.integer(tb)),
              collapse = " "), "\n")
  }
  invisible(NULL)
}


# Append (or replace, by dataset_id) one row in the per-stratum secondary
# bias-diagnostics artifact (.ZPLOT_DIAG_COLS). Kept OUT of the canonical
# sidecar so it stays a lean primitive table; non-blocking and best-effort.
.append_zplot_diagnostics <- function(dataset_id, analysis_id, stratum,
                                       zdiag, csv_path, run_id = NULL) {
  num <- function(v) if (is.null(v) || length(v) == 0L) NA_real_ else
    suppressWarnings(as.numeric(v[1]))
  row <- data.frame(
    dataset_id = dataset_id, analysis_id = analysis_id, stratum = stratum,
    ODR = num(zdiag$ODR), EDR = num(zdiag$EDR),
    Soric_FDR = num(zdiag$Soric_FDR), MissingN = num(zdiag$MissingN),
    run_id = run_id %||% format(Sys.time(), "%Y%m%dT%H%M%S"),
    stringsAsFactors = FALSE
  )[, .ZPLOT_DIAG_COLS, drop = FALSE]

  new <- row
  if (file.exists(csv_path)) {
    old <- try(read.csv(csv_path, stringsAsFactors = FALSE,
                        check.names = FALSE), silent = TRUE)
    if (!inherits(old, "try-error") && is.data.frame(old) && nrow(old) > 0L &&
        identical(sort(colnames(old)), sort(.ZPLOT_DIAG_COLS))) {
      old <- old[old$dataset_id != dataset_id, , drop = FALSE]
      new <- rbind(old[, .ZPLOT_DIAG_COLS, drop = FALSE], row)
    }
  }
  new <- new[order(new$dataset_id), , drop = FALSE]
  atomic_write_csv(new, csv_path)
  invisible(csv_path)
}


# ==== MAIN ENTRY POINT ======================================================

fit_robma_models <- function(
    data,                   # data.frame: g/se_g (preferred) or d/se_d fallback
    dataset_name   = NULL,  # e.g. "post2012_fiber_hba1c"; defaults to deparsed
    stratum        = NULL,  # conceptual group; parsed from the stem if NULL
    source_article = NULL,  # source-article token; parsed if NULL
    outcome_slug   = NULL,  # outcome token; parsed if NULL (NOT the mu+ comp.)
    study_col      = NULL   # optional: column used as the RoBMA4 `cluster`
) {

  if (!is.data.frame(data)) stop("data must be a data.frame")
  if (is.null(dataset_name)) dataset_name <- deparse(substitute(data))

  # Arm the RoBMA/runjags runtime here (NOT at source time): keeps sourcing
  # this script define-only while still configuring runjags before any fit.
  .ensure_robma_runtime()

  parts          <- strsplit(dataset_name, "_")[[1]]
  source_article <- norm_slug(source_article %||%
                      (if (length(parts) >= 1) parts[1] else "misc"))
  stratum        <- norm_slug(stratum %||%
                      (if (length(parts) >= 2) parts[2] else "misc"))
  outcome_slug   <- norm_slug(outcome_slug %||%
                      (if (length(parts) >= 3)
                        paste(parts[3:length(parts)], collapse = "_") else "misc"))

  path_stratum <- stratum               # physical data-tree stratum folder
  dataset_id <- sprintf("%s_%s_%s", source_article, stratum, outcome_slug)
  paths      <- .paths_for(stratum, source_article, outcome_slug)
  run_id     <- paste0(format(Sys.time(), "%Y%m%dT%H%M%S"), "_", dataset_id)

  # ---- Validate required columns and data quality --------------------------
  ## RoBMA4 effect-size interface (yi/sei). Preferred/default input is Hedges'
  ## g as `g`/`se_g`; `d`/`se_d` (Cohen's d) is accepted as a no-rename
  ## fallback. Pair selection + finite/positive-SE validation is the shared
  ## .resolve_effect_input() (00_utils.R) so 20 and 40 cannot drift.
  eff <- .resolve_effect_input(data)
  if (nrow(data) < 3) stop("Minimum 3 studies required")
  if (!is.null(study_col) && !study_col %in% colnames(data))
    stop(sprintf("Study column '%s' not found", study_col))

  yi  <- eff$yi
  sei <- eff$sei

  slab <- NULL
  lab_col <- intersect(c("Author", "author", "study", "Study", "slab", "label"),
                       colnames(data))
  if (length(lab_col) > 0) slab <- as.character(data[[lab_col[1]]])
  cluster <- if (!is.null(study_col)) data[[study_col]] else NULL

  message(sprintf("Fitting '%s' (stratum=%s, n=%d studies)",
                  dataset_id, stratum, nrow(data)))
  message(sprintf("RoBMA4: measure=%s, effect_input=%s (%s/%s), model_type=%s, sample=%d, burnin=%d, adapt=%d, chains=%d",
                  CONFIG$measure, eff$effect_input, eff$est_col, eff$se_col,
                  CONFIG$model_type, CONFIG$sample,
                  CONFIG$burnin, CONFIG$adapt, CONFIG$chains))

  # ---- Baseline: brma() unadjusted random-effects (RoBMA4: replaces NoBMA) --
  message("Fitting brma baseline (unadjusted random-effects)...")
  fit_RE <- tryCatch(
    RoBMA::brma(
      yi = yi, sei = sei, measure = CONFIG$measure,
      slab = slab, cluster = cluster,
      sample = CONFIG$sample, burnin = CONFIG$burnin, adapt = CONFIG$adapt,
      chains = CONFIG$chains, thin = CONFIG$thin, parallel = CONFIG$parallel,
      seed = CONFIG$seed, silent = TRUE
    ),
    error = function(e) {
      warning(sprintf("brma baseline fit failed: %s", conditionMessage(e)))
      NULL
    })

  # ---- Full RoBMA-PSMA product-space ensemble (RoBMA4) ---------------------
  message("Fitting RoBMA PSMA ensemble (bias-adjusted product space)...")
  fit_RoBMA <- tryCatch(
    RoBMA::RoBMA(
      yi = yi, sei = sei, measure = CONFIG$measure,
      slab = slab, cluster = cluster,
      model_type = CONFIG$model_type,
      effect_direction = CONFIG$effect_direction,
      sample = CONFIG$sample, burnin = CONFIG$burnin, adapt = CONFIG$adapt,
      chains = CONFIG$chains, thin = CONFIG$thin, parallel = CONFIG$parallel,
      seed = CONFIG$seed, silent = TRUE
    ),
    error = function(e) {
      warning(sprintf("RoBMA PSMA fit failed: %s", conditionMessage(e)))
      NULL
    })

  # ---- zplot diagnostics (RoBMA4: as_zplot; secondary, NON-BLOCKING) -------
  zplot_RE <- zplot_RoBMA <- NULL
  if (isTRUE(CONFIG$zplot)) {
    zplot_RE <- tryCatch(RoBMA::as_zplot(fit_RE),
                         error = function(e) {
                           message("  [zplot] RE: ", conditionMessage(e)); NULL })
    zplot_RoBMA <- tryCatch(RoBMA::as_zplot(fit_RoBMA),
                            error = function(e) {
                              message("  [zplot] RoBMA: ", conditionMessage(e)); NULL })
  }

  # ---- Stamp objects into the global environment (v4 names) ----------------
  assign_with_notice <- function(name, obj) {
    if (!is.null(obj)) {
      if (exists(name, envir = .GlobalEnv)) message(sprintf("Overwriting: %s", name))
      assign(name, obj, envir = .GlobalEnv)
    }
  }
  assign_with_notice(paste0("fit_RE4_",     dataset_id), fit_RE)
  assign_with_notice(paste0("fit_RoBMA4_",  dataset_id), fit_RoBMA)
  assign_with_notice(paste0("zplot_RE4_",   dataset_id), zplot_RE)
  assign_with_notice(paste0("zplot_RoBMA4_", dataset_id), zplot_RoBMA)

  # ---- Persist versioned *.rds artifacts -----------------------------------
  if (CONFIG$save_outputs) {
    dir.create(paths$out_dir, recursive = TRUE, showWarnings = FALSE)
    if (!is.null(fit_RE))
      saveRDS(fit_RE,    file.path(paths$out_dir, paste0("fit_RE4_",    dataset_id, ".rds")))
    if (!is.null(fit_RoBMA))
      saveRDS(fit_RoBMA, file.path(paths$out_dir, paste0("fit_RoBMA4_", dataset_id, ".rds")))
    if (!is.null(zplot_RE))
      saveRDS(zplot_RE,  file.path(paths$out_dir, paste0("zplot_RE4_",  dataset_id, ".rds")))
    if (!is.null(zplot_RoBMA))
      saveRDS(zplot_RoBMA, file.path(paths$out_dir, paste0("zplot_RoBMA4_", dataset_id, ".rds")))
    message(sprintf("Saved versioned outputs to: %s/", paths$out_dir))
  }

  # ---- Model-family evidence + audit tables --------------------------------
  evidence <- if (!is.null(fit_RoBMA)) {
    extract_model_family_evidence(
      fit_RoBMA,
      audit_dir = if (CONFIG$save_outputs) paths$audit_dir else NULL,
      stem      = dataset_id, verbose = TRUE)
  } else {
    warning(sprintf("RoBMA fit is NULL for %s; rigor/component fields NA.",
                    dataset_id))
    list(uncertain = TRUE)
  }

  zdiag <- .extract_zplot_diagnostics(zp = zplot_RoBMA, fit = fit_RoBMA,
                                      verbose = TRUE)

  # ---- Lean per-stratum v4 sidecar + separate zplot diagnostics ------------
  if (!is.null(fit_RE) || !is.null(fit_RoBMA)) {
    meta <- list(corpus_id      = CONFIG$corpus_id,
                 scheme         = CONFIG$scheme,
                 stratum        = stratum,
                 dataset_id     = dataset_id,
                 source_article = source_article,
                 outcome_slug   = outcome_slug,
                 path_stratum   = path_stratum)
    row  <- .build_sidecar_row_v4(fit_RE, fit_RoBMA, nrow(data), meta,
                                  evidence = evidence, run_id = run_id)
    .append_sidecar_v4(row, paths$sidecar_csv)
    if (CONFIG$save_outputs)
      .append_zplot_diagnostics(dataset_id, row$analysis_id, stratum,
                                zdiag, paths$zplot_csv, run_id = run_id)
    message(sprintf("Updated v4 sidecar: %s", paths$sidecar_csv))
  } else {
    warning(sprintf("Both fits failed for %s", dataset_id))
  }

  # ---- Console-friendly summary --------------------------------------------
  cat("\n=== RESULTS ===\n")
  cat(sprintf("Dataset: %s (stratum=%s, n=%d studies)\n",
              dataset_id, stratum, nrow(data)))
  if (!is.null(fit_RE))
    cat(sprintf("brma baseline mu: %.3f\n", .estimate_triplet(fit_RE, "mu")[["est"]]))
  if (!is.null(fit_RoBMA))
    cat(sprintf("RoBMA-PSMA   mu: %.3f\n", .estimate_triplet(fit_RoBMA, "mu")[["est"]]))
  if (!isTRUE(evidence$uncertain) && !is.null(evidence$log10BF_rigor)) {
    cat(sprintf("log10BF_rigor: %.3f | log10BF_no_bias: %.3f | log10BF_effect: %.3f\n",
                evidence$log10BF_rigor, evidence$log10BF_no_bias,
                evidence$log10BF_effect))
  } else {
    cat("log10BF_rigor: NA (model-family classification uncertain)\n")
  }
  cat(sprintf("Objects: fit_RE4_%s, fit_RoBMA4_%s\n", dataset_id, dataset_id))
  cat("===============\n\n")

  invisible(list(
    fit_RE         = fit_RE,
    fit_RoBMA      = fit_RoBMA,
    zplot_RE       = zplot_RE,
    zplot_RoBMA    = zplot_RoBMA,
    evidence       = evidence,
    dataset_id     = dataset_id,
    stratum        = stratum,
    source_article = source_article,
    outcome_slug   = outcome_slug,
    path_stratum   = path_stratum,
    measure        = CONFIG$measure,
    run_id         = run_id,
    out_dir        = paths$out_dir
  ))
}
