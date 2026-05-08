# 30_robma_analysis.R
# ------------------------------------------------------------------------------
# Optional per-fit diagnostic helper.
#
# analyze_robma_fit() looks up the four objects that 20_robma_fit.R stamps
# into the global environment for a given basename --
#   fit_RE_<basename>, fit_RoBMA_<basename>,
#   zcurve_RE_<basename>, zcurve_RoBMA_<basename>
# -- prints concise summaries, and (optionally) writes z-distribution and
# extrapolation PDFs plus a captured-text console summary. It is *not* part
# of the minimal pipeline: 40_batch_fit.R and the topic/overview scripts do
# not depend on this file. Use it only for interactive inspection of an
# individual fit.
#
# Sourcing this file only defines functions; nothing is read or written.
#
# Quick-Start
#   source("scripts/30_robma_analysis.R")
#   # Console-only inspection (no files written):
#   analyze_robma_fit("morton2018_protein_lean_body_mass", write_files = FALSE)
#   # With PDFs written under output/<topic>/<authoryear>/{plots,summary}/:
#   res <- analyze_robma_fit("morton2018_protein_lean_body_mass")
#   res$plots$z_plot_fun()             # re-draw on screen
#   res$plots$z_extrapolation_fun()
# ------------------------------------------------------------------------------


# ==== HELPERS ================================================================

#' Infer topic from basename
#'
#' Extracts the second underscore-delimited token as the topic.
#' E.g., "saneei2014_diet_diastolic_blood_pressure" -> "diet"
#' Falls back to "misc" if fewer than 2 tokens.
infer_topic_from_basename <- function(basename) {
  tokens <- strsplit(basename, "_", fixed = TRUE)[[1]]
  if (length(tokens) >= 2) {
    return(tolower(tokens[2]))
  }
  return("misc")
}


#' Infer author-year from basename
#'
#' Extracts the first underscore-delimited token as the author-year identifier.
#' E.g., "saneei2014_diet_diastolic_blood_pressure" -> "saneei2014"
#' Falls back to "unknown" if no tokens.
infer_authoryear_from_basename <- function(basename) {
  tokens <- strsplit(basename, "_", fixed = TRUE)[[1]]
  if (length(tokens) >= 1) {
    return(tokens[1])
  }
  return("unknown")
}


#' Format author-year token as "Author Year"
#'
#' Splits "nunes2022" into author and year components, capitalizes the
#' author name, and returns "Nunes 2022".
format_authoryear_label <- function(authoryear) {
  m <- regmatches(authoryear, regexec("^([A-Za-z]+)(\\d{4})$", authoryear))[[1]]
  if (length(m) == 3) {
    author <- paste0(toupper(substring(m[2], 1, 1)), substring(m[2], 2))
    return(paste(author, m[3]))
  }
  return(authoryear)
}


#' Open a PDF device (cairo_pdf if available, else pdf)
open_pdf_device <- function(file, width, height) {
  if (capabilities("cairo")) {
    grDevices::cairo_pdf(filename = file, width = width, height = height)
  } else {
    grDevices::pdf(file = file, width = width, height = height, useDingbats = FALSE)
  }
}


# ==== Z-VALUE EXTRACTION & ADAPTIVE AXIS BOUNDS =============================
#
# These helpers choose plot x-axis bounds in 2-unit "sections" anchored at even
# integers (-4, -2, 0, 2, 4, 6, 8), then apply a -1 left-pad so the visual
# range preserves the current "-3 ... 6" aesthetic.
#
# Workflow:
#   1. extract_z_values()     - pull observed z-values from available objects
#   2. choose_plot_xlim()     - pick (from, to) based on data range


