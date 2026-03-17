//
//  Repository+blame.swift
//  SwiftGitX
//

import Foundation
import libgit2

/// A hunk of blame information representing one or more contiguous lines
/// that were last changed by the same commit.
public struct BlameHunk: Sendable {
    /// The OID of the commit that last changed these lines.
    public let commitID: OID

    /// The author signature of the commit.
    public let author: Signature

    /// The committer signature of the commit.
    public let committer: Signature

    /// The 1-based line number where this hunk begins in the final file.
    public let startLineNumber: Int

    /// The number of lines in this hunk.
    public let lineCount: Int

    /// The original path of the file in the commit that introduced the change.
    public let originalPath: String?

    /// The 1-based line number where this hunk begins in the original file.
    public let originalStartLineNumber: Int
}

extension Repository {
    /// Get the blame information for a file.
    ///
    /// - Parameter path: The path to the file, relative to the repository working directory.
    ///
    /// - Returns: An array of ``BlameHunk`` values describing the authorship of each section
    ///   of the file.
    public func blame(path: String) throws(SwiftGitXError) -> [BlameHunk] {
        var options = git_blame_options()
        git_blame_options_init(&options, UInt32(GIT_BLAME_OPTIONS_VERSION))

        let blamePointer = try git(operation: .blame) {
            var blamePointer: OpaquePointer?
            let status = git_blame_file(&blamePointer, pointer, path, &options)
            return (blamePointer, status)
        }
        defer { git_blame_free(blamePointer) }

        let hunkCount = git_blame_hunkcount(blamePointer)
        var hunks = [BlameHunk]()
        hunks.reserveCapacity(hunkCount)

        for index in 0..<hunkCount {
            guard let rawHunk = git_blame_hunk_byindex(blamePointer, index) else {
                continue
            }

            let hunk = rawHunk.pointee

            let author: Signature
            if let sig = hunk.final_signature {
                author = Signature(pointer: sig)
            } else {
                author = Signature(name: "Unknown", email: "")
            }

            let committer: Signature
            if let sig = hunk.final_committer {
                committer = Signature(pointer: sig)
            } else {
                committer = author
            }

            let originalPath: String?
            if let path = hunk.orig_path {
                originalPath = String(cString: path)
            } else {
                originalPath = nil
            }

            hunks.append(
                BlameHunk(
                    commitID: OID(raw: hunk.final_commit_id),
                    author: author,
                    committer: committer,
                    startLineNumber: Int(hunk.final_start_line_number),
                    lineCount: Int(hunk.lines_in_hunk),
                    originalPath: originalPath,
                    originalStartLineNumber: Int(hunk.orig_start_line_number)
                )
            )
        }

        return hunks
    }

    /// Get the blame information for a file at a URL.
    ///
    /// - Parameter file: The URL to the file inside the repository.
    ///
    /// - Returns: An array of ``BlameHunk`` values.
    public func blame(file: URL) throws(SwiftGitXError) -> [BlameHunk] {
        let relativePath = try file.relativePath(from: workingDirectory)
        return try blame(path: relativePath)
    }
}

extension SwiftGitXError.Operation {
    public static let blame = Self(rawValue: "blame")
}
