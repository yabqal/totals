import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:totals/local_server/network_utils.dart';

void main() {
  group('NetworkUtils.isPrivateOrLoopback', () {
    test('accepts loopback, link-local and private ranges', () {
      for (final address in [
        '127.0.0.1',
        '10.0.0.5',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.43.20',
        '169.254.10.10',
        '::1',
        'fe80::1',
        'fd12:3456::1',
      ]) {
        expect(
          NetworkUtils.isPrivateOrLoopback(InternetAddress(address)),
          isTrue,
          reason: address,
        );
      }
    });

    test('rejects public addresses', () {
      for (final address in [
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '192.169.1.1',
        '100.64.0.1',
        '2001:4860:4860::8888',
      ]) {
        expect(
          NetworkUtils.isPrivateOrLoopback(InternetAddress(address)),
          isFalse,
          reason: address,
        );
      }
    });
  });
}
