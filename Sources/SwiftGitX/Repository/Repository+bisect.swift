//
//  Repository+bisect.swift
//  SwiftGitX
//

import Foundation
import libgit2

/// The result of a bisect step.
public enum BisectResult: Sendable {
    /// The search is still narrowing; `remaining` is the approximate number of steps left.
    case narrowing(remaining: Int, current: OID)
    /// The offending commit has been identified.
    case found(commit: OID)
}

/// Manages an in-progress bisect session.
///
/// libgit2 does not provide a native bisect API, so this implements bisect as a
/// state machine that performs binary search over the commit history between a
/// known good commit and a known bad commit.
public final class BisectState: @unchecked Sendable {
    /// The OID of the commit known to be bad (contains the bug).
    public internal(set) var bad: OID
    /// The OID of the commit known to be good (does not contain the bug).
    public internal(set) var good: OID
    /// The list of candidate commit OIDs between good and bad, in topological order.
    public internal(set) var candidates: [OID]
    /// The OID of the commit that HEAD was pointing to before bisect started.
    public let originalHEAD: OID

    init(bad: OID, good: OID, candidates: [OID], originalHEAD: OID) {
        self.bad = bad
        self.good = good
        self.candidates = candidates
        self.originalHEAD = originalHEAD
    }

    /// The midpoint index used for the next step.
    var midpointIndex: Int {
        candidates.count / 2
    }

    /// The current midpoint OID.
    public var currentOID: OID? {
        candidates.isEmpty ? nil : candidates[midpointIndex]
    }
}

// Thread-safe storage for bisect state, keyed by repository path.
private final class BisectStorage: @unchecked Sendable {
    static let shared = BisectStorage()

    private let lock = NSLock()
    private var states = [String: BisectState]()

    func get(_ key: String) -> BisectState? {
        lock.lock()
        defer { lock.unlock() }
        return states[key]
    }

    func set(_ key: String, value: BisectState?) {
        lock.lock()
        defer { lock.unlock() }
        states[key] = value
    }
}

extension Repository {
    /// Begin a bisect session between a known bad commit and a known good commit.
    ///
    /// - Parameters:
    ///   - bad: The OID of a commit known to contain the bug.
    ///   - good: The OID of a commit known to be bug-free.
    ///
    /// - Returns: A ``BisectResult`` indicating the initial state.
    ///
    /// The repository will be checked out to the midpoint commit. The caller should
    /// test the current state and call ``bisectGood()`` or ``bisectBad()`` to continue.
    @discardableResult
    public func bisectStart(bad: OID, good: OID) throws(SwiftGitXError) -> BisectResult {
        // Save original HEAD
        let headRef = try git(operation: .bisect) {
            var headRefPointer: OpaquePointer?
            let status = git_repository_head(&headRefPointer, pointer)
            return (headRefPointer, status)
        }
        defer { git_reference_free(headRef) }

        guard let headTargetOID = git_reference_target(headRef) else {
            throw SwiftGitXError(
                code: .error, operation: .bisect, category: .repository,
                message: "HEAD has no target"
            )
        }
        let originalHEAD = OID(raw: headTargetOID.pointee)

        // Build the list of commits between good and bad
        let candidates = try commitsBetween(good: good, bad: bad)

        if candidates.isEmpty {
            // The bad commit itself is the culprit
            return .found(commit: bad)
        }

        let state = BisectState(
            bad: bad,
            good: good,
            candidates: candidates,
            originalHEAD: originalHEAD
        )
        setBisectState(state)

        // Checkout the midpoint
        let midOID = candidates[state.midpointIndex]
        try checkoutDetached(oid: midOID)

        let remaining = estimateSteps(count: candidates.count)
        return .narrowing(remaining: remaining, current: midOID)
    }

    /// Mark the current bisect commit as good and narrow the search.
    ///
    /// - Returns: A ``BisectResult`` indicating whether the search continues or is complete.
    public func bisectGood() throws(SwiftGitXError) -> BisectResult {
        guard let state = getBisectState() else {
            throw SwiftGitXError(
                code: .error, operation: .bisect, category: .repository,
                message: "No bisect in progress"
            )
        }

        guard let current = state.currentOID else {
            throw SwiftGitXError(
                code: .error, operation: .bisect, category: .repository,
                message: "No current bisect commit"
            )
        }

        // Current is good, so the bug is in the upper half (closer to bad)
        let midIdx = state.midpointIndex
        // Keep only commits after the midpoint (they are between current and bad)
        state.candidates = Array(state.candidates[(midIdx + 1)...])
        state.good = current

        return try advanceBisect(state: state)
    }

