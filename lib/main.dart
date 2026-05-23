import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const NexaPlayApp());
}

// ══════════════════════════════════════════════
//  COLORES — Dark Premium
// ══════════════════════════════════════════════
const kBg      = Color(0xFF06090F);
const kBg2     = Color(0xFF0C1220);
const kBg3     = Color(0xFF111830);
const kSurf    = Color(0xFF141C32);
const kSurf2   = Color(0xFF1A2440);
const kBorder  = Color(0xFF253050);
const kCyan    = Color(0xFF00E5FF);
const kMagenta = Color(0xFFE040FB);
const kBlue    = Color(0xFF448AFF);
const kGreen   = Color(0xFF69F0AE);
const kOrange  = Color(0xFFFFAB40);
const kRed     = Color(0xFFFF5252);
const kGold    = Color(0xFFFFD740);
const kT1      = Color(0xFFF0F2FF);
const kT2      = Color(0xFF8890B0);
const kT3      = Color(0xFF4A5070);

// ══════════════════════════════════════════════
//  MODELOS
// ══════════════════════════════════════════════

// Cuenta guardada
class Account {
  String id, name, type; // type: xtream | m3u
  String server, username, password; // para xtream
  String m3uUrl; // para m3u
  DateTime createdAt;

  Account({
    String? id, required this.name, required this.type,
    this.server = '', this.username = '', this.password = '',
    this.m3uUrl = '', DateTime? createdAt,
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'type': type, 'server': server,
    'username': username, 'password': password, 'm3uUrl': m3uUrl,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: j['id'], name: j['name'] ?? '', type: j['type'] ?? 'xtream',
    server: j['server'] ?? '', username: j['username'] ?? '',
    password: j['password'] ?? '', m3uUrl: j['m3uUrl'] ?? '',
    createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
  );
}

// Canal / Contenido
class Channel {
  String name, url, logo, group, epgId;
  String type; // live, movie, series
  int streamId;

  Channel({
    required this.name, required this.url, this.logo = '',
    this.group = 'Sin categoría', this.epgId = '',
    this.type = 'live', this.streamId = 0,
  });
}

// ══════════════════════════════════════════════
//  STORAGE
// ══════════════════════════════════════════════
class Store {
  static SharedPreferences? _p;
  static Future<void> init() async => _p = await SharedPreferences.getInstance();

  static List<Account> getAccounts() {
    final r = _p?.getString('accounts');
    if (r == null) return [];
    return (jsonDecode(r) as List).map((e) => Account.fromJson(e)).toList();
  }
  static Future<void> saveAccounts(List<Account> l) async =>
    await _p?.setString('accounts', jsonEncode(l.map((e) => e.toJson()).toList()));

  static List<String> getFavs() => _p?.getStringList('favs') ?? [];
  static Future<void> saveFavs(List<String> l) async => await _p?.setStringList('favs', l);

  static List<String> getHistory() => _p?.getStringList('history') ?? [];
  static Future<void> addHistory(String url) async {
    final h = getHistory();
    h.remove(url);
    h.insert(0, url);
    if (h.length > 50) h.removeLast();
    await _p?.setStringList('history', h);
  }
}

// ══════════════════════════════════════════════
//  PARSER M3U
// ══════════════════════════════════════════════
class M3uParser {
  static List<Channel> parse(String content, {String type = 'live'}) {
    final channels = <Channel>[];
    final lines = content.split('\n');
    String name = '', logo = '', group = '', epgId = '';

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXTINF')) {
        // Parsear atributos
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line);
        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
        final epgMatch = RegExp(r'tvg-id="([^"]*)"').firstMatch(line);
        final nameMatch = RegExp(r',(.+)$').firstMatch(line);

