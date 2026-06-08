import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:audiotags/audiotags.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

const String kGithubRepo = 'skydivex/sono';
const String kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(ChangeNotifierProvider(create: (_) => SonoProvider(), child: const SonoApp()));
}

// ─── ENUMS ────────────────────────────────────────────────────────────────────

enum SortType { titleAsc, titleDesc, artistAsc, artistDesc, dateAddedAsc, dateAddedDesc }

extension SortTypeLabel on SortType {
  String get label {
    switch (this) {
      case SortType.titleAsc: return 'İsim (A→Z)';
      case SortType.titleDesc: return 'İsim (Z→A)';
      case SortType.artistAsc: return 'Sanatçı (A→Z)';
      case SortType.artistDesc: return 'Sanatçı (Z→A)';
      case SortType.dateAddedAsc: return 'Tarih (Eskiden Yeniye)';
      case SortType.dateAddedDesc: return 'Tarih (Yeniden Eskiye)';
    }
  }
}

enum ThemeAccent { purple, blue, green, red, orange, pink }

extension ThemeAccentColor on ThemeAccent {
  Color get color {
    switch (this) {
      case ThemeAccent.purple: return const Color(0xFF6C63FF);
      case ThemeAccent.blue: return const Color(0xFF2196F3);
      case ThemeAccent.green: return const Color(0xFF4CAF50);
      case ThemeAccent.red: return const Color(0xFFF44336);
      case ThemeAccent.orange: return const Color(0xFFFF9800);
      case ThemeAccent.pink: return const Color(0xFFE91E63);
    }
  }
  String get label {
    switch (this) {
      case ThemeAccent.purple: return 'Mor';
      case ThemeAccent.blue: return 'Mavi';
      case ThemeAccent.green: return 'Yeşil';
      case ThemeAccent.red: return 'Kırmızı';
      case ThemeAccent.orange: return 'Turuncu';
      case ThemeAccent.pink: return 'Pembe';
    }
  }
}

// ─── MODEL ────────────────────────────────────────────────────────────────────

class SongModel {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String path;
  final int duration;
  final DateTime dateAdded;
  Uint8List? artwork;

  SongModel({
    required this.id, required this.title, required this.artist,
    required this.album, required this.path, required this.duration,
    required this.dateAdded, this.artwork,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'artist': artist, 'album': album,
    'path': path, 'duration': duration, 'dateAdded': dateAdded.toIso8601String(),
    'artwork': artwork != null ? base64Encode(artwork!) : null,
  };

  factory SongModel.fromJson(Map<String, dynamic> j) => SongModel(
    id: j['id'], title: j['title'], artist: j['artist'], album: j['album'],
    path: j['path'], duration: j['duration'], dateAdded: DateTime.parse(j['dateAdded']),
    artwork: j['artwork'] != null ? base64Decode(j['artwork']) : null,
  );
}

// ─── PROVIDER ─────────────────────────────────────────────────────────────────

class SonoProvider extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();

  List<SongModel> allSongs = [];
  List<SongModel> filteredSongs = [];
  List<SongModel> queue = [];
  SongModel? currentSong;
  int currentIndex = 0;
  bool isPlaying = false;
  bool shuffle = false;
  bool loopOne = false;
  bool loopAll = false;
  int currentNavIndex = 0;
  String searchQuery = '';
  bool isLoading = false;
  SortType sortType = SortType.titleAsc;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  ThemeAccent themeAccent = ThemeAccent.purple;
  bool showArtistInList = true;
  bool showDurationInList = true;
  bool gaplessPlayback = false;
  double playbackSpeed = 1.0;
  bool autoPlay = false;
  bool scanWhatsApp = true;
  bool scanDownloads = true;
  bool scanRecordings = true;

  String? latestVersion;
  String? updateUrl;
  bool hasUpdate = false;

  SonoProvider() {
    _initPlayer();
    _loadSettings();
  }

  void _initPlayer() {
    _player.onPlayerStateChanged.listen((state) {
      isPlaying = state == PlayerState.playing;
      notifyListeners();
    });
    _player.onPositionChanged.listen((pos) { position = pos; notifyListeners(); });
    _player.onDurationChanged.listen((dur) { duration = dur; notifyListeners(); });
    _player.onPlayerComplete.listen((_) => _onComplete());
  }

