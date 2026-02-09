# Ingress + HPA Stress Test + Observability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Install nginx-ingress-controller with `externalTrafficPolicy: Local` (preserving source IPs for auditing), configure path-based Ingress routing (`/grafana`, `/vmagent`, `/vmsingle`, `/nginx`), then configure HPA for my-service and Grafana with full observability (metrics, dashboards) to monitor scaling under stress.

**Architecture:** Three phases. Phase 0: Install ingress-nginx controller via Ansible + create Ingress resources via GitOps (ArgoCD). Phase 1: Stress nginx (my-service) while monitoring live in Grafana via VictoriaMetrics. Phase 2: Stress Grafana itself, monitoring via kubectl. nginx keeps its existing NodePort AND gets Ingress access. All services accessible via path prefix on the VM IP (192.168.15.64).

**Tech Stack:** k3s (v1.28.5+k3s1), ingress-nginx controller v1.7.1 (baremetal), Kustomize, Helm (Grafana chart 6.50.5), VictoriaMetrics (VMAgent + VMSingle), ArgoCD, nginx-prometheus-exporter, HPA autoscaling/v2

---

## Phase 0: Ingress Controller + Ingress Resources

### Task 1: Install ingress-nginx controller via Ansible

Adapt the pattern from `~/ansible/roles/k3s/tasks/setup_nginx.yml` into the joga-together Ansible playbook.

**Files:**
- Modify: `/home/jason/my-projects/joga-together/ansible/setup-k3s.yml`

**Step 1: Add ingress-nginx installation tasks to setup-k3s.yml**

Add these tasks at the end of the existing playbook (after the ArgoCD password display task):

```yaml
    # ── Ingress Nginx Controller ──────────────────────────────────────
    - name: "Download ingress-nginx manifest (baremetal) to VM"
      ansible.builtin.get_url:
        url: "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.7.1/deploy/static/provider/baremetal/deploy.yaml"
        dest: "/tmp/ingress-nginx-deploy.yaml"
        force: no

    - name: "Deploy ingress-nginx controller"
      ansible.builtin.shell: "kubectl --kubeconfig {{ remote_kubeconfig }} apply -f /tmp/ingress-nginx-deploy.yaml"
      changed_when: true

    - name: "Aguarda o deployment do ingress-nginx-controller ficar disponível"
      ansible.builtin.shell: >
        kubectl --kubeconfig {{ remote_kubeconfig }} -n ingress-nginx
        rollout status deployment/ingress-nginx-controller --timeout=120s
      register: nginx_rollout
      until: nginx_rollout.rc == 0
      retries: 5
      delay: 10
      changed_when: false

    - name: "Cria o Service LoadBalancer com externalTrafficPolicy: Local"
      ansible.builtin.shell: |
        cat <<'EOF' | kubectl --kubeconfig {{ remote_kubeconfig }} apply -f -
        apiVersion: v1
        kind: Service
        metadata:
          name: ingress-nginx-controller-loadbalancer
          namespace: ingress-nginx
        spec:
          selector:
            app.kubernetes.io/component: controller
            app.kubernetes.io/instance: ingress-nginx
            app.kubernetes.io/name: ingress-nginx
          ports:
          - name: http
            port: 80
            protocol: TCP
            targetPort: 80
          - name: https
            port: 443
            protocol: TCP
            targetPort: 443
          type: LoadBalancer
          externalTrafficPolicy: Local
        EOF
      changed_when: true

    - name: "Patch ingress-nginx-controller para 1 réplica"
      ansible.builtin.shell: >
        kubectl --kubeconfig {{ remote_kubeconfig }} -n ingress-nginx
        scale deployment ingress-nginx-controller --replicas=1
      changed_when: true

    - name: "Remove ValidatingWebhookConfiguration do ingress-nginx"
      ansible.builtin.shell: >
        kubectl --kubeconfig {{ remote_kubeconfig }}
        delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found
      changed_when: true
```

