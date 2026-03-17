//
//  Repository+reflog.swift
//  SwiftGitX
//

import Foundation
import libgit2

/// An entry in a reference log.
public struct ReflogEntry: Sendable {
    /// The new OID after this reflog entry.
    public let newID: OID

    /// The old OID before this reflog entry.
    public let oldID: OID

    /// The log message for this entry.
    public let message: String

    /// The committer (person who performed the action).
    public let committer: Signature
}

extension Repository {
    /// Read the reflog for the given reference name.
    ///
    /// - Parameter name: The reference name (e.g., "HEAD" or "refs/heads/main").
    ///   Defaults to "HEAD".
    ///
    /// - Returns: An array of ``ReflogEntry`` values, most recent first.
    public func reflog(name: String = "HEAD") throws(SwiftGitXError) -> [ReflogEntry] {
        let reflogPointer = try git(operation: .reflog) {
            var reflogPointer: OpaquePointer?
            let status = git_reflog_read(&reflogPointer, pointer, name)
            return (reflogPointer, status)
        }
        defer { git_reflog_free(reflogPointer) }

        let count = git_reflog_entrycount(reflogPointer)
        var entries = [ReflogEntry]()
        entries.reserveCapacity(count)

        for index in 0..<count {
            guard let entry = git_reflog_entry_byindex(reflogPointer, index) else {
                continue
            }

            let newOID: OID
            if let oidPtr = git_reflog_entry_id_new(entry) {
                newOID = OID(raw: oidPtr.pointee)
            } else {
                newOID = .zero
            }

            let oldOID: OID
            if let oidPtr = git_reflog_entry_id_old(entry) {
                oldOID = OID(raw: oidPtr.pointee)
            } else {
                oldOID = .zero
            }

            let message: String
            if let msgPtr = git_reflog_entry_message(entry) {
                message = String(cString: msgPtr)
            } else {
                message = ""
            }

            let committer: Signature
            if let sigPtr = git_reflog_entry_committer(entry) {
                committer = Signature(pointer: sigPtr)
            } else {
                committer = Signature(name: "Unknown", email: "")
            }

            entries.append(
                ReflogEntry(
                    newID: newOID,
                    oldID: oldOID,
                    message: message,
                    committer: committer
                )
            )
        }

        return entries
    }
}

extension SwiftGitXError.Operation {
    public static let reflog = Self(rawValue: "reflog")
}
