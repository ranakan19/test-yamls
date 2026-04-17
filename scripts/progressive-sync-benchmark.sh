#!/bin/bash
set -e

# Progressive Sync Performance Benchmark Script
# Compares baseline (master) vs changes (current branch) for progressive sync scenarios
#
# Local Development Setup:
# - Works with 'make start-local' (goreman-based setup)
# - Requires kubectl access to the cluster
# - Optional: Prometheus at http://localhost:9090 for enhanced metrics
#   - For local setup, you may need to port-forward Prometheus:
#     kubectl port-forward -n monitoring svc/prometheus 9090:9090
#   - Or access ArgoCD metrics directly:
#     kubectl port-forward -n argocd svc/argocd-metrics 8082:8082
#     kubectl port-forward -n argocd svc/argocd-applicationset-controller 8084:8084

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/test/performance/results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
BASELINE_BRANCH="${BASELINE_BRANCH:-master}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
ARGOCD_SERVER="${ARGOCD_SERVER:-localhost:8080}"
ARGOCD_METRICS_URL="${ARGOCD_METRICS_URL:-http://localhost:8082}"
ARGOCD_APPSET_METRICS_URL="${ARGOCD_APPSET_METRICS_URL:-http://localhost:12345}"
ENABLE_GIT_CHANGE_TEST="${ENABLE_GIT_CHANGE_TEST:-true}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Usage Notes for Local Development (make start-local)
# ============================================================================
# This script works with both:
# 1. Full Kubernetes deployment (kubectl apply -k manifests/...)
# 2. Local development setup (make start-local with goreman)
#
# For local development:
# - ArgoCD components run via goreman (defined in Procfile)
# - kubectl is still used to interact with the K8s API
# - ApplicationSets and Applications are created in the cluster
# - Prometheus metrics MAY not be available (depends on your setup)
#   - If you want Prometheus metrics, you can:
#     a) Run Prometheus locally pointing to ArgoCD metrics endpoints
#     b) Port-forward metrics services (see script header comments)
#
# The script will automatically fall back to kubectl-based metrics if
# Prometheus is not available.
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Create results directory
mkdir -p "$RESULTS_DIR/$TIMESTAMP"

# Ensure we're in the repo root
cd "$REPO_ROOT"

# Function to query Prometheus
query_prometheus() {
    local query=$1
    local output_file=$2

    curl -s -G "$PROMETHEUS_URL/api/v1/query" \
        --data-urlencode "query=$query" \
        | jq -r '.data.result' > "$output_file"
}

# Function to query Prometheus range
query_prometheus_range() {
    local query=$1
    local start=$2
    local end=$3
    local step=$4
    local output_file=$5

    curl -s -G "$PROMETHEUS_URL/api/v1/query_range" \
        --data-urlencode "query=$query" \
        --data-urlencode "start=$start" \
        --data-urlencode "end=$end" \
        --data-urlencode "step=$step" \
        | jq -r '.data.result' > "$output_file"
}

