# Methodology

_Technical design for extracting dynamic network features and testing their incremental forecasting value_

---

## 🎯 Research design

The project asks whether features extracted from a rolling sparse vector autoregression add out-of-sample information beyond conventional lagged-return predictors.

The primary design uses 12 hourly cryptocurrency return series, a `30`-day rolling estimation window, a lag cap of `12` hours, and daily network refits. Robustness settings vary the lag cap over `{6, 12, 24}` and the rolling window over `{15, 30, 45}` days. The main [README](../README.md) provides a visual overview of the full pipeline.

## ⚙️ Sparse VAR layer

For the return vector `r[t]`, the project estimates a regularized VAR:

```text
r[t] = c + A[1]r[t-1] + ... + A[p]r[t-p] + u[t]
```

The primary estimator is the `HLAGELEM` structure implemented in `BigVAR`. Hierarchical lag regularization preserves the ordered nature of time lags while allowing different source-target pairs to have different effective lag depths.[^1][^2]

Nonzero cross-asset coefficients are interpreted as directed lagged predictive links, not structural causal effects.

## 🔗 Network features

Each rolling fit is converted into three feature groups:

| Feature group | Examples | Interpretation |
| --- | --- | --- |
| Node summaries | Incoming effect, outgoing effect, net influence | Current network role of each asset |
| Aggregate signals | Own, cross, and total weighted returns | VAR-implied predictive contribution |
| Pair signals | `signal_from_BTC`, `signal_from_ETH`, ... | Source-specific incoming contribution |

Coefficients remain fixed between daily refits, while lagged returns update hourly. This creates hourly signals without using information after the forecast origin.

## 📊 Forecast evaluation

The benchmark contains lagged returns and calendar controls. Network-augmented variants add node, aggregate, pair, full-network, or asset-specific interaction features.

Models are evaluated with:

- LASSO logistic regression
- Random forest
- XGBoost
- Historical positive-rate reference

The main XGBoost comparison uses shallow trees with `max_depth = 3`, a learning rate of `0.05`, and `150` boosting rounds. These settings provide a consistent nonlinear benchmark; they are not an exhaustive tuning exercise. A separate sensitivity check uses a validation period, up to `300` rounds, and early stopping to see whether the main result depends on that fixed choice.

The final comparison uses AUC, balanced accuracy, accuracy, and F1. Moving-block bootstrap intervals use 24-hour timestamp blocks to preserve short-range dependence in the pooled test predictions.

## ⚠️ Interpretation boundary

The workflow evaluates predictive association. It does not claim causal spillovers, a profitable trading strategy, or performance after transaction costs. Best-feature summaries across the robustness grid are descriptive and are not treated as a new validation sample.

## 🔗 References

[^1]: Nicholson, W. B., Matteson, D. S., and Bien, J. (2017). "VARX-L: Structured regularization for large vector autoregressions with exogenous variables." _International Journal of Forecasting_. https://doi.org/10.1016/j.ijforecast.2017.01.003

[^2]: Nicholson, W. B., Wilms, I., Bien, J., and Matteson, D. S. (2020). "High dimensional forecasting via interpretable vector autoregression." _Journal of Machine Learning Research_. https://jmlr.org/papers/v21/19-777.html
