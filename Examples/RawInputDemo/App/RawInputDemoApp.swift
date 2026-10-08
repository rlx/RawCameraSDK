import SwiftUI

@main
struct RawInputDemoApp: App {
    @State private var library = Library()

    init() {
        // Exits the process if a benchmark was requested. See Benchmark.swift.
        Benchmark.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            GalleryView()
                .environment(library)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
