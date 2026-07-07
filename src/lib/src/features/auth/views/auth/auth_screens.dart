import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:webview_all/webview_all.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/views/layout.dart';
import 'package:yayma/src/rust/api/auth.dart' as rust;
import 'package:yayma/src/rust/api/playback.dart' as rust;

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  bool _hasLoadedState = false;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final authState = authSignal.value;

        return authState.map(
          data: (isLoggedIn) {
            if (isLoggedIn) {
              if (!_hasLoadedState) {
                _hasLoadedState = true;
                unawaited(
                  Future.microtask(() {
                    unawaited(() async {
                      final ctx = appContextSignal.value;
                      if (ctx == null) return;
                      final state = await rust.restoreSavedState(ctx: ctx);
                      if (state != null) {
                        await rust.restoreAndPlay(
                          ctx: ctx,
                          trackId: state.trackId,
                          positionMs: state.positionMs,
                          isPlaying: state.isPlaying,
                        );
                      }
                    }());
                  }),
                );
              }
              return const AppLayout();
            }
            return const LoginScreen();
          },
          error: (dynamic e, dynamic _) =>
              Scaffold(body: Center(child: Text('Ошибка: $e'))),
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
        );
      },
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _tokenController = TextEditingController();

  void _showWebView() {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => const YandexLoginDialog(),
      ),
    );
  }

  void _showDeviceLogin() {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => const YandexDeviceLoginDialog(),
      ),
    );
  }

  void _handleLogin(String val) {
    var token = val.trim();
    try {
      token = Uri.decodeFull(token);
    } on Object catch (_) {}

    token = token.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF\u00A0]'), '');
    token = token.replaceAll(RegExp(r'[^\x21-\x7E]'), '');

    final urlMatch = RegExp('access_token=([^&/#?]+)').firstMatch(token);
    if (urlMatch != null) {
      token = urlMatch.group(1)!;
    } else {
      final directMatch = RegExp('(y0_[a-zA-Z0-9._-]+)').firstMatch(token);
      if (directMatch != null) {
        token = directMatch.group(1)!;
      }
    }

    if (token.isNotEmpty && !token.startsWith('http')) {
      unawaited(login(token));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final theme = Theme.of(context);
        final isDesktop =
            Platform.isWindows || Platform.isLinux || Platform.isMacOS;
        final isCustomTitlebar = isDesktop && customTitlebarSignal.value;
        final showBrowserFirst = Platform.isLinux;

        final webViewButton = showBrowserFirst
            ? OutlinedButton.icon(
                onPressed: _showWebView,
                icon: const Icon(Icons.open_in_new_rounded),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                ),
                label: const Text(
                  'Открыть окно входа',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              )
            : ElevatedButton.icon(
                onPressed: _showWebView,
                icon: const Icon(Icons.open_in_new_rounded),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 50),
                ),
                label: const Text(
                  'Открыть окно входа',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              );

        final browserButton = showBrowserFirst
            ? ElevatedButton.icon(
                onPressed: _showDeviceLogin,
                icon: const Icon(Icons.devices_rounded),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 50),
                ),
                label: const Text(
                  'Войти через браузер',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              )
            : OutlinedButton.icon(
                onPressed: _showDeviceLogin,
                icon: const Icon(Icons.devices_rounded),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                ),
                label: const Text(
                  'Войти через браузер',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              );

        return Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.colorScheme.surfaceContainerHighest,
                        theme.colorScheme.surface,
                      ],
                    ),
                  ),
                  child: Center(
                    child: Card(
                      elevation: 8,
                      child: Container(
                        width: 400,
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.music_note_rounded,
                              size: 64,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'YAYMA',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text(
                              'Вход через Яндекс',
                              style: TextStyle(color: Colors.white54),
                            ),
                            const SizedBox(height: 32),
                            if (showBrowserFirst) ...[
                              browserButton,
                              const SizedBox(height: 12),
                              webViewButton,
                            ] else ...[
                              webViewButton,
                              const SizedBox(height: 12),
                              browserButton,
                            ],
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Row(
                                children: [
                                  Expanded(child: Divider()),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: Text(
                                      'Или введите токен',
                                      style: TextStyle(
                                        color: Colors.white24,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  Expanded(child: Divider()),
                                ],
                              ),
                            ),
                            TextField(
                              controller: _tokenController,
                              decoration: InputDecoration(
                                labelText: 'Ссылка или OAuth токен',
                                hintText:
                                    'https://music.yandex.ru/#access_token=y0_...',
                                helperText:
                                    'Используйте это поле только если хотите ввести готовый OAuth токен вручную.',
                                border: const OutlineInputBorder(),
                                suffixIcon: IconButton(
                                  icon: const Icon(Icons.login_rounded),
                                  onPressed: () =>
                                      _handleLogin(_tokenController.text),
                                ),
                              ),
                              onSubmitted: _handleLogin,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (isCustomTitlebar)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SizedBox(
                    height: 32,
                    child: WindowCaption(
                      brightness: Brightness.dark,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class YandexLoginDialog extends StatefulWidget {
  const YandexLoginDialog({super.key});

  @override
  State<YandexLoginDialog> createState() => _YandexLoginDialogState();
}

class _YandexLoginDialogState extends State<YandexLoginDialog> {
  late final WebViewController _controller;
  bool _isFinalized = false;
  bool _isFetchingToken = false;
  static final _tokenRegExp = RegExp('access_token=(y0_[^&]+)');

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    unawaited(_controller.setJavaScriptMode(JavaScriptMode.unrestricted));
    unawaited(
      _controller.setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      ),
    );
    unawaited(
      _controller.setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) async {
            unawaited(_parseToken(url));
          },
          onUrlChange: (change) async {
            if (change.url != null) {
              unawaited(_parseToken(change.url!));
            }
          },
          onNavigationRequest: (request) async {
            return _parseToken(request.url);
          },
          onPageFinished: (url) async {
            unawaited(_parseToken(url));
            final currentUrl = await _controller.currentUrl();
            if (currentUrl != null) {
              unawaited(_parseToken(currentUrl));
            }
          },
        ),
      ),
    );
    unawaited(
      _controller.loadRequest(
        Uri.parse('https://passport.yandex.ru/pwl-yandex/auth/'),
      ),
    );
  }

  Future<NavigationDecision> _parseToken(String urlString) async {
    if (_isFinalized) return NavigationDecision.navigate;

    debugPrint('🌐 URL: $urlString');

    // 1. Intercept from URL (OAuth redirect)
    final match = _tokenRegExp.firstMatch(urlString);
    if (match != null) {
      final token = match.group(1);
      if (token != null) {
        await _handleFoundToken(token);
        return NavigationDecision.prevent;
      }
    }

    // 2. Fetch token if already in profile but not yet authorized
    if (!_isFetchingToken &&
        (urlString.startsWith('https://id.yandex.ru') ||
            urlString.startsWith('https://passport.yandex.ru/profile'))) {
      debugPrint('🔍 Authorized! Getting token via official desktop client...');
      _isFetchingToken = true;

      unawaited(
        _controller.loadRequest(
          Uri.parse(
            'https://oauth.yandex.ru/authorize?response_type=token&client_id=97fe03033fa34407ac9bcf91d5afed5b',
          ),
        ),
      );

      return NavigationDecision.prevent;
    }

    return NavigationDecision.navigate;
  }

  Future<void> _handleFoundToken(String token) async {
    if (_isFinalized) return;
    _isFinalized = true;
    await login(token);

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 1000,
        height: 800,
        child: Column(
          children: [
            Expanded(
              child: WebViewWidget(controller: _controller),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await WebViewCookieManager().clearCookies();
                      if (context.mounted) Navigator.pop(context);
                    },
                    icon: const Icon(
                      Icons.delete_sweep_rounded,
                      color: Colors.redAccent,
                    ),
                    label: const Text(
                      'СБРОСИТЬ БРАУЗЕР',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('ЗАКРЫТЬ'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class YandexDeviceLoginDialog extends StatefulWidget {
  const YandexDeviceLoginDialog({super.key});

  @override
  State<YandexDeviceLoginDialog> createState() =>
      _YandexDeviceLoginDialogState();
}

class _YandexDeviceLoginDialogState extends State<YandexDeviceLoginDialog> {
  String? _userCode;
  String? _deviceCode;
  String? _verificationUrl;
  int _interval = 5;
  Timer? _timer;
  bool _isLoading = true;
  String? _error;
  bool _isFinalized = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initDeviceFlow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _initDeviceFlow() async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('https://oauth.yandex.ru/device/code'),
      );
      request.headers.set('content-type', 'application/x-www-form-urlencoded');
      request.write('client_id=23cabbbdc6cd418abb4b39c32c41195d');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        setState(() {
          _userCode = data['user_code'] as String?;
          _deviceCode = data['device_code'] as String?;
          _verificationUrl = data['verification_url'] as String?;
          _interval = (data['interval'] as num?)?.toInt() ?? 5;
          _isLoading = false;
        });
        _startPolling();
      } else {
        setState(() {
          _error = 'Не удалось получить код устройства от Яндекс.';
          _isLoading = false;
        });
      }
    } on Object catch (e) {
      setState(() {
        _error = 'Ошибка сети: $e';
        _isLoading = false;
      });
    } finally {
      client.close();
    }
  }

  void _startPolling() {
    _timer = Timer.periodic(Duration(seconds: _interval), (timer) {
      unawaited(_pollToken());
    });
  }

  Future<void> _pollToken() async {
    if (_isFinalized || _deviceCode == null) return;

    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('https://oauth.yandex.ru/token'),
      );
      request.headers.set('content-type', 'application/x-www-form-urlencoded');
      request.write(
        'grant_type=device_code'
        '&client_id=23cabbbdc6cd418abb4b39c32c41195d'
        '&client_secret=53bc75238f0c4d08a118e51fe9203300'
        '&code=$_deviceCode',
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        final token = data['access_token'] as String?;
        if (token != null) {
          _timer?.cancel();
          await _handleFoundToken(token);
        }
      } else {
        final error = data['error'] as String?;
        if (error != 'authorization_pending') {
          _timer?.cancel();
          setState(() {
            _error =
                data['error_description'] as String? ??
                'Ошибка авторизации ($error).';
          });
        }
      }
    } on Object catch (e) {
      debugPrint('Error polling token: $e');
    } finally {
      client.close();
    }
  }

  Future<void> _handleFoundToken(String token) async {
    if (_isFinalized) return;
    _isFinalized = true;
    await login(token);

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _openBrowser() {
    final url = _verificationUrl ?? 'https://ya.ru/device';
    unawaited(
      () async {
        try {
          if (Platform.isWindows) {
            await Process.run('cmd', ['/c', 'start', '', url]);
          } else if (Platform.isMacOS) {
            await Process.run('open', [url]);
          } else if (Platform.isLinux) {
            await Process.run('xdg-open', [url]);
          }
        } on Object catch (e) {
          debugPrint('Error launching browser: $e');
        }
      }(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget content;
    if (_isLoading) {
      content = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Получение кода авторизации...'),
          ],
        ),
      );
    } else if (_error != null) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.redAccent,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _error = null;
                  });
                  unawaited(_initDeviceFlow());
                },
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Перейдите на страницу ya.ru/device и введите код подтверждения:',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            child: Text(
              _userCode ?? '',
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  if (_userCode != null) {
                    await Clipboard.setData(ClipboardData(text: _userCode!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Код скопирован в буфер обмена'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Копировать код'),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: _openBrowser,
                icon: const Icon(Icons.open_in_browser_rounded),
                label: const Text('Открыть ссылку'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text(
                'Ожидание ввода кода на сайте',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ],
      );
    }

    return Dialog(
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.devices_rounded,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Вход по коду устройства',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(height: 32),
            content,
          ],
        ),
      ),
    );
  }
}
