# Fase 5: Alertmanager + Alerting Rules + Telegram Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Alertmanager, write Prometheus alerting rules per PRD §7.1's threshold table (one file per category per CLAUDE.md convention), and route alerts to Telegram — completing PRD section 10 Fase 5.

**Architecture:** A fourth-ish stack component, `alertmanager`, joins the existing `docker-compose.yml` stack (Prometheus, pve-exporter, node-exporter, backup-job-exporter, Grafana), bound to loopback only (same pattern as Prometheus's own UI). Prometheus evaluates rule files in `prometheus/rules/*.yml` (the glob was already wired in Fase 1; the directory has been empty until now) and pushes firing alerts to `alertmanager:9093` (Fase 1 left this target empty on purpose, wired here). Alertmanager routes `severity=critical` alerts to a Telegram receiver with a 15-minute repeat (the closest achievable approximation of PRD §7.3's "escalation if not acknowledged in 15 minutes" — this repo has no ack-tracking tool, so it re-notifies on a timer instead of truly detecting acknowledgment; documented as a known limitation, not silently implied as full escalation) and `severity=warning` alerts to the same Telegram chat with a 30-minute repeat (grouped, per PRD §7.3). Real bot credentials follow the same gitignored-real-file / committed-`.example`-template pattern established for `prometheus/pve.yml` in Fase 1.

**Tech Stack:** Alertmanager, Prometheus alerting rules (PromQL), Telegram Bot API (via Alertmanager's native `telegram_configs`).

## Global Constraints

- Alertmanager config: real file `alertmanager/alertmanager.yml` is gitignored (contains the real bot token and chat ID); `alertmanager/alertmanager.yml.example` is the committed template — same pattern as `prometheus/pve.yml` / `prometheus/pve.yml.example` from Fase 1.
- Telegram receiver schema confirmed against the real upstream Alertmanager docs this session (not guessed): `telegram_configs` fields are `bot_token`, `chat_id` (integer), `api_url` (falls back to `global.telegram_api_url` if set there instead), `parse_mode`, `message`. Route matchers use the modern `matchers: [- label="value"]` list syntax, not the deprecated `match:`/`match_re:` maps.
- Alerting rule files: one file per category in `prometheus/rules/` (CLAUDE.md) — `resource.yml` (CPU, memory), `storage.yml` (VM disk + Proxmox storage pool), `backup-job.yml` (backup status/staleness), `service-health.yml` (target-down checks). Threshold values come from PRD §7.1's draft table (per the user's earlier explicit decision: "pakai draft dulu") — do not invent different numbers.
- PRD §7.1 only specifies an explicit alert duration ("selama N menit") for CPU usage (10m warning / 5m critical) and Service down (2m) and Node Proxmox offline (immediate/0m). Memory usage, Disk usage (VM and storage pool), and the backup-job checks have no PRD-specified duration — this plan uses `for: 5m` for Memory/Disk as a reasonable default (avoids flapping on instantaneous spikes, consistent with the 80/90% thresholds already used in Fase 2/4 dashboards) and `for: 0m` for the backup-job and Proxmox-offline checks (their "duration" is effectively baked into the threshold itself — e.g. "no success in >7200s" already implies elapsed time). This is a judgment call, not a PRD-specified value — call it out as such wherever it appears, same as Fase 4's dashboard thresholds did for values PRD didn't specify.
- Service health scope decision (confirmed with the user this session): blackbox_exporter (HTTP/TCP endpoint probing, PRD §6.4) is explicitly OUT of scope for this phase — no exporter for it exists in this repo yet. `service-health.yml` instead uses Prometheus's own `up` metric (1 = last scrape succeeded, 0 = failed) as a proxy for "is this monitored target reachable" — this covers "service tidak respons" for our own exporters and stands in for "Node Proxmox offline" via `up{job="pve"}`, since pve-exporter losing contact with the Proxmox API is the closest signal this stack has to real node/API downtime. Document this substitution honestly in `docs/deployment.md`, don't imply true HTTP/TCP service monitoring exists.
- Per PRD §9 ("gunakan firewall/VPN"), Alertmanager binds to `127.0.0.1:9093:9093` on the docker-compose host port mapping — same loopback-only pattern already used for Prometheus's own UI port since Fase 1's security fix round, reachable via SSH tunnel per the existing `docs/deployment.md` instructions.
- `docker`/`promtool`/`amtool` are NOT available in this dev sandbox — validation here is YAML syntax only (`python3 -c "import yaml; yaml.safe_load(open(...))"`). Full validation (`promtool check rules`, `amtool check-config`, an actual Telegram message arriving) must happen on the real deployment host, called out in `docs/deployment.md` same as every prior phase.
- `prometheus/prometheus.yml`'s existing `pve`/`node`/`backup` scrape jobs (Fase 1-3) must not be modified by this plan except where a task explicitly says so (only the `alerting.alertmanagers` block changes).

