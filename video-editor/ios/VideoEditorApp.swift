import AVFoundation
import AVKit
import Foundation
import PhotosUI
import SwiftUI

#if !MEMOIRSCORE_HOST
@main
struct VideoEditorApp: App {
    var body: some Scene {
        WindowGroup { VideoEditorView() }
    }
}

#endif

@MainActor
final class EditorStore: ObservableObject {
    @Published private(set) var timeline = Timeline()
    @Published private(set) var selected: UUID?
    @Published private(set) var position = 0.0
    @Published private(set) var muted = false
    @Published private(set) var busy = false
    @Published private(set) var canUndo = false
    @Published private(set) var hasPreview = false
    @Published private(set) var exported: URL?
    @Published var error: String?

    let player = AVPlayer()
    private var composition: MediaComposition?
    private var history: [Timeline] = []
    private var observer: Any?
    private var pendingSeek: UUID?
    private var importedFiles = Set<URL>()
    private var outputs = Set<URL>()

    init() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 15), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy, self.pendingSeek == nil, self.hasPreview else { return }
                let time = self.player.currentTime().seconds
                guard time.isFinite else { return }
                let position = min(max(0, time), self.timeline.duration)
                guard abs(position - self.position) > 0.001 else { return }
                self.position = position
                self.selected = self.timeline.clip(at: position)?.id
            }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        for url in importedFiles.union(outputs) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    var videoSize: CGSize { composition?.videoComposition.renderSize ?? .zero }

    var canSplit: Bool { timeline.splitOffset(id: selected, at: position) != nil }
    var selectedIndex: Int? { timeline.clips.firstIndex { $0.id == selected } }

    func importVideos(_ items: [PhotosPickerItem]) async {
        guard !busy, !items.isEmpty else { return }
        busy = true
        player.pause()
        var candidate = timeline
        var staged = Set<URL>()
        defer {
            busy = false
            for url in staged.subtracting(importedFiles) { try? FileManager.default.removeItem(at: url) }
        }
        do {
            let oldDuration = candidate.duration
            for item in items {
                guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                    throw MediaError.unreadable
                }
                staged.insert(movie.url)
                let asset = AVURLAsset(url: movie.url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw MediaError.unreadable
                }
                let sourceRange = try await track.load(.timeRange)
                let start = max(0, sourceRange.start.seconds)
                let end = sourceRange.end.seconds
                guard start.isFinite, end.isFinite, end - start >= Clip.minimumLength else {
                    throw MediaError.unreadable
                }
                candidate.clips.append(Clip(url: movie.url, name: "片段 \(candidate.clips.count + 1)", start: start, end: end))
            }
            try await install(candidate, at: oldDuration, muted: muted, remember: true)
            importedFiles.formUnion(staged)
        } catch { self.error = error.localizedDescription }
    }

    func seek(_ seconds: Double, select: Bool = true) {
        guard !busy, hasPreview, seconds.isFinite else { return }
        player.pause()
        position = min(max(0, seconds), timeline.duration)
        if select { selected = timeline.clip(at: position)?.id }
        let request = UUID()
        pendingSeek = request
        player.seek(to: MediaComposition.time(position), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingSeek == request else { return }
                self.pendingSeek = nil
            }
        }
    }

    func select(_ clip: Clip) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        seek(timeline.start(of: index), select: false)
        selected = clip.id
    }

    func split() async {
        var candidate = timeline
        guard let id = candidate.split(id: selected, at: position) else { return }
        await edit(candidate, at: position, selection: id)
    }

    func delete() async {
        guard let index = selectedIndex else { return }
        let start = timeline.start(of: index)
        var candidate = timeline
        candidate.clips.remove(at: index)
        let duration = candidate.duration
        candidate.titles.removeAll { $0.start >= duration }
        for index in candidate.titles.indices {
            candidate.titles[index].end = min(candidate.titles[index].end, duration)
        }
        await edit(candidate, at: start)
    }

    func move(by offset: Int) async {
        guard let selected else { return }
        var candidate = timeline
        guard let start = candidate.move(id: selected, by: offset) else { return }
        await edit(candidate, at: start, selection: selected)
    }

    func undo() async {
        guard !busy, let previous = history.last else { return }
        busy = true
        defer { busy = false }
        do {
            try await install(previous, at: position, muted: muted, remember: false)
            history.removeLast()
            canUndo = !history.isEmpty
        } catch { self.error = error.localizedDescription }
    }

    func toggleMute() async {
        guard !busy, hasPreview else { return }
        busy = true
        defer { busy = false }
        do { try await install(timeline, at: position, muted: !muted, remember: false, selection: selected) }
        catch { self.error = error.localizedDescription }
    }

    func updateTitle(_ title: VideoTitle, deleting: Bool = false) {
        guard !busy, hasPreview else { return }
        if deleting {
            guard timeline.titles.contains(where: { $0.id == title.id }) else { return }
        } else {
            guard title.start >= 0, title.end > title.start, title.end <= timeline.duration,
                  !title.text.isEmpty else { return }
        }
        rememberTimeline()
        if deleting {
            timeline.titles.removeAll { $0.id == title.id }
        } else if let index = timeline.titles.firstIndex(where: { $0.id == title.id }) {
            timeline.titles[index] = title
        } else {
            timeline.titles.append(title)
        }
        exported = nil
        if !deleting { seek(title.start) }
    }

    private func rememberTimeline() {
        history.append(timeline)
        if history.count > 30 { history.removeFirst() }
        canUndo = true
    }

    func export() async {
        guard !busy, let composition else { return }
        player.pause()
        busy = true
        defer { busy = false }
        do {
            let file = try await composition.export(titles: timeline.titles, duration: timeline.duration)
            outputs.insert(file)
            exported = file
        } catch { self.error = error.localizedDescription }
    }

    private func edit(_ candidate: Timeline, at seconds: Double, selection: UUID? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await install(candidate, at: seconds, muted: muted, remember: true, selection: selection) }
        catch { self.error = error.localizedDescription }
    }

    private func install(
        _ candidate: Timeline, at seconds: Double, muted: Bool, remember: Bool, selection: UUID? = nil
    ) async throws {
        player.pause()
        let next = candidate.clips.isEmpty ? nil : try await MediaComposition.build(clips: candidate.clips, muted: muted)
        if remember { rememberTimeline() }
        canUndo = !history.isEmpty
        timeline = candidate
        composition = next
        hasPreview = next != nil
        self.muted = muted
        exported = nil
        position = min(max(0, seconds), candidate.duration)
        selected = selection ?? candidate.clip(at: position)?.id
        pendingSeek = nil
        player.replaceCurrentItem(with: next?.playerItem())
        if next != nil {
            _ = await player.seek(to: MediaComposition.time(position), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
}

@MainActor
struct VideoEditorView: View {
    private let onClose: (() -> Void)?
    @StateObject private var store = EditorStore()

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }
    @State private var picker: [PhotosPickerItem] = []
    @State private var titleDraft: VideoTitle?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    if titleDraft != nil { titleEditor }
                    timeline
                    if titleDraft == nil { actions }
                    if let file = store.exported {
                        ShareLink(item: file) {
                            Label("分享或保存 MP4", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .disabled(store.busy)
            }
            .navigationTitle("视频剪辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回") {
                            store.player.pause()
                            onClose()
                        }
                        .disabled(store.busy)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $picker, maxSelectionCount: 12, matching: .videos) {
                        Label("添加视频", systemImage: "plus")
                    }
                    .disabled(store.busy)
                }
            }
            .overlay {
                if store.busy {
                    ProgressView("正在处理…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: picker) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    await store.importVideos(items)
                    picker = []
                }
            }
            .alert("处理失败", isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            )) {
                Button("好") { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if store.hasPreview {
                VideoPlayer(player: store.player)
                    .overlay { titlePreview.allowsHitTesting(false) }
            } else {
                ContentUnavailableView("添加视频开始剪辑", systemImage: "film")
                    .foregroundStyle(.white)
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var titlePreview: some View {
        GeometryReader { geometry in
            let size = store.videoSize
            if size.width > 0, size.height > 0 {
                let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                let titles = store.timeline.titles.filter {
                    $0.id != titleDraft?.id && $0.contains(store.position)
                }
                ZStack {
                    ForEach(titles) { title in
                        previewTitle(title.text, frame: size, scale: scale)
                    }
                    if let draft = titleDraft {
                        previewTitle(draft.text.isEmpty ? "输入文字…" : draft.text, frame: size, scale: scale)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func previewTitle(_ text: String, frame: CGSize, scale: CGFloat) -> some View {
        let image = MediaComposition.titleImage(text, frame: frame)
        return Image(uiImage: image)
            .resizable()
            .frame(width: image.size.width * scale, height: image.size.height * scale)
    }

    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("输入文字", text: Binding(
                get: { titleDraft?.text ?? "" },
                set: { titleDraft?.text = String($0.prefix(30)) }
            ))
            .textFieldStyle(.roundedBorder)
            HStack {
                titleTimeField("开始（秒）", at: \.start)
                titleTimeField("结束（秒）", at: \.end)
            }
            HStack {
                Button("取消") { titleDraft = nil }
                Button("保存文字") {
                    guard var draft = titleDraft, validTitle(draft) else { return }
                    draft.text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.updateTitle(draft)
                    titleDraft = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(titleDraft.map { !validTitle($0) } ?? true)
                if let draft = titleDraft, store.timeline.titles.contains(where: { $0.id == draft.id }) {
                    Button("删除文字", role: .destructive) {
                        store.updateTitle(draft, deleting: true)
                        titleDraft = nil
                    }
                }
            }
            if let draft = titleDraft, !validTitle(draft) {
                Text("请输入文字，并设置项目时长内的起止时间。").font(.caption)
            }
        }
    }

    private func validTitle(_ title: VideoTitle) -> Bool {
        !title.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            title.start >= 0 && title.end > title.start && title.end <= store.timeline.duration
    }

    private func titleTimeField(_ label: String, at keyPath: WritableKeyPath<VideoTitle, Double>) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption)
            TextField(label, value: Binding(
                get: { titleDraft?[keyPath: keyPath] ?? 0 },
                set: { titleDraft?[keyPath: keyPath] = $0 }
            ), format: .number.precision(.fractionLength(0...3)))
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时间轴").font(.headline)
                Spacer()
                Text("\(store.position.formatted(.number.precision(.fractionLength(2)))) / \(store.timeline.duration.formatted(.number.precision(.fractionLength(2)))) 秒")
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { store.position }, set: { store.seek($0) }),
                   in: 0...max(0.01, store.timeline.duration))
                .accessibilityLabel("播放位置")
                .disabled(!store.hasPreview)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(store.timeline.clips) { clip in
                        Button {
                            store.select(clip)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(clip.name).fontWeight(.semibold)
                                Text(clip.duration, format: .number.precision(.fractionLength(2))) + Text(" 秒")
                            }
                            .lineLimit(1)
                            .padding(10)
                            .frame(minWidth: 90, alignment: .leading)
                            .background(store.selected == clip.id ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.selected == clip.id ? .isSelected : [])
                    }
                }
            }
            if store.hasPreview && !store.timeline.titles.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.timeline.titles) { title in
                            Button {
                                editTitle(title)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(title.text).lineLimit(1)
                                    Text("\(title.start.formatted(.number.precision(.fractionLength(2))))–\(title.end.formatted(.number.precision(.fractionLength(2)))) 秒")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                        }
                    }
                }
                .accessibilityLabel("文字轨道")
            }
        }
    }

    private func editTitle(_ title: VideoTitle) {
        store.seek(title.start)
        titleDraft = title
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 102))], spacing: 10) {
            action("添加文字", "textformat", enabled: store.hasPreview) {
                let start = min(store.position, max(0, store.timeline.duration - Clip.minimumLength))
                editTitle(VideoTitle(text: "", start: start, end: min(start + 3, store.timeline.duration)))
            }
            action("分割", "scissors", enabled: store.canSplit) { await store.split() }
            action("删除", "trash", enabled: store.selected != nil) { await store.delete() }
            action("前移", "arrow.left", enabled: (store.selectedIndex ?? 0) > 0) { await store.move(by: -1) }
            action("后移", "arrow.right", enabled: store.selectedIndex.map { $0 + 1 < store.timeline.clips.count } ?? false) { await store.move(by: 1) }
            action("撤销", "arrow.uturn.backward", enabled: store.canUndo) { await store.undo() }
            action(store.muted ? "开启原声" : "关闭原声", store.muted ? "speaker.wave.2" : "speaker.slash", enabled: store.hasPreview) { await store.toggleMute() }
            action("导出 MP4", "square.and.arrow.down", enabled: store.hasPreview) { await store.export() }
        }
    }

    private func action(_ title: String, _ icon: String, enabled: Bool, run: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await run() }
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
}

