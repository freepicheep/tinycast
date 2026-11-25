import Tinycast

struct Spin: View {
    @State var count = 0
    var body: some View {
        List {
            Label("Spin", systemImage: "arrow.clockwise").contextMenu {
                Button("Forever") { while true { count += 1 } }
            }
        }
    }
}

Plugin.command("spin") { Spin() }
