use super::commands::AudioMessage;
use super::thumbnail::{self, WM_APP_TASKBAR};
use crate::app::{AppContext, logic::library};
use parking_lot::{Mutex, RwLock};
use std::sync::{LazyLock, OnceLock};
use tokio::sync::watch;
use windows::{
    Win32::Foundation::{HMODULE, HWND, LPARAM, WPARAM},
    Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance},
    Win32::System::LibraryLoader::GetModuleFileNameW,
    Win32::UI::Controls::{HIMAGELIST, ILC_COLOR32, ILC_MASK, ImageList_Create, ImageList_ReplaceIcon},
    Win32::UI::Shell::{
        ITaskbarList3, THB_BITMAP, THB_FLAGS, THB_TOOLTIP, THBF_ENABLED, THBF_HIDDEN,
        THUMBBUTTON, THUMBBUTTONFLAGS, THUMBBUTTONMASK, TaskbarList,
    },
    Win32::UI::WindowsAndMessaging::{
        HICON, IMAGE_ICON, LR_LOADFROMFILE, LR_LOADTRANSPARENT, LoadImageW, SM_CXSMICON,
        SM_CYSMICON, WM_COMMAND, GetSystemMetrics, IsWindowVisible, PostMessageW,
    },
    core::{HSTRING, PCWSTR},
};

/// ITaskbarList3 must live on the STA platform thread; the UI-state below is
/// only ever touched from messages dispatched there.
struct ComSend<T>(T);
unsafe impl<T> Send for ComSend<T> {}

const BUTTON_COUNT: usize = 7;
const FIRST_BUTTON_ID: u32 = 40001;
const DEBOUNCE: std::time::Duration = std::time::Duration::from_millis(300);

struct ButtonSpec {
    icon: String,
    tooltip: String,
}

enum UiCmd {
    SetButtons {
        buttons: Vec<ButtonSpec>,
        tooltip: String,
    },
}

struct UiState {
    taskbar: Option<ComSend<ITaskbarList3>>,
    // Raw GDI handles stored as isize: HICON/HIMAGELIST are plain pointers
    // and not Send, while the state lives in a static shared across threads.
    image_list: Option<isize>,
    buttons_added: bool,
    icons: std::collections::HashMap<String, isize>,
    slot_icons: Vec<String>,
}

impl Default for UiState {
    fn default() -> Self {
        Self {
            taskbar: None,
            image_list: None,
            buttons_added: false,
            icons: std::collections::HashMap::new(),
            slot_icons: vec![String::new(); BUTTON_COUNT],
        }
    }
}

impl UiState {
    fn slot_icon(&self, i: usize) -> &str {
        self.slot_icons.get(i).map(String::as_str).unwrap_or("")
    }
    fn set_slot_icon(&mut self, i: usize, value: String) {
        if self.slot_icons.len() <= i {
            self.slot_icons.resize(BUTTON_COUNT, String::new());
        }
        self.slot_icons[i] = value;
    }
}

static UI_STATE: LazyLock<Mutex<UiState>> = LazyLock::new(|| Mutex::new(UiState::default()));

static CTX: RwLock<Option<AppContext>> = RwLock::new(None);
static RUNTIME: OnceLock<tokio::runtime::Handle> = OnceLock::new();
static MAIN_HWND: OnceLock<isize> = OnceLock::new();

/// Store the context and start the watcher that pushes toolbar state to the
/// platform thread. Call once after `AppContext` is built.
pub fn init(ctx: AppContext, mut shutdown_rx: watch::Receiver<bool>) {
    let _ = RUNTIME.set(tokio::runtime::Handle::current());
    *CTX.write() = Some(ctx.clone());

    tokio::spawn(async move {
        if let Some(hwnd) = thumbnail::get_flutter_hwnd() {
            let _ = MAIN_HWND.set(hwnd.0 as isize);
        }

        let mut changed_rx = ctx.audio.signals.changed_rx.clone();
        send_update(&ctx).await;
        let mut last_sent = tokio::time::Instant::now();

        loop {
            tokio::select! {
                _ = shutdown_rx.changed() => {
                    if *shutdown_rx.borrow() { break; }
                }
                res = changed_rx.changed() => {
                    if res.is_err() { break; }
                    // Leading-edge throttle: an isolated state change (e.g. a
                    // single pause click) updates the toolbar immediately;
                    // only changes arriving inside the throttle window after
                    // the previous update (buffering play/pause flaps) are
                    // coalesced into one rebuild at the end of the window.
                    let since_last = last_sent.elapsed();
                    if since_last < DEBOUNCE {
                        tokio::time::sleep(DEBOUNCE - since_last).await;
                        // Drain coalesced changes; the send below reads the
                        // latest state, intermediate ones don't need a turn.
                        while changed_rx.has_changed().unwrap_or(false) {
                            let _ = changed_rx.changed().await;
                        }
                    }
                    send_update(&ctx).await;
                    last_sent = tokio::time::Instant::now();
                }
            }
        }
    });
}