  void _onComplete() {
    if (loopOne) { _player.seek(Duration.zero); _player.resume(); }
    else if (currentIndex < queue.length - 1) { next(); }
    else if (loopAll) { currentIndex = 0; playSong(queue[0], queue); }
  }

  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    themeAccent = ThemeAccent.values[p.getInt('themeAccent') ?? 0];
    showArtistInList = p.getBool('showArtistInList') ?? true;
    showDurationInList = p.getBool('showDurationInList') ?? true;
    gaplessPlayback = p.getBool('gaplessPlayback') ?? false;
    playbackSpeed = p.getDouble('playbackSpeed') ?? 1.0;
    autoPlay = p.getBool('autoPlay') ?? false;
    scanWhatsApp = p.getBool('scanWhatsApp') ?? true;
    scanDownloads = p.getBool('scanDownloads') ?? true;
    scanRecordings = p.getBool('scanRecordings') ?? true;
    sortType = SortType.values[p.getInt('sortType') ?? 0];
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('themeAccent', themeAccent.index);
    await p.setBool('showArtistInList', showArtistInList);
    await p.setBool('showDurationInList', showDurationInList);
    await p.setBool('gaplessPlayback', gaplessPlayback);
    await p.setDouble('playbackSpeed', playbackSpeed);
    await p.setBool('autoPlay', autoPlay);
    await p.setBool('scanWhatsApp', scanWhatsApp);
    await p.setBool('scanDownloads', scanDownloads);
    await p.setBool('scanRecordings', scanRecordings);
    await p.setInt('sortType', sortType.index);
  }

  void setThemeAccent(ThemeAccent a) { themeAccent = a; _saveSettings(); notifyListeners(); }
  void toggleShowArtist() { showArtistInList = !showArtistInList; _saveSettings(); notifyListeners(); }
  void toggleShowDuration() { showDurationInList = !showDurationInList; _saveSettings(); notifyListeners(); }
  void toggleGapless() { gaplessPlayback = !gaplessPlayback; _saveSettings(); notifyListeners(); }
  void toggleAutoPlay() { autoPlay = !autoPlay; _saveSettings(); notifyListeners(); }
  void toggleScanWhatsApp() { scanWhatsApp = !scanWhatsApp; _saveSettings(); notifyListeners(); }
  void toggleScanDownloads() { scanDownloads = !scanDownloads; _saveSettings(); notifyListeners(); }
  void toggleScanRecordings() { scanRecordings = !scanRecordings; _saveSettings(); notifyListeners(); }
  void setPlaybackSpeed(double s) { playbackSpeed = s; _player.setPlaybackRate(s); _saveSettings(); notifyListeners(); }

  Future<void> clearCache() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('song_cache');
    await p.remove('cache_date');
  }

  Future<List<SongModel>?> _loadCache() async {
    try {
      final p = await SharedPreferences.getInstance();
      final dateStr = p.getString('cache_date');
      if (dateStr == null) return null;
      if (DateTime.now().difference(DateTime.parse(dateStr)).inHours > 24) return null;
      final list = p.getStringList('song_cache');
      if (list == null || list.isEmpty) return null;
      return list.map((s) => SongModel.fromJson(jsonDecode(s))).toList();
    } catch (_) { return null; }
  }

  Future<void> _saveCache(List<SongModel> songs) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('song_cache', songs.map((s) => jsonEncode(s.toJson())).toList());
      await p.setString('cache_date', DateTime.now().toIso8601String());
    } catch (e) { debugPrint('Cache error: $e'); }
  }

  Future<void> loadSongs({bool forceRescan = false}) async {
    isLoading = true;
    notifyListeners();

    if (!forceRescan) {
      final cached = await _loadCache();
      if (cached != null && cached.isNotEmpty) {
        final valid = cached.where((s) => File(s.path).existsSync()).toList();
        if (valid.isNotEmpty) {
          allSongs = valid;
          _applySortAndFilter();
          isLoading = false;
          notifyListeners();
          checkForUpdate();
          return;
        }
      }
    }

    PermissionStatus status = await Permission.audio.request();
    if (!status.isGranted) status = await Permission.storage.request();
    if (!status.isGranted) { isLoading = false; notifyListeners(); return; }

    final songs = <SongModel>[];
    final dirs = ['/storage/emulated/0/Music'];
    if (scanDownloads) { dirs.add('/storage/emulated/0/Download'); dirs.add('/storage/emulated/0/Downloads'); }
    if (scanWhatsApp) dirs.add('/storage/emulated/0/WhatsApp/Media/WhatsApp Audio');
    if (scanRecordings) dirs.add('/storage/emulated/0/Recordings');

    for (final d in dirs) {
      final dir = Directory(d);
      if (await dir.exists()) await _scanDir(dir, songs);
    }

    final seen = <String>{};
    allSongs = songs.where((s) => seen.add(s.path)).toList();
    _applySortAndFilter();
    isLoading = false;
    notifyListeners();
    await _saveCache(allSongs);
    checkForUpdate();
  }

  Future<void> _scanDir(Directory dir, List<SongModel> songs) async {
    final exts = ['.mp3', '.flac', '.opus', '.aac', '.m4a', '.ogg', '.wav', '.wma'];
    try {
      await for (final e in dir.list(recursive: true)) {
        if (e is File) {
          final lower = e.path.toLowerCase();
          if (exts.any((x) => lower.endsWith(x))) {
            final stat = await e.stat();
            final name = e.path.split('/').last;
            final rawTitle = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
            String title = rawTitle, artist = 'Bilinmeyen Sanatçı', album = '';
            int dur = 0;
            Uint8List? artwork;
            try {
              final tag = await AudioTags.read(e.path);
              if (tag != null) {
                title = tag.title?.isNotEmpty == true ? tag.title! : rawTitle;
                artist = tag.trackArtist?.isNotEmpty == true ? tag.trackArtist! : 'Bilinmeyen Sanatçı';
                album = tag.album ?? '';
                dur = ((tag.duration ?? 0) * 1000).toInt();
                if (tag.pictures.isNotEmpty) artwork = tag.pictures.first.bytes;
              }
            } catch (_) {}
            songs.add(SongModel(id: e.path, title: title, artist: artist, album: album,
                path: e.path, duration: dur, dateAdded: stat.modified, artwork: artwork));
          }
        }
      }
    } catch (e) { debugPrint('Scan error: $e'); }
  }

  void setSortType(SortType t) { sortType = t; _applySortAndFilter(); _saveSettings(); notifyListeners(); }

  void _applySortAndFilter() {
    var list = List<SongModel>.from(allSongs);
    switch (sortType) {
      case SortType.titleAsc: list.sort((a, b) => a.title.compareTo(b.title)); break;
      case SortType.titleDesc: list.sort((a, b) => b.title.compareTo(a.title)); break;
      case SortType.artistAsc: list.sort((a, b) => a.artist.compareTo(b.artist)); break;
      case SortType.artistDesc: list.sort((a, b) => b.artist.compareTo(a.artist)); break;
      case SortType.dateAddedAsc: list.sort((a, b) => a.dateAdded.compareTo(b.dateAdded)); break;
      case SortType.dateAddedDesc: list.sort((a, b) => b.dateAdded.compareTo(a.dateAdded)); break;
    }
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      list = list.where((s) => s.title.toLowerCase().contains(q) || s.artist.toLowerCase().contains(q)).toList();
    }
    filteredSongs = list;
  }

  void search(String q) { searchQuery = q; _applySortAndFilter(); notifyListeners(); }

  Future<void> playSong(SongModel song, List<SongModel> list) async {
    queue = List.from(list);
    currentIndex = queue.indexWhere((s) => s.id == song.id);
    if (currentIndex == -1) currentIndex = 0;
    currentSong = song;
    position = Duration.zero;
    duration = Duration.zero;
    notifyListeners();
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(song.path));
      await _player.setPlaybackRate(playbackSpeed);
    } catch (e) { debugPrint('Play error: $e'); }
  }

  Future<void> togglePlayPause() async {
    if (isPlaying) { await _player.pause(); } else { await _player.resume(); }
  }

  Future<void> next() async {
    if (queue.isEmpty) return;
    if (shuffle) {
      int n;
      do { n = DateTime.now().millisecond % queue.length; } while (n == currentIndex && queue.length > 1);
      currentIndex = n;
    } else {
      currentIndex = (currentIndex + 1) % queue.length;
    }
    await playSong(queue[currentIndex], queue);
  }

  Future<void> previous() async {
    if (queue.isEmpty) return;
    if (position.inSeconds > 3) { await _player.seek(Duration.zero); }
    else { currentIndex = (currentIndex - 1 + queue.length) % queue.length; await playSong(queue[currentIndex], queue); }
  }

  Future<void> seek(Duration pos) async => await _player.seek(pos);
  void toggleShuffle() { shuffle = !shuffle; notifyListeners(); }
  void toggleLoop() {
    if (!loopAll && !loopOne) { loopAll = true; }
    else if (loopAll) { loopAll = false; loopOne = true; }
    else { loopOne = false; }
    notifyListeners();
  }
  void setNavIndex(int i) { currentNavIndex = i; notifyListeners(); }

  Future<void> checkForUpdate() async {
    try {
      final res = await http.get(Uri.parse('https://api.github.com/repos/$kGithubRepo/releases/latest'),
          headers: {'Accept': 'application/vnd.github.v3+json'}).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final tag = data['tag_name'] as String? ?? '';
        final parts = tag.replaceAll('v', '').split('.');
        final tagRun = parts.length >= 3 ? int.tryParse(parts[2]) ?? 0 : 0;
        final curRun = int.tryParse(kAppVersion.split('.').last) ?? 0;
        final assets = data['assets'] as List<dynamic>? ?? [];
        String? apkUrl;
        for (final a in assets) {
          if ((a['name'] as String? ?? '').endsWith('.apk')) { apkUrl = a['browser_download_url']; break; }
        }
        if (tagRun > curRun && apkUrl != null) {
          latestVersion = tag.replaceAll('v', '');
          updateUrl = apkUrl;
          hasUpdate = true;
          notifyListeners();
        }
      }
    } catch (e) { debugPrint('Update error: $e'); }
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }
}

