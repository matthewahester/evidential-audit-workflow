# 50_stratum_visuals.R
# ------------------------------------------------------------------------------
# Stratum-level / source-level inspection figures (RoBMA 4.0 rigor pipeline).
#
# This is the within-stratum visual counterpart to 60_estimand_tables.R. It
# consumes the canonical reporting registry written by build_estimand_tables()
# (output/overview/outcome_registry.csv), filters it to one stratum (and
# optionally one source article and/or analysis variant), and renders the
# paired baseline-vs-RoBMA-PSMA inspection figures. It writes FIGURES ONLY:
# the tabular schemas are owned by 60_estimand_tables.R and are never
# regenerated or re-derived here.
#
# build_stratum_visuals() produces:
#   * <scope>_effect_estimate_comparison.pdf  - paired baseline RE vs RoBMA-PSMA
#   * <scope>_effect_forest.pdf               - forest plot (RE vs PSMA)
#   * <scope>_component_violin_stack.pdf       - 3-panel (effect / het / bias)
#                                               display-capped raw-log10 violins
#   * <scope>_rigor_ranking.pdf               - outcome-level rigor ranking
#                                               (display-capped raw log10 axis;
#                                               include_rigor)
# under output/<stratum>/plots/, or output/<stratum>/<source_article>/plots/
# when a source article is requested. `<scope>` is the stratum slug, or
# <stratum>_<source_article> for a source-scoped run. The component-BF and
# rigor figures use RAW log10(BF) axes with DISPLAY CAPPING at
# |log10(BF)| = 2 (values beyond the cap, incl. +-Inf, are plotted AT the
# cap; raw registry/sidecar values are never mutated). The retired
# orchard (evidence-axis transform) panel is not part of the active
# pipeline (archived only) and is not produced here.
#
# The visual layer is downstream of 60. If output/overview/outcome_registry.csv
# is missing, build_stratum_visuals() stops with a clear error telling the
# caller to run build_estimand_tables() first; there is NO sidecar fallback
# and no silent legacy-schema remap.
#
# DEFINE-ONLY: sourcing installs functions/constants and a load sentinel only.
# No package is attached, nothing is discovered, read, written, or plotted
# merely by sourcing. The plotting runtime is armed lazily inside the entry
# points (.ensure_visual_runtime()).
#
# Quick-Start
#   source("scripts/50_stratum_visuals.R")
#   build_stratum_visuals(stratum = "fiber")                       # whole stratum
#   build_stratum_visuals(stratum = "fiber", source_article = "nunes2022")
#   build_stratum_visuals(stratum = "fiber", variant = "main")
#   build_source_visuals("fiber", "nunes2022")                     # convenience
# ------------------------------------------------------------------------------


# ---- Shared contract + helpers (sentinel-guarded; 00_utils.R is define-only) -
# Provides format_stratum, norm_slug, %||%, .strip_excl_suffix,
# .ANALYSIS_VARIANT_LEVELS. (The evidence-axis transform helpers are no
# longer used here - the orchard module is retired and archived only.)
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}

# Plotting runtime, armed lazily so sourcing this file stays side-effect-free.
.ensure_visual_runtime <- function() {
  suppressPackageStartupMessages({
    library(tidyverse); library(readr); library(stringr); library(patchwork)
  })
}

# Palette for the paired baseline RE vs RoBMA-PSMA visuals. Pulled from
# the shared semantic palette in scripts/00_utils.R::.VIS_COLORS so the
# Baseline-RE-blue / RoBMA-PSMA-red mapping is consistent across every
# figure family (see docs/visual_color_contract.md).
COLOR_ORIGINAL  <- .VIS_COLORS$method[["baseline_re"]]
COLOR_CORRECTED <- .VIS_COLORS$method[["robma_psma"]]

# rigor_direction is stored as effect / no_effect only (never "null").
# Both are POSITIVE evidential states; no_effect uses muted purple so
# it does not read as failure.
.RIGOR_DIR_COLORS <- .VIS_COLORS$rigor_direction


# ==== LIGHTWEIGHT VISUAL DIAGNOSTICS ========================================
# One-row record per generated plot. Constructed AFTER ggsave() so the file
# checks reflect the written PDF. No CSV is ever written - build_*_visuals()
# returns the bound rows as an invisible tibble ($diagnostics). Kept local to
# this script (not shared) per the migration's "no new helper script" rule.
.diag_row <- function(plot_type, output_file,
                      scope_stratum = NA_character_,
                      scope_source_article = NA_character_,
                      scope_variant = NA_character_,
                      panel = NA_character_,
                      rows_available = NA_integer_,
                      rows_plotted = NA_integer_,
                      x_min = NA_real_, x_max = NA_real_,
                      y_min = NA_real_, y_max = NA_real_,
                      axis_override = "none",
                      n_outside_axis_override = NA_integer_,
                      n_inf = NA_integer_,
                      inf_disposition = NA_character_) {
  fe <- file.exists(output_file)
  fs <- if (fe) suppressWarnings(file.size(output_file)) else NA_real_
  data.frame(
    plot_type = plot_type, panel = panel,
    scope_stratum = scope_stratum,
    scope_source_article = scope_source_article,
    scope_variant = scope_variant,
    output_file = output_file,
    rows_available = as.integer(rows_available),
    rows_plotted   = as.integer(rows_plotted),
    rows_dropped   = as.integer(rows_available) - as.integer(rows_plotted),
    x_min = x_min, x_max = x_max, y_min = y_min, y_max = y_max,
    axis_override = axis_override,
    n_outside_axis_override = as.integer(n_outside_axis_override),
    n_inf = as.integer(n_inf),
    inf_disposition = inf_disposition,
    file_exists  = fe,
    file_size_ok = isTRUE(fe) && !is.na(fs) && fs > 0,
    stringsAsFactors = FALSE
  )
}

