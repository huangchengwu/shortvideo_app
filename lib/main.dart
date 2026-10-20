import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_native_error/get_native_error.dart';
import 'package:http/http.dart' as http;
import 'package:lpinyin/lpinyin.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

// ══════════════════════ 全局日志收集器（落盘版） ══════════════════════
class AppLogger {
  static final List<String> logs = [];
  static File? _logFile;

  /// 在 runApp 之前调用，初始化磁盘日志文件
  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}/app_logs.txt');
    } catch (_) {
      // 拿不到目录就算了，只走内存日志
    }
  }

  static void log(String tag, String message, [Object? error, StackTrace? stack]) {
    final time = DateTime.now().toIso8601String();
    final content = '[$time] [$tag] $message\n'
        '${error != null ? "错误: $error\n" : ""}'
        '${stack != null ? "堆栈: $stack\n" : ""}'
        '----------------------------------------\n';

    logs.add(content);
    debugPrint(content);

    // 追加写入磁盘，不阻塞主流程
    _logFile?.writeAsString(content, mode: FileMode.append).catchError((_) {});
  }
}

// ══════════════════════ 入口 ══════════════════════
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. 尽早安装原生崩溃信号处理器
  await NativeError.install();

  // 2. 初始化磁盘日志
  await AppLogger.init();

  // 3. 读取上次原生崩溃报告（如果有）
  try {
    final crash = await NativeError.takePendingCrash();
    if (crash != null) {
      AppLogger.log(
        "NativeCrash",
        "上次原生崩溃报告",
        crash.toJson().toString(),
        null,
      );
    }
  } catch (e, s) {
    AppLogger.log("NativeCrash", "读取崩溃报告失败", e, s);
  }

  // 4. Dart 层全局错误捕获
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    AppLogger.log("Flutter", "框架报错", details.exception, details.stack);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLogger.log("Platform", "平台异步报错", error, stack);
    return true;
  };

  // 5. 用 runZonedGuarded 兜底未捕获的异步异常
  runZonedGuarded(
    () async {
      MediaKit.ensureInitialized();

      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);

      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ));

      runApp(const ShortVideoApp());
    },
    (error, stack) {
      AppLogger.log("Zone", "未捕获的异步异常", error, stack);
    },
  );
}

// ══════════════════════ 存储模块 ══════════════════════
class Store {
  late File _file;
  Map<String, dynamic> data = {
    'videos': <dynamic>[],
    'alist': {
      'url': 'http://127.0.0.1:5244',
      'user': 'admin',
      'pwd': 'admin',
      'root': '/视频',
      'exclude_dirs': 'data_disk3',
    },
    'shuffle': false,
    'replay_mode': false,
    'last_play': {'path': '', 'pts': 0.0},
    'progress': <String, dynamic>{},
    'is_cover_mode': false,
  };

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/.shortvid.json');
    if (await _file.exists()) {
      try {
        final loaded = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        data.addAll(loaded);
        data['alist'] = <String, dynamic>{...(data['alist'] as Map? ?? {})};
        data['progress'] = <String, dynamic>{...(data['progress'] as Map? ?? {})};
        data['videos'] = List<dynamic>.from(data['videos'] ?? []);
      } catch (_) {}
    }
  }

  Future<void> save() async {
    try {
      await _file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }
}

// ══════════════════════ Alist 网络模块 ══════════════════════
class AlistClient {
  final String base;
  final String user;
  final String pwd;
  String token = '';

  AlistClient(String base, this.user, this.pwd)
      : base = base.replaceAll(RegExp(r'/+$'), '');

