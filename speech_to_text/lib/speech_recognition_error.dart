import 'package:json_annotation/json_annotation.dart';

part 'speech_recognition_error.g.dart';

/// A single error returned from the underlying speech services.
///
/// Errors are either transient or permanent. Permanent errors
/// block speech recognition from continuing and must be
/// addressed before recognition will work. Transient errors
/// cause individual recognition sessions to fail but subsequent
/// attempts may well succeed.
@JsonSerializable()
class SpeechRecognitionError {
  /// Use this to differentiate the various error conditions.
  ///
  /// Not meant for display to the user.
  final String errorMsg;

  /// True means that recognition cannot continue until
  /// the error is resolved.
  final bool permanent;

  /// Why the error happened, when the platform knows — for diagnostics, not
  /// for display.
  ///
  /// On iOS and macOS: for `error_listen_failed`, the setup step that failed
  /// and the native error's domain and code (or exception name) with the
  /// system's description of it, plus the input formats and the route's port
  /// type; for a recognizer error, its domain, code and description. At most
  /// 200 characters, never the user's speech or a device name. Null when the
  /// platform sent none — always on Android and the web — and left out of
  /// [toJson] then, so a payload without it reads and writes as before.
  @JsonKey(includeIfNull: false)
  final String? detail;

  SpeechRecognitionError(this.errorMsg, this.permanent, {this.detail});

  factory SpeechRecognitionError.fromJson(Map<String, dynamic> json) =>
      _$SpeechRecognitionErrorFromJson(json);
  Map<String, dynamic> toJson() => _$SpeechRecognitionErrorToJson(this);

  @override
  String toString() {
    final why = detail == null ? '' : ', detail: $detail';
    return 'SpeechRecognitionError msg: $errorMsg, permanent: $permanent$why';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SpeechRecognitionError &&
            errorMsg == other.errorMsg &&
            permanent == other.permanent &&
            detail == other.detail;
  }

  @override
  int get hashCode => errorMsg.hashCode;
}
