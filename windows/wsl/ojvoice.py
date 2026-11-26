#!/usr/bin/env python3
"""ojvoice.py — Turno de voz de JARVIS de baja latencia, 100 % local (Fase 2C).

Flujo: WAV (stdin) -> STT -> LLM en streaming por el camino directo del servidor (memoria inyectada y registrada
por OpenJarvis, sin agente ni herramientas) -> cada frase completa se sintetiza (TTS) en paralelo mientras el
modelo sigue generando -> audio a stdout.

Uso:
  ojvoice.py [--frames] < pregunta.wav > respuesta.(wav|frames)
  ojvoice.py --text "pregunta" [--frames]
  --frames : salida por fragmentos para reproducir la primera frase antes de terminar: repetido
             b"OJWV" + uint32 little-endian longitud + WAV ; final b"OJWE" + uint32(0)
             (sin --frames: un único WAV con todas las frases concatenadas)
stderr: "TÚ: …", "JARVIS: …", "TIEMPOS: …", "ERROR: …"
Códigos: 0 ok · 2 sin audio · 10 servidor caído · 11 STT · 12 inferencia · 13 TTS
"""
import io, json, os, re, struct, sys, threading, time, uuid, urllib.error, urllib.request, wave

API = os.environ.get("OJ_API", "http://127.0.0.1:8000")
HOME = os.environ.get("OPENJARVIS_HOME", os.path.expanduser("~/.openjarvis"))
VOICE = os.environ.get("OJ_VOICE", "ef_dora")
MAX_TOKENS = int(os.environ.get("OJ_VOICE_MAX_TOKENS", "160"))
HIST = os.path.join(HOME, "voice_history.jsonl")
SYSTEM = ("Eres JARVIS, asistente personal de Jerónimo. Responde en español, en una o dos frases cortas, "
          "en texto plano apto para leerse en voz alta, sin markdown, listas ni emojis.")
T0 = time.monotonic()
ms = lambda: int((time.monotonic() - T0) * 1000)
timing = {}


def say(s):
    print(s, file=sys.stderr, flush=True)


def die(code, msg):
    say(f"ERROR: {msg}")
    sys.exit(code)


def model_name():
    m = os.environ.get("OJ_MODEL")
    if m:
        return m
    try:
        for line in open(os.path.join(HOME, "config.toml"), encoding="utf-8"):
            mm = re.match(r'\s*default_model\s*=\s*"([^"]+)"', line)
            if mm:
                return mm.group(1)
    except OSError:
        pass
    return "qwen3.5:2b"