  Future<void> login() async {
    final r = await http.post(
      Uri.parse('$base/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': user, 'password': pwd}),
    ).timeout(const Duration(seconds: 10));
    final d = jsonDecode(r.body) as Map<String, dynamic>;
    if (d['code'] != 200) throw Exception(d['message'] ?? 'login failed');
    token = d['data']['token'];
  }

  Future<Map<String, dynamic>> _post(String endpoint, Map<String, dynamic> body) async {
    if (token.isEmpty) await login();
    var headers = {'Authorization': token, 'Content-Type': 'application/json'};
    var r = await http
        .post(Uri.parse('$base$endpoint'), headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
    var d = jsonDecode(r.body) as Map<String, dynamic>;
    if (d['code'] == 401) {
      await login();
      headers['Authorization'] = token;
      r = await http
          .post(Uri.parse('$base$endpoint'), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
      d = jsonDecode(r.body) as Map<String, dynamic>;
    }
    if (d['code'] != 200) throw Exception(d['message'] ?? '$endpoint failed');
    return d;
  }

  Future<List<dynamic>> listFiles(String path) async {
    final d = await _post('/api/fs/list', {'path': path, 'page': 1, 'per_page': 500});
    return (d['data']['content'] as List?) ?? [];
  }

  Future<String> getUrl(String path) async {
    final d = await _post('/api/fs/get', {'path': path});
    final url = d['data']['raw_url'] ?? d['data']['url'];
    if (url == null) throw Exception('no url');
    return url.startsWith('http') ? url : '$base$url';
  }

  Future<List<Map<String, dynamic>>> scanMp4(String root,
      {List<String> excludedDirs = const [], void Function(int)? progressCb}) async {
    final found = <Map<String, dynamic>>[];
    final visited = <String>{};

    Future<void> walk(String p) async {
      if (visited.contains(p)) return;
      visited.add(p);
      if (p.split('/').where((s) => s.isNotEmpty).any((s) => excludedDirs.contains(s))) return;
      List<dynamic> items;
      try {
        items = await listFiles(p);
      } catch (_) {
        return;
      }
      for (final it in items) {
        final name = (it['name'] ?? '') as String;
        final lower = name.toLowerCase();
        if (it['is_dir'] == true) {
          if (excludedDirs.contains(name)) continue;
          await walk('$p/$name'.replaceAll('//', '/'));
        } else if (lower.endsWith('.mp4') || lower.endsWith('.avi')) {
          // ★ AVI 已放行
          found.add({
            'title': name.substring(0, name.lastIndexOf('.')),
            'path': '$p/$name'.replaceAll('//', '/'),
            'dir': root,
          });
          progressCb?.call(found.length);
        }
      }
    }

    await walk(root);
    return found;
  }
}

// ══════════════════════ 主 App ══════════════════════
class ShortVideoApp extends StatelessWidget {
  const ShortVideoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShortVideo',
      debugShowCheckedModeBanner: false,
      builder: (context, widget) {
        ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
          return Material(
            color: Colors.red,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  '代码报错了:\n${errorDetails.exceptionAsString()}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          );
        };
        return widget ?? const SizedBox();
      },
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(primary: Color(0xFF2196F3)),
        fontFamily: 'MyFont',
      ),
      home: const BootScreen(),
    );
  }
}

class BootScreen extends StatefulWidget {
  const BootScreen({super.key});
  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  final store = Store();
  bool ready = false;

