# Fase 2: node_exporter + Dashboard Resource Dasar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy `node_exporter` (via Docker Compose, on the same VM as the monitoring stack, per user decision — self-monitoring for now while only 1 VM exists) and add a basic Grafana "VM Detail" resource dashboard (CPU, memory, disk, network, load, uptime), completing PRD section 10 Fase 2.

**Architecture:** `node_exporter` runs as a fourth container in the existing `docker-compose.yml`, on the same `monitoring` network as Prometheus/Grafana/pve-exporter, exposing host metrics at `node-exporter:9100` (not published to the host, per PRD §9 "exporter tidak expose ke publik" — same pattern as `pve-exporter`). Prometheus scrapes it via a new static job. Grafana gets one new dashboard JSON file, auto-loaded by the file-based provider set up in Fase 1 (`grafana/provisioning/dashboards/dashboards.yml`), using a dashboard-level `datasource` template variable so no datasource UID is hardcoded into panels.

**Tech Stack:** Docker Compose, `prom/node-exporter` image, Prometheus, Grafana dashboard JSON (schema v39-ish, dashboard provisioning v1).

## Global Constraints

- Exporters must not be exposed publicly (PRD §9: "exporter tidak expose ke publik, gunakan firewall/VPN") — `node-exporter` gets no `ports:` mapping in `docker-compose.yml`, same as `pve-exporter`.
- Prometheus label convention: `instance`, `vm_name`, `node`, `job` (CLAUDE.md). `job` and `instance` are Prometheus defaults (job name, target address); `vm_name` and `node` are added as static labels on the scrape target.
- Dashboard Grafana must use the already-provisioned Prometheus datasource, not a hardcoded UID (CLAUDE.md) — use a dashboard-level `datasource` template variable (type `datasource`, query `prometheus`) so panels reference `$datasource` instead of a literal uid string.
- Config as code: no manual Grafana UI edits — the dashboard JSON is the source of truth, auto-loaded via the existing file provider.
- `docker` and `promtool` are NOT available in this dev sandbox — validation here is YAML/JSON syntax only (`python3 -c "import yaml/json; ..."`). Full validation (`docker compose config`, `promtool check config`, actually opening the dashboard in Grafana) must happen on the real deployment host, called out in `docs/deployment.md`.
- Current environment: 1 VM total, and per user decision for this phase, `node_exporter` runs on the *same* VM as the monitoring stack (self-monitoring) — not a separate production VM. `vm_name: monitoring-vm` is the correct static label value for this phase; a later phase (when a second, separate VM exists) will need to generalize this to per-VM values instead of one static one.

---

### Task 1: Add `node-exporter` service to `docker-compose.yml`

**Files:**
- Modify: `docker-compose.yml`

**Interfaces:**
- Consumes: existing `monitoring` network and `prometheus-data`/`grafana-data` volume declarations already in the file (from Fase 1).
- Produces: a `node-exporter` service reachable at `node-exporter:9100` from other containers on the `monitoring` network — this is the hostname/port Task 2's Prometheus scrape job targets.

- [ ] **Step 1: Read the current file**

