#!/usr/bin/env Rscript

# Block-level BigVAR network feature pipeline.
#
# This script estimates BigVAR networks for a subset of rolling-window refit
# origins. The block design lets long runs be split into manageable pieces and
# merged later by scripts/merge_network_forecast_blocks.R.

# Locate the project root and load shared configuration/helper functions.
script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  script_path <- "scripts/run_network_forecast_pipeline_block.R"
}
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(root, "scripts", "R", "project_config.R"))
use_project_r_libs(root)
source(file.path(root, "scripts", "R", "network_features.R"))
source(file.path(root, "scripts", "R", "forecast_models.R"))

# Parse command-line settings for one block.
#
# Main empirical controls:
# - structure: BigVAR penalty structure, e.g. HLAGELEM.
# - lag_cap: VAR maximum lag p.
# - window_days: rolling-window length used to estimate each BigVAR.
# - step_hours: refit frequency; 24 means one BigVAR refit per day.
# - origin_start/origin_end: which refit origins this block owns.
parse_block_args <- function(args) {
  config <- list(
    structure = default_empirical_design$primary_structure,
    lag_cap = 6,
    window_days = 30,
    step_hours = default_empirical_design$network_refit_step_hours,
    origin_start = 1,
    origin_end = 25,
    block_id = NULL,
    sample_start = NULL,
    sample_end = NULL,
    sample_label = "",
    run_prediction = TRUE
  )
  for (arg in args) {
    if (grepl("^--structure=", arg)) {
      config$structure <- sub("^--structure=", "", arg)
    } else if (grepl("^--lag-cap=", arg)) {
      config$lag_cap <- as.integer(sub("^--lag-cap=", "", arg))
    } else if (grepl("^--window-days=", arg)) {
      config$window_days <- as.integer(sub("^--window-days=", "", arg))
    } else if (grepl("^--step-hours=", arg)) {
      config$step_hours <- as.integer(sub("^--step-hours=", "", arg))
    } else if (grepl("^--origin-start=", arg)) {
      config$origin_start <- as.integer(sub("^--origin-start=", "", arg))
    } else if (grepl("^--origin-end=", arg)) {
      config$origin_end <- as.integer(sub("^--origin-end=", "", arg))
    } else if (grepl("^--block-id=", arg)) {
      config$block_id <- sub("^--block-id=", "", arg)
    } else if (grepl("^--sample-start=", arg)) {
      config$sample_start <- sub("^--sample-start=", "", arg)
    } else if (grepl("^--sample-end=", arg)) {
      config$sample_end <- sub("^--sample-end=", "", arg)
    } else if (grepl("^--sample-label=", arg)) {
      config$sample_label <- sub("^--sample-label=", "", arg)
    } else if (arg == "--no-prediction") {
      config$run_prediction <- FALSE
    }
  }
  if (is.null(config$block_id)) {
    config$block_id <- sprintf("origins%04d-%04d", config$origin_start, config$origin_end)
  }
  config
}

# Restrict the return matrix to the requested empirical sample.
#
# The two-year runs pass sample_start/sample_end here, while full-sample runs
# can leave both NULL.
filter_returns_sample <- function(returns_wide, sample_start = NULL, sample_end = NULL) {
  if (!is.null(sample_start)) {
    returns_wide <- returns_wide[returns_wide$timestamp_utc >= as.POSIXct(sample_start, tz = "UTC"), , drop = FALSE]
  }
  if (!is.null(sample_end)) {
    returns_wide <- returns_wide[returns_wide$timestamp_utc <= as.POSIXct(sample_end, tz = "UTC"), , drop = FALSE]
  }
  returns_wide
}

# Convert block-level origin numbers into row indices of returns_wide.
#
# The first available refit origin is after window_days * 24 observations, so
# every BigVAR fit has a complete rolling-window history. The horizon exclusion
# keeps the forecast target from running past the sample end.
select_origin_indices <- function(n_rows, window_days, step_hours, horizon, origin_start, origin_end) {
  window_hours <- window_days * 24
  all_indices <- seq(window_hours, n_rows - horizon, by = step_hours)
  if (origin_start < 1 || origin_end < origin_start) {
    stop("Invalid origin range.")
  }
  if (origin_start > length(all_indices)) {
    stop("origin_start exceeds available refit origins. Available: ", length(all_indices))
  }
  all_indices[origin_start:min(origin_end, length(all_indices))]
}

