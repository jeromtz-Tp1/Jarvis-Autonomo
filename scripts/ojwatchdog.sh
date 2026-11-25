#!/usr/bin/env bash
# Watchdog del entorno de PRUEBAS: cada 15 s comprueba salud; si falla 2 veces seguidas, reinicia.
fails=0
while true; do
  if curl -s -m 10 http://127.0.0.1:8000/health | grep -q ok && curl -s -m 5 http://127.0.0.1:11434/api/version >/dev/null; then fails=0
  else fails=$((fails+1)); echo "$(date -u +%FT%TZ) health FAIL ($fails)"; fi
  if [ $fails -ge 2 ]; then echo "$(date -u +%FT%TZ) RESTART"; /opt/oj/bin/ojctl.sh stop >/dev/null; /opt/oj/bin/ojctl.sh start; fails=0; fi
  sleep 15
done
