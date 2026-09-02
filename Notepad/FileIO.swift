import Foundation

// MARK: - Text Encoding
//
// Notepad used to read every file with `String(contentsOf:encoding:.utf8)` and,
// on three of the four load paths, swallow the failure with `?? ""`. Anything
// that wasn't valid UTF-8 — a Windows-1252 CSV out of Excel, a UTF-16 export
// from a Windows tool — opened as a BLANK document, and the next ⌘S wrote that
// blankness over the user's file. Everything in this file exists to make the
// round trip (detect on read → preserve on write) lossless.

/// The encodings Notepad can read and write. Ordered as shown in the menus.
enum FileEncoding: String, Codable, CaseIterable, Sendable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    // BOM-less UTF-16 exists in the wild and must go back out the way it came
    // in — writing a BOM the file never had is still rewriting someone's file.
    // Detection can produce these; the menus don't offer them (an explicit
    // choice of UTF-16 gets the BOM, which is the unambiguous form).
    case utf16LENoBOM
    case utf16BENoBOM
    case windowsCP1252
    case isoLatin1
    case macRoman

    /// The encodings offered in the menus, in order. Leaves out the BOM-less
    /// UTF-16 forms, which exist only to round-trip a file that arrived that way.
    static let menuCases: [FileEncoding] = [
        .utf8, .utf8BOM, .utf16LE, .utf16BE, .windowsCP1252, .isoLatin1, .macRoman
    ]

    var displayName: String {
        switch self {
        case .utf8:          return "UTF-8"
        case .utf8BOM:       return "UTF-8 with BOM"
        case .utf16LE:       return "UTF-16 LE"
        case .utf16BE:       return "UTF-16 BE"
        case .utf16LENoBOM:  return "UTF-16 LE (no BOM)"
        case .utf16BENoBOM:  return "UTF-16 BE (no BOM)"
        case .windowsCP1252: return "Western (Windows-1252)"
        case .isoLatin1:     return "Western (ISO Latin 1)"
        case .macRoman:      return "Western (Mac OS Roman)"
        }
    }

    /// Short form for the status bar.
    var badge: String {
        switch self {
        case .utf8:          return "UTF-8"
        case .utf8BOM:       return "UTF-8 BOM"
        case .utf16LE, .utf16LENoBOM: return "UTF-16 LE"
        case .utf16BE, .utf16BENoBOM: return "UTF-16 BE"
        case .windowsCP1252: return "CP-1252"
        case .isoLatin1:     return "Latin-1"
        case .macRoman:      return "Mac Roman"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE, .utf16LENoBOM: return .utf16LittleEndian
        case .utf16BE, .utf16BENoBOM: return .utf16BigEndian
        case .windowsCP1252:  return .windowsCP1252
        case .isoLatin1:      return .isoLatin1
        case .macRoman:       return .macOSRoman
        }
    }

    /// Byte-order mark written ahead of the payload. Empty for the BOM-less forms.
    /// The UTF-16 cases carry one so Windows tools identify the file correctly —
    /// `.utf16LittleEndian` data on its own has no marker at all.
    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default:       return []
        }
    }
}

// MARK: - Line Endings

/// Files keep the line endings they arrived with. Internally the buffer is
/// always LF — every other part of the app (find, line counting, the CSV
/// serializer) assumes that — and the original ending is restored on write.
enum LineEnding: String, Codable, CaseIterable, Sendable {
    case lf, crlf, cr

    var displayName: String {
        switch self {
        case .lf:   return "Unix (LF)"
        case .crlf: return "Windows (CRLF)"
        case .cr:   return "Classic Mac (CR)"
        }
    }

    var badge: String {
        switch self {
        case .lf:   return "LF"
        case .crlf: return "CRLF"
        case .cr:   return "CR"
        }
    }

    var literal: String {
        switch self {
        case .lf:   return "\n"
        case .crlf: return "\r\n"
        case .cr:   return "\r"
        }
    }

