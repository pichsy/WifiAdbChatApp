import SwiftUI

struct ContentView: View {
    enum Tab: Hashable {
        case mobile
        case computer
    }

    @State private var tab: Tab = .mobile

    var body: some View {
        TabView(selection: $tab) {
            MobileDeviceView()
                .tabItem { Label("移动设备", systemImage: "iphone") }
                .tag(Tab.mobile)

            LANTransferView()
                .tabItem { Label("电脑设备", systemImage: "laptopcomputer") }
                .tag(Tab.computer)
        }
        .frame(minWidth: 720, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
