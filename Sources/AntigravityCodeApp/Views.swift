import SwiftUI
import AppKit
import AntigravityCore

struct MainView: View {
    @EnvironmentObject var model: SessionViewModel

    var body: some View {
        Group {
            if model.workspace == nil {
                WelcomeView()
            } else {
                HSplitView {
                    ConversationPane().frame(minWidth: 460, idealWidth: 620)
                    InspectorPane().frame(minWidth: 380, idealWidth: 520)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.chooseFolder() } label: { Label("Open", systemImage: "folder") }
                if let ws = model.workspace {
                    Text(ws.root.lastPathComponent).font(.headline)
                    if ws.isGitRepo { Image(systemName: "arrow.triangle.branch").foregroundColor(.secondary) }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Review: approve every write. Turbo: auto-run reads, edits and tests; ask for risky commands.")
                if model.isRunning {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.circle.fill") }
                }
                Button { model.newConversation() } label: { Label("New", systemImage: "square.and.pencil") }
            }
        }
        .sheet(item: $model.pending) { p in ApprovalSheet(pending: p) }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: SessionViewModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 48)).foregroundColor(.accentColor)
            Text("Antigravity Code").font(.largeTitle.bold())
            Text("Open a project folder to start an agent session.").foregroundColor(.secondary)
            Button("Open Folder…") { model.chooseFolder() }.keyboardShortcut("o").controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Conversation

struct ConversationPane: View {
    @EnvironmentObject var model: SessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.transcript) { item in
                            TranscriptRow(item: item).id(item.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: model.transcript.count) { _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                PromptEditor(text: $model.input, onSubmit: model.send)
                    .frame(minHeight: 44, maxHeight: 140)
                Button(action: model.send) {
                    Image(systemName: model.isRunning ? "hourglass" : "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
            }
            .padding(10)
            HStack {
                Text(model.modelID).font(.caption.monospaced())
                Spacer()
                if model.tokens.prompt > 0 {
                    Text("\(model.tokens.prompt) in · \(model.tokens.output) out").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }
}

/// Multi-line editor: Return sends, Shift-Return inserts a newline.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        scroll.borderType = .bezelBorder
        return scroll
    }
    func updateNSView(_ v: NSScrollView, context: Context) {
        let tv = v.documentView as! NSTextView
        if tv.string != text { tv.string = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        init(_ p: PromptEditor) { parent = p }
        func textDidChange(_ n: Notification) { parent.text = (n.object as! NSTextView).string }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) { tv.insertNewlineIgnoringFieldEditor(nil); return true }
                parent.onSubmit(); return true
            }
            return false
        }
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    @EnvironmentObject var model: SessionViewModel

    var body: some View {
        switch item {
        case .user(_, let t):
            Text(t).textSelection(.enabled).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        case .assistant(_, let t):
            MarkdownText(t)
        case .thinking(_, let t):
            DisclosureGroup {
                Text(t).font(.callout).foregroundColor(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Thinking", systemImage: "brain").font(.caption).foregroundColor(.secondary)
            }
        case .tool(let c):
            ToolCardView(card: c)
        case .plan(_, let items):
            PlanCard(items: items)
        case .error(_, let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red).textSelection(.enabled)
        }
    }
}

struct MarkdownText: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        let attr = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        Text(attr).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolCardView: View {
    let card: ToolCard
    @EnvironmentObject var model: SessionViewModel
    @State private var expanded = false

    var icon: (String, Color) {
        switch card.status {
        case .running: return ("circle.dotted", .blue)
        case .awaitingApproval: return ("hand.raised", .orange)
        case .succeeded: return ("checkmark.circle.fill", .green)
        case .failed: return ("xmark.octagon.fill", .red)
        case .denied: return ("nosign", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon.0).foregroundColor(icon.1)
                Text(card.name).font(.caption.monospaced().bold())
                Text(card.summary).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
                Spacer()
                if card.risk == .destructive { Text("destructive").font(.caption2).foregroundColor(.red) }
                if let d = card.diff {
                    Button("+\(d.additions) −\(d.deletions)") { model.selectedDiff = d }.buttonStyle(.link).font(.caption)
                }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }.buttonStyle(.borderless)
            }
            if expanded {
                ScrollView {
                    Text(card.result.isEmpty ? card.output : card.result)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }
}

struct PlanCard: View {
    let items: [PlanItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Plan · \(items.filter { $0.status == .completed }.count)/\(items.count)", systemImage: "checklist").font(.caption.bold())
            ForEach(items) { i in
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(i.status)).foregroundColor(Self.color(i.status))
                    Text(i.title).strikethrough(i.status == .completed).font(.callout)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
    static func symbol(_ s: PlanItem.Status) -> String {
        switch s { case .completed: return "checkmark.square.fill"; case .in_progress: return "arrow.right.square"; case .failed: return "xmark.square"; case .pending: return "square" }
    }
    static func color(_ s: PlanItem.Status) -> Color {
        switch s { case .completed: return .green; case .in_progress: return .blue; case .failed: return .red; case .pending: return .secondary }
    }
}

// MARK: - Inspector (terminal / diff / plan)

struct InspectorPane: View {
    @EnvironmentObject var model: SessionViewModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Terminal").tag(0)
                Text("Diff").tag(1)
                Text("Plan").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()
            switch tab {
            case 0: TerminalView(text: model.terminal)
            case 1:
                if let d = model.selectedDiff { DiffView(diff: d) }
                else { placeholder("No diff selected", "Proposed and applied edits appear here.") }
            default:
                if model.plan.isEmpty { placeholder("No plan yet", "The agent publishes a checklist for multi-step tasks.") }
                else { ScrollView { PlanCard(items: model.plan).padding() } }
            }
        }
        .onChange(of: model.selectedDiff) { d in if d != nil { tab = 1 } }
    }

    func placeholder(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 6) { Text(title).font(.headline); Text(sub).foregroundColor(.secondary).font(.callout) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TerminalView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "Command output will stream here." : text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color(nsColor: .init(white: 0.9, alpha: 1)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                    .id("end")
            }
            .background(Color(nsColor: .init(white: 0.09, alpha: 1)))
            .onChange(of: text.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct DiffView: View {
    let diff: FileDiff
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(diff.path).font(.system(.callout, design: .monospaced).bold())
                if diff.isNewFile { Text("new").font(.caption).foregroundColor(.green) }
                Spacer()
                Text("+\(diff.additions)").foregroundColor(.green).font(.caption.monospaced())
                Text("−\(diff.deletions)").foregroundColor(.red).font(.caption.monospaced())
            }
            .padding(8)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, h in
                        Text(h.header).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.08))
                        ForEach(Array(h.lines.enumerated()), id: \.offset) { _, l in DiffLineView(line: l) }
                    }
                }
            }
        }
    }
}

