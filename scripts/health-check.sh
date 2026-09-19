#!/usr/bin/env bash
set -uo pipefail

restart_threshold="${HEALTH_RESTART_THRESHOLD:-5}"
failed=()

check_host() {
    local host="$1" target out
    target=$(just admin _target "$host")
    # heredoc is quoted ('REMOTE') so it runs server-side verbatim; restart_threshold is passed as $1 rather than interpolated, so no client/server escaping to track.
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" bash -s -- "$restart_threshold" <<'REMOTE'
set -uo pipefail
restart_threshold="$1"
systemctl --failed --no-legend --plain | sed 's/^/  failed: /'
for u in $(systemctl list-units --type=service --no-legend --plain --state=running,activating 2>/dev/null | awk '{print $1}'); do
  n=$(systemctl show "$u" -p NRestarts --value 2>/dev/null || echo 0)
  [ "$n" -gt "$restart_threshold" ] && echo "  crash-looping: $u: $n restarts"
done
true
REMOTE
    ) || {
        echo "==> ${host}: unreachable"
        return 1
    }

    if [ -z "$out" ]; then
        echo "==> ${host}: OK"
        return 0
    fi

    echo "==> ${host}: UNHEALTHY"
    echo "$out"
    return 1
}

# obs-0-specific: catches the pieces that can be "active" while functionally dead.
check_obs0_functional() {
    local target
    target=$(just admin _target minz-obs-0)
    local out
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" bash -s <<'REMOTE'
set -uo pipefail
grafana_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:3000/api/health 2>/dev/null)
loki_result=$(curl -s --max-time 5 --get "http://127.0.0.1:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum(count_over_time({job="systemd-journal"}[10m]))' 2>/dev/null \
  | grep -oE '"result":\[[^]]*\]')
vm_up=$(curl -s --max-time 5 "http://127.0.0.1:9090/api/v1/query?query=up" 2>/dev/null \
  | grep -o '"value":\[[0-9.]*,"0"\]' | wc -l)
echo "grafana_code=${grafana_code:-none}"
if [ "$loki_result" = '"result":[]' ] || [ -z "$loki_result" ]; then
  echo "loki_recent=empty"
else
  echo "loki_recent=data"
fi
echo "vm_targets_down=${vm_up:-0}"
REMOTE
    ) || { echo "==> obs-0 functional checks: unreachable"; return 1; }

    echo "$out"
    local rc=0
    echo "$out" | grep -q "grafana_code=200" || { echo "  Grafana not returning 200"; rc=1; }
    echo "$out" | grep -q "loki_recent=empty" && { echo "  Loki has no ingestion in the last 10m"; rc=1; }
    echo "$out" | grep -q "vm_targets_down=0" || { echo "  VictoriaMetrics has scrape targets down"; rc=1; }
    return $rc
}

for host in $(just deploy list); do
    check_host "$host" || failed+=("$host")
done

echo "==> obs-0 functional checks"
check_obs0_functional || failed+=("obs-0-functional")

if [ "${#failed[@]}" -gt 0 ]; then
    echo "Failed: ${failed[*]}" >&2
    exit 1
fi

echo "All hosts healthy."
