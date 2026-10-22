import AVFoundation
import CwlCatchException
import Foundation

/// Builds `SpeechRecognitionError.detail`: why an error happened, in a form a
/// crash or analytics report can carry. Flutter-free, like
/// `SpeechAudioCapture`.
///
/// What goes in: the step that failed, the native error's domain and code (or
/// an Objective-C exception's name), the system's own description of it and,
/// for a listen that failed to start, the input formats and route involved.
/// What never goes in: anything the user said, a file path, or a device or
/// port NAME — a Bluetooth port is named after its owner ("Mikoto's
/// AirPods"), so only port types are used. Object addresses are dropped, so
/// one failure reads the same on every device.
enum SpeechErrorDetail {
  /// The longest detail sent. Analytics keeps only the first 100 characters
  /// of a value, so the step and the error come first and the context last.
  static let maxLength = 200

  /// Room for the error itself, so a long exception reason cannot push the
  /// context out of `maxLength`.
  static let maxErrorLength = 120

  /// "<step>: <error>; <context>", at most `maxLength` characters. `step` and
  /// `context` are optional.
  static func make(step: String?, error: Error, context: String? = nil) -> String {
    var text = String(clean(describe(error)).prefix(maxErrorLength))
    if let step = step {
      text = "\(step): \(text)"
    }
    if let context = context, !context.isEmpty {
      text += "; \(context)"
    }
    return String(text.prefix(maxLength))
  }

  /// The domain, code and description of `error`.
  ///
  /// An Objective-C exception caught by `catchExceptionAsError` arrives as an
  /// `ExceptionError`, whose own domain and description name nothing but the
  /// wrapper type; its name and reason are what AVFAudio wrote
  /// ("com.apple.coreaudio.avfaudio: required condition is false: ...").
  static func describe(_ error: Error) -> String {
    if let caught = error as? ExceptionError {
      return "\(caught.exception.name.rawValue): \(caught.exception.reason ?? "no reason")"
    }
    if let pluginError = error as? SpeechToTextError,
      case .runtimeError(let message) = pluginError
    {
      return message
    }
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
  }

  /// "48000/1ch" (sample rate / channel count), or "none".
  static func describe(_ format: AVAudioFormat?) -> String {
    guard let format = format else {
      return "none"
    }
    return "\(Int(format.sampleRate))/\(format.channelCount)ch"
  }

  /// One line, without object addresses.
  private static func clean(_ text: String) -> String {
    return text
      .replacingOccurrences(of: "0x[0-9A-Fa-f]+", with: "0x", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }
}
