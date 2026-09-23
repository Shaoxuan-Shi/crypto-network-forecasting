# Prediction panel construction and model evaluation helpers.
#
# BigVAR produces network features, but the prediction task is evaluated
# with separate classifiers. This file builds conventional lagged-return
# predictors, merges them with network features, fits benchmark and augmented
# prediction models, and reports pooled plus per-asset metrics.

# Construct the conventional lagged-return benchmark feature block.
#
# These raw return lags are included in every model, so network features are
# assessed as incremental information beyond standard autoregressive predictors.
make_lagged_return_features <- function(returns_wide, assets, lag_cap) {
  start_idx <- lag_cap
  end_idx <- nrow(returns_wide)
  out <- data.frame(
    timestamp_utc = format(returns_wide$timestamp_utc[start_idx:end_idx], "%Y-%m-%d %H:%M:%S"),
    stringsAsFactors = FALSE
  )

  for (lag in seq_len(lag_cap)) {
    source_indices <- (start_idx:end_idx) - lag + 1
    for (asset in assets) {
      out[[paste0("ret_", asset, "_lag", lag)]] <- returns_wide[[asset]][source_indices]
    }
  }
  out
}

# Merge target labels, lagged returns, network features, and time controls.
#
# The forecast panel supplies the next-hour direction target. The lagged and
# network features are aligned at timestamp t and asset B, while the label is
# return direction at t+1 for that asset.
build_prediction_panel <- function(forecast_panel_path, lagged_features, hourly_network_features) {
  panel <- read.csv(forecast_panel_path, stringsAsFactors = FALSE, check.names = FALSE)
  hourly_network_features$timestamp_utc <- as.character(hourly_network_features$timestamp_utc)
  lagged_features$timestamp_utc <- as.character(lagged_features$timestamp_utc)

  merged <- merge(panel, lagged_features, by = "timestamp_utc", all.x = FALSE, all.y = FALSE)
  merged <- merge(merged, hourly_network_features, by = c("timestamp_utc", "asset"), all.x = FALSE, all.y = FALSE)
  merged$hour_sin <- sin(2 * pi * merged$hour_of_day / 24)
  merged$hour_cos <- cos(2 * pi * merged$hour_of_day / 24)
  merged$dow_sin <- sin(2 * pi * merged$day_of_week / 7)
  merged$dow_cos <- cos(2 * pi * merged$day_of_week / 7)
  merged <- merged[complete.cases(merged), , drop = FALSE]
  merged[order(merged$timestamp_utc, merged$asset), , drop = FALSE]
}

# Classification metric: average of true positive rate and true negative rate.
# This is useful when up/down classes are not perfectly balanced.
balanced_accuracy <- function(actual, predicted) {
  pos <- actual == 1
  neg <- actual == 0
  tpr <- if (sum(pos) == 0) NA_real_ else mean(predicted[pos] == 1)
  tnr <- if (sum(neg) == 0) NA_real_ else mean(predicted[neg] == 0)
  mean(c(tpr, tnr), na.rm = TRUE)
}

# Classification metric emphasizing correct positive/up predictions.
f1_score <- function(actual, predicted) {
  tp <- sum(actual == 1 & predicted == 1)
  fp <- sum(actual == 0 & predicted == 1)
  fn <- sum(actual == 1 & predicted == 0)
  denom <- 2 * tp + fp + fn
  if (denom == 0) NA_real_ else 2 * tp / denom
}

# Rank-based AUC implementation to avoid adding another dependency.
auc_rank <- function(actual, score) {
  pos <- score[actual == 1]
  neg <- score[actual == 0]
  if (length(pos) == 0 || length(neg) == 0) {
    return(NA_real_)
  }
  ranks <- rank(c(pos, neg), ties.method = "average")
  pos_ranks <- ranks[seq_along(pos)]
  numerator <- sum(pos_ranks) - length(pos) * (length(pos) + 1) / 2
  denominator <- as.numeric(length(pos)) * as.numeric(length(neg))
  numerator / denominator
}