        logo = logoMatch?.group(1) ?? '';
        group = groupMatch?.group(1) ?? 'Sin categoría';
        epgId = epgMatch?.group(1) ?? '';
        name = nameMatch?.group(1)?.trim() ?? 'Canal $i';
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        // Es una URL
        if (name.isNotEmpty || line.startsWith('http')) {
          // Detectar tipo por extensión o grupo
          String chType = type;
          final lowerGroup = group.toLowerCase();
          final lowerUrl = line.toLowerCase();
          if (lowerGroup.contains('movie') || lowerGroup.contains('pelicul') || lowerGroup.contains('vod') ||
              lowerUrl.contains('/movie/') || lowerUrl.endsWith('.mp4') || lowerUrl.endsWith('.mkv')) {
            chType = 'movie';
          } else if (lowerGroup.contains('serie') || lowerUrl.contains('/series/')) {
            chType = 'series';
          }

          channels.add(Channel(
            name: name.isEmpty ? 'Canal ${channels.length + 1}' : name,
            url: line, logo: logo, group: group, epgId: epgId, type: chType,
          ));
          name = ''; logo = ''; group = ''; epgId = '';
        }
      }
    }
    return channels;
  }
}

// ══════════════════════════════════════════════
//  XTREAM API
// ══════════════════════════════════════════════
class XtreamApi {
  static Future<Map<String, dynamic>?> authenticate(String server, String user, String pass) async {
    try {
      final url = '${server.replaceAll(RegExp(r'/$'), '')}/player_api.php?username=$user&password=$pass';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['user_info'] != null && data['user_info']['auth'] == 1) {
          return data;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<List<Channel>> getLive(String server, String user, String pass) async {
    try {
      final url = '${server.replaceAll(RegExp(r'/$'), '')}/player_api.php?username=$user&password=$pass&action=get_live_streams';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return list.map((e) => Channel(
          name: e['name'] ?? '', streamId: e['stream_id'] ?? 0,
          url: '${server.replaceAll(RegExp(r'/$'), '')}/$user/$pass/${e['stream_id']}',
          logo: e['stream_icon'] ?? '', group: e['category_name'] ?? 'Sin categoría',
          epgId: e['epg_channel_id'] ?? '', type: 'live',
        )).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<List<Channel>> getVod(String server, String user, String pass) async {
    try {
      final url = '${server.replaceAll(RegExp(r'/$'), '')}/player_api.php?username=$user&password=$pass&action=get_vod_streams';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return list.map((e) => Channel(
          name: e['name'] ?? '', streamId: e['stream_id'] ?? 0,
          url: '${server.replaceAll(RegExp(r'/$'), '')}/movie/$user/$pass/${e['stream_id']}.${e['container_extension'] ?? 'mp4'}',
          logo: e['stream_icon'] ?? '', group: e['category_name'] ?? 'Sin categoría',
          type: 'movie',
        )).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<List<Channel>> getSeries(String server, String user, String pass) async {
    try {
      final url = '${server.replaceAll(RegExp(r'/$'), '')}/player_api.php?username=$user&password=$pass&action=get_series';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return list.map((e) => Channel(
          name: e['name'] ?? '', streamId: e['series_id'] ?? 0,
          url: '', logo: e['cover'] ?? '', group: e['category_name'] ?? 'Sin categoría',
          type: 'series',
        )).toList();
      }
    } catch (_) {}
    return [];
  }

  static String getM3u(String server, String user, String pass) {
    return '${server.replaceAll(RegExp(r'/$'), '')}/get.php?username=$user&password=$pass&type=m3u_plus&output=mpegts';
  }
}

// ══════════════════════════════════════════════
//  APP
// ══════════════════════════════════════════════
class NexaPlayApp extends StatelessWidget {
  const NexaPlayApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'NexaPlay IPTV',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: const ColorScheme.dark(primary: kCyan, secondary: kMagenta, surface: kSurf),
      scaffoldBackgroundColor: kBg,
      appBarTheme: const AppBarTheme(backgroundColor: kBg2, foregroundColor: kT1, elevation: 0),
      useMaterial3: true,
    ),
    home: const SplashScreen(),
  );
}

// ══════════════════════════════════════════════
//  SPLASH
// ══════════════════════════════════════════════
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ac;
  late Animation<double> _fade, _scale;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    _fade = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _ac, curve: Curves.easeIn));
    _scale = Tween<double>(begin: 0.7, end: 1).animate(CurvedAnimation(parent: _ac, curve: Curves.elasticOut));
    _ac.forward();
    _load();
  }

  Future<void> _load() async {
    await Store.init();
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void dispose() { _ac.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: Container(
      decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment.center, radius: 1.2, colors: [Color(0xFF0C1840), kBg])),
      child: Center(child: FadeTransition(opacity: _fade, child: ScaleTransition(scale: _scale, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 120, height: 120,
          decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
            BoxShadow(color: kCyan.withOpacity(0.4), blurRadius: 50, spreadRadius: 8),
            BoxShadow(color: kMagenta.withOpacity(0.2), blurRadius: 70, spreadRadius: 15),
          ]),
          child: ClipOval(child: Container(
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [kCyan.withOpacity(0.3), kMagenta.withOpacity(0.2)])),
            child: const Icon(Icons.play_circle_fill, color: kCyan, size: 70),
          )),
        ),
        const SizedBox(height: 24),
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(colors: [kCyan, kMagenta]).createShader(b),
          child: const Text('NexaPlay', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 4)),
        ),
        const SizedBox(height: 4),
        const Text('IPTV', style: TextStyle(color: kT3, fontSize: 14, letterSpacing: 8, fontWeight: FontWeight.w300)),
        const SizedBox(height: 40),
        SizedBox(width: 120, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: const LinearProgressIndicator(backgroundColor: kBg3, color: kCyan, minHeight: 3))),
      ])))),
    ),
  );
}

