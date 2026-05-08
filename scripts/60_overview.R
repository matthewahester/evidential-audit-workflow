# ==============================================================================
# 60_overview.R - Cross-topic overview analysis
# ==============================================================================
# Purpose: Auto-discover all per-topic RoBMA-PSMA summary CSVs (output/<topic>/
#          <topic>_robma_summary.csv) and produce the cross-topic overview
#          deliverables: orchard plots, paired baseline RE vs RoBMA-PSMA
#          boxplots, per-topic violin hybrid plots (standalone + stacked
#          full-page composite), a joint effect-vs-bias scatter, an
#          evidence-centred topic_summary.csv, and a supplement-ready
#          intervention-outcome dataset CSV plus LaTeX longtable fragment.
#
# Source-on-load behavior: defines `build_overview()` and helpers only.
# Sourcing this file does NOT scan output/, fit anything, or write files.
#
# Quick-Start
#   source("scripts/60_overview.R")
#   build_overview()                                  # default settings
#   build_overview(output_dir = "reports/overview")   # custom output dir
#   build_overview(verbose = FALSE)                   # quieter run
#   build_overview(strip_ylim_override = c(-0.05, 0.5))  # tighter strip y-axis
#
# Inputs (auto-discovered):
#   output/<topic>/<topic>_robma_summary.csv  for each per-topic fit
#
# Outputs (written to <output_dir>):
#   topic_summary.csv
#   intervention_outcome_datasets.csv
#   intervention_outcome_datasets_table.tex
#   orchard_{effect,heterogeneity,bias}.pdf
#   boxplot_combined_horizontal.pdf
#   boxplot_strip_single.pdf
#   violin_{effect,heterogeneity,bias}.pdf
#   violin_stack_fullpage.pdf  (+ .png companion when device available)
#   scatter_effect_vs_bias.pdf
# ==============================================================================

# --- Libraries ----------------------------------------------------------------
library(tidyverse)
library(fs)
library(patchwork)

# --- Shared helpers (00_utils.R) ----------------------------------------------
# Idempotent guarded source: provides `format_topic`, `.bf_evidence_transform`,
# `.bf_axis_spec`, `.compute_precision`, `is_meta_basename`, `%||%`.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R",
               "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}

# --- Module-level palette constant --------------------------------------------
# Tableau-inspired palette used to colour topics. Topics are mapped to colours
# in alphabetical order inside `build_overview()`.
.tableau10 <- c(
  "#263238",  # base charcoal
  "#1B5E20",  # plant green
  "#1B5E63",  # deep teal
  "#6D4C41",  # grain brown
  "#F9A825",  # micronutrient gold
  "#EF6C00",  # supplement orange
  "#8E24AA",  # metabolic purple
  "#0277BD",  # marine blue
  "#37474F"
)


# ==============================================================================
# File-scope helpers (define-only; no execution at source time)
# ==============================================================================

# Build and save one orchard plot using the piecewise evidence-axis transform.
# `topic_colors` is a named character vector mapping topic display label -> hex.
.orchard_facet_plot <- function(dat, bf_col, title, outfile,
                                topic_colors, verbose = TRUE) {

  dat <- dat %>%
    mutate(
      x_raw = .data[[bf_col]],
      x_t   = .bf_evidence_transform(x_raw)
    ) %>%
    filter(is.finite(x_t))

  if (nrow(dat) == 0L) {
    if (verbose) message(sprintf("  Warning: no valid %s data", bf_col))
    return(invisible(NULL))
  }

  dat <- .compute_precision(dat)

  # Capitalize topic names for display
  dat <- dat %>%
    mutate(topic = format_topic(topic))

  # jitter outcomes around the horizontal band y=0
  set.seed(7825)
  dat$y_jit <- runif(nrow(dat), -0.18, 0.18)

  # topic-level pooled mean, CI, PI (computed on transformed x)
  pool <- dat %>%
    group_by(topic) %>%
    summarize(
      n = n(),
      mean = mean(x_t, na.rm = TRUE),
      sd   = sd(x_t,   na.rm = TRUE),
      se   = if_else(n >= 2, sd/sqrt(n), NA_real_),
      ci_l = if_else(n >= 2, mean - 1.96*se, NA_real_),
      ci_u = if_else(n >= 2, mean + 1.96*se, NA_real_),
      pi_l = if_else(n >= 2, mean - 1.96*sd, NA_real_),
      pi_u = if_else(n >= 2, mean + 1.96*sd, NA_real_),
      .groups = "drop"
    )

  # stable size legend ticks - ensure 3 distinct values
  qs <- suppressWarnings(quantile(dat$prec, c(.10, .50, .90), na.rm = TRUE))
  if (any(!is.finite(qs))) qs <- rep(median(dat$prec, na.rm = TRUE), 3)

  br <- unique(round(qs, 1))
  if (length(br) < 3) br <- round(qs, 2)
  if (length(br) < 3) {
    prec_range <- range(dat$prec, na.rm = TRUE)
    br <- round(seq(prec_range[1], prec_range[2], length.out = 3), 1)
  }

  # --- X-axis limits in transformed space ---
  all_t <- dat$x_t[is.finite(dat$x_t)]
  if (length(all_t) > 0) {
    data_range <- range(all_t, na.rm = TRUE)
    range_width <- diff(data_range)
    padding <- max(0.15, range_width * 0.06)
    t_xlim <- c(data_range[1] - padding, data_range[2] + padding)
    t_xlim[1] <- max(t_xlim[1], -3.65)
    t_xlim[2] <- min(t_xlim[2],  3.65)
  } else {
    t_xlim <- c(-1, 1)
  }
  if (!all(is.finite(t_xlim))) t_xlim <- c(-1, 1)

  # Axis breaks and labels
  ax <- .bf_axis_spec(t_xlim)

  # Evidence band boundaries in transformed space
  band_edges <- .bf_evidence_transform(c(-2, -1, -log10(3), log10(3), 1, 2))
  be <- setNames(band_edges, c("m2", "m1", "m05", "p05", "p1", "p2"))

  # --- Build plot ---
  p <- ggplot(dat, aes(x = x_t))

  # Background evidence bands
  if (t_xlim[1] < be["m2"]) {
    p <- p + annotate("rect", xmin = t_xlim[1], xmax = min(t_xlim[2], be["m2"]),
                      ymin = -Inf, ymax = Inf, fill = "gray10", alpha = 0.2)
  }
  if (t_xlim[1] < be["m1"] && t_xlim[2] > be["m2"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["m2"]), xmax = min(t_xlim[2], be["m1"]),
                      ymin = -Inf, ymax = Inf, fill = "gray30", alpha = 0.2)
  }
  if (t_xlim[1] < be["m05"] && t_xlim[2] > be["m1"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["m1"]), xmax = min(t_xlim[2], be["m05"]),
                      ymin = -Inf, ymax = Inf, fill = "gray70", alpha = 0.2)
  }
  # Skip white/neutral region from BF=1/3 to BF=3
  if (t_xlim[1] < be["p1"] && t_xlim[2] > be["p05"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["p05"]), xmax = min(t_xlim[2], be["p1"]),
                      ymin = -Inf, ymax = Inf, fill = "gray70", alpha = 0.2)
  }
  if (t_xlim[1] < be["p2"] && t_xlim[2] > be["p1"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["p1"]), xmax = min(t_xlim[2], be["p2"]),
                      ymin = -Inf, ymax = Inf, fill = "gray30", alpha = 0.2)
  }
  if (t_xlim[2] > be["p2"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["p2"]), xmax = t_xlim[2],
                      ymin = -Inf, ymax = Inf, fill = "gray10", alpha = 0.2)
  }

  # Vertical guide lines at transformed threshold positions
  p <- p + geom_vline(xintercept = .bf_evidence_transform(0),
                      linetype = "solid", linewidth = 1.0, color = "gray20")

  # BF = 1/3 and 3 (dashed)
  for (lbf in c(-log10(3), log10(3))) {
    tv <- .bf_evidence_transform(lbf)
    if (tv >= t_xlim[1] && tv <= t_xlim[2]) {
      p <- p + geom_vline(xintercept = tv, linetype = "dashed",
                          linewidth = 0.8, color = "gray40")
    }
  }
  # BF = 1/100, 1/10, 10, 100 (dotted)
  for (lbf in c(-2, -1, 1, 2)) {
    tv <- .bf_evidence_transform(lbf)
    if (tv >= t_xlim[1] && tv <= t_xlim[2]) {
      p <- p + geom_vline(xintercept = tv, linetype = "dotted",
                          linewidth = 0.8, color = "gray50")
    }
  }

  p <- p +
    # outcome bubbles (size = precision, color = topic) — all circles now
    geom_point(aes(y = y_jit, size = prec, color = topic), alpha = 0.82, shape = 16) +

    facet_wrap(~ topic, scales = "free_y", ncol = 2, axes = "all_x") +
    scale_color_manual(values = topic_colors) +
    scale_size_continuous(
      name = "Precision (1/SE)",
      range = c(2.2, 10.5),
      breaks = br
    ) +
    guides(color = "none", size = "none") +

    coord_cartesian(xlim = t_xlim, ylim = c(-.19, .19), clip = "off") +
    scale_x_continuous(
      expand = c(0, 0),
      breaks = ax$breaks,
      labels = ax$labels
    ) +

    labs(
      title = title,
      subtitle = "Bubbles = outcomes sized by precision",
      x = "Bayes Factor", y = NULL
    ) +

    theme_minimal(base_size = 13) +
    theme(
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_blank(),
      strip.text = element_text(face = "bold", size = 11),
      axis.text.y  = element_blank(),
      axis.ticks.y = element_blank(),
      axis.text.x = element_text(size = 10),
      axis.ticks.x = element_line(color = "gray60"),
      legend.position = "bottom",
      legend.direction = "horizontal",
      plot.title = element_text(face = "bold", size = 12),
      plot.subtitle = element_text(size = 10, color = "gray50"),
      plot.margin = margin(12, 12, 6, 12),
      panel.spacing.y = unit(10, "pt"),
      panel.spacing.x = unit(12, "pt"),
      panel.border = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line = element_line(colour = "gray60", linewidth = 0.3)
    )

  ggsave(outfile, p,
         width = 9,
         height = max(5, ceiling(length(unique(dat$topic)) / 2) * 3),
         limitsize = FALSE,
         useDingbats = FALSE)
  if (verbose) message(sprintf("  \u2713 Saved: %s", outfile))
  invisible(p)
}

