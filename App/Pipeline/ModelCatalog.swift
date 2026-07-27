import Foundation
import InkfallCore
import Observation

/// 本地模型的下载状态与操作，托盘菜单和设置页共用一份。
///
/// 状态的真相在磁盘上（下没下、占多大），所以这里只做缓存 + 显式刷新，
/// 不做长期持有 —— 用户可能在访达里把权重删了。
@MainActor
@Observable
final class ModelCatalog {

    struct Entry: Identifiable {
        let model: LocalModelDefinition
        var downloaded: Bool
        var bytes: Int64
        /// 0…1，仅下载中非 nil。
        var progress: Double?

        var id: String { model.id }
        var sizeText: String {
            downloaded
                ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                : model.sizeLabel
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var busy: String?
    private(set) var lastError: String?

    /// 分离模型（Pyannote）。它跟 Whisper 完全独立 —— 一共 11 MB，
    /// 所以单列一栏，而不是混进转写档位里让人以为要二选一。
    private(set) var diarization = DiarizationState()

    struct DiarizationState {
        var downloaded = false
        var bytes: Int64 = 0
        var progress: Double?

        var sizeText: String {
            downloaded
                ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                : "~11 MB"
        }
    }

    static let diarizationID = "speaker-diarization"

    private let store: SettingsStore
    private let transcriber: LocalTranscriber

    init(store: SettingsStore, transcriber: LocalTranscriber) {
        self.store = store
        self.transcriber = transcriber
        refresh()
    }

    var selectedID: String { store.settings.selectedLocalModelId }
    var selected: Entry? { entries.first { $0.id == selectedID } }

    /// 按磁盘现状重建。每次展开菜单/打开设置页都调 —— 缓存了就会骗人。
    func refresh() {
        diarization = DiarizationState(
            downloaded: LocalTranscriber.isDiarizationDownloaded,
            bytes: LocalTranscriber.diarizationBytes,
            progress: diarization.progress)
        entries = LocalModels.all.map { model in
            let downloaded = LocalTranscriber.isDownloaded(model)
            return Entry(model: model,
                         downloaded: downloaded,
                         bytes: downloaded ? LocalTranscriber.diskBytes(model) : 0,
                         progress: entries.first { $0.id == model.id }?.progress)
        }
    }

    // MARK: - 操作

    /// 切换在用的模型。
    ///
    /// 必须把旧的卸掉再预热新的 —— 否则 1.5 GB 的 turbo 会和新模型一起赖在内存里。
    func select(_ id: String) {
        guard id != selectedID, LocalModels.definition(id: id) != nil else { return }
        store.settings.selectedLocalModelId = id
        store.save()
        Log.write("model: 切换到 \(id)")
        refresh()

        Task { [transcriber] in
            await transcriber.unload()
            guard let model = LocalModels.definition(id: id),
                  LocalTranscriber.isDownloaded(model) else { return }
            await transcriber.prewarm(modelID: id)
        }
    }

    func download(_ id: String) {
        guard busy == nil, let model = LocalModels.definition(id: id) else { return }
        busy = id
        lastError = nil
        setProgress(id, 0)

        Task { [transcriber] in
            do {
                try await LocalTranscriber.download(model) { fraction in
                    Task { @MainActor in self.setProgress(id, fraction) }
                }
                self.finishDownload(id, error: nil)
                if id == self.selectedID { await transcriber.prewarm(modelID: id) }
            } catch {
                self.finishDownload(id, error: error)
            }
        }
    }

    func delete(_ id: String) {
        guard busy == nil, let model = LocalModels.definition(id: id) else { return }
        Task { [transcriber] in
            do {
                try await transcriber.delete(model)
                Log.write("model: 已删除 \(id) 的权重")
            } catch {
                self.lastError = error.localizedDescription
                Log.write("model: 删除失败 \(error)")
            }
            self.refresh()
        }
    }

    // MARK: - 分离模型

    func downloadDiarization() {
        guard busy == nil else { return }
        busy = Self.diarizationID
        lastError = nil
        diarization.progress = 0

        Task { [transcriber] in
            do {
                try await LocalTranscriber.downloadDiarization { fraction in
                    Task { @MainActor in self.diarization.progress = fraction }
                }
                self.busy = nil
                self.diarization.progress = nil
                self.refresh()
                await transcriber.prewarmDiarization()
            } catch {
                self.busy = nil
                self.diarization.progress = nil
                self.lastError = error.localizedDescription
                Log.write("diarize: 下载失败 \(error)")
                self.refresh()
            }
        }
    }

    func deleteDiarization() {
        guard busy == nil else { return }
        Task { [transcriber] in
            do {
                try await transcriber.deleteDiarization()
                Log.write("diarize: 已删除分离模型权重")
            } catch {
                self.lastError = error.localizedDescription
            }
            self.refresh()
        }
    }

    /// 开关「区分人物」。开的时候权重还没下就顺手下 ——
    /// 打开一个开关之后什么都没发生是最糟的反馈。
    func setDiarizationEnabled(_ on: Bool) {
        store.settings.noteSpeakerDiarizationEnabled = on
        store.save()
        guard on else { return }
        if diarization.downloaded {
            Task { [transcriber] in await transcriber.prewarmDiarization() }
        } else {
            downloadDiarization()
        }
    }

    var diarizationEnabled: Bool { store.settings.noteSpeakerDiarizationEnabled }

    private func setProgress(_ id: String, _ fraction: Double) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].progress = fraction
    }

    private func finishDownload(_ id: String, error: Error?) {
        busy = nil
        if let error {
            lastError = error.localizedDescription
            Log.write("model: 下载失败 \(error)")
        }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].progress = nil
        }
        refresh()
    }
}
