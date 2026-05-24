#!/usr/bin/env Rscript

# 55_orchard_visuals.R
# ------------------------------------------------------------------------------
# OPTIONAL / RETIRED orchard (evidence-axis) visualizations.
#
# These preserve the earlier *transformed* Bayes-factor axis (the piecewise
# evidence-axis transform + terminal Inf bin) for diagnostic / pedagogical
# inspection only. They are NO LONGER part of the main manuscript-facing
# visual suite and are NOT sourced or called by 50_stratum_visuals.R or
# 70_corpus_visuals.R. The active component-evidence displays are the
# DISPLAY-CAPPED raw-log10 violin figures:
#   * stratum : <scope>_component_violin_stack.pdf   (50_stratum_visuals.R)
#   * corpus  : corpus_component_violin_{effect,heterogeneity,bias}.pdf
#               and corpus_component_violin_stack.pdf (70_corpus_visuals.R)
#
# This module only runs when explicitly invoked:
#   source("scripts/55_orchard_visuals.R")
#   build_corpus_orchards()                       # corpus_orchard_*.pdf
#   build_stratum_orchards(stratum = "protein")   # <scope>_component_orchard.pdf
#
# It consumes the same canonical reporting registry written by
# build_estimand_tables() (output/overview/outcome_registry.csv). It writes
# FIGURES ONLY and never re-derives any tabular schema or sidecar.
#
# DEFINE-ONLY: sourcing installs functions/constants and a load sentinel only.
# Nothing is attached, discovered, read, written, or plotted merely by
# sourcing; the plotting runtime is armed lazily inside the entry points.
# ------------------------------------------------------------------------------


# ---- Shared contract + helpers (sentinel-guarded; 00_utils.R is define-only) -
# Provides format_stratum, norm_slug, %||%, .compute_precision,
# .bf_evidence_transform, .bf_axis_spec, .compute_evidence_xlim,
# .evidence_band_layers, .evidence_guide_layers, .ANALYSIS_VARIANT_LEVELS.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}

# Plotting runtime, armed lazily so sourcing this file stays side-effect-free.
.ensure_orchard_runtime <- function() {
  suppressPackageStartupMessages({
    library(tidyverse); library(readr); library(stringr); library(patchwork)
  })
}

# Tableau-inspired stratum palette (kept in sync with 70_corpus_visuals.R so a
# retired orchard rebuild matches the historical colour assignment).
.orchard_tableau10 <- c(
  "#263238", "#1B5E20", "#1B5E63", "#6D4C41", "#F9A825",
  "#EF6C00", "#8E24AA", "#0277BD", "#37474F"
)


# ==============================================================================
# Registry consumer (60 output; no sidecar rediscovery, no legacy fallback)
# ==============================================================================
.orchard_read_registry <- function(output_dir, verbose) {
  vmsg <- function(...) if (verbose) message(...)
  csv_path <- file.path(output_dir, "outcome_registry.csv")
  if (!file.exists(csv_path))
    stop(sprintf(paste0(
      "Reporting registry not found: %s\n",
      "  The orchard module is downstream of 60_estimand_tables.R. Run\n",
      "  build_estimand_tables() (scripts/60_estimand_tables.R) first."),
      csv_path), call. = FALSE)
  vmsg(sprintf("Reading reporting registry: %s", csv_path))
  reg <- readr::read_csv(csv_path, show_col_types = FALSE, progress = FALSE)

  req <- c("stratum", "source_article", "outcome_slug", "dataset_id",
           "analysis_variant", "log10BF_effect", "log10BF_het",
           "log10BF_bias", "mu_BC_lCI", "mu_BC_uCI")
  miss <- setdiff(req, names(reg))
  if (length(miss))
    stop(sprintf(paste0(
      "Registry is missing required v4 column(s): %s\n",
      "  %s is not a v4 outcome_registry.csv. Re-run build_estimand_tables()."),
      paste(miss, collapse = ", "), csv_path), call. = FALSE)

  reg %>%
    mutate(
      stratum        = as.character(stratum),
      log10BF_effect = suppressWarnings(as.numeric(log10BF_effect)),
      log10BF_het    = suppressWarnings(as.numeric(log10BF_het)),
      log10BF_bias   = suppressWarnings(as.numeric(log10BF_bias)),
      stratum_label  = format_stratum(stratum)
    )
}


# ==============================================================================
# Orchard panel / facet helpers (preserved evidence-axis transform)
# ==============================================================================

