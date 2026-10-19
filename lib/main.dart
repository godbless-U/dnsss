import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'dns_manager.dart';
import 'ip_converter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GamingDnsApp());
}

class DnsServer {
  final String ip;
  final int? ping;
  final bool isPremium;

  const DnsServer({
    required this.ip,
    this.ping,
    this.isPremium = false,
  });
}

class GamingDnsApp extends StatelessWidget {
  const GamingDnsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Gaming DNS',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.deepPurpleAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.deepPurpleAccent,
          centerTitle: true,
        ),
        colorScheme: ThemeData.dark().colorScheme.copyWith(
          primary: Colors.deepPurpleAccent,
          secondary: Colors.orangeAccent,
        ),
      ),
      home: const DnsScreen(),
    );
  }
}

class DnsScreen extends StatefulWidget {
  const DnsScreen({super.key});

  @override
  State<DnsScreen> createState() => _DnsScreenState();
}

class _DnsScreenState extends State<DnsScreen> {
  static const platform = MethodChannel('com.example.gaming_dns/vpn');
  final DnsManager _dnsManager = DnsManager();

  List<DnsServer> displayList = [];
  final Set<String> selectedIps = <String>{};
  bool isLoading = false;
  bool isTestingPing = false;
  bool sortByPing = false;
  String? connectedDns;
  int pageSize = 100;
  int pageIndex = 0;
  int importLimit = 1000;
  int totalPoolSize = 0;

  @override
  void initState() {
    super.initState();
    _reloadPage();
    _restoreVpnStatus();
  }

  Future<void> _restoreVpnStatus() async {
    try {
      final activeDns = await platform.invokeMethod<String?>('getVpnStatus');
      if (!mounted) return;
      setState(() => connectedDns = activeDns);
    } on PlatformException {
      // Older/non-Android builds may not expose the native VPN channel.
    } catch (_) {
      // The DNS inventory remains usable if VPN status cannot be queried.
    }
  }

  Future<void> _reloadPage({bool showLoading = true}) async {
    if (showLoading && mounted) setState(() => isLoading = true);

    try {
      final count = await _dnsManager.getDnsCount();
      final rows = await _dnsManager.getDnsPage(
        offset: pageIndex * pageSize,
        limit: pageSize,
        sortByPing: sortByPing,
      );
      if (!mounted) return;

      setState(() {
        totalPoolSize = count;
        displayList = rows.map((row) {
          return DnsServer(
            ip: row['ip']! as String,
            ping: row['ping_ms'] as int?,
            isPremium: (row['is_premium'] as int? ?? 0) == 1,
          );
        }).toList(growable: false);
        isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => isLoading = false);
      _showMessage('خطا در خواندن پایگاه داده: $error', isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textDirection: TextDirection.rtl),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
      ),
    );
  }

  Future<void> huntNewDns() async {
    if (isLoading || isTestingPing) return;
    setState(() => isLoading = true);

    final result = await _dnsManager.fetchFromNetwork(limit: importLimit);
    if (!mounted) return;

    final status = result['status'] as String? ?? 'error';
    final count = result['count'] as int? ?? 0;
    final succeeded = result['sources_succeeded'] as int? ?? 0;
    final failed = result['sources_failed'] as int? ?? 0;

    pageIndex = 0;
    await _reloadPage(showLoading: false);

    if (!mounted) return;
    if (status == 'success') {
      if (count > 0) {
        _showMessage(
          '$count DNS جدید ذخیره شد. منابع موفق: $succeeded، منابع ناموفق: $failed',
        );
      } else {
        _showMessage(
          'منابع بررسی شدند، اما DNS جدیدی اضافه نشد. ممکن است همه موارد تکراری باشند یا تعداد موجود کمتر از درخواست شما باشد.',
        );
      }
    } else {
      _showMessage(
        'دریافت از منابع ناموفق بود. اتصال اینترنت و دسترسی به GitHub را بررسی کنید. منابع ناموفق: $failed',
        isError: true,
      );
    }
  }

