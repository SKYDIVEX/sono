import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.skydivex.sono.channel.audio',
      androidNotificationChannelName: 'SONO Audio',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: true,
    );
  } catch (e) {
    debugPrint('JustAudioBackground init error: $e');
  }

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  runApp(
    ChangeNotifierProvider(
      create: (_) => SonoProvider(),
      child: const SonoApp(),
    ),
  );
}

// ─── CONSTANTS ────────────────────────────────────────────────────────────────

const String kAppVersion = '1.0.0';
const String kGithubRepo = 'skydivex/sono';

// ─── ENUMS ────────────────────────────────────────────────────────────────────

enum SortType {
  titleAsc,
  titleDesc,
  artistAsc,
  artistDesc,
  dateAddedAsc,
  dateAddedDesc,
}

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

// ─── MODELS ───────────────────────────────────────────────────────────────────

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
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.path,
    required this.duration,
    required this.dateAdded,
    this.artwork,
  });
}

class PositionData {
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
  PositionData(this.position, this.bufferedPosition, this.duration);
}

// ─── PROVIDER ─────────────────────────────────────────────────────────────────

class SonoProvider extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();

  List<SongModel> allSongs = [];
  List<SongModel> filteredSongs = [];
  List<SongModel> queue = [];
  SongModel? currentSong;
  int currentIndex = 0;
  bool isPlaying = false;
  bool shuffle = false;
  LoopMode loopMode = LoopMode.off;
  int currentNavIndex = 0;
  String searchQuery = '';
  bool isLoading = false;
  SortType sortType = SortType.titleAsc;

  // Güncelleme
  String? latestVersion;
  String? updateUrl;
  bool hasUpdate = false;

  SonoProvider() {
    _initPlayer();
  }

  void _initPlayer() {
    player.playerStateStream.listen((state) {
      isPlaying = state.playing;
      notifyListeners();
    });
    player.currentIndexStream.listen((index) {
      if (index != null && queue.isNotEmpty) {
        currentIndex = index;
        currentSong = queue[index];
        notifyListeners();
      }
    });
  }

  Future<void> loadSongs() async {
    isLoading = true;
    notifyListeners();

    PermissionStatus status = await Permission.audio.request();
    if (!status.isGranted) {
      status = await Permission.storage.request();
    }

    if (!status.isGranted) {
      isLoading = false;
      notifyListeners();
      return;
    }

    final List<SongModel> songs = [];

    // Sadece müzik klasörlerini tara, tüm depolamayı değil
    final dirs = [
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Downloads',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Audio',
      '/storage/emulated/0/Recordings',
    ];

    for (final dirPath in dirs) {
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await _scanDir(dir, songs);
      }
    }

    // Tekrar eden path'leri temizle
    final seen = <String>{};
    final unique = songs.where((s) => seen.add(s.path)).toList();

    allSongs = unique;
    _applySortAndFilter();
    isLoading = false;
    notifyListeners();

    checkForUpdate();
  }

  Future<void> _scanDir(Directory dir, List<SongModel> songs) async {
    final extensions = ['.mp3', '.flac', '.opus', '.aac', '.m4a', '.ogg', '.wav', '.wma'];
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final lower = entity.path.toLowerCase();
          if (extensions.any((e) => lower.endsWith(e))) {
            final stat = await entity.stat();
            final name = entity.path.split('/').last;
            final title = name.contains('.')
                ? name.substring(0, name.lastIndexOf('.'))
                : name;
            songs.add(SongModel(
              id: entity.path,
              title: title,
              artist: 'Bilinmeyen Sanatçı',
              album: '',
              path: entity.path,
              duration: 0,
              dateAdded: stat.modified,
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('Scan error: $e');
    }
  }

  void setSortType(SortType type) {
    sortType = type;
    _applySortAndFilter();
    notifyListeners();
  }

  void _applySortAndFilter() {
    List<SongModel> list = List.from(allSongs);

    // Sıralama
    switch (sortType) {
      case SortType.titleAsc:
        list.sort((a, b) => a.title.compareTo(b.title));
        break;
      case SortType.titleDesc:
        list.sort((a, b) => b.title.compareTo(a.title));
        break;
      case SortType.artistAsc:
        list.sort((a, b) => a.artist.compareTo(b.artist));
        break;
      case SortType.artistDesc:
        list.sort((a, b) => b.artist.compareTo(a.artist));
        break;
      case SortType.dateAddedAsc:
        list.sort((a, b) => a.dateAdded.compareTo(b.dateAdded));
        break;
      case SortType.dateAddedDesc:
        list.sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
        break;
    }

    // Arama filtresi
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      list = list.where((s) {
        return s.title.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q);
      }).toList();
    }

    filteredSongs = list;
  }

  void search(String query) {
    searchQuery = query;
    _applySortAndFilter();
    notifyListeners();
  }

  Future<void> playSong(SongModel song, List<SongModel> songList) async {
    queue = List.from(songList);
    currentIndex = queue.indexWhere((s) => s.id == song.id);
    if (currentIndex == -1) currentIndex = 0;
    currentSong = song;

    final playlist = ConcatenatingAudioSource(
      children: queue.map((s) {
        final uri = s.path.startsWith('/')
            ? Uri.parse('file://${s.path}')
            : Uri.parse(s.path);
        return AudioSource.uri(
          uri,
          tag: MediaItem(
            id: s.id,
            title: s.title,
            artist: s.artist,
            album: s.album,
          ),
        );
      }).toList(),
    );

    await player.setAudioSource(playlist, initialIndex: currentIndex);
    await player.play();
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    if (isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> next() async => await player.seekToNext();
  Future<void> previous() async => await player.seekToPrevious();

  Future<void> toggleShuffle() async {
    shuffle = !shuffle;
    await player.setShuffleModeEnabled(shuffle);
    notifyListeners();
  }

  Future<void> toggleLoop() async {
    if (loopMode == LoopMode.off) {
      loopMode = LoopMode.all;
    } else if (loopMode == LoopMode.all) {
      loopMode = LoopMode.one;
    } else {
      loopMode = LoopMode.off;
    }
    await player.setLoopMode(loopMode);
    notifyListeners();
  }

  void setNavIndex(int index) {
    currentNavIndex = index;
    notifyListeners();
  }

  // ─── GÜNCELLEME SİSTEMİ ───────────────────────────────────────────────────

  Future<void> checkForUpdate() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$kGithubRepo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tag = data['tag_name'] as String? ?? '';
        // Tag: v1.0.33 → runNumber: 33
        final tagParts = tag.replaceAll('v', '').split('.');
        final tagRunNumber = tagParts.length >= 3 ? int.tryParse(tagParts[2]) ?? 0 : 0;
        final currentRunNumber = int.tryParse(kAppVersion.split('.').last) ?? 0;

        final assets = data['assets'] as List<dynamic>? ?? [];
        String? apkUrl;
        for (final asset in assets) {
          final name = asset['name'] as String? ?? '';
          if (name.endsWith('.apk')) {
            apkUrl = asset['browser_download_url'] as String?;
            break;
          }
        }

        if (tagRunNumber > currentRunNumber && apkUrl != null) {
          latestVersion = tag.replaceAll('v', '');
          updateUrl = apkUrl;
          hasUpdate = true;
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Update check error: $e');
    }
  }

  Stream<PositionData> get positionDataStream =>
      Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
        player.positionStream,
        player.bufferedPositionStream,
        player.durationStream,
        (position, buffered, duration) =>
            PositionData(position, buffered, duration ?? Duration.zero),
      );

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }
}

