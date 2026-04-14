import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:webview_all/webview_all.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/rust/api/auth.dart' as rust;
import 'package:yayma/src/rust/api/playback.dart' as rust;
import 'package:yayma/src/ui/layout.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  bool _hasLoadedState = false;

  @override
  Widget build(BuildContext context) {
    final authState = authSignal.watch(context);

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

  void _handleLogin(String val) {
    var token = val.trim();
    final match = RegExp('access_token=([^&]+)').firstMatch(token);
    if (match != null) {
      token = match.group(1)!;
    }
    if (token.isNotEmpty) {
      unawaited(login(token));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Container(
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
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'Вход через Яндекс',
                    style: TextStyle(color: Colors.white54),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: _showWebView,
                    icon: const Icon(Icons.open_in_browser_rounded),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 56),
                    ),
                    label: const Text(
                      'ОТКРЫТЬ ОКНО ВХОДА',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Row(
                      children: [
                        Expanded(child: Divider()),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'ИЛИ ВВЕДИТЕ ТОКЕН',
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
                      hintText: 'https://music.yandex.ru/#access_token=y0_...',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.login_rounded),
                        onPressed: () => _handleLogin(_tokenController.text),
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
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: _parseToken,
          onUrlChange: (change) {
            if (change.url != null) {
              _parseToken(change.url!);
            }
          },
          onNavigationRequest: (request) {
            _parseToken(request.url);
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse('https://passport.yandex.ru/pwl-yandex/auth/'));
  }

  Future<void> _parseToken(String urlString) async {
    if (_isFinalized) return;

    // 1. ПЕРЕХВАТ ИЗ URL (OAuth редирект)
    final match = _tokenRegExp.firstMatch(urlString);
    if (match != null) {
      final token = match.group(1);
      if (token != null) {
        await _handleFoundToken(token);
        return;
      }
    }

    // 2. ЕСЛИ В ПРОФИЛЕ И ЕЩЕ НЕ ПОШЛИ ЗА ТОКЕНОМ - ИДЕМ ЗА ТОКЕНОМ
    if (!_isFetchingToken &&
        (urlString.startsWith('https://id.yandex.ru') ||
            urlString.startsWith('https://passport.yandex.ru/profile'))) {
      debugPrint('🔍 Authorized! Getting token via official desktop client...');
      _isFetchingToken = true;

      await _controller.loadRequest(
        Uri.parse(
          'https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d',
        ),
      );
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 1000,
        height: 800,
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12),
                ),
                child: WebViewWidget(controller: _controller),
              ),
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