  Future<void> testSingleDns(DnsServer server) async {
    if (isTestingPing || isLoading) return;
    setState(() => isTestingPing = true);

    final result = await _dnsManager.testDns(server.ip);
    await _dnsManager.updatePingResult(server.ip, result ?? 9999);

    if (!mounted) return;
    setState(() => isTestingPing = false);
    await _reloadPage(showLoading: false);
    if (!mounted) return;

    _showMessage(
      result == null
          ? '${server.ip}: پاسخی از DNS دریافت نشد.'
          : '${server.ip}: زمان پاسخ واقعی DNS برابر $result ms است.',
      isError: result == null,
    );
  }

  Future<void> testVisibleDns() async {
    if (isTestingPing || isLoading || displayList.isEmpty) return;
    setState(() => isTestingPing = true);

    // محدودکردن هم‌زمانی برای جلوگیری از فشار غیرضروری به شبکه.
    for (var i = 0; i < displayList.length; i += 10) {
      final end = (i + 10 < displayList.length) ? i + 10 : displayList.length;
      final chunk = displayList.sublist(i, end);
      await Future.wait(chunk.map((server) async {
        final result = await _dnsManager.testDns(server.ip);
        await _dnsManager.updatePingResult(server.ip, result ?? 9999);
      }));
    }

    if (!mounted) return;
    setState(() => isTestingPing = false);
    await _reloadPage(showLoading: false);
    _showMessage('تست صفحه تمام شد. زمان‌ها بر اساس پاسخ واقعی DNS ثبت شدند.');
  }

  Future<void> pickAndImportFile() async {
    // file_picker 12+ returns PlatformFile directly and no longer exposes
    // FilePicker.platform or FilePickerResult.
    final selectedFile = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['txt', 'csv', 'json'],
    );
    if (selectedFile == null) return;

    final filePath = selectedFile.path;
    if (filePath == null || filePath.isEmpty) {
      _showMessage(
        'مسیر فایل قابل دسترسی نیست. فایل TXT/CSV را دوباره انتخاب کنید.',
        isError: true,
      );
      return;
    }

