# 30_zplot.R
# ------------------------------------------------------------------------------
# Artifact-driven z-plot renderer (RoBMA 4.0).
#
# Reads the canonical per-stratum sidecar
# (output/<stratum>/<stratum>_robma_summary.csv) to discover fitted datasets,
# loads the saved RoBMA 4.0 z-plot artifacts that 20_robma_fit.R writes
# (zplot_RE4_<dataset_id>.rds / zplot_RoBMA4_<dataset_id>.rds, with the
# fit_*4_*.rds fits as a z-value fallback), and renders manuscript-clean
# z-distribution and z-extrapolation PDFs under the dataset's source-article
# output folder.
#
# This replaces the old global-object interface of 30_robma_analysis.R
# (analyze_robma_fit() looked up fit_RE_<basename>/fit_RoBMA_<basename>/
# zcurve_*_<basename> in the global environment). Nothing here depends on
# global objects or requires the user to load anything by hand: after a batch
# fit has run, z-plots are produced purely from the sidecar + saved artifacts.
#
# DEFINE-ONLY: sourcing installs functions/constants only. No sidecar is read,
# no artifact is loaded, no plot is drawn, no directory is created, and no
# package is attached or installed merely by sourcing. 00_utils.R is sourced
# sentinel-guarded (it is itself side-effect-free) for norm_slug()/%||%, the
# same pattern 20/40 use. The RoBMA namespace (which registers the
# hist/lines/plot z-plot S3 methods) is loaded lazily at call time inside
# build_zplots(), never at source time.
#
# Quick-Start
#   source("scripts/30_zplot.R")
#   build_zplots(stratum = "fiber", source_article = "nunes2022")
#   build_zplots(stratum = "fiber", dataset_id = "nunes2022_fiber_lean_body_mass")
#   build_zplots(stratum = "fiber")                      # whole stratum
#   log <- build_zplots(stratum = "fiber", source_article = "whelton2005")
#   log                                                  # attempted-rows log
# ------------------------------------------------------------------------------


# ---- Shared helpers (sentinel-guarded) -------------------------------------
# 00_utils.R provides norm_slug(), %||%, format_stratum(), and
# .outcome_slug_from_stem(); it is define-only so sourcing it has no side
# effects. Mirrors the load pattern in 20_robma_fit.R / 40_batch_fit.R.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# ==== CONSTANTS =============================================================
# v4 artifact filename prefixes written by 20_robma_fit.R (the "4" suffix
# marks RoBMA 4.0 product-space artifacts; archived 3.6.x names are never
# read). Each artifact's tail token is the stable dataset_id stem, e.g.
# zplot_RoBMA4_whelton2005_fiber_systolic_bp.rds.
.ZPLOT_FIT_RE_PREFIX    <- "fit_RE4_"
.ZPLOT_FIT_ROBMA_PREFIX <- "fit_RoBMA4_"
.ZPLOT_ZP_RE_PREFIX     <- "zplot_RE4_"
.ZPLOT_ZP_ROBMA_PREFIX  <- "zplot_RoBMA4_"

# Columns of the invisible per-row log returned by build_zplots().
.ZPLOT_LOG_COLS <- c(
  "stratum", "source_article", "dataset_id", "analysis_id",
  "analysis_variant", "z_plot_pdf", "z_extrapolation_pdf",
  "status", "message"
)

# Manuscript-clean grayscale palette (no hard-coded blue/red). The histogram
# is a light fill; the unadjusted baseline (brma RE) and the bias-adjusted
# RoBMA-PSMA predicted-z curves are distinguished by shade + linetype.
.ZPLOT_HIST_FILL   <- "grey90"
.ZPLOT_HIST_BORDER <- "white"
.ZPLOT_RE_COL      <- "grey45"
.ZPLOT_ROBMA_COL   <- "black"


# ==== RUNTIME (armed at call time, never at source time) ====================
# Loading the RoBMA namespace registers the hist/lines/plot methods for the
# zplot_brma artifacts (S3 methods register on namespace load; RoBMA is NOT
# attached). No JAGS/runjags is needed for rendering saved artifacts.
.ensure_zplot_runtime <- function() {
  if (!requireNamespace("RoBMA", quietly = TRUE)) {
    stop("Package 'RoBMA' is required to render z-plots but is not installed. ",
         "Install it manually; sourcing this script intentionally does not.",
         call. = FALSE)
  }
  invisible(TRUE)
}

