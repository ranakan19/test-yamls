#!/bin/bash
set -e

# Query Prometheus for Progressive Sync Metrics
# Focuses on application-level reconcile counts and timing

PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if Prometheus is available
check_prometheus() {
    if ! curl -s "$PROMETHEUS_URL/-/healthy" > /dev/null 2>&1; then
        log_error "Prometheus not available at $PROMETHEUS_URL"
        return 1
    fi
    return 0
}

# Query Prometheus and return just the value
query_instant() {
    local query=$1
    curl -s -G "$PROMETHEUS_URL/api/v1/query" \
        --data-urlencode "query=$query" \
        | jq -r '.data.result[0].value[1] // "0"'
}

# Query Prometheus range and return results
query_range() {
    local query=$1
    local start=$2
    local end=$3
    local step=${4:-15s}

    curl -s -G "$PROMETHEUS_URL/api/v1/query_range" \
        --data-urlencode "query=$query" \
        --data-urlencode "start=$start" \
        --data-urlencode "end=$end" \
        --data-urlencode "step=$step" \
        | jq -r '.data.result'
}

# Get application reconcile metrics for a specific appset
get_app_reconcile_metrics() {
    local appset_name=$1
    local start_time=$2
    local end_time=$3

    if ! check_prometheus; then
        echo "{}"
        return 1
    fi

    local start_epoch=$(date -d "$start_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +%s 2>/dev/null)
    local end_epoch=$(date -d "$end_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_time" +%s 2>/dev/null)
    local duration=$((end_epoch - start_epoch))

    log_info "Querying Prometheus for appset: $appset_name"
    log_info "Time window: $start_time to $end_time (${duration}s)"

    # Query: Total application reconciles during the window
    # argocd_app_reconcile is a histogram, _count is auto-appended by Prometheus
    local total_app_reconciles=$(query_instant "sum(increase(argocd_app_reconcile_count{namespace=\"argocd\"}[${duration}s]))")

    # Query: Average reconciles per application
    local avg_app_reconciles=$(query_instant "avg(increase(argocd_app_reconcile_count{namespace=\"argocd\"}[${duration}s]))")

    # Query: Max reconciles for any single application
    local max_app_reconciles=$(query_instant "max(increase(argocd_app_reconcile_count{namespace=\"argocd\"}[${duration}s]))")

    # Query: ApplicationSet reconciles during the window
    # argocd_appset_reconcile is a histogram, _count is auto-appended
    local appset_reconciles=$(query_instant "increase(argocd_appset_reconcile_count{name=\"${appset_name}\",namespace=\"argocd\"}[${duration}s])")

    # Query: Total sync operations
    local sync_count=$(query_instant "sum(increase(argocd_app_sync_total{namespace=\"argocd\"}[${duration}s]))")

    # Query: Average sync duration (using histogram sum/count)
    local avg_sync_duration=$(query_instant "sum(increase(argocd_app_sync_duration_seconds_total{namespace=\"argocd\"}[${duration}s])) / sum(increase(argocd_app_sync_total{namespace=\"argocd\"}[${duration}s]))")

    # Output as JSON
    cat <<EOF
{
  "prometheus_available": true,
  "time_window_seconds": $duration,
  "metrics": {
    "total_app_reconciles": $total_app_reconciles,
    "avg_app_reconciles": $avg_app_reconciles,
    "max_app_reconciles": $max_app_reconciles,
    "appset_reconciles": $appset_reconciles,
    "sync_operations": $sync_count,
    "avg_sync_duration": $avg_sync_duration
  }
}
EOF
}

# Get detailed per-application reconcile counts
get_per_app_reconciles() {
    local appset_name=$1
    local start_time=$2
    local end_time=$3

    if ! check_prometheus; then
        echo "[]"
        return 1
    fi

    local start_epoch=$(date -d "$start_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +%s 2>/dev/null)
    local end_epoch=$(date -d "$end_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_time" +%s 2>/dev/null)
    local duration=$((end_epoch - start_epoch))

    log_info "Fetching per-application reconcile counts..."

    # Query for each application's reconcile count
    # argocd_app_reconcile is a histogram metric, _count suffix gives us the count
    curl -s -G "$PROMETHEUS_URL/api/v1/query" \
        --data-urlencode "query=increase(argocd_app_reconcile_count{namespace=\"argocd\"}[${duration}s])" \
        | jq -r '.data.result | map({
            app: .metric.name,
            namespace: .metric.namespace,
            dest_server: .metric.dest_server,
            project: .metric.project,
            reconciles: (.value[1] | tonumber)
          })'
}

# Get reconcile timeline (shows when reconciles happened)
get_reconcile_timeline() {
    local appset_name=$1
    local start_time=$2
    local end_time=$3
    local step=${4:-30s}

    if ! check_prometheus; then
        echo "[]"
        return 1
    fi

    local start_epoch=$(date -d "$start_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" +%s 2>/dev/null)
    local end_epoch=$(date -d "$end_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_time" +%s 2>/dev/null)

    log_info "Fetching reconcile timeline..."

    # Rate of reconciles over time (reconciles per second)
    # Using _count from the histogram to get reconciliation rate
    query_range "rate(argocd_app_reconcile_count{namespace=\"argocd\"}[1m])" \
        "$start_epoch" "$end_epoch" "$step"
}

# Main command dispatcher
case "${1:-}" in
    app-reconciles)
        get_app_reconcile_metrics "$2" "$3" "$4"
        ;;
    per-app)
        get_per_app_reconciles "$2" "$3" "$4"
        ;;
    timeline)
        get_reconcile_timeline "$2" "$3" "$4" "${5:-30s}"
        ;;
    check)
        if check_prometheus; then
            echo "Prometheus is available at $PROMETHEUS_URL"
            exit 0
        else
            exit 1
        fi
        ;;
    *)
        cat <<EOF
Usage: $0 <command> [args...]

Commands:
  check
      Check if Prometheus is available

  app-reconciles <appset-name> <start-time> <end-time>
      Get application reconcile metrics summary
      Example: $0 app-reconciles perf-medium "2026-04-03T10:00:00Z" "2026-04-03T10:10:00Z"

  per-app <appset-name> <start-time> <end-time>
      Get per-application reconcile counts
      Example: $0 per-app perf-medium "2026-04-03T10:00:00Z" "2026-04-03T10:10:00Z"

  timeline <appset-name> <start-time> <end-time> [step]
      Get reconcile rate timeline (default step: 30s)
      Example: $0 timeline perf-medium "2026-04-03T10:00:00Z" "2026-04-03T10:10:00Z" 15s

Environment Variables:
  PROMETHEUS_URL    Prometheus URL (default: http://localhost:9090)

Example:
  export PROMETHEUS_URL="http://prometheus.example.com:9090"
  $0 app-reconciles perf-medium "2026-04-03T10:00:00Z" "2026-04-03T10:10:00Z"
EOF
        exit 1
        ;;
esac