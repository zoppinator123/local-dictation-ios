import AVFoundation
import Foundation
#if os(iOS)
import AudioToolbox
#endif

public enum SpeechCaptureError: Error, Equatable, LocalizedError {
    case invalidInputFormat
    case engineStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Microphone is not ready yet."
        case .engineStartFailed(let message):
            return message
        }
    }
}

/// Keyboard-safe capture. AVAudioEngine/AVAudioRecorder both try to own
/// an output graph and fail in an appex (`record() false` with fa=1).
/// AudioQueueNewInput is input-only. Session/start stay on the main thread.
public final class SpeechCaptureEngine: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var request: SFSpeechBufferAppending?
    private var tapInstalled = false
    #if os(iOS)
    private var audioQueue: AudioQueueRef?
    private var queueFormat: AVAudioFormat?
    #endif

    public init() {}

    @MainActor
    public func startLive(appending request: SFSpeechBufferAppending) async throws {
        stopAndDelete()
        self.request = request
        #if os(iOS)
        try await prepareSession()
        var errors: [String] = []
        do {
            try startAudioQueue()
            return
        } catch {
            errors.append("aq \(error.localizedDescription)")
        }
        do {
            try startEngine()
            return
        } catch {
            errors.append("eng \(error.localizedDescription)")
            throw SpeechCaptureError.engineStartFailed(errors.joined(separator: " | "))
        }
        #else
        try startEngine()
        #endif
    }

    @MainActor
    public func startFile() async throws {
        stopAndDelete()
        #if os(iOS)
        try await prepareSession()
        #endif
        try startRecorder()
    }

    public func endAudio() {
        request?.endAudio()
    }

    @discardableResult
    public func stop() -> URL? {
        request?.endAudio()
        #if os(iOS)
        if let audioQueue {
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
            self.audioQueue = nil
        }
        queueFormat = nil
        #endif
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let engine, engine.isRunning {
            engine.stop()
        }
        engine = nil
        request = nil
        recorder?.stop()
        let url = fileURL
        recorder = nil
        fileURL = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        return url
    }

    public func stopAndDelete() {
        let url = stop()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    #if os(iOS)
    private func startAudioQueue() throws {
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        let sampleRate = sessionRate > 0 ? sessionRate : 48_000
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SpeechCaptureError.invalidInputFormat
        }
        queueFormat = format

        var queue: AudioQueueRef?
        let status = AudioQueueNewInput(
            &asbd,
            Self.audioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &queue
        )
        guard status == noErr, let queue else {
            throw SpeechCaptureError.engineStartFailed("AudioQueueNewInput \(status)")
        }
        audioQueue = queue

        let bufferBytes = UInt32(sampleRate * 0.1 * 2)
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            let alloc = AudioQueueAllocateBuffer(queue, bufferBytes, &buffer)
            guard alloc == noErr, let buffer else {
                throw SpeechCaptureError.engineStartFailed("AudioQueueAllocateBuffer \(alloc)")
            }
            let enq = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            guard enq == noErr else {
                throw SpeechCaptureError.engineStartFailed("AudioQueueEnqueueBuffer \(enq)")
            }
        }

        let start = AudioQueueStart(queue, nil)
        guard start == noErr else {
            throw SpeechCaptureError.engineStartFailed("AudioQueueStart \(start)")
        }
    }

    private static let audioQueueCallback: AudioQueueInputCallback = { userData, queue, buffer, _, numPackets, _ in
        guard let userData else {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            return
        }
        if numPackets > 0 {
            let capture = Unmanaged<SpeechCaptureEngine>.fromOpaque(userData).takeUnretainedValue()
            capture.appendQueueBuffer(buffer, packetCount: numPackets)
        }
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private func appendQueueBuffer(_ buffer: AudioQueueBufferRef, packetCount: UInt32) {
        guard let format = queueFormat,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: packetCount) else { return }
        pcm.frameLength = packetCount
        let byteCount = Int(packetCount) * 2
        if let dest = pcm.int16ChannelData?[0] {
            memcpy(dest, buffer.pointee.mAudioData, byteCount)
        }
        request?.append(pcm)
    }
    #endif

    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0 else {
            engine.reset()
            self.engine = nil
            throw SpeechCaptureError.invalidInputFormat
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            stopAndDelete()
            throw SpeechCaptureError.engineStartFailed("engine \(nsErrorText(error))")
        }
    }

    private func startRecorder() throws {
        #if os(iOS)
        let rate = AVAudioSession.sharedInstance().sampleRate
        let sampleRate = rate > 0 ? rate : 44_100
        #else
        let sampleRate = 44_100.0
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.prepareToRecord() else {
            throw SpeechCaptureError.engineStartFailed("prepareToRecord failed")
        }
        guard recorder.record() else {
            throw SpeechCaptureError.engineStartFailed("record() false rate=\(Int(sampleRate))")
        }
        self.recorder = recorder
        self.fileURL = url
    }

    #if os(iOS)
    @MainActor
    private func prepareSession() async throws {
        let granted = await requestMicPermission()
        guard granted else {
            throw SpeechCaptureError.engineStartFailed("Allow Microphone in the Local Dictation app, then try again.")
        }
        try activateMixedRecordSession()
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    private func activateMixedRecordSession() throws {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        var lastError: Error?
        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playAndRecord, .voiceChat, [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]),
            (.playAndRecord, .spokenAudio, [.mixWithOthers, .duckOthers, .defaultToSpeaker]),
            (.record, .measurement, [.mixWithOthers]),
        ]
        for (category, mode, options) in attempts {
            do {
                try session.setCategory(category, mode: mode, options: options)
                try session.setActive(true)
                return
            } catch {
                lastError = error
            }
        }
        throw SpeechCaptureError.engineStartFailed(nsErrorText(lastError ?? SpeechCaptureError.engineStartFailed("Audio session failed")))
    }
    #endif
}

public func nsErrorText(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain.isEmpty {
        return error.localizedDescription
    }
    return "\(ns.domain) \(ns.code): \(error.localizedDescription)"
}

public protocol SFSpeechBufferAppending: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}