  @override
  void initState() {
    super.initState();
    store.init().then((_) {
      if (mounted) setState(() => ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return MainScreen(store: store);
  }
}

// ══════════════════════ 主界面 ══════════════════════
class MainScreen extends StatefulWidget {
  final Store store;
  const MainScreen({super.key, required this.store});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final PageController _pageController = PageController();
  final Map<String, Player> _players = {};
  final Map<String, VideoController> _videoControllers = {};
  final Set<String> _initializing = {};
  final Set<String> _errorPaths = {};
  final Map<String, String> _errorDetails = {};

  List<Map<String, dynamic>> _playlist = [];
  String _modeLabel = '全库';
  int _currentIdx = 0;

  bool _uiVisible = true;
  Timer? _uiTimer;

  double _speed = 1.0;
  final List<double> _speedOptions = [0.5, 1.0, 1.25, 1.5, 2.0];

  double _globalScale = 1.0;
  bool _isCoverMode = false;
  bool _isLandscape = false;

  @override
  void initState() {
    super.initState();
    _isCoverMode = widget.store.data['is_cover_mode'] == true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFromStore());
    _scheduleHide();
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _pageController.dispose();
    for (final p in _players.values) {
      _safeDisposePlayer(p);
    }
    super.dispose();
  }

  /// ★ 安全释放：先 pause 再 dispose，异常全部吞掉并记日志
  Future<void> _safeDisposePlayer(Player? player) async {
    if (player == null) return;
    try {
      await player.pause();
    } catch (e, s) {
      AppLogger.log("Player", "dispose 前 pause 失败", e, s);
    }
    try {
      await player.dispose();
    } catch (e, s) {
      AppLogger.log("Player", "dispose 失败", e, s);
    }
  }

  void _loadFromStore() {
    final videos =
        List<Map<String, dynamic>>.from((widget.store.data['videos'] as List).cast<Map>());
    if (videos.isEmpty) {
      setState(() {
        _playlist = [];
        _currentIdx = 0;
      });
      return;
    }

    final lastPath = ((widget.store.data['last_play'] as Map)['path'] ?? '') as String;
    int idx = 0;
    if (lastPath.isNotEmpty && widget.store.data['replay_mode'] != true) {
      final i = videos.indexWhere((v) => v['path'] == lastPath);
      if (i >= 0) idx = i;
    }
    setState(() {
      _playlist = videos;
      _currentIdx = idx;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients && idx > 0) _pageController.jumpToPage(idx);
      _onPageChanged(idx);
    });
  }

  void _scheduleHide() {
    _uiTimer?.cancel();
    _uiTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      if (_playlist.isEmpty) return;
      final path = _playlist[_currentIdx]['path'] as String;
      if (_players[path]?.state.playing == true && _globalScale == 1.0) {
        setState(() => _uiVisible = false);
      }
    });
  }

  void _showUi() {
    if (!_uiVisible) setState(() => _uiVisible = true);
    _scheduleHide();
  }

  void _toggleOrientation() async {
    setState(() => _isLandscape = !_isLandscape);
    if (_isLandscape) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _showUi();
  }

  Future<void> _ensureController(int idx, {bool autoPlay = false}) async {
    if (idx < 0 || idx >= _playlist.length) return;
    final path = _playlist[idx]['path'] as String;

    if (_errorPaths.contains(path)) return;
    if (_players.containsKey(path)) {
      if (autoPlay) _players[path]?.play();
      return;
    }
    if (_initializing.contains(path)) return;

    _initializing.add(path);
    try {
      String finalUrl = path;

      if (_modeLabel == '本地目录') {
        finalUrl = Uri.file(path).toString();
        AppLogger.log("Player", "准备加载本地文件: $finalUrl");
      } else {
        final a = widget.store.data['alist'] as Map;
        final client = AlistClient(a['url'], a['user'], a['pwd']);
        finalUrl = await client.getUrl(path);
        AppLogger.log("Player", "获取网络流地址: $finalUrl");
      }

      final player = Player();
      final videoController = VideoController(player);

      await player.setPlaylistMode(PlaylistMode.loop);
      await player.setRate(_speed);
      await player.open(Media(finalUrl), play: autoPlay);

      _players[path] = player;
      _videoControllers[path] = videoController;

      final savedPts = ((widget.store.data['progress'] as Map)[path] ?? 0) as num;
      if (savedPts > 1.5 && widget.store.data['replay_mode'] != true) {
        Future.delayed(const Duration(milliseconds: 500), () {
          player.seek(Duration(milliseconds: (savedPts * 1000).toInt()));
        });
      }

      if (mounted) setState(() {});
    } catch (e, stack) {
      AppLogger.log("Player", "播放失败: $path", e, stack);
      if (mounted) {
        setState(() {
          _errorPaths.add(path);
          _errorDetails[path] = e.toString();
        });
      }
    } finally {
      _initializing.remove(path);
    }
  }

  void _onPageChanged(int idx) async {
    if (idx < 0 || idx >= _playlist.length) return;
    final prev = _currentIdx;

    if (prev != idx) {
      setState(() => _currentIdx = idx);
      final prevPath = _playlist[prev]['path'] as String;
      _players[prevPath]?.pause();
    } else {
      setState(() => _currentIdx = idx);
    }

    final currentPath = _playlist[idx]['path'] as String;
    if (!_players.containsKey(currentPath) && !_errorPaths.contains(currentPath)) {
      await _ensureController(idx, autoPlay: true);
    } else if (_players.containsKey(currentPath)) {
      _players[currentPath]?.play();
    }

    _ensureController(idx + 1);
    _ensureController(idx - 1);

    final toRemove = <String>[];
    for (final path in _players.keys) {
      final i = _playlist.indexWhere((v) => v['path'] == path);
      if (i != -1 && (i - idx).abs() > 2) toRemove.add(path);
    }
    for (final path in toRemove) {
      await _safeDisposePlayer(_players.remove(path)); // ★ 安全释放
      _videoControllers.remove(path);
    }
    _saveProgress(prev);
    _showUi();
  }

  void _retryCurrentVideo() {
    final path = _playlist[_currentIdx]['path'];
    setState(() {
      _errorPaths.remove(path);
      _errorDetails.remove(path);
    });
    _ensureController(_currentIdx, autoPlay: true);
  }

  void _saveProgress(int idx) {
    if (idx < 0 || idx >= _playlist.length) return;
    final path = _playlist[idx]['path'];
    final player = _players[path];
    if (player == null || player.state.duration.inMilliseconds == 0) return;
    final pts = player.state.position.inMilliseconds / 1000.0;
    if (pts < 1) return;
    (widget.store.data['progress'] as Map)[path] = pts;
    widget.store.data['last_play'] = {'path': path, 'pts': pts};
    widget.store.save();
  }

  void _togglePlayPause() {
    final path = _playlist[_currentIdx]['path'];
    final player = _players[path];
    if (player == null) return;

    if (player.state.playing) {
      player.pause();
      setState(() => _uiVisible = true);
      _uiTimer?.cancel();
    } else {
      player.play();
      _showUi();
    }
    setState(() {});
  }

  void _seekRelative(int deltaSec) {
    final path = _playlist[_currentIdx]['path'];
    final player = _players[path];
    if (player == null) return;

    final target = player.state.position + Duration(seconds: deltaSec);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > player.state.duration ? player.state.duration : target);
    player.seek(clamped);
    _showUi();
  }

  void _next() {
    if (_currentIdx < _playlist.length - 1) {
      _pageController.nextPage(
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  void _prev() {
    if (_currentIdx > 0) {
      _pageController.previousPage(
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  void _cycleSpeed() {
    final i = _speedOptions.indexOf(_speed);
    _speed = _speedOptions[(i + 1) % _speedOptions.length];
    for (var p in _players.values) {
      p.setRate(_speed);
    }
    _showUi();
    setState(() {});
  }

  Future<void> _scanLocalDirectory() async {
    try {
      String? dirPath = await FilePicker.getDirectoryPath();
      if (dirPath == null) return;

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('正在扫描文件夹，请稍候...')));
      }

      Directory dir = Directory(dirPath);
      if (!await dir.exists()) return;

      List<Map<String, dynamic>> localVideos = [];

      await for (var entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final lower = entity.path.toLowerCase();
          if (lower.endsWith('.mp4') || lower.endsWith('.avi')) {
            // ★ AVI 已放行
            String fileName = entity.path.split(Platform.pathSeparator).last;
            localVideos.add({
              'title': fileName.substring(0, fileName.lastIndexOf('.')),
              'path': entity.path,
              'dir': dirPath,
            });
          }
        }
      }

      if (localVideos.isNotEmpty) {
        localVideos.sort((a, b) => a['path'].compareTo(b['path']));
        _switchPlaylist(localVideos, '本地目录');
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('该目录下未找到可播放视频')));
        }
      }
    } catch (e, stack) {
      AppLogger.log("Scanner", "扫描失败", e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('扫描失败: $e')));
      }
    }
  }

  void _toggleShuffle() {
    final isShuffle = widget.store.data['shuffle'] != true;
    widget.store.data['shuffle'] = isShuffle;
    widget.store.save();

    if (_playlist.isNotEmpty) {
      final currentVideo = _playlist[_currentIdx];

      if (isShuffle) {
        _playlist.shuffle();
      } else {
        _playlist =
            List<Map<String, dynamic>>.from((widget.store.data['videos'] as List).cast<Map>());
      }

      final newIdx = _playlist.indexWhere((v) => v['path'] == currentVideo['path']);
      setState(() {
        _currentIdx = newIdx >= 0 ? newIdx : 0;
      });

      if (_pageController.hasClients) _pageController.jumpToPage(_currentIdx);
    }
    _showUi();
    setState(() {});
  }

  void _toggleReplay() {
    widget.store.data['replay_mode'] = widget.store.data['replay_mode'] != true;
    widget.store.save();
    _showUi();
    setState(() {});
  }

  void _toggleCoverMode() {
    setState(() {
      _isCoverMode = !_isCoverMode;
      widget.store.data['is_cover_mode'] = _isCoverMode;
      widget.store.save();
    });
    _showUi();
  }

  Future<void> _openAdmin() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AdminScreen(store: widget.store)));
    for (final p in _players.values) {
      await _safeDisposePlayer(p); // ★ 安全释放
    }
    _players.clear();
    _videoControllers.clear();
    _errorPaths.clear();
    _errorDetails.clear();
    setState(() {
      _playlist = [];
      _currentIdx = 0;
    });
    _loadFromStore();
  }

  Future<void> _openSearch() async {
    final videos =
        List<Map<String, dynamic>>.from((widget.store.data['videos'] as List).cast<Map>());
    if (videos.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('库里还没有视频')));
      return;
    }
    final result = await showDialog<List<Map<String, dynamic>>>(
        context: context, builder: (_) => SearchDialog(videos: videos));
    if (result != null && result.isNotEmpty) _switchPlaylist(result, '搜索');
  }

  Future<void> _openBrowser() async {
    final result = await showDialog<List<Map<String, dynamic>>>(
        context: context, builder: (_) => AlistBrowserDialog(store: widget.store));
    if (result != null && result.isNotEmpty) _switchPlaylist(result, '浏览');
  }

  Future<void> _switchPlaylist(List<Map<String, dynamic>> list, String label) async {
    for (final p in _players.values) {
      await _safeDisposePlayer(p); // ★ 安全释放
    }
    _players.clear();
    _videoControllers.clear();
    _errorPaths.clear();
    _errorDetails.clear();
    setState(() {
      _playlist = list;
      _modeLabel = label;
      _currentIdx = 0;
      _globalScale = 1.0;
    });
    if (_pageController.hasClients) _pageController.jumpToPage(0);
    _onPageChanged(0);
  }

  Future<void> _restoreFull() async {
    widget.store.data['shuffle'] = false;
    widget.store.save();

    final videos =
        List<Map<String, dynamic>>.from((widget.store.data['videos'] as List).cast<Map>());
    if (videos.isEmpty) return;
    _switchPlaylist(videos, '全库');
  }

  void _showDetail() {
    if (_playlist.isEmpty) return;
    final v = _playlist[_currentIdx];
    final player = _players[v['path']];
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('视频详情'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow('标题', (v['title'] ?? '').toString()),
              _detailRow('目录', (v['dir'] ?? '—').toString()),
              _detailRow('路径', (v['path'] ?? '').toString()),
              _detailRow('模式', _modeLabel),
              _detailRow(
                  '进度',
                  player == null
                      ? '—'
                      : '${_fmt(player.state.position)} / ${_fmt(player.state.duration)}'),
              _detailRow('倍速', '${_speed}x'),
              _detailRow('画面', _isCoverMode ? '铺满裁剪' : '原始比例'),
              _detailRow('随机', widget.store.data['shuffle'] == true ? '开' : '关'),
              _detailRow('重播', widget.store.data['replay_mode'] == true ? '开' : '关'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: (v['path'] ?? '').toString()));
              Navigator.pop(context);
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('路径已复制')));
            },
            child: const Text('复制路径'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _detailRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 60, child: Text('$k：', style: const TextStyle(color: Colors.grey))),
            Expanded(child: Text(v)),
          ],
        ),
      );

  String _fmt(Duration d) {
    if (d.inMilliseconds <= 0) return '00:00';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _showLogDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bug_report, color: Colors.redAccent),
            SizedBox(width: 8),
            Text('运行日志'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              child: SelectableText(
                AppLogger.logs.isEmpty ? "暂无日志" : AppLogger.logs.join('\n\n'),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, color: Colors.greenAccent),
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: AppLogger.logs.join('\n\n')));
              Navigator.pop(context);
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('日志已复制到剪贴板')));
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制全部日志'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        final shuffle = widget.store.data['shuffle'] == true;
        final replay = widget.store.data['replay_mode'] == true;

        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.folder, color: Colors.orangeAccent),
                title: const Text('打开本地目录', style: TextStyle(color: Colors.orangeAccent)),
                onTap: () {
                  Navigator.pop(context);
                  _scanLocalDirectory();
                },
              ),
              ListTile(
                leading: const Icon(Icons.search, color: Colors.white),
                title: const Text('搜索网络视频 (拼音)', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _openSearch();
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open, color: Colors.white),
                title: const Text('浏览 Alist 目录', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _openBrowser();
                },
              ),
              ListTile(
                leading: Icon(Icons.shuffle, color: shuffle ? Colors.blue : Colors.white),
                title: Text('随机播放',
                    style: TextStyle(color: shuffle ? Colors.blue : Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _toggleShuffle();
                },
              ),
              ListTile(
                leading: Icon(Icons.repeat, color: replay ? Colors.blue : Colors.white),
                title: Text('重播模式',
                    style: TextStyle(color: replay ? Colors.blue : Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _toggleReplay();
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings, color: Colors.cyan),
                title: const Text('服务器设置', style: TextStyle(color: Colors.cyan)),
                onTap: () {
                  Navigator.pop(context);
                  _openAdmin();
                },
              ),
              ListTile(
                leading: const Icon(Icons.bug_report, color: Colors.redAccent),
                title: const Text('查看运行日志', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(context);
                  _showLogDialog();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_playlist.isEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.video_library, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('暂无视频，去后台扫描或打开本地目录',
                  style: TextStyle(color: Colors.grey, fontSize: 16)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _scanLocalDirectory,
                icon: const Icon(Icons.folder_open),
                label: const Text('打开本地目录'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: _openAdmin, icon: const Icon(Icons.settings), label: const Text('打开后台')),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            physics: _globalScale > 1.0
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            onPageChanged: _onPageChanged,
            itemCount: _playlist.length,
            itemBuilder: (context, i) {
              final path = _playlist[i]['path'];
              return VideoPage(
                key: ValueKey(path),
                videoController: _videoControllers[path],
                isActive: i == _currentIdx,
                isCoverMode: _isCoverMode,
                isError: _errorPaths.contains(path),
                errorMsg: _errorDetails[path],
                onRetry: _retryCurrentVideo,
                onNeedController: () => _ensureController(i, autoPlay: true),
                onTap: () {
                  if (_uiVisible) {
                    setState(() => _uiVisible = false);
                    _uiTimer?.cancel();
                  } else {
                    _showUi();
                  }
                },
                onDoubleTap: _togglePlayPause,
                onHorizontalSeek: _seekRelative,
                onScaleChanged: (s) {
                  if (s != _globalScale) setState(() => _globalScale = s);
                },
              );
            },
          ),
          _buildTopBar(),
          if (_uiVisible) _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: AnimatedOpacity(
          opacity: _uiVisible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black.withOpacity(0.6), Colors.transparent])),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _showDetail,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                          '[$_modeLabel] ${_playlist[_currentIdx]['title']} (${_currentIdx + 1}/${_playlist.length})',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
                if (_modeLabel != '全库')
                  IconButton(
                      icon: const Icon(Icons.undo, size: 20, color: Colors.white70),
                      onPressed: _restoreFull,
                      tooltip: '返回全库'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final path = _playlist[_currentIdx]['path'];
    final player = _players[path];

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black.withOpacity(0.75), Colors.transparent])),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (player != null) ProgressBar(player: player, onSeek: _showUi),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.skip_previous, color: Colors.white, size: 24),
                      onPressed: _prev),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: StreamBuilder<bool>(
                      stream: player?.stream.playing ?? const Stream<bool>.empty(),
                      initialData: player?.state.playing ?? false,
                      builder: (context, snapshot) {
                        final isPlaying = snapshot.data ?? false;
                        return Icon(
                          isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                          color: Colors.white,
                          size: 34,
                        );
                      },
                    ),
                    onPressed: _togglePlayPause,
                  ),
                  IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.skip_next, color: Colors.white, size: 24),
                      onPressed: _next),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _isCoverMode ? Icons.crop : Icons.crop_free,
                      color: _isCoverMode ? Colors.blueAccent : Colors.white,
                      size: 22,
                    ),
                    onPressed: _toggleCoverMode,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _isLandscape ? Icons.screen_lock_portrait : Icons.screen_lock_landscape,
                      color: Colors.white,
                      size: 24,
                    ),
                    onPressed: _toggleOrientation,
                    tooltip: '横竖屏切换',
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextButton(
                      onPressed: _cycleSpeed,
                      style: TextButton.styleFrom(
                          minimumSize: const Size(40, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          backgroundColor: Colors.white24,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
                      child: Text('${_speed}x',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ),
                  IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.menu, color: Colors.cyanAccent, size: 24),
                      onPressed: _showMoreMenu),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════ 单视频页面 ══════════════════════
class VideoPage extends StatefulWidget {
  final VideoController? videoController;
  final bool isActive;
  final bool isCoverMode;
  final bool isError;
  final String? errorMsg;
  final VoidCallback onRetry;
  final VoidCallback onNeedController;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final void Function(int deltaSec) onHorizontalSeek;
  final ValueChanged<double> onScaleChanged;

  const VideoPage({
    super.key,
    required this.videoController,
    required this.isActive,
    required this.isCoverMode,
    required this.isError,
    this.errorMsg,
    required this.onRetry,
    required this.onNeedController,
    required this.onTap,
    required this.onDoubleTap,
    required this.onHorizontalSeek,
    required this.onScaleChanged,
  });

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  Offset _startOffset = Offset.zero;
  double _startScale = 1.0;

  double _dragDeltaX = 0;
  bool _seeking = false;
  int _seekPreviewDelta = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.videoController == null && !widget.isError) widget.onNeedController();
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onScaleStart: (d) {
        _startOffset = _offset;
        _startScale = _scale;
      },
      onScaleUpdate: (d) {
        if (d.pointerCount >= 2) {
          setState(() {
            _scale = (_startScale * d.scale).clamp(1.0, 4.0);
            if (_scale <= 1.0) _offset = Offset.zero;
          });
          widget.onScaleChanged(_scale);
        } else if (_scale > 1.0) {
          setState(() => _offset = _startOffset + (d.focalPointDelta));
        }
      },
      onScaleEnd: (_) {
        if (_scale <= 1.05) {
          setState(() {
            _scale = 1.0;
            _offset = Offset.zero;
          });
          widget.onScaleChanged(_scale);
        }
      },
      onHorizontalDragStart: _scale > 1.0
          ? null
          : (d) {
              _dragDeltaX = 0;
              _seeking = true;
              setState(() {});
            },
      onHorizontalDragUpdate: _scale > 1.0
          ? null
          : (d) {
              _dragDeltaX += d.delta.dx;
              _seekPreviewDelta = (_dragDeltaX / 10).round();
              setState(() {});
            },
      onHorizontalDragEnd: _scale > 1.0
          ? null
          : (d) {
              if (_seekPreviewDelta.abs() > 2) {
                widget.onHorizontalSeek(_seekPreviewDelta);
              }
              setState(() {
                _seeking = false;
                _seekPreviewDelta = 0;
                _dragDeltaX = 0;
              });
            },
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            Center(
              child: Transform(
                transform: Matrix4.identity()
                  ..translate(_offset.dx, _offset.dy)
                  ..scale(_scale),
                alignment: Alignment.center,
                child: _buildVideo(widget.videoController),
              ),
            ),
            if (widget.videoController == null && !widget.isError)
              const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 12),
                    Text('正在加载视频...', style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ],
                ),
              ),
            if (widget.isError)
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                    const SizedBox(height: 12),
                    const Text('加载失败', style: TextStyle(color: Colors.white, fontSize: 16)),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(widget.errorMsg ?? '网络较差或视频无法加载',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    ),
                    ElevatedButton.icon(
                      onPressed: widget.onRetry,
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      label: const Text('点击重试', style: TextStyle(color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                      ),
                    ),
                  ],
                ),
              ),
            if (_seeking && _seekPreviewDelta.abs() > 2)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                      color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    '${_seekPreviewDelta > 0 ? "快进" : "快退"} ${_seekPreviewDelta.abs()}s',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo(VideoController? ctrl) {
    if (ctrl == null) return const SizedBox.shrink();
    return SizedBox.expand(
      child: Video(
        controller: ctrl,
        fit: widget.isCoverMode ? BoxFit.cover : BoxFit.contain,
        controls: NoVideoControls,
      ),
    );
  }
}

