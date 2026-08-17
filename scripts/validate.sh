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
done < <(find . -type f \( -name "*.yml" -o -name "*.yaml" -o -name "*.yml.example" -o -name "*.yaml.example" \) -not -path "./.git/*" -print0)

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