# Standardize metric output across all model/feature-set combinations.
metric_row <- function(model_name, feature_set, actual, probability) {
  predicted <- as.integer(probability >= 0.5)
  data.frame(
    model = model_name,
    feature_set = feature_set,
    n = length(actual),
    accuracy = mean(predicted == actual),
    balanced_accuracy = balanced_accuracy(actual, predicted),
    f1 = f1_score(actual, predicted),
    auc = auc_rank(actual, probability),
    positive_rate_actual = mean(actual == 1),
    positive_rate_predicted = mean(predicted == 1),
    stringsAsFactors = FALSE
  )
}

# Build a train/test design matrix from a formula-style feature list.
#
# This is shared by glmnet and xgboost. Sparse matrices keep interaction-heavy
# designs manageable, especially for asset x signal feature sets.
make_model_matrix <- function(train_df, test_df, feature_cols, include_asset_main_effect = FALSE) {
  rhs <- paste(feature_cols, collapse = " + ")
  if (include_asset_main_effect && !"factor(asset)" %in% feature_cols) {
    rhs <- paste(rhs, "factor(asset)", sep = " + ")
  }
  formula <- stats::as.formula(paste("target_direction ~", rhs))
  if (requireNamespace("Matrix", quietly = TRUE)) {
    x_train <- Matrix::sparse.model.matrix(formula, data = train_df)[, -1, drop = FALSE]
    x_test <- Matrix::sparse.model.matrix(formula, data = test_df)[, -1, drop = FALSE]
  } else {
    x_train <- stats::model.matrix(formula, data = train_df)[, -1, drop = FALSE]
    x_test <- stats::model.matrix(formula, data = test_df)[, -1, drop = FALSE]
  }
  common_cols <- intersect(colnames(x_train), colnames(x_test))
  x_train <- x_train[, common_cols, drop = FALSE]
  x_test <- x_test[, common_cols, drop = FALSE]
  variable_cols <- if (inherits(x_train, "sparseMatrix")) {
    Matrix::colSums(x_train != 0) > 0
  } else {
    apply(x_train, 2, stats::sd, na.rm = TRUE) > 0
  }
  x_train <- x_train[, variable_cols, drop = FALSE]
  x_test <- x_test[, variable_cols, drop = FALSE]
  list(x_train = x_train, x_test = x_test)
}

# LASSO logistic regression benchmark/augmented classifier.
#
# alpha = 1 gives LASSO regularization. lambda.1se is used as a conservative
# cross-validated choice to avoid overfitting high-dimensional feature sets.
fit_glmnet_classifier <- function(train_df, test_df, feature_cols, alpha = 1, nfolds = 5) {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    stop("The glmnet package is required for penalized logistic regression.")
  }
  matrices <- make_model_matrix(train_df, test_df, feature_cols)
  x_train <- matrices$x_train
  x_test <- matrices$x_test
  if (ncol(x_train) == 0) {
    return(rep(mean(train_df$target_direction == 1), nrow(test_df)))
  }
  y_train <- train_df$target_direction
  cv_fit <- glmnet::cv.glmnet(
    x_train, y_train,
    family = "binomial",
    alpha = alpha,
    type.measure = "class",
    nfolds = nfolds
  )
  as.numeric(stats::predict(cv_fit, newx = x_test, s = "lambda.1se", type = "response"))
}

# Random forest secondary classifier.
#
# This gives a nonlinear comparison model without heavy tuning. The training
# sample is capped to keep runtime feasible for repeated robustness runs.
fit_random_forest_classifier <- function(train_df, test_df, feature_cols, max_train_rows = 100000, ntree = 300) {
  if (!requireNamespace("randomForest", quietly = TRUE)) {
    return(NULL)
  }
  # Tree models can learn target-asset-specific effects through asset splits, so
  # explicit formula interaction terms are dropped for RF to keep the formula
  # parser simple and the model size manageable.
  feature_cols <- feature_cols[!grepl("^factor\\(asset\\):", feature_cols)]
  if (!"asset" %in% feature_cols) {
    feature_cols <- c(feature_cols, "asset")
  }
  if (nrow(train_df) > max_train_rows) {
    set.seed(20260529)
    train_df <- train_df[sample(seq_len(nrow(train_df)), max_train_rows), , drop = FALSE]
  }
  formula <- stats::as.formula(paste("as.factor(target_direction) ~", paste(feature_cols, collapse = " + ")))
  fit <- randomForest::randomForest(formula, data = train_df, ntree = ntree)
  as.numeric(stats::predict(fit, newdata = test_df, type = "prob")[, "1"])
}