# Read a pipeline CONFIG value with a safe fallback when 20_robma_fit.R has
# not been sourced into this session (mirrors .cfg() in 40_batch_fit.R).
.zcfg <- function(key, default) {
  if (exists("CONFIG", envir = .GlobalEnv)) {
    get("CONFIG", envir = .GlobalEnv)[[key]] %||% default
  } else default
}


# ==== HELPERS ===============================================================

# Open a PDF device (cairo_pdf when available for crisp vector text, else the
# base pdf device). Caller is responsible for grDevices::dev.off().
.zplot_pdf_device <- function(file, width, height) {
  if (isTRUE(capabilities("cairo"))) {
    grDevices::cairo_pdf(filename = file, width = width, height = height)
  } else {
    grDevices::pdf(file = file, width = width, height = height,
                   useDingbats = FALSE)
  }
}

# "nunes2022" -> "Nunes 2022"; passes through unrecognized tokens unchanged.
.format_source_label <- function(source_article, source_year = NULL) {
  m <- regmatches(source_article,
                   regexec("^([A-Za-z]+)(\\d{4})$", source_article))[[1]]
  if (length(m) == 3L) {
    author <- paste0(toupper(substring(m[2], 1, 1)), substring(m[2], 2))
    return(paste(author, m[3]))
  }
  if (!is.null(source_year) && !is.na(source_year) &&
      nzchar(as.character(source_year))) {
    return(paste(tools::toTitleCase(gsub("_", " ", source_article)),
                 source_year))
  }
  tools::toTitleCase(gsub("_", " ", source_article))
}

# "lean_body_mass" -> "Lean Body Mass".
.format_outcome_label <- function(outcome_slug) {
  tools::toTitleCase(gsub("_", " ", outcome_slug))
}

# Readable plot title, e.g. "Nunes 2022 - Lean Body Mass"; an exclusion-
# sensitivity variant is flagged so main/excl plots are not confused (file
# identity still relies on dataset_id, never the title).
.zplot_title <- function(row) {
  src <- .format_source_label(row$source_article, row$source_year)
  out <- .format_outcome_label(row$outcome_slug)
  ttl <- sprintf("%s — %s", src, out)
  if (!is.null(row$analysis_variant) &&
      identical(as.character(row$analysis_variant),
                "exclusion_sensitivity")) {
    ttl <- paste0(ttl, " (exclusion sensitivity)")
  }
  ttl
}

# output/<stratum>/<source_article>/ (+ /<outcome> when nest_by_outcome),
# mirroring .paths_for() in 20_robma_fit.R / .out_dir_for() in 40_batch_fit.R
# so the artifact directory cannot drift from where the fitter wrote it.
.zplot_source_dir <- function(output_root, stratum, source_article,
                              dataset_id) {
  d <- file.path(output_root, norm_slug(stratum), norm_slug(source_article))
  if (isTRUE(.zcfg("nest_by_outcome", FALSE))) {
    d <- file.path(d, norm_slug(.outcome_slug_from_stem(dataset_id)))
  }
  d
}

# Canonical per-stratum sidecar path (matches .paths_for()'s sidecar_csv).
.zplot_sidecar_path <- function(output_root, stratum) {
  s <- norm_slug(stratum)
  file.path(output_root, s, sprintf("%s_robma_summary.csv", s))
}

# Read the per-stratum sidecar as a plain data.frame (no factor/parse
# surprises). Missing identity columns are filled with NA so downstream
# subsetting/labelling never errors on an older/leaner sidecar.
.read_stratum_sidecar <- function(sidecar_path) {
  df <- read.csv(sidecar_path, stringsAsFactors = FALSE, check.names = FALSE)
  ident <- c("stratum", "path_stratum", "source_article", "source_key",
             "source_year", "outcome_slug", "dataset_id", "analysis_id",
             "analysis_variant")
  for (cl in ident) if (!cl %in% names(df)) df[[cl]] <- NA
  df
}

# Observed z-values for adaptive axis bounds. The RoBMA 4.0 as_zplot artifact
# stores them directly at $zplot$data$z; fall back to a fit object's
# yi/sei (z = yi/sei). Returns a finite numeric vector or NULL.
.observed_z <- function(zp_robma = NULL, zp_re = NULL,
                        fit_robma = NULL, fit_re = NULL) {
  ok <- function(z) is.numeric(z) && length(z) >= 2L && any(is.finite(z))
  safe <- function(e) tryCatch(e, error = function(x) NULL)

  for (zp in list(zp_robma, zp_re)) {
    if (is.null(zp)) next
    z <- safe(zp$zplot$data$z)
    if (ok(z)) return(z[is.finite(z)])
  }
  for (fit in list(fit_robma, fit_re)) {
    if (is.null(fit)) next
    yi  <- safe(fit$data$outcome$yi)
    sei <- safe(fit$data$outcome$sei)
    if (ok(yi) && ok(sei) && length(yi) == length(sei)) {
      z <- yi / sei
      if (ok(z)) return(z[is.finite(z)])
    }
  }
  NULL
}

