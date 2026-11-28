import AVFoundation
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "mov" : ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}

struct SpeechSubtitle: Decodable, Identifiable {
    private(set) var id = UUID()
    let start: Double
    let end: Double
    let text: String

    enum CodingKeys: String, CodingKey {
        case start, end, text
    }
}

struct Clip: Identifiable {
    static let minimumLength = 0.15

    var id = UUID()
    let url: URL
    let name: String
    var start: Double
    var end: Double
    var isGenerated = false
    var subtitles: [SpeechSubtitle] = []

    var duration: Double { end - start }
}

struct VideoTitle: Identifiable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
    var isSubtitle = false

    func contains(_ position: Double) -> Bool {
        start <= position && position < end
    }
}

struct Timeline {
    var clips: [Clip] = []
    var titles: [VideoTitle] = []

    var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    var generatedTitles: [VideoTitle] {
        var position = 0.0
        var labels: [VideoTitle] = []
        for clip in clips {
            let end = position + clip.duration
            if clip.isGenerated {
                labels.append(VideoTitle(id: clip.id, text: "AI 生成画面", start: position, end: end))
            }
            position = end
        }
        return labels
    }

    var subtitles: [VideoTitle] {
        var position = 0.0
        var labels: [VideoTitle] = []
        for clip in clips {
            for line in clip.subtitles {
                let start = max(clip.start, line.start)
                let end = min(clip.end, line.end)
                if end - start >= 0.15 {
                    labels.append(VideoTitle(id: line.id, text: line.text,
                                             start: position + start - clip.start,
                                             end: position + end - clip.start, isSubtitle: true))
                }
            }
            position += clip.duration
        }
        return labels
    }

    func start(of index: Int) -> Double {
        clips.prefix(index).reduce(0) { $0 + $1.duration }
    }

    func clip(at seconds: Double) -> Clip? {
        var end = 0.0
        for clip in clips {
            end += clip.duration
            if seconds < end { return clip }
        }
        return clips.last
    }

    func splitOffset(id: UUID?, at seconds: Double) -> Double? {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        let offset = seconds - start(of: index)
        guard offset >= Clip.minimumLength,
              clips[index].duration - offset >= Clip.minimumLength else { return nil }
        return offset
    }

    mutating func split(id: UUID?, at seconds: Double) -> UUID? {
        guard let offset = splitOffset(id: id, at: seconds),
              let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        var right = clips[index]
        right.id = UUID()
        right.start += offset
        clips[index].end = right.start
        clips.insert(right, at: index + 1)
        return right.id
    }

    mutating func move(id: UUID, by offset: Int) -> Double? {
        guard let index = clips.firstIndex(where: { $0.id == id }),
              clips.indices.contains(index + offset) else { return nil }
        let clip = clips.remove(at: index)
        clips.insert(clip, at: index + offset)
        return start(of: index + offset)
    }
}