// ══════════════════════════════════════════════
//  LOGIN
// ══════════════════════════════════════════════
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final _serverCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _m3uCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String _error = '';
  List<Account> _accounts = [];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _accounts = Store.getAccounts();
  }

  @override
  void dispose() { _tabCtrl.dispose(); _serverCtrl.dispose(); _userCtrl.dispose(); _passCtrl.dispose(); _m3uCtrl.dispose(); _nameCtrl.dispose(); super.dispose(); }

  // Login Xtream
  Future<void> _loginXtream() async {
    if (_serverCtrl.text.isEmpty || _userCtrl.text.isEmpty || _passCtrl.text.isEmpty) {
      setState(() => _error = 'Completa todos los campos');
      return;
    }
    setState(() { _loading = true; _error = ''; });

    String server = _serverCtrl.text.trim();
    if (!server.startsWith('http')) server = 'http://$server';

    final auth = await XtreamApi.authenticate(server, _userCtrl.text.trim(), _passCtrl.text.trim());
    if (auth != null) {
      // Guardar cuenta
      final acc = Account(
        name: _nameCtrl.text.isEmpty ? _userCtrl.text : _nameCtrl.text,
        type: 'xtream', server: server,
        username: _userCtrl.text.trim(), password: _passCtrl.text.trim(),
      );
      _accounts.add(acc);
      await Store.saveAccounts(_accounts);

      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => HomeScreen(account: acc),
        ));
      }
    } else {
      setState(() { _error = 'Error de autenticación. Verifica los datos.'; _loading = false; });
    }
  }

  // Login M3U
  Future<void> _loginM3u() async {
    if (_m3uCtrl.text.isEmpty) {
      setState(() => _error = 'Ingresa la URL de la lista M3U');
      return;
    }
    setState(() { _loading = true; _error = ''; });

    final acc = Account(
      name: _nameCtrl.text.isEmpty ? 'Lista M3U' : _nameCtrl.text,
      type: 'm3u', m3uUrl: _m3uCtrl.text.trim(),
    );
    _accounts.add(acc);
    await Store.saveAccounts(_accounts);

    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(
        builder: (_) => HomeScreen(account: acc),
      ));
    }
  }

  // Abrir archivo M3U local
  Future<void> _pickM3uFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result != null && result.files.isNotEmpty && result.files.first.path != null) {
        _m3uCtrl.text = result.files.first.path!;
      }
    } catch (_) {}
  }

  // Login con cuenta guardada
  void _loginSaved(Account acc) {
    Navigator.pushReplacement(context, MaterialPageRoute(
      builder: (_) => HomeScreen(account: acc),
    ));
  }

  void _deleteSaved(Account acc) async {
    _accounts.removeWhere((a) => a.id == acc.id);
    await Store.saveAccounts(_accounts);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: Container(
      decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.4), radius: 1.5, colors: [Color(0xFF0C1840), kBg])),
      child: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
        const SizedBox(height: 20),
        // Logo
        ShaderMask(
          shaderCallback: (b) => const LinearGradient(colors: [kCyan, kMagenta]).createShader(b),
          child: const Text('NexaPlay', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 3)),
        ),
        const SizedBox(height: 4),
        const Text('IPTV Player', style: TextStyle(color: kT3, fontSize: 12, letterSpacing: 2)),
        const SizedBox(height: 24),

        // Cuentas guardadas
        if (_accounts.isNotEmpty) ...[
          const Align(alignment: Alignment.centerLeft, child: Text('Cuentas guardadas', style: TextStyle(color: kT2, fontSize: 13, fontWeight: FontWeight.w600))),
          const SizedBox(height: 8),
          ...(_accounts.map((a) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: kSurf, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
            child: ListTile(
              leading: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(shape: BoxShape.circle, color: a.type == 'xtream' ? kCyan.withOpacity(0.15) : kMagenta.withOpacity(0.15)),
                child: Icon(a.type == 'xtream' ? Icons.dns : Icons.list, color: a.type == 'xtream' ? kCyan : kMagenta, size: 20),
              ),
              title: Text(a.name, style: const TextStyle(color: kT1, fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text(a.type == 'xtream' ? a.server : 'Lista M3U', style: const TextStyle(color: kT3, fontSize: 11)),
              trailing: IconButton(icon: const Icon(Icons.delete_outline, color: kRed, size: 18), onPressed: () => _deleteSaved(a)),
              onTap: () => _loginSaved(a),
            ),
          ))),
          const SizedBox(height: 16),
          const Divider(color: kBorder, height: 1),
          const SizedBox(height: 16),
        ],

        // Nombre de cuenta
        _field(_nameCtrl, 'Nombre de la cuenta (opcional)', Icons.bookmark_outline),
        const SizedBox(height: 12),

        // Tabs Xtream / M3U
        Container(
          decoration: BoxDecoration(color: kSurf, borderRadius: BorderRadius.circular(12)),
          child: TabBar(
            controller: _tabCtrl,
            labelColor: kCyan,
            unselectedLabelColor: kT3,
            indicatorColor: kCyan,
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            tabs: const [
              Tab(text: 'Xtream Codes'),
              Tab(text: 'Lista M3U'),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Contenido tabs
        SizedBox(
          height: 240,
          child: TabBarView(controller: _tabCtrl, children: [
            // Xtream
            Column(children: [
              _field(_serverCtrl, 'Servidor (ej: http://url.com:8080)', Icons.dns_outlined),
              const SizedBox(height: 10),
              _field(_userCtrl, 'Usuario', Icons.person_outline),
              const SizedBox(height: 10),
              _field(_passCtrl, 'Contraseña', Icons.lock_outline, obscure: true),
              const SizedBox(height: 14),
              _loginBtn('CONECTAR', _loginXtream),
            ]),
            // M3U
            Column(children: [
              _field(_m3uCtrl, 'URL de lista M3U o ruta local', Icons.link),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _actionBtn(Icons.folder_open, 'Archivo local', kMagenta, _pickM3uFile)),
                const SizedBox(width: 8),
                Expanded(child: _actionBtn(Icons.cloud_download, 'URL remota', kCyan, () {})),
              ]),
              const SizedBox(height: 14),
              _loginBtn('CARGAR LISTA', _loginM3u),
            ]),
          ]),
        ),

        if (_error.isNotEmpty) Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_error, style: const TextStyle(color: kRed, fontSize: 12)),
        ),

        if (_loading) const Padding(
          padding: EdgeInsets.only(top: 16),
          child: CircularProgressIndicator(color: kCyan),
        ),
      ]))),
    ),
  );

  Widget _field(TextEditingController c, String hint, IconData icon, {bool obscure = false}) => Container(
    decoration: BoxDecoration(color: kSurf, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
    child: TextField(
      controller: c, obscureText: obscure,
      style: const TextStyle(color: kT1, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint, hintStyle: const TextStyle(color: kT3, fontSize: 13),
        prefixIcon: Icon(icon, color: kCyan, size: 18),
        border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(vertical: 14),
      ),
    ),
  );

  Widget _loginBtn(String label, VoidCallback fn) => SizedBox(
    width: double.infinity, height: 48,
    child: GestureDetector(
      onTap: _loading ? null : fn,
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [kCyan, kBlue]),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: kCyan.withOpacity(0.3), blurRadius: 16)],
        ),
        child: Center(child: Text(label, style: const TextStyle(color: kBg, fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: 2))),
      ),
    ),
  );

  Widget _actionBtn(IconData icon, String label, Color color, VoidCallback fn) => GestureDetector(
    onTap: fn,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.3))),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 11)),
      ]),
    ),
  );
}