// ─── APP ──────────────────────────────────────────────────────────────────────

class SonoApp extends StatelessWidget {
  const SonoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();
    return MaterialApp(
      title: 'SONO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        colorScheme: ColorScheme.dark(primary: provider.themeAccent.color, secondary: provider.themeAccent.color, surface: const Color(0xFF12121A)),
        textTheme: GoogleFonts.spaceGroteskTextTheme(ThemeData.dark().textTheme),
      ),
      home: const SonoHome(),
    );
  }
}

// ─── HOME ─────────────────────────────────────────────────────────────────────

class SonoHome extends StatefulWidget {
  const SonoHome({super.key});

  @override
  State<SonoHome> createState() => _SonoHomeState();
}

class _SonoHomeState extends State<SonoHome> {
  bool _updateShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<SonoProvider>().loadSongs());
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();
    if (provider.hasUpdate && !_updateShown) {
      _updateShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showUpdateDialog(context, provider));
    }
    final pages = [const LibraryPage(), const SearchPage(), const QueuePage(), const SettingsPage()];
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(children: [
        pages[provider.currentNavIndex],
        if (provider.currentSong != null)
          Positioned(left: 0, right: 0, bottom: 80, child: const MiniPlayer()),
      ]),
      bottomNavigationBar: const _BottomNav(),
    );
  }

  void _showUpdateDialog(BuildContext ctx, SonoProvider p) {
    showDialog(context: ctx, barrierDismissible: false, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A26),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(children: [
        Icon(Icons.system_update_rounded, color: p.themeAccent.color),
        const SizedBox(width: 10),
        Text('Güncelleme Mevcut', style: GoogleFonts.spaceGrotesk(color: Colors.white, fontWeight: FontWeight.w700)),
      ]),
      content: Text('SONO v${p.latestVersion} yayınlandı.\nGüncellemek ister misin?',
          style: TextStyle(color: Colors.white.withOpacity(0.7))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Sonra', style: TextStyle(color: Colors.white.withOpacity(0.4)))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: p.themeAccent.color, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          onPressed: () async { Navigator.pop(ctx); if (p.updateUrl != null) await _downloadApk(ctx, p.updateUrl!, p.themeAccent.color); },
          child: const Text('Güncelle', style: TextStyle(color: Colors.white)),
        ),
      ],
    ));
  }

  Future<void> _downloadApk(BuildContext ctx, String url, Color accent) async {
    final sm = ScaffoldMessenger.of(ctx);
    sm.showSnackBar(SnackBar(content: const Text('APK indiriliyor...'), backgroundColor: accent, duration: const Duration(seconds: 60)));
    try {
      final res = await http.get(Uri.parse(url));
      await File('/storage/emulated/0/Download/sono-update.apk').writeAsBytes(res.bodyBytes);
      sm.hideCurrentSnackBar();
      sm.showSnackBar(SnackBar(content: const Text('İndirildi! Download klasöründen yükleyin.'), backgroundColor: Colors.green.shade700));
    } catch (_) {
      sm.hideCurrentSnackBar();
      sm.showSnackBar(SnackBar(content: const Text('İndirme başarısız'), backgroundColor: Colors.red.shade700));
    }
  }
}