---

### Task 1: Alertmanager config template

**Files:**
- Create: `alertmanager/alertmanager.yml.example`
- Modify: `.gitignore`

**Interfaces:**
- Produces: the template a human copies to `alertmanager/alertmanager.yml` (gitignored) before deploy, containing receivers named `telegram-critical` and `telegram-warning` — these exact receiver names are what the `route`/`routes` block in this same file references, and Task 6's `docker-compose.yml` mounts whatever file ends up at `alertmanager/alertmanager.yml`.

- [ ] **Step 1: Create `alertmanager/alertmanager.yml.example`**

```yaml
# Copy this file to alertmanager/alertmanager.yml (gitignored) and fill in real Telegram credentials.
# Do NOT commit alertmanager/alertmanager.yml.
#
# To get a bot_token: message @BotFather on Telegram, /newbot, follow prompts.
# To get a chat_id: message your new bot once, then visit
#   https://api.telegram.org/bot<TOKEN>/getUpdates
#   and read the "chat":{"id": ...} field in the response. Full steps in docs/deployment.md.

global:
  resolve_timeout: 5m
  telegram_api_url: https://api.telegram.org

route:
  receiver: telegram-warning
  group_by: ['alertname', 'vm_name']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers:
        - severity="critical"
      receiver: telegram-critical
      group_wait: 10s
      group_interval: 5m
      repeat_interval: 15m
    - matchers:
        - severity="warning"
      receiver: telegram-warning
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 30m

receivers:
  - name: telegram-critical
    telegram_configs:
      - bot_token: "changeme-bot-token"
        chat_id: 000000000
        parse_mode: HTML
        message: |
          🔴 <b>CRITICAL</b>: {{ .CommonLabels.alertname }}
          {{ range .Alerts }}{{ .Annotations.summary }}
          {{ end }}

  - name: telegram-warning
    telegram_configs:
      - bot_token: "changeme-bot-token"
        chat_id: 000000000
        parse_mode: HTML
        message: |
          🟡 <b>WARNING</b>: {{ .CommonLabels.alertname }}
          {{ range .Alerts }}{{ .Annotations.summary }}
          {{ end }}
```

- [ ] **Step 2: Update `.gitignore`**

