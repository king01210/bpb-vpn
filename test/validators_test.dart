import 'package:bpb/ui/prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('IPv6 as Xray reads it: bare without a port, [IPv6] with one', () {
    // No port (clean IPs, CDN addresses, routing rules, DNS): bare only.
    expect(validateHost('2606:4700::1'), isNull);
    expect(validateHost('[2606:4700::1]'), isNotNull);
    expect(validateIpOrCidr('2001:db8::/32'), isNull);
    expect(validateIpOrCidr('[2001:db8::1]'), isNotNull);
    expect(validateIpOrCidr('10.0.0.1'), isNull);
    expect(validateIpOrCidr('example.ir'), isNotNull);
    expect(validateIp('2606:4700::1111'), isNull);

    // Proxy IPs: port optional, IPv6 always in brackets (a bare "IPv6:port" would be ambiguous).
    expect(validateHostPort('[2606:4700::1]'), isNull);
    expect(validateHostPort('[2606:4700::1]:443'), isNull);
    expect(validateHostPort('2606:4700::1'), isNotNull);
    expect(validateHostPort('proxy.example.com'), isNull);
    expect(validateHostPort('proxy.example.com:443'), isNull);
    expect(validateHostPort('1.2.3.4:8443'), isNull);

    // WARP endpoints / upstream proxy: port required.
    expect(validateEndpoint('162.159.192.1:2408'), isNull);
    expect(validateEndpoint('[2606:4700:d0::a29f:c001]:2408'), isNull);
    expect(validateEndpoint('engage.cloudflareclient.com:2408'), isNull);
    expect(validateEndpoint('162.159.192.1'), isNotNull);
    expect(validateEndpoint('[2606:4700:d0::a29f:c001]'), isNotNull);
    expect(validateEndpoint('2606:4700:d0::a29f:c001:2408'), isNotNull);
    expect(validateEndpoint('1.2.3.4:70000'), isNotNull);
  });

  test('DNS fields as in BPB panel', () {
    // Remote DNS: TCP / DoH URLs, not Cloudflare's; no DoT (Xray's DNS has none).
    expect(validateRemoteDns('https://8.8.8.8/dns-query'), isNull); // the default
    expect(validateRemoteDns('tls://dns.google'), isNotNull);
    expect(validateRemoteDns('tcp://8.8.8.8'), isNull);
    expect(validateRemoteDns('8.8.8.8'), isNotNull);
    expect(validateRemoteDns('quic://dns.adguard.com'), isNotNull);
    expect(validateRemoteDns('https://1.1.1.1/dns-query'), isNotNull);
    expect(validateRemoteDns('https://cloudflare-dns.com/dns-query'), isNotNull);
    // DoH needs its /dns-query path; TCP takes a domain or IP host and no path.
    expect(validateRemoteDns('https://dns.google/dns-query'), isNull);
    expect(validateRemoteDns('https://[2001:4860:4860::8888]/dns-query'), isNull);
    expect(validateRemoteDns('https://dns.google:8443/dns-query'), isNull);
    expect(validateRemoteDns('https://dns.google'), isNotNull);
    expect(validateRemoteDns('https://dns.google/resolve'), isNotNull);
    expect(validateRemoteDns('tcp://dns.google'), isNull);
    expect(validateRemoteDns('tcp://8.8.8.8:53'), isNull);
    expect(validateRemoteDns('tls://8.8.8.8'), isNotNull);
    expect(validateRemoteDns('tcp://dns.google/dns-query'), isNotNull);
    expect(validateRemoteDns('tcp://not_a_host'), isNotNull);
    expect(validateRemoteDns('https://user@dns.google/dns-query'), isNotNull);
    expect(validateRemoteDns('https://dns.google/dns-query?x=1'), isNotNull);

    // Anti-sanction: an IP, TCP, QUIC (DoQ) or DoH.
    expect(validateSanctionDns('178.22.122.100'), isNull); // the default
    expect(validateSanctionDns('2001:db8::1'), isNull);
    expect(validateSanctionDns('https://dns.403.online/dns-query'), isNull);
    expect(validateSanctionDns('https://8.8.8.8/dns-query'), isNull);
    expect(validateSanctionDns('dns.403.online'), isNotNull); // a bare domain
    expect(validateSanctionDns('tls://dns.403.online'), isNotNull);
    expect(validateSanctionDns('tcp://8.8.8.8'), isNull);
    expect(validateSanctionDns('tcp://dns.403.online:53'), isNull);
    expect(validateSanctionDns('quic://dns.adguard-dns.com'), isNull);
    expect(validateSanctionDns('quic://dns.adguard-dns.com/dns-query'), isNotNull); // no path
    expect(validateSanctionDns('udp://8.8.8.8'), isNotNull);
    // DoH must be standard: a path ending in /dns-query.
    expect(validateSanctionDns('https://dns.403.online'), isNotNull);
    expect(validateSanctionDns('https://8.8.8.8'), isNotNull);
    expect(validateSanctionDns('https://dns.403.online/resolve'), isNotNull);
    expect(validateSanctionDns('https://dns.example/custom/dns-query'), isNull);

    // ECH: an IP, or DoH with an IP host (v4 or v6).
    expect(validateEchDns('8.8.8.8'), isNull);
    expect(validateEchDns('2001:4860:4860::8888'), isNull);
    expect(validateEchDns('https://8.8.8.8/dns-query'), isNull);
    expect(validateEchDns('https://[2001:4860:4860::8888]/dns-query'), isNull);
    expect(validateEchDns('https://dns.google/dns-query'), isNotNull);
    expect(validateEchDns('tls://8.8.8.8'), isNotNull);
    expect(validateEchDns('https://8.8.8.8'), isNotNull); // not a standard DoH
    expect(validateEchDns('https://8.8.8.8/'), isNotNull);
    expect(validateEchDns('https://8.8.8.8/dns-query?x=1'), isNotNull);

    // Domain names (used by routing rules).
    expect(validateDomain('cloudflare-ech.com'), isNull);
    expect(validateDomain('8.8.8.8'), isNotNull);
    expect(validateDomain('not a domain'), isNotNull);

    // WARP / MASQUE (through the tunnel): an IP, TCP or DoH; no QUIC (Xray's DoQ is local only).
    expect(validateTunnelDns('1.1.1.1'), isNull); // the default
    expect(validateTunnelDns('2606:4700:4700::1111'), isNull);
    expect(validateTunnelDns('https://1.1.1.1/dns-query'), isNull);
    expect(validateTunnelDns('https://dns.google/dns-query'), isNull);
    expect(validateTunnelDns('tcp://8.8.8.8'), isNull);
    expect(validateTunnelDns('tcp://dns.google:53'), isNull);
    expect(validateTunnelDns('quic://dns.adguard-dns.com'), isNotNull);
    expect(validateTunnelDns('tls://dns.google'), isNotNull);
    expect(validateTunnelDns('https://dns.google'), isNotNull);
  });

  test('local DNS: localhost, an IP or tcp://IP', () {
    expect(validateLocalDns('localhost'), isNull);
    expect(validateLocalDns('8.8.8.8'), isNull);
    expect(validateLocalDns('2001:4860:4860::8888'), isNull);
    expect(validateLocalDns('tcp://8.8.8.8'), isNull);
    expect(validateLocalDns('tcp://8.8.8.8:53'), isNull);
    expect(validateLocalDns('tcp://[2001:4860:4860::8888]:53'), isNull);
    expect(validateLocalDns('tcp://dns.google'), isNotNull); // IPs only
    expect(validateLocalDns('https://8.8.8.8/dns-query'), isNotNull);
    expect(validateLocalDns('udp://8.8.8.8'), isNotNull);
    expect(validateLocalDns('dns.google'), isNotNull);
  });
}
