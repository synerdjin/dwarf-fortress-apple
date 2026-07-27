import DFCore

/// Storage for variable-length per-entity data.
///
/// Constitution IV bars `Array` from components, but the simulation is full of
/// variable-length per-entity data: a creature's body parts and their tissue
/// layers, its wounds, inventory, skills, relationships and memories. Research
/// confirms creature anatomy is not merely variable in length but nested and
/// structurally different between creature types, so a fixed inline cap would
/// either waste memory on every dwarf or truncate a forgotten beast.
///
/// The naive fix is a general arena plus `(offset, count)` handles inside
/// components. That fails a subtler requirement: **the state hash must not
/// depend on allocation history.** Two fortresses with identical contents that
/// reached them by different routes have different offsets and different
/// garbage, and would hash differently — silently breaking replay for reasons
/// having nothing to do with the simulation.
///
/// So this is not an arena with loose handles. It is a *storage*, parallel to
/// `ComponentStorage`, that owns both the pool and the entity mapping. Hashing
/// walks live lists in **entity order** and touches only live elements, which
/// makes the digest a function of contents alone. Offsets, capacity slack and
/// garbage are invisible to it — and therefore compaction cannot change a hash,
/// which is what lets compaction happen whenever it is convenient.
public final class ListStorage<T: PlainData>: @unchecked Sendable {
  /// One entity's list. Dense, swap-removed like `ComponentStorage`.
  private struct Record {
    var owner: EntityID
    /// Start of the run in `pool`.
    var offset: Int32
    /// Live element count.
    var count: Int32
    /// Allocated room before a move is required.
    var capacity: Int32
  }

  private var pool: UnsafeMutableBufferPointer<T>
  private var poolCapacity: Int
  /// High-water mark; allocation is a bump from here.
  private var poolUsed: Int
  /// Slots stranded by growth and removal, reclaimed by `compact()`.
  private var garbage: Int

  private var records: [Record]
  /// Entity slot index -> record index, or `absent`.
  private var sparse: [Int32]

  private static var absent: Int32 { -1 }

  public init(initialCapacity: Int = 256) {
    poolCapacity = Swift.max(1, initialCapacity)
    pool = .allocate(capacity: poolCapacity)
    poolUsed = 0
    garbage = 0
    records = []
    sparse = []
  }

  deinit {
    pool.deallocate()
  }

  // MARK: - Introspection

  public var listCount: Int { records.count }
  /// Live elements across all lists.
  public var elementCount: Int { records.reduce(0) { $0 + Int($1.count) } }
  /// Slots allocated but not live. `compact()` reclaims these.
  public var garbageSlots: Int { garbage }

  public func contains(_ entity: EntityID) -> Bool {
    recordIndex(of: entity) != nil
  }

  public func count(for entity: EntityID) -> Int {
    guard let index = recordIndex(of: entity) else { return 0 }
    return Int(records[index].count)
  }

  // MARK: - Reading

  /// Exposes an entity's list for reading or in-place mutation.
  ///
  /// Scoped to a closure rather than returned, because the pool moves under
  /// growth and compaction — a pointer that outlived this call could dangle.
  @discardableResult
  public func withList<R>(
    _ entity: EntityID,
    _ body: (UnsafeMutableBufferPointer<T>) -> R
  ) -> R? {
    guard let index = recordIndex(of: entity) else { return nil }
    let record = records[index]
    let start = pool.baseAddress!.advanced(by: Int(record.offset))
    return body(UnsafeMutableBufferPointer(start: start, count: Int(record.count)))
  }

  /// Copies an entity's list out. Convenience for tests and cold paths; hot
  /// paths use `withList` and avoid the allocation.
  public func list(_ entity: EntityID) -> [T] {
    withList(entity) { Array($0) } ?? []
  }

  public subscript(entity: EntityID, elementIndex: Int) -> T? {
    guard let index = recordIndex(of: entity) else { return nil }
    let record = records[index]
    guard elementIndex >= 0 && elementIndex < Int(record.count) else { return nil }
    return pool[Int(record.offset) + elementIndex]
  }

  // MARK: - Writing

  /// Replaces an entity's list wholesale.
  public func set(_ entity: EntityID, _ values: [T]) {
    values.withUnsafeBufferPointer { set(entity, $0) }
  }

  public func set(_ entity: EntityID, _ values: UnsafeBufferPointer<T>) {
    let needed = values.count
    let index = ensureRecord(for: entity, capacity: needed)
    var record = records[index]

    if Int(record.capacity) < needed {
      garbage += Int(record.capacity)
      let allocation = allocate(needed)
      record.offset = allocation.offset
      record.capacity = allocation.capacity
    }
    if needed > 0 {
      pool.baseAddress!.advanced(by: Int(record.offset))
        .update(from: values.baseAddress!, count: needed)
    }
    record.count = Int32(needed)
    records[index] = record
  }

  /// Appends one element, growing the run if it is full.
  public func append(_ entity: EntityID, _ value: T) {
    let index = ensureRecord(for: entity, capacity: 1)
    var record = records[index]

    if record.count == record.capacity {
      // Doubling keeps repeated appends amortised O(1). The old run becomes
      // garbage rather than being freed into a size-classed free list: a free
      // list makes reuse depend on allocation history, which is exactly the
      // coupling this type exists to avoid.
      let newCapacity = Swift.max(4, Int(record.capacity) * 2)
      let allocation = allocate(newCapacity)
      if record.count > 0 {
        pool.baseAddress!.advanced(by: Int(allocation.offset))
          .update(
            from: pool.baseAddress!.advanced(by: Int(record.offset)),
            count: Int(record.count)
          )
      }
      garbage += Int(record.capacity)
      record.offset = allocation.offset
      record.capacity = allocation.capacity
    }

    pool[Int(record.offset) + Int(record.count)] = value
    record.count += 1
    records[index] = record
  }

