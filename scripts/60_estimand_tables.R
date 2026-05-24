# 60_estimand_tables.R
# ==============================================================================
# Canonical reporting / data-mart layer for the RoBMA 4.0 rigor-estimand
# pipeline.
#
# This is the single source of truth for the schemas of every cleaned tabular
# output. It consumes the LEAN per-stratum v4 sidecars written by
# 20_robma_fit.R / 40_batch_fit.R, regenerates the derived reporting columns
# (the sidecar deliberately does not store them), and writes stable CSV +
# manuscript/supplement TeX tables. Rigor is the headline estimand throughout;
# effect / heterogeneity / bias component evidence is secondary.
#
# Inputs (auto-discovered under `root`, default "output"):
#   * output/<stratum>/<stratum>_robma_summary.csv      lean v4 sidecar
#       (.SIDECAR_V4_COLS, written by 20). One row per analyzed outcome.
#   * output/<stratum>/<stratum>_zplot_diagnostics.csv  optional, secondary
#       as_zplot diagnostics (.ZPLOT_DIAG_COLS, keyed by dataset_id /
#       analysis_id). Missing diagnostics never abort the run.
#   Generated reporting directories (overview / _scratch / the chosen
#   output_dir) are excluded from sidecar discovery.
#
# Outputs (written to <output_dir>, default "output/overview/"):
#   outcome_registry.csv                complete audit / data-mart file
#                                       (one row per analyzed outcome/variant)
#   outcome_registry_compact.csv        human-facing browsing view, sorted by
#                                       descending selected log10BF_rigor
#   outcome_registry_table.tex          supplement longtable
#   stratum_estimands.csv               per stratum + Overall (outcome-weighted)
#   stratum_estimands_table.tex
#   article_balanced_estimands.csv      per stratum + Overall (article-balanced)
#   article_balanced_estimands_table.tex
#   corpus_estimands.csv                numerator/denominator headline claims
#   corpus_estimands_table.tex
#   rigor_category_summary.csv          rigor-category counts/props
#   rigor_direction_summary.csv         effect vs no_effect counts/props
#   rigor_direction_summary_table.tex
#   component_evidence_summary.csv      secondary effect/het/bias/no-bias
#                                       roll-up (long: one row per stratum x
#                                       component)
#
# Selected rigor:
#   log10BF_rigor_effect    = log10BF_muplus_omega0  (clean evidence FOR effect)
#   log10BF_rigor_no_effect = log10BF_mu0_omega0     (clean evidence FOR no eff)
#   log10BF_rigor           = max(rigor_effect, rigor_no_effect)  (SELECTED;
#       a selected statistic, NOT a Bayes factor for one fixed model family)
#   rigor_direction in {effect, no_effect}  (ties -> effect; never "null")
# `omega0` means "no modeled selection / small-study component", which is NOT
# proof the literature is bias-free. "bias" throughout means bias /
# small-study / selection mechanisms, not publication bias alone.
#
# DEFINE-ONLY: sourcing installs functions/constants and a load sentinel.
# No discovery, no file read/write, no plotting, nothing installed merely by
# sourcing. 00_utils.R is sourced sentinel-guarded (it is itself
# side-effect-free); base R is used for I/O so no package is attached at
# source time. Call build_estimand_tables() to actually run.
#
# Quick-Start
#   source("scripts/60_estimand_tables.R")
#   build_estimand_tables()                      # all strata
#   build_estimand_tables(stratum = "fiber")     # one stratum
#   tables <- build_estimand_tables(write_tex = FALSE)
# ==============================================================================


# ---- Shared contract + helpers (sentinel-guarded) --------------------------
# Provides %||%, norm_slug(), format_stratum(), .latex_escape(), .fmt_num(),
# .fmt_pct(), the single-row estimand derivers (.attenuation_pct/.shrink50/
# .sign_flip/.bc_ci_includes_zero), .rigor_category(), the v4 contract
# (.SIDECAR_V4_COLS/.ZPLOT_DIAG_COLS/.SCHEMA_VERSION/.ESTIMAND_VERSION/
# .RIGOR_DIRECTION_LEVELS/.EVIDENCE_THRESHOLDS). 00_utils.R is define-only.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# ==============================================================================
# Schema definitions (stable on-disk column order)
# ==============================================================================

# Sidecar columns carried verbatim into outcome_registry.csv, in reporting
# order. Every name here is a member of .SIDECAR_V4_COLS (00_utils.R); this is
# a curated reordering, never a redefinition of the sidecar contract.
.REGISTRY_SIDECAR_COLS <- c(
  # identity / corpus
  "corpus_id", "scheme", "stratum", "path_stratum",
  "source_article", "source_key", "source_year", "outcome_slug",
  "dataset_id", "analysis_id", "analysis_variant",
  "parent_dataset_id", "exclusion_reason", "n_studies", "has_excl_variant",
  # posterior estimates
  "mu_RE", "mu_RE_lCI", "mu_RE_uCI",
  "mu_BC", "mu_BC_lCI", "mu_BC_uCI",
  "tau_RE", "tau_RE_lCI", "tau_RE_uCI",
  "tau_BC", "tau_BC_lCI", "tau_BC_uCI",
  # marginal component evidence
  "prior_p_effect",  "post_p_effect",  "log10BF_effect",
  "prior_p_het",     "post_p_het",     "log10BF_het",
  "prior_p_bias",    "post_p_bias",    "log10BF_bias",
  "prior_p_no_bias", "post_p_no_bias", "log10BF_no_bias",
  # joint mu x omega model-family evidence (rigor branches come from here)
  "prior_p_muplus_omega0",    "post_p_muplus_omega0",    "log10BF_muplus_omega0",
  "prior_p_mu0_omega0",       "post_p_mu0_omega0",       "log10BF_mu0_omega0",
  "prior_p_muplus_omegaplus", "post_p_muplus_omegaplus", "log10BF_muplus_omegaplus",
  "prior_p_mu0_omegaplus",    "post_p_mu0_omegaplus",    "log10BF_mu0_omegaplus",
  # selected rigor
  "prior_p_rigor_effect",    "post_p_rigor_effect",    "log10BF_rigor_effect",
  "prior_p_rigor_no_effect", "post_p_rigor_no_effect", "log10BF_rigor_no_effect",
  "log10BF_rigor", "rigor_direction", "rigor_margin", "rigor_category",
  # validation / status / reproducibility
  "family_evidence_uncertain", "partition_ok", "unresolved_labels",
  "component_probability_validation_ok", "component_bf_validation_ok",
  "component_validation_ok", "validation_failure_reason",
  "schema_version", "estimand_version", "config_hash", "robma_version",
  "run_id"
)

# Secondary as_zplot diagnostics joined onto the registry (the four numeric
# fields of .ZPLOT_DIAG_COLS; the key/run columns are already in the sidecar).
.REGISTRY_ZPLOT_COLS <- c("ODR", "EDR", "Soric_FDR", "MissingN")

# Derived reporting columns regenerated in 60 from sidecar primitives.
# rigor_margin_reporting is the Inf-safe companion to the raw sidecar
# rigor_margin (which stores abs(branch diff) and is NA for same-sign
# infinities); the raw rigor_margin is kept untouched for audit.
.REGISTRY_DERIVED_COLS <- c(
  "abs_mu_RE", "abs_mu_BC", "attenuation_abs", "attenuation_pct",
  "shrink50", "sign_flip", "bc_ci_includes_zero", "claimed_effect",
  "effect_evidence_category", "het_evidence_category",
  "bias_evidence_category", "no_bias_evidence_category",
  "rigor_direction_display", "rigor_margin_reporting",
  "n_outcomes_in_source", "article_weight", "zplot_diag_joined"
)

# Compact human-facing browsing registry (a column subset; the full
# outcome_registry.csv remains the complete audit/data-mart file). The
# `rigor_margin` column here is sourced from the Inf-safe
# rigor_margin_reporting so a (-Inf,-Inf) row browses as 0, not blank.
.REGISTRY_COMPACT_COLS <- c(
  "stratum", "source_article", "source_year", "outcome_slug",
  "dataset_id", "analysis_variant", "n_studies",
  "mu_RE", "mu_BC", "attenuation_pct", "shrink50", "sign_flip",
  "log10BF_effect", "log10BF_het", "log10BF_bias", "log10BF_no_bias",
  "log10BF_rigor", "rigor_direction", "rigor_category", "rigor_margin",
  "log10BF_rigor_effect", "log10BF_rigor_no_effect",
  "ODR", "EDR", "Soric_FDR", "MissingN"
)

