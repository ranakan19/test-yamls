# Metrics Reference for Progressive Sync Performance Testing

This document lists the **actual Argo CD Prometheus metrics** used by the performance testing scripts.

## Application Controller Metrics (port 8082)

### `argocd_app_reconcile` (histogram)
- **Description**: Application reconciliation performance in seconds
- **Type**: Histogram (automatically creates `_count`, `_sum`, `_bucket` suffixes)
- **Labels**: `name`, `namespace`, `dest_server`, `project`
- **Usage in tests**:
  - `argocd_app_reconcile_count` - Number of reconciliations
  - `argocd_app_reconcile_sum` - Total time spent reconciling

**Example Query:**
```promql
# Total reconciles for all apps in last 10 minutes
sum(increase(argocd_app_reconcile_count{namespace="argocd"}[10m]))

# Average reconciles per app
avg(increase(argocd_app_reconcile_count{namespace="argocd"}[10m]))

# Max reconciles for any single app
max(increase(argocd_app_reconcile_count{namespace="argocd"}[10m]))
```

### `argocd_app_sync_total` (counter)
- **Description**: Counter for application sync history
- **Type**: Counter
- **Labels**: `name`, `namespace`, `phase`, `dest_server`, `project`
- **Usage in tests**: Count sync operations

**Example Query:**
```promql
# Total syncs in time window
sum(increase(argocd_app_sync_total{namespace="argocd"}[10m]))
```

### `argocd_app_sync_duration_seconds_total` (counter)
- **Description**: Application sync performance in seconds total
- **Type**: Counter  
- **Labels**: `name`, `namespace`, `dest_server`, `project`
- **Usage in tests**: Calculate average sync duration

**Example Query:**
```promql
# Average sync duration
sum(increase(argocd_app_sync_duration_seconds_total{namespace="argocd"}[10m])) 
/ 
sum(increase(argocd_app_sync_total{namespace="argocd"}[10m]))
```

### `argocd_app_info` (gauge)
- **Description**: Information about Applications (includes `sync_status`, `health_status`)
- **Type**: Gauge
- **Labels**: `name`, `namespace`, `sync_status`, `health_status`, `dest_server`, `project`
- **Usage in tests**: Track app status during progressive sync

**Example Query:**
```promql
# Count healthy apps
count(argocd_app_info{health_status="Healthy",namespace="argocd"})
```

---

## ApplicationSet Controller Metrics (port 8084)

### `argocd_appset_reconcile` (histogram)
- **Description**: ApplicationSet reconciliation performance in seconds
- **Type**: Histogram (automatically creates `_count`, `_sum`, `_bucket` suffixes)
- **Labels**: `name`, `namespace`
- **Usage in tests**:
  - `argocd_appset_reconcile_count` - Number of ApplicationSet reconciliations
  - `argocd_appset_reconcile_sum` - Total time spent reconciling

**Example Query:**
```promql
# ApplicationSet reconciles in time window
increase(argocd_appset_reconcile_count{name="perf-medium",namespace="argocd"}[10m])

# Average reconcile duration
argocd_appset_reconcile_sum{name="perf-medium"} 
/ 
argocd_appset_reconcile_count{name="perf-medium"}
```

### `argocd_appset_owned_applications` (gauge)
- **Description**: Number of applications owned by the applicationset
- **Type**: Gauge
- **Labels**: `name`, `namespace`
- **Usage in tests**: Verify expected application count

**Example Query:**
```promql
argocd_appset_owned_applications{name="perf-medium",namespace="argocd"}
```

### `argocd_appset_info` (gauge)
- **Description**: Information about ApplicationSets
- **Type**: Gauge
- **Labels**: `name`, `namespace`, `resource_update_status`
- **Usage in tests**: Track ApplicationSet status

**Example Query:**
```promql
argocd_appset_info{name="perf-medium",namespace="argocd"}
```

---

## Queries Used in Performance Scripts

