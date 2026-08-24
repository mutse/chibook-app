# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

chibook is a local-first Flutter reading + text-to-speech ("听书") app for Android/iOS. Imported books, highlights and settings live only on the device. An optional WeRead integration adds QR login, the user's remote shelf, and on-demand chapter reading; there is still no bookstore or social layer. UI strings and project docs are in Chinese.

Two docs define intent and are worth reading before non-trivial work:
- `README.md` — implemented feature list and the reasoning behind the EPUB/PDF/TTS trade-offs.
- `docs/flutter-reader-prompt.md` — the authoritative spec: product scope boundaries, "technical facts that must be respected", persistence compatibility rules, priorities (P0–P2), and acceptance scenarios for playback. Treat its constraints as binding.
- `docs/erdu-mockup.html` — the visual/interaction reference the UI is built against.

## Commands

```bash
flutter pub get
flutter run

flutter analyze                                    # must stay at "No issues found!"
flutter test                                       # whole suite
flutter test test/models_test.dart                 # single file
flutter test --plain-name "listening record round-trip keeps duration"   # single test

flutter build apk --debug
flutter build ios --debug --no-codesign
```

Tests are pure-Dart (`package:test`, no widget tests yet), so `dart test test/models_test.dart` also works.

CI (`.github/workflows/mobile.yml`) pins Flutter **3.41.4** and runs `flutter analyze` + `flutter test`, then release APK and unsigned IPA builds; `v*` tags publish a GitHub Release. First PDF-capable build on a new machine downloads PDFium binaries via `pdfrx` — slow, not hung.

## Architecture

### Single state source, single playback source

Two globals own everything:

1. **`appControllerProvider`** (`lib/app/app_state.dart`) — one Riverpod `Notifier<AppState>` holding books, reader settings, TTS settings, highlights, audio progress, and listening records. It delegates all I/O to `BookRepository` and is the only writer of persisted state. Pages read via `ref.watch(appControllerProvider.select(...))`; they never persist directly.
2. **`ttsAudioHandler`** (`lib/services/tts_audio_handler.dart`) — a late-final global `BaseAudioHandler` created in `main()` via `AudioService.init`, before `runApp`. It is the *only* owner of playing/chapter/character-offset/speed/mode.

Pages subscribe to `ttsAudioHandler.playbackState` and `ttsAudioHandler.customEvent` and send intents back (`play`, `pause`, `playChapter`, `seekToCharacter`, …). Do **not** cache a page-level copy of playback state, and do not add a second playback path — the full player, the mini player in `AppShell`, the reader's highlight follow, and the OS media controls all consume the same streams.

`customEvent` is an untyped map bus with `type` ∈ `progress | chapter | mode | loading | error | sleepComplete`, plus `bookId`, `chapter`, `start`, `end`, `speed`, `mode`. `AppShell` (`lib/app/app_router.dart`) debounces those events by 1s and writes position back through `AppController.updateProgress` / `saveAudioPosition`.

### Routing

`go_router` in `lib/app/app_router.dart`: a `StatefulShellRoute.indexedStack` with three branches (`/reading`, `/shelf` + nested `/shelf/search`, `/profile`), plus root-navigator full-screen routes `/reader/:id`, `/player/:id`, `/settings/tts`, and `/splash` as the initial location. The shell's `bottomNavigationBar` hosts both the mini player and the `NavigationBar`, which is why the mini player survives tab switches.

### Two readers, deliberately separate

`ReaderPage` dispatches on `book.format`:
- **`ReflowReaderPage`** — TXT/EPUB. Chapters are a `PageView`; positions are *chapter index + character offset*. Font size, line height, and theme apply here.
- **`PdfReaderPage`** — PDF via `pdfrx`/PDFium, fixed layout. Positions are *page number + normalized rect*. Zoom and paging only.

`ReadingLocation` (`lib/core/models.dart`) encodes this split with two named constructors (`.text` / `.pdf`) discriminated by `ReadingLocationKind`. Keep them separate: don't apply reflow settings to PDF, and don't fabricate character offsets for PDF pages.

### Import and parsing (`lib/data/book_repository.dart`)

