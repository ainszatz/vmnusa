# PRD Teknis: Sistem Monitoring VM Nusabackup

**Versi:** 1.0
**Tanggal:** 16 Agustus 2026
**Status:** Draft

---

## 1. Latar Belakang

Nusabackup menjalankan sejumlah VM di atas platform Proxmox untuk layanan backup. Saat ini belum ada sistem monitoring terpusat yang memantau kondisi resource, status job backup, kapasitas storage, dan kesehatan service secara real-time. Diperlukan sistem monitoring yang dapat memberikan visibilitas penuh dan alert dini terhadap potensi gangguan.

## 2. Tujuan (Goals)

- Memberikan visibilitas real-time terhadap kondisi seluruh VM di lingkungan Proxmox.
- Mendeteksi kegagalan atau anomali job backup sedini mungkin.
- Mencegah insiden storage penuh (disk full) sebelum berdampak ke layanan.
- Memastikan availability service-service kritis (backup agent, database, API, dsb).
- Menyediakan dashboard terpusat untuk tim ops/infra.

## 3. Non-Goals

- Tidak mencakup monitoring aplikasi level kode (APM) di fase ini.
- Tidak mencakup log management terpusat (bisa jadi fase lanjutan/terintegrasi dengan Loki).
- Tidak menggantikan backup verification tool khusus (fokus di monitoring status, bukan validasi integritas file backup).

## 4. Rekomendasi Stack

Karena preferensi tools belum ditentukan, berikut rekomendasi berdasarkan lingkungan Proxmox dan kebutuhan cakupan "full monitoring":

| Komponen | Rekomendasi | Alasan |
|---|---|---|
| Metrics collection | **Prometheus** | Open-source, native pull-based, ekosistem exporter luas, cocok untuk infra self-hosted |
| Visualisasi | **Grafana** | Dashboard fleksibel, integrasi native dengan Prometheus & Proxmox |
| Proxmox metrics | **Proxmox VE Exporter (prometheus-pve-exporter)** | Mengambil metrik host & VM langsung dari Proxmox API |
| Node-level metrics (per VM) | **node_exporter** | CPU, RAM, disk, network di level OS masing-masing VM |
| Alerting | **Alertmanager** (terhubung ke Prometheus) | Routing alert, grouping, silencing, multi-channel notifikasi |
| Backup job status | **Custom exporter / script + Pushgateway** atau **Blackbox exporter** (jika ada endpoint status) | Nusabackup kemungkinan punya job scheduler custom, perlu exporter custom untuk expose status job sebagai metrik |
| Storage capacity | **node_exporter (disk metrics) + Proxmox storage API** | Kombinasi metrik OS-level dan storage pool Proxmox |
| Uptime/service health | **Blackbox exporter** (HTTP/TCP/ICMP probe) | Cek availability service dari luar (external probe) |

**Alternatif:** Zabbix bisa dipertimbangkan jika tim lebih familiar dengan pendekatan agent-based all-in-one (built-in alerting, tanpa perlu merakit banyak exporter terpisah). Prometheus+Grafana direkomendasikan karena lebih fleksibel untuk custom metrics job backup dan lebih ringan untuk environment yang akan terus berkembang.

## 5. Arsitektur Sistem

```
┌─────────────────────────────────────────────────────────┐
│                     Proxmox Cluster                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                │
│  │  VM 1    │  │  VM 2    │  │  VM N    │                │
│  │ node_exp │  │ node_exp │  │ node_exp │                │
│  │ backup   │  │ backup   │  │ backup   │                │
│  │ exporter │  │ exporter │  │ exporter │                │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                │
│       │             │             │                        │
│  ┌────▼─────────────▼─────────────▼────┐                 │
│  │      Proxmox VE API (pve-exporter)   │                 │
│  └───────────────┬───────────────────────┘                │
└──────────────────┼─────────────────────────────────────────┘
                    │ (scrape via Prometheus, port 9090/9100/dst)
             ┌──────▼──────┐
             │  Prometheus  │◄──── Blackbox Exporter (probe endpoint)
             └──────┬───────┘
                    │
        ┌───────────┼────────────┐
        ▼                        ▼
  ┌───────────┐           ┌─────────────┐
  │  Grafana  │           │ Alertmanager│
  │ (Dashboard)│           │ (Alerting)  │
  └───────────┘           └──────┬──────┘
                                  │
                     ┌────────────┼────────────┐
                     ▼            ▼             ▼
                 Telegram      Email        Slack/WA
```

**Lokasi deployment yang disarankan:** monitoring stack (Prometheus, Grafana, Alertmanager) dijalankan di VM terpisah (dedicated monitoring VM), bukan di VM produksi, untuk isolasi resource dan menghindari single point of failure ikut terdampak jika VM produksi bermasalah.

## 6. Cakupan Monitoring (Scope: Full)

### 6.1 Resource VM
- CPU usage (%), load average
- Memory usage (used/available/cached)
- Disk I/O (read/write throughput, IOPS, latency)
- Network throughput (in/out), error/drop packet
- Uptime & reboot events

