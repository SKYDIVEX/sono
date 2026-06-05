import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:math';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.skydivex.sono.channel.audio',
    androidNotificationChannelName: 'SONO Audio',
    androidNotificationOngoing: true,
    androidShowNotificationBadge: true,
  );
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

// ─── MODELS ───────────────────────────────────────────────────────────────────

class PositionData {
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
  PositionData(this.position, this.bufferedPosition, this.duration);
}

// ─── PROVIDER ─────────────────────────────────────────────────────────────────

class SonoProvider extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  final OnAudioQuery audioQuery = OnAudioQuery();

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
    final status = await Permission.audio.request();
    if (!status.isGranted) {
      await Permission.storage.request();
    }
    allSongs = await audioQuery.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );
    filteredSongs = List.from(allSongs);
    notifyListeners();
  }

  void search(String query) {
    searchQuery = query;
    if (query.isEmpty) {
      filteredSongs = List.from(allSongs);
    } else {
      final q = query.toLowerCase();
      filteredSongs = allSongs.where((s) {
        final titleMatch = s.title.toLowerCase().contains(q);
        final artistMatch = (s.artist ?? '').toLowerCase().contains(q);
        return titleMatch || artistMatch;
      }).toList();
    }
    notifyListeners();
  }

  Future<void> playSong(SongModel song, List<SongModel> songList) async {
    queue = List.from(songList);
    currentIndex = queue.indexOf(song);
    currentSong = song;

    final playlist = ConcatenatingAudioSource(
      children: queue.map((s) => AudioSource.uri(
        Uri.parse(s.uri!),
        tag: MediaItem(
          id: s.id.toString(),
          title: s.title,
          artist: s.artist ?? 'Bilinmeyen Sanatçı',
          album: s.album ?? '',
          duration: Duration(milliseconds: s.duration ?? 0),
        ),
      )).toList(),
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

  Future<void> next() async {
    await player.seekToNext();
  }

  Future<void> previous() async {
    await player.seekToPrevious();
  }

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
      bottomNavigationBar: _BottomNav(),
    );
  }
}

// ─── BOTTOM NAV ───────────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SonoProvider>();
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF12121A),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.05)),
        ),
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
            child: Text(
              'SONO',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF6C63FF),
                letterSpacing: 4,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              '${provider.allSongs.length} şarkı',
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: provider.allSongs.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF6C63FF),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 160),
                    itemCount: provider.allSongs.length,
                    itemBuilder: (context, index) {
                      final song = provider.allSongs[index];
                      return SongTile(
                        song: song,
                        songList: provider.allSongs,
                        isPlaying: provider.currentSong?.id == song.id &&
                            provider.isPlaying,
                      );
                    },
                  ),
          ),
        ],
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
              onChanged: provider.search,
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
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 160),
              itemCount: provider.filteredSongs.length,
              itemBuilder: (context, index) {
                final song = provider.filteredSongs[index];
                return SongTile(
                  song: song,
                  songList: provider.filteredSongs,
                  isPlaying: provider.currentSong?.id == song.id &&
                      provider.isPlaying,
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
              style: GoogleFonts.spaceGrotesk(
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: provider.queue.isEmpty
                ? Center(
                    child: Text(
                      'Kuyruk boş',
                      style: TextStyle(color: Colors.white.withOpacity(0.3)),
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
        child: QueryArtworkWidget(
          id: song.id,
          type: ArtworkType.AUDIO,
          artworkWidth: 52,
          artworkHeight: 52,
          artworkFit: BoxFit.cover,
          nullArtworkWidget: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A26),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.music_note,
              color: const Color(0xFF6C63FF).withOpacity(0.6),
              size: 24,
            ),
          ),
        ),
      ),
      title: _buildHighlightedText(
        song.title,
        highlightQuery,
        const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        isCurrent
            ? const TextStyle(
                color: Color(0xFF6C63FF),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              )
            : null,
      ),
      subtitle: _buildHighlightedText(
        song.artist ?? 'Bilinmeyen Sanatçı',
        highlightQuery,
        TextStyle(
          color: Colors.white.withOpacity(0.45),
          fontSize: 12,
        ),
        null,
      ),
      trailing: isPlaying
          ? const _PlayingIndicator()
          : Text(
              _formatDuration(song.duration ?? 0),
              style: TextStyle(
                color: Colors.white.withOpacity(0.3),
                fontSize: 12,
              ),
            ),
      onTap: () {
        context.read<SonoProvider>().playSong(song, songList);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NowPlayingPage()),
        );
      },
    );
  }

  Widget _buildHighlightedText(
    String text,
    String query,
    TextStyle baseStyle,
    TextStyle? overrideStyle,
  ) {
    if (query.isEmpty || overrideStyle != null) {
      return Text(
        text,
        style: overrideStyle ?? baseStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
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
      text: TextSpan(
        children: [
          TextSpan(text: text.substring(0, index), style: baseStyle),
          TextSpan(
            text: text.substring(index, index + query.length),
            style: baseStyle.copyWith(
              color: const Color(0xFF6C63FF),
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: text.substring(index + query.length), style: baseStyle),
        ],
      ),
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

class _PlayingIndicatorState extends State<_PlayingIndicator>
    with TickerProviderStateMixin {
  late List<AnimationController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(3, (i) {
      final c = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 400 + i * 100),
      )..repeat(reverse: true);
      return c;
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
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
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const NowPlayingPage()),
      ),
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
              child: QueryArtworkWidget(
                id: song.id,
                type: ArtworkType.AUDIO,
                artworkWidth: 44,
                artworkHeight: 44,
                artworkFit: BoxFit.cover,
                nullArtworkWidget: Container(
                  width: 44,
                  height: 44,
                  color: const Color(0xFF12121A),
                  child: const Icon(Icons.music_note,
                      color: Color(0xFF6C63FF), size: 20),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    song.artist ?? 'Bilinmeyen Sanatçı',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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
              icon: const Icon(Icons.skip_next_rounded,
                  color: Colors.white, size: 28),
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
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              size: 32, color: Colors.white),
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
            // Artwork
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
                child: QueryArtworkWidget(
                  id: song.id,
                  type: ArtworkType.AUDIO,
                  artworkWidth: double.infinity,
                  artworkHeight: 300,
                  artworkFit: BoxFit.cover,
                  nullArtworkWidget: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A26),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 80,
                      color: const Color(0xFF6C63FF).withOpacity(0.4),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            // Title & Artist
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        song.artist ?? 'Bilinmeyen Sanatçı',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            // Progress Bar
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
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6),
                        overlayShape: SliderComponentShape.noOverlay,
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: position.inMilliseconds
                            .clamp(0, duration.inMilliseconds)
                            .toDouble(),
                        max: duration.inMilliseconds.toDouble(),
                        onChanged: (value) {
                          provider.player.seek(
                              Duration(milliseconds: value.toInt()));
                        },
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _fmt(position),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          _fmt(duration),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            // Controls
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.shuffle_rounded,
                    color: provider.shuffle
                        ? const Color(0xFF6C63FF)
                        : Colors.white.withOpacity(0.4),
                    size: 24,
                  ),
                  onPressed: provider.toggleShuffle,
                ),
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded,
                      color: Colors.white, size: 36),
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
                      provider.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded,
                      color: Colors.white, size: 36),
                  onPressed: provider.next,
                ),
                IconButton(
                  icon: Icon(
                    provider.loopMode == LoopMode.off
                        ? Icons.repeat_rounded
                        : provider.loopMode == LoopMode.all
                            ? Icons.repeat_rounded
                            : Icons.repeat_one_rounded,
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