/// A sorted, deduplicated set of indices, maintained deterministically.
///
/// Built for the active-set pattern `docs/reference/performance-model.md`
/// requires for M3: only tiles whose neighbourhood changed last tick need
/// recomputing, and *which* tiles those are must not depend on iteration or
/// insertion order -- "sorted or index-ordered, never a hash set iteration."
/// A plain `Set<Int>` fails this the moment two builds of the same logical
/// set happen to iterate its storage in different orders, which Swift's
/// `Set` gives no guarantee against.
///
/// `JobSystem.parallelCollect` is the sanctioned way to build one in
/// parallel, for free: each partition covers a contiguous, increasing range
/// of indices and appends in increasing order within its own range, and
/// `JobSystem` merges partition results in partition order -- so the merged
/// array is already globally sorted, with no separate sort step needed.
/// `init(sortedUnique:)` takes that array directly.
public struct ActiveSet: Sendable, Equatable {
  private var indices: [Int]

  public init() {
    indices = []
  }

  /// Trusts `sorted` is already strictly increasing -- the shape
  /// `parallelCollect` over contiguous partitions produces for free. Checked
  /// in debug builds; a caller that violates it elsewhere fails loudly rather
  /// than silently reordering which tiles are "active."
  public init(sortedUnique sorted: [Int]) {
    assert(
      sorted.indices.dropFirst().allSatisfy { sorted[$0] > sorted[$0 - 1] },
      "ActiveSet.init(sortedUnique:) requires a strictly increasing sequence")
    indices = sorted
  }

  public var isEmpty: Bool { indices.isEmpty }
  public var count: Int { indices.count }
  public var sortedIndices: [Int] { indices }

  public func contains(_ index: Int) -> Bool {
    var low = 0
    var high = indices.count
    while low < high {
      let mid = (low + high) / 2
      if indices[mid] < index { low = mid + 1 } else { high = mid }
    }
    return low < indices.count && indices[low] == index
  }

  /// Inserts a single index, for incremental, non-parallel updates -- a
  /// designation just made one tile active. O(n) for the shift; building many
  /// new entries at once should go through `parallelCollect` and `merging`
  /// instead, which stay linear rather than paying this per insertion.
  public mutating func insert(_ index: Int) {
    var low = 0
    var high = indices.count
    while low < high {
      let mid = (low + high) / 2
      if indices[mid] < index { low = mid + 1 } else { high = mid }
    }
    if low == indices.count || indices[low] != index {
      indices.insert(index, at: low)
    }
  }

  /// Merges two sorted sets into one, still sorted -- a linear merge, not
  /// concatenate-then-sort, so the result depends only on the two inputs'
  /// values and never on which one was appended first.
  public func merging(_ other: ActiveSet) -> ActiveSet {
    var result: [Int] = []
    result.reserveCapacity(indices.count + other.indices.count)
    var i = 0
    var j = 0
    while i < indices.count && j < other.indices.count {
      if indices[i] == other.indices[j] {
        result.append(indices[i])
        i += 1
        j += 1
      } else if indices[i] < other.indices[j] {
        result.append(indices[i])
        i += 1
      } else {
        result.append(other.indices[j])
        j += 1
      }
    }
    result.append(contentsOf: indices[i...])
    result.append(contentsOf: other.indices[j...])
    return ActiveSet(sortedUnique: result)
  }

  public func forEach(_ body: (Int) -> Void) {
    for index in indices { body(index) }
  }
}
