import AVFoundation
import CoreGraphics
import Foundation

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

    func export() async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else { throw MediaError.cannotExport }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoirsCore-" + UUID().uuidString)
            .appendingPathExtension("mp4")
        session.videoComposition = videoComposition
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

