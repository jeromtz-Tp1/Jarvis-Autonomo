#!/usr/bin/env bash
# Control del entorno de PRUEBAS OpenJarvis (solo /opt/oj). Uso: ojctl.sh start|stop|restart|status
# Ejecutar como root (lanza procesos como usuario sin privilegios 'jarvis') o como 'jarvis'.
set -u
L=/opt/oj/logs
RUN() { if [ "$(id -un)" = jarvis ]; then bash -c "$1"; else runuser -u jarvis -- bash -c "$1"; fi; }
ENV="source /opt/oj/bin/ojenv.sh; ulimit -n 4096; cd /opt/oj/workspace"
alive() { [ -f "$L/$1.pid" ] && kill -0 "$(cat $L/$1.pid)" 2>/dev/null; }
start() {
  alive ollama || RUN "$ENV; nohup nice -n 5 /opt/oj/ollama/bin/ollama serve >>$L/ollama.log 2>&1 & echo \$! > $L/ollama.pid"
  for i in $(seq 1 30); do curl -s -m 2 http://127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done
  alive server || RUN "$ENV; nohup nice -n 5 /opt/oj/venv/bin/jarvis serve --host 127.0.0.1 --port 8000 >>$L/server.log 2>&1 & echo \$! > $L/server.pid"
  for i in $(seq 1 120); do curl -s -m 2 http://127.0.0.1:8000/health >/dev/null && break; sleep 1; done
  status
}
stop() {
  for s in server ollama; do
    if alive $s; then p=$(cat $L/$s.pid); kill -TERM "$p"; for i in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 1; done; kill -0 "$p" 2>/dev/null && kill -KILL "$p"; fi
    rm -f $L/$s.pid
  done; echo "stopped"
}
status() {
  echo "ollama: $(curl -s -m 3 http://127.0.0.1:11434/api/version || echo DOWN) pid=$(cat $L/ollama.pid 2>/dev/null)"
  echo "server: $(curl -s -m 5 http://127.0.0.1:8000/health || echo DOWN) pid=$(cat $L/server.pid 2>/dev/null)"
}
case "${1:-status}" in start) start;; stop) stop;; restart) stop; start;; status) status;; *) echo "uso: $0 start|stop|restart|status"; exit 2;; esac
