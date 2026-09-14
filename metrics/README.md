# Traffic Metrics

This folder stores long-term GitHub traffic data, captured daily by
[`.github/workflows/traffic-snapshot.yml`](../.github/workflows/traffic-snapshot.yml).

GitHub's native traffic API only retains the last **14 days**. This workflow
snapshots the data daily and merges it into a continuous history, so you can
track clones and views over months.

## Files

- **`SUMMARY.md`** — Human-readable summary (90-day totals + last 30 days). **Start here.**
- **`traffic_history.jsonl`** — Raw daily snapshots (one JSON record per day). Used for deeper analysis.

## Querying the raw data

```bash
# 90-day unique cloner total
jq -s '[.[].clones_daily[]] | map({(.timestamp[0:10]): .uniques}) | add | to_entries | map(.value) | add' metrics/traffic_history.jsonl

# Last 7 captured snapshots
tail -7 metrics/traffic_history.jsonl | jq '{date, clones_unique_14d, views_unique_14d}'
```

## Setup

Requires a repo secret named `TRAFFIC_TOKEN` — a fine-grained PAT with
`Administration: Read` and `Contents: Read and Write` permissions on this repo.
See the workflow file header for details.