#' Extract observed z-values from zcurve / fit objects (best-effort)
#'
#' RoBMA fit objects typically store effect sizes (y) and standard errors (se),
#' not pre-computed z-values, so the primary strategy is z = y / se. Falls
#' back to searching zcurve internals and, finally, to adaptive name-based
#' discovery via names() / slotNames().
#'
#' Emits a message() indicating which extraction path succeeded (or that the
#' helper fell back to defaults) for diagnostic transparency.
#'
#' @return Numeric vector of z-values, or NULL if extraction fails.
extract_z_values <- function(primary_zcurve = NULL,
                             zcurve_RE      = NULL,
                             zcurve_RoBMA   = NULL,
                             fit_RE         = NULL,
                             fit_RoBMA      = NULL) {
  # Helper: safely try an expression, return NULL on failure
  safe <- function(expr) tryCatch(expr, error = function(e) NULL)

  # Helper: validate a candidate z vector (numeric, length >= 2, finite values)
  ok <- function(z) is.numeric(z) && length(z) >= 2 && any(is.finite(z))

  # Helper: null-default (avoids depending on rlang or 00_utils.R here)
  null_default <- function(x, default) if (is.null(x)) default else x

  # Helper: return z with diagnostic summary
  found <- function(z, label) {
    message(sprintf("  [axis bounds] %s  (n=%d, range=[%.2f, %.2f])",
                    label, length(z), min(z), max(z)))
    return(z)
  }

  # ---- Priority 1: compute z = y / se from zcurve objects --------------------
  # zcurve objects are what actually get plotted, so they're the authoritative
  # source. They store a $data data.frame with y (effect size) and se.
  for (zc in list(primary_zcurve, zcurve_RoBMA, zcurve_RE)) {
    if (is.null(zc)) next

    # Compute z from $data$y and $data$se (the standard zcurve layout)
    y  <- safe(zc$data$y)
    se <- safe(zc$data$se)
    if (ok(y) && ok(se) && length(y) == length(se)) {
      z <- y / se
      if (ok(z)) return(found(z, "z computed via zcurve$data$y / zcurve$data$se"))
    }

    # Compute from $data$d / $data$se (Cohen's d parameterization)
    d  <- safe(zc$data$d)
    se <- safe(zc$data$se)
    if (ok(d) && ok(se) && length(d) == length(se)) {
      z <- d / se
      if (ok(z)) return(found(z, "z computed via zcurve$data$d / zcurve$data$se"))
    }

    # Direct z field (if it exists)
    z <- safe(zc$z);        if (ok(z)) return(found(z, "z via zcurve$z"))
    z <- safe(zc$data$z);   if (ok(z)) return(found(z, "z via zcurve$data$z"))
    z <- safe(zc$z.scores); if (ok(z)) return(found(z, "z via zcurve$z.scores"))
    z <- safe(attr(zc, "z")); if (ok(z)) return(found(z, "z via attr(zcurve,'z')"))

    # S4 slot access
    if (safe(isS4(zc)) %in% TRUE) {
      for (sn in null_default(safe(slotNames(zc)), character(0))) {
        z <- safe(slot(zc, sn))
        if (ok(z)) return(found(z, paste0("z via zcurve S4 slot '", sn, "'")))
      }
    }
  }

  # ---- Priority 2: compute z = y / se from the RoBMA / RE model fit ---------
  # Fallback: the fit objects may store data differently (e.g., absolute values
  # or transformed scales), so we prefer zcurve objects above.
  for (fit in list(fit_RoBMA, fit_RE)) {
    if (is.null(fit)) next

    # Try fit$data$y / fit$data$se  (RoBMA >= 3.x standard layout)
    y  <- safe(fit$data$y)
    se <- safe(fit$data$se)
    if (ok(y) && ok(se) && length(y) == length(se)) {
      z <- y / se
      if (ok(z)) return(found(z, "z via fit$data$y / fit$data$se"))
    }

    # Try fit$data$d / fit$data$se  (Cohen's d parameterization)
    d  <- safe(fit$data$d)
    se <- safe(fit$data$se)
    if (ok(d) && ok(se) && length(d) == length(se)) {
      z <- d / se
      if (ok(z)) return(found(z, "z via fit$data$d / fit$data$se"))
    }

    # Try fit$data$r -> Fisher z / se  (correlation parameterization)
    r  <- safe(fit$data$r)
    se <- safe(fit$data$se)
    if (ok(r) && ok(se) && length(r) == length(se)) {
      z <- atanh(r) / se
      if (ok(z)) return(found(z, "z via atanh(fit$data$r) / fit$data$se"))
    }

    # Try fit$data$t  (pre-computed t-statistics)
    z <- safe(fit$data$t)
    if (ok(z)) return(found(z, "z via fit$data$t"))

    # Try fit$data$z  (some versions store z directly)
    z <- safe(fit$data$z)
    if (ok(z)) return(found(z, "z via fit$data$z"))

    # Older RoBMA: fit$input variants
    for (path in list(
      quote(fit$input$y / fit$input$se),
      quote(fit$input$d / fit$input$se),
      quote(fit$input$z),
      quote(fit$input$data$y / fit$input$data$se),
      quote(fit$input$data$z)
    )) {
      z <- safe(eval(path))
      if (ok(z)) return(found(z, "z via fit$input path"))
    }
  }

  # ---- Fallback: could not extract ------------------------------------------
  message("  [axis bounds] WARNING: could not extract z-values; using default range -3..6")
  return(NULL)
}


