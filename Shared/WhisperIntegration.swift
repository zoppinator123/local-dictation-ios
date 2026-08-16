import Foundation
import Darwin

public enum BundledWhisperModel {
    public static let folderName = "openai_whisper-base.en"
    public static let repository = "argmaxinc/whisperkit-coreml"
    public static let revision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    public static let tokenizerRepository = "openai/whisper-base.en"
    public static let tokenizerRevision = "911407f4214e0e1d82085af863093ec0b66f9cd6"
    public static let tokenizerSHA256: [String: String] = [
        "added_tokens.json": "560be47bea388757f8d4cc185c5d82067426cbb6361e38016dd90ddc01ab203a",
        "merges.txt": "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5",
        "normalizer.json": "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd",
        "special_tokens_map.json": "014f8f802366ed818919550be0ad9e35907327cb9e142e8aaa102420f460bda8",
        "tokenizer.json": "5eb60cec1e77aeeb6869a2bb5a8e01a84c3fe5d072d75369343021fe6f5310d0",
        "tokenizer_config.json": "14f84bdf4b9ecdbd4738ddc81c17a1baedfc02bb93c6e049c951e15a1b40b70d",
        "vocab.json": "3ba3c3109ff33976c4bd966589c11ee14fcaa1f4c9e5e154c2ed7f99d80709e7",
    ]
}

public enum WhisperVocabularyPrompt {
    public static let words = [
        "Hostaway",
        "Breezeway",
        "Sevierville",
        "Tendwell",
        "ADR",
        "GBV",
        "StaydOS",
    ]

    public static let text = "Vocabulary: " + words.joined(separator: ", ") + "."
}

public struct CapturedPCMChunk: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var frameCount: Int {
        channels.map(\.count).min() ?? 0
    }

    public var channelCount: Int { channels.count }
}

/// Owns copied PCM in one preallocated planar buffer. The Core Audio callback
/// performs only bounded memory copies with lock-free atomic coordination: no
/// arrays, locks, tasks, actor hops, or growing collections are created there.
public final class PCMClipBuffer: @unchecked Sendable {
    private let maximumFrames: Int
    private let maximumChannels: Int
    private let storage: UnsafeMutablePointer<Float>
    private let clippingFlag: UnsafeMutablePointer<Int32>
    private let writersInFlight: UnsafeMutablePointer<Int32>
    private var storedFrames = 0
    private var storedChannels = 0
    private var storedSampleRate = 0.0
    private var didOverflow = false

    public init(maximumFrames: Int = 48_000 * 120, maximumChannels: Int = 1) {
        self.maximumFrames = maximumFrames
        self.maximumChannels = maximumChannels
        storage = .allocate(capacity: maximumFrames * maximumChannels)
        clippingFlag = .allocate(capacity: 1)
        clippingFlag.initialize(to: 0)
        writersInFlight = .allocate(capacity: 1)
        writersInFlight.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        clippingFlag.deinitialize(count: 1)
        clippingFlag.deallocate()
        writersInFlight.deinitialize(count: 1)
        writersInFlight.deallocate()
    }

    public func beginClip() {
        stopAcceptingAndDrainWriters()
        storedFrames = 0
        storedChannels = 0
        storedSampleRate = 0
        didOverflow = false
        OSMemoryBarrier()
        _ = OSAtomicCompareAndSwap32Barrier(0, 1, clippingFlag)
    }

