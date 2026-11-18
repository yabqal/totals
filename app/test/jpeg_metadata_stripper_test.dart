import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:totals/utils/jpeg_metadata_stripper.dart';

const _soi = [0xFF, 0xD8];
const _eoi = [0xFF, 0xD9];
const _jfif = [
  0xFF, 0xE0, 0x00, 0x10, //
  0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01,
  0x00, 0x00,
];
const _dqt = [0xFF, 0xDB, 0x00, 0x04, 0xAA, 0xBB];
const _scan = [0xFF, 0xDA, 0x00, 0x04, 0xCC, 0xDD, 0x11, 0x22, 0x33];

/// Little-endian EXIF with orientation 6, a GPS IFD pointer and a marker
/// string standing in for location data.
List<int> _exifSegment() {
  final payload = <int>[
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // Exif\0\0
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // II, IFD0 at 8
    0x02, 0x00, // two entries
    0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
    0x25, 0x88, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, // no next IFD
    ...ascii.encode('SECRETGPS'),
  ];
  final length = payload.length + 2;
  return [0xFF, 0xE1, length >> 8, length & 0xFF, ...payload];
}

List<int> _comment(String text) {
  final body = ascii.encode(text);
  final length = body.length + 2;
  return [0xFF, 0xFE, length >> 8, length & 0xFF, ...body];
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

void main() {
  test('drops EXIF and comments but keeps orientation and image data', () {
    final input = Uint8List.fromList([
      ..._soi,
      ..._jfif,
      ..._exifSegment(),
      ..._comment('hello!'),
      ..._dqt,
      ..._scan,
      ..._eoi,
    ]);

    final output = stripJpegMetadata(input);

    expect(_contains(output, ascii.encode('SECRETGPS')), isFalse);
    expect(_contains(output, ascii.encode('hello!')), isFalse);
    expect(output.sublist(0, 2), _soi);
    expect(_contains(output, _jfif), isTrue);
    expect(_contains(output, [..._dqt, ..._scan, ..._eoi]), isTrue);
    expect(
      _contains(output, [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 6]),
      isTrue,
    );
    expect(output.length, lessThan(input.length));
  });

  test('leaves a JPEG without metadata unchanged', () {
    final input = Uint8List.fromList([
      ..._soi,
      ..._jfif,
      ..._dqt,
      ..._scan,
      ..._eoi,
    ]);

    expect(stripJpegMetadata(input), input);
  });

  test('returns non-JPEG bytes unchanged', () {
    final input = Uint8List.fromList(ascii.encode('not an image'));

    expect(identical(stripJpegMetadata(input), input), isTrue);
  });

  test('returns truncated JPEG bytes unchanged', () {
    final input = Uint8List.fromList([..._soi, 0xFF, 0xE1, 0x01, 0x00, 0x00]);

    expect(identical(stripJpegMetadata(input), input), isTrue);
  });
}