# Sidecar columns coerced to numeric on load (Inf / -Inf preserved; only
# NA / NaN are missing). source_year / n_studies / unresolved_labels are
# whole numbers; the rest are continuous.
.REGISTRY_NUMERIC_COLS <- c(
  "source_year", "n_studies", "unresolved_labels",
  "mu_RE", "mu_RE_lCI", "mu_RE_uCI", "mu_BC", "mu_BC_lCI", "mu_BC_uCI",
  "tau_RE", "tau_RE_lCI", "tau_RE_uCI", "tau_BC", "tau_BC_lCI", "tau_BC_uCI",
  "prior_p_effect", "post_p_effect", "log10BF_effect",
  "prior_p_het", "post_p_het", "log10BF_het",
  "prior_p_bias", "post_p_bias", "log10BF_bias",
  "prior_p_no_bias", "post_p_no_bias", "log10BF_no_bias",
  "prior_p_muplus_omega0", "post_p_muplus_omega0", "log10BF_muplus_omega0",
  "prior_p_mu0_omega0", "post_p_mu0_omega0", "log10BF_mu0_omega0",
  "prior_p_muplus_omegaplus", "post_p_muplus_omegaplus", "log10BF_muplus_omegaplus",
  "prior_p_mu0_omegaplus", "post_p_mu0_omegaplus", "log10BF_mu0_omegaplus",
  "prior_p_rigor_effect", "post_p_rigor_effect", "log10BF_rigor_effect",
  "prior_p_rigor_no_effect", "post_p_rigor_no_effect", "log10BF_rigor_no_effect",
  "log10BF_rigor", "rigor_margin"
)

.REGISTRY_LOGICAL_COLS <- c(
  "has_excl_variant", "family_evidence_uncertain", "partition_ok",
  "component_probability_validation_ok", "component_bf_validation_ok",
  "component_validation_ok"
)

# Minimum v4 columns a sidecar must expose. Their absence is treated as an
# old-schema / malformed sidecar and fails the run loudly (we never silently
# remap legacy `topic` / `author` / `effect` columns).
.REQUIRED_V4_COLS <- c(
  "scheme", "stratum", "source_article", "source_key", "outcome_slug",
  "dataset_id", "analysis_id", "analysis_variant",
  "mu_RE", "mu_BC", "mu_BC_lCI", "mu_BC_uCI",
  "log10BF_effect", "log10BF_het", "log10BF_bias", "log10BF_no_bias",
  "log10BF_muplus_omega0", "log10BF_mu0_omega0",
  "log10BF_rigor_effect", "log10BF_rigor_no_effect",
  "log10BF_rigor", "rigor_direction", "rigor_margin", "rigor_category",
  "schema_version", "estimand_version"
)

# Legacy reporting vocabulary. Migration comment only: these are pre-v4
# column names; their presence WITHOUT the required v4 columns marks an
# old-schema sidecar that must be refit, not silently re-mapped.
.LEGACY_SCHEMA_COLS <- c("topic", "author", "effect", "meta_analysis")

# rigor_category values produced by .rigor_category() (00_utils.R). No shared
# constant exists for these, so the reporting layer pins the level set here
# and the verbose validation flags any value outside it.
.RIGOR_CATEGORY_LEVELS <- c(
  "clean_effect_supported", "clean_no_effect_supported",
  "inconclusive_clean_evidence", "clean_evidence_disfavored"
)

.STRATUM_ESTIMAND_COLS <- c(
  "scheme", "stratum", "weighting",
  "n_outcomes", "n_source_articles", "n_main",
  "n_exclusion_sensitivity", "n_claimed_effects",
  "median_log10BF_rigor", "q25_log10BF_rigor", "q75_log10BF_rigor",
  "prop_rigor_moderate", "prop_rigor_strong",
  "prop_rigor_effect_direction", "prop_rigor_no_effect_direction",
  "median_rigor_margin",
  "median_log10BF_rigor_effect", "median_log10BF_rigor_no_effect",
  "prop_rigor_effect_branch_moderate", "prop_rigor_no_effect_branch_moderate",
  "median_mu_RE", "median_mu_BC", "median_attenuation_pct",
  "prop_shrink50", "prop_sign_flip", "prop_bc_ci_includes_zero",
  "median_log10BF_effect", "prop_effect_inconclusive",
  "prop_effect_moderate_positive", "prop_effect_moderate_null",
  "median_log10BF_bias", "prop_bias_moderate",
  "median_log10BF_het", "prop_het_moderate",
  "median_log10BF_no_bias",
  "prop_claimed_shrink50", "prop_claimed_inconclusive_effect",
  "prop_claimed_rigor_moderate", "prop_claimed_rigor_no_effect_direction"
)

.ARTICLE_BALANCED_COLS <- c(
  "scheme", "stratum", "weighting",
  "n_source_articles", "n_outcomes",
  "article_balanced_mean_log10BF_rigor",
  "article_balanced_median_log10BF_rigor",
  "mean_source_prop_rigor_effect_direction",
  "mean_source_prop_rigor_no_effect_direction",
  "mean_source_prop_rigor_moderate",
  "mean_source_prop_shrink50",
  "mean_source_prop_effect_inconclusive",
  "mean_source_prop_bias_moderate"
)

.CORPUS_ESTIMAND_COLS <- c(
  "estimand", "weighting", "subset", "numerator", "denominator",
  "proportion", "note"
)

# Long format (one row per stratum x component) so visual scripts can
# consume it directly. Components: effect / heterogeneity / bias / no_bias.
.COMPONENT_EVIDENCE_COLS <- c(
  "stratum", "component", "median_log10BF",
  "prop_moderate_positive", "prop_inconclusive", "prop_moderate_negative",
  "n_available"
)


# ==============================================================================
# Small numeric / formatting helpers (file-scope, define-only)
# ==============================================================================

# Inf-preserving "BF is available" test: TRUE for any non-NA / non-NaN value
# including +Inf and -Inf. Use this (NOT is.finite) for log10 BF denominators
# -- the sidecars keep genuine Inf as "overwhelming evidence" and it must
# count toward the denominator. Reserve is.finite() for mu/tau/CI endpoints.
.bf_available <- function(x) !is.na(x)

# Vectorized safe proportion: NA when the denominator is not strictly > 0.
.safe_prop <- function(num, denom) {
  denom <- as.numeric(denom)
  ifelse(!is.na(denom) & denom > 0, num / denom, NA_real_)
}

# Median / quantile that return NA (not a warning) on an all-missing input
# and keep Inf as a meaningful value.
.med <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0L) NA_real_ else stats::median(x)
}
.qtl <- function(x, p) {
  x <- x[!is.na(x)]
  if (length(x) == 0L) return(NA_real_)
  suppressWarnings(as.numeric(stats::quantile(x, p, names = FALSE)))
}

# Element-wise Bayes-factor equality robust to NA / +-Inf (mirrors eq_num in
# 40_batch_fit.R): both NA -> TRUE ("not applicable"); one NA -> FALSE;
# matched +-Inf same sign -> TRUE; exactly one Inf -> FALSE; else |a-b|<=tol.
.bf_equal <- function(a, b, tol = 1e-6) {
  mapply(function(x, y) {
    if (is.na(x) && is.na(y)) return(TRUE)
    if (is.na(x) || is.na(y)) return(FALSE)
    if (is.infinite(x) || is.infinite(y))
      return(is.infinite(x) && is.infinite(y) && sign(x) == sign(y))
    abs(x - y) <= tol
  }, a, b)
}

# Inf-safe rigor margin from the two branch log10 BFs (reporting companion to
# the raw sidecar rigor_margin = abs(branch diff), which is NA for same-sign
# infinities). Rules: both infinite & same sign -> 0; both infinite &
# opposite sign -> Inf; exactly one infinite -> Inf; both finite ->
# abs(a - b); either branch missing -> NA. Vectorized.
.rigor_margin_safe <- function(a, b) {
  mapply(function(x, y) {
    if (is.na(x) || is.na(y)) return(NA_real_)
    xi <- is.infinite(x); yi <- is.infinite(y)
    if (xi && yi) return(if (sign(x) == sign(y)) 0 else Inf)
    if (xi || yi) return(Inf)
    abs(x - y)
  }, a, b, USE.NAMES = FALSE)
}

# Directional evidence category for one signed log10 BF axis. Positive ->
# evidence FOR the modeled component (effect present / heterogeneity present /
# bias present / no-bias), negative -> evidence FOR its complement. Inf / -Inf
# fall in the strong bins; only NA / NaN -> NA. Thresholds from
# .EVIDENCE_THRESHOLDS (00_utils.R).
.evidence_category <- function(x) {
  th <- .EVIDENCE_THRESHOLDS
  ifelse(is.na(x), NA_character_,
  ifelse(abs(x) <= th$inconclusive, "inconclusive",
  ifelse(x >  th$strong,        "strong_positive",
  ifelse(x >  th$moderate,      "moderate_positive",
  ifelse(x <  th$strong_null,   "strong_negative",
  ifelse(x <  th$moderate_null, "moderate_negative",
         "inconclusive"))))))
}

# Render a log10 Bayes factor for LaTeX. NA -> "---", +Inf -> $\infty$,
# -Inf -> $-\infty$, finite -> fixed decimals. CSV outputs keep numeric Inf
# as-is; this only governs TeX. (No shared .fmt_bf exists in 00_utils.R.)
.fmt_bf <- function(x, digits = 2L) {
  out <- rep("---", length(x))
  out[!is.na(x) & is.infinite(x) & x > 0] <- "$\\infty$"
  out[!is.na(x) & is.infinite(x) & x < 0] <- "$-\\infty$"
  fin <- !is.na(x) & is.finite(x)
  out[fin] <- formatC(x[fin], format = "f", digits = digits)
  out
}

# Integer-as-string for TeX; NA -> "".
.fmt_int <- function(x) ifelse(is.na(x), "", as.character(as.integer(x)))