# Compute all evidence-bin metrics for a data frame slice.
# Variable names are the final column names — no renaming in the tibble.
#
# Column-naming convention (Option A):
#   n_log10BF_{axis}_{condition}        — count
#   prop_log10BF_{axis}_{condition}     — proportion (denominator = finite values on that axis)
# Thresholds:
#   abs_le_0.5 ≈ BF in [1/3, 3]  (inconclusive)
#   gt_0.5     ≈ BF > 3          (moderate)
#   gt_1       ≈ BF > 10         (strong)
#   lt_m0.5    ≈ BF < 1/3        (moderate for null)
#   lt_m1      ≈ BF < 1/10       (strong for null)
.evidence_bins <- function(df) {
  n <- nrow(df)
  sp <- function(k, d) if (d > 0L) round(k / d, 3) else NA_real_  # safe proportion

  # ---- finite-only vectors per BF axis (denominators for proportions) --------
  lbf_e <- df$logBF_effect[is.finite(df$logBF_effect)]
  lbf_b <- df$logBF_bias[is.finite(df$logBF_bias)]
  lbf_h <- df$logBF_heterogeneity[is.finite(df$logBF_heterogeneity)]
  ne <- length(lbf_e);  nb <- length(lbf_b);  nh <- length(lbf_h)

  # ---- Effect evidence counts ------------------------------------------------
  n_log10BF_effect_abs_le_0.5 <- sum(abs(lbf_e) <= 0.5)
  n_log10BF_effect_gt_0.5     <- sum(lbf_e >  0.5)
  n_log10BF_effect_lt_m0.5    <- sum(lbf_e < -0.5)
  n_log10BF_effect_gt_1       <- sum(lbf_e >  1.0)
  n_log10BF_effect_lt_m1      <- sum(lbf_e < -1.0)

  # ---- Effect evidence proportions -------------------------------------------
  prop_log10BF_effect_abs_le_0.5 <- sp(n_log10BF_effect_abs_le_0.5, ne)
  prop_log10BF_effect_gt_0.5     <- sp(n_log10BF_effect_gt_0.5,     ne)
  prop_log10BF_effect_lt_m0.5    <- sp(n_log10BF_effect_lt_m0.5,    ne)
  prop_log10BF_effect_gt_1       <- sp(n_log10BF_effect_gt_1,       ne)
  prop_log10BF_effect_lt_m1      <- sp(n_log10BF_effect_lt_m1,      ne)

  # ---- Bias-adjustment evidence counts + proportions -------------------------
  n_log10BF_bias_gt_0.5    <- sum(lbf_b > 0.5)
  n_log10BF_bias_gt_1      <- sum(lbf_b > 1.0)
  prop_log10BF_bias_gt_0.5 <- sp(n_log10BF_bias_gt_0.5, nb)
  prop_log10BF_bias_gt_1   <- sp(n_log10BF_bias_gt_1,   nb)

  # ---- Heterogeneity evidence counts + proportions ---------------------------
  n_log10BF_het_gt_0.5    <- sum(lbf_h > 0.5)
  n_log10BF_het_gt_1      <- sum(lbf_h > 1.0)
  prop_log10BF_het_gt_0.5 <- sp(n_log10BF_het_gt_0.5, nh)
  prop_log10BF_het_gt_1   <- sp(n_log10BF_het_gt_1,   nh)

  # ---- Claimed-effect anchor -------------------------------------------------
  ok_claimed <- is.finite(df$mu_RE) & is.finite(df$mu_BC) &
    is.finite(df$logBF_effect)
  claimed <- ok_claimed & (abs(df$mu_RE) >= 0.2)

  n_abs_muRE_ge_0.2    <- sum(claimed)
  prop_abs_muRE_ge_0.2 <- sp(n_abs_muRE_ge_0.2, sum(ok_claimed))

  if (n_abs_muRE_ge_0.2 > 0L) {
    cdf <- df[claimed, ]
    prop_claimed_shrink50 <-
      sp(sum(abs(cdf$mu_BC) <= 0.5 * abs(cdf$mu_RE)), n_abs_muRE_ge_0.2)
    prop_claimed_log10BF_effect_abs_le_0.5 <-
      sp(sum(abs(cdf$logBF_effect) <= 0.5),            n_abs_muRE_ge_0.2)
  } else {
    prop_claimed_shrink50                  <- NA_real_
    prop_claimed_log10BF_effect_abs_le_0.5 <- NA_real_
  }

  # ---- Signature: bias moderate AND effect inconclusive ----------------------
  joint_ok <- is.finite(df$logBF_bias) & is.finite(df$logBF_effect)
  n_joint  <- sum(joint_ok)
  prop_sig_log10BF_bias_gt_0.5_and_log10BF_effect_abs_le_0.5 <-
    sp(sum((df$logBF_bias[joint_ok] > 0.5) &
             (abs(df$logBF_effect[joint_ok]) <= 0.5)),
       n_joint)

  # ---- Assemble tibble (names already correct) -------------------------------
  tibble(
    n_outcomes = n,
    # effect
    n_log10BF_effect_abs_le_0.5,
    prop_log10BF_effect_abs_le_0.5,
    n_log10BF_effect_gt_0.5,
    prop_log10BF_effect_gt_0.5,
    n_log10BF_effect_lt_m0.5,
    prop_log10BF_effect_lt_m0.5,
    n_log10BF_effect_gt_1,
    prop_log10BF_effect_gt_1,
    n_log10BF_effect_lt_m1,
    prop_log10BF_effect_lt_m1,
    # bias
    n_log10BF_bias_gt_0.5,
    prop_log10BF_bias_gt_0.5,
    n_log10BF_bias_gt_1,
    prop_log10BF_bias_gt_1,
    # heterogeneity
    n_log10BF_het_gt_0.5,
    prop_log10BF_het_gt_0.5,
    n_log10BF_het_gt_1,
    prop_log10BF_het_gt_1,
    # claimed-effect anchor
    n_abs_muRE_ge_0.2,
    prop_abs_muRE_ge_0.2,
    prop_claimed_shrink50,
    prop_claimed_log10BF_effect_abs_le_0.5,
    # signature
    prop_sig_log10BF_bias_gt_0.5_and_log10BF_effect_abs_le_0.5
  )
}

# Escape characters with LaTeX-special meaning. The backslash replacement
# `\textbackslash{}` itself contains braces, which the later { / } passes
# would double-escape, so we route backslashes through a sentinel that
# contains no LaTeX-special characters and restore them at the end.
.latex_escape <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  BSL <- "\001BACKSLASH\001"
  x <- gsub("\\", BSL,                    x, fixed = TRUE)
  x <- gsub("&",  "\\&",                  x, fixed = TRUE)
  x <- gsub("%",  "\\%",                  x, fixed = TRUE)
  x <- gsub("$",  "\\$",                  x, fixed = TRUE)
  x <- gsub("#",  "\\#",                  x, fixed = TRUE)
  x <- gsub("_",  "\\_",                  x, fixed = TRUE)
  x <- gsub("{",  "\\{",                  x, fixed = TRUE)
  x <- gsub("}",  "\\}",                  x, fixed = TRUE)
  x <- gsub("~",  "\\textasciitilde{}",   x, fixed = TRUE)
  x <- gsub("^",  "\\textasciicircum{}",  x, fixed = TRUE)
  x <- gsub(BSL,  "\\textbackslash{}",    x, fixed = TRUE)
  x
}

# Format a numeric vector to fixed decimals; non-finite/NA -> "---".
.fmt_num <- function(x, digits) {
  if (is.null(x)) return(character(0))
  ifelse(is.na(x) | !is.finite(x), "---",
         formatC(x, format = "f", digits = digits))
}

