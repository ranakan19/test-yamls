# Progressive Sync Performance Results

**Branch:** master
**Date:** Fri Apr 17 18:35:26 EDT 2026
**Commit:** d87bb08b2

## Test Scenarios

### Small Scale (5 apps, 2 steps)

**Initial Sync Phase:**
```json
{
  "total_duration_seconds": 9,
  "expected_apps": 5,
  "actual_apps": 0,
  "argocd_metrics": {
    "baseline_app_reconcile_count": 0,
    "final_app_reconcile_count": 37,
    "total_app_reconciles": 37,
    "baseline_appset_reconcile_count": 0,
    "final_appset_reconcile_count": 32,
    "total_appset_reconciles": 32,
    "note": "Direct from argocd_app_reconcile_count and argocd_appset_reconcile_count metrics at http://localhost:8082"
  }
}
```

**Git Change Phase:**
```json
{
  "duration_seconds": 5,
  "start_time": "2026-04-17T22:28:21Z",
  "end_time": "2026-04-17T22:31:11Z",
  "argocd_metrics": {
    "baseline_app_reconcile_count": 37,
    "final_app_reconcile_count": 46,
    "total_app_reconciles": 9,
    "baseline_appset_reconcile_count": 32,
    "final_appset_reconcile_count": 48,
    "total_appset_reconciles": 16
  }
}
```

### Medium Scale (30 apps, 3 steps)

**Initial Sync Phase:**
```json
{
  "total_duration_seconds": 14,
  "expected_apps": 30,
  "actual_apps": 0,
  "argocd_metrics": {
    "baseline_app_reconcile_count": 76,
    "final_app_reconcile_count": 352,
    "total_app_reconciles": 276,
    "baseline_appset_reconcile_count": 48,
    "final_appset_reconcile_count": 133,
    "total_appset_reconciles": 85,
    "note": "Direct from argocd_app_reconcile_count and argocd_appset_reconcile_count metrics at http://localhost:8082"
  }
}
```

**Git Change Phase:**
```json
{
  "duration_seconds": 5,
  "start_time": "2026-04-17T22:32:13Z",
  "end_time": "2026-04-17T22:35:16Z",
  "argocd_metrics": {
    "baseline_app_reconcile_count": 370,
    "final_app_reconcile_count": 477,
    "total_app_reconciles": 107,
    "baseline_appset_reconcile_count": 133,
    "final_appset_reconcile_count": 276,
    "total_appset_reconciles": 143
  }
}
```

## Metrics Tracked

All metrics are captured directly from the ArgoCD metrics endpoint (`http://localhost:8082`):

- **argocd_metrics**:
  - `baseline_app_reconcile_count`: Value of `argocd_app_reconcile_count` before test
  - `final_app_reconcile_count`: Value of `argocd_app_reconcile_count` after apps healthy & stabilized
  - `total_app_reconciles`: Difference (final - baseline)
  - `baseline_appset_reconcile_count`: Value of `argocd_appset_reconcile_count` before test
  - `final_appset_reconcile_count`: Value of `argocd_appset_reconcile_count` after apps healthy & stabilized
  - `total_appset_reconciles`: Difference (final - baseline)

These metrics are queried directly from:
- `curl http://localhost:8082/metrics | grep argocd_app_reconcile_count`
- `curl http://localhost:12345/metrics | grep argocd_appset_reconcile_count`

## Comparison

To compare with baseline branch, run:
```bash
git checkout master
./test/performance/progressive-sync-benchmark.sh
```

Then use the comparison script:
```bash
./test/performance/compare-results.sh /Users/krana/go/src/github.com/argoproj/argo-cd/test/performance/results/20260417_182739 /Users/krana/go/src/github.com/argoproj/argo-cd/test/performance/results/<baseline-timestamp>
```