// ─── BOTTOM NAV ───────────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  const _BottomNav();

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF12121A), border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05)))),
      child: NavigationBar(
        backgroundColor: Colors.transparent,
        selectedIndex: p.currentNavIndex,
        onDestinationSelected: p.setNavIndex,
        indicatorColor: p.themeAccent.color.withOpacity(0.2),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Kütüphane'),
          NavigationDestination(icon: Icon(Icons.search_outlined), selectedIcon: Icon(Icons.search), label: 'Ara'),
          NavigationDestination(icon: Icon(Icons.queue_music_outlined), selectedIcon: Icon(Icons.queue_music), label: 'Kuyruk'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Ayarlar'),
        ],
      ),
    );
  }
}

// ─── LIBRARY PAGE ─────────────────────────────────────────────────────────────

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('SONO', style: GoogleFonts.spaceGrotesk(fontSize: 32, fontWeight: FontWeight.w800, color: p.themeAccent.color, letterSpacing: 4)),
            Row(children: [
              IconButton(icon: const Icon(Icons.refresh_rounded, color: Colors.white70), onPressed: () => p.loadSongs(forceRescan: true)),
              _SortButton(),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Text('${p.allSongs.length} şarkı • ${p.sortType.label}', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13)),
        ),
        Expanded(
          child: p.isLoading
              ? Center(child: CircularProgressIndicator(color: p.themeAccent.color))
              : p.filteredSongs.isEmpty
                  ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.music_off_rounded, size: 64, color: Colors.white.withOpacity(0.15)),
                      const SizedBox(height: 16),
                      Text('Müzik bulunamadı', style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 16)),
                    ]))
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 160),
                      itemCount: p.filteredSongs.length,
                      itemBuilder: (ctx, i) {
                        final song = p.filteredSongs[i];
                        return SongTile(song: song, songList: p.filteredSongs, isPlaying: p.currentSong?.id == song.id && p.isPlaying);
                      }),
        ),
      ]),
    );
  }
}