// ══════════════════════ 进度条（修复版） ══════════════════════
class ProgressBar extends StatefulWidget {
  final Player player;
  final VoidCallback onSeek;
  const ProgressBar({super.key, required this.player, required this.onSeek});

  @override
  State<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<ProgressBar> {
  bool _dragging = false;
  double _dragValue = 0;

  @override
  void didUpdateWidget(covariant ProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _dragging = false;
      _dragValue = 0;
    }
  }

  String _fmt(Duration d) {
    if (d.inMilliseconds <= 0) return '00:00';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  double _clamp(double v, double min, double max) => v < min ? min : (v > max ? max : v);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, posSnapshot) {
        return StreamBuilder<Duration>(
          stream: widget.player.stream.duration,
          initialData: widget.player.state.duration,
          builder: (context, durSnapshot) {
            final pos = posSnapshot.data ?? Duration.zero;
            final dur = durSnapshot.data ?? Duration.zero;

            final hasDuration = dur.inMilliseconds > 0;
            final max = hasDuration ? dur.inMilliseconds.toDouble() : 1.0;
            final posMs = pos.inMilliseconds.toDouble();

            final currentValue = _dragging
                ? _clamp(_dragValue, 0.0, max)
                : (hasDuration ? _clamp(posMs, 0.0, max) : 0.0);

            final displayPos = _dragging
                ? Duration(milliseconds: _dragValue.round().clamp(0, max.toInt()))
                : pos;

            return Row(
              children: [
                Text(_fmt(displayPos),
                    style: const TextStyle(color: Colors.white70, fontSize: 11)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: Colors.blue,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.blue,
                      disabledActiveTrackColor: Colors.blueGrey,
                      disabledInactiveTrackColor: Colors.white12,
                      disabledThumbColor: Colors.blueGrey,
                    ),
                    child: Slider(
                      value: currentValue,
                      max: max,
                      onChangeStart: hasDuration
                          ? (v) {
                              setState(() {
                                _dragging = true;
                                _dragValue = v;
                              });
                            }
                          : null,
                      onChanged: hasDuration
                          ? (v) {
                              setState(() => _dragValue = v);
                            }
                          : null,
                      onChangeEnd: hasDuration
                          ? (v) {
                              widget.player.seek(Duration(milliseconds: v.round()));
                              setState(() => _dragging = false);
                              widget.onSeek();
                            }
                          : null,
                    ),
                  ),
                ),
                Text(_fmt(dur), style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            );
          },
        );
      },
    );
  }
}

