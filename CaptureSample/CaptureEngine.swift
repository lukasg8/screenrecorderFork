/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An object that captures a stream of captured sample buffers containing screen and audio content.
*/

import Foundation
import AVFAudio
import ScreenCaptureKit
import OSLog
import Combine

/// A structure that contains the video data to render.
struct CapturedFrame {
    static let invalid = CapturedFrame(surface: nil, contentRect: .zero, contentScale: 0, scaleFactor: 0)

    let surface: IOSurface?
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat
    var size: CGSize { contentRect.size }
}

class AudioCaptureEngine: NSObject, @unchecked Sendable {
    
    private let logger = Logger()
    var audio: AudioRecorder = AudioRecorder(audioSettings: [:])
    private var microphoneRecorder: AVAudioRecorder?
    
    private var stream: SCStream?
    private let audioSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.AudioSampleBufferQueue")
    
    // Performs average and peak power calculations on the audio samples.
    private let powerMeter = PowerMeter()
    var audioLevels: AudioLevels { powerMeter.levels }

    // Store the the startCapture continuation, so that you can cancel it when you call stopCapture().
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?

    private var startTime = Date()
    
    private func setupMicrophoneRecorder() {
        // The settings for the recording: uncompressed audio in .wav format
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let outputFileName = NSUUID().uuidString
        let filePath = self.append(toPath: self.documentDirectory(),
                                             withPathComponent: outputFileName)
        let fileURL = URL(fileURLWithPath: filePath!).appendingPathExtension("WAV")
        
        do {
            microphoneRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        } catch {
            logger.error("Failed to initialize AVAudioRecorder: \(String(describing: error))")
        }
    }
    
    private func documentDirectory() -> String {
        let documentDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                                    .userDomainMask,
                                                                    true)
        return documentDirectory[0]
    }
    
    private func append(toPath path: String,
                        withPathComponent pathComponent: String) -> String? {
        if var pathURL = URL(string: path) {
            pathURL.appendPathComponent(pathComponent)

            return pathURL.absoluteString
        }

        return nil
    }

    
    func startCapture(configuration: SCStreamConfiguration, filter: SCContentFilter, audio: AudioRecorder) -> AsyncThrowingStream<CapturedFrame, Error> {
        AsyncThrowingStream<CapturedFrame, Error> { continuation in
            // The stream output object.
            let streamOutput = CaptureEngineAudioOutput()
            streamOutput.audio = audio
            streamOutput.pcmBufferHandler = { self.powerMeter.process(buffer: $0) }
            self.audio = streamOutput.audio!
            self.startTime = Date()
            self.audio.startRecording()
            
            self.setupMicrophoneRecorder()

            do {
                stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)

                try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)

                self.microphoneRecorder?.record()
                stream?.startCapture()
            } catch {
                debugPrint("Error: during start capture!")
            }
        }
    }
    
    func stopCapture() async {
        do {
            self.microphoneRecorder?.stop()
            try await stream?.stopCapture()
            continuation?.finish()
        } catch {
            debugPrint("Error: during start capture!")
        }
        powerMeter.processSilence()
        self.audio.stopRecording { [self] url in
            // save to CoreData
            do {
                let endTime = Date()

                let videoEntry = VideoEntry(context: DataController.shared.moc)
                videoEntry.id = UUID()
                videoEntry.url = url.description
                videoEntry.startTime = self.startTime
                videoEntry.endTime = endTime
                print(videoEntry)
                try? DataController.shared.save()
            } catch {
                logger.error("Failed to save the new audio: \(String(describing: error))")
            }

        }
    }

    /// - Tag: UpdateStreamConfiguration
    func update(configuration: SCStreamConfiguration, filter: SCContentFilter) async {
        do {
            try await stream?.updateConfiguration(configuration)
            try await stream?.updateContentFilter(filter)
        } catch {
            logger.error("Failed to update the stream session: \(String(describing: error))")
        }
    }

}

private class CaptureEngineAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var audio: AudioRecorder?
    
    var pcmBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        switch outputType {
        case .screen:
            break
        case .audio:
            guard let samples = createPCMBuffer(for: sampleBuffer) else { return }
            pcmBufferHandler?(samples)
            audio?.recordAudio(sampleBuffer: sampleBuffer)
        @unknown default:
            fatalError("Encountered unknown stream output type: \(outputType)")
        }
        
    }
    
    // Creates an AVAudioPCMBuffer instance on which to perform an average and peak audio level calculation.
    func createPCMBuffer(for sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}

/// An object that wraps an instance of `SCStream`, and returns its results as an `AsyncThrowingStream`.
class CaptureEngine: NSObject, @unchecked Sendable {
    