/// Called from the window subclass (platform thread). Returns true for
/// messages consumed here; everything else must fall through to
/// `DefSubclassProc` (tray menus, other plugins also send `WM_COMMAND`).
pub(crate) fn handle_window_message(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> bool {
    if msg == WM_APP_TASKBAR {
        let cmd = unsafe { Box::from_raw(lparam.0 as *mut UiCmd) };
        match *cmd {
            UiCmd::SetButtons { buttons, tooltip } => {
                apply_buttons(hwnd, buttons, tooltip);
            }
        }
        return true;
    }

    if msg == WM_COMMAND {
        let id = (wparam.0 & 0xFFFF) as u32;
        if !(FIRST_BUTTON_ID..FIRST_BUTTON_ID + BUTTON_COUNT as u32).contains(&id) {
            return false;
        }
        handle_button_action(id - FIRST_BUTTON_ID);
        return true;
    }

    false
}

async fn send_update(ctx: &AppContext) {
    let is_playing = ctx.audio.signals.is_playing.get();
    let is_shuffled = ctx.audio.signals.is_shuffled.get();
    let repeat_mode = ctx.audio.signals.repeat_mode.get();
    let track_id = ctx.audio.signals.current_track_id.get();
    let track = ctx.audio.signals.current_track.get();
    let (liked_ids, disliked_ids) = ctx.audio.state.read().await.liked.snapshot();

    let liked = track_id
        .as_deref()
        .map(|id| liked_ids.contains(id))
        .unwrap_or(false);
    let disliked = track_id
        .as_deref()
        .map(|id| disliked_ids.contains(id))
        .unwrap_or(false);

    // Redundant-update gate, same as the Dart effect it replaces.
    {
        static LAST: Mutex<[u64; 5]> = Mutex::new([u64::MAX; 5]);
        let mut last = LAST.lock();
        let sig: [u64; 5] = [
            track_id.as_deref().map(cover::hash_str).unwrap_or(0),
            is_playing as u64,
            liked as u64,
            disliked as u64,
            is_shuffled as u64 * 2 + repeat_mode as u64,
        ];
        if *last == sig {
            return;
        }
        *last = sig;
    }

    let icon = |name: &str| format!("assets/icons/{name}.ico");
    let buttons = vec![
        ButtonSpec {
            icon: icon(if is_shuffled { "shuffle_on" } else { "shuffle" }),
            tooltip: if is_shuffled {
                "Выключить перемешивание".into()
            } else {
                "Включить перемешивание".into()
            },
        },
        ButtonSpec {
            icon: icon(if disliked { "disliked" } else { "dislike" }),
            tooltip: if disliked { "Убрать дизлайк" } else { "Дизлайк" }.into(),
        },
        ButtonSpec {
            icon: icon("skip_previous"),
            tooltip: "Назад".into(),
        },
        ButtonSpec {
            icon: icon(if is_playing { "pause" } else { "play" }),
            tooltip: if is_playing { "Пауза" } else { "Играть" }.into(),
        },
        ButtonSpec {
            icon: icon("skip_next"),
            tooltip: "Вперед".into(),
        },
        ButtonSpec {
            icon: icon(if liked { "liked" } else { "like" }),
            tooltip: if liked { "Убрать лайк" } else { "Лайк" }.into(),
        },
        ButtonSpec {
            icon: icon(match repeat_mode {
                crate::audio::enums::RepeatMode::Single => "repeat_one",
                crate::audio::enums::RepeatMode::All => "repeat_on",
                crate::audio::enums::RepeatMode::None => "repeat",
            }),
            tooltip: "Повтор".into(),
        },
    ];

    let mut tooltip = track
        .as_ref()
        .map(|t| t.title.clone().unwrap_or_default())
        .unwrap_or_default();
    if let Some(track) = &track {
        let artists = track
            .artists
            .iter()
            .filter_map(|a| a.name.clone())
            .collect::<Vec<_>>()
            .join(", ");
        if !artists.is_empty() {
            tooltip = format!("{artists} - {tooltip}");
        }
    }

    dispatch_on_ui_thread(UiCmd::SetButtons { buttons, tooltip });
}

fn dispatch_on_ui_thread(cmd: UiCmd) {
    let Some(hwnd) = MAIN_HWND.get().copied() else {
        return;
    };
    let ptr = Box::into_raw(Box::new(cmd));
    let posted = unsafe {
        PostMessageW(
            Some(HWND(hwnd as *mut _)),
            WM_APP_TASKBAR,
            WPARAM(0),
            LPARAM(ptr as isize),
        )
    };
    if posted.is_err() {
        // Window is gone; free the command instead of leaking it.
        drop(unsafe { Box::from_raw(ptr) });
    }
}

fn apply_buttons(hwnd: HWND, buttons: Vec<ButtonSpec>, tooltip: String) {
    unsafe {
        if !IsWindowVisible(hwnd).as_bool() {
            // Hidden (e.g. closed to tray): skip now, the watcher retries on
            // the next state change after the window reappears.
            return;
        }

        let mut state = UI_STATE.lock();

        if state.taskbar.is_none() {
            let taskbar: Option<ITaskbarList3> =
                CoCreateInstance(&TaskbarList, None, CLSCTX_INPROC_SERVER).ok();
            let Some(taskbar) = taskbar else {
                return;
            };
            if taskbar.HrInit().is_err() {
                return;
            }
            state.taskbar = Some(ComSend(taskbar));
        }

        let cx = GetSystemMetrics(SM_CXSMICON);
        let cy = GetSystemMetrics(SM_CYSMICON);
        let image_list = if let Some(raw) = state.image_list {
            HIMAGELIST(raw)
        } else {
            let list = ImageList_Create(cx, cy, ILC_MASK | ILC_COLOR32, BUTTON_COUNT as i32, 1);
            if list.is_invalid() {
                return;
            }
            state.image_list = Some(list.0);
            list
        };

        for i in 0..BUTTON_COUNT {
            let wanted = buttons.get(i).map(|b| b.icon.clone()).unwrap_or_default();
            let current = state.slot_icon(i).to_string();

            if wanted.is_empty() || wanted == current {
                continue;
            }

            let Some(icon) = cached_icon(&mut state.icons, &wanted, cx, cy) else {
                continue;
            };

            // First fill appends (index -1); later changes replace in place.
            let index = if current.is_empty() { -1 } else { i as i32 };
            if ImageList_ReplaceIcon(image_list, index, icon) != -1 {
                state.set_slot_icon(i, wanted);
            }
        }

        let Some(state_taskbar) = state.taskbar.as_ref() else {
            return;
        };
        // Clone the interface out: `state.buttons_added` is mutated below.
        let taskbar = state_taskbar.0.clone();

        let _ = taskbar.ThumbBarSetImageList(hwnd, image_list);

        let mut thumb_buttons: [THUMBBUTTON; BUTTON_COUNT] = std::array::from_fn(|_| THUMBBUTTON {
            dwMask: THUMBBUTTONMASK(0),
            iId: 0,
            iBitmap: 0,
            hIcon: HICON::default(),
            szTip: [0; 260],
            dwFlags: THUMBBUTTONFLAGS(0),
        });

        for i in 0..BUTTON_COUNT {
            let id = FIRST_BUTTON_ID + i as u32;
            if let Some(spec) = buttons.get(i) {
                thumb_buttons[i] = THUMBBUTTON {
                    dwMask: THUMBBUTTONMASK(THB_BITMAP.0 | THB_TOOLTIP.0 | THB_FLAGS.0),
                    iId: id,
                    iBitmap: i as u32,
                    hIcon: HICON::default(),
                    szTip: utf16(spec.tooltip.as_str()),
                    dwFlags: THBF_ENABLED,
                };
            } else {
                thumb_buttons[i] = THUMBBUTTON {
                    dwMask: THUMBBUTTONMASK(THB_FLAGS.0),
                    iId: id,
                    iBitmap: 0,
                    hIcon: HICON::default(),
                    szTip: [0; 260],
                    dwFlags: THBF_HIDDEN,
                };
            }
        }

        let result = if state.buttons_added {
            taskbar.ThumbBarUpdateButtons(hwnd, &thumb_buttons)
        } else {
            let r = taskbar.ThumbBarAddButtons(hwnd, &thumb_buttons);
            if r.is_ok() {
                state.buttons_added = true;
            }
            r
        };
        if result.is_err() {
            return;
        }

        let tip = HSTRING::from(tooltip.as_str());
        let _ = taskbar.SetThumbnailTooltip(hwnd, PCWSTR(tip.as_ptr()));
    }
}

fn cached_icon(
    icons: &mut std::collections::HashMap<String, isize>,
    asset: &str,
    cx: i32,
    cy: i32,
) -> Option<HICON> {
    if let Some(raw) = icons.get(asset) {
        return Some(HICON(*raw as *mut _));
    }

    let path = resolve_asset(asset)?;
    let mut wide: Vec<u16> = path.as_os_str().to_string_lossy().encode_utf16().collect();
    wide.push(0);

    let handle = unsafe {
        LoadImageW(
            None,
            PCWSTR(wide.as_ptr()),
            IMAGE_ICON,
            cx,
            cy,
            LR_LOADFROMFILE | LR_LOADTRANSPARENT,
        )
        .ok()?
    };
    let icon = HICON(handle.0);
    icons.insert(asset.to_string(), icon.0 as isize);
    Some(icon)
}

/// Resolve a flutter asset (`assets/icons/x.ico`) to an absolute path under
/// `data/flutter_assets/` next to the executable.
fn resolve_asset(asset: &str) -> Option<std::path::PathBuf> {
    static ASSETS_DIR: OnceLock<Option<std::path::PathBuf>> = OnceLock::new();
    let dir = ASSETS_DIR.get_or_init(|| {
        let mut buf = [0u16; 1024];
        let len = unsafe { GetModuleFileNameW(Some(HMODULE::default()), &mut buf) } as usize;
        if len == 0 {
            return None;
        }
        let exe = std::path::PathBuf::from(String::from_utf16_lossy(&buf[..len]));
        Some(exe.parent()?.join("data").join("flutter_assets"))
    });
    dir.as_ref().map(|d| d.join(asset))
}

fn handle_button_action(index: u32) {
    let Some(ctx) = CTX.read().clone() else {
        return;
    };

    let send = |msg: AudioMessage| {
        // UI thread must not block on the (bounded) actor channel.
        let _ = ctx.audio.tx.try_send(msg);
    };

    match index {
        0 => send(AudioMessage::ToggleShuffle),
        1 => {
            let Some(rt) = RUNTIME.get() else { return };
            rt.spawn(async move {
                let Some(track_id) = ctx.audio.signals.current_track_id.get() else {
                    return;
                };
                library::toggle_dislike(&ctx, track_id).await;
            });
        }
        2 => send(AudioMessage::Prev),
        3 => send(AudioMessage::PlayPause),
        4 => send(AudioMessage::Next),
        5 => {
            let Some(rt) = RUNTIME.get() else { return };
            rt.spawn(async move {
                let Some(track_id) = ctx.audio.signals.current_track_id.get() else {
                    return;
                };
                library::toggle_like(&ctx, track_id).await;
            });
        }
        6 => send(AudioMessage::ToggleRepeatMode),
        _ => {}
    }
}

fn utf16(s: &str) -> [u16; 260] {
    let mut out = [0u16; 260];
    for (i, unit) in s.encode_utf16().take(259).enumerate() {
        out[i] = unit;
    }
    out
}

mod cover {
    pub fn hash_str(s: &str) -> u64 {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for b in s.as_bytes() {
            hash ^= *b as u64;
            hash = hash.wrapping_mul(0x1_0000_0001_b3);
        }
        hash
    }
}
