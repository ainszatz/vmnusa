# Deployment — Monitoring Stack

## Prasyarat
- Docker + Docker Compose terpasang di monitoring VM (terpisah dari VM produksi, lihat PRD section 5).
- Proxmox API token read-only sudah dibuat: Datacenter → Permissions → API Tokens. Beri role `PVEAuditor` ke token tersebut (cukup untuk metrics, jangan pakai token dengan hak admin).
- Bot Telegram sudah dibuat: chat @BotFather di Telegram, kirim `/newbot`, ikuti instruksi, simpan bot token yang diberikan. Untuk chat_id: kirim 1 pesan apa saja ke bot yang baru dibuat, lalu buka `https://api.telegram.org/bot<TOKEN>/getUpdates` di browser dan cari field `"chat":{"id": ...}` di response JSON-nya.

## Setup

1. Copy env template dan isi kredensial asli:
   ```bash
   cp .env.example .env
   cp prometheus/pve.yml.example prometheus/pve.yml
   cp alertmanager/alertmanager.yml.example alertmanager/alertmanager.yml
   ```
   Edit `.env` dengan password admin Grafana (`GRAFANA_ADMIN_PASSWORD`, wajib diisi — lihat catatan fail-fast di langkah 3). Edit `prometheus/pve.yml` dengan user dan token Proxmox asli (bukan host — file ini tidak punya field host). Ganti juga placeholder `pve1.example.local` di `prometheus/prometheus.yml` (job `pve`) dengan hostname/IP Proxmox asli — file ini **bukan** template `.example`, jadi diedit langsung di tempat, bukan lewat `cp`. Edit `alertmanager/alertmanager.yml` dengan bot token dan chat_id Telegram asli (dua tempat: receiver `telegram-critical` dan `telegram-warning`). Ketiga file hasil `cp` di atas di-gitignore — jangan pernah di-commit.

2. Validasi config sebelum start (di monitoring VM, bukan di sandbox dev):
   ```bash
   docker compose config
   promtool check config prometheus/prometheus.yml
   amtool check-config alertmanager/alertmanager.yml
   ```

3. Jalankan stack:
   ```bash
   docker compose up -d
   ```
   Grafana mensyaratkan `GRAFANA_ADMIN_USER` dan `GRAFANA_ADMIN_PASSWORD` terisi di `.env` — jika salah satu kosong, `docker compose up` akan langsung gagal (fail-fast) alih-alih start dengan kredensial kosong.