// ══════════════════════════════════════════════
//  HOME
// ══════════════════════════════════════════════
class HomeScreen extends StatefulWidget {
  final Account account;
  const HomeScreen({super.key, required this.account});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  List<Channel> _allChannels = [];
  List<Channel> _live = [];
  List<Channel> _movies = [];
  List<Channel> _series = [];
  List<String> _favUrls = [];
  bool _loading = true;
  String _error = '';
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _selectedGroup = 'Todas';

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 5, vsync: this);
    _favUrls = Store.getFavs();
    _loadContent();
  }

  Future<void> _loadContent() async {
    setState(() { _loading = true; _error = ''; });
    try {
      if (widget.account.type == 'xtream') {
        await _loadXtream();
      } else {
        await _loadM3u();
      }
    } catch (e) {
      setState(() => _error = 'Error al cargar: $e');
    }
    setState(() => _loading = false);
  }

  Future<void> _loadXtream() async {
    final s = widget.account.server;
    final u = widget.account.username;
    final p = widget.account.password;

    // Intentar cargar por API primero
    _live = await XtreamApi.getLive(s, u, p);
    _movies = await XtreamApi.getVod(s, u, p);
    _series = await XtreamApi.getSeries(s, u, p);

    // Si la API no devuelve nada, intentar M3U
    if (_live.isEmpty && _movies.isEmpty) {
      final m3uUrl = XtreamApi.getM3u(s, u, p);
      final res = await http.get(Uri.parse(m3uUrl)).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        _allChannels = M3uParser.parse(res.body);
        _live = _allChannels.where((c) => c.type == 'live').toList();
        _movies = _allChannels.where((c) => c.type == 'movie').toList();
        _series = _allChannels.where((c) => c.type == 'series').toList();
      }
    }

    _allChannels = [..._live, ..._movies, ..._series];
  }

  Future<void> _loadM3u() async {
    String content = '';
    final url = widget.account.m3uUrl;

    if (url.startsWith('http')) {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) content = res.body;
    } else {
      // Archivo local
      final file = File(url);
      if (await file.exists()) content = await file.readAsString();
    }

    if (content.isNotEmpty) {
      _allChannels = M3uParser.parse(content);
      _live = _allChannels.where((c) => c.type == 'live').toList();
      _movies = _allChannels.where((c) => c.type == 'movie').toList();
      _series = _allChannels.where((c) => c.type == 'series').toList();
      // Si no hay clasificación, todo es live
      if (_movies.isEmpty && _series.isEmpty) {
        _live = _allChannels;
      }
    }
  }

  void _toggleFav(Channel ch) {
    setState(() {
      if (_favUrls.contains(ch.url)) _favUrls.remove(ch.url);
      else _favUrls.add(ch.url);
    });
    Store.saveFavs(_favUrls);
  }

  List<Channel> _filterList(List<Channel> list) {
    var result = list;
    if (_searchQuery.isNotEmpty) {
      result = result.where((c) => c.name.toLowerCase().contains(_searchQuery) || c.group.toLowerCase().contains(_searchQuery)).toList();
    }
    if (_selectedGroup != 'Todas') {
      result = result.where((c) => c.group == _selectedGroup).toList();
    }
    return result;
  }

  Set<String> _getGroups(List<Channel> list) {
    final groups = <String>{'Todas'};
    for (final c in list) { if (c.group.isNotEmpty) groups.add(c.group); }
    return groups;
  }

  void _playChannel(Channel ch) {
    Store.addHistory(ch.url);
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlayerScreen(channel: ch, playlist: _filterList(_live.isNotEmpty ? _live : _allChannels)),
    ));
  }

  @override
  void dispose() { _tabCtrl.dispose(); _searchCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: Stack(children: [
      Container(decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(-0.5, -0.8), radius: 1.5, colors: [Color(0xFF0C1840), kBg]))),
      Column(children: [
        // Header
        Container(
          color: kBg2,
          child: SafeArea(bottom: false, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 8, 8, 4), child: Row(children: [
              ShaderMask(
                shaderCallback: (b) => const LinearGradient(colors: [kCyan, kMagenta]).createShader(b),
                child: const Text('NexaPlay', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.white, fontSize: 20, letterSpacing: 2)),
              ),
              const Spacer(),
              Text(widget.account.name, style: const TextStyle(color: kT3, fontSize: 11)),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, color: kT2, size: 20),
                onPressed: _loadContent,
              ),
              IconButton(
                icon: const Icon(Icons.logout, color: kRed, size: 20),
                onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen())),
              ),
            ])),
            // Search
            Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6), child: Container(
              height: 40,
              decoration: BoxDecoration(color: kSurf, borderRadius: BorderRadius.circular(10), border: Border.all(color: kBorder)),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: kT1, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Buscar canales, películas...', hintStyle: const TextStyle(color: kT3, fontSize: 12),
                  prefixIcon: const Icon(Icons.search, color: kT3, size: 18),
                  suffixIcon: _searchQuery.isNotEmpty ? IconButton(icon: const Icon(Icons.close, color: kT3, size: 16), onPressed: () { _searchCtrl.clear(); setState(() => _searchQuery = ''); }) : null,
                  border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
              ),
            )),
            // Tabs
            TabBar(
              controller: _tabCtrl,
              isScrollable: false,
              labelColor: kCyan,
              unselectedLabelColor: kT3,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 10),
              indicatorColor: kCyan,
              indicatorWeight: 2,
              dividerColor: Colors.transparent,
              tabs: [
                Tab(icon: const Icon(Icons.live_tv, size: 18), text: 'En Vivo (${_live.length})'),
                Tab(icon: const Icon(Icons.movie, size: 18), text: 'Películas (${_movies.length})'),
                Tab(icon: const Icon(Icons.tv, size: 18), text: 'Series (${_series.length})'),
                Tab(icon: const Icon(Icons.favorite, size: 18), text: 'Favs'),
                Tab(icon: const Icon(Icons.history, size: 18), text: 'Historial'),
              ],
            ),
          ])),
        ),
        // Content
        Expanded(
          child: _loading
            ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(color: kCyan),
                SizedBox(height: 16),
                Text('Cargando contenido...', style: TextStyle(color: kT3)),
              ]))
            : _error.isNotEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline, color: kRed, size: 48),
                  const SizedBox(height: 12),
                  Text(_error, style: const TextStyle(color: kT2), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _loadContent, style: ElevatedButton.styleFrom(backgroundColor: kCyan),
                    child: const Text('Reintentar', style: TextStyle(color: kBg))),
                ]))
              : TabBarView(controller: _tabCtrl, children: [
                  _channelList(_live),
                  _channelList(_movies),
                  _channelList(_series),
                  _favList(),
                  _historyList(),
                ]),
        ),
      ]),
    ]),
  );

  Widget _channelList(List<Channel> channels) {
    final filtered = _filterList(channels);
    final groups = _getGroups(channels);

    return Column(children: [
      // Filtro por categoría
      if (groups.length > 2) SizedBox(height: 36, child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: groups.length,
        itemBuilder: (_, i) {
          final g = groups.elementAt(i);
          final sel = _selectedGroup == g;
          return Padding(padding: const EdgeInsets.only(right: 6), child: GestureDetector(
            onTap: () => setState(() => _selectedGroup = g),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: sel ? kCyan.withOpacity(0.2) : kSurf,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: sel ? kCyan : kBorder),
              ),
              child: Center(child: Text(g, style: TextStyle(color: sel ? kCyan : kT3, fontSize: 10, fontWeight: sel ? FontWeight.w700 : FontWeight.w400))),
            ),
          ));
        },
      )),
      // Lista
      Expanded(
        child: filtered.isEmpty
          ? const Center(child: Text('Sin contenido', style: TextStyle(color: kT3)))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              itemCount: filtered.length,
              itemBuilder: (_, i) => _channelTile(filtered[i]),
            ),
      ),
    ]);
  }

  Widget _channelTile(Channel ch) {
    final isFav = _favUrls.contains(ch.url);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: kSurf, borderRadius: BorderRadius.circular(10), border: Border.all(color: kBorder.withOpacity(0.5))),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: kBg3),
          child: ch.logo.isNotEmpty && ch.logo.startsWith('http')
            ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(ch.logo, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: kCyan, size: 22)))
            : Icon(ch.type == 'movie' ? Icons.movie : ch.type == 'series' ? Icons.tv : Icons.live_tv, color: kCyan, size: 22),
        ),
        title: Text(ch.name, style: const TextStyle(color: kT1, fontWeight: FontWeight.w600, fontSize: 13), overflow: TextOverflow.ellipsis),
        subtitle: Text(ch.group, style: const TextStyle(color: kT3, fontSize: 10), overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTap: () => _toggleFav(ch),
            child: Icon(isFav ? Icons.favorite : Icons.favorite_border, color: isFav ? kMagenta : kT3, size: 18),
          ),
          const SizedBox(width: 8),
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(shape: BoxShape.circle, color: kCyan.withOpacity(0.15)),
            child: const Icon(Icons.play_arrow, color: kCyan, size: 18),
          ),
        ]),
        onTap: () => _playChannel(ch),
      ),
    );
  }

  Widget _favList() {
    final favChannels = _allChannels.where((c) => _favUrls.contains(c.url)).toList();
    return favChannels.isEmpty
      ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.favorite_border, size: 48, color: kT3),
          SizedBox(height: 8),
          Text('Sin favoritos', style: TextStyle(color: kT3)),
        ]))
      : ListView.builder(
          padding: const EdgeInsets.all(10),
          itemCount: favChannels.length,
          itemBuilder: (_, i) => _channelTile(favChannels[i]),
        );
  }

  Widget _historyList() {
    final history = Store.getHistory();
    final histChannels = <Channel>[];
    for (final url in history) {
      final ch = _allChannels.where((c) => c.url == url).toList();
      if (ch.isNotEmpty) histChannels.add(ch.first);
    }
    return histChannels.isEmpty
      ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.history, size: 48, color: kT3),
          SizedBox(height: 8),
          Text('Sin historial', style: TextStyle(color: kT3)),
        ]))
      : ListView.builder(
          padding: const EdgeInsets.all(10),
          itemCount: histChannels.length,
          itemBuilder: (_, i) => _channelTile(histChannels[i]),
        );
  }
}