# XGBoost secondary classifier.
#
# The configuration is intentionally conservative and classic: shallow trees,
# modest learning rate, and binary logistic objective. It is meant to test
# whether nonlinear interactions improve prediction, not to maximize a trading
# strategy through extensive tuning.
fit_xgboost_classifier <- function(train_df, test_df, feature_cols, nrounds = 150) {
  if (!requireNamespace("xgboost", quietly = TRUE)) {
    return(NULL)
  }
  # XGBoost receives a sparse design matrix. Asset main effects are included so
  # trees can split differently by target asset; explicit interactions are kept
  # only when present in feature_cols.
  matrices <- make_model_matrix(train_df, test_df, feature_cols, include_asset_main_effect = TRUE)
  x_train <- matrices$x_train
  x_test <- matrices$x_test
  if (ncol(x_train) == 0) {
    return(rep(mean(train_df$target_direction == 1), nrow(test_df)))
  }
  dtrain <- xgboost::xgb.DMatrix(data = x_train, label = train_df$target_direction)
  fit <- xgboost::xgb.train(
    params = list(objective = "binary:logistic", eval_metric = "logloss", max_depth = 3, eta = 0.05),
    data = dtrain,
    nrounds = nrounds,
    verbose = 0
  )
  as.numeric(stats::predict(fit, x_test))
}

# Compute the same metrics separately for each target cryptocurrency.
per_asset_metric_rows <- function(model_name, feature_set, test_df, probability) {
  rows <- list()
  for (asset_name in sort(unique(test_df$asset))) {
    idx <- test_df$asset == asset_name
    row <- metric_row(model_name, feature_set, test_df$target_direction[idx], probability[idx])
    row$asset <- asset_name
    rows[[length(rows) + 1]] <- row[, c("asset", setdiff(names(row), "asset"))]
  }
  do.call(rbind, rows)
}

