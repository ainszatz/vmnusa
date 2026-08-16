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
   Grafana mensyaratkan `GRAFANA_ADMIN_USER` dan `GRAFANA_ADMIN_PASSWORD` terisi di `.env` — jika salah satu kosong, `docker compose up` akan langsung gagal (fail-fast) alih-alih start dengan kredensial kosong.

4. Verifikasi:
   - Prometheus: port Prometheus di-bind ke `127.0.0.1:9090` di monitoring VM (loopback-only, tidak bisa diakses langsung dari browser di komputer lain). Cara verifikasi:
     - Dari monitoring VM langsung: `curl http://127.0.0.1:9090/-/healthy` (harus mengembalikan `Prometheus Server is Healthy.`).
     - Dari komputer lain, buat SSH tunnel dulu: `ssh -L 9090:127.0.0.1:9090 user@monitoring-vm`, lalu buka `http://localhost:9090` di browser lokal → Status → Targets → pastikan job `prometheus` dan `pve` berstatus `UP`.
   - `pve-exporter` sengaja tidak di-expose ke host (tidak ada port mapping) — hanya bisa diakses lewat docker network internal oleh Prometheus. Jangan heran kalau `curl <monitoring-vm>:9221` gagal, itu memang disengaja.
   - Grafana: `http://<monitoring-vm>:3000` → login pakai `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` dari `.env` → Connections → Data sources → pastikan datasource `Prometheus` sudah otomatis terprovisioning dan status "Data source is working".

## Known limitations (Fase 1)
- Baru mencakup 1 node Proxmox (`node: pve1` hardcoded di `prometheus/prometheus.yml`) — auto-discovery multi-node menyusul saat jumlah VM bertambah.
- Alertmanager belum di-wire (target Fase 5 di PRD section 10) — `alerting.alertmanagers` di `prometheus.yml` sengaja kosong.
- node_exporter per-VM dan custom backup-job exporter belum dideploy (Fase 2 & 3).
