use arc_swap::ArcSwapOption;
use parking_lot::Mutex;
use std::cell::RefCell;
use std::sync::atomic::{AtomicIsize, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, OnceLock};
use windows::{
    Win32::Foundation::*, Win32::Graphics::Dwm::*, Win32::Graphics::Gdi::*,
    Win32::Graphics::Imaging::*, Win32::System::Com::*,
    Win32::System::Threading::GetCurrentProcessId, Win32::UI::Shell::SetWindowSubclass,
    Win32::UI::Shell::*, Win32::UI::WindowsAndMessaging::*, core::*,
};

const SUBCLASS_ID: usize = 1337;
const WM_APP_REMOTECALL: u32 = WM_APP + 1337;
/// Posted by `taskbar.rs` once it has stored a `taskbar::UiCmd` in its own
/// mailbox; the subclass runs it on the platform thread.
pub const WM_APP_TASKBAR: u32 = WM_APP + 1338;

/// Maximum number of DWM-requested sizes (thumbnail + live preview) tracked
/// and pre-rendered by the background thread.
const MAX_READY_BITMAPS: usize = 4;

struct CachedBitmap {
    hbitmap_ptr: isize,
    width: u32,
    height: u32,
}

struct Cover {
    hash: u64,
    bytes: Arc<Vec<u8>>,
}

static READY_BITMAPS: LazyLock<Mutex<Vec<CachedBitmap>>> = LazyLock::new(|| Mutex::new(Vec::new()));
static LAST_COVER: LazyLock<Mutex<Option<Cover>>> = LazyLock::new(|| Mutex::new(None));
/// Sizes DWM has actually requested, newest first. Empty until the first
/// taskbar hover, so the first render per size stays on the UI thread and
/// every later cover change is prerendered off it.
static REQUESTED_SIZES: LazyLock<Mutex<Vec<(u32, u32)>>> = LazyLock::new(|| Mutex::new(Vec::new()));
/// Hash of the cover currently (or last) shown via DWM, to skip redundant
/// invalidations when SMTC re-reports the same track's artwork.
static INVALIDATED_HASH: AtomicU64 = AtomicU64::new(0);
/// Id of the newest `update_cover` call, assigned by the caller. A cover that
/// loads slower than the next one must not win, so every stage checks it.
static LAST_SEQ: AtomicU64 = AtomicU64::new(0);
/// One-slot mailbox for the prerender thread: a newer job overwrites an older
/// one instead of queueing, so a burst of tracks can't pile up cover bytes.
static PENDING: LazyLock<ArcSwapOption<PrerenderJob>> = LazyLock::new(ArcSwapOption::empty);

thread_local! {
    static WIC_FACTORY: RefCell<Option<IWICImagingFactory>> = const { RefCell::new(None) };
}

static HOOK_HANDLE: AtomicIsize = AtomicIsize::new(0);

#[derive(Clone, Copy)]
pub struct ThumbnailManager {
    hwnd_ptr: isize,
}

/// Only a raw `HWND` value is stored; the manager itself owns no COM/GDI
/// objects. Every Win32 call made with that handle (`IsWindow`,
/// `DwmInvalidateIconicBitmaps`) is documented to be valid from any thread.
unsafe impl Send for ThumbnailManager {}
unsafe impl Sync for ThumbnailManager {}

impl ThumbnailManager {
    pub fn new(hwnd_raw: *mut std::ffi::c_void) -> Option<Self> {
        let target_hwnd = if hwnd_raw.is_null() {
            get_flutter_hwnd()?
        } else {
            HWND(hwnd_raw.cast())
        };

        // `SetWindowsHookExW` runs `hook_proc` on the target thread's message
        // loop, which is where the DWM attributes and the subclass must be set.
        let thread_id = unsafe { GetWindowThreadProcessId(target_hwnd, None) };
        if thread_id == 0 {
            return None;
        }
        let hook =
            match unsafe { SetWindowsHookExW(WH_CALLWNDPROC, Some(hook_proc), None, thread_id) } {
                Ok(hook) => hook,
                Err(e) => {
                    tracing::warn!(?e, "thumbnail_hook_install_failed");
                    return None;
                }
            };
        unsafe {
            HOOK_HANDLE.store(hook.0 as isize, Ordering::Relaxed);
            let _ = SendMessageW(
                target_hwnd,
                WM_APP_REMOTECALL,
                Some(WPARAM(0)),
                Some(LPARAM(0)),
            );
        }

        Some(Self {
            hwnd_ptr: target_hwnd.0 as isize,
        })
    }