4. Verifikasi:
   - Prometheus: port Prometheus di-bind ke `127.0.0.1:9090` di monitoring VM (loopback-only, tidak bisa diakses langsung dari browser di komputer lain). Cara verifikasi:
     - Dari monitoring VM langsung: `curl http://127.0.0.1:9090/-/healthy` (harus mengembalikan `Prometheus Server is Healthy.`).
     - Dari komputer lain, buat SSH tunnel dulu: `ssh -L 9090:127.0.0.1:9090 user@monitoring-vm`, lalu buka `http://localhost:9090` di browser lokal → Status → Targets → pastikan job `prometheus`, `pve`, `node`, dan `backup` semuanya `UP`.
   - `pve-exporter` sengaja tidak di-expose ke host (tidak ada port mapping) — hanya bisa diakses lewat docker network internal oleh Prometheus. Jangan heran kalau `curl <monitoring-vm>:9221` gagal, itu memang disengaja.
   - Grafana: `http://<monitoring-vm>:3000` → login pakai `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` dari `.env` → Connections → Data sources → pastikan datasource `Prometheus` sudah otomatis terprovisioning dan status "Data source is working".
   - Grafana → Dashboards → folder "Nusabackup Monitoring" → dashboard **VM Detail** harus menampilkan data CPU/memory/disk/load/uptime dalam beberapa menit setelah stack jalan (tunggu minimal 1 scrape interval, 30 detik).
   - Grafana → Dashboards → folder "Nusabackup Monitoring" → dashboard **Backup Job Status** akan kosong sampai ada file JSON status job ditulis ke `exporters/backup-job-exporter/status/` (lihat kontrak di `exporters/backup-job-exporter/README.md`) — kosong itu normal untuk instalasi baru, bukan tanda error.
   - Grafana → Dashboards → folder "Nusabackup Monitoring" → dashboard **Storage Capacity** harus menampilkan data Storage Pool Usage dan VM Disk Usage segera (tidak perlu job baru — datanya sudah mengalir dari job `pve` dan `node` yang sudah ada). Panel "Prediksi Hari Sampai Penuh" mulai menampilkan angka setelah ~1-2 menit (begitu ada 2 sample scrape), tapi estimasinya baru cukup bermakna setelah beberapa jam data terkumpul — anggap angka di jam-jam pertama sebagai noise, bukan sinyal akurat, itu normal bukan tanda error.
   - Alertmanager UI (via SSH tunnel, sama seperti Prometheus: `ssh -L 9093:127.0.0.1:9093 user@monitoring-vm` lalu buka `http://localhost:9093`): pastikan halaman Status menampilkan config ter-load tanpa error, dan halaman utama tidak menampilkan silence/alert yang tidak diharapkan.
   - Prometheus UI → Alerts: pastikan semua rule group (`resource`, `storage`, `backup-job`, `service-health`) ter-load tanpa error merah. Rule yang statusnya "inactive" itu normal — artinya kondisi alert belum terpenuhi.
   - Test kirim alert manual (opsional tapi disarankan sebelum go-live): `docker compose exec alertmanager amtool alert add alertname=TestAlert severity=warning --alertmanager.url=http://localhost:9093` lalu cek pesan masuk ke Telegram dalam ~30 detik (sesuai `group_wait`).

## Firewall / Akses

- Port Grafana (`3000`) di-bind ke semua interface (`0.0.0.0`) karena tim ops perlu mengakses dashboard dari luar monitoring VM. Batasi akses ini di firewall host ke subnet/VPN ops saja, jangan biarkan terbuka ke internet. Contoh dengan `ufw`:
  ```bash
  ufw allow from 10.0.0.0/24 to any port 3000 proto tcp
  ufw deny 3000/tcp
  ```
  Atau dengan `nftables`, tambahkan rule yang hanya mengizinkan source IP/subnet VPN ops ke port 3000 dan menolak selainnya.
- Untuk production, pertimbangkan menaruh reverse proxy (nginx/Caddy/Traefik) dengan TLS di depan Grafana alih-alih expose port 3000 langsung, terutama jika diakses lewat internet publik.
- Port Alertmanager (`9093`) di-bind ke `127.0.0.1` saja (loopback-only), sama seperti Prometheus (`9090`) — tidak bisa diakses langsung dari luar monitoring VM, harus lewat SSH tunnel (lihat bagian Verifikasi).

