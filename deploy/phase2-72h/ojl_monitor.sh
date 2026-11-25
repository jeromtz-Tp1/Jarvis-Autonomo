#!/usr/bin/env bash
# Muestreo cada 60 s (lanzado por ojl-monitor.timer). Solo lectura + append a CSV. Sin red externa.
set -u
CSV=/opt/oj/logs/trial72h.csv
[ -f "$CSV" ] || echo "ts,health,health_ms,slice_mem_mb,slice_cpu_s,host_memavail_mb,psi_mem_avg60,server_restarts,ollama_restarts,agents_error,disk_free_gb" > "$CSV"
t0=$(date +%s%N); h=$(curl -s -m 10 http://127.0.0.1:8000/health | grep -q '"ok"' && echo ok || echo FAIL); ms=$(( ($(date +%s%N)-t0)/1000000 ))
mem=$(( $(systemctl show openjarvis.slice -p MemoryCurrent --value 2>/dev/null || echo 0) / 1048576 ))
cpu=$(( $(systemctl show openjarvis.slice -p CPUUsageNSec --value 2>/dev/null || echo 0) / 1000000000 ))
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
psi=$(awk '/^some/{split($3,a,"="); print a[2]}' /proc/pressure/memory 2>/dev/null)
rs=$(systemctl show ojl-server.service -p NRestarts --value 2>/dev/null); ro=$(systemctl show ojl-ollama.service -p NRestarts --value 2>/dev/null)
ae=$(curl -s -m 10 http://127.0.0.1:8000/v1/agents/errors | grep -o '"id"' | wc -l)
df=$(df -BG --output=avail /opt/oj | tail -1 | tr -dc 0-9)
echo "$(date -u +%FT%TZ),$h,$ms,$mem,$cpu,$avail,${psi:-na},${rs:-na},${ro:-na},$ae,$df" >> "$CSV"