    /// Hand a freshly loaded cover to the thumbnail pipeline. `seq` must grow
    /// monotonically across calls, otherwise a slow load overwrites a newer
    /// cover (or is discarded as stale).
    pub fn update_cover(&self, seq: u64, img_bytes: Vec<u8>) {
        if LAST_SEQ.fetch_max(seq, Ordering::Relaxed) > seq {
            return;
        }
        let hash = cover_hash(&img_bytes);
        if INVALIDATED_HASH.load(Ordering::Relaxed) == hash {
            return;
        }

        let bytes = Arc::new(img_bytes);
        *LAST_COVER.lock() = Some(Cover {
            hash,
            bytes: bytes.clone(),
        });

        // Live bitmaps are replaced only after new ones are ready, so the
        // preview never flashes empty in between.
        let sizes = REQUESTED_SIZES.lock().clone();
        if sizes.is_empty() {
            // DWM never asked yet; the first request decodes LAST_COVER inline.
            INVALIDATED_HASH.store(hash, Ordering::Relaxed);
            return;
        }

        enqueue_prerender(PrerenderJob {
            seq,
            hash,
            bytes,
            hwnd: self.hwnd_ptr,
        });
    }
}

struct PrerenderJob {
    seq: u64,
    hash: u64,
    bytes: Arc<Vec<u8>>,
    hwnd: isize,
}

fn enqueue_prerender(job: PrerenderJob) {
    PENDING.store(Some(Arc::new(job)));
    let _ = wake_sender().send(());
}

fn wake_sender() -> &'static std::sync::mpsc::Sender<()> {
    static SENDER: OnceLock<std::sync::mpsc::Sender<()>> = OnceLock::new();
    SENDER.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        if let Err(e) = std::thread::Builder::new()
            .name("thumbnail-prerender".into())
            .spawn(move || prerender_loop(rx))
        {
            // Without the thread the sync path in `handle_iconic_request`
            // still works, just without prerendering.
            tracing::warn!(?e, "thumbnail_prerender_spawn_failed");
        }
        tx
    })
}

/// Decodes covers for the sizes DWM has been asking for, off the platform
/// thread. The WIC decode of a JPEG cover takes tens of milliseconds; doing
/// it inside `subclass_proc` used to stall the Flutter platform thread and
/// starve DWM's iconic-bitmap requests (the "loading" glass in the preview).
fn prerender_loop(rx: std::sync::mpsc::Receiver<()>) {
    ensure_com();
    while rx.recv().is_ok() {
        let Some(job) = PENDING.swap(None) else {
            continue;
        };
        if !is_current(&job) {
            continue;
        }

        let sizes = REQUESTED_SIZES.lock().clone();
        let mut installed_any = false;
        for (tw, th) in sizes {
            let Some(h) = create_hbitmap_from_wic(&job.bytes, tw, th) else {
                tracing::warn!(tw, th, "thumbnail_decode_failed");
                continue;
            };
            let mut ready = READY_BITMAPS.lock();
            if !is_current(&job) {
                unsafe {
                    let _ = DeleteObject(HBITMAP(h.0.cast()).into());
                }
                break;
            }
            replace_ready_bitmap(&mut ready, tw, th, h);
            installed_any = true;
        }

        if installed_any {
            INVALIDATED_HASH.store(job.hash, Ordering::Relaxed);
            let hwnd = HWND(job.hwnd as *mut _);
            unsafe {
                if IsWindow(Some(hwnd)).as_bool() {
                    let _ = DwmInvalidateIconicBitmaps(hwnd);
                }
            }
        }
    }
}

/// A newer cover arrived while this job was queued or decoding.
fn is_current(job: &PrerenderJob) -> bool {
    job.seq >= LAST_SEQ.load(Ordering::Relaxed)
        && LAST_COVER.lock().as_ref().map(|c| c.hash) == Some(job.hash)
}

