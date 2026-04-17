# How to Run Progressive Sync Performance Tests

Quick guide to measure the performance impact of your progressive sync changes.

## The Plan

1. **Test baseline (master)** → capture metrics
2. **Test your branch (annotationPOC)** → capture metrics  
3. **Compare results** → generate report for PR

## Prerequisites

```bash
# Install required tools
brew install jq yq  # macOS
# or
sudo apt-get install jq && wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq  # Linux

# Verify you have a k8s cluster with Argo CD
kubectl cluster-info
kubectl get ns argocd
```

## Step-by-Step

### 1. Test Baseline (master branch)

```bash
# Switch to master
git checkout master

# Build and install Argo CD
make install

# Enable progressive syncs
kubectl set env deployment/argocd-applicationset-controller \
  -n argocd ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS=true

# Wait for rollout
kubectl rollout status -n argocd deployment/argocd-applicationset-controller

# Run benchmark
cd test/performance
chmod +x *.sh
./progressive-sync-benchmark.sh

# Save the output - note the results directory path
# Example: Results saved to: test/performance/results/20260407_120000
```

**The script will:**
- Generate 2 test ApplicationSets (small-scale: 5 apps, medium-scale: 40 apps)
- Apply each ApplicationSet
- Wait for all apps to become Healthy
- Count application reconciles (via kubectl events)
- Query Prometheus metrics (if available)
- Clean up ApplicationSets
- Generate `results/<timestamp>/` with JSON metrics

### 2. Test Your Branch (annotationPOC)

```bash
# Switch to your branch
git checkout annotationPOC

# Build and install
make install

# Enable progressive syncs (same as before)
kubectl set env deployment/argocd-applicationset-controller \
  -n argocd ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS=true

# Wait for rollout
kubectl rollout status -n argocd deployment/argocd-applicationset-controller

# Run benchmark again
./progressive-sync-benchmark.sh

# Note the new results directory
# Example: Results saved to: test/performance/results/20260407_140000
```

### 3. Compare Results

```bash
# Compare the two test runs
./compare-results.sh \
  results/20260407_120000 \
  results/20260407_140000

# This outputs a formatted comparison table
```

**Example output:**
```
## medium-scale Comparison

| Metric | master | annotationPOC | Change |
|--------|--------|---------------|--------|
| Total Duration (s) | 45 | 52 | +15.6% |
| AppSet Reconciles | 8 | 12 | +50% |
| Avg App Reconciles (kubectl) | 2.1 | 3.4 | +62% |
| Max App Reconciles (kubectl) | 3 | 5 | +67% |
| Apps w/ Refresh Annotation | 0 | 40 | +100% |
```

### 4. Include in PR

```bash
# Save comparison to file
./compare-results.sh \
  results/20260407_120000 \
  results/20260407_140000 \
  > performance-comparison.md

# Add to PR description or commit as evidence
git add performance-comparison.md
git commit -m "docs: add performance comparison for progressive sync changes"
```

---

## What Gets Measured

### Primary Metrics (Application-Level)
- **Avg App Reconciles**: How many times each app reconciles on average
- **Max App Reconciles**: Worst-case reconcile count
- **Total Duration**: Time from appset creation to all apps healthy

### Why These Matter
Your changes add annotation-based refresh to ensure apps have current status before progressive sync proceeds. This means:
- ✅ **More reconciles** (expected: 10-30% increase)
- ✅ **Slightly longer sync time** (expected: 5-15% increase)
- ✅ **Eliminates race conditions** (the tradeoff)

---


## Optional: Set Up Prometheus

For more accurate metrics, run Prometheus locally:

```bash
# Create Prometheus config
cat > /tmp/prometheus.yml <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'argocd-metrics'
    static_configs:
      - targets: ['localhost:8082']  # app-controller metrics
  - job_name: 'argocd-appset-controller'
    static_configs:
      - targets: ['localhost:8084']  # appset-controller metrics
EOF

# Run Prometheus in Docker
docker run -d --name prometheus -p 9090:9090 \
  -v /tmp/prometheus.yml:/etc/prometheus/prometheus.yml \
  prom/prometheus

# Port-forward Argo CD metrics (in separate terminals)
kubectl port-forward -n argocd svc/argocd-metrics 8082:8082 &
kubectl port-forward -n argocd svc/argocd-applicationset-controller 8084:8084 &

# Verify Prometheus is scraping
curl http://localhost:9090/-/healthy
curl http://localhost:9090/api/v1/query?query=argocd_app_reconcile_count | jq .
```

**With Prometheus, you'll get:**
- More accurate reconcile counts (controller-reported vs event-based)
- Per-application breakdown
- Time-series data showing when reconciles happened

---

## Troubleshooting

### "Timeout waiting for ApplicationSet to complete"
```bash
# Check controller logs
kubectl logs -n argocd deployment/argocd-applicationset-controller --tail=100

# Verify progressive syncs are enabled
kubectl get deployment -n argocd argocd-applicationset-controller -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS")].value}'
```

### "jq: command not found"
```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq
```

### Prometheus not available
The tests will still run using kubectl-based metrics. Prometheus just provides more accurate counts.

### Results look the same
Make sure:
1. You built and deployed both branches
2. Pods actually restarted: `kubectl get pods -n argocd`
3. Controller is using the new image

---

## Advanced: Multiple Test Runs

For statistical significance, run multiple times:

```bash
# Baseline (3 runs)
git checkout master
make install && kubectl rollout restart -n argocd deployment/argocd-applicationset-controller
for i in {1..3}; do
  echo "Baseline run $i..."
  ./progressive-sync-benchmark.sh
  sleep 60  # cool-down
done

# Your branch (3 runs)
git checkout annotationPOC
make install && kubectl rollout restart -n argocd deployment/argocd-applicationset-controller
for i in {1..3}; do
  echo "Branch run $i..."
  ./progressive-sync-benchmark.sh
  sleep 60
done

# Compare all runs (pick median results)
ls -la results/
```

---

## Quick Reference

```bash
# One-liner to run all tests
git checkout master && make install && \
  kubectl set env -n argocd deployment/argocd-applicationset-controller ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS=true && \
  sleep 30 && ./progressive-sync-benchmark.sh

git checkout annotationPOC && make install && \
  kubectl set env -n argocd deployment/argocd-applicationset-controller ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS=true && \
  sleep 30 && ./progressive-sync-benchmark.sh

./compare-results.sh results/<timestamp-1> results/<timestamp-2>
```

---

## What to Include in PR

1. **Comparison table** (from compare-results.sh output)
2. **Brief explanation**:
   - "Medium-scale test (40 apps): +X% reconciles, +Y% sync time"
   - "Tradeoff: Eliminates stale status race conditions"
3. **Justification**: Why the overhead is acceptable
4. **Optional**: Link to full results JSON if reviewers want details