# Finite range helper: range over finite values, c(NA, NA) when none.
.frng <- function(v) {
  v <- v[is.finite(v)]
  if (!length(v)) c(NA_real_, NA_real_) else range(v)
}


# ==== RIGOR HELPERS (raw log10 axes; local to this script) ==================
# Rigor is defined as the larger of the effect-supporting and
# no-effect-supporting no-bias branch Bayes factors,
# max(log10BF_rigor_effect, log10BF_rigor_no_effect); it is NOT a Bayes factor
# for one fixed model family, and rigor_direction (effect / no_effect) records
# the winning branch. The rigor figure uses a RAW log10 axis with DISPLAY
# CAPPING at |log10(BF)| = 2 (same convention as the violins; see the
# display-capped violin helpers below and docs/visuals.md).

# Reference/guide lines within [lo, hi]: 0 solid, +-0.5 / +-1 dashed.
.rigor_guide_lines <- function(lo, hi, vertical = TRUE,
                               thresholds = c(-1, -0.5, 0, 0.5, 1)) {
  if (!is.finite(lo) || !is.finite(hi)) return(list())
  th <- thresholds[thresholds >= lo & thresholds <= hi]
  lapply(th, function(t) {
    lt <- if (t == 0) "solid"  else "dashed"
    cl <- if (t == 0) "gray30" else "gray65"
    if (vertical)
      ggplot2::geom_vline(xintercept = t, linetype = lt, color = cl,
                          linewidth = 0.4)
    else
      ggplot2::geom_hline(yintercept = t, linetype = lt, color = cl,
                          linewidth = 0.4)
  })
}


# ==== DISPLAY-CAPPED VIOLIN HELPERS (shared style with 70; local copies) =====
# The stratum component figure uses the SAME display-capping convention as the
# corpus violins in 70_corpus_visuals.R. Helpers are duplicated here (kept
# byte-identical to 70) so 50 stays self-contained and define-only
# without cross-sourcing 70. The evidence-axis orchard module is retired
# and archived only.

# Display cap for the violin family. log10(BF) = 2 already means BF = 100;
# values beyond +/-cap (incl. +/-Inf) are winsorized onto the cap FOR DISPLAY
# ONLY. Raw registry/sidecar values are never mutated.
LOG10_BF_DISPLAY_CAP <- 2

.cap_log10_bf_for_violin <- function(x, cap = LOG10_BF_DISPLAY_CAP) {
  x <- suppressWarnings(as.numeric(x))
  d <- x
  d[!is.na(x) & x >  cap] <-  cap     # also catches +Inf
  d[!is.na(x) & x < -cap] <- -cap     # also catches -Inf
  d
}

.summarize_violin_display_cap <- function(x, cap = LOG10_BF_DISPLAY_CAP) {
  x   <- suppressWarnings(as.numeric(x))
  fin <- x[is.finite(x)]
  d   <- .cap_log10_bf_for_violin(x, cap)
  d   <- d[!is.na(d)]
  list(
    display_cap   = cap,
    finite_n      = length(fin),
    pos_inf_n     = sum(is.infinite(x) & x > 0),
    neg_inf_n     = sum(is.infinite(x) & x < 0),
    missing_n     = sum(is.na(x)),
    finite_min    = if (length(fin)) min(fin) else NA_real_,
    finite_max    = if (length(fin)) max(fin) else NA_real_,
    capped_low_n  = sum(!is.na(x) & x <= -cap),
    capped_high_n = sum(!is.na(x) & x >=  cap),
    display_min   = if (length(d)) min(d) else NA_real_,
    display_max   = if (length(d)) max(d) else NA_real_
  )
}

