#!/bin/bash
set -e

# Compare Progressive Sync Performance Results
# Compares metrics between two test runs (e.g., baseline vs current branch)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <results-dir-1> <results-dir-2>"
    echo "Example: $0 ./results/20260403_120000 ./results/20260403_140000"
    exit 1
fi

RESULTS_DIR_1="$1"
RESULTS_DIR_2="$2"

if [ ! -d "$RESULTS_DIR_1" ]; then
    echo "Error: Directory $RESULTS_DIR_1 not found"
    exit 1
fi

if [ ! -d "$RESULTS_DIR_2" ]; then
    echo "Error: Directory $RESULTS_DIR_2 not found"
    exit 1
fi

# Function to calculate percentage change
calc_percent_change() {
    local baseline=$1
    local current=$2

    if [ "$baseline" = "0" ]; then
        echo "N/A"
    else
        echo "scale=1; (($current - $baseline) / $baseline) * 100" | bc
    fi
}

# Function to format change with color
format_change() {
    local change=$1
    local inverse=${2:-false}  # Some metrics are better when lower

    if [ "$change" = "N/A" ]; then
        echo "N/A"
        return
    fi

    local abs_change=$(echo "$change" | sed 's/-//')

    if (( $(echo "$change > 0" | bc -l) )); then
        if [ "$inverse" = "true" ]; then
            echo -e "${RED}+${change}%${NC}"
        else
            echo -e "${GREEN}+${change}%${NC}"
        fi
    elif (( $(echo "$change < 0" | bc -l) )); then
        if [ "$inverse" = "true" ]; then
            echo -e "${GREEN}${change}%${NC}"
        else
            echo -e "${RED}${change}%${NC}"
        fi
    else
        echo "0%"
    fi
}

