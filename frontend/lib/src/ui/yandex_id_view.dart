import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:yayma/src/providers/navigation_provider.dart';

class YandexIdView extends StatefulWidget {
  const YandexIdView({super.key});

  @override
  State<YandexIdView> createState() => _YandexIdViewState();
}

class _YandexIdViewState extends State<YandexIdView> {
  InAppWebViewController? _webViewController;

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
                      if (await _webViewController?.canGoBack() ?? false) {
                        await _webViewController?.goBack();
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
                      if (await _webViewController?.canGoForward() ?? false) {
                        await _webViewController?.goForward();
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
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              child: InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri('https://id.yandex.ru'),
                ),
                initialSettings: InAppWebViewSettings(
                  transparentBackground: true,
                  supportZoom: false,
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