# Estimate BigVAR networks for all refit origins assigned to this block.
#
# For each origin:
# 1. take the trailing rolling window of hourly returns;
# 2. fit one BigVAR(p) model with the selected structure;
# 3. parse the fitted coefficients into interpretable network outputs:
#    node-level summaries, directed edge list, dense coefficient table;
# 4. keep a status row so failures are visible instead of silently disappearing.
estimate_network_for_origin_indices <- function(
    returns_wide,
    assets,
    lag_cap,
    window_days,
    structure,
    origin_indices,
    horizon = 1,
    tolerance = 1e-8,
    verbose = TRUE) {
  window_hours <- window_days * 24
  feature_blocks <- list()
  edge_blocks <- list()
  coefficient_blocks <- list()
  status_rows <- list()

  for (k in seq_along(origin_indices)) {
    origin_idx <- origin_indices[k]
    origin_time <- returns_wide$timestamp_utc[origin_idx]
    window_start <- origin_idx - window_hours + 1
    # BigVAR is trained only on information available at this refit origin.
    window_data <- as.matrix(returns_wide[window_start:origin_idx, assets, drop = FALSE])

    if (verbose) {
      message(sprintf(
        "[%s] Block estimating %s p=%s window=%sd at %s (%s/%s)",
        Sys.time(), structure, lag_cap, window_days, format(origin_time, "%Y-%m-%d %H:%M:%S"), k, length(origin_indices)
      ))
    }

    # Fit the sparse VAR. try() keeps the remaining block usable if a single
    # rolling window is numerically problematic.
    fit <- try(fit_bigvar_at_origin(window_data, lag_cap, structure, horizon, verbose = FALSE), silent = TRUE)
    if (inherits(fit, "try-error")) {
      status_rows[[length(status_rows) + 1]] <- data.frame(
        refit_timestamp_utc = format(origin_time, "%Y-%m-%d %H:%M:%S"),
        structure = structure,
        lag_cap = lag_cap,
        window_days = window_days,
        status = "failed",
        message = as.character(fit),
        stringsAsFactors = FALSE
      )
      next
    }

    # BigVAR stores coefficients in package-specific form; parsing converts
    # them into lag/source/target rows that are easier to audit and reuse.
    parsed <- parse_bigvar_coefficients(
      coef_df = coef(fit),
      assets = assets,
      lag_cap = lag_cap,
      timestamp_utc = origin_time,
      structure = structure,
      tolerance = tolerance
    )
    feature_blocks[[length(feature_blocks) + 1]] <- parsed$features
    if (nrow(parsed$edges) > 0) {
      edge_blocks[[length(edge_blocks) + 1]] <- parsed$edges
    }
    coefficient_blocks[[length(coefficient_blocks) + 1]] <- parsed$coefficients
    status_rows[[length(status_rows) + 1]] <- data.frame(
      refit_timestamp_utc = format(origin_time, "%Y-%m-%d %H:%M:%S"),
      structure = structure,
      lag_cap = lag_cap,
      window_days = window_days,
      status = "ok",
      message = "",
      stringsAsFactors = FALSE
    )
  }

  list(
    features = if (length(feature_blocks) == 0) data.frame() else do.call(rbind, feature_blocks),
    edges = if (length(edge_blocks) == 0) data.frame() else do.call(rbind, edge_blocks),
    coefficients = if (length(coefficient_blocks) == 0) data.frame() else do.call(rbind, coefficient_blocks),
    status = if (length(status_rows) == 0) data.frame() else do.call(rbind, status_rows)
  )
}

