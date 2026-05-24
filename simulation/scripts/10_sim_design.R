# 10_sim_design.R — load and validate the current full36 simulation design.
#
# Define-only on source. Provides one entry point, `sim_load_design()`,
# that loads `simulation/config/design_v3_full36.csv` (the only
# operational design config) and returns a validated 36-cell data frame.
# Two layers of validation are applied:
#   * DGM checks — band membership (e0..e3 / h0..h2 / b0..b2), selection
#     vocabulary, weight ranges, the b0 clean-control rule, the b1/b2
#     threshold-selection rule, and monotone bias severity within each
#     (effect, het) pair;
#   * identity checks — slug↔band consistency via the in-code crosswalk,
#     `cell == cell_slug`, `stratum == sim_<cell_slug>`,
#     `legacy_cell_code == <eff>_<het>_<bias>`, path-safe slugs, anchor
#     consistency, and the full 4×3×3 = 36-cell grid.
#
# Returns the design table used by the generator (20/30/40) and by
# downstream diagnostics (45/50/55/65/70). No generation, no fitting,
# no disk writes.

if (!exists(".robma_sim_utils_loaded", inherits = TRUE) ||
    !isTRUE(.robma_sim_utils_loaded)) {
  source("simulation/scripts/00_sim_utils.R")
}

# ---------------------------------------------------------------------------
# Canonical band tables (used for validation).
# ---------------------------------------------------------------------------

.sim_eff_anchors <- c(e0 = 0.00, e1 = 0.10, e2 = 0.25, e3 = 0.50)
.sim_het_anchors <- c(h0 = 0.05, h1 = 0.15, h2 = 0.40)

# (sig01, sig05, ns) weights for each bias band. b0 is no-selection (all 1).
.sim_bias_weights <- list(
  b0 = c(sig01 = 1.00, sig05 = 1.00, ns = 1.00),
  b1 = c(sig01 = 1.00, sig05 = 0.50, ns = 0.20),
  b2 = c(sig01 = 1.00, sig05 = 0.25, ns = 0.05)
)

# Composite-bias schedule: SE-proportional small-study burden that pairs
# with the threshold-selection weights above. b0 stays clean; b1 adds
# mild small-study bias; b2 adds stronger small-study bias. This turns
# the bias axis into an ordered composite-burden axis without adding a
# fourth design dimension.
.sim_bias_alpha <- c(b0 = 0.00, b1 = 0.25, b2 = 0.50)

# Canonical band <-> readable-slug crosswalk. These constants ARE the
# crosswalk contract (no external CSV is read). They must agree with
# simulation/config/design_v3_full36.csv. Used to validate that a
# design's slugs are consistent with its legacy band codes (and that
# cell_slug / stratum / legacy_cell_code line up).
.sim_eff_slug  <- c(e0 = "null",   e1 = "small",  e2 = "moderate", e3 = "large")
.sim_het_slug  <- c(h0 = "lowhet", h1 = "midhet", h2 = "highhet")
.sim_bias_slug <- c(b0 = "clean",  b1 = "modbias", b2 = "highbias")

# Convenience defaults filled into the design when the CSV doesn't ship
# replicate/n-sampler columns. The operational path supplies the
# replicate count via sim_run_design(n_replicates_override = ...); these
# values exist only so `mode = "pilot"` and `mode = "full"` are
# well-defined without an override.
.SIM_DEFAULT_PILOT_REPS <- 25L
.SIM_DEFAULT_FULL_REPS  <- 150L
.SIM_DEFAULT_N_MEANLOG  <- log(30)
.SIM_DEFAULT_N_SDLOG    <- 0.6

