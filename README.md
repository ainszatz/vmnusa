# Nusabackup VM Monitoring

Sistem monitoring terpusat untuk VM di lingkungan Proxmox milik Nusabackup — mencakup resource VM, status job backup, kapasitas storage, dan service health, dengan dashboard terpusat dan alerting dini.

Spesifikasi lengkap: [`PRD_Monitoring_VM_Nusabackup.md`](PRD_Monitoring_VM_Nusabackup.md). Panduan kerja untuk Claude Code: [`CLAUDE.md`](CLAUDE.md).

## Stack

- **Prometheus** — metrics collection
- **Grafana** — dashboard & visualisasi
- **Alertmanager** — routing & notifikasi alert (Telegram)
- **node_exporter** — metrik OS-level per VM
- **prometheus-pve-exporter** — metrik host/VM dari Proxmox API
- **blackbox_exporter** — probe HTTP/TCP/ICMP (belum dideploy — lihat Known Limitations)
- **Custom exporter** (Python) — status job backup, prefix metrik `nusabackup_`

## Struktur Direktori

```
.
├── PRD_Monitoring_VM_Nusabackup.md
├── docker-compose.yml
├── .env.example
├── prometheus/
│   ├── prometheus.yml
│   ├── pve.yml.example      # copy ke pve.yml (gitignored) sebelum deploy
│   └── rules/                # alerting rules (resource, storage, backup-job, service-health)
├── alertmanager/
│   └── alertmanager.yml.example   # copy ke alertmanager.yml (gitignored) sebelum deploy
├── grafana/
│   ├── dashboards/            # JSON dashboard (vm-detail, backup-job-status, storage-capacity)
│   └── provisioning/
├── exporters/
│   └── backup-job-exporter/   # custom exporter status job backup (Fase 3)
├── scripts/
│   ├── validate.sh             # validasi syntax YAML/JSON seluruh repo (Fase 6)
│   └── install.sh              # instalasi otomatis: prerequisites, kredensial, validasi, start stack
└── docs/
    ├── deployment.md
    └── handover.md             # runbook operasional & handover (Fase 6)
```

## Deploy

Cara tercepat: jalankan `bash scripts/install.sh` di monitoring VM — script ini meng-install prerequisites yang belum ada (Docker via get.docker.com, python3/PyYAML), copy template config, prompt kredensial (Grafana, Proxmox API token, Telegram bot) secara interaktif, validasi config (`promtool`/`amtool` dijalankan lewat image Docker yang sama dengan stack, tanpa perlu install terpisah), lalu `docker compose up -d`. Flag: `--yes` (skip semua konfirmasi), `--skip-start` (stop sebelum start stack), `--force` (isi ulang kredensial yang sudah ada).

Untuk langkah manual step-by-step (atau kalau installer gagal di suatu langkah), lihat [`docs/deployment.md`](docs/deployment.md).

## Handover & Validasi

Lihat [`docs/handover.md`](docs/handover.md) untuk panduan operasional, troubleshooting, cara tuning threshold, dan daftar keterbatasan yang perlu diketahui sebelum go-live. Jalankan `bash scripts/validate.sh` untuk validasi syntax semua file config sebelum deploy.

## Status Progres

| Fase | Deliverable (PRD §10) | Status |
|---|---|---|
| 1 | Setup monitoring VM + Prometheus + Grafana + Proxmox exporter | ✅ Selesai |
| 2 | Deploy node_exporter ke semua VM, dashboard resource dasar | ✅ Selesai (1 VM, self-monitoring) |
| 3 | Custom exporter status job backup + dashboard job | ✅ Selesai (exporter + dashboard; integrasi ke backup script asli menyusul) |
| 4 | Storage capacity monitoring + prediksi kapasitas | ✅ Selesai |
| 5 | Setup Alertmanager + rule threshold + integrasi Telegram | ✅ Selesai |
| 6 | Testing, tuning threshold, dokumentasi & handover | ✅ Selesai (dokumentasi + validasi; testing nyata & tuning berbasis data produksi menyusul setelah deploy) |

### Fase 1 — Setup Monitoring VM + Prometheus + Grafana + Proxmox Exporter

Selesai 2026-08-16. Dibangun: `docker-compose.yml` (prometheus + pve-exporter + grafana), `prometheus/prometheus.yml`, `prometheus/pve.yml.example`, `grafana/provisioning/**`, `docs/deployment.md`.

