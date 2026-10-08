import SwiftUI
import UniformTypeIdentifiers

/// The file browser: a grid of embedded previews, none of which needs a RAW decode.
struct GalleryView: View {
    @Environment(Library.self) private var library
    @State private var isImporting = false
    @State private var path: [RawItem] = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12, pinnedViews: []) {
                    if !library.imported.isEmpty {
                        section("Imported", items: library.imported)
                    }
                    section(
                        "Both decoders open this", items: library.shared,
                        footnote: "Switch between Apple and Fallback, then between Decoder, Neutral and Film: their own outputs differ, and the shared rendering brings them together.")
                    section(
                        "Apple's decoder can't open these", items: library.samples,
                        footnote: "Bundled CC0 samples from raw.pixls.us. Each one fails in Apple's RAW engine on this OS and opens through the fallback.")
                }
                .padding()
            }
            .navigationTitle("RAW Input")
            .navigationDestination(for: RawItem.self) { DetailView(item: $0) }
            .toolbar {
                Button("Import", systemImage: "square.and.arrow.down") { isImporting = true }
            }
            .onAppear {
                // `-openSample 3` on the command line opens the third sample directly, which
                // is how the README's screenshots are scripted (simctl cannot tap).
                let index = UserDefaults.standard.integer(forKey: "openSample")
                if path.isEmpty, library.samples.indices.contains(index - 1) {
                    path = [library.samples[index - 1]]
                }
            }
            .fileImporter(
                isPresented: $isImporting, allowedContentTypes: [.rawImage, .image, .data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task { await library.add(urls) }
                }
            }
            .alert("Couldn't import", isPresented: importFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.importFailure ?? "")
            }
        }
    }

    private var importFailed: Binding<Bool> {
        Binding(
            get: { library.importFailure != nil },
            set: { if !$0 { library.importFailure = nil } })
    }

    @ViewBuilder
    private func section(_ title: String, items: [RawItem], footnote: String? = nil) -> some View {
        Section {
            ForEach(items) { item in
                NavigationLink(value: item) { Tile(item: item) }
                    .buttonStyle(.plain)
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                if let footnote {
                    Text(footnote).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }
}

private struct Tile: View {
    let item: RawItem
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.secondary.opacity(0.15)
                .aspectRatio(3 / 2, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .task(id: item.id) { thumbnail = await Develop.thumbnail(item.url) }
    }
}
