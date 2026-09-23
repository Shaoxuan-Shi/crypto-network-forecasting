#!/usr/bin/env python3
"""Prepare research-ready hourly crypto datasets for the forecasting project.

Outputs:
- asset_universe.csv
- hourly_prices_long.csv
- hourly_returns_wide.csv
- forecast_panel_base.csv
- preparation_summary.json
"""

from __future__ import annotations

import csv
import json
import math
import zipfile
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from statistics import mean, pstdev


ASSETS = [
    "BTCUSDT",
    "ETHUSDT",
    "XRPUSDT",
    "BNBUSDT",
    "SOLUSDT",
    "TRXUSDT",
    "DOGEUSDT",
    "ADAUSDT",
    "LINKUSDT",
    "LTCUSDT",
    "AVAXUSDT",
    "DOTUSDT",
    "BCHUSDT",
    "XLMUSDT",
    "SHIBUSDT",
]

PRIMARY_ASSETS = [
    "BTCUSDT",
    "ETHUSDT",
    "XRPUSDT",
    "BNBUSDT",
    "SOLUSDT",
    "TRXUSDT",
    "DOGEUSDT",
    "ADAUSDT",
    "LINKUSDT",
    "LTCUSDT",
    "AVAXUSDT",
    "DOTUSDT",
]

BACKUP_ASSETS = ["BCHUSDT", "XLMUSDT", "SHIBUSDT"]

SAMPLE_START = datetime(2023, 4, 1, 0, 0, tzinfo=timezone.utc)
SAMPLE_END = datetime(2026, 3, 31, 23, 0, tzinfo=timezone.utc)

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw" / "binance_monthly_zips"
PROCESSED_DIR = ROOT / "data" / "processed"


@dataclass
class PriceRow:
    timestamp_utc: str
    asset: str
    close: float
    open_price: float
    high: float
    low: float
    volume: float
    quote_volume: float
    n_trades: int


def parse_binance_timestamp(raw_value: str) -> datetime:
    value = int(raw_value)
    if value >= 10**15:
        seconds = value / 1_000_000
    else:
        seconds = value / 1_000
    return datetime.fromtimestamp(seconds, tz=timezone.utc)


def iter_zip_csv_rows(symbol: str):
    asset_dir = RAW_DIR / symbol
    for zip_path in sorted(asset_dir.glob("*.zip")):
        with zipfile.ZipFile(zip_path) as archive:
            names = archive.namelist()
            if len(names) != 1:
                raise ValueError(f"Unexpected archive contents in {zip_path}")
            with archive.open(names[0], "r") as file_obj:
                for raw_line in file_obj:
                    line = raw_line.decode("utf-8").strip()
                    if not line:
                        continue
                    yield next(csv.reader([line]))


def load_asset_rows(symbol: str):
    rows = []
    seen_timestamps = set()
    for fields in iter_zip_csv_rows(symbol):
        ts = parse_binance_timestamp(fields[0])
        if ts < SAMPLE_START or ts > SAMPLE_END:
            continue
        ts_label = ts.strftime("%Y-%m-%d %H:%M:%S")
        if ts_label in seen_timestamps:
            continue
        seen_timestamps.add(ts_label)
        rows.append(
            PriceRow(
                timestamp_utc=ts_label,
                asset=symbol.replace("USDT", ""),
                close=float(fields[4]),
                open_price=float(fields[1]),
                high=float(fields[2]),
                low=float(fields[3]),
                volume=float(fields[5]),
                quote_volume=float(fields[7]),
                n_trades=int(float(fields[8])),
            )
        )
    rows.sort(key=lambda row: row.timestamp_utc)
    return rows


def build_hour_grid():
    grid = []
    current = SAMPLE_START
    while current <= SAMPLE_END:
        grid.append(current.strftime("%Y-%m-%d %H:%M:%S"))
        current += timedelta(hours=1)
    return grid


def write_asset_universe():
    path = PROCESSED_DIR / "asset_universe.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "asset",
                "symbol",
                "quote_asset",
                "exchange",
                "market_type",
                "sample_role",
            ]
        )
        for symbol in PRIMARY_ASSETS:
            writer.writerow([symbol.replace("USDT", ""), symbol, "USDT", "Binance", "spot", "primary"])
        for symbol in BACKUP_ASSETS:
            writer.writerow([symbol.replace("USDT", ""), symbol, "USDT", "Binance", "spot", "backup"])
    return path


