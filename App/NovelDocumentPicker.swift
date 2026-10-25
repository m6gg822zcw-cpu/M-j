import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Ask Files to hand the app a local copy before starting the existing import pipeline.
struct NovelDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> NovelPickerController {
        let picker = NovelPickerController(forOpeningContentTypes: [.data], asCopy: true)
        picker.retainedCoordinator = context.coordinator
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        #if DEBUG
            PickerUITestTrace.record("picker.created", detail: "\(context.coordinator.sessionID), controller=\(ObjectIdentifier(picker))")
        #endif
        return picker
    }

    func updateUIViewController(_ controller: NovelPickerController, context: Context) {
        controller.retainedCoordinator = context.coordinator
        controller.delegate = context.coordinator
        #if DEBUG
            PickerUITestTrace.record("picker.updated", detail: "\(context.coordinator.sessionID), controller=\(ObjectIdentifier(controller))")
        #endif
    }

    static func dismantleUIViewController(_ controller: NovelPickerController, coordinator: Coordinator) {
        #if DEBUG
            PickerUITestTrace.record("picker.dismantled", detail: "\(coordinator.sessionID), controller=\(ObjectIdentifier(controller))")
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void
        private var completed = false
        let sessionID = UUID().uuidString

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        deinit {
            #if DEBUG
                PickerUITestTrace.record("delegate.deinit", detail: sessionID)
            #endif
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            #if DEBUG
                PickerUITestTrace.record("delegate.selected", detail: "\(urls.count) files, completed=\(completed), session=\(sessionID)")
            #endif
            guard !completed else { return }
            completed = true
            if urls.isEmpty { onCancel() } else { onPick(urls) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            #if DEBUG
                PickerUITestTrace.record("delegate.cancelled", detail: "completed=\(completed), session=\(sessionID)")
            #endif
            guard !completed else { return }
            completed = true
            onCancel()
        }
    }
}

/// UIKit keeps its delegate weak. Retain the handoff for the controller's full presentation lifetime.
final class NovelPickerController: UIDocumentPickerViewController {
    var retainedCoordinator: NovelDocumentPicker.Coordinator?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            PickerUITestTrace.record("picker.appeared", detail: "\(retainedCoordinator?.sessionID ?? "nil"), delegateMatches=\((delegate as AnyObject?) === retainedCoordinator)")
        #endif
    }
}

#if DEBUG
    enum PickerUITestTrace {
        static func record(_ event: String, detail: String = "") {
            guard ProcessInfo.processInfo.arguments.contains("--moxu-picker-ui-test") else { return }
            do {
                let folder = URL.documentsDirectory.appendingPathComponent("PickerUI", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = URL.documentsDirectory.appendingPathComponent("PickerUITestEvents.json")
                var events = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []
                events.append(["event": event, "detail": detail, "time": Date().timeIntervalSince1970])
                try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
                    .write(to: file, options: .atomic)
            } catch { print("Picker UI trace failed: \(error.localizedDescription)") }
        }
    }
#endif
