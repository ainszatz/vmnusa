# Nusabackup VM Monitoring

Sistem monitoring terpusat untuk VM di lingkungan Proxmox milik Nusabackup — mencakup resource VM, status job backup, kapasitas storage, dan service health, dengan dashboard terpusat dan alerting dini.

Spesifikasi lengkap: [`PRD_Monitoring_VM_Nusabackup.md`](PRD_Monitoring_VM_Nusabackup.md). Panduan kerja untuk Claude Code: [`CLAUDE.md`](CLAUDE.md).

## Stack

- **Prometheus** — metrics collection
- **Grafana** — dashboard & visualisasi
- **Alertmanager** — routing & notifikasi alert (Telegram)
- **node_exporter** — metrik OS-level per VM
- **prometheus-pve-exporter** — metrik host/VM dari Proxmox API
- **blackbox_exporter** — probe HTTP/TCP/ICMP
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
│   └── rules/                # alerting rules — kosong sampai Fase 5
├── alertmanager/              # belum ada — Fase 5
├── grafana/
│   ├── dashboards/            # JSON dashboard — kosong sampai Fase 2
│   └── provisioning/
├── exporters/                  # belum ada — Fase 3
└── docs/
    └── deployment.md
```

## Deploy

Lihat [`docs/deployment.md`](docs/deployment.md) untuk langkah setup, validasi, dan verifikasi lengkap.

## Status Progres

| Fase | Deliverable (PRD §10) | Status |
|---|---|---|
| 1 | Setup monitoring VM + Prometheus + Grafana + Proxmox exporter | ✅ Selesai |
| 2 | Deploy node_exporter ke semua VM, dashboard resource dasar | ✅ Selesai (1 VM, self-monitoring) |
| 3 | Custom exporter status job backup + dashboard job | ⬜ Belum mulai |
| 4 | Storage capacity monitoring + prediksi kapasitas | ⬜ Belum mulai |
| 5 | Setup Alertmanager + rule threshold + integrasi Telegram | ⬜ Belum mulai |
| 6 | Testing, tuning threshold, dokumentasi & handover | ⬜ Belum mulai |

### Fase 1 — Setup Monitoring VM + Prometheus + Grafana + Proxmox Exporter

Selesai 2026-08-16. Dibangun: `docker-compose.yml` (prometheus + pve-exporter + grafana), `prometheus/prometheus.yml`, `prometheus/pve.yml.example`, `grafana/provisioning/**`, `docs/deployment.md`.

Catatan penting sebelum deploy ke VM nyata:
- Ganti placeholder `pve1.example.local` di `prometheus/prometheus.yml` dengan hostname/IP Proxmox asli.
- Isi `prometheus/pve.yml` (copy dari `.example`) dan `.env` dengan kredensial token Proxmox asli.
- `promtool check config` dan `docker compose config` belum pernah dijalankan sungguhan (tidak tersedia di sandbox pengembangan) — wajib dijalankan di monitoring VM sebelum go-live.
- Belum di-pin versi image Docker (`:latest`) — pertimbangkan pin versi sebelum produksi.

### Fase 2 — node_exporter + Dashboard Resource Dasar

Selesai 2026-08-16. Dibangun: service `node-exporter` di `docker-compose.yml`, scrape job `node` di `prometheus/prometheus.yml`, dashboard Grafana `grafana/dashboards/vm-detail.json` (CPU, memory, disk, load average, uptime).

Catatan penting:
- `node_exporter` saat ini hanya memonitor VM monitoring itu sendiri (self-monitoring) — sesuai keputusan Fase 2, bukan VM produksi terpisah. Label `vm_name: monitoring-vm` di-hardcode di `prometheus/prometheus.yml`.
- Saat VM produksi/kedua tersedia, perlu digeneralisasi: node_exporter dideploy ke VM target masing-masing, label `vm_name` per-target (bukan satu nilai statis), pertimbangkan Proxmox SD atau file-based service discovery untuk auto-discovery.
- Dashboard `vm-detail.json` belum pernah benar-benar dibuka di Grafana sungguhan (validasi hanya JSON syntax check di sandbox) — verifikasi visual wajib dilakukan di monitoring VM nyata.
- Panel "Network I/O" sengaja dihapus dari dashboard — `node-exporter` jalan di bridge network Docker sehingga metrik network yang ter-scrape adalah traffic container itu sendiri, bukan traffic VM sungguhan. Detail dan rencana perbaikan di `docs/deployment.md` (Known limitations).

## Keputusan yang Sudah Dikonfirmasi

- Channel alerting: **Telegram**
- Sumber data status job backup: **custom exporter** (dibangun dari nol, bukan dari log/API existing)
- Jumlah VM saat ini: **1**
- Threshold alert: pakai draft di PRD §7.1 dulu, akan disesuaikan di Fase 5/6
