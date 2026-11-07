import Foundation

public enum DiffLineKind: Sendable, Equatable { case context, added, removed }

public struct DiffLine: Sendable, Equatable {
    public var kind: DiffLineKind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
}

public struct DiffHunk: Sendable, Equatable {
    public var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    public var lines: [DiffLine]
    public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
}

public struct FileDiff: Sendable, Equatable {
    public var path: String
    public var hunks: [DiffHunk]
    public var isNewFile: Bool
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    public var unifiedText: String {
        var s = "--- \(isNewFile ? "/dev/null" : "a/" + path)\n+++ b/\(path)\n"
        for h in hunks {
            s += h.header + "\n"
            for l in h.lines {
                switch l.kind {
                case .context: s += " " + l.text + "\n"
                case .added: s += "+" + l.text + "\n"
                case .removed: s += "-" + l.text + "\n"
                }
            }
        }
        return s
    }
}

public enum PatchError: Error, LocalizedError {
    case malformed(String)
    case hunkMismatch(Int, String)
    case notFound(String)
    case ambiguous(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let m): return "Malformed diff: \(m)"
        case .hunkMismatch(let i, let m): return "Hunk #\(i + 1) failed validation: \(m)"
        case .notFound(let m): return "Text to replace was not found: \(m)"
        case .ambiguous(let m): return "Text to replace is not unique: \(m)"
        }
    }
}

public enum Differ {
    static func splitLines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Compute a unified diff between two texts (LCS based, with `context` lines of context).
    public static func diff(path: String, old: String?, new: String, context: Int = 3) -> FileDiff {
        let a = splitLines(old ?? ""), b = splitLines(new)
        let ops = editScript(a, b)
        // Build hunks from the edit script.
        var hunks: [DiffHunk] = []
        var i = 0
        let n = ops.count
        while i < n {
            // find next change
            guard let start = (i..<n).first(where: { ops[$0].kind != .context }) else { break }
            let hStart = max(i, start - context)
            var end = start
            var j = start
            while j < n {
                if ops[j].kind != .context { end = j; j += 1; continue }
                // look ahead: if another change within 2*context, keep going
                let nextChange = (j..<min(n, j + 2 * context + 1)).first(where: { ops[$0].kind != .context })
                if let nc = nextChange { j = nc } else { break }
            }
            let hEnd = min(n - 1, end + context)
            let slice = Array(ops[hStart...hEnd])
            let oldBefore = ops[0..<hStart].filter { $0.kind != .added }.count
            let newBefore = ops[0..<hStart].filter { $0.kind != .removed }.count
            let oc = slice.filter { $0.kind != .added }.count
            let nc = slice.filter { $0.kind != .removed }.count
            hunks.append(DiffHunk(oldStart: oc == 0 ? oldBefore : oldBefore + 1, oldCount: oc,
                                  newStart: nc == 0 ? newBefore : newBefore + 1, newCount: nc, lines: slice))
            i = hEnd + 1
        }
        return FileDiff(path: path, hunks: hunks, isNewFile: old == nil)
    }

    static func editScript(_ a: [String], _ b: [String]) -> [DiffLine] {
        // Trim common prefix/suffix to keep the DP small.
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let am = Array(a[pre..<(a.count - suf)]), bm = Array(b[pre..<(b.count - suf)])
        var out: [DiffLine] = []
        for k in 0..<pre { out.append(DiffLine(kind: .context, text: a[k], oldLine: k + 1, newLine: k + 1)) }
        let m = am.count, n = bm.count
        if m * n > 4_000_000 || m == 0 || n == 0 {
            for (k, l) in am.enumerated() { out.append(DiffLine(kind: .removed, text: l, oldLine: pre + k + 1, newLine: nil)) }
            for (k, l) in bm.enumerated() { out.append(DiffLine(kind: .added, text: l, oldLine: nil, newLine: pre + k + 1)) }
        } else {
            var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
            for x in stride(from: m - 1, through: 0, by: -1) {
                for y in stride(from: n - 1, through: 0, by: -1) {
                    dp[x][y] = am[x] == bm[y] ? dp[x + 1][y + 1] + 1 : max(dp[x + 1][y], dp[x][y + 1])
                }
            }
            var x = 0, y = 0
            while x < m || y < n {
                if x < m, y < n, am[x] == bm[y] {
                    out.append(DiffLine(kind: .context, text: am[x], oldLine: pre + x + 1, newLine: pre + y + 1)); x += 1; y += 1
                } else if y < n, x == m || dp[x][y + 1] >= dp[x + 1][y] {
                    out.append(DiffLine(kind: .added, text: bm[y], oldLine: nil, newLine: pre + y + 1)); y += 1
                } else {
                    out.append(DiffLine(kind: .removed, text: am[x], oldLine: pre + x + 1, newLine: nil)); x += 1
                }
            }
        }
        for k in 0..<suf {
            let oi = a.count - suf + k, ni = b.count - suf + k
            out.append(DiffLine(kind: .context, text: a[oi], oldLine: oi + 1, newLine: ni + 1))
        }
        return out
    }