#' Load the current full36 simulation design table.
#'
#' Reads the v3 full36 design CSV
#' (`simulation/config/design_v3_full36.csv` by default) and returns a
#' validated 36-cell data frame suitable for `sim_run_design()`.
#'
#' Required CSV columns (the v3 CSV ships all of these):
#'   cell, cell_slug, stratum, legacy_cell_code,
#'   eff_band, effect_slug, mu_true,
#'   het_band, heterogeneity_slug, tau_true,
#'   bias_band, bias_slug,
#'   selection, w_sig01, w_sig05, w_ns, smallstudy_alpha
#'
#' Optional columns (filled with the defaults above if absent):
#'   n_replicates_pilot, n_replicates_full, n_meanlog, n_sdlog
#'
#' Other columns (e.g. `effect_label`, `cell_label`, `stress_role`,
#' `notes`) are preserved as-is.
#'
#' Validation (all checks fatal):
#'   * required columns present;
#'   * `cell`, `stratum`, `cell_slug`, `legacy_cell_code` are each unique;
#'   * `eff_band` in {e0, e1, e2, e3};
#'   * `het_band` in {h0, h1, h2};
#'   * `bias_band` in {b0, b1, b2};
#'   * `selection` in {none, threshold};
#'   * `w_sig01`, `w_sig05`, `w_ns` are finite numerics in [0, 1];
#'   * b0 rows have all selection weights == 1, `selection == "none"`,
#'     and `smallstudy_alpha == 0`;
#'   * b1/b2 rows use threshold selection and nonnegative smallstudy_alpha;
#'   * monotone threshold severity and small-study burden within each
#'     (eff, het) pair (b2 at least as severe as b1);
#'   * `effect_slug`/`heterogeneity_slug`/`bias_slug` match their band
#'     codes via the canonical crosswalk;
#'   * `cell_slug == <effect>_<het>_<bias>`, `cell == cell_slug`,
#'     `stratum == sim_<cell_slug>`,
#'     `legacy_cell_code == <eff_band>_<het_band>_<bias_band>`;
#'   * `mu_true`/`tau_true` equal the effect/heterogeneity anchors;
#'   * `cell_slug` and `stratum` are path-safe (`^[a-z0-9_]+$`);
#'   * when `expect_full36` is TRUE (default), the design is the
#'     complete 4×3×3 = 36-cell grid.
#'
#' @param path Path to a design CSV. Default `.SIM_DEFAULT_DESIGN_PATH`.
#' @param expect_full36 If TRUE (default), require the complete 36-cell
#'   grid. Set FALSE only for a deliberate subset (e.g. tests).
#'
#' @return A data frame with one row per simulation cell.
sim_load_design <- function(path = .SIM_DEFAULT_DESIGN_PATH,
                            expect_full36 = TRUE) {

  if (is.null(path) || !nzchar(path) || !file.exists(path)) {
    stop("Design CSV not found: '", path %||% "<NULL>", "'.")
  }
  df <- utils::read.csv(path, stringsAsFactors = FALSE)

  # Convenience defaults: only the four sampler/replicate-count columns
  # are filled when absent. Everything else must be on the CSV.
  if (!"n_replicates_pilot" %in% names(df))
    df$n_replicates_pilot <- .SIM_DEFAULT_PILOT_REPS
  if (!"n_replicates_full"  %in% names(df))
    df$n_replicates_full  <- .SIM_DEFAULT_FULL_REPS
  if (!"n_meanlog"          %in% names(df))
    df$n_meanlog          <- .SIM_DEFAULT_N_MEANLOG
  if (!"n_sdlog"            %in% names(df))
    df$n_sdlog            <- .SIM_DEFAULT_N_SDLOG

  required_cols <- c(
    "cell", "cell_slug", "stratum", "legacy_cell_code",
    "eff_band", "effect_slug", "het_band", "heterogeneity_slug",
    "bias_band", "bias_slug",
    "mu_true", "tau_true",
    "selection", "w_sig01", "w_sig05", "w_ns", "smallstudy_alpha",
    "n_replicates_pilot", "n_replicates_full",
    "n_meanlog", "n_sdlog")
  missing <- setdiff(required_cols, names(df))
  if (length(missing)) {
    stop("Design table is missing required columns: ",
         paste(missing, collapse = ", "), ".")
  }

  # ---- type coercion -----------------------------------------------------
  for (.c in c("cell", "cell_slug", "stratum", "legacy_cell_code",
               "eff_band", "effect_slug", "het_band", "heterogeneity_slug",
               "bias_band", "bias_slug", "selection"))
    df[[.c]] <- as.character(df[[.c]])
  df$mu_true            <- as.numeric(df$mu_true)
  df$tau_true           <- as.numeric(df$tau_true)
  df$w_sig01            <- as.numeric(df$w_sig01)
  df$w_sig05            <- as.numeric(df$w_sig05)
  df$w_ns               <- as.numeric(df$w_ns)
  df$smallstudy_alpha   <- as.numeric(df$smallstudy_alpha)
  df$n_replicates_pilot <- as.integer(df$n_replicates_pilot)
  df$n_replicates_full  <- as.integer(df$n_replicates_full)
  df$n_meanlog          <- as.numeric(df$n_meanlog)
  df$n_sdlog            <- as.numeric(df$n_sdlog)

  # ---- validation --------------------------------------------------------
  .sim_validate_design_dgm(df)
  .sim_validate_design_identity(df, expect_full36 = expect_full36)
  df
}

