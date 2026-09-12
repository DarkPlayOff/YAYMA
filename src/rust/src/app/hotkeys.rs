//! System-wide hotkeys, backed by `wayclip-global-hotkey` (a `global-hotkey`
//! fork with Wayland support via the XDG desktop portal).
//!
//! Ownership lives entirely in Rust: bindings are persisted in the app
//! database, registration happens on a dedicated manager thread, and key
//! presses are dispatched straight to the audio actor / library logic. Dart
//! only reads and edits the binding table through the FRB API — it never
//! registers anything itself.
//!
//! Replaces the `hotkey_manager` Flutter plugin, which had no Wayland backend.

use super::{AppContext, logic::library};
use crate::audio::commands::AudioMessage;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use std::sync::mpsc;
use std::sync::{LazyLock, OnceLock};
use std::time::Duration;
use wayclip_global_hotkey::hotkey::{Code, HotKey, Modifiers};
use wayclip_global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager};


const SETTINGS_KEY: &str = "hotkeys";
/// Manager command poll interval. Also the worst-case latency for WM_HOTKEY
/// delivery on Windows (the thread must pump the win32 message queue).
const MANAGER_POLL: Duration = Duration::from_millis(50);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyAction {
    PlayPause,
    PreviousTrack,
    NextTrack,
    SeekBackward,
    SeekForward,
    LikeTrack,
    DislikeTrack,
}

impl HotkeyAction {
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "playPause" => Self::PlayPause,
            "previousTrack" => Self::PreviousTrack,
            "nextTrack" => Self::NextTrack,
            "seekBackward" => Self::SeekBackward,
            "seekForward" => Self::SeekForward,
            "likeTrack" => Self::LikeTrack,
            "dislikeTrack" => Self::DislikeTrack,
            _ => return None,
        })
    }

    pub fn name(&self) -> &'static str {
        match self {
            Self::PlayPause => "playPause",
            Self::PreviousTrack => "previousTrack",
            Self::NextTrack => "nextTrack",
            Self::SeekBackward => "seekBackward",
            Self::SeekForward => "seekForward",
            Self::LikeTrack => "likeTrack",
            Self::DislikeTrack => "dislikeTrack",
        }
    }
}

/// One hotkey binding. `key` holds a `keyboard_types::Code` variant name
/// ("Space", "ArrowLeft", "KeyL", ...), the same names the W3C code table and
/// Flutter's USB HID usages map onto.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HotkeyBinding {
    pub action: String,
    pub enabled: bool,
    pub key: String,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub meta: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HotkeySettings {
    pub enabled: bool,
    pub bindings: Vec<HotkeyBinding>,
}

fn default_settings() -> HotkeySettings {
    let binding = |action: &str, key: &str, shift: bool| HotkeyBinding {
        action: action.to_string(),
        enabled: true,
        key: key.to_string(),
        ctrl: true,
        alt: true,
        shift,
        meta: false,
    };
    HotkeySettings {
        // Off until the user turns hotkeys on, matching the old behavior.
        enabled: false,
        bindings: vec![
            binding("playPause", "Space", false),
            binding("previousTrack", "ArrowLeft", false),
            binding("nextTrack", "ArrowRight", false),
            binding("seekBackward", "ArrowLeft", true),
            binding("seekForward", "ArrowRight", true),
            binding("likeTrack", "KeyL", false),
            binding("dislikeTrack", "KeyD", false),
        ],
    }
}

fn to_hotkey(binding: &HotkeyBinding) -> Option<HotKey> {
    let code = Code::from_str(&binding.key).ok()?;
    let mut modifiers = Modifiers::empty();
    if binding.ctrl {
        modifiers |= Modifiers::CONTROL;
    }
    if binding.alt {
        modifiers |= Modifiers::ALT;
    }
    if binding.shift {
        modifiers |= Modifiers::SHIFT;
    }
    if binding.meta {
        modifiers |= Modifiers::META;
    }
    Some(HotKey::new(Some(modifiers), code))
}

