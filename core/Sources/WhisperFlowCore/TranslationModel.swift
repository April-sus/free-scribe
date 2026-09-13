import Foundation

/// The local translation model: M2M-100, quantised to int8.
///
/// Downloaded rather than bundled — it is larger than the app by two orders of
/// magnitude, and most people never leave their own language.
public enum TranslationModel {
    /// A CTranslate2 conversion of google/madlad400-3b-mt, Apache-2.0.
    ///
    /// Two M2M-100 sizes were measured before this one. Both translated word by
    /// word: "open source" became an open water spring, "application" became the
    /// kind you fill in for a job, and "what's up" was read as a question about
    /// altitude. MADLAD gets all three right, and its Korean reads as naturally as
    /// Apple's own. It costs about a second per dictation and 2.8GB to download.
    static let repository = "SoybeanMilk/madlad400-3b-mt-ct2-int8_float16"

    /// Everything the sidecar needs and nothing it does not: the weights, the
    /// vocabulary that maps tokens to ids, and the tokeniser itself.
    /// Everything the sidecar needs and nothing it does not: the weights, the
    /// vocabulary that maps tokens to ids, and the tokeniser. Unlike M2M, this
    /// model ships a HuggingFace tokenizer, so there is only one file for it.
    static let files = [
        "config.json",
        "model.bin",
        "shared_vocabulary.json",
        "tokenizer.json",
    ]

    public static let approximateSize = "~2.8 GB"
    public static let languageCount = 98

    public static var directory: URL {
        Transcriber.modelsBase.appending(path: "translation/madlad400-3b-int8")
    }

    public static var isInstalled: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    public static func bytesUsed() -> Int64 {
        files.reduce(0) { total, name in
            let path = directory.appending(path: name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    public static func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Downloads every part, reporting progress across the whole set rather than
    /// restarting the bar for each file.
    public static func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The weights are almost all of it, so weight the bar by real byte counts
        // instead of treating four files as four equal quarters.
        var sizes: [String: Int64] = [:]
        for name in files {
            sizes[name] = try await contentLength(of: name) ?? 0
        }
        let total = max(sizes.values.reduce(0, +), 1)
        var completed: Int64 = 0

        for name in files {
            let destination = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: destination.path) {
                completed += sizes[name] ?? 0
                onProgress(Double(completed) / Double(total))
                continue
            }

            let alreadyDone = completed
            let (temporary, _) = try await URLSession.shared.download(from: url(for: name)) { written, _ in
                onProgress(Double(alreadyDone + written) / Double(total))
            }

            // Moved into place only once complete, so a cancelled download never
            // looks like an installed model.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            completed += sizes[name] ?? 0
            onProgress(Double(completed) / Double(total))
        }
    }

    static func url(for file: String) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/main/\(file)")!
    }

    private static func contentLength(of file: String) async throws -> Int64? {
        var request = URLRequest(url: url(for: file))
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.expectedContentLength
    }
}

private extension URLSession {
    /// `URLSession.download(from:)` reports nothing while it runs, and half a
    /// gigabyte with no progress bar looks like a hang.
    func download(
        from url: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await self.bytes(from: url)
        let expected = response.expectedContentLength

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "free-scribe-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onProgress(written, expected)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            onProgress(written, expected)
        }

        return (temporary, response)
    }
}
