import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import UIKit

enum MediaError: LocalizedError {
    case unreadable, cannotCompose, cannotExport

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取所选视频。"
        case .cannotCompose: "无法生成预览，请检查素材的格式。"
        case .cannotExport: "无法导出 MP4。"
        }
    }
}

struct MediaComposition {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }

    static func build(clips: [Clip], muted: Bool) async throws -> Self {
        let composition = AVMutableComposition()
        guard let outputVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw MediaError.cannotCompose }
        let outputAudio = muted ? nil : composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var cursor = CMTime.zero
        var audioCursor = CMTime.zero

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw MediaError.unreadable
            }
            let (transform, size) = try await video.load(.preferredTransform, .naturalSize)
            let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
            guard bounds.width > 0, bounds.height > 0 else { throw MediaError.cannotCompose }
            if instructions.isEmpty {
                let scale = min(1, 1920 / max(bounds.width, bounds.height))
                videoComposition.renderSize = CGSize(
                    width: max(2, floor(bounds.width * scale / 2) * 2),
                    height: max(2, floor(bounds.height * scale / 2) * 2)
                )
            }
            let range = CMTimeRange(start: time(clip.start), end: time(clip.end))
            try outputVideo.insertTimeRange(range, of: video, at: cursor)

            if let outputAudio, let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let overlap = range.intersection(try await audio.load(.timeRange))
                if overlap.isValid && !overlap.isEmpty {
                    let audioStart = cursor + (overlap.start - range.start)
                    if CMTimeCompare(audioStart, audioCursor) > 0 {
                        outputAudio.insertEmptyTimeRange(CMTimeRange(start: audioCursor, end: audioStart))
                    }
                    try outputAudio.insertTimeRange(overlap, of: audio, at: audioStart)
                    audioCursor = audioStart + overlap.duration
                }
            }

            let frame = videoComposition.renderSize
            let factor = min(frame.width / bounds.width, frame.height / bounds.height)
            let position = transform
                .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: factor, y: factor))
                .concatenating(CGAffineTransform(
                    translationX: (frame.width - bounds.width * factor) / 2,
                    y: (frame.height - bounds.height * factor) / 2
                ))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: outputVideo)
            layer.setTransform(position, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + range.duration
        }
        if let outputAudio, outputAudio.segments.isEmpty {
            composition.removeTrack(outputAudio)
        }
        videoComposition.instructions = instructions
        return Self(asset: composition, videoComposition: videoComposition)
    }

    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        return item
    }

    // Render the same outlined title for the player overlay and the exported movie.
    @MainActor
    static func titleImage(_ text: String, frame: CGSize) -> UIImage {
        let height = min(frame.width, frame.height) * 0.18
        let width = frame.width * 0.9
        let font = UIFont.boldSystemFont(ofSize: height * 0.55)
        let line = NSAttributedString(string: text, attributes: [.font: font])
        let scale = min(1, width / max(1, line.size().width + 8))
        let fitted = UIFont.boldSystemFont(ofSize: font.pointSize * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            let title = NSAttributedString(string: text, attributes: [
                .font: fitted,
                .foregroundColor: UIColor(red: 1, green: 0.855, blue: 0.34, alpha: 1),
                .strokeColor: UIColor.black,
                .strokeWidth: -5
            ])
            let size = title.size()
            title.draw(at: CGPoint(x: (width - size.width) / 2, y: (height - size.height) / 2))
        }
    }

    @MainActor
    private func compositionForExport(titles: [VideoTitle], duration: Double) -> AVVideoComposition {
        guard !titles.isEmpty else { return videoComposition }
        let result = AVMutableVideoComposition()
        result.renderSize = videoComposition.renderSize
        result.frameDuration = videoComposition.frameDuration
        result.instructions = videoComposition.instructions
        let bounds = CGRect(origin: .zero, size: result.renderSize)
        let parent = CALayer()
        let video = CALayer()
        parent.frame = bounds
        video.frame = bounds
        parent.addSublayer(video)

        for title in titles where title.start < duration && title.end > title.start {
            let image = Self.titleImage(title.text, frame: bounds.size)
            let layer = CALayer()
            layer.bounds = CGRect(origin: .zero, size: image.size)
            layer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            layer.contents = image.cgImage
            layer.opacity = 0
            parent.addSublayer(layer)

            let visibility = CAKeyframeAnimation(keyPath: "opacity")
            let start = title.start / duration
            let end = min(title.end / duration, 1)
            var values = [start == 0 ? 1 : 0]
            var times: [NSNumber] = [0]
            if start > 0 {
                values.append(1)
                times.append(NSNumber(value: start))
            }
            if end < 1 {
                values.append(0)
                times.append(NSNumber(value: end))
            }
            values.append(values.last ?? 0)
            times.append(1)
            visibility.values = values
            visibility.keyTimes = times
            visibility.calculationMode = .discrete
            visibility.beginTime = AVCoreAnimationBeginTimeAtZero
            visibility.duration = duration
            visibility.isRemovedOnCompletion = false
            layer.add(visibility, forKey: "visibility")
        }

        result.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        return result
    }

    @MainActor
    func export(titles: [VideoTitle], duration: Double) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else { throw MediaError.cannotExport }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoirsCore-" + UUID().uuidString)
            .appendingPathExtension("mp4")
        session.videoComposition = compositionForExport(titles: titles, duration: duration)
        session.shouldOptimizeForNetworkUse = true
        do {
            if #available(iOS 18.0, *) {
                try await session.export(to: url, as: .mp4)
            } else {
                session.outputURL = url
                session.outputFileType = .mp4
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    session.exportAsynchronously { continuation.resume() }
                }
                guard session.status == .completed else {
                    throw session.error ?? MediaError.cannotExport
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }
}

