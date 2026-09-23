#!/usr/bin/env Rscript

# Validation-based XGBoost diagnostic for the primary prediction panel.
#
# The thesis comparison intentionally uses one conservative XGBoost setting.
# This script adds a separate check with a validation period, early stopping,
# stochastic row/column sampling, and feature-importance output. It is a model
# diagnostic, not a replacement for the main out-of-sample comparison.

script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  script_path <- "scripts/run_xgboost_diagnostic.R"
}
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(root, "scripts", "R", "project_config.R"))
use_project_r_libs(root)
source(file.path(root, "scripts", "R", "forecast_models.R"))

if (!requireNamespace("xgboost", quietly = TRUE)) {
  stop("The xgboost package is required. Run Rscript scripts/install_required_packages.R first.")
}
if (!requireNamespace("Matrix", quietly = TRUE)) {
  stop("The Matrix package is required. Run Rscript scripts/install_required_packages.R first.")
}

default_panel_path <- file.path(
  root,
  "data",
  "interim",
  "forecast_panel_with_network_HLAGELEM_twoyear_p12_w30d_step24h_merged.csv"
)
panel_path <- Sys.getenv("XGBOOST_PANEL_PATH", unset = default_panel_path)
summary_path <- file.path(root, "results", "xgboost_diagnostic_summary.csv")
importance_path <- file.path(root, "results", "checkpoints", "xgboost_diagnostic_importance.csv")

if (!file.exists(panel_path)) {
  stop(
    "Primary prediction panel not found. Run bash scripts/run_full_primary.sh first: ",
    panel_path
  )
}

dir.create(dirname(importance_path), recursive = TRUE, showWarnings = FALSE)

binary_logloss <- function(actual, probability) {
  eps <- 1e-15
  p <- pmin(pmax(probability, eps), 1 - eps)
  -mean(actual * log(p) + (1 - actual) * log(1 - p))
}

best_validation_iteration <- function(training_log) {
  iteration_lines <- grep("^\\[[0-9]+\\]", training_log, value = TRUE)
  if (length(iteration_lines) == 0) {
    return(NA_integer_)
  }

  parsed <- lapply(iteration_lines, function(line) {
    match <- regexec(
      "^\\[([0-9]+)\\]\\s+train-logloss:([0-9.]+)\\s+validation-logloss:([0-9.]+)",
      line
    )
    parts <- regmatches(line, match)[[1]]
    if (length(parts) != 4) {
      return(NULL)
    }
    c(iteration = as.integer(parts[2]), validation_logloss = as.numeric(parts[4]))
  })
  parsed <- parsed[!vapply(parsed, is.null, logical(1))]
  if (length(parsed) == 0) {
    return(NA_integer_)
  }

  parsed <- do.call(rbind, parsed)
  as.integer(parsed[which.min(parsed[, "validation_logloss"]), "iteration"])
}

make_three_way_matrix <- function(train_df, validation_df, test_df, feature_cols) {
  rhs <- paste(unique(c(feature_cols, "factor(asset)")), collapse = " + ")
  formula <- stats::as.formula(paste("target_direction ~", rhs))
  n_train <- nrow(train_df)
  n_validation <- nrow(validation_df)
  combined <- rbind(train_df, validation_df, test_df)
  matrix_all <- Matrix::sparse.model.matrix(formula, data = combined)[, -1, drop = FALSE]
  variable_cols <- Matrix::colSums(matrix_all[seq_len(n_train), , drop = FALSE] != 0) > 0
  matrix_all <- matrix_all[, variable_cols, drop = FALSE]

  list(
    train = matrix_all[seq_len(n_train), , drop = FALSE],
    validation = matrix_all[(n_train + 1):(n_train + n_validation), , drop = FALSE],
    test = matrix_all[(n_train + n_validation + 1):nrow(matrix_all), , drop = FALSE]
  )
}

panel <- read.csv(panel_path, stringsAsFactors = FALSE, check.names = FALSE)
panel$timestamp_utc <- as.character(panel$timestamp_utc)
panel <- panel[order(panel$timestamp_utc, panel$asset), , drop = FALSE]

ordered_times <- sort(unique(panel$timestamp_utc))
test_split <- ordered_times[max(1, floor(length(ordered_times) * 0.7))]
training_period <- panel[panel$timestamp_utc <= test_split, , drop = FALSE]
test_df <- panel[panel$timestamp_utc > test_split, , drop = FALSE]

training_times <- sort(unique(training_period$timestamp_utc))
validation_split <- training_times[max(1, floor(length(training_times) * 0.8))]
train_df <- training_period[training_period$timestamp_utc <= validation_split, , drop = FALSE]
validation_df <- training_period[training_period$timestamp_utc > validation_split, , drop = FALSE]

