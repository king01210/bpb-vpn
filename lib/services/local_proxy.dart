import 'dart:io';

/// The local SOCKS/HTTP proxy (Xray's mixed inbound, see XrayConfigBuilder). The app
/// is excluded from the VPN, so its own requests reach the internet through this.
class LocalProxy {
  static const port = 10808;

  /// Set while LAN connections are allowed with a username and password: then every
  /// client, the app included, must log in.
  static ({String user, String pass})? credentials;

  /// Dart's proxy setting for the local proxy. Credentials go in this string because
  /// that's the only place Dart reads them for HTTPS (CONNECT) requests.
  static String get proxyString {
    final c = credentials;
    final auth = c == null ? '' : '${c.user}:${c.pass}@';
    return 'PROXY ${auth}127.0.0.1:$port';
  }

  /// Points [client] at the local proxy, or at another HTTP proxy on this phone ([port], e.g.
  /// the setup wizard's Tor), which takes no login.
  static void apply(HttpClient client, {int port = port}) {
    final proxy = port == LocalProxy.port ? proxyString : 'PROXY 127.0.0.1:$port';
    client.findProxy = (_) => proxy;
  }
}