def write_asset_universe_primary():
    path = PROCESSED_DIR / "asset_universe_primary.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "asset",
                "symbol",
                "quote_asset",
                "exchange",
                "market_type",
            ]
        )
        for symbol in PRIMARY_ASSETS:
            writer.writerow([symbol.replace("USDT", ""), symbol, "USDT", "Binance", "spot"])
    return path


def write_hourly_prices_long(rows_by_symbol: dict[str, list[PriceRow]]):
    path = PROCESSED_DIR / "hourly_prices_long.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "timestamp_utc",
                "asset",
                "symbol",
                "open",
                "high",
                "low",
                "close",
                "volume",
                "quote_volume",
                "n_trades",
            ]
        )
        for symbol in ASSETS:
            for row in rows_by_symbol[symbol]:
                writer.writerow(
                    [
                        row.timestamp_utc,
                        row.asset,
                        symbol,
                        f"{row.open_price:.16g}",
                        f"{row.high:.16g}",
                        f"{row.low:.16g}",
                        f"{row.close:.16g}",
                        f"{row.volume:.16g}",
                        f"{row.quote_volume:.16g}",
                        row.n_trades,
                    ]
                )
    return path


def write_hourly_prices_long_primary(rows_by_symbol: dict[str, list[PriceRow]]):
    path = PROCESSED_DIR / "hourly_prices_long_primary.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "timestamp_utc",
                "asset",
                "symbol",
                "open",
                "high",
                "low",
                "close",
                "volume",
                "quote_volume",
                "n_trades",
            ]
        )
        for symbol in PRIMARY_ASSETS:
            for row in rows_by_symbol[symbol]:
                writer.writerow(
                    [
                        row.timestamp_utc,
                        row.asset,
                        symbol,
                        f"{row.open_price:.16g}",
                        f"{row.high:.16g}",
                        f"{row.low:.16g}",
                        f"{row.close:.16g}",
                        f"{row.volume:.16g}",
                        f"{row.quote_volume:.16g}",
                        row.n_trades,
                    ]
                )
    return path


def build_close_maps(rows_by_symbol: dict[str, list[PriceRow]]):
    close_maps = {}
    for symbol, rows in rows_by_symbol.items():
        close_maps[symbol] = {row.timestamp_utc: row.close for row in rows}
    return close_maps


def write_hourly_returns_wide(close_maps: dict[str, dict[str, float]], hour_grid: list[str]):
    path = PROCESSED_DIR / "hourly_returns_wide.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        header = ["timestamp_utc"] + [symbol.replace("USDT", "") for symbol in PRIMARY_ASSETS]
        writer.writerow(header)
        previous_close = {symbol: None for symbol in PRIMARY_ASSETS}
        for timestamp in hour_grid:
            row_out = [timestamp]
            for symbol in PRIMARY_ASSETS:
                close_price = close_maps[symbol].get(timestamp)
                if close_price is None or previous_close[symbol] is None:
                    row_out.append("")
                else:
                    row_out.append(f"{math.log(close_price) - math.log(previous_close[symbol]):.16g}")
                if close_price is not None:
                    previous_close[symbol] = close_price
            writer.writerow(row_out)
    return path


def write_hourly_returns_wide_primary(close_maps: dict[str, dict[str, float]], hour_grid: list[str]):
    path = PROCESSED_DIR / "hourly_returns_wide_primary.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        header = ["timestamp_utc"] + [symbol.replace("USDT", "") for symbol in PRIMARY_ASSETS]
        writer.writerow(header)
        previous_close = {symbol: None for symbol in PRIMARY_ASSETS}
        for timestamp in hour_grid:
            row_out = [timestamp]
            for symbol in PRIMARY_ASSETS:
                close_price = close_maps[symbol].get(timestamp)
                if close_price is None or previous_close[symbol] is None:
                    row_out.append("")
                else:
                    row_out.append(f"{math.log(close_price) - math.log(previous_close[symbol]):.16g}")
                if close_price is not None:
                    previous_close[symbol] = close_price
            writer.writerow(row_out)
    return path