# Reshape outcome-level BF data to long format
.compute_topic_bf_long <- function(dat) {
  dat %>%
    mutate(topic_display = format_topic(topic)) %>%
    select(topic_display, author, effect,
           logBF_effect, logBF_heterogeneity, logBF_bias) %>%
    pivot_longer(
      cols = starts_with("logBF_"),
      names_to = "bf_type",
      names_prefix = "logBF_",
      values_to = "logBF"
    ) %>%
    filter(is.finite(logBF))
}

# Compute topic-level summary stats for violin overlay
.compute_topic_bf_summary <- function(long_dat) {
  long_dat %>%
    group_by(topic_display, bf_type) %>%
    summarize(
      n_outcomes = n(),
      median_logBF = median(logBF, na.rm = TRUE),
      q10_logBF = quantile(logBF, 0.10, na.rm = TRUE),
      q25_logBF = quantile(logBF, 0.25, na.rm = TRUE),
      q75_logBF = quantile(logBF, 0.75, na.rm = TRUE),
      q90_logBF = quantile(logBF, 0.90, na.rm = TRUE),
      .groups = "drop"
    )
}

# Build (and optionally save) a single violin hybrid plot.
# Returns the ggplot object invisibly so it can be composed by patchwork.
# The optional override arguments are used by the stacked full-page figure to
# enforce a common x-axis range, a fixed topic order, and per-panel formatting.
# `style` is a named list of visual-density knobs; defaults reproduce the
# standalone-plot look. The stacked figure passes a denser style profile.
# `topic_colors` is a named character vector mapping topic display label -> hex.
.topic_violin_plot <- function(long_dat, summary_dat, bf_type_filter,
                               title, outfile = NULL,
                               topic_colors,
                               topic_order_override = NULL,
                               t_xlim_override = NULL,
                               show_x_axis = TRUE,
                               subtitle = paste0(
                                 "Violin = outcome distribution; point = median; ",
                                 "thick bar = IQR; whiskers = 10\u201390%"
                               ),
                               save = TRUE,
                               style = list(),
                               verbose = TRUE) {

  # Visual-density defaults (match the standalone-plot look). The `style` arg
  # can override any subset; missing entries fall back to these values.
  default_style <- list(
    point_size        = 0.8,
    point_alpha       = 1.0,
    violin_alpha      = 0.28,
    iqr_linewidth     = 3.0,
    iqr_alpha         = 0.8,
    whisker_linewidth = 0.7,
    whisker_alpha     = 0.7,
    median_size_outer = 3.0,
    median_size_inner = 2.0,
    y_text_size       = 11,
    title_size        = 12,
    plot_margin       = margin(12, 12, 6, 12)
  )
  st <- modifyList(default_style, as.list(style))

  # Filter to this bf_type
  vdat <- long_dat %>% filter(bf_type == bf_type_filter)
  sdat <- summary_dat %>% filter(bf_type == bf_type_filter)

  if (nrow(vdat) == 0) {
    if (verbose) message(sprintf("  Warning: no data for bf_type = %s", bf_type_filter))
    return(invisible(NULL))
  }

  # Transform all values to the evidence axis
  vdat <- vdat %>% mutate(x_t = .bf_evidence_transform(logBF))
  sdat <- sdat %>% mutate(
    median_t = .bf_evidence_transform(median_logBF),
    q10_t    = .bf_evidence_transform(q10_logBF),
    q25_t    = .bf_evidence_transform(q25_logBF),
    q75_t    = .bf_evidence_transform(q75_logBF),
    q90_t    = .bf_evidence_transform(q90_logBF)
  )

  # Order topics: use override if provided (used by the stacked figure to
  # lock topic position across all three panels); otherwise order by ascending
  # median for this BF type so the highest-median topic sits at the top.
  if (!is.null(topic_order_override)) {
    topic_order <- topic_order_override[topic_order_override %in% sdat$topic_display]
  } else {
    topic_order <- sdat %>%
      arrange(median_t) %>%
      pull(topic_display)
  }

  # Build labels with n
  label_map <- sdat %>%
    mutate(topic_label = paste0(topic_display, " (n=", n_outcomes, ")"))
  label_levels <- label_map %>%
    mutate(topic_display = factor(topic_display, levels = topic_order)) %>%
    arrange(topic_display) %>%
    pull(topic_label)

  # Apply factor ordering
  vdat <- vdat %>%
    left_join(label_map %>% select(topic_display, topic_label),
              by = "topic_display") %>%
    mutate(topic_label = factor(topic_label, levels = label_levels))

  sdat <- sdat %>%
    left_join(label_map %>% select(topic_display, topic_label) %>% distinct(),
              by = "topic_display") %>%
    mutate(topic_label = factor(topic_label, levels = label_levels))

  n_topics <- n_distinct(vdat$topic_display)

  # --- X-axis limits in transformed space ---
  # Use override if provided (the stacked figure passes a common range across
  # all three components); otherwise use this panel's data range with padding,
  # capped at the piecewise terminal bounds (\u00b13.65).
  if (!is.null(t_xlim_override)) {
    t_xlim <- t_xlim_override
  } else {
    all_t <- vdat$x_t[is.finite(vdat$x_t)]
    if (length(all_t) == 0) {
      t_xlim <- c(-1, 1)
    } else {
      data_range <- range(all_t, na.rm = TRUE)
      range_width <- diff(data_range)
      padding <- max(0.15, range_width * 0.06)
      t_xlim <- c(data_range[1] - padding, data_range[2] + padding)
      # Clamp to piecewise terminal bounds
      t_xlim[1] <- max(t_xlim[1], -3.65)
      t_xlim[2] <- min(t_xlim[2],  3.65)
    }
  }
  if (!all(is.finite(t_xlim))) t_xlim <- c(-1, 1)

  # Get axis spec
  ax <- .bf_axis_spec(t_xlim)

  # --- Evidence band boundaries in transformed space ---
  # Map the log10(BF) threshold boundaries through the transform
  band_edges <- .bf_evidence_transform(c(-2, -1, -log10(3), log10(3), 1, 2))
  # Named for clarity
  be <- setNames(band_edges, c("m2", "m1", "m05", "p05", "p1", "p2"))

  # --- Build plot ---
  p <- ggplot(vdat, aes(x = x_t, y = topic_label))

  # Background evidence bands (using transformed boundaries)
  if (t_xlim[1] < be["m2"]) {
    p <- p + annotate("rect", xmin = t_xlim[1], xmax = min(t_xlim[2], be["m2"]),
                      ymin = -Inf, ymax = Inf, fill = "gray10", alpha = 0.2)
  }
  if (t_xlim[1] < be["m1"] && t_xlim[2] > be["m2"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["m2"]), xmax = min(t_xlim[2], be["m1"]),
                      ymin = -Inf, ymax = Inf, fill = "gray30", alpha = 0.2)
  }
  if (t_xlim[1] < be["m05"] && t_xlim[2] > be["m1"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["m1"]), xmax = min(t_xlim[2], be["m05"]),
                      ymin = -Inf, ymax = Inf, fill = "gray70", alpha = 0.2)
  }
  # Skip white/neutral region from BF=1/3 to BF=3
  if (t_xlim[1] < be["p1"] && t_xlim[2] > be["p05"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["p05"]), xmax = min(t_xlim[2], be["p1"]),
                      ymin = -Inf, ymax = Inf, fill = "gray70", alpha = 0.2)
  }
  if (t_xlim[1] < be["p2"] && t_xlim[2] > be["p1"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["p1"]), xmax = min(t_xlim[2], be["p2"]),
                      ymin = -Inf, ymax = Inf, fill = "gray30", alpha = 0.2)
  }
  if (t_xlim[2] > be["p2"]) {
    p <- p + annotate("rect", xmin = max(t_xlim[1], be["p2"]), xmax = t_xlim[2],
                      ymin = -Inf, ymax = Inf, fill = "gray10", alpha = 0.2)
  }

  # Vertical guide lines at transformed threshold positions
  t_zero <- .bf_evidence_transform(0)
  p <- p + geom_vline(xintercept = t_zero, linetype = "solid",
                      linewidth = 1.0, color = "gray20")

  # BF = 1/3 and 3 (dashed)
  for (lbf in c(-log10(3), log10(3))) {
    tv <- .bf_evidence_transform(lbf)
    if (tv >= t_xlim[1] && tv <= t_xlim[2]) {
      p <- p + geom_vline(xintercept = tv, linetype = "dashed",
                          linewidth = 0.8, color = "gray40")
    }
  }
  # BF = 1/100, 1/10, 10, 100 (dotted)
  for (lbf in c(-2, -1, 1, 2)) {
    tv <- .bf_evidence_transform(lbf)
    if (tv >= t_xlim[1] && tv <= t_xlim[2]) {
      p <- p + geom_vline(xintercept = tv, linetype = "dotted",
                          linewidth = 0.8, color = "gray50")
    }
  }

  # Violin bodies — per-topic color
  p <- p +
    geom_violin(
      aes(fill = topic_label),
      color = "gray40", linewidth = 0.3,
      alpha = st$violin_alpha, scale = "width",
      trim = TRUE, adjust = 1.2,
      show.legend = FALSE
    )

  # Build fill color map keyed by topic_label
  violin_fill_colors <- label_map %>%
    mutate(color = topic_colors[as.character(topic_display)]) %>%
    { setNames(.$color, .$topic_label) }

  p <- p + scale_fill_manual(values = violin_fill_colors)

  # Subtle outcome-level points
  set.seed(3947)
  p <- p +
    geom_jitter(
      aes(color = topic_label),
      height = 0.12, width = 0,
      size = st$point_size, alpha = st$point_alpha,
      show.legend = FALSE
    ) +
    scale_color_manual(values = violin_fill_colors)

  # Summary overlay: whiskers (q10–q90), IQR bar, median point
  p <- p +
    geom_segment(
      data = sdat,
      aes(x = q10_t, xend = q90_t,
          y = topic_label, yend = topic_label),
      color = "gray20",
      linewidth = st$whisker_linewidth, alpha = st$whisker_alpha
    ) +
    geom_segment(
      data = sdat,
      aes(x = q25_t, xend = q75_t,
          y = topic_label, yend = topic_label),
      color = "gray15",
      linewidth = st$iqr_linewidth, alpha = st$iqr_alpha
    ) +
    geom_point(
      data = sdat,
      aes(x = median_t, y = topic_label),
      color = "white", size = st$median_size_outer, shape = 16
    ) +
    geom_point(
      data = sdat,
      aes(x = median_t, y = topic_label),
      color = "gray10", size = st$median_size_inner, shape = 16
    )

  # Axis and theme
  p <- p +
    coord_cartesian(xlim = t_xlim, clip = "off") +
    scale_x_continuous(
      expand = c(0, 0),
      breaks = ax$breaks,
      labels = ax$labels
    ) +
    labs(
      title = title,
      subtitle = subtitle,
      x = "Bayes Factor",
      y = NULL
    ) +
    theme_minimal(base_size = 13) +
    theme(
      panel.grid.minor   = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_blank(),
      axis.text.y  = element_text(face = "bold", size = st$y_text_size),
      axis.ticks.y = element_blank(),
      axis.text.x  = element_text(size = 10),
      axis.ticks.x = element_line(color = "gray60"),
      legend.position = "none",
      plot.title    = element_text(face = "bold", size = st$title_size),
      plot.subtitle = element_text(size = 9, color = "gray50"),
      plot.margin   = st$plot_margin,
      panel.border  = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line     = element_line(colour = "gray60", linewidth = 0.3)
    )

  # Optional: suppress x-axis title, tick labels, and ticks. Used by the
  # stacked figure so that only the bottom panel carries the BF axis.
  if (!show_x_axis) {
    p <- p + theme(
      axis.title.x = element_blank(),
      axis.text.x  = element_blank(),
      axis.ticks.x = element_blank()
    )
  }

  # Save (skipped when this plot is being composed into a larger figure)
  if (save && !is.null(outfile)) {
    plot_height <- max(4.5, 0.7 * n_topics + 1.5)
    ggsave(outfile, p,
           width = 9, height = plot_height,
           limitsize = FALSE, useDingbats = FALSE)
    if (verbose) message(sprintf("  \u2713 Saved: %s", outfile))
  }

  invisible(p)
}


