# Progressive Sync Performance Results

**Branch:** master
**Date:** Fri Apr 17 19:37:54 EDT 2026
**Commit:** d87bb08b2

## Test Scenarios

### Small Scale (5 apps, 2 steps)

**Initial Sync Phase:**
```json
{
  "total_duration_seconds": 10,
  "expected_apps": 5,
  "actual_apps": 0,
  "argocd_metrics": {
    "baseline_app_reconcile_count": 744,
    "final_app_reconcile_count": 783,
    "total_app_reconciles": 39,
    "baseline_appset_reconcile_count": 278,
    "final_appset_reconcile_count": 322,
    "total_appset_reconciles": 44,
    "note": "Direct from argocd_app_reconcile_count and argocd_appset_reconcile_count metrics at http://localhost:8082"
  }
}
```

**Git Change Phase:**
```json
{
  "duration_seconds": 0,
  "start_time": "2026-04-17T23:29:08Z",
  "end_time": "2026-04-17T23:33:16Z",
  "argocd_metrics": {
    "baseline_app_reconcile_count": 783,
    "final_app_reconcile_count": 793,
    "total_app_reconciles": 10,
    "baseline_appset_reconcile_count": 322,
    "final_appset_reconcile_count": 333,
    "total_appset_reconciles": 11
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
    "baseline_app_reconcile_count": 819,
    "final_app_reconcile_count": 1091,
    "total_app_reconciles": 272,
    "baseline_appset_reconcile_count": 333,
    "final_appset_reconcile_count": 420,
    "total_appset_reconciles": 87,
    "note": "Direct from argocd_app_reconcile_count and argocd_appset_reconcile_count metrics at http://localhost:8082"
  }
}
```

**Git Change Phase:**
```json
{
  "duration_seconds": 52,
  "start_time": "2026-04-17T23:34:20Z",
  "end_time": "2026-04-17T23:37:44Z",
  "argocd_metrics": {
    "baseline_app_reconcile_count": 1109,
    "final_app_reconcile_count": 1295,
    "total_app_reconciles": 186,
    "baseline_appset_reconcile_count": 420,
    "final_appset_reconcile_count": 609,
    "total_appset_reconciles": 189
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
./test/performance/compare-results.sh /Users/krana/go/src/github.com/argoproj/argo-cd/test/performance/results/20260417_192828 /Users/krana/go/src/github.com/argoproj/argo-cd/test/performance/results/<baseline-timestamp>
```