def write_forecast_panel_base(close_maps: dict[str, dict[str, float]], hour_grid: list[str]):
    returns = defaultdict(dict)
    previous_close = {symbol: None for symbol in PRIMARY_ASSETS}
    for timestamp in hour_grid:
        for symbol in PRIMARY_ASSETS:
            close_price = close_maps[symbol].get(timestamp)
            if close_price is not None and previous_close[symbol] is not None:
                returns[symbol][timestamp] = math.log(close_price) - math.log(previous_close[symbol])
            if close_price is not None:
                previous_close[symbol] = close_price

    path = PROCESSED_DIR / "forecast_panel_base.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "timestamp_utc",
                "asset",
                "return_t",
                "target_direction",
                "hour_of_day",
                "day_of_week",
            ]
        )
        for idx, timestamp in enumerate(hour_grid[:-1]):
            dt = datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
            next_timestamp = hour_grid[idx + 1]
            for symbol in PRIMARY_ASSETS:
                current_return = returns[symbol].get(timestamp)
                next_return = returns[symbol].get(next_timestamp)
                if current_return is None or next_return is None:
                    continue
                writer.writerow(
                    [
                        timestamp,
                        symbol.replace("USDT", ""),
                        f"{current_return:.16g}",
                        1 if next_return > 0 else 0,
                        dt.hour,
                        dt.weekday(),
                    ]
                )
    return path


def write_forecast_panel_primary(close_maps: dict[str, dict[str, float]], hour_grid: list[str]):
    path = PROCESSED_DIR / "forecast_panel_primary.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "timestamp_utc",
                "asset",
                "return_t",
                "target_direction",
                "hour_of_day",
                "day_of_week",
            ]
        )
        returns = build_primary_returns(hour_grid, close_maps)
        for idx, timestamp in enumerate(hour_grid[:-1]):
            dt = datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
            next_timestamp = hour_grid[idx + 1]
            for symbol in PRIMARY_ASSETS:
                current_return = returns[symbol].get(timestamp)
                next_return = returns[symbol].get(next_timestamp)
                if current_return is None or next_return is None:
                    continue
                writer.writerow(
                    [
                        timestamp,
                        symbol.replace("USDT", ""),
                        f"{current_return:.16g}",
                        1 if next_return > 0 else 0,
                        dt.hour,
                        dt.weekday(),
                    ]
                )
    return path


def build_primary_returns(hour_grid: list[str], close_maps: dict[str, dict[str, float]]):
    returns = defaultdict(dict)
    previous_close = {symbol: None for symbol in PRIMARY_ASSETS}
    for timestamp in hour_grid:
        for symbol in PRIMARY_ASSETS:
            close_price = close_maps[symbol].get(timestamp)
            if close_price is not None and previous_close[symbol] is not None:
                returns[symbol][timestamp] = math.log(close_price) - math.log(previous_close[symbol])
            if close_price is not None:
                previous_close[symbol] = close_price
    return returns


