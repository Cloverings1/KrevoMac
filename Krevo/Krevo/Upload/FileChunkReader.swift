import Foundation

nonisolated enum FileChunkError: Error, LocalizedError {
    case readFailed(expected: Int, got: Int)
    case fileModified

    var errorDescription: String? {
        switch self {
        case .readFailed(let expected, let got):
            return "Failed to read chunk: expected \(expected) bytes, got \(got)"
        case .fileModified:
            return "File was modified during upload. Please retry with the original file."
        }
    }
}

/// Reads file chunks using pread for thread-safe positioned reads.
/// Multiple threads/tasks can call readChunk simultaneously on the same
/// instance without locks — pread does not modify the file descriptor offset.
nonisolated final class FileChunkReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let filePath: String
    let fileSize: Int64
    let chunkSize: Int
    private let originalModificationDate: Date?

    /// Modification time captured at init via fstat — used for integrity checks.
    private let originalMtimeSec: Int
    private let originalMtimeNsec: Int

    init(url: URL, chunkSize: Int) throws {
        self.fileHandle = try FileHandle(forReadingFrom: url)
        self.filePath = url.path
        self.chunkSize = chunkSize

        // Use fstat on the open descriptor for an atomic snapshot of size + mtime
        var statBuf = stat()
        guard fstat(fileHandle.fileDescriptor, &statBuf) == 0 else {
            try? self.fileHandle.close()
            throw FileChunkError.readFailed(expected: 0, got: 0)
        }
        self.fileSize = Int64(statBuf.st_size)
        self.originalMtimeSec = statBuf.st_mtimespec.tv_sec
        self.originalMtimeNsec = statBuf.st_mtimespec.tv_nsec
        self.originalModificationDate = nil // kept for API compat, fstat fields are authoritative
    }

    /// Check that the file has not been modified since the reader was opened.
    /// Uses fstat(2) on the open file descriptor for an atomic size + mtime check.
    func validateIntegrity() throws {
        var statBuf = stat()
        guard fstat(fileHandle.fileDescriptor, &statBuf) == 0 else {
            throw FileChunkError.fileModified
        }
        if Int64(statBuf.st_size) != fileSize {
            throw FileChunkError.fileModified
        }
        if statBuf.st_mtimespec.tv_sec != originalMtimeSec ||
           statBuf.st_mtimespec.tv_nsec != originalMtimeNsec {
            throw FileChunkError.fileModified
        }
    }

    var totalChunks: Int {
        Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize))
    }

    /// Read chunk at the given zero-based index.
    /// Uses pread(2) for thread-safe positioned reads without seeking.
    func readChunk(at index: Int) throws -> Data {
        let offset = Int64(index) * Int64(chunkSize)
        let length = Int(min(Int64(chunkSize), fileSize - offset))

        guard length > 0 else {
            throw FileChunkError.readFailed(expected: 1, got: 0)
        }

        // Allocate without zero-filling — pread overwrites the entire buffer
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 1)
        let bytesRead = pread(fileHandle.fileDescriptor, buffer, length, off_t(offset))

        guard bytesRead == length else {
            buffer.deallocate()
            throw FileChunkError.readFailed(expected: length, got: bytesRead)
        }

        // Transfer ownership to Data without copying
        return Data(bytesNoCopy: buffer, count: length, deallocator: .custom { ptr, _ in ptr.deallocate() })
    }

    deinit {
        try? fileHandle.close()
    }
}
