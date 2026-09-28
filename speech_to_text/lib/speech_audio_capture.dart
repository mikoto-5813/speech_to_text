/// The outcome of recording one listen session's microphone audio.
///
/// Delivered to the `onAudioCaptured` listener of [SpeechToText.listen] once
/// for every listen that set [SpeechListenOptions.audioCapturePath], after
/// the file at [path] has been closed. Only iOS and macOS record audio; on
/// other platforms the listener is never called.
///
/// The file is a WAV: linear PCM, 16-bit signed little-endian integers,
/// [sampleRate] Hz (16000), [channels] channel (mono). It holds exactly the
/// audio the speech recognizer heard.
class SpeechAudioCapture {
  /// The `audioCapturePath` the listen session was started with.
  final String path;

  /// False when recording failed at any point. The file may then be
  /// missing (it could not be created), or a valid WAV that holds only the
  /// part of the session recorded before the failure. See [errorMsg].
  final bool success;

  /// Length of the audio in the file, in milliseconds. Can be 0, for
  /// example when listening failed to start.
  final int durationMs;

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// What closed the file, for diagnostics only: `stop`, `cancel`,
  /// `recognizerFinishedReadingAudio`, `recognizerCancelled`,
  /// `recognizerFinished`, `listenFailed`, `listenEnded`, `superseded`,
  /// `interrupted` or `engineConfigurationChange`. New values may appear.
  final String endReason;

  /// Why recording failed, when [success] is false; null otherwise.
  final String? errorMsg;

  const SpeechAudioCapture({
    required this.path,
    required this.success,
    required this.durationMs,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.endReason,
    this.errorMsg,
  });

  Duration get duration => Duration(milliseconds: durationMs);

  factory SpeechAudioCapture.fromJson(Map<String, dynamic> json) {
    int readInt(String key) => (json[key] as num?)?.toInt() ?? 0;
    return SpeechAudioCapture(
      path: json['path'] as String? ?? '',
      success: json['success'] == true,
      durationMs: readInt('durationMs'),
      sampleRate: readInt('sampleRate'),
      channels: readInt('channels'),
      bitsPerSample: readInt('bitsPerSample'),
      endReason: json['endReason'] as String? ?? '',
      errorMsg: json['errorMsg'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'success': success,
        'durationMs': durationMs,
        'sampleRate': sampleRate,
        'channels': channels,
        'bitsPerSample': bitsPerSample,
        'endReason': endReason,
        if (null != errorMsg) 'errorMsg': errorMsg,
      };

  @override
  String toString() => 'SpeechAudioCapture(path: $path, success: $success, '
      'durationMs: $durationMs, endReason: $endReason'
      '${null != errorMsg ? ', errorMsg: $errorMsg' : ''})';
}
