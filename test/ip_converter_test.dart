import 'package:flutter_test/flutter_test.dart';
import 'package:gaming_dns/ip_converter.dart';

void main() {
  group('IpAddressConverter', () {
    test('creates mapped and NAT64 representations for IPv4', () {
      final result = IpAddressConverter.convert('8.8.8.8');

      expect(result.isValid, isTrue);
      expect(result.family, IpAddressFamily.ipv4);
      expect(result.ipv4MappedIpv6, '::ffff:8.8.8.8');
      expect(result.nat64Ipv6, '64:ff9b::808:808');
    });

    test('recovers IPv4 from IPv4-mapped IPv6', () {
      final result = IpAddressConverter.convert('::ffff:8.8.8.8');

      expect(result.isValid, isTrue);
      expect(result.family, IpAddressFamily.ipv6);
      expect(result.ipv4, '8.8.8.8');
    });

    test('recovers IPv4 from the well-known NAT64 /96 prefix', () {
      final result = IpAddressConverter.convert('64:ff9b::808:808');

      expect(result.isValid, isTrue);
      expect(result.ipv4, '8.8.8.8');
    });

    test('does not invent an IPv4 equivalent for native IPv6', () {
      final result = IpAddressConverter.convert('2606:4700:4700::1111');

      expect(result.isValid, isTrue);
      expect(result.family, IpAddressFamily.ipv6);
      expect(result.ipv4, isNull);
    });

    test('rejects hostnames and malformed input', () {
      expect(IpAddressConverter.convert('dns.google').isValid, isFalse);
      expect(IpAddressConverter.convert('999.1.1.1').isValid, isFalse);
      expect(IpAddressConverter.convert('').isValid, isFalse);
    });
  });
}