    private let logger = Logger()
    var movie: MovieRecorder = MovieRecorder(audioSettings: [:], videoSettings: [:], videoTransform: .identity)



    private var stream: SCStream?
    private let videoSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoSampleBufferQueue")
    private let audioSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.AudioSampleBufferQueue")

    // Performs average and peak power calculations on the audio samples.
    private let powerMeter = PowerMeter()
    var audioLevels: AudioLevels { powerMeter.levels }

    // Store the the startCapture continuation, so that you can cancel it when you call stopCapture().
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?

    private var startTime = Date()

    /// - Tag: StartCapture
    func startCapture(configuration: SCStreamConfiguration, filter: SCContentFilter, movie: MovieRecorder) -> AsyncThrowingStream<CapturedFrame, Error> {
        AsyncThrowingStream<CapturedFrame, Error> { continuation in
            // The stream output object.
            let streamOutput = CaptureEngineStreamOutput(continuation: continuation)
            streamOutput.movie = movie
            streamOutput.capturedFrameHandler = { continuation.yield($0) }
            streamOutput.pcmBufferHandler = { self.powerMeter.process(buffer: $0) }
            self.movie = streamOutput.movie!
            self.startTime = Date()
            self.movie.startRecording(height: Int(configuration.height), width: Int(configuration.width))

            do {
                stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)

                // Add a stream output to capture screen content.
                try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
                try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)

                stream?.startCapture()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func stopCapture() async {
        do {
            try await stream?.stopCapture()
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
        powerMeter.processSilence()
        self.movie.stopRecording { [self] url in
            // save to CoreData
            do {
                let endTime = Date()

                let videoEntry = VideoEntry(context: DataController.shared.moc)
                videoEntry.id = UUID()
                videoEntry.url = url.description
                videoEntry.startTime = self.startTime
                videoEntry.endTime = endTime
                print(videoEntry)
                try? DataController.shared.save()
            } catch {
                logger.error("Failed to save the new video: \(String(describing: error))")
            }

        }
    }

    /// - Tag: UpdateStreamConfiguration
    func update(configuration: SCStreamConfiguration, filter: SCContentFilter) async {
        do {
            try await stream?.updateConfiguration(configuration)
            try await stream?.updateContentFilter(filter)
        } catch {
            logger.error("Failed to update the stream session: \(String(describing: error))")
        }
    }
}

/// A class that handles output from an SCStream, and handles stream errors.
private class CaptureEngineStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var movie: MovieRecorder?

    var pcmBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    var capturedFrameHandler: ((CapturedFrame) -> Void)?

    // Store the the startCapture continuation, so you can cancel it if an error occurs.
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?

    init(continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?) {
        self.continuation = continuation
    }

    /// - Tag: DidOutputSampleBuffer
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {

        // Return early if the sample buffer is invalid.
        guard sampleBuffer.isValid else { return }

        //
        //movie.recordVideo(sampleBuffer: sampleBuffer)

        // Determine which type of data the sample buffer contains.
        switch outputType {
        case .screen:
            // Create a CapturedFrame structure for a video sample buffer.
            guard let frame = createFrame(for: sampleBuffer) else { return }
            capturedFrameHandler?(frame)
            movie?.recordVideo(sampleBuffer: sampleBuffer)

        case .audio:
            // Create an AVAudioPCMBuffer from an audio sample buffer.
            guard let samples = createPCMBuffer(for: sampleBuffer) else { return }
            pcmBufferHandler?(samples)
            movie?.recordAudio(sampleBuffer: sampleBuffer)
        @unknown default:
            fatalError("Encountered unknown stream output type: \(outputType)")
        }
    }

    /// Create a `CapturedFrame` for the video sample buffer.
    private func createFrame(for sampleBuffer: CMSampleBuffer) -> CapturedFrame? {

        // Retrieve the array of metadata attachments from the sample buffer.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                             createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return nil }

        // Validate the status of the frame. If it isn't `.complete`, return nil.
        guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else { return nil }

        // Get the pixel buffer that contains the image data.
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return nil }

        // Get the backing IOSurface.
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)

        // Retrieve the content rectangle, scale, and scale factor.
        guard let contentRectDict = attachments[.contentRect],
              let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary),
              let contentScale = attachments[.contentScale] as? CGFloat,
              let scaleFactor = attachments[.scaleFactor] as? CGFloat else { return nil }

        // Create a new frame with the relevant data.
        let frame = CapturedFrame(surface: surface,
                                  contentRect: contentRect,
                                  contentScale: contentScale,
                                  scaleFactor: scaleFactor)
        return frame
    }

    // Creates an AVAudioPCMBuffer instance on which to perform an average and peak audio level calculation.
    func createPCMBuffer(for sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation?.finish(throwing: error)
    }
}
