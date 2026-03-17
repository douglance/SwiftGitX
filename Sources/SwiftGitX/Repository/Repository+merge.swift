//
//  Repository+merge.swift
//  SwiftGitX
//

import Foundation
import libgit2

/// Result of a merge operation.
public enum MergeResult: Sendable {
    /// The branch is already up-to-date with HEAD.
    case upToDate
    /// The merge was performed as a fast-forward.
    case fastForward
    /// A normal merge was performed and a merge commit was created.
    case merged
    /// The merge resulted in conflicts that must be resolved.
    case conflict
}

extension Repository {
    /// Merge the given branch into HEAD.
    ///
    /// - Parameter branch: The branch to merge into HEAD.
    ///
    /// - Returns: A ``MergeResult`` indicating what happened.
    ///
    /// If the merge is a fast-forward, HEAD and the working directory are updated
    /// to match the branch tip. If a normal merge is required and there are no
    /// conflicts, a merge commit is created automatically. If conflicts are
    /// detected, the index is left in a conflicted state and `.conflict` is
    /// returned so the caller can resolve them.
    public func merge(branch: Branch) throws(SwiftGitXError) -> MergeResult {
        // 1. Look up the reference for the branch
        let branchRefPointer = try ReferenceFactory.lookupBranchPointer(
            name: branch.name,
            type: branch.type.raw,
            repositoryPointer: pointer
        )
        defer { git_reference_free(branchRefPointer) }

        // 2. Create an annotated commit from the branch reference
        let annotatedCommit = try git(operation: .merge) {
            var annotatedCommitPointer: OpaquePointer?
            let status = git_annotated_commit_from_ref(
                &annotatedCommitPointer,
                pointer,
                branchRefPointer
            )
            return (annotatedCommitPointer, status)
        }
        defer { git_annotated_commit_free(annotatedCommit) }

        // 3. Perform merge analysis
        var analysis = GIT_MERGE_ANALYSIS_NONE
        var preference = GIT_MERGE_PREFERENCE_NONE

        var theirHead: OpaquePointer? = annotatedCommit
        try git(operation: .merge) {
            git_merge_analysis(
                &analysis,
                &preference,
                pointer,
                &theirHead,
                1
            )
        }

        // 4. Act on the analysis result
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return .upToDate
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            return try performFastForward(annotatedCommit: annotatedCommit)
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 {
            return try performNormalMerge(
                annotatedCommit: annotatedCommit,
                branchName: branch.name
            )
        }

        // If we reach here, no merge is possible
        throw SwiftGitXError(
            code: .error,
            operation: .merge,
            category: .merge,
            message: "Merge analysis returned unexpected result"
        )
    }

    // MARK: - Private Helpers

    /// Perform a fast-forward merge by moving HEAD to the target commit.
    private func performFastForward(
        annotatedCommit: OpaquePointer
    ) throws(SwiftGitXError) -> MergeResult {
        // Get the target OID from the annotated commit
        guard let targetOID = git_annotated_commit_id(annotatedCommit) else {
            throw SwiftGitXError(
                code: .error, operation: .merge, category: .merge,
                message: "Failed to get target OID from annotated commit"
            )
        }

        // Checkout the target commit tree
        let targetCommitPointer = try ObjectFactory.lookupObjectPointer(
            oid: targetOID.pointee,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(targetCommitPointer) }

        var checkoutOptions = git_checkout_options()
        git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        try git(operation: .merge) {
            git_checkout_tree(pointer, targetCommitPointer, &checkoutOptions)
        }

        // Update HEAD to the new target
        let headRef = try git(operation: .merge) {
            var headRefPointer: OpaquePointer?
            let status = git_repository_head(&headRefPointer, pointer)
            return (headRefPointer, status)
        }
        defer { git_reference_free(headRef) }

        var oid = targetOID.pointee
        let newRef = try git(operation: .merge) {
            var newRefPointer: OpaquePointer?
            let status = git_reference_set_target(
                &newRefPointer,
                headRef,
                &oid,
                "merge: Fast-forward"
            )
            return (newRefPointer, status)
        }
        git_reference_free(newRef)

        return .fastForward
    }

