//
//  Repository+apply.swift
//  SwiftGitX
//

import libgit2

/// The location to apply a diff.
public enum ApplyLocation: Sendable {
    /// Apply the diff to the working directory.
    case workdir
    /// Apply the diff to the index (staging area).
    case index
    /// Apply the diff to both the index and the working directory.
    case both

    /// The corresponding libgit2 apply location value.
    var raw: git_apply_location_t {
        switch self {
        case .workdir:
            return GIT_APPLY_LOCATION_WORKDIR
        case .index:
            return GIT_APPLY_LOCATION_INDEX
        case .both:
            return GIT_APPLY_LOCATION_BOTH
        }
    }
}

extension Repository {
    /// Apply a diff string to the repository.
    ///
    /// - Parameters:
    ///   - diffString: A unified diff string (e.g., the output of `git diff`).
    ///   - location: Where to apply the diff. Defaults to ``ApplyLocation/both``.
    ///
    /// This is the foundation for hunk-level and line-level staging: build a diff
    /// string containing only the desired hunks/lines and apply it to the index.
    public func apply(diffString: String, location: ApplyLocation = .both) throws(SwiftGitXError) {
        // Allocate a C string copy on the heap so we can pass it to libgit2
        // without needing a closure that breaks typed throws.
        let length = diffString.utf8.count
        let cString = strdup(diffString)
        defer { free(cString) }

        guard let cString else {
            throw SwiftGitXError(
                code: .error, operation: .apply, category: .patch,
                message: "Failed to allocate diff string"
            )
        }

        let diffPointer = try git(operation: .apply) {
            var diffPtr: OpaquePointer?
            let status = git_diff_from_buffer(&diffPtr, cString, length)
            return (diffPtr, status)
        }
        defer { git_diff_free(diffPointer) }

        var options = git_apply_options()
        git_apply_options_init(&options, UInt32(GIT_APPLY_OPTIONS_VERSION))

        try git(operation: .apply) {
            git_apply(pointer, diffPointer, location.raw, &options)
        }
    }

    /// Apply a diff to the repository using the diff's internal patch representation.
    ///
    /// - Parameters:
    ///   - diff: The ``Diff`` to apply. The diff is serialized to unified diff format
    ///     and then applied via libgit2.
    ///   - location: Where to apply the diff. Defaults to ``ApplyLocation/both``.
    ///
    /// The diff is reconstructed as a unified diff string from its patches and applied.
    /// For hunk-level staging, build a diff containing only the desired hunks and apply
    /// it to ``ApplyLocation/index``.
    public func apply(diff: Diff, location: ApplyLocation = .both) throws(SwiftGitXError) {
        let diffText = serializeDiff(diff)

        guard !diffText.isEmpty else {
            // Nothing to apply
            return
        }

        try apply(diffString: diffText, location: location)
    }

    // MARK: - Private helpers

    /// Serialize a Diff back to unified diff text by reconstructing each patch.
    private func serializeDiff(_ diff: Diff) -> String {
        var text = ""

        for patch in diff.patches {
            let oldPath = patch.delta.oldFile.path
            let newPath = patch.delta.newFile.path

            // File header
            text += "diff --git a/\(oldPath) b/\(newPath)\n"

            switch patch.delta.type {
            case .added:
                text += "new file mode 100644\n"
                text += "--- /dev/null\n"
                text += "+++ b/\(newPath)\n"
            case .deleted:
                text += "deleted file mode 100644\n"
                text += "--- a/\(oldPath)\n"
                text += "+++ /dev/null\n"
            default:
                text += "--- a/\(oldPath)\n"
                text += "+++ b/\(newPath)\n"
            }

            // Hunks
            for hunk in patch.hunks {
                text += hunk.header
                // Ensure the header ends with a newline
                if !hunk.header.hasSuffix("\n") {
                    text += "\n"
                }

                for line in hunk.lines {
                    text += line.type.rawValue
                    text += line.content
                    // Ensure each line ends with newline (unless it's an EOF marker)
                    if !line.content.hasSuffix("\n") {
                        text += "\n"
                    }
                }
            }
        }

        return text
    }
}

extension SwiftGitXError.Operation {
    public static let apply = Self(rawValue: "apply")
}