# ==============================================================================
# Loader: v4 per-stratum sidecars -> outcome registry
# ==============================================================================
# Discovers every output/<stratum>/<stratum>_robma_summary.csv under `root`,
# excluding generated reporting directories (overview / _scratch / the chosen
# output_dir). Validates each sidecar carries the required v4 columns (fails
# loudly on an old-schema sidecar instead of silently remapping legacy
# columns), optionally joins the per-stratum zplot diagnostics, and returns
# the outcome-level registry. The returned frame has attr "zplot_join" with
# the join bookkeeping for the validation report.
#
# 60 is strictly DOWNSTREAM of the acceptance contract gate. It checks v4
# column presence so it cannot silently consume a pre-v4 sidecar, but it does
# NOT re-run the full contract and it never repairs/remaps a sidecar. The
# trust gate is sidecar_acceptance(stratum=...) / sidecar_acceptance_all()
# in 40_batch_fit.R; run that (all checks PASS) before build_estimand_tables().
.load_v4_outcome_registry <- function(root = "output", stratum = NULL,
                                       include_zplot_diagnostics = TRUE,
                                       exclude_dirs = character(0),
                                       verbose = TRUE) {
  vmsg <- function(...) if (verbose) message(...)

  if (!dir.exists(root))
    stop(sprintf("Root directory does not exist: %s", root))

  norm <- function(p) tryCatch(
    normalizePath(p, winslash = "/", mustWork = FALSE),
    error = function(e) p)
  excl_norm <- tolower(vapply(c(exclude_dirs), norm, character(1)))

  all_csv <- list.files(root, pattern = "_robma_summary\\.csv$",
                        recursive = TRUE, full.names = TRUE)
  # Never read backups / pre-v4 archives or generated reporting dirs.
  all_csv <- all_csv[!grepl("(\\.bak|pre_v4)", all_csv)]
  keep <- vapply(all_csv, function(p) {
    parent      <- dirname(p)
    parent_base <- tolower(basename(parent))
    if (parent_base %in% c("overview", "_scratch", "reports", "tables"))
      return(FALSE)
    pn <- tolower(norm(parent))
    !any(nzchar(excl_norm) & (pn == excl_norm |
                              startsWith(pn, paste0(excl_norm, "/"))))
  }, logical(1))
  sidecars <- all_csv[keep]

  if (!is.null(stratum)) {
    want <- norm_slug(stratum)
    sidecars <- sidecars[tolower(basename(dirname(sidecars))) == want]
    if (length(sidecars) == 0L)
      stop(sprintf("No v4 sidecar found for stratum '%s' under %s/.",
                   stratum, root))
  }
  if (length(sidecars) == 0L)
    stop(sprintf(paste0("No per-stratum v4 sidecars found under %s/. ",
                        "Expected %s/<stratum>/<stratum>_robma_summary.csv ",
                        "(run batch_fit() then the contract gate ",
                        "sidecar_acceptance_all() in 40_batch_fit.R first)."),
                 root, root))

  sidecars <- sort(sidecars)
  vmsg(sprintf("Discovered %d v4 sidecar(s):", length(sidecars)))
  for (f in sidecars) vmsg(sprintf("  - %s", f))

  read_one <- function(path) {
    df <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
    miss   <- setdiff(.REQUIRED_V4_COLS, names(df))
    legacy <- intersect(.LEGACY_SCHEMA_COLS, names(df))
    if (length(miss) > 0L) {
      if (length(legacy) > 0L) {
        stop(sprintf(paste0(
          "Old-schema sidecar detected: %s\n",
          "  Legacy columns present: %s\n",
          "  Missing required v4 columns: %s\n",
          "  This is a pre-v4 (topic/author/effect) sidecar. Refit with ",
          "40_batch_fit.R / backfill_sidecars(), then run the contract ",
          "gate sidecar_acceptance_all() (40_batch_fit.R) before ",
          "build_estimand_tables(); 60 never remaps or repairs legacy ",
          "sidecars."),
          path, paste(legacy, collapse = ", "),
          paste(miss, collapse = ", ")), call. = FALSE)
      }
      stop(sprintf(paste0(
        "Malformed sidecar (missing required v4 columns): %s\n  Missing: %s",
        "\n  Run sidecar_acceptance_all() (40_batch_fit.R) to gate sidecars ",
        "before build_estimand_tables(); 60 does not repair sidecars."),
        path, paste(miss, collapse = ", ")), call. = FALSE)
    }
    if (length(legacy) > 0L)
      warning(sprintf(
        "Sidecar %s carries harmless extra legacy column(s) %s; ignored.",
        path, paste(legacy, collapse = ", ")), call. = FALSE)
    df
  }

  frames <- lapply(sidecars, read_one)
  # Carry exactly the curated registry columns (every name is in
  # .SIDECAR_V4_COLS); rbind across strata is then trivially aligned.
  reg <- do.call(rbind, lapply(frames, function(df)
    df[, .REGISTRY_SIDECAR_COLS, drop = FALSE]))
  reg <- .coerce_registry_types(reg)
  rownames(reg) <- NULL

  if (nrow(reg) == 0L) stop("Sidecars were found but contained no rows.")

  # ---- Optional zplot-diagnostics join ------------------------------------
  for (cl in .REGISTRY_ZPLOT_COLS) reg[[cl]] <- NA_real_
  reg$zplot_diag_joined <- FALSE
  zjoin <- list(included = isTRUE(include_zplot_diagnostics),
                n_total = nrow(reg), n_joined = 0L,
                missing_strata = character(0), key = NA_character_)

  if (isTRUE(include_zplot_diagnostics)) {
    strata_dirs <- unique(dirname(sidecars))
    for (sd in strata_dirs) {
      s_slug  <- basename(sd)
      zp_path <- file.path(sd, sprintf("%s_zplot_diagnostics.csv", s_slug))
      in_str  <- reg$stratum == s_slug | tolower(reg$path_stratum) == s_slug
      if (!file.exists(zp_path)) {
        zjoin$missing_strata <- c(zjoin$missing_strata, s_slug)
        next
      }
      zp <- tryCatch(read.csv(zp_path, stringsAsFactors = FALSE,
                              check.names = FALSE),
                      error = function(e) NULL)
      if (is.null(zp) || nrow(zp) == 0L) {
        zjoin$missing_strata <- c(zjoin$missing_strata, s_slug)
        next
      }
      # Strongest reliable key: analysis_id if present in both, else dataset_id.
      key <- if (all(c("analysis_id") %in% names(zp)) &&
                 !all(is.na(zp$analysis_id))) "analysis_id" else "dataset_id"
      zjoin$key <- key
      idx <- match(reg[[key]][in_str], zp[[key]])
      for (cl in .REGISTRY_ZPLOT_COLS) {
        if (cl %in% names(zp))
          reg[[cl]][in_str] <- suppressWarnings(as.numeric(zp[[cl]][idx]))
      }
      reg$zplot_diag_joined[in_str] <- !is.na(idx)
    }
    zjoin$n_joined <- sum(reg$zplot_diag_joined)
    if (length(zjoin$missing_strata) > 0L)
      message(sprintf(
        "zplot diagnostics absent for stratum(s): %s (columns set NA).",
        paste(zjoin$missing_strata, collapse = ", ")))
  }

  reg <- reg[order(reg$stratum, reg$source_key, reg$outcome_slug), ,
             drop = FALSE]
  rownames(reg) <- NULL
  attr(reg, "zplot_join")    <- zjoin
  attr(reg, "n_sidecars")    <- length(sidecars)
  reg
}


# Coerce sidecar string columns to their reporting types. read.csv() already
# parses numeric columns and preserves Inf / -Inf; this is the explicit,
# Inf-preserving belt-and-braces pass (all-"NA" columns parse as logical and
# would otherwise stay logical).
.coerce_registry_types <- function(df) {
  for (cl in intersect(.REGISTRY_NUMERIC_COLS, names(df)))
    df[[cl]] <- suppressWarnings(as.numeric(df[[cl]]))
  for (cl in intersect(.REGISTRY_LOGICAL_COLS, names(df)))
    df[[cl]] <- as.logical(df[[cl]])
  chr <- setdiff(names(df),
                 c(.REGISTRY_NUMERIC_COLS, .REGISTRY_LOGICAL_COLS))
  for (cl in chr) df[[cl]] <- as.character(df[[cl]])
  df
}


