use parking_lot::Mutex;
use std::cell::RefCell;
use std::sync::atomic::{AtomicIsize, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, OnceLock};
use windows::{
    Win32::Foundation::*, Win32::Graphics::Dwm::*, Win32::Graphics::Gdi::*,
    Win32::Graphics::Imaging::*, Win32::System::Com::*, Win32::System::Threading::GetCurrentProcessId,
    Win32::UI::Shell::SetWindowSubclass, Win32::UI::Shell::*, Win32::UI::WindowsAndMessaging::*,
    core::*,
};

const SUBCLASS_ID: usize = 1337;
const WM_APP_REMOTECALL: u32 = WM_APP + 1337;
/// Posted by `taskbar.rs` with a heap-allocated `taskbar::UiCmd` in LPARAM;
/// the subclass executes it on the platform thread and frees the box.
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

thread_local! {
    static WIC_FACTORY: RefCell<Option<IWICImagingFactory>> = const { RefCell::new(None) };
}

static HOOK_HANDLE: AtomicIsize = AtomicIsize::new(0);

#[derive(Clone, Copy)]
pub struct ThumbnailManager {
    hwnd_ptr: isize,
}

unsafe impl Send for ThumbnailManager {}
unsafe impl Sync for ThumbnailManager {}

impl ThumbnailManager {
    pub fn new(hwnd_raw: *mut std::ffi::c_void) -> Option<Self> {
        let target_hwnd = if hwnd_raw.is_null() {
            get_flutter_hwnd()?
        } else {
            HWND(hwnd_raw as *mut _)
        };

        unsafe {
            let thread_id = GetWindowThreadProcessId(target_hwnd, None);
            if let Ok(hook) = SetWindowsHookExW(WH_CALLWNDPROC, Some(hook_proc), None, thread_id) {
                HOOK_HANDLE.store(hook.0 as isize, Ordering::Relaxed);
                let _ = SendMessageW(
                    target_hwnd,
                    WM_APP_REMOTECALL,
                    Some(WPARAM(0)),
                    Some(LPARAM(0)),
                );
            }
        }

        Some(Self {
            hwnd_ptr: target_hwnd.0 as isize,
        })
    }

    pub fn update_cover(&self, img_bytes: Vec<u8>) {
        let hash = cover_hash(&img_bytes);
        if INVALIDATED_HASH.load(Ordering::Relaxed) == hash {
            return;
        }

        let bytes = Arc::new(img_bytes);
        *LAST_COVER.lock() = Some(Cover {
            hash,
            bytes: bytes.clone(),
        });

        // Don't delete the current bitmaps here: they are replaced only after
        // the prerendered ones are installed, and DWM may still be reading
        // them. Just invalidate so DWM re-requests.
        let sizes = REQUESTED_SIZES.lock().clone();
        if sizes.is_empty() {
            // DWM has never asked yet; the first request will decode
            // LAST_COVER synchronously. Nothing to invalidate into.
            INVALIDATED_HASH.store(hash, Ordering::Relaxed);
            return;
        }

        let hwnd = self.hwnd_ptr;
        prerender_sender().send(PrerenderJob {
            hash,
            bytes,
            hwnd,
        }).ok();
    }
}

struct PrerenderJob {
    hash: u64,
    bytes: Arc<Vec<u8>>,
    hwnd: isize,
}

fn prerender_sender() -> &'static std::sync::mpsc::Sender<PrerenderJob> {
    static SENDER: OnceLock<std::sync::mpsc::Sender<PrerenderJob>> = OnceLock::new();
    SENDER.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::channel::<PrerenderJob>();
        std::thread::Builder::new()
            .name("thumbnail-prerender".into())
            .spawn(move || prerender_loop(rx))
            .expect("spawn thumbnail prerender thread");
        tx
    })
}

