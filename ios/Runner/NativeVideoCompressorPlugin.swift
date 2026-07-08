import Flutter
import AVFoundation

// Backs lib/core/media/video_compressor.dart's iOS side. AVAssetReader
// (decode) → AVAssetWriter (H.264 encode) — a framework-managed pipeline,
// deliberately not raw VTCompressionSession (would mean hand-rolling frame
// buffer/timestamp/NAL-unit management ourselves) and not
// AVAssetExportSession (Apple's named presets don't expose a custom
// bitrate, and were confirmed on-device to not reliably downscale portrait
// video — see git history for the v_video_compressor investigation this
// replaced).
//
// The resize itself doesn't need a manual composition/GL step: the writer's
// AVVideoScalingModeKey does it internally when the output settings'
// width/height differ from the decoded frame size (confirmed against
// T2Je/FYVideoCompressor, a proven reference for this exact technique).
// Orientation is handled the standard, simple way — copying the source
// track's preferredTransform onto the writer input — rather than manual
// rotation-matrix math.
//
// Only one compression runs at a time (single AVAssetWriter/Reader pair as
// instance state) — matches the native encoder's own real concurrency limit
// and keeps this plugin simple. A second concurrent `compress` call fails
// fast with BUSY so the Dart side's safe-fallback (send the original file)
// kicks in rather than corrupting/racing two exports.
class NativeVideoCompressorPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var isBusy = false
  private var isCancelled = false
  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "mugam/native_video_compressor",
      binaryMessenger: registrar.messenger()
    )
    let progressChannel = FlutterEventChannel(
      name: "mugam/native_video_compressor/progress",
      binaryMessenger: registrar.messenger()
    )
    let instance = NativeVideoCompressorPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    progressChannel.setStreamHandler(instance)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "compress":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let outputPath = args["outputPath"] as? String,
            let shortSide = args["shortSide"] as? Int,
            let bitrate = args["bitrate"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected path, outputPath, shortSide, bitrate", details: nil))
        return
      }
      if isBusy {
        result(FlutterError(code: "BUSY", message: "A compression is already in progress", details: nil))
        return
      }
      isBusy = true
      isCancelled = false
      compress(path: path, outputPath: outputPath, shortSide: shortSide, bitrate: bitrate) { [weak self] outcome in
        self?.isBusy = false
        outcome.fold(
          onSuccess: { result(nil) },
          onFailure: { code, message in result(FlutterError(code: code, message: message, details: nil)) }
        )
      }
    case "cancel":
      isCancelled = true
      reader?.cancelReading()
      writer?.cancelWriting()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func compress(
    path: String,
    outputPath: String,
    shortSide: Int,
    bitrate: Int,
    completion: @escaping (CompressResult) -> Void
  ) {
    let inputURL = URL(fileURLWithPath: path)
    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: outputURL)

    let asset = AVURLAsset(url: inputURL)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      completion(.failure(code: "READ_ERROR", message: "No video track"))
      return
    }
    let audioTrack = asset.tracks(withMediaType: .audio).first

    guard let assetReader = try? AVAssetReader(asset: asset) else {
      completion(.failure(code: "READ_ERROR", message: "Could not create AVAssetReader"))
      return
    }
    guard let assetWriter = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
      completion(.failure(code: "WRITE_ERROR", message: "Could not create AVAssetWriter"))
      return
    }
    self.reader = assetReader
    self.writer = assetWriter

    // naturalSize is the raw encoded buffer, before preferredTransform's
    // rotation is applied — a 90/270 transform means the visually-portrait
    // frame is actually stored as a landscape buffer under the hood. The
    // short-side target has to be computed against the DISPLAY size (after
    // rotation) so a portrait 1080x1920 video and a landscape 1920x1080
    // video with the same visual content compress to the same profile —
    // then that scale factor is applied back to the raw buffer dimensions,
    // since that's the space AVVideoWidthKey/HeightKey and the decoded
    // sample buffers actually live in.
    let naturalSize = videoTrack.naturalSize
    let transform = videoTrack.preferredTransform
    let displaySize = naturalSize.applying(transform)
    let displayWidth = abs(displaySize.width)
    let displayHeight = abs(displaySize.height)
    let displayShortSide = min(displayWidth, displayHeight)
    let scale = displayShortSide > CGFloat(shortSide) ? CGFloat(shortSide) / displayShortSide : 1.0
    let targetWidth = alignEven(naturalSize.width * scale)
    let targetHeight = alignEven(naturalSize.height * scale)

    let videoOutputSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
    videoOutput.alwaysCopiesSampleData = false
    guard assetReader.canAdd(videoOutput) else {
      completion(.failure(code: "READ_ERROR", message: "Cannot add video output"))
      return
    }
    assetReader.add(videoOutput)

    var audioOutput: AVAssetReaderTrackOutput?
    if let audioTrack = audioTrack {
      // nil settings == passthrough, no audio re-encode. Audio is a small
      // fraction of a chat video's total size — not worth the extra
      // complexity/risk of a second encoder for marginal savings.
      let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
      output.alwaysCopiesSampleData = false
      if assetReader.canAdd(output) {
        assetReader.add(output)
        audioOutput = output
      }
    }

    let videoWriterSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: targetWidth,
      AVVideoHeightKey: targetHeight,
      AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoWriterSettings)
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = transform
    guard assetWriter.canAdd(videoInput) else {
      completion(.failure(code: "WRITE_ERROR", message: "Cannot add video input"))
      return
    }
    assetWriter.add(videoInput)

    var audioInput: AVAssetWriterInput?
    if audioOutput != nil {
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
      input.expectsMediaDataInRealTime = false
      if assetWriter.canAdd(input) {
        assetWriter.add(input)
        audioInput = input
      }
    }

    guard assetReader.startReading() else {
      completion(.failure(code: "READ_ERROR", message: assetReader.error?.localizedDescription ?? "startReading failed"))
      return
    }
    guard assetWriter.startWriting() else {
      completion(.failure(code: "WRITE_ERROR", message: assetWriter.error?.localizedDescription ?? "startWriting failed"))
      return
    }
    assetWriter.startSession(atSourceTime: .zero)

    let durationSeconds = CMTimeGetSeconds(asset.duration)
    let group = DispatchGroup()

    group.enter()
    let videoQueue = DispatchQueue(label: "mugam.videoCompressor.video")
    videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
      guard let self = self else { group.leave(); return }
      while videoInput.isReadyForMoreMediaData {
        if self.isCancelled {
          videoInput.markAsFinished()
          group.leave()
          return
        }
        guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
          videoInput.markAsFinished()
          group.leave()
          return
        }
        if durationSeconds > 0 {
          let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
          self.emitProgress(min(pts / durationSeconds, 1.0))
        }
        videoInput.append(sampleBuffer)
      }
    }

    if let audioInput = audioInput, let audioOutput = audioOutput {
      group.enter()
      let audioQueue = DispatchQueue(label: "mugam.videoCompressor.audio")
      audioInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
        guard let self = self else { group.leave(); return }
        while audioInput.isReadyForMoreMediaData {
          if self.isCancelled {
            audioInput.markAsFinished()
            group.leave()
            return
          }
          guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
            audioInput.markAsFinished()
            group.leave()
            return
          }
          audioInput.append(sampleBuffer)
        }
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self = self else { return }
      if self.isCancelled || assetReader.status == .cancelled {
        assetWriter.cancelWriting()
        completion(.failure(code: "CANCELLED", message: "Compression cancelled"))
        return
      }
      if assetReader.status == .failed {
        assetWriter.cancelWriting()
        completion(.failure(code: "READ_ERROR", message: assetReader.error?.localizedDescription ?? "Reader failed"))
        return
      }
      assetWriter.finishWriting {
        if assetWriter.status == .completed {
          self.emitProgress(1.0)
          completion(.success)
        } else {
          completion(.failure(code: "WRITE_ERROR", message: assetWriter.error?.localizedDescription ?? "Writer failed"))
        }
      }
    }
  }

  private func emitProgress(_ value: Double) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(value)
    }
  }

  private func alignEven(_ value: CGFloat) -> CGFloat {
    let rounded = (value / 2).rounded() * 2
    return max(rounded, 2)
  }
}

private enum CompressResult {
  case success
  case failure(code: String, message: String)

  func fold(onSuccess: () -> Void, onFailure: (String, String) -> Void) {
    switch self {
    case .success: onSuccess()
    case .failure(let code, let message): onFailure(code, message)
    }
  }
}
