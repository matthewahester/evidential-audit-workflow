# 10_load_data.R
# ------------------------------------------------------------------------------
# Dataset discovery and loading helpers.
#
# Walks data/<topic>/<author>/*.csv and exposes:
#   * list_datasets()  - return a data.frame describing the available CSVs
#   * load_datasets()  - read selected CSVs into an environment (defaults to
#                        the global environment) for downstream fitting
#
# Sourcing this file only defines functions; nothing is read or written.
#
# Quick-Start (run line-by-line)
#   source("scripts/00_utils.R")
#   source("scripts/10_load_data.R")
#   list_datasets()                                          # full catalog
#   list_datasets(only_candidates = TRUE)                    # exclude meta files
#   load_datasets(topic = "Protein", author = "morton2018")  # all matching CSVs
#   load_datasets(topic = "Protein", author = "morton2018",
#                 file = "morton2018_protein_lean_body_mass")  # one file by stem
# ------------------------------------------------------------------------------


# ---- Shared utilities ------------------------------------------------------
# Provides is_meta_basename(). Sentinel-guarded: skipped if already loaded.
if (!exists(".robma_utils_loaded", inherits = TRUE)) {
  for (.p in c("scripts/00_utils.R", "00_utils.R",
               file.path("..", "scripts", "00_utils.R"))) {
    if (file.exists(.p)) { source(.p); break }
  }
  if (exists(".p")) rm(.p)
}


# ==== DATASET DISCOVERY =====================================================

list_datasets <- function(root = "data", only_candidates = FALSE) {
  # Returns a data.frame describing CSV files under `root` with topic, author,
  # file, basename, and absolute path columns.
  #
  # Args:
  #   root            Path to the data directory (default "data").
  #   only_candidates If TRUE, exclude meta/catalog files (see is_meta_basename).
  #
  # Returns: data.frame (possibly with zero rows if no CSVs are found).

  if (!dir.exists(root)) {
    return(data.frame(
      topic = character(), author = character(),
      file = character(), basename = character(), path = character(),
      stringsAsFactors = FALSE
    ))
  }

  all_files <- list.files(root, pattern = "\\.csv$",
                          recursive = TRUE, full.names = TRUE)
  if (length(all_files) == 0) {
    return(data.frame(
      topic = character(), author = character(),
      file = character(), basename = character(), path = character(),
      stringsAsFactors = FALSE
    ))
  }

  # Normalize paths and strip the root prefix so we can split cleanly into
  # <topic>/<author>/<basename>.
  norm_root <- try(normalizePath(root, winslash = .Platform$file.sep,
                                 mustWork = TRUE), silent = TRUE)
  norm_files <- vapply(all_files, function(p) {
    tryCatch(normalizePath(p, winslash = .Platform$file.sep, mustWork = TRUE),
             error = function(e) p)
  }, character(1))

  esc <- function(x) gsub("([\\^$.|()?*+{}\\\\])", "\\\\\\1", x)
  root_rx <- paste0("^", esc(norm_root), esc(.Platform$file.sep))

  relative_paths <- sub(root_rx, "", norm_files)
  parts <- strsplit(relative_paths, .Platform$file.sep, fixed = FALSE)

  topic <- vapply(parts, function(x)
    if (length(x) >= 1) x[1] else NA_character_, character(1))
  author <- vapply(parts, function(x)
    if (length(x) >= 2) x[2] else NA_character_, character(1))
  file <- basename(norm_files)
  base <- tools::file_path_sans_ext(file)

  out <- data.frame(
    topic = topic,
    author = author,
    file = file,
    basename = base,
    path = norm_files,
    stringsAsFactors = FALSE
  )

  if (isTRUE(only_candidates)) {
    out <- out[!is_meta_basename(out$basename), , drop = FALSE]
  }

  # Stable ordering for reproducible iteration.
  out[order(out$topic, out$author, out$basename, na.last = TRUE), , drop = FALSE]
}


# ==== DATASET LOADING =======================================================

load_datasets <- function(topic = NULL, author = NULL, file = NULL,
                          all = FALSE, envir = .GlobalEnv) {
  # Read selected CSVs into `envir` (default: the global environment),
  # assigning each to a variable named after its basename. Existing objects
  # with the same name are overwritten with a message.
  #
  # Args:
  #   topic, author, file  Filters (case-insensitive). `file` accepts either a
  #                        basename stem or a full *.csv filename.
  #   all                  If TRUE, ignore the filters and load everything.
  #   envir                Target environment for the loaded objects.
  #
  # Returns: invisibly, a named list of the loaded data.frames.

  catalog <- list_datasets(only_candidates = TRUE)
  filtered <- catalog

  if (!all) {
    if (!is.null(topic)) {
      filtered <- filtered[tolower(filtered$topic) == tolower(topic), , drop = FALSE]
      if (nrow(filtered) == 0) {
        avail <- unique(catalog$topic)
        if (length(avail) > 10) avail <- c(avail[1:10], "...")
        stop("No datasets found for topic '", topic, "'.\n",
             "Available: ", paste(avail, collapse = ", "))
      }
    }

    if (!is.null(author)) {
      filtered <- filtered[tolower(filtered$author) == tolower(author), , drop = FALSE]
      if (nrow(filtered) == 0) {
        if (!is.null(topic)) {
          avail <- unique(catalog$author[tolower(catalog$topic) == tolower(topic)])
        } else {
          avail <- unique(catalog$author)
        }
        if (length(avail) > 10) avail <- c(avail[1:10], "...")
        stop("No datasets found for author '", author, "'.\n",
             "Available: ", paste(avail, collapse = ", "))
      }
    }

    if (!is.null(file)) {
      if (grepl("\\.csv$", file, ignore.case = TRUE)) {
        filtered <- filtered[tolower(filtered$file) == tolower(file), , drop = FALSE]
      } else {
        filtered <- filtered[tolower(filtered$basename) == tolower(file), , drop = FALSE]
      }
      if (nrow(filtered) == 0) {
        stop("No datasets found for file '", file, "'")
      }
    }
  }

  if (nrow(filtered) == 0) {
    if (nrow(catalog) == 0) stop("No CSV files found in data directory")
    stop("No datasets match the specified filters")
  }

  loaded_data <- list()
  loaded_names <- character(0)

  for (i in seq_len(nrow(filtered))) {
    row <- filtered[i, ]

    obj_name <- row$basename
    if (is.na(obj_name)) {
      warning("Skipping file with missing basename: ", row$path)
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
      df <- readr::read_csv(row$path, show_col_types = FALSE, guess_max = 10000)

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
