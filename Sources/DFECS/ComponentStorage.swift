import DFCore

/// Trivially copyable simulation data that contributes to the state hash.
///
/// `BitwiseCopyable` is Constitution IV and is enforced here by the type system
/// -- data containing a `String` or a `class` simply will not compile. That
/// buys ARC-free iteration over hundreds of thousands of entities and makes
/// serialization a bulk copy rather than a graph walk.
public protocol PlainData: BitwiseCopyable, Sendable {
  /// Folds this value's fields into the per-tick state hash. Cover every field;
  /// an unhashed field can drift between runs with no test noticing.
  func hash(into hasher: inout StateHasher)
}

/// A component: plain data attached one-per-entity.
///
/// For data an entity has a *variable number of* -- body parts, wounds,
/// inventory, skills -- use `ListStorage` instead, whose element type is
/// `PlainData` rather than `Component`.
public protocol Component: PlainData {}

/// Sparse-set storage for one component type.
///
/// Dense arrays hold the values back to back so iteration is a linear scan with
/// no pointer chasing; a sparse map turns an entity's slot index into a dense
/// index for O(1) random access.
///
/// **Iteration order is history-dependent but deterministic.** Removal is a
/// swap-with-last, so the dense order reflects the sequence of adds and removes
/// that produced it. Two runs that applied the same commands have the same
/// order; a run that took a different path does not. Systems needing an order
/// that is stable across *different* histories must sort by `EntityID` -- and
/// should say why in a comment, because the sort is not free.
public final class ComponentStorage<T: Component>: @unchecked Sendable {
  /// Dense component values, `0..<count` live.
  private var dense: UnsafeMutableBufferPointer<T>
  /// Entity owning each dense slot, parallel to `dense`.
  private var owners: UnsafeMutableBufferPointer<EntityID>
  /// Slot index -> dense index, or `absent`.
  private var sparse: [Int32]
  private var count: Int
  private var capacity: Int

  private static var absent: Int32 { -1 }

  public init(initialCapacity: Int = 64) {
    capacity = Swift.max(1, initialCapacity)
    dense = .allocate(capacity: capacity)
    owners = .allocate(capacity: capacity)
    sparse = []
    count = 0
  }

  deinit {
    // Deinitialize before deallocating. A no-op for the trivial types this
    // storage holds, but writing it correctly keeps the buffer's initialized
    // region honest -- see docs/known-issues.md KI-001.
    dense.baseAddress!.deinitialize(count: count)
    owners.baseAddress!.deinitialize(count: count)
    dense.deallocate()
    owners.deallocate()
  }

  public var componentCount: Int { count }
  public var isEmpty: Bool { count == 0 }

  // MARK: - Mutation

  /// Adds or overwrites the component for `entity`.
  public func set(_ entity: EntityID, _ value: T) {
    let slot = Int(entity.index)
    growSparse(toInclude: slot)

    let existing = sparse[slot]
    if existing != ComponentStorage.absent {
      dense[Int(existing)] = value
      return
    }

    if count == capacity { grow() }
    // `initialize`, not assignment: slot `count` is past the initialized
    // region, and assigning into uninitialized memory is undefined -- it
    // presumes an existing value to overwrite.
    (dense.baseAddress! + count).initialize(to: value)
    (owners.baseAddress! + count).initialize(to: entity)
    sparse[slot] = Int32(count)
    count += 1
  }

  /// Removes the component if present. Returns whether anything was removed.
  ///
  /// Swap-with-last keeps the dense array packed, at the cost of perturbing
  /// order -- see the type's documentation.
  @discardableResult
  public func remove(_ entity: EntityID) -> Bool {
    let slot = Int(entity.index)
    guard slot < sparse.count else { return false }
    let denseIndex = sparse[slot]
    guard denseIndex != ComponentStorage.absent else { return false }

    let last = count - 1
    let removed = Int(denseIndex)
    if removed != last {
      // Both slots are initialized here, so assignment is correct.
      dense[removed] = dense[last]
      owners[removed] = owners[last]
      sparse[Int(owners[removed].index)] = Int32(removed)
    }
    // The tail slot leaves the initialized region.
    (dense.baseAddress! + last).deinitialize(count: 1)
    (owners.baseAddress! + last).deinitialize(count: 1)
    sparse[slot] = ComponentStorage.absent
    count = last
    return true
  }