/// Decodes covers for the sizes DWM has been asking for, off the platform
/// thread. The WIC decode of a JPEG cover takes tens of milliseconds; doing
/// it inside `subclass_proc` used to stall the Flutter platform thread and
/// starve DWM's iconic-bitmap requests (the "loading" glass in the preview).
fn prerender_loop(rx: std::sync::mpsc::Receiver<PrerenderJob>) {
    ensure_com();
    while let Ok(job) = rx.recv() {
        // A newer cover arrived while we were queued: drop this one entirely,
        // the newer job will render it.
        if LAST_COVER.lock().as_ref().map(|c| c.hash) != Some(job.hash) {
            continue;
        }

        let sizes = REQUESTED_SIZES.lock().clone();
        let mut installed_any = false;
        for (tw, th) in sizes {
            if let Some(h) = create_hbitmap_from_wic(&job.bytes, tw, th) {
                let mut ready = READY_BITMAPS.lock();
                if LAST_COVER.lock().as_ref().map(|c| c.hash) != Some(job.hash) {
                    unsafe {
                        let _ = DeleteObject(HBITMAP(h.0 as *mut _).into());
                    }
                    break;
                }
                replace_ready_bitmap(&mut ready, tw, th, h);
                installed_any = true;
            }
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

/// Replace (or add) the cached bitmap for `(tw, th)`, deleting the evicted
/// HBITMAP. Caller holds `READY_BITMAPS`.
fn replace_ready_bitmap(ready: &mut Vec<CachedBitmap>, tw: u32, th: u32, h: HBITMAP) {
    if let Some(pos) = ready
        .iter()
        .position(|c| c.width == tw && c.height == th)
    {
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
    unsafe {
        if code >= 0 {
            let msg = &*(lparam.0 as *const CWPSTRUCT);
            if msg.message == WM_APP_REMOTECALL {
                let hwnd = msg.hwnd;
                let force_iconic = BOOL::from(true);
                let attr_ptr = &force_iconic as *const _ as *const _;

                let _ = DwmSetWindowAttribute(hwnd, DWMWA_FORCE_ICONIC_REPRESENTATION, attr_ptr, 4);
                let _ = DwmSetWindowAttribute(hwnd, DWMWA_HAS_ICONIC_BITMAP, attr_ptr, 4);
                let _ = SetWindowSubclass(hwnd, Some(subclass_proc), SUBCLASS_ID, 0);

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
    unsafe {
        match msg {
            WM_DWMSENDICONICTHUMBNAIL | WM_DWMSENDICONICLIVEPREVIEWBITMAP => {
                handle_iconic_request(hwnd, msg, lparam)
            }
            _ => {
                if super::taskbar::handle_window_message(hwnd, msg, wparam, lparam) {
                    LRESULT(0)
                } else {
                    DefSubclassProc(hwnd, msg, wparam, lparam)
                }
            }
        }
    }
}

/// Answer a DWM request for the iconic thumbnail / live preview bitmap.
///
/// Steady state: the background prerender thread has already built a bitmap
/// for this size, so this only swaps a pointer. First-ever request for a size
/// still decodes synchronously (once), then caches.
unsafe fn handle_iconic_request(hwnd: HWND, msg: u32, lparam: LPARAM) -> LRESULT {
    unsafe {
        let (tw, th) = match msg {
            WM_DWMSENDICONICTHUMBNAIL => ((lparam.0 >> 16) as u32, (lparam.0 & 0xFFFF) as u32),
            WM_DWMSENDICONICLIVEPREVIEWBITMAP => {
                let mut rc = RECT::default();
                let _ = GetClientRect(hwnd, &mut rc);
                ((rc.right - rc.left) as u32, (rc.bottom - rc.top) as u32)
            }
            _ => return DefSubclassProc(hwnd, msg, WPARAM(0), lparam),
        };

        if tw == 0 || th == 0 {
            return DefSubclassProc(hwnd, msg, WPARAM(0), lparam);
        }

        record_requested_size(tw, th);

        let mut ready = READY_BITMAPS.lock();
        // The lock is held across the DWM call: the prerender thread takes the
        // same lock to replace bitmaps, so an evicted HBITMAP can't be deleted
        // while DWM is still reading it.
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
}

fn record_requested_size(tw: u32, th: u32) {
    let mut sizes = REQUESTED_SIZES.lock();
    if sizes.contains(&(tw, th)) {
        return;
    }
    sizes.insert(0, (tw, th));
    while sizes.len() > MAX_READY_BITMAPS {
        sizes.pop();
        let mut ready = READY_BITMAPS.lock();
        if let Some(old) = ready.pop() {
            unsafe {
                let _ = DeleteObject(HBITMAP(old.hbitmap_ptr as *mut _).into());
            }
        }
    }
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
        let radius = (size as f32 * 0.12) as i32;
        let r_f = radius as f32;

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

        let dest_ptr = bits_ptr as *mut u8;
        std::ptr::write_bytes(dest_ptr, 0, (target_w * target_h * 4) as usize);

        let (offset_x, offset_y) = ((target_w - size) / 2, (target_h - size) / 2);
        let stride = size * 4;
        let mut row_buf = vec![0u8; stride as usize];

        for y in 0..size {
            let prc = WICRect {
                X: 0,
                Y: y as i32,
                Width: size as i32,
                Height: 1,
            };
            if converter.CopyPixels(&prc, stride, &mut row_buf).is_err() {
                continue;
            }

            let dest_row_start = ((offset_y + y) * target_w * 4 + offset_x * 4) as usize;
            let is_top = y < radius as u32;
            let is_bottom = y >= size - radius as u32;

            for x in 0..size {
                let mut a = row_buf[(x * 4 + 3) as usize];

                if (is_top || is_bottom) && (x < radius as u32 || x >= size - radius as u32) {
                    let cx = if x < radius as u32 {
                        r_f
                    } else {
                        size as f32 - r_f - 1.0
                    };
                    let cy = if is_top { r_f } else { size as f32 - r_f - 1.0 };
                    let dist = ((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt();

                    if dist > r_f {
                        a = 0;
                    } else if dist > r_f - 1.0 {
                        a = (a as f32 * (r_f - dist)) as u8;
                    }
                }

                if a > 0 {
                    let f = a as f32 / 255.0;
                    let di = dest_row_start + (x * 4) as usize;
                    let si = (x * 4) as usize;
                    *dest_ptr.add(di) = (row_buf[si] as f32 * f) as u8;
                    *dest_ptr.add(di + 1) = (row_buf[si + 1] as f32 * f) as u8;
                    *dest_ptr.add(di + 2) = (row_buf[si + 2] as f32 * f) as u8;
                    *dest_ptr.add(di + 3) = a;
                }
            }
        }

        Some(hbitmap)
    }
}

fn cover_hash(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x1_0000_0001_b3);
    }
    hash
}

#[cfg(not(target_os = "windows"))]
#[derive(Clone, Copy)]
pub struct ThumbnailManager;
#[cfg(not(target_os = "windows"))]
impl ThumbnailManager {
    pub fn new(_h: *mut std::ffi::c_void) -> Option<Self> {
        Some(Self)
    }
    pub fn update_cover(&self, _b: Vec<u8>) {}
}
