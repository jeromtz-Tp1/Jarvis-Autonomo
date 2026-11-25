#!/usr/bin/env bash
# openclaw_readonly_inventory.sh — Inventario de SOLO LECTURA del servidor de OpenClaw (Fase 2A).
#
# Garantías (revisables leyendo este archivo):
#   - No instala, no escribe fuera de un archivo de salida en /tmp, no reinicia ni modifica servicios.
#   - No usa sudo. Ejecutar como un usuario normal (idealmente el que corre OpenClaw).
#   - No lee archivos de configuración, .env, claves, tokens ni variables de entorno de procesos.
#   - Las líneas de comando de procesos se truncan y se redactan patrones tipo token/clave/contraseña.
#   - No hace conexiones de red salvo a 127.0.0.1 para comprobar puertos locales ya abiertos.
#   - Duración ~30 s (incluye 10 s de muestreo de CPU con vmstat).
# Uso:   bash openclaw_readonly_inventory.sh      -> imprime la ruta del informe /tmp/oc_inventory_<fecha>.txt
# Revise el informe antes de compartirlo. Elimínelo después: rm /tmp/oc_inventory_*.txt
set -u
export LC_ALL=C
OUT="/tmp/oc_inventory_$(date -u +%Y%m%dT%H%M%SZ).txt"
umask 077
redact() { sed -E 's/((key|token|secret|passw(or)?d|pwd|auth|bearer|api[_-]?key)[=: ]+)[^ ]+/\1<REDACTED>/Ig; s/(sk|xox[abp]|ghp|gho|hf|AKIA)[-_A-Za-z0-9]{8,}/<REDACTED>/g'; }
sec() { printf '\n===== %s =====\n' "$1"; }
run() { if command -v "$1" >/dev/null 2>&1; then "$@" 2>&1 | redact; else echo "(no disponible: $1)"; fi; }
{
sec "META"; echo "fecha_utc=$(date -u +%FT%TZ) usuario=$(id -un) uid=$(id -u) grupos=$(id -Gn)"; echo "hostname_hash=$(hostname | sha256sum | cut -c1-12)  (hash, no nombre)"
sec "PROVEEDOR / VIRTUALIZACION"
for f in sys_vendor product_name product_version chassis_vendor bios_vendor; do printf '%s=' "$f"; cat /sys/class/dmi/id/$f 2>/dev/null || echo "n/d"; done
run systemd-detect-virt; command -v cloud-id >/dev/null && cloud-id 2>/dev/null
sec "SISTEMA OPERATIVO"; cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION_ID|ID)='; uname -srm; run systemctl --version | head -1
echo "uptime: $(uptime)"
sec "CPU"; echo "nproc=$(nproc) modelo=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"; command -v lscpu >/dev/null && lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket|Flags' | sed -E 's/^(Flags:).*/\1 avx2='"$(grep -qw avx2 /proc/cpuinfo && echo si || echo no)"' avx512f='"$(grep -qw avx512f /proc/cpuinfo && echo si || echo no)"'/'
sec "CARGA CPU"; echo "loadavg: $(cat /proc/loadavg)"; command -v vmstat >/dev/null && vmstat 2 5
sec "GPU"; if command -v nvidia-smi >/dev/null; then nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv; else echo "sin nvidia-smi"; fi
sec "MEMORIA"; free -m; echo; grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree|Committed_AS' /proc/meminfo
sec "PRESION DE RECURSOS (PSI)"; for r in cpu memory io; do printf '%s: ' $r; cat /proc/pressure/$r 2>/dev/null | head -1 || echo n/d; done
sec "DISCO"; df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null; echo; df -i / 2>/dev/null | tail -1
sec "CGROUPS / LIMITES"; stat -fc %T /sys/fs/cgroup 2>/dev/null; echo "memory.max(raiz)=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo n/d)"; ulimit -a 2>/dev/null | grep -E 'open files|max user processes'
sec "TOP 15 PROCESOS POR MEMORIA (comando truncado y redactado)"; ps -eo user:12,pid,ppid,pcpu,pmem,rss,etime,args --sort=-rss 2>/dev/null | head -16 | cut -c1-160 | redact
sec "TOP 10 PROCESOS POR CPU"; ps -eo user:12,pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -11
sec "SERVICIOS systemd EN EJECUCION"; run systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}'
sec "SERVICIOS systemd FALLIDOS"; run systemctl list-units --state=failed --no-pager --no-legend
sec "SERVICIOS DE USUARIO (systemd --user)"; run systemctl --user list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}'
sec "TIMERS"; run systemctl list-timers --all --no-pager --no-legend | awk '{print $(NF-1), $NF}' | head -30
sec "CRON DEL USUARIO (comandos redactados)"; crontab -l 2>&1 | grep -v '^#' | cut -c1-160 | redact
# Lectura directa de /proc/net/tcp{,6} (estado 0A = LISTEN): no depende de ss/netstat ni de root.
listen() { for f in /proc/net/tcp /proc/net/tcp6; do [ -r "$f" ] || continue
    while read -r _ loc _ st _; do [ "$st" = "0A" ] || continue; ip=${loc%:*}; port=$((16#${loc##*:}))
      case "$ip" in 0100007F|00000000000000000000000001000000) v=loopback;; 00000000|00000000000000000000000000000000) v=TODAS-LAS-INTERFACES;; *) v=ip-especifica;; esac
      echo "$port $v"; done < <(tail -n +2 "$f"); done | sort -n -u; }