def http(method, path, body=None, ctype="application/json", timeout=300):
    """Devuelve (código, bytes). Nunca lanza por errores HTTP: el cuerpo del error se conserva."""
    req = urllib.request.Request(API + path, data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # conexión rechazada, timeout…
        return 0, str(e).encode()


def short(b):
    return b[:300].decode("utf-8", "replace").replace("\n", " ")


def multipart(field, filename, data, extra):
    boundary = uuid.uuid4().hex
    parts = []
    for k, v in extra.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
                 f'Content-Type: audio/wav\r\n\r\n'.encode() + data + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def tts(text):
    code, data = http("POST", "/v1/speech/synthesize", json.dumps({"text": text[:1500], "voice_id": VOICE}).encode())
    if code != 200 or data[:4] != b"RIFF":
        raise RuntimeError(f"síntesis de voz falló (HTTP {code}): {short(data)}")
    return data


def join_wavs(chunks):
    out = io.BytesIO()
    params, frames = None, []
    for c in chunks:
        with wave.open(io.BytesIO(c)) as w:
            params = params or w.getparams()
            frames.append(w.readframes(w.getnframes()))
    with wave.open(out, "wb") as w:
        w.setparams(params)
        for f in frames:
            w.writeframes(f)
    return out.getvalue()


def main():
    args = sys.argv[1:]
    frames_mode = "--frames" in args
    out = sys.stdout.buffer
    code, data = http("GET", "/health", timeout=10)
    if code != 200:
        die(10, f"el servidor JARVIS no responde (HTTP {code}). Ejecute Repair-OpenJarvisLab.ps1.")

    # 1) STT
    if "--text" in args:
        user_text = args[args.index("--text") + 1]
        timing["stt_ms"] = 0
    else:
        audio = sys.stdin.buffer.read()
        if len(audio) < 1000:
            die(2, "no se recibió audio del micrófono (archivo vacío)")
        t = ms()
        body, ctype = multipart("file", "in.wav", audio, {"language": "es"})
        code, data = http("POST", "/v1/speech/transcribe", body, ctype)
        if code != 200:
            die(11, f"transcripción falló (HTTP {code}): {short(data)}")
        try:
            user_text = json.loads(data).get("text", "").strip()
        except ValueError:
            die(11, f"transcripción devolvió datos no válidos: {short(data)}")
        timing["stt_ms"] = ms() - t
    if not user_text.strip():
        die(11, "no se entendió nada en el audio (¿micrófono silenciado?)")
    say(f"TÚ: {user_text}")

    # 2) LLM en streaming + 3) TTS por frase en paralelo
    msgs = [{"role": "system", "content": SYSTEM}]
    try:
        for line in open(HIST, encoding="utf-8").read().splitlines()[-8:]:
            try:
                msgs.append(json.loads(line))
            except ValueError:
                pass
    except OSError:
        pass
    msgs.append({"role": "user", "content": user_text})
    req = urllib.request.Request(API + "/v1/chat/completions", method="POST",
                                 data=json.dumps({"model": model_name(), "messages": msgs, "stream": True,
                                                  "max_tokens": MAX_TOKENS, "temperature": 0.3}).encode())
    req.add_header("Content-Type", "application/json")
    t_llm = ms()
    sentences, threads, results, errors, emitted = [], [], {}, [], [0]
    lock = threading.Lock()

    def synth(i, text):
        t = ms()
        try:
            results[i] = tts(text)
        except Exception as e:  # noqa: BLE001
            errors.append(str(e))
        with lock:
            timing.setdefault("tts_ms_por_frase", []).append(ms() - t)

    def emit_ready():  # en modo fragmentos, enviar en orden lo que ya esté sintetizado
        while emitted[0] in results:
            if emitted[0] == 0 and frames_mode:
                timing["primera_voz_ms"] = ms()
            if frames_mode:
                out.write(b"OJWV" + struct.pack("<I", len(results[emitted[0]])) + results[emitted[0]]); out.flush()
            emitted[0] += 1

    def push(text):
        text = re.sub(r"[*#_`>]+", "", text).strip()
        if not text:
            return
        i = len(sentences); sentences.append(text)
        th = threading.Thread(target=synth, args=(i, text)); th.start(); threads.append(th)

    buf, full = "", ""
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                    delta = chunk["choices"][0].get("delta", {}).get("content") or ""
                except (ValueError, KeyError, IndexError):
                    die(12, f"respuesta de inferencia no válida: {payload[:200]}")
                if delta and "llm_primer_token_ms" not in timing:
                    timing["llm_primer_token_ms"] = ms() - t_llm
                buf += delta; full += delta
                while True:  # cortar en fin de frase
                    m = re.search(r"[\.\!\?¡¿…:;](\s|$)", buf)
                    if not m or len(buf[:m.end()].strip()) < 12:
                        break
                    push(buf[:m.end()]); buf = buf[m.end():]
                emit_ready()
    except urllib.error.HTTPError as e:
        die(12, f"inferencia falló (HTTP {e.code}, modelo {model_name()}): {short(e.read())}")
    except Exception as e:  # noqa: BLE001
        die(12, f"inferencia falló (modelo {model_name()}): {e}")
    push(buf)
    timing["llm_ms"] = ms() - t_llm
    answer = re.sub(r"[*#_`>]+", "", full).strip()
    if not answer:
        die(12, "el modelo devolvió una respuesta vacía")
    say(f"JARVIS: {answer}")
    t_wait = ms()
    for th in threads:
        th.join()
    if errors:
        die(13, errors[0])
    timing["tts_espera_tras_llm_ms"] = ms() - t_wait
    emit_ready()
    if frames_mode:
        out.write(b"OJWE" + struct.pack("<I", 0)); out.flush()
    else:
        timing.setdefault("primera_voz_ms", ms())
        out.write(join_wavs([results[i] for i in range(len(sentences))])); out.flush()
    timing["total_ms"] = ms()
    try:
        os.makedirs(HOME, exist_ok=True)
        with open(HIST, "a", encoding="utf-8") as f:
            f.write(json.dumps({"role": "user", "content": user_text}, ensure_ascii=False) + "\n")
            f.write(json.dumps({"role": "assistant", "content": answer}, ensure_ascii=False) + "\n")
    except OSError as e:
        say(f"AVISO: no se pudo guardar el historial de voz: {e}")
    tf = timing.pop("tts_ms_por_frase", [])
    timing["tts_ms_primera_frase"] = tf[0] if tf else 0
    timing["frases"] = len(sentences)
    say("TIEMPOS: " + " ".join(f"{k}={v}" for k, v in timing.items()))


if __name__ == "__main__":
    main()
