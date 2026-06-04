use rodio::{
    Device, DeviceSinkBuilder, DeviceTrait, MixerDeviceSink, Player,
    cpal::{BufferSize, SampleFormat, StreamConfig, default_host, traits::HostTrait},
};

fn extract_display_name(raw: &str) -> &str {
    if let Some(pos) = raw.find(" (") {
        let inner = &raw[pos + 2..];
        if inner.ends_with(')') {
            return &inner[..inner.len() - 1];
        }
    }
    raw
}

#[cfg(target_os = "windows")]
pub(crate) fn get_windows_full_device_names() -> Vec<String> {
    use windows::core::GUID;
    use windows::Win32::Foundation::PROPERTYKEY;
    use windows::Win32::Media::Audio::{
        eRender, IMMDeviceEnumerator, MMDeviceEnumerator, DEVICE_STATE_ACTIVE,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, STGM_READ, CLSCTX_ALL,
        COINIT_MULTITHREADED,
    };

    let pkey_friendly_name = PROPERTYKEY {
        fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0),
        pid: 14,
    };

    let mut result = Vec::new();

    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);

        if let Ok(enumerator) = CoCreateInstance::<_, IMMDeviceEnumerator>(
            &MMDeviceEnumerator,
            None,
            CLSCTX_ALL,
        ) {
            if let Ok(collection) = enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) {
                if let Ok(count) = collection.GetCount() {
                    for i in 0..count {
                        if let Ok(device) = collection.Item(i) {
                            if let Ok(prop_store) = device.OpenPropertyStore(STGM_READ) {
                                if let Ok(name_var) =
                                    prop_store.GetValue(&pkey_friendly_name)
                                {
                                    result.push(name_var.to_string());
                                }
                            }
                        }
                    }
                }
            }
        }

        CoUninitialize();
    }

    result
}

fn parse_device_spec(name: &str) -> (&str, usize) {
    if let Some(rest) = name.strip_suffix(')') {
        if let Some((base, num)) = rest.rsplit_once(" (") {
            if let Ok(n) = num.parse::<usize>() {
                return (base, n);
            }
        }
    }
    (name, 1)
}

pub fn setup_device_config(device_name: Option<&str>) -> (Device, StreamConfig, SampleFormat) {
    let host = default_host();
    let device = if let Some(name) = device_name {
        let (base_name, index) = parse_device_spec(name);
        let cpal_devices: Vec<Device> = host
            .output_devices()
            .map(|devs| devs.into_iter().collect())
            .unwrap_or_default();

        // Try matching by display name (full names from Windows, or raw names otherwise)
        let chosen = {
            let mut matched = 0usize;
            let mut fallback: Option<Device> = None;

            #[cfg(target_os = "windows")]
            let windows_names: Vec<String> = get_windows_full_device_names();

            for (i, dev) in cpal_devices.iter().enumerate() {
                if let Ok(desc) = dev.description() {
                    #[cfg(target_os = "windows")]
                    let display = {
                        let full = windows_names.get(i).map(|s| s.as_str()).unwrap_or(desc.name());
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
        };

        chosen.or_else(|| host.default_output_device())
    } else {
        host.default_output_device()
    };
    let device = device.unwrap();

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

    (device, config, sample_format)
}

pub fn construct_sink<F>(
    device: Device,
    _config: &StreamConfig,
    _sample_format: SampleFormat,
    error_callback: F,
) -> Result<(MixerDeviceSink, Player), Box<dyn std::error::Error + Send + Sync>>
where
    F: FnMut(rodio::cpal::StreamError) + Send + Clone + 'static,
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