# One single-component orchard panel for the stratum-level 3x1 figure. The
# piecewise evidence-axis transform maps Inf to the terminal evidence bin
# (kept, never silently dropped); only missing BFs drop.
.orchard_panel <- function(dat, bf_col, title, plot_color, t_xlim, ax) {

  n_avail <- nrow(dat)
  raw_vec <- suppressWarnings(as.numeric(dat[[bf_col]]))
  n_inf   <- sum(is.infinite(raw_vec))

  dat <- dat %>%
    mutate(
      x_raw = .data[[bf_col]],
      x_t   = .bf_evidence_transform(x_raw)
    ) %>%
    filter(is.finite(x_t))

  info <- list(
    rows_available  = n_avail,
    rows_plotted    = nrow(dat),
    x_min = t_xlim[1], x_max = t_xlim[2],
    y_min = -0.19, y_max = 0.19,
    n_inf = n_inf,
    inf_disposition = if (n_inf > 0L) "transformed_terminal_bin" else "none"
  )

  if (nrow(dat) == 0L) {
    message(sprintf("  Warning: no valid %s data", bf_col))
    return(list(plot = NULL, info = info))
  }

  dat <- .compute_precision(dat)

  set.seed(7385783)
  dat$y_jit <- runif(nrow(dat), -0.18, 0.18)

  qs <- suppressWarnings(quantile(dat$prec, c(.10, .50, .90), na.rm = TRUE))
  if (any(!is.finite(qs))) qs <- rep(median(dat$prec, na.rm = TRUE), 3)

  br <- unique(round(qs, 1))
  if (length(br) < 3) br <- round(qs, 2)
  if (length(br) < 3) {
    prec_range <- range(dat$prec, na.rm = TRUE)
    br <- round(seq(prec_range[1], prec_range[2], length.out = 3), 1)
  }

  p <- ggplot(dat, aes(x = x_t)) +
    .evidence_band_layers(t_xlim) +
    .evidence_guide_layers(t_xlim) +
    geom_point(aes(y = y_jit, size = prec), alpha = 0.82, shape = 16,
               color = plot_color) +
    scale_size_continuous(range = c(2.5, 9), breaks = br, guide = "none") +
    coord_cartesian(xlim = t_xlim, ylim = c(-.19, .19), clip = "off") +
    scale_x_continuous(expand = c(0, 0), breaks = ax$breaks,
                       labels = ax$labels) +
    labs(title = title, x = "Bayes Factor", y = NULL) +
    theme_minimal(base_size = 13) +
    theme(
      panel.grid.minor   = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_blank(),
      axis.text.y  = element_blank(),
      axis.ticks.y = element_blank(),
      axis.text.x  = element_text(size = 10),
      axis.ticks.x = element_line(color = "gray60"),
      legend.position = "none",
      plot.title   = element_text(face = "bold", size = 12),
      plot.margin  = margin(12, 12, 6, 12),
      panel.border = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line    = element_line(colour = "gray60", linewidth = 0.3)
    )

  list(plot = p, info = info)
}

