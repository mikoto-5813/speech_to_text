import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';

import 'test_speech_to_text_platform.dart';

String captureJson(String path,
    {bool success = true,
    int durationMs = 1500,
    String endReason = 'stop',
    String? errorMsg}) {
  return jsonEncode({
    'path': path,
    'success': success,
    'durationMs': durationMs,
    'sampleRate': 16000,
    'channels': 1,
    'bitsPerSample': 16,
    'endReason': endReason,
    if (null != errorMsg) 'errorMsg': errorMsg,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpeechAudioCapture.fromJson', () {
    test('reads a successful capture', () {
      final capture = SpeechAudioCapture.fromJson(
          jsonDecode(captureJson('/tmp/a.wav', durationMs: 2345)));
      expect(capture.path, '/tmp/a.wav');
      expect(capture.success, isTrue);
      expect(capture.durationMs, 2345);
      expect(capture.duration, const Duration(milliseconds: 2345));
      expect(capture.sampleRate, 16000);
      expect(capture.channels, 1);
      expect(capture.bitsPerSample, 16);
      expect(capture.endReason, 'stop');
      expect(capture.errorMsg, isNull);
    });
    test('reads a failed capture', () {
      final capture = SpeechAudioCapture.fromJson(jsonDecode(captureJson(
          '/tmp/a.wav',
          success: false,
          durationMs: 0,
          endReason: 'listenFailed',
          errorMsg: 'capture_file_create_failed: No such file or directory')));
      expect(capture.success, isFalse);
      expect(capture.errorMsg, startsWith('capture_file_create_failed'));
      expect(capture.endReason, 'listenFailed');
    });
    test('tolerates missing fields', () {
      final capture = SpeechAudioCapture.fromJson({'path': '/tmp/a.wav'});
      expect(capture.success, isFalse);
      expect(capture.durationMs, 0);
      expect(capture.endReason, '');
    });
    test('round-trips through toJson', () {
      final json = jsonDecode(captureJson('/tmp/a.wav', errorMsg: 'x'));
      expect(SpeechAudioCapture.fromJson(json).toJson(), json);
    });
  });

  group('listen with audio capture', () {
    late TestSpeechToTextPlatform platform;
    late SpeechToText speech;
    late List<SpeechAudioCapture> captured;

    void record(SpeechAudioCapture capture) => captured.add(capture);

    setUp(() async {
      platform = TestSpeechToTextPlatform();
      SpeechToTextPlatform.instance = platform;
      speech = SpeechToText.withMethodChannel();
      captured = [];
      await speech.initialize();
    });

    test('forwards audioCapturePath to the platform', () async {
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/a.wav'),
          onAudioCaptured: record);
      expect(platform.listenOptions?.audioCapturePath, '/tmp/a.wav');
    });
    test('a listen without options still sends no capture path', () async {
      await speech.listen();
      expect(platform.listenOptions?.audioCapturePath, isNull);
    });
    test('delivers the capture of that path, once', () async {
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/a.wav'),
          onAudioCaptured: record);
      platform.notifyAudioCaptured(captureJson('/tmp/a.wav'));
      platform.notifyAudioCaptured(captureJson('/tmp/a.wav'));
      expect(captured, hasLength(1));
      expect(captured.single.path, '/tmp/a.wav');
      expect(captured.single.success, isTrue);
    });
    test('ignores a capture of another path', () async {
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/a.wav'),
          onAudioCaptured: record);
      platform.notifyAudioCaptured(captureJson('/tmp/other.wav'));
      expect(captured, isEmpty);
    });
    test('each session reaches its own listener', () async {
      final first = <SpeechAudioCapture>[];
      final second = <SpeechAudioCapture>[];
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/1.wav'),
          onAudioCaptured: first.add);
      platform.notifyAudioCaptured(captureJson('/tmp/1.wav'));
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/2.wav'),
          onAudioCaptured: second.add);
      platform.notifyAudioCaptured(captureJson('/tmp/2.wav'));
      expect(first.map((c) => c.path), ['/tmp/1.wav']);
      expect(second.map((c) => c.path), ['/tmp/2.wav']);
    });
    test('delivers a capture reported before a failed listen returns',
        () async {
      platform.listenResult = false;
      platform.duringListen = () => platform.notifyAudioCaptured(captureJson(
          '/tmp/a.wav',
          durationMs: 0,
          endReason: 'listenFailed'));
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/a.wav'),
          onAudioCaptured: record);
      expect(captured.single.endReason, 'listenFailed');
    });
    test('drops the listener of a listen that did not start', () async {
      platform.listenResult = false;
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/a.wav'),
          onAudioCaptured: record);
      platform.notifyAudioCaptured(captureJson('/tmp/a.wav'));
      expect(captured, isEmpty);
    });
    test('drops the listener of a listen that threw', () async {
      platform.listenException = true;
      await expectLater(
          speech.listen(
              listenOptions:
                  SpeechListenOptions(audioCapturePath: '/tmp/a.wav'),
              onAudioCaptured: record),
          throwsA(isA<ListenFailedException>()));
      platform.notifyAudioCaptured(captureJson('/tmp/a.wav'));
      expect(captured, isEmpty);
    });
    test('forgets an unreported capture once the next listen starts',
        () async {
      // A platform that never records (Android) never reports; nothing may
      // accumulate, and a stray late report must not reach the old listener.
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/1.wav'),
          onAudioCaptured: record);
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/2.wav'),
          onAudioCaptured: record);
      platform.notifyAudioCaptured(captureJson('/tmp/1.wav'));
      expect(captured, isEmpty);
      platform.notifyAudioCaptured(captureJson('/tmp/2.wav'));
      expect(captured.single.path, '/tmp/2.wav');
    });
    test('a path without a listener records but notifies nobody', () async {
      await speech.listen(
          listenOptions: SpeechListenOptions(audioCapturePath: '/tmp/a.wav'));
      expect(platform.listenOptions?.audioCapturePath, '/tmp/a.wav');
      platform.notifyAudioCaptured(captureJson('/tmp/a.wav'));
    });
    test('a listener without a path is never called', () async {
      await speech.listen(onAudioCaptured: record);
      platform.notifyAudioCaptured(captureJson(''));
      expect(captured, isEmpty);
    });
  });
}
