## Unreleased — BigBean fork (`feature/audio-capture`)
- Added `audioCapturePath: String?` to `SpeechListenOptions` (constructor
  and `copyWith`; default `null`). Sent as `audioCapturePath` in the listen
  payload only when set, so a listen without it sends exactly what it
  did before.
- Added `SpeechToTextPlatform.onAudioCaptured`, fed by the new
  `audioCaptured` method-channel callback (a JSON string describing the
  closed capture file). Only the iOS / macOS plugin sends it.

## Unreleased — BigBean fork (`feature/contextual-strings`)
- Added `contextualStrings: List<String>` to `SpeechListenOptions`,
  forwarded as `contextualStrings` on the method channel for the
  platform plugin to consume (currently only honored by the
  iOS / macOS Swift plugin via `SFSpeechRecognitionRequest.contextualStrings`).

## 2.3.0
- Added copyWith to SpeechListenOptions

## 2.2.0
- Added options for listen method in place of separate parameters

## 2.1.0
- Updated for Flutter 3.0

## 2.0.1
- fix test method deprecation

## 2.0.0
- null safety / flutter 2.0 compatability is now the main release

## 2.0.0-nullsafety
- prerelease for null safety / flutter 2.0 compatability

## 1.4.2
- bug fix for null options

## 1.4.1
- uses platform options in method channel call

## 1.4.0
- platform specific configuration properties added to initialize

## 1.3.0
- listen changed to bool

## 1.2.0
- Added callback methods

## 1.1.0
- Changed argument types before release
- removed `launch` 

## 1.0.0
- Initial open-source release.