    /// Compatibility helper for tests and non-realtime callers.
    public func append(_ chunk: CapturedPCMChunk) {
        guard chunk.sampleRate > 0, chunk.channelCount > 0, chunk.frameCount > 0,
              beginRealtimeWrite() else { return }
        defer { endRealtimeWrite() }
        appendToStorage(
            frameCount: chunk.frameCount,
            channelCount: chunk.channelCount,
            sampleRate: chunk.sampleRate
        ) { channel, destination, count in
            chunk.channels[channel].withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    destination.update(from: base, count: count)
                }
            }
        }
    }

    /// Copies Float32 callback samples into preallocated storage. `channelData`
    /// is used synchronously and never retained.
    public func appendFloat32(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        interleaved: Bool
    ) {
        guard frameCount > 0, channelCount > 0, sampleRate > 0,
              beginRealtimeWrite() else { return }
        defer { endRealtimeWrite() }
        appendToStorage(
            frameCount: frameCount,
            channelCount: channelCount,
            sampleRate: sampleRate
        ) { channel, destination, count in
            if interleaved {
                let source = channelData[0]
                for frame in 0..<count {
                    destination[frame] = source[frame * channelCount + channel]
                }
            } else {
                destination.update(from: channelData[channel], count: count)
            }
        }
    }

    public func takeClip() -> PCMClipSnapshot {
        stopAcceptingAndDrainWriters()
        let frames = storedFrames
        let channels = storedChannels
        let sampleRate = storedSampleRate
        let overflowed = didOverflow
        storedFrames = 0
        storedChannels = 0
        storedSampleRate = 0
        didOverflow = false

        guard frames > 0, channels > 0 else {
            return PCMClipSnapshot(chunks: [], overflowed: overflowed)
        }
        var copiedChannels: [[Float]] = []
        copiedChannels.reserveCapacity(channels)
        for channel in 0..<channels {
            copiedChannels.append(Array(UnsafeBufferPointer(
                start: storage.advanced(by: channel * maximumFrames),
                count: frames
            )))
        }
        return PCMClipSnapshot(
            chunks: [CapturedPCMChunk(sampleRate: sampleRate, channels: copiedChannels)],
            overflowed: overflowed
        )
    }

    public func cancelClip() {
        stopAcceptingAndDrainWriters()
        storedFrames = 0
        storedChannels = 0
        storedSampleRate = 0
        didOverflow = false
    }

    public var isClipping: Bool {
        OSAtomicAdd32Barrier(0, clippingFlag) == 1
    }

    private func appendToStorage(
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        copier: (_ channel: Int, _ destination: UnsafeMutablePointer<Float>, _ count: Int) -> Void
    ) {
        let channelsToCopy = min(channelCount, maximumChannels)
        let count = min(frameCount, maximumFrames - storedFrames)
        guard channelsToCopy > 0, count > 0 else {
            didOverflow = true
            return
        }
        if storedFrames == 0 {
            storedChannels = channelsToCopy
            storedSampleRate = sampleRate
        }
        let activeChannels = min(storedChannels, channelsToCopy)
        for channel in 0..<activeChannels {
            copier(
                channel,
                storage.advanced(by: channel * maximumFrames + storedFrames),
                count
            )
        }
        storedFrames += count
        if count < frameCount || channelsToCopy < channelCount { didOverflow = true }
    }

    private func beginRealtimeWrite() -> Bool {
        guard OSAtomicAdd32Barrier(0, clippingFlag) == 1 else { return false }
        _ = OSAtomicIncrement32Barrier(writersInFlight)
        guard OSAtomicAdd32Barrier(0, clippingFlag) == 1 else {
            _ = OSAtomicDecrement32Barrier(writersInFlight)
            return false
        }
        return true
    }

    private func endRealtimeWrite() {
        _ = OSAtomicDecrement32Barrier(writersInFlight)
    }

    /// Runs only on the command path. It closes the producer gate, then waits
    /// for a callback that already entered to finish its bounded memory copy.
    private func stopAcceptingAndDrainWriters() {
        _ = OSAtomicCompareAndSwap32Barrier(1, 0, clippingFlag)
        while OSAtomicAdd32Barrier(0, writersInFlight) != 0 {
            sched_yield()
        }
        OSMemoryBarrier()
    }
}

public struct PCMClipSnapshot: Equatable, Sendable {
    public let chunks: [CapturedPCMChunk]
    public let overflowed: Bool

    public init(chunks: [CapturedPCMChunk], overflowed: Bool = false) {
        self.chunks = chunks
        self.overflowed = overflowed
    }

    public var frameCount: Int { chunks.reduce(0) { $0 + $1.frameCount } }
    public var channelCount: Int { chunks.map(\.channelCount).max() ?? 0 }
    public var sampleRate: Double? { chunks.first?.sampleRate }
}

public enum PCMConversionError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case invalidSampleRate
    case inconsistentSampleRate
    case missingChannel

    public var errorDescription: String? {
        switch self {
        case .empty: return "No audio was captured."
        case .invalidSampleRate: return "The captured audio sample rate is invalid."
        case .inconsistentSampleRate: return "The microphone sample rate changed during the take."
        case .missingChannel: return "The captured audio has no readable channel."
        }
    }
}