# Adaptive x-axis bounds from observed z-values (preserves the old script's
# "-3 .. 6 aesthetic" floor): even-ish integer bounds clamped to [-6, 8] but
# never tighter than [-3, 4]. Defaults to (-3, 6) when z is unavailable.
.zplot_xlim <- function(z) {
  from <- -3; to <- 6
  if (is.null(z)) return(list(from = from, to = to))
  z <- z[is.finite(z)]
  if (length(z) < 2L) return(list(from = from, to = to))
  from <- min(max(-6, floor(min(z))), -3)
  to   <- max(min( 8, ceiling(max(z))), 4)
  list(from = from, to = to)
}

# Shared base-plot margins for a compact, manuscript-clean single panel.
.zplot_par <- function() {
  graphics::par(mar = c(3.0, 3.0, 2.6, 0.6), mgp = c(1.8, 0.6, 0),
                tcl = -0.3, las = 1, cex.axis = 0.8, cex.lab = 0.85)
}


# ==== PLOT DRAWERS ==========================================================
# Each drawer takes already-loaded zplot_brma artifacts and draws into the
# currently open device. They raise on a genuine plotting failure so the
# per-row handler can classify it; "nothing to draw" is signalled by FALSE.

# Z-distribution: histogram of observed z (primary = RoBMA artifact, else RE)
# with the brma-RE and RoBMA-PSMA predicted-z curves overlaid when available.
.draw_z_plot <- function(zp_robma, zp_re, xlim, title) {
  primary <- zp_robma %||% zp_re
  if (is.null(primary)) return(FALSE)

  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  .zplot_par()

  graphics::hist(primary, from = xlim$from, to = xlim$to, by = 0.25,
                 main = "", xlab = "Z-statistic", ylab = "Density",
                 col = .ZPLOT_HIST_FILL, border = .ZPLOT_HIST_BORDER,
                 plot_thresholds = TRUE)

  labs <- character(0); cols <- character(0); ltys <- integer(0)
  if (!is.null(zp_re)) {
    graphics::lines(zp_re, from = xlim$from, to = xlim$to,
                    col = .ZPLOT_RE_COL, plot_ci = FALSE, lty = 2, lwd = 2)
    labs <- c(labs, "Random-effects (brma)")
    cols <- c(cols, .ZPLOT_RE_COL); ltys <- c(ltys, 2L)
  }
  if (!is.null(zp_robma)) {
    graphics::lines(zp_robma, from = xlim$from, to = xlim$to,
                    col = .ZPLOT_ROBMA_COL, plot_ci = FALSE, lty = 1, lwd = 2)
    labs <- c(labs, "RoBMA-PSMA")
    cols <- c(cols, .ZPLOT_ROBMA_COL); ltys <- c(ltys, 1L)
  }
  if (length(labs) > 0) {
    graphics::legend("topright", legend = labs, col = cols, lty = ltys,
                     lwd = 2, bty = "n", cex = 0.8)
  }
  graphics::mtext(title, side = 3, line = 0.8, cex = 0.95, font = 2)
  TRUE
}

# Z-extrapolation: the RoBMA-PSMA bias-adjusted extrapolation panel. Only
# meaningful for the bias-adjusted ensemble, so it requires the RoBMA
# artifact specifically.
.draw_z_extrapolation <- function(zp_robma, xlim, title) {
  if (is.null(zp_robma)) return(FALSE)

  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  .zplot_par()

  graphics::plot(zp_robma, from = xlim$from, to = xlim$to,
                 plot_fit = TRUE, plot_extrapolation = TRUE, plot_ci = TRUE,
                 plot_thresholds = TRUE, by.hist = 0.25,
                 main = "", xlab = "Z-statistic", ylab = "Density")
  graphics::mtext(title, side = 3, line = 0.8, cex = 0.95, font = 2)
  TRUE
}


