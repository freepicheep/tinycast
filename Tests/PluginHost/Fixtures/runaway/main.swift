import Tinycast

struct Spin: View {
    @State var count = 0
    var body: some View {
        List {
            Item("Spin").actions {
                Button("Forever") { while true { count += 1 } }
            }
        }
    }
}

Plugin.command("spin") { Spin() }