    // MARK: - Applying patches

    /// Apply a unified diff (single file) to `original`, validating every hunk's context.
    /// Hunks may float up to `fuzz` lines away from their declared position.
    public static func apply(unifiedDiff: String, to original: String, fuzz: Int = 50) throws -> String {
        var lines = splitLines(original)
        let hadTrailingNewline = original.isEmpty || original.hasSuffix("\n")
        let hunks = try parseHunks(unifiedDiff)
        if hunks.isEmpty { throw PatchError.malformed("no hunks found") }
        var offset = 0
        for (idx, h) in hunks.enumerated() {
            let oldBlock = h.lines.filter { $0.kind != .added }.map(\.text)
            let newBlock = h.lines.filter { $0.kind != .removed }.map(\.text)
            let expected = max(0, (h.oldCount == 0 ? h.oldStart : h.oldStart - 1) + offset)
            guard let at = locate(oldBlock, in: lines, near: expected, fuzz: fuzz) else {
                throw PatchError.hunkMismatch(idx, "context lines do not match the file near line \(h.oldStart)")
            }
            lines.replaceSubrange(at..<(at + oldBlock.count), with: newBlock)
            offset += newBlock.count - oldBlock.count + (at - expected)
        }
        var out = lines.joined(separator: "\n")
        if hadTrailingNewline, !lines.isEmpty { out += "\n" }
        return out
    }

    static func locate(_ block: [String], in lines: [String], near: Int, fuzz: Int) -> Int? {
        func matches(_ at: Int) -> Bool {
            guard at >= 0, at + block.count <= lines.count else { return false }
            for k in 0..<block.count where lines[at + k] != block[k] {
                if lines[at + k].trimmingCharacters(in: .whitespaces) != block[k].trimmingCharacters(in: .whitespaces) { return false }
            }
            return true
        }
        if block.isEmpty { return min(max(0, near), lines.count) }
        for d in 0...fuzz {
            if matches(near - d) { return near - d }
            if d > 0, matches(near + d) { return near + d }
        }
        return nil
    }

    public static func parseHunks(_ text: String) throws -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var current: DiffHunk?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("@@") {
                if let c = current { hunks.append(c) }
                current = try parseHeader(line)
            } else if current == nil || line.hasPrefix("+++ ") || line.hasPrefix("--- a/") || line.hasPrefix("--- /dev/null") || line.hasPrefix("diff --git") {
                continue
            } else if current != nil {
                if line.hasPrefix("\\") { continue } // "\ No newline at end of file"
                if line.hasPrefix("+") { current!.lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldLine: nil, newLine: nil)) }
                else if line.hasPrefix("-") { current!.lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldLine: nil, newLine: nil)) }
                else if line.hasPrefix(" ") { current!.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldLine: nil, newLine: nil)) }
                else if line.isEmpty { current!.lines.append(DiffLine(kind: .context, text: "", oldLine: nil, newLine: nil)) }
            }
        }
        if let c = current { hunks.append(c) }
        // Trailing empty context lines are usually artifacts of the final newline.
        return hunks.map { h in
            var h = h
            while let last = h.lines.last, last.kind == .context, last.text.isEmpty { h.lines.removeLast() }
            return h
        }
    }

    static func parseHeader(_ line: String) throws -> DiffHunk {
        // @@ -a,b +c,d @@  (counts optional; bare "@@" allowed: position will be searched)
        let parts = line.split(separator: " ")
        func nums(_ s: Substring?) -> (Int, Int) {
            guard let s = s else { return (1, 0) }
            let body = s.dropFirst().split(separator: ",")
            let start = Int(body.first ?? "1") ?? 1
            let count = body.count > 1 ? (Int(body[1]) ?? 1) : 1
            return (start, count)
        }
        let o = nums(parts.first(where: { $0.hasPrefix("-") }))
        let n = nums(parts.first(where: { $0.hasPrefix("+") }))
        return DiffHunk(oldStart: o.0, oldCount: o.1, newStart: n.0, newCount: n.1, lines: [])
    }

    /// Exact search/replace edit (Claude Code style). Requires a unique match unless replaceAll.
    public static func replace(in text: String, old: String, new: String, replaceAll: Bool = false) throws -> String {
        guard !old.isEmpty else { throw PatchError.malformed("old_text is empty") }
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { throw PatchError.notFound(String(old.prefix(80))) }
        if count > 1 && !replaceAll { throw PatchError.ambiguous("\(count) occurrences; add context or set replace_all") }
        if replaceAll { return text.replacingOccurrences(of: old, with: new) }
        let r = text.range(of: old)!
        return text.replacingCharacters(in: r, with: new)
    }
}