    /// Perform a normal (three-way) merge.
    private func performNormalMerge(
        annotatedCommit: OpaquePointer,
        branchName: String
    ) throws(SwiftGitXError) -> MergeResult {
        // Perform the merge into the index and working directory
        var mergeOptions = git_merge_options()
        git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))

        var checkoutOptions = git_checkout_options()
        git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue

        var theirHead: OpaquePointer? = annotatedCommit
        try git(operation: .merge) {
            git_merge(
                pointer,
                &theirHead,
                1,
                &mergeOptions,
                &checkoutOptions
            )
        }

        // Check for conflicts
        let indexPointer = try git(operation: .merge) {
            var indexPointer: OpaquePointer?
            let status = git_repository_index(&indexPointer, pointer)
            return (indexPointer, status)
        }
        defer { git_index_free(indexPointer) }

        if git_index_has_conflicts(indexPointer) != 0 {
            // Leave the repository in the merge state so the user can resolve conflicts
            return .conflict
        }

        // No conflicts -- create the merge commit
        try createMergeCommit(branchName: branchName, indexPointer: indexPointer)

        // Clean up the merge state
        try git(operation: .merge) {
            git_repository_state_cleanup(pointer)
        }

        return .merged
    }

    /// Create a merge commit from the current index state.
    private func createMergeCommit(
        branchName: String,
        indexPointer: OpaquePointer
    ) throws(SwiftGitXError) {
        // Write the index as a tree
        var treeOID = git_oid()
        try git(operation: .merge) {
            git_index_write_tree(&treeOID, indexPointer)
        }

        let treePointer = try ObjectFactory.lookupObjectPointer(
            oid: treeOID,
            type: GIT_OBJECT_TREE,
            repositoryPointer: pointer
        )
        defer { git_object_free(treePointer) }

        // Get HEAD commit (our parent)
        let headRef = try git(operation: .merge) {
            var headRefPointer: OpaquePointer?
            let status = git_repository_head(&headRefPointer, pointer)
            return (headRefPointer, status)
        }
        defer { git_reference_free(headRef) }

        guard let headTargetOID = git_reference_target(headRef) else {
            throw SwiftGitXError(
                code: .error, operation: .merge, category: .merge,
                message: "HEAD has no target"
            )
        }

        let headCommitPointer = try ObjectFactory.lookupObjectPointer(
            oid: headTargetOID.pointee,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_commit_free(headCommitPointer) }

        // Get the merge head (their parent) from MERGE_HEAD file
        let mergeHeadOID = try readMergeHead()
        let mergeCommitPointer = try ObjectFactory.lookupObjectPointer(
            oid: mergeHeadOID,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_commit_free(mergeCommitPointer) }

        // Get default signature
        let signature = try Signature.default(in: pointer)
        let signaturePointer = try ObjectFactory.makeSignaturePointer(signature: signature)
        defer { git_signature_free(signaturePointer) }

        // Create the merge commit with two parents
        let message = "Merge branch '\(branchName)'"

        var commitOID = git_oid()

        // Build the parents array for git_commit_create
        var parents: [OpaquePointer?] = [headCommitPointer, mergeCommitPointer]

        let status = parents.withUnsafeMutableBufferPointer { buffer in
            git_commit_create(
                &commitOID,
                pointer,
                "HEAD",
                signaturePointer,
                signaturePointer,
                nil,
                message,
                treePointer,
                2,
                buffer.baseAddress
            )
        }
        try SwiftGitXError.check(status, operation: .merge)
    }

    /// Read the MERGE_HEAD file to get the OID of the commit being merged.
    private func readMergeHead() throws(SwiftGitXError) -> git_oid {
        // MERGE_HEAD is stored in the .git directory
        let gitDir = String(cString: git_repository_path(pointer))
        let mergeHeadPath = gitDir + "MERGE_HEAD"

        guard let contents = try? String(contentsOfFile: mergeHeadPath, encoding: .utf8) else {
            throw SwiftGitXError(
                code: .notFound, operation: .merge, category: .merge,
                message: "MERGE_HEAD not found"
            )
        }

        let hex = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        var oid = git_oid()
        try git(operation: .merge) {
            git_oid_fromstr(&oid, hex)
        }

        return oid
    }

    /// Abort a merge in progress, restoring the repository to its pre-merge state.
    public func mergeAbort() throws(SwiftGitXError) {
        // Reset the index and working directory to HEAD
        let headRef = try git(operation: .merge) {
            var headRefPointer: OpaquePointer?
            let status = git_repository_head(&headRefPointer, pointer)
            return (headRefPointer, status)
        }
        defer { git_reference_free(headRef) }

        guard let headTargetOID = git_reference_target(headRef) else {
            throw SwiftGitXError(
                code: .error, operation: .merge, category: .merge,
                message: "HEAD has no target"
            )
        }

        let headCommitPointer = try ObjectFactory.lookupObjectPointer(
            oid: headTargetOID.pointee,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(headCommitPointer) }

        // Reset the index and working directory to HEAD
        try git(operation: .merge) {
            git_reset(pointer, headCommitPointer, GIT_RESET_HARD, nil)
        }

        // Clean up merge state files (MERGE_HEAD, MERGE_MSG, etc.)
        try git(operation: .merge) {
            git_repository_state_cleanup(pointer)
        }
    }
}

extension SwiftGitXError.Operation {
    public static let merge = Self(rawValue: "merge")
}
