import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'masque.dart';
import 'warp.dart';

/// A [StateError] for the UI whose cause is a network failure (see [isNetworkError]).
class NetworkStateError extends StateError {
  NetworkStateError(super.message);
}

/// Whether [e] means the server couldn't be reached (blocked, timed out, reset), rather than
/// that it answered with an error: only then may another route (e.g. Tor) help.
bool isNetworkError(Object e) => switch (e) {
  NetworkStateError() => true,
  WarpException(:final network) => network,
  MasqueException(:final network) => network,
  SocketException() || TimeoutException() || HandshakeException() || TlsException() => true,
  HttpException() || http.ClientException() => true,
  _ => false,
};
