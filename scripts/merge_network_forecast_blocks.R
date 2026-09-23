#!/usr/bin/env Rscript

script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  script_path <- "scripts/merge_network_forecast_blocks.R"
}
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(root, "scripts", "R", "project_config.R"))
use_project_r_libs(root)
source(file.path(root, "scripts", "R", "forecast_models.R"))
source(file.path(root, "scripts", "R", "network_diagnostics.R"))

parse_merge_args <- function(args) {
  config <- list(
    structure = default_empirical_design$primary_structure,
    lag_cap = 6,
    window_days = 30,
    step_hours = default_empirical_design$network_refit_step_hours,
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
    } else if (grepl("^--sample-label=", arg)) {
      config$sample_label <- sub("^--sample-label=", "", arg)
    } else if (arg == "--no-prediction") {
      config$run_prediction <- FALSE
    }
  }
  config
}

read_and_bind <- function(files) {
  if (length(files) == 0) {
    return(data.frame())
  }
  nonempty_files <- files[file.info(files)$size > 0]
  if (length(nonempty_files) == 0) {
    return(data.frame())
  }
  frames <- lapply(nonempty_files, function(path) {
    tryCatch(
      read.csv(path, stringsAsFactors = FALSE, check.names = FALSE),
      error = function(e) data.frame()
    )
  })
  frames <- frames[vapply(frames, nrow, integer(1)) > 0]
  if (length(frames) == 0) {
    return(data.frame())
  }
  do.call(rbind, frames)
}

dedupe_sort <- function(df, key_cols) {
  if (nrow(df) == 0) {
    return(df)
  }
  df <- df[!duplicated(df[, key_cols, drop = FALSE]), , drop = FALSE]
  df[do.call(order, df[, key_cols, drop = FALSE]), , drop = FALSE]
}

main <- function() {
  paths <- project_paths(root)
  ensure_output_dirs(paths)
  args <- parse_merge_args(commandArgs(trailingOnly = TRUE))
  block_dir <- file.path(paths$interim, "blocks")

  base_label <- sprintf(
    "%s%s_p%s_w%sd_step%sh",
    args$structure,
    if (nzchar(args$sample_label)) paste0("_", args$sample_label) else "",
    args$lag_cap,
    args$window_days,
    args$step_hours
  )
  pattern_suffix <- paste0(base_label, "_block_.*\\.csv$")

  features <- read_and_bind(list.files(block_dir, paste0("^bigvar_network_features_", pattern_suffix), full.names = TRUE))
  edges <- read_and_bind(list.files(block_dir, paste0("^bigvar_network_edges_", pattern_suffix), full.names = TRUE))
  coefficients <- read_and_bind(list.files(block_dir, paste0("^bigvar_coefficients_", pattern_suffix), full.names = TRUE))
  status <- read_and_bind(list.files(block_dir, paste0("^bigvar_network_status_", pattern_suffix), full.names = TRUE))
  hourly <- read_and_bind(list.files(block_dir, paste0("^hourly_network_signal_features_", pattern_suffix), full.names = TRUE))
  panel <- read_and_bind(list.files(block_dir, paste0("^forecast_panel_with_network_", pattern_suffix), full.names = TRUE))

  features <- dedupe_sort(features, c("refit_timestamp_utc", "asset"))
  if (nrow(edges) > 0) {
    edges <- dedupe_sort(edges, c("refit_timestamp_utc", "structure", "lag", "from_asset", "to_asset"))
  }
  coefficients <- dedupe_sort(coefficients, c("refit_timestamp_utc", "structure", "lag", "from_asset", "to_asset"))
  status <- dedupe_sort(status, c("refit_timestamp_utc", "structure", "lag_cap", "window_days"))
  hourly <- dedupe_sort(hourly, c("timestamp_utc", "asset"))
  panel <- dedupe_sort(panel, c("timestamp_utc", "asset"))

  write.csv(features, file.path(paths$interim, paste0("bigvar_network_features_", base_label, "_merged.csv")), row.names = FALSE)
  write.csv(edges, file.path(paths$interim, paste0("bigvar_network_edges_", base_label, "_merged.csv")), row.names = FALSE)
  write.csv(coefficients, file.path(paths$interim, paste0("bigvar_coefficients_", base_label, "_merged.csv")), row.names = FALSE)
  write.csv(status, file.path(paths$interim, paste0("bigvar_network_status_", base_label, "_merged.csv")), row.names = FALSE)
  write.csv(hourly, file.path(paths$interim, paste0("hourly_network_signal_features_", base_label, "_merged.csv")), row.names = FALSE)
  write.csv(panel, file.path(paths$interim, paste0("forecast_panel_with_network_", base_label, "_merged.csv")), row.names = FALSE)
  diagnostics <- compute_network_diagnostics(features, coefficients)
  write.csv(diagnostics, file.path(paths$results, paste0("network_diagnostics_", base_label, "_merged.csv")), row.names = FALSE)

  message("Merged block outputs for: ", base_label)
  message("Refit feature rows: ", nrow(features))
  message("Hourly feature rows: ", nrow(hourly))
  message("Prediction panel rows: ", nrow(panel))
  message("Network diagnostic rows: ", nrow(diagnostics))

  if (args$run_prediction && nrow(panel) > 0 && length(unique(panel$timestamp_utc)) >= 10) {
    evaluation <- evaluate_prediction_models(panel, args$lag_cap)
    write.csv(evaluation$metrics, file.path(paths$results, paste0("forecast_metrics_", base_label, "_merged.csv")), row.names = FALSE)
    write.csv(evaluation$per_asset_metrics, file.path(paths$results, paste0("forecast_metrics_by_asset_", base_label, "_merged.csv")), row.names = FALSE)
    write.csv(evaluation$predictions, file.path(paths$results, paste0("forecast_predictions_", base_label, "_merged.csv")), row.names = FALSE)
    write.csv(evaluation$split, file.path(paths$results, paste0("forecast_split_", base_label, "_merged.csv")), row.names = FALSE)
    message("Wrote merged forecast evaluation.")
  }
}

main()
