import 'dart:io';

import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [PathUtils.isUsableImageFile], the guard that keeps a broken
/// `cover.jpg` from reaching `Image.file`.
///
/// The SD-card work left covers in three states, and only the first is caught
/// by a bare `existsSync()`:
///
///   * missing            — the write never started
///   * zero-length        — the file was created, then the download died
///   * non-empty garbage  — the write was interrupted partway
///
/// The third cannot be detected from metadata, so callers must also pass an
/// `errorBuilder`; these tests pin the two states that are decidable from the
/// filesystem so a future refactor cannot quietly drop back to `existsSync()`.
///
/// Read-only with respect to `lib/`: everything happens in a temp dir.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cover_validity_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  File write(String name, List<int> bytes) =>
      File('${tempDir.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(bytes);

  group('isUsableImageFile', () {
    test('rejects a missing file', () {
      final missing = File(
        '${tempDir.path}${Platform.pathSeparator}cover.jpg',
      );
      expect(missing.existsSync(), isFalse, reason: 'precondition');
      expect(PathUtils.isUsableImageFile(missing), isFalse);
    });

    test('rejects a zero-length file that existsSync alone would accept', () {
      final empty = write('cover.jpg', const []);
      // This is the case that motivated the helper: existsSync() is true, so
      // the old code handed a 0-byte file to Image.file and rendered the red
      // cross.
      expect(empty.existsSync(), isTrue, reason: 'precondition');
      expect(empty.lengthSync(), 0);
      expect(PathUtils.isUsableImageFile(empty), isFalse);
    });

    test('accepts a file with content', () {
      final cover = write('cover.jpg', const [0xFF, 0xD8, 0xFF, 0xE0]);
      expect(PathUtils.isUsableImageFile(cover), isTrue);
    });

    test('treats a directory path as unusable rather than throwing', () {
      // lengthSync() on a directory throws; the guard must absorb it so a
      // malformed entryDirPath cannot crash the download list.
      expect(PathUtils.isUsableImageFile(tempDir), isFalse);
    });

    test('a non-empty file is still not proof of a decodable image', () {
      // Documents the limit of this check: content validity is decided by the
      // decoder, which is why callers pair this with an errorBuilder.
      final garbage = write('cover.jpg', List<int>.filled(64, 0x41));
      expect(garbage.lengthSync(), greaterThan(0));
      expect(PathUtils.isUsableImageFile(garbage), isTrue);
    });
  });
}