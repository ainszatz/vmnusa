# Fase 6: Handover Docs + Validation Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out PRD section 10 Fase 6 ("Testing, tuning threshold, dokumentasi & handover") within what's actually achievable in this dev sandbox — a consolidated handover runbook, an automated static-validation script, and a final documentation consistency audit — while being explicit that real device testing and data-driven threshold tuning require a live deployment and are handed off to the operator, not silently claimed as done here.

**Architecture:** No new stack components. This phase adds two new files (`scripts/validate.sh`, `docs/handover.md`) and audits/touches up the existing `docs/deployment.md` and `README.md` for accuracy after 5 phases of incremental edits. `scripts/validate.sh` is a shell script (bash, matching the monitoring VM's actual runtime environment, not this Windows dev sandbox) that automates the `python3 -c "import yaml/json..."` syntax checks every prior phase ran manually per-file, discovering files by glob instead of a hardcoded list so it doesn't silently go stale as new config files are added in future phases.

**Tech Stack:** Bash, Python 3 (yaml/json stdlib+PyYAML, already used throughout this repo for validation), Markdown.

## Global Constraints

- Scope confirmed with the user this session: real testing (actually running `docker compose up`, triggering real alerts, watching Telegram) and data-driven threshold tuning (adjusting numbers based on real production traffic) are NOT achievable in this sandbox (no `docker`/`promtool`/`amtool`/live Proxmox/live Telegram bot) — this phase does NOT claim either is done. Instead: (a) a validation script automates what CAN be checked here (static syntax) and clearly hands off what can't (promtool/amtool/docker compose config, listed as next steps in its own output); (b) `docs/handover.md` documents HOW to tune thresholds and WHERE they live, without changing any actual threshold values (Fase 5's PRD §7.1 draft values stand until someone with real production data adjusts them).
- `docs/handover.md` must accurately reflect the CURRENT state of every prior phase's known limitations — read `README.md` and `docs/deployment.md` in full immediately before writing it (their content may have been touched by review fix-rounds after this plan was drafted); do not silently trust the bullet text quoted in this plan's Task 2 as still being verbatim-current without checking.
- `scripts/validate.sh` discovers files by glob (`find . -name "*.yml" -o -name "*.yaml"`, `find . -name "*.json"`), not a hardcoded file list — CLAUDE.md's own "Command yang Sering Dipakai" section lists per-file `promtool`/`docker compose` commands; this script is a NEW convenience addition, not a replacement for those, and its own output should say so.
- PRD §12's Open Questions must be revisited honestly in `docs/handover.md`: questions 1-3 (channel, backup-job data source, VM count) were answered during this project's execution and should be marked resolved; questions 4 (integrasi Loki) and 5 (siapa on-call/penerima alert critical) were NEVER answered and remain genuinely open — do not silently mark them resolved or invent an answer, flag them prominently as blocking real go-live (especially #5 — an alerting system with no defined on-call recipient is incomplete regardless of how well the technical plumbing works).
- `docker`/`promtool`/`amtool` remain unavailable in this dev sandbox for this phase too — `scripts/validate.sh` itself cannot be executed end-to-end here beyond a syntax self-check of the script (`bash -n scripts/validate.sh`); running it for real against the repo's YAML/JSON files IS something this sandbox can do (Python + the files are both present), so the implementer SHOULD actually run it here and confirm it reports success, that part is not sandbox-blocked.

---

### Task 1: Static validation script

**Files:**
- Create: `scripts/validate.sh`

**Interfaces:**
- Produces: a standalone script, runnable both in this dev sandbox (syntax-only checks, since `docker`/`promtool`/`amtool` aren't installed here) and on a real monitoring VM (same syntax checks, plus it prints the follow-up `promtool`/`amtool`/`docker compose config` commands as next steps rather than trying to run them itself — running those requires the actual binaries and a config file with real credentials filled in, neither of which this script can assume exist).

- [ ] **Step 1: Create `scripts/validate.sh`**

```bash
#!/usr/bin/env bash
# Static syntax validation for this repo's YAML/JSON config files.
# Does NOT replace promtool/amtool/docker compose config — those need
# real binaries and a fully-configured deployment and are listed as
# next steps at the end of this script's output.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0

echo "== Validating YAML syntax =="
while IFS= read -r -d '' f; do
  if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    echo "OK   $f"
  else
    echo "FAIL $f"
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f"
    fail=1
  fi
done < <(find . -type f \( -name "*.yml" -o -name "*.yaml" \) -not -path "./.git/*" -print0)

echo
echo "== Validating JSON syntax =="
while IFS= read -r -d '' f; do
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    echo "OK   $f"
  else
    echo "FAIL $f"
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f"
    fail=1
  fi
done < <(find . -type f -name "*.json" -not -path "./.git/*" -print0)

echo
if [ "$fail" -ne 0 ]; then
  echo "Validation FAILED -- fix the file(s) marked FAIL above before deploying."
  exit 1
fi

echo "All static syntax checks passed."
echo
echo "NEXT STEPS -- jalankan ini juga di monitoring VM sungguhan sebelum deploy"
echo "(butuh docker/promtool/amtool asli, tidak tersedia di sandbox pengembangan):"
echo "  docker compose config"
echo "  promtool check config prometheus/prometheus.yml"
echo "  promtool check rules prometheus/rules/*.yml"
echo "  amtool check-config alertmanager/alertmanager.yml"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/validate.sh`

- [ ] **Step 3: Self-check the script's own syntax**

Run: `bash -n scripts/validate.sh`
Expected: no output, exit code 0 (bash's `-n` flag parses without executing).

- [ ] **Step 4: Actually run it against this repo's real files**

Run: `bash scripts/validate.sh`
Expected: every YAML/JSON file in the repo reported `OK`, ending with "All static syntax checks passed." and the NEXT STEPS block. This IS achievable in this sandbox (Python is present) — actually run it, don't just claim it would work. Paste the real output in your report.

- [ ] **Step 5: Commit**

```bash
git add scripts/validate.sh
git commit -m "feat: add static config validation script (yaml/json syntax across whole repo)"
```

---

### Task 2: Handover documentation

**Files:**
- Create: `docs/handover.md`

**Interfaces:**
- Consumes: the CURRENT content of `README.md` and `docs/deployment.md` (read them fresh, do not assume this plan's quoted excerpts are still accurate) to accurately consolidate known limitations, architecture, and setup state across all 5 completed phases.

- [ ] **Step 1: Re-read `README.md` and `docs/deployment.md` in full**

Read both files completely before writing — they may have been edited by fix-rounds after this plan was drafted. If anything below contradicts what you actually find, trust the actual files, not this plan text, and note the discrepancy in your report.

- [ ] **Step 2: Create `docs/handover.md`**

```markdown
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
| backup-job-exporter | tidak di-expose (internal saja) | Metrik status job backup (custom, lihat §6) |

Semua komponen terhubung lewat Docker network internal `monitoring`. Detail konfigurasi tiap komponen ada di `docker-compose.yml`, `prometheus/prometheus.yml`, `prometheus/rules/*.yml`, `alertmanager/alertmanager.yml.example`, `grafana/provisioning/**`.

## 2. Operasional Harian

- **Cek dashboard**: buka Grafana (`http://<monitoring-vm>:3000`, lewat VPN/firewall yang sudah dibatasi) → folder "Nusabackup Monitoring" → 3 dashboard: **VM Detail** (resource VM), **Backup Job Status** (status job backup), **Storage Capacity** (kapasitas & prediksi penuh).
- **Kalau ada alert masuk ke Telegram**: pesan warning (🟡) berulang tiap 30 menit selama kondisi masih terjadi; pesan critical (🔴) berulang tiap 15 menit. Pesan yang sama datang lagi = **belum ditangani**, bukan false alarm berulang — ini adalah bentuk "eskalasi" yang dipakai sistem ini (lihat §7, sistem belum punya acknowledgment-tracking sungguhan). Alert yang sudah pulih akan dikirim ulang dengan tanda ✅ RESOLVED.
- **Silence/maintenance window**: kalau mau maintenance terjadwal dan tidak mau di-spam alert, buat silence lewat Alertmanager UI (`http://localhost:9093` lewat SSH tunnel, lihat `docs/deployment.md`) atau `amtool silence add`. Ini fitur native Alertmanager, tidak perlu setup tambahan.

## 3. Troubleshooting Cepat

| Gejala | Kemungkinan penyebab | Cek |
|---|---|---|
| Dashboard Grafana kosong/error datasource | Prometheus down, atau datasource provisioning gagal | Prometheus UI → Status → Targets; Grafana → Connections → Data sources |
| Target `pve`/`node`/`backup` berstatus DOWN di Prometheus | Exporter container mati, atau kredensial di `prometheus/pve.yml` salah | `docker compose ps`, `docker compose logs <service>` |
| Tidak ada alert Telegram sama sekali, padahal ada kondisi yang harusnya alert | Bot token/chat_id salah di `alertmanager/alertmanager.yml`, atau Alertmanager tidak jalan | Cek alert `Watchdog` (§7) — kalau pesan Watchdog juga tidak muncul secara berkala, jalur notifikasi memang mati |
| Dashboard Backup Job Status kosong | Belum ada file status JSON ditulis ke `exporters/backup-job-exporter/status/` — normal kalau backup script asli belum diintegrasikan (lihat §6 dan Known Limitations) | `exporters/backup-job-exporter/README.md` |
| `docker compose up` langsung gagal | `.env` tidak lengkap (`GRAFANA_ADMIN_USER`/`PASSWORD` fail-fast by design), atau `prometheus/pve.yml`/`alertmanager/alertmanager.yml` belum di-copy dari `.example` | `docs/deployment.md` bagian Setup |

## 4. Cara Tuning Threshold

Semua threshold alert ada di `prometheus/rules/*.yml` (satu file per kategori: `resource.yml`, `storage.yml`, `backup-job.yml`, `service-health.yml`). Nilai saat ini adalah draft dari PRD §7.1 — **belum pernah divalidasi terhadap traffic produksi asli** (lihat Known Limitations §7).

Cara mengubah:
1. Edit angka threshold (mis. `> 75` jadi `> 70`) atau durasi `for:` di file rule yang relevan.
2. Validasi: `bash scripts/validate.sh` (syntax check cepat) lalu `promtool check rules prometheus/rules/*.yml` di monitoring VM.
3. Reload Prometheus TANPA restart container: `curl -X POST http://localhost:9090/-/reload` (baca perubahan rule file tanpa downtime).
4. Cek Prometheus UI → Alerts, pastikan rule ter-load ulang tanpa error.

Tips kalibrasi setelah beberapa minggu berjalan di produksi:
- Alert warning yang terlalu sering firing tapi tidak pernah jadi masalah nyata → naikkan threshold atau `for:` duration.
- Alert yang seharusnya firing tapi tidak pernah muncul → turunkan threshold, atau cek apakah metriknya benar-benar ter-scrape (lihat Prometheus → Graph, coba query manual).

## 5. Onboarding VM Baru

Saat ini sistem hanya memonitor 1 VM (VM monitoring itu sendiri, self-monitoring — lihat Known Limitations §7). Untuk menambah VM produksi:

1. Deploy `node_exporter` di VM target (bisa docker-compose seperti contoh di `docker-compose.yml`, atau binary+systemd langsung).
2. Tambah target baru di `prometheus/prometheus.yml`'s job `node` — untuk 1 VM tambahan, tambah `static_configs` baru dengan `targets` dan `labels.vm_name` yang beda. Untuk banyak VM ke depan, pertimbangkan Proxmox SD (`proxmox_sd_configs` di Prometheus) atau file-based service discovery alih-alih menambah baris manual satu-satu.
3. Deploy dashboard `vm-detail.json` sudah otomatis mencakup VM baru (query-nya group by `vm_name`, tidak perlu dashboard terpisah per VM).
4. Tambah rule threshold di `prometheus/rules/resource.yml`/`storage.yml` biasanya tidak perlu diubah — rule-nya sudah generic per `vm_name`, akan otomatis mencakup VM baru begitu node_exporter-nya ter-scrape.

## 6. Onboarding Job Backup Baru

`backup-job-exporter` (Fase 3) membaca kontrak file JSON per-job dari `exporters/backup-job-exporter/status/` — skema lengkap ada di `exporters/backup-job-exporter/README.md`. Untuk menghubungkan job backup Nusabackup yang sebenarnya:

1. Setelah tiap eksekusi job backup (sukses maupun gagal), script backup harus menulis 1 file `<job_name>.json` ke direktori itu (idealnya atomic write: tulis ke file temp lalu `rename()`).
2. Field wajib: `job_name`, `status` (`success`/`failed`/`running`), `duration_seconds`, `last_success_timestamp`, `consecutive_failures`, `size_bytes` — detail tipe data dan makna tiap field ada di README exporter.
3. Ini **belum dikerjakan** di fase manapun — dashboard Backup Job Status akan tetap kosong sampai integrasi ini dibuat oleh tim yang punya akses ke script backup Nusabackup asli.

## 7. Known Limitations & Roadmap (konsolidasi dari Fase 1-5)

Daftar ini merangkum semua batasan yang sudah didokumentasikan sepanjang Fase 1-5 (detail lengkap tetap ada di `docs/deployment.md` Known Limitations dan `README.md` per-fase) — WAJIB DIBACA sebelum go-live produksi:

- **Belum divalidasi dengan tooling asli**: `promtool check config/rules`, `amtool check-config`, `docker compose config`, dan pesan Telegram nyata belum pernah dijalankan (sandbox pengembangan tidak punya `docker`/`promtool`/`amtool`). Jalankan `scripts/validate.sh` PLUS keempat command di atas di monitoring VM sebelum go-live.
- **Baru 1 VM (self-monitoring)**: node_exporter, backup-job-exporter, semua label `vm_name` masih hardcode ke `monitoring-vm`. Lihat §5 untuk cara generalisasi.
- **Label `node` di job `pve` selalu `pve1`** (hardcoded di `relabel_configs`, Fase 1) — nama node Proxmox asli ada di label `exported_node`. Dashboard Storage Capacity sudah pakai `exported_node`, tapi query manual di Prometheus/Grafana Explore bisa membingungkan kalau tidak tahu ini.
- **Panel Network I/O sengaja tidak ada** di dashboard VM Detail — `node-exporter` jalan di bridge network Docker, metrik network yang ter-scrape adalah traffic container, bukan VM. Perlu `network_mode: host` untuk data akurat (scope lebih besar, ditunda).
- **Disk I/O (throughput/IOPS) belum ada** di dashboard VM Detail — baru kapasitas (%).
- **`backup-job-exporter` belum terhubung ke script backup Nusabackup asli** — lihat §6.
- **Service health cuma `up==0`**, bukan probe HTTP/TCP sungguhan — `blackbox_exporter` (PRD §6.4) belum pernah dideploy. "Node Proxmox offline" adalah proxy dari `up{job="pve"}==0` (pve-exporter gagal reach API), tidak bisa membedakan node down vs API down vs exporter sendiri bermasalah.
- **Eskalasi critical adalah `repeat_interval: 15m`**, bukan acknowledgment-tracking sungguhan (perlu tool seperti Karma/PagerDuty untuk itu).
- **Alertmanager sendiri belum di-scrape** — kalau Alertmanager mati, `MonitoringTargetDown` tidak akan mendeteksinya (Prometheus tidak tahu Alertmanager down). Ada alert `Watchdog` (`vector(1)`, selalu firing) sebagai dead-man's-switch parsial: kalau operator berhenti menerima pesan Watchdog secara berkala, itu tanda ada yang rusak di jalur Prometheus→Alertmanager→Telegram — tapi ini tidak spesifik menunjuk komponen mana yang mati.
- **Threshold masih draft PRD §7.1**, belum di-tuning dengan data produksi asli — lihat §4.
- **Image Docker belum di-pin versi** (`:latest` di semua service) — pertimbangkan pin sebelum produksi jangka panjang.

## 8. Open Questions — BELUM Terjawab (PRD §12)

PRD section 12 punya 5 open question. 3 sudah terjawab selama pengerjaan (lihat `README.md` "Keputusan yang Sudah Dikonfirmasi": channel Telegram, sumber data backup custom exporter, jumlah VM 1). **2 masih terbuka dan perlu dijawab tim sebelum benar-benar go-live:**

- **Siapa yang jadi on-call/penerima alert critical?** (PRD §12 poin 5) — saat ini semua alert (warning maupun critical) masuk ke SATU chat_id Telegram yang sama di `alertmanager/alertmanager.yml`. Kalau ada beberapa orang on-call bergiliran, atau butuh grup/channel terpisah untuk critical vs warning, itu perlu didesain dan chat_id/struktur receiver-nya disesuaikan — bukan pekerjaan teknis besar, tapi butuh keputusan organisasi dulu.
- **Apakah butuh integrasi log terpusat (Loki)?** (PRD §12 poin 4) — belum dikerjakan sama sekali, di luar scope Fase 1-6. Kalau dibutuhkan, ini jadi fase terpisah (arsitektur baru: Loki + Promtail/Alloy, dashboard log correlation di Grafana).
```

- [ ] **Step 3: Sanity check**

Run: `python3 -c "print(open('docs/handover.md').read()[:200])"` and confirm it prints without error.

- [ ] **Step 4: Commit**

```bash
git add docs/handover.md
git commit -m "docs: add consolidated handover runbook (ops, troubleshooting, tuning, onboarding, open questions)"
```

---

### Task 3: Final documentation audit + README Fase 6 status update

**Files:**
- Modify: `README.md`
- Possibly modify: `docs/deployment.md` (only if the audit finds something genuinely stale — do not edit it speculatively)

**Interfaces:**
- Consumes: Tasks 1-2's new files (`scripts/validate.sh`, `docs/handover.md`) — README should link to both.

- [ ] **Step 1: Read `README.md` and `docs/deployment.md` in full, one more time**

This is a dedicated audit pass, not just "add the Fase 6 section." Read every bullet in both files' "Known limitations"/per-phase sections looking specifically for: (a) claims that are now stale given Tasks 1-2's new files existing, (b) any contradiction between the two files, (c) anything a careful reader would find confusing or inconsistent. This project's history (Fase 3 Task 6, Fase 4 Tasks 2-3, Fase 5 Task 7) shows this kind of audit reliably finds at least one real issue — don't rubber-stamp "looks fine" without genuinely checking each bullet against the actual current repo state (e.g. does `exporters/backup-job-exporter/status/` really have no real files in it still? does `prometheus/rules/*.yml` still match what the bullets describe?).

- [ ] **Step 2: Fix anything the audit finds**

If you find a real issue, fix it directly in the relevant file (`README.md` or `docs/deployment.md`) as part of this task — don't defer it. Document what you found and fixed in your report even if it wasn't explicitly anticipated by this step list.

- [ ] **Step 3: Add a "Handover & Validasi" pointer near the top of README.md**

After the existing "Deploy" section (which links to `docs/deployment.md`), add:

```markdown
## Handover & Validasi

Lihat [`docs/handover.md`](docs/handover.md) untuk panduan operasional, troubleshooting, cara tuning threshold, dan daftar keterbatasan yang perlu diketahui sebelum go-live. Jalankan `bash scripts/validate.sh` untuk validasi syntax semua file config sebelum deploy.
```

- [ ] **Step 4: Update the status table**

Change the Fase 6 row from:
```markdown
| 6 | Testing, tuning threshold, dokumentasi & handover | ⬜ Belum mulai |
```
to:
```markdown
| 6 | Testing, tuning threshold, dokumentasi & handover | ✅ Selesai (dokumentasi + validasi; testing nyata & tuning berbasis data produksi menyusul setelah deploy) |
```

- [ ] **Step 5: Add a Fase 6 detail section**

Add after the existing "Fase 5 — ..." section, before "## Keputusan yang Sudah Dikonfirmasi":

```markdown
### Fase 6 — Handover, Dokumentasi & Validasi

Selesai 2026-08-17. Dibangun: `scripts/validate.sh` (validasi syntax YAML/JSON otomatis untuk seluruh repo), `docs/handover.md` (runbook operasional, troubleshooting, cara tuning threshold, onboarding VM/job baru, konsolidasi known limitations, dan open questions PRD §12 yang belum terjawab).

Catatan penting:
- Testing nyata (`docker compose up`, trigger alert sungguhan, cek pesan Telegram) dan tuning threshold berbasis data produksi **tidak bisa dikerjakan di sandbox pengembangan** (tidak ada `docker`/`promtool`/`amtool`/Proxmox/Telegram nyata) — ini eksplisit diserahkan ke operator setelah deploy ke monitoring VM sungguhan, bukan diklaim selesai di sini.
- 2 dari 5 open question PRD §12 masih belum terjawab: **siapa on-call/penerima alert critical**, dan **apakah butuh integrasi Loki**. Lihat `docs/handover.md` §8.
- `scripts/validate.sh` benar-benar dijalankan di sandbox ini terhadap semua file config repo dan semuanya lolos syntax check — tapi ini cuma syntax, bukan pengganti `promtool`/`amtool`/`docker compose config`.
```

- [ ] **Step 6: Commit**

```bash
git add README.md
# also `git add docs/deployment.md` if Step 2 touched it
git commit -m "docs: final audit pass and update README progress tracker for fase 6 completion"
```

---

## Self-Review Notes

- **Spec coverage:** PRD Fase 6 deliverable = "Testing, tuning threshold, dokumentasi & handover" → per the user's explicit scope decision this session, "testing" and "tuning" are documented as handed-off-to-operator (not fabricated as done), while "dokumentasi & handover" is fully delivered via Task 2's `docs/handover.md`. Task 1's validation script is the closest approximation of "testing" actually achievable here — it doesn't test the running system, but it does verify every config file's syntax automatically instead of requiring manual per-file checks like every prior phase did. Task 3's audit directly addresses "testing" in the sense of testing the DOCUMENTATION's own internal consistency, which is the one thing fully verifiable in this sandbox.
- **Placeholder scan:** no TBD/TODO; Task 1 has complete script content, Task 2 has complete markdown content.
- **Type/naming consistency:** file paths referenced in `docs/handover.md` (§4's `scripts/validate.sh`, §6's `exporters/backup-job-exporter/`) match the actual paths created in this plan's Task 1 and in Fase 3. The Known Limitations consolidation in Task 2 §7 was cross-checked against the actual current `docs/deployment.md` content (read fresh in this same research turn, not from memory) to avoid re-introducing the stale-doc bug pattern this project has hit multiple times before.
