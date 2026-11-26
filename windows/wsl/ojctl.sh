#!/usr/bin/env bash
# ojctl.sh start|stop|restart|status — control de OpenJarvisLab. Código de salida != 0 si algo no está sano.
# Instalado en @PREFIX@/bin por setup_lab.sh / repair_lab.sh (los marcadores se sustituyen al instalar).
PREFIX=@PREFIX@; OJUSER=@OJUSER@; L=$PREFIX/logs
sysd() { [ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ] && [ -f /etc/systemd/system/ojl-server.service ]; }
health() { curl -s -m 5 http://127.0.0.1:8000/health | grep -q '"ok"'; }
RUN() { runuser -u "$OJUSER" -- bash -c "cd '$PREFIX/workspace'; export UV_NO_CONFIG=1; source '$PREFIX/bin/ojenv.sh'; $1"; }
alive() { [ -f "$L/$1.pid" ] && kill -0 "$(cat "$L/$1.pid")" 2>/dev/null; }
start() {
  if sysd; then systemctl start ojl-ollama.service ojl-server.service ojl-monitor.timer
  else
    alive ollama || RUN "nohup $PREFIX/ollama/bin/ollama serve >>$L/ollama.log 2>&1 & echo \$! > $L/ollama.pid"
    for _ in $(seq 30); do curl -s -m 2 http://127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done
    alive server || RUN "nohup $PREFIX/venv/bin/jarvis serve --host 127.0.0.1 --port 8000 >>$L/server.log 2>&1 & echo \$! > $L/server.pid"
  fi
  for _ in $(seq 240); do health && break; sleep 1; done
}
stop() {
  if sysd; then systemctl stop ojl-monitor.timer ojl-server.service ojl-ollama.service
  else for s in server ollama; do alive $s && kill "$(cat "$L/$s.pid")"; rm -f "$L/$s.pid"; done; sleep 2; pkill -u "$OJUSER" -f llama-server || true; fi
}
status() {
  local o s; o=$(curl -s -m 3 http://127.0.0.1:11434/api/version || echo DOWN); s=$(curl -s -m 5 http://127.0.0.1:8000/health || echo DOWN)
  echo "ollama: $o"; echo "server: $s"
  if sysd; then for u in ojl-ollama ojl-server ojl-monitor.timer; do echo "$u: $(systemctl is-active $u)"; done; fi
  health
}
case "${1:-status}" in
  start) start; status;; stop) stop; echo stopped;; restart) stop; start; status;; status) status;;
  *) echo "uso: $0 start|stop|restart|status"; exit 2;;
esac
