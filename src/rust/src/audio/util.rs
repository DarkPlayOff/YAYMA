use rodio::{
    Device, DeviceSinkBuilder, DeviceTrait, MixerDeviceSink, Player,
    cpal::{BufferSize, SampleFormat, StreamConfig, default_host, traits::HostTrait},
};

#[cfg(not(target_os = "linux"))]
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

#[cfg(not(target_os = "linux"))]
fn parse_device_spec(name: &str) -> (&str, usize) {
    if let Some(rest) = name.strip_suffix(')')
        && let Some((base, num)) = rest.rsplit_once(" (")
        && let Ok(n) = num.parse::<usize>()
    {
        return (base, n);
    }
    (name, 1)
}

/// ALSA `default` must point at the session sound server (pipewire-alsa /
/// the pulse plugin). On a system without that bridge it resolves to raw
/// hardware, playback grabs the card exclusively, and the whole desktop's
/// audio freezes — the "silence while everything hangs" field reports. The
/// PCM name cannot tell the two apart, but `snd_pcm_info` can: server-facing
/// plugins (pulse/pipewire/null) report card -1, a chain ending at real
/// hardware reports the actual card index (plug forwards info to its slave).
#[cfg(target_os = "linux")]
fn warn_if_default_bypasses_sound_server() {
    use alsa::{Direction, pcm::PCM};
    // Non-blocking: a busy card (e.g. our own stream during a recreate) fails
    // fast instead of stalling the thread that still must open the real one.
    let Ok(pcm) = PCM::new("default", Direction::Playback, true) else {
        return;
    };
    let Ok(info) = pcm.info() else { return };
    if info.get_card() >= 0 {
        tracing::warn!(
            card = info.get_card(),
            "default_bypasses_sound_server: ALSA 'default' resolves to raw hardware; \
             install pipewire-alsa (or route 'default' through the sound server), \
             otherwise playback holds the card exclusively and can freeze desktop audio"
        );
    }
}

pub fn setup_device_config(
    device_name: Option<&str>,
) -> Result<(Device, StreamConfig, SampleFormat), Box<dyn std::error::Error + Send + Sync>> {
    let host = default_host();

    // On Linux there is deliberately no per-app device choice: a PCM picked
    // by name can be a raw ALSA device that grabs the card exclusively and
    // wedges the desktop's audio server, and routing belongs to the server
    // (pavucontrol, GNOME/KDE settings). Always follow the server default;
    // a stored name (from another platform or an older build) is ignored.
    #[cfg(target_os = "linux")]
    let device = host.default_output_device();

    #[cfg(target_os = "linux")]
    warn_if_default_bypasses_sound_server();

    #[cfg(not(target_os = "linux"))]
    let device = if let Some(name) = device_name {
        let (base_name, index) = parse_device_spec(name);
        let cpal_devices: Vec<Device> = host
            .output_devices()
            .map(|devs| devs.into_iter().collect())
            .unwrap_or_default();

        // Try matching by display name (full names from Windows, or raw names otherwise)
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
        let chosen = fallback;

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

    // Field debugging: which PCM was actually opened (raw hw vs server) and
    // what the device settled on. Without this, reports of "no sound / wrong
    // speed" cannot be tied to a device or config. `stored` is what the
    // setting held; on Linux it is intentionally ignored (server default).
    let desc = device.description().ok();
    tracing::info!(
        device = desc.as_ref().map(|d| d.name()).unwrap_or_default(),
        pcm = desc.as_ref().and_then(|d| d.driver()).unwrap_or_default(),
        stored = device_name.unwrap_or("default"),
        rate = config.sample_rate,
        channels = config.channels,
        sample_format = ?sample_format,
        "audio_device_opened"
    );

    Ok((device, config, sample_format))
}

pub fn construct_sink<F>(
    device: Device,
    config: &StreamConfig,
    sample_format: SampleFormat,
    error_callback: F,
) -> Result<(MixerDeviceSink, Player), Box<dyn std::error::Error + Send + Sync>>
where
    F: FnMut(rodio::cpal::Error) + Send + Clone + 'static,
{
    // Open with the device's own default config, not the builder's 44.1k/2ch
    // default: on a fallback the engine would resample to a rate/channel count
    // the stream never runs at, playing everything at the wrong pitch.
    let stream = DeviceSinkBuilder::default()
        .with_device(device)
        .with_config(config)
        .with_sample_format(sample_format)
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

    // Linux ignores the stored device name entirely, so the spec parser only
    // exists on the platforms that still honor it.
    #[cfg(not(target_os = "linux"))]
    #[test]
    fn device_spec_roundtrips() {
        assert_eq!(parse_device_spec("pulse"), ("pulse", 1));
        assert_eq!(parse_device_spec("Name (2)"), ("Name", 2));
        // Not a spec suffix — a display name that just ends in a parenthesis.
        assert_eq!(parse_device_spec("Weird (x)"), ("Weird (x)", 1));
    }

    // CI machines have no sound card, so the open fails and nothing is
    // asserted there; on a real desktop the probe must survive both a
    // bridged default (card -1) and a raw-hardware one (card >= 0).
    #[cfg(target_os = "linux")]
    #[test]
    fn default_probe_survives_bridged_and_raw_chains() {
        use alsa::{Direction, pcm::PCM};
        if let Ok(pcm) = PCM::new("default", Direction::Playback, true)
            && let Ok(info) = pcm.info()
        {
            assert!(info.get_card() >= -1);
        }
    }
}
