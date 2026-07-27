// Temporary scaffold: prints golden values used to pin DFCore's algorithms in
// tests. Replaced by the real CLI in task #6.
import DFCore

var h = StateHasher()
h.combine(UInt64(0))
print("empty+zero:", h.hex)

var h2 = StateHasher()
h2.combine(Coord3(3, -7, 12))
print("coord:", h2.hex)

var h3 = StateHasher()
let bytes: [UInt8] = Array(0..<20)
bytes.withUnsafeBufferPointer { h3.combine(buffer: $0) }
print("bytes20:", h3.hex)

var rng = RNGStream(seed: 0xDEAD_BEEF, .testing)
print("rng:", (0..<6).map { _ in rng.next() })

var a = RNGStream(seed: 1, .combat)
var b = RNGStream(seed: 1, .moods)
print("domain-independence:", a.next() != b.next())
