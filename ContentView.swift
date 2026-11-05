import Photos
import PhotosUI
import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var model = LivePhotoViewModel()
    @State private var showingPicker = false
    @State private var playbackID = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Group {
                        if let livePhoto = model.livePhoto {
                            LivePhotoPreview(photo: livePhoto, playbackID: playbackID)
                        } else {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color.accentColor.opacity(0.08))
                                .overlay {
                                    VStack(spacing: 14) {
                                        Image(systemName: "livephoto")
                                            .font(.system(size: 56))
                                        Text("حوّل لحظتك إلى صورة حية")
                                            .font(.headline)
                                        Text("فيديو • صورة حية • صورة متحركة")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding()
                                }
                        }
                    }
                    .aspectRatio(1284.0 / 2778.0, contentMode: .fit)
                    .frame(maxWidth: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .accessibilityLabel("معاينة الصورة الحية؛ اضغط مطولاً لتشغيلها")

                    if model.isBusy {
                        ProgressView(value: model.progress)
                            .accessibilityLabel("تقدم المعالجة")
                    }

                    Text(model.status)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.updatesFrequently)

                    Button {
                        showingPicker = true
                    } label: {
                        Label("اختيار الوسائط من الصور", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)

                    if model.livePhoto != nil {
                        Button {
                            playbackID = UUID()
                        } label: {
                            Label("تشغيل المعاينة", systemImage: "play.fill")
                        }
                        .disabled(model.isBusy)
                    }

                    Button {
                        Task { await model.save() }
                    } label: {
                        Label(model.hasSaved ? "تم الحفظ في الصور" : "حفظ الصورة الحية في الصور",
                              systemImage: model.hasSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.livePhoto == nil || model.hasSaved)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("إعدادات التحويل")
                            .font(.headline)
                        Text("مدة من ثانية إلى ٣ ثوانٍ • ٣٠ إطاراً في الثانية • ترميز HEVC • دون صوت. تُكرر المقاطع القصيرة لإكمال ثانية، ويُدمج آخر ٠٫٢ ثانية تدريجياً مع الإطار الأول لتخفيف الانتقال إلى البداية. تُقص الأطراف لتناسب شاشة آيفون ١٤ بلس، ويصبح الإطار الأول الصورة الثابتة.")
                        Text("لتعيين الخلفية: الإعدادات ← خلفية الشاشة ← إضافة خلفية جديدة ← الصور ← الصور الحية، ثم فعّل الحركة إذا أتاحها النظام.")
                        Text("في آي أو إس ١٧ والأحدث تعمل حركة الخلفية عند إيقاظ الشاشة. قبول الصورة كخلفية متحركة يحدده النظام، وقد يرفض الحركة رغم صلاحية الصورة الحية في تطبيق الصور.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("صور حية")
            .sheet(isPresented: $showingPicker) {
                MediaPicker(onPick: { result in
                    showingPicker = false
                    Task { await model.importAndConvert(result) }
                }, onImportStarted: { model.beginImport() })
                .ignoresSafeArea()
            }
            .alert("تنبيه", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("حسناً", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "ar"))
    }
}

@MainActor
final class LivePhotoViewModel: ObservableObject {
    @Published var livePhoto: PHLivePhoto?
    @Published var isBusy = false
    @Published var progress = 0.0
    @Published var hasSaved = false
    @Published var status = "اختر فيديو أو صورة متحركة للبدء."
    @Published var errorMessage: String?
    private var resources: LivePhotoResources?
    private var isImporting = false

    func beginImport() {
        isImporting = true
        isBusy = true
        progress = 0
        status = "جارٍ استيراد الوسائط…"
    }

    func importAndConvert(_ result: Result<URL, Error>) async {
        guard isImporting || !isBusy else { return }
        isImporting = false
        isBusy = false
        let sourceURL: URL
        switch result {
        case .failure(let error):
            status = "تعذّر استيراد الوسائط. يمكنك المحاولة مجدداً."
            errorMessage = arabicMessage(error, fallback:
                "تعذّر استيراد الوسائط. تأكد من اتصالك بالإنترنت إذا كانت محفوظة في آي كلاود، ثم حاول مجدداً.")
            return
        case .success(let url): sourceURL = url
        }
        isBusy = true
        progress = 0
        hasSaved = false
        status = "جارٍ تحويل الوسائط إلى صورة حية…"
        livePhoto = nil
        removeResources()
        defer {
            isBusy = false
            try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
        }
        do {
            let output = try await LivePhotoConverter().convert(sourceURL: sourceURL) { value in
                Task { @MainActor [weak self] in self?.progress = value }
            }
            resources = output
            livePhoto = try await PhotoLibraryService.preview(output)
            progress = 1
            status = "المعاينة جاهزة. اضغط مطولاً عليها لتشغيل الحركة، ثم احفظها في الصور."
        } catch {
            removeResources()
            status = "لم يكتمل التحويل. يمكنك اختيار ملف آخر."
            errorMessage = arabicMessage(error, fallback:
                "تعذّر تحويل الوسائط. جرّب فيديو أو صورة متحركة أخرى، وتأكد من توفر مساحة كافية على الجهاز.")
        }
    }

    func save() async {
        guard !isBusy, !hasSaved, let resources, livePhoto != nil else { return }
        isBusy = true
        status = "جارٍ الحفظ في تطبيق الصور…"
        defer { isBusy = false }
        do {
            try await PhotoLibraryService.save(resources)
            hasSaved = true
            status = "تم حفظ الصورة الحية. افتح إعدادات الخلفية لاختيارها وتجربة الحركة."
        } catch {
            status = "تعذّر الحفظ. يمكنك إعادة المحاولة."
            errorMessage = arabicMessage(error, fallback:
                "تعذّر حفظ الصورة الحية. تحقق من إذن الإضافة إلى الصور والمساحة المتاحة، ثم حاول مجدداً.")
        }
    }

    private func arabicMessage(_ error: Error, fallback: String) -> String {
        if let error = error as? ConversionError { return error.errorDescription ?? fallback }
        if let error = error as? ImportError { return error.errorDescription ?? fallback }
        return fallback
    }

    private func removeResources() {
        if let resources { try? FileManager.default.removeItem(at: resources.directory) }
        resources = nil
    }
}

private struct LivePhotoPreview: UIViewRepresentable {
    let photo: PHLivePhoto
    let playbackID: UUID

    final class Coordinator {
        var lastPlaybackID: UUID?
        var lastPhoto: PHLivePhoto?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        let photoChanged = context.coordinator.lastPhoto !== photo
        if photoChanged {
            context.coordinator.lastPhoto = photo
            view.livePhoto = photo
        }
        if photoChanged || context.coordinator.lastPlaybackID != playbackID {
            context.coordinator.lastPlaybackID = playbackID
            view.startPlayback(with: .full)
        }
    }
}