#' Choose plot x-axis bounds from observed z-values
#'
#' Simple approach: floor(min(z)) for left, ceiling(max(z)) for right,
#' clamped to [-6, 8]. Defaults to -3..6 if z is unavailable.
#'
#' @return Named list: list(from, to)
choose_plot_xlim <- function(z) {
  default_from <- -3
  default_to   <-  6

  if (is.null(z) || length(z) < 2) {
    return(list(from = default_from, to = default_to))
  }

  z <- z[is.finite(z)]
  if (length(z) < 2) {
    return(list(from = default_from, to = default_to))
  }

  plot_from <- max(-6, floor(min(z)))
  plot_to   <- min( 8, ceiling(max(z)))

  # Don't shrink tighter than sensible minimums
  plot_from <- min(plot_from, -3)
  plot_to   <- max(plot_to,    4)

  message(sprintf("  [axis bounds] from=%d, to=%d  (z range: [%.2f, %.2f])",
                  plot_from, plot_to, min(z), max(z)))
  return(list(from = plot_from, to = plot_to))
}



# ==== ANALYSIS ===============================================================

#' Print summaries and (optionally) write z-distribution PDFs for one fit
#'
#' Looks up the four objects that 20_robma_fit.R assigns into `envir` for
#' the given basename: fit_RE_<basename>, fit_RoBMA_<basename>, and matching
#' zcurve_* objects. Prints a captured console summary; if `write_files`,
#' also writes z_plot.pdf, z_extrapolation.pdf, and a console.txt under
#' output/<topic>/<authoryear>/{plots,summary}/. The plot-drawer functions
#' are returned in `$plots` so they can be replayed later.
#'
#' @param basename     E.g. "saneei2014_diet_diastolic".
#' @param write_files  If TRUE (default), write PDFs and the console summary.
#'                     Use FALSE for quick console-only inspection.
#' @param output_root  Root directory for written files.
#' @param pdf_width,pdf_height  PDF page size in inches.
#' @param assign_plots If TRUE, also stamp the plot-drawer closures into
#'                     `envir` as <basename>_z_plot / <basename>_z_extrapolation.
#' @param envir        Environment to look up fit objects in (and to assign
#'                     plot drawers if requested). Default: caller's frame.
#'
#' @return Invisibly, list(plots = list(z_plot_fun, z_extrapolation_fun),
#'                          files = list(z_plot_pdf, z_extrapolation_pdf, console_txt))
analyze_robma_fit <- function(
    basename,
    write_files  = TRUE,
    output_root  = "output",
    pdf_width    = 7,
    pdf_height   = 4,
    assign_plots = FALSE,
    envir        = parent.frame()
) {

  # Construct object names
  fit_RE_name <- paste0("fit_RE_", basename)
  fit_RoBMA_name <- paste0("fit_RoBMA_", basename)
  zcurve_RE_name <- paste0("zcurve_RE_", basename)
  zcurve_RoBMA_name <- paste0("zcurve_RoBMA_", basename)

  # Retrieve objects
  fit_RE <- if (exists(fit_RE_name, envir = envir))
    get(fit_RE_name, envir = envir) else NULL
  fit_RoBMA <- if (exists(fit_RoBMA_name, envir = envir))
    get(fit_RoBMA_name, envir = envir) else NULL
  zcurve_RE <- if (exists(zcurve_RE_name, envir = envir))
    get(zcurve_RE_name, envir = envir) else NULL
  zcurve_RoBMA <- if (exists(zcurve_RoBMA_name, envir = envir))
    get(zcurve_RoBMA_name, envir = envir) else NULL

  # Prepare output paths
  topic <- infer_topic_from_basename(basename)
  authoryear <- infer_authoryear_from_basename(basename)
  base_dir <- file.path(output_root, topic, authoryear)
  plots_dir <- file.path(base_dir, "plots")
  summary_dir <- file.path(base_dir, "summary")

  z_plot_pdf_path <- file.path(plots_dir, paste0(basename, "_z_plot.pdf"))
  z_extrapolation_pdf_path <- file.path(plots_dir, paste0(basename, "_z_extrapolation.pdf"))
  console_txt_path <- file.path(summary_dir, paste0(basename, "_console.txt"))

  # Initialize return values for files
  files_written <- list(
    z_plot_pdf = NULL,
    z_extrapolation_pdf = NULL,
    console_txt = NULL
  )


  # ==== ADAPTIVE AXIS BOUNDS (computed once, captured by closures) ============
  # Extract observed z-values, choose from/to.  Falls back to -3..6 if
  # extraction fails.

  z_vals <- extract_z_values(
    primary_zcurve = if (!is.null(zcurve_RoBMA)) zcurve_RoBMA else zcurve_RE,
    zcurve_RE      = zcurve_RE,
    zcurve_RoBMA   = zcurve_RoBMA,
    fit_RE         = fit_RE,
    fit_RoBMA      = fit_RoBMA
  )

  plot_lim <- choose_plot_xlim(z_vals)

  local_plot_from <- plot_lim$from
  local_plot_to   <- plot_lim$to


  # ==== Z-DISTRIBUTION PLOT CLOSURE ==========================================

  z_plot_fun <- NULL
  if (!is.null(zcurve_RoBMA) || !is.null(zcurve_RE)) {
    # Capture the objects needed for the closure
    primary_zcurve <- if (!is.null(zcurve_RoBMA)) zcurve_RoBMA else zcurve_RE
    local_zcurve_RE <- zcurve_RE
    local_zcurve_RoBMA <- zcurve_RoBMA
    local_label <- format_authoryear_label(authoryear)

    z_plot_fun <- function() {
      op <- par(no.readonly = TRUE)
      on.exit(par(op), add = TRUE)
      par(
        mar = c(2.1, 1.9, 2.5, 0.5),
        mgp = c(2.0, 0.6, 0),
        tcl = -0.3,
        las = 1,
        cex.axis = 0.8,
        cex.lab = 0.8
      )

      # Base histogram (suppress internal title)
      hist(primary_zcurve, from = local_plot_from, to = local_plot_to, by = 0.25,
           main = "",
           xlab = "Z-Statistic", ylab = "",
           col = "lightgray", border = "white")

      # Custom title via mtext
      mtext(paste("Z-Plot -", local_label), side = 3, line = 0.8,
            cex = 0.95, font = 2)

      # Legend components
      labs <- cols <- ltys <- lwds <- NULL

      # Add RE line
      if (!is.null(local_zcurve_RE)) {
        lines(local_zcurve_RE, from = local_plot_from, to = local_plot_to, lty = 2, lwd = 2, col = "black")
        labs <- c(labs, "RE")
        cols <- c(cols, "black")
        ltys <- c(ltys, 2)
        lwds <- c(lwds, 2)
      }

      # Add RoBMA line
      if (!is.null(local_zcurve_RoBMA)) {
        lines(local_zcurve_RoBMA, from = local_plot_from, to = local_plot_to, lty = 2, lwd = 2, col = "blue")
        labs <- c(labs, "RoBMA")
        cols <- c(cols, "blue")
        ltys <- c(ltys, 2)
        lwds <- c(lwds, 2)
      }

      invisible(NULL)
    }
  }


  # ==== EXTRAPOLATION PLOT CLOSURE ===========================================

  z_extrapolation_fun <- NULL
  if (!is.null(zcurve_RoBMA)) {
    local_zcurve_RoBMA_extrap <- zcurve_RoBMA
    local_label_extrap <- format_authoryear_label(authoryear)

    z_extrapolation_fun <- function() {
      op <- par(no.readonly = TRUE)
      on.exit(par(op), add = TRUE)
      par(
        mar = c(2.1, 1.9, 2.5, 0.5),
        mgp = c(2.0, 0.6, 0),
        tcl = -0.3,
        las = 1,
        cex.axis = 0.8,
        cex.lab = 0.8
      )

      # RoBMA plot (suppress internal title)
      plot(local_zcurve_RoBMA_extrap, from = local_plot_from, to = local_plot_to, by.hist = 0.25,
           main = "", xlab = "", ylab = "")

      # Custom title via mtext
      mtext(paste("Extrapolation -", local_label_extrap), side = 3, line = 0.8,
            cex = 0.95, font = 2)
      invisible(NULL)
    }
  }


  # ==== ASSIGN PLOT CLOSURES TO ENVIRONMENT ==================================

  if (assign_plots) {
    if (!is.null(z_plot_fun)) {
      assign(paste0(basename, "_z_plot"), z_plot_fun, envir = envir)
    }
    if (!is.null(z_extrapolation_fun)) {
      assign(paste0(basename, "_z_extrapolation"), z_extrapolation_fun, envir = envir)
    }
  }


  # ==== CONSOLE SUMMARIES (capture + print) ==================================

  # Define a function that prints all summaries
  print_summaries <- function() {
    # RE summary
    if (!is.null(fit_RE)) {
      cat("\n---- RE summary:", fit_RE_name, "----\n")
      print(summary(fit_RE))
    } else {
      cat("\n---- RE summary:", fit_RE_name, "(not found) ----\n")
    }

    # RoBMA ensemble summary
    if (!is.null(fit_RoBMA)) {
      cat("\n---- RoBMA (SS) ensemble:", fit_RoBMA_name, "----\n")
      print(summary(fit_RoBMA, type = "ensemble"))
    } else {
      cat("\n---- RoBMA (SS) ensemble:", fit_RoBMA_name, "(not found) ----\n")
    }

    # zcurve RE summary
    if (!is.null(zcurve_RE)) {
      cat("\n---- zcurve RE:", zcurve_RE_name, "----\n")
      print(summary(zcurve_RE))
    } else {
      cat("\n---- zcurve RE:", zcurve_RE_name, "(not found) ----\n")
    }

    # zcurve RoBMA summary
    if (!is.null(zcurve_RoBMA)) {
      cat("\n---- zcurve RoBMA:", zcurve_RoBMA_name, "----\n")
      print(summary(zcurve_RoBMA))
    } else {
      cat("\n---- zcurve RoBMA:", zcurve_RoBMA_name, "(not found) ----\n")
    }

    # Heterogeneity (RE)
    if (!is.null(fit_RE)) {
      cat("\n---- Heterogeneity (RE):", fit_RE_name, "----\n")
      tryCatch(print(summary_heterogeneity(fit_RE)),
               error = function(e) message("heterogeneity: ", e$message))
    }

    # Heterogeneity (RoBMA)
    if (!is.null(fit_RoBMA)) {
      cat("\n---- Heterogeneity (RoBMA):", fit_RoBMA_name, "----\n")
      tryCatch(print(summary_heterogeneity(fit_RoBMA)),
               error = function(e) message("heterogeneity: ", e$message))
    }
  }

  # Capture output once, then print to console once
  console_output <- utils::capture.output(print_summaries(), type = "output")
  cat(paste(console_output, collapse = "\n"), "\n")


  # ==== FILE WRITING =========================================================

  if (write_files) {
    # Create directories
    if (!dir.exists(plots_dir)) {
      dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)
    }
    if (!dir.exists(summary_dir)) {
      dir.create(summary_dir, recursive = TRUE, showWarnings = FALSE)
    }

    # Write z_plot PDF
    if (!is.null(z_plot_fun)) {
      opened <- FALSE
      tryCatch({
        open_pdf_device(z_plot_pdf_path, width = pdf_width, height = pdf_height)
        opened <- TRUE
        z_plot_fun()
        files_written$z_plot_pdf <- z_plot_pdf_path
      }, finally = {
        if (opened) grDevices::dev.off()
      })
    }

    # Write z_extrapolation PDF
    if (!is.null(z_extrapolation_fun)) {
      opened <- FALSE
      tryCatch({
        open_pdf_device(z_extrapolation_pdf_path, width = pdf_width, height = pdf_height)
        opened <- TRUE
        z_extrapolation_fun()
        files_written$z_extrapolation_pdf <- z_extrapolation_pdf_path
      }, finally = {
        if (opened) grDevices::dev.off()
      })
    }

    # Write console summary text file
    writeLines(console_output, con = console_txt_path)
    files_written$console_txt <- console_txt_path
  }


  # ==== RETURN ===============================================================

  invisible(list(
    plots = list(
      z_plot_fun = z_plot_fun,
      z_extrapolation_fun = z_extrapolation_fun
    ),
    files = files_written
  ))
}