    /// Converts an LF-normalized buffer back to this ending.
    func applying(to text: String) -> String {
        self == .lf ? text : text.replacingOccurrences(of: "\n", with: literal)
    }

    /// Picks the dominant ending in `text`. A file with no line breaks at all
    /// gets LF, which is also what a brand-new document starts as.
    static func detect(in text: String) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        while let scalar = pending {
            if scalar == "\r" {
                let next = iterator.next()
                if next == "\n" { crlf += 1; pending = iterator.next() }
                else            { cr += 1;   pending = next }
            } else {
                if scalar == "\n" { lf += 1 }
                pending = iterator.next()
            }
        }
        if crlf >= lf && crlf >= cr && crlf > 0 { return .crlf }
        if cr   >  lf && cr   >  crlf           { return .cr }
        return .lf
    }
}

// MARK: - Load result

struct LoadedTextFile {
    let text: String            // always LF-normalized
    let encoding: FileEncoding
    let lineEnding: LineEnding
}

// MARK: - Errors

enum TextFileError: LocalizedError {
    case looksBinary(String)
    case undecodable(String)
    case unrepresentable(FileEncoding)

    var errorDescription: String? {
        switch self {
        case .looksBinary(let name):
            return "\"\(name)\" doesn't look like a text file. Opening it here would show only garbage, and saving would damage it."
        case .undecodable(let name):
            return "\"\(name)\" couldn't be read as text in any encoding Notepad understands."
        case .unrepresentable(let encoding):
            return "Some characters in this document can't be written as \(encoding.displayName)."
        }
    }
}

// MARK: - Reading & writing

enum TextFileIO {

    // MARK: Read

    /// Reads `url` as text, detecting its encoding and line endings.
    /// Throws rather than returning empty content — an empty string that the
    /// caller can't distinguish from a genuinely empty file is what made the
    /// original bug destructive.
    static func read(_ url: URL) throws -> LoadedTextFile {
        let data = try Data(contentsOf: url)
        return try decode(data, name: url.lastPathComponent)
    }

    /// Reads `url` forcing a specific encoding (File ▸ Reopen with Encoding),
    /// for the rare file whose detection guesses wrong.
    static func read(_ url: URL, forcing encoding: FileEncoding) throws -> LoadedTextFile {
        let data = try Data(contentsOf: url)
        let body = stripBOM(data, for: encoding)
        guard let raw = String(data: body, encoding: encoding.stringEncoding) else {
            throw TextFileError.undecodable(url.lastPathComponent)
        }
        return LoadedTextFile(text: normalizeNewlines(raw),
                              encoding: encoding,
                              lineEnding: LineEnding.detect(in: raw))
    }

    static func decode(_ data: Data, name: String) throws -> LoadedTextFile {
        guard !data.isEmpty else {
            return LoadedTextFile(text: "", encoding: .utf8, lineEnding: .lf)
        }

        // 1. Byte-order mark — definitive when present.
        if let (encoding, body) = bomEncoding(data),
           let raw = String(data: body, encoding: encoding.stringEncoding) {
            return finish(raw, encoding)
        }

        // 2. BOM-less UTF-16, which Windows tools do emit. This has to come BEFORE
        //    the UTF-8 attempt: ASCII text in UTF-16 is a NUL between every letter,
        //    and NUL is perfectly valid UTF-8 — so UTF-8 "succeeds" and hands back
        //    a string full of invisible NULs. The giveaway is that the NULs land in
        //    every other byte.
        if let encoding = bomlessUTF16(data),
           let raw = String(data: data, encoding: encoding.stringEncoding) {
            return finish(raw, encoding)
        }

        // 3. Strict UTF-8. Covers almost everything written this century.
        if let raw = String(data: data, encoding: .utf8) {
            return finish(raw, .utf8)
        }

        // 4. Not text at all — refuse instead of showing (and later saving) garbage.
        if looksBinary(data) { throw TextFileError.looksBinary(name) }

        // 5. Single-byte legacy encodings. Windows-1252 first: it is what Excel
        //    writes on Windows and what nearly every stray CSV in the wild is.
        for encoding in [FileEncoding.windowsCP1252, .macRoman, .isoLatin1] {
            if let raw = String(data: data, encoding: encoding.stringEncoding) {
                return finish(raw, encoding)
            }
        }

        throw TextFileError.undecodable(name)
    }