# x-axis geometry for a display-capped axis: data-driven with light padding,
# extended a fixed amount past a USED cap so the winsorized pile is not flush
# with the border; the cap tick is labelled "<= -cap" / ">= cap" (plotmath).
.violin_axis <- function(disp, cap = LOG10_BF_DISPLAY_CAP) {
  disp <- disp[is.finite(disp)]
  if (length(disp)) {
    rng  <- range(disp)
    span <- diff(rng)
    pad  <- if (span > 0) 0.04 * span else 0.1
  } else {
    rng <- c(-1, 1); pad <- 0.1
  }
  cap_pad <- 0.10
  hit_hi <- length(disp) && rng[2] >=  cap - 1e-9
  hit_lo <- length(disp) && rng[1] <= -cap + 1e-9
  x_hi <- if (hit_hi)  cap + cap_pad else rng[2] + pad
  x_lo <- if (hit_lo) -cap - cap_pad else rng[1] - pad

  fb <- suppressWarnings(scales::extended_breaks(n = 5)(c(rng[1], rng[2])))
  fb <- fb[is.finite(fb) & fb > x_lo & fb < x_hi]
  if (hit_hi) fb <- fb[fb <  cap - 1e-9]
  if (hit_lo) fb <- fb[fb > -cap + 1e-9]

  brk <- c(if (hit_lo) -cap, fb, if (hit_hi) cap)
  num_lbl <- lapply(format(fb, trim = TRUE), function(s) bquote(.(s)))
  lbl <- c(if (hit_lo) list(bquote("" <= .(-cap))),
           num_lbl,
           if (hit_hi) list(bquote("" >= .(cap))))

  list(x_lo = x_lo, x_hi = x_hi, breaks = brk, labels = lbl,
       hit_lo = hit_lo, hit_hi = hit_hi)
}

# Evidence-style gray bands at raw log10 BF thresholds (|log10 BF| =
# log10(3), 1, 2), clamped to the visible [lo, hi]. Same family as 70.
.rigor_evidence_bands <- function(lo, hi) {
  if (!is.finite(lo) || !is.finite(hi) || hi <= lo) return(list())
  e <- list(m2 = -2, m1 = -1, m05 = -log10(3),
            p05 =  log10(3), p1 = 1, p2 = 2)
  layers <- list()
  push <- function(a, b, fill) {
    a <- max(a, lo); b <- min(b, hi)
    if (b <= a) return(invisible(NULL))
    layers[[length(layers) + 1L]] <<- ggplot2::annotate(
      "rect", xmin = a, xmax = b, ymin = -Inf, ymax = Inf,
      fill = fill, alpha = 0.2)
  }
  push(-Inf,  e$m2,  "gray10")
  push(e$m2,  e$m1,  "gray30")
  push(e$m1,  e$m05, "gray70")
  push(e$p05, e$p1,  "gray70")
  push(e$p1,  e$p2,  "gray30")
  push(e$p2,   Inf,  "gray10")
  layers
}

# Forest-plot-style two-line outcome label (shared style with the forest
# plot below and the corpus ranking-extremes figure in 70):
#   OUTCOME NAME (REDUCED SET)
#   Author Year  n=k
.forest_style_label <- function(df) {
  sa       <- as.character(df$source_article)
  src_name <- sub("[0-9]+$", "", sa)
  yr <- if ("source_year" %in% names(df))
    suppressWarnings(as.integer(df$source_year)) else rep(NA_integer_, nrow(df))
  src_label <- ifelse(
    !is.na(yr) & nzchar(src_name),
    paste0(tools::toTitleCase(src_name), " ", yr),
    tools::toTitleCase(sa))
  excl  <- !is.na(df$analysis_variant) &
           df$analysis_variant == "exclusion_sensitivity"
  base  <- .strip_excl_suffix(as.character(df$outcome_slug))
  oname <- stringr::str_to_title(gsub("_", " ", base))
  suffix <- ifelse(excl, " (reduced set)", "")
  nval <- if ("n_studies" %in% names(df))
    suppressWarnings(as.integer(df$n_studies)) else rep(NA_integer_, nrow(df))
  n_label <- ifelse(!is.na(nval), paste0("  n=", nval), "")
  paste0(toupper(oname), toupper(suffix), "\n", src_label, n_label)
}

# One display-capped component violin panel (single distribution of this
# stratum/scope's outcomes for `bf_col`). Returns list(plot, info).
.stratum_component_panel <- function(df, bf_col, title, fill_color,
                                     cap = LOG10_BF_DISPLAY_CAP) {
  raw  <- suppressWarnings(as.numeric(df[[bf_col]]))
  scs  <- .summarize_violin_display_cap(raw, cap)
  disp <- .cap_log10_bf_for_violin(raw, cap)
  dd   <- data.frame(x = disp[!is.na(disp)])
  ax   <- .violin_axis(dd$x, cap)
  info <- c(list(rows_available = length(raw), rows_plotted = nrow(dd),
                 x_min = ax$x_lo, x_max = ax$x_hi), scs)

  base_theme <- theme_minimal(base_size = 12) +
    theme(
      panel.grid.minor   = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_blank(),
      axis.text.y  = element_blank(),
      axis.ticks.y = element_blank(),
      axis.text.x  = element_text(size = 9),
      axis.ticks.x = element_line(color = "gray60"),
      legend.position = "none",
      plot.title   = element_text(face = "bold", size = 12),
      plot.margin  = margin(8, 10, 6, 10),
      panel.border = element_rect(colour = "gray30", fill = NA,
                                  linewidth = 0.4),
      axis.line    = element_line(colour = "gray60", linewidth = 0.3))

  if (nrow(dd) == 0L) {
    p <- ggplot() + labs(title = title, x = expression(log[10](BF)),
                         y = NULL) + base_theme
    return(list(plot = p, info = info))
  }

  q <- quantile(dd$x, c(.10, .25, .50, .75, .90))
  dd$g <- "scope"
  set.seed(7385783)
  p <- ggplot(dd, aes(x = x, y = g)) +
    .rigor_evidence_bands(ax$x_lo, ax$x_hi) +
    .rigor_guide_lines(ax$x_lo, ax$x_hi, vertical = TRUE) +
    geom_violin(fill = fill_color, color = "gray40", linewidth = 0.3,
                alpha = 0.30, scale = "width", trim = TRUE, adjust = 1.2) +
    geom_jitter(height = 0.16, width = 0, size = 1.3, alpha = 0.8,
                color = fill_color) +
    annotate("segment", x = q[1], xend = q[5], y = 1, yend = 1,
             color = "gray20", linewidth = 0.7, alpha = 0.7) +
    annotate("segment", x = q[2], xend = q[4], y = 1, yend = 1,
             color = "gray15", linewidth = 3.0, alpha = 0.8) +
    annotate("point", x = q[3], y = 1, color = "white", size = 3.0,
             shape = 16) +
    annotate("point", x = q[3], y = 1, color = "gray10", size = 2.0,
             shape = 16) +
    scale_x_continuous(expand = c(0, 0),
                       breaks = ax$breaks, labels = ax$labels) +
    scale_y_discrete(expand = expansion(add = 0.6)) +
    coord_cartesian(xlim = c(ax$x_lo, ax$x_hi), clip = "off") +
    labs(title = title, x = expression(log[10](BF)), y = NULL) +
    base_theme
  list(plot = p, info = info)
}