# ==============================================================================
# Entry point: build_overview()
# ==============================================================================
# Discovers per-topic summaries, builds all overview deliverables, and writes
# them to `output_dir`. No file I/O happens until this function is called.
#
# Args:
#   output_dir          - directory for all generated files (created if absent)
#   strip_ylim_override - c(lo, hi) hard-coded y-axis range for the
#                         single-strip boxplot; NULL = auto whisker-based.
#                         Default c(-0.05, 0.7) keeps the historical look.
#   horiz_xlim_override - c(lo, hi) hard-coded x-axis range for the horizontal
#                         combined boxplot; NULL = auto.
#   verbose             - print per-step progress messages
# ==============================================================================
build_overview <- function(output_dir = "output/overview",
                           strip_ylim_override = c(-0.05, 0.7),
                           horiz_xlim_override = NULL,
                           verbose = TRUE) {

  vmsg <- function(...) if (verbose) message(...)

  dir_create(output_dir)

  vmsg("=== Nutrition-Wide Overview Analysis ===\n")

  # --- Discover summary files -------------------------------------------------
  vmsg("Discovering per-topic summary files...")

  # Find all *_robma_summary.csv files, excluding output/overview/ itself.
  summary_files <- dir_ls(
    "output",
    recurse = TRUE,
    regexp = "_robma_summary\\.csv$"
  ) %>%
    str_subset("output/overview", negate = TRUE)

  if (length(summary_files) == 0) {
    stop("No summary files found. Expected files like output/<topic>/<topic>_robma_summary.csv")
  }

  vmsg(sprintf("Found %d summary file(s):\n  %s\n",
               length(summary_files),
               paste(summary_files, collapse = "\n  ")))

  # --- Read and merge data ----------------------------------------------------
  vmsg("Reading and merging data...")

  all_data <- map_dfr(summary_files, function(file_path) {
    # Extract topic_slug from parent directory name
    topic_slug <- path_file(path_dir(file_path))

    # Read CSV
    df <- read_csv(file_path, show_col_types = FALSE)

    # Add topic identifier if not present
    if (!"topic" %in% names(df)) {
      df <- df %>% mutate(topic = topic_slug, .before = 1)
    }

    df
  })

  vmsg(sprintf("Merged %d rows from %d topics\n",
               nrow(all_data),
               n_distinct(all_data$topic)))

  # --- Deterministic topic colors --------------------------------------------
  # Get canonical topic labels (match the Title Case step used in plotting)
  topic_levels <- all_data %>%
    mutate(topic = format_topic(topic)) %>%
    distinct(topic) %>%
    arrange(topic) %>%
    pull(topic)

  topic_colors <- setNames(
    .tableau10[seq_along(topic_levels) %% length(.tableau10) + 1],
    topic_levels
  )

  # --- Compute derived metrics ------------------------------------------------
  vmsg("Computing derived metrics...")

  all_data <- all_data %>%
    mutate(
      # Log10 Bayes Factors from RoBMA-PSMA bias-adjusted fits
      # (eff_bf_BC / het_bf_BC / bias_bf_BC are upstream column names; "BC" is
      # retained as a data-column suffix only)
      logBF_effect        = log10(pmax(eff_bf_BC,  1e-10)),
      logBF_heterogeneity = log10(pmax(het_bf_BC,  1e-10)),
      logBF_bias          = log10(pmax(bias_bf_BC, 1e-10)),

      # Change in effect size: baseline RE -> RoBMA-PSMA (bias-adjusted)
      change = mu_BC - mu_RE,

      # Percent change (avoid division by zero)
      pct_change = if_else(abs(mu_RE) > 1e-8,
                           100 * change / abs(mu_RE),
                           NA_real_),

      # Direction flip indicator
      flip = (mu_RE * mu_BC < 0) & !is.na(mu_RE) & !is.na(mu_BC),

      # Create outcome label for plotting
      outcome_label = paste0(author, ": ", effect)
    )

  # --- Orchard plots ----------------------------------------------------------
  vmsg("Creating orchard plots for log10 Bayes Factors...")

  .orchard_facet_plot(all_data, "logBF_effect",
                      "Pattern of effect evidence",
                      file.path(output_dir, "orchard_effect.pdf"),
                      topic_colors = topic_colors, verbose = verbose)

  .orchard_facet_plot(all_data, "logBF_heterogeneity",
                      "Pattern of heterogeneity evidence",
                      file.path(output_dir, "orchard_heterogeneity.pdf"),
                      topic_colors = topic_colors, verbose = verbose)

  .orchard_facet_plot(all_data, "logBF_bias",
                      "Pattern of bias evidence",
                      file.path(output_dir, "orchard_bias.pdf"),
                      topic_colors = topic_colors, verbose = verbose)

  # --- Combined horizontal boxplot --------------------------------------------
  # Paired baseline RE vs RoBMA-PSMA effect sizes, all topics on one plot.
  # Topic-colored boxes with baseline RE on top (solid) and RoBMA-PSMA below (faded)
  vmsg("\nCreating combined baseline-vs-RoBMA-PSMA boxplot...")

  # Prepare long-format data for boxplots
  box_data <- all_data %>%
    filter(is.finite(mu_RE) & is.finite(mu_BC)) %>%
    mutate(topic_display = format_topic(topic))

  # Paired long format for geom_boxplot
  # Factor levels: RoBMA-PSMA first so position_dodge puts Baseline RE on top
  box_long <- box_data %>%
    select(topic_display, author, effect, mu_RE, mu_BC) %>%
    pivot_longer(
      cols = c(mu_RE, mu_BC),
      names_to  = "Method",
      values_to = "Estimate"
    ) %>%
    mutate(
      Method = factor(
        ifelse(Method == "mu_RE", "Baseline RE", "RoBMA-PSMA"),
        levels = c("RoBMA-PSMA", "Baseline RE")
      )
    )

  # Order topics alphabetically (consistent with orchard panels)
  topic_order_box <- sort(unique(box_data$topic_display))

  box_long <- box_long %>%
    mutate(topic_display = factor(topic_display, levels = topic_order_box))

  box_data <- box_data %>%
    mutate(topic_display = factor(topic_display, levels = topic_order_box))

  # Generate consistent jitter per outcome (same jitter for RE and BC of the same pair)
  set.seed(9182)
  box_data <- box_data %>%
    mutate(jitter = runif(n(), -0.08, 0.08))

  n_topics_box <- length(topic_order_box)

  # Compute effect-size axis limits from per-topic boxplot whisker extents + 20% padding
  # Each topic×method group has its own whiskers; we find the global extent
  whisker_extremes <- box_long %>%
    group_by(topic_display, Method) %>%
    summarize(
      q1 = quantile(Estimate, 0.25, na.rm = TRUE),
      q3 = quantile(Estimate, 0.75, na.rm = TRUE),
      iqr = q3 - q1,
      w_lo = min(Estimate[Estimate >= q1 - 1.5 * iqr], na.rm = TRUE),
      w_hi = max(Estimate[Estimate <= q3 + 1.5 * iqr], na.rm = TRUE),
      .groups = "drop"
    )
  whisker_lo   <- min(whisker_extremes$w_lo, na.rm = TRUE)
  whisker_hi   <- max(whisker_extremes$w_hi, na.rm = TRUE)
  whisker_span <- whisker_hi - whisker_lo
  es_lim <- c(whisker_lo - 0.025 * whisker_span, whisker_hi + 0.025 * whisker_span)

  # --- Resolve effect-size axis overrides -----------------------------------
  # Each plot resolves to an auto whisker-based es_lim by default. To hard-code
  # a tighter (or wider) range, the corresponding *_override argument can be
  # set to c(lo, hi); leaving it NULL keeps the auto behavior.
  #   horiz_xlim_override -> x-axis of boxplot_combined_horizontal.pdf
  #   strip_ylim_override -> y-axis of boxplot_strip_single.pdf
  # Caveat: jittered outcome points beyond the limits will be clipped silently
  # (boxplot whiskers are drawn with outlier.shape = NA, but the point overlay
  # still draws every (mu_RE, mu_BC) — so a tight override can hide outliers).
  horiz_xlim <- if (is.null(horiz_xlim_override)) es_lim else horiz_xlim_override
  strip_ylim <- if (is.null(strip_ylim_override)) es_lim else strip_ylim_override

  # Compute numeric y positions for the paired segments
  # Must match scale_y_discrete(limits = rev(topic_order_box)) ordering
  topic_nums <- setNames(seq_along(rev(topic_order_box)), rev(topic_order_box))

  box_data_h <- box_data %>%
    mutate(
      y_orig = topic_nums[as.character(topic_display)] + 0.15 + jitter * 0.8,
      y_bc   = topic_nums[as.character(topic_display)] - 0.15 + jitter * 0.8
    )

  # Build per-topic fill colors: each Method box uses the topic's orchard color
  # We create an interaction factor and map it to colors
  box_long <- box_long %>%
    mutate(
      topic_method = interaction(topic_display, Method, sep = "___")
    )

  topic_method_colors <- box_long %>%
    distinct(topic_display, topic_method) %>%
    mutate(color = topic_colors[as.character(topic_display)]) %>%
    { setNames(.$color, .$topic_method) }

  p_box_h <- ggplot() +
    # Zero reference line
    geom_vline(xintercept = 0, linetype = "dashed", color = "grey30", linewidth = 0.5) +
    # Boxplots: dodge within each topic, colored by topic
    geom_boxplot(
      data = box_long,
      aes(y = topic_display, x = Estimate, fill = topic_method,
          alpha = Method, group = topic_method),
      width = 0.55, outlier.shape = NA,
      position = position_dodge(width = 0.7)
    ) +
    # Paired connecting lines
    geom_segment(
      data = box_data_h,
      aes(y = y_orig, yend = y_bc,
          x = mu_RE, xend = mu_BC),
      color = "gray40", alpha = 0.35, linewidth = 0.3
    ) +
    # Baseline RE points (top)
    geom_point(
      data = box_data_h,
      aes(y = y_orig, x = mu_RE),
      color = "black", size = 1.2, alpha = 0.5
    ) +
    # RoBMA-PSMA points (bottom)
    geom_point(
      data = box_data_h,
      aes(y = y_bc, x = mu_BC),
      color = "black", size = 1.2, alpha = 0.5
    ) +
    scale_fill_manual(values = topic_method_colors, guide = "none") +
    scale_alpha_manual(
      values = c("Baseline RE" = 0.75, "RoBMA-PSMA" = 0.45),
      labels = c("Baseline RE", "RoBMA-PSMA"),
      guide = guide_legend(override.aes = list(fill = "gray50"))
    ) +
    scale_y_discrete(limits = rev(topic_order_box)) +
    scale_x_continuous(expand = c(0, 0)) +
    coord_cartesian(xlim = horiz_xlim) +
    labs(
      title = "Meta-analysis effect sizes \u2014 All topics",
      subtitle = "Baseline RE vs RoBMA-PSMA; solid = baseline RE, faded = RoBMA-PSMA",
      x = "Standardized Effect Size",
      y = NULL,
      alpha = NULL
    ) +
    theme_minimal(base_size = 13) +
    theme(
      plot.title    = element_text(face = "bold", size = 13),
      plot.subtitle = element_text(color = "gray40", size = 10),
      axis.text.y   = element_text(face = "bold", size = 11),
      legend.position = "bottom",
      legend.direction = "horizontal",
      legend.text   = element_text(size = 10),
      panel.border  = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line     = element_line(colour = "gray60", linewidth = 0.3)
    )

  box_h_height <- max(5, n_topics_box * 1.0 + 2)

  ggsave(file.path(output_dir, "boxplot_combined_horizontal.pdf"),
         p_box_h, width = 10, height = box_h_height,
         limitsize = FALSE, useDingbats = FALSE)
  vmsg(sprintf("  \u2713 Saved: %s", file.path(output_dir, "boxplot_combined_horizontal.pdf")))

  # --- Single-strip boxplot (descending median) -------------------------------
  vmsg("\nCreating single-strip boxplot (topics ordered by descending median baseline RE estimate)...")

  # Compute median baseline RE estimate per topic for ordering
  topic_median_es <- box_data %>%
    group_by(topic_display) %>%
    summarize(med_es = median(mu_RE, na.rm = TRUE), .groups = "drop") %>%
    arrange(desc(med_es))

  topic_order_desc <- topic_median_es$topic_display

  # Re-level for this plot \u2014 Baseline RE first so dodge puts it on the left
  box_long_desc <- box_long %>%
    mutate(
      topic_display = factor(topic_display, levels = topic_order_desc),
      Method = factor(Method, levels = c("Baseline RE", "RoBMA-PSMA"))
    )

  # Compute numeric x positions for paired segments (vertical orientation)
  # Factor levels go 1..n left-to-right matching topic_order_desc
  topic_nums_v <- setNames(seq_along(topic_order_desc), topic_order_desc)

  # position_dodge(width=0.7) with 2 groups offsets each ±0.175 from center
  # Factor levels: "Baseline RE" first (left), "RoBMA-PSMA" second (right)
  box_data_v <- box_data %>%
    mutate(
      topic_display = factor(topic_display, levels = topic_order_desc),
      x_orig = topic_nums_v[as.character(topic_display)] - 0.175 + jitter * 0.8,
      x_bc   = topic_nums_v[as.character(topic_display)] + 0.175 + jitter * 0.8
    )

  p_box_strip <- ggplot() +
    geom_hline(yintercept = 0, linetype = "dashed", color = "grey30", linewidth = 0.5) +
    geom_boxplot(
      data = box_long_desc,
      aes(x = topic_display, y = Estimate, fill = topic_display,
          alpha = Method, group = interaction(topic_display, Method)),
      width = 0.6, outlier.shape = NA,
      position = position_dodge(width = 0.7)
    ) +
    # Paired connecting lines
    geom_segment(
      data = box_data_v,
      aes(x = x_orig, xend = x_bc,
          y = mu_RE, yend = mu_BC),
      color = "gray40", alpha = 0.35, linewidth = 0.3
    ) +
    # Baseline RE points (left/dodge position)
    geom_point(
      data = box_data_v,
      aes(x = x_orig, y = mu_RE),
      color = "black", size = 1.2, alpha = 0.5
    ) +
    # RoBMA-PSMA points (right/dodge position)
    geom_point(
      data = box_data_v,
      aes(x = x_bc, y = mu_BC),
      color = "black", size = 1.2, alpha = 0.5
    ) +
    scale_fill_manual(values = topic_colors, guide = "none") +
    scale_alpha_manual(
      values = c("Baseline RE" = 0.75, "RoBMA-PSMA" = 0.40),
      labels = c("Baseline RE", "RoBMA-PSMA"),
      guide  = guide_legend(override.aes = list(fill = "gray50"))
    ) +
    scale_y_continuous(expand = c(0, 0)) +
    coord_cartesian(ylim = strip_ylim) +
    labs(
      title    = "Meta-analysis effect sizes \u2014 All topics",
      subtitle = "Topics ordered by descending median baseline RE estimate; solid = baseline RE, faded = RoBMA-PSMA",
      y = "Standardized Effect Size",
      x = NULL,
      alpha = NULL
    ) +
    theme_minimal(base_size = 13) +
    theme(
      plot.title      = element_text(face = "bold", size = 13),
      plot.subtitle   = element_text(color = "gray40", size = 10),
      axis.text.x     = element_text(face = "bold", size = 10, angle = 45, hjust = 1, vjust = 1),
      legend.position = "bottom",
      legend.direction = "horizontal",
      legend.text     = element_text(size = 10),
      panel.border    = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line       = element_line(colour = "gray60", linewidth = 0.3)
    )

  strip_w <- max(6, n_topics_box * 0.9 + 1.5)
  strip_h <- 1 * strip_w

  ggsave(file.path(output_dir, "boxplot_strip_single.pdf"),
         p_box_strip, width = strip_w, height = strip_h,
         limitsize = FALSE, useDingbats = FALSE)
  vmsg(sprintf("  \u2713 Saved: %s", file.path(output_dir, "boxplot_strip_single.pdf")))

  # --- Topic evidence summary -------------------------------------------------
  # Single evidence-centred CSV: <output_dir>/topic_summary.csv
  vmsg("\nComputing topic-level evidence summary...")

  # Per-topic rows
  topic_rows <- all_data %>%
    mutate(topic = format_topic(topic)) %>%
    group_by(topic) %>%
    group_modify(~ .evidence_bins(.x)) %>%
    ungroup()

  # Overall row
  overall_row <- .evidence_bins(all_data) %>%
    mutate(topic = "Overall", .before = 1)

  # Combine and write
  topic_summary <- bind_rows(topic_rows, overall_row)

  summary_csv_path <- path(output_dir, "topic_summary.csv")
  write_csv(topic_summary, summary_csv_path)
  vmsg(sprintf("\u2713 Saved topic evidence summary: %s", summary_csv_path))

  if (verbose) {
    message("\nTopic Evidence Summary:")
    print(topic_summary, n = Inf, width = Inf)
  }

  # --- Intervention-outcome dataset table -------------------------------------
  # Supplement-ready listing of every analyzed intervention-outcome dataset
  # included in the audit. One row per (topic, meta_analysis, outcome).
  # Foregrounds the Bayes-factor trio (effect, heterogeneity, bias) and the
  # bias-adjusted effect estimate; all raw BFs, MCMC settings, paths, and
  # timestamps are intentionally excluded.
  vmsg("\nBuilding intervention-outcome dataset table...")

  # Defensive: required columns must exist in the merged frame.
  required_io_cols <- c("topic", "author", "effect", "n_studies",
                        "logBF_effect", "logBF_heterogeneity", "logBF_bias",
                        "mu_BC")
  missing_io_cols  <- setdiff(required_io_cols, names(all_data))
  if (length(missing_io_cols) > 0L) {
    stop(sprintf(
      "Cannot build intervention-outcome dataset table - missing column(s): %s",
      paste(missing_io_cols, collapse = ", ")
    ))
  }

  # Optional bias-adjusted CI and baseline RE estimate: include when present.
  have_bc_lci <- "mu_BC_lCI" %in% names(all_data)
  have_bc_uci <- "mu_BC_uCI" %in% names(all_data)
  have_mu_re  <- "mu_RE"     %in% names(all_data)

  # Stage candidate rows: format topic, parse year, derive has_excl_variant,
  # rename log10 BF columns to their final paper-facing names. We keep the
  # original row order via .row_id so the dedup tiebreaker is stable.
  io_staged <- all_data %>%
    mutate(
      .row_id          = row_number(),
      topic            = format_topic(topic),
      meta_analysis    = author,
      year             = suppressWarnings(as.integer(str_extract(author, "\\d{4}$"))),
      outcome          = effect,
      has_excl_variant = str_detect(effect, "_excl"),
      log10BF_effect   = logBF_effect,
      log10BF_het      = logBF_heterogeneity,
      log10BF_bias     = logBF_bias
    )

  # Dedup rule for any (topic, meta_analysis, outcome) duplicates:
  # keep the row with the most non-NA values across the export-critical
  # columns; ties (and the typical no-duplicate case) resolve to the first
  # occurrence in original file order.
  io_completeness_cols <- c("log10BF_effect", "log10BF_het", "log10BF_bias",
                            "mu_BC",
                            if (have_bc_lci) "mu_BC_lCI",
                            if (have_bc_uci) "mu_BC_uCI",
                            if (have_mu_re)  "mu_RE",
                            "n_studies")

  io_deduped <- io_staged %>%
    mutate(.completeness = rowSums(!is.na(across(all_of(io_completeness_cols))))) %>%
    arrange(.row_id) %>%
    group_by(topic, meta_analysis, outcome) %>%
    slice_max(order_by = .completeness, n = 1, with_ties = FALSE) %>%
    ungroup()

  # Final column order: identification first, then study count + flag, then
  # the effect estimate(s), then the BF trio.
  final_io_cols <- c("topic", "meta_analysis", "year", "outcome",
                     "n_studies", "has_excl_variant",
                     if (have_mu_re)  "mu_RE",
                     "mu_BC",
                     if (have_bc_lci) "mu_BC_lCI",
                     if (have_bc_uci) "mu_BC_uCI",
                     "log10BF_effect", "log10BF_het", "log10BF_bias")

  intervention_outcome_datasets <- io_deduped %>%
    select(all_of(final_io_cols)) %>%
    arrange(topic, meta_analysis, outcome)

  # Write
  io_csv_path <- file.path(output_dir, "intervention_outcome_datasets.csv")
  write_csv(intervention_outcome_datasets, io_csv_path)
  vmsg(sprintf("\u2713 Saved intervention-outcome dataset table: %s", io_csv_path))

  # --- Supplement-ready LaTeX fragment ----------------------------------------
  # Companion to intervention_outcome_datasets.csv: a longtable fragment that the
  # supplement can \input{} directly. Compact landscape layout that foregrounds
  # the bias-adjusted estimate and the three log10 Bayes factors. Combines the
  # bias-adjusted CI bounds into a single "95% CrI" column for compactness.
  # Rows are ordered by descending log10 BF for the effect component, so the
  # most impactful effect-component evidence appears first; the CSV companion
  # stays in alphabetical (topic, meta, outcome) order for stable diffing.
  vmsg("Building supplement-ready LaTeX fragment...")

  # Build the per-row text columns. We re-derive from intervention_outcome_datasets
  # so the TeX fragment is guaranteed consistent with the exported CSV.
  io_for_tex <- intervention_outcome_datasets

  # Defensive: handle optional CI columns by filling with NA if absent.
  if (!"mu_BC_lCI" %in% names(io_for_tex)) io_for_tex$mu_BC_lCI <- NA_real_
  if (!"mu_BC_uCI" %in% names(io_for_tex)) io_for_tex$mu_BC_uCI <- NA_real_

  io_tex <- io_for_tex %>%
    mutate(
      .topic_tex   = .latex_escape(topic),
      .meta_tex    = .latex_escape(meta_analysis),
      .year_tex    = ifelse(is.na(year), "", as.character(year)),
      .outcome_tex = .latex_escape(outcome),
      .k_tex       = ifelse(is.na(n_studies), "", as.character(n_studies)),
      .excl_tex    = ifelse(is.na(has_excl_variant) | !has_excl_variant, "", "yes"),
      .mu_tex      = .fmt_num(mu_BC, 3),
      .cri_tex     = ifelse(
        is.finite(mu_BC_lCI) & is.finite(mu_BC_uCI),
        sprintf("[%s,\\,%s]",
                .fmt_num(mu_BC_lCI, 3),
                .fmt_num(mu_BC_uCI, 3)),
        "---"
      ),
      .bfe_tex     = .fmt_num(log10BF_effect, 2),
      .bfh_tex     = .fmt_num(log10BF_het,    2),
      .bfb_tex     = .fmt_num(log10BF_bias,   2)
    ) %>%
    # Order rows by descending effect-component evidence (most impactful first).
    # The CSV companion remains alphabetical for stable diffing; this sort is
    # cosmetic and applies only to the rendered table. NA log10BF_effect values
    # sink to the bottom under arrange(desc(.)). Ties resolve alphabetically
    # so the rendered order is deterministic.
    arrange(desc(log10BF_effect), topic, meta_analysis, outcome)

  # Column spec: 11 columns, outcome wrapped, numerics right-aligned.
  col_spec <- "@{}l l c p{4.2cm} r c r c r r r@{}"

  header_row <- paste(
    "\\textbf{Topic}",
    "\\textbf{Meta-analysis}",
    "\\textbf{Year}",
    "\\textbf{Outcome}",
    "\\textbf{$k$}",
    "\\textbf{Excl.}",
    "\\textbf{$\\hat{\\mu}_{\\mathrm{BC}}$}",
    "\\textbf{95\\% CrI}",
    "\\textbf{$\\log_{10}\\mathrm{BF}_{\\text{eff}}$}",
    "\\textbf{$\\log_{10}\\mathrm{BF}_{\\text{het}}$}",
    "\\textbf{$\\log_{10}\\mathrm{BF}_{\\text{bias}}$} \\\\",
    sep = " & "
  )

  body_rows <- with(io_tex, paste0(
    .topic_tex,   " & ",
    .meta_tex,    " & ",
    .year_tex,    " & ",
    .outcome_tex, " & ",
    .k_tex,       " & ",
    .excl_tex,    " & ",
    .mu_tex,      " & ",
    .cri_tex,     " & ",
    .bfe_tex,     " & ",
    .bfh_tex,     " & ",
    .bfb_tex,     " \\\\"
  ))

  tex_lines <- c(
    "% =============================================================",
    "% intervention_outcome_datasets_table.tex",
    "% Auto-generated by 60_overview.R - do not edit by hand.",
    "% Source CSV: <output_dir>/intervention_outcome_datasets.csv",
    sprintf("%% Generated: %s",
            format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    sprintf("%% Rows (datasets): %d   Topics: %d",
            nrow(intervention_outcome_datasets),
            dplyr::n_distinct(intervention_outcome_datasets$topic)),
    "% Required packages (loaded in supplement preamble):",
    "%   longtable, booktabs, array, pdflscape",
    "% =============================================================",
    "\\begin{landscape}",
    "\\begingroup",
    "\\small",
    "\\setlength{\\tabcolsep}{4pt}",
    "\\renewcommand{\\arraystretch}{1.05}",
    sprintf("\\begin{longtable}{%s}", col_spec),
    paste0(
      "\\caption{Complete list of analyzed intervention--outcome datasets, ",
      "with bias-adjusted effect estimates ($\\hat{\\mu}_{\\mathrm{BC}}$) ",
      "and inclusion $\\log_{10}$ Bayes factors for the effect, heterogeneity, ",
      "and publication-bias/selection components. ",
      "Excl.\\ marks sensitivity-variant outcomes retained for stable RoBMA fitting. ",
      "Auto-generated from the audit pipeline.\\label{tab:io-datasets}}\\\\"
    ),
    "\\toprule",
    header_row,
    "\\midrule",
    "\\endfirsthead",
    "\\multicolumn{11}{l}{\\itshape Table~\\ref{tab:io-datasets} (continued)}\\\\",
    "\\toprule",
    header_row,
    "\\midrule",
    "\\endhead",
    "\\midrule",
    "\\multicolumn{11}{r}{\\itshape Continued on next page}\\\\",
    "\\endfoot",
    "\\bottomrule",
    "\\endlastfoot",
    body_rows,
    "\\end{longtable}",
    "\\endgroup",
    "\\end{landscape}",
    ""
  )

  io_tex_path <- file.path(output_dir, "intervention_outcome_datasets_table.tex")
  writeLines(tex_lines, io_tex_path, useBytes = TRUE)
  vmsg(sprintf("\u2713 Saved supplement TeX fragment: %s", io_tex_path))

  # Console report
  vmsg(sprintf(
    paste0(
      "\nIntervention-outcome dataset table:\n",
      "  Rows (datasets) : %d\n",
      "  Topics          : %d"
    ),
    nrow(intervention_outcome_datasets),
    n_distinct(intervention_outcome_datasets$topic)
  ))

  if (verbose) {
    message("\nPreview of intervention_outcome_datasets.csv (first 10 rows):")
    print(intervention_outcome_datasets, n = 10, width = Inf)
  }

  # --- Violin hybrid plots ----------------------------------------------------
  # Violin + forest summary overlay with custom evidence-axis transform.
  # Three outputs: violin_effect.pdf, violin_heterogeneity.pdf, violin_bias.pdf
  vmsg("\nCreating violin hybrid plots...")

  # Compute long and summary data for violins
  violin_long    <- .compute_topic_bf_long(all_data)
  violin_summary <- .compute_topic_bf_summary(violin_long)

  # Build the three violin hybrid plots
  .topic_violin_plot(
    violin_long, violin_summary, "effect",
    "Distribution of effect evidence across topics",
    file.path(output_dir, "violin_effect.pdf"),
    topic_colors = topic_colors, verbose = verbose
  )

  .topic_violin_plot(
    violin_long, violin_summary, "heterogeneity",
    "Distribution of heterogeneity evidence across topics",
    file.path(output_dir, "violin_heterogeneity.pdf"),
    topic_colors = topic_colors, verbose = verbose
  )

  .topic_violin_plot(
    violin_long, violin_summary, "bias",
    "Distribution of bias evidence across topics",
    file.path(output_dir, "violin_bias.pdf"),
    topic_colors = topic_colors, verbose = verbose
  )

  # --- Stacked full-page violin figure ----------------------------------------
  # Combined portrait-orientation figure stacking the three violin-hybrid panels
  # (effect / heterogeneity / bias-adjustment) on a single full-page layout.
  # All three panels share a common x-axis range. Topic order is computed per
  # panel by descending median BF (highest at top), which lets each panel be
  # read as a clean component-specific ranking. This trades the "drop your eye
  # down a topic column" property for cleaner within-panel evidence rankings.
  # Standalone violin_*.pdf files above are unchanged.
  vmsg("\nCreating stacked full-page violin figure...")

  # Common x-axis range across all three components.
  # Pad the union of finite transformed values, then clamp to piecewise terminal
  # bounds (\u00b13.65). This guarantees identical breaks/labels on every panel.
  global_x_t <- .bf_evidence_transform(violin_long$logBF)
  global_x_t <- global_x_t[is.finite(global_x_t)]
  if (length(global_x_t) > 0) {
    gx_range <- range(global_x_t, na.rm = TRUE)
    gx_pad   <- max(0.15, 0.06 * diff(gx_range))
    global_t_xlim <- c(gx_range[1] - gx_pad, gx_range[2] + gx_pad)
    global_t_xlim[1] <- max(global_t_xlim[1], -3.65)
    global_t_xlim[2] <- min(global_t_xlim[2],  3.65)
  } else {
    global_t_xlim <- c(-1, 1)
  }

  # Topic ordering is intentionally per-panel: each panel's helper call falls
  # back to the default `arrange(median_t)` behavior, which places the topic
  # with the highest median BF for that component at the top of the panel.

  # Compact visual-density profile for the stacked layout.
  # At ~0.4" per topic row, the standalone style's heavy IQR bar (linewidth 3.0)
  # overpowers the violin shape and hides individual points. We thin the IQR
  # bar, slightly enlarge and soften the outcome points, raise the violin alpha
  # so its shape carries more weight, and shrink the median dot. Standalone
  # violin_*.pdf outputs above are unaffected because they don't pass `style`.
  compact_style <- list(
    point_size        = 1.5,
    point_alpha       = 0.85,
    violin_alpha      = 0.42,
    iqr_linewidth     = 1.2,
    iqr_alpha         = 0.55,
    whisker_linewidth = 0.5,
    whisker_alpha     = 0.7,
    median_size_outer = 2.2,
    median_size_inner = 1.3,
    y_text_size       = 10,
    title_size        = 12,
    # Tighter margins in the stacked layout: less padding above/below each panel
    # converts directly into more plot area, which (for `scale = "width"`
    # violins) means thicker violin bodies.
    plot_margin       = margin(5, 12, 2, 12)
  )

  # Build the three panels with shared axis. Topic order is per-panel
  # (descending median BF) — see comment above.
  p_panel_eff <- .topic_violin_plot(
    violin_long, violin_summary, "effect",
    title = "A. Effect evidence",
    outfile = NULL, save = FALSE,
    topic_colors         = topic_colors,
    t_xlim_override      = global_t_xlim,
    show_x_axis          = FALSE,
    subtitle             = NULL,
    style                = compact_style,
    verbose              = verbose
  )

  p_panel_het <- .topic_violin_plot(
    violin_long, violin_summary, "heterogeneity",
    title = "B. Heterogeneity evidence",
    outfile = NULL, save = FALSE,
    topic_colors         = topic_colors,
    t_xlim_override      = global_t_xlim,
    show_x_axis          = FALSE,
    subtitle             = NULL,
    style                = compact_style,
    verbose              = verbose
  )

  p_panel_bias <- .topic_violin_plot(
    violin_long, violin_summary, "bias",
    title = "C. Bias evidence",
    outfile = NULL, save = FALSE,
    topic_colors         = topic_colors,
    t_xlim_override      = global_t_xlim,
    show_x_axis          = TRUE,
    subtitle             = NULL,
    style                = compact_style,
    verbose              = verbose
  )

  # Compose with patchwork. The bottom panel gets a slightly larger relative
  # height to accommodate its x-axis tick labels and axis title.
  violin_stack <- (p_panel_eff / p_panel_het / p_panel_bias) +
    plot_layout(heights = c(1, 1, 1.15))

  stack_pdf <- file.path(output_dir, "violin_stack_fullpage.pdf")
  ggsave(stack_pdf, violin_stack,
         width = 8.25, height = 12.5, units = "in",
         useDingbats = FALSE)
  vmsg(sprintf("  \u2713 Saved: %s", stack_pdf))

  # Optional PNG companion for slide previews. The vector PDF above is the
  # primary submission asset; this is a convenience output and is allowed to
  # fail silently if the PNG device is not available on this system.
  stack_png <- file.path(output_dir, "violin_stack_fullpage.png")
  tryCatch({
    ggsave(stack_png, violin_stack,
           width = 8.25, height = 12.5, units = "in",
           dpi = 300)
    vmsg(sprintf("  \u2713 Saved: %s", stack_png))
  }, error = function(e) {
    vmsg(sprintf("  Note: PNG companion not saved (%s)", conditionMessage(e)))
  })

  # --- Joint evidence scatter -------------------------------------------------
  # Effect evidence vs bias-adjustment evidence on raw log10(BF) axes.
  # The shaded region marks the "bias without robust effect" pattern:
  # weak effect evidence (|logBF_effect| <= 0.5) combined with at least
  # moderate bias-adjustment evidence (logBF_bias > 0.5).
  vmsg("\nCreating joint evidence scatter plot (effect vs bias adjustment)...")

  # Optional ggrepel for non-overlapping point labels; degrade gracefully if absent
  have_ggrepel <- requireNamespace("ggrepel", quietly = TRUE)

  scatter_dat <- all_data %>%
    filter(is.finite(logBF_effect), is.finite(logBF_bias)) %>%
    mutate(
      topic_display    = format_topic(topic),
      has_excl_variant = str_detect(effect, "_excl")
    )

  if (nrow(scatter_dat) == 0L) {
    vmsg("  Warning: no finite (logBF_effect, logBF_bias) pairs; skipping scatter plot.")
  } else {

    n_excl_pts <- sum(scatter_dat$has_excl_variant, na.rm = TRUE)

    # Axis limits with mild padding
    sx_rng <- range(scatter_dat$logBF_effect, na.rm = TRUE)
    sy_rng <- range(scatter_dat$logBF_bias,   na.rm = TRUE)
    sx_pad <- max(0.2, 0.05 * diff(sx_rng))
    sy_pad <- max(0.2, 0.05 * diff(sy_rng))
    scatter_xlim <- c(sx_rng[1] - sx_pad, sx_rng[2] + sx_pad)
    scatter_ylim <- c(sy_rng[1] - sy_pad, sy_rng[2] + sy_pad)

    # Bounds of the "bias without robust effect" shaded region (clipped to view).
    # If the data range does not actually intersect the region, draw_key = FALSE.
    key_xmin <- max(-0.5, scatter_xlim[1])
    key_xmax <- min( 0.5, scatter_xlim[2])
    key_ymin <- 0.5
    key_ymax <- scatter_ylim[2]
    draw_key_region <- (key_xmax > key_xmin) && (key_ymax > key_ymin)

    p_scatter <- ggplot(scatter_dat,
                        aes(x = logBF_effect, y = logBF_bias))

    # Shaded key region (only if the region intersects the visible data range)
    if (draw_key_region) {
      p_scatter <- p_scatter +
        annotate("rect",
                 xmin = key_xmin, xmax = key_xmax,
                 ymin = key_ymin, ymax = key_ymax,
                 fill = "#F9A825", alpha = 0.10)
    }

    p_scatter <- p_scatter +
      # Light zero reference lines
      geom_hline(yintercept = 0, color = "gray80", linewidth = 0.4) +
      geom_vline(xintercept = 0, color = "gray80", linewidth = 0.4) +
      # Threshold reference lines (BF ~ 3)
      geom_hline(yintercept = 0.5, linetype = "dashed",
                 color = "gray40", linewidth = 0.5) +
      geom_vline(xintercept = c(-0.5, 0.5), linetype = "dashed",
                 color = "gray40", linewidth = 0.5)

    # Points: shape distinguishes _excl variants only when any are present,
    # so the legend stays clean for analyses without sensitivity variants.
    if (n_excl_pts > 0L) {
      p_scatter <- p_scatter +
        geom_point(aes(color = topic_display, shape = has_excl_variant),
                   size = 2.4, alpha = 0.78, stroke = 0.4) +
        scale_shape_manual(
          values = c(`FALSE` = 16, `TRUE` = 17),
          labels = c(`FALSE` = "primary", `TRUE` = "_excl variant"),
          name   = NULL
        )
    } else {
      p_scatter <- p_scatter +
        geom_point(aes(color = topic_display),
                   size = 2.4, alpha = 0.78, shape = 16)
    }

    p_scatter <- p_scatter +
      scale_color_manual(values = topic_colors, name = "Topic") +
      coord_cartesian(xlim = scatter_xlim, ylim = scatter_ylim, clip = "off") +
      labs(
        title    = "Effect evidence vs bias-adjustment evidence",
        subtitle = paste0(
          "Shaded region marks the \u201cbias without robust effect\u201d pattern: ",
          "weak effect evidence with at least moderate bias-adjustment evidence"
        ),
        x = expression(log[10]~BF[effect]),
        y = expression(log[10]~BF[bias])
      ) +
      theme_minimal(base_size = 13) +
      theme(
        panel.grid.minor = element_blank(),
        panel.grid.major = element_line(color = "gray92", linewidth = 0.3),
        plot.title       = element_text(face = "bold", size = 12),
        plot.subtitle    = element_text(size = 9, color = "gray40"),
        legend.position  = "right",
        legend.title     = element_text(size = 10, face = "bold"),
        legend.text      = element_text(size = 9),
        panel.border     = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
        axis.line        = element_line(colour = "gray60", linewidth = 0.3),
        plot.margin      = margin(12, 12, 6, 12)
      ) +
      guides(color = guide_legend(override.aes = list(alpha = 1, size = 2.8)))

    # Optionally label a small number of "bias without robust effect" outcomes
    # (top by logBF_bias inside the shaded region) using ggrepel if available.
    if (have_ggrepel) {
      label_dat <- scatter_dat %>%
        filter(abs(logBF_effect) <= 0.5, logBF_bias > 0.5) %>%
        arrange(desc(logBF_bias)) %>%
        slice_head(n = 6)

      if (nrow(label_dat) > 0L) {
        p_scatter <- p_scatter +
          ggrepel::geom_text_repel(
            data = label_dat,
            aes(label = author),
            size = 2.8, color = "gray25",
            max.overlaps = Inf,
            box.padding   = 0.5,
            point.padding = 0.3,
            segment.color = "gray60",
            segment.size  = 0.3,
            min.segment.length = 0.1,
            show.legend = FALSE
          )
      }
    }

    scatter_outfile <- file.path(output_dir, "scatter_effect_vs_bias.pdf")
    ggsave(scatter_outfile, p_scatter,
           width = 8.5, height = 6,
           useDingbats = FALSE)
    vmsg(sprintf("  \u2713 Saved: %s", scatter_outfile))

  }  # end of: if (nrow(scatter_dat) == 0L) { ... } else { ... }

  # --- Final summary ----------------------------------------------------------
  vmsg("\n=== Overview Analysis Complete ===")
  vmsg(sprintf("Total outcomes analyzed: %d", nrow(all_data)))
  vmsg(sprintf("Topics included: %d", n_distinct(all_data$topic)))
  vmsg(sprintf("\nAll outputs saved to: %s/", output_dir))
  vmsg("\nGenerated files:")
  vmsg("  \u2022 topic_summary.csv")
  vmsg("  \u2022 intervention_outcome_datasets.csv")
  vmsg("  \u2022 intervention_outcome_datasets_table.tex")
  vmsg("  \u2022 orchard_effect.pdf")
  vmsg("  \u2022 orchard_heterogeneity.pdf")
  vmsg("  \u2022 orchard_bias.pdf")
  vmsg("  \u2022 boxplot_combined_horizontal.pdf")
  vmsg("  \u2022 boxplot_strip_single.pdf")
  vmsg("  \u2022 violin_effect.pdf")
  vmsg("  \u2022 violin_heterogeneity.pdf")
  vmsg("  \u2022 violin_bias.pdf")
  vmsg("  \u2022 violin_stack_fullpage.pdf  (combined portrait, manuscript-ready)")
  vmsg("  \u2022 violin_stack_fullpage.png  (optional companion)")
  vmsg("  \u2022 scatter_effect_vs_bias.pdf")
  vmsg("\n\u2713 Done!")

  invisible(list(
    output_dir   = output_dir,
    topic_summary = topic_summary,
    intervention_outcome_datasets = intervention_outcome_datasets
  ))
}


# ==============================================================================
# Intended usage
# ==============================================================================
# Sourcing this file defines `build_overview()` and helpers but does NOT run
# the analysis. To produce the overview deliverables:
#
#   source("scripts/60_overview.R")
#   build_overview()
#
# To make this script self-running (e.g. in a Makefile or CI), add an explicit
# top-level call:
#
#   if (sys.nframe() == 0L) build_overview()
#
# Left commented out by default to keep `source()` purely declarative.
# ==============================================================================
