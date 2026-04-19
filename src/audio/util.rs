use rodio::{
    Device, DeviceSinkBuilder, DeviceTrait, MixerDeviceSink, Player,
    cpal::{BufferSize, SampleFormat, StreamConfig, default_host, traits::HostTrait},
};

pub fn setup_device_config() -> (Device, StreamConfig, SampleFormat) {
    let host = default_host();
    let device = host.default_output_device().unwrap();
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
