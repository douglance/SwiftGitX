//
//  RepositoryState.swift
//  SwiftGitX
//

import libgit2

/// The state of a repository, indicating whether an operation is in progress.
public enum RepositoryState: Int, Sendable {
    /// No operation in progress.
    case clean = 0

    /// A merge is in progress.
    case merge = 1

    /// A revert is in progress.
    case revert = 2

    /// A revert sequence is in progress.
    case revertSequence = 3

    /// A cherry-pick is in progress.
    case cherryPick = 4

    /// A cherry-pick sequence is in progress.
    case cherryPickSequence = 5

    /// A bisect is in progress.
    case bisect = 6

    /// A rebase is in progress.
    case rebase = 7

    /// An interactive rebase is in progress.
    case rebaseInteractive = 8

    /// A rebase merge is in progress.
    case rebaseMerge = 9

    /// An apply mailbox is in progress.
    case applyMailbox = 10

    /// An apply mailbox or rebase is in progress.
    case applyMailboxOrRebase = 11
}
