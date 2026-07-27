import DFCore

/// A handle to a simulation entity: a dwarf, an item, a job, a building.
///
/// Packs a 32-bit slot index with a 32-bit generation counter. The generation
/// is what makes stale handles *detectable* rather than silently wrong: when a
/// dwarf dies its slot is reused, and a job that still holds the old handle
/// gets a clean "not alive" answer instead of quietly retargeting itself at
/// whatever creature moved into the slot.
public struct EntityID: Hashable, Sendable, BitwiseCopyable, Comparable {
  public var bits: UInt64

  @inlinable
  public init(bits: UInt64) {
    self.bits = bits
  }

  @inlinable
  public init(index: UInt32, generation: UInt32) {
    self.bits = UInt64(index) | (UInt64(generation) << 32)
  }

  /// Slot index into component sparse maps.
  @inlinable
  public var index: UInt32 { UInt32(truncatingIfNeeded: bits) }

  /// Incremented each time the slot is recycled.
  @inlinable
  public var generation: UInt32 { UInt32(truncatingIfNeeded: bits >> 32) }

  /// A handle that is never alive. Distinct from "slot 0, generation 0", which
  /// is a perfectly ordinary entity.
  public static let invalid = EntityID(bits: UInt64.max)

  @inlinable
  public var isValid: Bool { self != EntityID.invalid }

  /// Ordered by index then generation, giving systems a stable sort key when
  /// they need an iteration order that does not depend on storage history.
  @inlinable
  public static func < (lhs: EntityID, rhs: EntityID) -> Bool { lhs.bits < rhs.bits }
}

extension EntityID: CustomStringConvertible {
  public var description: String {
    self == EntityID.invalid ? "Entity(invalid)" : "Entity(\(index)v\(generation))"
  }
}

extension EntityID: StateHashable {
  public func hash(into hasher: inout StateHasher) {
    hasher.combine(bits)
  }
}

/// Allocates and recycles entity slots.
///
/// Recycling is LIFO: the most recently freed slot is the next one handed out.
/// The policy is arbitrary but it must be *fixed*, because it determines the
/// slot layout that every subsequent component array inherits, and therefore
/// the iteration order of the whole simulation. Changing it changes every
/// replay fixture in the project.
public struct EntityAllocator: Sendable {
  /// Generation counter per slot. Index into this is the entity's slot index.
  private var generations: [UInt32] = []
  /// Freed slots available for reuse, most recent last.
  private var freeSlots: [UInt32] = []
  /// Slots currently allocated.
  public private(set) var liveCount: Int = 0

  public init() {}

  /// Total slots ever allocated, live or recycled. Sizes sparse maps.
  public var slotCapacity: Int { generations.count }

  public mutating func create() -> EntityID {
    liveCount += 1
    if let slot = freeSlots.popLast() {
      return EntityID(index: slot, generation: generations[Int(slot)])
    }
    let slot = UInt32(generations.count)
    generations.append(0)
    return EntityID(index: slot, generation: 0)
  }

  /// Frees a slot. Returns false if the handle was already stale, which callers
  /// should treat as "someone else already killed it", not as an error.
  @discardableResult
  public mutating func destroy(_ entity: EntityID) -> Bool {
    guard isAlive(entity) else { return false }
    let slot = Int(entity.index)
    // Bumping the generation is what invalidates every outstanding handle to
    // this slot. Wrapping is deliberate: a slot recycled four billion times has
    // no live handles left from the previous cycle.
    generations[slot] = generations[slot] &+ 1
    freeSlots.append(entity.index)
    liveCount -= 1
    return true
  }

  public func isAlive(_ entity: EntityID) -> Bool {
    guard entity.isValid else { return false }
    let slot = Int(entity.index)
    guard slot < generations.count else { return false }
    return generations[slot] == entity.generation
  }

  public func hash(into hasher: inout StateHasher) {
    generations.withUnsafeBufferPointer { hasher.combine(buffer: $0) }
    freeSlots.withUnsafeBufferPointer { hasher.combine(buffer: $0) }
    hasher.combine(liveCount)
  }
}