main <- function() {
  # Set output directories and parse the block specification.
  paths <- project_paths(root)
  ensure_output_dirs(paths)
  args <- parse_block_args(commandArgs(trailingOnly = TRUE))
  block_dir <- file.path(paths$interim, "blocks")
  dir.create(block_dir, recursive = TRUE, showWarnings = FALSE)

  # Load the hourly return panel used for BigVAR estimation. The separate
  # forecast panel is merged later because it already contains asset-level
  # targets and time identifiers for prediction.
  returns_path <- file.path(paths$processed, "hourly_returns_wide_primary.csv")
  forecast_panel_path <- file.path(paths$processed, "forecast_panel_primary.csv")
  returns_wide <- load_returns_wide(returns_path, primary_assets)
  returns_wide <- filter_returns_sample(returns_wide, args$sample_start, args$sample_end)

  # Select the exact rolling-window refit origins handled by this block.
  origin_indices <- select_origin_indices(
    n_rows = nrow(returns_wide),
    window_days = args$window_days,
    step_hours = args$step_hours,
    horizon = default_empirical_design$forecast_horizon,
    origin_start = args$origin_start,
    origin_end = args$origin_end
  )

  # Build a stable label so every intermediate CSV can be traced back to its
  # empirical setting and block number.
  run_label <- sprintf(
    "%s%s_p%s_w%sd_step%sh_block_%s",
    args$structure,
    if (nzchar(args$sample_label)) paste0("_", args$sample_label) else "",
    args$lag_cap,
    args$window_days,
    args$step_hours,
    args$block_id
  )

  message("Network forecast block runner")
  message(sprintf(
    "Structure=%s sample=%s lag_cap=%s window_days=%s step_hours=%s origin_start=%s origin_end=%s block_id=%s",
    args$structure, args$sample_label, args$lag_cap, args$window_days, args$step_hours,
    args$origin_start, args$origin_end, args$block_id
  ))

  # Estimate the BigVAR networks and extract refit-level network objects.
  network <- estimate_network_for_origin_indices(
    returns_wide = returns_wide,
    assets = primary_assets,
    lag_cap = args$lag_cap,
    window_days = args$window_days,
    structure = args$structure,
    origin_indices = origin_indices,
    horizon = default_empirical_design$forecast_horizon,
    tolerance = default_empirical_design$coefficient_zero_tolerance,
    verbose = TRUE
  )

  # Write block outputs before any prediction-panel construction. This makes
  # the expensive BigVAR estimates recoverable even if later steps fail.
  feature_path <- file.path(block_dir, paste0("bigvar_network_features_", run_label, ".csv"))
  edge_path <- file.path(block_dir, paste0("bigvar_network_edges_", run_label, ".csv"))
  coefficient_path <- file.path(block_dir, paste0("bigvar_coefficients_", run_label, ".csv"))
  status_path <- file.path(block_dir, paste0("bigvar_network_status_", run_label, ".csv"))
  write.csv(network$features, feature_path, row.names = FALSE)
  write.csv(network$edges, edge_path, row.names = FALSE)
  write.csv(network$coefficients, coefficient_path, row.names = FALSE)
  write.csv(network$status, status_path, row.names = FALSE)

  message("Wrote block network features: ", feature_path)
  message("Wrote block edge list: ", edge_path)
  message("Wrote block dense coefficient table: ", coefficient_path)
  message("Wrote block estimation status: ", status_path)

  if (args$run_prediction && nrow(network$features) > 0) {
    # Expand refit-level coefficients to hourly network-signal features. The
    # coefficients stay fixed until the next refit, while lagged returns update
    # each hour; max_extension_hours prevents a block from extending beyond its
    # own refit interval when blocks are merged.
    hourly_network_features <- build_hourly_network_signal_features(
      returns_wide = returns_wide,
      assets = primary_assets,
      lag_cap = args$lag_cap,
      network_features = network$features,
      coefficients = network$coefficients,
      horizon = default_empirical_design$forecast_horizon,
      max_extension_hours = args$step_hours
    )
    hourly_network_path <- file.path(block_dir, paste0("hourly_network_signal_features_", run_label, ".csv"))
    write.csv(hourly_network_features, hourly_network_path, row.names = FALSE)
    message("Wrote block hourly network signal features: ", hourly_network_path)

    # Combine conventional lagged returns, BigVAR-implied network signals, and
    # the next-hour direction target into the block-level prediction panel.
    lagged_features <- make_lagged_return_features(returns_wide, primary_assets, args$lag_cap)
    prediction_panel <- build_prediction_panel(forecast_panel_path, lagged_features, hourly_network_features)
    prediction_panel_path <- file.path(block_dir, paste0("forecast_panel_with_network_", run_label, ".csv"))
    write.csv(prediction_panel, prediction_panel_path, row.names = FALSE)
    message("Wrote block prediction panel: ", prediction_panel_path)
  }
}

main()
