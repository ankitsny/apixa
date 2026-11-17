import SwiftUI

/// Turns pasted recipe text into looks. Handles Sony's site style
/// ("VV2 (Vivid 2) | Contrast +1, Highlights +1, … WB AWB A1 G1") and common blog/Reddit
/// "Key: value" lists. Recipes are separated by blank lines; a line without settings is the name.
enum RecipeParser {
    static func parse(_ text: String, group: String) -> [LookRecipe] {
        let clean = text.replacingOccurrences(of: "\r", with: "")
        // Recipes separated by "---" lines (keep each chunk whole), otherwise by blank lines.
        let separator = try! NSRegularExpression(pattern: "(?m)^\\s*[-–—_*=]{3,}\\s*$")
        let hasRules = separator.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) != nil
        let chunks = hasRules
            ? separator.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "\u{1E}")
                .components(separatedBy: "\u{1E}")
            : clean.components(separatedBy: "\n\n")
        let blocks = chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: [LookRecipe] = []
        var pendingName: String?
        for block in blocks {
            guard let base = look(in: block) else {
                // A block with no Creative Look is probably just the name of the next recipe.
                pendingName = block.components(separatedBy: "\n").first.map(cleanName)
                continue
            }
            var r = LookRecipe(name: "", group: group, base: base)
            r.contrast = int("Contrast", block) ?? 0
            r.highlights = int("Highlights?", block) ?? 0
            r.shadows = int("Shadows?", block) ?? 0
            r.fade = clamp(int("Fade", block) ?? 0, 0, 9)
            r.saturation = base.isMono ? 0 : (int("Saturation", block) ?? 0)
            r.sharpness = clamp(int("Sharpness(?!\\s*Range)", block) ?? 0, 0, 9)
            r.sharpnessRange = clamp(int("Sharpness\\s*Range", block) ?? 3, 1, 5)
            r.clarity = clamp(int("Clarity", block) ?? 0, 0, 9)
            (r.wb, r.kelvin) = whiteBalance(block)
            r.shiftAB = shift("A", "B", block)
            r.shiftGM = shift("M", "G", block)
            if let d = match("(?i)DRO[^\\n\\d]{0,12}?(?:L[eV]*L?\\.?\\s*|\\+)?([1-5])", block) { r.dro = Int(d) ?? 0 }
            r.name = name(in: block) ?? pendingName ?? "\(group) \(out.count + 1)"
            pendingName = nil
            out.append(r)
        }
        return out
    }

    // MARK: Pieces

    private static let looks: [CreativeLook] = [.VV2, .FL2, .FL3, .VV, .FL, .ST, .PT, .NT, .IN, .SH, .BW, .SE]

    static func look(in s: String) -> CreativeLook? {
        // Prefer "Creative Look: X"; otherwise the first standalone look code (case-sensitive, so "in" ≠ IN).
        if let v = match("Creative\\s*Look[^A-Z\\n]{0,6}([A-Z]{2}[23]?)", s), let l = CreativeLook(rawValue: v) { return l }
        for l in looks where s.range(of: "(?<![A-Za-z])\(l.rawValue)(?![A-Za-z0-9])", options: .regularExpression) != nil {
            return l
        }
        for l in CreativeLook.allCases where s.range(of: "\\b\(l.title)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            return l
        }
        return nil
    }

    private static func int(_ key: String, _ s: String) -> Int? {
        match("(?i)\\b\(key)\\b\\s*[:=]?\\s*([+\\-−±]?\\s*\\d+)", s).flatMap {
            Int($0.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "±", with: "")
                  .replacingOccurrences(of: "+", with: "").replacingOccurrences(of: " ", with: ""))
        }
    }

    private static func whiteBalance(_ s: String) -> (WhiteBalance, Int?) {
        if let k = match("(\\d{4,5})\\s*K\\b", s).flatMap(Int.init) { return (.colorTemp, k) }
        let lower = s.lowercased()
        let table: [(String, WhiteBalance)] = [("warm white", .fluorWarm), ("cool white", .fluorCool), ("day white", .fluorDay),
                                               ("fluor", .fluorDaylight), ("daylight", .daylight), ("shade", .shade),
                                               ("cloudy", .cloudy), ("incandescent", .incandescent), ("tungsten", .incandescent),
                                               ("flash", .flash)]
        for (k, v) in table where lower.contains(k) { return (v, nil) }
        return (.auto, nil)
    }

    /// e.g. "A1", "A 2", "Amber 2" → +, "B3"/"Blue 3" → −.
    /// Fractional steps (e.g. "B0.5", "G0.75") are allowed, as on newer bodies.
    private static func shift(_ pos: String, _ neg: String, _ s: String) -> Double {
        func val(_ letter: String, _ word: String) -> Double? {
            (match("(?<![A-Za-z])(?:\(letter)|\(word))\\s?([0-7](?:\\.\\d+)?)(?![0-9.])", s)).flatMap(Double.init)
        }
        let names = ["A": "Amber", "B": "Blue", "G": "Green", "M": "Magenta"]
        if let p = val(pos, names[pos]!) { return p }
        if let n = val(neg, names[neg]!) { return -n }
        return 0
    }

    private static func name(in s: String) -> String? {
        if let n = match("(?i)(?:Recipe|Name|Title)\\s*[:\\-]\\s*([^\\n]+)", s) { return cleanName(n) }
        let first = (s.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
        // A first line that's just a name (no settings in it), e.g. "FL3 Vintage Chrome" or "Jonpoon.jpg".
        let hasSettings = first.range(of: "(?i)contrast|highlight|shadow|saturation|sharpness|clarity|fade|\\||:\\s*[+\\-]?\\d",
                                      options: .regularExpression) != nil
        if !hasSettings, first.count <= 60, !first.isEmpty, CreativeLook(rawValue: first) == nil { return cleanName(first) }
        return nil
    }

    private static func cleanName(_ s: String) -> String {
        s.replacingOccurrences(of: "(?i)\\.(jpe?g|png|heic)$", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " #*-:•\t"))
    }

    private static func match(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, v)) }
}

struct RecipeImportSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var text = ""
    @ViewState private var group = "Imported Recipes"

    var body: some View {
        let parsed = RecipeParser.parse(text, group: group)
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Recipes").font(.title2.bold())
            Text("Paste one or more recipes. Put a blank line between recipes; a name line above each is optional. Sony's site format (“VV2 (Vivid 2) | Contrast +1, … WB AWB A1 G1”) and “Key: value” lists both work.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Group name", text: $group).textFieldStyle(.roundedBorder).frame(width: 260)
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("Recognised \(parsed.count) recipe\(parsed.count == 1 ? "" : "s"):").font(.callout.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(parsed.enumerated()), id: \.offset) { _, r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(.callout)
                            Text(r.settingsLine).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            Text("Imported looks are saved only in your Apixa library on this Mac.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(parsed.count) Look\(parsed.count == 1 ? "" : "s")") {
                    store.importLooks(parsed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 640)
        .onAppear { store.isEditingText = true }
        .onDisappear { store.isEditingText = false }
    }
}