/// Map a Flutter `PhysicalKeyboardKey.usbHidUsage` (USB HID page << 16 | id)
/// onto a `keyboard_types::Code`.
pub fn code_from_usb_hid_usage(usage: u64) -> Option<Code> {
    if usage >> 16 != 0x07 {
        return None;
    }
    let id = (usage & 0xFFFF) as u8;
    let code = match id {
        // Letters
        0x04..=0x1D => Code::from_str(&format!("Key{}", (b'A' + id - 0x04) as char)).ok()?,
        // Digits
        0x1E..=0x26 => Code::from_str(&format!("Digit{}", id - 0x1E + 1)).ok()?,
        0x27 => Code::Digit0,
        0x28 => Code::Enter,
        0x29 => Code::Escape,
        0x2A => Code::Backspace,
        0x2B => Code::Tab,
        0x2C => Code::Space,
        0x2D => Code::Minus,
        0x2E => Code::Equal,
        0x2F => Code::BracketLeft,
        0x30 => Code::BracketRight,
        0x31 => Code::Backslash,
        0x33 => Code::Semicolon,
        0x34 => Code::Quote,
        0x35 => Code::Backquote,
        0x36 => Code::Comma,
        0x37 => Code::Period,
        0x38 => Code::Slash,
        0x39 => Code::CapsLock,
        // F1..F12
        0x3A..=0x45 => Code::from_str(&format!("F{}", id - 0x3A + 1)).ok()?,
        0x49 => Code::Insert,
        0x4A => Code::Home,
        0x4B => Code::PageUp,
        0x4C => Code::Delete,
        0x4D => Code::End,
        0x4E => Code::PageDown,
        0x4F => Code::ArrowRight,
        0x50 => Code::ArrowLeft,
        0x51 => Code::ArrowDown,
        0x52 => Code::ArrowUp,
        _ => return None,
    };
    Some(code)
}

enum ManagerCmd {
    Apply(Vec<HotKey>),
    Shutdown,
}

static MANAGER_TX: OnceLock<mpsc::Sender<ManagerCmd>> = OnceLock::new();
static CTX: RwLock<Option<AppContext>> = RwLock::new(None);
static RUNTIME: OnceLock<tokio::runtime::Handle> = OnceLock::new();
static SETTINGS: LazyLock<RwLock<HotkeySettings>> =
    LazyLock::new(|| RwLock::new(default_settings()));
/// Hotkey id -> action, mirroring what is currently registered. `HotKey`
/// events carry the same id.
static REGISTERED: LazyLock<RwLock<Vec<(u32, HotkeyAction)>>> =
    LazyLock::new(|| RwLock::new(Vec::new()));

/// Load persisted settings and start the manager + event threads. Call once
/// after `AppContext` is built; desktop platforms only.
pub fn init(ctx: AppContext, mut shutdown_rx: tokio::sync::watch::Receiver<bool>) {
    let _ = RUNTIME.set(tokio::runtime::Handle::current());
    *CTX.write() = Some(ctx.clone());

    let (tx, rx) = mpsc::channel::<ManagerCmd>();
    let _ = MANAGER_TX.set(tx);

    std::thread::Builder::new()
        .name("hotkey-manager".into())
        .spawn(move || manager_loop(rx))
        .expect("spawn hotkey manager thread");

    std::thread::Builder::new()
        .name("hotkey-events".into())
        .spawn(event_loop)
        .expect("spawn hotkey event thread");

    // Apply persisted settings once the async context is available.
    let apply_ctx = ctx.clone();
    tokio::spawn(async move {
        let settings = load_settings(&apply_ctx).await;
        *SETTINGS.write() = settings;
        apply_current();
    });

    tokio::spawn(async move {
        let _ = shutdown_rx.changed().await;
        if *shutdown_rx.borrow() {
            if let Some(tx) = MANAGER_TX.get() {
                let _ = tx.send(ManagerCmd::Shutdown);
            }
        }
    });
}

async fn load_settings(ctx: &AppContext) -> HotkeySettings {
    let mut db = ctx.core.db.lock().await;
    db.load_setting::<HotkeySettings>(SETTINGS_KEY)
        .await
        .ok()
        .flatten()
        .unwrap_or_else(default_settings)
}

async fn persist_settings(ctx: &AppContext, settings: &HotkeySettings) {
    let mut db = ctx.core.db.lock().await;
    if let Err(e) = db.save_setting(SETTINGS_KEY, settings).await {
        tracing::error!("Failed to persist hotkey settings: {:?}", e);
    }
}

/// Persist + register the given settings.
pub async fn apply_settings(ctx: &AppContext, settings: HotkeySettings) {
    persist_settings(ctx, &settings).await;
    *SETTINGS.write() = settings;
    apply_current();
}

fn apply_current() {
    let settings = SETTINGS.read().clone();
    let registered: Vec<(u32, HotkeyAction)> = settings
        .bindings
        .iter()
        .filter(|b| b.enabled)
        .filter_map(|b| {
            let action = HotkeyAction::from_name(&b.action)?;
            let hotkey = to_hotkey(b)?;
            Some((hotkey.id(), action))
        })
        .collect();
    *REGISTERED.write() = registered.clone();

    if !settings.enabled {
        // Still send an empty apply so previously registered hotkeys are
        // unregistered.
        send_apply(Vec::new());
        return;
    }

    let hotkeys = settings
        .bindings
        .iter()
        .filter(|b| b.enabled)
        .filter_map(to_hotkey)
        .collect();
    send_apply(hotkeys);
}