# Function to wait for ApplicationSet progressive sync to complete
wait_for_appset_complete() {
    local appset_name=$1
    local namespace=${2:-argocd}
    local expected_apps=${3:-0}
    local timeout=${4:-600}

    log_info "Waiting for ApplicationSet $appset_name progressive sync to complete (timeout: ${timeout}s)..."
    log_info "Expected apps: $expected_apps"

    if [ "$expected_apps" -eq 0 ]; then
        log_error "Expected apps count is 0 or not provided!"
        return 1
    fi

    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))

    while [ $(date +%s) -lt $end_time ]; do
        # Check if applicationStatus is populated
        local app_status_json=$(kubectl get applicationset "$appset_name" -n "$namespace" -o jsonpath='{.status.applicationStatus}' 2>/dev/null || echo "")

        if [ -z "$app_status_json" ] || [ "$app_status_json" = "null" ]; then
            log_info "Waiting for applicationStatus to be populated..."
            sleep 3
            continue
        fi

        # Count how many entries in applicationStatus
        local status_count=$(kubectl get applicationset "$appset_name" -n "$namespace" -o jsonpath='{.status.applicationStatus}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

        if [ "$status_count" -ne "$expected_apps" ]; then
            log_info "applicationStatus has $status_count entries, expecting $expected_apps..."
            sleep 3
            continue
        fi

        # Check if all applications are Healthy
        local healthy_count=$(kubectl get applicationset "$appset_name" -n "$namespace" -o json 2>/dev/null | \
            jq -r '[.status.applicationStatus[] | select(.status == "Healthy")] | length' 2>/dev/null)
        healthy_count=${healthy_count:-0}

        local progressing_count=$(kubectl get applicationset "$appset_name" -n "$namespace" -o json 2>/dev/null | \
            jq -r '[.status.applicationStatus[] | select(.status == "Progressing")] | length' 2>/dev/null)
        progressing_count=${progressing_count:-0}

        local waiting_count=$(kubectl get applicationset "$appset_name" -n "$namespace" -o json 2>/dev/null | \
            jq -r '[.status.applicationStatus[] | select(.status == "Waiting")] | length' 2>/dev/null)
        waiting_count=${waiting_count:-0}

        log_info "Progressive sync status: Healthy=$healthy_count, Progressing=$progressing_count, Waiting=$waiting_count (total=$status_count)"

        # Ensure we have valid numbers for comparison
        if [ -z "$healthy_count" ]; then healthy_count=0; fi
        if [ -z "$expected_apps" ]; then expected_apps=0; fi

        if [ "$healthy_count" -eq "$expected_apps" ] && [ "$expected_apps" -gt 0 ]; then
            local elapsed=$(($(date +%s) - start_time))
            log_success "Progressive sync complete! All $expected_apps applications are Healthy (${elapsed}s)"
            echo "$elapsed"
            return 0
        fi

        sleep 5
    done

    log_error "Timeout waiting for progressive sync to complete"
    log_error "Final status: Healthy=$healthy_count/$expected_apps"
    return 1
}

# Function to wait for ApplicationSet progressive sync to complete after git change
# Validates that all apps are healthy AND reconciledAt is after the git change timestamp
wait_for_appset_to_complete_progressive_sync() {
    local appset_name=$1
    local namespace=${2:-argocd}
    local expected_apps=${3:-0}
    local git_change_timestamp=$4
    local timeout=${5:-600}

    log_info "Waiting for ApplicationSet $appset_name progressive sync to complete after git change (timeout: ${timeout}s)..."
    log_info "Expected apps: $expected_apps"
    log_info "Git change timestamp: $git_change_timestamp"

    if [ "$expected_apps" -eq 0 ]; then
        log_error "Expected apps count is 0 or not provided!"
        return 1
    fi

    if [ -z "$git_change_timestamp" ]; then
        log_error "Git change timestamp is required!"
        return 1
    fi

    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))
    local git_change_epoch=$(date -d "$git_change_timestamp" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$git_change_timestamp" +%s 2>/dev/null)

    while [ $(date +%s) -lt $end_time ]; do
        # Get all apps for this ApplicationSet
        local apps_json=$(kubectl get applications -n "$namespace" -o json | jq -r --arg appset "$appset_name" '[.items[] | select(any(.metadata.ownerReferences[]?; .name==$appset))]')

        local total_apps=$(echo "$apps_json" | jq 'length')

        if [ "$total_apps" -ne "$expected_apps" ]; then
            log_info "Found $total_apps apps, expecting $expected_apps..."
            sleep 3
            continue
        fi

        # Check all apps are healthy
        local healthy_count=$(echo "$apps_json" | jq '[.[] | select(.status.health.status == "Healthy")] | length')

        # Check all apps have reconciledAt after git change
        local reconciled_after_change=$(echo "$apps_json" | jq -r --arg ts "$git_change_timestamp" '[.[] | select(.status.reconciledAt >= $ts)] | length')

        # Get counts of apps by health status
        local degraded_count=$(echo "$apps_json" | jq '[.[] | select(.status.health.status == "Degraded")] | length')
        local progressing_count=$(echo "$apps_json" | jq '[.[] | select(.status.health.status == "Progressing")] | length')
        local missing_count=$(echo "$apps_json" | jq '[.[] | select(.status.health.status == "Missing")] | length')

        log_info "App status: Healthy=$healthy_count/$expected_apps, Degraded=$degraded_count, Progressing=$progressing_count, Missing=$missing_count"
        log_info "Apps reconciled after git change: $reconciled_after_change/$expected_apps"

        # Success condition: all apps healthy AND all reconciled after git change
        if [ "$healthy_count" -eq "$expected_apps" ] && [ "$reconciled_after_change" -eq "$expected_apps" ]; then
            local elapsed=$(($(date +%s) - start_time))
            log_success "Progressive sync complete! All $expected_apps applications are Healthy and reconciled after git change (${elapsed}s)"
            echo "$elapsed"
            return 0
        fi

        sleep 5
    done

    log_error "Timeout waiting for progressive sync to complete after git change"
    log_error "Final status: Healthy=$healthy_count/$expected_apps, Reconciled after change=$reconciled_after_change/$expected_apps"

    # Show which apps are not healthy or not reconciled
    log_error "Apps not meeting criteria:"
    echo "$apps_json" | jq -r --arg ts "$git_change_timestamp" '.[] | select(.status.health.status != "Healthy" or .status.reconciledAt < $ts) | "  - \(.metadata.name): health=\(.status.health.status), reconciledAt=\(.status.reconciledAt)"' >&2

    return 1
}