# Main prediction evaluation routine.
#
# The time split preserves forecast ordering: earlier observations train the
# model, later observations test it. The returned objects are written by the
# merge script as overall metrics, per-asset metrics, prediction probabilities,
# and split metadata.
evaluate_prediction_models <- function(prediction_panel, lag_cap, test_fraction = 0.3) {
  prediction_panel$timestamp_utc <- as.character(prediction_panel$timestamp_utc)
  ordered_times <- sort(unique(prediction_panel$timestamp_utc))
  split_time <- ordered_times[max(1, floor(length(ordered_times) * (1 - test_fraction)))]
  train_df <- prediction_panel[prediction_panel$timestamp_utc <= split_time, , drop = FALSE]
  test_df <- prediction_panel[prediction_panel$timestamp_utc > split_time, , drop = FALSE]

  lag_cols <- grep("^ret_.*_lag[0-9]+$", names(prediction_panel), value = TRUE)
  time_cols <- c("hour_sin", "hour_cos", "dow_sin", "dow_cos")
  network_cols <- c(
    "own_persistence", "incoming_cross_effect", "outgoing_cross_effect",
    "net_influence", "incoming_edge_count", "outgoing_edge_count"
  )
  signal_cols <- c(
    "network_weighted_own_return", "network_weighted_cross_return",
    "network_weighted_total_return"
  )
  pair_signal_cols <- grep("^signal_from_", names(prediction_panel), value = TRUE)
  asset_pair_interaction_cols <- paste0("factor(asset):", pair_signal_cols)
  asset_aggregate_interaction_cols <- paste0("factor(asset):", signal_cols)

  # Feature-set definitions used to answer the research question. The benchmark
  # is lagged_returns; the remaining sets add different BigVAR-derived network
  # representations to test where incremental predictive value appears.
  feature_sets <- list(
    lagged_returns = c(lag_cols, time_cols),
    lagged_returns_plus_node_network = c(lag_cols, network_cols, time_cols),
    lagged_returns_plus_aggregate_signals = c(lag_cols, signal_cols, time_cols),
    lagged_returns_plus_pair_signals = c(lag_cols, pair_signal_cols, time_cols),
    lagged_returns_plus_all_network = c(lag_cols, network_cols, signal_cols, pair_signal_cols, time_cols),
    lagged_returns_plus_asset_signal_interactions = c(
      lag_cols, network_cols, time_cols, "factor(asset)", signal_cols, pair_signal_cols,
      asset_aggregate_interaction_cols, asset_pair_interaction_cols
    )
  )

  metrics <- list()
  per_asset_metrics <- list()
  predictions <- list()

  # Naive baseline: always use the historical positive rate from the training
  # sample. With a 0.5 cutoff this becomes the historical majority direction.
  naive_prob <- rep(mean(train_df$target_direction == 1), nrow(test_df))
  metrics[[length(metrics) + 1]] <- metric_row("historical_positive_rate", "naive", test_df$target_direction, naive_prob)
  per_asset_metrics[[length(per_asset_metrics) + 1]] <- per_asset_metric_rows(
    "historical_positive_rate", "naive", test_df, naive_prob
  )

  for (feature_set_name in names(feature_sets)) {
    features <- feature_sets[[feature_set_name]]

    # Each model is wrapped in tryCatch so one model failure does not erase the
    # rest of the evaluation table for the same empirical run.
    glmnet_prob <- tryCatch(fit_glmnet_classifier(train_df, test_df, features), error = function(e) NULL)
    if (!is.null(glmnet_prob)) {
      metrics[[length(metrics) + 1]] <- metric_row("glmnet_logistic", feature_set_name, test_df$target_direction, glmnet_prob)
      per_asset_metrics[[length(per_asset_metrics) + 1]] <- per_asset_metric_rows(
        "glmnet_logistic", feature_set_name, test_df, glmnet_prob
      )
      predictions[[length(predictions) + 1]] <- data.frame(
        timestamp_utc = test_df$timestamp_utc,
        asset = test_df$asset,
        actual = test_df$target_direction,
        model = "glmnet_logistic",
        feature_set = feature_set_name,
        probability = glmnet_prob,
        stringsAsFactors = FALSE
      )
    }

    rf_prob <- tryCatch(fit_random_forest_classifier(train_df, test_df, features), error = function(e) NULL)
    if (!is.null(rf_prob)) {
      metrics[[length(metrics) + 1]] <- metric_row("random_forest", feature_set_name, test_df$target_direction, rf_prob)
      per_asset_metrics[[length(per_asset_metrics) + 1]] <- per_asset_metric_rows(
        "random_forest", feature_set_name, test_df, rf_prob
      )
      predictions[[length(predictions) + 1]] <- data.frame(
        timestamp_utc = test_df$timestamp_utc,
        asset = test_df$asset,
        actual = test_df$target_direction,
        model = "random_forest",
        feature_set = feature_set_name,
        probability = rf_prob,
        stringsAsFactors = FALSE
      )
    }

    xgb_prob <- tryCatch(fit_xgboost_classifier(train_df, test_df, features), error = function(e) NULL)
    if (!is.null(xgb_prob)) {
      metrics[[length(metrics) + 1]] <- metric_row("xgboost", feature_set_name, test_df$target_direction, xgb_prob)
      per_asset_metrics[[length(per_asset_metrics) + 1]] <- per_asset_metric_rows(
        "xgboost", feature_set_name, test_df, xgb_prob
      )
      predictions[[length(predictions) + 1]] <- data.frame(
        timestamp_utc = test_df$timestamp_utc,
        asset = test_df$asset,
        actual = test_df$target_direction,
        model = "xgboost",
        feature_set = feature_set_name,
        probability = xgb_prob,
        stringsAsFactors = FALSE
      )
    }
  }

  list(
    metrics = do.call(rbind, metrics),
    per_asset_metrics = do.call(rbind, per_asset_metrics),
    predictions = if (length(predictions) == 0) data.frame() else do.call(rbind, predictions),
    split = data.frame(
      lag_cap = lag_cap,
      split_time = split_time,
      n_train = nrow(train_df),
      n_test = nrow(test_df),
      stringsAsFactors = FALSE
    )
  )
}
