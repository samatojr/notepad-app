import Foundation
import Testing
@testable import Notepad

// Regression tests for the file I/O bugs fixed in 3.3 and 3.4.
//
// Every test here stands for a bug that shipped. The originals were all
// data-destructive in the same way: a file failed to decode, opened BLANK, and
// the next ⌘S wrote that blankness over the user's content. The assertions are
// written against that failure mode — "did not silently return empty" matters
// as much as "returned the right text".

@MainActor
struct FileIOTests {

    // MARK: - Line ending normalization
    //
    // Shipped bug (3.4): the guard was written `text.contains("\r")`, which is
    // FALSE for a CRLF file — Swift treats "\r\n" as ONE Character, so the
    // grapheme never equals "\r". Normalization was skipped entirely, the buffer
    // kept its \r\n, and the LF→CRLF pass on save turned every one into \r\r\n.

    @Test("CRLF normalizes to LF with no carriage returns left behind")
    func normalizeCRLF() {
        let normalized = TextFileIO.normalizeNewlines("one\r\ntwo\r\nthree")
        #expect(normalized == "one\ntwo\nthree")
        // The assertion that actually catches the bug: test at the SCALAR level,
        // because `contains("\r")` is exactly what was wrong in the first place.
        #expect(!normalized.unicodeScalars.contains("\r"))
    }

    @Test("Classic Mac CR normalizes to LF")
    func normalizeCR() {
        let normalized = TextFileIO.normalizeNewlines("one\rtwo\rthree")
        #expect(normalized == "one\ntwo\nthree")
        #expect(!normalized.unicodeScalars.contains("\r"))
    }

    @Test("Mixed endings all collapse to LF")
    func normalizeMixed() {
        let normalized = TextFileIO.normalizeNewlines("a\r\nb\rc\nd")
        #expect(normalized == "a\nb\nc\nd")
        #expect(!normalized.unicodeScalars.contains("\r"))
    }

    @Test("LF-only text is returned untouched")
    func normalizeLFIsNoOp() {
        #expect(TextFileIO.normalizeNewlines("a\nb\nc") == "a\nb\nc")
    }

    // MARK: - Line ending detection

    @Test("Detects the dominant line ending", arguments: [
        ("one\r\ntwo\r\n",  LineEnding.crlf),
        ("one\ntwo\n",      LineEnding.lf),
        ("one\rtwo\r",      LineEnding.cr),
        ("no breaks here",  LineEnding.lf),   // a file with none defaults to LF
        ("",                LineEnding.lf),
    ])
    func detectLineEnding(text: String, expected: LineEnding) {
        #expect(LineEnding.detect(in: text) == expected)
    }

    @Test("A CRLF file with one stray LF is still a CRLF file")
    func detectMostlyCRLF() {
        #expect(LineEnding.detect(in: "a\r\nb\r\nc\nd\r\n") == .crlf)
    }

    @Test("applying() converts LF back to the target ending")
    func applyLineEnding() {
        #expect(LineEnding.crlf.applying(to: "a\nb") == "a\r\nb")
        #expect(LineEnding.cr.applying(to: "a\nb")   == "a\rb")
        #expect(LineEnding.lf.applying(to: "a\nb")   == "a\nb")
    }

    // MARK: - Byte-exact round trips
    //
    // The strongest regression test in this file: read a file, write it straight
    // back, and demand the bytes are identical. This is the single test that
    // would have caught the \r\r\n bug before it shipped.