# Function to get total argocd_app_reconcile_count from metrics endpoint
get_app_reconcile_count_from_metrics() {
    local metrics_url="${1:-$ARGOCD_METRICS_URL}"

    # Query the metrics endpoint and sum all argocd_app_reconcile_count values
    # The metric has format: argocd_app_reconcile_count{labels...} VALUE
    local total=$(curl -s "$metrics_url/metrics" 2>/dev/null | \
        grep '^argocd_app_reconcile_count{' | \
        awk '{print $2}' | \
        awk '{s+=$1} END {print s+0}')

    echo "$total"
}

# Function to get total argocd_appset_reconcile_count from metrics endpoint
get_appset_reconcile_count_from_metrics() {
    local metrics_url="${1:-$ARGOCD_APPSET_METRICS_URL}"

    # Query the metrics endpoint and sum all argocd_appset_reconcile_count values
    # The metric has format: argocd_appset_reconcile_count{labels...} VALUE
    local total=$(curl -s "$metrics_url/metrics" 2>/dev/null | \
        grep '^argocd_appset_reconcile_count{' | \
        awk '{print $2}' | \
        awk '{s+=$1} END {print s+0}')

    echo "$total"
}

# Function to wait for reconcile counts to stabilize
wait_for_reconcile_stabilization() {
    local max_wait=${1:-30}  # Max wait time in seconds
    local check_interval=2    # Check every 2 seconds

    log_info "Waiting for reconcile counts to stabilize..."

    local prev_count=$(get_app_reconcile_count_from_metrics)
    local stable_count=0
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        sleep $check_interval
        elapsed=$((elapsed + check_interval))

        local curr_count=$(get_app_reconcile_count_from_metrics)

        if [ "$curr_count" -eq "$prev_count" ]; then
            stable_count=$((stable_count + 1))
            # If count is stable for 3 consecutive checks (6 seconds), we're good
            if [ $stable_count -ge 3 ]; then
                log_success "Reconcile counts stabilized at $curr_count (waited ${elapsed}s)"
                echo "$curr_count"
                return 0
            fi
        else
            log_info "Reconcile count: $prev_count -> $curr_count (still changing...)"
            stable_count=0
        fi

        prev_count=$curr_count
    done

    log_warn "Reconcile counts did not fully stabilize after ${max_wait}s (current: $prev_count)"
    echo "$prev_count"
    return 0
}

