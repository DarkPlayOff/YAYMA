use parking_lot::Mutex;
use std::cell::RefCell;
use std::sync::LazyLock;
use std::sync::atomic::{AtomicIsize, Ordering};
use windows::{
    Win32::Foundation::*, Win32::Graphics::Dwm::*, Win32::Graphics::Gdi::*,
    Win32::Graphics::Imaging::*, Win32::System::Com::*,
    Win32::System::Threading::GetCurrentProcessId, Win32::UI::Shell::SetWindowSubclass,
    Win32::UI::Shell::*, Win32::UI::WindowsAndMessaging::*, core::*,
};

struct CachedBitmap {
    hbitmap_ptr: isize,
    width: u32,
    height: u32,
    raw_bytes: Vec<u8>,
}

static CURRENT_BITMAP: LazyLock<Mutex<Option<CachedBitmap>>> = LazyLock::new(|| Mutex::new(None));
static PENDING_BYTES: LazyLock<Mutex<Option<Vec<u8>>>> = LazyLock::new(|| Mutex::new(None));

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

        tracing::info!("ThumbnailManager: Hooking HWND: {:?}", target_hwnd.0);

        unsafe {
            let thread_id = GetWindowThreadProcessId(target_hwnd, None);
            if let Ok(hook) = SetWindowsHookExW(WH_CALLWNDPROC, Some(hook_proc), None, thread_id) {
                HOOK_HANDLE.store(hook.0 as isize, Ordering::Relaxed);
                let _ = SendMessageW(target_hwnd, WM_APP + 1337, Some(WPARAM(0)), Some(LPARAM(0)));
            }
        }

        Some(Self {
            hwnd_ptr: target_hwnd.0 as isize,
        })
    }

    pub fn update_cover(&self, img_bytes: Vec<u8>) {
        *PENDING_BYTES.lock() = Some(img_bytes);

        if let Some(old) = CURRENT_BITMAP.lock().take() {
            unsafe {
                let _ = DeleteObject(HBITMAP(old.hbitmap_ptr as *mut _).into());
            }
        }

        unsafe {
            let hwnd = HWND(self.hwnd_ptr as *mut std::ffi::c_void);
            if IsWindow(Some(hwnd)).as_bool() {
                let _ = DwmInvalidateIconicBitmaps(hwnd);
            }
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
    if target_hwnd.0.is_null() {
        None
    } else {
        Some(target_hwnd)
    }
}

unsafe extern "system" fn enum_windows_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let mut pid = 0;
    let _ = unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    if pid == unsafe { GetCurrentProcessId() } {
        let mut class_name = [0u16; 256];
        let len = unsafe { GetClassNameW(hwnd, &mut class_name) };
        let class_str = String::from_utf16_lossy(&class_name[..len as usize]);
        if class_str == "FLUTTER_RUNNER_WIN32_WINDOW" {
            let ptr = lparam.0 as *mut HWND;
            unsafe { *ptr = hwnd };
            return BOOL::from(false);
        }
    }
    BOOL::from(true)
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let msg = unsafe { &*(lparam.0 as *const CWPSTRUCT) };
        if msg.message == WM_APP + 1337 {
            let hwnd = msg.hwnd;
            let force_iconic = BOOL::from(true);
            let attr_ptr = std::ptr::addr_of!(force_iconic) as *const _;

            let _ = unsafe {
                DwmSetWindowAttribute(hwnd, DWMWA_FORCE_ICONIC_REPRESENTATION, attr_ptr, 4)
            };
            let _ = unsafe { DwmSetWindowAttribute(hwnd, DWMWA_HAS_ICONIC_BITMAP, attr_ptr, 4) };
            let _ = unsafe { SetWindowSubclass(hwnd, Some(subclass_proc), 1337, 0) };

            let hook = HOOK_HANDLE.swap(0, Ordering::Relaxed);
            if hook != 0 {
                let _ = unsafe { UnhookWindowsHookEx(HHOOK(hook as *mut std::ffi::c_void)) };
            }
        }
    }
    unsafe { CallNextHookEx(Some(HHOOK::default()), code, wparam, lparam) }
}

