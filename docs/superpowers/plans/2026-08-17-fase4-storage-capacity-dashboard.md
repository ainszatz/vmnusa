# Fase 4: Storage Capacity Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Grafana "Storage Capacity" dashboard covering Proxmox storage pool usage/trend and VM disk usage, plus a linear-regression-based "days until full" projection for both — completing PRD section 10 Fase 4.

**Architecture:** No new exporter or scrape job is needed. Confirmed via the upstream `prometheus-pve-exporter` documentation (github.com/prometheus-pve/prometheus-pve-exporter) that its "resources" collector — which produces `pve_disk_size_bytes`, `pve_disk_usage_bytes`, and the joinable `pve_storage_info` metric — is enabled by default and is NOT disabled anywhere in this repo's `docker-compose.yml` (the `pve-exporter` service has no `command:` override, so it runs with the image's default flags). These metrics have been flowing into Prometheus since Fase 1's `pve` scrape job. VM-level disk metrics (`node_filesystem_size_bytes`/`node_filesystem_avail_bytes`) have been flowing since Fase 2's `node` scrape job. This phase is purely a new dashboard JSON file plus docs updates.

**Tech Stack:** Grafana dashboard JSON, PromQL (including `deriv()` for linear-trend projection).

## Global Constraints

- Dashboard Grafana must use the already-provisioned Prometheus datasource via the `$datasource` template variable, never a hardcoded UID (CLAUDE.md, same pattern as `vm-detail.json` and `backup-job-status.json`).
- `pve_disk_size_bytes` and `pve_disk_usage_bytes` carry only the `id` label (e.g. `storage/proxmox/local`) — they do NOT carry `node`/`storage` labels directly. To get human-readable node/storage-pool names, PromQL must join them with `pve_storage_info` (which does carry `node`, `storage`, `content`, `plugintype` labels) via `* on(id) group_left(node, storage) pve_storage_info`. This is confirmed from the upstream exporter's documented metric schema, not guessed.
- Disk usage thresholds match PRD §7.1: warning >80%, critical >90% — same steps used in Fase 2's `vm-detail.json` Disk Usage gauge, reused here for both the storage-pool and VM disk usage panels.
- "Days until full" projection uses PromQL's `deriv()` (per-second linear-regression slope over a 6h range) rather than `predict_linear()`, to produce a directly interpretable "how many days" number instead of a "predicted value at a future timestamp" that would need extra arithmetic either way. Formula derivation (verify this logic when reading/reviewing, don't just trust the plan text — it's arithmetic, not an external API contract):
  - Storage pool: `avail = size - usage`; since capacity is ~constant, `deriv(avail) ≈ -deriv(usage)`; seconds-until-full = `-avail / deriv(avail) = -avail / (-deriv(usage)) = avail / deriv(usage)`. So: `(pve_disk_size_bytes - pve_disk_usage_bytes) / deriv(pve_disk_usage_bytes[6h]) / 86400` gives days-until-full, positive when usage is growing.
  - VM disk: `node_filesystem_avail_bytes` already IS the avail metric directly, so: `-node_filesystem_avail_bytes{...} / deriv(node_filesystem_avail_bytes{...}[6h]) / 86400` (negative sign because avail shrinks as disk fills, so its derivative is negative when filling — dividing by it flips the sign back to positive days).
  - Both formulas produce negative or very large values when the disk is NOT currently trending toward full (flat or shrinking usage) — this is expected linear-regression behavior for that case, not a bug. Both panels get a `description` field explaining this so a dashboard viewer isn't confused by it.
  - Both formulas require a full 6h window of scrape history to produce any value (the `deriv()` range) — on a fresh install, these two panels will show "No data" until 6 hours have elapsed. This must be documented, not silently left for someone to discover and think it's broken.
- `docker`/`promtool`/Grafana are NOT available in this dev sandbox — validation here is JSON syntax only. Full validation (does the dashboard actually render, do the PromQL queries return sensible values against real data) must happen on the real deployment host, called out in `docs/deployment.md` same as prior phases.

---

### Task 1: Storage Capacity dashboard (Grafana)

**Files:**
- Create: `grafana/dashboards/storage-capacity.json`

**Interfaces:**
- Consumes: `pve_disk_size_bytes`, `pve_disk_usage_bytes`, `pve_storage_info` (from Fase 1's `pve` scrape job, already flowing, no changes needed), `node_filesystem_size_bytes`/`node_filesystem_avail_bytes` (from Fase 2's `node` scrape job, already flowing), and the `Prometheus` datasource (`uid: prometheus`, provisioned in Fase 1).
- Produces: a dashboard auto-loaded by the existing Grafana file provider (folder "Nusabackup Monitoring").

