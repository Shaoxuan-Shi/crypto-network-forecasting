# BigVAR network estimation and feature construction helpers.
#
# This file contains the core methodology objects:
# - fitting a sparse BigVAR model on each rolling window;
# - converting BigVAR coefficients into directed source-target-lag tables;
# - summarizing each asset's network role at every refit origin;
# - building hourly BigVAR-implied signal features for prediction.

# Load the wide hourly return panel used as BigVAR input.
#
# BigVAR expects a multivariate time-series matrix with one row per timestamp
# and one column per asset. Missing asset columns are treated as fatal because
# the coefficient interpretation depends on a stable asset order.
load_returns_wide <- function(path, assets = primary_assets) {
  raw <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  raw$timestamp_utc <- as.POSIXct(raw$timestamp_utc, tz = "UTC")
  missing_assets <- setdiff(assets, names(raw))
  if (length(missing_assets) > 0) {
    stop("Missing asset columns in returns file: ", paste(missing_assets, collapse = ", "))
  }
  raw <- raw[, c("timestamp_utc", assets)]
  keep <- complete.cases(raw[, assets])
  raw[keep, , drop = FALSE]
}

# Convert one fitted BigVAR coefficient object into analysis-ready network data.
#
# For a VAR(p), each refit produces p lag-specific 12 x 12 coefficient matrices.
# BigVAR exposes them as columns such as Y1L1, Y2L1, ..., Y12Lp. This parser
# translates those package-specific names into explicit lag/from_asset/to_asset
# rows and creates interpretable summaries for each target asset.
parse_bigvar_coefficients <- function(coef_df, assets, lag_cap, timestamp_utc, structure, tolerance = 1e-8) {
  coef_mat <- as.matrix(coef_df)
  if (nrow(coef_mat) != length(assets)) {
    stop("Coefficient row count does not match asset count.")
  }

  network_rows <- list()
  edge_rows <- list()
  coefficient_rows <- list()

  for (target_idx in seq_along(assets)) {
    target <- assets[target_idx]
    # These node-level features describe the target asset's role in the fitted
    # directed predictive network at this refit timestamp.
    incoming_cross <- 0
    outgoing_cross <- 0
    own_persistence <- 0
    incoming_edge_count <- 0
    outgoing_edge_count <- 0

    for (lag in seq_len(lag_cap)) {
      for (predictor_idx in seq_along(assets)) {
        predictor_col <- paste0("Y", predictor_idx, "L", lag)
        if (!predictor_col %in% colnames(coef_mat)) {
          next
        }

        # Incoming coefficient: how source asset at this lag enters the target
        # asset equation. This is the primitive object used for both edge lists
        # and later weighted lagged-return signal construction.
        incoming_value <- coef_mat[target_idx, predictor_col]
        coefficient_rows[[length(coefficient_rows) + 1]] <- data.frame(
          refit_timestamp_utc = format(timestamp_utc, "%Y-%m-%d %H:%M:%S"),
          structure = structure,
          lag = lag,
          from_asset = assets[predictor_idx],
          to_asset = target,
          coefficient = incoming_value,
          abs_coefficient = abs(incoming_value),
          is_own_edge = target_idx == predictor_idx,
          stringsAsFactors = FALSE
        )

        if (target_idx == predictor_idx) {
          own_persistence <- own_persistence + abs(incoming_value)
        } else {
          incoming_cross <- incoming_cross + abs(incoming_value)
          incoming_edge_count <- incoming_edge_count + as.integer(abs(incoming_value) > tolerance)
        }

        # Outgoing influence is measured from the symmetric perspective: how the
        # current target asset appears as a predictor in other assets' equations.
        outgoing_value <- coef_mat[predictor_idx, paste0("Y", target_idx, "L", lag)]
        if (target_idx != predictor_idx && !is.na(outgoing_value)) {
          outgoing_cross <- outgoing_cross + abs(outgoing_value)
          outgoing_edge_count <- outgoing_edge_count + as.integer(abs(outgoing_value) > tolerance)
        }

        if (abs(incoming_value) > tolerance) {
          # Sparse edge list keeps only coefficients that survive the tolerance
          # threshold; the dense table above still preserves zeros for auditing.
          edge_rows[[length(edge_rows) + 1]] <- data.frame(
            refit_timestamp_utc = format(timestamp_utc, "%Y-%m-%d %H:%M:%S"),
            structure = structure,
            lag = lag,
            from_asset = assets[predictor_idx],
            to_asset = target,
            coefficient = incoming_value,
            abs_coefficient = abs(incoming_value),
            is_own_edge = target_idx == predictor_idx,
            stringsAsFactors = FALSE
          )
        }
      }
    }

    network_rows[[length(network_rows) + 1]] <- data.frame(
      refit_timestamp_utc = format(timestamp_utc, "%Y-%m-%d %H:%M:%S"),
      asset = target,
      structure = structure,
      own_persistence = own_persistence,
      incoming_cross_effect = incoming_cross,
      outgoing_cross_effect = outgoing_cross,
      net_influence = outgoing_cross - incoming_cross,
      incoming_edge_count = incoming_edge_count,
      outgoing_edge_count = outgoing_edge_count,
      stringsAsFactors = FALSE
    )
  }

  list(
    features = do.call(rbind, network_rows),
    edges = if (length(edge_rows) == 0) data.frame() else do.call(rbind, edge_rows),
    coefficients = do.call(rbind, coefficient_rows)
  )
}

