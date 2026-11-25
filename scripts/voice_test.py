"""T06/T07: TTS (Kokoro, backend de OpenJarvis) -> WAV -> STT (faster-whisper, backend de OpenJarvis)."""
import sys, time, json, wave
from pathlib import Path
from openjarvis.speech.kokoro_tts import KokoroTTSBackend
from openjarvis.speech.faster_whisper import FasterWhisperBackend
out = Path("/opt/oj/evidence/audio"); res = {}
cases = [("af_heart", "en", "Hello Jarvis. The synthetic invoice total is four hundred twenty dollars."),
         ("ef_dora", "es", "Hola Jarvis. El reporte de cobranza de prueba está listo.")]
stt = FasterWhisperBackend(model_size=sys.argv[1] if len(sys.argv) > 1 else "base", device="cpu", compute_type="int8")
tts = KokoroTTSBackend()
for voice, lang, text in cases:
    r = {"voice": voice, "text_in": text}
    try:
        t = time.time(); tr = tts.synthesize(text, voice_id=voice); r["tts_s"] = round(time.time()-t, 2)
        p = out / f"tts_{voice}.wav"; tr.save(p); r["wav"] = str(p)
        with wave.open(str(p)) as w: r["audio_s"] = round(w.getnframes()/w.getframerate(), 2); r["rate"] = w.getframerate()
        t = time.time(); s = stt.transcribe(p.read_bytes(), format="wav", language=lang); r["stt_s"] = round(time.time()-t, 2)
        r["text_out"] = s.text; r["lang"] = s.language
    except Exception as e:
        r["error"] = f"{type(e).__name__}: {e}"
    res[voice] = r
print(json.dumps(res, ensure_ascii=False, indent=1))
