#!/usr/bin/env Rscript

script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  script_path <- "scripts/run_network_forecast_pipeline.R"
}
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(root, "scripts", "R", "project_config.R"))
use_project_r_libs(root)
source(file.path(root, "scripts", "R", "network_features.R"))
source(file.path(root, "scripts", "R", "forecast_models.R"))

parse_args <- function(args) {
  config <- list(
    structure = default_empirical_design$primary_structure,
    lag_cap = 6,
    window_days = 30,
    step_hours = default_empirical_design$network_refit_step_hours,
    max_origins = Inf,
    smoke = FALSE,
    run_prediction = TRUE
  )
  for (arg in args) {
    if (arg == "--smoke") {
      config$smoke <- TRUE
      config$lag_cap <- 2
      config$window_days <- 30
      config$step_hours <- 24
      config$max_origins <- 4
    } else if (grepl("^--structure=", arg)) {
      config$structure <- sub("^--structure=", "", arg)
    } else if (grepl("^--lag-cap=", arg)) {
      config$lag_cap <- as.integer(sub("^--lag-cap=", "", arg))
    } else if (grepl("^--window-days=", arg)) {
      config$window_days <- as.integer(sub("^--window-days=", "", arg))
    } else if (grepl("^--step-hours=", arg)) {
      config$step_hours <- as.integer(sub("^--step-hours=", "", arg))
    } else if (grepl("^--max-origins=", arg)) {
      config$max_origins <- as.integer(sub("^--max-origins=", "", arg))
    } else if (arg == "--no-prediction") {
      config$run_prediction <- FALSE
    }
  }
  config
}

main <- function() {
  paths <- project_paths(root)
  ensure_output_dirs(paths)
  args <- parse_args(commandArgs(trailingOnly = TRUE))

  message("Network forecast pipeline")
  message(sprintf("Structure=%s lag_cap=%s window_days=%s step_hours=%s max_origins=%s",
                  args$structure, args$lag_cap, args$window_days, args$step_hours, args$max_origins))

  returns_path <- file.path(paths$processed, "hourly_returns_wide_primary.csv")
  forecast_panel_path <- file.path(paths$processed, "forecast_panel_primary.csv")
  returns_wide <- load_returns_wide(returns_path, primary_assets)

  network <- estimate_rolling_network_features(
    returns_wide = returns_wide,
    assets = primary_assets,
    lag_cap = args$lag_cap,
    window_days = args$window_days,
    structure = args$structure,
    step_hours = args$step_hours,
    horizon = default_empirical_design$forecast_horizon,
    tolerance = default_empirical_design$coefficient_zero_tolerance,
    max_origins = args$max_origins,
    verbose = TRUE
  )

  run_label <- sprintf(
    "%s_p%s_w%sd_step%sh%s",
    args$structure,
    args$lag_cap,
    args$window_days,
    args$step_hours,
    if (args$smoke) "_smoke" else ""
  )

  feature_path <- file.path(paths$interim, paste0("bigvar_network_features_", run_label, ".csv"))
  edge_path <- file.path(paths$interim, paste0("bigvar_network_edges_", run_label, ".csv"))
  coefficient_path <- file.path(paths$interim, paste0("bigvar_coefficients_", run_label, ".csv"))
  status_path <- file.path(paths$interim, paste0("bigvar_network_status_", run_label, ".csv"))
  write.csv(network$features, feature_path, row.names = FALSE)
  write.csv(network$edges, edge_path, row.names = FALSE)
  write.csv(network$coefficients, coefficient_path, row.names = FALSE)
  write.csv(network$status, status_path, row.names = FALSE)

  message("Wrote network features: ", feature_path)
  message("Wrote network edge list: ", edge_path)
  message("Wrote dense coefficient table: ", coefficient_path)
  message("Wrote estimation status: ", status_path)

  if (args$run_prediction && nrow(network$features) > 0) {
    hourly_network_features <- build_hourly_network_signal_features(
      returns_wide = returns_wide,
      assets = primary_assets,
      lag_cap = args$lag_cap,
      network_features = network$features,
      coefficients = network$coefficients,
      horizon = default_empirical_design$forecast_horizon,
      max_extension_hours = args$step_hours
    )
    hourly_network_path <- file.path(paths$interim, paste0("hourly_network_signal_features_", run_label, ".csv"))
    write.csv(hourly_network_features, hourly_network_path, row.names = FALSE)
    message("Wrote hourly network signal features: ", hourly_network_path)

    lagged_features <- make_lagged_return_features(returns_wide, primary_assets, args$lag_cap)
    prediction_panel <- build_prediction_panel(forecast_panel_path, lagged_features, hourly_network_features)
    prediction_panel_path <- file.path(paths$interim, paste0("forecast_panel_with_network_", run_label, ".csv"))
    write.csv(prediction_panel, prediction_panel_path, row.names = FALSE)
    message("Wrote prediction panel: ", prediction_panel_path)

    if (length(unique(prediction_panel$timestamp_utc)) >= 10) {
      evaluation <- evaluate_prediction_models(prediction_panel, args$lag_cap)
      metrics_path <- file.path(paths$results, paste0("forecast_metrics_", run_label, ".csv"))
      per_asset_metrics_path <- file.path(paths$results, paste0("forecast_metrics_by_asset_", run_label, ".csv"))
      predictions_path <- file.path(paths$results, paste0("forecast_predictions_", run_label, ".csv"))
      split_path <- file.path(paths$results, paste0("forecast_split_", run_label, ".csv"))
      write.csv(evaluation$metrics, metrics_path, row.names = FALSE)
      write.csv(evaluation$per_asset_metrics, per_asset_metrics_path, row.names = FALSE)
      write.csv(evaluation$predictions, predictions_path, row.names = FALSE)
      write.csv(evaluation$split, split_path, row.names = FALSE)
      message("Wrote forecast metrics: ", metrics_path)
      message("Wrote per-asset forecast metrics: ", per_asset_metrics_path)
      message("Wrote forecast predictions: ", predictions_path)
      message("Wrote forecast split: ", split_path)
    } else {
      message("Skipping prediction evaluation because the smoke panel has too few distinct timestamps.")
    }
  }
}

main()
