#!/usr/bin/env bash
# T12: carga ligera continua + muestreo de recursos. Uso: stability.sh MINUTOS
DUR=$(( ${1:-32} * 60 )); END=$(( $(date +%s) + DUR )); OUT=/opt/oj/evidence/T12
mkdir -p $OUT; : > $OUT/requests.csv; : > $OUT/resources.csv
echo "ts,i,http,latency_s,ok,answer" > $OUT/requests.csv
echo "ts,total_rss_mb,server_rss_mb,ollama_rss_mb,runner_rss_mb,cpu_pct_jarvis_user,mem_avail_mb" > $OUT/resources.csv
sample() { while [ $(date +%s) -lt $END ]; do
  s=$(ps -u jarvis -o rss=,pcpu=,comm= | awk '{t+=$1;c+=$2; if($3=="jarvis")j+=$1; if($3=="ollama")o+=$1; if($3=="llama-server")r+=$1} END{printf "%d,%d,%d,%d,%.1f",t/1024,j/1024,o/1024,r/1024,c}')
  echo "$(date -u +%FT%TZ),$s,$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)" >> $OUT/resources.csv; sleep 30; done; }
sample & i=0
while [ $(date +%s) -lt $END ]; do i=$((i+1)); a=$((RANDOM%50)); b=$((RANDOM%50)); t0=$(date +%s.%N)
  r=$(curl -s -m 240 -w '\n%{http_code}' http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' \
     -d "{\"model\":\"qwen3.5:2b\",\"messages\":[{\"role\":\"user\",\"content\":\"Cuanto es $a + $b? Responde solo el numero.\"}]}")
  code=$(echo "$r" | tail -1); lat=$(echo "$(date +%s.%N) - $t0" | bc)
  ans=$(echo "$r" | head -n -1 | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'].strip().replace(',',' ')[:40])" 2>/dev/null)
  ok=$( [ "$(echo "$ans" | grep -o '[0-9]\+' | head -1)" = "$((a+b))" ] && echo 1 || echo 0)
  echo "$(date -u +%FT%TZ),$i,$code,$lat,$ok,$ans" >> $OUT/requests.csv
  sleep 60; done
wait; echo DONE $(date -u +%FT%TZ) >> $OUT/requests.csv
