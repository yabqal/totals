import 'dart:io';

class NetworkUtils {
  /// Priority list of interface names for Wi-Fi (wlan0, swlan0, etc.)
  static const List<String> _wifiInterfacePriority = [
    'swlan0',
    'wlan0',
    'wlan1',
    'wifi0',
    'wifi',
    'en0', // macOS Wi-Fi
    'en1',
    'Wi-Fi',
  ];

  /// Gets the local IP address of this device on the network
  /// Prioritizes Wi-Fi interfaces (wlan0, swlan0, etc.)
  static Future<String?> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      // First, try to find a Wi-Fi interface by priority
      for (final priorityName in _wifiInterfacePriority) {
        for (final interface in interfaces) {
          if (interface.name.toLowerCase() == priorityName.toLowerCase()) {
            for (final addr in interface.addresses) {
              if (!addr.isLoopback) {
                return addr.address;
              }
            }
          }
        }
      }

      // Fallback: return the first non-loopback address
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('Error getting local IP: $e');
    }
    return null;
  }

  /// True for loopback, link-local and private-range addresses (10/8,
  /// 172.16/12, 192.168/16, fc00::/7) — the clients a home or hotspot network
  /// can have. Public addresses, e.g. reaching the phone over mobile data,
  /// return false.
  static bool isPrivateOrLoopback(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0], b = bytes[1];
      return a == 10 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168);
    }
    if (address.type == InternetAddressType.IPv6) {
      return (bytes[0] & 0xFE) == 0xFC;
    }
    return false;
  }

  /// Gets the Wi-Fi IP address specifically (wlan0, swlan0, etc.)
  static Future<String?> getWifiIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final priorityName in _wifiInterfacePriority) {
        for (final interface in interfaces) {
          if (interface.name.toLowerCase() == priorityName.toLowerCase()) {
            for (final addr in interface.addresses) {
              if (!addr.isLoopback) {
                return addr.address;
              }
            }
          }
        }
      }
    } catch (e) {
      print('Error getting Wi-Fi IP: $e');
    }
    return null;
  }

  /// Gets all available network interfaces
  /// Sorted with Wi-Fi interfaces first
  static Future<List<NetworkInterfaceInfo>> getAllInterfaces() async {
    final result = <NetworkInterfaceInfo>[];

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            result.add(
              NetworkInterfaceInfo(
                name: interface.name,
                address: addr.address,
                isWifi: _isWifiInterface(interface.name),
              ),
            );
          }
        }
      }

      // Sort: Wi-Fi interfaces first
      result.sort((a, b) {
        if (a.isWifi && !b.isWifi) return -1;
        if (!a.isWifi && b.isWifi) return 1;
        return a.name.compareTo(b.name);
      });
    } catch (e) {
      print('Error listing interfaces: $e');
    }

    return result;
  }

  /// Check if an interface name is a Wi-Fi interface
  static bool _isWifiInterface(String name) {
    final lowerName = name.toLowerCase();
    return _wifiInterfacePriority.any(
      (wifi) => lowerName.contains(wifi.toLowerCase()),
    );
  }
}

class NetworkInterfaceInfo {
  final String name;
  final String address;
  final bool isWifi;

  NetworkInterfaceInfo({
    required this.name,
    required this.address,
    this.isWifi = false,
  });
}