**Step 2: Verify YAML syntax**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('/home/jason/my-projects/joga-together/ansible/setup-k3s.yml'))"
```
Expected: No output (no errors).

**Step 3: Commit**

```bash
cd /home/jason/my-projects/joga-together/ansible
git add setup-k3s.yml
git commit -m "feat: add ingress-nginx controller installation with externalTrafficPolicy Local"
```

---

### Task 2: Create Ingress resource for Grafana

Grafana needs `root_url` and `serve_from_sub_path` configured to work under `/grafana` sub-path. We update both the Helm values and create an Ingress resource.

**Files:**
- Modify: `infra/grafana/dev/values.yaml` (add sub-path config + ingress)
- Create: `argocd/dev/ingress.yaml` (ArgoCD Application for Ingress resources)
- Create: `apps/ingress/dev/ingress.yaml` (the actual Ingress manifest)
- Create: `apps/ingress/dev/kustomization.yaml`

**Step 1: Update Grafana values to support /grafana sub-path**

Replace the full content of `infra/grafana/dev/values.yaml` with:

```yaml
# platform-gitops/infra/grafana/dev/values.yaml

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: VictoriaMetrics
      type: prometheus
      url: http://vmsingle-dev-victoria-metrics-single-server.dev-monitoring.svc:8428
      access: proxy
      isDefault: true

adminPassword: admin

persistence:
  enabled: true
  storageClassName: data-path
  size: 2Gi

grafana.ini:
  server:
    root_url: "%(protocol)s://%(domain)s/grafana/"
    serve_from_sub_path: true