struct DiffLineView: View {
    let line: DiffLine
    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLine.map { "\($0)" } ?? "").frame(width: 38, alignment: .trailing).foregroundColor(.secondary)
            Text(line.newLine.map { "\($0)" } ?? "").frame(width: 38, alignment: .trailing).foregroundColor(.secondary)
            Text(prefix).frame(width: 16)
            Text(SyntaxHighlighter.highlight(line.text))
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }
    var prefix: String { switch line.kind { case .added: return "+"; case .removed: return "−"; case .context: return " " } }
    var bg: Color { switch line.kind { case .added: return .green.opacity(0.15); case .removed: return .red.opacity(0.15); case .context: return .clear } }
}

/// Tiny keyword/string/comment highlighter for diff lines.
enum SyntaxHighlighter {
    static let keywords = Set(("func let var if else for while return import struct class enum protocol extension case switch "
        + "public private static guard throw throws try async await def fn pub impl const function export from interface type "
        + "true false nil null self Self new in of break continue do").split(separator: " ").map(String.init))

    static func highlight(_ s: String) -> AttributedString {
        var out = AttributedString()
        if let r = s.range(of: "//") ?? s.range(of: "# ") , !s[..<r.lowerBound].contains("\"") {
            out += highlightCode(String(s[..<r.lowerBound]))
            var c = AttributedString(String(s[r.lowerBound...])); c.foregroundColor = .gray
            return out + c
        }
        return highlightCode(s)
    }

    static func highlightCode(_ s: String) -> AttributedString {
        var out = AttributedString()
        var word = ""
        var inString = false
        func flush() {
            guard !word.isEmpty else { return }
            var a = AttributedString(word)
            if inString { a.foregroundColor = .orange }
            else if keywords.contains(word) { a.foregroundColor = .purple }
            else if word.first?.isNumber == true { a.foregroundColor = .blue }
            out += a; word = ""
        }
        for ch in s {
            if ch == "\"" {
                if inString { word.append(ch); flush(); inString = false } else { flush(); inString = true; word.append(ch) }
            } else if inString || ch.isLetter || ch.isNumber || ch == "_" {
                word.append(ch)
            } else {
                flush(); out += AttributedString(String(ch))
            }
        }
        flush()
        return out
    }
}

// MARK: - Approval

struct ApprovalSheet: View {
    let pending: PendingApproval
    @EnvironmentObject var model: SessionViewModel
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: pending.request.risk == .destructive ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .foregroundColor(pending.request.risk == .destructive ? .red : .orange).font(.title2)
                VStack(alignment: .leading) {
                    Text(pending.request.risk == .destructive ? "Destructive action" : "Approve action").font(.headline)
                    Text(pending.request.toolName).font(.caption.monospaced()).foregroundColor(.secondary)
                }
            }
            if let cmd = pending.request.command {
                Text(cmd).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.8))).foregroundColor(.white)
            } else {
                Text(pending.request.summary).font(.callout.monospaced())
            }
            if let d = pending.request.diff {
                DiffView(diff: d).frame(minHeight: 260, maxHeight: 460)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            TextField("Optional feedback for the agent (sent if you deny)", text: $feedback)
            HStack {
                Button("Deny", role: .cancel) { model.resolve(.deny(reason: feedback.isEmpty ? nil : feedback)) }
                    .keyboardShortcut(.escape)
                Spacer()
                if pending.request.risk != .destructive {
                    Button("Always allow \(pending.request.toolName) this session") { model.resolve(.allowAlwaysForSession) }
                }
                Button("Approve") { model.resolve(.allow) }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 720)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: SessionViewModel
    @State private var apiKey = ""
    @State private var saved = KeychainStore.load() != nil

    var body: some View {
        Form {
            Section(header: Text("Antigravity API")) {
                SecureField("API key", text: $apiKey)
                HStack {
                    Button("Save to Keychain") {
                        try? KeychainStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        apiKey = ""; saved = KeychainStore.load() != nil
                        model.newConversation()
                    }.disabled(apiKey.isEmpty)
                    if saved {
                        Text("Key stored").foregroundColor(.green)
                        Button("Remove") { KeychainStore.delete(); saved = false }
                    }
                }
                Text("Alternatively set GOOGLE_CLOUD_PROJECT and sign in with `gcloud auth login` to use OAuth (Vertex AI).")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(header: Text("Model")) {
                TextField("Model ID", text: $model.modelID)
                Toggle("Show thinking", isOn: $model.showThinking)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
