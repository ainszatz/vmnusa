# Handover — Nusabackup VM Monitoring

Dokumen ini untuk siapa pun yang mengoperasikan atau melanjutkan pengembangan sistem monitoring ini setelah Fase 1-6 (lihat `README.md` untuk status tiap fase, `PRD_Monitoring_VM_Nusabackup.md` untuk spesifikasi lengkap).

## 1. Ringkasan Arsitektur

Docker Compose stack di satu monitoring VM (terpisah dari VM produksi, per PRD §5):

| Komponen | Port (host) | Fungsi |
|---|---|---|
| Prometheus | `127.0.0.1:9090` (loopback-only) | Scrape metrics, evaluasi alerting rules |
| Grafana | `0.0.0.0:3000` (dibatasi firewall) | Dashboard |
| Alertmanager | `127.0.0.1:9093` (loopback-only) | Routing & notifikasi alert ke Telegram |
| pve-exporter | tidak di-expose (internal saja) | Metrik Proxmox (VM, node, storage pool) |
| node-exporter | tidak di-expose (internal saja) | Metrik OS-level VM |
| backup-job-exporter | tidak di-expose (internal saja) | Metrik status job backup (custom, lihat §7) |

Semua komponen terhubung lewat Docker network internal `monitoring`. Detail konfigurasi tiap komponen ada di `docker-compose.yml`, `prometheus/prometheus.yml`, `prometheus/rules/*.yml`, `alertmanager/alertmanager.yml.example`, `grafana/provisioning/**`.

## 2. Status Deployment Saat Ini (2026-09-02)

Stack sudah **live** di monitoring VM ("vm client 1") lewat `scripts/install.sh`. Sudah diverifikasi sesuai checklist `docs/deployment.md`:

- ✅ Prometheus targets (`prometheus`, `pve`, `node`, `backup`) semua UP.
- ✅ Grafana datasource Prometheus "working"; dashboard **VM Detail** dan **Storage Capacity** menampilkan data.
- ✅ Alertmanager config ter-load tanpa error.
- ✅ Semua rule group (`resource`, `storage`, `backup-job`, `service-health`) ter-load tanpa error di Prometheus Alerts.

**Belum dikerjakan / follow-up terbuka:**

- ⏳ **Firewall port Grafana (3000) belum dibatasi.** Akses VM saat ini hanya lewat Tailscale (tidak ada exposure LAN/publik), sehingga risikonya jauh lebih kecil dari skenario default di `docs/deployment.md`. Tapi Grafana tetap bind ke `0.0.0.0:3000` (semua interface), jadi Tailscale saja bukan pembatas — kalau VM ini nanti dapat jalur network lain (LAN, port-forward tidak sengaja, dst), port 3000 langsung ikut ter-expose. Rule yang direkomendasikan (scope ke Tailscale, bukan subnet ops generic):
  ```bash
  ufw allow in on tailscale0 to any port 3000 proto tcp
  ufw deny 3000/tcp
  # atau, kalau mau by IP range Tailscale (CGNAT) alih-alih by interface:
  ufw allow from 100.64.0.0/10 to any port 3000 proto tcp
  ufw deny 3000/tcp
  ```
- ⏳ Test kirim alert manual (`amtool alert add ... severity=warning`) ke Telegram belum eksplisit dikonfirmasi — disarankan sebelum benar-benar mengandalkan alerting untuk incident nyata.

## 3. Operasional Harian