# Function to count reconciles for an application
count_app_reconciles() {
    local app_name=$1
    local namespace=${2:-argocd}
    local since_timestamp=$3

    # Count reconcile events from kubectl events
    # Sum the 'count' field from events (default to 1 if count is null)
    # Use >= to include events at the exact timestamp
    # Check both firstTimestamp and lastTimestamp since events can be updated
    kubectl get events -n "$namespace" \
        --field-selector involvedObject.name="$app_name" \
        --field-selector involvedObject.kind=Application \
        -o json | jq -r --arg since "$since_timestamp" \
        '[.items[] | select(.firstTimestamp >= $since or .lastTimestamp >= $since) | select(.reason == "OperationCompleted" or .reason == "ResourceUpdated" or .reason == "ResourceActionRunSucceeded")] | map(.count // 1) | add // 0'
}

# Function to get application refresh count
get_app_refresh_count() {
    local app_name=$1
    local namespace=${2:-argocd}

    # Check how many times the refresh annotation was added
    kubectl get application "$app_name" -n "$namespace" -o json | \
        jq -r '.metadata.annotations["argocd.argoproj.io/refresh"] // "never"'
}

# Function to get per-app reconcile counts from Prometheus
get_per_app_reconciles_from_prometheus() {
    local appset_name=$1
    local start_time=$2
    local end_time=$3
    local output_file=$4

    if ! "$SCRIPT_DIR/query-prometheus.sh" check > /dev/null 2>&1; then
        echo "[]" > "$output_file"
        return 1
    fi

    "$SCRIPT_DIR/query-prometheus.sh" per-app "$appset_name" "$start_time" "$end_time" > "$output_file"
}

