//  Waraq - A native macOS animated wallpaper app.
//  Copyright (C) 2026 Omar A. Othman
//
//  This program is free software: you can redistribute it
//  and/or modify it under the terms of the GNU General
//  Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at
//  your option) any later version.
//
//  This program is distributed in the hope that it will
//  be useful, but WITHOUT ANY WARRANTY; without even the
//  implied warranty of MERCHANTABILITY or FITNESS FOR A
//  PARTICULAR PURPOSE. See the GNU General Public License
//  for more details.
//
//  You should have received a copy of the GNU General
//  Public License along with this program. If not, see
//  <https://www.gnu.org/licenses/>.
//

import AVFoundation
import Combine
import CoreVideo
import Foundation
import RifeMetal

@MainActor
final class RifeInterpolationQueue: ObservableObject {
    static let shared = RifeInterpolationQueue()

    struct Job: Identifiable, Equatable {
        enum Status: Equatable {
            case queued
            case processing
            case completed
            case failed
        }

        let id: String
        let name: String
        let targetFrameRates: [Int]
        var status: Status = .queued
        var currentFrameRate: Int?
        var variantProgress: Double = 0
        var progress: Double = 0
        var completedFrameRates: [Int] = []
        var errorMessage: String?

        var isFinished: Bool {
            status == .completed || status == .failed
        }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isPaused = false

    func enqueue(
        id: String,
        name: String,
        targetFrameRates: [Int]
    ) {
        jobs.removeAll { $0.id == id }
        jobs.append(
            Job(
                id: id,
                name: name,
                targetFrameRates: targetFrameRates
            )
        )
    }

    func start(id: String, frameRate: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard !jobs[index].isFinished else { return }
        jobs[index].status = .processing
        jobs[index].currentFrameRate = frameRate
        jobs[index].variantProgress = 0
    }

    func update(
        id: String,
        frameRate: Int,
        variantProgress: Double,
        progress: Double
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard !jobs[index].isFinished else { return }
        jobs[index].status = .processing
        jobs[index].currentFrameRate = frameRate
        jobs[index].variantProgress = clamped(variantProgress)
        jobs[index].progress = clamped(progress)
    }

    func completeVariant(
        id: String,
        frameRate: Int,
        progress: Double
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard !jobs[index].isFinished else { return }
        if !jobs[index].completedFrameRates.contains(frameRate) {
            jobs[index].completedFrameRates.append(frameRate)
        }
        jobs[index].currentFrameRate = nil
        jobs[index].variantProgress = 1
        jobs[index].progress = clamped(progress)
    }

    func complete(id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].status = .completed
        jobs[index].currentFrameRate = nil
        jobs[index].variantProgress = 1
        jobs[index].progress = 1
        jobs[index].completedFrameRates = jobs[index].targetFrameRates
    }

    func fail(id: String, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].status = .failed
        jobs[index].currentFrameRate = nil
        jobs[index].errorMessage = message
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        Task {
            await RifeMetalPreprocessor.shared.setPaused(paused)
        }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Offline frame interpolation for imported videos.
///
/// The job is intentionally sequential per wallpaper: each completed MP4 is
/// immediately usable, while the remaining target rates continue in the
/// background. RifeMetal's bundled Practical-RIFE v4.26 model is the only
/// model used here.
actor RifeMetalPreprocessor {
    static let shared = RifeMetalPreprocessor()
    static let didProduceVariantNotification = Notification.Name(
        "Waraq.rifeMetalVariantDidProduce"
    )

    private var jobs: [String: Task<Void, Never>] = [:]
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func setPaused(_ paused: Bool) {
        isPaused = paused
        guard !paused else { return }
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func enqueue(
        sourceURL: URL,
        wallpaperID: String,
        displayName: String,
        outputDirectory: URL,
        displayMaxFPS: Int
    ) {
        guard jobs[wallpaperID] == nil else { return }

        let asset = AVURLAsset(url: sourceURL)
        let sourceFPS = asset.tracks(withMediaType: .video).first.map {
            max(Double($0.nominalFrameRate), 1)
        } ?? 1
        let targetFrameRates = Self.targetFrameRates(
            sourceFPS: sourceFPS,
            displayMaxFPS: displayMaxFPS
        )
        Task { @MainActor in
            RifeInterpolationQueue.shared.enqueue(
                id: wallpaperID,
                name: displayName,
                targetFrameRates: targetFrameRates
            )
        }

        let job = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Self.process(
                    sourceURL: sourceURL,
                    wallpaperID: wallpaperID,
                    outputDirectory: outputDirectory,
                    displayMaxFPS: displayMaxFPS,
                    waitUntilResumed: { [weak self] in
                        await self?.waitUntilResumed()
                    }
                )
                Task { @MainActor in
                    RifeInterpolationQueue.shared.complete(id: wallpaperID)
                }
            } catch {
                NSLog("Waraq: RifeMetal preprocessing failed: \(error)")
                Task { @MainActor in
                    RifeInterpolationQueue.shared.fail(
                        id: wallpaperID,
                        message: error.localizedDescription
                    )
                }
            }
            await self?.finish(wallpaperID)
        }
        jobs[wallpaperID] = job
    }

