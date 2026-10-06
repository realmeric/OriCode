import Foundation

/// The pictures you sent, at the size they went out. The message keeps only a small preview for
/// its bubble, which enlarged would be a blur, so each picture is kept as a file for Quick Look
/// to show: a folder a thread, a folder a message inside it, so a thread's go with it.
struct SentPictures: Sendable {
    /// One picture as it went to the engine, without the image an attachment draws itself with,
    /// which can't leave the main thread.
    struct Picture: Sendable {
        let data: Data
        let mediaType: String
    }

    let root: URL
    /// Where a picture with no file is shown from: its preview, written out when it's asked for.
    let temporary: URL

    /// The build's own, so OriCode Molten never reads or removes OriCode's.
    static let standard = SentPictures(
        root: Build.support.appending(path: "Images", directoryHint: .isDirectory),
        temporary: FileManager.default.temporaryDirectory.appending(path: "\(Build.folder) Images", directoryHint: .isDirectory))

    /// Every read and write waits its turn here and none on the main thread, so a send never waits
    /// on the disk, and a picture opened the moment it's sent finds the file its send wrote.
    private static let disk = DispatchQueue(label: "SentPictures.disk", qos: .utility)

    func folder(of thread: UUID) -> URL {
        root.appending(path: thread.uuidString, directoryHint: .isDirectory)
    }

    func folder(of message: UUID, in thread: UUID) -> URL {
        folder(of: thread).appending(path: message.uuidString, directoryHint: .isDirectory)
    }

    /// Named for what Quick Look's title says, counted from one.
    func file(thread: UUID, message: UUID, index: Int, mediaType: String) -> URL {
        folder(of: message, in: thread).appending(path: Self.name(index, mediaType: mediaType), directoryHint: .notDirectory)
    }

    private static func name(_ index: Int, mediaType: String) -> String {
        "Image \(index + 1).\(mediaType == "image/png" ? "png" : "jpg")"
    }

    func save(_ pictures: [Picture], thread: UUID, message: UUID) {
        guard !pictures.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder(of: message, in: thread), withIntermediateDirectories: true)
        for (index, picture) in pictures.enumerated() {
            try? picture.data.write(to: file(thread: thread, message: message, index: index, mediaType: picture.mediaType), options: .atomic)
        }
    }

    /// The file a picture was kept in, whichever of the two kinds it went out as.
    func find(thread: UUID, message: UUID, index: Int) -> URL? {
        ["image/png", "image/jpeg"]
            .map { file(thread: thread, message: message, index: index, mediaType: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What a click shows: the picture's file, or its preview written out when there's none, as
    /// for a message from before pictures were kept, so a click always shows something.
    func open(thread: UUID?, message: UUID, index: Int, preview: Data) -> URL? {
        if let thread, let kept = find(thread: thread, message: message, index: index) { return kept }
        let written = temporary.appending(path: message.uuidString, directoryHint: .isDirectory)
        let file = written.appending(path: Self.name(index, mediaType: "image/jpeg"), directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        do {
            try FileManager.default.createDirectory(at: written, withIntermediateDirectories: true)
            try preview.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    func remove(thread: UUID) {
        try? FileManager.default.removeItem(at: folder(of: thread))
    }

    func remove(message: UUID, in thread: UUID) {
        try? FileManager.default.removeItem(at: folder(of: message, in: thread))
    }
}

/// The same, from the main thread and off it.
extension SentPictures {
    func keep(_ images: [ImageAttachment], thread: UUID, message: UUID) {
        guard !images.isEmpty else { return }
        // Already encoded for the engine: nothing is drawn or compressed again.
        let pictures = images.map { Picture(data: $0.data, mediaType: $0.mediaType) }
        Self.disk.async { save(pictures, thread: thread, message: message) }
    }

    /// A message's pictures as Quick Look takes them, one for each preview and nil where even
    /// the preview couldn't be written.
    func opened(thread: UUID?, message: UUID, previews: [Data]) async -> [URL?] {
        await withCheckedContinuation { continuation in
            Self.disk.async {
                continuation.resume(returning: previews.indices.map {
                    open(thread: thread, message: message, index: $0, preview: previews[$0])
                })
            }
        }
    }

    /// A thread deleted for good takes its pictures with it.
    func forget(thread: UUID) {
        Self.disk.async { remove(thread: thread) }
    }

    /// A message that never ran went back to the composer, where sent again it's a new one.
    func forget(message: UUID, in thread: UUID) {
        Self.disk.async { remove(message: message, in: thread) }
    }
}