# ==== PER-ROW RENDER ========================================================
# Render the requested plot_types for ONE sidecar row. Never throws: every
# failure mode is captured and returned as a one-row log data.frame so a bad
# row cannot abort a whole-stratum run. Message vocabulary distinguishes
# artifact-missing / zplot-object-missing / plot-method-failed / unsupported.
.render_one <- function(row, output_root, plot_types, overwrite,
                        pdf_width, pdf_height, verbose) {
  dataset_id <- as.character(row$dataset_id)
  log_row <- data.frame(
    stratum             = as.character(row$stratum),
    source_article      = as.character(row$source_article),
    dataset_id          = dataset_id,
    analysis_id         = as.character(row$analysis_id),
    analysis_variant    = as.character(row$analysis_variant),
    z_plot_pdf          = NA_character_,
    z_extrapolation_pdf = NA_character_,
    status              = "skipped",
    message             = NA_character_,
    stringsAsFactors    = FALSE
  )

  stratum_dir <- norm_slug(row$path_stratum %||% row$stratum)
  src_dir <- .zplot_source_dir(output_root, stratum_dir,
                               row$source_article, dataset_id)
  if (!dir.exists(src_dir)) {
    log_row$status  <- "error"
    log_row$message <- sprintf("source-article output dir missing: %s", src_dir)
    return(log_row)
  }

  zp_robma_p <- file.path(src_dir, paste0(.ZPLOT_ZP_ROBMA_PREFIX,
                                          dataset_id, ".rds"))
  zp_re_p    <- file.path(src_dir, paste0(.ZPLOT_ZP_RE_PREFIX,
                                          dataset_id, ".rds"))
  fit_robma_p <- file.path(src_dir, paste0(.ZPLOT_FIT_ROBMA_PREFIX,
                                           dataset_id, ".rds"))
  fit_re_p    <- file.path(src_dir, paste0(.ZPLOT_FIT_RE_PREFIX,
                                           dataset_id, ".rds"))

  if (!file.exists(zp_robma_p) && !file.exists(zp_re_p)) {
    log_row$status  <- "error"
    log_row$message <- "z-plot artifacts missing (no zplot_*4_<id>.rds)"
    return(log_row)
  }

  rd <- function(p) if (file.exists(p))
    tryCatch(readRDS(p), error = function(e) NULL) else NULL
  zp_robma  <- rd(zp_robma_p)
  zp_re     <- rd(zp_re_p)
  fit_robma <- rd(fit_robma_p)
  fit_re    <- rd(fit_re_p)

  if (is.null(zp_robma) && is.null(zp_re)) {
    log_row$status  <- "error"
    log_row$message <- "zplot object missing (readRDS failed for both RE/RoBMA)"
    return(log_row)
  }
  is_zp <- function(o) !is.null(o) && inherits(o, "zplot_brma")
  if (!is_zp(zp_robma) && !is_zp(zp_re)) {
    log_row$status  <- "error"
    log_row$message <- "unsupported object structure (not a zplot_brma artifact)"
    return(log_row)
  }
  if (!is_zp(zp_robma)) zp_robma <- NULL
  if (!is_zp(zp_re))    zp_re    <- NULL

  xlim  <- .zplot_xlim(.observed_z(zp_robma, zp_re, fit_robma, fit_re))
  title <- .zplot_title(row)

  if (!dir.exists(src_dir)) dir.create(src_dir, recursive = TRUE,
                                       showWarnings = FALSE)
  plots_dir <- file.path(src_dir, "plots")
  dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

  msgs <- character(0)
  any_written <- FALSE
  any_failed  <- FALSE

  # One PDF target. Returns the path on success, NA on skip/failure, and
  # appends a human-readable note to `msgs` in the enclosing frame.
  render_pdf <- function(kind, draw_fun) {
    pdf_path <- file.path(plots_dir,
                          sprintf("%s_%s.pdf", dataset_id, kind))
    if (file.exists(pdf_path) && !overwrite) {
      msgs[[length(msgs) + 1L]] <<- sprintf("%s: exists (overwrite=FALSE)",
                                            kind)
      return(pdf_path)
    }
    opened <- FALSE
    res <- tryCatch({
      .zplot_pdf_device(pdf_path, width = pdf_width, height = pdf_height)
      opened <- TRUE
      drew <- isTRUE(draw_fun())
      grDevices::dev.off(); opened <- FALSE
      drew
    }, error = function(e) {
      if (opened) try(grDevices::dev.off(), silent = TRUE)
      if (file.exists(pdf_path)) unlink(pdf_path)
      structure(FALSE, errmsg = conditionMessage(e))
    })
    if (isTRUE(res)) {
      any_written <<- TRUE
      return(pdf_path)
    }
    if (file.exists(pdf_path)) unlink(pdf_path)
    em <- attr(res, "errmsg")
    if (!is.null(em)) {
      any_failed <<- TRUE
      msgs[[length(msgs) + 1L]] <<- sprintf("%s: plot method failed: %s",
                                            kind, em)
    } else {
      msgs[[length(msgs) + 1L]] <<- sprintf("%s: no drawable object", kind)
    }
    NA_character_
  }

  if ("z_plot" %in% plot_types) {
    log_row$z_plot_pdf <- render_pdf(
      "z_plot", function() .draw_z_plot(zp_robma, zp_re, xlim, title))
  }
  if ("z_extrapolation" %in% plot_types) {
    if (is.null(zp_robma)) {
      msgs[[length(msgs) + 1L]] <-
        "z_extrapolation: requires the RoBMA-PSMA zplot artifact (absent)"
    } else {
      log_row$z_extrapolation_pdf <- render_pdf(
        "z_extrapolation",
        function() .draw_z_extrapolation(zp_robma, xlim, title))
    }
  }

  log_row$status <- if (any_written && !any_failed) "ok"
                    else if (any_written && any_failed) "partial"
                    else if (any_failed) "error"
                    else "skipped"
  if (length(msgs) > 0) log_row$message <- paste(msgs, collapse = "; ")
  else if (log_row$status == "ok") log_row$message <- "written"

  if (verbose) {
    message(sprintf("  [%s] %s%s", log_row$status, dataset_id,
                    if (is.na(log_row$message)) ""
                    else paste0(" - ", log_row$message)))
  }
  log_row
}


