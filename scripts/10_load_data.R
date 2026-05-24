# 10_load_data.R
# ------------------------------------------------------------------------------
# Dataset discovery and loading for the active fitting layer.
#
# Walks the physical data/<stratum>/<source_article>/*.csv tree and exposes:
#   * list_datasets()  - a data.frame describing each analysis-ready CSV with
#                        the v4 identity vocabulary parsed once by the shared
#                        .build_identity_fields() (00_utils.R), so the
#                        catalog's analysis_id / dataset_id agree exactly with
#                        what 20_robma_fit.R writes to the sidecar.
#   * load_datasets()  - read selected CSVs into an environment (default: the
#                        global env) for fitting.
#
# Define-only: sourcing installs functions; nothing is read or written.
#
# Catalog columns:
#   path           absolute CSV path
#   dataset_file   CSV filename
#   dataset_stem   on-disk stem (object name + fit-artifact infix)
#   path_stratum   physical stratum folder name (e.g. "Fiber")
#   path_article   physical source-article folder name (e.g. "whelton2005")
#   corpus_id scheme stratum dataset_id analysis_id source_key
#   source_article source_year outcome_slug analysis_variant
#   parent_dataset_id has_excl_variant
#
# Quick-Start
#   source("scripts/00_utils.R"); source("scripts/10_load_data.R")
#   list_datasets(only_candidates = TRUE)
#   load_datasets(stratum = "fiber", source_article = "whelton2005")
#   load_datasets(file = "whelton2005_fiber_systolic_bp")   # one stem
# ------------------------------------------------------------------------------


# ---- Shared utilities (sentinel-guarded) -----------------------------------
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# ==== DATASET DISCOVERY =====================================================

# Canonical empty catalog (stable schema for every zero-row return so 40's
# plan_from_data / load_datasets always see the same columns).
.empty_catalog <- function() {
  data.frame(
    path = character(), dataset_file = character(),
    dataset_stem = character(),
    path_stratum = character(), path_article = character(),
    corpus_id = character(), scheme = character(),
    stratum = character(), source_key = character(),
    source_article = character(), source_year = integer(),
    outcome_slug = character(), dataset_id = character(),
    analysis_id = character(), analysis_variant = character(),
    parent_dataset_id = character(), has_excl_variant = logical(),
    stringsAsFactors = FALSE
  )
}

# Attach the v4 identity vocabulary to a frame carrying the physical
# path_stratum / path_article folder names and the on-disk dataset_stem.
# corpus_id/scheme come from CONFIG when 20 has been sourced, else defaults.
.augment_catalog_identity <- function(out) {
  cfg_get <- function(k, d) {
    if (exists("CONFIG", envir = .GlobalEnv))
      (get("CONFIG", envir = .GlobalEnv)[[k]] %||% d) else d
  }
  corpus_id <- cfg_get("corpus_id", "nutrition_v4")
  scheme    <- cfg_get("scheme",    "nutrition_domain")

  ident <- lapply(seq_len(nrow(out)), function(i) {
    ps <- out$path_stratum[i]; pa <- out$path_article[i]
    st <- out$dataset_stem[i]
    if (is.na(ps) || is.na(pa) || is.na(st)) {
      return(.build_identity_fields(corpus_id, scheme,
               NA_character_, NA_character_, NA_character_,
               NA_character_, NA_character_))
    }
    stratum_s <- norm_slug(ps)
    article_s <- norm_slug(pa)
    out_s     <- norm_slug(.outcome_slug_from_stem(st))
    did       <- sprintf("%s_%s_%s", article_s, stratum_s, out_s)
    .build_identity_fields(corpus_id, scheme, stratum_s,
                           article_s, out_s, did, ps)
  })

  g <- function(nm, mode = "character") {
    vapply(ident, function(x) {
      val <- x[[nm]]
      if (is.null(val) || length(val) == 0L) NA else val[1]
    }, if (mode == "integer") integer(1)
       else if (mode == "logical") logical(1)
       else character(1))
  }

  out$corpus_id         <- g("corpus_id")
  out$scheme            <- g("scheme")
  out$stratum           <- g("stratum")
  out$source_key        <- g("source_key")
  out$source_article    <- g("source_article")
  out$source_year       <- g("source_year", "integer")
  out$outcome_slug      <- g("outcome_slug")
  out$dataset_id        <- g("dataset_id")
  out$analysis_id       <- g("analysis_id")
  out$analysis_variant  <- g("analysis_variant")
  out$parent_dataset_id <- g("parent_dataset_id")
  out$has_excl_variant  <- g("has_excl_variant", "logical")
  out
}

