import json
import logging
from pathlib import Path

from prometheus_client.core import GaugeMetricFamily

logger = logging.getLogger(__name__)

REQUIRED_FIELDS = {
    "job_name",
    "status",
    "duration_seconds",
    "last_success_timestamp",
    "consecutive_failures",
    "size_bytes",
}
STATUS_VALUES = {"failed": 0, "success": 1, "running": 2}
NUMERIC_FIELDS = (
    "duration_seconds",
    "last_success_timestamp",
    "consecutive_failures",
    "size_bytes",
)


class BackupJobCollector:
    """Reads one JSON status file per backup job from status_dir and exposes
    them as nusabackup_backup_job_* Prometheus gauges. Re-reads the
    directory on every collect() call, so it is always current as of the
    last Prometheus scrape, with no background thread or caching."""

    def __init__(self, status_dir):
        self.status_dir = Path(status_dir)

    def collect(self):
        status = GaugeMetricFamily(
            "nusabackup_backup_job_status",
            "Status job backup terakhir (1=success, 0=failed, 2=running)",
            labels=["job_name"],
        )
        duration = GaugeMetricFamily(
            "nusabackup_backup_job_duration_seconds",
            "Durasi eksekusi job backup terakhir, dalam detik",
            labels=["job_name"],
        )
        last_success = GaugeMetricFamily(
            "nusabackup_backup_job_last_success_timestamp_seconds",
            "Unix timestamp job backup terakhir sukses (0 jika belum pernah sukses)",
            labels=["job_name"],
        )
        consecutive_failures = GaugeMetricFamily(
            "nusabackup_backup_job_consecutive_failures",
            "Jumlah kegagalan berturut-turut job backup",
            labels=["job_name"],
        )
        size = GaugeMetricFamily(
            "nusabackup_backup_job_size_bytes",
            "Ukuran data yang di-backup pada eksekusi terakhir, dalam bytes",
            labels=["job_name"],
        )

        for record in self._read_status_records():
            job_name = record["job_name"]
            status.add_metric([job_name], STATUS_VALUES[record["status"]])
            duration.add_metric([job_name], record["duration_seconds"])
            last_success.add_metric([job_name], record["last_success_timestamp"])
            consecutive_failures.add_metric([job_name], record["consecutive_failures"])
            size.add_metric([job_name], record["size_bytes"])

        yield status
        yield duration
        yield last_success
        yield consecutive_failures
        yield size

    def _read_status_records(self):
        if not self.status_dir.is_dir():
            logger.warning("status_dir %s does not exist", self.status_dir)
            return

        seen_job_names = set()

        for path in sorted(self.status_dir.glob("*.json")):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    record = json.load(f)
            except (json.JSONDecodeError, OSError) as exc:
                logger.warning("skipping %s: %s", path, exc)
                continue

            if not isinstance(record, dict):
                logger.warning(
                    "skipping %s: expected a JSON object at top level, got %s",
                    path, type(record).__name__,
                )
                continue

            missing = REQUIRED_FIELDS - record.keys()
            if missing:
                logger.warning("skipping %s: missing fields %s", path, sorted(missing))
                continue

            if record["status"] not in STATUS_VALUES:
                logger.warning("skipping %s: invalid status %r", path, record["status"])
                continue

            if not isinstance(record["job_name"], str):
                logger.warning(
                    "skipping %s: job_name must be a string, got %s",
                    path, type(record["job_name"]).__name__,
                )
                continue

            invalid_numeric = False
            for field in NUMERIC_FIELDS:
                try:
                    record[field] = float(record[field])
                except (TypeError, ValueError):
                    logger.warning(
                        "skipping %s: field %s has non-numeric value %r",
                        path, field, record[field],
                    )
                    invalid_numeric = True
                    break
            if invalid_numeric:
                continue

            # job_name identifies the series, not the filename, so two files
            # could declare the same job_name. Emitting duplicate label sets
            # in one metric family makes Prometheus reject the whole scrape,
            # so we keep the first record seen (by sorted filename order) and
            # skip/warn on later duplicates.
            if record["job_name"] in seen_job_names:
                logger.warning(
                    "skipping %s: duplicate job_name %r already seen in this collection",
                    path, record["job_name"],
                )
                continue
            seen_job_names.add(record["job_name"])

            yield record
