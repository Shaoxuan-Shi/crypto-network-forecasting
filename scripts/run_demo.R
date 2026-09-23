#!/usr/bin/env Rscript

# Small end-to-end demonstration using the bundled 35-day sample.
# The demo fits two rolling sparse VARs, constructs network features, and
# evaluates whichever supported classifiers are installed locally.

script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  script_path <- "scripts/run_demo.R"
}
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)

source(file.path(root, "scripts", "R", "project_config.R"))
source(file.path(root, "scripts", "R", "network_features.R"))
source(file.path(root, "scripts", "R", "forecast_models.R"))

assets <- primary_assets
returns_path <- file.path(root, "data", "sample", "hourly_returns_wide_sample.csv")
forecast_panel_path <- file.path(root, "data", "sample", "forecast_panel_sample.csv")
output_dir <- file.path(root, "results", "demo")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

lag_cap <- 12
window_days <- 30
step_hours <- 24
max_origins <- 2

message("Running compact portfolio demo")
message(sprintf(
  "HLAGELEM, p=%d, window=%d days, refit=%d hours, origins=%d",
  lag_cap, window_days, step_hours, max_origins
))

returns_wide <- load_returns_wide(returns_path, assets)
network <- estimate_rolling_network_features(
  returns_wide = returns_wide,
  assets = assets,
  lag_cap = lag_cap,
  window_days = window_days,
  structure = "HLAGELEM",
  step_hours = step_hours,
  horizon = 1,
  max_origins = max_origins,
  verbose = TRUE
)

write.csv(network$features, file.path(output_dir, "network_features.csv"), row.names = FALSE)
write.csv(network$edges, file.path(output_dir, "network_edges.csv"), row.names = FALSE)
write.csv(network$status, file.path(output_dir, "estimation_status.csv"), row.names = FALSE)

if (nrow(network$features) == 0) {
  stop("The demo did not produce any successful network estimates.")
}

hourly_network_features <- build_hourly_network_signal_features(
  returns_wide = returns_wide,
  assets = assets,
  lag_cap = lag_cap,
  network_features = network$features,
  coefficients = network$coefficients,
  horizon = 1,
  max_extension_hours = step_hours
)
lagged_features <- make_lagged_return_features(returns_wide, assets, lag_cap)
prediction_panel <- build_prediction_panel(
  forecast_panel_path,
  lagged_features,
  hourly_network_features
)
evaluation <- evaluate_prediction_models(prediction_panel, lag_cap)

write.csv(evaluation$metrics, file.path(output_dir, "forecast_metrics.csv"), row.names = FALSE)
write.csv(evaluation$per_asset_metrics, file.path(output_dir, "forecast_metrics_by_asset.csv"), row.names = FALSE)
write.csv(evaluation$split, file.path(output_dir, "forecast_split.csv"), row.names = FALSE)

message("Demo complete. Outputs: ", output_dir)