/// Replace (or add) the cached bitmap for `(tw, th)`, deleting the evicted
/// HBITMAP. Caller holds `READY_BITMAPS`.
fn replace_ready_bitmap(ready: &mut Vec<CachedBitmap>, tw: u32, th: u32, h: HBITMAP) {
    if let Some(pos) = ready.iter().position(|c| c.width == tw && c.height == th) {
        let old = ready.remove(pos);
        unsafe {
            let _ = DeleteObject(HBITMAP(old.hbitmap_ptr as *mut _).into());
        }
    } else if ready.len() >= MAX_READY_BITMAPS {
        let old = ready.remove(0);
        unsafe {
            let _ = DeleteObject(HBITMAP(old.hbitmap_ptr as *mut _).into());
        }
    }
    ready.push(CachedBitmap {
        hbitmap_ptr: h.0 as isize,
        width: tw,
        height: th,
    });
}

fn set_iconic_bitmap(hwnd: HWND, msg: u32, h: HBITMAP) {
    unsafe {
        if msg == WM_DWMSENDICONICTHUMBNAIL {
            let _ = DwmSetIconicThumbnail(hwnd, h, 0);
        } else {
            let _ = DwmSetIconicLivePreviewBitmap(hwnd, h, None, 0);
        }
    }
}

pub fn get_flutter_hwnd() -> Option<HWND> {
    let mut target_hwnd = HWND::default();
    unsafe {
        let _ = EnumWindows(
            Some(enum_windows_proc),
            LPARAM(&mut target_hwnd as *mut _ as isize),
        );
    }
    (!target_hwnd.0.is_null()).then_some(target_hwnd)
}

unsafe extern "system" fn enum_windows_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    // SAFETY: Windows passes a live window handle; `lparam` is the
    // `*mut HWND` handed to `EnumWindows` in `get_flutter_hwnd`.
    unsafe {
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == GetCurrentProcessId() {
            let mut class_name = [0u16; 256];
            let len = GetClassNameW(hwnd, &mut class_name);
            if String::from_utf16_lossy(&class_name[..len as usize])
                == "FLUTTER_RUNNER_WIN32_WINDOW"
            {
                let ptr = lparam.0 as *mut HWND;
                *ptr = hwnd;
                return BOOL::from(false);
            }
        }
        BOOL::from(true)
    }
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    // SAFETY: with `code >= 0` the hook is documented to receive a valid
    // `CWPSTRUCT` in `lparam`. The hook unhooks itself before this module
    // could be unloaded.
    unsafe {
        if code >= 0 {
            let msg = &*(lparam.0 as *const CWPSTRUCT);
            if msg.message == WM_APP_REMOTECALL {
                let hwnd = msg.hwnd;
                let force_iconic = BOOL::from(true);
                let attr_ptr = &raw const force_iconic as *const _;

                let _ = DwmSetWindowAttribute(hwnd, DWMWA_FORCE_ICONIC_REPRESENTATION, attr_ptr, 4);
                let _ = DwmSetWindowAttribute(hwnd, DWMWA_HAS_ICONIC_BITMAP, attr_ptr, 4);
                if !SetWindowSubclass(hwnd, Some(subclass_proc), SUBCLASS_ID, 0).as_bool() {
                    tracing::warn!("thumbnail_subclass_failed");
                }

                let hook = HOOK_HANDLE.swap(0, Ordering::Relaxed);
                if hook != 0 {
                    let _ = UnhookWindowsHookEx(HHOOK(hook as *mut _));
                }
            }
        }
        CallNextHookEx(None, code, wparam, lparam)
    }
}

unsafe extern "system" fn subclass_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    // SAFETY: Windows calls the subclass with a live window handle and the
    // message parameters for `msg`; unwritten messages fall through to
    // `DefSubclassProc`.
    unsafe {
        if msg == WM_DWMSENDICONICTHUMBNAIL || msg == WM_DWMSENDICONICLIVEPREVIEWBITMAP {
            return match iconic_request_size(hwnd, msg, lparam) {
                Some((tw, th)) => handle_iconic_request(hwnd, msg, tw, th),
                None => DefSubclassProc(hwnd, msg, wparam, lparam),
            };
        }
        if super::taskbar::handle_window_message(hwnd, msg, wparam, lparam) {
            LRESULT(0)
        } else {
            DefSubclassProc(hwnd, msg, wparam, lparam)
        }
    }
}