# ==============================================================================
# Augment: regenerate derived reporting columns from sidecar primitives
# ==============================================================================
# The sidecar is a lean primitive table; every reporting convenience is
# derived here (never required to pre-exist in the sidecar). Effect-size
# attenuation flags come from the shared single-row derivers in 00_utils.R so
# the formulas cannot drift from the fitting layer.
.augment_registry_for_reporting <- function(registry) {
  th <- .EVIDENCE_THRESHOLDS
  d  <- registry

  d$abs_mu_RE       <- abs(d$mu_RE)
  d$abs_mu_BC       <- abs(d$mu_BC)
  d$attenuation_abs <- d$abs_mu_RE - d$abs_mu_BC
  d$attenuation_pct <- .attenuation_pct(d$mu_RE, d$mu_BC)
  d$shrink50            <- .shrink50(d$mu_RE, d$mu_BC)
  d$sign_flip           <- .sign_flip(d$mu_RE, d$mu_BC)
  d$bc_ci_includes_zero <- .bc_ci_includes_zero(d$mu_BC_lCI, d$mu_BC_uCI)

  # A "claimed effect" is a finite, at-least-small baseline RE estimate with a
  # finite bias-corrected counterpart (the bias-shrinkage anchor).
  d$claimed_effect <- is.finite(d$mu_RE) & is.finite(d$mu_BC) &
                       abs(d$mu_RE) >= th$claimed_mu_threshold

  # Inf-safe reporting margin (raw sidecar rigor_margin kept untouched for
  # audit; this is what summaries / the compact registry use so a
  # (-Inf,-Inf) row is 0, not a missing value).
  d$rigor_margin_reporting <- .rigor_margin_safe(d$log10BF_rigor_effect,
                                                 d$log10BF_rigor_no_effect)

  d$effect_evidence_category  <- .evidence_category(d$log10BF_effect)
  d$het_evidence_category     <- .evidence_category(d$log10BF_het)
  d$bias_evidence_category    <- .evidence_category(d$log10BF_bias)
  d$no_bias_evidence_category <- .evidence_category(d$log10BF_no_bias)

  # Stored rigor_direction stays raw (effect / no_effect); this is the
  # presentation form only.
  d$rigor_direction_display <- ifelse(
    is.na(d$rigor_direction), NA_character_,
    ifelse(d$rigor_direction == "effect", "Effect",
    ifelse(d$rigor_direction == "no_effect", "No effect",
           d$rigor_direction)))

  # Article-balancing weight w_k = 1 / m_{a(k),s} : the inverse of the number
  # of outcomes the source article contributes within its stratum (README
  # default). source_key is the article-balancing unit.
  grp <- paste(d$stratum, d$source_key, sep = "\r")
  m   <- ave(rep(1L, nrow(d)), grp, FUN = length)
  d$n_outcomes_in_source <- as.integer(m)
  d$article_weight       <- 1 / m
  d
}


# ==============================================================================
# Stratum-level estimands (outcome-weighted)
# ==============================================================================
# Denominator conventions (kept consistent across the file):
#   * log10 BF proportions    : non-missing BF rows; genuine Inf is retained
#                               and counts toward numerator and denominator.
#   * rigor-direction props   : rows with rigor_direction in
#                               .RIGOR_DIRECTION_LEVELS.
#   * effect-change props     : rows where the single-row deriver is non-NA.
#   * claimed-effect cond.     : conditioned on the per-stratum claimed set
#                               (finite mu_RE, finite mu_BC, |mu_RE| >=
#                               threshold, non-missing log10BF_effect).
.build_stratum_estimand_row <- function(df, stratum_label) {
  th <- .EVIDENCE_THRESHOLDS

  lbf <- function(col) df[[col]][.bf_available(df[[col]])]
  R  <- lbf("log10BF_rigor")
  Re <- lbf("log10BF_rigor_effect")
  Rn <- lbf("log10BF_rigor_no_effect")
  Le <- lbf("log10BF_effect")
  Lb <- lbf("log10BF_bias")
  Lh <- lbf("log10BF_het")
  Ln <- lbf("log10BF_no_bias")

  dir_valid <- df$rigor_direction %in% .RIGOR_DIRECTION_LEVELS
  rd <- df$rigor_direction[dir_valid]

  sh <- df$shrink50[!is.na(df$shrink50)]
  sf <- df$sign_flip[!is.na(df$sign_flip)]
  cz <- df$bc_ci_includes_zero[!is.na(df$bc_ci_includes_zero)]

  # Claimed-effect set (the bias-shrinkage / over-claim anchor).
  claimed <- df$claimed_effect %in% TRUE & .bf_available(df$log10BF_effect)
  cdf <- df[claimed, , drop = FALSE]
  nclaim <- nrow(cdf)
  c_rig_ok  <- .bf_available(cdf$log10BF_rigor)
  c_dir_ok  <- cdf$rigor_direction %in% .RIGOR_DIRECTION_LEVELS

  scheme_val <- unique(df$scheme)
  scheme_val <- if (length(scheme_val) == 1L) scheme_val else "mixed"

  data.frame(
    scheme = scheme_val, stratum = stratum_label,
    weighting = "outcome_weighted",

    n_outcomes              = nrow(df),
    # Count (stratum, source_key) units so the Overall row cannot collapse
    # same author-year keys that appear in different strata (this matches the
    # article-balanced denominator). Per-stratum rows are unchanged because
    # stratum is constant within them.
    n_source_articles       = length(unique(paste(df$stratum, df$source_key,
                                                  sep = "\r"))),
    n_main                  = sum(df$analysis_variant == "main"),
    n_exclusion_sensitivity = sum(df$analysis_variant ==
                                  "exclusion_sensitivity"),
    n_claimed_effects       = nclaim,

    median_log10BF_rigor = .med(R),
    q25_log10BF_rigor    = .qtl(R, 0.25),
    q75_log10BF_rigor    = .qtl(R, 0.75),
    prop_rigor_moderate  = .safe_prop(sum(R > th$moderate), length(R)),
    prop_rigor_strong    = .safe_prop(sum(R > th$strong),   length(R)),
    prop_rigor_effect_direction    = .safe_prop(sum(rd == "effect"),
                                                length(rd)),
    prop_rigor_no_effect_direction = .safe_prop(sum(rd == "no_effect"),
                                                length(rd)),
    median_rigor_margin  = .med(df$rigor_margin_reporting),

    median_log10BF_rigor_effect    = .med(Re),
    median_log10BF_rigor_no_effect = .med(Rn),
    prop_rigor_effect_branch_moderate    = .safe_prop(
      sum(Re > th$moderate), length(Re)),
    prop_rigor_no_effect_branch_moderate = .safe_prop(
      sum(Rn > th$moderate), length(Rn)),

    median_mu_RE           = .med(df$mu_RE),
    median_mu_BC           = .med(df$mu_BC),
    median_attenuation_pct = .med(df$attenuation_pct),
    prop_shrink50            = .safe_prop(sum(sh %in% TRUE), length(sh)),
    prop_sign_flip           = .safe_prop(sum(sf %in% TRUE), length(sf)),
    prop_bc_ci_includes_zero = .safe_prop(sum(cz %in% TRUE), length(cz)),

    median_log10BF_effect = .med(Le),
    prop_effect_inconclusive      = .safe_prop(
      sum(abs(Le) <= th$inconclusive), length(Le)),
    prop_effect_moderate_positive = .safe_prop(
      sum(Le > th$moderate),       length(Le)),
    prop_effect_moderate_null     = .safe_prop(
      sum(Le < th$moderate_null),  length(Le)),
    median_log10BF_bias = .med(Lb),
    prop_bias_moderate  = .safe_prop(sum(Lb > th$moderate), length(Lb)),
    median_log10BF_het  = .med(Lh),
    prop_het_moderate   = .safe_prop(sum(Lh > th$moderate), length(Lh)),
    median_log10BF_no_bias = .med(Ln),

    prop_claimed_shrink50 = .safe_prop(
      sum(cdf$shrink50 %in% TRUE), nclaim),
    prop_claimed_inconclusive_effect = .safe_prop(
      sum(abs(cdf$log10BF_effect) <= th$inconclusive), nclaim),
    prop_claimed_rigor_moderate = .safe_prop(
      sum(c_rig_ok & cdf$log10BF_rigor > th$moderate), sum(c_rig_ok)),
    prop_claimed_rigor_no_effect_direction = .safe_prop(
      sum(c_dir_ok & cdf$rigor_direction == "no_effect"), sum(c_dir_ok)),

    stringsAsFactors = FALSE
  )[, .STRATUM_ESTIMAND_COLS, drop = FALSE]
}