  /// Removes the element at `elementIndex`, preserving the order of the rest.
  ///
  /// Order-preserving on purpose: a creature's body parts are referred to by
  /// index from wounds and equipment, so swap-removal would silently reattach
  /// a wound to a different limb.
  @discardableResult
  public func remove(_ entity: EntityID, at elementIndex: Int) -> Bool {
    guard let index = recordIndex(of: entity) else { return false }
    var record = records[index]
    guard elementIndex >= 0 && elementIndex < Int(record.count) else { return false }

    let base = pool.baseAddress!.advanced(by: Int(record.offset))
    let tail = Int(record.count) - elementIndex - 1
    if tail > 0 {
      base.advanced(by: elementIndex)
        .update(from: base.advanced(by: elementIndex + 1), count: tail)
    }
    record.count -= 1
    records[index] = record
    return true
  }

  /// Drops an entity's list entirely.
  @discardableResult
  public func removeList(_ entity: EntityID) -> Bool {
    guard let index = recordIndex(of: entity) else { return false }
    garbage += Int(records[index].capacity)

    let last = records.count - 1
    if index != last {
      records[index] = records[last]
      sparse[Int(records[index].owner.index)] = Int32(index)
    }
    records.removeLast()
    sparse[Int(entity.index)] = ListStorage.absent
    return true
  }

  // MARK: - Compaction

  /// Rebuilds the pool with no garbage, in entity order.
  ///
  /// Safe to call at any time and from any tick: it moves elements but changes
  /// no list's contents, and the state hash reads contents only. Compaction can
  /// therefore never perturb a replay.
  public func compact() {
    guard garbage > 0 else { return }

    var order = Array(0..<records.count)
    order.sort { records[$0].owner.bits < records[$1].owner.bits }

    let live = elementCount
    let newCapacity = Swift.max(1, live)
    let newPool = UnsafeMutableBufferPointer<T>.allocate(capacity: newCapacity)

    var cursor = 0
    var rebuilt: [Record] = []
    rebuilt.reserveCapacity(records.count)
    for recordIndex in order {
      var record = records[recordIndex]
      let count = Int(record.count)
      if count > 0 {
        newPool.baseAddress!.advanced(by: cursor)
          .update(from: pool.baseAddress!.advanced(by: Int(record.offset)), count: count)
      }
      record.offset = Int32(cursor)
      record.capacity = Int32(count)
      cursor += count
      rebuilt.append(record)
    }

    pool.deallocate()
    pool = newPool
    poolCapacity = newCapacity
    poolUsed = cursor
    garbage = 0
    records = rebuilt

    for (index, record) in records.enumerated() {
      sparse[Int(record.owner.index)] = Int32(index)
    }
  }

  // MARK: - Hashing

  /// Folds live list contents into the tick hash, in entity order.
  ///
  /// Deliberately hashes neither offsets nor capacities nor garbage — only
  /// which entity owns which elements. That is what makes the digest a function
  /// of simulation contents rather than of allocation history.
  public func hash(into hasher: inout StateHasher) {
    hasher.combine(records.count)
    var order = Array(0..<records.count)
    order.sort { records[$0].owner.bits < records[$1].owner.bits }

    for recordIndex in order {
      let record = records[recordIndex]
      hasher.combine(record.owner)
      hasher.combine(Int(record.count))
      for offset in 0..<Int(record.count) {
        pool[Int(record.offset) + offset].hash(into: &hasher)
      }
    }
  }

  // MARK: - Internals

  private func recordIndex(of entity: EntityID) -> Int? {
    let slot = Int(entity.index)
    guard slot < sparse.count else { return nil }
    let index = sparse[slot]
    guard index != ListStorage.absent else { return nil }
    return Int(index)
  }

  /// Returns the record index for `entity`, creating an empty list if needed.
  private func ensureRecord(for entity: EntityID, capacity: Int) -> Int {
    if let existing = recordIndex(of: entity) { return existing }

    let slot = Int(entity.index)
    if slot >= sparse.count {
      sparse.append(
        contentsOf: repeatElement(ListStorage.absent, count: slot - sparse.count + 1)
      )
    }
    let allocation = allocate(Swift.max(capacity, 0))
    records.append(
      Record(owner: entity, offset: allocation.offset, count: 0, capacity: allocation.capacity)
    )
    sparse[slot] = Int32(records.count - 1)
    return records.count - 1
  }

  /// Bump-allocates a run, growing the pool if required.
  private func allocate(_ count: Int) -> (offset: Int32, capacity: Int32) {
    guard count > 0 else { return (Int32(poolUsed), 0) }
    if poolUsed + count > poolCapacity {
      var target = Swift.max(poolCapacity * 2, 1)
      while target < poolUsed + count { target *= 2 }
      growPool(to: target)
    }
    let offset = Int32(poolUsed)
    poolUsed += count
    return (offset, Int32(count))
  }

  private func growPool(to newCapacity: Int) {
    let newPool = UnsafeMutableBufferPointer<T>.allocate(capacity: newCapacity)
    if poolUsed > 0 {
      newPool.baseAddress!.update(from: pool.baseAddress!, count: poolUsed)
    }
    pool.deallocate()
    pool = newPool
    poolCapacity = newCapacity
  }
}
