use rodio::{
    Device, DeviceSinkBuilder, DeviceTrait, MixerDeviceSink, Player,
    cpal::{BufferSize, SampleFormat, StreamConfig, default_host, traits::HostTrait},
};

fn extract_display_name(raw: &str) -> &str {
    if let Some(pos) = raw.find(" (") {
        let inner = &raw[pos + 2..];
        if let Some(stripped) = inner.strip_suffix(')') {
            return stripped;
        }
    }
    raw
}

#[cfg(target_os = "windows")]
pub(crate) fn get_windows_full_device_names() -> Vec<String> {
    use windows::Win32::Foundation::PROPERTYKEY;
    use windows::Win32::Media::Audio::{
        DEVICE_STATE_ACTIVE, IMMDeviceEnumerator, MMDeviceEnumerator, eRender,
    };
    use windows::Win32::System::Com::{
        CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
        STGM_READ,
    };
    use windows::core::GUID;

    let pkey_friendly_name = PROPERTYKEY {
        fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0),
        pid: 14,
    };

    let mut result = Vec::new();

    // SAFETY: COM is initialized and torn down on this same thread within the
    // block; every COM object lives only inside it, and the copied-out names are
    // plain Rust strings.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);

        if let Ok(enumerator) =
            CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL)
            && let Ok(collection) = enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)
            && let Ok(count) = collection.GetCount()
        {
            for i in 0..count {
                if let Ok(device) = collection.Item(i)
                    && let Ok(prop_store) = device.OpenPropertyStore(STGM_READ)
                    && let Ok(name_var) = prop_store.GetValue(&pkey_friendly_name)
                {
                    result.push(name_var.to_string());
                }
            }
        }

        CoUninitialize();
    }

    result
}

fn parse_device_spec(name: &str) -> (&str, usize) {
    if let Some(rest) = name.strip_suffix(')')
        && let Some((base, num)) = rest.rsplit_once(" (")
        && let Ok(n) = num.parse::<usize>()
    {
        return (base, n);
    }
    (name, 1)
}

/// True for ALSA PCMs that route through the session sound server
/// (PipeWire/PulseAudio). Raw hardware PCMs (`hw:`, `front:`, `dmix:` ...)
/// bypass it: opening one grabs the card exclusively and wedges every other
/// pulse client on the desktop — field-verified on PipeWire, where a stream
/// ending up on `hw:` froze system-wide audio for 15+ seconds.
/// No-op (always true) on platforms where cpal's default host is not ALSA.
#[cfg(target_os = "linux")]
pub(crate) fn is_server_mediated_pcm(name: &str) -> bool {
    !(name.starts_with("hw:")
        || name.starts_with("plughw:")
        || name.starts_with("front:")
        || name.starts_with("dmix:")
        || name.starts_with("sysdefault")
        || name.starts_with("surround"))
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn is_server_mediated_pcm(_name: &str) -> bool {
    true
}

pub fn setup_device_config(
    device_name: Option<&str>,
) -> Result<(Device, StreamConfig, SampleFormat), Box<dyn std::error::Error + Send + Sync>> {
    let host = default_host();
    let device = if let Some(name) = device_name {
        let (base_name, index) = parse_device_spec(name);
        let cpal_devices: Vec<Device> = host
            .output_devices()
            .map(|devs| devs.into_iter().collect())
            .unwrap_or_default();

        // Try matching by display name (full names from Windows, or raw names otherwise).
        // A stored raw-hardware PCM name (saved by an older build whose picker
        // still listed `hw:` devices) must never be honored: opening one grabs
        // the card exclusively and wedges the desktop's audio server, so fall
        // back to the default device, which routes through the server.
        let chosen = if is_server_mediated_pcm(base_name) {
            let mut matched = 0usize;
            let mut fallback: Option<Device> = None;

            #[cfg(target_os = "windows")]
            let windows_names: Vec<String> = get_windows_full_device_names();

            #[cfg_attr(not(target_os = "windows"), allow(unused_variables))]
            for (i, dev) in cpal_devices.iter().enumerate() {
                if let Ok(desc) = dev.description() {
                    #[cfg(target_os = "windows")]
                    let display = {
                        let full = windows_names
                            .get(i)
                            .map(|s| s.as_str())
                            .unwrap_or(desc.name());
                        extract_display_name(full).to_string()
                    };
                    #[cfg(not(target_os = "windows"))]
                    let display = extract_display_name(desc.name()).to_string();

                    if display == base_name {
                        if matched == index.saturating_sub(1) {
                            fallback = Some(dev.clone());
                            break;
                        }
                        matched += 1;
                    }
                }
            }
            fallback
        } else {
            None
        };

        chosen.or_else(|| host.default_output_device())
    } else {
        host.default_output_device()
    };
    // Reached from the cpal stream-error callback via PlaybackEngine::recreate, i.e.
    // exactly when the device just disappeared — panicking here took the app down on
    // an unplugged DAC or a disconnected BT headset.
    let device = device.ok_or_else(|| {
        Box::<dyn std::error::Error + Send + Sync>::from("no audio output device available")
    })?;

    let config: StreamConfig;
    let sample_format: SampleFormat;

    if let Ok(default_config) = device.default_output_config() {
        config = default_config.config();
        sample_format = default_config.sample_format();
    } else {
        config = StreamConfig {
            channels: 2,
            sample_rate: 44100,
            buffer_size: BufferSize::Default,
        };
        sample_format = SampleFormat::F32;
    }

    Ok((device, config, sample_format))
}

pub fn construct_sink<F>(
    device: Device,
    _config: &StreamConfig,
    _sample_format: SampleFormat,
    error_callback: F,
) -> Result<(MixerDeviceSink, Player), Box<dyn std::error::Error + Send + Sync>>
where
    F: FnMut(rodio::cpal::Error) + Send + Clone + 'static,
{
    let stream = DeviceSinkBuilder::default()
        .with_device(device)
        .with_error_callback(error_callback)
        .open_sink_or_fallback()
        .map_err(|e| Box::<dyn std::error::Error + Send + Sync>::from(e.to_string()))?;
    let mixer = stream.mixer();
    let sink = Player::connect_new(mixer);

    Ok((stream, sink))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_spec_roundtrips() {
        assert_eq!(parse_device_spec("pulse"), ("pulse", 1));
        assert_eq!(parse_device_spec("Name (2)"), ("Name", 2));
        // Not a spec suffix — a display name that just ends in a parenthesis.
        assert_eq!(parse_device_spec("Weird (x)"), ("Weird (x)", 1));
    }

    // The picker and the stored-name matcher must agree: server-mediated
    // PCMs are usable, raw hardware PCMs are not. Meaningless (always true)
    // on non-Linux hosts, so only assert there.
    #[cfg(target_os = "linux")]
    #[test]
    fn raw_hardware_pcms_are_rejected() {
        for raw in [
            "hw:CARD=PCH,DEV=0",
            "plughw:CARD=PCH,DEV=0",
            "front:CARD=PCH,DEV=0",
            "surround51:CARD=PCH,DEV=0",
            "dmix:CARD=PCH,DEV=0",
            "sysdefault:CARD=PCH,DEV=0",
        ] {
            assert!(!is_server_mediated_pcm(raw), "{raw} must be rejected");
        }
        for server in ["default", "pulse", "pipewire"] {
            assert!(is_server_mediated_pcm(server), "{server} must be kept");
        }
    }
}
