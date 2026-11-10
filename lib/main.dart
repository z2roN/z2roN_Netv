// z2roN Net - 내 네트워크 정보 보기 (Android)
// 외부(공인) IP, 연결 방식(Wi-Fi/유선/모바일), SSID, 연결속도, 게이트웨이(공유기) 접속,
// 같은 네트워크의 기기 목록, 다운로드/업로드 속도, 내 기기 이름·운영체제·버전
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kAppName = 'z2roN Net';
const String kVersion = '1.0.0';
const MethodChannel _ch = MethodChannel('z2ron/net');

const Color kBlue = Color(0xFF2B63D9);
const Color kBlueDark = Color(0xFF1B3F9C);
const Color kBlueSoft = Color(0xFFEEF3FD);

void main() => runApp(const NetApp());

class NetApp extends StatelessWidget {
  const NetApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: kBlue),
          scaffoldBackgroundColor: const Color(0xFFF4F7FC),
        ),
        home: const HomePage(),
      );
}

class Host {
  final String ip;
  String name;
  String kind;
  final List<int> ports;
  bool isGateway;
  Host(this.ip, this.name, this.kind, this.ports, this.isGateway);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, dynamic> info = {};
  bool loading = true;
  String? error;

  String? pubIp, pubCountry, pubIsp, pubError;
  bool pubLoading = false;

  bool testing = false;
  String phase = '';
  double? ping, down, up;

  bool scanning = false, cancelScan = false;
  double scanProgress = 0;
  List<Host> hosts = [];
  bool scannedOnce = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  // ---------- 값 꺼내기 ----------
  String? s(String k) {
    final v = info[k];
    return v == null ? null : v.toString();
  }

  int? n(String k) {
    final v = info[k];
    return v is int ? v : null;
  }

  List<String> list(String k) {
    final v = info[k];
    return v is List ? v.map((e) => e.toString()).toList() : <String>[];
  }

