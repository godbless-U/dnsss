import 'dart:io';

enum IpAddressFamily { ipv4, ipv6 }

/// Converts only address formats with a defined, reversible representation.
///
/// An arbitrary IPv4 resolver does not automatically have a native IPv6
/// address, and an arbitrary IPv6 address does not automatically have an IPv4
/// equivalent. This helper therefore exposes IPv4-mapped IPv6 and the RFC 6052
/// well-known NAT64 /96 prefix as representations, not as proof that a DNS
/// server is reachable at the generated address.
class IpConversionResult {
  final bool isValid;
  final IpAddressFamily? family;
  final String? ipv4MappedIpv6;
  final String? nat64Ipv6;
  final String? ipv4;
  final String message;

  const IpConversionResult({
    required this.isValid,
    required this.family,
    required this.message,
    this.ipv4MappedIpv6,
    this.nat64Ipv6,
    this.ipv4,
  });
}

class IpAddressConverter {
  static const List<int> _nat64Prefix = <int>[
    0x00, 0x64, 0xff, 0x9b, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ];

  static IpConversionResult convert(String input) {
    final value = input.trim();
    if (value.isEmpty || value.contains('%')) {
      return const IpConversionResult(
        isValid: false,
        family: null,
        message: 'یک آدرس IPv4 یا IPv6 معتبر وارد کنید.',
      );
    }

    final address = InternetAddress.tryParse(value);
    if (address == null) {
      return const IpConversionResult(
        isValid: false,
        family: null,
        message: 'قالب IP معتبر نیست. نام دامنه و پورت پذیرفته نمی‌شود.',
      );
    }

    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final mapped = '::ffff:${address.address}';
      final nat64 = '64:ff9b::${_hexWord(bytes[0], bytes[1])}:${_hexWord(bytes[2], bytes[3])}';
      return IpConversionResult(
        isValid: true,
        family: IpAddressFamily.ipv4,
        ipv4MappedIpv6: mapped,
        nat64Ipv6: nat64,
        message: 'IPv4 معتبر است. دو نمایش IPv6 ساخته شد؛ این تبدیل به‌تنهایی وجود DNS متناظر روی IPv6 را تضمین نمی‌کند.',
      );
    }

    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      if (_isIpv4Mapped(bytes)) {
        return IpConversionResult(
          isValid: true,
          family: IpAddressFamily.ipv6,
          ipv4: _toIpv4(bytes.sublist(12, 16)),
          message: 'این IPv6 از نوع IPv4-mapped است؛ IPv4 اصلی قابل بازیابی است.',
        );
      }

      if (_hasNat64Prefix(bytes)) {
        return IpConversionResult(
          isValid: true,
          family: IpAddressFamily.ipv6,
          ipv4: _toIpv4(bytes.sublist(12, 16)),
          message: 'این آدرس از پیشوند شناخته‌شدهٔ NAT64 استفاده می‌کند؛ بخش IPv4 قابل بازیابی است.',
        );
      }

      return const IpConversionResult(
        isValid: true,
        family: IpAddressFamily.ipv6,
        message: 'IPv6 معتبر است، اما برای IPv6 بومی تبدیل یکتای عمومی به IPv4 وجود ندارد. باید IPv4 همان سرویس‌دهنده را جداگانه پیدا کنید.',
      );
    }

    return const IpConversionResult(
      isValid: false,
      family: null,
      message: 'نوع آدرس پشتیبانی نمی‌شود.',
    );
  }

  static bool _isIpv4Mapped(List<int> bytes) {
    return bytes.length == 16 &&
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
  }

  static bool _hasNat64Prefix(List<int> bytes) {
    if (bytes.length != 16) return false;
    for (var i = 0; i < _nat64Prefix.length; i++) {
      if (bytes[i] != _nat64Prefix[i]) return false;
    }
    return true;
  }

  static String _toIpv4(List<int> bytes) => bytes.join('.');

  static String _hexWord(int high, int low) =>
      ((high << 8) | low).toRadixString(16);
}