class _SortButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    return IconButton(
      icon: const Icon(Icons.sort_rounded, color: Colors.white70),
      onPressed: () => showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1A1A26),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sırala', style: GoogleFonts.spaceGrotesk(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
            const SizedBox(height: 16),
            ...SortType.values.map((t) => ListTile(
              leading: Icon(p.sortType == t ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: p.sortType == t ? p.themeAccent.color : Colors.white38),
              title: Text(t.label, style: const TextStyle(color: Colors.white)),
              onTap: () { p.setSortType(t); Navigator.pop(context); },
            )),
          ]),
        ),
      ),
    );
  }
}

// ─── SEARCH PAGE ──────────────────────────────────────────────────────────────

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctrl = TextEditingController();

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          child: TextField(
            controller: _ctrl,
            onChanged: (v) { p.search(v); setState(() {}); },
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Şarkı veya sanatçı ara...',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
              prefixIcon: Icon(Icons.search, color: p.themeAccent.color),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.clear, color: Colors.white54), onPressed: () { _ctrl.clear(); p.search(''); setState(() {}); })
                  : null,
              filled: true, fillColor: const Color(0xFF1A1A26),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: p.themeAccent.color)),
            ),
          ),
        ),
        if (p.searchQuery.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 8),
            child: Align(alignment: Alignment.centerLeft,
                child: Text('${p.filteredSongs.length} sonuç', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13))),
          ),
        Expanded(
          child: p.filteredSongs.isEmpty && p.searchQuery.isNotEmpty
              ? Center(child: Text('Sonuç bulunamadı', style: TextStyle(color: Colors.white.withOpacity(0.3))))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 160),
                  itemCount: p.filteredSongs.length,
                  itemBuilder: (ctx, i) {
                    final song = p.filteredSongs[i];
                    return SongTile(song: song, songList: p.filteredSongs,
                        isPlaying: p.currentSong?.id == song.id && p.isPlaying, highlightQuery: p.searchQuery);
                  }),
        ),
      ]),
    );
  }
}

// ─── QUEUE PAGE ───────────────────────────────────────────────────────────────

class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
          child: Text('Çalma Sırası', style: GoogleFonts.spaceGrotesk(fontSize: 24, fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: p.queue.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.queue_music_rounded, size: 64, color: Colors.white.withOpacity(0.15)),
                  const SizedBox(height: 16),
                  Text('Kuyruk boş', style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 16)),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 160),
                  itemCount: p.queue.length,
                  itemBuilder: (ctx, i) {
                    final song = p.queue[i];
                    return SongTile(song: song, songList: p.queue, isPlaying: i == p.currentIndex && p.isPlaying, isCurrent: i == p.currentIndex);
                  }),
        ),
      ]),
    );
  }
}

