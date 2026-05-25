import 'dart:typed_data';

/// Wraps raw 16-bit little-endian PCM samples in a minimal WAV (RIFF/WAVE)
/// container so just_audio's platform decoders can play them. The gateway's
/// ElevenLabs-compatible TTS WS returns raw PCM; just_audio needs a header.
Uint8List wrapPcmAsWav(
  Uint8List pcm, {
  int sampleRate = 24000,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  final dataSize = pcm.length;
  final fileSize = 36 + dataSize;

  final out = BytesBuilder(copy: false);
  // RIFF header
  out.add(const [0x52, 0x49, 0x46, 0x46]); // "RIFF"
  out.add(_u32le(fileSize));
  out.add(const [0x57, 0x41, 0x56, 0x45]); // "WAVE"
  // fmt subchunk
  out.add(const [0x66, 0x6D, 0x74, 0x20]); // "fmt "
  out.add(_u32le(16));
  out.add(_u16le(1)); // PCM
  out.add(_u16le(channels));
  out.add(_u32le(sampleRate));
  out.add(_u32le(byteRate));
  out.add(_u16le(blockAlign));
  out.add(_u16le(bitsPerSample));
  // data subchunk
  out.add(const [0x64, 0x61, 0x74, 0x61]); // "data"
  out.add(_u32le(dataSize));
  out.add(pcm);
  return out.toBytes();
}

Uint8List _u32le(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _u16le(int v) {
  final b = ByteData(2)..setUint16(0, v, Endian.little);
  return b.buffer.asUint8List();
}
