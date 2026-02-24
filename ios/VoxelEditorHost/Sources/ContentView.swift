import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voxel Editor iOS Host")
                .font(.title2.weight(.bold))
            Text("This Xcode target runs `zig build ios` in a pre-build step and links `libvoxel_editor_ios.a`.")
                .font(.body)
            Text("Next step: bridge into exported Zig entry points for runtime integration.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}