// ─── SETTINGS PAGE ────────────────────────────────────────────────────────────

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    final accent = p.themeAccent.color;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 160),
        children: [
          Text('Ayarlar', style: GoogleFonts.spaceGrotesk(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 24),

          _SHeader('Görünüm'),
          _SCard(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Renk Teması', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: ThemeAccent.values.map((a) {
                    final sel = p.themeAccent == a;
                    return GestureDetector(
                      onTap: () => p.setThemeAccent(a),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: a.color, shape: BoxShape.circle,
                          border: sel ? Border.all(color: Colors.white, width: 3) : null,
                          boxShadow: sel ? [BoxShadow(color: a.color.withOpacity(0.5), blurRadius: 8)] : null,
                        ),
                        child: sel ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
              ]),
            ),
            _STile(icon: Icons.person_rounded, title: 'Listede Sanatçı Göster',
                trailing: Switch(value: p.showArtistInList, onChanged: (_) => p.toggleShowArtist(), activeColor: accent)),
            _STile(icon: Icons.timer_outlined, title: 'Listede Süre Göster',
                trailing: Switch(value: p.showDurationInList, onChanged: (_) => p.toggleShowDuration(), activeColor: accent)),
          ]),

          _SHeader('Çalma'),
          _SCard(children: [
            _STile(icon: Icons.speed_rounded, title: 'Çalma Hızı', subtitle: '${p.playbackSpeed.toStringAsFixed(1)}x',
                onTap: () => _showSpeedPicker(context, p)),
            _STile(icon: Icons.play_circle_outline_rounded, title: 'Otomatik Oynat',
                trailing: Switch(value: p.autoPlay, onChanged: (_) => p.toggleAutoPlay(), activeColor: accent)),
            _STile(icon: Icons.graphic_eq_rounded, title: 'Kesintisiz Çalma', subtitle: 'Şarkılar arası boşluk yok',
                trailing: Switch(value: p.gaplessPlayback, onChanged: (_) => p.toggleGapless(), activeColor: accent)),
          ]),

          _SHeader('Kütüphane Tarama'),
          _SCard(children: [
            _STile(icon: Icons.download_rounded, title: 'İndirilenler',
                trailing: Switch(value: p.scanDownloads, onChanged: (_) => p.toggleScanDownloads(), activeColor: accent)),
            _STile(icon: Icons.message_rounded, title: 'WhatsApp Sesleri',
                trailing: Switch(value: p.scanWhatsApp, onChanged: (_) => p.toggleScanWhatsApp(), activeColor: accent)),
            _STile(icon: Icons.mic_rounded, title: 'Kayıtlar',
                trailing: Switch(value: p.scanRecordings, onChanged: (_) => p.toggleScanRecordings(), activeColor: accent)),
            _STile(icon: Icons.refresh_rounded, title: 'Yeniden Tara', subtitle: 'Cache temizle ve tara',
                onTap: () async {
                  await p.clearCache();
                  await p.loadSongs(forceRescan: true);
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: const Text('Kütüphane yenilendi'), backgroundColor: accent));
                }),
          ]),

          _SHeader('Ses Kalitesi'),
          _SCard(children: [
            _STile(icon: Icons.bluetooth_audio_rounded, title: 'LDAC', subtitle: 'Sistem ayarlarından etkinleştirin',
                onTap: () => showDialog(context: context, builder: (_) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1A26),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: const Text('LDAC Hakkında', style: TextStyle(color: Colors.white)),
                  content: const Text('LDAC, Sony\'nin yüksek kaliteli Bluetooth ses kodek teknolojisidir.\n\nEtkinleştirmek için:\n1. Telefon Ayarları → Bağlantı\n2. Bluetooth → Kulaklığınız\n3. Ses Kalitesi → LDAC\n\nSONO tüm ses kalitelerini destekler.', style: TextStyle(color: Colors.white70, height: 1.5)),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('Anladım', style: TextStyle(color: accent)))],
                ))),
            _STile(icon: Icons.high_quality_rounded, title: 'Desteklenen Formatlar', subtitle: 'MP3, FLAC, Opus, AAC, M4A, OGG, WAV, WMA'),
          ]),

          _SHeader('Hakkında'),
          _SCard(children: [
            _STile(icon: Icons.info_outline_rounded, title: 'Sürüm', subtitle: 'SONO v$kAppVersion'),
            _STile(icon: Icons.code_rounded, title: 'Geliştirici', subtitle: 'SKYDIVEX'),
            _STile(icon: Icons.update_rounded, title: 'Güncelleme Kontrol Et',
                subtitle: p.hasUpdate ? 'v${p.latestVersion} mevcut!' : 'Güncel',
                trailing: p.hasUpdate
                    ? Icon(Icons.new_releases_rounded, color: accent)
                    : Icon(Icons.check_circle_outline_rounded, color: Colors.green.shade400),
                onTap: () => p.checkForUpdate()),
          ]),
        ],
      ),
    );
  }

  void _showSpeedPicker(BuildContext context, SonoProvider p) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A26),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Çalma Hızı', style: GoogleFonts.spaceGrotesk(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
          const SizedBox(height: 16),
          ...speeds.map((s) => ListTile(
            leading: Icon(p.playbackSpeed == s ? Icons.radio_button_checked : Icons.radio_button_off,
                color: p.playbackSpeed == s ? p.themeAccent.color : Colors.white38),
            title: Text('${s.toStringAsFixed(2)}x', style: const TextStyle(color: Colors.white)),
            onTap: () { p.setPlaybackSpeed(s); Navigator.pop(context); },
          )),
        ]),
      ),
    );
  }
}

