import 'dart:typed_data';

/// Removes metadata from a JPEG before it leaves the device: EXIF (GPS
/// position, camera and capture time), XMP, comments and other APPn blocks.
///
/// JFIF, Adobe and ICC colour segments are kept so the image still decodes
/// and displays the same. The EXIF orientation is kept as a minimal EXIF
/// block because the image picker scales pixels without rotating them.
///
/// Returns [bytes] unchanged when they are not a well-formed JPEG.
Uint8List stripJpegMetadata(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return bytes;

  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  int? orientation;
  var wroteOrientation = false;
  var i = 2;

  while (i + 1 < bytes.length) {
    if (bytes[i] != 0xFF) return bytes;
    final marker = bytes[i + 1];

    // Fill bytes before a marker.
    if (marker == 0xFF) {
      i++;
      continue;
    }

    // Markers without a length field.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      out.add(Uint8List.sublistView(bytes, i, i + 2));
      i += 2;
      continue;
    }
    if (marker == 0xD9) {
      out.add(const [0xFF, 0xD9]);
      return out.toBytes();
    }

    if (i + 4 > bytes.length) return bytes;
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    final end = i + 2 + length;
    if (length < 2 || end > bytes.length) return bytes;

    // Start of scan: everything after this is image data.
    if (marker == 0xDA) {
      if (!wroteOrientation && orientation != null) {
        out.add(_orientationOnlyExif(orientation));
      }
      out.add(Uint8List.sublistView(bytes, i));
      return out.toBytes();
    }

    final payloadStart = i + 4;
    if (marker == 0xE1 && _startsWith(bytes, payloadStart, end, _exifHeader)) {
      orientation ??= _readOrientation(bytes, payloadStart + 6, end);
    }

    if (_isMetadataSegment(bytes, marker, payloadStart, end)) {
      i = end;
      continue;
    }

    // Put the orientation back after JFIF, ahead of the image tables.
    if (!wroteOrientation && orientation != null && marker != 0xE0) {
      out.add(_orientationOnlyExif(orientation));
      wroteOrientation = true;
    }
    out.add(Uint8List.sublistView(bytes, i, end));
    i = end;
  }
  return bytes;
}

const List<int> _exifHeader = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // Exif\0\0
const List<int> _iccHeader = [
  0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, // ICC_PROFILE
];

bool _isMetadataSegment(Uint8List bytes, int marker, int start, int end) {
  if (marker == 0xFE) return true; // COM
  if (marker < 0xE0 || marker > 0xEF) return false;
  if (marker == 0xE0) return false; // JFIF
  if (marker == 0xEE) return false; // Adobe colour transform
  if (marker == 0xE2 && _startsWith(bytes, start, end, _iccHeader)) {
    return false;
  }
  return true;
}

bool _startsWith(Uint8List bytes, int start, int end, List<int> prefix) {
  if (end - start < prefix.length) return false;
  for (var k = 0; k < prefix.length; k++) {
    if (bytes[start + k] != prefix[k]) return false;
  }
  return true;
}

/// Reads tag 0x0112 from IFD0 of the TIFF structure at [tiff].
int? _readOrientation(Uint8List bytes, int tiff, int end) {
  if (tiff + 8 > end) return null;
  final bigEndian = bytes[tiff] == 0x4D && bytes[tiff + 1] == 0x4D;
  final littleEndian = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
  if (!bigEndian && !littleEndian) return null;

  int read16(int at) => bigEndian
      ? (bytes[at] << 8) | bytes[at + 1]
      : bytes[at] | (bytes[at + 1] << 8);
  int read32(int at) => bigEndian
      ? (bytes[at] << 24) |
          (bytes[at + 1] << 16) |
          (bytes[at + 2] << 8) |
          bytes[at + 3]
      : bytes[at] |
          (bytes[at + 1] << 8) |
          (bytes[at + 2] << 16) |
          (bytes[at + 3] << 24);

  final ifd = tiff + read32(tiff + 4);
  if (ifd + 2 > end) return null;
  final count = read16(ifd);
  for (var n = 0; n < count; n++) {
    final entry = ifd + 2 + n * 12;
    if (entry + 12 > end) return null;
    if (read16(entry) != 0x0112) continue;
    final value = read16(entry + 8);
    return value >= 1 && value <= 8 ? value : null;
  }
  return null;
}

/// An APP1 segment holding only the orientation tag.
Uint8List _orientationOnlyExif(int orientation) {
  return Uint8List.fromList([
    0xFF, 0xE1, 0x00, 0x22, // APP1, length 34
    ..._exifHeader,
    0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // big-endian TIFF, IFD0 at 8
    0x00, 0x01, // one entry
    0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // orientation, SHORT, 1
    0x00, orientation, 0x00, 0x00, // value
    0x00, 0x00, 0x00, 0x00, // no next IFD
  ]);
}