- [ ] **Step 1: Create `grafana/dashboards/storage-capacity.json`**

```json
{
  "title": "Storage Capacity",
  "uid": "storage-capacity",
  "schemaVersion": 39,
  "version": 1,
  "editable": false,
  "timezone": "browser",
  "time": { "from": "now-7d", "to": "now" },
  "refresh": "5m",
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
      "title": "Storage Pool Usage (%)",
      "type": "table",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 80 },
              { "color": "red", "value": 90 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "(pve_disk_usage_bytes / pve_disk_size_bytes * 100) * on(id) group_left(node, storage) pve_storage_info",
          "legendFormat": "{{node}}/{{storage}}",
          "refId": "A",
          "format": "table",
          "instant": true
        }
      ]
    },
    {
      "id": 4,
      "title": "VM Disk Usage (%)",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 80 },
              { "color": "red", "value": 90 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "100 - ((node_filesystem_avail_bytes{job=\"node\", mountpoint=\"/\"} / node_filesystem_size_bytes{job=\"node\", mountpoint=\"/\"}) * 100)",
          "legendFormat": "{{vm_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 3,
      "title": "Prediksi Hari Sampai Penuh — Storage Pool",
      "type": "stat",
      "description": "Estimasi berdasarkan regresi linear tren pemakaian 6 jam terakhir. Nilai negatif atau sangat besar berarti storage pool sedang TIDAK bertumbuh (stabil/mengecil) -- itu bukan bug, memang begitu hasil regresi linear untuk kasus tersebut. Hanya nilai positif yang bermakna sebagai estimasi waktu sampai penuh. Butuh minimal 6 jam histori scrape sebelum panel ini menampilkan data.",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "fieldConfig": {
        "defaults": {
          "unit": "d",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "yellow", "value": 7 },
              { "color": "green", "value": 30 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "((pve_disk_size_bytes - pve_disk_usage_bytes) / deriv(pve_disk_usage_bytes[6h]) / 86400) * on(id) group_left(node, storage) pve_storage_info",
          "legendFormat": "{{node}}/{{storage}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 5,
      "title": "Prediksi Hari Sampai Penuh — VM Disk",
      "type": "stat",
      "description": "Estimasi berdasarkan regresi linear tren pemakaian 6 jam terakhir. Nilai negatif atau sangat besar berarti disk VM sedang TIDAK bertumbuh (stabil/mengecil) -- itu bukan bug, memang begitu hasil regresi linear untuk kasus tersebut. Hanya nilai positif yang bermakna sebagai estimasi waktu sampai penuh. Butuh minimal 6 jam histori scrape sebelum panel ini menampilkan data.",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "fieldConfig": {
        "defaults": {
          "unit": "d",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "yellow", "value": 7 },
              { "color": "green", "value": 30 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "-node_filesystem_avail_bytes{job=\"node\", mountpoint=\"/\"} / deriv(node_filesystem_avail_bytes{job=\"node\", mountpoint=\"/\"}[6h]) / 86400",
          "legendFormat": "{{vm_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 2,
      "title": "Storage Pool Capacity Trend",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 16 },
      "fieldConfig": {
        "defaults": { "unit": "bytes" },
        "overrides": []
      },
      "targets": [
        {
          "expr": "pve_disk_usage_bytes * on(id) group_left(node, storage) pve_storage_info",
          "legendFormat": "{{node}}/{{storage}}",
          "refId": "A"
        }
      ]
    }
  ]
}
```

- [ ] **Step 2: Validate JSON syntax**

Run: `python3 -c "import json; json.load(open('grafana/dashboards/storage-capacity.json'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add grafana/dashboards/storage-capacity.json
git commit -m "feat: add Storage Capacity dashboard (pool usage, VM disk usage, days-until-full projections)"
```

---

### Task 2: Update deployment docs for storage capacity monitoring

**Files:**
- Modify: `docs/deployment.md`

**Interfaces:**
- Consumes: Task 1's new dashboard.

- [ ] **Step 1: Read the current file**

Read `docs/deployment.md` in full.

- [ ] **Step 2: Extend the Verifikasi step**

Add a new bullet after the Backup Job Status dashboard bullet:

```markdown
   - Grafana → Dashboards → folder "Nusabackup Monitoring" → dashboard **Storage Capacity** harus menampilkan data Storage Pool Usage dan VM Disk Usage segera (tidak perlu job baru — datanya sudah mengalir dari job `pve` dan `node` yang sudah ada). Panel "Prediksi Hari Sampai Penuh" butuh minimal 6 jam histori scrape sebelum menampilkan angka — kosong di 6 jam pertama setelah instalasi itu normal, bukan tanda error.
```

- [ ] **Step 3: Update "Known limitations"**

Add a new bullet:

```markdown
- Panel prediksi "Hari Sampai Penuh" di dashboard Storage Capacity pakai regresi linear sederhana (`deriv()` PromQL) atas tren 6 jam terakhir — cukup untuk early-warning kasar, tapi bisa memberi angka negatif/sangat besar saat storage sedang tidak bertumbuh (itu bukan bug) dan belum memperhitungkan pola non-linear (mis. lonjakan mendadak saat backup besar). Threshold warna (merah <7 hari, kuning <30 hari) belum ada di PRD §7.1 — dipilih sebagai default wajar, sesuaikan jika perlu.
```

- [ ] **Step 4: Sanity check**

Run: `python3 -c "print(open('docs/deployment.md').read()[:200])"` and confirm it prints without error.

- [ ] **Step 5: Commit**

```bash
git add docs/deployment.md
git commit -m "docs: document storage capacity dashboard verification and prediction caveats"
```

---

### Task 3: Update README.md progress tracker for Fase 4

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1-2's completed work, per the CLAUDE.md convention.

- [ ] **Step 1: Read the current file**

Read `README.md` in full.

- [ ] **Step 2: Update the status table**

Change the Fase 4 row from:
```markdown
| 4 | Storage capacity monitoring + prediksi kapasitas | ⬜ Belum mulai |
```
to:
```markdown
| 4 | Storage capacity monitoring + prediksi kapasitas | ✅ Selesai |
```

- [ ] **Step 3: Add a Fase 4 detail section**

Add after the existing "Fase 3 — ..." section, before "## Keputusan yang Sudah Dikonfirmasi":

```markdown
### Fase 4 — Storage Capacity Dashboard

Selesai 2026-08-17. Dibangun: dashboard Grafana `grafana/dashboards/storage-capacity.json` (usage % per storage pool Proxmox, usage % disk VM, tren kapasitas storage pool, dan 2 panel prediksi "hari sampai penuh" berbasis regresi linear). Tidak ada exporter atau scrape job baru — metrik `pve_disk_size_bytes`/`pve_disk_usage_bytes`/`pve_storage_info` (dari job `pve`, Fase 1) dan `node_filesystem_*` (dari job `node`, Fase 2) sudah mengalir sejak fase-fase sebelumnya.

Catatan penting:
- Panel prediksi butuh minimal 6 jam histori scrape sebelum menampilkan angka (kosong di awal itu normal).
- Prediksi pakai regresi linear sederhana, belum memperhitungkan pola non-linear — cukup untuk early-warning kasar, bukan proyeksi presisi.
- Threshold warna panel prediksi (merah <7 hari, kuning <30 hari) adalah default yang dipilih sendiri, bukan dari PRD §7.1 — PRD hanya mengatur threshold usage % (>80% warning, >90% critical), yang sudah dipakai di panel usage.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update README progress tracker for fase 4 completion"
```

---

## Self-Review Notes

- **Spec coverage:** PRD Fase 4 deliverable = "Storage capacity monitoring + prediksi kapasitas" → PRD §6.3's three bullets (disk usage per VM, storage pool capacity & trend, prediksi waktu disk penuh) map to Task 1's 5 panels exactly (VM Disk Usage %, Storage Pool Usage % + trend, 2 prediction panels). PRD §8's dashboard #4 "Storage Capacity — tren penggunaan storage & proyeksi kapasitas" is the dashboard title/purpose, matched exactly. No new exporter/scrape-job task was needed or invented — verified via upstream documentation research (not assumption) that the required metrics already flow from existing Fase 1/2 scrape jobs.
- **Placeholder scan:** no TBD/TODO; Task 1 has complete literal JSON content.
- **Type/naming consistency:** metric names (`pve_disk_size_bytes`, `pve_disk_usage_bytes`, `pve_storage_info`, `node_filesystem_size_bytes`, `node_filesystem_avail_bytes`) match the confirmed upstream schema and the existing `job="node"` filter convention from Fase 2. The `on(id) group_left(node, storage) pve_storage_info` join pattern is used identically in the two panels that need node/storage names (Storage Pool Usage table, Storage Pool Capacity Trend, and the prediction panel) — consistent join key (`id`) and consistent group_left labels (`node`, `storage`) across all three.
