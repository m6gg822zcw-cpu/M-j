import Foundation

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
