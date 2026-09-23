# Reproducibility guide

_How to run the compact demonstration and reconstruct the full empirical pipeline_

---

## 🚀 Compact demo

The bundled 35-day sample supports a small end-to-end run:

```bash
Rscript scripts/install_required_packages.R
Rscript scripts/run_demo.R
```

The demo fits two rolling `HLAGELEM` networks with `p = 12` and writes results under `results/demo/`. The dates cover a representative sparse-network refit, so the output includes selected cross-asset edges. It verifies the workflow; it is not intended to reproduce the reported two-year estimates.

## 📦 Full primary run

Prepare the full inputs:

```bash
python3 scripts/download_binance_hourly_data.py
python3 scripts/prepare_crypto_hourly_dataset.py
```

Then run the primary configuration:

```bash
bash scripts/run_full_primary.sh
```

The primary run uses `700` daily refits split into `28` blocks of `25` origins. Each block writes recoverable intermediate files before model evaluation.

## ⚡ Runtime and compute

| Run | Workload | Practical expectation |
| --- | --- | --- |
| Demo | 2 sparse VAR refits | About 1–2 minutes on the local test machine |
| Primary block | 25 sparse VAR refits | About 20–25 minutes in the original run environment |
| Full primary, sequential | 28 blocks | Roughly 9–12 hours based on recorded block times |
| Full primary, parallel | Independent blocks | About 1.5 hours in the original multi-worker run |

Runtime varies with CPU, package versions, and available parallel workers. A modern machine with at least `16 GB` RAM is a reasonable starting point; `8+` CPU cores are useful when blocks are scheduled in parallel. The supplied shell script runs sequentially for portability.

## 🧰 Reference environment

The reported results and local verification used the following direct software versions:

| Software | Version |
| --- | --- |
| R | 4.4.1 |
| BigVAR | 1.1.4 |
| glmnet | 4.1-10 |
| Matrix | 1.7-0 |
| randomForest | 4.7-1.2 |
| xgboost | 3.2.1.1 |
| ggplot2 | 4.0.2 |

## 🔍 Verification

Run lightweight checks without fitting the full model:

```bash
make check
```

Regenerate the portfolio heatmap from the included summary data:

```bash
make figures
```

After the full primary run, reproduce the validation-based XGBoost check:

```bash
Rscript scripts/run_xgboost_diagnostic.R
```

This check reuses the merged primary prediction panel and normally finishes in under a minute once that panel exists. It writes a compact summary to `results/xgboost_diagnostic_summary.csv` and detailed feature importance to the ignored `results/checkpoints/` directory.

Expected full-sample checkpoints:

| Check | Expected value |
| --- | ---: |
| Hourly timestamps per asset | 17,520 |
| Primary daily refits | 700 |
| Assets | 12 |
| Pooled test predictions per model-feature set | 60,480 |

## ⚠️ Reproducibility scope

The repository includes the code and compact sample needed to inspect and test the workflow. Exact full-result reproduction requires downloading the archived Binance inputs and running the computationally intensive block pipeline. Random seeds control stochastic classifiers where implemented, but numerical differences can still occur across package and platform versions.