public struct ResampledPCM: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let sourceFrameCount: Int
    public let sourceSampleRate: Double
    public let sourceChannelCount: Int

    public init(
        samples: [Float],
        sampleRate: Int,
        sourceFrameCount: Int,
        sourceSampleRate: Double,
        sourceChannelCount: Int
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sourceFrameCount = sourceFrameCount
        self.sourceSampleRate = sourceSampleRate
        self.sourceChannelCount = sourceChannelCount
    }
}

public enum PCMResampler {
    public static let whisperSampleRate = 16_000
    private static let decimation48To16Weights: [Double] = (-3...3).map { offset in
        let distance = Double(offset)
        let cutoff = (16_000.0 / 48_000.0) * 0.94
        let sincArgument = Double.pi * distance * cutoff
        let sinc = abs(sincArgument) < 1e-12 ? 1.0 : sin(sincArgument) / sincArgument
        let window = 0.5 * (1.0 + cos(Double.pi * abs(distance) / 4.0))
        return cutoff * sinc * window
    }

    /// Selects channel zero and performs deterministic windowed-sinc conversion.
    /// The low-pass cutoff prevents the aliasing caused by simple sample dropping.
    public static func convertToWhisperPCM(_ clip: PCMClipSnapshot) throws -> ResampledPCM {
        guard let sourceRate = clip.sampleRate else { throw PCMConversionError.empty }
        guard sourceRate.isFinite, sourceRate > 0 else { throw PCMConversionError.invalidSampleRate }
        guard clip.frameCount > 0 else { throw PCMConversionError.empty }

        var mono: [Float] = []
        mono.reserveCapacity(clip.frameCount)
        for chunk in clip.chunks {
            guard abs(chunk.sampleRate - sourceRate) < 0.5 else {
                throw PCMConversionError.inconsistentSampleRate
            }
            guard let channelZero = chunk.channels.first, chunk.frameCount > 0 else {
                throw PCMConversionError.missingChannel
            }
            mono.append(contentsOf: channelZero.prefix(chunk.frameCount))
        }
        guard !mono.isEmpty else { throw PCMConversionError.empty }

        let output = resample(mono, from: sourceRate, to: Double(whisperSampleRate))
        return ResampledPCM(
            samples: output,
            sampleRate: whisperSampleRate,
            sourceFrameCount: mono.count,
            sourceSampleRate: sourceRate,
            sourceChannelCount: clip.channelCount
        )
    }

    public static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        if abs(sourceRate - targetRate) < 0.5 { return input }
        if abs(sourceRate - 48_000) < 0.5, abs(targetRate - 16_000) < 0.5 {
            return decimate48To16(input)
        }

        let outputCount = max(1, Int((Double(input.count) * targetRate / sourceRate).rounded()))
        let sourcePerOutput = sourceRate / targetRate
        let cutoff = min(1.0, targetRate / sourceRate) * 0.94
        let radius = 16
        var output = [Float](repeating: 0, count: outputCount)

        for outputIndex in output.indices {
            let center = (Double(outputIndex) + 0.5) * sourcePerOutput - 0.5
            let first = max(0, Int(floor(center)) - radius + 1)
            let last = min(input.count - 1, Int(floor(center)) + radius)
            var weighted = 0.0
            var weightSum = 0.0
            if first <= last {
                for sourceIndex in first...last {
                    let distance = Double(sourceIndex) - center
                    let normalized = abs(distance) / Double(radius)
                    guard normalized < 1 else { continue }
                    let sincArgument = Double.pi * distance * cutoff
                    let sinc = abs(sincArgument) < 1e-12 ? 1.0 : sin(sincArgument) / sincArgument
                    let window = 0.5 * (1.0 + cos(Double.pi * normalized))
                    let weight = cutoff * sinc * window
                    weighted += Double(input[sourceIndex]) * weight
                    weightSum += weight
                }
            }
            output[outputIndex] = Float(weightSum == 0 ? 0 : weighted / weightSum)
        }
        return output
    }

    private static func decimate48To16(_ input: [Float]) -> [Float] {
        let outputCount = max(1, Int((Double(input.count) / 3).rounded()))
        var output = [Float](repeating: 0, count: outputCount)
        for outputIndex in output.indices {
            let center = outputIndex * 3 + 1
            var weighted = 0.0
            var weightSum = 0.0
            for (weightIndex, weight) in decimation48To16Weights.enumerated() {
                let sourceIndex = center + weightIndex - 3
                guard input.indices.contains(sourceIndex) else { continue }
                weighted += Double(input[sourceIndex]) * weight
                weightSum += weight
            }
            output[outputIndex] = Float(weightSum == 0 ? 0 : weighted / weightSum)
        }
        return output
    }
}

