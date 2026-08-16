# Fase 1: Setup Monitoring Stack (Prometheus + Grafana + Proxmox Exporter) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold and configure the core monitoring stack (Prometheus, Grafana, prometheus-pve-exporter) as config-as-code, deployable via Docker Compose on a dedicated monitoring VM, per PRD section 10 Fase 1.

**Architecture:** A single `docker-compose.yml` runs three containers — Prometheus (scrapes itself + pve-exporter), prometheus-pve-exporter (queries the Proxmox VE API using an API token), and Grafana (provisioned with a non-hardcoded Prometheus datasource). Secrets (Proxmox API token, Grafana admin password) live in a gitignored `.env` / `prometheus/pve.yml`, never committed — only `.example` templates are.

**Tech Stack:** Docker Compose, Prometheus, Grafana, prometheus-pve-exporter (`prompve/prometheus-pve-exporter` image), YAML.

## Global Constraints

- Config as code: no manual UI edits to Prometheus/Grafana config; everything lives in this repo (per `CLAUDE.md`).
- Secrets (Proxmox API token, Grafana admin password) must never be committed — use `.env` (gitignored), referenced via environment variables.
- Prometheus label convention: `instance`, `vm_name`, `node`, `job` (per `CLAUDE.md`).
- Grafana datasource must reference Prometheus via variable/service name, not a hardcoded UID.
- Directory layout must match the target structure in `CLAUDE.md` (`prometheus/`, `grafana/provisioning/`, etc.).
- Environment: 1 Proxmox node/VM currently (per user), so scrape config targets a single pve-exporter instance — no Proxmox SD auto-discovery yet (that's a later hardening step once more nodes exist).
- `docker` and `promtool` are NOT available in this dev sandbox — validation here is YAML-syntax-only (`python3 -c "import yaml..."`). Full validation (`docker compose config`, `promtool check config`) must be re-run by the user on the actual monitoring VM before go-live; this is called out in `docs/deployment.md`.

---

### Task 1: Repo scaffolding, gitignore, and env template

**Files:**
- Create: `.gitignore`
- Create: `.env.example`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Secrets
.env
prometheus/pve.yml

# OS/editor
.DS_Store
Thumbs.db

# Python
__pycache__/
*.pyc
.venv/
venv/
```

- [ ] **Step 2: Create `.env.example`**

```dotenv
# Proxmox VE API token (create a dedicated read-only API token in Proxmox, do NOT use root password)
PVE_API_HOST=pve.example.local
PVE_API_USER=monitoring@pve
PVE_API_TOKEN_NAME=prometheus
PVE_API_TOKEN_VALUE=changeme-uuid-token
PVE_VERIFY_SSL=false

# Grafana
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=changeme

# Prometheus internal service name (used by Grafana datasource provisioning)
PROMETHEUS_URL=http://prometheus:9090
```

- [ ] **Step 3: Verify files exist**

Run: `ls -la .gitignore .env.example`
Expected: both files listed.

- [ ] **Step 4: Commit**

```bash
git add .gitignore .env.example
git commit -m "chore: add gitignore and env template for monitoring stack"
```

---

### Task 2: Proxmox exporter config template

**Files:**
- Create: `prometheus/pve.yml.example`

**Interfaces:**
- Produces: `prometheus/pve.yml.example` — the template a human copies to `prometheus/pve.yml` (gitignored) before first deploy. The `default` cluster key here is what Task 3's `prometheus.yml` scrape job references via the exporter's `?target=` query semantics is NOT needed — prometheus-pve-exporter exposes one `/pve` endpoint per configured cluster block, and Prometheus scrapes it directly (module-based scraping like blackbox is not required for pve-exporter's default single-cluster mode).

- [ ] **Step 1: Create `prometheus/pve.yml.example`**

```yaml
# Copy this file to prometheus/pve.yml (gitignored) and fill in real credentials.
# Do NOT commit prometheus/pve.yml.
default:
  user: monitoring@pve
  token_name: prometheus
  token_value: changeme-uuid-token
  verify_ssl: false
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('prometheus/pve.yml.example'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add prometheus/pve.yml.example
git commit -m "chore: add prometheus-pve-exporter config template"
```

---

### Task 3: Prometheus main config with self-scrape and pve-exporter job

**Files:**
- Create: `prometheus/prometheus.yml`

**Interfaces:**
- Consumes: pve-exporter service exposed at `pve-exporter:9221` (set up in Task 4's `docker-compose.yml`), which itself reads `prometheus/pve.yml` (Task 2).
- Produces: Prometheus scrape target labels `job="prometheus"` and `job="pve"`, with `node` label set per PRD's Proxmox host naming convention.

- [ ] **Step 1: Create `prometheus/prometheus.yml`**

```yaml
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    environment: nusabackup

rule_files:
  - "rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets: []
          # Alertmanager wiring lands in Fase 5 (PRD section 10) — left empty for now.

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: pve
    static_configs:
      - targets: ["pve-exporter:9221"]
        labels:
          node: pve1
    metrics_path: /pve
    params:
      module: [default]
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('prometheus/prometheus.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add prometheus/prometheus.yml
git commit -m "feat: add prometheus config with self-scrape and pve-exporter job"
```

---

### Task 4: Docker Compose stack (Prometheus, pve-exporter, Grafana)

**Files:**
- Create: `docker-compose.yml`

**Interfaces:**
- Consumes: `.env` (Task 1, user-created from `.env.example`), `prometheus/prometheus.yml` (Task 3), `prometheus/pve.yml` (Task 2, user-created), `grafana/provisioning/**` (Task 5).
- Produces: three named services — `prometheus` (port 9090), `pve-exporter` (port 9221, internal), `grafana` (port 3000) — on a shared `monitoring` bridge network, so Grafana can reach Prometheus at `http://prometheus:9090` and Prometheus can reach the exporter at `http://pve-exporter:9221`.

- [ ] **Step 1: Create `docker-compose.yml`**

```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: nusabackup-prometheus
    restart: unless-stopped
    volumes:
      - ./prometheus:/etc/prometheus:ro
      - prometheus-data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=30d"
    ports:
      - "9090:9090"
    networks:
      - monitoring
    depends_on:
      - pve-exporter

  pve-exporter:
    image: prompve/prometheus-pve-exporter:latest
    container_name: nusabackup-pve-exporter
    restart: unless-stopped
    volumes:
      - ./prometheus/pve.yml:/etc/prometheus/pve.yml:ro
    environment:
      PVE_EXPORTER_CONFIG_FILE: /etc/prometheus/pve.yml
    ports:
      - "9221:9221"
    networks:
      - monitoring

  grafana:
    image: grafana/grafana:latest
    container_name: nusabackup-grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      PROMETHEUS_URL: ${PROMETHEUS_URL}
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
    ports:
      - "3000:3000"
    networks:
      - monitoring
    depends_on:
      - prometheus

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus-data:
  grafana-data:
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose stack for prometheus, pve-exporter, grafana"
```

---

### Task 5: Grafana provisioning (datasource + dashboard provider)

**Files:**
- Create: `grafana/provisioning/datasources/prometheus.yml`
- Create: `grafana/provisioning/dashboards/dashboards.yml`
- Create: `grafana/dashboards/.gitkeep`

**Interfaces:**
- Consumes: `PROMETHEUS_URL` env var (Task 1/4), injected into Grafana container environment.
- Produces: a Grafana datasource named `Prometheus` (uid `prometheus`, referenced by future dashboard JSON via `${DS_PROMETHEUS}` template variable, never a hardcoded UID), and a dashboard provider that auto-loads any JSON dropped into `grafana/dashboards/`.

- [ ] **Step 1: Create `grafana/provisioning/datasources/prometheus.yml`**

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: ${PROMETHEUS_URL}
    isDefault: true
    editable: false
```

- [ ] **Step 2: Create `grafana/provisioning/dashboards/dashboards.yml`**

```yaml
apiVersion: 1

providers:
  - name: nusabackup-dashboards
    orgId: 1
    folder: "Nusabackup Monitoring"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
```

- [ ] **Step 3: Create `grafana/dashboards/.gitkeep`**

```
```

(empty file — placeholder so the directory is tracked by git before any dashboard JSON exists; real dashboards land in Fase 2+.)

- [ ] **Step 4: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('grafana/provisioning/datasources/prometheus.yml')); yaml.safe_load(open('grafana/provisioning/dashboards/dashboards.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add grafana/provisioning grafana/dashboards
git commit -m "feat: add grafana provisioning for prometheus datasource and dashboard loader"
```

---

### Task 6: Deployment docs

**Files:**
- Create: `docs/deployment.md`

- [ ] **Step 1: Create `docs/deployment.md`**

```markdown
# Deployment — Fase 1 Monitoring Stack

## Prasyarat
- Docker + Docker Compose terpasang di monitoring VM (terpisah dari VM produksi, lihat PRD section 5).
- Proxmox API token read-only sudah dibuat: Datacenter → Permissions → API Tokens. Beri role `PVEAuditor` ke token tersebut (cukup untuk metrics, jangan pakai token dengan hak admin).

## Setup

1. Copy env template dan isi kredensial asli:
   ```bash
   cp .env.example .env
   cp prometheus/pve.yml.example prometheus/pve.yml
   ```
   Edit `.env` dan `prometheus/pve.yml` dengan host, user, token Proxmox, dan password admin Grafana. Kedua file ini di-gitignore — jangan pernah di-commit.

2. Validasi config sebelum start (di monitoring VM, bukan di sandbox dev):
   ```bash
   docker compose config
   promtool check config prometheus/prometheus.yml
   ```

3. Jalankan stack:
   ```bash
   docker compose up -d
   ```

4. Verifikasi:
   - Prometheus UI: `http://<monitoring-vm>:9090` → Status → Targets → pastikan job `prometheus` dan `pve` berstatus `UP`.
   - Grafana: `http://<monitoring-vm>:3000` → login pakai `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` dari `.env` → Connections → Data sources → pastikan datasource `Prometheus` sudah otomatis terprovisioning dan status "Data source is working".

## Known limitations (Fase 1)
- Baru mencakup 1 node Proxmox (`node: pve1` hardcoded di `prometheus/prometheus.yml`) — auto-discovery multi-node menyusul saat jumlah VM bertambah.
- Alertmanager belum di-wire (target Fase 5 di PRD section 10) — `alerting.alertmanagers` di `prometheus.yml` sengaja kosong.
- node_exporter per-VM dan custom backup-job exporter belum dideploy (Fase 2 & 3).
```

- [ ] **Step 2: Verify file exists**

Run: `ls -la docs/deployment.md`
Expected: file listed.

- [ ] **Step 3: Commit**

```bash
git add docs/deployment.md
git commit -m "docs: add fase 1 deployment guide for monitoring stack"
```

---

## Self-Review Notes

- **Spec coverage:** PRD Fase 1 deliverable = "Setup monitoring VM + Prometheus + Grafana + Proxmox exporter" → covered by Task 1 (scaffolding/secrets), Task 2 (pve-exporter config), Task 3 (Prometheus scrape config), Task 4 (compose stack tying it together), Task 5 (Grafana provisioning, non-hardcoded datasource per `CLAUDE.md`), Task 6 (deployment runbook). Alertmanager, node_exporter, custom backup exporter, and rule files are explicitly out of scope for Fase 1 per PRD section 10 phasing — left as empty/deferred with a comment in `prometheus.yml` and called out in `docs/deployment.md` so nothing is silently missing.
- **Placeholder scan:** no TBD/TODO; every step has literal file content.
- **Type/naming consistency:** service names (`prometheus`, `pve-exporter`, `grafana`) match across `docker-compose.yml` (Task 4), `prometheus.yml` target (Task 3), and `PROMETHEUS_URL` default in `.env.example` (Task 1). Datasource `uid: prometheus` matches the constraint of no hardcoded UID being used in *dashboards* (dashboards will template on this uid, not hardcode it into JSON per-dashboard).
