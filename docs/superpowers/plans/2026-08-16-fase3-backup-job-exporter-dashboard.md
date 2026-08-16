# Fase 3: Custom Backup-Job Exporter + Dashboard Job Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the custom Python exporter that exposes Nusabackup's backup-job status as Prometheus metrics, wire it into the existing Docker Compose stack and Prometheus scrape config, and add a Grafana "Backup Job Status" dashboard — completing PRD section 10 Fase 3.

**Architecture:** A standalone Python exporter (`exporters/backup-job-exporter/`) reads one JSON status file per backup job from a shared directory (per user decision this session: file-based reporting, not Pushgateway or SQLite) and exposes them as Prometheus metrics via a custom `prometheus_client` Collector that re-reads the directory on every scrape (no background thread/staleness). Backup scripts are expected to write `<job_name>.json` files into that directory after each run — the exact schema is documented as a contract in the exporter's own `README.md`, since no real nusabackup backup scheduler integration exists yet in this repo (this phase builds the exporter and its documented contract; wiring real backup scripts to write status files is future work, not part of this phase). The exporter runs as a fourth internal-only container (`backup-job-exporter:9301`) on the existing `monitoring` network, scraped by Prometheus, visualized by a new Grafana dashboard.

**Tech Stack:** Python 3, `prometheus_client`, `pytest` (TDD for the collector), Docker Compose, Prometheus, Grafana dashboard JSON.

## Global Constraints

