#!/usr/bin/env bash
# ojvoice.sh — envoltorio estable (lo invoca Talk-Jarvis.ps1). La lógica está en ojvoice.py (Fase 2C:
# streaming directo, TTS por frase en paralelo, tiempos por etapa, errores HTTP visibles).
exec /usr/bin/python3 "$(dirname "$(readlink -f "$0")")/ojvoice.py" "$@"