class _SHeader extends StatelessWidget {
  final String title;
  const _SHeader(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 0, 8),
    child: Text(title, style: TextStyle(color: context.watch<SonoProvider>().themeAccent.color, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
  );
}

class _SCard extends StatelessWidget {
  final List<Widget> children;
  const _SCard({required this.children});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: const Color(0xFF12121A), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white.withOpacity(0.05))),
    child: Column(children: children),
  );
}

class _STile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _STile({required this.icon, required this.title, this.subtitle, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<SonoProvider>().themeAccent.color;
    return ListTile(
      leading: Container(width: 36, height: 36,
          decoration: BoxDecoration(color: accent.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: accent, size: 20)),
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: subtitle != null ? Text(subtitle!, style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12)) : null,
      trailing: trailing,
      onTap: onTap,
    );
  }
}

// ─── SONG TILE ────────────────────────────────────────────────────────────────

class SongTile extends StatelessWidget {
  final SongModel song;
  final List<SongModel> songList;
  final bool isPlaying;
  final bool isCurrent;
  final String highlightQuery;

  const SongTile({super.key, required this.song, required this.songList, this.isPlaying = false, this.isCurrent = false, this.highlightQuery = ''});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    final accent = p.themeAccent.color;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: song.artwork != null
            ? Image.memory(song.artwork!, width: 52, height: 52, fit: BoxFit.cover)
            : Container(width: 52, height: 52,
                decoration: BoxDecoration(color: const Color(0xFF1A1A26), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.music_note, color: accent.withOpacity(0.6), size: 24)),
      ),
      title: _txt(song.title, highlightQuery,
          const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
          isCurrent ? TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w700) : null),
      subtitle: p.showArtistInList
          ? _txt(song.artist, highlightQuery, TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12), null)
          : null,
      trailing: isPlaying ? _PlayingIndicator(color: accent)
          : p.showDurationInList ? Text(_fmt(song.duration), style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12)) : null,
      onTap: () {
        p.playSong(song, songList);
        Navigator.push(context, MaterialPageRoute(builder: (_) => const NowPlayingPage()));
      },
    );
  }

  Widget _txt(String text, String query, TextStyle base, TextStyle? over) {
    if (query.isEmpty || over != null) return Text(text, style: over ?? base, maxLines: 1, overflow: TextOverflow.ellipsis);
    final i = text.toLowerCase().indexOf(query.toLowerCase());
    if (i == -1) return Text(text, style: base, maxLines: 1, overflow: TextOverflow.ellipsis);
    return RichText(maxLines: 1, overflow: TextOverflow.ellipsis, text: TextSpan(children: [
      TextSpan(text: text.substring(0, i), style: base),
      TextSpan(text: text.substring(i, i + query.length), style: base.copyWith(color: const Color(0xFF6C63FF), fontWeight: FontWeight.w800)),
      TextSpan(text: text.substring(i + query.length), style: base),
    ]));
  }

  String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    return '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }
}

// ─── PLAYING INDICATOR ────────────────────────────────────────────────────────

class _PlayingIndicator extends StatefulWidget {
  final Color color;
  const _PlayingIndicator({required this.color});

  @override
  State<_PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<_PlayingIndicator> with TickerProviderStateMixin {
  late List<AnimationController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(3, (i) => AnimationController(vsync: this, duration: Duration(milliseconds: 400 + i * 100))..repeat(reverse: true));
  }

  @override
  void dispose() { for (final c in _controllers) { c.dispose(); } super.dispose(); }

  @override
  Widget build(BuildContext context) => SizedBox(width: 20, height: 20,
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) => AnimatedBuilder(animation: _controllers[i],
        builder: (_, __) => Container(width: 4, height: 6 + _controllers[i].value * 14,
          decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(2)))))));
}

// ─── MINI PLAYER ─────────────────────────────────────────────────────────────

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    final song = p.currentSong;
    if (song == null) return const SizedBox();
    final accent = p.themeAccent.color;

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NowPlayingPage())),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E), borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          boxShadow: [BoxShadow(color: accent.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 4))],
        ),
        child: Row(children: [
          ClipRRect(borderRadius: BorderRadius.circular(10),
            child: song.artwork != null
                ? Image.memory(song.artwork!, width: 44, height: 44, fit: BoxFit.cover)
                : Container(width: 44, height: 44, color: const Color(0xFF12121A),
                    child: Icon(Icons.music_note, color: accent, size: 20))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(song.title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(song.artist, style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          IconButton(icon: Icon(p.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28), onPressed: p.togglePlayPause),
          IconButton(icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 28), onPressed: p.next),
        ]),
      ),
    );
  }
}