unsafe extern "system" fn subclass_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    let (tw, th) = match msg {
        WM_DWMSENDICONICTHUMBNAIL => ((lparam.0 >> 16) as u32, (lparam.0 & 0xFFFF) as u32),
        WM_DWMSENDICONICLIVEPREVIEWBITMAP => {
            let mut rc = RECT::default();
            let _ = unsafe { GetClientRect(hwnd, &mut rc) };
            ((rc.right - rc.left) as u32, (rc.bottom - rc.top) as u32)
        }
        _ => return unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) },
    };

    if tw == 0 && th == 0 {
        return unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) };
    }

    let mut hbitmap_ptr_to_set = None;
    {
        let mut cache_guard = CURRENT_BITMAP.lock();
        if let Some(cache) = cache_guard
            .as_ref()
            .filter(|c| c.width == tw && c.height == th)
        {
            hbitmap_ptr_to_set = Some(cache.hbitmap_ptr);
        }

        if hbitmap_ptr_to_set.is_none() {
            let bytes_to_use = PENDING_BYTES
                .lock()
                .clone()
                .or_else(|| cache_guard.as_ref().map(|c| c.raw_bytes.clone()));

            if let Some(bytes) = bytes_to_use
                && let Some(h) = create_hbitmap_from_wic(&bytes, tw, th)
            {
                if let Some(old) = cache_guard.take() {
                    let _ = unsafe { DeleteObject(HBITMAP(old.hbitmap_ptr as *mut _).into()) };
                }
                let ptr = h.0 as isize;
                *cache_guard = Some(CachedBitmap {
                    hbitmap_ptr: ptr,
                    width: tw,
                    height: th,
                    raw_bytes: bytes,
                });
                hbitmap_ptr_to_set = Some(ptr);
            }
        }
    }

    if let Some(ptr) = hbitmap_ptr_to_set {
        let h = HBITMAP(ptr as *mut _);
        if msg == WM_DWMSENDICONICTHUMBNAIL {
            let _ = unsafe { DwmSetIconicThumbnail(hwnd, h, 0) };
        } else {
            let _ = unsafe { DwmSetIconicLivePreviewBitmap(hwnd, h, None, 0) };
        }
    }

    LRESULT(0)
}

fn create_hbitmap_from_wic(bytes: &[u8], target_w: u32, target_h: u32) -> Option<HBITMAP> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        let factory = WIC_FACTORY.with(|f| {
            if f.borrow().is_none() {
                let f_res: core::result::Result<IWICImagingFactory, _> =
                    CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER);
                *f.borrow_mut() = f_res.ok();
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

        let mut bgra_data = vec![0u8; (target_w * target_h * 4) as usize];
        let mut temp_buf = vec![0u8; (size * size * 4) as usize];
        let stride = size * 4;
        if converter
            .CopyPixels(std::ptr::null(), stride, &mut temp_buf)
            .is_err()
        {
            return None;
        }

        let (offset_x, offset_y) = ((target_w - size) / 2, (target_h - size) / 2);
        let r_f = radius as f32;

        for y in 0..size {
            for x in 0..size {
                let src_idx = (y * stride + x * 4) as usize;
                let dest_idx = ((offset_y + y) * target_w * 4 + (offset_x + x) * 4) as usize;
                let mut a = temp_buf[src_idx + 3];

                let dx = (r_f - x as f32)
                    .max(x as f32 - (size as f32 - r_f - 1.0))
                    .max(0.0);
                let dy = (r_f - y as f32)
                    .max(y as f32 - (size as f32 - r_f - 1.0))
                    .max(0.0);

                if dx > 0.0 && dy > 0.0 {
                    let dist = (dx * dx + dy * dy).sqrt();
                    if dist > r_f {
                        a = 0;
                    } else if dist > r_f - 1.0 {
                        a = (a as f32 * (r_f - dist)) as u8;
                    }
                }

                if a > 0 {
                    let f = a as f32 / 255.0;
                    bgra_data[dest_idx] = (temp_buf[src_idx] as f32 * f) as u8;
                    bgra_data[dest_idx + 1] = (temp_buf[src_idx + 1] as f32 * f) as u8;
                    bgra_data[dest_idx + 2] = (temp_buf[src_idx + 2] as f32 * f) as u8;
                    bgra_data[dest_idx + 3] = a;
                }
            }
        }

        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: target_w as i32,
                biHeight: -(target_h as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: 0,
                biSizeImage: 0,
                biXPelsPerMeter: 0,
                biYPelsPerMeter: 0,
                biClrUsed: 0,
                biClrImportant: 0,
            },
            ..Default::default()
        };
        let hdc = GetDC(None);
        let mut ptr = std::ptr::null_mut();
        let hbitmap = CreateDIBSection(Some(hdc), &bmi, DIB_RGB_COLORS, &mut ptr, None, 0);
        let _ = ReleaseDC(None, hdc);

        if let Ok(h) = hbitmap
            && !h.is_invalid()
            && !ptr.is_null()
        {
            std::ptr::copy_nonoverlapping(bgra_data.as_ptr(), ptr as *mut u8, bgra_data.len());
            return Some(h);
        }
        None
    }
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
