import 'dart:io';

import 'package:share_plus/share_plus.dart';

import '../../core/failures.dart';
import '../../core/result.dart';

class ShareService {
  Future<Result<void>> sharePdf(File file, {String? subject}) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          subject: subject,
        ),
      );
      return const Success(null);
    } catch (e) {
      return Failure(
          UnexpectedFailure('Nie udało się udostępnić dokumentu.', cause: e));
    }
  }
}