```

**Step 2: Create the Ingress manifest**

Create `apps/ingress/dev/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: platform-ingress
  namespace: dev-monitoring
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      # Grafana: http://<IP>/grafana/
      - path: /grafana(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: grafana-dev
            port:
              number: 80

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: platform-ingress-vmagent
  namespace: dev-monitoring
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      # VMAgent: http://<IP>/vmagent/
      - path: /vmagent(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: vmagent-dev-victoria-metrics-agent
            port:
              number: 8429

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: platform-ingress-vmsingle
  namespace: dev-monitoring
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      # VictoriaMetrics Single: http://<IP>/vmsingle/
      - path: /vmsingle(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: vmsingle-dev-victoria-metrics-single-server
            port:
              number: 8428

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: platform-ingress-nginx
  namespace: dev-apps
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      # Nginx (my-service): http://<IP>/nginx/ — also still on NodePort 30081
      - path: /nginx(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: my-service
            port:
              number: 80
```

Note: Service names for VMAgent and VMSingle follow the Helm chart naming convention. Run `kubectl get svc -n dev-monitoring` on your cluster to verify the exact names and adjust if they differ. The my-service NodePort (30081) remains unchanged — this Ingress adds a second access path.

**Step 3: Create kustomization for ingress**

Create `apps/ingress/dev/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ingress.yaml
```

**Step 4: Create ArgoCD Application for Ingress**

Create `argocd/dev/ingress.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ingress-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/ojasonw/platform-gitops.git'
    targetRevision: HEAD
    path: apps/ingress/dev
  destination:
    server: 'https://kubernetes.default.svc'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

Note: We don't set a single destination namespace because the Ingress resources span multiple namespaces (`dev-monitoring` and `dev-apps`). Each Ingress manifest defines its own namespace in its metadata.

**Step 5: Verify kustomize builds correctly**

Run:
```bash
kubectl kustomize apps/ingress/dev
```
Expected: Outputs 4 Ingress resources. No errors.

**Step 6: Commit**

```bash
git add infra/grafana/dev/values.yaml apps/ingress/dev/ingress.yaml apps/ingress/dev/kustomization.yaml argocd/dev/ingress.yaml
git commit -m "feat: add path-based Ingress for /grafana, /vmagent, /vmsingle, /nginx"
```

---

### Task 3: Verify Ingress routing works

This task is manual verification. No file changes.

**Step 1: Verify ingress-nginx controller is running**

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```
Expected: Controller pod Running. LoadBalancer service with EXTERNAL-IP (should be the node IP via k3s ServiceLB).

**Step 2: Verify service names match**

```bash
kubectl get svc -n dev-monitoring
kubectl get svc -n dev-apps
```

Compare the actual service names with what's in the Ingress manifest. If any name differs, update `apps/ingress/dev/ingress.yaml` accordingly.

**Step 3: Test each route**

```bash
# Grafana (should show Grafana login page HTML)
curl -s http://192.168.15.64/grafana/login | head -5

# VMAgent (should show VMAgent UI or API response)
curl -s http://192.168.15.64/vmagent/

# VictoriaMetrics Single (should show vmui or API response)
curl -s http://192.168.15.64/vmsingle/

# Nginx my-service (should show nginx welcome page)
curl -s http://192.168.15.64/nginx/

# Verify NodePort still works for my-service
curl -s http://192.168.15.64:30081/
```

**Step 4: Verify source IP preservation**

```bash
# Check nginx-ingress logs for real client IPs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20
```

Expected: Logs should show the actual client IP (your machine's IP), NOT a cluster-internal IP like 10.42.x.x. This confirms `externalTrafficPolicy: Local` is working.

---

## Pre-requisites for HPA (run before Phase 1)

Before starting HPA tasks, run these checks on your k3s cluster:

```bash
# Check if metrics-server is running (required for HPA)
kubectl get pods -n kube-system | grep metrics

# If NOT present, install it:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# For k3s with self-signed certs, you may need:
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Verify metrics-server is working (may take 1-2 minutes after install):
kubectl top nodes
kubectl top pods -n dev-apps
```

---

## Phase 1: Stress my-service (nginx) + Monitor in Grafana

### Task 4: Add resource requests/limits and nginx-exporter sidecar to my-service

HPA requires `resources.requests.cpu` to calculate utilization percentage. We also add the nginx-prometheus-exporter sidecar for metrics, and a ConfigMap for stub_status.

**Files:**
- Modify: `apps/my-service/base/deployment.yaml`
- Create: `apps/my-service/base/nginx-config.yaml`
- Modify: `apps/my-service/base/kustomization.yaml`

**Step 1: Create the nginx ConfigMap for stub_status**

Create `apps/my-service/base/nginx-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  default.conf: |
    server {
        listen 80;
        server_name localhost;

        location / {
            root /usr/share/nginx/html;
            index index.html index.htm;
        }

        location /nginx_status {
            stub_status on;
            allow 127.0.0.1;
            deny all;
        }
    }
```

**Step 2: Update the deployment with resources, exporter sidecar, and volume**

Replace the full content of `apps/my-service/base/deployment.yaml` with:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
spec:
  selector:
    matchLabels:
      app: my-service
  template:
    metadata:
      labels:
        app: my-service
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9113"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: my-service
        image: nginx:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d/
      - name: nginx-exporter
        image: nginx/nginx-prometheus-exporter:1.1.0
        args:
        - "-nginx.scrape-uri=http://localhost/nginx_status"
        ports:
        - containerPort: 9113
          name: metrics
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            cpu: 50m
            memory: 32Mi
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-config
```

**Step 3: Update kustomization to include new resources**

Replace the full content of `apps/my-service/base/kustomization.yaml` with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - nginx-config.yaml
```

**Step 4: Verify kustomize builds correctly**

Run:
```bash
kubectl kustomize apps/my-service/overlays/dev
```
Expected: Outputs merged YAML with deployment (2 containers), service, and configmap. No errors.

**Step 5: Commit**

```bash
git add apps/my-service/base/deployment.yaml apps/my-service/base/nginx-config.yaml apps/my-service/base/kustomization.yaml
git commit -m "feat: add resource limits, nginx-exporter sidecar, and stub_status config"
```

---

### Task 5: Create HPA for my-service

**Files:**
- Create: `apps/my-service/base/hpa.yaml`
- Modify: `apps/my-service/base/kustomization.yaml`
- Modify: `apps/my-service/overlays/dev/patch-replicas.yaml`
- Modify: `apps/my-service/overlays/dev/kustomization.yaml`

**Step 1: Create the HPA manifest**

Create `apps/my-service/base/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-service
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
      - type: Pods
        value: 2
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 120
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
```

**Step 2: Add HPA to kustomization**

Replace the full content of `apps/my-service/base/kustomization.yaml` with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - nginx-config.yaml
  - hpa.yaml
```

**Step 3: Remove fixed replicas from dev overlay**

When HPA is active, you must NOT set `spec.replicas` in the Deployment, otherwise it conflicts with HPA.

Replace the full content of `apps/my-service/overlays/dev/patch-replicas.yaml` with:

```yaml
# Replicas are now managed by HPA (hpa.yaml in base).
# This file is kept empty intentionally.
```

Replace the full content of `apps/my-service/overlays/dev/kustomization.yaml` with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
  - ../../base
images:
  - name: my-service
    newTag: v1.0.0
```

**Step 4: Verify kustomize builds correctly**

Run:
```bash
kubectl kustomize apps/my-service/overlays/dev
```
Expected: Output includes HPA manifest. Deployment should NOT have `spec.replicas` field.

**Step 5: Commit**

```bash
git add apps/my-service/base/hpa.yaml apps/my-service/base/kustomization.yaml apps/my-service/overlays/dev/patch-replicas.yaml apps/my-service/overlays/dev/kustomization.yaml
git commit -m "feat: add HPA for my-service with CPU-based autoscaling 1-5 replicas"
```

---

### Task 6: Configure VMAgent to scrape nginx metrics

**Files:**
- Modify: `infra/victoria-metrics/dev/vmagent-values.yaml`

**Step 1: Update vmagent values with scrape config for nginx**

Replace the full content of `infra/victoria-metrics/dev/vmagent-values.yaml` with:

```yaml
# platform-gitops/infra/victoria-metrics/dev/vmagent-values.yaml

remoteWrite:
  - url: "http://vmsingle-dev-victoria-metrics-single-server.dev-monitoring.svc:8428/api/v1/write"

config:
  scrape_configs:
    - job_name: "nginx-exporter"
      kubernetes_sd_configs:
        - role: pod
          namespaces:
            names:
              - dev-apps
      relabel_configs:
        - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
          action: keep
          regex: "true"
        - source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
          action: replace
          target_label: __address__
          regex: (.+);(.+)
          replacement: "${1}:${2}"
        - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
          action: replace
          target_label: __metrics_path__
          regex: (.+)
        - source_labels: [__meta_kubernetes_pod_name]
          target_label: pod
        - source_labels: [__meta_kubernetes_pod_namespace]
          target_label: namespace
```

**Step 2: Commit**

```bash
git add infra/victoria-metrics/dev/vmagent-values.yaml
git commit -m "feat: add nginx-exporter scrape config to vmagent"
```

---

### Task 7: Create Grafana dashboard for HPA monitoring

**Files:**
- Create: `infra/grafana/dev/dashboards/hpa-stress-test.json`
- Modify: `infra/grafana/dev/values.yaml`

**Step 1: Create the dashboard JSON**

Create directory and file `infra/grafana/dev/dashboards/hpa-stress-test.json`:

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "graphTooltip": 0,
  "panels": [
    {
      "title": "Pod Count (HPA Scaling)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "count(kube_pod_info{namespace=\"dev-apps\", pod=~\"my-service.*\"})",
          "legendFormat": "Running Pods"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "palette-classic" },
          "custom": { "fillOpacity": 20, "lineWidth": 2, "drawStyle": "line" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 3 },
              { "color": "red", "value": 5 }
            ]
          }
        },
        "overrides": []
      }
    },
    {
      "title": "HPA Desired vs Current Replicas",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler=\"my-service\", namespace=\"dev-apps\"}",
          "legendFormat": "Desired Replicas"
        },
        {
          "expr": "kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler=\"my-service\", namespace=\"dev-apps\"}",
          "legendFormat": "Current Replicas"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "palette-classic" },
          "custom": { "fillOpacity": 10, "lineWidth": 2, "drawStyle": "line" }
        },
        "overrides": []
      }
    },
    {
      "title": "CPU Usage per Pod",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "rate(container_cpu_usage_seconds_total{namespace=\"dev-apps\", pod=~\"my-service.*\", container=\"my-service\"}[2m]) * 100",
          "legendFormat": "{{ pod }}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "color": { "mode": "palette-classic" },
          "custom": { "fillOpacity": 15, "lineWidth": 1, "drawStyle": "line" }
        },
        "overrides": []
      }
    },
    {
      "title": "Memory Usage per Pod",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "container_memory_working_set_bytes{namespace=\"dev-apps\", pod=~\"my-service.*\", container=\"my-service\"}",
          "legendFormat": "{{ pod }}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "bytes",
          "color": { "mode": "palette-classic" },
          "custom": { "fillOpacity": 15, "lineWidth": 1, "drawStyle": "line" }
        },
        "overrides": []
      }
    },
    {
      "title": "Nginx Requests per Second",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 16 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "sum(rate(nginx_http_requests_total{namespace=\"dev-apps\"}[1m]))",
          "legendFormat": "Total RPS"
        },
        {
          "expr": "rate(nginx_http_requests_total{namespace=\"dev-apps\"}[1m])",
          "legendFormat": "{{ pod }}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "color": { "mode": "palette-classic" },
          "custom": { "fillOpacity": 20, "lineWidth": 2, "drawStyle": "line" }
        },
        "overrides": []
      }
    },
    {
      "title": "Nginx Active Connections",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 16 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "sum(nginx_connections_active{namespace=\"dev-apps\"})",
          "legendFormat": "Active Connections"
        },
        {
          "expr": "sum(nginx_connections_waiting{namespace=\"dev-apps\"})",
          "legendFormat": "Waiting Connections"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "palette-classic" },
          "custom": { "fillOpacity": 15, "lineWidth": 2, "drawStyle": "line" }
        },
        "overrides": []
      }
    },
    {
      "title": "HPA CPU Utilization vs Target",
      "type": "gauge",
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 24 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "kube_horizontalpodautoscaler_status_target_metric{horizontalpodautoscaler=\"my-service\", namespace=\"dev-apps\"}",
          "legendFormat": "Current CPU %"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 50 },
              { "color": "red", "value": 80 }
            ]
          }
        },
        "overrides": []
      }
    },
    {
      "title": "HPA Replicas Status",
      "type": "stat",
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 24 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler=\"my-service\", namespace=\"dev-apps\"}",
          "legendFormat": "Max Replicas"
        },
        {
          "expr": "kube_horizontalpodautoscaler_spec_min_replicas{horizontalpodautoscaler=\"my-service\", namespace=\"dev-apps\"}",
          "legendFormat": "Min Replicas"
        },
        {
          "expr": "kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler=\"my-service\", namespace=\"dev-apps\"}",
          "legendFormat": "Current Replicas"
        }
      ],
      "fieldConfig": {
        "defaults": { "color": { "mode": "palette-classic" } },
        "overrides": []
      }
    },
    {
      "title": "Network I/O per Pod",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 24 },
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "targets": [
        {
          "expr": "sum(rate(container_network_receive_bytes_total{namespace=\"dev-apps\", pod=~\"my-service.*\"}[2m]))",
          "legendFormat": "RX bytes/s"
        },
        {
          "expr": "sum(rate(container_network_transmit_bytes_total{namespace=\"dev-apps\", pod=~\"my-service.*\"}[2m]))",
          "legendFormat": "TX bytes/s"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "Bps",
          "color": { "mode": "palette-classic" },
          "custom": { "fillOpacity": 15, "lineWidth": 1, "drawStyle": "line" }
        },
        "overrides": []
      }
    }
  ],
  "schemaVersion": 39,
  "templating": {
    "list": [
      {
        "current": { "selected": false, "text": "VictoriaMetrics", "value": "VictoriaMetrics" },
        "hide": 0,
        "includeAll": false,
        "label": "Datasource",
        "multi": false,
        "name": "datasource",
        "options": [],
        "query": "prometheus",
        "type": "datasource"
      }
    ]
  },
  "time": { "from": "now-30m", "to": "now" },
  "refresh": "5s",
  "title": "HPA Stress Test - my-service",
  "uid": "hpa-stress-test-nginx"
}
```

**Step 2: Update Grafana values to provision dashboards via sidecar**

Replace the full content of `infra/grafana/dev/values.yaml` with:

```yaml
# platform-gitops/infra/grafana/dev/values.yaml

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: VictoriaMetrics
      type: prometheus
      url: http://vmsingle-dev-victoria-metrics-single-server.dev-monitoring.svc:8428
      access: proxy
      isDefault: true

adminPassword: admin

persistence:
  enabled: true
  storageClassName: data-path
  size: 2Gi

grafana.ini:
  server:
    root_url: "%(protocol)s://%(domain)s/grafana/"
    serve_from_sub_path: true

sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    searchNamespace: dev-monitoring

dashboardsConfigMaps:
  hpa-stress-test: "grafana-dashboard-hpa-stress-test"
```

**Step 3: Apply the dashboard as a ConfigMap for testing**

```bash
mkdir -p infra/grafana/dev/dashboards
kubectl create configmap grafana-dashboard-hpa-stress-test \
  --from-file=hpa-stress-test.json=infra/grafana/dev/dashboards/hpa-stress-test.json \
  -n dev-monitoring \
  --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client | \
  kubectl apply -f -
```

**Step 4: Verify dashboard appears in Grafana**

```bash
# Access Grafana via Ingress
curl -s http://192.168.15.64/grafana/api/search | head -20
```

Look for "HPA Stress Test - my-service" in the dashboard list.

**Step 5: Commit**

```bash
git add infra/grafana/dev/dashboards/hpa-stress-test.json infra/grafana/dev/values.yaml
git commit -m "feat: add Grafana dashboard for HPA stress test monitoring"
```

---

### Task 8: Run Phase 1 stress test

This task is manual. No file changes.

**Step 1: Apply all changes to cluster**

```bash
# Apply my-service changes
kubectl apply -k apps/my-service/overlays/dev -n dev-apps

# Verify pods have 2 containers (nginx + exporter)
kubectl get pods -n dev-apps -l app=my-service

# Verify HPA is reading metrics (may take ~60s)
kubectl get hpa -n dev-apps
```

**Step 2: Open monitoring (separate terminals)**

Terminal 1 - Watch HPA:
```bash
kubectl get hpa -n dev-apps -w
```

Terminal 2 - Watch pods:
```bash
kubectl get pods -n dev-apps -w
```

Terminal 3 - Open Grafana: `http://192.168.15.64/grafana/` (login: admin/admin)

**Step 3: Start stress test**

```bash
kubectl run -i --tty load-generator --rm --image=busybox:1.36 \
  --restart=Never -n dev-apps -- \
  /bin/sh -c "while true; do wget -q -O- http://my-service.dev-apps.svc; done"
```

**Step 4: Observe scaling**

- Terminal 1: CPU should climb above 50%, HPA increases desired replicas
- Terminal 2: New pods appear
- Grafana dashboard: All panels show live data

Scaling up takes 30-60 seconds after CPU exceeds target.

**Step 5: Stop and observe scale-down**

Press `Ctrl+C`. Scale-down happens after ~2 minutes (`stabilizationWindowSeconds: 120`).

---

## Phase 2: Stress Grafana + Monitor via Terminal

### Task 9: Add resource requests to Grafana and create HPA

**Files:**
- Modify: `infra/grafana/dev/values.yaml`
- Create: `infra/grafana/dev/hpa.yaml`

**Step 1: Add resources to Grafana values**

Append these lines to the end of `infra/grafana/dev/values.yaml`:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 300m
    memory: 256Mi
```

**Step 2: Create Grafana HPA manifest**

Create `infra/grafana/dev/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: grafana-hpa
  namespace: dev-monitoring
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: grafana-dev
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
      - type: Pods
        value: 2
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 120
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
```

Note: Verify the Grafana deployment name with `kubectl get deploy -n dev-monitoring`. If it's not `grafana-dev`, update the `scaleTargetRef.name`.

**Step 3: Disable ArgoCD auto-sync for Grafana during test**

```bash
kubectl patch application grafana-dev -n argocd --type merge -p '{"spec":{"syncPolicy":null}}'
```

**Step 4: Apply HPA to cluster**

```bash
kubectl apply -f infra/grafana/dev/hpa.yaml
kubectl get hpa -n dev-monitoring
```

**Step 5: Commit**

```bash
git add infra/grafana/dev/values.yaml infra/grafana/dev/hpa.yaml
git commit -m "feat: add resource limits and HPA for Grafana"
```

---

### Task 10: Run Phase 2 stress test on Grafana

This task is manual. No file changes.

**Step 1: Open monitoring terminals**

Terminal 1:
```bash
kubectl get hpa -n dev-monitoring -w
```

Terminal 2:
```bash
kubectl get pods -n dev-monitoring -w
```

**Step 2: Find Grafana service name**

```bash
kubectl get svc -n dev-monitoring | grep grafana
```

**Step 3: Start stress test**

```bash
kubectl run -i --tty grafana-load-generator --rm --image=busybox:1.36 \
  --restart=Never -n dev-monitoring -- \
  /bin/sh -c "while true; do wget -q -O- http://<GRAFANA_SVC>.dev-monitoring.svc:80/login; done"
```

Replace `<GRAFANA_SVC>` with the actual service name from step 2.

**Step 4: Observe and stop**

Watch terminals. HPA should scale Grafana when CPU > 50%. Press `Ctrl+C` to stop. Scale-down in ~2 minutes.

---

## Cleanup

### Task 11: Restore ArgoCD auto-sync

**Step 1: Re-enable auto-sync for all modified applications**

```bash
kubectl patch application grafana-dev -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'

kubectl patch application vmagent-dev -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'

kubectl patch application my-service-dev -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
```

**Step 2: Verify**

```bash
kubectl get applications -n argocd
```

Expected: All apps `Synced` and `Healthy`.

---

## File Summary

| File | Action | Purpose |
|------|--------|---------|
| **Phase 0 - Ingress** | | |
| `../ansible/setup-k3s.yml` | Modify | Install ingress-nginx controller + LB with externalTrafficPolicy: Local |
| `apps/ingress/dev/ingress.yaml` | Create | Ingress rules: /grafana, /vmagent, /vmsingle, /nginx |
| `apps/ingress/dev/kustomization.yaml` | Create | Kustomization for ingress resources |
| `argocd/dev/ingress.yaml` | Create | ArgoCD Application for ingress |
| `infra/grafana/dev/values.yaml` | Modify | Add root_url + serve_from_sub_path for /grafana |
| **Phase 1 - HPA my-service** | | |
| `apps/my-service/base/deployment.yaml` | Modify | Add resources, nginx-exporter sidecar, volume |
| `apps/my-service/base/nginx-config.yaml` | Create | nginx stub_status config for exporter |
| `apps/my-service/base/hpa.yaml` | Create | HPA 1-5 replicas, 50% CPU target |
| `apps/my-service/base/kustomization.yaml` | Modify | Add nginx-config.yaml + hpa.yaml |
| `apps/my-service/overlays/dev/patch-replicas.yaml` | Modify | Remove fixed replicas (HPA manages) |
| `apps/my-service/overlays/dev/kustomization.yaml` | Modify | Remove replicas patch |
| `infra/victoria-metrics/dev/vmagent-values.yaml` | Modify | Add nginx-exporter scrape config |
| `infra/grafana/dev/dashboards/hpa-stress-test.json` | Create | Grafana dashboard JSON |
| **Phase 2 - HPA Grafana** | | |
| `infra/grafana/dev/values.yaml` | Modify | Add resources for HPA |
| `infra/grafana/dev/hpa.yaml` | Create | HPA 1-5 replicas, 50% CPU target |

## Access Summary (after all tasks)

| Service | Ingress Path | NodePort | Namespace |
|---------|-------------|----------|-----------|
| Grafana | `http://192.168.15.64/grafana/` | - | dev-monitoring |
| VMAgent | `http://192.168.15.64/vmagent/` | - | dev-monitoring |
| VictoriaMetrics | `http://192.168.15.64/vmsingle/` | - | dev-monitoring |
| my-service (nginx) | `http://192.168.15.64/nginx/` | `http://192.168.15.64:30081` | dev-apps |
| ArgoCD | - | `https://192.168.15.64:30080` | argocd |