#' DGM-layer design validation.
#'
#' Internal: stops on any structural violation in the band / selection /
#' weight / monotonicity layer. Exposed for tests.
.sim_validate_design_dgm <- function(df) {

  # Unique cell names.
  dup <- df$cell[duplicated(df$cell)]
  if (length(dup)) {
    stop("Duplicate cell names in design: ", paste(unique(dup), collapse = ", "))
  }

  # Valid band codes.
  bad_e <- !df$eff_band %in% names(.sim_eff_anchors)
  bad_h <- !df$het_band %in% names(.sim_het_anchors)
  bad_b <- !df$bias_band %in% names(.sim_bias_weights)
  if (any(bad_e)) {
    stop("Unknown eff_band values: ",
         paste(unique(df$eff_band[bad_e]), collapse = ", "),
         ". Allowed: ", paste(names(.sim_eff_anchors), collapse = ", "), ".")
  }
  if (any(bad_h)) {
    stop("Unknown het_band values: ",
         paste(unique(df$het_band[bad_h]), collapse = ", "),
         ". Allowed: ", paste(names(.sim_het_anchors), collapse = ", "), ".")
  }
  if (any(bad_b)) {
    stop("Unknown bias_band values: ",
         paste(unique(df$bias_band[bad_b]), collapse = ", "),
         ". Allowed: ", paste(names(.sim_bias_weights), collapse = ", "), ".")
  }

  # Selection vocabulary.
  bad_sel <- !df$selection %in% c("none", "threshold")
  if (any(bad_sel)) {
    stop("Unknown selection values: ",
         paste(unique(df$selection[bad_sel]), collapse = ", "),
         ". Allowed: 'none', 'threshold'.")
  }

  # Selection weights numeric and in [0, 1].
  for (col in c("w_sig01", "w_sig05", "w_ns")) {
    v <- df[[col]]
    if (!is.numeric(v) || any(!is.finite(v)) || any(v < 0) || any(v > 1)) {
      stop("Column '", col, "' must be finite numeric in [0, 1].")
    }
  }

  # b0 rows are truly no-selection: all weights == 1, selection == "none",
  # and no small-study bias (b0 is the clean negative control).
  is_b0 <- df$bias_band == "b0"
  if (any(is_b0)) {
    if (any(df$selection[is_b0] != "none")) {
      stop("b0 rows must have selection == 'none'. Offenders: ",
           paste(df$cell[is_b0 & df$selection != "none"], collapse = ", "))
    }
    bad_w <- abs(df$w_sig01[is_b0] - 1) > 1e-12 |
             abs(df$w_sig05[is_b0] - 1) > 1e-12 |
             abs(df$w_ns   [is_b0] - 1) > 1e-12
    if (any(bad_w)) {
      stop("b0 rows must have (w_sig01, w_sig05, w_ns) = (1, 1, 1). ",
           "Offenders: ", paste(df$cell[is_b0][bad_w], collapse = ", "))
    }
    bad_a <- abs(df$smallstudy_alpha[is_b0]) > 1e-12
    if (any(bad_a)) {
      stop("b0 rows must have smallstudy_alpha = 0 (clean negative ",
           "control). Offenders: ",
           paste(df$cell[is_b0][bad_a], collapse = ", "))
    }
  }

  # b1/b2 rows are threshold-selection rows with nonnegative small-study
  # burden; b2 at least as severe as b1 on that axis.
  is_b1_or_b2 <- df$bias_band %in% c("b1", "b2")
  if (any(is_b1_or_b2)) {
    bad_sel2 <- df$selection[is_b1_or_b2] != "threshold"
    if (any(bad_sel2)) {
      stop("b1 and b2 rows must have selection == 'threshold'. Offenders: ",
           paste(df$cell[is_b1_or_b2][bad_sel2], collapse = ", "))
    }
    if (any(df$smallstudy_alpha[is_b1_or_b2] < 0)) {
      stop("smallstudy_alpha must be non-negative on b1/b2 rows.")
    }
  }

  # Composite-bias monotonicity on small-study burden.
  key_eh <- paste0(df$eff_band, "_", df$het_band)
  for (k in unique(key_eh)) {
    sub <- df[key_eh == k, , drop = FALSE]
    if (all(c("b1", "b2") %in% sub$bias_band)) {
      a1 <- sub$smallstudy_alpha[sub$bias_band == "b1"]
      a2 <- sub$smallstudy_alpha[sub$bias_band == "b2"]
      if (a2 < a1 - 1e-12) {
        stop("Non-monotone composite bias at ", k, ": ",
             "b2 smallstudy_alpha (", a2, ") < b1 (", a1, ").")
      }
    }
  }

  # Monotone threshold severity: b2's w_sig05 and w_ns weights must be
  # <= b1 within each (eff, het) pair.
  for (k in unique(key_eh)) {
    sub <- df[key_eh == k, , drop = FALSE]
    if (all(c("b1", "b2") %in% sub$bias_band)) {
      b1 <- sub[sub$bias_band == "b1", ]
      b2 <- sub[sub$bias_band == "b2", ]
      if (b2$w_sig05 > b1$w_sig05 + 1e-12 ||
          b2$w_ns    > b1$w_ns    + 1e-12) {
        stop("Non-monotone bias severity at ", k, ": ",
             "b2 must be at least as severe as b1 ",
             "(w_sig05_b2 <= w_sig05_b1 and w_ns_b2 <= w_ns_b1).")
      }
    }
  }

  invisible(df)
}

