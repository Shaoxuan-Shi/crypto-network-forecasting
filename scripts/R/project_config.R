# Shared project configuration for the empirical pipeline.
#
# This file is sourced by the main runners before any data processing,
# BigVAR estimation, or prediction evaluation. It keeps paths, asset lists, and
# default empirical design choices in one place so individual scripts do not
# hard-code those values separately.

# Return the active project root. Most runners set their working directory to
# project root before sourcing this file.
project_root <- function() {
  normalizePath(getwd(), mustWork = TRUE)
}

# Small helper for optional values: use x unless it is NULL, otherwise use y.
`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

# Centralize the main input/output directories used by R scripts.
project_paths <- function(root = getwd()) {
  list(
    root = normalizePath(root, mustWork = TRUE),
    processed = file.path(root, "data", "processed"),
    interim = file.path(root, "data", "interim"),
    results = file.path(root, "results")
  )
}

# Put the project-local R library first on .libPaths().
#
# This lets the pipeline use packages installed under r_libs/ without requiring
# changes to the user's global R setup.
use_project_r_libs <- function(root = getwd()) {
  local_lib <- file.path(root, "r_libs")
  if (dir.exists(local_lib)) {
    .libPaths(c(normalizePath(local_lib), .libPaths()))
  }
}

# Primary cryptocurrency universe used throughout the experiments.
# Order matters because BigVAR coefficient columns are position-based.
primary_assets <- c(
  "BTC", "ETH", "XRP", "BNB", "SOL", "TRX",
  "DOGE", "ADA", "LINK", "LTC", "AVAX", "DOT"
)

# Default empirical design settings.
#
# The block scripts can override these from the command line, but these values
# document the intended primary design and common robustness candidates.
default_empirical_design <- list(
  network_structures = c("HLAGELEM", "HLAGC", "SparseLag", "Basic"),
  primary_structure = "HLAGELEM",
  lag_cap_candidates = c(6, 12, 24),
  rolling_window_day_candidates = c(15, 30, 45),
  forecast_horizon = 1,
  network_refit_step_hours = 24,
  robustness_refit_step_hours = 168,
  coefficient_zero_tolerance = 1e-8
)

# Create output folders expected by downstream scripts.
ensure_output_dirs <- function(paths) {
  dir.create(paths$interim, recursive = TRUE, showWarnings = FALSE)
  dir.create(paths$results, recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(paths$results, "figures"), recursive = TRUE, showWarnings = FALSE)
}