  void toast(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 2)));
  }

  void copy(String? t) {
    if (t == null || t.isEmpty) return;
    Clipboard.setData(ClipboardData(text: t));
    toast('복사했습니다: $t');
  }

  // ---------- 새로고침 ----------
  Future<void> _refresh() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await _ch.invokeMethod('requestLocation'); // SSID 를 읽으려면 위치 권한이 필요합니다
    } catch (_) {}
    try {
      final m = await _ch.invokeMethod<Map>('info');
      info = m == null ? {} : Map<String, dynamic>.from(m);
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
    _fetchPublic();
  }

  Future<String> _get(String url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await c.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 8));
      return await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _fetchPublic() async {
    setState(() {
      pubLoading = true;
      pubError = null;
    });
    try {
      String? ip;
      for (final u in ['https://api.ipify.org', 'https://icanhazip.com', 'https://ifconfig.me/ip']) {
        try {
          ip = (await _get(u)).trim();
          if (ip.isNotEmpty && ip.length < 64) break;
        } catch (_) {}
      }
      if (ip == null || ip.isEmpty) throw '인터넷에 연결되어 있지 않거나 외부 IP 서버에 접속할 수 없습니다.';
      pubIp = ip;
      try {
        final j = jsonDecode(await _get('https://ipwho.is/$ip')) as Map<String, dynamic>;
        pubCountry = j['country']?.toString();
        final conn = j['connection'];
        pubIsp = conn is Map ? (conn['isp'] ?? conn['org'])?.toString() : null;
      } catch (_) {}
    } catch (e) {
      pubError = '$e';
      pubIp = null;
    }
    if (mounted) setState(() => pubLoading = false);
  }

  // ---------- 속도 측정 ----------
  Future<void> _speedTest() async {
    if (testing) return;
    setState(() {
      testing = true;
      ping = down = up = null;
      phase = '응답 시간 측정 중...';
    });
    try {
      await _measurePing();
      setState(() => phase = '다운로드 측정 중...');
      await _measureDown();
      setState(() => phase = '업로드 측정 중...');
      await _measureUp();
      setState(() => phase = '측정 완료');
    } catch (e) {
      setState(() => phase = '측정 실패: 인터넷 연결을 확인하세요');
    }
    if (mounted) setState(() => testing = false);
  }

  Future<void> _measurePing() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final times = <int>[];
      for (int i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        final req = await c.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=0'));
        final resp = await req.close();
        await resp.drain();
        sw.stop();
        if (i > 0) times.add(sw.elapsedMilliseconds); // 첫 번째는 연결 준비 시간이라 제외
      }
      times.sort();
      if (mounted) setState(() => ping = times.first.toDouble());
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _measureDown() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await c.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=60000000'));
      final resp = await req.close();
      final sw = Stopwatch();
      int bytes = 0;
      await for (final chunk in resp) {
        if (!sw.isRunning) sw.start();
        bytes += chunk.length;
        final sec = sw.elapsedMicroseconds / 1e6;
        if (sec > 0.3 && mounted) setState(() => down = bytes * 8 / sec / 1e6);
        if (sec >= 8) break;
      }
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _measureUp() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      const total = 12 * 1024 * 1024;
      final req = await c.postUrl(Uri.parse('https://speed.cloudflare.com/__up'));
      req.contentLength = total;
      req.headers.contentType = ContentType.binary;
      final chunk = Uint8List(128 * 1024);
      final sw = Stopwatch()..start();
      int sent = 0;
      while (sent < total && sw.elapsedMilliseconds < 9000) {
        req.add(chunk);
        await req.flush();
        sent += chunk.length;
        final sec = sw.elapsedMicroseconds / 1e6;
        if (sec > 0.3 && mounted) setState(() => up = sent * 8 / sec / 1e6);
      }
      if (sent >= total) {
        final r = await req.close();
        await r.drain();
      } else {
        req.abort();
      }
    } finally {
      c.close(force: true);
    }
  }

  // ---------- 같은 네트워크 기기 찾기 ----------
  static const List<int> _ports = [80, 443, 445, 139, 135, 22, 53, 3389, 5555, 8009, 8080, 9100, 548, 62078];

  Future<Host?> _probe(String ip, String? gw) async {
    final open = <int>[];
    bool alive = false;
    await Future.wait(_ports.map((p) async {
      try {
        final sk = await Socket.connect(ip, p, timeout: const Duration(milliseconds: 600));
        sk.destroy();
        alive = true;
        open.add(p);
      } on SocketException catch (e) {
        if (e.osError?.errorCode == 111) alive = true; // 연결 거부 = 기기는 살아 있음
      } catch (_) {}
    }));
    if (!alive) return null;
    open.sort();
    final isGw = ip == gw;
    return Host(ip, '', _guess(open.toSet(), isGw), open, isGw);
  }

  String _guess(Set<int> o, bool isGw) {
    if (isGw) return '공유기 / 게이트웨이';
    if (o.contains(62078)) return 'iPhone / iPad (추정)';
    if (o.contains(3389) || o.contains(135) || (o.contains(445) && o.contains(139))) return 'Windows PC (추정)';
    if (o.contains(9100)) return '프린터 (추정)';
    if (o.contains(5555) || o.contains(8009)) return 'Android / 스마트TV (추정)';
    if (o.contains(548)) return 'Mac (추정)';
    if (o.contains(22)) return 'Linux / NAS 등 (추정)';
    if (o.contains(445)) return 'Windows / NAS (추정)';
    if (o.contains(80) || o.contains(443) || o.contains(8080)) return '웹 지원 기기 (추정)';
    return '종류 알 수 없음';
  }

  Future<void> _scan() async {
    if (scanning) {
      cancelScan = true;
      return;
    }
    final ip = s('localIp');
    if (ip == null || ip.split('.').length != 4) {
      toast('연결된 네트워크의 내 IP 를 알 수 없습니다. Wi-Fi 또는 유선에 연결하세요.');
      return;
    }
    final p = ip.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final base = '${p[0]}.${p[1]}.${p[2]}';
    final gw = s('gateway');
    setState(() {
      scanning = true;
      cancelScan = false;
      scanProgress = 0;
      hosts = [];
      scannedOnce = true;
    });
    final targets = <int>[for (int i = 1; i < 255; i++) if (i != p[3]) i];
    final found = <Host>[];
    int done = 0;
    for (int i = 0; i < targets.length && !cancelScan; i += 16) {
      final batch = targets.sublist(i, min(i + 16, targets.length));
      final res = await Future.wait(batch.map((x) => _probe('$base.$x', gw)));
      for (final h in res) {
        if (h != null) found.add(h);
      }
      done += batch.length;
      if (mounted) setState(() => scanProgress = done / targets.length);
    }
    // 이름(호스트명) 조회: 공유기가 알려주는 경우에만 나옵니다.
    await Future.wait(found.map((h) async {
      try {
        final r = await InternetAddress(h.ip).reverse().timeout(const Duration(milliseconds: 1500));
        if (r.host != h.ip) h.name = r.host;
      } catch (_) {}
    }));
    int last(Host h) => int.tryParse(h.ip.split('.').last) ?? 0;
    found.sort((a, b) => last(a).compareTo(last(b)));
    if (mounted) {
      setState(() {
        hosts = found;
        scanning = false;
      });
    }
  }

  Future<void> _open(String url) async {
    try {
      await _ch.invokeMethod('openUrl', {'url': url});
    } catch (e) {
      toast('열 수 없습니다: $e');
    }
  }

  // ---------- 화면 ----------
  String get transportText {
    switch (s('transport')) {
      case 'wifi':
        return '무선 (Wi-Fi)';
      case 'ethernet':
        return '유선 (이더넷)';
      case 'cellular':
        return '모바일 데이터';
      case 'vpn':
        return 'VPN';
      case 'other':
        return '기타';
      default:
        return '연결 안 됨';
    }
  }

  Widget card(String title, IconData icon, Color color, List<Widget> children, {Widget? trailing}) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFD9E5FB))),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 14, backgroundColor: color, child: Icon(icon, size: 16, color: Colors.white)),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: kBlueDark))),
            if (trailing != null) trailing,
          ]),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    );
  }

  Widget row(String label, String? value, {Widget? trailing, bool big = false}) {
    final v = (value == null || value.isEmpty) ? '-' : value;
    return InkWell(
      onLongPress: () => copy(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 92, child: Text(label, style: const TextStyle(color: Colors.black54))),
          Expanded(child: Text(v, style: TextStyle(fontSize: big ? 20 : 14, fontWeight: big ? FontWeight.bold : FontWeight.w500))),
          if (trailing != null) trailing,
        ]),
      ),
    );
  }

  Widget smallBtn(String text, IconData icon, Color color, VoidCallback? onTap) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 16),
          label: Text(text, style: const TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      );

  Widget speedBox(String label, double? v, String unit, Color c) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            Text(label, style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 4),
            Text(v == null ? '-' : (v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(unit, style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ]),
        ),
      );

  String bandText(int? f) {
    if (f == null) return '-';
    if (f < 3000) return '2.4GHz ($f MHz)';
    if (f < 5900) return '5GHz ($f MHz)';
    return '6GHz ($f MHz)';
  }

  String signalText(int? r) {
    if (r == null) return '-';
    final q = r >= -50 ? '매우 좋음' : r >= -60 ? '좋음' : r >= -70 ? '보통' : '약함';
    return '$r dBm ($q)';
  }

  @override
  Widget build(BuildContext context) {
    final wifi = s('transport') == 'wifi';
    final gw = s('gateway');
    return Scaffold(
      body: Column(children: [
        Container(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 10, 8, 12),
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [kBlueDark, Color(0xFF3B8BFF)])),
          child: Row(children: [
            const Icon(Icons.public, color: Colors.white, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text(kAppName, style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  const Text('v$kVersion', style: TextStyle(color: Color(0xFFFFECA0), fontSize: 12)),
                ]),
                const Text('내 네트워크 정보 한눈에 보기', style: TextStyle(color: Color(0xFFD6E4FF), fontSize: 12)),
              ]),
            ),
            IconButton(onPressed: loading ? null : _refresh, icon: const Icon(Icons.refresh, color: Colors.white)),
          ]),
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(padding: const EdgeInsets.only(bottom: 24, top: 4), children: [
                    if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text('정보를 읽지 못했습니다: $error', style: const TextStyle(color: Colors.red))),
                    card('외부(공인) IP', Icons.language, const Color(0xFF2B63D9), [
                      row('공인 IP', pubLoading ? '확인 중...' : (pubIp ?? pubError), big: true, trailing: smallBtn('복사', Icons.copy, const Color(0xFF2B63D9), pubIp == null ? null : () => copy(pubIp))),
                      if (pubCountry != null) row('국가', pubCountry),
                      if (pubIsp != null) row('통신사', pubIsp),
                    ]),
                    card('연결 정보', wifi ? Icons.wifi : (s('transport') == 'ethernet' ? Icons.settings_ethernet : Icons.network_check), const Color(0xFF16A085), [
                      row('연결 방식', transportText),
                      if (wifi) row('Wi-Fi 이름', s('ssid') ?? (info['hasLocation'] == true ? (info['locationOn'] == false ? '(휴대폰 위치 기능을 켜면 보입니다)' : '-') : '(위치 권한을 허용하면 보입니다)')),
                      if (wifi) row('공유기 BSSID', s('bssid')),
                      if (wifi) row('주파수', bandText(n('freq'))),
                      if (wifi) row('신호 세기', signalText(n('rssi'))),
                      if (wifi) row('연결 속도', n('linkSpeed') == null ? null : '${n('linkSpeed')} Mbps' + (n('rxSpeed') != null && n('rxSpeed')! > 0 ? '  (받기 ${n('rxSpeed')} / 보내기 ${n('txSpeed')})' : '')),
                      row('내 IP 주소', s('localIp') == null ? null : '${s('localIp')} /${n('prefix') ?? 24}'),
                      row('인터페이스', s('iface')),
                      row('DNS', list('dns').join(', ')),
                      row('게이트웨이', gw, trailing: gw == null ? null : smallBtn('공유기 접속', Icons.open_in_browser, const Color(0xFFE67E22), () => _open('http://$gw'))),
                      if (list('ifaces').isNotEmpty) row('모든 IP', list('ifaces').join('\n')),
                    ]),
                    card('속도 측정', Icons.speed, const Color(0xFF8E44AD), [
                      Row(children: [speedBox('다운로드', down, 'Mbps', const Color(0xFF2B63D9)), speedBox('업로드', up, 'Mbps', const Color(0xFF16A085)), speedBox('응답(핑)', ping, 'ms', const Color(0xFFE67E22))]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: Text(phase, style: const TextStyle(color: Colors.black54, fontSize: 12))),
                        smallBtn(testing ? '측정 중...' : '측정 시작', Icons.play_arrow, const Color(0xFF8E44AD), testing ? null : _speedTest),
                      ]),
                      const Text('인터넷 속도 측정 서버(Cloudflare)를 이용하며 데이터를 조금 사용합니다.', style: TextStyle(fontSize: 11, color: Colors.black45)),
                    ]),
                    card('내 기기', Icons.phone_android, const Color(0xFF34495E), [
                      row('기기 이름', s('deviceName')),
                      row('제조사 / 모델', '${s('manufacturer') ?? ''} ${s('model') ?? ''}'.trim()),
                      row('운영체제', 'Android ${s('androidVersion') ?? '-'} (API ${s('sdk') ?? '-'})'),
                      row('커널', s('kernel')),
                    ]),
                    card('같은 네트워크의 기기', Icons.devices, const Color(0xFFC0392B), [
                      if (scanning) LinearProgressIndicator(value: scanProgress),
                      if (!scannedOnce) const Text('[검색 시작]을 누르면 같은 공유기에 연결된 기기의 IP, 이름, 종류(추정)를 찾습니다.', style: TextStyle(color: Colors.black54, fontSize: 12)),
                      if (scannedOnce && !scanning && hosts.isEmpty) const Text('찾은 기기가 없습니다. (공유기의 기기 간 접속 차단 설정이 켜져 있을 수 있습니다)', style: TextStyle(color: Colors.black54, fontSize: 12)),
                      for (final h in hosts) hostTile(h),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(child: Text(hosts.isEmpty ? '' : '${hosts.length}대 찾음', style: const TextStyle(color: kBlueDark, fontWeight: FontWeight.bold))),
                        smallBtn(scanning ? '중지' : '검색 시작', scanning ? Icons.stop : Icons.search, const Color(0xFFC0392B), _scan),
                      ]),
                      const Text('운영체제는 열려 있는 포트로 짐작한 값이라 틀릴 수 있습니다. 컴퓨터 이름은 공유기가 알려주는 경우에만 나옵니다.', style: TextStyle(fontSize: 11, color: Colors.black45)),
                    ]),
                  ]),
                ),
        ),
      ]),
    );
  }

  Widget hostTile(Host h) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: kBlueSoft, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(h.isGateway ? Icons.router : Icons.computer, color: kBlue, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(h.ip + (h.name.isEmpty ? '' : '   ${h.name}'), style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(h.kind + (h.ports.isEmpty ? '' : '   포트 ${h.ports.join(',')}'), style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ]),
        ),
        smallBtn('복사', Icons.copy, const Color(0xFF2B63D9), () => copy(h.ip)),
        if (h.ports.contains(80) || h.ports.contains(8080)) smallBtn('열기', Icons.open_in_browser, const Color(0xFFE67E22), () => _open('http://${h.ip}${h.ports.contains(80) ? '' : ':8080'}')),
      ]),
    );
  }
}