# Function to compare scenario results
compare_scenario() {
    local scenario_name=$1
    local file1="$RESULTS_DIR_1/${scenario_name}-results.json"
    local file2="$RESULTS_DIR_2/${scenario_name}-results.json"

    if [ ! -f "$file1" ] || [ ! -f "$file2" ]; then
        return
    fi

    # Extract metrics
    local branch1=$(jq -r '.branch' "$file1")
    local branch2=$(jq -r '.branch' "$file2")

    # Initial Sync Phase - ArgoCD Metrics
    local initial_duration1=$(jq -r '.metrics.total_duration_seconds // "N/A"' "$file1")
    local initial_duration2=$(jq -r '.metrics.total_duration_seconds // "N/A"' "$file2")
    local initial_duration_change="N/A"
    if [ "$initial_duration1" != "N/A" ] && [ "$initial_duration1" != "null" ] && [ "$initial_duration2" != "N/A" ] && [ "$initial_duration2" != "null" ]; then
        initial_duration_change=$(calc_percent_change "$initial_duration1" "$initial_duration2")
    fi

    local initial_app_rec1=$(jq -r '.metrics.argocd_metrics.total_app_reconciles // "N/A"' "$file1")
    local initial_app_rec2=$(jq -r '.metrics.argocd_metrics.total_app_reconciles // "N/A"' "$file2")
    local initial_app_rec_change="N/A"
    if [ "$initial_app_rec1" != "N/A" ] && [ "$initial_app_rec1" != "null" ] && [ "$initial_app_rec2" != "N/A" ] && [ "$initial_app_rec2" != "null" ]; then
        initial_app_rec_change=$(calc_percent_change "$initial_app_rec1" "$initial_app_rec2")
    fi

    local initial_appset_rec1=$(jq -r '.metrics.argocd_metrics.total_appset_reconciles // "N/A"' "$file1")
    local initial_appset_rec2=$(jq -r '.metrics.argocd_metrics.total_appset_reconciles // "N/A"' "$file2")
    local initial_appset_rec_change="N/A"
    if [ "$initial_appset_rec1" != "N/A" ] && [ "$initial_appset_rec1" != "null" ] && [ "$initial_appset_rec2" != "N/A" ] && [ "$initial_appset_rec2" != "null" ]; then
        initial_appset_rec_change=$(calc_percent_change "$initial_appset_rec1" "$initial_appset_rec2")
    fi

    # Git Change Phase - ArgoCD Metrics
    local git_duration1=$(jq -r '.git_change_phase.duration_seconds // "N/A"' "$file1")
    local git_duration2=$(jq -r '.git_change_phase.duration_seconds // "N/A"' "$file2")
    local git_duration_change="N/A"
    if [ "$git_duration1" != "N/A" ] && [ "$git_duration1" != "null" ] && [ "$git_duration2" != "N/A" ] && [ "$git_duration2" != "null" ]; then
        git_duration_change=$(calc_percent_change "$git_duration1" "$git_duration2")
    fi

    local git_app_rec1=$(jq -r '.git_change_phase.argocd_metrics.total_app_reconciles // "N/A"' "$file1")
    local git_app_rec2=$(jq -r '.git_change_phase.argocd_metrics.total_app_reconciles // "N/A"' "$file2")
    local git_app_rec_change="N/A"
    if [ "$git_app_rec1" != "N/A" ] && [ "$git_app_rec1" != "null" ] && [ "$git_app_rec2" != "N/A" ] && [ "$git_app_rec2" != "null" ]; then
        git_app_rec_change=$(calc_percent_change "$git_app_rec1" "$git_app_rec2")
    fi

    local git_appset_rec1=$(jq -r '.git_change_phase.argocd_metrics.total_appset_reconciles // "N/A"' "$file1")
    local git_appset_rec2=$(jq -r '.git_change_phase.argocd_metrics.total_appset_reconciles // "N/A"' "$file2")
    local git_appset_rec_change="N/A"
    if [ "$git_appset_rec1" != "N/A" ] && [ "$git_appset_rec1" != "null" ] && [ "$git_appset_rec2" != "N/A" ] && [ "$git_appset_rec2" != "null" ]; then
        git_appset_rec_change=$(calc_percent_change "$git_appset_rec1" "$git_appset_rec2")
    fi

    # Print comparison table
    cat <<EOF

## $scenario_name Comparison

| Metric | $branch1 | $branch2 | Change |
|--------|----------|----------|--------|
EOF

    # Add Initial Sync Phase metrics if available
    if [ "$initial_app_rec1" != "N/A" ] && [ "$initial_app_rec1" != "null" ]; then
        cat <<EOF
| | | | |
| **Initial Sync Phase** | | | |
| _Duration (s)_ | $initial_duration1 | $initial_duration2 | $(format_change "$initial_duration_change" true) |
| _App Reconciles (argocd_app_reconcile_count)_ | $initial_app_rec1 | $initial_app_rec2 | $(format_change "$initial_app_rec_change" true) |
| _AppSet Reconciles (argocd_appset_reconcile_count)_ | $initial_appset_rec1 | $initial_appset_rec2 | $(format_change "$initial_appset_rec_change" true) |
EOF
    fi

    # Add Git Change Phase metrics if available
    if [ "$git_app_rec1" != "N/A" ] && [ "$git_app_rec1" != "null" ]; then
        cat <<EOF
| | | | |
| **Git Change Phase** | | | |
| _Duration (s)_ | $git_duration1 | $git_duration2 | $(format_change "$git_duration_change" true) |
| _App Reconciles (argocd_app_reconcile_count)_ | $git_app_rec1 | $git_app_rec2 | $(format_change "$git_app_rec_change" true) |
| _AppSet Reconciles (argocd_appset_reconcile_count)_ | $git_appset_rec1 | $git_appset_rec2 | $(format_change "$git_appset_rec_change" true) |
EOF
    fi
}

# Main execution
main() {
    log_info "Comparing performance results"
    log_info "Baseline: $RESULTS_DIR_1"
    log_info "Current:  $RESULTS_DIR_2"

    echo ""
    echo "# Progressive Sync Performance Comparison"
    echo ""
    echo "**Baseline:** $(basename "$RESULTS_DIR_1")"
    echo "**Current:**  $(basename "$RESULTS_DIR_2")"
    echo ""

    # Compare all scenarios
    compare_scenario "small-scale"
    compare_scenario "medium-scale"
}

# Run main function
main "$@"
