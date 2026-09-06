# Gemini STT quality spike

Test Google's `gemini-3.5-transcribe` **before** wiring it into MyWhisperFlow.

## 1. Get a free API key

1. Open [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
2. Sign in → **Create API key**
3. Save it (do not commit it):

```bash
cd /Users/princetholia/Desktop/Projects/Real/goon-whisper
echo 'GEMINI_API_KEY=paste_here' > .env
```

Or: `export GEMINI_API_KEY='…'`

## 2. Record a real dictation clip

Speak like you would into Whisper: a name, a filler (“um”), a product/code term.

```bash
cd /Users/princetholia/Desktop/Projects/Real/goon-whisper
./scripts/record_sample.sh            # ~20s → samples/dictation-….wav
# or: ./scripts/record_sample.sh samples/mine.wav 25
afplay samples/dictation-*.wav        # listen back
```

If ffmpeg complains about the mic device, list them and edit the `-i` index:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

## 3. Transcribe

```bash
.venv/bin/python scripts/test_gemini_stt.py samples/dictation-….wav
.venv/bin/python scripts/test_gemini_stt.py samples/dictation-….wav --mode smart
.venv/bin/python scripts/test_gemini_stt.py samples/dictation-….wav --mode verbatim --vocab WhisperApp Cursor
```

Judge: accuracy, punctuation, latency, weird names/code. Same file through Groq later for a side-by-side.

## Rate limits / cost

- Free tier works without billing for this spike (check your caps in AI Studio).
- Paid ballpark for recorded transcribe is about **$0.005/min**.
- Exact RPM/TPM: [AI Studio rate limits](https://aistudio.google.com/rate-limit).

When quality looks good enough, we integrate this into MyWhisperFlow (Fn + paste stay; swap STT backend).