# One cross-stratum (corpus) orchard, faceted by stratum, evidence-axis
# transform. Inf maps to the terminal evidence bin; only missing BFs drop.
.orchard_facet_plot <- function(dat, bf_col, title, outfile,
                                stratum_colors, verbose = TRUE) {

  n_avail <- nrow(dat)
  raw_vec <- suppressWarnings(as.numeric(dat[[bf_col]]))
  n_inf   <- sum(is.infinite(raw_vec))

  dat <- dat %>%
    mutate(
      x_raw = .data[[bf_col]],
      x_t   = .bf_evidence_transform(x_raw)
    ) %>%
    filter(is.finite(x_t))

  if (nrow(dat) == 0L) {
    if (verbose) message(sprintf("  Warning: no valid %s data", bf_col))
    return(list(plot = NULL, info = list(
      rows_available = n_avail, rows_plotted = 0L,
      x_min = NA_real_, x_max = NA_real_, y_min = NA_real_, y_max = NA_real_,
      n_inf = n_inf,
      inf_disposition = if (n_inf > 0L) "transformed_terminal_bin" else "none"
    )))
  }

  dat <- .compute_precision(dat)

  set.seed(7825)
  dat$y_jit <- runif(nrow(dat), -0.18, 0.18)

  qs <- suppressWarnings(quantile(dat$prec, c(.10, .50, .90), na.rm = TRUE))
  if (any(!is.finite(qs))) qs <- rep(median(dat$prec, na.rm = TRUE), 3)

  br <- unique(round(qs, 1))
  if (length(br) < 3) br <- round(qs, 2)
  if (length(br) < 3) {
    prec_range <- range(dat$prec, na.rm = TRUE)
    br <- round(seq(prec_range[1], prec_range[2], length.out = 3), 1)
  }

  t_xlim <- .compute_evidence_xlim(dat$x_raw)
  ax     <- .bf_axis_spec(t_xlim)

  p <- ggplot(dat, aes(x = x_t)) +
    .evidence_band_layers(t_xlim) +
    .evidence_guide_layers(t_xlim) +
    geom_point(aes(y = y_jit, size = prec, color = stratum_label),
               alpha = 0.82, shape = 16) +
    facet_wrap(~ stratum_label, scales = "free_y", ncol = 2,
               axes = "all_x") +
    scale_color_manual(values = stratum_colors) +
    scale_size_continuous(name = "Precision (1/SE)",
                          range = c(2.2, 10.5), breaks = br) +
    guides(color = "none", size = "none") +
    coord_cartesian(xlim = t_xlim, ylim = c(-.19, .19), clip = "off") +
    scale_x_continuous(expand = c(0, 0), breaks = ax$breaks,
                       labels = ax$labels) +
    labs(title = title,
         subtitle = "Bubbles = outcomes sized by precision",
         x = "Bayes Factor", y = NULL) +
    theme_minimal(base_size = 13) +
    theme(
      panel.grid.minor   = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_blank(),
      strip.text   = element_text(face = "bold", size = 11),
      axis.text.y  = element_blank(),
      axis.ticks.y = element_blank(),
      axis.text.x  = element_text(size = 10),
      axis.ticks.x = element_line(color = "gray60"),
      legend.position  = "bottom",
      legend.direction = "horizontal",
      plot.title    = element_text(face = "bold", size = 12),
      plot.subtitle = element_text(size = 10, color = "gray50"),
      plot.margin   = margin(12, 12, 6, 12),
      panel.spacing.y = unit(10, "pt"),
      panel.spacing.x = unit(12, "pt"),
      panel.border  = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line     = element_line(colour = "gray60", linewidth = 0.3)
    )

  ggsave(outfile, p,
         width  = 9,
         height = max(5, ceiling(length(unique(dat$stratum_label)) / 2) * 3),
         limitsize  = FALSE,
         useDingbats = FALSE)
  if (verbose) message(sprintf("  ✓ Saved (retired orchard): %s", outfile))

  list(plot = p, info = list(
    rows_available = n_avail, rows_plotted = nrow(dat),
    x_min = t_xlim[1], x_max = t_xlim[2], y_min = -0.19, y_max = 0.19,
    n_inf = n_inf,
    inf_disposition = if (n_inf > 0L) "transformed_terminal_bin" else "none"
  ))
}


# ==============================================================================
# Entry point: corpus orchards (retired; explicit call only)
# ==============================================================================
# Reproduces the historical corpus_orchard_{effect,heterogeneity,bias}.pdf
# (evidence-axis transform). NOT emitted by build_corpus_visuals().
build_corpus_orchards <- function(output_dir = "output/overview",
                                  verbose = TRUE) {
  .ensure_orchard_runtime()
  vmsg <- function(...) if (verbose) message(...)
  vmsg("=== Retired orchard figures (evidence-axis transform) ===")
  vmsg("NOTE: orchards are a retired diagnostic; the active component-evidence",
       " displays are the display-capped raw-log10 violins (50/70).")

  reg <- .orchard_read_registry(output_dir, verbose)
  stratum_levels <- reg %>% distinct(stratum, stratum_label) %>%
    arrange(stratum) %>% pull(stratum_label)
  stratum_colors <- setNames(
    .orchard_tableau10[seq_along(stratum_levels) %%
                       length(.orchard_tableau10) + 1],
    stratum_levels)

  specs <- list(
    list(col = "log10BF_effect", title = "Pattern of effect evidence",
         file = "corpus_orchard_effect.pdf"),
    list(col = "log10BF_het",    title = "Pattern of heterogeneity evidence",
         file = "corpus_orchard_heterogeneity.pdf"),
    list(col = "log10BF_bias",   title = "Pattern of modeled bias evidence",
         file = "corpus_orchard_bias.pdf"))

  files <- character(0)
  for (sp in specs) {
    of <- file.path(output_dir, sp$file)
    .orchard_facet_plot(reg, sp$col, sp$title, of,
                        stratum_colors = stratum_colors, verbose = verbose)
    files <- c(files, of)
  }
  invisible(list(output_dir = output_dir, files = files))
}


