# Progressive Sync Performance Results

**Branch:** annotationPOC
**Date:** Fri Apr 17 18:17:58 EDT 2026
**Commit:** 7b75baa8f

## Test Scenarios

### Small Scale (5 apps, 2 steps)

**Initial Sync Phase:**
```json
{
  "total_duration_seconds": 9,
  "expected_apps": 5,
  "actual_apps": 0,
  "argocd_metrics": {
    "baseline_app_reconcile_count": 2338,
    "final_app_reconcile_count": 2378,
    "total_app_reconciles": 40,
    "baseline_appset_reconcile_count": 336,
    "final_appset_reconcile_count": 367,
    "total_appset_reconciles": 31,
    "note": "Direct from argocd_app_reconcile_count and argocd_appset_reconcile_count metrics at http://localhost:8082"
  }
}
```

**Git Change Phase:**
```json
{
  "duration_seconds": 6,
  "start_time": "2026-04-17T22:07:32Z",
  "end_time": "2026-04-17T22:10:04Z",
  "argocd_metrics": {
    "baseline_app_reconcile_count": 2378,
    "final_app_reconcile_count": 2408,
    "total_app_reconciles": 30,
    "baseline_appset_reconcile_count": 367,
    "final_appset_reconcile_count": 400,
    "total_appset_reconciles": 33
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
    "baseline_app_reconcile_count": 2430,
    "final_app_reconcile_count": 2713,
    "total_app_reconciles": 283,
    "baseline_appset_reconcile_count": 400,
    "final_appset_reconcile_count": 479,
    "total_appset_reconciles": 79,
    "note": "Direct from argocd_app_reconcile_count and argocd_appset_reconcile_count metrics at http://localhost:8082"
  }
}
```

**Git Change Phase:**
```json
{
  "duration_seconds": 17,
  "start_time": "2026-04-17T22:14:42Z",
  "end_time": "2026-04-17T22:17:48Z",
  "argocd_metrics": {
    "baseline_app_reconcile_count": 2788,
    "final_app_reconcile_count": 3049,
    "total_app_reconciles": 261,
    "baseline_appset_reconcile_count": 500,
    "final_appset_reconcile_count": 588,
    "total_appset_reconciles": 88
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
./test/performance/compare-results.sh /Users/krana/go/src/github.com/argoproj/argo-cd/test/performance/results/20260417_180643 /Users/krana/go/src/github.com/argoproj/argo-cd/test/performance/results/<baseline-timestamp>
```
