import DFCore
import DFECS

/// The fortress map: a sparse grid of 16×16×1 tile blocks.
///
/// **Block geometry follows Dwarf Fortress's own: flat single-z slabs, not
/// cubes.** Almost every system works within a z-level — fluid spreading,
/// temperature exchange, pathing across a floor, and the renderer, which draws
/// one z-slice at a time. A 16×16×16 cubic block would drag sixteen z-levels of
/// data through cache to read one. See `docs/reference/map-and-time.md`.
///
/// **Palette compression is what makes the map affordable.** A block that is
/// entirely one tile value — which is nearly all of an unexcavated fortress —
/// stores that single value and no per-tile array. Blocks materialize on the
/// first write that breaks uniformity. A 16×16 embark at 65 z-levels is
/// 768×768×65 ≈ 38M tiles; at 8 bytes each that is 300 MB fully materialized,
/// versus a few megabytes for a fortress the player has actually dug into.
///
/// Uniformity is **canonical**, not incidental: a materialized block whose
/// tiles have all become equal collapses back to uniform. Without that, two
/// identical fortresses could hold the same tiles in different representations
/// and hash differently — the same history-dependence trap `ListStorage` avoids.
public final class MapStore: @unchecked Sendable {
  /// Block dimensions in tiles. Flat by design.
  public static let blockWidth = 16
  public static let blockHeight = 16
  public static let tilesPerBlock = blockWidth * blockHeight

  /// A block header. Trivial, stored contiguously; the tile payload lives in
  /// the shared pool so blocks stay ARC-free.
  private struct Block {
    /// The tile value when uniform, and the fill value used on materialization.
    var uniformTile: Tile
    /// Offset into `pool` in tiles, or `-1` when uniform.
    var storageOffset: Int32
    /// Bumped whenever passability changes, so pathfinding can invalidate
    /// cached routes without diffing tiles.
    var revision: UInt32
    /// Set when contents change; cleared by the renderer after upload.
    var dirty: Bool

    var isUniform: Bool { storageOffset < 0 }
  }

  /// Map extent in tiles.
  public let size: Coord3
  /// Map extent in blocks.
  public let blockCounts: Coord3

  private var blocks: [Block]
  private var pool: UnsafeMutableBufferPointer<Tile>
  private var poolCapacity: Int
  /// High-water mark in tiles. Never decreases; freed runs go to `freeOffsets`.
  private var poolUsed: Int
  /// Runs abandoned by collapse, available for reuse. LIFO, so reuse order is
  /// fixed. Offsets never reach the state hash, so reuse cannot perturb it.
  private var freeOffsets: [Int]
  /// Materialized block count; each occupies `tilesPerBlock` pool entries.
  private var materializedBlocks: Int

  /// Creates a map of `size` tiles, uniformly filled with `fill`.
  ///
  /// Costs one block header per block and no tile storage at all — an
  /// unexcavated 768×768×65 map allocates about 3 MB of headers and nothing else.
  public init(size: Coord3, fill: Tile = .solidGranite) {
    precondition(size.x > 0 && size.y > 0 && size.z > 0, "map size must be positive")
    self.size = size
    self.blockCounts = Coord3(
      (size.x + Int32(MapStore.blockWidth) - 1) / Int32(MapStore.blockWidth),
      (size.y + Int32(MapStore.blockHeight) - 1) / Int32(MapStore.blockHeight),
      size.z
    )
    let total = Int(blockCounts.x) * Int(blockCounts.y) * Int(blockCounts.z)
    blocks = Array(
      repeating: Block(uniformTile: fill, storageOffset: -1, revision: 0, dirty: false),
      count: total
    )
    poolCapacity = MapStore.tilesPerBlock * 8
    pool = .allocate(capacity: poolCapacity)
    poolUsed = 0
    freeOffsets = []
    materializedBlocks = 0
  }

  deinit {
    pool.deallocate()
  }

  // MARK: - Bounds

  @inlinable
  public var bounds: Region3 { Region3(origin: .zero, size: size) }

  @inlinable
  public func contains(_ coord: Coord3) -> Bool { bounds.contains(coord) }

  public var blockCount: Int { blocks.count }
  /// Blocks holding a per-tile array. The rest cost one header each.
  public var materializedBlockCount: Int { materializedBlocks }

  /// Bytes actually held for tile payloads.
  public var tileStorageBytes: Int {
    materializedBlocks * MapStore.tilesPerBlock * MemoryLayout<Tile>.stride
  }

  // MARK: - Tile access

  /// Reads a tile. Out-of-bounds reads return solid wall rather than trapping,
  /// so neighbour scans at the map edge need no special-casing.
  public subscript(coord: Coord3) -> Tile {
    get {
      guard let location = locate(coord) else { return .solidGranite }
      let block = blocks[location.block]
      if block.isUniform { return block.uniformTile }
      return pool[Int(block.storageOffset) + location.tile]
    }
    set { setTile(coord, newValue) }
  }

  public func setTile(_ coord: Coord3, _ tile: Tile) {
    guard let location = locate(coord) else { return }
    var block = blocks[location.block]

    if block.isUniform {
      // Writing the value a uniform block already holds changes nothing, and
      // must not materialize it -- otherwise painting a designation over solid
      // rock would materialize the entire map.
      if block.uniformTile == tile { return }
      materialize(&block, at: location.block)
    }

    let index = Int(block.storageOffset) + location.tile
    let previous = pool[index]
    guard previous != tile else { return }

    pool[index] = tile
    block.dirty = true
    if previous.isPassable != tile.isPassable {
      block.revision &+= 1
    }
    blocks[location.block] = block
  }

  /// Applies an edit in place, avoiding a read-modify-write round trip.
  public func modifyTile(_ coord: Coord3, _ body: (inout Tile) -> Void) {
    var tile = self[coord]
    body(&tile)
    setTile(coord, tile)
  }

