use std::fs::File;
use std::io::{BufWriter, Write};
use symphonia::core::codecs::CODEC_TYPE_FLAC;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::probe::Hint;

/// Извлекает Native FLAC из MP4-контейнера
pub fn extract_native_flac(
    input_path: &str,
    output_path: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let file = File::open(input_path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    hint.with_extension("flac"); // Подсказка, что внутри может быть FLAC

    // Инициализируем реестр форматов и кодеков
    let probe = symphonia::default::get_probe();

    // Пробуем определить формат
    let probed = probe.format(&hint, mss, &FormatOptions::default(), &Default::default())?;

    let mut format = probed.format;

    // Ищем аудио-дорожку с кодеком FLAC
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec == CODEC_TYPE_FLAC)
        .ok_or("FLAC track not found in the container")?;

    let track_id = track.id;
    let codec_params = &track.codec_params;

    // STREAMINFO блок обязателен для Native FLAC. В MP4 он лежит в extra_data (34 байта).
    let extra_data = codec_params
        .extra_data
        .as_ref()
        .ok_or("Missing FLAC STREAMINFO (extra_data)")?;

    let out_file = File::create(output_path)?;
    let mut writer = BufWriter::new(out_file);

    // 1. Пишем магическое число "fLaC"
    writer.write_all(b"fLaC")?;

    // 2. Пишем заголовок блока метаданных STREAMINFO
    // Формат заголовка FLAC Metadata Block:
    // 1 бит: "последний блок" (1)
    // 7 бит: тип блока (0 для STREAMINFO)
    // 24 бита: длина данных блока
    let length = extra_data.len() as u32;
    let mut header = [0u8; 4];
    header[0] = 0x80; // Флаг последнего блока | Тип 0 (StreamInfo)
    header[1] = ((length >> 16) & 0xFF) as u8;
    header[2] = ((length >> 8) & 0xFF) as u8;
    header[3] = (length & 0xFF) as u8;

    writer.write_all(&header)?;
    writer.write_all(extra_data)?;

    // 3. Читаем пакеты из MP4 и пишем их "как есть" (фреймы FLAC)
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() == track_id {
            writer.write_all(&packet.data)?;
        }
    }

    writer.flush()?;
    Ok(())
}
