import Foundation

// MARK: - Expanded File

/// A single uploadable file resolved from a user selection (flat file or folder tree).
nonisolated struct ExpandedFile: Sendable {
    let url: URL
    /// Relative path from the dropped ancestor folder, or nil for a directly-selected file.
    let relativePath: String?
}

// MARK: - Folder Expansion

/// Expands a mixed array of file and folder URLs into individual uploadable files.
/// Hidden files (dotfiles) and .DS_Store entries are skipped at every depth.
nonisolated func expandURLs(_ urls: [URL]) -> [ExpandedFile] {
    var result: [ExpandedFile] = []

    for url in urls {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            continue
        }

        if isDir.boolValue {
            result.append(contentsOf: expandFolder(url))
        } else {
            if !isHidden(url.lastPathComponent) {
                result.append(ExpandedFile(url: url, relativePath: nil))
            }
        }
    }

    return result
}

// MARK: - Private Helpers

private nonisolated func expandFolder(_ folderURL: URL) -> [ExpandedFile] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    let folderName = folderURL.lastPathComponent
    var result: [ExpandedFile] = []

    for case let fileURL as URL in enumerator {
        if fileURL.pathComponents.contains(where: { isHidden($0) }) {
            continue
        }

        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            continue
        }

        let relativePath: String
        if let rel = relativePathComponent(of: fileURL, from: folderURL) {
            relativePath = folderName + "/" + rel
        } else {
            relativePath = folderName + "/" + fileURL.lastPathComponent
        }

        result.append(ExpandedFile(url: fileURL, relativePath: relativePath))
    }

    return result
}

private nonisolated func relativePathComponent(of child: URL, from ancestor: URL) -> String? {
    let childComponents = child.standardized.pathComponents
    let ancestorComponents = ancestor.standardized.pathComponents

    guard childComponents.count > ancestorComponents.count,
          childComponents.starts(with: ancestorComponents) else {
        return nil
    }

    return childComponents.dropFirst(ancestorComponents.count).joined(separator: "/")
}

private nonisolated func isHidden(_ name: String) -> Bool {
    name.hasPrefix(".")
}
