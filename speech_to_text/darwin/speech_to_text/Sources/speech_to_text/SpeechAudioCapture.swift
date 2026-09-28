import AVFoundation
import Foundation
import os.log

/// What closed a capture. Sent to Dart as `endReason`; diagnostic only.
enum SpeechAudioCaptureEndReason: String {
  /// Dart called `stop`.
  case stop
  /// Dart called `cancel`.
  case cancel
  /// The recognizer stopped reading audio: a final result, an error or its
  /// own time limit.
  case recognizerFinishedReadingAudio
  /// The recognition task reported that it was cancelled.
  case recognizerCancelled
  /// The recognition task finished, successfully or not.
  case recognizerFinished
  /// Listening failed to start after the capture file was opened.
  case listenFailed
  /// The session was torn down with no earlier end signal.
  case listenEnded
  /// A new listen started while this capture was still open.
  case superseded
  /// An audio session interruption began (iOS).
  case interrupted
  /// The audio engine stopped itself after an I/O configuration change.
  case engineConfigurationChange
  /// The plugin was detached from its Flutter engine.
  case detached
}

/// The outcome of one capture, sent to Dart as the JSON argument of
/// `audioCaptured`.
struct SpeechAudioCaptureOutcome: Codable {
  let path: String
  let success: Bool
  let durationMs: Int
  let sampleRate: Int
  let channels: Int
  let bitsPerSample: Int
  let endReason: String
  let errorMsg: String?
}

struct SpeechAudioCaptureError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Records the audio one listen session feeds the speech recognizer into a
/// WAV file: linear PCM, 16-bit signed little-endian, 16 kHz, mono.
///
/// Threading contract:
/// * `init` runs on the thread that starts the listen, before the input tap
///   that will call `append` is installed. It creates (or truncates) the
///   file; the converter is built on the capture queue from the first
///   buffer, so it always matches the format the tap really delivers.
/// * `append` runs on the input-node tap thread. It copies the buffer and
///   hands it to a private serial queue; conversion and file I/O never run on
///   the tap thread, and the tap never waits for them.
/// * `finish` may run on any thread except that private queue. It waits for
///   every buffer already handed over, flushes the converter, patches the
///   header and closes the file before it returns, so once it has returned
///   the file is a complete WAV and nothing will touch it again.
///
/// Nothing here can throw into, or stall, the recognizer: every failure is
/// recorded, logged once, and switches capture off for the rest of the
/// session. What was written until then stays a valid (shorter) WAV.
final class SpeechAudioCapture {
  static let sampleRate: Double = 16_000
  static let channelCount: AVAudioChannelCount = 1
  static let bitsPerSample = 16

  /// Tap buffers handed to the queue but not yet written. A tap buffer holds
  /// roughly 20-100 ms, so reaching this means file I/O has stalled for
  /// several seconds; capture then stops instead of growing memory without
  /// bound.
  static let maxPendingBuffers = 256

  /// Extra output frames beyond the exact sample-rate ratio, so one pass of
  /// the converter always has room for everything a buffer produces.
  private static let outputFrameMargin: AVAudioFrameCount = 64
  private static let drainFrameCapacity: AVAudioFrameCount = 1024
  private static let maxConvertPasses = 16

  let path: String
  private let log: OSLog
  private let queue = DispatchQueue(
    label: "com.csdcorp.speechToText.audioCapture", autoreleaseFrequency: .workItem)
  private let outputFormat: AVAudioFormat?

  // Guarded by `lock`: read on the tap thread.
  private let lock = NSLock()
  private var accepting = true
  private var pendingBuffers = 0
  private var finished = false

  // Confined to `queue` once `init` has returned.
  private var writer: WavFileWriter?
  private var converter: AVAudioConverter?
  private var errorMsg: String?
  private var framesWritten: Int64 = 0

