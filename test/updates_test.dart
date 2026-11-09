import 'dart:convert';

import 'package:bpb/services/updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response release(String tag) => http.Response(
  jsonEncode({
    'tag_name': tag,
    'body': 'Fixes',
    'html_url': 'https://github.com/bia-pain-bache/BPB-VPN/releases/tag/$tag',
    'assets': [
      for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64'])
        {
          'name': 'bpb-${tag.substring(1)}-$abi.apk',
          'browser_download_url': 'https://github.com/x/releases/download/$tag/bpb-${tag.substring(1)}-$abi.apk',
        },
      {'name': 'SHA256SUMS', 'browser_download_url': 'https://github.com/x/SHA256SUMS'},
    ],
  }),
  200,
);

void main() {
  test('versions compare numerically; build numbers and pre-release tags are ignored', () {
    expect(compareVersions('1.0.10', '1.0.9'), greaterThan(0));
    expect(compareVersions('1.2.0', '1.10.0'), lessThan(0));
    expect(compareVersions('1.0.0+5', '1.0.0'), 0);
    expect(compareVersions('1.0', '1.0.0'), 0);
  });

  test('a newer release: its notes, and the APK for the first ABI it has', () async {
    final client = MockClient((req) async {
      expect(req.url.toString(), 'https://api.github.com/repos/bia-pain-bache/BPB-VPN/releases/latest');
      return release('v1.1.0');
    });
    final update = await UpdateChecker(client).check(installed: '1.0.0', abis: ['riscv64', 'armeabi-v7a']);
    expect(update!.version, '1.1.0');
    expect(update.notes, 'Fixes');
    expect(update.apkUrl, endsWith('/bpb-1.1.0-armeabi-v7a.apk'));
  });

  test('no update when the latest is this version (or older)', () async {
    expect(
      await UpdateChecker(MockClient((_) async => release('v1.0.0'))).check(installed: '1.0.0', abis: ['arm64-v8a']),
      isNull,
    );
  });

  test('a 404 is not reported as up to date', () async {
    expect(
      UpdateChecker(MockClient((_) async => http.Response('{}', 404)))
          .check(installed: '1.0.0', abis: []),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('update status is unknown'),
        ),
      ),
    );
  });
}
