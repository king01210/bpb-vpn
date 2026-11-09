import 'dart:async';
import 'dart:io';

import 'package:bpb/models/cf_account.dart';
import 'package:bpb/models/settings.dart';
import 'package:bpb/services/masque.dart';
import 'package:bpb/services/net_errors.dart';
import 'package:bpb/services/warp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an account is used only with both Workers and Pages; a deployment adds or replaces', () {
    const workers = Deployment(type: WorkerType.workers, name: 'wk', host: 'wk.me.workers.dev', version: 1);
    const pages = Deployment(type: WorkerType.pages, name: 'pg', host: 'pg.pages.dev', version: 1);
    const a = SavedCfAccount(id: 'acc', name: 'Mine', token: 't', uuid: 'u', deployments: [pages]);
    expect(a.isComplete, isFalse);
    final both = a.withAdded(workers);
    expect(both.isComplete, isTrue);
    expect(both.deployments.map((d) => d.type), [WorkerType.workers, WorkerType.pages]); // Workers first.
    final redeployed = both.withAdded(const Deployment(type: WorkerType.pages, name: 'pg2', host: 'h', version: 1));
    expect(redeployed.deployments.map((d) => d.name), ['wk', 'pg2']);
  });

  test('setup done survives the device settings JSON', () {
    expect(const DeviceSettings().setupDone, isFalse);
    expect(DeviceSettings.fromJson(const DeviceSettings().updated('setupDone', true).toJson()).setupDone, isTrue);
  });

  test('only unreachable servers count as network errors (Tor may help), not refusals', () {
    expect(isNetworkError(const SocketException('reset')), isTrue);
    expect(isNetworkError(TimeoutException('slow')), isTrue);
    expect(isNetworkError(const WarpException('x', network: true)), isTrue);
    expect(isNetworkError(const MasqueException('x', network: true)), isTrue);
    expect(isNetworkError(NetworkStateError("Can't reach Cloudflare")), isTrue);
    expect(isNetworkError(const WarpException('WARP registration failed (HTTP 429)')), isFalse);
    expect(isNetworkError(StateError('Invalid API token')), isFalse);
  });
}