// ══════════════════════ 拼音搜索弹窗 ══════════════════════
class SearchDialog extends StatefulWidget {
  final List<Map<String, dynamic>> videos;
  const SearchDialog({super.key, required this.videos});
  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  late Map<String, String> _pinyinCache;

  @override
  void initState() {
    super.initState();
    _results = List.of(widget.videos);
    _pinyinCache = {};
    for (var v in widget.videos) {
      final title = (v['title'] ?? '').toString();
      _pinyinCache[title] = PinyinHelper.getPinyinE(title,
          separator: '', defPinyin: '', format: PinyinFormat.WITHOUT_TONE).toLowerCase();
    }
    _ctrl.addListener(_onSearch);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onSearch() {
    final q = _ctrl.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _results = List.of(widget.videos);
      } else {
        final kws = q.split(RegExp(r'\s+')).where((k) => k.isNotEmpty).toList();
        _results = widget.videos.where((v) {
          final title = (v['title'] ?? '').toString().toLowerCase();
          final norm = title.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]'), '');
          final py = _pinyinCache[title] ?? '';
          return kws.every((k) {
            final nk = k.replaceAll(RegExp(r'[^a-z0-9]'), '');
            return title.contains(k) || (nk.isNotEmpty && norm.contains(nk)) || py.contains(k);
          });
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '输入关键词（支持拼音，如 "dys" 搜 "电影史"）',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Text('共 ${_results.length} 个结果',
                    style: const TextStyle(color: Colors.grey, fontSize: 12))
              ]),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.builder(
                itemCount: _results.length > 200 ? 200 : _results.length,
                itemBuilder: (context, i) => ListTile(
                  dense: true,
                  title: Text((_results[i]['title'] ?? '').toString(),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, _results),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(context), child: const Text('关闭'))
                  ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════ Alist 浏览器弹窗 ══════════════════════
class AlistBrowserDialog extends StatefulWidget {
  final Store store;
  const AlistBrowserDialog({super.key, required this.store});
  @override
  State<AlistBrowserDialog> createState() => _AlistBrowserDialogState();
}

class _AlistBrowserDialogState extends State<AlistBrowserDialog> {
  late AlistClient _client;
  String _path = '/';
  List<dynamic> _items = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final a = widget.store.data['alist'] as Map;
    _client = AlistClient(a['url'], a['user'], a['pwd']);
    final root = (a['root'] as String?)?.replaceAll(RegExp(r'/+$'), '') ?? '/';
    _path = root.isEmpty ? '/' : root;
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _client.listFiles(_path);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e, stack) {
      AppLogger.log("Browser", "列表加载失败", e, stack);
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _enter(String name) {
    setState(() => _path = '$_path/$name'.replaceAll('//', '/'));
    _refresh();
  }

  void _up() {
    if (_path == '/') return;
    final parts = _path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isNotEmpty) parts.removeLast();
    setState(() => _path = '/' + parts.join('/'));
    _refresh();
  }

  Future<void> _playDir() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final excluded = ((widget.store.data['alist']['exclude_dirs'] as String?) ?? '')
          .replaceAll('，', ',')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final videos = await _client.scanMp4(_path, excludedDirs: excluded);
      if (!mounted) return;
      if (videos.isEmpty) {
        setState(() {
          _loading = false;
          _error = '目录内无可播放视频';
        });
        return;
      }
      Navigator.pop(context, videos);
    } catch (e, stack) {
      AppLogger.log("Browser", "目录扫描失败", e, stack);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _playFile(String name) {
    Navigator.pop(context, [
      {
        'title': name.substring(0, name.lastIndexOf('.')),
        'path': '$_path/$name'.replaceAll('//', '/'),
        'dir': ''
      }
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(8),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _path == '/' ? null : _up),
                  Expanded(
                      child: Text(_path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
                  IconButton(
                      icon: const Icon(Icons.play_arrow),
                      color: Colors.greenAccent,
                      onPressed: _loading ? null : _playDir,
                      tooltip: '播放此目录全部'),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('❌ $_error',
                      style: const TextStyle(color: Colors.red, fontSize: 12))),
            Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildList()),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(context), child: const Text('关闭'))
                  ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final dirs = _items.where((it) => it['is_dir'] == true).toList()
      ..sort((a, b) =>
          (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
    final files = _items.where((it) => it['is_dir'] != true).toList()
      ..sort((a, b) =>
          (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
    final all = [...dirs, ...files];
    if (all.isEmpty) {
      return const Center(child: Text('文件夹为空', style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      itemCount: all.length,
      itemBuilder: (context, i) {
        final it = all[i];
        final name = (it['name'] ?? '') as String;
        final isDir = it['is_dir'] == true;
        final lower = name.toLowerCase();
        final isVideo = lower.endsWith('.mp4') || lower.endsWith('.avi');
        return ListTile(
          dense: true,
          leading: Icon(
              isDir
                  ? Icons.folder
                  : (isVideo ? Icons.video_file : Icons.insert_drive_file),
              color: isDir ? Colors.blue : (isVideo ? Colors.cyan : Colors.grey)),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: isDir ? () => _enter(name) : null,
          trailing: isDir
              ? IconButton(
                  icon: const Icon(Icons.play_arrow, color: Colors.redAccent),
                  onPressed: () {
                    setState(() => _path = '$_path/$name'.replaceAll('//', '/'));
                    _playDir();
                  })
              : (isVideo
                  ? IconButton(
                      icon: const Icon(Icons.play_circle, color: Colors.cyan),
                      onPressed: () => _playFile(name))
                  : null),
        );
      },
    );
  }
}

// ══════════════════════ 后台配置页 ══════════════════════
class AdminScreen extends StatefulWidget {
  final Store store;
  const AdminScreen({super.key, required this.store});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late TextEditingController _urlCtrl, _userCtrl, _pwdCtrl, _rootCtrl, _excludeCtrl;
  String _status = '';
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    final a = widget.store.data['alist'] as Map;
    _urlCtrl = TextEditingController(text: a['url'] ?? '');
    _userCtrl = TextEditingController(text: a['user'] ?? '');
    _pwdCtrl = TextEditingController(text: a['pwd'] ?? '');
    _rootCtrl = TextEditingController(text: a['root'] ?? '/视频');
    _excludeCtrl = TextEditingController(text: a['exclude_dirs'] ?? '');
    _status = '当前本地库: ${(widget.store.data['videos'] as List).length} 个视频';
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _pwdCtrl.dispose();
    _rootCtrl.dispose();
    _excludeCtrl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final url = _urlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    final root = _rootCtrl.text.trim().isEmpty ? '/' : _rootCtrl.text.trim();
    final exclude = _excludeCtrl.text.trim();

    widget.store.data['alist'] = {
      'url': url,
      'user': user,
      'pwd': pwd,
      'root': root,
      'exclude_dirs': exclude
    };
    await widget.store.save();

    setState(() {
      _scanning = true;
      _status = '正在扫描...';
    });

    try {
      final client = AlistClient(url, user, pwd);
      final excluded = exclude
          .replaceAll('，', ',')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final videos =
          await client.scanMp4(root, excludedDirs: excluded, progressCb: (n) {
        if (mounted) setState(() => _status = '扫描中... 已找到 $n 个');
      });
      final validPaths = videos.map((v) => v['path']).toSet();
      final progress = widget.store.data['progress'] as Map;
      progress.removeWhere((k, _) => !validPaths.contains(k));
      widget.store.data['videos'] = videos;
      await widget.store.save();

      if (!mounted) return;
      setState(() {
        _scanning = false;
        _status = '✅ 扫描成功! 共 ${videos.length} 个';
      });
    } catch (e, stack) {
      AppLogger.log("Scanner", "全库扫描失败", e, stack);
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _status = '❌ 失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alist 服务器配置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                    labelText: 'Alist URL',
                    prefixIcon: Icon(Icons.link),
                    border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: _userCtrl,
                decoration:
                    const InputDecoration(labelText: '用户', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: _pwdCtrl,
                obscureText: true,
                decoration:
                    const InputDecoration(labelText: '密码', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: _rootCtrl,
                decoration: const InputDecoration(
                    labelText: '扫描根目录', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: _excludeCtrl,
                decoration: const InputDecoration(
                    labelText: '排除目录（逗号分隔）', border: OutlineInputBorder())),
            const SizedBox(height: 20),
            Text(_status,
                style: TextStyle(
                    color: _status.startsWith('✅')
                        ? Colors.green
                        : (_status.startsWith('❌') ? Colors.red : Colors.grey))),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _scanning ? null : _scan,
              icon: const Icon(Icons.search),
              label: Text(_scanning ? '扫描中...' : '保存并扫描全库'),
              style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
                onPressed: () => Navigator.pop(context, true), child: const Text('返回播放器')),
          ],
        ),
      ),
    );
  }
}