Read `docker-compose.yml` in full before editing — it currently has three services (`prometheus`, `pve-exporter`, `grafana`), a `monitoring` network, and `prometheus-data`/`grafana-data` volumes (added across Fase 1's Task 4 and its security fix round).

- [ ] **Step 2: Add the `node-exporter` service**

Insert a new service between `pve-exporter` and `grafana` (or after `grafana`, either position is fine — keep it grouped near `pve-exporter` since both are internal-only exporters):

```yaml
  node-exporter:
    image: prom/node-exporter:latest
    container_name: nusabackup-node-exporter
    restart: unless-stopped
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"
    networks:
      - monitoring
```

Do not add a `ports:` block — this exporter is internal-network-only, same as `pve-exporter` (PRD §9 constraint). Do not add it to `depends_on` for any other service; nothing depends on it starting first.

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add node-exporter service for VM resource metrics"
```

---

### Task 2: Add `node` scrape job to `prometheus/prometheus.yml`

**Files:**
- Modify: `prometheus/prometheus.yml`

**Interfaces:**
- Consumes: `node-exporter:9100` (Task 1).
- Produces: Prometheus series labeled `job="node"`, `vm_name="monitoring-vm"`, `node="pve1"` (matching the existing `node: pve1` relabel value used by the `pve` job from Fase 1) — this is what Task 3's dashboard queries filter/group by.

- [ ] **Step 1: Read the current file**

Read `prometheus/prometheus.yml` in full — it currently has `prometheus` and `pve` scrape jobs (from Fase 1, the `pve` job already uses `relabel_configs` for its target/instance pattern — do not touch that job).

- [ ] **Step 2: Add the `node` scrape job**

Add a new entry under `scrape_configs`, after the `pve` job:

```yaml
  - job_name: node
    static_configs:
      - targets: ["node-exporter:9100"]
        labels:
          vm_name: monitoring-vm
          node: pve1
```

This is a plain static target (unlike `pve`'s relabel-based multi-target pattern) because `node_exporter` is single-target by design — it always reports on the host it runs on, so no `target` query param or relabeling is needed.

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('prometheus/prometheus.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add prometheus/prometheus.yml
git commit -m "feat: add node scrape job for node-exporter metrics"
```

---

### Task 3: VM Detail resource dashboard (Grafana)

**Files:**
- Create: `grafana/dashboards/vm-detail.json`

**Interfaces:**
- Consumes: `node_exporter` metrics scraped by Task 2's `node` job (`node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes`, `node_filesystem_avail_bytes`, `node_filesystem_size_bytes`, `node_network_receive_bytes_total`, `node_network_transmit_bytes_total`, `node_load1`, `node_boot_time_seconds`) and the `Prometheus` datasource provisioned in Fase 1 (`grafana/provisioning/datasources/prometheus.yml`, `uid: prometheus`).
- Produces: a dashboard auto-loaded by Fase 1's `grafana/provisioning/dashboards/dashboards.yml` file provider (folder "Nusabackup Monitoring") — no manual Grafana UI import needed.

- [ ] **Step 1: Create `grafana/dashboards/vm-detail.json`**

```json
{
  "title": "VM Detail",
  "uid": "vm-detail",
  "schemaVersion": 39,
  "version": 1,
  "editable": false,
  "timezone": "browser",
  "time": { "from": "now-6h", "to": "now" },
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "datasource",
        "type": "datasource",
        "query": "prometheus",
        "current": {},
        "hide": 0,
        "refresh": 1
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "CPU Usage",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] },
      "targets": [
        {
          "expr": "100 - (avg by (vm_name) (rate(node_cpu_seconds_total{job=\"node\", mode=\"idle\"}[5m])) * 100)",
          "legendFormat": "{{vm_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 2,
      "title": "Memory Usage",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] },
      "targets": [
        {
          "expr": "(1 - (node_memory_MemAvailable_bytes{job=\"node\"} / node_memory_MemTotal_bytes{job=\"node\"})) * 100",
          "legendFormat": "{{vm_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 3,
      "title": "Disk Usage (/)",
      "type": "gauge",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 8 },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100 }, "overrides": [] },
      "targets": [
        {
          "expr": "100 - ((node_filesystem_avail_bytes{job=\"node\", mountpoint=\"/\"} / node_filesystem_size_bytes{job=\"node\", mountpoint=\"/\"}) * 100)",
          "legendFormat": "{{vm_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 4,
      "title": "Load Average (1m)",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 8 },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "targets": [
        {
          "expr": "node_load1{job=\"node\"}",
          "legendFormat": "{{vm_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 5,
      "title": "Uptime",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 8 },
      "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] },
      "targets": [
        {
          "expr": "time() - node_boot_time_seconds{job=\"node\"}",
          "legendFormat": "{{vm_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 6,
      "title": "Network I/O",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 16 },
      "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] },
      "targets": [
        {
          "expr": "rate(node_network_receive_bytes_total{job=\"node\", device!=\"lo\"}[5m])",
          "legendFormat": "{{vm_name}} rx {{device}}",
          "refId": "A"
        },
        {
          "expr": "rate(node_network_transmit_bytes_total{job=\"node\", device!=\"lo\"}[5m])",
          "legendFormat": "{{vm_name}} tx {{device}}",
          "refId": "B"
        }
      ]
    }
  ]
}
```

- [ ] **Step 2: Validate JSON syntax**

Run: `python3 -c "import json; json.load(open('grafana/dashboards/vm-detail.json'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add grafana/dashboards/vm-detail.json
git commit -m "feat: add VM Detail resource dashboard (CPU, memory, disk, load, uptime, network)"
```

---

### Task 4: Update deployment docs for node_exporter

**Files:**
- Modify: `docs/deployment.md`

**Interfaces:**
- Consumes: Tasks 1-3's new service/scrape job/dashboard.

- [ ] **Step 1: Read the current file**

Read `docs/deployment.md` in full — it currently has Prasyarat, Setup (4 numbered steps), a "Firewall / Akses" section (added during Fase 1's final-review fix round), and "Known limitations".

- [ ] **Step 2: Extend the verification step**

In the "Verifikasi" step (step 4 of Setup), add a bullet after the existing Prometheus-targets bullet:

```markdown
   - Prometheus UI (via SSH tunnel atau `curl` di VM, lihat catatan di atas): Status → Targets → pastikan job `prometheus`, `pve`, dan `node` semuanya `UP`.
```

(Replace the existing targets bullet's wording if it only mentions `prometheus`/`pve` — it must now mention all three job names.)

Add a new bullet after the Grafana verification bullet:

```markdown
   - Grafana → Dashboards → folder "Nusabackup Monitoring" → dashboard **VM Detail** harus menampilkan data CPU/memory/disk/load/uptime/network dalam beberapa menit setelah stack jalan (tunggu minimal 1 scrape interval, 30 detik).
```

- [ ] **Step 3: Update "Known limitations"**

Update the bullet about node_exporter (it currently says something like "node_exporter per-VM ... belum dideploy") to reflect that it's now deployed, but only self-monitoring the same VM as the stack:

```markdown
- `node_exporter` saat ini hanya jalan di VM monitoring itu sendiri (self-monitoring, label `vm_name: monitoring-vm` hardcoded di `prometheus/prometheus.yml`) — belum di-deploy ke VM produksi terpisah. Saat VM kedua tersedia, generalisasi diperlukan: pisahkan node_exporter ke docker-compose/systemd service di VM target masing-masing, dan ganti static label `vm_name` per-target atau pakai Proxmox SD/file-based service discovery.
```

- [ ] **Step 4: Verify the file still renders as valid markdown (no broken syntax)**

Run: `python3 -c "print(open('docs/deployment.md').read()[:200])"` and confirm it prints without error (a minimal sanity check — no markdown linter available in this sandbox).

- [ ] **Step 5: Commit**

```bash
git add docs/deployment.md
git commit -m "docs: document node-exporter verification and self-monitoring limitation"
```

---

### Task 5: Update README.md progress tracker for Fase 2

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1-4's completed work, per the CLAUDE.md convention ("setiap kali sebuah fase selesai... update tabel status progres dan bagian ringkasan per-fase di README.md").

- [ ] **Step 1: Read the current file**

Read `README.md` in full — it has a "Status Progres" table and a per-phase detail section (currently only "Fase 1 — ...").

- [ ] **Step 2: Update the status table**

Change the Fase 2 row from:
```markdown
| 2 | Deploy node_exporter ke semua VM, dashboard resource dasar | ⬜ Belum mulai |
```
to:
```markdown
| 2 | Deploy node_exporter ke semua VM, dashboard resource dasar | ✅ Selesai (1 VM, self-monitoring) |
```

- [ ] **Step 3: Add a Fase 2 detail section**

Add after the existing "Fase 1 — ..." section:

```markdown
### Fase 2 — node_exporter + Dashboard Resource Dasar

Selesai 2026-08-16. Dibangun: service `node-exporter` di `docker-compose.yml`, scrape job `node` di `prometheus/prometheus.yml`, dashboard Grafana `grafana/dashboards/vm-detail.json` (CPU, memory, disk, load average, uptime, network I/O).

Catatan penting:
- `node_exporter` saat ini hanya memonitor VM monitoring itu sendiri (self-monitoring) — sesuai keputusan Fase 2, bukan VM produksi terpisah. Label `vm_name: monitoring-vm` di-hardcode di `prometheus/prometheus.yml`.
- Saat VM produksi/kedua tersedia, perlu digeneralisasi: node_exporter dideploy ke VM target masing-masing, label `vm_name` per-target (bukan satu nilai statis), pertimbangkan Proxmox SD atau file-based service discovery untuk auto-discovery.
- Dashboard `vm-detail.json` belum pernah benar-benar dibuka di Grafana sungguhan (validasi hanya JSON syntax check di sandbox) — verifikasi visual wajib dilakukan di monitoring VM nyata.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update README progress tracker for fase 2 completion"
```

---

## Self-Review Notes

- **Spec coverage:** PRD Fase 2 deliverable = "Deploy node_exporter ke semua VM, dashboard resource dasar" → Task 1 (node_exporter service), Task 2 (scrape job), Task 3 (VM Detail dashboard) cover this for the 1 VM currently in scope, per the user's explicit decision to self-monitor the monitoring VM for now rather than block on a second VM existing. Task 4/5 keep docs and README in sync per the CLAUDE.md convention established after Fase 1. The "semua VM" (all VMs) part of the PRD wording is honestly caveated as a Fase 2-scoped limitation (only 1 VM exists; self-monitoring only) rather than silently claimed as done — this is called out in both `docs/deployment.md`'s Known Limitations and README's Fase 2 detail section.
- **Placeholder scan:** no TBD/TODO; every step has literal file content, including the full dashboard JSON.
- **Type/naming consistency:** `node-exporter:9100` matches across Task 1 (service name/no exposed port) and Task 2 (scrape target). `job="node"` and `vm_name="monitoring-vm"` labels match across Task 2 (scrape config) and Task 3 (dashboard PromQL queries, which all filter `job="node"` and group/legend by `vm_name`). Datasource `uid: prometheus` (Fase 1) is referenced only via the `$datasource` template variable in Task 3, never hardcoded directly into a panel — matching the CLAUDE.md constraint and the correction the Fase 1 final reviewer already flagged once.