Catatan penting sebelum deploy ke VM nyata:
- Ganti placeholder `pve1.example.local` di `prometheus/prometheus.yml` dengan hostname/IP Proxmox asli.
- Isi `prometheus/pve.yml` (copy dari `.example`) dengan kredensial token Proxmox asli — `.env` hanya untuk kredensial Grafana, bukan Proxmox.
- `promtool check config` dan `docker compose config` belum pernah dijalankan sungguhan (tidak tersedia di sandbox pengembangan) — wajib dijalankan di monitoring VM sebelum go-live.
- Belum di-pin versi image Docker (`:latest`) — pertimbangkan pin versi sebelum produksi.

### Fase 2 — node_exporter + Dashboard Resource Dasar

Selesai 2026-08-16. Dibangun: service `node-exporter` di `docker-compose.yml`, scrape job `node` di `prometheus/prometheus.yml`, dashboard Grafana `grafana/dashboards/vm-detail.json` (CPU, memory, disk, load average, uptime).

Catatan penting:
- `node_exporter` saat ini hanya memonitor VM monitoring itu sendiri (self-monitoring) — sesuai keputusan Fase 2, bukan VM produksi terpisah. Label `vm_name: monitoring-vm` di-hardcode di `prometheus/prometheus.yml`.
- Saat VM produksi/kedua tersedia, perlu digeneralisasi: node_exporter dideploy ke VM target masing-masing, label `vm_name` per-target (bukan satu nilai statis), pertimbangkan Proxmox SD atau file-based service discovery untuk auto-discovery.
- Dashboard `vm-detail.json` belum pernah benar-benar dibuka di Grafana sungguhan (validasi hanya JSON syntax check di sandbox) — verifikasi visual wajib dilakukan di monitoring VM nyata.
- Panel "Network I/O" sengaja dihapus dari dashboard — `node-exporter` jalan di bridge network Docker sehingga metrik network yang ter-scrape adalah traffic container itu sendiri, bukan traffic VM sungguhan. Detail dan rencana perbaikan di `docs/deployment.md` (Known limitations).

### Fase 3 — Custom Backup-Job Exporter + Dashboard Job

Selesai 2026-08-16. Dibangun: exporter Python `exporters/backup-job-exporter/` (`collector.py` dengan test TDD, `main.py`, `Dockerfile`), service `backup-job-exporter` di `docker-compose.yml`, scrape job `backup` di `prometheus/prometheus.yml`, dashboard Grafana `grafana/dashboards/backup-job-status.json` (status terakhir, waktu sejak sukses, kegagalan berturut-turut, ukuran data, tren durasi).

Catatan penting:
- Exporter membaca kontrak file JSON per-job dari `exporters/backup-job-exporter/status/` (lihat `exporters/backup-job-exporter/README.md` untuk skema lengkap) — **belum terhubung ke script backup Nusabackup yang sebenarnya**. Sampai integrasi itu dibuat, dashboard Backup Job Status akan kosong.
- Metrik: `nusabackup_backup_job_status` (1=success, 0=failed, 2=running), `nusabackup_backup_job_duration_seconds`, `nusabackup_backup_job_last_success_timestamp_seconds`, `nusabackup_backup_job_consecutive_failures`, `nusabackup_backup_job_size_bytes`.
- `collector.py` punya 8 unit test (pytest) yang jalan bersih di sandbox pengembangan — build image Docker & jalan sungguhan di monitoring VM belum pernah divalidasi (tidak ada `docker` di sandbox ini).

### Fase 4 — Storage Capacity Dashboard

Selesai 2026-08-17. Dibangun: dashboard Grafana `grafana/dashboards/storage-capacity.json` (usage % per storage pool Proxmox, usage % disk VM, tren kapasitas storage pool, dan 2 panel prediksi "hari sampai penuh" berbasis regresi linear). Tidak ada exporter atau scrape job baru — metrik `pve_disk_size_bytes`/`pve_disk_usage_bytes`/`pve_storage_info` (dari job `pve`, Fase 1) dan `node_filesystem_*` (dari job `node`, Fase 2) sudah mengalir sejak fase-fase sebelumnya.

Catatan penting:
- Panel prediksi mulai menampilkan angka setelah ~1-2 menit (begitu ada 2 sample scrape), tapi estimasinya baru cukup bermakna setelah beberapa jam data terkumpul — anggap angka di jam-jam pertama sebagai noise, bukan sinyal akurat.
- Prediksi pakai regresi linear sederhana, belum memperhitungkan pola non-linear — cukup untuk early-warning kasar, bukan proyeksi presisi.
- Threshold warna panel prediksi (merah <7 hari, kuning <30 hari) adalah default yang dipilih sendiri, bukan dari PRD §7.1 — PRD hanya mengatur threshold usage % (>80% warning, >90% critical), yang sudah dipakai di panel usage.