/// Bitmap size DWM asked for, clamped so a full-window live preview doesn't
/// stall the platform thread with a one-off synchronous decode. DWM scales
/// whatever it gets to the requested box.
///
/// # Safety
/// `hwnd` must be a live window of this process, called on its owning thread.
unsafe fn iconic_request_size(hwnd: HWND, msg: u32, lparam: LPARAM) -> Option<(u32, u32)> {
    // SAFETY: inherited from the caller (`subclass_proc`).
    unsafe {
        let (w, h) = if msg == WM_DWMSENDICONICTHUMBNAIL {
            // Documented packing: width in HIWORD, height in LOWORD.
            let lp = lparam.0 as u32;
            (lp >> 16, lp & 0xFFFF)
        } else {
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            (
                u32::try_from(rc.right - rc.left).ok()?,
                u32::try_from(rc.bottom - rc.top).ok()?,
            )
        };
        if w == 0 || h == 0 {
            return None;
        }
        let k = 512.0 / w.max(h) as f32;
        if k >= 1.0 {
            return Some((w, h));
        }
        Some((
            ((w as f32 * k) as u32).max(1),
            ((h as f32 * k) as u32).max(1),
        ))
    }
}

/// Answer a DWM request for the iconic thumbnail / live preview bitmap.
///
/// Steady state: the background prerender thread has already built a bitmap
/// for this size, so this only swaps a pointer. First-ever request for a size
/// still decodes synchronously (once), then caches.
fn handle_iconic_request(hwnd: HWND, msg: u32, tw: u32, th: u32) -> LRESULT {
    record_requested_size(tw, th);

    let mut ready = READY_BITMAPS.lock();
    // Held across the DWM call so the prerender thread can't evict and
    // `DeleteObject` this HBITMAP while `DwmSetIconic*` is using it.
    if let Some(cached) = ready.iter().find(|c| c.width == tw && c.height == th) {
        set_iconic_bitmap(hwnd, msg, HBITMAP(cached.hbitmap_ptr as *mut _));
        return LRESULT(0);
    }

    let bytes = LAST_COVER.lock().as_ref().map(|c| c.bytes.clone());
    if let Some(bytes) = bytes
        && let Some(h) = create_hbitmap_from_wic(&bytes, tw, th)
    {
        replace_ready_bitmap(&mut ready, tw, th, h);
        set_iconic_bitmap(hwnd, msg, h);
    }

    // Without a bitmap DWM keeps showing its default loading glass and
    // re-requests later; returning 0 is the documented behavior.
    LRESULT(0)
}

fn record_requested_size(tw: u32, th: u32) {
    let mut sizes = REQUESTED_SIZES.lock();
    if sizes.contains(&(tw, th)) {
        return;
    }
    sizes.insert(0, (tw, th));
    // Keep only the sizes DWM currently asks for; `replace_ready_bitmap` drops
    // the matching bitmap when it has to make room, so both stay in step.
    sizes.truncate(MAX_READY_BITMAPS);
}

fn ensure_com() {
    // CoInitializeEx is per-thread. The Flutter platform thread already runs
    // STA, so MTA init there fails with RPC_E_CHANGED_MODE and is ignored;
    // WIC objects are free-threaded either way. Skipping CoUninitialize is
    // intentional: it would tear down COM under threads we don't own.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED | COINIT_DISABLE_OLE1DDE);
    }
}

