import SwiftUI

// The console: everything the running program says, streamed live.
struct ConsoleView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(model.isRunning ? Theme.green : Theme.muted)
                    .frame(width: 8, height: 8)
                Text(model.isRunning ? "running" : "console")
                    .font(.caption.smallCaps()).foregroundStyle(Theme.muted)
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.stopRun() }
                        .font(.caption.bold()).foregroundStyle(Theme.red)
                }
                Button {
                    model.consoleText = ""
                } label: {
                    Image(systemName: "xmark.bin").font(.caption)
                }
                .foregroundStyle(Theme.muted)
                Button {
                    withAnimation { model.showConsole = false }
                } label: {
                    Image(systemName: "chevron.down").font(.caption.bold())
                }
                .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.panel2)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.consoleText.isEmpty ? "— press ▶ to run —" : model.consoleText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(model.consoleText.isEmpty ? Theme.muted : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                        .id("console-end")
                }
                .onChange(of: model.consoleText) {
                    proxy.scrollTo("console-end", anchor: .bottom)
                }
            }
            .background(Theme.panel)
        }
        .frame(height: 260)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .shadow(color: .black.opacity(0.5), radius: 18, y: -4)
    }
}