# Fit one BigVAR model for one rolling-window origin.
#
# The selected structure is passed directly to BigVAR::constructModel. In the
# main experiments this is HLAGELEM, but the helper is generic so robustness
# structures can be run with the same code.
fit_bigvar_at_origin <- function(window_matrix, lag_cap, structure, horizon = 1, verbose = FALSE) {
  if (!requireNamespace("BigVAR", quietly = TRUE)) {
    stop("The BigVAR package is required for sparse VAR network estimation.")
  }
  if (!"package:BigVAR" %in% search()) {
    suppressPackageStartupMessages(library(BigVAR))
  }
  model <- BigVAR::constructModel(
    Y = window_matrix,
    p = lag_cap,
    struct = structure,
    gran = c(50, 10),
    h = horizon,
    cv = "Rolling",
    verbose = verbose,
    IC = TRUE,
    window.size = max(24, floor(nrow(window_matrix) / 4)),
    model.controls = list(intercept = TRUE)
  )
  BigVAR::cv.BigVAR(model)
}

# Full-sample rolling network estimator.
#
# This function predates the block runner and is still useful for smoke tests or
# small runs. Large experiments use run_network_forecast_pipeline_block.R to
# split the same rolling-refit logic into separate blocks.
estimate_rolling_network_features <- function(
    returns_wide,
    assets,
    lag_cap,
    window_days,
    structure,
    step_hours = 24,
    horizon = 1,
    tolerance = 1e-8,
    max_origins = Inf,
    verbose = FALSE) {
  window_hours <- window_days * 24
  if (nrow(returns_wide) <= window_hours + lag_cap + horizon) {
    stop("Not enough observations for the requested rolling window and lag cap.")
  }

  origin_indices <- seq(window_hours, nrow(returns_wide) - horizon, by = step_hours)
  if (is.finite(max_origins)) {
    origin_indices <- head(origin_indices, max_origins)
  }

  feature_blocks <- list()
  edge_blocks <- list()
  coefficient_blocks <- list()
  status_rows <- list()

  for (k in seq_along(origin_indices)) {
    origin_idx <- origin_indices[k]
    origin_time <- returns_wide$timestamp_utc[origin_idx]
    window_start <- origin_idx - window_hours + 1
    window_data <- as.matrix(returns_wide[window_start:origin_idx, assets, drop = FALSE])

    if (verbose) {
      message(sprintf(
        "[%s] Estimating %s p=%s window=%sd at %s (%s/%s)",
        Sys.time(), structure, lag_cap, window_days, format(origin_time, "%Y-%m-%d %H:%M:%S"), k, length(origin_indices)
      ))
    }

    fit <- try(fit_bigvar_at_origin(window_data, lag_cap, structure, horizon, verbose = FALSE), silent = TRUE)
    if (inherits(fit, "try-error")) {
      status_rows[[length(status_rows) + 1]] <- data.frame(
        timestamp_utc = format(origin_time, "%Y-%m-%d %H:%M:%S"),
        structure = structure,
        lag_cap = lag_cap,
        window_days = window_days,
        status = "failed",
        message = as.character(fit),
        stringsAsFactors = FALSE
      )
      next
    }

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

# Reconstruct the coefficient matrix for a single refit timestamp.
#
# Rows are target assets. Columns stack all source assets across lags:
# BTC_lag1, ETH_lag1, ..., DOT_lag1, BTC_lag2, ..., DOT_lagp.
coefficient_matrix_for_refit <- function(coefficients, refit_timestamp, assets, lag_cap) {
  coef_mat <- matrix(0, nrow = length(assets), ncol = length(assets) * lag_cap)
  rownames(coef_mat) <- assets
  colnames(coef_mat) <- as.vector(sapply(seq_len(lag_cap), function(lag) paste0(assets, "_lag", lag)))

  block <- coefficients[coefficients$refit_timestamp_utc == refit_timestamp, , drop = FALSE]
  for (row_idx in seq_len(nrow(block))) {
    target_idx <- match(block$to_asset[row_idx], assets)
    source_idx <- match(block$from_asset[row_idx], assets)
    col_idx <- (block$lag[row_idx] - 1) * length(assets) + source_idx
    coef_mat[target_idx, col_idx] <- block$coefficient[row_idx]
  }
  coef_mat
}

# Build the lagged return vector aligned with coefficient_matrix_for_refit().
#
# Lag 1 corresponds to return_t at forecast origin t. These values are known
# before predicting return_{t+1}, so this construction avoids look-ahead bias.
lag_vector_at_time <- function(returns_wide, time_idx, assets, lag_cap) {
  values <- numeric(length(assets) * lag_cap)
  names(values) <- as.vector(sapply(seq_len(lag_cap), function(lag) paste0(assets, "_lag", lag)))
  for (lag in seq_len(lag_cap)) {
    source_idx <- time_idx - lag + 1
    offset <- (lag - 1) * length(assets)
    values[(offset + 1):(offset + length(assets))] <- as.numeric(returns_wide[source_idx, assets])
  }
  values
}

# Expand refit-level BigVAR outputs to hourly asset-level prediction features.
#
# Coefficients are estimated only at refit timestamps. Between refits, the same
# coefficients are reused, but the lagged return vector changes every hour. This
# creates hourly network-implied predictive contribution features without
# refitting BigVAR every hour.
build_hourly_network_signal_features <- function(
    returns_wide,
    assets,
    lag_cap,
    network_features,
    coefficients,
    horizon = 1,
    max_extension_hours = Inf) {
  if (nrow(network_features) == 0 || nrow(coefficients) == 0) {
    return(data.frame())
  }

  returns_wide$timestamp_label <- format(returns_wide$timestamp_utc, "%Y-%m-%d %H:%M:%S")
  refit_times <- sort(unique(coefficients$refit_timestamp_utc))
  refit_indices <- match(refit_times, returns_wide$timestamp_label)
  valid <- !is.na(refit_indices)
  refit_times <- refit_times[valid]
  refit_indices <- refit_indices[valid]

  feature_rows <- list()
  pair_cols <- paste0("signal_from_", assets)

  for (r in seq_along(refit_times)) {
    refit_time <- refit_times[r]
    # The current refit's coefficients are valid from the refit timestamp until
    # the next refit. For block runs, max_extension_hours prevents one block's
    # last refit from covering timestamps that belong to the next block.
    start_idx <- max(refit_indices[r], lag_cap)
    next_refit_end <- if (r < length(refit_indices)) {
      min(refit_indices[r + 1] - 1, nrow(returns_wide) - horizon)
    } else {
      nrow(returns_wide) - horizon
    }
    extension_end <- if (is.finite(max_extension_hours)) {
      min(start_idx + max_extension_hours - 1, nrow(returns_wide) - horizon)
    } else {
      nrow(returns_wide) - horizon
    }
    end_idx <- min(next_refit_end, extension_end)
    if (start_idx > end_idx) {
      next
    }

    coef_mat <- coefficient_matrix_for_refit(coefficients, refit_time, assets, lag_cap)
    node_block <- network_features[network_features$refit_timestamp_utc == refit_time, , drop = FALSE]

    for (time_idx in start_idx:end_idx) {
      current_time <- returns_wide$timestamp_label[time_idx]
      lag_values <- lag_vector_at_time(returns_wide, time_idx, assets, lag_cap)
      # Total signal is the fitted VAR contribution from all own and cross-asset
      # lagged returns for each target asset equation.
      total_signal <- as.numeric(coef_mat %*% lag_values)

      for (target_idx in seq_along(assets)) {
        target <- assets[target_idx]
        pair_signals <- numeric(length(assets))
        names(pair_signals) <- pair_cols
        for (source_idx in seq_along(assets)) {
          # Pair-specific signal from source A to target B sums the selected
          # A -> B coefficients across all lags times source A's lagged returns.
          source_cols <- source_idx + (seq_len(lag_cap) - 1) * length(assets)
          pair_signals[source_idx] <- sum(coef_mat[target_idx, source_cols] * lag_values[source_cols])
        }
        own_signal <- pair_signals[target_idx]
        cross_signal <- sum(pair_signals[-target_idx])
        # The pair-specific incoming feature set focuses on other coins' signals;
        # own contribution is represented separately as network_weighted_own_return.
        pair_signals[target_idx] <- 0

        node_row <- node_block[node_block$asset == target, , drop = FALSE]
        feature_rows[[length(feature_rows) + 1]] <- cbind(
          data.frame(
            timestamp_utc = current_time,
            refit_timestamp_utc = refit_time,
            asset = target,
            structure = node_row$structure,
            own_persistence = node_row$own_persistence,
            incoming_cross_effect = node_row$incoming_cross_effect,
            outgoing_cross_effect = node_row$outgoing_cross_effect,
            net_influence = node_row$net_influence,
            incoming_edge_count = node_row$incoming_edge_count,
            outgoing_edge_count = node_row$outgoing_edge_count,
            network_weighted_own_return = own_signal,
            network_weighted_cross_return = cross_signal,
            network_weighted_total_return = total_signal[target_idx],
            stringsAsFactors = FALSE
          ),
          as.data.frame(as.list(pair_signals), check.names = FALSE)
        )
      }
    }
  }

  if (length(feature_rows) == 0) {
    data.frame()
  } else {
    do.call(rbind, feature_rows)
  }
}
