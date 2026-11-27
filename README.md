# Murmur

Murmur is a local transcription app for Apple silicon Macs. The app itself is about 10 MB. It lives in the menu bar, runs a small speech model on the GPU, and pastes the words where your cursor already is. Audio stays on this Mac.

Two jobs share that idea. Dictation is the one you keep running: hold a key, speak, get text. File transcription is optional, for a recording you already have, and it loads only while that window is open.

## Dictate

Hold **Left ⌥ Option** and speak. Release to insert the text. Double-tap Option to keep listening, then tap once to finish, or press Esc to cancel.

A press shorter than a fifth of a second is treated as a tap, so Option still works inside shortcuts. If Option is held as part of another shortcut, Murmur steps aside. A take needs a little real speech before it is transcribed; a quiet hold is dropped.

While you speak, a small pill shows the level. On release it turns the audio into text and pastes it into the focused app. The same text stays on the clipboard. The recording is written to disk before the model runs, so a failed pass can be tried again from **Retry Last Transcription** in the menu bar.

The first launch asks for three permissions:

| Permission | What it is for |
| --- | --- |
| Microphone | Hears your voice. |
| Input Monitoring | Notices the Left Option key. |
| Accessibility | Pastes the text at the cursor. |

Without Accessibility, the text is still copied. Settings also has sound feedback and open-at-login.

## Transcribe a file

**Transcribe a File…** in the menu bar (or the button in Settings) takes an audio or video file. Drop one on the window, or choose it.

The first time, Murmur downloads two models, about 800 MB, and a small local runtime. They stay in `~/Library/Application Support/Murmur`. Closing the window unloads them. This path wants about 8 GB of memory; below that, the window says so and dictation keeps working.

Two ways through a file:

- **Quick transcript** labels speakers Voice 1, Voice 2, and so on, with punctuation.
- **Name the voices** plays a short sample of each speaker. You name them, and the transcript uses those names.

A long recording is cut at quiet moments, and the same speaker keeps the same label from the start of the file to the end. Copy the result or save it.

WAV, M4A, and the usual video containers that macOS can open work directly. For containers macOS cannot open, such as Matroska, install `ffmpeg`.

## Model

Live dictation uses [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) through [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) on Metal. The weights are the `Q5_K_M` quant, 549 MB:

`~/Library/Application Support/Murmur/models/parakeet-tdt-0.6b-v3-Q5_K_M.gguf`

[Download that file](https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/resolve/main/parakeet-tdt-0.6b-v3-Q5_K_M.gguf) and put it at that path. Murmur loads it at launch and warms the GPU so the first take is already fast. The model reads the language from the audio. It does not translate.

On LibriSpeech test-clean, this quant is about 1.92% word error, in line with NVIDIA’s figure for the full model. That is clean read speech; real dictation varies. The point of the size is that this accuracy fits in a menu-bar app.

Supported languages: Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, and Ukrainian.

File transcription uses a separate pair, downloaded from the app: Parakeet at Q8, which writes the words, and [Nemotron-3 Sortformer](https://huggingface.co/nvidia/Nemotron-3-Diarization), which keeps the voices apart. Dictation never starts that engine.

## Build

Apple silicon, macOS 26.5 or later.

`scripts/build.sh` builds `Murmur.app` and installs it to `~/Applications`. It compiles the vendored transcribe.cpp library when that build is missing, then signs the app with your Apple Development identity when one is available.