# ==== PRIMARY ENTRY POINT ===================================================

#' Render z-plots for fitted datasets, a source article, or a whole stratum.
#'
#' Discovers fitted outcomes from the canonical per-stratum sidecar
#' (output/<stratum>/<stratum>_robma_summary.csv) and renders z-distribution
#' and z-extrapolation PDFs from the saved RoBMA 4.0 artifacts written by
#' 20_robma_fit.R. No global objects and no manual artifact loading required.
#'
#' @param stratum         Required. Stratum slug, e.g. "fiber".
#' @param source_article  Optional. Restrict to one source article (e.g.
#'                         "nunes2022"); compared on the normalized slug.
#' @param dataset_id      Optional. Restrict to one or more exact dataset_id
#'                         stems, e.g. "nunes2022_fiber_lean_body_mass".
#' @param analysis_id     Optional. Restrict to one or more exact analysis_id
#'                         values.
#' @param variant         "all" (default), "main", or
#'                         "exclusion_sensitivity"; filters analysis_variant.
#' @param output_root     Output tree root (default "output").
#' @param plot_types      Which plots to render; subset of
#'                         c("z_plot", "z_extrapolation").
#' @param overwrite       Re-render existing PDFs (default TRUE).
#' @param pdf_width,pdf_height  PDF page size in inches.
#' @param verbose         Show compact per-row progress (default TRUE).
#'
#' @return Invisibly, a data.frame log (one row per attempted dataset) with
#'   columns stratum, source_article, dataset_id, analysis_id,
#'   analysis_variant, z_plot_pdf, z_extrapolation_pdf, status, message.
build_zplots <- function(
    stratum,
    source_article = NULL,
    dataset_id     = NULL,
    analysis_id    = NULL,
    variant        = c("all", "main", "exclusion_sensitivity"),
    output_root    = "output",
    plot_types     = c("z_plot", "z_extrapolation"),
    overwrite      = TRUE,
    pdf_width      = 7,
    pdf_height     = 4,
    verbose        = TRUE
) {
  if (missing(stratum) || is.null(stratum) ||
      !nzchar(as.character(stratum)[1])) {
    stop("`stratum` is required (e.g. build_zplots(stratum = \"fiber\")).",
         call. = FALSE)
  }
  variant <- match.arg(variant)
  plot_types <- match.arg(plot_types, c("z_plot", "z_extrapolation"),
                           several.ok = TRUE)
  .ensure_zplot_runtime()

  empty_log <- function() {
    z <- as.data.frame(
      setNames(replicate(length(.ZPLOT_LOG_COLS), character(0),
                         simplify = FALSE), .ZPLOT_LOG_COLS),
      stringsAsFactors = FALSE)
    z
  }

  sidecar_path <- .zplot_sidecar_path(output_root, stratum)
  if (!file.exists(sidecar_path)) {
    stop(sprintf("Sidecar not found: %s. Run a fit/backfill for stratum '%s' ",
                 sidecar_path, stratum),
         "first (40_batch_fit.R).", call. = FALSE)
  }
  sc <- .read_stratum_sidecar(sidecar_path)
  if (nrow(sc) == 0L) {
    message(sprintf("Sidecar '%s' has no rows.", sidecar_path))
    return(invisible(empty_log()))
  }

  keep <- rep(TRUE, nrow(sc))
  if (!is.null(source_article)) {
    keep <- keep & norm_slug(sc$source_article) %in% norm_slug(source_article)
  }
  if (!is.null(dataset_id)) {
    keep <- keep & as.character(sc$dataset_id) %in% as.character(dataset_id)
  }
  if (!is.null(analysis_id)) {
    keep <- keep & as.character(sc$analysis_id) %in% as.character(analysis_id)
  }
  if (variant != "all") {
    keep <- keep & as.character(sc$analysis_variant) %in% variant
  }
  sc <- sc[keep, , drop = FALSE]

  if (nrow(sc) == 0L) {
    message("No sidecar rows match the supplied filters ",
            "(stratum/source_article/dataset_id/analysis_id/variant).")
    return(invisible(empty_log()))
  }

  if (verbose) {
    message(sprintf("build_zplots: %d dataset(s) in stratum '%s'%s.",
                     nrow(sc), stratum,
                     if (!is.null(source_article))
                       sprintf(", source_article '%s'",
                               paste(source_article, collapse = ",")) else ""))
  }

  logs <- vector("list", nrow(sc))
  for (i in seq_len(nrow(sc))) {
    logs[[i]] <- tryCatch(
      .render_one(sc[i, , drop = FALSE], output_root, plot_types,
                  overwrite, pdf_width, pdf_height, verbose),
      error = function(e) {
        r <- sc[i, , drop = FALSE]
        data.frame(
          stratum = as.character(r$stratum),
          source_article = as.character(r$source_article),
          dataset_id = as.character(r$dataset_id),
          analysis_id = as.character(r$analysis_id),
          analysis_variant = as.character(r$analysis_variant),
          z_plot_pdf = NA_character_, z_extrapolation_pdf = NA_character_,
          status = "error",
          message = sprintf("render aborted: %s", conditionMessage(e)),
          stringsAsFactors = FALSE)
      })
  }
  log <- do.call(rbind, logs)
  log <- log[, .ZPLOT_LOG_COLS, drop = FALSE]
  rownames(log) <- NULL

  if (verbose) {
    tab <- table(factor(log$status,
                         levels = c("ok", "partial", "skipped", "error")))
    message(sprintf("build_zplots done: ok=%d partial=%d skipped=%d error=%d",
                     tab["ok"], tab["partial"], tab["skipped"], tab["error"]))
  }
  invisible(log)
}