lag_cols <- grep("^ret_.*_lag[0-9]+$", names(panel), value = TRUE)
time_cols <- c("hour_sin", "hour_cos", "dow_sin", "dow_cos")
network_cols <- c(
  "own_persistence", "incoming_cross_effect", "outgoing_cross_effect",
  "net_influence", "incoming_edge_count", "outgoing_edge_count"
)
signal_cols <- c(
  "network_weighted_own_return", "network_weighted_cross_return",
  "network_weighted_total_return"
)
pair_signal_cols <- grep("^signal_from_", names(panel), value = TRUE)

feature_sets <- list(
  lagged_returns = c(lag_cols, time_cols),
  lagged_returns_plus_node_network = c(lag_cols, network_cols, time_cols),
  lagged_returns_plus_aggregate_signals = c(lag_cols, signal_cols, time_cols),
  lagged_returns_plus_pair_signals = c(lag_cols, pair_signal_cols, time_cols),
  lagged_returns_plus_all_network = c(
    lag_cols, network_cols, signal_cols, pair_signal_cols, time_cols
  ),
  lagged_returns_plus_asset_signal_interactions = c(
    lag_cols, network_cols, time_cols, "factor(asset)", signal_cols, pair_signal_cols,
    paste0("factor(asset):", signal_cols),
    paste0("factor(asset):", pair_signal_cols)
  )
)

params <- list(
  objective = "binary:logistic",
  eval_metric = "logloss",
  max_depth = 4,
  eta = 0.05,
  subsample = 0.8,
  colsample_bytree = 0.8,
  seed = 20260620
)

network_name_parts <- c(
  "own_persistence", "incoming_cross_effect", "outgoing_cross_effect",
  "net_influence", "incoming_edge_count", "outgoing_edge_count",
  "network_weighted_", "signal_from_"
)

summary_rows <- list()
importance_rows <- list()

for (feature_set_name in names(feature_sets)) {
  matrices <- make_three_way_matrix(
    train_df,
    validation_df,
    test_df,
    feature_sets[[feature_set_name]]
  )
  dtrain <- xgboost::xgb.DMatrix(matrices$train, label = train_df$target_direction)
  dvalidation <- xgboost::xgb.DMatrix(
    matrices$validation,
    label = validation_df$target_direction
  )
  dtest <- xgboost::xgb.DMatrix(matrices$test, label = test_df$target_direction)

  set.seed(params$seed)
  training_log <- capture.output({
    fit <- xgboost::xgb.train(
      params = params,
      data = dtrain,
      nrounds = 300,
      evals = list(train = dtrain, validation = dvalidation),
      early_stopping_rounds = 20,
      verbose = 1
    )
  })

  validation_probability <- as.numeric(stats::predict(fit, dvalidation))
  test_probability <- as.numeric(stats::predict(fit, dtest))
  importance <- as.data.frame(
    xgboost::xgb.importance(feature_names = colnames(matrices$train), model = fit)
  )
  importance$feature_set <- feature_set_name
  importance_rows[[length(importance_rows) + 1]] <- importance

  is_network_feature <- if (nrow(importance) == 0) {
    logical(0)
  } else {
    vapply(
      importance$Feature,
      function(name) any(vapply(network_name_parts, grepl, logical(1), x = name, fixed = TRUE)),
      logical(1)
    )
  }
  best_iteration <- best_validation_iteration(training_log)

  summary_rows[[length(summary_rows) + 1]] <- data.frame(
    feature_set = feature_set_name,
    test_auc = auc_rank(test_df$target_direction, test_probability),
    validation_auc = auc_rank(validation_df$target_direction, validation_probability),
    test_logloss = binary_logloss(test_df$target_direction, test_probability),
    best_iteration = best_iteration,
    network_features_used = sum(is_network_feature),
    network_gain_share = if (any(is_network_feature)) sum(importance$Gain[is_network_feature]) else 0,
    stringsAsFactors = FALSE
  )
}

summary <- do.call(rbind, summary_rows)
baseline_auc <- summary$test_auc[summary$feature_set == "lagged_returns"]
summary$delta_test_auc <- summary$test_auc - baseline_auc
summary <- summary[, c(
  "feature_set", "test_auc", "delta_test_auc", "validation_auc", "test_logloss",
  "best_iteration", "network_features_used", "network_gain_share"
)]

importance <- do.call(rbind, importance_rows)
write.csv(summary, summary_path, row.names = FALSE)
write.csv(importance, importance_path, row.names = FALSE)

message("Wrote ", summary_path)
message("Wrote ", importance_path)
print(summary)