- **Cek dashboard**: buka Grafana (`http://<monitoring-vm>:3000`, lewat VPN/firewall yang sudah dibatasi) → folder "Nusabackup Monitoring" → 3 dashboard: **VM Detail** (resource VM), **Backup Job Status** (status job backup), **Storage Capacity** (kapasitas & prediksi penuh).
- **Kalau ada alert masuk ke Telegram**: pesan warning (🟡) berulang tiap 30 menit selama kondisi masih terjadi; pesan critical (🔴) berulang tiap 15 menit. Pesan yang sama datang lagi = **belum ditangani**, bukan false alarm berulang — ini adalah bentuk "eskalasi" yang dipakai sistem ini (lihat §8, sistem belum punya acknowledgment-tracking sungguhan). Alert yang sudah pulih akan dikirim ulang dengan tanda ✅ RESOLVED.
- **Silence/maintenance window**: kalau mau maintenance terjadwal dan tidak mau di-spam alert, buat silence lewat Alertmanager UI (`http://localhost:9093` lewat SSH tunnel, lihat `docs/deployment.md`) atau `docker compose exec alertmanager amtool silence add alertname=<nama> --alertmanager.url=http://localhost:9093`. Ini fitur native Alertmanager, tidak perlu setup tambahan.

## 4. Troubleshooting Cepat

| Gejala | Kemungkinan penyebab | Cek |
|---|---|---|
| Dashboard Grafana kosong/error datasource | Prometheus down, atau datasource provisioning gagal | Prometheus UI → Status → Targets; Grafana → Connections → Data sources |
| Target `pve`/`node`/`backup` berstatus DOWN di Prometheus | Exporter container mati, atau kredensial di `prometheus/pve.yml` salah | `docker compose ps`, `docker compose logs <service>` |
| Tidak ada alert Telegram sama sekali, padahal ada kondisi yang harusnya alert | Bot token/chat_id salah di `alertmanager/alertmanager.yml`, atau Alertmanager tidak jalan | Cek alert `Watchdog` (§8) — kalau pesan Watchdog juga tidak muncul secara berkala, jalur notifikasi memang mati |
| Dashboard Backup Job Status kosong | Belum ada file status JSON ditulis ke `exporters/backup-job-exporter/status/` — normal kalau backup script asli belum diintegrasikan (lihat §7 dan Known Limitations) | `exporters/backup-job-exporter/README.md` |
| `docker compose up` langsung gagal | `.env` tidak lengkap (`GRAFANA_ADMIN_USER`/`PASSWORD` fail-fast by design), atau `prometheus/pve.yml`/`alertmanager/alertmanager.yml` belum di-copy dari `.example` | `docs/deployment.md` bagian Setup |

## 5. Cara Tuning Threshold

Semua threshold alert ada di `prometheus/rules/*.yml` (satu file per kategori: `resource.yml`, `storage.yml`, `backup-job.yml`, `service-health.yml`). Nilai saat ini adalah draft dari PRD §7.1 — **belum pernah divalidasi terhadap traffic produksi asli** (lihat Known Limitations §8).

Cara mengubah:
1. Edit angka threshold (mis. `> 75` jadi `> 70`) atau durasi `for:` di file rule yang relevan.
2. Validasi: `bash scripts/validate.sh` (syntax check cepat) lalu `promtool check rules prometheus/rules/*.yml` di monitoring VM.
3. Reload Prometheus TANPA restart container: `curl -X POST http://localhost:9090/-/reload` (baca perubahan rule file tanpa downtime).
4. Cek Prometheus UI → Alerts, pastikan rule ter-load ulang tanpa error.

Tips kalibrasi setelah beberapa minggu berjalan di produksi:
- Alert warning yang terlalu sering firing tapi tidak pernah jadi masalah nyata → naikkan threshold atau `for:` duration.
- Alert yang seharusnya firing tapi tidak pernah muncul → turunkan threshold, atau cek apakah metriknya benar-benar ter-scrape (lihat Prometheus → Graph, coba query manual).

## 6. Onboarding VM Baru

Saat ini sistem hanya memonitor 1 VM (VM monitoring itu sendiri, self-monitoring — lihat Known Limitations §8). Untuk menambah VM produksi:

1. Deploy `node_exporter` di VM target (bisa docker-compose seperti contoh di `docker-compose.yml`, atau binary+systemd langsung).
2. Tambah target baru di `prometheus/prometheus.yml`'s job `node` — untuk 1 VM tambahan, tambah `static_configs` baru dengan `targets` dan `labels.vm_name` yang beda. Catatan: job `node` juga meng-hardcode label `node: pve1` (lihat §8) — kalau VM tambahan itu ada di Proxmox node yang BEDA dari `pve1`, label `node` di target barunya juga perlu diganti, bukan cuma `vm_name`. Untuk banyak VM ke depan, pertimbangkan Proxmox SD (`proxmox_sd_configs` di Prometheus) atau file-based service discovery alih-alih menambah baris manual satu-satu.
3. Dashboard `vm-detail.json` sudah otomatis mencakup VM baru (query-nya group by `vm_name`, tidak perlu dashboard terpisah per VM).
4. Tambah rule threshold di `prometheus/rules/resource.yml`/`storage.yml` biasanya tidak perlu diubah — rule-nya sudah generic per `vm_name`, akan otomatis mencakup VM baru begitu node_exporter-nya ter-scrape.

## 7. Onboarding Job Backup Baru

`backup-job-exporter` (Fase 3) membaca kontrak file JSON per-job dari `exporters/backup-job-exporter/status/` — skema lengkap ada di `exporters/backup-job-exporter/README.md`. Untuk menghubungkan job backup Nusabackup yang sebenarnya:

1. Setelah tiap eksekusi job backup (sukses maupun gagal), script backup harus menulis 1 file `<job_name>.json` ke direktori itu (idealnya atomic write: tulis ke file temp lalu `rename()`).
2. Field wajib: `job_name`, `status` (`success`/`failed`/`running`), `duration_seconds`, `last_success_timestamp`, `consecutive_failures`, `size_bytes` — detail tipe data dan makna tiap field ada di README exporter.
3. Ini **belum dikerjakan** di fase manapun — dashboard Backup Job Status akan tetap kosong sampai integrasi ini dibuat oleh tim yang punya akses ke script backup Nusabackup asli.

## 8. Known Limitations & Roadmap (konsolidasi dari Fase 1-5)

Daftar ini merangkum semua batasan yang sudah didokumentasikan sepanjang Fase 1-5 (detail lengkap tetap ada di `docs/deployment.md` Known Limitations dan `README.md` per-fase) — WAJIB DIBACA sebelum go-live produksi:

- **Sudah divalidasi dengan tooling asli** (update 2026-09-02, lihat §2): `promtool check config/rules`, `amtool check-config`, `docker compose config` sudah jalan lewat `scripts/install.sh` di monitoring VM sungguhan, dan dashboard `vm-detail.json`/`storage-capacity.json` sudah dibuka di instance Grafana sungguhan dan menampilkan data. Yang **belum** dikonfirmasi: test kirim alert nyata ke Telegram (§2), dan image Docker `backup-job-exporter` belum pernah di-build/dijalankan dengan job backup asli (masih nunggu integrasi §7) sehingga dashboard Backup Job Status masih kosong seperti kondisi awal.
- **Dashboard "Overview Cluster" (PRD §8, dashboard ke-4) belum pernah dibuat** di fase manapun — hanya 3 dari 4 dashboard minimal PRD yang ada (VM Detail, Backup Job Status, Storage Capacity). Overview Cluster seharusnya menampilkan status seluruh VM & Proxmox host dalam satu layar. Ini gap nyata dari PRD yang baru terdeteksi di audit akhir Fase 6 — perlu dikerjakan sebagai pekerjaan lanjutan, di luar scope Fase 1-6 yang sudah berjalan.
- **Retention data metrik baru 30 hari (raw)**, belum ada tier downsampled 90 hari sesuai PRD §9 — butuh solusi tambahan (mis. Thanos, VictoriaMetrics, atau recording rules) untuk itu, di luar scope Fase 1-6.
- **Baru 1 VM (self-monitoring)**: node_exporter, backup-job-exporter, semua label `vm_name` masih hardcode ke `monitoring-vm`. Lihat §6 untuk cara generalisasi.
- **Label `node` di job `pve` selalu `pve1`** (hardcoded di `relabel_configs`, Fase 1) — nama node Proxmox asli ada di label `exported_node`. Dashboard Storage Capacity sudah pakai `exported_node`, tapi query manual di Prometheus/Grafana Explore bisa membingungkan kalau tidak tahu ini.
- **Panel Network I/O sengaja tidak ada** di dashboard VM Detail — `node-exporter` jalan di bridge network Docker, metrik network yang ter-scrape adalah traffic container, bukan VM. Perlu `network_mode: host` untuk data akurat (scope lebih besar, ditunda).
- **Disk I/O (throughput/IOPS) belum ada** di dashboard VM Detail — baru kapasitas (%).
- **`backup-job-exporter` belum terhubung ke script backup Nusabackup asli** — lihat §7.
- **Service health cuma `up==0`**, bukan probe HTTP/TCP sungguhan — `blackbox_exporter` (PRD §6.4) belum pernah dideploy. "Node Proxmox offline" adalah proxy dari `up{job="pve"}==0` (pve-exporter gagal reach API), tidak bisa membedakan node down vs API down vs exporter sendiri bermasalah.
- **Eskalasi critical adalah `repeat_interval: 15m`**, bukan acknowledgment-tracking sungguhan (perlu tool seperti Karma/PagerDuty untuk itu).
- **Alertmanager sendiri belum di-scrape** — kalau Alertmanager mati, `MonitoringTargetDown` tidak akan mendeteksinya (Prometheus tidak tahu Alertmanager down). Ada alert `Watchdog` (`vector(1)`, selalu firing) sebagai dead-man's-switch parsial: kalau operator berhenti menerima pesan Watchdog secara berkala, itu tanda ada yang rusak di jalur Prometheus→Alertmanager→Telegram — tapi ini tidak spesifik menunjuk komponen mana yang mati.
- **Prediksi "Hari Sampai Penuh" (Storage Capacity) pakai regresi linear sederhana** — belum memperhitungkan pola non-linear (mis. lonjakan mendadak saat backup besar), cukup untuk early-warning kasar bukan proyeksi presisi. Threshold warna (merah <7 hari, kuning <30 hari) adalah default yang dipilih sendiri, bukan dari PRD §7.1.
- **Threshold masih draft PRD §7.1**, belum di-tuning dengan data produksi asli — lihat §5.
- **Image Docker belum di-pin versi** (`:latest` di semua service) — pertimbangkan pin sebelum produksi jangka panjang.

## 9. Open Questions — BELUM Terjawab (PRD §12)

PRD section 12 punya 5 open question. 3 sudah terjawab selama pengerjaan (lihat `README.md` "Keputusan yang Sudah Dikonfirmasi": channel Telegram, sumber data backup custom exporter, jumlah VM 1). **2 masih terbuka dan perlu dijawab tim sebelum benar-benar go-live:**

- **Siapa yang jadi on-call/penerima alert critical?** (PRD §12 poin 5) — `alertmanager/alertmanager.yml.example` sudah punya 2 receiver terpisah (`telegram-critical` dan `telegram-warning`), masing-masing dengan field `chat_id` sendiri, jadi secara teknis critical dan warning **sudah bisa** diarahkan ke chat/grup Telegram yang berbeda. Yang belum ada adalah keputusannya: chat_id/grup mana yang jadi tujuan `telegram-critical` (satu orang? grup on-call bergiliran?). Sampai keputusan itu diambil, kedua receiver di file `.example` memakai placeholder `chat_id` yang sama (`000000000`) — operator perlu mengisi chat_id yang sesuai keputusan tim saat setup.
- **Apakah butuh integrasi log terpusat (Loki)?** (PRD §12 poin 4) — belum dikerjakan sama sekali, di luar scope Fase 1-6. Kalau dibutuhkan, ini jadi fase terpisah (arsitektur baru: Loki + Promtail/Alloy, dashboard log correlation di Grafana).