fn send_apply(hotkeys: Vec<HotKey>) {
    if let Some(tx) = MANAGER_TX.get() {
        let _ = tx.send(ManagerCmd::Apply(hotkeys));
    }
}

pub fn shutdown() {
    if let Some(tx) = MANAGER_TX.get() {
        let _ = tx.send(ManagerCmd::Shutdown);
    }
}

pub fn settings_snapshot() -> HotkeySettings {
    SETTINGS.read().clone()
}

pub fn default_settings_public() -> HotkeySettings {
    default_settings()
}

fn manager_loop(rx: mpsc::Receiver<ManagerCmd>) {
    // Identify the app to the GlobalShortcuts portal (the Wayland path reads
    // this during D-Bus registration); without it the crate falls back to a
    // generic `com.global-hotkey.app`. Must be set before the manager is
    // created.
    #[cfg(target_os = "linux")]
    if std::env::var_os("GLOBAL_HOTKEY_APP_ID").is_none() {
        unsafe {
            std::env::set_var("GLOBAL_HOTKEY_APP_ID", "io.github.darkplayoff.yayma");
        }
    }

    let manager = match GlobalHotKeyManager::new() {
        Ok(manager) => manager,
        Err(e) => {
            tracing::error!("Failed to create global hotkey manager: {e}");
            return;
        }
    };

    let mut registered: Vec<HotKey> = Vec::new();
    loop {
        // Windows: WM_HOTKEY arrives on this thread's message queue, so the
        // queue must be pumped regularly for the crate's window proc to see
        // it. On Linux (X11/Wayland portal) the crate handles events itself.
        #[cfg(target_os = "windows")]
        pump_win32_messages();

        match rx.recv_timeout(MANAGER_POLL) {
            Ok(ManagerCmd::Apply(hotkeys)) => {
                for old in &registered {
                    if let Err(e) = manager.unregister(*old) {
                        tracing::debug!("Hotkey unregister failed: {e}");
                    }
                }
                registered.clear();
                for hotkey in hotkeys {
                    match manager.register(hotkey) {
                        Ok(()) => registered.push(hotkey),
                        // The combo may already belong to another application.
                        Err(e) => tracing::warn!("Hotkey register failed: {e}"),
                    }
                }
            }
            Ok(ManagerCmd::Shutdown) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
}

#[cfg(target_os = "windows")]
fn pump_win32_messages() {
    use windows::Win32::UI::WindowsAndMessaging::{
        DispatchMessageW, MSG, PM_REMOVE, PeekMessageW, TranslateMessage,
    };
    unsafe {
        let mut msg = MSG::default();
        while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

fn event_loop() {
    let receiver = GlobalHotKeyEvent::receiver();
    while let Ok(event) = receiver.recv() {
        if event.state() != wayclip_global_hotkey::HotKeyState::Pressed {
            continue;
        }
        let action = REGISTERED
            .read()
            .iter()
            .find(|(id, _)| *id == event.id())
            .map(|(_, action)| *action);
        let Some(action) = action else {
            continue;
        };
        dispatch_action(action);
    }
}

fn dispatch_action(action: HotkeyAction) {
    let Some(ctx) = CTX.read().clone() else {
        return;
    };
    let Some(runtime) = RUNTIME.get() else {
        return;
    };

    runtime.spawn(async move {
        match action {
            HotkeyAction::PlayPause => {
                let _ = ctx.audio.tx.send(AudioMessage::PlayPause).await;
            }
            HotkeyAction::PreviousTrack => {
                let _ = ctx.audio.tx.send(AudioMessage::Prev).await;
            }
            HotkeyAction::NextTrack => {
                let _ = ctx.audio.tx.send(AudioMessage::Next).await;
            }
            HotkeyAction::SeekBackward => seek_by(&ctx, -5_000).await,
            HotkeyAction::SeekForward => seek_by(&ctx, 5_000).await,
            HotkeyAction::LikeTrack => {
                let Some(track_id) = ctx.audio.signals.current_track_id.get() else {
                    return;
                };
                library::toggle_like(&ctx, track_id).await;
            }
            HotkeyAction::DislikeTrack => {
                let Some(track_id) = ctx.audio.signals.current_track_id.get() else {
                    return;
                };
                library::toggle_dislike(&ctx, track_id).await;
            }
        }
    });
}

async fn seek_by(ctx: &AppContext, offset_ms: i64) {
    let position = ctx.audio.signals.position_ms.get() as i64;
    let duration = ctx.audio.signals.duration_ms.get() as i64;
    let target = (position + offset_ms).clamp(0, duration.max(0)) as u64;
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::Seek(Duration::from_millis(target)))
        .await;
}