public enum TranscriptionEngine: String, Equatable, Sendable {
    case none
    case whisperKit
    case appleSpeech
}

public struct TranscriptionOutcome: Equatable, Sendable {
    public let text: String
    public let engine: TranscriptionEngine
    public let fallbackReason: String?

    public init(text: String, engine: TranscriptionEngine, fallbackReason: String? = nil) {
        self.text = text
        self.engine = engine
        self.fallbackReason = fallbackReason
    }
}

public enum PrimaryTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .timedOut: return "WhisperKit did not finish within the 5-second limit."
        }
    }
}

public struct FallbackTranscriptionCoordinator: Sendable {
    public let timeoutNanoseconds: UInt64
    public let minimumSamples: Int

    public init(timeoutNanoseconds: UInt64 = 5_000_000_000, minimumSamples: Int = 800) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.minimumSamples = minimumSamples
    }

    public func transcribe(
        samples: [Float],
        primaryAvailable: Bool,
        primaryUnavailableReason: String = "WhisperKit model is unavailable.",
        primary: @escaping @Sendable ([Float]) async throws -> String,
        fallback: @escaping @Sendable ([Float]) async throws -> String
    ) async throws -> TranscriptionOutcome {
        guard samples.count >= minimumSamples else {
            return TranscriptionOutcome(text: "", engine: .none, fallbackReason: "clip-too-short")
        }

        if !primaryAvailable {
            let text = try await fallback(samples)
            return TranscriptionOutcome(text: text, engine: .appleSpeech, fallbackReason: primaryUnavailableReason)
        }

        do {
            let text = try await runPrimaryWithTimeout(samples: samples, operation: primary)
            return TranscriptionOutcome(text: text, engine: .whisperKit)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let text = try await fallback(samples)
            return TranscriptionOutcome(text: text, engine: .appleSpeech, fallbackReason: reason)
        }
    }

    private func runPrimaryWithTimeout(
        samples: [Float],
        operation: @escaping @Sendable ([Float]) async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await operation(samples) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw PrimaryTranscriptionError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PrimaryTranscriptionError.unavailable("WhisperKit returned no result.")
            }
            return first
        }
    }
}

public final class TakeGenerationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    @discardableResult
    public func advance() -> UInt64 {
        lock.lock()
        value &+= 1
        let next = value
        lock.unlock()
        return next
    }

    public func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        snapshot() == candidate
    }
}

public enum LocalhostAuthentication {
    public static let headerName = "X-Local-Dictation-Token"

    public static func isAuthorized(request: String, expectedToken: String?) -> Bool {
        guard let expectedToken, !expectedToken.isEmpty,
              let supplied = headerValue(named: headerName, in: request), !supplied.isEmpty else {
            return false
        }
        return constantTimeEqual(Data(supplied.utf8), Data(expectedToken.utf8))
    }

    public static func headerValue(named name: String, in request: String) -> String? {
        let lines = request.components(separatedBy: .newlines).dropFirst()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let header = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            if header.caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        let count = max(left.count, right.count)
        var difference = UInt64(left.count ^ right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= UInt64(a ^ b)
        }
        return difference == 0
    }
}

public enum LocalhostRequestPolicy {
    public static func isAllowed(request: String, route: HostCaptureRoute) -> Bool {
        guard route != .unknown,
              let method = requestLineMethod(request) else { return false }
        switch route {
        case .health:
            return method == "GET"
        case .start, .stop, .off:
            return method == "POST"
        case .unknown:
            return false
        }
    }

    private static func requestLineMethod(_ request: String) -> String? {
        let line = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init)
        return line?.split(separator: " ").first.map { String($0).uppercased() }
    }
}

public enum KeyboardTransportPolicy {
    public static let sessionExpiredMessage = "Session expired. Reopen Local Dictation."
}
