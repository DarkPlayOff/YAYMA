import 'dart:async';

import 'package:flutter/material.dart';
import 'package:m3e_collection/m3e_collection.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/rust/api/auth.dart' as rust;
import 'package:yayma/src/rust/api/playback.dart' as rust_playback;
import 'package:yayma/src/ui/layout.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';

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
                    await rust_playback.restoreAndPlay(
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
      loading: () => Scaffold(
        body: Center(
          child: Transform.scale(
            scale: 1.5,
            child: const LoadingIndicatorM3E(),
          ),
        ),
      ),
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
  bool _isLoading = false;

  Future<void> _showWebView() async {
    setState(() => _isLoading = true);
    try {
      final token = await rust.loginViaWebview();
      if (token.isNotEmpty) {
        unawaited(login(token));
      }
    } catch (e) {
      debugPrint('Login failed or cancelled: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка входа: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
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
              child: AnimatedSize(
                duration: const Duration(milliseconds: 300),
                child: _isLoading
                    ? SizedBox(
                        height: 300,
                        child: Center(
                          child: Transform.scale(
                            scale: 2.0,
                            child: const LoadingIndicatorM3E(),
                          ),
                        ),
                      )
                    : Column(
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
                                fontSize: 32, fontWeight: FontWeight.bold),
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
                              backgroundColor:
                                  Theme.of(context).colorScheme.primary,
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
                              hintText:
                                  'https://music.yandex.ru/#access_token=y0_...',
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
    );
  }
}
