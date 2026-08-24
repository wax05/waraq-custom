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

import AppKit
import AVFoundation

final class VideoEngine: NSObject {
    private var asset: AVAsset
    private let player: AVPlayer
    private var playerItem: AVPlayerItem

    private(set) var videoURL: URL

    /// Container layer that's installed in the wallpaper window.
    /// Holds the player layer (and possibly a CAReplicatorLayer for
    /// Tile mode) at appropriate sizes and positions.
    let containerLayer: CALayer

    /// The actual AVPlayerLayer. Exposed for tests.
    let playerLayer: AVPlayerLayer

    /// Public interface for WallpaperWindow.install(layer:)
    var layer: CALayer {
        containerLayer
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var fitMode: DisplaySettings.FitMode {
        didSet { applyFitMode() }
    }

    var loop: Bool = true

    private(set) var renderFrameRate: Double?
    private(set) var renderScale: Float = 1

    private var presentationSizeObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init(videoURL: URL, fitMode: DisplaySettings.FitMode = .fill) {
        let asset = AVURLAsset(url: videoURL)
        self.asset = asset
        self.videoURL = videoURL
        playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        player.actionAtItemEnd = .none

        containerLayer = CALayer()
        containerLayer.backgroundColor = NSColor.black.cgColor
        containerLayer.autoresizingMask = [
            .layerWidthSizable, .layerHeightSizable,
        ]

        playerLayer = AVPlayerLayer(player: player)
        self.fitMode = fitMode

        super.init()

        applyFitMode()

        installItemObservers()
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    /// Switches to a preprocessed variant without rebuilding the window or
    /// AVPlayerLayer. The current playback position and play state survive
    /// the swap so a frame-rate setting change is not visible to the user.
    func replaceVideo(with url: URL) {
        guard url != videoURL else { return }

        let wasPlaying = player.rate != 0
        let currentTime = player.currentTime()
        player.pause()

        presentationSizeObserver?.invalidate()
        presentationSizeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        let newAsset = AVURLAsset(url: url)
        let newItem = AVPlayerItem(asset: newAsset)
        player.replaceCurrentItem(with: newItem)
        asset = newAsset
        playerItem = newItem
        videoURL = url
        renderFrameRate = nil
        renderScale = 1
        installItemObservers()
        applyFitMode()

        guard currentTime.isNumeric, currentTime.seconds >= 0 else {
            if wasPlaying { player.play() }
            return
        }

        player.seek(
            to: currentTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            guard wasPlaying else { return }
            self?.player.play()
        }
    }

    /// Applies the shared performance preset without replacing the
    /// AVPlayerLayer path. AVVideoComposition lets AVFoundation limit
    /// composed output cadence and scale before the layer is presented.
    func applyRenderSettings(
        quality: RenderQuality,
        maximumFrameRate: Double?
    ) {
        let frameRate = maximumFrameRate.map {
            min(max($0, 10), 120)
        }
        let scale = renderScale(for: quality)

        if renderFrameRate == frameRate, renderScale == scale {
            return
        }

        guard let track = asset.tracks(withMediaType: .video).first else {
            playerItem.videoComposition = nil
            renderFrameRate = nil
            renderScale = 1
            return
        }

        // AVPlayer already decodes and presents the source efficiently when
        // no cadence reduction or downscaling is needed. Creating a video
        // composition in that case adds a CPU-side render stage for no gain.
        let sourceFrameRate = Double(track.nominalFrameRate)
        let needsFrameRateLimit: Bool = if let frameRate {
            sourceFrameRate <= 0 || frameRate + 0.5 < sourceFrameRate
        } else {
            false
        }

        guard needsFrameRateLimit || scale < 1 else {
            playerItem.videoComposition = nil
            renderFrameRate = nil
            renderScale = 1
            return
        }

        let composition = AVMutableVideoComposition()
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: asset.duration
        )
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: track
        )
        layerInstruction.setTransform(track.preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        let transformedSize = track.naturalSize.applying(
            track.preferredTransform
        )
        composition.renderSize = CGSize(
            width: abs(transformedSize.width),
            height: abs(transformedSize.height)
        )
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        if let frameRate {
            composition.frameDuration = CMTime(
                seconds: 1 / frameRate,
                preferredTimescale: 600
            )
        }
        composition.renderScale = scale
        playerItem.videoComposition = composition
        renderFrameRate = frameRate
        renderScale = scale
    }

    @objc
    private func playerDidReachEnd() {
        guard loop else { return }
        player.seek(to: .zero)
        player.play()
    }

    private func installItemObservers() {
        presentationSizeObserver = playerItem.observe(
            \.presentationSize, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.applyFitMode()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.playerDidReachEnd()
        }
    }

    /// Rebuild the container's sublayers based on the current fit
    /// mode. Called on init, on fit change, and when video
    /// presentation size becomes known.
    private func applyFitMode() {
        // Disable implicit animations during layer rebuild so we
        // don't get fade transitions between fit modes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        containerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let displayBounds = containerLayer.bounds
        // Containerlayer.bounds may be .zero if not yet sized.
        // We still set up the layer; autoresizing applies once
        // installed in a sized parent.

        switch fitMode {
        case .fill:
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = displayBounds
            playerLayer.autoresizingMask = [
                .layerWidthSizable, .layerHeightSizable,
            ]
            containerLayer.addSublayer(playerLayer)

        case .fit:
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = displayBounds
            playerLayer.autoresizingMask = [
                .layerWidthSizable, .layerHeightSizable,
            ]
            containerLayer.addSublayer(playerLayer)

        case .stretch:
            playerLayer.videoGravity = .resize
            playerLayer.frame = displayBounds
            playerLayer.autoresizingMask = [
                .layerWidthSizable, .layerHeightSizable,
            ]
            containerLayer.addSublayer(playerLayer)

        case .center:
            let natural = naturalSize(fallback: CGSize(
                width: displayBounds.width / 2,
                height: displayBounds.height / 2
            ))
            playerLayer.videoGravity = .resize
            playerLayer.autoresizingMask = []
            playerLayer.frame = CGRect(
                x: (displayBounds.width - natural.width) / 2,
                y: (displayBounds.height - natural.height) / 2,
                width: natural.width,
                height: natural.height
            )
            containerLayer.addSublayer(playerLayer)

        case .tile:
            let rawNatural = naturalSize(fallback: CGSize(
                width: displayBounds.width / 3,
                height: displayBounds.height / 3
            ))
            // Guard against a zero/degenerate tile size. At launch
            // the container bounds can be .zero and the video's
            // presentationSize may not have loaded yet, so the
            // fallback collapses to 0. A 0-width tile makes the
            // column/row count 0/0 = NaN, and Int(NaN) traps with
            // "Double value cannot be converted to Int". applyFitMode
            // re-runs once the layer is sized and the size loads.
            let natural = CGSize(
                width: max(1, rawNatural.width),
                height: max(1, rawNatural.height)
            )
            playerLayer.videoGravity = .resize
            playerLayer.autoresizingMask = []
            playerLayer.frame = CGRect(
                origin: .zero, size: natural
            )

            // Two-level CAReplicator: horizontal row, then vertical
            // stack of rows.
            let cols = tileCount(total: displayBounds.width, unit: natural.width)
            let rows = tileCount(total: displayBounds.height, unit: natural.height)

            let horizontal = CAReplicatorLayer()
            horizontal.instanceCount = cols
            horizontal.instanceTransform = CATransform3DMakeTranslation(
                natural.width, 0, 0
            )
            horizontal.frame = CGRect(
                x: 0, y: 0,
                width: natural.width,
                height: natural.height
            )
            horizontal.addSublayer(playerLayer)

            let vertical = CAReplicatorLayer()
            vertical.instanceCount = rows
            vertical.instanceTransform = CATransform3DMakeTranslation(
                0, natural.height, 0
            )
            vertical.frame = CGRect(
                x: 0, y: 0,
                width: natural.width * CGFloat(cols),
                height: natural.height
            )
            vertical.addSublayer(horizontal)

            containerLayer.addSublayer(vertical)
        }
    }

    private func naturalSize(fallback: CGSize) -> CGSize {
        let p = playerItem.presentationSize
        if p == .zero { return fallback }
        return p
    }

    private func renderScale(for quality: RenderQuality) -> Float {
        guard let maximum = quality.maximumVideoDimension,
              let track = asset.tracks(withMediaType: .video).first else
        {
            return 1
        }

        let transformed = track.naturalSize.applying(track.preferredTransform)
        let sourceDimension = max(
            abs(transformed.width),
            abs(transformed.height)
        )
        guard sourceDimension > maximum, sourceDimension.isFinite else {
            return 1
        }
        return Float(maximum / sourceDimension)
    }

    /// Number of `unit`-sized tiles needed to cover `total`, clamped
    /// to a finite, sane range. Returns 1 for degenerate inputs
    /// (zero/NaN/infinite) so `Int(...)` can never trap on a NaN or
    /// infinite value.
    private func tileCount(total: CGFloat, unit: CGFloat) -> Int {
        guard total > 0, unit > 0, total.isFinite, unit.isFinite else {
            return 1
        }
        let count = ceil(total / unit)
        guard count.isFinite, count >= 1 else { return 1 }
        return Int(min(count, 1000))
    }

    deinit {
        presentationSizeObserver?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        NotificationCenter.default.removeObserver(self)
        player.pause()
    }
}
