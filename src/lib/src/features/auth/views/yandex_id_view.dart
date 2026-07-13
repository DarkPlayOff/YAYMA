import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';

class YandexIdView extends StatefulWidget {
  final bool fullscreen;

  const YandexIdView({super.key, this.fullscreen = false});

  @override
  State<YandexIdView> createState() => _YandexIdViewState();
}

class _YandexIdViewState extends State<YandexIdView> {
  late final WebViewController _controller;
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    unawaited(_controller.setJavaScriptMode(JavaScriptMode.unrestricted));
    unawaited(_controller.setBackgroundColor(Colors.transparent));
    unawaited(
      _controller.setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      ),
    );
    unawaited(_controller.loadRequest(Uri.parse('https://id.yandex.ru')));

    // Delay WebView initialization to wait for the transition animation to finish.
    // This prevents "Setting webview bounds failed" error on Windows.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 450), () {
        if (mounted) {
          setState(() {
            _isReady = true;
          });
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (widget.fullscreen) {
      return Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: const Text('Управление аккаунтом'),
        ),
        body: WebViewWidget(controller: _controller),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: WebViewWidget(controller: _controller),
    );
  }
}