  /// Fills a region. Regions that cover whole blocks collapse them to uniform,
  /// which is how large excavations give memory back.
  public func fill(_ region: Region3, with tile: Tile) {
    region.clamped(to: bounds).forEach { setTile($0, tile) }
    collapseUniformBlocks()
  }

  // MARK: - Block metadata

  /// Revision counter for the block containing `coord`. Pathfinding caches key
  /// off this rather than diffing tiles.
  public func blockRevision(at coord: Coord3) -> UInt32 {
    guard let location = locate(coord) else { return 0 }
    return blocks[location.block].revision
  }

  public func isDirty(at coord: Coord3) -> Bool {
    guard let location = locate(coord) else { return false }
    return blocks[location.block].dirty
  }

  public func clearDirtyFlags() {
    for index in blocks.indices { blocks[index].dirty = false }
  }

  // MARK: - Canonicalization

  /// Collapses materialized blocks whose tiles have all become equal.
  ///
  /// Required for hash stability, not merely a memory optimisation: a
  /// materialized block full of identical tiles and a uniform block holding
  /// that tile are the same map, and must hash the same. `hash(into:)` calls
  /// this, so callers rarely need to.
  public func collapseUniformBlocks() {
    guard materializedBlocks > 0 else { return }
    for index in blocks.indices {
      var block = blocks[index]
      guard !block.isUniform else { continue }
      let base = Int(block.storageOffset)
      let first = pool[base]
      var uniform = true
      for offset in 1..<MapStore.tilesPerBlock where pool[base + offset] != first {
        uniform = false
        break
      }
      guard uniform else { continue }
      block.uniformTile = first
      block.storageOffset = -1
      blocks[index] = block
      materializedBlocks -= 1
      // The freed run goes on the free list for reuse. Recycling is safe here
      // precisely because offsets never reach the state hash -- only block
      // order and tile contents do -- so layout history cannot perturb a digest.
      freeOffsets.append(base)
    }
  }

  // MARK: - Hashing

  /// Folds the map into the tick hash.
  ///
  /// Costs are proportional to *materialized* blocks: an untouched map hashes
  /// its block headers only. Uniform and materialized-but-uniform blocks hash
  /// identically, which is why `collapseUniformBlocks` runs first.
  public func hash(into hasher: inout StateHasher) {
    collapseUniformBlocks()
    hasher.combine(size)
    hasher.combine(blocks.count)

    for (index, block) in blocks.enumerated() {
      if block.isUniform {
        // Marker distinguishes "one tile repeated" from "256 tiles that happen
        // to start with this one".
        hasher.combine(UInt8(0))
        block.uniformTile.hash(into: &hasher)
      } else {
        hasher.combine(UInt8(1))
        hasher.combine(index)
        let base = Int(block.storageOffset)
        for offset in 0..<MapStore.tilesPerBlock {
          pool[base + offset].hash(into: &hasher)
        }
      }
    }
  }

  public var stateHash: UInt64 {
    var hasher = StateHasher()
    hash(into: &hasher)
    return hasher.value
  }

  // MARK: - ASCII rendering

  /// Renders one z-level as text.
  ///
  /// This is how an agent *looks at* the map (Constitution V). A change that
  /// "should work" and a change observed producing the right tiles are
  /// different things.
  public func asciiSlice(z: Int32, region: Region3? = nil) -> String {
    let area = (region ?? bounds).clamped(to: bounds)
    guard z >= 0 && z < size.z, !area.isEmpty else { return "" }

    var output = ""
    output.reserveCapacity(Int(area.size.y) * Int(area.size.x + 1))
    for y in area.origin.y..<(area.origin.y + area.size.y) {
      for x in area.origin.x..<(area.origin.x + area.size.x) {
        output.append(self[Coord3(x, y, z)].glyph)
      }
      output.append("\n")
    }
    return output
  }

  // MARK: - Internals

  private func locate(_ coord: Coord3) -> (block: Int, tile: Int)? {
    guard contains(coord) else { return nil }
    let blockX = Int(coord.x) / MapStore.blockWidth
    let blockY = Int(coord.y) / MapStore.blockHeight
    let blockIndex =
      (Int(coord.z) * Int(blockCounts.y) + blockY) * Int(blockCounts.x) + blockX
    let tileIndex =
      (Int(coord.y) % MapStore.blockHeight) * MapStore.blockWidth
      + (Int(coord.x) % MapStore.blockWidth)
    return (blockIndex, tileIndex)
  }

  /// Gives a block its own tile array, filled with its former uniform value.
  private func materialize(_ block: inout Block, at index: Int) {
    let offset = allocateBlockStorage()
    let base = pool.baseAddress!.advanced(by: offset)
    base.initialize(repeating: block.uniformTile, count: MapStore.tilesPerBlock)
    block.storageOffset = Int32(offset)
    blocks[index] = block
    materializedBlocks += 1
  }

  private func allocateBlockStorage() -> Int {
    if let recycled = freeOffsets.popLast() { return recycled }
    let offset = poolUsed
    if offset + MapStore.tilesPerBlock > poolCapacity {
      growPool(to: Swift.max(poolCapacity * 2, offset + MapStore.tilesPerBlock))
    }
    poolUsed += MapStore.tilesPerBlock
    return offset
  }

  private func growPool(to newCapacity: Int) {
    let newPool = UnsafeMutableBufferPointer<Tile>.allocate(capacity: newCapacity)
    if poolUsed > 0 {
      newPool.baseAddress!.update(from: pool.baseAddress!, count: poolUsed)
    }
    pool.deallocate()
    pool = newPool
    poolCapacity = newCapacity
  }
}