### 6.2 Status Backup Job
- Status job terakhir (success/failed/running)
- Durasi eksekusi job backup
- Waktu job backup terakhir sukses (untuk deteksi job yang "stuck"/tidak jalan)
- Jumlah retry/failure berturut-turut
- Ukuran data yang di-backup per job

### 6.3 Kapasitas Storage
- Disk usage per VM (used/total, %)
- Storage pool Proxmox (local, NFS, Ceph, dsb) - kapasitas & trend pertumbuhan
- Prediksi waktu disk penuh (berdasarkan tren pertumbuhan)

### 6.4 Service Health
- Status service kritis (backup agent, database, API service) via systemd/process check
- HTTP/TCP endpoint probe (availability & response time)
- Proxmox host & cluster health (quorum status, node online/offline)

## 7. Alerting

### 7.1 Threshold Alert (Contoh Awal, Perlu Disesuaikan)

| Metrik | Warning | Critical |
|---|---|---|
| CPU usage | >75% selama 10 menit | >90% selama 5 menit |
| Memory usage | >80% | >95% |
| Disk usage | >80% | >90% |
| Backup job gagal | 1x gagal | 2x berturut-turut gagal |
| Backup job tidak jalan | Terlambat >2 jam dari jadwal | Terlambat >6 jam |
| Service down | - | Service tidak respons >2 menit |
| Node Proxmox offline | - | Immediate |

### 7.2 Channel Notifikasi

Belum ditentukan — opsi yang tersedia di Alertmanager:
- **Telegram** — cepat, gratis, cocok untuk tim kecil/ops on-call
- **Email** — cocok untuk laporan/audit trail, kurang real-time
- **Slack/WhatsApp** — cocok jika tim sudah pakai untuk komunikasi harian

**Rekomendasi:** kombinasi Telegram (untuk alert critical real-time) + Email (untuk ringkasan/audit). Perlu konfirmasi dari tim sebelum implementasi.

### 7.3 Alert Routing
- Critical → notifikasi langsung + escalation jika tidak di-acknowledge dalam 15 menit
- Warning → notifikasi grouped, dikirim per interval (misal tiap 30 menit)
- Silencing/maintenance window untuk mencegah alert saat maintenance terjadwal

## 8. Dashboard (Grafana)

Minimal 4 dashboard:
1. **Overview Cluster** — status seluruh VM & Proxmox host dalam satu layar
2. **VM Detail** — drill-down resource per VM
3. **Backup Job Status** — matrix status job per VM/hari, success rate, tren durasi
4. **Storage Capacity** — tren penggunaan storage & proyeksi kapasitas

## 9. Kebutuhan Non-Fungsional

| Aspek | Requirement |
|---|---|
| Retention data metrik | Minimal 30 hari (raw), 90 hari (downsampled) — sesuaikan kapasitas storage monitoring VM |
| Scrape interval | 15–30 detik untuk resource, 1–5 menit untuk backup job status |
| High availability | Monitoring VM sebaiknya punya backup konfigurasi (IaC/config as code) agar mudah di-restore |
| Security | Akses Grafana dibatasi via auth (LDAP/local user), exporter tidak expose ke publik, gunakan firewall/VPN |
| Skalabilitas | Arsitektur harus mudah menambah VM baru tanpa downtime (auto-discovery via Proxmox SD di Prometheus) |
| Resource overhead | Agent (node_exporter) di tiap VM harus ringan (<50MB RAM, <1% CPU) |

## 10. Rencana Implementasi (Fase)

| Fase | Deliverable | Estimasi |
|---|---|---|
| 1 | Setup monitoring VM + Prometheus + Grafana + Proxmox exporter | 1 minggu |
| 2 | Deploy node_exporter ke semua VM, dashboard resource dasar | 1 minggu |
| 3 | Custom exporter untuk backup job status + dashboard job | 1–2 minggu |
| 4 | Storage capacity monitoring + prediksi kapasitas | 3–5 hari |
| 5 | Setup Alertmanager + rule threshold + integrasi channel notifikasi | 1 minggu |
| 6 | Testing, tuning threshold, dokumentasi & handover | 3–5 hari |

## 11. Metrik Keberhasilan (Success Metrics)

- 100% VM ter-monitor dalam dashboard terpusat.
- Waktu deteksi kegagalan backup job < 15 menit dari waktu seharusnya job berjalan.
- Tidak ada insiden disk full tanpa peringatan (early warning) dalam 3 bulan pertama setelah go-live.
- Mean Time to Detect (MTTD) untuk service down < 5 menit.

## 12. Open Questions / Perlu Konfirmasi

1. Channel alerting final: Telegram, Email, Slack, atau WhatsApp?
2. Apakah backup job scheduler nusabackup punya API/log yang bisa di-expose sebagai metrik, atau perlu dibuat custom exporter dari awal?
3. Berapa jumlah VM saat ini dan proyeksi pertumbuhan (untuk sizing monitoring VM)?
4. Apakah butuh integrasi log terpusat (Loki) di fase berikutnya?
5. Siapa yang akan jadi on-call/penerima alert critical?

---
*Dokumen ini adalah draft awal dan dapat disesuaikan setelah konfirmasi open questions di atas.*
