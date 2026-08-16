# Deployment — Monitoring Stack

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
     - Dari komputer lain, buat SSH tunnel dulu: `ssh -L 9090:127.0.0.1:9090 user@monitoring-vm`, lalu buka `http://localhost:9090` di browser lokal → Status → Targets → pastikan job `prometheus`, `pve`, dan `node` semuanya `UP`.
   - `pve-exporter` sengaja tidak di-expose ke host (tidak ada port mapping) — hanya bisa diakses lewat docker network internal oleh Prometheus. Jangan heran kalau `curl <monitoring-vm>:9221` gagal, itu memang disengaja.
   - Grafana: `http://<monitoring-vm>:3000` → login pakai `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` dari `.env` → Connections → Data sources → pastikan datasource `Prometheus` sudah otomatis terprovisioning dan status "Data source is working".
   - Grafana → Dashboards → folder "Nusabackup Monitoring" → dashboard **VM Detail** harus menampilkan data CPU/memory/disk/load/uptime dalam beberapa menit setelah stack jalan (tunggu minimal 1 scrape interval, 30 detik).

## Firewall / Akses

- Port Grafana (`3000`) di-bind ke semua interface (`0.0.0.0`) karena tim ops perlu mengakses dashboard dari luar monitoring VM. Batasi akses ini di firewall host ke subnet/VPN ops saja, jangan biarkan terbuka ke internet. Contoh dengan `ufw`:
  ```bash
  ufw allow from 10.0.0.0/24 to any port 3000 proto tcp
  ufw deny 3000/tcp
  ```
  Atau dengan `nftables`, tambahkan rule yang hanya mengizinkan source IP/subnet VPN ops ke port 3000 dan menolak selainnya.
- Untuk production, pertimbangkan menaruh reverse proxy (nginx/Caddy/Traefik) dengan TLS di depan Grafana alih-alih expose port 3000 langsung, terutama jika diakses lewat internet publik.

## Known limitations
- Baru mencakup 1 node Proxmox (`node: pve1` hardcoded di `prometheus/prometheus.yml`) — auto-discovery multi-node menyusul saat jumlah VM bertambah.
- Alertmanager belum di-wire (target Fase 5 di PRD section 10) — `alerting.alertmanagers` di `prometheus.yml` sengaja kosong.
- `node_exporter` saat ini hanya jalan di VM monitoring itu sendiri (self-monitoring, label `vm_name: monitoring-vm` hardcoded di `prometheus/prometheus.yml`) — belum di-deploy ke VM produksi terpisah. Saat VM kedua tersedia, generalisasi diperlukan: pisahkan node_exporter ke docker-compose/systemd service di VM target masing-masing, dan ganti static label `vm_name` per-target atau pakai Proxmox SD/file-based service discovery.
- Custom backup-job exporter belum dideploy (Fase 3).
- Panel "Network I/O" sengaja TIDAK ada di dashboard VM Detail: `node-exporter` berjalan di bridge network Docker (bukan host network), sehingga metrik network yang di-scrape adalah traffic interface container itu sendiri, bukan traffic VM sungguhan — datanya akan terlihat masuk akal tapi salah. Untuk network throughput yang akurat, `node-exporter` perlu `network_mode: host` (retarget scrape job ke `host.docker.internal:9100`, dan tambah rule firewall untuk port 9100 di host) — ditunda ke fase berikutnya karena scope-nya lebih besar dari "dashboard resource dasar".
- Dashboard VM Detail belum mencakup Disk I/O (read/write throughput, IOPS) dari PRD §6.1 — baru mencakup kapasitas disk (%). Menyusul di fase berikutnya.