# Function to wait for user to make git change and monitor reconciles
wait_for_git_change_and_monitor() {
    local appset_name=$1
    local namespace=${2:-argocd}
    local expected_apps=${3:-0}
    local result_file=$4

    log_info "=== Git Change Detection Phase ==="
    log_info "The ApplicationSet $appset_name is now synced and all apps are healthy."
    log_info ""
    log_info "Next step: Make a change to your git repository and commit it."
    log_info "This will test how progressive sync handles repository updates."
    log_info ""
    log_info "Instructions:"
    log_info "  1. Make a change to the source repository (e.g., update an image tag, change a label)"
    log_info "  2. Commit and push the change"
    log_info "  3. Come back here and press ENTER to continue monitoring"
    log_info ""
    read -p "Press ENTER when you have made and pushed your git change, or Ctrl+C to skip... " _

    log_info "Starting git change reconcile monitoring..."

    # Capture baseline metrics before git change
    local git_baseline_reconciles=0
    local git_baseline_appset_reconciles=0
    local git_metrics_available=false
    if curl -s "$ARGOCD_METRICS_URL/metrics" > /dev/null 2>&1; then
        git_baseline_reconciles=$(get_app_reconcile_count_from_metrics)
        git_baseline_appset_reconciles=$(get_appset_reconcile_count_from_metrics)
        git_metrics_available=true
        log_info "Git change baseline argocd_app_reconcile_count: $git_baseline_reconciles"
        log_info "Git change baseline argocd_appset_reconcile_count: $git_baseline_appset_reconciles"
    fi

    local git_change_start=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local git_change_start_epoch=$(date +%s)

    # Wait for applications to detect the change and reconcile
    log_info "Waiting for applications to detect git change and reconcile..."
    sleep 120  # Give ArgoCD time to detect the change

    # Monitor for OutOfSync status (indicates change detected)
    local timeout=200
    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))
    local change_detected=false

    while [ $(date +%s) -lt $end_time ]; do
        local out_of_sync_count=$(kubectl get applications -n "$namespace" \
            -o json | jq -r --arg appset "$appset_name" '[.items[] | select(any(.metadata.ownerReferences[]?; .name==$appset) and (.status.sync.status == "OutOfSync"))] | length' 2>/dev/null || echo "0")

        if [ "$out_of_sync_count" -gt 0 ]; then
            log_info "Git change detected! $out_of_sync_count applications are OutOfSync"
            change_detected=true
            break
        fi

        log_info "Waiting for applications to detect git change... (OutOfSync: $out_of_sync_count)"
        sleep 1
    done

    if [ "$change_detected" = false ]; then
        log_warn "No OutOfSync applications detected within timeout. Applications may already be in sync."
        log_warn "This could mean: 1) Change wasn't detected, 2) Auto-sync was too fast, or 3) No change was made"
    fi

    # Now wait for progressive sync to complete again
    log_info "Waiting for progressive sync to complete after git change..."
    local git_change_duration=$(wait_for_appset_to_complete_progressive_sync "$appset_name" "$namespace" "$expected_apps" "$git_change_start")

    # Wait for reconcile counts to stabilize after git change
    local git_final_reconciles=0
    local git_final_appset_reconciles=0
    local git_total_reconciles_from_metrics=0
    local git_total_appset_reconciles_from_metrics=0
    if [ "$git_metrics_available" = true ]; then
        git_final_reconciles=$(wait_for_reconcile_stabilization 30)
        git_final_appset_reconciles=$(get_appset_reconcile_count_from_metrics)
        git_total_reconciles_from_metrics=$((git_final_reconciles - git_baseline_reconciles))
        git_total_appset_reconciles_from_metrics=$((git_final_appset_reconciles - git_baseline_appset_reconciles))
        log_success "Git change total app reconciles (from metrics): $git_total_reconciles_from_metrics (baseline: $git_baseline_reconciles, final: $git_final_reconciles)"
        log_success "Git change total appset reconciles (from metrics): $git_total_appset_reconciles_from_metrics (baseline: $git_baseline_appset_reconciles, final: $git_final_appset_reconciles)"
    fi

    local git_change_end_epoch=$(date +%s)
    local git_change_end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Append git change metrics to result file
    local git_metrics_app_value="null"
    local git_metrics_appset_value="null"
    if [ "$git_metrics_available" = true ]; then
        git_metrics_app_value="$git_total_reconciles_from_metrics"
        git_metrics_appset_value="$git_total_appset_reconciles_from_metrics"
    fi

    local temp_file="${result_file}.tmp"
    jq --arg duration "$git_change_duration" \
       --arg start "$git_change_start" \
       --arg end "$git_change_end" \
       --arg baseline_app "$git_baseline_reconciles" \
       --arg final_app "$git_final_reconciles" \
       --arg total_app "$git_metrics_app_value" \
       --arg baseline_appset "$git_baseline_appset_reconciles" \
       --arg final_appset "$git_final_appset_reconciles" \
       --arg total_appset "$git_metrics_appset_value" \
       '. + {
           git_change_phase: {
               duration_seconds: ($duration | tonumber),
               start_time: $start,
               end_time: $end,
               argocd_metrics: {
                   baseline_app_reconcile_count: ($baseline_app | tonumber),
                   final_app_reconcile_count: ($final_app | tonumber),
                   total_app_reconciles: (if $total_app == "null" then null else ($total_app | tonumber) end),
                   baseline_appset_reconcile_count: ($baseline_appset | tonumber),
                   final_appset_reconcile_count: ($final_appset | tonumber),
                   total_appset_reconciles: (if $total_appset == "null" then null else ($total_appset | tonumber) end)
               }
           }
       }' "$result_file" > "$temp_file"
    mv "$temp_file" "$result_file"

    log_success "Git change phase complete!"
    log_info "Git change reconcile summary:"
    log_info "  - Duration: ${git_change_duration}s"
    if [ "$git_metrics_available" = true ]; then
        log_info "  - Total app reconciles: $git_total_reconciles_from_metrics"
        log_info "  - Total appset reconciles: $git_total_appset_reconciles_from_metrics"
    else
        log_warn "  - Metrics not available from $ARGOCD_METRICS_URL"
    fi
}

