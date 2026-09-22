import SwiftUI
import UIKit

@main
struct TonkunstApp: App {
    @StateObject private var store = MusicStore()

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.largeTitleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
                for: UIFont.systemFont(ofSize: 28, weight: .bold)
            )
        ]

        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
    }

    var body: some Scene { WindowGroup { LibraryView().environmentObject(store).tint(Color(red: 0.22, green: 0.45, blue: 0.92)) } }
}
