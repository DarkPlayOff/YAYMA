# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

YAYMA (Yet Another Yandex Music App) — an unofficial Yandex Music client. Flutter frontend + Rust backend, bridged via `flutter_rust_bridge` (FRB). Targets Windows, Linux, and Android (see `README.md`, `CHANGELOG.md`). Uses Yandex Music's undocumented API.

All application code lives under `src/`:
- `src/lib/` — Flutter/Dart frontend
- `src/rust/` — Rust backend (audio engine, API client, storage)
- `src/windows/`, `src/linux/`, `src/android/`, `src/macos/` — platform runner shells (mostly Flutter-generated, native glue code only)
- `src/shaders/` — GLSL shaders (e.g. `vibe.frag`, used for the "vibe"/visualizer effect)

`src/rust/target/` and `src/build/` are build output — never read or edit these; ignore them when searching.

## Commands

All commands run from `src/` (the Flutter project root, not the repo root).

```bash
flutter pub get                      # install Dart deps
flutter_rust_bridge_codegen generate # regenerate FRB bindings (see below)
dart run build_runner build          # regenerate freezed/json_serializable code
flutter build windows --release
flutter build linux --release
flutter build apk --release --split-per-abi
flutter analyze                      # lint (very_good_analysis + signals_lint)
```

A VS Code task `generate-code` runs both codegen steps together; `Build Release` depends on it (`.vscode/tasks.json`).

Rust alone (from `src/rust/`): standard `cargo build` / `cargo check` works for iterating on backend logic, but the Dart side won't see API changes until `flutter_rust_bridge_codegen generate` is rerun.

**Toolchain pinning is load-bearing**: `flutter_rust_bridge` in `src/pubspec.yaml` and `src/rust/Cargo.toml` is pinned to the same git rev of `fzyzcjy/flutter_rust_bridge`, and `flutter_rust_bridge_codegen` (the CLI, installed via `cargo install ... --git ... --rev <same-rev>`) must match that rev too. If codegen output looks wrong or won't compile, check these three are in sync first (see `.github/workflows/build.yml` for the exact install invocation).

No test suite is currently wired up (`integration_test` is commented out in `pubspec.yaml`).

## Architecture

### FRB boundary

`src/flutter_rust_bridge.yaml` configures codegen: Rust API surface is `crate::api` (in `src/rust/src/api/`), generated Dart output lands in `src/lib/src/rust/`. **Everything under `src/lib/src/rust/` is generated — never hand-edit it**; edit the Rust source and regenerate instead.

The Rust `api/` modules (`simple`, `auth`, `content`, `library`, `playback`, `audio_fx`, `updates`) are a thin FRB-exposed layer — each function just delegates to a same-named module under `src/rust/src/app/logic/`, which holds the actual logic. When adding a new Rust-callable operation, add it in both places following this 1:1 mirroring.

Every FRB function that touches app state takes `&AppContext` as its first argument (see `src/rust/src/app/context.rs`). `AppContext` is a cheap `Clone`-able `Arc` wrapper (`Deref`s to `AppContextInner`) grouping:
- `audio: AppAudioContext` — the `mpsc::Sender<AudioMessage>` to the audio actor, `AudioSignals`, shared `SystemState`, DSP effect handles
- `core: AppCoreContext` — `ApiService` (Yandex API client), DB handle, HTTP/track caches
- `system: AppSystemContext` — the `StreamSink<AppEvent>` used to push events to Dart, and a shutdown watch channel

On the Dart side, call into Rust through `runRustAction` / `runRustFetch` (`src/lib/src/features/auth/providers/auth_provider.dart`) rather than calling generated bindings directly — they pull `AppContext` from `appContextSignal`, centralize error handling, and auto-logout on session expiry (`Invalid token or session expired` / `Unauthorized`). Rust → Dart push events flow through the single `AppEvent` enum (`src/rust/src/api/simple.rs`) over `app_event_stream`.

### Startup sequence

`app::initialize_infrastructure` runs once (logging, panic hook) at FRB startup. `app::initialize_app` → `initialize_services` (`src/rust/src/app/init.rs`) does the real bring-up: opens the DB, builds HTTP/track caches, spawns the audio system (`AudioSystem::spawn`), constructs `AppContext`, loads persisted settings, then spawns five background actors from `app/workers.rs` (sync, event, bridge, settings, cache), each running a `tokio::select!` loop against a shared shutdown `watch` channel.

### Audio engine (`src/rust/src/audio/`)

Playback is actor-style: Dart/other code sends an `AudioMessage` (`audio/commands.rs`) over an `mpsc` channel; `AudioSystem` (`audio/system.rs`) owns the receive loop and drives `AudioController` (`audio/controller.rs`), `QueueManager`, and `YandexProvider`. Effects run through a modular DSP chain (`audio/fx/modules/`: biquad, eq, compressor, chorus, delay, reverb, overdrive, fade, dc_block, monitor) composed via `fx/chain.rs` and addressable by `EffectHandle`s stored in a shared `HashMap`. Platform integrations (SMTC on Windows, Discord Rich Presence) are gated `cfg(not(target_os = "android"))`. Streaming/decoding (buffering, PCM, `symphonia`/`rodio` data sources) lives in `src/rust/src/stream/`.

### Shared mutable state: `Signal<T>`

`src/rust/src/util/reactive.rs` defines `Signal<T>` — an `Arc<ArcSwap<T>>` wrapper with `get`/`set`/`with`/`update`. This is the standard way state is shared across async tasks/threads in the Rust backend (e.g. `AudioSignals`, `SystemState`). It is the backend analogue of `signals_flutter` on the Dart side — don't reach for `Mutex`/`RwLock` for simple shared values when `Signal<T>` fits.

### Flutter frontend (`src/lib/src/`)

Organized by feature under `features/<name>/{providers,views}/`: `providers/` holds state (via `signals_flutter` — `Signal`/`FlutterSignal`, not Provider/Riverpod/Bloc) and `views/` holds widgets. Cross-cutting UI lives under `features/core/`. `src/app/` holds app-level bootstrap (`init.dart`, `system_tray.dart`).

DTOs shared with Rust are generated types (`rust/api/models.dart` + `.freezed.dart`); when you need new Dart-only models, follow the existing `freezed` + `json_serializable` pattern and run `dart run build_runner build`.

### Storage

`src/rust/src/storage/` — `db.rs` uses the `toasty` ORM over SQLite; `cache.rs` implements `HttpCache` and `TrackCache` (downloaded-track cache enabling full offline playback, per the recent "play downloaded tracks fully offline" feature).
