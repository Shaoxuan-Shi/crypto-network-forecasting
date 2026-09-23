#!/usr/bin/env python3
"""Download Binance spot monthly 1h klines for the project asset universe.

This script uses only the Python standard library so it can run without
additional environment setup.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date
from pathlib import Path


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

START_YEAR = 2023
START_MONTH = 4
END_YEAR = 2026
END_MONTH = 3

BASE_URL = "https://data.binance.vision/data/spot/monthly/klines"
ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw" / "binance_monthly_zips"
LOG_PATH = ROOT / "data" / "logs" / "download_manifest.json"


@dataclass(frozen=True)
class MonthRef:
    year: int
    month: int

    @property
    def label(self) -> str:
        return f"{self.year:04d}-{self.month:02d}"


def iter_months(start_year: int, start_month: int, end_year: int, end_month: int):
    current = date(start_year, start_month, 1)
    end = date(end_year, end_month, 1)
    while current <= end:
        yield MonthRef(current.year, current.month)
        if current.month == 12:
            current = date(current.year + 1, 1, 1)
        else:
            current = date(current.year, current.month + 1, 1)


def build_url(symbol: str, month_ref: MonthRef) -> str:
    filename = f"{symbol}-1h-{month_ref.label}.zip"
    return f"{BASE_URL}/{symbol}/1h/{filename}"


def download_file(url: str, destination: Path) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            data = response.read()
            destination.write_bytes(data)
            return {
                "status": "downloaded",
                "http_status": response.getcode(),
                "bytes": len(data),
            }
    except urllib.error.HTTPError as exc:
        return {
            "status": "http_error",
            "http_status": exc.code,
            "bytes": 0,
        }
    except Exception as exc:  # noqa: BLE001
        return {
            "status": "error",
            "http_status": None,
            "bytes": 0,
            "error": repr(exc),
        }


def main() -> int:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)

    manifest: list[dict] = []
    months = list(iter_months(START_YEAR, START_MONTH, END_YEAR, END_MONTH))
    total = len(ASSETS) * len(months)
    counter = 0

    for symbol in ASSETS:
        asset_dir = RAW_DIR / symbol
        asset_dir.mkdir(parents=True, exist_ok=True)
        for month_ref in months:
            counter += 1
            filename = f"{symbol}-1h-{month_ref.label}.zip"
            destination = asset_dir / filename
            url = build_url(symbol, month_ref)
            if destination.exists() and destination.stat().st_size > 0:
                result = {
                    "status": "exists",
                    "http_status": 200,
                    "bytes": destination.stat().st_size,
                }
            else:
                result = download_file(url, destination)
                time.sleep(0.1)
            entry = {
                "symbol": symbol,
                "month": month_ref.label,
                "url": url,
                "path": str(destination),
                **result,
            }
            manifest.append(entry)
            print(
                f"[{counter:03d}/{total:03d}] {symbol} {month_ref.label} "
                f"{entry['status']} {entry.get('http_status')}"
            )

    LOG_PATH.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    failures = [row for row in manifest if row["status"] not in {"downloaded", "exists"}]
    if failures:
        print(f"Finished with {len(failures)} failed downloads. See {LOG_PATH}.", file=sys.stderr)
        return 1

    print(f"All downloads completed successfully. Manifest: {LOG_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