# Stratum-level vertical three-component violin stack (Effect /
# Heterogeneity / Modeled bias, top-to-bottom) for one stratum/source scope.
# Each panel keeps its own component-specific display-capped x axis (same
# convention as the corpus stack in 70).
.stratum_component_violin_stack <- function(df, scope_lab,
                                            cap = LOG10_BF_DISPLAY_CAP) {
  pe <- .stratum_component_panel(df, "log10BF_effect", "A. Effect evidence",
                                 .VIS_COLORS$component[["effect"]], cap)
  ph <- .stratum_component_panel(df, "log10BF_het",
                                 "B. Heterogeneity evidence",
                                 .VIS_COLORS$component[["heterogeneity"]],
                                 cap)
  pb <- .stratum_component_panel(df, "log10BF_bias",
                                 "C. Modeled bias evidence",
                                 .VIS_COLORS$component[["bias"]], cap)

  combined <- (pe$plot / ph$plot / pb$plot) +
    plot_annotation(
      title = sprintf("Component Bayes factors — %s", scope_lab),
      caption = paste0("Display-capped at |log10(BF)| = 2; values beyond ",
                       "the cap, incl. +/-Inf, are plotted at the cap."),
      theme = theme(
        plot.title   = element_text(hjust = 0.5, size = 14, face = "bold",
                                    margin = margin(b = 8)),
        plot.caption = element_text(hjust = 0.5, size = 9, color = "gray40",
                                    margin = margin(t = 8))))

  list(plot = combined,
       infos = list(effect = pe$info, heterogeneity = ph$info,
                    bias = pb$info))
}


# ==== REGISTRY CONSUMER =====================================================
# Read the canonical reporting registry from 60 and slice it to the requested
# stratum (+ optional source_article / analysis_variant). No sidecar fallback,
# no legacy-schema remap: a missing or non-v4 registry is a hard error.
.consume_stratum_slice <- function(output_dir, stratum,
                                    source_article, variant, verbose) {
  vmsg <- function(...) if (verbose) message(...)

  registry_path <- file.path(output_dir, "outcome_registry.csv")
  if (!file.exists(registry_path)) {
    stop(sprintf(paste0(
      "Reporting registry not found: %s\n",
      "  The visual layer is downstream of 60_estimand_tables.R. Run\n",
      "  build_estimand_tables() (scripts/60_estimand_tables.R) first."),
      registry_path), call. = FALSE)
  }
  vmsg(sprintf("Reading reporting registry: %s", registry_path))
  reg <- readr::read_csv(registry_path, show_col_types = FALSE,
                         progress = FALSE)

  # v4 columns these figures need. Their absence means this is not a v4
  # outcome_registry.csv (we never silently remap legacy topic/author/effect).
  req <- c("stratum", "source_article", "source_year", "outcome_slug",
           "dataset_id", "analysis_variant", "n_studies",
           "mu_RE", "mu_RE_lCI", "mu_RE_uCI",
           "mu_BC", "mu_BC_lCI", "mu_BC_uCI",
           "log10BF_effect", "log10BF_het", "log10BF_bias",
           "log10BF_rigor", "log10BF_rigor_effect",
           "log10BF_rigor_no_effect", "rigor_direction", "rigor_category")
  miss <- setdiff(req, names(reg))
  if (length(miss)) {
    stop(sprintf(paste0(
      "Registry is missing required v4 column(s): %s\n",
      "  %s is not a v4 outcome_registry.csv. Re-run build_estimand_tables()\n",
      "  (scripts/60_estimand_tables.R)."),
      paste(miss, collapse = ", "), registry_path), call. = FALSE)
  }

  stratum_slug <- norm_slug(stratum)
  in_stratum   <- norm_slug(reg$stratum) == stratum_slug
  if (!any(in_stratum)) {
    stop(sprintf(paste0(
      "No outcomes for stratum '%s' in the registry.\n  Available strata: %s"),
      stratum, paste(sort(unique(reg$stratum)), collapse = ", ")),
      call. = FALSE)
  }
  reg <- reg[in_stratum, , drop = FALSE]

  if (!is.null(source_article)) {
    keep <- reg$source_article == source_article
    if (!any(keep)) {
      stop(sprintf(paste0(
        "No outcomes for source_article '%s' in stratum '%s'.\n",
        "  Available source articles: %s"),
        source_article, stratum,
        paste(sort(unique(reg$source_article)), collapse = ", ")),
        call. = FALSE)
    }
    reg <- reg[keep, , drop = FALSE]
  }

  if (!is.null(variant)) {
    if (!variant %in% .ANALYSIS_VARIANT_LEVELS) {
      stop(sprintf("Invalid variant '%s'; expected one of: %s",
                   variant, paste(.ANALYSIS_VARIANT_LEVELS, collapse = ", ")),
           call. = FALSE)
    }
    keep <- reg$analysis_variant == variant
    if (!any(keep)) {
      stop(sprintf("No '%s' outcomes for the requested stratum/source.",
                   variant), call. = FALSE)
    }
    reg <- reg[keep, , drop = FALSE]
  }

  reg
}