  public func removeAll() {
    for index in 0..<count {
      sparse[Int(owners[index].index)] = ComponentStorage.absent
    }
    dense.baseAddress!.deinitialize(count: count)
    owners.baseAddress!.deinitialize(count: count)
    count = 0
  }

  // MARK: - Access

  public func contains(_ entity: EntityID) -> Bool {
    let slot = Int(entity.index)
    guard slot < sparse.count else { return false }
    return sparse[slot] != ComponentStorage.absent
  }

  public subscript(entity: EntityID) -> T? {
    get {
      let slot = Int(entity.index)
      guard slot < sparse.count else { return nil }
      let denseIndex = sparse[slot]
      guard denseIndex != ComponentStorage.absent else { return nil }
      return dense[Int(denseIndex)]
    }
    set {
      if let newValue {
        set(entity, newValue)
      } else {
        remove(entity)
      }
    }
  }

  /// In-place mutation without a get/set round trip.
  public func modify(_ entity: EntityID, _ body: (inout T) -> Void) {
    let slot = Int(entity.index)
    guard slot < sparse.count else { return }
    let denseIndex = sparse[slot]
    guard denseIndex != ComponentStorage.absent else { return }
    body(&dense[Int(denseIndex)])
  }

  /// The entity owning a dense slot.
  public func owner(atDenseIndex index: Int) -> EntityID {
    precondition(index >= 0 && index < count, "dense index out of range")
    return owners[index]
  }

  // MARK: - Bulk access

  /// Exposes the packed values for linear iteration.
  ///
  /// This is the hot path: systems scan the dense buffer directly rather than
  /// going through subscripts, so there is no sparse-map indirection and no
  /// bounds check per element.
  public func withDense<R>(
    _ body: (UnsafeMutableBufferPointer<T>, UnsafeBufferPointer<EntityID>) -> R
  ) -> R {
    let values = UnsafeMutableBufferPointer(start: dense.baseAddress, count: count)
    let entities = UnsafeBufferPointer(start: owners.baseAddress, count: count)
    return body(values, entities)
  }

  /// Entities holding this component, in dense order.
  public var entities: [EntityID] {
    Array(UnsafeBufferPointer(start: owners.baseAddress, count: count))
  }

  // MARK: - Hashing

  /// Folds the whole storage into the tick hash.
  ///
  /// Hashes in **entity order**, not dense order. Dense order is a legitimate
  /// consequence of history, so two runs that reached identical fortresses by
  /// different routes should agree -- and more importantly, sorting here means
  /// the hash tests what the simulation *is* rather than how its arrays happen
  /// to be laid out.
  public func hash(into hasher: inout StateHasher) {
    hasher.combine(count)
    var order = Array(0..<count)
    order.sort { owners[$0].bits < owners[$1].bits }
    for denseIndex in order {
      hasher.combine(owners[denseIndex])
      dense[denseIndex].hash(into: &hasher)
    }
  }

  // MARK: - Storage growth

  private func grow() {
    let newCapacity = capacity * 2
    let newDense = UnsafeMutableBufferPointer<T>.allocate(capacity: newCapacity)
    let newOwners = UnsafeMutableBufferPointer<EntityID>.allocate(capacity: newCapacity)
    // `moveInitialize`, not `update`: the destination is freshly allocated and
    // therefore uninitialized, and `update` requires an initialized
    // destination. This also leaves the source uninitialized, which is exactly
    // right before deallocating it.
    newDense.baseAddress!.moveInitialize(from: dense.baseAddress!, count: count)
    newOwners.baseAddress!.moveInitialize(from: owners.baseAddress!, count: count)
    dense.deallocate()
    owners.deallocate()
    dense = newDense
    owners = newOwners
    capacity = newCapacity
  }

  private func growSparse(toInclude slot: Int) {
    guard slot >= sparse.count else { return }
    sparse.append(
      contentsOf: repeatElement(ComponentStorage.absent, count: slot - sparse.count + 1)
    )
  }
}