// ─── NOW PLAYING PAGE ─────────────────────────────────────────────────────────

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  String _fmt(Duration d) => '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final p = context.watch<SonoProvider>();
    final song = p.currentSong;
    if (song == null) return const SizedBox();
    final accent = p.themeAccent.color;
    final maxDur = p.duration.inMilliseconds.toDouble();
    final curPos = p.position.inMilliseconds.clamp(0, maxDur > 0 ? maxDur.toInt() : 1).toDouble();

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white), onPressed: () => Navigator.pop(context)),
        title: Text('ŞİMDİ ÇALIYOR', style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 3, color: Colors.white.withOpacity(0.4))),
        centerTitle: true,
        actions: [IconButton(icon: Icon(Icons.more_vert_rounded, color: Colors.white.withOpacity(0.6)), onPressed: () => _showOptions(context, p, song))],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(children: [
          const SizedBox(height: 16),
          Container(
            width: double.infinity, height: 280,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: accent.withOpacity(0.3), blurRadius: 40, offset: const Offset(0, 16))]),
            child: ClipRRect(borderRadius: BorderRadius.circular(24),
              child: song.artwork != null
                  ? Image.memory(song.artwork!, fit: BoxFit.cover)
                  : Container(decoration: BoxDecoration(color: const Color(0xFF1A1A26), borderRadius: BorderRadius.circular(24)),
                      child: Icon(Icons.music_note_rounded, size: 80, color: accent.withOpacity(0.4)))),
          ),
          const SizedBox(height: 20),
          Align(alignment: Alignment.centerLeft, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(song.title, style: GoogleFonts.spaceGrotesk(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(song.artist, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (song.album.isNotEmpty) Text(song.album, style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          const SizedBox(height: 16),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accent, inactiveTrackColor: Colors.white.withOpacity(0.1),
              thumbColor: Colors.white, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: SliderComponentShape.noOverlay, trackHeight: 3,
            ),
            child: Slider(value: curPos, max: maxDur > 0 ? maxDur : 1, onChanged: (v) => p.seek(Duration(milliseconds: v.toInt()))),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_fmt(p.position), style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12)),
            Text(_fmt(p.duration), style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton(icon: Icon(Icons.shuffle_rounded, color: p.shuffle ? accent : Colors.white.withOpacity(0.4), size: 24), onPressed: p.toggleShuffle),
            IconButton(icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 36), onPressed: p.previous),
            GestureDetector(
              onTap: p.togglePlayPause,
              child: Container(width: 68, height: 68,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: accent.withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 6))]),
                child: Icon(p.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 36)),
            ),
            IconButton(icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 36), onPressed: p.next),
            IconButton(
              icon: Icon(p.loopOne ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  color: (p.loopOne || p.loopAll) ? accent : Colors.white.withOpacity(0.4), size: 24),
              onPressed: p.toggleLoop,
            ),
          ]),
        ]),
      ),
    );
  }

  void _showOptions(BuildContext context, SonoProvider p, SongModel song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A26),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Icon(Icons.info_outline_rounded, color: p.themeAccent.color),
            title: const Text('Şarkı Bilgisi', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              showDialog(context: context, builder: (_) => AlertDialog(
                backgroundColor: const Color(0xFF1A1A26),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: Text(song.title, style: const TextStyle(color: Colors.white)),
                content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _IRow('Sanatçı', song.artist),
                  _IRow('Albüm', song.album.isEmpty ? '-' : song.album),
                  _IRow('Dosya', song.path.split('/').last),
                  _IRow('Yol', song.path),
                ]),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('Kapat', style: TextStyle(color: p.themeAccent.color)))],
              ));
            },
          ),
          ListTile(
            leading: Icon(Icons.speed_rounded, color: p.themeAccent.color),
            title: Text('Çalma Hızı: ${p.playbackSpeed.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
              showModalBottomSheet(
                context: context,
                backgroundColor: const Color(0xFF1A1A26),
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                builder: (_) => Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('Çalma Hızı', style: GoogleFonts.spaceGrotesk(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(height: 16),
                  ...speeds.map((s) => ListTile(
                    leading: Icon(p.playbackSpeed == s ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: p.playbackSpeed == s ? p.themeAccent.color : Colors.white38),
                    title: Text('${s.toStringAsFixed(2)}x', style: const TextStyle(color: Colors.white)),
                    onTap: () { p.setPlaybackSpeed(s); Navigator.pop(context); },
                  )),
                ])),
              );
            },
          ),
        ]),
      ),
    );
  }
}

class _IRow extends StatelessWidget {
  final String label, value;
  const _IRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 60, child: Text('$label:', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12))),
      Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 12))),
    ]),
  );
}