# ==============================================================================
# Entry point: stratum orchard (retired; explicit call only)
# ==============================================================================
# Reproduces the historical <scope>_component_orchard.pdf 3x1 panel
# (evidence-axis transform). NOT emitted by build_stratum_visuals().
build_stratum_orchards <- function(stratum,
                                   output_dir = "output/overview",
                                   root = "output",
                                   source_article = NULL,
                                   variant = NULL,
                                   verbose = TRUE) {
  .ensure_orchard_runtime()
  vmsg <- function(...) if (verbose) message(...)

  reg  <- .orchard_read_registry(output_dir, verbose)
  slug <- norm_slug(stratum)
  reg  <- reg[norm_slug(reg$stratum) == slug, , drop = FALSE]
  if (nrow(reg) == 0L)
    stop(sprintf("No outcomes for stratum '%s' in the registry.", stratum),
         call. = FALSE)
  if (!is.null(source_article)) {
    reg <- reg[reg$source_article == source_article, , drop = FALSE]
    if (nrow(reg) == 0L)
      stop(sprintf("No outcomes for source_article '%s' in stratum '%s'.",
                   source_article, stratum), call. = FALSE)
  }
  if (!is.null(variant)) {
    reg <- reg[reg$analysis_variant == variant, , drop = FALSE]
    if (nrow(reg) == 0L)
      stop(sprintf("No '%s' outcomes for the requested stratum/source.",
                   variant), call. = FALSE)
  }

  if (!is.null(source_article)) {
    plots_dir  <- file.path(root, slug, source_article, "plots")
    scope_stem <- paste(slug, source_article, sep = "_")
    scope_lab  <- sprintf("%s — %s", format_stratum(slug), source_article)
  } else {
    plots_dir  <- file.path(root, slug, "plots")
    scope_stem <- slug
    scope_lab  <- format_stratum(slug)
  }
  dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

  all_bf <- c(reg$log10BF_effect, reg$log10BF_het, reg$log10BF_bias)
  t_xlim <- .compute_evidence_xlim(all_bf)
  ax     <- .bf_axis_spec(t_xlim)

  o_eff  <- .orchard_panel(reg, "log10BF_effect", "Effect evidence",
                           "#0072B2", t_xlim, ax)
  o_het  <- .orchard_panel(reg, "log10BF_het", "Heterogeneity evidence",
                           "#009E73", t_xlim, ax)
  o_bias <- .orchard_panel(reg, "log10BF_bias", "Modeled bias evidence",
                           "#D55E00", t_xlim, ax)

  np <- c(effect        = o_eff$info$rows_plotted,
          heterogeneity = o_het$info$rows_plotted,
          bias          = o_bias$info$rows_plotted)
  cap_txt <- "Bubbles = outcomes sized by precision (RETIRED diagnostic)"
  if (length(unique(np)) > 1L)
    cap_txt <- paste0(cap_txt, sprintf(paste0(
      "\nPanels show outcomes with a non-missing Bayes factor ",
      "(effect n=%d, heterogeneity n=%d, bias n=%d)"),
      np[["effect"]], np[["heterogeneity"]], np[["bias"]]))

  combined <- o_eff$plot / o_het$plot / o_bias$plot +
    plot_annotation(
      title = sprintf("Component Bayes factors — %s", scope_lab),
      caption = cap_txt,
      theme = theme(
        plot.title   = element_text(hjust = 0.5, size = 14, face = "bold",
                                    margin = margin(b = 10)),
        plot.caption = element_text(hjust = 0.5, size = 10, color = "gray40",
                                    margin = margin(t = 10))
      ))

  outfile <- file.path(plots_dir,
                        paste0(scope_stem, "_component_orchard.pdf"))
  ggsave(outfile, combined, width = 6, height = 10, device = "pdf",
         useDingbats = FALSE)
  if (verbose) message(sprintf("  ✓ Saved (retired orchard): %s", outfile))
  invisible(list(file = outfile))
}


# ==============================================================================
# CLI (explicit invocation only; plain source() stays define-only)
# ==============================================================================
# Rscript scripts/55_orchard_visuals.R --corpus
# Rscript scripts/55_orchard_visuals.R --stratum protein
if (sys.nframe() == 0L && !interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  arg_val <- function(flag) {
    i <- which(args == flag)
    if (length(i) > 0 && length(args) > i) args[i + 1] else NULL
  }
  if ("--corpus" %in% args) {
    build_corpus_orchards()
  } else {
    st <- arg_val("--stratum") %||% "protein"
    build_stratum_orchards(stratum = st,
                           source_article = arg_val("--source-article"),
                           variant = arg_val("--variant"))
  }
}


# Sentinel for symmetry with the rest of the pipeline.
.orchard_visuals_loaded <- TRUE
