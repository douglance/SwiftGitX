//
//  Repository+cherrypick.swift
//  SwiftGitX
//

import libgit2

extension Repository {
    /// Cherry-picks the given commit, producing changes in the index and working directory.
    ///
    /// - Parameter commit: The commit to cherry-pick.
    ///
    /// This method applies the changes introduced by the given commit to the current
    /// HEAD. The result is staged in the index but not committed, allowing the caller
    /// to inspect the result and create a commit.
    public func cherryPick(_ commit: Commit) throws(SwiftGitXError) {
        // Lookup the commit pointer
        let commitPointer = try ObjectFactory.lookupObjectPointer(
            oid: commit.id.raw,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(commitPointer) }

        // Perform the cherry-pick operation
        try git(operation: .cherryPick) {
            git_cherrypick(pointer, commitPointer, nil)
        }
    }

    /// Clean up the cherry-pick state after completing or aborting a cherry-pick.
    public func cherryPickCleanup() throws(SwiftGitXError) {
        try git(operation: .cherryPick) {
            git_repository_state_cleanup(pointer)
        }
    }
}

extension SwiftGitXError.Operation {
    public static let cherryPick = Self(rawValue: "cherryPick")
}
