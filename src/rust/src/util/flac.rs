use std::fs::File;
use std::io::{BufWriter, Write};
use symphonia::core::codecs::CODEC_TYPE_FLAC;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::probe::Hint;

/// Extracts Native FLAC from an MP4 container
pub fn extract_native_flac(
    input_path: &str,
    output_path: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let file = File::open(input_path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    hint.with_extension("flac"); // Hint that the content might be FLAC

    let probe = symphonia::default::get_probe();

    let probed = probe.format(&hint, mss, &FormatOptions::default(), &Default::default())?;

    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec == CODEC_TYPE_FLAC)
        .ok_or("FLAC track not found in the container")?;

    let track_id = track.id;
    let codec_params = &track.codec_params;

    // STREAMINFO block is mandatory for Native FLAC. In MP4, it is stored in extra_data (34 bytes).
    let extra_data = codec_params
        .extra_data
        .as_ref()
        .ok_or("Missing FLAC STREAMINFO (extra_data)")?;

    let out_file = File::create(output_path)?;
    let mut writer = BufWriter::new(out_file);

    writer.write_all(b"fLaC")?;

    // Write STREAMINFO metadata block header
    // FLAC Metadata Block header format:
    // 1 bit: "last block" (1)
    // 7 bits: block type (0 for STREAMINFO)
    // 24 bits: block data length
    let length = extra_data.len() as u32;
    let mut header = [0u8; 4];
    header[0] = 0x80; // Last block flag | Type 0 (StreamInfo)
    header[1] = ((length >> 16) & 0xFF) as u8;
    header[2] = ((length >> 8) & 0xFF) as u8;
    header[3] = (length & 0xFF) as u8;

    writer.write_all(&header)?;
    writer.write_all(extra_data)?;

    // Read packets from MP4 and write them as is (FLAC frames)
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() == track_id {
            writer.write_all(&packet.data)?;
        }
    }

    writer.flush()?;
    Ok(())
}