    /// Mark the current bisect commit as bad and narrow the search.
    ///
    /// - Returns: A ``BisectResult`` indicating whether the search continues or is complete.
    public func bisectBad() throws(SwiftGitXError) -> BisectResult {
        guard let state = getBisectState() else {
            throw SwiftGitXError(
                code: .error, operation: .bisect, category: .repository,
                message: "No bisect in progress"
            )
        }

        guard let current = state.currentOID else {
            throw SwiftGitXError(
                code: .error, operation: .bisect, category: .repository,
                message: "No current bisect commit"
            )
        }

        // Current is bad, so the bug is in the lower half (closer to good)
        let midIdx = state.midpointIndex
        // Keep only commits before the midpoint (they are between good and current)
        state.candidates = Array(state.candidates[..<midIdx])
        state.bad = current

        return try advanceBisect(state: state)
    }

    /// Reset the repository to its pre-bisect state.
    public func bisectReset() throws(SwiftGitXError) {
        guard let state = getBisectState() else {
            throw SwiftGitXError(
                code: .error, operation: .bisect, category: .repository,
                message: "No bisect in progress"
            )
        }

        try checkoutDetached(oid: state.originalHEAD)

        // Verify HEAD is restored
        let headRef = try git(operation: .bisect) {
            var headRefPointer: OpaquePointer?
            let status = git_repository_head(&headRefPointer, pointer)
            return (headRefPointer, status)
        }
        git_reference_free(headRef)

        setBisectState(nil)
    }

    /// The current bisect state, or `nil` if no bisect is in progress.
    public var bisectState: BisectState? {
        getBisectState()
    }

    // MARK: - Private bisect storage

    private var bisectStorageKey: String {
        String(cString: git_repository_path(pointer))
    }

    private func getBisectState() -> BisectState? {
        BisectStorage.shared.get(bisectStorageKey)
    }

    private func setBisectState(_ state: BisectState?) {
        BisectStorage.shared.set(bisectStorageKey, value: state)
    }

    // MARK: - Private helpers

    /// Advance the bisect to the next midpoint, or declare the result found.
    private func advanceBisect(state: BisectState) throws(SwiftGitXError) -> BisectResult {
        if state.candidates.isEmpty {
            // The bad commit is the first bad one
            let result = BisectResult.found(commit: state.bad)
            setBisectState(nil)
            return result
        }

        let midOID = state.candidates[state.midpointIndex]
        try checkoutDetached(oid: midOID)

        let remaining = estimateSteps(count: state.candidates.count)
        return .narrowing(remaining: remaining, current: midOID)
    }

    /// Collect commit OIDs between good (exclusive) and bad (exclusive), in topological order.
    private func commitsBetween(good: OID, bad: OID) throws(SwiftGitXError) -> [OID] {
        // Use a rev walker to walk from bad backwards, stopping at good
        var walkerPointer: OpaquePointer?
        let walkerStatus = git_revwalk_new(&walkerPointer, pointer)
        try SwiftGitXError.check(walkerStatus, operation: .bisect)
        defer { git_revwalk_free(walkerPointer) }

        git_revwalk_sorting(walkerPointer, GIT_SORT_TOPOLOGICAL.rawValue)

        var badOID = bad.raw
        git_revwalk_push(walkerPointer, &badOID)

        var goodOID = good.raw
        git_revwalk_hide(walkerPointer, &goodOID)

        var oids = [OID]()
        var oid = git_oid()

        while git_revwalk_next(&oid, walkerPointer) == GIT_OK.rawValue {
            let currentOID = OID(raw: oid)
            // Exclude the bad commit itself from the candidates
            if currentOID != bad {
                oids.append(currentOID)
            }
        }

        // Reverse so that the list goes from good->bad direction
        return oids.reversed()
    }

    /// Checkout a specific commit in detached HEAD mode.
    private func checkoutDetached(oid: OID) throws(SwiftGitXError) {
        let commitPointer = try ObjectFactory.lookupObjectPointer(
            oid: oid.raw,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(commitPointer) }

        var checkoutOptions = git_checkout_options()
        git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        try git(operation: .bisect) {
            git_checkout_tree(pointer, commitPointer, &checkoutOptions)
        }

        var rawOID = oid.raw
        try git(operation: .bisect) {
            git_repository_set_head_detached(pointer, &rawOID)
        }
    }

    /// Estimate the number of bisect steps remaining for a given candidate count.
    private func estimateSteps(count: Int) -> Int {
        if count <= 1 { return 1 }
        // log2(count) rounded up
        var n = count
        var steps = 0
        while n > 1 {
            n /= 2
            steps += 1
        }
        return steps
    }
}

extension SwiftGitXError.Operation {
    public static let bisect = Self(rawValue: "bisect")
}
