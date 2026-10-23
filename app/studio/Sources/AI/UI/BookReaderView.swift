import SwiftUI

/// State for the activity bar's "The Vanta Book" sidebar: chapter list,
/// BM25 search over sections, and an in-sidebar reader.
final class BookReaderModel: ObservableObject {
    static let shared = BookReaderModel()
    @Published var query = ""
    @Published var openDoc: KnowledgeBase.Document?
    @Published var targetLine: Int?
    @Published var readerToken = 0

    func open(url: URL, line: Int = 0) {
        let kb = KnowledgeBase.shared
        if !kb.isLoaded { kb.loadNow() }
        openDoc = kb.documents.first { $0.url.standardizedFileURL == url.standardizedFileURL }
        targetLine = line
        readerToken += 1
    }
}

struct BookReaderView: View {
    @ObservedObject var model = BookReaderModel.shared
    @ObservedObject var kb = KnowledgeBase.shared

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader("The Vanta Book") {
                IconButton(icon: "sparkles", help: "Ask the Book (Vee answers from the book, with citations)") {
                    VeeAssistant.shared.mode = "book"
                    Services.shared.layout.auxVisible = true
                    VeeAssistant.shared.focusToken += 1
                }
                IconButton(icon: "doc.richtext", help: "Open the PDF") { openPDF() }
            }
            if let doc = model.openDoc {
                ReaderPane(doc: doc)
            } else {
                searchField
                if !kb.isLoaded {
                    ProgressView().controlSize(.small).padding(30)
                    Spacer()
                } else if kb.documents.isEmpty {
                    PlaceholderPanel(title: "Book not found", icon: "book.closed",
                                     message: "The chapters weren't bundled and ~/projects/vanta-book/chapters doesn't exist.")
                } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    chapterList
                } else {
                    results
                }
            }
        }
        .onAppear { kb.load() }
    }

    var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(Theme.muted)
            TextField("Search the book (e.g. default values)", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(Theme.muted)
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.editorBg))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    var chapterList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                section("Chapters", kb.documents.filter { $0.source == .book })
                section("Reference docs", kb.documents.filter { $0.source == .docs })
            }.padding(.bottom, 16)
        }
    }

    func section(_ title: String, _ docs: [KnowledgeBase.Document]) -> some View {
        Group {
            if !docs.isEmpty {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(Theme.muted)
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 3)
                ForEach(docs) { d in
                    let isPart = d.url.lastPathComponent.hasSuffix("0-part.md")
                    HStack(spacing: 6) {
                        Image(systemName: isPart ? "bookmark.fill" : d.source == .book ? "text.book.closed" : "doc.plaintext")
                            .font(.system(size: 10.5)).foregroundColor(isPart ? Theme.amber : Theme.accent)
                        Text(d.title).font(.system(size: 12.5, weight: isPart ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 23).contentShape(Rectangle())
                    .onTapGesture { model.open(url: d.url) }
                }
            }
        }
    }

    var results: some View {
        let hits = kb.scoredSearch(model.query, k: 25)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if hits.isEmpty {
                    Text("No sections match.").font(.system(size: 12)).foregroundColor(Theme.muted).padding(14)
                }
                ForEach(hits, id: \.0.id) { c, _ in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.heading.isEmpty ? c.docTitle : c.heading).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(c.docTitle).font(.system(size: 10.5)).foregroundColor(Theme.accent).lineLimit(1)
                        Text(snippet(c.text)).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(url: c.fileURL, line: c.line) }
                }
            }.padding(.vertical, 4)
        }
    }

    func snippet(_ t: String) -> String {
        t.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("```") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3).joined(separator: " ").replacingOccurrences(of: "`", with: "")
    }

    func openPDF() {
        if let u = KnowledgeBase.pdfURL { NSWorkspace.shared.open(u) }
        else { Services.shared.flash("The Vanta Book PDF wasn't found (Desktop, Documents, or bundled)") }
    }
}

/// Reads one chapter inside the sidebar, section by section.
struct ReaderPane: View {
    let doc: KnowledgeBase.Document
    @ObservedObject var model = BookReaderModel.shared

    var body: some View {
        let chunks = KnowledgeBase.shared.chunks(of: doc.url)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.openDoc = nil } label: {
                    HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("Contents") }.font(.system(size: 11.5))
                }.buttonStyle(.plain).foregroundColor(Theme.accent)
                Spacer()
                IconButton(icon: "arrow.up.forward.square", help: "Open in an editor tab (read-only)", size: 11) {
                    if let pane = Services.shared.editors.open(doc.url, preview: true) {
                        pane.document.isReadOnly = true
                        pane.textView.isEditable = false
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
            Hairline().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chunks) { c in
                            VStack(alignment: .leading, spacing: 6) {
                                MarkdownView(text: c.text, codeActions: false, fontSize: 12.5)
                                Button { ask(c) } label: {
                                    Label("Ask Vee about this", systemImage: "sparkles").font(.system(size: 10.5))
                                }.buttonStyle(.plain).foregroundColor(Theme.muted)
                            }
                            .id(c.line)
                        }
                    }
                    .padding(12)
                }
                .onAppear { scroll(proxy, chunks) }
                .onChange(of: model.readerToken) { _, _ in scroll(proxy, chunks) }
            }
        }
    }

    func scroll(_ proxy: ScrollViewProxy, _ chunks: [KnowledgeChunk]) {
        guard let line = model.targetLine, let target = chunks.last(where: { $0.line <= line }) else { return }
        DispatchQueue.main.async { proxy.scrollTo(target.line, anchor: .top) }
    }

    func ask(_ c: KnowledgeChunk) {
        let vee = VeeAssistant.shared
        vee.mode = "book"
        Services.shared.layout.auxVisible = true
        vee.input = "Explain “\(c.citation)” with a simple example."
        vee.focusToken += 1
    }
}
