//
//  Repository+rebase.swift
//  SwiftGitX
//

import libgit2

/// The type of a rebase operation.
public enum RebaseOperationType: UInt32, Sendable {
    /// Apply the commit as-is (pick).
    case pick = 0
    /// Reword the commit message.
    case reword = 1
    /// Edit the commit.
    case edit = 2
    /// Squash this commit into the previous one.
    case squash = 3
    /// Fixup this commit into the previous one (discard message).
    case fixup = 4
    /// Execute a command.
    case exec = 5
}

/// A single operation in a rebase sequence.
public struct RebaseOperation: Sendable {
    /// The type of the operation (pick, squash, fixup, etc.).
    public let type: RebaseOperationType

    /// The commit ID associated with this operation.
    public let id: OID
}

/// Manages an in-progress rebase, wrapping the libgit2 rebase pointer.
///
/// A `Rebase` instance is obtained from ``Repository/rebase(onto:)``.
/// The caller drives the rebase by repeatedly calling ``next()``,
/// then ``commit(signature:)`` for each step, and finally ``finish(signature:)``.
public final class Rebase: @unchecked Sendable {
    /// The underlying libgit2 rebase pointer.
    nonisolated(unsafe) private let rebasePointer: OpaquePointer
    /// The repository pointer (kept alive for commit operations).
    nonisolated(unsafe) private let repositoryPointer: OpaquePointer

    /// The total number of operations in this rebase.
    public var operationCount: Int {
        git_rebase_operation_entrycount(rebasePointer)
    }

    /// The index of the current operation, or `nil` if the rebase has not started.
    public var currentOperationIndex: Int? {
        let idx = git_rebase_operation_current(rebasePointer)
        // GIT_REBASE_NO_OPERATION is SIZE_MAX
        return idx == Int.max ? nil : idx
    }

    init(rebasePointer: OpaquePointer, repositoryPointer: OpaquePointer) {
        self.rebasePointer = rebasePointer
        self.repositoryPointer = repositoryPointer
    }

    deinit {
        git_rebase_free(rebasePointer)
    }

    /// Advance to the next operation in the rebase.
    ///
    /// - Returns: The next ``RebaseOperation``, or `nil` if there are no more operations.
    public func next() throws(SwiftGitXError) -> RebaseOperation? {
        var operationPointer: UnsafeMutablePointer<git_rebase_operation>?

        let status = git_rebase_next(&operationPointer, rebasePointer)

        if status == GIT_ITEROVER.rawValue {
            return nil
        }

        try SwiftGitXError.check(status, operation: .rebase)

        guard let op = operationPointer?.pointee else {
            throw SwiftGitXError(
                code: .error, operation: .rebase, category: .rebase,
                message: "Failed to read rebase operation"
            )
        }

        let type = RebaseOperationType(rawValue: op.type.rawValue) ?? .pick
        return RebaseOperation(type: type, id: OID(raw: op.id))
    }

    /// Commit the current rebase operation.
    ///
    /// - Parameter signature: The signature to use for the commit. If `nil`, the default
    ///   signature from the repository configuration is used.
    ///
    /// - Returns: The OID of the newly created commit.
    @discardableResult
    public func commit(signature: Signature? = nil) throws(SwiftGitXError) -> OID {
        let resolvedSignature: Signature
        if let signature {
            resolvedSignature = signature
        } else {
            resolvedSignature = try Signature.default(in: repositoryPointer)
        }
        let signaturePointer = try ObjectFactory.makeSignaturePointer(signature: resolvedSignature)
        defer { git_signature_free(signaturePointer) }

        var oid = git_oid()
        try git(operation: .rebase) {
            git_rebase_commit(&oid, rebasePointer, nil, signaturePointer, nil, nil)
        }

        return OID(raw: oid)
    }

    /// Finish the rebase, cleaning up rebase state files.
    ///
    /// - Parameter signature: The signature for the reflog entry. If `nil`, the default
    ///   signature from the repository configuration is used.
    public func finish(signature: Signature? = nil) throws(SwiftGitXError) {
        let resolvedSignature: Signature
        if let signature {
            resolvedSignature = signature
        } else {
            resolvedSignature = try Signature.default(in: repositoryPointer)
        }
        let signaturePointer = try ObjectFactory.makeSignaturePointer(signature: resolvedSignature)
        defer { git_signature_free(signaturePointer) }

        try git(operation: .rebase) {
            git_rebase_finish(rebasePointer, signaturePointer)
        }
    }

    /// Abort the in-progress rebase, restoring the repository to its original state.
    public func abort() throws(SwiftGitXError) {
        try git(operation: .rebase) {
            git_rebase_abort(rebasePointer)
        }
    }
}

extension Repository {
    /// Begin a rebase of the current branch onto the given branch.
    ///
    /// - Parameter branch: The branch to rebase onto.
    ///
    /// - Returns: A ``Rebase`` instance that can be used to drive the rebase operation.
    ///
    /// After calling this method, use the returned ``Rebase`` object to iterate through
    /// each operation with ``Rebase/next()``, commit with ``Rebase/commit(signature:)``,
    /// and finish with ``Rebase/finish(signature:)``.
    public func rebase(onto branch: Branch) throws(SwiftGitXError) -> Rebase {
        // Create an annotated commit from the branch reference
        let branchRefPointer = try ReferenceFactory.lookupBranchPointer(
            name: branch.name,
            type: branch.type.raw,
            repositoryPointer: pointer
        )
        defer { git_reference_free(branchRefPointer) }

        let ontoAnnotated = try git(operation: .rebase) {
            var annotatedCommitPointer: OpaquePointer?
            let status = git_annotated_commit_from_ref(
                &annotatedCommitPointer,
                pointer,
                branchRefPointer
            )
            return (annotatedCommitPointer, status)
        }
        defer { git_annotated_commit_free(ontoAnnotated) }

        // Initialize the rebase
        var rebaseOptions = git_rebase_options()
        git_rebase_options_init(&rebaseOptions, UInt32(GIT_REBASE_OPTIONS_VERSION))

        let rebasePointer = try git(operation: .rebase) {
            var rebasePointer: OpaquePointer?
            let status = git_rebase_init(
                &rebasePointer,
                pointer,
                nil,  // branch (HEAD)
                nil,  // upstream (will be computed)
                ontoAnnotated,
                &rebaseOptions
            )
            return (rebasePointer, status)
        }

        return Rebase(rebasePointer: rebasePointer, repositoryPointer: pointer)
    }

    /// Open an existing in-progress rebase.
    ///
    /// - Returns: A ``Rebase`` instance for the in-progress rebase.
    ///
    /// This is useful for resuming a rebase after resolving conflicts.
    public func openRebase() throws(SwiftGitXError) -> Rebase {
        var rebaseOptions = git_rebase_options()
        git_rebase_options_init(&rebaseOptions, UInt32(GIT_REBASE_OPTIONS_VERSION))

        let rebasePointer = try git(operation: .rebase) {
            var rebasePointer: OpaquePointer?
            let status = git_rebase_open(&rebasePointer, pointer, &rebaseOptions)
            return (rebasePointer, status)
        }

        return Rebase(rebasePointer: rebasePointer, repositoryPointer: pointer)
    }
}

extension SwiftGitXError.Operation {
    public static let rebase = Self(rawValue: "rebase")
}