# Function to run a test scenario
run_scenario() {
    local scenario_name=$1
    local appset_file=$2
    local expected_apps=$3
    local result_file=$4

    log_info "Running scenario: $scenario_name"

    # Capture baseline metrics from ArgoCD metrics endpoint
    local baseline_app_reconciles=0
    local baseline_appset_reconciles=0
    local metrics_available=false
    if curl -s "$ARGOCD_METRICS_URL/metrics" > /dev/null 2>&1; then
        baseline_app_reconciles=$(get_app_reconcile_count_from_metrics)
        baseline_appset_reconciles=$(get_appset_reconcile_count_from_metrics)
        metrics_available=true
        log_info "Baseline argocd_app_reconcile_count: $baseline_app_reconciles"
        log_info "Baseline argocd_appse_reconcile_count: $baseline_appset_reconciles"
    else
        log_warn "ArgoCD metrics endpoint not available at $ARGOCD_METRICS_URL"
        log_warn "Total reconcile count will not be accurate. Ensure 'make start-local' is running."
    fi

    local start_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_epoch=$(date +%s)

    # Apply the ApplicationSet
    kubectl apply -f "$appset_file"
    local appset_name=$(yq e '.metadata.name' "$appset_file")

    # Wait for progressive sync completion and capture duration
    local total_duration=$(wait_for_appset_complete "$appset_name" "argocd" "$expected_apps")

    # Wait for reconcile counts to stabilize before capturing final metrics
    local final_app_reconciles=0
    local total_app_reconciles_from_metrics=0
    local final_appset_reconciles=0
    local total_appset_reconciles_from_metrics=0
    if [ "$metrics_available" = true ]; then
        final_app_reconciles=$(wait_for_reconcile_stabilization 30)
        total_app_reconciles_from_metrics=$((final_app_reconciles - baseline_app_reconciles))
        final_appset_reconciles=$(get_appset_reconcile_count_from_metrics)
        total_appset_reconciles_from_metrics=$((final_appset_reconciles - baseline_appset_reconciles))
        log_success "Total app reconciles (from metrics): $total_app_reconciles_from_metrics (baseline: $baseline_app_reconciles, final: $final_app_reconciles)"
        log_success "Total appset reconciles (from metrics): $total_appset_reconciles_from_metrics (baseline: $baseline_appset_reconciles, final: $final_appset_reconciles)"
    fi

    local end_epoch=$(date +%s)
    local end_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Count apps directly from kubectl
    local app_count=$(kubectl get applications -n argocd -l "argocd.argoproj.io/application-set-name=$appset_name" -o json | jq -r '.items | length')
    log_info "Found $app_count applications for ApplicationSet $appset_name"

    # Write results to JSON with proper structure
    local metrics_app_reconciles="null"
    local metrics_appset_reconciles="null"
    if [ "$metrics_available" = true ]; then
        metrics_app_reconciles="$total_app_reconciles_from_metrics"
        metrics_appset_reconciles="$total_appset_reconciles_from_metrics"
    fi

    cat > "$result_file" <<EOF
{
  "scenario": "$scenario_name",
  "branch": "$CURRENT_BRANCH",
  "timestamp": "$start_timestamp",
  "applicationset_name": "$appset_name",
  "metrics": {
    "total_duration_seconds": $total_duration,
    "expected_apps": $expected_apps,
    "actual_apps": $app_count,
    "argocd_metrics": {
      "baseline_app_reconcile_count": $baseline_app_reconciles,
      "final_app_reconcile_count": $final_app_reconciles,
      "total_app_reconciles": $metrics_app_reconciles,
      "baseline_appset_reconcile_count": $baseline_appset_reconciles,
      "final_appset_reconcile_count": $final_appset_reconciles,
      "total_appset_reconciles": $metrics_appset_reconciles,
      "note": "Direct from argocd_app_reconcile_count and argocd_appset_reconcile_count metrics at $ARGOCD_METRICS_URL"
    }
  },
  "start_time": "$start_timestamp",
  "end_time": "$end_timestamp"
}
EOF

    log_success "Scenario complete: $scenario_name"
    cat "$result_file" | jq '.'

    # Git change monitoring phase (if enabled)
    if [ "$ENABLE_GIT_CHANGE_TEST" = "true" ]; then
        log_info ""
        log_info "=== Git Change Test Phase (Optional) ==="
        log_info "This phase tests reconcile behavior when git changes occur."
        log_info ""
        read -p "Do you want to test git change reconciles? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            wait_for_git_change_and_monitor "$appset_name" "argocd" "$expected_apps" "$result_file"
        else
            log_info "Skipping git change test"
        fi
    fi

    # Cleanup
    log_info "Cleaning up ApplicationSet and Applications..."
    kubectl delete -f "$appset_file" --wait=true --timeout=120s

    # Give system time to settle
    sleep 10
}