Read the current `.gitignore` first, then add (don't duplicate if an equivalent pattern already exists):

```gitignore
alertmanager/alertmanager.yml
```

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('alertmanager/alertmanager.yml.example'))"`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add alertmanager/alertmanager.yml.example .gitignore
git commit -m "feat: add alertmanager config template with telegram routing"
```

---

### Task 2: Resource alerting rules (CPU, memory)

**Files:**
- Create: `prometheus/rules/resource.yml`

**Interfaces:**
- Consumes: `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes` from the `node` scrape job (Fase 2), all carrying the static label `vm_name="monitoring-vm"`.
- Produces: alerts `CPUUsageWarning`, `CPUUsageCritical`, `MemoryUsageWarning`, `MemoryUsageCritical`, each with label `severity` (`warning`/`critical`) — this is what Task 1's Alertmanager `matchers: [- severity="critical"]`/`severity="warning"` routes on.

- [ ] **Step 1: Create `prometheus/rules/resource.yml`**

```yaml
groups:
  - name: resource
    rules:
      - alert: CPUUsageWarning
        expr: 100 - (avg by (vm_name) (rate(node_cpu_seconds_total{job="node", mode="idle"}[5m])) * 100) > 75
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "CPU usage tinggi di {{ $labels.vm_name }} ({{ $value | printf \"%.1f\" }}%)"

      - alert: CPUUsageCritical
        expr: 100 - (avg by (vm_name) (rate(node_cpu_seconds_total{job="node", mode="idle"}[5m])) * 100) > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "CPU usage KRITIS di {{ $labels.vm_name }} ({{ $value | printf \"%.1f\" }}%)"

      - alert: MemoryUsageWarning
        expr: (1 - (node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"})) * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Memory usage tinggi di {{ $labels.vm_name }} ({{ $value | printf \"%.1f\" }}%)"

      - alert: MemoryUsageCritical
        expr: (1 - (node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"})) * 100 > 95
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Memory usage KRITIS di {{ $labels.vm_name }} ({{ $value | printf \"%.1f\" }}%)"
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('prometheus/rules/resource.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add prometheus/rules/resource.yml
git commit -m "feat: add resource alerting rules (CPU, memory)"
```

---

### Task 3: Storage alerting rules (VM disk + Proxmox storage pool)

**Files:**
- Create: `prometheus/rules/storage.yml`

**Interfaces:**
- Consumes: `node_filesystem_avail_bytes`/`node_filesystem_size_bytes` (job `node`, Fase 2) for VM disk; `pve_disk_usage_bytes`/`pve_disk_size_bytes`/`pve_storage_info` (job `pve`, Fase 1) for storage pools. The storage-pool query joins on `id` and pulls in `exported_node`/`storage` labels via `group_left` — use `exported_node`, NOT `node`, per the label-collision fix already applied in Fase 4's `storage-capacity.json` dashboard (the `pve` job's `relabel_configs` force-sets `node` to the literal `pve1`; the exporter's real node name survives only as `exported_node`).
- Produces: alerts `DiskUsageWarningVM`, `DiskUsageCriticalVM`, `StoragePoolUsageWarning`, `StoragePoolUsageCritical`, each labeled `severity`.

- [ ] **Step 1: Create `prometheus/rules/storage.yml`**

```yaml
groups:
  - name: storage
    rules:
      - alert: DiskUsageWarningVM
        expr: 100 - ((node_filesystem_avail_bytes{job="node", mountpoint="/"} / node_filesystem_size_bytes{job="node", mountpoint="/"}) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk usage VM {{ $labels.vm_name }} tinggi ({{ $value | printf \"%.1f\" }}%)"

      - alert: DiskUsageCriticalVM
        expr: 100 - ((node_filesystem_avail_bytes{job="node", mountpoint="/"} / node_filesystem_size_bytes{job="node", mountpoint="/"}) * 100) > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Disk usage VM {{ $labels.vm_name }} KRITIS ({{ $value | printf \"%.1f\" }}%)"

      - alert: StoragePoolUsageWarning
        expr: (pve_disk_usage_bytes / pve_disk_size_bytes * 100) * on(id) group_left(exported_node, storage) pve_storage_info > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Storage pool {{ $labels.exported_node }}/{{ $labels.storage }} tinggi ({{ $value | printf \"%.1f\" }}%)"

      - alert: StoragePoolUsageCritical
        expr: (pve_disk_usage_bytes / pve_disk_size_bytes * 100) * on(id) group_left(exported_node, storage) pve_storage_info > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Storage pool {{ $labels.exported_node }}/{{ $labels.storage }} KRITIS ({{ $value | printf \"%.1f\" }}%)"
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('prometheus/rules/storage.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add prometheus/rules/storage.yml
git commit -m "feat: add storage alerting rules (VM disk, proxmox storage pool)"
```

---

### Task 4: Backup-job alerting rules

**Files:**
- Create: `prometheus/rules/backup-job.yml`

**Interfaces:**
- Consumes: `nusabackup_backup_job_status`, `nusabackup_backup_job_consecutive_failures`, `nusabackup_backup_job_last_success_timestamp_seconds` (job `backup`, Fase 3), all labeled `job_name` (per-backup-job identity, NOT the Prometheus `job` label).
- Produces: alerts `BackupJobFailed`, `BackupJobFailedConsecutive`, `BackupJobLate`, `BackupJobVeryLate`, each labeled `severity`.

- [ ] **Step 1: Create `prometheus/rules/backup-job.yml`**

```yaml
groups:
  - name: backup-job
    rules:
      - alert: BackupJobFailed
        expr: nusabackup_backup_job_status == 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "Backup job {{ $labels.job_name }} gagal"

      - alert: BackupJobFailedConsecutive
        expr: nusabackup_backup_job_consecutive_failures >= 2
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Backup job {{ $labels.job_name }} gagal {{ $value }}x berturut-turut"

      - alert: BackupJobLate
        expr: (time() - nusabackup_backup_job_last_success_timestamp_seconds) > 7200
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "Backup job {{ $labels.job_name }} terlambat >2 jam dari sukses terakhir"

      - alert: BackupJobVeryLate
        expr: (time() - nusabackup_backup_job_last_success_timestamp_seconds) > 21600
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Backup job {{ $labels.job_name }} terlambat >6 jam dari sukses terakhir"
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('prometheus/rules/backup-job.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add prometheus/rules/backup-job.yml
git commit -m "feat: add backup-job alerting rules (failure, consecutive failure, staleness)"
```

---

### Task 5: Service-health alerting rules

**Files:**
- Create: `prometheus/rules/service-health.yml`

**Interfaces:**
- Consumes: Prometheus's built-in `up` metric (1 = last scrape succeeded, 0 = failed) for jobs `prometheus`, `node`, `backup`, `pve` — no new exporter needed.
- Produces: alerts `MonitoringTargetDown`, `ProxmoxUnreachable`, each labeled `severity: critical` (PRD §7.1 has no `warning` row for either service-down or node-offline — both are critical-only).

- [ ] **Step 1: Create `prometheus/rules/service-health.yml`**

```yaml
groups:
  - name: service-health
    rules:
      - alert: MonitoringTargetDown
        expr: up{job=~"prometheus|node|backup"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Target monitoring {{ $labels.job }} ({{ $labels.instance }}) tidak merespons >2 menit"

      - alert: ProxmoxUnreachable
        expr: up{job="pve"} == 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "pve-exporter tidak bisa menjangkau Proxmox API -- node Proxmox atau API mungkin down (immediate, PRD 7.1)"
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('prometheus/rules/service-health.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add prometheus/rules/service-health.yml
git commit -m "feat: add service-health alerting rules (target down, proxmox unreachable)"
```

---

### Task 6: Wire Alertmanager into docker-compose.yml and prometheus.yml

**Files:**
- Modify: `docker-compose.yml`
- Modify: `prometheus/prometheus.yml`

**Interfaces:**
- Consumes: `alertmanager/alertmanager.yml` (Task 1, human-created from `.example` before real deploy — bind-mounted, same pattern as `prometheus/pve.yml`).
- Produces: `alertmanager:9093` reachable on the `monitoring` network from Prometheus; `prometheus/prometheus.yml`'s `alerting.alertmanagers.static_configs.targets` populated (was intentionally left `[]` in Fase 1).

- [ ] **Step 1: Read both current files**

Read `docker-compose.yml` and `prometheus/prometheus.yml` in full.

- [ ] **Step 2: Add the `alertmanager` service to `docker-compose.yml`**

Insert a new service (position: anywhere reasonable, e.g. right after `prometheus`):

```yaml
  alertmanager:
    image: prom/alertmanager:latest
    container_name: nusabackup-alertmanager
    restart: unless-stopped
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager-data:/alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
    ports:
      - "127.0.0.1:9093:9093"
    networks:
      - monitoring
```

Add `alertmanager-data:` to the `volumes:` section at the bottom of the file (alongside the existing `prometheus-data:`/`grafana-data:`).

Add `alertmanager` to the `prometheus` service's existing `depends_on:` list (Prometheus already depends on `pve-exporter`; add `alertmanager` alongside it, since Prometheus pushes alerts there).

- [ ] **Step 3: Update `prometheus/prometheus.yml`'s alerting block**

Change:
```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets: []
          # Alertmanager wiring lands in Fase 5 (PRD section 10) — left empty for now.
```
to:
```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
```

Do not touch any `scrape_configs` entries (`prometheus`, `pve`, `node`, `backup` jobs stay exactly as they are).

- [ ] **Step 4: Validate YAML syntax of both files**

Run: `python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml')); yaml.safe_load(open('prometheus/prometheus.yml'))"`
Expected: no output, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml prometheus/prometheus.yml
git commit -m "feat: wire alertmanager into docker-compose stack and prometheus alerting config"
```

---

### Task 7: Update deployment docs for Alertmanager and Telegram

**Files:**
- Modify: `docs/deployment.md`

**Interfaces:**
- Consumes: Tasks 1-6's new component, rules, and wiring.

- [ ] **Step 1: Read the current file**

Read `docs/deployment.md` in full — it currently has Prasyarat, Setup (4 numbered steps), Firewall/Akses, and Known limitations sections.

- [ ] **Step 2: Extend "Prasyarat"**

Add a bullet:

```markdown
- Bot Telegram sudah dibuat: chat @BotFather di Telegram, kirim `/newbot`, ikuti instruksi, simpan bot token yang diberikan. Untuk chat_id: kirim 1 pesan apa saja ke bot yang baru dibuat, lalu buka `https://api.telegram.org/bot<TOKEN>/getUpdates` di browser dan cari field `"chat":{"id": ...}` di response JSON-nya.
```

- [ ] **Step 3: Extend Setup step 1 (copy templates)**

Add a line to the existing `cp` commands in Setup step 1:

```bash
cp alertmanager/alertmanager.yml.example alertmanager/alertmanager.yml
```

And a sentence noting: edit `alertmanager/alertmanager.yml` dengan bot token dan chat_id Telegram asli (dua tempat: receiver `telegram-critical` dan `telegram-warning`).

- [ ] **Step 4: Extend the Verifikasi step**

Add bullets after the existing dashboard verification bullets:

```markdown
   - Alertmanager UI (via SSH tunnel, sama seperti Prometheus: `ssh -L 9093:127.0.0.1:9093 user@monitoring-vm` lalu buka `http://localhost:9093`): pastikan halaman Status menampilkan config ter-load tanpa error, dan halaman utama tidak menampilkan silence/alert yang tidak diharapkan.
   - Prometheus UI → Alerts: pastikan semua rule group (`resource`, `storage`, `backup-job`, `service-health`) ter-load tanpa error merah. Rule yang statusnya "inactive" itu normal — artinya kondisi alert belum terpenuhi.
   - Test kirim alert manual (opsional tapi disarankan sebelum go-live): `docker compose exec alertmanager amtool alert add alertname=TestAlert severity=warning --alertmanager.url=http://localhost:9093` lalu cek pesan masuk ke Telegram dalam ~30 detik (sesuai `group_wait`).
```

- [ ] **Step 5: Update "Firewall / Akses"**

Add a bullet noting Alertmanager's port 9093 is also loopback-only (same treatment as Prometheus's 9090), consistent with the existing section's guidance — read the existing wording first and match its style/format exactly.

- [ ] **Step 6: Update "Known limitations"**

Add these bullets:

```markdown
- Eskalasi alert critical yang belum di-acknowledge dalam 15 menit (PRD §7.3) didekati dengan `repeat_interval: 15m` di Alertmanager (alert critical dikirim ulang tiap 15 menit selama masih firing) -- ini BUKAN eskalasi sungguhan berbasis acknowledgment, karena stack ini belum punya tool tracking-ack (mis. Karma, PagerDuty, dsb). Operator harus menganggap "pesan Telegram yang sama datang lagi" sebagai sinyal belum ditangani, bukan mengandalkan sistem untuk tahu itu.
- Service health hanya dicek lewat metrik `up` (target Prometheus reachable atau tidak) untuk exporter yang sudah ada (`prometheus`, `pve`, `node`, `backup`) -- BUKAN probe HTTP/TCP endpoint service sungguhan (PRD §6.4 minta blackbox_exporter, belum dideploy di fase manapun). "Node Proxmox offline" didekati lewat `up{job="pve"}==0` (pve-exporter gagal reach Proxmox API), yang tidak bisa membedakan node down vs API down vs pve-exporter container sendiri yang bermasalah.
- Semua threshold di `prometheus/rules/*.yml` pakai nilai draft PRD §7.1 -- untuk Memory usage, Disk usage, dan rule backup-job, PRD tidak menspesifikasikan durasi "for" (hanya CPU, service down, dan node offline yang eksplisit) -- durasi 5 menit untuk Memory/Disk adalah default yang dipilih sendiri, bukan dari PRD. Tuning threshold final adalah pekerjaan Fase 6.
```

- [ ] **Step 7: Sanity check**

Run: `python3 -c "print(open('docs/deployment.md').read()[:200])"` and confirm it prints without error.

- [ ] **Step 8: Commit**

```bash
git add docs/deployment.md
git commit -m "docs: document alertmanager setup, telegram bot creation, and alerting limitations"
```

---

### Task 8: Update README.md progress tracker for Fase 5

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1-7's completed work, per the CLAUDE.md convention.

- [ ] **Step 1: Read the current file**

Read `README.md` in full, including the "Struktur Direktori" tree (check whether `alertmanager/` still carries a stale "belum ada" comment that needs updating, per the pattern caught in Fase 3's Task 6 and Fase 4's Task 3 reviews) and the "Keputusan yang Sudah Dikonfirmasi" section (the "Threshold alert: pakai draft di PRD §7.1 dulu, akan disesuaikan di Fase 5/6" line may need a small update now that Fase 5 has actually consumed that draft).

- [ ] **Step 2: Update the status table**

Change the Fase 5 row from:
```markdown
| 5 | Setup Alertmanager + rule threshold + integrasi Telegram | ⬜ Belum mulai |
```
to:
```markdown
| 5 | Setup Alertmanager + rule threshold + integrasi Telegram | ✅ Selesai |
```

- [ ] **Step 3: Fix the "Struktur Direktori" tree if stale**

If the tree's `alertmanager/` line has a comment like `# belum ada` or similar implying it doesn't exist yet, update it to reflect that `alertmanager/alertmanager.yml.example` now exists there, matching the style of the `exporters/` line fixed in Fase 4.

- [ ] **Step 4: Add a Fase 5 detail section**

Add after the existing "Fase 4 — ..." section, before "## Keputusan yang Sudah Dikonfirmasi":

```markdown
### Fase 5 — Alertmanager + Alerting Rules + Telegram

Selesai 2026-08-17. Dibangun: `alertmanager/alertmanager.yml.example` (routing Telegram, critical repeat 15 menit, warning repeat 30 menit), 4 file rule alert di `prometheus/rules/` (`resource.yml`, `storage.yml`, `backup-job.yml`, `service-health.yml`) sesuai threshold draft PRD §7.1, service `alertmanager` di `docker-compose.yml`, dan wiring `alerting.alertmanagers` di `prometheus/prometheus.yml`.

Catatan penting:
- Eskalasi critical didekati dengan re-notifikasi tiap 15 menit (`repeat_interval`), bukan acknowledgment-tracking sungguhan -- lihat `docs/deployment.md` Known limitations.
- Service health baru mencakup `up==0` (target Prometheus reachable/tidak), belum probe HTTP/TCP endpoint sungguhan (blackbox_exporter belum dideploy).
- Threshold Memory/Disk/backup-job pakai durasi "for" default 5 menit yang dipilih sendiri (PRD §7.1 tidak menspesifikasikan durasi untuk metrik-metrik itu) -- tuning final menyusul di Fase 6.
- Belum pernah divalidasi dengan `promtool check rules` / `amtool check-config` sungguhan atau pesan Telegram nyata (tidak tersedia di sandbox pengembangan) -- wajib diverifikasi di monitoring VM sebelum go-live.
```

- [ ] **Step 5: Update "Keputusan yang Sudah Dikonfirmasi" if needed**

If the existing "Threshold alert: pakai draft di PRD §7.1 dulu, akan disesuaikan di Fase 5/6" line reads oddly now that Fase 5 is done, adjust it minimally (e.g. "sudah dipakai di Fase 5, tuning final di Fase 6") — read the current exact wording first before editing, keep the change small.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: update README progress tracker for fase 5 completion"
```

---

## Self-Review Notes

- **Spec coverage:** PRD Fase 5 deliverable = "Setup Alertmanager + rule threshold + integrasi channel notifikasi" → Task 1 (Alertmanager config + Telegram receivers), Tasks 2-5 (all 4 rule categories from CLAUDE.md's file-per-category convention, covering every row of PRD §7.1's threshold table except blackbox-exporter-dependent HTTP/TCP probing, which was explicitly scoped out by the user this session), Task 6 (wiring into the stack), Tasks 7-8 (docs/README per established convention). PRD §7.3's routing requirements (critical immediate+escalation, warning grouped/interval, silencing) are covered: immediate delivery via `group_wait: 10s` on the critical route, escalation approximated via `repeat_interval: 15m` (documented as an approximation, not true ack-tracking), warning grouped via `group_interval`/`repeat_interval: 30m`, silencing is native Alertmanager functionality requiring no extra config (mentioned in docs).
- **Placeholder scan:** no TBD/TODO; every step has literal file content including full YAML for the Alertmanager config and all 4 rule files.
- **Type/naming consistency:** `severity: warning`/`severity: critical` labels are used identically across all 4 rule files (Tasks 2-5) and match exactly what Task 1's Alertmanager `matchers: [- severity="critical"]`/`severity="warning"` route on — this label-name consistency across files is exactly the kind of cross-file check that broke a prior phase when missed. Receiver names `telegram-critical`/`telegram-warning` are defined and referenced only within Task 1's single file, so no cross-task drift risk there. The `exported_node` (not `node`) label fix from Fase 4's dashboard is carried into Task 3's storage-pool alert rules for consistency — using `node` there would silently alert with the wrong node name once a second Proxmox node exists, the same class of bug Fase 4's final review caught.
