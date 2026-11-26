#!/usr/bin/env python3
"""ojselect.py — Elige modelo e hilos a partir de un JSON de ojbench.py, con reglas explícitas y auditables.

Regla:
  1. Candidatos: modelos con calidad >= 75 % (6/8 preguntas verificables) y brevedad >= 6/8.
  2. Latencia estimada de un turno de voz = STT p50 + tiempo del modelo p50 (Ollama directo, respuesta completa)
     + sobrecoste del servidor (medido con el modelo configurado: servidor p50 - modelo p50) + 60 % del TTS (las frases
     se sintetizan en paralelo con la generación). Es una estimación: la medición real se hace después con ojvoice.
  3. Si el 4B cumple la meta, se elige el 4B (mejor calidad). Si no, el candidato más rápido que la cumpla.
     Si ninguno la cumple, el candidato más rápido (y se informa que la meta no se alcanzó).
  4. Hilos: el valor con menor tiempo p50 en la prueba de hilos del modelo elegido.
Salida: JSON {model, threads, estimado_ms, meta_ms, cumple_meta, motivo, candidatos}
"""
import json, sys

bench = json.load(open(sys.argv[1])); target = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
stt = (bench.get("stt_ms") or {}).get("p50", 0); tts = (bench.get("tts_ms") or {}).get("p50", 0)
cands = []
srv = bench.get("servidor") or {}
srv_model = (srv.get("modelo") or "").replace("jarvis-voz:", "qwen3.5:")
overhead = 0
if srv.get("ms") and srv_model in bench.get("modelos", {}) and bench["modelos"][srv_model].get("modelo_ms"):
    overhead = max(0, srv["ms"]["p50"] - bench["modelos"][srv_model]["modelo_ms"]["p50"])
for m, R in bench.get("modelos", {}).items():
    if "calidad_pct" not in R or not R.get("modelo_ms"):
        continue
    est = stt + R["modelo_ms"]["p50"] + overhead + 0.6 * tts
    brev = int(R.get("brevedad", "0/8").split("/")[0])
    ok = R["calidad_pct"] >= 75 and brev >= 6
    hilos = R.get("hilos") or {}
    best_t = min(hilos, key=lambda k: (hilos[k].get("wall_ms") or {}).get("p50", 1e12)) if hilos else None
    cands.append({"model": m, "calidad_pct": R["calidad_pct"], "brevedad": R.get("brevedad"), "estimado_ms": round(est),
                  "modelo_p50_ms": R["modelo_ms"]["p50"], "sobrecoste_servidor_ms": round(overhead), "apto_calidad": ok, "mejores_hilos": best_t})
apt = [c for c in cands if c["apto_calidad"]] or cands
if not apt:
    print(json.dumps({"error": "sin datos de modelos en el benchmark"})); sys.exit(1)
four = [c for c in apt if c["model"].endswith(":4b") and c["estimado_ms"] <= target]
meet = sorted([c for c in apt if c["estimado_ms"] <= target], key=lambda c: c["estimado_ms"])
if four:
    pick, why = four[0], "el 4B cumple la meta con la mejor calidad"
elif meet:
    pick, why = meet[0], "el modelo más rápido que cumple la meta con calidad suficiente"
else:
    pick = sorted(apt, key=lambda c: c["estimado_ms"])[0]; why = "ningún modelo cumple la meta en este hardware: se elige el más rápido con calidad suficiente"
print(json.dumps({"model": pick["model"], "threads": int(pick["mejores_hilos"]) if pick["mejores_hilos"] else None,
                  "estimado_ms": pick["estimado_ms"], "meta_ms": target, "cumple_meta": pick["estimado_ms"] <= target,
                  "motivo": why, "candidatos": cands}, ensure_ascii=False))