# Function to generate test ApplicationSet manifests
generate_test_manifests() {
    local manifest_dir="$RESULTS_DIR/$TIMESTAMP/manifests"
    mkdir -p "$manifest_dir"

    log_info "Generating test manifests..."

    # Scenario 1: Small scale (5 apps, 2 steps)
    cat > "$manifest_dir/small-scale.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: perf-small
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - name: app1
            env: dev
          - name: app2
            env: dev
          - name: app3
            env: dev
          - name: app4
            env: prod
          - name: app5
            env: prod
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: environment
              operator: In
              values:
                - dev
        - matchExpressions:
            - key: environment
              operator: In
              values:
                - prod
  template:
    metadata:
      name: 'perf-small-{{.name}}'
      labels:
        environment: '{{.env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/ranakan19/argocd-example-apps.git
        path: guestbook
        targetRevision: HEAD
      destination:
        server: https://kubernetes.default.svc
        namespace: 'perf-{{.name}}'
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
EOF

    # Scenario 2: Medium scale (30 apps, 3 steps - canary pattern)
    cat > "$manifest_dir/medium-scale.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: perf-medium
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
EOF

    # Generate canary apps (2 apps = 8%)
    for i in {1..2}; do
        echo "          - name: app$i" >> "$manifest_dir/medium-scale.yaml"
        echo "            env: canary" >> "$manifest_dir/medium-scale.yaml"
    done

    # Generate staging apps (8 apps = 26%)
    for i in {3..10}; do
        echo "          - name: app$i" >> "$manifest_dir/medium-scale.yaml"
        echo "            env: staging" >> "$manifest_dir/medium-scale.yaml"
    done

    # Generate prod apps (20 apps = 66%)
    for i in {11..30}; do
        echo "          - name: app$i" >> "$manifest_dir/medium-scale.yaml"
        echo "            env: prod" >> "$manifest_dir/medium-scale.yaml"
    done

    cat >> "$manifest_dir/medium-scale.yaml" <<'EOF'
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: environment
              operator: In
              values:
                - canary
        - matchExpressions:
            - key: environment
              operator: In
              values:
                - staging
          maxUpdate: 50%
        - matchExpressions:
            - key: environment
              operator: In
              values:
                - prod
          maxUpdate: 10
  template:
    metadata:
      name: 'perf-med-{{.name}}'
      labels:
        environment: '{{.env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/ranakan19/argocd-example-apps.git
        path: guestbook
        targetRevision: HEAD
      destination:
        server: https://kubernetes.default.svc
        namespace: 'perf-med-{{.name}}'
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
EOF

    log_success "Test manifests generated in $manifest_dir"
    echo "$manifest_dir"
}

