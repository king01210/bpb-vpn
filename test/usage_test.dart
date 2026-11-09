import 'dart:convert';

import 'package:bpb/services/cloudflare_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _token = 'cfut_Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56Qr78St90Uv12Wx34';

void main() {
  test('sums account and worker requests from the GraphQL response', () async {
    late Map<String, dynamic> sent;
    final api = CloudflareApi(
      _token,
      client: MockClient((req) async {
        expect(req.url.path, endsWith('/graphql'));
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'data': {
              'viewer': {
                'accounts': [
                  {
                    'total': [
                      {
                        'sum': {'requests': 1200},
                      },
                      {
                        'sum': {'requests': 34},
                      },
                    ],
                    'worker': [
                      {
                        'sum': {'requests': 500},
                      },
                    ],
                  },
                ],
              },
            },
            'errors': null,
          }),
          200,
        );
      }),
    );
    final usage = await api.workerUsage('acc', 'edge');
    expect(usage.total, 1234);
    expect(usage.worker, 500);
    expect(sent['variables']['scriptName'], 'edge');
    // Cloudflare's GraphQL API rejects directives such as @include.
    expect(sent['query'], isNot(contains('@')));
  });

  test('surfaces GraphQL errors', () async {
    final denied = CloudflareApi(
      _token,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': null,
            'errors': [
              {'message': 'not authorized'},
            ],
          }),
          200,
        ),
      ),
    );
    expect(
      denied.workerUsage('acc', 'edge'),
      throwsA(isA<CloudflareException>().having((e) => e.message, 'message', contains('not authorized'))),
    );
  });
}
