#!/bin/bash
# Quick test to verify manifest generation works

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_DIR="/tmp/perf-test-$TIMESTAMP"

echo "Testing manifest generation..."
echo "Output directory: $TEST_DIR"

mkdir -p "$TEST_DIR/manifests"

# Generate small-scale manifest
cat > "$TEST_DIR/manifests/small-scale.yaml" <<'EOF'
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
        repoURL: https://github.com/argoproj/argocd-example-apps.git
        path: guestbook
        targetRevision: HEAD
      destination:
        server: https://kubernetes.default.svc
        namespace: 'perf-{{.name}}'
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
EOF

# Generate medium-scale manifest
cat > "$TEST_DIR/manifests/medium-scale.yaml" <<'EOF'
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

# Generate canary apps (2 apps)
for i in {1..2}; do
    echo "          - name: app$i" >> "$TEST_DIR/manifests/medium-scale.yaml"
    echo "            env: canary" >> "$TEST_DIR/manifests/medium-scale.yaml"
done

# Generate staging apps (8 apps)
for i in {3..10}; do
    echo "          - name: app$i" >> "$TEST_DIR/manifests/medium-scale.yaml"
    echo "            env: staging" >> "$TEST_DIR/manifests/medium-scale.yaml"
done

# Generate prod apps (30 apps)
for i in {11..40}; do
    echo "          - name: app$i" >> "$TEST_DIR/manifests/medium-scale.yaml"
    echo "            env: prod" >> "$TEST_DIR/manifests/medium-scale.yaml"
done

cat >> "$TEST_DIR/manifests/medium-scale.yaml" <<'EOF'
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
        repoURL: https://github.com/argoproj/argocd-example-apps.git
        path: guestbook
        targetRevision: HEAD
      destination:
        server: https://kubernetes.default.svc
        namespace: 'perf-med-{{.name}}'
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
EOF

echo "✓ Manifests generated successfully!"
echo ""
ls -lh "$TEST_DIR/manifests/"
echo ""
echo "Small-scale manifest (5 apps):"
echo "  $TEST_DIR/manifests/small-scale.yaml"
echo ""
echo "Medium-scale manifest (40 apps):"
echo "  $TEST_DIR/manifests/medium-scale.yaml"
echo ""
echo "Verify medium-scale has 40 app entries:"
grep -c "name: app" "$TEST_DIR/manifests/medium-scale.yaml"
echo ""
echo "Preview medium-scale ApplicationSet:"
head -30 "$TEST_DIR/manifests/medium-scale.yaml"
echo "..."
echo ""
echo "You can test these manifests with:"
echo "  kubectl apply -f $TEST_DIR/manifests/medium-scale.yaml"