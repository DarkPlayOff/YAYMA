import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';
import 'package:yayma/src/providers/navigation_provider.dart';

class YandexIdView extends StatefulWidget {
  const YandexIdView({super.key});

  @override
  State<YandexIdView> createState() => _YandexIdViewState();
}

class _YandexIdViewState extends State<YandexIdView> {
  late final WebViewController _controller;
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      )
      ..loadRequest(Uri.parse('https://id.yandex.ru'));

    // Задержка инициализации WebView, чтобы дождаться окончания анимации перехода
    // Это предотвращает ошибку "Setting webview bounds failed" на Windows
    Future.delayed(const Duration(milliseconds: 450), () {
      if (mounted) {
        setState(() {
          _isReady = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Column(
        children: [
          AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leadingWidth: 150,
            leading: Row(
              children: [
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => setSection(AppSection.home),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                  onPressed: () {
                    unawaited(() async {
                      if (await _controller.canGoBack()) {
                        await _controller.goBack();
                      }
                    }());
                  },
                ),
                IconButton(
                  icon: const Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                  onPressed: () {
                    unawaited(() async {
                      if (await _controller.canGoForward()) {
                        await _controller.goForward();
                      }
                    }());
                  },
                ),
              ],
            ),
            title: const Text(
              'Яндекс ID',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          Expanded(
            child: _isReady
                ? ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    child: WebViewWidget(controller: _controller),
                  )
                : const Center(
                    child: CircularProgressIndicator(),
                  ),
          ),
        ],
      ),
    );
  }
}
