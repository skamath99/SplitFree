import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            GroupsListView()
                .tabItem { Label("Groups", systemImage: "person.3.fill") }
            ActivityView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            InsightsView()
                .tabItem { Label("Insights", systemImage: "chart.pie.fill") }
            AboutView()
                .tabItem { Label("About", systemImage: "heart.circle") }
        }
    }
}