  /// Creates (or truncates) the file at `path`, holding a header that
  /// describes an empty data chunk until `finish` completes it.
  init(path: String, log: OSLog) {
    self.path = path
    self.log = log
    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: SpeechAudioCapture.sampleRate,
      channels: SpeechAudioCapture.channelCount, interleaved: true)
    do {
      writer = try WavFileWriter(
        path: path, sampleRate: UInt32(SpeechAudioCapture.sampleRate),
        channels: UInt16(SpeechAudioCapture.channelCount),
        bitsPerSample: UInt16(SpeechAudioCapture.bitsPerSample))
    } catch {
      fail(error)
    }
  }

  /// Hands one tap buffer over for conversion and writing. Called on the tap
  /// thread; never blocks on I/O.
  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0 else {
      return
    }
    lock.lock()
    guard accepting else {
      lock.unlock()
      return
    }
    guard pendingBuffers < SpeechAudioCapture.maxPendingBuffers else {
      accepting = false
      lock.unlock()
      queue.async {
        self.fail(
          SpeechAudioCaptureError(
            "capture_backlog: more than \(SpeechAudioCapture.maxPendingBuffers) buffers waiting"))
      }
      return
    }
    pendingBuffers += 1
    lock.unlock()

    // The engine may reuse the tap's buffer once the tap block returns.
    let copy = SpeechAudioCapture.copy(buffer)
    queue.async {
      self.lock.lock()
      self.pendingBuffers -= 1
      self.lock.unlock()
      guard let copy = copy else {
        self.fail(SpeechAudioCaptureError("capture_buffer_copy_failed"))
        return
      }
      self.process(copy)
    }
  }

  /// Finalises the file and returns the outcome, or nil when this capture
  /// was already finished. Blocks until every pending buffer is written and
  /// the file is closed. Must not be called on the capture queue.
  func finish(reason: SpeechAudioCaptureEndReason) -> SpeechAudioCaptureOutcome? {
    lock.lock()
    if finished {
      lock.unlock()
      return nil
    }
    finished = true
    accepting = false
    lock.unlock()
    return queue.sync {
      finalize(reason)
    }
  }

  // MARK: - Capture queue

  private func process(_ buffer: AVAudioPCMBuffer) {
    guard errorMsg == nil, writer != nil else {
      return
    }
    do {
      let converter = try converterFor(buffer.format)
      try convert(buffer, with: converter)
    } catch {
      fail(error)
    }
  }

  private func finalize(_ reason: SpeechAudioCaptureEndReason) -> SpeechAudioCaptureOutcome {
    if errorMsg == nil, let converter = converter {
      // The sample-rate converter holds back a few frames of history; ending
      // the stream releases them so the file ends where the speech did.
      do {
        try drain(converter)
      } catch {
        fail(error)
      }
    }
    converter = nil
    if let writer = writer {
      do {
        try writer.close()
      } catch {
        fail(error)
      }
    }
    writer = nil
    return SpeechAudioCaptureOutcome(
      path: path,
      success: errorMsg == nil,
      durationMs: Int(framesWritten * 1000 / Int64(SpeechAudioCapture.sampleRate)),
      sampleRate: Int(SpeechAudioCapture.sampleRate),
      channels: Int(SpeechAudioCapture.channelCount),
      bitsPerSample: SpeechAudioCapture.bitsPerSample,
      endReason: reason.rawValue,
      errorMsg: errorMsg)
  }

  private func converterFor(_ format: AVAudioFormat) throws -> AVAudioConverter {
    if let current = converter, current.inputFormat == format {
      return current
    }
    if let previous = converter {
      // The tap's format changed mid-session (not expected: the engine stops
      // on a hardware change). Keep the old stream's tail and carry on with a
      // converter for the new format.
      converter = nil
      try drain(previous)
    }
    let fresh = try makeConverter(from: format)
    converter = fresh
    return fresh
  }

  private func makeConverter(from format: AVAudioFormat) throws -> AVAudioConverter {
    guard let outputFormat = outputFormat,
      let made = AVAudioConverter(from: format, to: outputFormat)
    else {
      throw SpeechAudioCaptureError("capture_converter_create_failed: \(format)")
    }
    if format.channelCount != outputFormat.channelCount {
      // Mix every input channel into the mono output rather than keeping
      // only the first.
      made.downmix = true
    }
    return made
  }

  private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter) throws {
    guard let outputFormat = outputFormat else {
      throw SpeechAudioCaptureError("capture_format_unavailable")
    }
    let ratio = outputFormat.sampleRate / input.format.sampleRate
    let capacity =
      AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up))
      + SpeechAudioCapture.outputFrameMargin
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      throw SpeechAudioCaptureError("capture_buffer_alloc_failed")
    }
    // Offer the buffer once, then report "no data for now" rather than end
    // of stream, so the converter keeps its state for the next buffer.
    var supplied = false
    try pull(from: converter, into: output) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return input
    }
  }

  private func drain(_ converter: AVAudioConverter) throws {
    guard let outputFormat = outputFormat,
      let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat, frameCapacity: SpeechAudioCapture.drainFrameCapacity)
    else {
      throw SpeechAudioCaptureError("capture_buffer_alloc_failed")
    }
    try pull(from: converter, into: output) { _, inputStatus in
      inputStatus.pointee = .endOfStream
      return nil
    }
  }

  /// Runs the converter until it needs more input or has ended, writing
  /// every chunk it produces.
  private func pull(
    from converter: AVAudioConverter, into output: AVAudioPCMBuffer,
    input: @escaping AVAudioConverterInputBlock
  ) throws {
    for _ in 0..<SpeechAudioCapture.maxConvertPasses {
      output.frameLength = 0
      var error: NSError?
      let status = converter.convert(to: output, error: &error, withInputFrom: input)
      if status == .error {
        throw SpeechAudioCaptureError(
          "capture_convert_failed: \(error?.localizedDescription ?? "unknown")")
      }
      try write(output)
      // .haveData means the output buffer filled up and more may be waiting.
      if status != .haveData {
        return
      }
    }
  }

  private func write(_ buffer: AVAudioPCMBuffer) throws {
    guard buffer.frameLength > 0, let writer = writer else {
      return
    }
    guard let samples = buffer.int16ChannelData?[0] else {
      throw SpeechAudioCaptureError("capture_buffer_layout_unexpected")
    }
    let byteCount =
      Int(buffer.frameLength) * Int(buffer.format.channelCount) * MemoryLayout<Int16>.size
    try writer.append(UnsafeRawPointer(samples), byteCount: byteCount)
    framesWritten += Int64(buffer.frameLength)
  }

  /// Records the first failure and stops accepting audio. Runs in `init` or
  /// on the capture queue.
  private func fail(_ error: Error) {
    lock.lock()
    accepting = false
    lock.unlock()
    guard errorMsg == nil else {
      return
    }
    let message = String(describing: error)
    errorMsg = message
    os_log(
      "Audio capture disabled for this listen: %{PUBLIC}@", log: log, type: .error, message)
  }

  private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
    else {
      return nil
    }
    copy.frameLength = source.frameLength
    let from = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: source.audioBufferList))
    let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard from.count == to.count else {
      return nil
    }
    for index in 0..<from.count {
      guard let sourceData = from[index].mData, let copyData = to[index].mData else {
        return nil
      }
      memcpy(copyData, sourceData, Int(min(from[index].mDataByteSize, to[index].mDataByteSize)))
    }
    return copy
  }
}

