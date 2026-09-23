# Data guide

_Data provenance, included sample, and generated-file policy for this repository_

---

## 📋 Data source

The project uses monthly Binance spot-market kline archives for USDT pairs at hourly frequency.[^1] The full empirical sample contains 12 assets from `2024-04-01 00:00:00` through `2026-03-31 23:00:00` UTC.

| Field | Value |
| --- | --- |
| Exchange | Binance spot |
| Quote asset | USDT |
| Frequency | Hourly |
| Full sample | 2024-04-01 to 2026-03-31 |
| Assets | BTC, ETH, XRP, BNB, SOL, TRX, DOGE, ADA, LINK, LTC, AVAX, DOT |
| Full timestamps | 17,520 per asset |

## 📦 Included sample

The repository includes a small processed sample covering 35 days around a representative sparse-network refit:

- `sample/hourly_returns_wide_sample.csv` contains aligned hourly log returns
- `sample/forecast_panel_sample.csv` contains asset-level targets and time controls
- `sample/asset_universe.csv` documents the selected trading pairs

The sample supports the compact demo without committing the full raw or intermediate datasets.

## ⚙️ Full data preparation

Run the following commands from the repository root:

```bash
python3 scripts/download_binance_hourly_data.py
python3 scripts/prepare_crypto_hourly_dataset.py
```

Downloaded archives are written under `data/raw/`; research-ready files are written under `data/processed/`. Both directories are excluded from version control.

## 🔍 Target construction

For asset `i`, the hourly log return is:

```text
r[i,t] = log(P[i,t]) - log(P[i,t-1])
```

The binary target equals one when the next-hour return is positive and zero otherwise. Timestamps remain in UTC throughout preparation and estimation.

## 🔗 References

[^1]: Binance. "Binance Public Data." https://github.com/binance/binance-public-data