fn create_hbitmap_from_wic(bytes: &[u8], target_w: u32, target_h: u32) -> Option<HBITMAP> {
    unsafe {
        ensure_com();
        let factory = WIC_FACTORY.with(|f| {
            if f.borrow().is_none() {
                *f.borrow_mut() =
                    CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER).ok();
            }
            f.borrow().clone()
        })?;

        let stream = SHCreateMemStream(Some(bytes))?;
        let decoder = factory
            .CreateDecoderFromStream(&stream, std::ptr::null(), WICDecodeMetadataCacheOnDemand)
            .ok()?;
        let frame = decoder.GetFrame(0).ok()?;

        let size = target_w.min(target_h);
        if size == 0 {
            return None;
        }
        let radius = (size as f32 * 0.12) as i32;

        let scaler = factory.CreateBitmapScaler().ok()?;
        scaler
            .Initialize(&frame, size, size, WICBitmapInterpolationModeFant)
            .ok()?;

        let converter = factory.CreateFormatConverter().ok()?;
        converter
            .Initialize(
                &scaler,
                &GUID_WICPixelFormat32bppPBGRA,
                WICBitmapDitherTypeNone,
                None,
                0.0,
                WICBitmapPaletteTypeCustom,
            )
            .ok()?;

        let row_bytes = (size * 4) as usize;
        let mut src = vec![0u8; row_bytes * size as usize];
        converter
            .CopyPixels(
                &WICRect {
                    X: 0,
                    Y: 0,
                    Width: size as i32,
                    Height: size as i32,
                },
                row_bytes as u32,
                &mut src,
            )
            .ok()?;

        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: target_w as i32,
                biHeight: -(target_h as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: 0,
                ..Default::default()
            },
            ..Default::default()
        };

        let hdc = GetDC(None);
        if hdc.is_invalid() {
            return None;
        }
        let mut bits_ptr = std::ptr::null_mut();
        let hbitmap_result =
            CreateDIBSection(Some(hdc), &bmi, DIB_RGB_COLORS, &mut bits_ptr, None, 0);
        ReleaseDC(None, hdc);
        let hbitmap = hbitmap_result.ok()?;
        if bits_ptr.is_null() {
            let _ = DeleteObject(hbitmap.into());
            return None;
        }

        let dest_ptr = bits_ptr.cast::<u8>();
        std::ptr::write_bytes(dest_ptr, 0, (target_w * target_h * 4) as usize);

        let (offset_x, offset_y) = ((target_w - size) / 2, (target_h - size) / 2);

        for y in 0..size {
            let dest_row_start = (((offset_y + y) * target_w + offset_x) * 4) as usize;
            for x in 0..size {
                let si = y as usize * row_bytes + (x * 4) as usize;
                let a = (src[si + 3] as f32 * corner_coverage(size, radius, x, y)) as u8;

                if a > 0 {
                    let f = a as f32 / 255.0;
                    let di = dest_row_start + (x * 4) as usize;
                    *dest_ptr.add(di) = (src[si] as f32 * f) as u8;
                    *dest_ptr.add(di + 1) = (src[si + 1] as f32 * f) as u8;
                    *dest_ptr.add(di + 2) = (src[si + 2] as f32 * f) as u8;
                    *dest_ptr.add(di + 3) = a;
                }
            }
        }

        Some(hbitmap)
    }
}

/// Alpha multiplier (0..=1) for the rounded corner at `(x, y)` of a
/// `size`×`size` square with corner `radius`.
fn corner_coverage(size: u32, radius: i32, x: u32, y: u32) -> f32 {
    let r = radius.max(0) as u32;
    if r == 0 {
        return 1.0;
    }
    let is_top = y < r;
    let is_bottom = y >= size.saturating_sub(r);
    let is_left = x < r;
    let is_right = x >= size.saturating_sub(r);
    if !((is_top || is_bottom) && (is_left || is_right)) {
        return 1.0;
    }

    let r_f = r as f32;
    let cx = if is_left {
        r_f
    } else {
        size as f32 - r_f - 1.0
    };
    let cy = if is_top { r_f } else { size as f32 - r_f - 1.0 };
    let dist = ((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt();

    if dist > r_f {
        0.0
    } else if dist > r_f - 1.0 {
        r_f - dist
    } else {
        1.0
    }
}

fn cover_hash(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corners_are_transparent_and_the_middle_is_opaque() {
        let (size, radius) = (100, 12);
        assert_eq!(corner_coverage(size, radius, 0, 0), 0.0);
        assert_eq!(corner_coverage(size, radius, size - 1, size - 1), 0.0);
        assert_eq!(corner_coverage(size, radius, size / 2, size / 2), 1.0);
        // First pixel past the corner arc is fully opaque.
        assert_eq!(
            corner_coverage(size, radius, radius as u32, radius as u32),
            1.0
        );
    }

    #[test]
    fn zero_radius_keeps_every_pixel() {
        assert_eq!(corner_coverage(100, 0, 0, 0), 1.0);
        assert_eq!(corner_coverage(100, 0, 99, 99), 1.0);
    }

    #[test]
    fn cover_hash_tracks_content() {
        assert_eq!(cover_hash(b"cover"), cover_hash(b"cover"));
        assert_ne!(cover_hash(b"cover"), cover_hash(b"coveR"));
    }
}