# ==============================================================================
# Article-balanced estimands
# ==============================================================================
# Two-stage so prolific source meta-analyses do not dominate: (1) collapse to
# one summary per source article (within its stratum); (2) average those
# source-level summaries with EQUAL weight per source article. This realizes
# the README article-balanced weight w_k = 1/m_{a(k),s}. Denominator
# conventions are documented in the per-stratum builder and the table notes.
.source_level_summaries <- function(df) {
  th  <- .EVIDENCE_THRESHOLDS
  key <- paste(df$stratum, df$source_key, sep = "\r")
  parts <- split(seq_len(nrow(df)), key)

  rows <- lapply(parts, function(ix) {
    s  <- df[ix, , drop = FALSE]
    R  <- s$log10BF_rigor[.bf_available(s$log10BF_rigor)]
    Le <- s$log10BF_effect[.bf_available(s$log10BF_effect)]
    Lb <- s$log10BF_bias[.bf_available(s$log10BF_bias)]
    dv <- s$rigor_direction %in% .RIGOR_DIRECTION_LEVELS
    rd <- s$rigor_direction[dv]
    sh <- s$shrink50[!is.na(s$shrink50)]
    data.frame(
      stratum    = s$stratum[1],
      source_key = s$source_key[1],
      n_outcomes_in_source = nrow(s),
      mean_log10BF_rigor   = if (length(R)) mean(R) else NA_real_,
      median_log10BF_rigor = .med(R),
      prop_rigor_effect_direction    = .safe_prop(sum(rd == "effect"),
                                                  length(rd)),
      prop_rigor_no_effect_direction = .safe_prop(sum(rd == "no_effect"),
                                                  length(rd)),
      prop_rigor_moderate     = .safe_prop(sum(R > th$moderate), length(R)),
      prop_shrink50           = .safe_prop(sum(sh %in% TRUE), length(sh)),
      prop_effect_inconclusive = .safe_prop(
        sum(abs(Le) <= th$inconclusive), length(Le)),
      prop_bias_moderate      = .safe_prop(sum(Lb > th$moderate),
                                           length(Lb)),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

.build_article_balanced_estimands <- function(df, stratum_label) {
  src <- .source_level_summaries(df)
  scheme_val <- unique(df$scheme)
  scheme_val <- if (length(scheme_val) == 1L) scheme_val else "mixed"

  data.frame(
    scheme = scheme_val, stratum = stratum_label,
    weighting = "article_balanced",
    n_source_articles = nrow(src),
    n_outcomes        = sum(src$n_outcomes_in_source),
    article_balanced_mean_log10BF_rigor   = .med0(mean,
      src$mean_log10BF_rigor),
    article_balanced_median_log10BF_rigor = .med(src$median_log10BF_rigor),
    mean_source_prop_rigor_effect_direction = .med0(mean,
      src$prop_rigor_effect_direction),
    mean_source_prop_rigor_no_effect_direction = .med0(mean,
      src$prop_rigor_no_effect_direction),
    mean_source_prop_rigor_moderate = .med0(mean, src$prop_rigor_moderate),
    mean_source_prop_shrink50       = .med0(mean, src$prop_shrink50),
    mean_source_prop_effect_inconclusive = .med0(mean,
      src$prop_effect_inconclusive),
    mean_source_prop_bias_moderate  = .med0(mean, src$prop_bias_moderate),
    stringsAsFactors = FALSE
  )[, .ARTICLE_BALANCED_COLS, drop = FALSE]
}

# Apply an aggregator over the non-missing values only (NA if none); keeps
# Inf as a meaningful source-level value.
.med0 <- function(fun, x) {
  x <- x[!is.na(x)]
  if (length(x) == 0L) NA_real_ else fun(x)
}


# ==============================================================================
# Corpus / headline estimands (numerator/denominator audit table)
# ==============================================================================
# Rigor-first numerator/denominator claims for the manuscript. Outcome-weighted
# rows carry integer numerator/denominator; article-balanced rows report the
# source-balanced proportion over n_source_articles (numerator left NA, since
# it is a mean of within-source proportions, not a raw count).
.build_corpus_estimands <- function(augmented) {
  th  <- .EVIDENCE_THRESHOLDS
  d   <- augmented

  R   <- d$log10BF_rigor
  Re  <- d$log10BF_rigor_effect
  Rn  <- d$log10BF_rigor_no_effect
  Le  <- d$log10BF_effect
  Lb  <- d$log10BF_bias
  Lh  <- d$log10BF_het
  dv  <- d$rigor_direction %in% .RIGOR_DIRECTION_LEVELS

  ow <- function(estimand, subset, num, denom, note)
    data.frame(estimand = estimand, weighting = "outcome_weighted",
               subset = subset, numerator = as.integer(num),
               denominator = as.integer(denom),
               proportion = .safe_prop(num, denom), note = note,
               stringsAsFactors = FALSE)

  rigor_av <- .bf_available(R)
  claimed  <- d$claimed_effect %in% TRUE & .bf_available(Le)
  ncl      <- sum(claimed)
  cl_dir   <- claimed & dv

  rows <- list(
    ow("Outcomes with at least moderate selected rigor",
       "non-missing log10BF_rigor",
       sum(R[rigor_av] > th$moderate), sum(rigor_av),
       "log10BF_rigor > 0.5 (selected statistic; Inf retained)"),
    ow("Outcomes with strong selected rigor",
       "non-missing log10BF_rigor",
       sum(R[rigor_av] > th$strong), sum(rigor_av),
       "log10BF_rigor > 1.0"),
    ow("Selected rigor favors effect",
       "valid rigor_direction",
       sum(d$rigor_direction[dv] == "effect"), sum(dv),
       "rigor_direction == effect (ties resolve to effect)"),
    ow("Selected rigor favors no effect",
       "valid rigor_direction",
       sum(d$rigor_direction[dv] == "no_effect"), sum(dv),
       "rigor_direction == no_effect"),
    ow("At least moderate rigor favoring no effect",
       "valid rigor_direction & non-missing log10BF_rigor",
       sum(dv & rigor_av & d$rigor_direction == "no_effect" &
           R > th$moderate),
       sum(dv & rigor_av),
       "no_effect direction AND log10BF_rigor > 0.5"),
    ow("Baseline claimed-effect outcomes",
       "finite mu_RE, mu_BC & non-missing log10BF_effect",
       ncl,
       sum(is.finite(d$mu_RE) & is.finite(d$mu_BC) & .bf_available(Le)),
       "|mu_RE| >= 0.2"),
    ow("Claimed-effect outcomes with >=50% shrinkage",
       "claimed-effect outcomes",
       sum(d$shrink50[claimed] %in% TRUE), ncl,
       "|mu_BC| <= 0.5 |mu_RE|"),
    ow("Claimed-effect outcomes still effect-inconclusive",
       "claimed-effect outcomes",
       sum(abs(Le[claimed]) <= th$inconclusive), ncl,
       "|log10BF_effect| <= 0.5"),
    ow("Claimed-effect outcomes whose selected rigor favors no effect",
       "claimed-effect outcomes with valid rigor_direction",
       sum(d$rigor_direction[cl_dir] == "no_effect"), sum(cl_dir),
       "rigor_direction == no_effect within claimed-effect set"),
    ow("Outcomes with at least moderate bias evidence",
       "non-missing log10BF_bias",
       sum(Lb[.bf_available(Lb)] > th$moderate), sum(.bf_available(Lb)),
       "log10BF_bias > 0.5 (bias/small-study/selection mechanisms)"),
    ow("Outcomes with at least moderate heterogeneity evidence",
       "non-missing log10BF_het",
       sum(Lh[.bf_available(Lh)] > th$moderate), sum(.bf_available(Lh)),
       "log10BF_het > 0.5")
  )

  # Article-balanced companions for the three rigor headlines: source-balanced
  # proportions over all source articles in the corpus.
  ab <- .build_article_balanced_estimands(d, "Overall")
  abrow <- function(estimand, subset, prop, note)
    data.frame(estimand = estimand, weighting = "article_balanced",
               subset = subset, numerator = NA_integer_,
               denominator = as.integer(ab$n_source_articles),
               proportion = prop, note = note, stringsAsFactors = FALSE)

  rows <- c(rows, list(
    abrow("Source-balanced selected rigor favors effect",
          "mean over source articles",
          ab$mean_source_prop_rigor_effect_direction,
          "each source article weighted 1/m within its stratum"),
    abrow("Source-balanced selected rigor favors no effect",
          "mean over source articles",
          ab$mean_source_prop_rigor_no_effect_direction,
          "each source article weighted 1/m within its stratum"),
    abrow("Source-balanced at least moderate selected rigor",
          "mean over source articles",
          ab$mean_source_prop_rigor_moderate,
          "mean of within-source P(log10BF_rigor > 0.5)")
  ))

  out <- do.call(rbind, rows)
  out[, .CORPUS_ESTIMAND_COLS, drop = FALSE]
}


# ==============================================================================
# Rigor-category and rigor-direction summaries
# ==============================================================================
.build_rigor_category_summary <- function(registry) {
  build <- function(df, label) {
    cat <- factor(df$rigor_category, levels = .RIGOR_CATEGORY_LEVELS)
    n   <- nrow(df)
    tab <- as.integer(table(cat))
    names(tab) <- .RIGOR_CATEGORY_LEVELS
    n_unc <- sum(is.na(df$rigor_category) |
                 !(df$rigor_category %in% .RIGOR_CATEGORY_LEVELS))
    row <- data.frame(stratum = label, n_outcomes = n,
                      stringsAsFactors = FALSE)
    for (lv in .RIGOR_CATEGORY_LEVELS) {
      row[[paste0("n_", lv)]]    <- tab[[lv]]
      row[[paste0("prop_", lv)]] <- .safe_prop(tab[[lv]], n)
    }
    row$n_uncategorized    <- n_unc
    row$prop_uncategorized <- .safe_prop(n_unc, n)
    row
  }
  per <- lapply(split(registry, registry$stratum), function(s)
    build(s, s$stratum[1]))
  rbind(do.call(rbind, per), build(registry, "Overall"))
}

.build_rigor_direction_summary <- function(registry) {
  build <- function(df, label) {
    dv <- df$rigor_direction %in% .RIGOR_DIRECTION_LEVELS
    ne <- sum(df$rigor_direction[dv] == "effect")
    nn <- sum(df$rigor_direction[dv] == "no_effect")
    data.frame(
      stratum = label, n_outcomes = nrow(df),
      n_with_direction = sum(dv),
      n_effect = ne, n_no_effect = nn,
      prop_effect    = .safe_prop(ne, sum(dv)),
      prop_no_effect = .safe_prop(nn, sum(dv)),
      n_missing_direction = sum(!dv),
      stringsAsFactors = FALSE)
  }
  per <- lapply(split(registry, registry$stratum), function(s)
    build(s, s$stratum[1]))
  rbind(do.call(rbind, per), build(registry, "Overall"))
}

# Secondary component-evidence roll-up in LONG format (one row per
# stratum x component) so visual scripts can consume it directly. NOT a
# substitute for the rigor-first summaries. n_available counts non-missing
# log10 BF rows (Inf retained).
.build_component_evidence_summary <- function(registry) {
  th <- .EVIDENCE_THRESHOLDS
  comp_col <- c(effect = "log10BF_effect", heterogeneity = "log10BF_het",
                bias = "log10BF_bias", no_bias = "log10BF_no_bias")
  build <- function(df, label) {
    do.call(rbind, lapply(names(comp_col), function(cn) {
      x <- df[[comp_col[[cn]]]]
      x <- x[.bf_available(x)]
      data.frame(
        stratum = label, component = cn,
        median_log10BF = .med(x),
        prop_moderate_positive = .safe_prop(sum(x > th$moderate),
                                            length(x)),
        prop_inconclusive = .safe_prop(sum(abs(x) <= th$inconclusive),
                                       length(x)),
        prop_moderate_negative = .safe_prop(sum(x < th$moderate_null),
                                            length(x)),
        n_available = length(x), stringsAsFactors = FALSE)
    }))
  }
  per <- lapply(split(registry, registry$stratum), function(s)
    build(s, s$stratum[1]))
  out <- rbind(do.call(rbind, per), build(registry, "Overall"))
  out[, .COMPONENT_EVIDENCE_COLS, drop = FALSE]
}


# ==============================================================================
# TeX renderers
# ==============================================================================
# Shared note fragments. Rigor is the headline; the note set keeps the
# selected-statistic, omega0, and broad-bias caveats explicit.
.TEX_RIGOR_NOTE <- paste(
  "\\textit{Note.} $\\log_{10}\\mathrm{BF}_{R}$ is the \\emph{selected}",
  "rigor statistic $\\max(\\log_{10}\\mathrm{BF}_{R}^{+},",
  "\\log_{10}\\mathrm{BF}_{R}^{0})$ with $\\log_{10}\\mathrm{BF}_{R}^{+}=",
  "\\log_{10}\\mathrm{BF}_{\\mu^{+}\\omega_{0}}$ (clean evidence for effect)",
  "and $\\log_{10}\\mathrm{BF}_{R}^{0}=\\log_{10}\\mathrm{BF}_{\\mu_{0}",
  "\\omega_{0}}$ (clean evidence for no effect); it is not the Bayes factor",
  "for a single fixed model family. $\\omega_{0}$ denotes no modeled",
  "selection / small-study component and does not prove the literature is",
  "bias-free. ``Bias'' refers to bias / small-study / selection mechanisms,",
  "not publication bias alone. Percentages on a Bayes-factor axis use",
  "non-missing $\\log_{10}\\mathrm{BF}$ rows as the denominator; infinite",
  "values are retained as overwhelming evidence.")

.tex_header <- function(name, src_csv, extra = character(0)) {
  c("% =============================================================",
    sprintf("%% %s", name),
    "% Auto-generated by 60_estimand_tables.R - do not edit by hand.",
    sprintf("%% Source CSV: <output_dir>/%s", src_csv),
    sprintf("%% Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    extra,
    "% =============================================================")
}

# Escape a plain-ASCII note and convert >= / <= tokens to math.
.tex_note <- function(x) {
  x <- .latex_escape(x)
  x <- gsub(">=", "$\\geq$", x, fixed = TRUE)
  gsub("<=", "$\\leq$", x, fixed = TRUE)
}

# ---- outcome_registry_table.tex ---------------------------------------------
# Supplement longtable, rigor-forward: stratum / source / year / outcome / k /
# variant / mu_RE / mu_BC / selected log10BF_rigor / direction / branch BFs /
# rigor_category. Sorted by descending selected rigor (most rigorous first).
.render_outcome_registry_tex <- function(registry, path) {
  r <- registry[order(-registry$log10BF_rigor, registry$stratum,
                       registry$source_key, registry$outcome_slug), ,
                 drop = FALSE]
  cat_short <- c(clean_effect_supported = "eff",
                 clean_no_effect_supported = "no-eff",
                 inconclusive_clean_evidence = "inconcl.",
                 clean_evidence_disfavored = "disfav.")
  body <- paste0(
    .latex_escape(format_stratum(r$stratum)), " & ",
    .latex_escape(r$source_article),          " & ",
    ifelse(is.na(r$source_year), "", as.character(r$source_year)), " & ",
    .latex_escape(gsub("_", " ", r$outcome_slug)), " & ",
    .fmt_int(r$n_studies), " & ",
    ifelse(r$analysis_variant == "exclusion_sensitivity", "excl", "main"),
    " & ",
    .fmt_num(r$mu_RE, 3), " & ",
    .fmt_num(r$mu_BC, 3), " & ",
    .fmt_bf(r$log10BF_rigor, 2), " & ",
    ifelse(is.na(r$rigor_direction_display), "---",
           r$rigor_direction_display), " & ",
    .fmt_bf(r$log10BF_rigor_effect, 2), " & ",
    .fmt_bf(r$log10BF_rigor_no_effect, 2), " & ",
    ifelse(r$rigor_category %in% names(cat_short),
           cat_short[r$rigor_category], "---"), " \\\\")

  header <- paste(
    "\\textbf{Stratum}", "\\textbf{Source}", "\\textbf{Yr}",
    "\\textbf{Outcome}", "\\textbf{$k$}", "\\textbf{Var.}",
    "\\textbf{$\\hat{\\mu}_{\\mathrm{RE}}$}",
    "\\textbf{$\\hat{\\mu}_{\\mathrm{BC}}$}",
    "\\textbf{$\\log_{10}\\mathrm{BF}_{R}$}",
    "\\textbf{Dir.}",
    "\\textbf{$\\log_{10}\\mathrm{BF}_{R}^{+}$}",
    "\\textbf{$\\log_{10}\\mathrm{BF}_{R}^{0}$}",
    "\\textbf{Cat.} \\\\", sep = " & ")
  col_spec <- "@{}l l c p{3.4cm} r c r r r c r r l@{}"

  tex <- c(
    .tex_header("outcome_registry_table.tex", "outcome_registry.csv",
      c("% Required packages: longtable, booktabs, array, pdflscape",
        sprintf("%% Rows: %d   Strata: %d", nrow(r),
                length(unique(r$stratum))))),
    "\\begin{landscape}", "\\begingroup", "\\scriptsize",
    "\\setlength{\\tabcolsep}{3.5pt}",
    "\\renewcommand{\\arraystretch}{1.05}",
    sprintf("\\begin{longtable}{%s}", col_spec),
    paste0("\\caption{Complete outcome registry: every analyzed ",
           "intervention--outcome dataset with baseline ($\\hat{\\mu}_",
           "{\\mathrm{RE}}$) and bias-corrected ($\\hat{\\mu}_{\\mathrm{BC}",
           "}$) effect estimates and the selected rigor evidence ",
           "($\\log_{10}\\mathrm{BF}_{R}$, its direction, and the two ",
           "pre-specified branch BFs). Sorted by descending selected ",
           "rigor.\\label{tab:outcome-registry}}\\\\"),
    "\\toprule", header, "\\midrule", "\\endfirsthead",
    "\\multicolumn{13}{l}{\\itshape Table~\\ref{tab:outcome-registry} (continued)}\\\\",
    "\\toprule", header, "\\midrule", "\\endhead",
    "\\midrule \\multicolumn{13}{r}{\\itshape Continued on next page}\\\\",
    "\\endfoot", "\\bottomrule",
    "\\multicolumn{13}{@{}p{\\linewidth}@{}}{\\scriptsize ",
    .TEX_RIGOR_NOTE, "}\\\\",
    "\\endlastfoot",
    body,
    "\\end{longtable}", "\\endgroup", "\\end{landscape}", "")
  writeLines(tex, path, useBytes = TRUE)
}

# ---- stratum_estimands_table.tex --------------------------------------------
# Compact manuscript table, rigor-forward.
.render_stratum_estimands_tex <- function(se, path) {
  se <- se[order(se$stratum == "Overall", se$stratum), , drop = FALSE]
  body <- paste0(
    .latex_escape(ifelse(se$stratum == "Overall", "Overall",
                         format_stratum(se$stratum))), " & ",
    se$n_outcomes, " & ", se$n_source_articles, " & ",
    .fmt_bf(se$median_log10BF_rigor, 2), " & ",
    paste0("[", .fmt_bf(se$q25_log10BF_rigor, 2), ",\\,",
           .fmt_bf(se$q75_log10BF_rigor, 2), "]"), " & ",
    .fmt_pct(se$prop_rigor_moderate), " & ",
    .fmt_pct(se$prop_rigor_effect_direction), " & ",
    .fmt_pct(se$prop_rigor_no_effect_direction), " & ",
    .fmt_num(se$median_attenuation_pct, 1), " & ",
    .fmt_pct(se$prop_shrink50), " & ",
    .fmt_pct(se$prop_bias_moderate), " \\\\")
  ov <- which(se$stratum == "Overall")
  if (length(ov)) body <- append(body, "\\midrule", after = ov[1] - 1L)

  header <- paste(
    "\\textbf{Stratum}", "\\textbf{$n$}", "\\textbf{$n_{\\mathrm{src}}$}",
    "\\textbf{med.\\ $\\log_{10}\\mathrm{BF}_{R}$}",
    "\\textbf{[Q1,\\,Q3]}",
    "\\textbf{\\% rig.\\ mod.}", "\\textbf{\\% dir.\\ eff.}",
    "\\textbf{\\% dir.\\ no-eff.}", "\\textbf{med.\\ atten.\\ \\%}",
    "\\textbf{\\% shrink50}", "\\textbf{\\% bias mod.} \\\\", sep = " & ")
  col_spec <- "@{}l r r r c r r r r r r@{}"

  tex <- c(
    .tex_header("stratum_estimands_table.tex", "stratum_estimands.csv",
                "% Required packages: booktabs, array"),
    "\\begingroup", "\\small", "\\setlength{\\tabcolsep}{4pt}",
    "\\renewcommand{\\arraystretch}{1.1}",
    sprintf("\\begin{tabular}{%s}", col_spec),
    "\\toprule", header, "\\midrule", body, "\\bottomrule",
    "\\end{tabular}",
    "\\par\\vspace{2pt}\\noindent\\begin{minipage}{\\linewidth}\\footnotesize",
    .TEX_RIGOR_NOTE,
    " Stratum estimands are outcome-weighted. \\end{minipage}",
    "\\endgroup", "")
  writeLines(tex, path, useBytes = TRUE)
}

# ---- article_balanced_estimands_table.tex -----------------------------------
.render_article_balanced_estimands_tex <- function(ab, path) {
  ab <- ab[order(ab$stratum == "Overall", ab$stratum), , drop = FALSE]
  body <- paste0(
    .latex_escape(ifelse(ab$stratum == "Overall", "Overall",
                         format_stratum(ab$stratum))), " & ",
    ab$n_source_articles, " & ", ab$n_outcomes, " & ",
    .fmt_bf(ab$article_balanced_mean_log10BF_rigor, 2), " & ",
    .fmt_bf(ab$article_balanced_median_log10BF_rigor, 2), " & ",
    .fmt_pct(ab$mean_source_prop_rigor_effect_direction), " & ",
    .fmt_pct(ab$mean_source_prop_rigor_no_effect_direction), " & ",
    .fmt_pct(ab$mean_source_prop_rigor_moderate), " & ",
    .fmt_pct(ab$mean_source_prop_shrink50), " \\\\")
  ov <- which(ab$stratum == "Overall")
  if (length(ov)) body <- append(body, "\\midrule", after = ov[1] - 1L)

  header <- paste(
    "\\textbf{Stratum}", "\\textbf{$n_{\\mathrm{src}}$}", "\\textbf{$n$}",
    "\\textbf{a.b.\\ mean $\\log_{10}\\mathrm{BF}_{R}$}",
    "\\textbf{a.b.\\ med.\\ $\\log_{10}\\mathrm{BF}_{R}$}",
    "\\textbf{\\% dir.\\ eff.}", "\\textbf{\\% dir.\\ no-eff.}",
    "\\textbf{\\% rig.\\ mod.}", "\\textbf{\\% shrink50} \\\\",
    sep = " & ")
  col_spec <- "@{}l r r r r r r r r@{}"

  tex <- c(
    .tex_header("article_balanced_estimands_table.tex",
                "article_balanced_estimands.csv",
                "% Required packages: booktabs, array"),
    "\\begingroup", "\\small", "\\setlength{\\tabcolsep}{4pt}",
    "\\renewcommand{\\arraystretch}{1.1}",
    sprintf("\\begin{tabular}{%s}", col_spec),
    "\\toprule", header, "\\midrule", body, "\\bottomrule",
    "\\end{tabular}",
    "\\par\\vspace{2pt}\\noindent\\begin{minipage}{\\linewidth}\\footnotesize",
    .TEX_RIGOR_NOTE,
    " Article-balanced (a.b.) summaries average source-level summaries with",
    " equal weight per source article ($w_k=1/m_{a(k),s}$), so prolific",
    " meta-analyses do not dominate. \\end{minipage}",
    "\\endgroup", "")
  writeLines(tex, path, useBytes = TRUE)
}

# ---- corpus_estimands_table.tex ---------------------------------------------
.render_corpus_estimands_tex <- function(ce, path) {
  nN <- ifelse(is.na(ce$numerator), "---",
               sprintf("%d / %d", ce$numerator, ce$denominator))
  body <- paste0(
    .tex_note(ce$estimand), " & ",
    gsub("_", " ", ce$weighting), " & ",
    nN, " & ", .fmt_pct(ce$proportion), " & ",
    .tex_note(ce$note), " \\\\")
  header <- paste(
    "\\textbf{Estimand}", "\\textbf{Weighting}", "\\textbf{$n/N$}",
    "\\textbf{\\%}", "\\textbf{Definition} \\\\", sep = " & ")
  col_spec <- "@{}p{4.6cm} l r r p{5.0cm}@{}"

  tex <- c(
    .tex_header("corpus_estimands_table.tex", "corpus_estimands.csv",
                "% Required packages: booktabs, array, amsmath"),
    "\\begingroup", "\\small", "\\setlength{\\tabcolsep}{5pt}",
    "\\renewcommand{\\arraystretch}{1.15}",
    sprintf("\\begin{tabular}{%s}", col_spec),
    "\\toprule", header, "\\midrule", body, "\\bottomrule",
    "\\end{tabular}",
    "\\par\\vspace{2pt}\\noindent\\begin{minipage}{\\linewidth}\\footnotesize",
    .TEX_RIGOR_NOTE,
    " Article-balanced rows report the mean of within-source proportions",
    " over all source articles ($N=n_{\\mathrm{src}}$); their numerator is",
    " a mean, not a count. \\end{minipage}",
    "\\endgroup", "")
  writeLines(tex, path, useBytes = TRUE)
}

# ---- rigor_direction_summary_table.tex --------------------------------------
.render_rigor_direction_summary_tex <- function(rd, path) {
  rd <- rd[order(rd$stratum == "Overall", rd$stratum), , drop = FALSE]
  body <- paste0(
    .latex_escape(ifelse(rd$stratum == "Overall", "Overall",
                         format_stratum(rd$stratum))), " & ",
    rd$n_outcomes, " & ", rd$n_with_direction, " & ",
    rd$n_effect, " & ", rd$n_no_effect, " & ",
    .fmt_pct(rd$prop_effect), " & ", .fmt_pct(rd$prop_no_effect),
    " \\\\")
  ov <- which(rd$stratum == "Overall")
  if (length(ov)) body <- append(body, "\\midrule", after = ov[1] - 1L)

  header <- paste(
    "\\textbf{Stratum}", "\\textbf{$n$}", "\\textbf{$n_{\\mathrm{dir}}$}",
    "\\textbf{$n_{+}$}", "\\textbf{$n_{0}$}",
    "\\textbf{\\% effect}", "\\textbf{\\% no effect} \\\\", sep = " & ")
  col_spec <- "@{}l r r r r r r@{}"

  tex <- c(
    .tex_header("rigor_direction_summary_table.tex",
                "rigor_direction_summary.csv",
                "% Required packages: booktabs, array"),
    "\\begingroup", "\\small", "\\setlength{\\tabcolsep}{5pt}",
    "\\renewcommand{\\arraystretch}{1.1}",
    sprintf("\\begin{tabular}{%s}", col_spec),
    "\\toprule", header, "\\midrule", body, "\\bottomrule",
    "\\end{tabular}",
    "\\par\\vspace{2pt}\\noindent\\begin{minipage}{\\linewidth}\\footnotesize",
    "\\textit{Note.} Direction composition of the selected rigor statistic",
    " over outcomes with a valid \\texttt{rigor\\_direction}",
    " (effect vs.\\ no\\_effect; ties resolve to effect).",
    " \\end{minipage}", "\\endgroup", "")
  writeLines(tex, path, useBytes = TRUE)
}


# ==============================================================================
# Verbose validation / integrity report (reporting sanity check only --
# sidecar_acceptance() / sidecar_acceptance_all() in 40_batch_fit.R remain
# the contract gate; this never repairs sidecars)
# ==============================================================================
.report_v4_validation <- function(registry, zjoin, n_sidecars) {
  zj <- zjoin
  ns <- n_sidecars %||% NA_integer_
  d  <- registry

  message("\n--- v4 reporting validation ---")
  message(sprintf("  sidecars discovered  : %s", ns))
  message(sprintf("  outcomes loaded      : %d", nrow(d)))
  message(sprintf("  strata               : %d (%s)",
                  length(unique(d$stratum)),
                  paste(sort(unique(d$stratum)), collapse = ", ")))
  message(sprintf("  source articles      : %d",
                  length(unique(paste(d$stratum, d$source_key)))))

  miss   <- setdiff(.REQUIRED_V4_COLS, names(d))
  legacy <- intersect(.LEGACY_SCHEMA_COLS, names(d))
  message(sprintf("  required v4 cols     : %s",
                  if (length(miss) == 0L) "all present"
                  else paste("MISSING", paste(miss, collapse = ","))))
  message(sprintf("  legacy cols detected : %s",
                  if (length(legacy) == 0L) "none"
                  else paste(legacy, collapse = ",")))

  # Selected-rigor identities (Inf-safe).
  sel <- pmax(d$log10BF_rigor_effect, d$log10BF_rigor_no_effect,
              na.rm = FALSE)
  id_ok <- .bf_equal(d$log10BF_rigor, sel, 1e-6)
  want_dir <- ifelse(is.na(d$log10BF_rigor_effect) |
                       is.na(d$log10BF_rigor_no_effect), NA_character_,
                     ifelse(d$log10BF_rigor_effect >=
                              d$log10BF_rigor_no_effect,
                            "effect", "no_effect"))
  dir_ok <- (d$rigor_direction == want_dir) |
            (is.na(d$rigor_direction) & is.na(want_dir))
  # Reporting-safe margin (added in augment). The raw sidecar rigor_margin
  # stores abs(branch diff) and is NA for same-sign infinities; accept that
  # NA as consistent with the reporting-safe 0 so the identity check does not
  # false-alarm on the (-Inf,-Inf) rows.
  rmrep <- d$rigor_margin_reporting
  margin_ok <- .bf_equal(d$rigor_margin, rmrep, 1e-6) |
               (is.na(d$rigor_margin) & is.finite(rmrep) & rmrep == 0)
  both_branch <- !is.na(d$log10BF_rigor_effect) &
                 !is.na(d$log10BF_rigor_no_effect)
  n_missing_rep_margin <- sum(both_branch & is.na(rmrep))
  message(sprintf("  rigor identity       : sel=%d/%d dir=%d/%d margin=%d/%d",
                  sum(id_ok, na.rm = TRUE), nrow(d),
                  sum(dir_ok, na.rm = TRUE), nrow(d),
                  sum(margin_ok, na.rm = TRUE), nrow(d)))
  message(sprintf(
    "  reporting margin     : %d missing where both branches present",
    n_missing_rep_margin))

  bad_dir <- !(d$rigor_direction %in% .RIGOR_DIRECTION_LEVELS |
               is.na(d$rigor_direction))
  message(sprintf("  rigor_direction lvls : %s",
                  if (!any(bad_dir)) "ok (effect/no_effect/NA only)"
                  else sprintf("BAD x%d", sum(bad_dir))))

  unexp_na <- .bf_available(d$log10BF_rigor) &
              d$rigor_direction %in% .RIGOR_DIRECTION_LEVELS &
              is.na(d$rigor_category)
  message(sprintf("  rigor_category NA    : %d unexpected (rigor+dir present)",
                  sum(unexp_na)))
  bad_cat <- !(d$rigor_category %in% .RIGOR_CATEGORY_LEVELS |
               is.na(d$rigor_category))
  if (any(bad_cat))
    message(sprintf("  rigor_category lvls  : BAD x%d", sum(bad_cat)))

  if (isTRUE(zj$included)) {
    message(sprintf("  zplot diag join      : %d/%d rows (key=%s)%s",
                    zj$n_joined, zj$n_total, zj$key %||% "n/a",
                    if (length(zj$missing_strata))
                      sprintf("; missing: %s",
                              paste(zj$missing_strata, collapse = ","))
                    else ""))
  } else message("  zplot diag join      : skipped (include=FALSE)")

  bf_cols <- c("log10BF_effect", "log10BF_het", "log10BF_bias",
               "log10BF_no_bias", "log10BF_rigor",
               "log10BF_rigor_effect", "log10BF_rigor_no_effect")
  for (cl in bf_cols) {
    x <- d[[cl]]
    message(sprintf("  %-24s NA=%d +Inf=%d -Inf=%d finite=%d", cl,
                    sum(is.na(x)),
                    sum(!is.na(x) & is.infinite(x) & x > 0),
                    sum(!is.na(x) & is.infinite(x) & x < 0),
                    sum(is.finite(x))))
  }
  message("-------------------------------")
  invisible(NULL)
}


# ==============================================================================
# Entry point: build_estimand_tables()
# ==============================================================================
#' Build all v4 reporting tables (CSV + TeX).
#'
#' @param output_dir   Directory for generated tables (created if absent).
#' @param root         Root under which per-stratum sidecars are discovered.
#' @param stratum      NULL -> all strata; a slug -> only that stratum.
#' @param include_zplot_diagnostics  Join the per-stratum zplot diagnostics
#'                     (missing files never abort; columns set NA).
#' @param write_tex    Also render the manuscript/supplement TeX tables.
#' @param verbose      Print progress + the reporting validation report.
#'
#' @return Invisibly, a list of the in-memory tables and the file paths
#'   written ($files).
build_estimand_tables <- function(output_dir = "output/overview",
                                  root       = "output",
                                  stratum    = NULL,
                                  include_zplot_diagnostics = TRUE,
                                  write_tex  = TRUE,
                                  verbose    = TRUE) {
  vmsg <- function(...) if (verbose) message(...)
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  vmsg("=== Building v4 estimand tables ===")

  registry <- .load_v4_outcome_registry(
    root = root, stratum = stratum,
    include_zplot_diagnostics = include_zplot_diagnostics,
    exclude_dirs = output_dir, verbose = verbose)
  zjoin      <- attr(registry, "zplot_join")
  n_sidecars <- attr(registry, "n_sidecars")
  registry <- .augment_registry_for_reporting(registry)
  registry <- registry[, c(.REGISTRY_SIDECAR_COLS, .REGISTRY_ZPLOT_COLS,
                           .REGISTRY_DERIVED_COLS), drop = FALSE]

  if (verbose) .report_v4_validation(registry, zjoin, n_sidecars)

  # ---- Build tables -------------------------------------------------------
  strata <- sort(unique(registry$stratum))

  stratum_estimands <- do.call(rbind, c(
    lapply(strata, function(s)
      .build_stratum_estimand_row(registry[registry$stratum == s, ,
                                            drop = FALSE], s)),
    list(.build_stratum_estimand_row(registry, "Overall"))))

  article_balanced <- do.call(rbind, c(
    lapply(strata, function(s)
      .build_article_balanced_estimands(
        registry[registry$stratum == s, , drop = FALSE], s)),
    list(.build_article_balanced_estimands(registry, "Overall"))))

  corpus_estimands       <- .build_corpus_estimands(registry)
  rigor_category_summary <- .build_rigor_category_summary(registry)
  rigor_direction_summary <- .build_rigor_direction_summary(registry)
  component_evidence      <- .build_component_evidence_summary(registry)

  # Compact browsing view: column subset sorted by descending selected rigor
  # (+Inf first, then finite, then -Inf, NA last). The full registry above
  # remains the complete audit/data-mart file.
  compact <- registry[order(-registry$log10BF_rigor), , drop = FALSE]
  compact$rigor_margin <- compact$rigor_margin_reporting
  compact <- compact[, .REGISTRY_COMPACT_COLS, drop = FALSE]
  rownames(compact) <- NULL

  # ---- Write CSVs ---------------------------------------------------------
  files <- list()
  put <- function(df, name) {
    p <- file.path(output_dir, name)
    write.csv(df, p, row.names = FALSE)
    files[[sub("\\.csv$", "", name)]] <<- p
    vmsg(sprintf("  ✓ %s", p))
  }
  put(registry,                "outcome_registry.csv")
  put(compact,                 "outcome_registry_compact.csv")
  put(stratum_estimands,       "stratum_estimands.csv")
  put(article_balanced,        "article_balanced_estimands.csv")
  put(corpus_estimands,        "corpus_estimands.csv")
  put(rigor_category_summary,  "rigor_category_summary.csv")
  put(rigor_direction_summary, "rigor_direction_summary.csv")
  put(component_evidence,      "component_evidence_summary.csv")

  # ---- Write TeX ----------------------------------------------------------
  if (isTRUE(write_tex)) {
    tput <- function(fun, df, name) {
      p <- file.path(output_dir, name)
      fun(df, p)
      files[[sub("\\.tex$", "_tex", name)]] <<- p
      vmsg(sprintf("  ✓ %s", p))
    }
    tput(.render_outcome_registry_tex, registry,
         "outcome_registry_table.tex")
    tput(.render_stratum_estimands_tex, stratum_estimands,
         "stratum_estimands_table.tex")
    tput(.render_article_balanced_estimands_tex, article_balanced,
         "article_balanced_estimands_table.tex")
    tput(.render_corpus_estimands_tex, corpus_estimands,
         "corpus_estimands_table.tex")
    tput(.render_rigor_direction_summary_tex, rigor_direction_summary,
         "rigor_direction_summary_table.tex")
  }

  vmsg(sprintf("\n=== Done. %d outcomes, %d strata -> %s/ ===",
               nrow(registry), length(strata), output_dir))

  invisible(list(
    output_dir              = output_dir,
    root                    = root,
    stratum                 = stratum,
    outcome_registry        = registry,
    outcome_registry_compact = compact,
    stratum_estimands       = stratum_estimands,
    article_balanced_estimands = article_balanced,
    corpus_estimands        = corpus_estimands,
    rigor_category_summary  = rigor_category_summary,
    rigor_direction_summary = rigor_direction_summary,
    component_evidence_summary = component_evidence,
    files                   = files
  ))
}


# Sentinel so other pipeline scripts can guard against double-sourcing.
.estimand_tables_loaded <- TRUE
