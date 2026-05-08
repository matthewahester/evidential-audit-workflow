#!/usr/bin/env Rscript

# 50_topic_analysis.R
# ------------------------------------------------------------------------------
# Within-topic comparison of baseline RE vs RoBMA-PSMA effects.
#
# build_topic_summary() reads the per-topic sidecar CSV that fit_robma_models()
# writes (output/<topic>/<topic>_robma_summary.csv), then produces:
#   * <topic>_bias_correction_comparison.pdf  - paired boxplot
#   * <topic>_forest_plot_comparison.pdf      - forest plot (RE vs PSMA)
#   * <topic>_orchard_combined.pdf            - 3x1 orchard panel
#                                               (effect / heterogeneity / bias)
# It also appends a row to output/topic_summary.csv with topic-level evidence
# and shrinkage statistics.
#
# Sourcing this file only defines functions; nothing is read or written. A CLI
# block at the bottom calls build_topic_summary() when the file is invoked
# non-interactively (e.g. `Rscript scripts/50_topic_analysis.R --topic Fiber`).
#
# Quick-Start
#   source("scripts/00_utils.R")
#   source("scripts/50_topic_analysis.R")
#   build_topic_summary(topic = "Fiber")
# ------------------------------------------------------------------------------

# SETUP ======================================================================
suppressPackageStartupMessages({
  library(tidyverse); library(readr); library(stringr); library(patchwork)
})


# ---- Shared utilities ------------------------------------------------------
# Provides format_topic, .compute_precision, .bf_evidence_transform,
# .bf_axis_spec. Sentinel-guarded.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# Plot palette for paired baseline RE vs RoBMA-PSMA visuals.
COLOR_ORIGINAL  <- "#2166ac"
COLOR_CORRECTED <- "#b2182b"


# HELPER FUNCTIONS ===========================================================

# Build one orchard panel using the piecewise evidence-axis transform.
# Returns a ggplot for patchwork composition (does not save). Renamed from
# `.orchard_plot` to avoid clashing with 60_overview.R's faceted version of
# the same name.
.orchard_panel <- function(dat, bf_col, title, plot_color, t_xlim, ax) {

  dat <- dat %>%
    mutate(
      x_raw = .data[[bf_col]],
      x_t   = .bf_evidence_transform(x_raw)
    ) %>%
    filter(is.finite(x_t))

  if (nrow(dat) == 0L) {
    message(sprintf("  Warning: no valid %s data", bf_col))
    return(NULL)
  }

  dat <- .compute_precision(dat)

  # jitter outcomes around the horizontal band y=0
  set.seed(7385783)
  dat$y_jit <- runif(nrow(dat), -0.18, 0.18)

  # topic-level pooled mean, CI, PI (on transformed x)
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

  # stable size legend ticks
  qs <- suppressWarnings(quantile(dat$prec, c(.10, .50, .90), na.rm = TRUE))
  if (any(!is.finite(qs))) qs <- rep(median(dat$prec, na.rm = TRUE), 3)

  br <- unique(round(qs, 1))
  if (length(br) < 3) br <- round(qs, 2)
  if (length(br) < 3) {
    prec_range <- range(dat$prec, na.rm = TRUE)
    br <- round(seq(prec_range[1], prec_range[2], length.out = 3), 1)
  }

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

  # Vertical guide lines
  p <- p + geom_vline(xintercept = .bf_evidence_transform(0),
                      linetype = "solid", linewidth = 1.0, color = "gray20")

  for (lbf in c(-log10(3), log10(3))) {
    tv <- .bf_evidence_transform(lbf)
    if (tv >= t_xlim[1] && tv <= t_xlim[2]) {
      p <- p + geom_vline(xintercept = tv, linetype = "dashed",
                          linewidth = 0.8, color = "gray40")
    }
  }
  for (lbf in c(-2, -1, 1, 2)) {
    tv <- .bf_evidence_transform(lbf)
    if (tv >= t_xlim[1] && tv <= t_xlim[2]) {
      p <- p + geom_vline(xintercept = tv, linetype = "dotted",
                          linewidth = 0.8, color = "gray50")
    }
  }

  p <- p +
    # outcome bubbles - all circles
    geom_point(aes(y = y_jit, size = prec), alpha = 0.82, shape = 16, color = plot_color) +

    scale_size_continuous(
      range = c(2.5, 9),
      breaks = br,
      guide = "none"
    ) +

    coord_cartesian(xlim = t_xlim, ylim = c(-.19, .19), clip = "off") +
    scale_x_continuous(
      expand = c(0, 0),
      breaks = ax$breaks,
      labels = ax$labels
    ) +

    labs(
      title = title,
      x = "Bayes Factor", y = NULL
    ) +

    theme_minimal(base_size = 13) +
    theme(
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_blank(),
      axis.text.y  = element_blank(),
      axis.ticks.y = element_blank(),
      axis.text.x = element_text(size = 10),
      axis.ticks.x = element_line(color = "gray60"),
      legend.position = "none",
      plot.title = element_text(face = "bold", size = 12),
      plot.margin = margin(12, 12, 6, 12),
      panel.border = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line = element_line(colour = "gray60", linewidth = 0.3)
    )

  return(p)
}