## Known limitations
- Baru mencakup 1 node Proxmox (`node: pve1` hardcoded di `prometheus/prometheus.yml`) — auto-discovery multi-node menyusul saat jumlah VM bertambah.
- `node_exporter` saat ini hanya jalan di VM monitoring itu sendiri (self-monitoring, label `vm_name: monitoring-vm` hardcoded di `prometheus/prometheus.yml`) — belum di-deploy ke VM produksi terpisah. Saat VM kedua tersedia, generalisasi diperlukan: pisahkan node_exporter ke docker-compose/systemd service di VM target masing-masing, dan ganti static label `vm_name` per-target atau pakai Proxmox SD/file-based service discovery.
- Panel "Network I/O" sengaja TIDAK ada di dashboard VM Detail: `node-exporter` berjalan di bridge network Docker (bukan host network), sehingga metrik network yang di-scrape adalah traffic interface container itu sendiri, bukan traffic VM sungguhan — datanya akan terlihat masuk akal tapi salah. Untuk network throughput yang akurat, `node-exporter` perlu `network_mode: host` (retarget scrape job ke `host.docker.internal:9100`, dan tambah rule firewall untuk port 9100 di host) — ditunda ke fase berikutnya karena scope-nya lebih besar dari "dashboard resource dasar".
- Dashboard VM Detail belum mencakup Disk I/O (read/write throughput, IOPS) dari PRD §6.1 — baru mencakup kapasitas disk (%). Menyusul di fase berikutnya.
- `backup-job-exporter` belum terhubung ke scheduler/log backup Nusabackup yang sebenarnya — exporter ini hanya membaca file JSON dari `exporters/backup-job-exporter/status/` sesuai kontrak di `exporters/backup-job-exporter/README.md`. Menghubungkan script backup Nusabackup asli untuk menulis ke direktori ini adalah pekerjaan fase berikutnya, bukan bagian dari Fase 3.
- Panel prediksi "Hari Sampai Penuh" di dashboard Storage Capacity pakai regresi linear sederhana (`deriv()` PromQL) atas tren 6 jam terakhir — cukup untuk early-warning kasar, dan belum memperhitungkan pola non-linear (mis. lonjakan mendadak saat backup besar). Hasil non-positif (storage tidak bertumbuh) difilter agar tidak salah tampil merah; panel menampilkan "Tidak bertumbuh" (no-data) untuk kasus itu. Threshold warna (merah <7 hari, kuning <30 hari) belum ada di PRD §7.1 — dipilih sebagai default wajar, sesuaikan jika perlu.
- Label `node` di semua metrik job `pve` (termasuk yang dipakai dashboard Storage Capacity) selalu berisi literal `pve1` -- di-hardcode oleh `relabel_configs` di `prometheus/prometheus.yml` (Fase 1), bukan nama node Proxmox sungguhan. Nama node asli dari exporter tersimpan di label `exported_node` (akibat collision resolution Prometheus saat `honor_labels: false`). Dashboard Storage Capacity sudah memakai `exported_node` untuk menghindari salah atribusi, tapi operator perlu tahu: kalau node Proxmox sungguhan bukan bernama `pve1`, pastikan tidak bingung saat melihat label `node="pve1"` di query manual/Explore. Perbaikan permanen (menghapus/mengganti relabel `node: pve1` di Fase 1) ditunda ke fase berikutnya.
- Eskalasi alert critical yang belum di-acknowledge dalam 15 menit (PRD §7.3) didekati dengan `repeat_interval: 15m` di Alertmanager (alert critical dikirim ulang tiap 15 menit selama masih firing) -- ini BUKAN eskalasi sungguhan berbasis acknowledgment, karena stack ini belum punya tool tracking-ack (mis. Karma, PagerDuty, dsb). Operator harus menganggap "pesan Telegram yang sama datang lagi" sebagai sinyal belum ditangani, bukan mengandalkan sistem untuk tahu itu.
- Service health hanya dicek lewat metrik `up` (target Prometheus reachable atau tidak) untuk exporter yang sudah ada (`prometheus`, `pve`, `node`, `backup`) -- BUKAN probe HTTP/TCP endpoint service sungguhan (PRD §6.4 minta blackbox_exporter, belum dideploy di fase manapun). "Node Proxmox offline" didekati lewat `up{job="pve"}==0` (pve-exporter gagal reach Proxmox API), yang tidak bisa membedakan node down vs API down vs pve-exporter container sendiri yang bermasalah.
- Semua threshold di `prometheus/rules/*.yml` pakai nilai draft PRD §7.1 -- untuk Memory usage, Disk usage, dan rule backup-job, PRD tidak menspesifikasikan durasi "for" (hanya CPU, service down, dan node offline yang eksplisit) -- durasi 5 menit untuk Memory/Disk adalah default yang dipilih sendiri, bukan dari PRD. Tuning threshold final berbasis data produksi diserahkan ke operator setelah deploy ke monitoring VM sungguhan (lihat `docs/handover.md` §4) — di luar apa yang bisa divalidasi di sandbox pengembangan.
