import RawInputKit
import SwiftUI

/// One file, developed. The decoder picker is the point of the demo: the same file through
/// Apple's decoder and through the fallback, switchable in place.
struct DetailView: View {
    let item: RawItem

    private enum Choice: String, CaseIterable, Identifiable {
        case automatic = "Automatic"
        case apple = "Apple"
        case fallback = "Fallback"

        var id: Self { self }
        var routing: RawDecodeOptions.Routing {
            switch self {
            case .automatic: .automatic
            case .apple: .apple
            case .fallback: .fallback
            }
        }
    }

    // `-route Apple` or `-route Fallback` on the command line picks the starting decoder;
    // with `-openSample` (see GalleryView) it scripts a screenshot.
    @State private var choice = UserDefaults.standard.string(forKey: "route").flatMap(Choice.init) ?? .automatic
    @State private var model = DetailModel()

    var body: some View {
        VStack(spacing: 0) {
            canvas
            controls
        }
        .navigationTitle(item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.loadPreview(item.url) }
        .task(id: choice) { await model.decode(item.url, routing: choice.routing) }
    }

    private var canvas: some View {
        ZStack {
            Color.black
            if let failure = model.failure {
                ContentUnavailableView(
                    choice == .apple ? "Apple's decoder can't open this file" : "Couldn't decode",
                    systemImage: "exclamationmark.triangle",
                    description: Text(choice == .apple ? "Switch to Fallback to see it developed." : failure))
                    .foregroundStyle(.white)
            } else if let image = model.rendered ?? model.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    // The camera's embedded preview stands in, dimmed, until the decode lands.
                    .opacity(model.rendered == nil ? 0.6 : 1)
            }
            if model.rendered == nil, model.failure == nil {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Decoder", selection: $choice) {
                ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let raw = model.raw {
                HStack(spacing: 8) {
                    Text(raw.decoder)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(raw.route == .apple ? Color.blue : Color.orange, in: .capsule)
                        .foregroundStyle(.white)
                    Text(stats(raw)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(metadata(raw.info)).font(.caption).foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "plusminus.circle")
                    Slider(value: $model.exposure, in: -3...3)
                    Text(model.exposure, format: .number.precision(.fractionLength(1)).sign(strategy: .always()))
                        .font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Exposure")
            }
        }
        .padding()
        .background(.bar)
    }

    private func stats(_ raw: RawImage) -> String {
        let size = "\(Int(raw.image.extent.width)) x \(Int(raw.image.extent.height))"
        let time = raw.openSeconds.formatted(.number.precision(.fractionLength(2)))
        let half = raw.isHalfSize ? " (half size)" : ""
        // "open" and not "decode": Apple's decoder defers its work to render time, so the
        // figure is only comparable between fallback paths.
        return "\(size)\(half) · open \(time) s · \(Int(model.memoryMB)) MB"
    }

    private func metadata(_ info: RawInfo) -> String {
        var parts = [info.camera]
        if let lens = info.lens { parts.append(lens) }
        if let iso = info.iso { parts.append("ISO \(Int(iso))") }
        if let shutter = info.shutterSeconds {
            parts.append(shutter >= 1 ? "\(shutter.formatted()) s" : "1/\(Int((1 / shutter).rounded())) s")
        }
        if let aperture = info.aperture {
            parts.append("f/\(aperture.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if let routine = info.decoderRoutine { parts.append(routine.replacingOccurrences(of: "()", with: "")) }
        return parts.joined(separator: " · ")
    }
}