    static func targetFrameRates(
        sourceFPS: Double,
        displayMaxFPS: Int
    ) -> [Int] {
        let maximum = min(max(displayMaxFPS, 30), 120)
        var result: [Int] = []

        func append(_ fps: Int) {
            guard fps >= 30, fps <= maximum,
                  Double(fps) > sourceFPS + 0.5,
                  !result.contains(fps) else { return }
            result.append(fps)
        }

        // The original file is always available as the fallback. Generate
        // only the useful interpolation variants on top of it.
        [30, 60, maximum].forEach(append)
        return result
    }

    private func finish(_ wallpaperID: String) {
        jobs[wallpaperID] = nil
    }

    private func waitUntilResumed() async {
        guard isPaused else { return }
        await withCheckedContinuation { continuation in
            if isPaused {
                pauseWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private static func process(
        sourceURL: URL,
        wallpaperID: String,
        outputDirectory: URL,
        displayMaxFPS: Int,
        waitUntilResumed: @escaping @Sendable () async -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ProcessingError.missingVideo
        }

        let sourceFPS = max(Double(track.nominalFrameRate), 1)
        let targets = targetFrameRates(
            sourceFPS: sourceFPS,
            displayMaxFPS: displayMaxFPS
        )
        guard !targets.isEmpty else { return }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let interpolator = try RifeInterpolator(
            configuration: .bundled(qualityTier: .balanced)
        )

        for (index, fps) in targets.enumerated() {
            await waitUntilResumed()
            let finalURL = outputDirectory
                .appendingPathComponent("\(fps)fps.mp4")
            let temporaryURL = outputDirectory
                .appendingPathComponent(".\(fps)fps.partial.mp4")
            try? FileManager.default.removeItem(at: finalURL)
            try? FileManager.default.removeItem(at: temporaryURL)

            Task { @MainActor in
                RifeInterpolationQueue.shared.start(
                    id: wallpaperID,
                    frameRate: fps
                )
            }
            var reporter = ProgressReporter(
                wallpaperID: wallpaperID,
                frameRate: fps,
                variantIndex: index,
                variantCount: targets.count
            )
            reporter.report(0, force: true)

            do {
                try writeVariant(
                    asset: asset,
                    track: track,
                    fps: fps,
                    interpolator: interpolator,
                    outputURL: temporaryURL,
                    progress: { fraction in
                        reporter.report(fraction)
                    }
                )
                reporter.report(1, force: true)
                try FileManager.default.moveItem(
                    at: temporaryURL,
                    to: finalURL
                )
                Task { @MainActor in
                    RifeInterpolationQueue.shared.completeVariant(
                        id: wallpaperID,
                        frameRate: fps,
                        progress: Double(index + 1) / Double(targets.count)
                    )
                }
                NotificationCenter.default.post(
                    name: didProduceVariantNotification,
                    object: nil,
                    userInfo: [
                        "wallpaperID": wallpaperID,
                        "frameRate": fps,
                        "url": finalURL,
                    ]
                )
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
    }

    private static func writeVariant(
        asset: AVAsset,
        track: AVAssetTrack,
        fps: Int,
        interpolator: RifeInterpolator,
        outputURL: URL,
        progress: (Double) -> Void
    ) throws {
        let (reader, videoOutput) = try makeVideoReader(
            asset: asset,
            track: track
        )
        guard let first = nextFrame(
            from: videoOutput,
            origin: .zero
        ) else {
            throw ProcessingError.missingVideo
        }

        let width = CVPixelBufferGetWidth(first.buffer)
        let height = CVPixelBufferGetHeight(first.buffer)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    // Keep generated storage proportional to both pixels
                    // and output cadence instead of using the same large
                    // bitrate for every Rife variant.
                    AVVideoAverageBitRateKey: max(
                        4_000_000,
                        min(
                            Int(Double(width * height) * Double(fps) * 0.08),
                            40_000_000
                        )
                    ),
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = track.preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if asset.tracks(withMediaType: .audio).first != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil
            )
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw ProcessingError.writer(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        var previous = first
        var current = nextFrame(from: videoOutput, origin: .zero)
        let duration = max(asset.duration.seconds, 0)
        let step = 1.0 / Double(fps)
        var outputSeconds = 0.0
        let epsilon = 0.000_001
        progress(0)

        while outputSeconds < duration - epsilon {
            while let candidate = current,
                  candidate.time.seconds < outputSeconds - epsilon
            {
                previous = candidate
                current = nextFrame(from: videoOutput, origin: .zero)
            }

            let outputBuffer: CVPixelBuffer
            if current == nil ||
                outputSeconds <= previous.time.seconds + epsilon
            {
                outputBuffer = previous.buffer
            } else if let current,
                      abs(current.time.seconds - outputSeconds) <= epsilon
            {
                outputBuffer = current.buffer
            } else if let current {
                let span = current.time.seconds - previous.time.seconds
                let ratio = span > epsilon
                    ? (outputSeconds - previous.time.seconds) / span
                    : 0.5
                let timestep = Float(min(max(ratio, 0.001), 0.999))
                outputBuffer = try interpolator.interpolate(
                    previous: previous.buffer,
                    current: current.buffer,
                    timesteps: [timestep]
                )[0]
            } else {
                outputBuffer = previous.buffer
            }

            let presentationTime = CMTime(
                seconds: outputSeconds,
                preferredTimescale: 60_000
            )
            guard waitUntilReady(videoInput, writer: writer),
                  adaptor.append(
                      outputBuffer,
                      withPresentationTime: presentationTime
                  ) else {
                throw ProcessingError.writer(writer.error)
            }
            outputSeconds += step
            let fraction = duration > epsilon
                ? min(outputSeconds / duration, 1)
                : 1
            progress(fraction)
        }
        progress(1)
        videoInput.markAsFinished()

        if let audioInput {
            try appendAudio(
                asset: asset,
                input: audioInput,
                writer: writer
            )
            audioInput.markAsFinished()
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ProcessingError.writer(writer.error)
        }
        _ = reader
    }

    private static func makeVideoReader(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ProcessingError.reader(nil)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ProcessingError.reader(reader.error)
        }
        return (reader, output)
    }

    private static func nextFrame(
        from output: AVAssetReaderTrackOutput,
        origin: CMTime
    ) -> VideoFrame? {
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            guard timestamp.seconds.isFinite else { continue }
            return VideoFrame(
                buffer: buffer,
                time: CMTimeSubtract(timestamp, origin)
            )
        }
        return nil
    }

    private static func appendAudio(
        asset: AVAsset,
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws {
        guard let track = asset.tracks(withMediaType: .audio).first else {
            return
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw ProcessingError.reader(nil)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ProcessingError.reader(reader.error)
        }
        while let sample = output.copyNextSampleBuffer() {
            guard waitUntilReady(input, writer: writer), input.append(sample) else {
                throw ProcessingError.writer(writer.error)
            }
        }
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) -> Bool {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return writer.status == .writing
    }

    private struct VideoFrame {
        let buffer: CVPixelBuffer
        let time: CMTime
    }

    private struct ProgressReporter {
        let wallpaperID: String
        let frameRate: Int
        let variantIndex: Int
        let variantCount: Int
        var lastSentAt: TimeInterval = 0

        mutating func report(_ variantProgress: Double, force: Bool = false) {
            let clamped = min(max(variantProgress, 0), 1)
            let now = ProcessInfo.processInfo.systemUptime
            guard force || clamped >= 1 || now - lastSentAt >= 0.1 else {
                return
            }
            lastSentAt = now
            let overallProgress = (
                Double(variantIndex) + clamped
            ) / Double(variantCount)
            let id = wallpaperID
            let rate = frameRate
            Task { @MainActor in
                RifeInterpolationQueue.shared.update(
                    id: id,
                    frameRate: rate,
                    variantProgress: clamped,
                    progress: overallProgress
                )
            }
        }
    }

    private enum ProcessingError: LocalizedError {
        case missingVideo
        case reader(Error?)
        case writer(Error?)

        var errorDescription: String? {
            switch self {
            case .missingVideo:
                return NSLocalizedString(
                    "No decodable video frames were found.",
                    comment: "Frame interpolation error"
                )
            case let .reader(error):
                return String(
                    format: NSLocalizedString(
                        "AVAssetReader failed: %@",
                        comment: "Frame interpolation error"
                    ),
                    error?.localizedDescription ?? NSLocalizedString(
                        "unknown error",
                        comment: "Unknown error"
                    )
                )
            case let .writer(error):
                return String(
                    format: NSLocalizedString(
                        "AVAssetWriter failed: %@",
                        comment: "Frame interpolation error"
                    ),
                    error?.localizedDescription ?? NSLocalizedString(
                        "unknown error",
                        comment: "Unknown error"
                    )
                )
            }
        }
    }
}