Imports copy the picked file into `<appDocuments>/library/<uuid>.<ext>` and parse it to `List<Chapter>` at import time — the reader and TTS only ever see plain text.
- **TXT** — UTF-8 with latin1 fallback, split on `第…章/节/回` or `Chapter N`; a single-part result becomes one `正文` chapter.
- **EPUB** — no WebView. Reads the ZIP directly: `META-INF/container.xml` → OPF → manifest + spine order → XHTML → plain text. Complex CSS/floats/footnotes are intentionally lost; this is what lets themes, selection, highlights, and TTS share one position model.
- **PDF** — per-page text extraction filtered through `lib/core/pdf_text.dart`. `isGarbledPdfText` rejects a page whose font has no ToUnicode CMap (PDFium then returns NUL/PUA code points — non-empty but unreadable, very common in Chinese PDFs); `cleanPdfPageText` normalizes both the text layer and the OCR result (drops unmapped glyphs, removes PDFium's inter-ideograph spaces, rejoins hard-wrapped lines). Empty **and** garbled pages fall back to on-device Google ML Kit Chinese OCR (`lib/services/pdf_ocr_service.dart`, Android/iOS only); when OCR also comes back empty the page is stored empty on purpose — a garbled page must never be persisted, TTS would read it aloud. One page = one `Chapter`.

`loadBooks()` returns `demoBooks` (bundled sample library) when nothing is stored or decoding fails.

### WeRead integration

`lib/services/weread_service.dart` owns the optional WeRead Web session, QR login protocol, shelf/catalog calls, content-shard signing and decoding. Cookies and account metadata live in `flutter_secure_storage`; never move them to SharedPreferences. Remote books use `BookSource.weread`, retain only metadata in `erdu.books.v1`, and load chapter text on demand through `AppController`. `BookRepository.saveBooks` deliberately strips remote chapter bodies before persistence. The Web content endpoints are compatibility interfaces rather than a stable public API, so failures must stay explicit and recoverable.

### TTS: local and cloud engines, one position model

`TtsAudioHandler` drives either engine and keeps identical character-offset semantics:
- **builtin** — `flutter_tts`, speaks `content.substring(_characterOffset)`; `setProgressHandler` offsets are relative, so they're rebased onto `_speechStartOffset`.
- **openai** — `CloudTtsService` (`lib/services/cloud_tts_service.dart`) splits a chapter into ~1200-char `TextChunk`s on sentence boundaries, POSTs `/v1/audio/speech` (`gpt-4o-mini-tts`), caches the MP3 under `<appSupport>/tts_cache/<bookId>/<chapter>/<voice>_<sha256>.mp3`, and plays it with `just_audio`. Playback position is mapped back to a character offset by `position/duration` ratio across the chunk.
- **azure enum / keyless Microsoft voice** — implemented through the Microsoft Edge Read Aloud compatible WebSocket via `edge_tts`; this is not the official Azure Speech API (which requires a resource key or bearer token) and has no Azure SLA. It reuses the same MP3 cache, `just_audio`, cancellation token, and character-position mapping as OpenAI.

`aliyun` exists in the `TtsProvider` enum but is **not implemented** — the settings page shows it disabled. Don't describe it as working.

Async cancellation uses the `_operation` monotonic token: any operation that restarts speech increments it and re-checks `token != _operation` after every await, so a slow cloud fetch can't resurrect a stale chunk. Preserve this pattern when adding async paths.

## Conventions that will bite you

- **Persistence keys are `erdu.*`, not `chibook.*`.** The app was renamed; `AppController`/`ErduApp`, `erdu.iml`, the Android app id `com.chibook.erdu`, and the CI artifact names still carry the old name. Changing a `SharedPreferences` key orphans real user data — don't rename them casually.
- **All decode paths must degrade, never throw.** Every `load*` in `BookRepository` wraps decoding in try/catch with a safe default, and `fromJson` gives every optional field a default (see `AudioProgress.fromJson` tolerating legacy JSON). New model fields must be nullable-or-defaulted; unknown enum values must fall back rather than crash init.
- **API keys never reach SharedPreferences.** `TtsSettings.toJson` deliberately omits `apiKey`; the key lives in `flutter_secure_storage` via `TtsCredentialStore`. `AppController._initialize` migrates any legacy plaintext key into secure storage and rewrites the JSON without it. `setTtsSettings` clears the key before persisting. `test/models_test.dart` asserts this — keep it true.
- **WeRead TTS is lazy.** Remote chapter metadata is loaded before entering the player; `TtsAudioHandler` receives a chapter loader so manual and automatic chapter changes fetch text on demand instead of treating unloaded chapters as empty.
- **Deleting a book must cascade.** `removeBook`/`removeBooks` clear highlights, audio progress, listening records, the copied file in `library/`, and the cloud TTS cache for that book.
- Dependencies are intentionally constrained: no Hive, Bloc, WebView, or Dio. `dart:io` `HttpClient` is used directly for the OpenAI calls. Justify any new dependency against the existing stack first.
- Native config that must stay in sync with `audio_service`: Android declares `WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `POST_NOTIFICATIONS`, the `AudioService` service, and `MediaButtonReceiver`; iOS sets `UIBackgroundModes = audio` with the `playback`/`spokenAudio` category. iOS deployment target is 15.5 (the README's "13.0" is stale).
- Correctness ordering from the spec: data/state correctness (progress merge rules, race handling, JSON migration) comes before visual polish. Simulated page-curl animation is explicitly not a priority.
