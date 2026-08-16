# CLAUDE.md

Panduan ini memberi konteks kepada Claude Code saat bekerja di repository **Nusabackup VM Monitoring**.

## Ringkasan Project

Sistem monitoring terpusat untuk VM di lingkungan **Proxmox** milik Nusabackup. Mencakup 4 area: resource VM, status backup job, kapasitas storage, dan service health. Spesifikasi lengkap ada di `PRD_Monitoring_VM_Nusabackup.md` — baca file itu dulu sebelum mengerjakan task besar/baru.

## Stack Teknis

- **Prometheus** — metrics collection (scrape-based)
- **Grafana** — dashboard & visualisasi
- **Alertmanager** — routing & notifikasi alert
- **node_exporter** — metrik OS-level tiap VM (CPU, RAM, disk, network)
- **prometheus-pve-exporter** — metrik host/VM dari Proxmox API
- **blackbox_exporter** — probe HTTP/TCP/ICMP untuk service health
- **Custom exporter** (Python, format Prometheus text exposition) — status job backup, di-push ke Pushgateway atau di-scrape langsung

## Struktur Direktori (target)

```
.
├── PRD_Monitoring_VM_Nusabackup.md
├── prometheus/
│   ├── prometheus.yml
│   └── rules/              # alerting rules (.yml)
├── alertmanager/
│   └── alertmanager.yml
├── grafana/
│   ├── dashboards/         # JSON dashboard exports
│   └── provisioning/
├── exporters/
│   └── backup-job-exporter/  # custom exporter untuk status job backup
├── ansible/ atau terraform/   # (jika ada) provisioning monitoring VM & agent
└── docs/
```

## Konvensi & Aturan Kerja

- **Config as code**: semua konfigurasi Prometheus/Alertmanager/Grafana disimpan sebagai file (YAML/JSON) di repo ini, bukan diubah manual lewat UI. Perubahan lewat UI Grafana harus di-export ulang ke `grafana/dashboards/`.
- **Alerting rules**: taruh di `prometheus/rules/`, satu file per kategori (mis. `resource.yml`, `backup-job.yml`, `storage.yml`, `service-health.yml`). Threshold mengacu ke tabel di PRD (section 7.1) — jangan ubah threshold tanpa alasan yang dicatat di commit message.
- **Custom exporter**: tulis dalam Python, expose metrik dengan format Prometheus text exposition standar (gunakan library `prometheus_client`). Nama metrik pakai prefix `nusabackup_` (contoh: `nusabackup_backup_job_last_success_timestamp_seconds`, `nusabackup_backup_job_status`).
- **Secrets**: JANGAN commit credential Proxmox API, token Telegram/bot, SMTP password, dsb. Gunakan `.env` (di-gitignore) atau secret manager, referensikan lewat environment variable di config.
- **Naming label Prometheus**: gunakan label konsisten `instance`, `vm_name`, `node` (nama host Proxmox), dan `job` sesuai kategori exporter.
- **Dashboard Grafana**: setiap dashboard baru harus datasource Prometheus yang sudah diprovisioning, bukan hardcode UID datasource.

## Command yang Sering Dipakai

```bash
# Validasi syntax config Prometheus
promtool check config prometheus/prometheus.yml

# Validasi alerting rules
promtool check rules prometheus/rules/*.yml

# Test rule dengan data sample (jika ada unit test rule)
promtool test rules prometheus/rules/tests/*.yml

# Reload Prometheus tanpa restart (setelah config berubah)
curl -X POST http://localhost:9090/-/reload

# Jalankan custom exporter secara lokal untuk testing
cd exporters/backup-job-exporter && python3 main.py

# Validasi syntax Alertmanager config
amtool check-config alertmanager/alertmanager.yml
```

## Hal yang Perlu Dikonfirmasi ke User (jangan asumsikan sendiri)

- Channel alerting final (Telegram/Email/Slack/WhatsApp) — lihat Open Questions di PRD.
- Sumber data status job backup: apakah dari log file, database, atau API scheduler nusabackup. Jangan bikin asumsi format tanpa konfirmasi jika belum jelas dari kode yang ada.
- Threshold alert final — nilai di PRD adalah draft awal.

## Testing & Verifikasi Sebelum Commit

1. `promtool check config` dan `promtool check rules` harus pass.
2. Jika mengubah custom exporter, jalankan lokal dan cek output `/metrics` valid (format Prometheus, bisa di-scrape tanpa error).
3. Jika mengubah dashboard Grafana, pastikan JSON hasil export valid dan datasource pakai variable, bukan UID hardcoded.