def write_descriptive_stats(returns: dict[str, dict[str, float]]):
    csv_path = PROCESSED_DIR / "descriptive_stats_primary_assets.csv"
    tex_path = PROCESSED_DIR / "descriptive_stats_primary_assets.tex"

    rows = []
    for symbol in PRIMARY_ASSETS:
        asset = symbol.replace("USDT", "")
        values = list(returns[symbol].values())
        pos_share = sum(1 for value in values if value > 0) / len(values)
        zero_share = sum(1 for value in values if value == 0) / len(values)
        rows.append(
            {
                "asset": asset,
                "n": len(values),
                "mean_pct": mean(values) * 100,
                "sd_pct": pstdev(values) * 100,
                "min_pct": min(values) * 100,
                "max_pct": max(values) * 100,
                "positive_share_pct": pos_share * 100,
                "zero_share_pct": zero_share * 100,
            }
        )

    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "asset",
                "n_returns",
                "mean_return_pct",
                "sd_return_pct",
                "min_return_pct",
                "max_return_pct",
                "positive_return_share_pct",
                "zero_return_share_pct",
            ]
        )
        for row in rows:
            writer.writerow(
                [
                    row["asset"],
                    row["n"],
                    f"{row['mean_pct']:.4f}",
                    f"{row['sd_pct']:.4f}",
                    f"{row['min_pct']:.4f}",
                    f"{row['max_pct']:.4f}",
                    f"{row['positive_share_pct']:.2f}",
                    f"{row['zero_share_pct']:.2f}",
                ]
            )

    with tex_path.open("w", encoding="utf-8") as handle:
        handle.write("\\begin{table}[htbp]\n")
        handle.write("\\centering\n")
        handle.write("\\caption{Descriptive statistics for hourly log returns of the selected cryptocurrencies}\n")
        handle.write("\\label{tab:data_desc}\n")
        handle.write("\\begin{tabular}{lrrrrrrr}\n")
        handle.write("\\hline\n")
        handle.write("Asset & $N$ & Mean & SD & Min & Max & Pos.(\\%) & Zero(\\%) \\\\\n")
        handle.write("\\hline\n")
        for row in rows:
            handle.write(
                f"{row['asset']} & {row['n']} & {row['mean_pct']:.4f} & {row['sd_pct']:.4f} & "
                f"{row['min_pct']:.4f} & {row['max_pct']:.4f} & {row['positive_share_pct']:.2f} & "
                f"{row['zero_share_pct']:.2f} \\\\\n"
            )
        handle.write("\\hline\n")
        handle.write("\\end{tabular}\n")
        handle.write("\\end{table}\n")

    return csv_path, tex_path


def summarize(rows_by_symbol: dict[str, list[PriceRow]], hour_grid: list[str], output_paths: dict[str, str]):
    summary = {
        "sample_start_utc": SAMPLE_START.strftime("%Y-%m-%d %H:%M:%S"),
        "sample_end_utc": SAMPLE_END.strftime("%Y-%m-%d %H:%M:%S"),
        "expected_hours": len(hour_grid),
        "primary_assets": [symbol.replace("USDT", "") for symbol in PRIMARY_ASSETS],
        "backup_assets": [symbol.replace("USDT", "") for symbol in BACKUP_ASSETS],
        "coverage": {},
        "outputs": output_paths,
    }
    for symbol, rows in rows_by_symbol.items():
        timestamps = {row.timestamp_utc for row in rows}
        summary["coverage"][symbol.replace("USDT", "")] = {
            "observed_hours": len(rows),
            "missing_hours": len(hour_grid) - len(timestamps),
            "first_timestamp": rows[0].timestamp_utc if rows else None,
            "last_timestamp": rows[-1].timestamp_utc if rows else None,
        }
    path = PROCESSED_DIR / "preparation_summary.json"
    path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return path


def main():
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    rows_by_symbol = {}
    for symbol in ASSETS:
        print(f"Loading {symbol}...")
        rows_by_symbol[symbol] = load_asset_rows(symbol)

    hour_grid = build_hour_grid()
    output_paths = {}
    output_paths["asset_universe_csv"] = str(write_asset_universe())
    output_paths["asset_universe_primary_csv"] = str(write_asset_universe_primary())
    output_paths["hourly_prices_long_csv"] = str(write_hourly_prices_long(rows_by_symbol))
    output_paths["hourly_prices_long_primary_csv"] = str(write_hourly_prices_long_primary(rows_by_symbol))
    close_maps = build_close_maps(rows_by_symbol)
    output_paths["hourly_returns_wide_csv"] = str(write_hourly_returns_wide(close_maps, hour_grid))
    output_paths["hourly_returns_wide_primary_csv"] = str(write_hourly_returns_wide_primary(close_maps, hour_grid))
    output_paths["forecast_panel_base_csv"] = str(write_forecast_panel_base(close_maps, hour_grid))
    output_paths["forecast_panel_primary_csv"] = str(write_forecast_panel_primary(close_maps, hour_grid))
    primary_returns = build_primary_returns(hour_grid, close_maps)
    stats_csv_path, stats_tex_path = write_descriptive_stats(primary_returns)
    output_paths["descriptive_stats_primary_assets_csv"] = str(stats_csv_path)
    output_paths["descriptive_stats_primary_assets_tex"] = str(stats_tex_path)
    summary_path = summarize(rows_by_symbol, hour_grid, output_paths)
    print(f"Wrote summary to {summary_path}")


if __name__ == "__main__":
    main()
