import 'package:yayma/src/rust/api/updates.dart' as updates;

typedef AppUpdateInfo = updates.AppUpdateInfoDto;

class UpdateService {
  static Future<AppUpdateInfo?> checkForUpdates() async {
    try {
      return await updates.checkForUpdates();
    } on Object {
      return null;
    }
  }
}
