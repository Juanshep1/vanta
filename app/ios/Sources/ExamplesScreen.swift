import SwiftUI

// The Learn tab: bundled example programs. Read them, or add one to your
// files and start hacking on it.
struct ExamplesScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                List {
                    Section {
                        ForEach(model.bundledExamples(), id: \.self) { url in
                            NavigationLink {
                                ExampleDetail(url: url)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.lastPathComponent)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(Theme.ink)
                                    Text(blurb(for: url))
                                        .font(.caption).foregroundStyle(Theme.muted)
                                }
                                .padding(.vertical, 2)
                            }
                            .listRowBackground(Theme.panel)
                        }
                    } header: {
                        Text("Example programs")
                    } footer: {
                        Text("Vanta reads like plain English. Open one, add it to your files, and change things — that's the whole trick to learning it.")
                            .foregroundStyle(Theme.muted)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Learn")
        }
    }

    private func blurb(for url: URL) -> String {
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let first = source.split(separator: "\n").first.map(String.init) ?? ""
        return first.hasPrefix("#") ? String(first.dropFirst()).trimmingCharacters(in: .whitespaces)
                                    : "a Vanta program"
    }
}

struct ExampleDetail: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @State private var added = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                Text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    model.createFile(url.lastPathComponent, contents: source)
                    added = true
                } label: {
                    Label(added ? "Added" : "Add to my files",
                          systemImage: added ? "checkmark" : "plus")
                        .font(.callout.bold())
                }
                .disabled(added)
            }
        }
    }
}