    setState(() => isLoading = true);
    try {
      final added = await _dnsManager.importFile(
        File(filePath),
        limit: importLimit,
      );
      pageIndex = 0;
      await _reloadPage(showLoading: false);
      if (!mounted) return;
      _showMessage(
        'از فایل ${selectedFile.name} تعداد $added DNS جدید ذخیره شد. سقف این عملیات: $importLimit',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => isLoading = false);
      _showMessage('خطا هنگام واردکردن فایل: $error', isError: true);
    }
  }

  Future<void> exportDnsDatabase() async {
    if (isLoading) return;
    setState(() => isLoading = true);
    final exportFile = await _dnsManager.generateExportFile();
    if (!mounted) return;
    setState(() => isLoading = false);

    if (exportFile == null) {
      _showMessage('ساخت فایل خروجی ناموفق بود.', isError: true);
      return;
    }

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(exportFile.path)],
        text: 'پشتیبان فهرست Gaming DNS',
      ),
    );
  }

  Future<void> showImportLimitDialog() async {
    final controller = TextEditingController(text: '$importLimit');
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تعداد DNS برای واردکردن'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'حداکثر تعداد رکورد جدید',
            hintText: 'مثلاً 10000',
            helperText: 'فقط تعداد واقعی و موجود در منابع وارد می‌شود.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed != null && parsed > 0) {
                Navigator.pop(dialogContext, parsed);
              }
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );

    if (value != null && mounted) {
      setState(() => importLimit = value);
    }
  }

  Future<void> _showIpConverterDialog() async {
    final controller = TextEditingController();
    String copyMessage = '';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final value = controller.text.trim();
          final result = IpAddressConverter.convert(value);

          Widget copyableRow(String label, String address) {
            return Card(
              margin: const EdgeInsets.only(top: 8),
              color: const Color(0xFF292536),
              child: ListTile(
                dense: true,
                title: Text(label, textDirection: TextDirection.rtl),
                subtitle: SelectableText(
                  address,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    color: Colors.lightBlueAccent,
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                ),
                trailing: IconButton(
                  tooltip: 'کپی آدرس',
                  icon: const Icon(Icons.copy, size: 19),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: address));
                    setDialogState(() => copyMessage = 'آدرس کپی شد.');
                  },
                ),
              ),
            );
          }

          return AlertDialog(
            title: const Text('تبدیل خودکار IPv4 و IPv6'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'آدرس IP را وارد کنید؛ نوع آن خودکار تشخیص داده می‌شود.',
                      textDirection: TextDirection.rtl,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textDirection: TextDirection.ltr,
                      onChanged: (_) => setDialogState(() => copyMessage = ''),
                      decoration: const InputDecoration(
                        labelText: 'IPv4 یا IPv6',
                        hintText: 'مثلاً 8.8.8.8 یا ::ffff:8.8.8.8',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (value.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        result.message,
                        textDirection: TextDirection.rtl,
                        style: TextStyle(
                          color: result.isValid
                              ? Colors.white70
                              : Colors.redAccent,
                        ),
                      ),
                      if (result.isValid && result.family == IpAddressFamily.ipv4) ...[
                        if (result.ipv4MappedIpv6 != null)
                          copyableRow('IPv6 از نوع IPv4-mapped', result.ipv4MappedIpv6!),
                        if (result.nat64Ipv6 != null)
                          copyableRow('IPv6 با پیشوند NAT64', result.nat64Ipv6!),
                        const SizedBox(height: 10),
                        const Text(
                          'توجه: این دو قالب الزاماً DNS جدید یا قابل‌دسترسی ایجاد نمی‌کنند. IPv4-mapped معمولاً برای نمایش/سازگاری آدرس است؛ NAT64 فقط در شبکه‌ای کار می‌کند که NAT64 داشته باشد. برای اتصال واقعی، IPv6 بومی همان DNS را لازم دارید.',
                          textDirection: TextDirection.rtl,
                          style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                        ),
                      ] else if (result.isValid && result.family == IpAddressFamily.ipv6 && result.ipv4 != null) ...[
                        copyableRow('IPv4 بازیابی‌شده', result.ipv4!),
                      ],
                    ] else ...[
                      const SizedBox(height: 12),
                      const Text(
                        'برای نمونه 1.1.1.1 یا 2606:4700:4700::1111 را وارد کنید.',
                        textDirection: TextDirection.rtl,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                    if (copyMessage.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        copyMessage,
                        textDirection: TextDirection.rtl,
                        style: const TextStyle(color: Colors.greenAccent),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('بستن'),
              ),
            ],
          );
        },
      ),
    );

    controller.dispose();
  }

  void _showAddOptionsModal() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.dns, color: Colors.greenAccent),
              title: const Text('افزودن DNS تکی'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showAddSingleDnsDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link, color: Colors.orangeAccent),
              title: const Text('افزودن لینک منبع HTTPS'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showAddSourceDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_upload_outlined, color: Colors.cyanAccent),
              title: const Text('واردکردن از فایل'),
              onTap: () {
                Navigator.pop(sheetContext);
                pickAndImportFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddSingleDnsDialog() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('افزودن DNS جدید'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'مثال: 8.8.8.8 یا IPv6'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () async {
              final ip = controller.text.trim();
              if (!_dnsManager.isValidIp(ip)) {
                _showMessage('آدرس واردشده، IPv4 یا IPv6 معتبر نیست.', isError: true);
                return;
              }
              final added = await _dnsManager.addIps([ip], source: 'manual');
              if (!mounted) return;
              Navigator.pop(dialogContext);
              pageIndex = 0;
              await _reloadPage();
              _showMessage(added == 1 ? 'DNS اضافه شد.' : 'این DNS از قبل وجود دارد.');
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
  }

  void _showAddSourceDialog() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('افزودن لینک منبع'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/dns.txt',
            helperText: 'برای امنیت، فقط لینک HTTPS پذیرفته می‌شود.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () async {
              final url = controller.text.trim();
              final uri = Uri.tryParse(url);
              if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
                _showMessage('لینک HTTPS معتبر وارد کنید.', isError: true);
                return;
              }
              final sources = await _dnsManager.loadSources();
              if (!sources.contains(url)) {
                sources.add(url);
                await _dnsManager.saveSources(sources);
              }
              if (!mounted) return;
              Navigator.pop(dialogContext);
              _showMessage('منبع ذخیره شد. برای دریافت، «دریافت DNS» را بزنید.');
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete({
    required String title,
    required String message,
    required Future<int> Function() action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message, textDirection: TextDirection.rtl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => isLoading = true);
    final deleted = await action();
    if (!mounted) return;
    selectedIps.clear();
    pageIndex = 0;
    await _reloadPage(showLoading: false);
    if (!mounted) return;
    _showMessage('$deleted DNS حذف شد.');
  }

  Future<void> _deleteAllDns() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف کل DNSها؟'),
        content: const Text(
          'تمام رکوردهای ذخیره‌شده، از جمله DNSهای داخلی برنامه، حذف می‌شوند. این عملیات قابل بازگشت نیست.',
          textDirection: TextDirection.rtl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف همه'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => isLoading = true);
    await _dnsManager.deleteAllDns();
    selectedIps.clear();
    pageIndex = 0;
    await _reloadPage(showLoading: false);
    _showMessage('تمام DNSهای ذخیره‌شده حذف شدند.');
  }

  Future<void> _showLatencyDeleteDialog() async {
    final controller = TextEditingController(text: '100');
    final threshold = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف DNSهای کند'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'حداکثر تأخیر برحسب ms',
            helperText: 'رکوردهای تست‌شده با زمان بالاتر حذف می‌شوند.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value != null && value >= 0) {
                Navigator.pop(dialogContext, value);
              }
            },
            child: const Text('ادامه'),
          ),
        ],
      ),
    );
    if (threshold == null || !mounted) return;

    await _confirmDelete(
      title: 'تأیید حذف DNSهای کند',
      message: 'DNSهای تست‌شده با تأخیر بیشتر از $threshold ms حذف شوند؟',
      action: () => _dnsManager.deleteDnsAboveLatency(threshold),
    );
  }

  Future<void> _handleManagementAction(String action) async {
    switch (action) {
      case 'invalid':
        await _confirmDelete(
          title: 'حذف DNSهای نامعتبر',
          message: 'رکوردهایی که آدرس IP معتبر ندارند حذف شوند.',
          action: _dnsManager.deleteInvalidDns,
        );
        break;
      case 'unresponsive':
        await _confirmDelete(
          title: 'حذف DNSهای بدون پاسخ',
          message: 'تمام DNSهایی که قبلاً تست شده‌اند و پاسخی نداده‌اند حذف شوند. DNSهای تست‌نشده دست‌نخورده می‌مانند.',
          action: _dnsManager.deleteUnresponsiveDns,
        );
        break;
      case 'slow':
        await _showLatencyDeleteDialog();
        break;
      case 'all':
        await _deleteAllDns();
        break;
    }
  }

  Future<void> _deleteSelected() async {
    if (selectedIps.isEmpty) return;
    await _confirmDelete(
      title: 'حذف DNSهای انتخاب‌شده',
      message: '${selectedIps.length} DNS انتخاب شده است. حذف شوند؟',
      action: () => _dnsManager.deleteIps(selectedIps),
    );
  }

  Future<void> connectDns(String dns) async {
    if (connectedDns != null) {
      _showMessage('ابتدا اتصال DNS فعلی را قطع کنید.', isError: true);
      return;
    }
    _showMessage('در حال درخواست مجوز اندروید و آزمایش اتصال واقعی DNS به $dns ...');
    try {
      final started = await platform.invokeMethod<bool>(
        'startVpn',
        <String, Object>{'dns_ip': dns},
      );
      if (!mounted) return;
      if (started == true) {
        setState(() => connectedDns = dns);
        _showMessage(
          'اتصال واقعی DNS برقرار شد: $dns. درخواست‌های DNS سیستم از تونل محلی عبور می‌کنند.',
        );
      } else {
        _showMessage('اندروید اتصال DNS را تأیید نکرد. دوباره تلاش کنید.', isError: true);
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      _showMessage(
        'اتصال DNS برقرار نشد: ${error.message ?? error.code}',
        isError: true,
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage('خطای اتصال DNS: $error', isError: true);
    }
  }

  Future<void> disconnectDns() async {
    try {
      await platform.invokeMethod('stopVpn');
    } on PlatformException {
      // The VPN service may already have stopped; clear the UI state either way.
    }
    if (!mounted) return;
    setState(() => connectedDns = null);
  }

  Color _pingColor(DnsServer server) {
    if (server.ping == null) return Colors.grey;
    if (server.ping == 9999) return Colors.redAccent;
    if (server.ping! < 60) return Colors.greenAccent;
    if (server.ping! < 120) return Colors.amberAccent;
    return Colors.orangeAccent;
  }

  String _pingLabel(DnsServer server) {
    if (server.ping == null) return 'تست نشده';
    if (server.ping == 9999) return 'بدون پاسخ';
    return '${server.ping} ms';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Gaming DNS Manager',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'تبدیل IPv4 و IPv6',
            onPressed: _showIpConverterDialog,
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'واردکردن از فایل',
            onPressed: isLoading ? null : pickAndImportFile,
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'خروجی TXT',
            onPressed: isLoading ? null : exportDnsDatabase,
          ),
          IconButton(
            icon: isTestingPing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.speed),
            tooltip: 'تست DNSهای همین صفحه',
            onPressed: isTestingPing || isLoading ? null : testVisibleDns,
          ),
          PopupMenuButton<String>(
            tooltip: 'مدیریت و حذف',
            onSelected: _handleManagementAction,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'invalid',
                child: Text('حذف DNSهای نامعتبر'),
              ),
              PopupMenuItem(
                value: 'unresponsive',
                child: Text('حذف DNSهای بدون پاسخ'),
              ),
              PopupMenuItem(
                value: 'slow',
                child: Text('حذف بر اساس حداکثر ms'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'all',
                child: Text('حذف کل DNSها'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.deepPurpleAccent,
        onPressed: _showAddOptionsModal,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      bottomNavigationBar: selectedIps.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: const Color(0xFF24202E),
                child: Row(
                  children: [
                    Expanded(child: Text('${selectedIps.length} مورد انتخاب شده')),
                    TextButton.icon(
                      onPressed: () => setState(() => selectedIps.clear()),
                      icon: const Icon(Icons.close),
                      label: const Text('لغو انتخاب'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                      ),
                      onPressed: _deleteSelected,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('حذف'),
                    ),
                  ],
                ),
              ),
            ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            color: const Color(0xFF1E1E1E),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.storage, color: Colors.orangeAccent, size: 19),
                    const SizedBox(width: 7),
                    Text('کل DNS ذخیره‌شده: $totalPoolSize'),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: showImportLimitDialog,
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text('تعداد ورود: $importLimit'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('نمایش:'),
                    const SizedBox(width: 6),
                    DropdownButton<int>(
                      value: pageSize,
                      dropdownColor: const Color(0xFF2C2C2C),
                      underline: const SizedBox.shrink(),
                      items: [50, 100, 200, 500]
                          .map((value) => DropdownMenuItem<int>(
                                value: value,
                                child: Text('$value'),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          pageSize = value;
                          pageIndex = 0;
                        });
                        _reloadPage();
                      },
                    ),
                    IconButton(
                      tooltip: sortByPing ? 'مرتب‌سازی جدیدترین' : 'مرتب‌سازی بر اساس ms',
                      onPressed: () {
                        setState(() => sortByPing = !sortByPing);
                        _reloadPage();
                      },
                      icon: Icon(
                        sortByPing ? Icons.sort : Icons.speed,
                        color: sortByPing ? Colors.orangeAccent : Colors.white70,
                      ),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: isLoading || isTestingPing ? null : huntNewDns,
                      icon: const Icon(Icons.radar),
                      label: const Text(
                        'دریافت DNS',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.orangeAccent),
                  )
                : displayList.isEmpty
                    ? const Center(
                        child: Text(
                          'DNS ذخیره‌شده‌ای وجود ندارد. از دریافت اینترنتی، فایل یا افزودن تکی استفاده کنید.',
                          textAlign: TextAlign.center,
                          textDirection: TextDirection.rtl,
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: displayList.length,
                        itemBuilder: (context, index) {
                          final server = displayList[index];
                          final isSelected = selectedIps.contains(server.ip);
                          final isConnected = server.ip == connectedDns;

                          return Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            color: isSelected
                                ? Colors.deepPurple.withValues(alpha: 0.28)
                                : const Color(0xFF252525),
                            shape: RoundedRectangleBorder(
                              side: BorderSide(
                                color: isSelected
                                    ? Colors.deepPurpleAccent
                                    : Colors.transparent,
                                width: 1.5,
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: ListTile(
                              leading: Checkbox(
                                value: isSelected,
                                onChanged: (value) {
                                  setState(() {
                                    if (value == true) {
                                      selectedIps.add(server.ip);
                                    } else {
                                      selectedIps.remove(server.ip);
                                    }
                                  });
                                },
                              ),
                              title: Text(
                                server.ip,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              subtitle: Row(
                                children: [
                                  Text(
                                    _pingLabel(server),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: _pingColor(server),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  if (server.isPremium)
                                    const Text(
                                      'داخلی/منتخب',
                                      style: TextStyle(
                                        color: Colors.orangeAccent,
                                        fontSize: 11,
                                      ),
                                    ),
                                ],
                              ),
                              trailing: Wrap(
                                spacing: 0,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  IconButton(
                                    tooltip: 'تست تکی',
                                    onPressed: isTestingPing || isLoading
                                        ? null
                                        : () => testSingleDns(server),
                                    icon: const Icon(
                                      Icons.speed,
                                      color: Colors.cyanAccent,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'حذف',
                                    onPressed: isLoading || isTestingPing
                                        ? null
                                        : () => _confirmDelete(
                                              title: 'حذف DNS',
                                              message: 'آدرس ${server.ip} حذف شود؟',
                                              action: () => _dnsManager.deleteIps([server.ip]),
                                            ),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: isConnected ? 'قطع اتصال واقعی DNS' : 'اتصال واقعی DNS',
                                    onPressed: isConnected
                                        ? disconnectDns
                                        : () => connectDns(server.ip),
                                    icon: Icon(
                                      isConnected ? Icons.link_off : Icons.link,
                                      color: isConnected
                                          ? Colors.redAccent
                                          : Colors.deepPurpleAccent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
          if (totalPoolSize > pageSize)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: const Color(0xFF1E1E1E),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'صفحه قبل',
                    onPressed: pageIndex <= 0 || isLoading
                        ? null
                        : () {
                            setState(() => pageIndex--);
                            _reloadPage();
                          },
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    'صفحه ${pageIndex + 1} از ${(totalPoolSize / pageSize).ceil()}',
                  ),
                  IconButton(
                    tooltip: 'صفحه بعد',
                    onPressed: (pageIndex + 1) * pageSize >= totalPoolSize || isLoading
                        ? null
                        : () {
                            setState(() => pageIndex++);
                            _reloadPage();
                          },
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
