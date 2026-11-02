import 'package:yayma/src/rust/api/simple.dart' as simple;

/// Log levels matching the Rust `log_from_dart` mapping
/// (0=debug, 1=info, 2=warn, 3=error).
enum AppLogLevel { debug, info, warn, error }

/// Forwards a Dart-side message into the Rust tracing pipeline so it lands
/// in the same rotated file log. Fire-and-forget and never throws: logging
/// must not become a failure source of its own.
void appLog(AppLogLevel level, String message) {
  // Single line so entries stay greppable in the file log.
  final line = message.replaceAll('\r', ' ').replaceAll('\n', ' ');
  try {
    // There is no init flag for RustLib; a call before init() throws and is
    // swallowed below like any other logging failure.
    simple.logFromDart(level: level.index, message: line).ignore();
  } on Object catch (_) {}
}