# ==== CONVENIENCE WRAPPERS ==================================================

#' Render z-plots for every fitted dataset of one source article.
build_zplots_for_source <- function(stratum, source_article, ...) {
  build_zplots(stratum = stratum, source_article = source_article, ...)
}

#' Render z-plots for one (or more) exact dataset_id stem(s).
build_zplots_for_dataset <- function(stratum, dataset_id, ...) {
  build_zplots(stratum = stratum, dataset_id = dataset_id, ...)
}


# ==== DEPRECATED BACK-COMPAT SHIM ===========================================
# The pre-v4 analyze_robma_fit(basename, ...) looked up global fit/zcurve
# objects (fit_RE_<basename> etc.). That interface is removed. This tiny
# shim only maps the old basename -> the artifact-driven build_zplots()
# (basename == dataset_id; token 2 of the stem is the stratum) so old call
# sites degrade gracefully instead of erroring on missing globals.
analyze_robma_fit <- function(basename, output_root = "output", ...) {
  .Deprecated("build_zplots",
              msg = paste0("analyze_robma_fit() is deprecated and no longer ",
                           "uses global fit/zcurve objects. Use ",
                           "build_zplots(stratum=, dataset_id=) instead; ",
                           "forwarding by dataset_id."))
  toks <- strsplit(basename, "_", fixed = TRUE)[[1]]
  if (length(toks) < 2L) {
    stop("Cannot infer stratum from basename '", basename,
         "'. Call build_zplots(stratum=, dataset_id=) directly.",
         call. = FALSE)
  }
  build_zplots(stratum = tolower(toks[2]), dataset_id = basename,
               output_root = output_root, ...)
}
