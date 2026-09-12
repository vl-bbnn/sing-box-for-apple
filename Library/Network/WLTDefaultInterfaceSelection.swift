#if SFI_DEV
  import Darwin
  import Network

  enum WLTDefaultInterfaceSelection {
    // Availability alone does not establish a usable default route. A withdrawn
    // Wi-Fi interface may remain in availableInterfaces during cellular recovery.
    static func offset(
      status: NWPath.Status, available: [NWInterface.InterfaceType],
      used: [NWInterface.InterfaceType]
    ) -> Int? {
      guard status == .satisfied else { return nil }
      for type: NWInterface.InterfaceType in [.wiredEthernet, .wifi, .cellular]
      where used.contains(type) {
        if let index = available.firstIndex(of: type) { return index }
      }
      return nil
    }

    static func uptimeNanos() -> Int64 {
      var value = timespec()
      guard clock_gettime(CLOCK_UPTIME_RAW, &value) == 0 else { return 0 }
      return Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
    }
  }
#endif