sec "PUERTOS TCP EN ESCUCHA (puerto, alcance)"; listen
sec "PUERTOS EXPUESTOS FUERA DE LOOPBACK"; listen | grep -v loopback || echo "ninguno"
sec "DOCKER"; if command -v docker >/dev/null 2>&1; then echo "docker CLI: $(command -v docker)"; timeout 10 docker version --format 'cliente={{.Client.Version}} servidor={{.Server.Version}}' 2>&1 | head -2
  docker info --format 'contenedores={{.Containers}} en_ejecucion={{.ContainersRunning}} imagenes={{.Images}} cgroup={{.CgroupVersion}} rootless={{.SecurityOptions}}' 2>&1 | head -2
  docker ps --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}' 2>&1 | head -40
  docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}' 2>&1 | head -40
  docker system df 2>&1 | head -8; else echo "docker no instalado"; fi
command -v podman >/dev/null && { sec "PODMAN"; podman ps --format '{{.Names}} {{.Image}} {{.Status}}' 2>&1 | head -20; }
sec "OPENCLAW"
ps -eo pid=,user=,etime=,rss=,args= 2>/dev/null | grep -iE 'openclaw|clawdbot|moltbot' | grep -vE "inventory|grep -iE|$$ " | cut -c1-160 | redact; echo "(fin lista procesos openclaw)"
for b in openclaw clawdbot; do command -v $b >/dev/null && echo "$b version: $($b --version 2>&1 | head -1)"; done
for d in "$HOME/.openclaw" "$HOME/.clawdbot"; do [ -d "$d" ] && echo "dir $d existe, tamaño $(du -sh "$d" 2>/dev/null | cut -f1) (contenido NO leído)"; done
command -v node >/dev/null && echo "node $(node --version)"
for p in 18789 18790 3000 8000 8080 11434; do (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null && echo "127.0.0.1:$p abierto" ; done
sec "MODELOS LOCALES EXISTENTES"; command -v ollama >/dev/null && ollama list 2>&1 | head -20 || echo "ollama no instalado"
sec "SEGURIDAD DE RED (sin root: solo lo legible)"
grep -hiE '^\s*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|Port|AllowUsers)\b' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null
command -v ufw >/dev/null && echo "ufw instalado (estado requiere root)"; systemctl is-active fail2ban 2>/dev/null | sed 's/^/fail2ban: /'
systemctl is-active unattended-upgrades 2>/dev/null | sed 's/^/unattended-upgrades: /'
command -v tailscale >/dev/null && echo "tailscale instalado"; command -v cloudflared >/dev/null && echo "cloudflared instalado"
sec "ACTUALIZACIONES PENDIENTES"; [ -f /var/run/reboot-required ] && echo "REINICIO REQUERIDO" || echo "sin reinicio pendiente"
command -v apt >/dev/null && apt list --upgradable 2>/dev/null | tail -n +2 | wc -l | sed 's/^/paquetes actualizables: /'
sec "FIN"
} > "$OUT" 2>&1
echo "Informe: $OUT  ($(wc -l < "$OUT") líneas). Revíselo antes de compartirlo."