list_datasets <- function(root = "data", only_candidates = FALSE) {
  # Discover analysis-ready CSVs under `root` and return the v4 catalog.
  #
  # Args:
  #   root            data directory (default "data").
  #   only_candidates exclude meta/extraction-record files (is_meta_basename).
  #
  # Returns: data.frame (zero rows -> .empty_catalog() schema).

  if (!dir.exists(root)) return(.empty_catalog())

  all_files <- list.files(root, pattern = "\\.csv$",
                          recursive = TRUE, full.names = TRUE)
  if (length(all_files) == 0) return(.empty_catalog())

  # Strip the root prefix and split into <stratum>/<source_article>/<stem>.
  norm_root <- try(normalizePath(root, winslash = .Platform$file.sep,
                                 mustWork = TRUE), silent = TRUE)
  norm_files <- vapply(all_files, function(p) {
    tryCatch(normalizePath(p, winslash = .Platform$file.sep, mustWork = TRUE),
             error = function(e) p)
  }, character(1))

  esc <- function(x) gsub("([\\^$.|()?*+{}\\\\])", "\\\\\\1", x)
  root_rx <- paste0("^", esc(norm_root), esc(.Platform$file.sep))
  parts <- strsplit(sub(root_rx, "", norm_files), .Platform$file.sep,
                    fixed = FALSE)

  path_stratum <- vapply(parts, function(x)
    if (length(x) >= 1) x[1] else NA_character_, character(1))
  path_article <- vapply(parts, function(x)
    if (length(x) >= 2) x[2] else NA_character_, character(1))
  dataset_file <- basename(norm_files)
  dataset_stem <- tools::file_path_sans_ext(dataset_file)

  out <- data.frame(
    path = norm_files,
    dataset_file = dataset_file,
    dataset_stem = dataset_stem,
    path_stratum = path_stratum,
    path_article = path_article,
    stringsAsFactors = FALSE
  )

  if (isTRUE(only_candidates)) {
    out <- out[!is_meta_basename(out$dataset_stem), , drop = FALSE]
  }
  if (nrow(out) == 0L) return(.empty_catalog())

  out <- .augment_catalog_identity(out)
  out <- out[order(out$path_stratum, out$path_article, out$dataset_stem,
                   na.last = TRUE), , drop = FALSE]
  rownames(out) <- NULL
  out
}


# ==== DATASET LOADING =======================================================

load_datasets <- function(stratum = NULL, source_article = NULL,
                          file = NULL, all = FALSE, envir = .GlobalEnv) {
  # Read selected CSVs into `envir`, each assigned to a variable named after
  # its on-disk stem. Existing objects with the same name are overwritten
  # with a message.
  #
  # Args:
  #   stratum         filter on stratum (matches path-folder OR slug).
  #   source_article  filter on source article (path-folder OR slug).
  #   file            a *.csv filename or a dataset stem.
  #   all             ignore filters and load everything.
  #   envir           target environment for loaded objects.
  #
  # Returns: invisibly, a named list of the loaded data.frames.

  catalog  <- list_datasets(only_candidates = TRUE)
  filtered <- catalog

  ci_in <- function(x, val) tolower(x) == tolower(val)

  if (!all) {
    if (!is.null(stratum)) {
      keep <- ci_in(filtered$path_stratum, stratum) |
              ci_in(filtered$stratum, stratum)
      filtered <- filtered[keep, , drop = FALSE]
      if (nrow(filtered) == 0) {
        avail <- unique(catalog$stratum)
        if (length(avail) > 10) avail <- c(avail[1:10], "...")
        stop("No datasets found for stratum '", stratum, "'.\n",
             "Available: ", paste(avail, collapse = ", "))
      }
    }

    if (!is.null(source_article)) {
      keep <- ci_in(filtered$path_article, source_article) |
              ci_in(filtered$source_article, source_article)
      filtered <- filtered[keep, , drop = FALSE]
      if (nrow(filtered) == 0) {
        avail <- unique(catalog$source_article)
        if (length(avail) > 10) avail <- c(avail[1:10], "...")
        stop("No datasets found for source_article '", source_article,
             "'.\nAvailable: ", paste(avail, collapse = ", "))
      }
    }

    if (!is.null(file)) {
      if (grepl("\\.csv$", file, ignore.case = TRUE)) {
        filtered <- filtered[ci_in(filtered$dataset_file, file), ,
                             drop = FALSE]
      } else {
        filtered <- filtered[ci_in(filtered$dataset_stem, file), ,
                             drop = FALSE]
      }
      if (nrow(filtered) == 0) stop("No datasets found for file '", file, "'")
    }
  }

  if (nrow(filtered) == 0) {
    if (nrow(catalog) == 0) stop("No CSV files found in data directory")
    stop("No datasets match the specified filters")
  }

  loaded_data  <- list()
  loaded_names <- character(0)

  for (i in seq_len(nrow(filtered))) {
    row <- filtered[i, ]

    obj_name <- row$dataset_stem
    if (is.na(obj_name)) {
      warning("Skipping file with missing stem: ", row$path)
      next
    }
    if (make.names(obj_name) != obj_name) {
      sanitized_name <- make.names(obj_name)
      message("Sanitizing '", obj_name, "' to '", sanitized_name, "'")
      obj_name <- sanitized_name
    }
    if (exists(obj_name, envir = envir)) {
      message("Overwriting existing object '", obj_name, "'")
    }

    tryCatch({
      df <- readr::read_csv(row$path, show_col_types = FALSE,
                            guess_max = 10000)
      if (!is.data.frame(df) || nrow(df) == 0) {
        message("Skipping empty dataframe: '", row$path, "'")
        next
      }
      assign(obj_name, df, envir = envir)
      loaded_data[[obj_name]] <- df
      loaded_names <- c(loaded_names, obj_name)
    }, error = function(e) {
      warning("Failed to read '", row$path, "': ", conditionMessage(e))
    })
  }

  if (length(loaded_names) > 0) {
    message("Loaded ", length(loaded_names), " dataset(s): ",
            paste(loaded_names, collapse = ", "))
  }

  invisible(loaded_data)
}