# ==== ENTRY POINT ===========================================================

build_stratum_visuals <- function(stratum,
                                   output_dir = "output/overview",
                                   root = "output",
                                   source_article = NULL,
                                   variant = NULL,
                                   verbose = TRUE,
                                   include_rigor = TRUE,
                                   rigor_axis_cap = NULL,
                                   ...) {
  # Build the within-stratum inspection figures from the canonical reporting
  # registry. Writes PDFs under output/<stratum>/plots/ (or
  # output/<stratum>/<source_article>/plots/ when source_article is given).
  # Figures only - 60_estimand_tables.R owns every tabular output.
  #
  # include_rigor   also write <scope>_rigor_ranking.pdf (raw log10
  #                 rigor axis, display-capped). Default TRUE.
  # rigor_axis_cap  deprecated / ignored: rigor is now display-
  #                 capped at |log10(BF)| = 2 (kept only for call-site
  #                 backward compatibility).
  #
  # Returns invisibly: list(data = <slice>, files = list(...),
  #   diagnostics = <tibble, one row per generated plot/panel>). The
  #   diagnostics log is never written to disk.

  .ensure_visual_runtime()

  vmsg <- function(...) if (verbose) message(...)
  # Reproducibility seed for the jitter/sampling steps. Kept inside the
  # function so sourcing this file does not mutate the caller's RNG state.
  set.seed(4738)

  stratum_slug <- norm_slug(stratum)
  scope_sa     <- source_article %||% NA_character_
  scope_var    <- variant %||% NA_character_
  diag_list    <- list()

  df <- .consume_stratum_slice(output_dir, stratum, source_article,
                               variant, verbose) %>%
    mutate(across(c(mu_RE, mu_BC, mu_RE_lCI, mu_RE_uCI,
                    mu_BC_lCI, mu_BC_uCI, n_studies,
                    log10BF_effect, log10BF_het, log10BF_bias,
                    log10BF_rigor, log10BF_rigor_effect,
                    log10BF_rigor_no_effect),
                  as.numeric),
           rigor_direction = as.character(rigor_direction))

  # Output scope: stratum-level vs source-scoped. The directory already
  # encodes the scope; the filename prefix keeps each PDF self-describing.
  source_scoped <- !is.null(source_article)
  if (source_scoped) {
    plots_dir  <- file.path(root, stratum_slug, source_article, "plots")
    scope_stem <- paste(stratum_slug, source_article, sep = "_")
    scope_lab  <- sprintf("%s — %s", format_stratum(stratum_slug),
                          source_article)
  } else {
    plots_dir  <- file.path(root, stratum_slug, "plots")
    scope_stem <- stratum_slug
    scope_lab  <- format_stratum(stratum_slug)
  }
  dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

  pairs_df <- df %>%
    filter(is.finite(mu_RE) & is.finite(mu_BC))
  if (nrow(pairs_df) == 0)
    stop("No outcomes with finite (mu_RE, mu_BC) pairs after filtering.",
         call. = FALSE)

  # ==========================================================================
  # 1. PAIRED BASELINE RE vs RoBMA-PSMA BOXPLOT
  # ==========================================================================
  vmsg("Creating paired baseline-vs-RoBMA-PSMA boxplot...")

  plot_data_long <- pairs_df %>%
    select(dataset_id, mu_RE, mu_BC) %>%
    pivot_longer(c(mu_RE, mu_BC), names_to = "Method",
                 values_to = "Estimate") %>%
    mutate(Method = factor(
      ifelse(Method == "mu_RE", "Baseline RE", "RoBMA-PSMA"),
      levels = c("Baseline RE", "RoBMA-PSMA")))

  set.seed(4738)
  df_jitter <- pairs_df %>% mutate(jitter = runif(n(), -0.08, 0.08))

  p_boxplot <- ggplot() +
    geom_boxplot(data = plot_data_long,
                 aes(x = Method, y = Estimate, fill = Method),
                 alpha = 0.6, width = 0.4, outlier.shape = NA) +
    geom_hline(yintercept = 0, linetype = "dashed",
               color = "grey30", linewidth = 0.5) +
    geom_segment(data = df_jitter,
                 aes(x = 1 + jitter, xend = 2 + jitter,
                     y = mu_RE, yend = mu_BC),
                 color = "gray40", alpha = 0.5) +
    geom_point(data = df_jitter, aes(x = 1 + jitter, y = mu_RE),
               color = "black", size = 2) +
    geom_point(data = df_jitter, aes(x = 2 + jitter, y = mu_BC),
               color = "black", size = 2) +
    scale_fill_manual(values = c("Baseline RE" = COLOR_ORIGINAL,
                                 "RoBMA-PSMA"  = COLOR_CORRECTED)) +
    labs(
      title = sprintf("Meta-analysis effect sizes — %s", scope_lab),
      subtitle = "Baseline RE vs RoBMA-PSMA (bias-adjusted)",
      y = "Standardized effect size",
      x = NULL
    ) +
    theme_minimal(base_size = 14) +
    theme(
      plot.title    = element_text(face = "bold"),
      plot.subtitle = element_text(color = "gray40"),
      axis.text.x   = element_text(face = "bold"),
      legend.position = "none",
      panel.border  = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line     = element_line(colour = "gray60", linewidth = 0.3)
    )

  boxplot_path <- file.path(plots_dir,
                            paste0(scope_stem, "_effect_estimate_comparison.pdf"))
  ggsave(boxplot_path, p_boxplot, width = 6, height = 10, device = "pdf")

  bx_y <- .frng(c(pairs_df$mu_RE, pairs_df$mu_BC))
  diag_list[[length(diag_list) + 1L]] <- .diag_row(
    plot_type = "effect_estimate_comparison", output_file = boxplot_path,
    scope_stratum = stratum_slug, scope_source_article = scope_sa,
    scope_variant = scope_var,
    rows_available = nrow(df), rows_plotted = nrow(pairs_df),
    y_min = bx_y[1], y_max = bx_y[2],
    axis_override = "none",
    n_inf = sum(is.infinite(c(pairs_df$mu_RE, pairs_df$mu_BC))),
    inf_disposition = "none")

  # ==========================================================================
  # 2. FOREST PLOT (baseline RE vs RoBMA-PSMA, v4 labels)
  # ==========================================================================
  vmsg("Creating forest plot...")

  forest_data <- pairs_df %>%
    transmute(
      dataset_id, source_article, source_year, outcome_slug,
      n_studies, analysis_variant,
      re_est = mu_RE, re_lo = mu_RE_lCI, re_hi = mu_RE_uCI,
      bc_est = mu_BC, bc_lo = mu_BC_lCI, bc_hi = mu_BC_uCI
    ) %>%
    mutate(
      # Source label from the v4 identity fields: "whelton2005" + 2005 ->
      # "Whelton 2005" (year suffix dropped from the name part when present).
      src_name  = str_replace(source_article, "[0-9]+$", ""),
      src_label = if_else(
        !is.na(source_year) & nzchar(src_name),
        paste0(tools::toTitleCase(src_name), " ", source_year),
        tools::toTitleCase(source_article)
      ),
      excl_flag     = analysis_variant == "exclusion_sensitivity",
      outcome_base  = .strip_excl_suffix(outcome_slug),
      outcome_label = stringr::str_to_title(
        str_replace_all(outcome_base, "_", " ")),
      label_suffix  = if_else(excl_flag, " (reduced set)", ""),
      n_label       = if_else(!is.na(n_studies),
                              paste0("  n=", n_studies), ""),
      y_label = paste0(toupper(outcome_label), toupper(label_suffix), "\n",
                       src_label, n_label)
    ) %>%
    arrange(outcome_label, src_label, excl_flag) %>%
    mutate(y_pos = n() - row_number() + 1)

  forest_long <- bind_rows(
    forest_data %>%
      select(dataset_id, y_pos, est = re_est, lo = re_lo, hi = re_hi) %>%
      mutate(Method = "Baseline RE", y_offset = 0.15),
    forest_data %>%
      select(dataset_id, y_pos, est = bc_est, lo = bc_lo, hi = bc_hi) %>%
      mutate(Method = "RoBMA-PSMA", y_offset = -0.15)
  ) %>%
    mutate(
      Method = factor(Method, levels = c("Baseline RE", "RoBMA-PSMA")),
      y_plot = y_pos + y_offset
    )

  p_forest <- ggplot(forest_long, aes(x = est, y = y_plot, color = Method)) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "gray60") +
    geom_errorbar(aes(xmin = lo, xmax = hi), orientation = "y",
                  width = 0.15, na.rm = TRUE) +
    geom_point(size = 3, na.rm = TRUE) +
    scale_color_manual(values = c("Baseline RE" = COLOR_ORIGINAL,
                                  "RoBMA-PSMA"  = COLOR_CORRECTED)) +
    scale_y_continuous(
      breaks = unique(forest_long$y_pos),
      labels = forest_data$y_label,
      expand = expansion(add = 0.5)
    ) +
    labs(
      title = sprintf("Forest plot — %s", scope_lab),
      subtitle = "Error bars show 95% credible intervals",
      x = "Standardized effect size",
      y = NULL,
      color = "Method"
    ) +
    theme_minimal(base_size = 14) +
    theme(
      plot.title    = element_text(face = "bold"),
      plot.subtitle = element_text(color = "gray40", size = 11, face = "italic"),
      legend.position    = "bottom",
      panel.grid.major.y = element_blank(),
      panel.grid.minor.y = element_blank(),
      panel.border  = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line     = element_line(colour = "gray60", linewidth = 0.3),
      axis.text.y   = element_text(size = 9, lineheight = 0.9, hjust = 1)
    )

  forest_height <- max(8, nrow(forest_data) * 0.4 + 2)
  forest_path <- file.path(plots_dir,
                           paste0(scope_stem, "_effect_forest.pdf"))
  ggsave(forest_path, p_forest, width = 8, height = forest_height,
         device = "pdf")

  f_x <- .frng(c(forest_long$est, forest_long$lo, forest_long$hi))
  f_y <- range(forest_data$y_pos)
  diag_list[[length(diag_list) + 1L]] <- .diag_row(
    plot_type = "effect_forest", output_file = forest_path,
    scope_stratum = stratum_slug, scope_source_article = scope_sa,
    scope_variant = scope_var,
    rows_available = nrow(df), rows_plotted = nrow(forest_data),
    x_min = f_x[1], x_max = f_x[2], y_min = f_y[1], y_max = f_y[2],
    axis_override = "none",
    n_inf = sum(is.infinite(c(forest_long$est, forest_long$lo,
                              forest_long$hi))),
    inf_disposition = "none")

  # ==========================================================================
  # 3. COMPONENT VIOLIN STACK (effect / heterogeneity / bias, display-capped)
  # ==========================================================================
  vmsg("Creating component violin stack (display-capped raw log10 BF)...")

  cvs <- .stratum_component_violin_stack(df, scope_lab,
                                         LOG10_BF_DISPLAY_CAP)

  cvs_path <- file.path(plots_dir,
                        paste0(scope_stem, "_component_violin_stack.pdf"))
  ggsave(cvs_path, cvs$plot, width = 7, height = 8.5, device = "pdf",
         useDingbats = FALSE)

  for (cmp in c("effect", "heterogeneity", "bias")) {
    oi <- cvs$infos[[cmp]]
    diag_list[[length(diag_list) + 1L]] <- .diag_row(
      plot_type = "component_violin_stack", panel = cmp,
      output_file = cvs_path,
      scope_stratum = stratum_slug, scope_source_article = scope_sa,
      scope_variant = scope_var,
      rows_available = oi$rows_available, rows_plotted = oi$rows_plotted,
      x_min = oi$x_min, x_max = oi$x_max,
      axis_override = "none",
      n_inf = (oi$pos_inf_n %||% 0L) + (oi$neg_inf_n %||% 0L),
      inf_disposition = if (((oi$pos_inf_n %||% 0L) +
                             (oi$neg_inf_n %||% 0L)) == 0L) "none"
                        else "display_capped")
  }

  # ==========================================================================
  # 4. RIGOR OUTCOME RANKING (display-capped raw log10 axis)
  # ==========================================================================
  rigor_path <- NA_character_
  if (isTRUE(include_rigor)) {
    vmsg("Creating rigor outcome ranking...")

    cap_d <- LOG10_BF_DISPLAY_CAP
    scs   <- .summarize_violin_display_cap(df$log10BF_rigor, cap_d)
    rk    <- df
    rk$rig <- .cap_log10_bf_for_violin(df$log10BF_rigor, cap_d)
    rk <- rk[!is.na(rk$rig), , drop = FALSE]

    # Forest-plot-style two-line labels (shared style with the forest plot).
    rk$lab <- .forest_style_label(rk)
    if (anyDuplicated(rk$lab))
      rk$lab <- paste0(rk$lab, "  (", rk$dataset_id, ")")
    rk <- rk[order(rk$rig), , drop = FALSE]
    rk$lab <- factor(rk$lab, levels = rk$lab)

    ax  <- .violin_axis(rk$rig, cap_d)
    sub <- "Points show rigor; colour shows rigor direction."

    p_rigor <- ggplot(rk, aes(x = rig, y = lab,
                              color = rigor_direction)) +
      .rigor_guide_lines(ax$x_lo, ax$x_hi, vertical = TRUE) +
      geom_segment(aes(x = 0, xend = rig, y = lab, yend = lab),
                   color = "gray70", linewidth = 0.4) +
      geom_point(size = 2.8) +
      scale_color_manual(values = .RIGOR_DIR_COLORS, na.value = "gray60",
                         name = "Rigor direction") +
      scale_x_continuous(expand = c(0, 0),
                         breaks = ax$breaks, labels = ax$labels) +
      coord_cartesian(xlim = c(ax$x_lo, ax$x_hi), clip = "off") +
      labs(title = sprintf("Rigor ranking — %s", scope_lab),
           subtitle = sub, x = expression(log[10](BF[rigor])), y = NULL) +
      theme_minimal(base_size = 12) +
      theme(panel.grid.minor = element_blank(),
            panel.grid.major.y = element_blank(),
            plot.title = element_text(face = "bold"),
            plot.subtitle = element_text(size = 9, color = "gray45"),
            legend.position = "bottom",
            axis.text.y = element_text(size = 7.5, lineheight = 0.9),
            panel.border = element_rect(colour = "gray30", fill = NA,
                                        linewidth = 0.4),
            axis.line = element_line(colour = "gray60", linewidth = 0.3))

    rigor_path <- file.path(plots_dir,
                            paste0(scope_stem, "_rigor_ranking.pdf"))
    ggsave(rigor_path, p_rigor, width = 8,
           height = max(4, 0.42 * nrow(rk) + 1.6),
           device = "pdf", useDingbats = FALSE)

    n_nonfin <- scs$pos_inf_n + scs$neg_inf_n
    diag_list[[length(diag_list) + 1L]] <- .diag_row(
      plot_type = "rigor_ranking", output_file = rigor_path,
      scope_stratum = stratum_slug, scope_source_article = scope_sa,
      scope_variant = scope_var,
      rows_available = nrow(df), rows_plotted = nrow(rk),
      x_min = ax$x_lo, x_max = ax$x_hi,
      axis_override = "none",
      n_inf = n_nonfin,
      inf_disposition = if (n_nonfin == 0L) "none" else "display_capped")
  }

  # ==========================================================================
  vmsg("\n=== Stratum figures written ===")
  vmsg(sprintf("✓ Effect estimates : %s", boxplot_path))
  vmsg(sprintf("✓ Effect forest    : %s", forest_path))
  vmsg(sprintf("✓ Component violins: %s", cvs_path))
  if (isTRUE(include_rigor))
    vmsg(sprintf("✓ Rigor ranking    : %s", rigor_path))
  vmsg("(Tabular summaries are owned by 60_estimand_tables.R; this script ",
       "writes figures only.)")

  diagnostics <- tibble::as_tibble(dplyr::bind_rows(diag_list))
  vmsg(sprintf("Diagnostics: %d plot record(s) (invisible $diagnostics; ",
               nrow(diagnostics)),
       "no CSV written)")

  invisible(list(
    data  = df,
    files = list(
      effect_estimate_comparison = boxplot_path,
      effect_forest              = forest_path,
      component_violin_stack     = cvs_path,
      rigor_ranking              = if (isTRUE(include_rigor)) rigor_path
                                   else NULL
    ),
    diagnostics = diagnostics
  ))
}


