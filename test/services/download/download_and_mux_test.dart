import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('FileSource Adaptive Dual-Track & MP4 Resolution Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('piliplus_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Case 1: When only video.m4s and audio.m4s exist, FileSource must fallback to DASH and NOT claim 0.mp4', () {
      final tagDir = Directory(p.join(tempDir.path, '80'));
      tagDir.createSync(recursive: true);

      final videoM4s = File(p.join(tagDir.path, PathUtils.videoNameType2));
      final audioM4s = File(p.join(tagDir.path, PathUtils.audioNameType2));
      videoM4s.writeAsStringSync('dummy video m4s');
      audioM4s.writeAsStringSync('dummy audio m4s');

      // Even if caller passes isMp4: true (e.g. from misconfigured entry.json or failed mux attempt)
      final source = FileSource(
        dir: tempDir.path,
        isMp4: true,
        hasDashAudio: true,
        typeTag: '80',
      );

      // Must NOT be MP4 because 0.mp4 doesn't exist on disk
      expect(source.isMp4, isFalse, reason: 'Must not claim isMp4 when 0.mp4 does not exist on disk');
      expect(source.videoSource, equals(videoM4s.path), reason: 'Video source must point to existing video.m4s');
      expect(source.audioSource, equals(audioM4s.path), reason: 'Audio source must point to existing audio.m4s to prevent missing audio');
    });

    test('Case 2: When 0.mp4 exists in tag folder, FileSource correctly identifies single MP4', () {
      final tagDir = Directory(p.join(tempDir.path, '80'));
      tagDir.createSync(recursive: true);

      final mp4File = File(p.join(tagDir.path, PathUtils.videoNameType1));
      mp4File.writeAsStringSync('dummy mp4');

      final source = FileSource(
        dir: tempDir.path,
        isMp4: false, // caller passed false, but 0.mp4 exists on disk
        hasDashAudio: false,
        typeTag: '80',
      );

      expect(source.isMp4, isTrue, reason: 'Must detect 0.mp4 in typeTag dir');
      expect(source.videoSource, equals(mp4File.path));
      expect(source.audioSource, isNull);
    });

    test('Case 3: When 0.mp4 exists in root folder, FileSource correctly identifies single MP4', () {
      final mp4File = File(p.join(tempDir.path, PathUtils.videoNameType1));
      mp4File.writeAsStringSync('dummy root mp4');

      final source = FileSource(
        dir: tempDir.path,
        isMp4: false,
        hasDashAudio: false,
        typeTag: '80',
      );

      expect(source.isMp4, isTrue, reason: 'Must detect 0.mp4 in root dir');
      expect(source.videoSource, equals(mp4File.path));
      expect(source.audioSource, isNull);
    });
  });
}
