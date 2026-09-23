#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(ggplot2))

script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  script_path <- "scripts/create_portfolio_figures.R"
}
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)

robustness_input <- file.path(root, "results", "robustness_best_delta_auc.csv")
robustness_output <- file.path(root, "results", "figures", "robustness_delta_auc.png")
metrics <- read.csv(robustness_input, stringsAsFactors = FALSE)

model_labels <- c(
  glmnet_logistic = "LASSO logistic",
  random_forest = "Random forest",
  xgboost = "XGBoost"
)
metrics$model_label <- factor(
  model_labels[metrics$model],
  levels = unname(model_labels)
)
metrics$lag_cap <- factor(metrics$lag_cap, levels = c(24, 12, 6))
metrics$window_days <- factor(metrics$window_days, levels = c(15, 30, 45))
limit <- max(abs(metrics$delta_auc), na.rm = TRUE)

plot <- ggplot(metrics, aes(x = window_days, y = lag_cap, fill = delta_auc)) +
  geom_tile(color = "white", linewidth = 1) +
  geom_text(aes(label = sprintf("%+.3f", delta_auc)), size = 4.1) +
  facet_wrap(~ model_label, nrow = 1) +
  scale_fill_gradient2(
    low = "#C44E52",
    mid = "#F7F7F7",
    high = "#2F6DAE",
    midpoint = 0,
    limits = c(-limit, limit),
    name = expression(Delta~AUC)
  ) +
  labs(
    title = "Best incremental AUC from network features",
    subtitle = "Maximum gain over the lagged-return benchmark within each model and BigVAR setting",
    x = "Rolling window (days)",
    y = "Lag cap p (hours)",
    caption = "Daily refits; two-year out-of-sample design. Best-feature selection is descriptive."
  ) +
  theme_minimal(base_size = 13) +
  theme(
    panel.grid = element_blank(),
    strip.text = element_text(face = "bold", size = 13),
    plot.title = element_text(face = "bold", size = 17),
    plot.subtitle = element_text(size = 11, color = "#444444"),
    plot.caption = element_text(size = 9, color = "#555555"),
    legend.position = "right"
  )

ggsave(robustness_output, plot, width = 12, height = 5.2, dpi = 200, bg = "white")
message("Wrote ", robustness_output)

xgboost_input <- file.path(root, "results", "xgboost_diagnostic_summary.csv")
xgboost_output <- file.path(root, "results", "figures", "xgboost_diagnostic_delta_auc.png")
xgboost_summary <- read.csv(xgboost_input, stringsAsFactors = FALSE)
xgboost_summary <- xgboost_summary[xgboost_summary$feature_set != "lagged_returns", , drop = FALSE]

feature_labels <- c(
  lagged_returns_plus_node_network = "Node summaries",
  lagged_returns_plus_aggregate_signals = "Aggregate signals",
  lagged_returns_plus_pair_signals = "Pair signals",
  lagged_returns_plus_all_network = "Full network",
  lagged_returns_plus_asset_signal_interactions = "Asset-specific signals"
)
xgboost_summary$feature_label <- factor(
  feature_labels[xgboost_summary$feature_set],
  levels = rev(unname(feature_labels))
)
xgboost_summary$direction <- ifelse(xgboost_summary$delta_test_auc >= 0, "Positive", "Negative")

xgboost_plot <- ggplot(
  xgboost_summary,
  aes(x = feature_label, y = delta_test_auc, fill = direction)
) +
  geom_hline(yintercept = 0, color = "#555555", linewidth = 0.5) +
  geom_col(width = 0.65) +
  geom_text(
    aes(
      label = sprintf("%+.4f", delta_test_auc),
      y = delta_test_auc + ifelse(delta_test_auc >= 0, 0.00025, -0.00025)
    ),
    hjust = ifelse(xgboost_summary$delta_test_auc >= 0, 0, 1),
    size = 4
  ) +
  coord_flip(clip = "off") +
  scale_fill_manual(values = c(Positive = "#2F6DAE", Negative = "#C44E52"), guide = "none") +
  scale_y_continuous(limits = c(-0.0065, 0.003), breaks = seq(-0.006, 0.002, by = 0.002)) +
  labs(
    title = "XGBoost sensitivity check",
    subtitle = "Change in test AUC after validation-based early stopping",
    x = NULL,
    y = expression(Delta~AUC),
    caption = "Compared with the lagged-return model on the same holdout period. Changes are descriptive."
  ) +
  theme_minimal(base_size = 13) +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.minor = element_blank(),
    plot.title = element_text(face = "bold", size = 17),
    plot.subtitle = element_text(size = 11, color = "#444444"),
    plot.caption = element_text(size = 9, color = "#555555"),
    plot.margin = margin(10, 25, 10, 10)
  )

ggsave(xgboost_output, xgboost_plot, width = 9, height = 5.2, dpi = 200, bg = "white")
message("Wrote ", xgboost_output)
