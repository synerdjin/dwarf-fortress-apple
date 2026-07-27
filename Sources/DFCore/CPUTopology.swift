import Darwin

/// Core counts for the machine we are running on.
///
/// Apple Silicon is asymmetric, and the distinction matters for scheduling. The
/// sim's critical path wants performance cores and low-latency QoS; worldgen,
/// history simulation and save compression are throughput work that belongs on
/// efficiency cores so it does not steal cycles from the tick loop.
///
/// Values are read once at startup. They are hardware facts, not configuration.
public enum CPUTopology {
  /// Performance ("P") core count. On an M4 this is 4.
  public static let performanceCoreCount: Int =
    sysctlInt("hw.perflevel0.logicalcpu") ?? fallbackCoreCount

  /// Efficiency ("E") core count. On an M4 this is 6.
  ///
  /// Zero on hardware without an efficiency cluster, which callers must treat
  /// as "use the performance cores" rather than "use no cores".
  public static let efficiencyCoreCount: Int = sysctlInt("hw.perflevel1.logicalcpu") ?? 0

  public static let totalCoreCount: Int = sysctlInt("hw.ncpu") ?? fallbackCoreCount

  /// Worker count for latency-sensitive simulation work.
  ///
  /// Deliberately the P-core count and not the total: spilling a tick phase
  /// onto efficiency cores means the barrier at the end of the phase waits on
  /// the slowest worker, and an E-core worker finishes late enough to cost
  /// more than the extra parallelism gains.
  public static var simulationWorkerCount: Int { max(1, performanceCoreCount) }

  /// Worker count for throughput work that may run on any core.
  public static var backgroundWorkerCount: Int { max(1, totalCoreCount) }

  private static let fallbackCoreCount = 1

  private static func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else {
      return nil
    }
    return Int(value)
  }
}