- Custom exporter: Python, `prometheus_client` library, standard Prometheus text exposition format, metric names prefixed `nusabackup_` (CLAUDE.md) — exact names used throughout this plan: `nusabackup_backup_job_status`, `nusabackup_backup_job_duration_seconds`, `nusabackup_backup_job_last_success_timestamp_seconds`, `nusabackup_backup_job_consecutive_failures`, `nusabackup_backup_job_size_bytes`.
- `nusabackup_backup_job_status` values: `1` = success, `0` = failed, `2` = running. This mapping must be identical in the collector code, its docstrings/help text, the exporter's README contract, and the Grafana dashboard's value mappings — a mismatch anywhere is a real defect, not a style nit.
- Per-backup-job identity uses the metric label `job_name` (from the JSON file's own `job_name` field) — NOT `job`. Prometheus reserves the label `job` for the scrape config's `job_name` (this is the exact clobbering hazard Fase 1's final review caught with the `node` label on the `pve` job) — using `job_name` instead sidesteps that collision entirely.
- Exporters must not be exposed publicly (PRD §9: "exporter tidak expose ke publik, gunakan firewall/VPN") — `backup-job-exporter` gets no `ports:` mapping in `docker-compose.yml`, same pattern as `pve-exporter` and `node-exporter`.
- Dashboard Grafana must use the already-provisioned Prometheus datasource via a dashboard-level `datasource` template variable (`$datasource`), never a hardcoded UID (CLAUDE.md, and the exact pattern used in Fase 2's `vm-detail.json`).
- Config as code: dashboard JSON and exporter code are the source of truth, no manual edits outside this repo.
- This phase does NOT integrate with any real nusabackup backup scheduler, log format, or database — per the PRD's open question #2, the answer confirmed this session is "custom exporter, built from scratch." The exporter's status-file contract is the integration point; actually wiring nusabackup's real backup scripts to write to it is explicitly out of scope here and must be documented as a follow-up, not silently implied as done.
- `docker`/`promtool` are NOT available in this dev sandbox. `pytest` IS available; `prometheus_client` is NOT pre-installed — implementers must `pip install prometheus_client` (or `pip install -r exporters/backup-job-exporter/requirements.txt`) before running the collector's tests.
- Environment: 1 VM (the monitoring VM itself, self-monitoring per Fase 2's decision) — `vm_name: monitoring-vm` is the correct static label on this phase's Prometheus scrape job too, consistent with Fase 2.

---

### Task 1: `BackupJobCollector` — core metric logic (TDD)

**Files:**
- Create: `exporters/backup-job-exporter/collector.py`
- Test: `exporters/backup-job-exporter/tests/test_collector.py`

**Interfaces:**
- Produces: `BackupJobCollector(status_dir: str)` — a plain Python class (no `prometheus_client` base class needed; any object with a `.collect()` generator method works when registered with `prometheus_client.REGISTRY.register(...)`, per `prometheus_client`'s documented custom-collector pattern). `.collect()` yields 5 `GaugeMetricFamily` objects, one per metric name listed in Global Constraints, each with a single label `job_name`. Task 2's `main.py` imports and registers this class; no other task depends on its internals beyond the 5 metric names and the `job_name` label.
- Consumes: nothing from other tasks — this is pure, standalone logic.

- [ ] **Step 1: Set up the test environment**

```bash
cd exporters/backup-job-exporter 2>/dev/null || mkdir -p exporters/backup-job-exporter/tests && cd exporters/backup-job-exporter
pip install prometheus_client pytest
```

- [ ] **Step 2: Write the failing tests**

Create `exporters/backup-job-exporter/tests/test_collector.py`:

```python
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from collector import BackupJobCollector


def write_status(dir_path, filename, **fields):
    with open(dir_path / filename, "w", encoding="utf-8") as f:
        json.dump(fields, f)


def collect_samples(collector):
    samples = {}
    for family in collector.collect():
        samples[family.name] = {s.labels["job_name"]: s.value for s in family.samples}
    return samples


def test_collects_successful_job(tmp_path):
    write_status(
        tmp_path, "vm-backup.json",
        job_name="vm-backup", status="success", duration_seconds=120.5,
        last_success_timestamp=1755000000, consecutive_failures=0, size_bytes=1073741824,
    )
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"]["vm-backup"] == 1
    assert samples["nusabackup_backup_job_duration_seconds"]["vm-backup"] == 120.5
    assert samples["nusabackup_backup_job_last_success_timestamp_seconds"]["vm-backup"] == 1755000000
    assert samples["nusabackup_backup_job_consecutive_failures"]["vm-backup"] == 0
    assert samples["nusabackup_backup_job_size_bytes"]["vm-backup"] == 1073741824


def test_collects_failed_job(tmp_path):
    write_status(
        tmp_path, "db-backup.json",
        job_name="db-backup", status="failed", duration_seconds=30,
        last_success_timestamp=1754900000, consecutive_failures=3, size_bytes=0,
    )
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"]["db-backup"] == 0
    assert samples["nusabackup_backup_job_consecutive_failures"]["db-backup"] == 3


def test_collects_running_job(tmp_path):
    write_status(
        tmp_path, "vm-backup.json",
        job_name="vm-backup", status="running", duration_seconds=0,
        last_success_timestamp=1754900000, consecutive_failures=0, size_bytes=0,
    )
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"]["vm-backup"] == 2


def test_multiple_jobs_produce_multiple_series(tmp_path):
    write_status(tmp_path, "a.json", job_name="a", status="success", duration_seconds=1,
                 last_success_timestamp=1, consecutive_failures=0, size_bytes=1)
    write_status(tmp_path, "b.json", job_name="b", status="failed", duration_seconds=1,
                 last_success_timestamp=1, consecutive_failures=1, size_bytes=1)
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert set(samples["nusabackup_backup_job_status"].keys()) == {"a", "b"}


def test_missing_status_dir_yields_no_series(tmp_path):
    missing_dir = tmp_path / "does-not-exist"
    collector = BackupJobCollector(str(missing_dir))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_malformed_json_is_skipped_not_crashed(tmp_path):
    (tmp_path / "broken.json").write_text("{not valid json", encoding="utf-8")
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_missing_required_field_is_skipped(tmp_path):
    write_status(tmp_path, "incomplete.json", job_name="x", status="success")
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_invalid_status_value_is_skipped(tmp_path):
    write_status(tmp_path, "bad-status.json", job_name="x", status="unknown",
                 duration_seconds=1, last_success_timestamp=1, consecutive_failures=0, size_bytes=1)
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}
```

- [ ] **Step 3: Run tests, confirm they fail with `ModuleNotFoundError` (no `collector.py` yet)**

Run: `cd exporters/backup-job-exporter && python3 -m pytest tests/ -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'collector'` (or import error), because `collector.py` doesn't exist yet.

- [ ] **Step 4: Implement `collector.py`**

Create `exporters/backup-job-exporter/collector.py`:

```python
import json
import logging
from pathlib import Path

from prometheus_client.core import GaugeMetricFamily

logger = logging.getLogger(__name__)

REQUIRED_FIELDS = {
    "job_name",
    "status",
    "duration_seconds",
    "last_success_timestamp",
    "consecutive_failures",
    "size_bytes",
}
STATUS_VALUES = {"failed": 0, "success": 1, "running": 2}


class BackupJobCollector:
    """Reads one JSON status file per backup job from status_dir and exposes
    them as nusabackup_backup_job_* Prometheus gauges. Re-reads the
    directory on every collect() call, so it is always current as of the
    last Prometheus scrape, with no background thread or caching."""

    def __init__(self, status_dir):
        self.status_dir = Path(status_dir)

    def collect(self):
        status = GaugeMetricFamily(
            "nusabackup_backup_job_status",
            "Status job backup terakhir (1=success, 0=failed, 2=running)",
            labels=["job_name"],
        )
        duration = GaugeMetricFamily(
            "nusabackup_backup_job_duration_seconds",
            "Durasi eksekusi job backup terakhir, dalam detik",
            labels=["job_name"],
        )
        last_success = GaugeMetricFamily(
            "nusabackup_backup_job_last_success_timestamp_seconds",
            "Unix timestamp job backup terakhir sukses (0 jika belum pernah sukses)",
            labels=["job_name"],
        )
        consecutive_failures = GaugeMetricFamily(
            "nusabackup_backup_job_consecutive_failures",
            "Jumlah kegagalan berturut-turut job backup",
            labels=["job_name"],
        )
        size = GaugeMetricFamily(
            "nusabackup_backup_job_size_bytes",
            "Ukuran data yang di-backup pada eksekusi terakhir, dalam bytes",
            labels=["job_name"],
        )

        for record in self._read_status_records():
            job_name = record["job_name"]
            status.add_metric([job_name], STATUS_VALUES[record["status"]])
            duration.add_metric([job_name], record["duration_seconds"])
            last_success.add_metric([job_name], record["last_success_timestamp"])
            consecutive_failures.add_metric([job_name], record["consecutive_failures"])
            size.add_metric([job_name], record["size_bytes"])

        yield status
        yield duration
        yield last_success
        yield consecutive_failures
        yield size

    def _read_status_records(self):
        if not self.status_dir.is_dir():
            logger.warning("status_dir %s does not exist", self.status_dir)
            return

        for path in sorted(self.status_dir.glob("*.json")):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    record = json.load(f)
            except (json.JSONDecodeError, OSError) as exc:
                logger.warning("skipping %s: %s", path, exc)
                continue

            missing = REQUIRED_FIELDS - record.keys()
            if missing:
                logger.warning("skipping %s: missing fields %s", path, sorted(missing))
                continue

            if record["status"] not in STATUS_VALUES:
                logger.warning("skipping %s: invalid status %r", path, record["status"])
                continue

            yield record
```

- [ ] **Step 5: Run tests, confirm they pass**

Run: `cd exporters/backup-job-exporter && python3 -m pytest tests/ -v`
Expected: PASS — all 8 tests green, pristine output (no warnings printed to stdout by pytest itself; the collector's own `logger.warning` calls in the malformed/missing-field/invalid-status tests are expected and fine — they go to Python's logging system, not pytest failure output).

- [ ] **Step 6: Commit**

```bash
git add exporters/backup-job-exporter/collector.py exporters/backup-job-exporter/tests/test_collector.py
git commit -m "feat: add BackupJobCollector with TDD coverage for backup-job-exporter"
```

---

### Task 2: Exporter entrypoint, packaging, and status-file contract docs

**Files:**
- Create: `exporters/backup-job-exporter/main.py`
- Create: `exporters/backup-job-exporter/requirements.txt`
- Create: `exporters/backup-job-exporter/Dockerfile`
- Create: `exporters/backup-job-exporter/README.md`
- Create: `exporters/backup-job-exporter/status/.gitkeep`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `BackupJobCollector` from Task 1 (`from collector import BackupJobCollector`).
- Produces: a runnable exporter listening on port `9301` (env var `EXPORTER_PORT`, default `9301`) reading from `/status` inside the container (env var `STATUS_DIR`, default `/status`) — these are the exact values Task 3's `docker-compose.yml` service definition must match.

- [ ] **Step 1: Create `exporters/backup-job-exporter/requirements.txt`**

```
prometheus_client>=0.20,<1.0
```

- [ ] **Step 2: Create `exporters/backup-job-exporter/main.py`**

```python
import argparse
import logging
import os
import time

from prometheus_client import REGISTRY, start_http_server

from collector import BackupJobCollector

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def main():
    parser = argparse.ArgumentParser(description="Nusabackup backup-job status exporter")
    parser.add_argument("--port", type=int, default=int(os.environ.get("EXPORTER_PORT", "9301")))
    parser.add_argument("--status-dir", default=os.environ.get("STATUS_DIR", "/status"))
    args = parser.parse_args()

    REGISTRY.register(BackupJobCollector(args.status_dir))
    start_http_server(args.port)
    logging.info(
        "backup-job-exporter listening on :%d, reading status from %s",
        args.port, args.status_dir,
    )

    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Create `exporters/backup-job-exporter/Dockerfile`**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py collector.py ./
ENV STATUS_DIR=/status
ENV EXPORTER_PORT=9301
EXPOSE 9301
CMD ["python", "main.py"]
```

- [ ] **Step 4: Create `exporters/backup-job-exporter/README.md`**

```markdown
# backup-job-exporter

Custom Prometheus exporter untuk status job backup Nusabackup. Baca satu file JSON per job dari sebuah direktori (`STATUS_DIR`, default `/status` di dalam container) dan expose sebagai metrik Prometheus di `:9301/metrics`.

**Status integrasi:** exporter ini BELUM terhubung ke scheduler/log backup Nusabackup yang sebenarnya. Kontrak file JSON di bawah ini adalah titik integrasi yang harus dipenuhi oleh script backup — menghubungkan script backup asli ke kontrak ini adalah pekerjaan lanjutan, bukan bagian dari fase ini.

## Kontrak file status

Setiap job backup menulis satu file `<job_name>.json` ke `STATUS_DIR` setelah tiap eksekusi (baik sukses maupun gagal). Contoh:

```json
{
  "job_name": "vm-web01-daily",
  "status": "success",
  "duration_seconds": 842.3,
  "last_success_timestamp": 1755331200,
  "consecutive_failures": 0,
  "size_bytes": 5368709120
}
```

| Field | Tipe | Keterangan |
|---|---|---|
| `job_name` | string | Identitas unik job backup. Jadi label `job_name` di semua metrik (bukan label `job` — itu reserved oleh Prometheus untuk nama scrape job). |
| `status` | string | `"success"`, `"failed"`, atau `"running"`. Nilai lain akan diabaikan (dicatat sebagai warning di log exporter, file tidak crash exporter). |
| `duration_seconds` | number | Durasi eksekusi terakhir, detik. |
| `last_success_timestamp` | number | Unix timestamp (detik) sukses terakhir. Isi `0` jika job belum pernah sukses — field ini harus tetap ada meskipun status saat ini bukan `success`. |
| `consecutive_failures` | number | Jumlah kegagalan berturut-turut sampai saat ini. Reset ke `0` setelah sukses. |
| `size_bytes` | number | Ukuran data yang di-backup pada eksekusi terakhir, bytes. |

Semua field wajib ada. File yang tidak valid JSON, field yang kurang, atau `status` di luar 3 nilai di atas akan di-skip (bukan meng-crash exporter) — dicatat sebagai warning di log.

**Rekomendasi**: script backup menulis ke file temporary lalu `rename()` ke `<job_name>.json` (atomic write) supaya exporter tidak pernah membaca file yang sedang setengah ditulis.

## Metrik yang di-expose

- `nusabackup_backup_job_status{job_name="..."}` — `1`=success, `0`=failed, `2`=running
- `nusabackup_backup_job_duration_seconds{job_name="..."}`
- `nusabackup_backup_job_last_success_timestamp_seconds{job_name="..."}`
- `nusabackup_backup_job_consecutive_failures{job_name="..."}`
- `nusabackup_backup_job_size_bytes{job_name="..."}`

## Jalankan lokal

```bash
pip install -r requirements.txt
STATUS_DIR=./status python3 main.py
curl http://localhost:9301/metrics
```
```

- [ ] **Step 5: Create the runtime status directory placeholder**

Create `exporters/backup-job-exporter/status/.gitkeep` (empty file) — this is the directory that gets bind-mounted into the container in Task 3; actual `*.json` status files written into it at runtime should not be committed.

- [ ] **Step 6: Update `.gitignore`**

Read the current `.gitignore` first, then add these two lines (don't duplicate if something equivalent already exists):

```gitignore
# backup-job-exporter runtime status files (not the .gitkeep placeholder)
exporters/backup-job-exporter/status/*.json
```

- [ ] **Step 7: Sanity-check the entrypoint imports correctly**

Run: `cd exporters/backup-job-exporter && python3 -c "import ast; ast.parse(open('main.py').read())"` (syntax check only — do not actually start the HTTP server in this sandbox since nothing needs to scrape it here).
Expected: no output, exit code 0.

- [ ] **Step 8: Commit**

```bash
git add exporters/backup-job-exporter/main.py exporters/backup-job-exporter/requirements.txt exporters/backup-job-exporter/Dockerfile exporters/backup-job-exporter/README.md exporters/backup-job-exporter/status/.gitkeep .gitignore
git commit -m "feat: add backup-job-exporter entrypoint, Dockerfile, and status-file contract docs"
```

---

### Task 3: Add `backup-job-exporter` service to `docker-compose.yml`

**Files:**
- Modify: `docker-compose.yml`

**Interfaces:**
- Consumes: `exporters/backup-job-exporter/` (Tasks 1-2, built via its `Dockerfile`), bind-mounts `exporters/backup-job-exporter/status` (host) to `/status` (container) read-only.
- Produces: `backup-job-exporter:9301` reachable on the `monitoring` network — this is what Task 4's Prometheus scrape job targets.

- [ ] **Step 1: Read the current file**

Read `docker-compose.yml` in full — it currently has `prometheus`, `pve-exporter`, `node-exporter`, `grafana` services, a `monitoring` network, and `prometheus-data`/`grafana-data` volumes.

- [ ] **Step 2: Add the `backup-job-exporter` service**

Insert a new service, grouped near the other internal-only exporters (after `node-exporter` is a good spot):

```yaml
  backup-job-exporter:
    build: ./exporters/backup-job-exporter
    container_name: nusabackup-backup-job-exporter
    restart: unless-stopped
    volumes:
      - ./exporters/backup-job-exporter/status:/status:ro
    networks:
      - monitoring
```

Do not add a `ports:` block (PRD §9 constraint, same as `pve-exporter`/`node-exporter`). The `:ro` mount is intentional — the exporter only reads status files, backup scripts running elsewhere are what write them (out of scope for this container in this phase).

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add backup-job-exporter service to docker-compose stack"
```

---

### Task 4: Add `backup` scrape job to `prometheus/prometheus.yml`

**Files:**
- Modify: `prometheus/prometheus.yml`

**Interfaces:**
- Consumes: `backup-job-exporter:9301` (Task 3).
- Produces: Prometheus series labeled `job="backup"`, `vm_name="monitoring-vm"`, plus the exporter's own `job_name` label per backup job (Task 1) — this is what Task 5's dashboard queries use.

- [ ] **Step 1: Read the current file**

Read `prometheus/prometheus.yml` in full — it currently has `prometheus`, `pve`, and `node` scrape jobs. Do not touch the existing jobs.

- [ ] **Step 2: Add the `backup` scrape job**

Add a new entry under `scrape_configs`, after the `node` job:

```yaml
  - job_name: backup
    static_configs:
      - targets: ["backup-job-exporter:9301"]
        labels:
          vm_name: monitoring-vm
```

This is a plain static target, same pattern as the `node` job — the exporter is single-target (it always reports on whatever `STATUS_DIR` it's configured with), no relabeling needed. Note the Prometheus scrape-config label here is `job="backup"` (auto-assigned from `job_name: backup`) — this is a DIFFERENT label from the per-backup-job `job_name` label the exporter itself attaches to each metric series (from the JSON files' `job_name` field). Both labels coexist on the same series without conflict because they have different label keys (`job` vs `job_name`).

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('prometheus/prometheus.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add prometheus/prometheus.yml
git commit -m "feat: add backup scrape job for backup-job-exporter metrics"
```

---

### Task 5: Backup Job Status dashboard (Grafana)

**Files:**
- Create: `grafana/dashboards/backup-job-status.json`

**Interfaces:**
- Consumes: `nusabackup_backup_job_*` metrics from Task 4's `backup` scrape job, and the `Prometheus` datasource provisioned in Fase 1 (`uid: prometheus`).
- Produces: a dashboard auto-loaded by the existing Grafana file provider (folder "Nusabackup Monitoring").

- [ ] **Step 1: Create `grafana/dashboards/backup-job-status.json`**

```json
{
  "title": "Backup Job Status",
  "uid": "backup-job-status",
  "schemaVersion": 39,
  "version": 1,
  "editable": false,
  "timezone": "browser",
  "time": { "from": "now-24h", "to": "now" },
  "refresh": "1m",
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
      "title": "Status Job Terakhir",
      "type": "table",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": { "text": "Failed", "color": "red" },
                "1": { "text": "Success", "color": "green" },
                "2": { "text": "Running", "color": "blue" }
              }
            }
          ]
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "nusabackup_backup_job_status",
          "legendFormat": "{{job_name}}",
          "refId": "A",
          "format": "table",
          "instant": true
        }
      ]
    },
    {
      "id": 2,
      "title": "Waktu Sejak Sukses Terakhir",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 7200 },
              { "color": "red", "value": 21600 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "time() - nusabackup_backup_job_last_success_timestamp_seconds",
          "legendFormat": "{{job_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 3,
      "title": "Kegagalan Berturut-turut",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 1 },
              { "color": "red", "value": 2 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "nusabackup_backup_job_consecutive_failures",
          "legendFormat": "{{job_name}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 4,
      "title": "Ukuran Data Backup Terakhir",
      "type": "table",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "fieldConfig": {
        "defaults": { "unit": "bytes" },
        "overrides": []
      },
      "targets": [
        {
          "expr": "nusabackup_backup_job_size_bytes",
          "legendFormat": "{{job_name}}",
          "refId": "A",
          "format": "table",
          "instant": true
        }
      ]
    },
    {
      "id": 5,
      "title": "Tren Durasi Backup",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "$datasource" },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 16 },
      "fieldConfig": {
        "defaults": { "unit": "s" },
        "overrides": []
      },
      "targets": [
        {
          "expr": "nusabackup_backup_job_duration_seconds",
          "legendFormat": "{{job_name}}",
          "refId": "A"
        }
      ]
    }
  ]
}
```

- [ ] **Step 2: Validate JSON syntax**

Run: `python3 -c "import json; json.load(open('grafana/dashboards/backup-job-status.json'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add grafana/dashboards/backup-job-status.json
git commit -m "feat: add Backup Job Status dashboard (status, staleness, failures, size, duration trend)"
```

---

### Task 6: Update deployment docs for the backup-job-exporter

**Files:**
- Modify: `docs/deployment.md`

**Interfaces:**
- Consumes: Tasks 1-5's new exporter/service/scrape-job/dashboard.

- [ ] **Step 1: Read the current file**

Read `docs/deployment.md` in full — it currently has Prasyarat, Setup (4 numbered steps), Firewall/Akses, and Known limitations sections (already phase-neutral in heading after Fase 2's fix round).

- [ ] **Step 2: Extend the Verifikasi step**

In the Verifikasi step, update the Prometheus-targets bullet to also mention `backup`:

```markdown
   - Prometheus UI (via SSH tunnel atau `curl` di VM, lihat catatan di atas): Status → Targets → pastikan job `prometheus`, `pve`, `node`, dan `backup` semuanya `UP`.
```

Add a new bullet after the VM Detail dashboard bullet:

```markdown
   - Grafana → Dashboards → folder "Nusabackup Monitoring" → dashboard **Backup Job Status** akan kosong sampai ada file JSON status job ditulis ke `exporters/backup-job-exporter/status/` (lihat kontrak di `exporters/backup-job-exporter/README.md`) — kosong itu normal untuk instalasi baru, bukan tanda error.
```

- [ ] **Step 3: Update "Known limitations"**

Add a new bullet:

```markdown
- `backup-job-exporter` belum terhubung ke scheduler/log backup Nusabackup yang sebenarnya — exporter ini hanya membaca file JSON dari `exporters/backup-job-exporter/status/` sesuai kontrak di `exporters/backup-job-exporter/README.md`. Menghubungkan script backup Nusabackup asli untuk menulis ke direktori ini adalah pekerjaan fase berikutnya, bukan bagian dari Fase 3.
```

- [ ] **Step 4: Sanity check**

Run: `python3 -c "print(open('docs/deployment.md').read()[:200])"` and confirm it prints without error.

- [ ] **Step 5: Commit**

```bash
git add docs/deployment.md
git commit -m "docs: document backup-job-exporter verification and integration gap"
```

---

### Task 7: Update README.md progress tracker for Fase 3

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1-6's completed work, per the CLAUDE.md convention.

- [ ] **Step 1: Read the current file**

Read `README.md` in full.

- [ ] **Step 2: Update the status table**

Change the Fase 3 row from:
```markdown
| 3 | Custom exporter status job backup + dashboard job | ⬜ Belum mulai |
```
to:
```markdown
| 3 | Custom exporter status job backup + dashboard job | ✅ Selesai (exporter + dashboard; integrasi ke backup script asli menyusul) |
```

- [ ] **Step 3: Add a Fase 3 detail section**

Add after the existing "Fase 2 — ..." section, before "## Keputusan yang Sudah Dikonfirmasi":

```markdown
### Fase 3 — Custom Backup-Job Exporter + Dashboard Job

Selesai 2026-08-16. Dibangun: exporter Python `exporters/backup-job-exporter/` (`collector.py` dengan test TDD, `main.py`, `Dockerfile`), service `backup-job-exporter` di `docker-compose.yml`, scrape job `backup` di `prometheus/prometheus.yml`, dashboard Grafana `grafana/dashboards/backup-job-status.json` (status terakhir, waktu sejak sukses, kegagalan berturut-turut, ukuran data, tren durasi).

Catatan penting:
- Exporter membaca kontrak file JSON per-job dari `exporters/backup-job-exporter/status/` (lihat `exporters/backup-job-exporter/README.md` untuk skema lengkap) — **belum terhubung ke script backup Nusabackup yang sebenarnya**. Sampai integrasi itu dibuat, dashboard Backup Job Status akan kosong.
- Metrik: `nusabackup_backup_job_status` (1=success, 0=failed, 2=running), `nusabackup_backup_job_duration_seconds`, `nusabackup_backup_job_last_success_timestamp_seconds`, `nusabackup_backup_job_consecutive_failures`, `nusabackup_backup_job_size_bytes`.
- `collector.py` punya 8 unit test (pytest) yang jalan bersih di sandbox pengembangan — build image Docker & jalan sungguhan di monitoring VM belum pernah divalidasi (tidak ada `docker` di sandbox ini).
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update README progress tracker for fase 3 completion"
```

---

## Self-Review Notes

- **Spec coverage:** PRD Fase 3 deliverable = "Custom exporter status job backup + dashboard job" → Task 1 (core collector logic, TDD), Task 2 (packaging + the documented status-file contract, since PRD explicitly flags the backup-status data source as an open question that was resolved this session to "custom, file-based"), Task 3 (docker-compose wiring), Task 4 (Prometheus scrape job), Task 5 (dashboard), Tasks 6-7 (docs/README per established convention). The PRD §6.2 metric list (status, durasi, waktu sukses terakhir, retry/failure berturut-turut, ukuran data) maps 1:1 to the 5 metrics in Task 1. The gap between "exporter built" and "real backup scripts wired up" is explicitly documented in three places (exporter README, deployment.md, README.md) rather than glossed over — matching the honesty standard set in Fase 2's final review.
- **Placeholder scan:** no TBD/TODO; every step has literal file content including full Python source, Dockerfile, and dashboard JSON.
- **Type/naming consistency:** metric names (`nusabackup_backup_job_status`, etc.) identical across Task 1 (collector.py), Task 2 (README contract), Task 5 (dashboard PromQL). Status value mapping (1/0/2 = success/failed/running) identical across Task 1's `STATUS_VALUES` dict, Task 2's README table, and Task 5's dashboard value mappings — this three-way consistency is called out explicitly in Global Constraints since Fase 2's review showed exactly this kind of cross-file mismatch is the failure mode that survives per-task review. Port `9301`/env var names (`STATUS_DIR`, `EXPORTER_PORT`) match between Task 2 (Dockerfile ENV, main.py defaults) and Task 3 (docker-compose service, implicitly via the Dockerfile's own defaults — no port override needed since docker-compose doesn't publish the port, only the internal `monitoring` network needs it, and Prometheus's target `backup-job-exporter:9301` in Task 4 matches the Dockerfile's `EXPOSE 9301`/`EXPORTER_PORT` default exactly).
