import argparse
import logging
import os
import time

from prometheus_client import REGISTRY, start_http_server

from collector import BackupJobCollector

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def main():
    parser = argparse.ArgumentParser(description="Nusabackup backup-job status exporter")
    parser.add_argument("--port", type=int, default=int(os.environ.get("EXPORTER_PORT", "9301")))
    parser.add_argument("--status-dir", default=os.environ.get("STATUS_DIR", "/status"))
    args = parser.parse_args()

    REGISTRY.register(BackupJobCollector(args.status_dir))
    start_http_server(args.port)
    logging.info(
        "backup-job-exporter listening on :%d, reading status from %s",
        args.port, args.status_dir,
    )

    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