#' Identity-layer design validation.
#'
#' Internal: stops on any violation of the readable-slug / cell-id /
#' grid-completeness contract. By default requires the full 36-cell
#' grid; set `expect_full36 = FALSE` for a deliberate subset.
.sim_validate_design_identity <- function(df, expect_full36 = TRUE) {

  # Uniqueness of every identity key.
  for (col in c("cell", "stratum", "cell_slug", "legacy_cell_code")) {
    dup <- df[[col]][duplicated(df[[col]])]
    if (length(dup)) {
      stop("Design has duplicate ", col, " values: ",
           paste(unique(dup), collapse = ", "), ".")
    }
  }

  # Slug <-> band consistency via the canonical crosswalk.
  exp_eff  <- unname(.sim_eff_slug[df$eff_band])
  exp_het  <- unname(.sim_het_slug[df$het_band])
  exp_bias <- unname(.sim_bias_slug[df$bias_band])
  bad_eff  <- which(df$effect_slug        != exp_eff)
  bad_het  <- which(df$heterogeneity_slug != exp_het)
  bad_bias <- which(df$bias_slug          != exp_bias)
  if (length(bad_eff)) {
    stop("effect_slug inconsistent with eff_band at cell(s): ",
         paste(df$cell[bad_eff], collapse = ", "), ".")
  }
  if (length(bad_het)) {
    stop("heterogeneity_slug inconsistent with het_band at cell(s): ",
         paste(df$cell[bad_het], collapse = ", "), ".")
  }
  if (length(bad_bias)) {
    stop("bias_slug inconsistent with bias_band at cell(s): ",
         paste(df$cell[bad_bias], collapse = ", "), ".")
  }

  # Composite-name identities.
  exp_slug   <- paste(df$effect_slug, df$heterogeneity_slug,
                      df$bias_slug, sep = "_")
  exp_legacy <- paste(df$eff_band, df$het_band, df$bias_band, sep = "_")
  if (any(df$cell_slug != exp_slug)) {
    bad <- df$cell[df$cell_slug != exp_slug]
    stop("cell_slug must equal <effect_slug>_<heterogeneity_slug>_",
         "<bias_slug>. Offenders: ", paste(bad, collapse = ", "), ".")
  }
  if (any(df$cell != df$cell_slug)) {
    bad <- df$cell[df$cell != df$cell_slug]
    stop("`cell` must equal `cell_slug`. Offenders: ",
         paste(bad, collapse = ", "), ".")
  }
  if (any(df$stratum != paste0("sim_", df$cell_slug))) {
    bad <- df$cell[df$stratum != paste0("sim_", df$cell_slug)]
    stop("`stratum` must equal sim_<cell_slug>. Offenders: ",
         paste(bad, collapse = ", "), ".")
  }
  if (any(df$legacy_cell_code != exp_legacy)) {
    bad <- df$cell[df$legacy_cell_code != exp_legacy]
    stop("legacy_cell_code must equal <eff_band>_<het_band>_<bias_band>. ",
         "Offenders: ", paste(bad, collapse = ", "), ".")
  }

  # DGM anchors: mu_true / tau_true must match the band anchors.
  exp_mu  <- unname(.sim_eff_anchors[df$eff_band])
  exp_tau <- unname(.sim_het_anchors[df$het_band])
  if (any(abs(df$mu_true - exp_mu) > 1e-9)) {
    bad <- df$cell[abs(df$mu_true - exp_mu) > 1e-9]
    stop("mu_true does not match the effect anchor at cell(s): ",
         paste(bad, collapse = ", "), ".")
  }
  if (any(abs(df$tau_true - exp_tau) > 1e-9)) {
    bad <- df$cell[abs(df$tau_true - exp_tau) > 1e-9]
    stop("tau_true does not match the heterogeneity anchor at cell(s): ",
         paste(bad, collapse = ", "), ".")
  }

  # Path safety: cell_slug / stratum become directory names.
  safe_rx <- "^[a-z0-9_]+$"
  bad_slug <- df$cell[!grepl(safe_rx, df$cell_slug)]
  bad_strt <- df$cell[!grepl(safe_rx, df$stratum)]
  if (length(bad_slug)) {
    stop("cell_slug is not path-safe (need ^[a-z0-9_]+$) at cell(s): ",
         paste(bad_slug, collapse = ", "), ".")
  }
  if (length(bad_strt)) {
    stop("stratum is not path-safe (need ^[a-z0-9_]+$) at cell(s): ",
         paste(bad_strt, collapse = ", "), ".")
  }

  # Full36 grid completeness.
  if (isTRUE(expect_full36)) {
    n_eff  <- length(.sim_eff_anchors)   # 4
    n_het  <- length(.sim_het_anchors)   # 3
    n_bias <- length(.sim_bias_weights)  # 3
    n_full <- n_eff * n_het * n_bias     # 36
    if (nrow(df) != n_full) {
      stop("Expected the full36 grid (", n_full, " cells = ",
           n_eff, " effect x ", n_het, " heterogeneity x ", n_bias,
           " bias), but the design has ", nrow(df), " rows. ",
           "Pass expect_full36 = FALSE only for a deliberate subset.")
    }
    grid <- expand.grid(e = names(.sim_eff_anchors),
                        h = names(.sim_het_anchors),
                        b = names(.sim_bias_weights),
                        stringsAsFactors = FALSE)
    want <- sort(paste(grid$e, grid$h, grid$b, sep = "_"))
    have <- sort(exp_legacy)
    if (!identical(want, have)) {
      missing_cells <- setdiff(want, have)
      extra_cells   <- setdiff(have, want)
      stop("full36 grid is incomplete. Missing (eff_het_bias): ",
           paste(missing_cells, collapse = ", "),
           if (length(extra_cells))
             paste0(" | Unexpected: ",
                    paste(extra_cells, collapse = ", ")) else "",
           ".")
    }
  }

  invisible(df)
}

#' Return the row-specific selection-weight named vector for one design row.
#'
#' Used by `20_sim_generate.R` to pass row-specific weights into
#' `sim_pub_weight()`. The names match the `weights` argument of
#' `sim_pub_weight()`: `sig01`, `sig05`, `ns`.
sim_row_weights <- function(cell_row) {
  stopifnot(is.data.frame(cell_row), nrow(cell_row) == 1L)
  c(sig01 = as.numeric(cell_row$w_sig01),
    sig05 = as.numeric(cell_row$w_sig05),
    ns    = as.numeric(cell_row$w_ns))
}