    private static func finish(_ raw: String, _ encoding: FileEncoding) -> LoadedTextFile {
        LoadedTextFile(text: normalizeNewlines(raw),
                       encoding: encoding,
                       lineEnding: LineEnding.detect(in: raw))
    }

    // MARK: Write

    /// Writes `text` atomically, converting back to `lineEnding` and `encoding`.
    /// Throws `.unrepresentable` when the buffer holds characters the target
    /// encoding has no room for, so the caller can offer UTF-8 instead of
    /// quietly dropping them.
    static func write(_ text: String, to url: URL,
                      encoding: FileEncoding, lineEnding: LineEnding) throws {
        let body = lineEnding.applying(to: text)
        guard let encoded = body.data(using: encoding.stringEncoding,
                                      allowLossyConversion: false) else {
            throw TextFileError.unrepresentable(encoding)
        }
        var data = Data(encoding.bom)
        data.append(encoded)
        try data.write(to: url, options: .atomic)
    }

    /// True when `url` already holds a non-empty file — the caller uses this to
    /// confirm before an empty buffer replaces real content.
    static func hasContent(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize ?? 0) > 0
    }

    // MARK: Detection helpers

    private static func bomEncoding(_ data: Data) -> (FileEncoding, Data)? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return (.utf8BOM, data.dropFirst(3))
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return (.utf16LE, data.dropFirst(2))
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return (.utf16BE, data.dropFirst(2))
        }
        return nil
    }

    private static func stripBOM(_ data: Data, for encoding: FileEncoding) -> Data {
        let bom = encoding.bom
        guard !bom.isEmpty, data.count >= bom.count,
              Array(data.prefix(bom.count)) == bom else { return data }
        return data.dropFirst(bom.count)
    }

    /// UTF-16 with no BOM: ASCII-range text puts a NUL in every second byte.
    /// Which half holds the NULs tells us the endianness.
    private static func bomlessUTF16(_ data: Data) -> FileEncoding? {
        let sample = [UInt8](data.prefix(2048))
        guard sample.count >= 16 else { return nil }
        let pairs = sample.count / 2
        var evenNULs = 0, oddNULs = 0
        for i in 0..<pairs {
            if sample[i * 2]     == 0 { evenNULs += 1 }
            if sample[i * 2 + 1] == 0 { oddNULs  += 1 }
        }
        let threshold = Int(Double(pairs) * 0.6)
        if oddNULs  >= threshold && evenNULs < threshold { return .utf16LENoBOM }
        if evenNULs >= threshold && oddNULs  < threshold { return .utf16BENoBOM }
        return nil
    }

    /// A NUL byte, or a heavy run of other control characters, means this is not
    /// text. Checked only after every text decoding has been tried.
    private static func looksBinary(_ data: Data) -> Bool {
        let sample = [UInt8](data.prefix(8192))
        guard !sample.isEmpty else { return false }
        var controls = 0
        for byte in sample {
            if byte == 0 { return true }
            // Everything below 0x20 except tab, newline, carriage return and form feed.
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D, byte != 0x0C {
                controls += 1
            }
        }
        return Double(controls) / Double(sample.count) > 0.10
    }

    static func normalizeNewlines(_ text: String) -> String {
        // Must test at the scalar level: Swift treats "\r\n" as ONE Character, so
        // `text.contains("\r")` is false for a CRLF file and the normalization was
        // skipped entirely — leaving \r\n in the buffer, which the LF→CRLF pass on
        // save then turned into \r\r\n.
        guard text.unicodeScalars.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r",   with: "\n")
    }
}