// ─── APP ──────────────────────────────────────────────────────────────────────

class SonoApp extends StatelessWidget {
  const SonoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SONO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFFFF6584),
          surface: Color(0xFF12121A),
        ),
        textTheme: GoogleFonts.spaceGroteskTextTheme(
          ThemeData.dark().textTheme,
        ),
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SonoProvider>().loadSongs();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();

    if (provider.hasUpdate && !_updateShown) {
      _updateShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showUpdateDialog(context, provider);
      });
    }

    final pages = [
      const LibraryPage(),
      const SearchPage(),
      const QueuePage(),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        children: [
          pages[provider.currentNavIndex],
          if (provider.currentSong != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 80,
              child: const MiniPlayer(),
            ),
        ],
      ),
      bottomNavigationBar: const _BottomNav(),
    );
  }

  void _showUpdateDialog(BuildContext context, SonoProvider provider) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A26),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded, color: Color(0xFF6C63FF)),
            const SizedBox(width: 10),
            Text(
              'Güncelleme Mevcut',
              style: GoogleFonts.spaceGrotesk(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        content: Text(
          'SONO v${provider.latestVersion} yayınlandı.\nŞimdi güncellemek ister misin?',
          style: TextStyle(color: Colors.white.withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Sonra', style: TextStyle(color: Colors.white.withOpacity(0.4))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C63FF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(context);
              if (provider.updateUrl != null) {
                await _downloadAndInstall(context, provider.updateUrl!);
              }
            },
            child: const Text('Güncelle', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(BuildContext context, String url) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('APK indiriliyor...'),
        backgroundColor: Color(0xFF6C63FF),
        duration: Duration(seconds: 60),
      ),
    );

    try {
      final response = await http.get(Uri.parse(url));
      final file = File('/storage/emulated/0/Download/sono-update.apk');
      await file.writeAsBytes(response.bodyBytes);
      scaffoldMessenger.hideCurrentSnackBar();
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: const Text('İndirildi! Download klasöründen yükleyin.'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      scaffoldMessenger.hideCurrentSnackBar();
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: const Text('İndirme başarısız'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }
}

// ─── BOTTOM NAV ───────────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  const _BottomNav();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF12121A),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: NavigationBar(
        backgroundColor: Colors.transparent,
        selectedIndex: provider.currentNavIndex,
        onDestinationSelected: provider.setNavIndex,
        indicatorColor: const Color(0xFF6C63FF).withOpacity(0.2),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music, color: Color(0xFF6C63FF)),
            label: 'Kütüphane',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search, color: Color(0xFF6C63FF)),
            label: 'Ara',
          ),
          NavigationDestination(
            icon: Icon(Icons.queue_music_outlined),
            selectedIcon: Icon(Icons.queue_music, color: Color(0xFF6C63FF)),
            label: 'Kuyruk',
          ),
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
    final provider = context.watch<SonoProvider>();

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'SONO',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF6C63FF),
                    letterSpacing: 4,
                  ),
                ),
                // Sıralama butonu
                _SortButton(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              '${provider.allSongs.length} şarkı • ${provider.sortType.label}',
              style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13),
            ),
          ),
          Expanded(
            child: provider.isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF)))
                : provider.filteredSongs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.music_off_rounded, size: 64, color: Colors.white.withOpacity(0.15)),
                            const SizedBox(height: 16),
                            Text('Müzik bulunamadı',
                                style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 16)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 160),
                        itemCount: provider.filteredSongs.length,
                        itemBuilder: (context, index) {
                          final song = provider.filteredSongs[index];
                          return SongTile(
                            song: song,
                            songList: provider.filteredSongs,
                            isPlaying: provider.currentSong?.id == song.id && provider.isPlaying,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ─── SORT BUTTON ──────────────────────────────────────────────────────────────

class _SortButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();

    return IconButton(
      icon: const Icon(Icons.sort_rounded, color: Colors.white70),
      onPressed: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1A1A26),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          builder: (_) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sırala',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                ...SortType.values.map((type) => ListTile(
                  leading: Icon(
                    provider.sortType == type ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: provider.sortType == type ? const Color(0xFF6C63FF) : Colors.white38,
                  ),
                  title: Text(type.label, style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    provider.setSortType(type);
                    Navigator.pop(context);
                  },
                )),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
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
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
            child: TextField(
              controller: _controller,
              onChanged: (val) {
                provider.search(val);
                setState(() {});
              },
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Şarkı veya sanatçı ara...',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF6C63FF)),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white54),
                        onPressed: () {
                          _controller.clear();
                          provider.search('');
                          setState(() {});
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF1A1A26),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Color(0xFF6C63FF)),
                ),
              ),
            ),
          ),
          if (provider.searchQuery.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${provider.filteredSongs.length} sonuç',
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13),
                ),
              ),
            ),
          Expanded(
            child: provider.filteredSongs.isEmpty && provider.searchQuery.isNotEmpty
                ? Center(
                    child: Text('Sonuç bulunamadı',
                        style: TextStyle(color: Colors.white.withOpacity(0.3))))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 160),
                    itemCount: provider.filteredSongs.length,
                    itemBuilder: (context, index) {
                      final song = provider.filteredSongs[index];
                      return SongTile(
                        song: song,
                        songList: provider.filteredSongs,
                        isPlaying: provider.currentSong?.id == song.id && provider.isPlaying,
                        highlightQuery: provider.searchQuery,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── QUEUE PAGE ───────────────────────────────────────────────────────────────

class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Text(
              'Çalma Sırası',
              style: GoogleFonts.spaceGrotesk(fontSize: 24, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: provider.queue.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.queue_music_rounded, size: 64, color: Colors.white.withOpacity(0.15)),
                        const SizedBox(height: 16),
                        Text('Kuyruk boş',
                            style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 16)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 160),
                    itemCount: provider.queue.length,
                    itemBuilder: (context, index) {
                      final song = provider.queue[index];
                      final isCurrent = index == provider.currentIndex;
                      return SongTile(
                        song: song,
                        songList: provider.queue,
                        isPlaying: isCurrent && provider.isPlaying,
                        isCurrent: isCurrent,
                      );
                    },
                  ),
          ),
        ],
      ),
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

  const SongTile({
    super.key,
    required this.song,
    required this.songList,
    this.isPlaying = false,
    this.isCurrent = false,
    this.highlightQuery = '',
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: song.artwork != null
            ? Image.memory(song.artwork!, width: 52, height: 52, fit: BoxFit.cover)
            : Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.music_note,
                    color: const Color(0xFF6C63FF).withOpacity(0.6), size: 24),
              ),
      ),
      title: _buildHighlightedText(
        song.title,
        highlightQuery,
        const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
        isCurrent
            ? const TextStyle(color: Color(0xFF6C63FF), fontSize: 14, fontWeight: FontWeight.w700)
            : null,
      ),
      subtitle: _buildHighlightedText(
        song.artist,
        highlightQuery,
        TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12),
        null,
      ),
      trailing: isPlaying
          ? const _PlayingIndicator()
          : Text(_formatDuration(song.duration),
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12)),
      onTap: () {
        context.read<SonoProvider>().playSong(song, songList);
        Navigator.push(context, MaterialPageRoute(builder: (_) => const NowPlayingPage()));
      },
    );
  }

  Widget _buildHighlightedText(String text, String query, TextStyle baseStyle, TextStyle? overrideStyle) {
    if (query.isEmpty || overrideStyle != null) {
      return Text(text, style: overrideStyle ?? baseStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final index = lowerText.indexOf(lowerQuery);

    if (index == -1) {
      return Text(text, style: baseStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: [
        TextSpan(text: text.substring(0, index), style: baseStyle),
        TextSpan(
          text: text.substring(index, index + query.length),
          style: baseStyle.copyWith(color: const Color(0xFF6C63FF), fontWeight: FontWeight.w800),
        ),
        TextSpan(text: text.substring(index + query.length), style: baseStyle),
      ]),
    );
  }

  String _formatDuration(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ─── PLAYING INDICATOR ────────────────────────────────────────────────────────

class _PlayingIndicator extends StatefulWidget {
  const _PlayingIndicator();

  @override
  State<_PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<_PlayingIndicator> with TickerProviderStateMixin {
  late List<AnimationController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(3, (i) {
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 400 + i * 100),
      )..repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) { c.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _controllers[i],
            builder: (_, __) => Container(
              width: 4,
              height: 6 + _controllers[i].value * 14,
              decoration: BoxDecoration(
                color: const Color(0xFF6C63FF),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─── MINI PLAYER ─────────────────────────────────────────────────────────────

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();
    final song = provider.currentSong;
    if (song == null) return const SizedBox();

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NowPlayingPage())),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6C63FF).withOpacity(0.15),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: song.artwork != null
                  ? Image.memory(song.artwork!, width: 44, height: 44, fit: BoxFit.cover)
                  : Container(
                      width: 44,
                      height: 44,
                      color: const Color(0xFF12121A),
                      child: const Icon(Icons.music_note, color: Color(0xFF6C63FF), size: 20),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(song.title,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(song.artist,
                      style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                provider.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 28,
              ),
              onPressed: provider.togglePlayPause,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 28),
              onPressed: provider.next,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── NOW PLAYING PAGE ─────────────────────────────────────────────────────────

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();
    final song = provider.currentSong;
    if (song == null) return const SizedBox();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'ŞİMDİ ÇALIYOR',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
            color: Colors.white.withOpacity(0.4),
          ),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          children: [
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              height: 300,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6C63FF).withOpacity(0.3),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: song.artwork != null
                    ? Image.memory(song.artwork!, fit: BoxFit.cover)
                    : Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A26),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Icon(Icons.music_note_rounded, size: 80,
                            color: const Color(0xFF6C63FF).withOpacity(0.4)),
                      ),
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        style: GoogleFonts.spaceGrotesk(
                            fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(song.artist,
                          style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            StreamBuilder<PositionData>(
              stream: provider.positionDataStream,
              builder: (context, snapshot) {
                final data = snapshot.data ??
                    PositionData(Duration.zero, Duration.zero, Duration.zero);
                final position = data.position;
                final duration = data.duration;

                return Column(
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFF6C63FF),
                        inactiveTrackColor: Colors.white.withOpacity(0.1),
                        thumbColor: Colors.white,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape: SliderComponentShape.noOverlay,
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble(),
                        max: duration.inMilliseconds.toDouble(),
                        onChanged: (value) {
                          provider.player.seek(Duration(milliseconds: value.toInt()));
                        },
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(position),
                            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12)),
                        Text(_fmt(duration),
                            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12)),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: Icon(Icons.shuffle_rounded,
                      color: provider.shuffle ? const Color(0xFF6C63FF) : Colors.white.withOpacity(0.4),
                      size: 24),
                  onPressed: provider.toggleShuffle,
                ),
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 36),
                  onPressed: provider.previous,
                ),
                GestureDetector(
                  onTap: provider.togglePlayPause,
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C63FF),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6C63FF).withOpacity(0.4),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Icon(
                      provider.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 36),
                  onPressed: provider.next,
                ),
                IconButton(
                  icon: Icon(
                    provider.loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                    color: provider.loopMode != LoopMode.off
                        ? const Color(0xFF6C63FF)
                        : Colors.white.withOpacity(0.4),
                    size: 24,
                  ),
                  onPressed: provider.toggleLoop,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
