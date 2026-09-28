import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';

void main() {
  group('copyWith', () {
    test('modifies expected properties', () async {
      final options = SpeechListenOptions(
        onDevice: true,
        partialResults: true,
        listenMode: ListenMode.search,
        sampleRate: 16000,
        cancelOnError: true,
        autoPunctuation: true,
        enableHapticFeedback: true,
      );
      final modifiedOptions = options.copyWith(
        onDevice: false,
        partialResults: false,
        listenMode: ListenMode.confirmation,
        sampleRate: 8000,
        cancelOnError: false,
        autoPunctuation: false,
        enableHapticFeedback: false,
      );
      expect(modifiedOptions.onDevice, false);
      expect(modifiedOptions.partialResults, false);
      expect(modifiedOptions.listenMode, ListenMode.confirmation);
      expect(modifiedOptions.sampleRate, 8000);
      expect(modifiedOptions.cancelOnError, false);
      expect(modifiedOptions.autoPunctuation, false);
      expect(modifiedOptions.enableHapticFeedback, false);
    });
    test('keeps contextualStrings and audioCapturePath when not given', () {
      final options = SpeechListenOptions(
        contextualStrings: ['eye'],
        audioCapturePath: '/tmp/a.wav',
      );
      final modifiedOptions = options.copyWith(onDevice: true);
      expect(modifiedOptions.onDevice, true);
      expect(modifiedOptions.contextualStrings, ['eye']);
      expect(modifiedOptions.audioCapturePath, '/tmp/a.wav');
    });
    test('sets audioCapturePath', () {
      final modifiedOptions =
          SpeechListenOptions().copyWith(audioCapturePath: '/tmp/b.wav');
      expect(modifiedOptions.audioCapturePath, '/tmp/b.wav');
    });
  });
  group('defaults', () {
    test('are unchanged, and record no audio', () {
      final options = SpeechListenOptions();
      expect(options.cancelOnError, false);
      expect(options.partialResults, true);
      expect(options.onDevice, false);
      expect(options.listenMode, ListenMode.confirmation);
      expect(options.sampleRate, 0);
      expect(options.autoPunctuation, false);
      expect(options.enableHapticFeedback, false);
      expect(options.contextualStrings, isEmpty);
      expect(options.audioCapturePath, isNull);
    });
  });
}