### Fase 5 — Alertmanager + Alerting Rules + Telegram

Selesai 2026-08-17. Dibangun: `alertmanager/alertmanager.yml.example` (routing Telegram, critical repeat 15 menit, warning repeat 30 menit), 4 file rule alert di `prometheus/rules/` (`resource.yml`, `storage.yml`, `backup-job.yml`, `service-health.yml`) sesuai threshold draft PRD §7.1, service `alertmanager` di `docker-compose.yml`, dan wiring `alerting.alertmanagers` di `prometheus/prometheus.yml`.

Catatan penting:
- Eskalasi critical didekati dengan re-notifikasi tiap 15 menit (`repeat_interval`), bukan acknowledgment-tracking sungguhan -- lihat `docs/deployment.md` Known limitations.
- Service health baru mencakup `up==0` (target Prometheus reachable/tidak), belum probe HTTP/TCP endpoint sungguhan (blackbox_exporter belum dideploy).
- Threshold Memory/Disk pakai durasi "for" default 5 menit yang dipilih sendiri (PRD §7.1 tidak menspesifikasikan durasi untuk metrik-metrik itu); rule backup-job pakai `for: 0m` (durasi "terlambat" sudah baked into threshold detik-nya sendiri) -- tuning final berbasis data produksi diserahkan ke operator setelah deploy (lihat Fase 6).
- Belum pernah divalidasi dengan `promtool check rules` / `amtool check-config` sungguhan atau pesan Telegram nyata (tidak tersedia di sandbox pengembangan) -- wajib diverifikasi di monitoring VM sebelum go-live.

### Fase 6 — Handover, Dokumentasi & Validasi

Selesai 2026-08-17. Dibangun: `scripts/validate.sh` (validasi syntax YAML/JSON otomatis untuk seluruh repo), `docs/handover.md` (runbook operasional, troubleshooting, cara tuning threshold, onboarding VM/job baru, konsolidasi known limitations, dan open questions PRD §12 yang belum terjawab).

Catatan penting:
- Testing nyata (`docker compose up`, trigger alert sungguhan, cek pesan Telegram) dan tuning threshold berbasis data produksi **tidak bisa dikerjakan di sandbox pengembangan** (tidak ada `docker`/`promtool`/`amtool`/Proxmox/Telegram nyata) — ini eksplisit diserahkan ke operator setelah deploy ke monitoring VM sungguhan, bukan diklaim selesai di sini.
- 2 dari 5 open question PRD §12 masih belum terjawab: **siapa on-call/penerima alert critical**, dan **apakah butuh integrasi Loki**. Lihat `docs/handover.md` §8.
- `scripts/validate.sh` benar-benar dijalankan di sandbox ini terhadap semua file config repo dan semuanya lolos syntax check — tapi ini cuma syntax, bukan pengganti `promtool`/`amtool`/`docker compose config`.
- **Follow-up pasca-Fase 6**: `scripts/install.sh` ditambahkan untuk mengotomatisasi seluruh langkah Setup di `docs/deployment.md` (install prerequisites, copy template, prompt kredensial, validasi via `docker run` promtool/amtool, start stack). Sudah diuji alur lengkapnya di sandbox dengan `docker` yang di-stub — belum pernah dijalankan sungguhan di monitoring VM nyata (install Docker asli, `docker compose up` asli).

## Keputusan yang Sudah Dikonfirmasi

- Channel alerting: **Telegram**
- Sumber data status job backup: **custom exporter** (dibangun dari nol, bukan dari log/API existing)
- Jumlah VM saat ini: **1**
- Threshold alert: draft PRD §7.1 sudah dipakai di Fase 5; tuning final berbasis data produksi diserahkan ke operator setelah deploy (lihat Fase 6 dan `docs/handover.md` §4), bukan dikerjakan di sandbox pengembangan
- **Gap PRD yang terdeteksi di audit akhir Fase 6**: dashboard "Overview Cluster" (PRD §8, dashboard ke-4 dari 4 minimal) belum pernah dibuat di fase manapun, dan retention data metrik baru 30 hari raw tanpa tier downsampled 90 hari (PRD §9). Detail lihat `docs/handover.md` §7.
