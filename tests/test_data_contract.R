script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)

returns <- read.csv(file.path(root, "data", "sample", "hourly_returns_wide_sample.csv"), check.names = FALSE)
panel <- read.csv(file.path(root, "data", "sample", "forecast_panel_sample.csv"), check.names = FALSE)

assets <- c("BTC", "ETH", "XRP", "BNB", "SOL", "TRX", "DOGE", "ADA", "LINK", "LTC", "AVAX", "DOT")

stopifnot(identical(names(returns), c("timestamp_utc", assets)))
stopifnot(all(c("timestamp_utc", "asset", "return_t", "target_direction", "hour_of_day", "day_of_week") %in% names(panel)))
stopifnot(nrow(returns) == 35 * 24)
stopifnot(setequal(unique(panel$asset), assets))
stopifnot(all(panel$target_direction %in% c(0, 1)))
stopifnot(!anyDuplicated(returns$timestamp_utc))
stopifnot(!anyNA(returns[, assets]))

message("Sample data contract checks passed.")