### 1. Total Application Reconciles
```promql
sum(increase(argocd_app_reconcile_count{namespace="argocd"}[TIME_WINDOW]))
```
**What it measures**: Total number of times ANY application was reconciled during the test window

### 2. Average Application Reconciles
```promql
avg(increase(argocd_app_reconcile_count{namespace="argocd"}[TIME_WINDOW]))
```
**What it measures**: Average reconcile count per application (**key metric for your changes**)

### 3. Max Application Reconciles
```promql
max(increase(argocd_app_reconcile_count{namespace="argocd"}[TIME_WINDOW]))
```
**What it measures**: Highest reconcile count for any single app (worst case)

### 4. ApplicationSet Reconciles
```promql
increase(argocd_appset_reconcile_count{name="APPSET_NAME",namespace="argocd"}[TIME_WINDOW])
```
**What it measures**: Number of times the ApplicationSet controller reconciled the AppSet

### 5. Sync Operations
```promql
sum(increase(argocd_app_sync_total{namespace="argocd"}[TIME_WINDOW]))
```
**What it measures**: Total sync operations triggered

### 6. Average Sync Duration
```promql
sum(increase(argocd_app_sync_duration_seconds_total{namespace="argocd"}[TIME_WINDOW])) 
/ 
sum(increase(argocd_app_sync_total{namespace="argocd"}[TIME_WINDOW]))
```
**What it measures**: Average time per sync operation (in seconds)

### 7. Per-Application Reconciles
```promql
increase(argocd_app_reconcile_count{namespace="argocd"}[TIME_WINDOW])
```
**Returns**: Vector with reconcile count for each individual application

### 8. Reconcile Rate Timeline
```promql
rate(argocd_app_reconcile_count{namespace="argocd"}[1m])
```
**What it measures**: Reconciles per second (time series showing when reconciles happened)

---

## Important Notes

### Histogram Metrics
Prometheus automatically appends suffixes to histogram metrics:
- `argocd_app_reconcile` becomes:
  - `argocd_app_reconcile_bucket` (for percentile calculations)
  - `argocd_app_reconcile_sum` (total duration)
  - `argocd_app_reconcile_count` (number of observations)

### Time Windows
- Use `[10m]` syntax for range vectors with `increase()` or `rate()`
- Replace `TIME_WINDOW` with actual duration like `[300s]` for a 5-minute test

### Labels Available
Application metrics include these labels:
- `name` - Application name
- `namespace` - Namespace where Application CR lives (typically `argocd`)
- `dest_server` - Destination cluster
- `project` - Argo CD AppProject name

ApplicationSet metrics include:
- `name` - ApplicationSet name
- `namespace` - Namespace where ApplicationSet CR lives

### Filtering by ApplicationSet
To get metrics only for apps owned by a specific ApplicationSet, use label matching in kubectl or filter app names by prefix.

**Note:** `argocd_app_reconcile` metrics don't have an `app_set_name` label, so you need to:
1. Get app names from the ApplicationSet status
2. Query metrics for those specific app names
3. Or use a naming convention (e.g., apps prefixed with appset name)

---

## Verification

To verify these metrics are available in your Prometheus:

```bash
# Check application reconcile metric exists
curl -s "http://localhost:9090/api/v1/query?query=argocd_app_reconcile_count" | jq .

# Check applicationset reconcile metric exists
curl -s "http://localhost:9090/api/v1/query?query=argocd_appset_reconcile_count" | jq .

# List all argocd metrics
curl -s "http://localhost:9090/api/v1/label/__name__/values" | jq '.data[] | select(startswith("argocd_"))'
```

---

## What's NOT Available

These metrics do **NOT** exist and should not be queried:
- ❌ `argocd_app_refresh_count` (not exposed)
- ❌ `argocd_app_status_updates` (not exposed)  
- ❌ `argocd_appset_progressive_sync_*` (not exposed)

Use kubectl events or application status for these instead.