import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:signals_flutter/signals_flutter.dart';
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
            unawaited(Future.microtask(() {
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
            }));
          }
          return const AppLayout();
        }
        return const LoginScreen();
      },
      error: (dynamic e, dynamic _) => Scaffold(body: Center(child: Text('Ошибка: $e'))),
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
    unawaited(showDialog<void>(
      context: context,
      builder: (context) => const YandexLoginDialog(),
    ));
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
                  ElevatedButton(
                    onPressed: _showWebView,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 56),
                    ),
                    child: const Text(
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
                            'ИЛИ',
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
                      labelText: 'Вставить OAuth токен',
                      hintText: 'y0_AgAAA...',
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

  void _handleLogin(String val) {
    if (val.trim().isNotEmpty) {
      unawaited(login(val.trim()));
    }
  }
}

class YandexLoginDialog extends StatefulWidget {
  const YandexLoginDialog({super.key});

  @override
  State<YandexLoginDialog> createState() => _YandexLoginDialogState();
}

class _YandexLoginDialogState extends State<YandexLoginDialog> {
  InAppWebViewController? _webViewController;
  bool _isFinalized = false;
  bool _isFetchingToken = false;

  static final _tokenRegExp = RegExp('access_token=(y0_[^&]+)');

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
                child: InAppWebView(
                  initialUrlRequest: URLRequest(
                    url: WebUri(
                      'https://passport.yandex.ru/pwl-yandex/auth/',
                    ),
                  ),
                  initialSettings: InAppWebViewSettings(
                    userAgent:
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
                    preferredContentMode: UserPreferredContentMode.DESKTOP,
                  ),
                  onWebViewCreated: (controller) =>
                      _webViewController = controller,
                  onLoadStop: (controller, url) => unawaited(_parseToken(url)),
                  onUpdateVisitedHistory: (c, url, _) => unawaited(_parseToken(url)),
                  onPermissionRequest: (c, r) async => PermissionResponse(
                    resources: r.resources,
                    action: PermissionResponseAction.GRANT,
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await CookieManager.instance().deleteAllCookies();
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

  Future<void> _parseToken(WebUri? url) async {
    if (url == null || _isFinalized) return;
    final urlString = url.toString();

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

      await _webViewController?.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(
            'https://oauth.yandex.ru/authorize?response_type=token&client_id=97fe03033fa34407ac9bcf91d5afed5b',
          ),
        ),
      );
    }
  }

  Future<void> _handleFoundToken(String token) async {
    if (_isFinalized) return;
    _isFinalized = true;
    await login(token);

    if (_webViewController != null) {
      await _webViewController?.stopLoading();
    }

    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}