// ══════════════════════════════════════════════
//  PLAYER
// ══════════════════════════════════════════════
class PlayerScreen extends StatefulWidget {
  final Channel channel;
  final List<Channel> playlist;
  const PlayerScreen({super.key, required this.channel, this.playlist = const []});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _vpc;
  bool _isInit = false;
  bool _showControls = true;
  bool _isFullscreen = false;
  bool _isBuffering = true;
  late Channel _current;
  int _currentIdx = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _current = widget.channel;
    _currentIdx = widget.playlist.indexWhere((c) => c.url == _current.url);
    if (_currentIdx < 0) _currentIdx = 0;
    _initPlayer(_current.url);
  }

  Future<void> _initPlayer(String url) async {
    await _vpc?.dispose();
    setState(() { _isInit = false; _isBuffering = true; _error = ''; });
    // Auto-fix: si es https en puerto 80, cambiar a http
    if (url.startsWith("https://") && url.contains(":80")) {
      url = url.replaceFirst("https://", "http://");
    }
    try {
      _vpc = VideoPlayerController.networkUrl(Uri.parse(url));
      await _vpc!.initialize();
      _vpc!.play();
      _vpc!.addListener(() { if (mounted) setState(() { _isBuffering = _vpc!.value.isBuffering; }); });
      setState(() => _isInit = true);
    } catch (e) {
      // Reintentar con http si era https o viceversa
      try {
        String alt = url.startsWith("https://") ? url.replaceFirst("https://", "http://") : url.replaceFirst("http://", "https://");
        await _vpc?.dispose();
        _vpc = VideoPlayerController.networkUrl(Uri.parse(alt));
        await _vpc!.initialize();
        _vpc!.play();
        _vpc!.addListener(() { if (mounted) setState(() { _isBuffering = _vpc!.value.isBuffering; }); });
        setState(() => _isInit = true);
      } catch (e2) {
        setState(() => _error = "Error al reproducir");
      }
    }
    Future.delayed(const Duration(seconds: 4), () { if (mounted) setState(() => _showControls = false); });
  }
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _nextChannel() {
    if (widget.playlist.isEmpty) return;
    _currentIdx = (_currentIdx + 1) % widget.playlist.length;
    _current = widget.playlist[_currentIdx];
    _initPlayer(_current.url);
  }

  void _prevChannel() {
    if (widget.playlist.isEmpty) return;
    _currentIdx = (_currentIdx - 1 + widget.playlist.length) % widget.playlist.length;
    _current = widget.playlist[_currentIdx];
    _initPlayer(_current.url);
  }

  @override
  void dispose() {
    _vpc?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      onDoubleTap: () {
        if (_vpc != null && _isInit) {
          _vpc!.value.isPlaying ? _vpc!.pause() : _vpc!.play();
        }
      },
      onHorizontalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -200) _nextChannel();
        if ((details.primaryVelocity ?? 0) > 200) _prevChannel();
      },
      child: Stack(children: [
        // Video
        Center(
          child: _error.isNotEmpty
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error, color: kRed, size: 48),
                const SizedBox(height: 8),
                Text(_error, style: const TextStyle(color: kT2, fontSize: 12), textAlign: TextAlign.center),
              ])
            : _isInit && _vpc != null
              ? AspectRatio(aspectRatio: _vpc!.value.aspectRatio, child: VideoPlayer(_vpc!))
              : const CircularProgressIndicator(color: kCyan),
        ),

        // Buffering
        if (_isBuffering && _isInit) const Center(child: CircularProgressIndicator(color: kCyan, strokeWidth: 2)),

        // Controles overlay
        if (_showControls) ...[
          // Top bar
          Positioned(top: 0, left: 0, right: 0, child: Container(
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withOpacity(0.8), Colors.transparent])),
            child: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(_current.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14), overflow: TextOverflow.ellipsis),
                Text(_current.group, style: const TextStyle(color: kT2, fontSize: 11)),
              ])),
            ]))),
          )),

          // Center controls
          Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.playlist.length > 1) IconButton(
              icon: const Icon(Icons.skip_previous, color: Colors.white, size: 36),
              onPressed: _prevChannel,
            ),
            const SizedBox(width: 16),
            GestureDetector(
              onTap: () {
                if (_vpc != null && _isInit) {
                  setState(() { _vpc!.value.isPlaying ? _vpc!.pause() : _vpc!.play(); });
                }
              },
              child: Container(
                width: 64, height: 64,
                decoration: BoxDecoration(shape: BoxShape.circle, color: kCyan.withOpacity(0.3)),
                child: Icon(
                  _vpc != null && _isInit && _vpc!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white, size: 38,
                ),
              ),
            ),
            const SizedBox(width: 16),
            if (widget.playlist.length > 1) IconButton(
              icon: const Icon(Icons.skip_next, color: Colors.white, size: 36),
              onPressed: _nextChannel,
            ),
          ])),

          // Bottom bar
          Positioned(bottom: 0, left: 0, right: 0, child: Container(
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black.withOpacity(0.8), Colors.transparent])),
            child: SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_isInit && _vpc != null) SliderTheme(
                data: SliderThemeData(trackHeight: 3, thumbColor: kCyan, activeTrackColor: kCyan, inactiveTrackColor: Colors.white24, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                child: Slider(
                  value: _vpc!.value.duration.inSeconds > 0 ? _vpc!.value.position.inSeconds.toDouble().clamp(0, _vpc!.value.duration.inSeconds.toDouble()) : 0,
                  max: _vpc!.value.duration.inSeconds > 0 ? _vpc!.value.duration.inSeconds.toDouble() : 1,
                  onChanged: (v) { _vpc!.seekTo(Duration(seconds: v.toInt())); },
                ),
              ),
              Row(children: [
                if (_isInit && _vpc != null) Text(_fmt(_vpc!.value.position), style: const TextStyle(color: Colors.white, fontSize: 11)),
                if (_isInit && _vpc != null) Text(" / ${_fmt(_vpc!.value.duration)}", style: const TextStyle(color: kT3, fontSize: 11)),
                const Spacer(),
                if (widget.playlist.length > 1) Text("${_currentIdx + 1}/${widget.playlist.length}", style: const TextStyle(color: kT2, fontSize: 11)),
                const SizedBox(width: 12),
                IconButton(icon: const Icon(Icons.fullscreen, color: Colors.white, size: 24), onPressed: _toggleFullscreen),
              ]),
            ]))),
          )),
        ],
      ]),
    ),
  );

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