    @Test("CRLF file round-trips byte-for-byte")
    func roundTripCRLF() throws {
        let original = Data("line one\r\nline two\r\nline three\r\n".utf8)
        try withTempFile(original) { url in
            let loaded = try TextFileIO.read(url)
            #expect(loaded.text == "line one\nline two\nline three\n")
            #expect(loaded.lineEnding == .crlf)
            #expect(loaded.encoding == .utf8)

            try TextFileIO.write(loaded.text, to: url,
                                 encoding: loaded.encoding, lineEnding: loaded.lineEnding)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test("Classic Mac CR file round-trips byte-for-byte")
    func roundTripCR() throws {
        let original = Data("alpha\rbeta\rgamma".utf8)
        try withTempFile(original) { url in
            let loaded = try TextFileIO.read(url)
            #expect(loaded.text == "alpha\nbeta\ngamma")
            #expect(loaded.lineEnding == .cr)

            try TextFileIO.write(loaded.text, to: url,
                                 encoding: loaded.encoding, lineEnding: loaded.lineEnding)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test("UTF-8 BOM survives the round trip")
    func roundTripUTF8BOM() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("héllo wörld\n".utf8)
        try withTempFile(original) { url in
            let loaded = try TextFileIO.read(url)
            #expect(loaded.encoding == .utf8BOM)
            #expect(loaded.text == "héllo wörld\n")   // BOM stripped from the buffer

            try TextFileIO.write(loaded.text, to: url,
                                 encoding: loaded.encoding, lineEnding: loaded.lineEnding)
            #expect(try Data(contentsOf: url) == original)   // BOM written back
        }
    }

    @Test("Windows-1252 CRLF file — the Excel CSV case — round-trips byte-for-byte")
    func roundTripCP1252() throws {
        // "Café,naïve\r\n" in Windows-1252: 0xE9 and 0xEF are NOT valid UTF-8.
        let original = Data([0x43, 0x61, 0x66, 0xE9, 0x2C,
                             0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0D, 0x0A])
        try withTempFile(original) { url in
            let loaded = try TextFileIO.read(url)
            #expect(loaded.encoding == .windowsCP1252)
            #expect(loaded.lineEnding == .crlf)
            #expect(loaded.text == "Café,naïve\n")

            try TextFileIO.write(loaded.text, to: url,
                                 encoding: loaded.encoding, lineEnding: loaded.lineEnding)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    // MARK: - BOM-less UTF-16
    //
    // Shipped bug (3.4): ASCII encoded as UTF-16 puts a NUL between every
    // letter — and NUL is perfectly valid UTF-8. So the strict UTF-8 attempt
    // "succeeded" and handed back a string full of invisible NULs. Detection of
    // BOM-less UTF-16 has to run BEFORE the UTF-8 attempt.

    @Test("BOM-less UTF-16 LE is detected before the UTF-8 attempt can claim it")
    func bomlessUTF16LE() throws {
        let text = "Hello, world!\nSecond line\n"
        let data = Data(text.unicodeScalars.flatMap { scalar -> [UInt8] in
            let code = UInt16(scalar.value)
            return [UInt8(code & 0xFF), UInt8(code >> 8)]     // little endian
        })
        let loaded = try TextFileIO.decode(data, name: "utf16le.txt")
        #expect(loaded.encoding == .utf16LENoBOM)
        #expect(loaded.text == text)
        // The bug's fingerprint: the old path produced a string riddled with NULs.
        #expect(!loaded.text.unicodeScalars.contains("\0"))
    }

    @Test("BOM-less UTF-16 BE is detected")
    func bomlessUTF16BE() throws {
        let text = "Hello, world!\nSecond line\n"
        let data = Data(text.unicodeScalars.flatMap { scalar -> [UInt8] in
            let code = UInt16(scalar.value)
            return [UInt8(code >> 8), UInt8(code & 0xFF)]     // big endian
        })
        let loaded = try TextFileIO.decode(data, name: "utf16be.txt")
        #expect(loaded.encoding == .utf16BENoBOM)
        #expect(loaded.text == text)
        #expect(!loaded.text.unicodeScalars.contains("\0"))
    }

    @Test("BOM-less UTF-16 is written back without a BOM it never had")
    func bomlessUTF16KeepsNoBOM() throws {
        #expect(FileEncoding.utf16LENoBOM.bom.isEmpty)
        #expect(FileEncoding.utf16BENoBOM.bom.isEmpty)
        try withTempFile(Data()) { url in
            try TextFileIO.write("hi", to: url, encoding: .utf16LENoBOM, lineEnding: .lf)
            let written = try Data(contentsOf: url)
            #expect(Array(written.prefix(2)) == [0x68, 0x00])   // 'h', not a BOM
        }
    }

    @Test("UTF-16 with a BOM round-trips with its BOM")
    func roundTripUTF16LEWithBOM() throws {
        let original = Data([0xFF, 0xFE]) + Data("ok\n".unicodeScalars.flatMap {
            [UInt8(UInt16($0.value) & 0xFF), UInt8(UInt16($0.value) >> 8)]
        })
        try withTempFile(original) { url in
            let loaded = try TextFileIO.read(url)
            #expect(loaded.encoding == .utf16LE)
            #expect(loaded.text == "ok\n")
            try TextFileIO.write(loaded.text, to: url,
                                 encoding: loaded.encoding, lineEnding: loaded.lineEnding)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    // MARK: - Refusing to open what it can't save
    //
    // Shipped bug (3.3/3.4): three of the four load paths swallowed the failure
    // with `?? ""`. A binary file opened blank and ⌘S destroyed it. Reading must
    // THROW, never hand back an empty document the caller can't tell apart from
    // a genuinely empty file.

    @Test("Binary data is refused, not opened as an empty document")
    func binaryIsRefused() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                        0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10,
                        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0xF3, 0xFF, 0x61])
        #expect(throws: TextFileError.self) {
            _ = try TextFileIO.decode(png, name: "image.png")
        }
    }

    @Test("A genuinely empty file opens as empty — and does not throw")
    func emptyFileIsNotAnError() throws {
        let loaded = try TextFileIO.decode(Data(), name: "empty.txt")
        #expect(loaded.text.isEmpty)
        #expect(loaded.encoding == .utf8)
        #expect(loaded.lineEnding == .lf)
    }

    @Test("Characters the target encoding cannot represent throw instead of being dropped")
    func unrepresentableThrows() throws {
        try withTempFile(Data()) { url in
            #expect(throws: TextFileError.self) {
                // An emoji has no Windows-1252 representation. Writing lossily
                // would silently mangle the user's document.
                try TextFileIO.write("emoji 🎉", to: url,
                                     encoding: .windowsCP1252, lineEnding: .lf)
            }
        }
    }

    @Test("hasContent distinguishes a real file from an empty one")
    func hasContentGuard() throws {
        try withTempFile(Data("x".utf8)) { url in
            #expect(TextFileIO.hasContent(at: url))
        }
        try withTempFile(Data()) { url in
            #expect(!TextFileIO.hasContent(at: url))
        }
        let missing = URL(fileURLWithPath: "/nonexistent/notepad-test-\(UUID().uuidString)")
        #expect(!TextFileIO.hasContent(at: missing))
    }

    // MARK: - Forced re-open (File ▸ Reopen with Encoding)

    @Test("Reopening with an explicit encoding strips that encoding's BOM")
    func forcedReopenStripsBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("plain\n".utf8)
        try withTempFile(data) { url in
            let loaded = try TextFileIO.read(url, forcing: .utf8BOM)
            #expect(loaded.text == "plain\n")
            #expect(loaded.encoding == .utf8BOM)
        }
    }

    @Test("Reopening with an encoding that cannot decode the bytes throws")
    func forcedReopenFailureThrows() throws {
        // A lone 0xE9 is not valid UTF-8.
        try withTempFile(Data([0x43, 0x61, 0x66, 0xE9])) { url in
            #expect(throws: TextFileError.self) {
                _ = try TextFileIO.read(url, forcing: .utf8)
            }
        }
    }

    // MARK: - Menu surface

    @Test("The menu offers only the unambiguous encodings")
    func menuOmitsBOMlessUTF16() {
        // The BOM-less forms exist to round-trip a file that arrived that way,
        // never as something a user picks: choosing "UTF-16" should get a BOM.
        #expect(!FileEncoding.menuCases.contains(.utf16LENoBOM))
        #expect(!FileEncoding.menuCases.contains(.utf16BENoBOM))
        #expect(FileEncoding.menuCases.contains(.utf8))
        #expect(FileEncoding.menuCases.contains(.windowsCP1252))
    }
}

// MARK: - Helpers

/// Writes `data` to a unique temp file, runs `body`, and always cleans up.
private func withTempFile(_ data: Data, _ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("notepad-test-\(UUID().uuidString).txt")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}