# ==== CONVENIENCE WRAPPER ===================================================
# Source-scoped run: identical to build_stratum_visuals() with source_article
# supplied; figures land under output/<stratum>/<source_article>/plots/.
build_source_visuals <- function(stratum, source_article, ...) {
  build_stratum_visuals(stratum = stratum, source_article = source_article,
                        ...)
}


# ==== DEPRECATED ALIASES ====================================================
# Pre-v4 callers used build_topic_visuals() / build_topic_summary() with a
# `topic=` argument. Both now forward to build_stratum_visuals(); the topic
# vocabulary is gone (60_estimand_tables.R owns all tabular summaries).
build_topic_visuals <- function(topic = "fiber", ...) {
  .Deprecated("build_stratum_visuals",
              msg = paste("build_topic_visuals() is deprecated; use",
                          "build_stratum_visuals(stratum = ...)."))
  build_stratum_visuals(stratum = topic, ...)
}

build_topic_summary <- function(topic = "fiber", ...) {
  .Deprecated("build_stratum_visuals",
              msg = paste(
                "build_topic_summary() is deprecated and never wrote tables.",
                "Use build_stratum_visuals() for figures and",
                "build_estimand_tables() (60_estimand_tables.R) for the",
                "tabular summaries."))
  build_stratum_visuals(stratum = topic, ...)
}


# ==== CLI ===================================================================
# Rscript scripts/50_stratum_visuals.R --stratum fiber
#                                      [--source-article nunes2022]
#                                      [--variant main|exclusion_sensitivity]
# sys.nframe() == 0L is TRUE only when this file is the top-level script being
# invoked directly; a plain source() (interactive or from another script)
# leaves it > 0, so sourcing stays strictly define-only.
if (sys.nframe() == 0L && !interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  arg_val <- function(flag) {
    i <- which(args == flag)
    if (length(i) > 0 && length(args) > i) args[i + 1] else NULL
  }

  stratum        <- arg_val("--stratum") %||% "fiber"
  source_article <- arg_val("--source-article")
  variant        <- arg_val("--variant")

  tryCatch({
    build_stratum_visuals(stratum = stratum,
                          source_article = source_article,
                          variant = variant)
    message(sprintf("\n✓ Visuals complete for stratum: %s", stratum))
  }, error = function(e) {
    message(sprintf("\n✗ Error processing stratum %s: %s",
                    stratum, conditionMessage(e)))
    quit(status = 1)
  })
}


# Sentinel for symmetry with the rest of the pipeline.
.stratum_visuals_loaded <- TRUE