/// A streaming WAV writer: a canonical 44-byte PCM header followed by the
/// raw samples. The header's size fields are written as zero when the file
/// is opened and made true by `close()`, which is what turns the file into a
/// valid WAV; until then a reader sees an empty data chunk at best.
///
/// Plain POSIX I/O so every step is explicit and deterministic: nothing is
/// finalised by an object being deallocated at an unknown time, and a
/// failure is an error value, never an Objective-C exception.
final class WavFileWriter {
  static let headerSize = 44

  private var fd: Int32
  private(set) var dataByteCount: UInt32 = 0
  private let sampleRate: UInt32
  private let channels: UInt16
  private let bitsPerSample: UInt16

  /// Creates the file, or truncates an existing one, and writes a header
  /// that describes an empty data chunk.
  init(path: String, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) throws {
    self.sampleRate = sampleRate
    self.channels = channels
    self.bitsPerSample = bitsPerSample
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode_t(0o644))
    guard fd >= 0 else {
      throw SpeechAudioCaptureError("capture_file_create_failed: \(WavFileWriter.errnoText())")
    }
    do {
      try writeHeader(to: fd)
    } catch {
      Darwin.close(fd)
      fd = -1
      throw error
    }
  }

  deinit {
    if fd >= 0 {
      try? close()
    }
  }

  func append(_ bytes: UnsafeRawPointer, byteCount: Int) throws {
    guard byteCount > 0 else {
      return
    }
    guard fd >= 0 else {
      throw SpeechAudioCaptureError("capture_file_closed")
    }
    // RIFF sizes are 32-bit. At 32 kB/s this is a day and a half of audio.
    guard
      UInt64(dataByteCount) + UInt64(byteCount)
        <= UInt64(UInt32.max) - UInt64(WavFileWriter.headerSize)
    else {
      throw SpeechAudioCaptureError("capture_file_too_large")
    }
    try WavFileWriter.writeFully(
      fd, bytes, byteCount, at: off_t(WavFileWriter.headerSize) + off_t(dataByteCount))
    dataByteCount += UInt32(byteCount)
  }

  /// Patches the header sizes and closes the file. Idempotent.
  func close() throws {
    guard fd >= 0 else {
      return
    }
    let handle = fd
    fd = -1
    var failure: SpeechAudioCaptureError?
    // A write that failed half way may have left bytes past the last chunk
    // that was counted; drop them so the data chunk is exactly the file's tail.
    if ftruncate(handle, off_t(WavFileWriter.headerSize) + off_t(dataByteCount)) != 0 {
      failure = SpeechAudioCaptureError(
        "capture_file_truncate_failed: \(WavFileWriter.errnoText())")
    }
    if failure == nil {
      do {
        try writeHeader(to: handle)
      } catch let error as SpeechAudioCaptureError {
        failure = error
      } catch {
        failure = SpeechAudioCaptureError("capture_file_write_failed: \(error)")
      }
    }
    if Darwin.close(handle) != 0, failure == nil {
      failure = SpeechAudioCaptureError("capture_file_close_failed: \(WavFileWriter.errnoText())")
    }
    if let failure = failure {
      throw failure
    }
  }

  private func writeHeader(to handle: Int32) throws {
    let header = makeHeader()
    try header.withUnsafeBytes { raw in
      try WavFileWriter.writeFully(handle, raw.baseAddress!, raw.count, at: 0)
    }
  }

  private func makeHeader() -> [UInt8] {
    let blockAlign = UInt16(Int(channels) * Int(bitsPerSample) / 8)
    let byteRate = sampleRate * UInt32(blockAlign)
    var header = [UInt8]()
    header.reserveCapacity(WavFileWriter.headerSize)
    func tag(_ text: String) {
      header.append(contentsOf: Array(text.utf8))
    }
    func uint32(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
    }
    func uint16(_ value: UInt16) {
      withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
    }
    tag("RIFF")
    uint32(UInt32(WavFileWriter.headerSize - 8) + dataByteCount)
    tag("WAVE")
    tag("fmt ")
    uint32(16)  // fmt chunk size for plain PCM
    uint16(1)  // WAVE_FORMAT_PCM
    uint16(channels)
    uint32(sampleRate)
    uint32(byteRate)
    uint16(blockAlign)
    uint16(bitsPerSample)
    tag("data")
    uint32(dataByteCount)
    return header
  }

  private static func writeFully(
    _ handle: Int32, _ bytes: UnsafeRawPointer, _ count: Int, at offset: off_t
  ) throws {
    var written = 0
    while written < count {
      let result = pwrite(
        handle, bytes.advanced(by: written), count - written, offset + off_t(written))
      if result < 0 {
        if errno == EINTR {
          continue
        }
        throw SpeechAudioCaptureError("capture_file_write_failed: \(errnoText())")
      }
      if result == 0 {
        throw SpeechAudioCaptureError("capture_file_write_failed: no progress")
      }
      written += result
    }
  }

  private static func errnoText() -> String {
    return String(cString: strerror(errno))
  }
}
