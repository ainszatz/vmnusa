import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from collector import BackupJobCollector


def write_status(dir_path, filename, **fields):
    with open(dir_path / filename, "w", encoding="utf-8") as f:
        json.dump(fields, f)


def collect_samples(collector):
    samples = {}
    for family in collector.collect():
        samples[family.name] = {s.labels["job_name"]: s.value for s in family.samples}
    return samples


def test_collects_successful_job(tmp_path):
    write_status(
        tmp_path, "vm-backup.json",
        job_name="vm-backup", status="success", duration_seconds=120.5,
        last_success_timestamp=1755000000, consecutive_failures=0, size_bytes=1073741824,
    )
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"]["vm-backup"] == 1
    assert samples["nusabackup_backup_job_duration_seconds"]["vm-backup"] == 120.5
    assert samples["nusabackup_backup_job_last_success_timestamp_seconds"]["vm-backup"] == 1755000000
    assert samples["nusabackup_backup_job_consecutive_failures"]["vm-backup"] == 0
    assert samples["nusabackup_backup_job_size_bytes"]["vm-backup"] == 1073741824


def test_collects_failed_job(tmp_path):
    write_status(
        tmp_path, "db-backup.json",
        job_name="db-backup", status="failed", duration_seconds=30,
        last_success_timestamp=1754900000, consecutive_failures=3, size_bytes=0,
    )
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"]["db-backup"] == 0
    assert samples["nusabackup_backup_job_consecutive_failures"]["db-backup"] == 3


def test_collects_running_job(tmp_path):
    write_status(
        tmp_path, "vm-backup.json",
        job_name="vm-backup", status="running", duration_seconds=0,
        last_success_timestamp=1754900000, consecutive_failures=0, size_bytes=0,
    )
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"]["vm-backup"] == 2


def test_multiple_jobs_produce_multiple_series(tmp_path):
    write_status(tmp_path, "a.json", job_name="a", status="success", duration_seconds=1,
                 last_success_timestamp=1, consecutive_failures=0, size_bytes=1)
    write_status(tmp_path, "b.json", job_name="b", status="failed", duration_seconds=1,
                 last_success_timestamp=1, consecutive_failures=1, size_bytes=1)
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert set(samples["nusabackup_backup_job_status"].keys()) == {"a", "b"}


def test_missing_status_dir_yields_no_series(tmp_path):
    missing_dir = tmp_path / "does-not-exist"
    collector = BackupJobCollector(str(missing_dir))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_malformed_json_is_skipped_not_crashed(tmp_path):
    (tmp_path / "broken.json").write_text("{not valid json", encoding="utf-8")
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_missing_required_field_is_skipped(tmp_path):
    write_status(tmp_path, "incomplete.json", job_name="x", status="success")
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_invalid_status_value_is_skipped(tmp_path):
    write_status(tmp_path, "bad-status.json", job_name="x", status="unknown",
                 duration_seconds=1, last_success_timestamp=1, consecutive_failures=0, size_bytes=1)
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_json_array_top_level_is_skipped(tmp_path):
    (tmp_path / "array.json").write_text("[1, 2, 3]", encoding="utf-8")
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_json_string_top_level_is_skipped(tmp_path):
    (tmp_path / "string.json").write_text('"hello"', encoding="utf-8")
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_null_numeric_field_is_skipped(tmp_path):
    write_status(tmp_path, "null-duration.json", job_name="x", status="success",
                 duration_seconds=None, last_success_timestamp=1, consecutive_failures=0, size_bytes=1)
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_nested_object_numeric_field_is_skipped(tmp_path):
    write_status(tmp_path, "object-duration.json", job_name="x", status="success",
                 duration_seconds={"x": 1}, last_success_timestamp=1, consecutive_failures=0, size_bytes=1)
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_non_string_job_name_is_skipped(tmp_path):
    write_status(tmp_path, "int-job-name.json", job_name=123, status="success",
                 duration_seconds=1, last_success_timestamp=1, consecutive_failures=0, size_bytes=1)
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert samples["nusabackup_backup_job_status"] == {}


def test_duplicate_job_name_across_files_keeps_only_one_series(tmp_path):
    write_status(tmp_path, "a.json", job_name="vm-backup", status="success", duration_seconds=1,
                 last_success_timestamp=1, consecutive_failures=0, size_bytes=1)
    write_status(tmp_path, "b.json", job_name="vm-backup", status="failed", duration_seconds=2,
                 last_success_timestamp=2, consecutive_failures=5, size_bytes=2)
    collector = BackupJobCollector(str(tmp_path))
    samples = collect_samples(collector)

    assert list(samples["nusabackup_backup_job_status"].keys()) == ["vm-backup"]
