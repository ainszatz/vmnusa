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
