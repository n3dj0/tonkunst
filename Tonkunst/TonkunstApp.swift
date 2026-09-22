import SwiftUI

@main
struct TonkunstApp: App {
    @StateObject private var store = MusicStore()
    var body: some Scene { WindowGroup { LibraryView().environmentObject(store).tint(Color(red: 0.22, green: 0.45, blue: 0.92)) } }
}
