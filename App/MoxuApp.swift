import MoxuCore
import SwiftUI
import UIKit

@main @MainActor struct MoxuApp: App {
    @StateObject private var studio = StudioModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(studio)
                .onOpenURL { url in Task { await studio.importFile(url) } }
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task {
                    await studio.load()
                    #if DEBUG
                        studio.preparePickerUITestFilesIfRequested()
                        await studio.runNativeSmokeChecksIfRequested()
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        studio.pauseForBackground()
                    } else if phase == .active {
                        studio.becameActive()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification))
            { _ in Task { await BitmapCache.shared.clear() } }
        }
    }
}
struct RootView: View {
    @EnvironmentObject private var studio: StudioModel
    var body: some View {
        TabView(selection: $studio.selectedTab) {
            NavigationStack { LibraryView() }.tabItem { Label("书架", systemImage: "books.vertical") }.tag(0)
            ArtistsView().tabItem { Label("画师", systemImage: "paintbrush.pointed") }.tag(1)
            ConnectionsView().tabItem { Label("连接", systemImage: "slider.horizontal.3") }.tag(2)
            QueueView().tabItem { Label("任务", systemImage: "square.stack.3d.up") }.badge(
                studio.jobs.filter { $0.state == .queued || $0.state == .running }.count
            ).tag(3)
        }.tint(Ink.accent)
            .alert("操作未完成", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } }))
        {
            Button("知道了", role: .cancel) { studio.error = nil }
        } message: {
            Text(studio.error ?? "")
        }
    }
}