# Main execution
main() {
    log_info "Progressive Sync Performance Benchmark"
    log_info "Branch: $CURRENT_BRANCH"
    log_info "Baseline: $BASELINE_BRANCH"
    log_info "Results directory: $RESULTS_DIR/$TIMESTAMP"
    log_info "ArgoCD Metrics URL: $ARGOCD_METRICS_URL"
    log_info ""

    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq."
        exit 1
    fi

    if ! command -v yq &> /dev/null; then
        log_error "yq not found. Please install yq (https://github.com/mikefarah/yq)."
        exit 1
    fi

    # Verify cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi

    # Generate test manifests
    local manifest_dir=$(generate_test_manifests)

    # Run scenarios
    log_info "Starting performance tests..."

    run_scenario "small-scale" \
        "$manifest_dir/small-scale.yaml" \
        5 \
        "$RESULTS_DIR/$TIMESTAMP/small-scale-results.json"

    run_scenario "medium-scale" \
        "$manifest_dir/medium-scale.yaml" \
        30 \
        "$RESULTS_DIR/$TIMESTAMP/medium-scale-results.json"

    # Generate summary report
    log_info "Generating summary report..."

    cat > "$RESULTS_DIR/$TIMESTAMP/summary.md" <<EOF
# Progressive Sync Performance Results

**Branch:** $CURRENT_BRANCH
**Date:** $(date)
**Commit:** $(git rev-parse --short HEAD)

## Test Scenarios

### Small Scale (5 apps, 2 steps)

**Initial Sync Phase:**
\`\`\`json
$(cat "$RESULTS_DIR/$TIMESTAMP/small-scale-results.json" | jq '.metrics')
\`\`\`

$(if cat "$RESULTS_DIR/$TIMESTAMP/small-scale-results.json" | jq -e '.git_change_phase' > /dev/null 2>&1; then
    echo "**Git Change Phase:**"
    echo "\`\`\`json"
    cat "$RESULTS_DIR/$TIMESTAMP/small-scale-results.json" | jq '.git_change_phase'
    echo "\`\`\`"
fi)

### Medium Scale (30 apps, 3 steps)

**Initial Sync Phase:**
\`\`\`json
$(cat "$RESULTS_DIR/$TIMESTAMP/medium-scale-results.json" | jq '.metrics')
\`\`\`

$(if cat "$RESULTS_DIR/$TIMESTAMP/medium-scale-results.json" | jq -e '.git_change_phase' > /dev/null 2>&1; then
    echo "**Git Change Phase:**"
    echo "\`\`\`json"
    cat "$RESULTS_DIR/$TIMESTAMP/medium-scale-results.json" | jq '.git_change_phase'
    echo "\`\`\`"
fi)

## Metrics Tracked

All metrics are captured directly from the ArgoCD metrics endpoint (\`$ARGOCD_METRICS_URL\`):

- **argocd_metrics**:
  - \`baseline_app_reconcile_count\`: Value of \`argocd_app_reconcile_count\` before test
  - \`final_app_reconcile_count\`: Value of \`argocd_app_reconcile_count\` after apps healthy & stabilized
  - \`total_app_reconciles\`: Difference (final - baseline)
  - \`baseline_appset_reconcile_count\`: Value of \`argocd_appset_reconcile_count\` before test
  - \`final_appset_reconcile_count\`: Value of \`argocd_appset_reconcile_count\` after apps healthy & stabilized
  - \`total_appset_reconciles\`: Difference (final - baseline)

These metrics are queried directly from:
- \`curl http://localhost:8082/metrics | grep argocd_app_reconcile_count\`
- \`curl http://localhost:12345/metrics | grep argocd_appset_reconcile_count\`

## Comparison

To compare with baseline branch, run:
\`\`\`bash
git checkout $BASELINE_BRANCH
./test/performance/progressive-sync-benchmark.sh
\`\`\`

Then use the comparison script:
\`\`\`bash
./test/performance/compare-results.sh $RESULTS_DIR/$TIMESTAMP $RESULTS_DIR/<baseline-timestamp>
\`\`\`
EOF

    log_success "Summary report written to $RESULTS_DIR/$TIMESTAMP/summary.md"
    cat "$RESULTS_DIR/$TIMESTAMP/summary.md"

    log_success "All performance tests completed!"
    log_info "Results saved to: $RESULTS_DIR/$TIMESTAMP"
}

# Run main function
main "$@"