# BUILD_TOPIC_SUMMARY ========================================================

build_topic_summary <- function(topic = "protein") {
  # Build the within-topic comparison artifacts for a single topic. Reads
  # the topic's sidecar CSV; writes plots under output/<topic>/plots/ and
  # appends/updates the row for this topic in output/topic_summary.csv.
  #
  # Args:
  #   topic   Topic name or slug. Case-insensitive; whitespace and other
  #           non-alphanumeric characters are folded to underscores.
  #
  # Returns: invisibly, list(data, files = list(topic_summary, boxplot,
  #                                              forest_plot,
  #                                              orchard_combined_pdf))

  # Reproducibility seed for the jitter / sampling steps below. Kept inside
  # the function so sourcing this file does not mutate the caller's RNG state.
  set.seed(4738)

  topic_slug <- tolower(gsub("[^a-z0-9]+", "_", topic))
  summary_path <- file.path("output", topic_slug, sprintf("%s_robma_summary.csv", topic_slug))
  plots_dir    <- file.path("output", topic_slug, "plots")
  dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

  if (!file.exists(summary_path)) stop(sprintf("Summary file not found: %s", summary_path))
  raw <- read_csv(summary_path, show_col_types = FALSE)

  req <- c("author", "effect", "mu_RE", "mu_BC")
  miss <- setdiff(req, names(raw))
  if (length(miss)) stop("Missing columns: ", paste(miss, collapse = ", "))

  # Standardize + derived
  df <- raw %>%
    transmute(
      author, outcome = effect,
      re_est = as.numeric(mu_RE),
      bc_est = as.numeric(mu_BC),
      re_lo = as.numeric(mu_RE_lCI),
      re_hi = as.numeric(mu_RE_uCI),
      bc_lo = as.numeric(mu_BC_lCI),
      bc_hi = as.numeric(mu_BC_uCI),
      n_studies = if ("n_studies" %in% names(raw)) raw$n_studies else NA_integer_
    ) %>%
    filter(is.finite(re_est) & is.finite(bc_est)) %>%
    mutate(
      change = bc_est - re_est,
      pct_change = ifelse(abs(re_est) > 1e-6, 100 * change / abs(re_est), NA_real_)
    )

  if (nrow(df) == 0) stop("No valid rows after filtering.")

  # PLOTS ====================================================================

  # 1. Boxplot with jitter
  message("Creating paired boxplot...")

  # Prepare long data
  plot_data_long <- df %>%
    select(author, outcome, re_est, bc_est) %>%
    pivot_longer(
      cols = c(re_est, bc_est),
      names_to = "Method",
      values_to = "Estimate"
    ) %>%
    mutate(
      Method = factor(
        ifelse(Method == "re_est", "Original", "Bias-corrected"),
        levels = c("Original", "Bias-corrected")
      )
    )

  # Generate consistent jitter for pairs
  n_pairs <- nrow(df)
  jitter_vals <- runif(n_pairs, -0.08, 0.08)
  df_jitter <- df %>% mutate(jitter = jitter_vals)

  # Create boxplot
  p_boxplot <- ggplot() +
    # Background boxplots
    geom_boxplot(
      data = plot_data_long,
      aes(x = Method, y = Estimate, fill = Method),
      alpha = 0.6,
      width = 0.4,
      outlier.shape = NA
    ) +
    # Add horizontal line at 0
    geom_hline(
      yintercept = 0,
      linetype = "dashed",
      color = "grey30",
      linewidth = 0.5
    ) +
    # Paired lines
    geom_segment(
      data = df_jitter,
      aes(x = 1 + jitter, xend = 2 + jitter,
          y = re_est, yend = bc_est),
      color = "gray40",
      alpha = 0.5
    ) +
    # Points
    geom_point(
      data = df_jitter,
      aes(x = 1 + jitter, y = re_est),
      color = "black",
      size = 2
    ) +
    geom_point(
      data = df_jitter,
      aes(x = 2 + jitter, y = bc_est),
      color = "black",
      size = 2
    ) +
    scale_fill_manual(values = c("Original" = COLOR_ORIGINAL,
                                 "Bias-corrected" = COLOR_CORRECTED)) +
    labs(
      title = sprintf("Meta-analysis effect sizes \u2014 %s", format_topic(topic)),
      subtitle = "Before and after bias-correction",
      y = "Effect Size (Hedges' g)",
      x = NULL
    ) +
    theme_minimal(base_size = 14) +
    theme(
      plot.title = element_text(face = "bold"),
      plot.subtitle = element_text(color = "gray40"),
      axis.text.x = element_text(face = "bold"),
      legend.position = "none",
      panel.border = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line = element_line(colour = "gray60", linewidth = 0.3)
    )

  # Save boxplot as PDF
  boxplot_path <- file.path(plots_dir, paste0(topic_slug, "_bias_correction_comparison.pdf"))
  ggsave(boxplot_path, p_boxplot, width = 6, height = 10, device = "pdf")

  # 2. Forest plot
  message("Creating forest plot...")

  # Prepare data for forest plot
  forest_data <- df %>%
    select(author, outcome, n_studies, re_est, re_lo, re_hi, bc_est, bc_lo, bc_hi)

  # Derive author_label: split "Name1999" into "Name 1999"
  forest_data <- forest_data %>%
    mutate(
      author_label = ifelse(
        str_detect(author, "^[A-Za-z]+[0-9]{4}$"),
        {
          name_part <- str_replace(author, "([0-9]{4})$", "")
          year_part <- str_extract(author, "([0-9]{4})$")
          paste0(tools::toTitleCase(name_part), " ", year_part)
        },
        tools::toTitleCase(author)
      )
    )

  # Derive excl_flag: TRUE if outcome ends with _EX or _EXCL
  forest_data <- forest_data %>%
    mutate(
      excl_flag = str_detect(outcome, "_EXCL$|_EX$")
    )

  # Derive outcome_base: outcome with trailing _EXCL or _EX removed
  forest_data <- forest_data %>%
    mutate(
      outcome_base = str_replace(outcome, "_EXCL$|_EX$", "")
    )

  # Derive outcome_label: title-cased version of outcome_base
  forest_data <- forest_data %>%
    mutate(
      outcome_label = str_replace_all(outcome_base, "_", " "),
      outcome_label = stringr::str_to_title(outcome_label)
    )

  # Derive label_suffix: " (reduced set)" if excluded, otherwise ""
  forest_data <- forest_data %>%
    mutate(
      label_suffix = if_else(excl_flag, " (reduced set)", "")
    )

  # Derive n_label: sample size annotation
  forest_data <- forest_data %>%
    mutate(
      n_label = if_else(!is.na(n_studies), paste0("  n=", n_studies), "")
    )

  # Derive y_label: two-line label - UPPERCASE outcome on top, author + n below
  forest_data <- forest_data %>%
    mutate(
      y_label = paste0(toupper(outcome_label), toupper(label_suffix), "\n",
                       author_label, n_label)
    )

  # Sort by outcome_label, author_label, excl_flag (non-excluded first) and compute y_pos
  forest_data <- forest_data %>%
    arrange(outcome_label, author_label, excl_flag) %>%
    mutate(y_pos = n() - row_number() + 1)

  # Create long format for plotting
  forest_long <- bind_rows(
    forest_data %>%
      select(author, outcome, y_pos, est = re_est, lo = re_lo, hi = re_hi) %>%
      mutate(Method = "Original", y_offset = 0.15),
    forest_data %>%
      select(author, outcome, y_pos, est = bc_est, lo = bc_lo, hi = bc_hi) %>%
      mutate(Method = "Bias-corrected", y_offset = -0.15)
  ) %>%
    mutate(
      Method = factor(Method, levels = c("Original", "Bias-corrected")),
      y_plot = y_pos + y_offset
    )

  # Create forest plot with error bars
  p_forest <- ggplot(forest_long, aes(x = est, y = y_plot, color = Method)) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "gray60") +
    geom_errorbarh(
      aes(xmin = lo, xmax = hi),
      height = 0.15,
      na.rm = TRUE
    ) +
    geom_point(size = 3, na.rm = TRUE) +
    scale_color_manual(values = c("Original" = COLOR_ORIGINAL,
                                  "Bias-corrected" = COLOR_CORRECTED)) +
    scale_y_continuous(
      breaks = unique(forest_long$y_pos),
      labels = forest_data$y_label,
      expand = expansion(add = 0.5)
    ) +
    labs(
      title = sprintf("Forest Plot \u2014 %s", format_topic(topic)),
      subtitle = "Error bars show 95% credible intervals",
      x = "Effect Size (Hedges' g)",
      y = NULL,
      color = "Method"
    ) +
    theme_minimal(base_size = 14) +
    theme(
      plot.title = element_text(face = "bold"),
      plot.subtitle = element_text(color = "gray40", size = 11, face = "italic"),
      legend.position = "bottom",
      panel.grid.major.y = element_blank(),
      panel.grid.minor.y = element_blank(),
      panel.border = element_rect(colour = "gray30", fill = NA, linewidth = 0.4),
      axis.line = element_line(colour = "gray60", linewidth = 0.3),
      axis.text.y = element_text(size = 9, lineheight = 0.9, hjust = 1)
    )

  # Save forest plot as PDF (height scales with number of outcomes for two-line labels)
  forest_height <- max(8, nrow(forest_data) * 0.4 + 2)
  forest_path <- file.path(plots_dir, paste0(topic_slug, "_forest_plot_comparison.pdf"))
  ggsave(forest_path, p_forest, width = 8, height = forest_height, device = "pdf")

  # 3. ORCHARD PLOTS (combined) with evidence-axis transform
  message("Creating combined orchard plot for Bayes factors...")

  # Helper function to convert character Inf to numeric Inf
  convert_inf_to_numeric <- function(x) {
    if (is.character(x)) {
      x <- ifelse(x == "Inf", Inf,
                  ifelse(x == "-Inf", -Inf, x))
      x <- as.numeric(x)
    }
    return(x)
  }

  # Prepare data for orchard plots - add topic column and compute log BFs
  orchard_data <- raw %>%
    mutate(
      topic = topic_slug,
      eff_bf_BC_numeric = convert_inf_to_numeric(eff_bf_BC),
      het_bf_BC_numeric = convert_inf_to_numeric(het_bf_BC),
      bias_bf_BC_numeric = convert_inf_to_numeric(bias_bf_BC),
      logBF_effect = log10(pmax(eff_bf_BC_numeric, 1e-10)),
      logBF_heterogeneity = log10(pmax(het_bf_BC_numeric, 1e-10)),
      logBF_bias = log10(pmax(bias_bf_BC_numeric, 1e-10)),
      mu_RE_lCI = as.numeric(mu_RE_lCI),
      mu_RE_uCI = as.numeric(mu_RE_uCI),
      mu_BC_lCI = as.numeric(mu_BC_lCI),
      mu_BC_uCI = as.numeric(mu_BC_uCI)
    )

  # Compute unified x-axis limits in transformed space across all three BF types
  all_bf_values <- c(
    orchard_data$logBF_effect,
    orchard_data$logBF_heterogeneity,
    orchard_data$logBF_bias
  )
  all_t <- .bf_evidence_transform(all_bf_values[is.finite(all_bf_values)])

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

  ax <- .bf_axis_spec(t_xlim)

  # Define colors for each plot type
  color_effect        <- "#0072B2"  # Sky Blue
  color_heterogeneity <- "#009E73"  # Bluish Green
  color_bias          <- "#D55E00"  # Vermillion

  # Format topic name for title
  topic_title <- format_topic(topic)

  # Create the three orchard plot objects
  p_effect <- .orchard_panel(orchard_data, "logBF_effect",
                             "Effect Evidence",
                             plot_color = color_effect,
                             t_xlim = t_xlim, ax = ax)

  p_heterogeneity <- .orchard_panel(orchard_data, "logBF_heterogeneity",
                                    "Heterogeneity Evidence",
                                    plot_color = color_heterogeneity,
                                    t_xlim = t_xlim, ax = ax)

  p_bias <- .orchard_panel(orchard_data, "logBF_bias",
                           "Publication Bias Evidence",
                           plot_color = color_bias,
                           t_xlim = t_xlim, ax = ax)

  # Combine plots vertically (3x1 layout)
  combined_orchard <- p_effect / p_heterogeneity / p_bias +
    plot_annotation(
      title = sprintf("Bayes Factors - %s", topic_title),
      caption = "Bubbles = outcomes sized by precision",
      theme = theme(
        plot.title = element_text(hjust = 0.5, size = 14, face = "bold", margin = margin(b = 10)),
        plot.caption = element_text(hjust = 0.5, size = 10, color = "gray40", margin = margin(t = 10))
      )
    )

  # Save combined orchard plot as PDF only
  orchard_pdf_path <- file.path(plots_dir, paste0(topic_slug, "_orchard_combined.pdf"))
  ggsave(orchard_pdf_path, combined_orchard,
         width = 6, height = 10, device = "pdf", useDingbats = FALSE)
  message(sprintf("  \u2713 Saved PDF: %s", orchard_pdf_path))

  # DETAILED SUMMARY ===========================================================

  # Compute topic-level aggregates from per-outcome data

  # Helper: compute SE from CI bounds
  compute_se <- function(lower_ci, upper_ci) {
    ifelse(is.finite(lower_ci) & is.finite(upper_ci),
           (upper_ci - lower_ci) / (2 * 1.96),
           NA_real_)
  }

  # Prepare working data with SE and relative change metrics
  summary_data <- orchard_data %>%
    mutate(
      # Compute SEs from CIs
      se_RE = compute_se(mu_RE_lCI, mu_RE_uCI),
      se_BC = compute_se(mu_BC_lCI, mu_BC_uCI),

      # Effect size relative change (percent)
      g_rel_change_pct = ifelse(abs(mu_RE) > 1e-6,
                                100 * (mu_BC - mu_RE) / abs(mu_RE),
                                NA_real_),

      # Uncertainty relative change (percent)
      se_rel_change_pct = ifelse(is.finite(se_RE) & is.finite(se_BC) & se_RE > 1e-10,
                                 100 * (se_BC - se_RE) / se_RE,
                                 NA_real_),

      # Indicators
      BC_CI_includes_zero = (mu_BC_lCI <= 0 & 0 <= mu_BC_uCI),
      sign_flip = sign(mu_RE) != sign(mu_BC) & abs(mu_RE) > 1e-6 & abs(mu_BC) > 1e-6,
      reduction_50pct = g_rel_change_pct <= -50,

      # Evidence thresholds (on raw BF scale, not log10)
      evidence_effect = eff_bf_BC_numeric > 3,
      evidence_bias = bias_bf_BC_numeric > 3,
      evidence_heterogeneity = het_bf_BC_numeric > 3,

      # Off-scale log10 BF (any |log10 BF| > 3)
      offscale_log10_BF = abs(logBF_effect) > 3 | abs(logBF_heterogeneity) > 3 | abs(logBF_bias) > 3
    )

  summary_data <- summary_data %>%
    mutate(
      # EFFECT evidence flags (raw BF scale)
      eff_BF_lt1   = eff_bf_BC_numeric < 1,
      eff_BF_gt3   = eff_bf_BC_numeric > 3,
      eff_BF_gt10  = eff_bf_BC_numeric > 10,

      # BIAS evidence flags
      bias_BF_gt3  = bias_bf_BC_numeric > 3,
      bias_BF_gt10 = bias_bf_BC_numeric > 10,

      # HETEROGENEITY evidence flags
      het_BF_gt3   = het_bf_BC_numeric > 3,
      het_BF_gt10  = het_bf_BC_numeric > 10
    )

  # handy safe quantile
  qfun <- function(x, p) suppressWarnings(as.numeric(stats::quantile(x, p, na.rm = TRUE)))

  topic_summary <- tibble(
    # Identity
    topic = topic_slug,
    n_outcomes = nrow(summary_data),

    # Effect size change
    median_g_rel_change_pct     = round(median(summary_data$g_rel_change_pct, na.rm = TRUE), 1),
    share_reduction_50pct       = round(mean(summary_data$reduction_50pct, na.rm = TRUE), 3),
    share_BC_CI_includes_zero   = round(mean(summary_data$BC_CI_includes_zero, na.rm = TRUE), 3),
    n_sign_flips                = sum(summary_data$sign_flip, na.rm = TRUE),

    # Uncertainty change
    median_se_rel_change_pct    = round(median(summary_data$se_rel_change_pct, na.rm = TRUE), 1),

    # --- Evidence scoreboards (shares + counts) ---
    # Effect
    share_eff_BF_lt1            = round(mean(summary_data$eff_BF_lt1, na.rm = TRUE), 3),
    n_eff_BF_lt1                = sum(summary_data$eff_BF_lt1, na.rm = TRUE),
    share_eff_BF_gt3            = round(mean(summary_data$eff_BF_gt3, na.rm = TRUE), 3),
    n_eff_BF_gt3                = sum(summary_data$eff_BF_gt3, na.rm = TRUE),
    share_eff_BF_gt10           = round(mean(summary_data$eff_BF_gt10, na.rm = TRUE), 3),
    n_eff_BF_gt10               = sum(summary_data$eff_BF_gt10, na.rm = TRUE),

    # Bias
    share_bias_BF_gt3           = round(mean(summary_data$bias_BF_gt3, na.rm = TRUE), 3),
    n_bias_BF_gt3               = sum(summary_data$bias_BF_gt3, na.rm = TRUE),
    share_bias_BF_gt10          = round(mean(summary_data$bias_BF_gt10, na.rm = TRUE), 3),
    n_bias_BF_gt10              = sum(summary_data$bias_BF_gt10, na.rm = TRUE),

    # Heterogeneity
    share_het_BF_gt3            = round(mean(summary_data$het_BF_gt3, na.rm = TRUE), 3),
    n_het_BF_gt3                = sum(summary_data$het_BF_gt3, na.rm = TRUE),
    share_het_BF_gt10           = round(mean(summary_data$het_BF_gt10, na.rm = TRUE), 3),
    n_het_BF_gt10               = sum(summary_data$het_BF_gt10, na.rm = TRUE),

    # Off-scale BF
    n_offscale_log10_BF         = sum(summary_data$offscale_log10_BF, na.rm = TRUE),

    # Distribution summaries for narration
    median_log10_BF_effect      = round(median(summary_data$logBF_effect, na.rm = TRUE), 3),
    q25_log10_BF_effect         = round(qfun(summary_data$logBF_effect, .25), 3),
    q75_log10_BF_effect         = round(qfun(summary_data$logBF_effect, .75), 3),
    median_log10_BF_bias        = round(median(summary_data$logBF_bias, na.rm = TRUE), 3),
    median_log10_BF_heterogeneity = round(median(summary_data$logBF_heterogeneity, na.rm = TRUE), 3)
  )

  # Add optional diagnostics if present in raw data
  optional_cols <- c("ODR", "EDR", "Soric_FDR", "MissingN")
  for (col in optional_cols) {
    if (col %in% names(raw)) {
      new_col_name <- paste0("mean_", col)
      topic_summary[[new_col_name]] <- round(mean(raw[[col]], na.rm = TRUE), 3)
    }
  }

  # WRITE OUT ==================================================================

  # Write/update consolidated topic summary CSV
  dir.create("output", recursive = TRUE, showWarnings = FALSE)
  consolidated_path <- file.path("output", "topic_summary.csv")

  if (file.exists(consolidated_path)) {
    # Read existing summaries
    existing <- read_csv(consolidated_path, show_col_types = FALSE)

    # Remove any existing row for this topic (to avoid duplicates)
    existing <- existing %>% filter(topic != topic_slug)

    # Append new summary
    combined <- bind_rows(existing, topic_summary)

    # Write back
    write_csv(combined, consolidated_path)
    message(sprintf("  \u2713 Updated consolidated summary: %s", consolidated_path))
  } else {
    # First topic - create new file
    write_csv(topic_summary, consolidated_path)
    message(sprintf("  \u2713 Created consolidated summary: %s", consolidated_path))
  }

  summary_csv_path <- consolidated_path

  # Log concise summary
  message(sprintf("\n--- Topic Summary: %s ---", topic_slug))
  message(sprintf("  n_outcomes: %d", topic_summary$n_outcomes))
  message(sprintf("  median_g_rel_change_pct: %.1f%%", topic_summary$median_g_rel_change_pct))
  message(sprintf("  share_BC_CI_includes_zero: %.3f", topic_summary$share_BC_CI_includes_zero))
  message(sprintf("  share_bias_BF_gt3: %.3f", topic_summary$share_bias_BF_gt3))
  message(sprintf("  n_offscale_log10_BF: %d", topic_summary$n_offscale_log10_BF))

  # Print completion checklist
  message("\n=== Files written successfully ===")
  message(sprintf("\u2713 Topic summary: %s", summary_csv_path))
  message(sprintf("\u2713 Boxplot (PDF): %s", boxplot_path))
  message(sprintf("\u2713 Forest plot (PDF): %s", forest_path))
  message(sprintf("\u2713 Combined orchard plot (PDF): %s", file.path(plots_dir, paste0(topic_slug, "_orchard_combined.pdf"))))

  # Return results invisibly
  invisible(list(
    data = df,
    files = list(
      topic_summary = summary_csv_path,
      boxplot = boxplot_path,
      forest_plot = forest_path,
      orchard_combined_pdf = file.path(plots_dir, paste0(topic_slug, "_orchard_combined.pdf"))
    )
  ))
}


# CLI ========================================================================
# When invoked non-interactively (e.g. via `Rscript scripts/50_topic_analysis.R
# --topic Fiber`), run build_topic_summary() with the requested topic.
if (!interactive()) {
  args <- commandArgs(trailingOnly = TRUE)

  topic <- "Fiber"   # default

  # Parse --topic argument
  if (length(args) > 0) {
    topic_idx <- which(args == "--topic")
    if (length(topic_idx) > 0 && length(args) > topic_idx) {
      topic <- args[topic_idx + 1]
    }
  }

  tryCatch({
    build_topic_summary(topic = topic)
    message(sprintf("\n\u2713 Analysis complete for topic: %s", topic))
  }, error = function(e) {
    message(sprintf("\n\u2717 Error processing topic %s: %s", topic, e$message))
    quit(status = 1)
  })
}
