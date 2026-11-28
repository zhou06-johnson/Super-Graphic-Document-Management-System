import AVFoundation
import AVKit
import Foundation
import PhotosUI
import SwiftUI
import UIKit

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
    private var previewComposition: MediaComposition?
    private var proxies: [URL: URL] = [:]
    private var checkedProxySources = Set<URL>()
    private var proxyTask: Task<Void, Never>?
    @Published private(set) var proxyEnabled = false
    @Published private(set) var preparingProxies = false
    @Published private(set) var usingProxies = false
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
        proxyTask?.cancel()
        for url in importedFiles.union(outputs).union(proxies.values) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    var videoSize: CGSize { previewComposition?.videoComposition.renderSize ?? .zero }

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

    func applyPlan(
        _ plan: AIEditPlan, assets: [AIEditorAsset], service: AIEditorService, appending: Bool
    ) async -> Bool {
        guard !busy else { return false }
        busy = true
        player.pause()
        var files: [String: URL] = [:]
        var applied = false
        defer {
            busy = false
            if !applied {
                for url in files.values { try? FileManager.default.removeItem(at: url) }
            }
        }
        do {
            var project = appending ? timeline : Timeline()
            let insertionTime = project.duration
            let names = Dictionary(assets.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            for segment in plan.clips {
                let url: URL
                if let local = files[segment.assetID] {
                    url = local
                } else {
                    url = try await service.download(segment.assetID)
                    files[segment.assetID] = url
                }
                let source = AVURLAsset(url: url)
                guard let track = try await source.loadTracks(withMediaType: .video).first else {
                    throw MediaError.unreadable
                }
                let range = try await track.load(.timeRange)
                let start = max(range.start.seconds, segment.start)
                let end = min(range.end.seconds, segment.end)
                guard start.isFinite, end.isFinite, end - start >= Clip.minimumLength - 0.001 else {
                    throw MediaError.cannotCompose
                }
                let generated = segment.generated == true
                project.clips.append(Clip(
                    url: url, name: generated ? "AI 生成画面" : names[segment.assetID] ?? "素材",
                    start: start, end: end, isGenerated: generated
                ))
            }
            if !plan.closingTitle.isEmpty {
                project.titles.append(VideoTitle(
                    text: plan.closingTitle, start: max(0, project.duration - 3), end: project.duration
                ))
            }
            try await install(project, at: insertionTime, muted: appending && muted, remember: true)
            importedFiles.formUnion(files.values)
            applied = true
            return true
        } catch {
            self.error = error.localizedDescription
            return false
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

    func setProxyEnabled(_ enabled: Bool) async {
        guard !busy, proxyEnabled != enabled else { return }
        proxyEnabled = enabled
        if enabled {
            prepareProxies()
        } else {
            cancelProxyPreparation()
            checkedProxySources = Set(proxies.keys)
            await refreshPreview()
        }
    }

    func cancelProxyPreparation() {
        proxyTask?.cancel()
        proxyTask = nil
        preparingProxies = false
    }

    func prepareProxies() {
        guard proxyEnabled, proxyTask == nil else { return }
        let sources = Set(timeline.clips.map(\.url)).subtracting(checkedProxySources)
        let hasCachedProxy = timeline.clips.contains { proxies[$0.url] != nil }
        guard !sources.isEmpty || (!usingProxies && hasCachedProxy) else { return }
        preparingProxies = !sources.isEmpty
        proxyTask = Task { [weak self] in
            for source in sources {
                guard !Task.isCancelled else { return }
                let proxy = try? await MediaComposition.makePreviewProxy(for: source)
                guard !Task.isCancelled, let self else {
                    if let proxy { try? FileManager.default.removeItem(at: proxy) }
                    return
                }
                self.checkedProxySources.insert(source)
                if let proxy { self.proxies[source] = proxy }
            }
            while let self, self.busy || self.player.timeControlStatus != .paused {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.proxyTask = nil
            self.preparingProxies = false
            await self.refreshPreview()
            if !Set(self.timeline.clips.map(\.url)).subtracting(self.checkedProxySources).isEmpty {
                self.prepareProxies()
            }
        }
    }

    private func resolvePreview(_ project: Timeline, original: MediaComposition?, muted: Bool) async -> (MediaComposition?, Bool) {
        guard proxyEnabled, let original, project.clips.contains(where: { proxies[$0.url] != nil }) else {
            return (original, false)
        }
        guard let preview = try? await MediaComposition.build(
            clips: project.clips, muted: muted, previewProxies: proxies,
            previewCanvas: original.videoComposition.renderSize
        ) else {
            return (original, false)
        }
        return (preview, true)
    }

    private func refreshPreview() async {
        guard !busy, let composition else { return }
        busy = true
        defer { busy = false }
        player.pause()
        let (preview, usesProxy) = await resolvePreview(timeline, original: composition, muted: muted)
        guard usesProxy || usingProxies else { return }
        await replacePreview(preview, usesProxy: usesProxy)
    }

    private func replacePreview(_ preview: MediaComposition?, usesProxy: Bool) async {
        previewComposition = preview
        usingProxies = usesProxy
        pendingSeek = nil
        player.replaceCurrentItem(with: preview?.playerItem())
        if preview != nil {
            _ = await player.seek(to: MediaComposition.time(position), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    @discardableResult
    func export() async -> Bool {
        guard !busy, let composition else { return false }
        player.pause()
        busy = true
        defer { busy = false }
        do {
            let file = try await composition.export(
                titles: timeline.titles + timeline.generatedTitles, duration: timeline.duration
            )
            outputs.insert(file)
            exported = file
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
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
        let (preview, usesProxy) = await resolvePreview(candidate, original: next, muted: muted)
        await replacePreview(preview, usesProxy: usesProxy)
        prepareProxies()
    }
}

@MainActor
struct VideoEditorView: View {
    private let onClose: (() -> Void)?
    private let aiService: AIEditorService?
    @StateObject private var store = EditorStore()

    init(baseURL: URL? = nil, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self.aiService = baseURL.map { AIEditorService(baseURL: $0) }
    }

    private enum LibraryMode: String, Identifiable {
        case manual, ai
        var id: String { rawValue }
    }

    @State private var libraryMode: LibraryMode?
    @State private var pendingPreferences: [String] = []
    @AppStorage("memoirscore.aiEditor.preferences") private var storedPreferences = Data()

    private var preferences: [String] {
        (try? JSONDecoder().decode([String].self, from: storedPreferences)) ?? []
    }

    private func rememberAcceptedPreferences() {
        var merged = preferences
        for choice in pendingPreferences {
            merged.removeAll { $0 == choice }
            merged.append(choice)
        }
        storedPreferences = (try? JSONEncoder().encode(Array(merged.suffix(12)))) ?? Data()
        pendingPreferences = []
    }
    @State private var picker: [PhotosPickerItem] = []
    @State private var titleDraft: VideoTitle?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    if store.hasPreview { proxyControls }
                    if titleDraft != nil { titleEditor }
                    timeline
                    if titleDraft == nil {
                        if aiService != nil {
                            Button { libraryMode = .ai } label: {
                                Label("AI 剪辑", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        actions
                    }
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
                    if aiService != nil {
                        Button { libraryMode = .manual } label: {
                            Label("添加素材", systemImage: "plus")
                        }
                        .disabled(store.busy)
                    } else {
                        PhotosPicker(selection: $picker, maxSelectionCount: 12, matching: .videos) {
                            Label("添加视频", systemImage: "plus")
                        }
                        .disabled(store.busy)
                    }
                }
            }
            .overlay {
                if store.busy {
                    ProgressView("正在处理…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onAppear { store.prepareProxies() }
            .onDisappear { store.cancelProxyPreparation() }
            .onChange(of: picker) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    await store.importVideos(items)
                    picker = []
                }
            }
            .sheet(item: $libraryMode) { mode in
                if let aiService {
                    LibraryEditSheet(service: aiService, preferences: preferences, manual: mode == .manual) { plan, assets in
                        if await store.applyPlan(plan, assets: assets, service: aiService, appending: mode == .manual) {
                            if mode == .ai { pendingPreferences = plan.preferences }
                            libraryMode = nil
                            return nil
                        }
                        let message = store.error ?? "无法载入所选素材。"
                        store.error = nil
                        return message
                    }
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
                ContentUnavailableView(aiService == nil ? "添加视频开始剪辑" : "从图库添加照片或视频", systemImage: "film")
                    .foregroundStyle(.white)
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var proxyControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("流畅预览", isOn: Binding(
                get: { store.proxyEnabled },
                set: { enabled in Task { await store.setProxyEnabled(enabled) } }
            ))
            if store.proxyEnabled {
                Text(store.preparingProxies
                     ? "正在准备代理，当前仍可剪辑。"
                     : store.usingProxies ? "正在使用代理预览 · 导出使用原素材"
                     : "当前使用原素材预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var titlePreview: some View {
        GeometryReader { geometry in
            let size = store.videoSize
            if size.width > 0, size.height > 0 {
                let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                let titles = (store.timeline.titles + store.timeline.generatedTitles).filter {
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
            action("导出 MP4", "square.and.arrow.down", enabled: store.hasPreview) {
                if await store.export() { rememberAcceptedPreferences() }
            }
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


struct AIEditorAsset: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let kind: String
    let start: Double
    let end: Double
    let labels: Labels?
    let hasThumbnail: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, status, kind, start, end, labels
        case hasThumbnail = "has_thumbnail"
    }

    struct Labels: Decodable {
        let summary: String?
        let tags: [String]?
    }

    var detail: String {
        if let tags = labels?.tags, !tags.isEmpty { return tags.joined(separator: " · ") }
        if status == "analyzing" { return "正在分析" }
        if status == "unavailable" { return "标签暂不可用" }
        if status == "local" || status == "pending" { return "待补充 AI 标签" }
        return labels?.summary ?? "已导入"
    }
}

struct AIEditPlan: Decodable {
    struct Segment: Decodable {
        let assetID: String
        let start: Double
        let end: Double
        let generated: Bool?

        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case start, end, generated
        }
    }

    let clips: [Segment]
    let closingTitle: String
    let preferences: [String]

    enum CodingKeys: String, CodingKey {
        case clips, preferences
        case closingTitle = "closing_title"
    }
}

struct AIEditorService {
    let baseURL: URL

    private struct ServerError: Decodable { let detail: String }
    private struct PlanRequest: Encodable {
        let prompt: String
        let required: [String]
        let only_required: Bool
        let allow_generated: Bool
        let preferences: [String]
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        let endpoint = path.split(separator: "/").reduce(baseURL) {
            $0.appendingPathComponent(String($1))
        }
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        if !query.isEmpty { url?.queryItems = query }
        var request = URLRequest(url: url?.url ?? endpoint, timeoutInterval: 240)
        request.httpMethod = method
        return request
    }

    private func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.detail
            throw NSError(domain: "MemoirsCore.AIEditor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message ?? "无法访问剪辑服务，请检查后端连接。"
            ])
        }
    }

    func assets() async throws -> [AIEditorAsset] {
        let (data, response) = try await URLSession.shared.data(for: request("api/ai-editor/assets"))
        try validate(response, data: data)
        return try JSONDecoder().decode([AIEditorAsset].self, from: data)
    }

    func reindex() async throws {
        let (data, response) = try await URLSession.shared.data(for: request("api/ai-editor/assets/reindex", method: "POST"))
        try validate(response, data: data)
    }

    func makePlan(
        prompt: String, required: Set<String>, onlyRequired: Bool, allowGenerated: Bool, preferences: [String]
    ) async throws -> AIEditPlan {
        var request = request("api/ai-editor/plan", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PlanRequest(
            prompt: prompt, required: required.sorted(), only_required: onlyRequired,
            allow_generated: allowGenerated, preferences: preferences
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(AIEditPlan.self, from: data)
    }

    func thumbnail(_ id: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request("api/ai-editor/assets/\(id)/thumbnail"))
        try validate(response, data: data)
        return data
    }

    func download(_ id: String) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(for: request("api/ai-editor/assets/\(id)/video"))
        try validate(response, data: (response as? HTTPURLResponse).map {
            (200..<300).contains($0.statusCode) ? Data() : (try? Data(contentsOf: file)) ?? Data()
        } ?? Data())
        let ext = response.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext?.isEmpty == false ? (ext ?? "mp4") : "mp4")
        try FileManager.default.moveItem(at: file, to: local)
        return local
    }
}

@MainActor
private struct LibraryEditSheet: View {
    let service: AIEditorService
    let preferences: [String]
    let manual: Bool
    let apply: (AIEditPlan, [AIEditorAsset]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var assets: [AIEditorAsset] = []
    @State private var selected: [String] = []
    @State private var onlyRequired = false
    @State private var allowGenerated = false
    @State private var choosing = false
    @State private var working = false
    @State private var message: String?


    var body: some View {
        NavigationStack {
            Form {
                if !manual {
                    Section("你想剪一段怎样的视频？") {
                        TextField("例如：把最近在杭州拍的剪成旅行回忆", text: $prompt, axis: .vertical)
                            .lineLimit(3...5)
                    }
                }
                Section("素材") {
                    Text("从 MemoirsCore 图库选择。需要添加内容时，请到图库点加号。")
                        .font(.footnote)
                    DisclosureGroup(isExpanded: Binding(
                        get: { manual || choosing },
                        set: { choosing = $0 }
                    )) {
                        if assets.isEmpty { Text("图库暂无素材。") }
                        ForEach(assets) { asset in
                            Toggle(isOn: Binding(
                                get: { selected.contains(asset.id) },
                                set: { include in
                                    if include {
                                        if selected.count < 24 { selected.append(asset.id) }
                                    } else {
                                        selected.removeAll { $0 == asset.id }
                                    }
                                }
                            )) {
                                HStack {
                                    AIAssetThumbnail(asset: asset, service: service)
                                    VStack(alignment: .leading) {
                                        Text(asset.name)
                                        Text(manual ? (asset.kind == "photo" ? "照片" : "视频") : asset.detail)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if !manual {
                            Toggle("只用我选的素材", isOn: $onlyRequired)
                                .disabled(selected.isEmpty)
                        }
                    } label: {
                        if selected.isEmpty {
                            Text("选择素材")
                        } else {
                            Text(manual ? "已选 \(selected.count) 项" : "已选 \(selected.count) 项，都会用到")
                        }
                    }
                    if !manual {
                        Toggle("允许 AI 补过渡画面", isOn: $allowGenerated)
                            .disabled(onlyRequired && !selected.isEmpty)
                        Button("补充并刷新标签") {
                            Task {
                                do {
                                    try await service.reindex()
                                    await refresh()
                                } catch { message = error.localizedDescription }
                            }
                        }
                    }
                }
                Section {
                    Button(manual ? "添加到时间轴" : "生成视频") { Task { await generate() } }
                        .disabled(manual ? selected.isEmpty : prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if working { ProgressView("正在处理…") }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            }
            .disabled(working)
            .navigationTitle(manual ? "从图库添加素材" : "AI 剪辑")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }.disabled(working)
                }
            }
            .interactiveDismissDisabled(working)
            .task {
                await refresh()
                while !manual && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    if !working, assets.contains(where: { $0.status == "analyzing" }) {
                        await refresh()
                    }
                }
            }

        }
    }

    private func refresh() async {
        do { assets = try await service.assets() }
        catch { if !Task.isCancelled { message = error.localizedDescription } }
    }

    private func generate() async {
        working = true
        message = nil
        defer { working = false }
        do {
            let plan: AIEditPlan
            if manual {
                let indexed = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let clips = selected.compactMap { id -> AIEditPlan.Segment? in
                    guard let item = indexed[id], item.end > item.start else { return nil }
                    return AIEditPlan.Segment(assetID: id, start: item.start, end: item.end, generated: nil)
                }
                guard clips.count == selected.count, !clips.isEmpty else {
                    message = "所选素材已变更，请重新选择。"
                    return
                }
                plan = AIEditPlan(clips: clips, closingTitle: "", preferences: [])
            } else {
                plan = try await service.makePlan(
                    prompt: prompt, required: Set(selected), onlyRequired: onlyRequired && !selected.isEmpty,
                    allowGenerated: allowGenerated, preferences: preferences
                )
            }
            message = await apply(plan, assets)
        } catch { message = error.localizedDescription }
    }
}


@MainActor
private struct AIAssetThumbnail: View {
    let asset: AIEditorAsset
    let service: AIEditorService
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 56, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: asset.hasThumbnail) {
            guard asset.hasThumbnail == true,
                  let data = try? await service.thumbnail(asset.id),
                  !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
    }
}
