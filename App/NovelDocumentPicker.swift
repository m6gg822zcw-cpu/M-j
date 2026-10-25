import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Ask Files to hand the app a local copy before starting the existing import pipeline.
struct NovelDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--moxu-picker-ui-test") {
                picker.directoryURL = URL.documentsDirectory.appendingPathComponent("PickerUI", isDirectory: true)
            }
        #endif
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void
        private var completed = false

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            #if DEBUG
                PickerUITestTrace.record("delegate.selected", detail: "\(urls.count) files, completed=\(completed)")
            #endif
            guard !completed else { return }
            completed = true
            if urls.isEmpty { onCancel() } else { onPick(urls) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            #if DEBUG
                PickerUITestTrace.record("delegate.cancelled", detail: "completed=\(completed)")
            #endif
            guard !completed else { return }
            completed = true
            onCancel()
        }
    }
}

#if DEBUG
    enum PickerUITestTrace {
        static func record(_ event: String, detail: String = "") {
            guard ProcessInfo.processInfo.arguments.contains("--moxu-picker-ui-test") else { return }
            do {
                let folder = URL.documentsDirectory.appendingPathComponent("PickerUI", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("PickerEvents.json")
                var events = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []
                events.append(["event": event, "detail": detail, "time": Date().timeIntervalSince1970])
                try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
                    .write(to: file, options: .atomic)
            } catch { print("Picker UI trace failed: \(error.localizedDescription)") }
        }
    }
#endif
