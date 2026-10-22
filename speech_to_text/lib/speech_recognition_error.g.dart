// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'speech_recognition_error.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SpeechRecognitionError _$SpeechRecognitionErrorFromJson(
        Map<String, dynamic> json) =>
    SpeechRecognitionError(
      json['errorMsg'] as String,
      json['permanent'] as bool,
      detail: json['detail'] as String?,
    );

Map<String, dynamic> _$SpeechRecognitionErrorToJson(
    SpeechRecognitionError instance) {
  final val = <String, dynamic>{
    'errorMsg': instance.errorMsg,
    'permanent': instance.permanent,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('detail', instance.detail);
  return val;
}
