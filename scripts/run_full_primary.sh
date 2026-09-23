#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

RETURNS_FILE="data/processed/hourly_returns_wide_primary.csv"
FORECAST_FILE="data/processed/forecast_panel_primary.csv"
if [[ ! -f "$RETURNS_FILE" || ! -f "$FORECAST_FILE" ]]; then
  echo "Processed inputs are missing. Run the download and preparation scripts first." >&2
  exit 1
fi

LAG_CAP=12
WINDOW_DAYS=30
STEP_HOURS=24
BLOCK_SIZE="${BLOCK_SIZE:-25}"
TOTAL_ORIGINS=700
SAMPLE_START="2024-04-01 00:00:00"
SAMPLE_END="2026-03-31 23:00:00"
SAMPLE_LABEL="twoyear"
LOG_DIR="results/logs"
mkdir -p "$LOG_DIR"

block_number=1
start_origin=1

while [[ "$start_origin" -le "$TOTAL_ORIGINS" ]]; do
  end_origin=$((start_origin + BLOCK_SIZE - 1))
  if [[ "$end_origin" -gt "$TOTAL_ORIGINS" ]]; then
    end_origin="$TOTAL_ORIGINS"
  fi

  block_id="$(printf "primary_p12_w30_b%03d" "$block_number")"
  log_path="$LOG_DIR/${block_id}.log"
  echo "[$(date)] Starting $block_id, origins ${start_origin}-${end_origin}" | tee "$log_path"

  Rscript scripts/run_network_forecast_pipeline_block.R \
    --lag-cap="$LAG_CAP" \
    --window-days="$WINDOW_DAYS" \
    --step-hours="$STEP_HOURS" \
    --origin-start="$start_origin" \
    --origin-end="$end_origin" \
    --block-id="$block_id" \
    --sample-start="$SAMPLE_START" \
    --sample-end="$SAMPLE_END" \
    --sample-label="$SAMPLE_LABEL" 2>&1 | tee -a "$log_path"

  start_origin=$((end_origin + 1))
  block_number=$((block_number + 1))
done

Rscript scripts/merge_network_forecast_blocks.R \
  --lag-cap="$LAG_CAP" \
  --window-days="$WINDOW_DAYS" \
  --step-hours="$STEP_HOURS" \
  --sample-label="$SAMPLE_LABEL" 2>&1 | tee "$LOG_DIR/primary_merge.log"

echo "[$(date)] Full primary run complete"
