/// Public DNS hosts and their fixed (anycast) IPs, IPv4 first. A DNS server given by one of
/// these names needs no lookup: its IPs go to the config's DNS hosts. Checked against the
/// names' A / AAAA records; geo-steered names (NextDNS, DNS.SB's doh.dns.sb…) are left out,
/// since their IPs depend on where they're looked up.
const publicDnsIps = <String, List<String>>{
  // Google
  'dns.google': ['8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'],
  'dns.google.com': ['8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'],

  // Cloudflare: standard, malware blocking (security), malware + adult blocking (family)
  'cloudflare-dns.com': ['104.16.248.249', '104.16.249.249', '2606:4700::6810:f8f9', '2606:4700::6810:f9f9'],
  'one.one.one.one': ['1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'],
  '1dot1dot1dot1.cloudflare-dns.com': ['1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'],
  'security.cloudflare-dns.com': ['1.1.1.2', '1.0.0.2', '2606:4700:4700::1112', '2606:4700:4700::1002'],
  'family.cloudflare-dns.com': ['1.1.1.3', '1.0.0.3', '2606:4700:4700::1113', '2606:4700:4700::1003'],
  'mozilla.cloudflare-dns.com': ['162.159.61.4', '172.64.41.4', '2803:f800:53::4', '2a06:98c1:52::4'],

  // Quad9: malware blocking (dns / dns9), unsecured (dns10), with ECS (dns11), ECS unsecured (dns12)
  'dns.quad9.net': ['9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'],
  'dns9.quad9.net': ['9.9.9.9', '149.112.112.9', '2620:fe::fe:9', '2620:fe::9'],
  'dns10.quad9.net': ['9.9.9.10', '149.112.112.10', '2620:fe::10', '2620:fe::fe:10'],
  'dns11.quad9.net': ['9.9.9.11', '149.112.112.11', '2620:fe::11', '2620:fe::fe:11'],
  'dns12.quad9.net': ['9.9.9.12', '149.112.112.12', '2620:fe::12', '2620:fe::fe:12'],

  // AdGuard: ad blocking (dns), none (unfiltered), ads + adult (family); the old adguard.com names
  'dns.adguard-dns.com': ['94.140.14.14', '94.140.15.15', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'],
  'unfiltered.adguard-dns.com': ['94.140.14.140', '94.140.14.141', '2a10:50c0::1:ff', '2a10:50c0::2:ff'],
  'family.adguard-dns.com': ['94.140.14.15', '94.140.15.16', '2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff'],
  'dns.adguard.com': ['94.140.14.14', '94.140.15.15', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'],
  'dns-unfiltered.adguard.com': ['94.140.14.140', '94.140.14.141', '2a10:50c0::1:ff', '2a10:50c0::2:ff'],
  'dns-family.adguard.com': ['94.140.14.15', '94.140.15.16', '2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff'],

  // OpenDNS (Cisco): standard, FamilyShield, Sandbox
  'doh.opendns.com': ['146.112.41.2', '2620:119:fc::2'],
  'doh.familyshield.opendns.com': ['146.112.41.3', '2620:119:fc::3'],
  'doh.sandbox.opendns.com': ['146.112.41.4', '2620:119:fc::4'],

  // CleanBrowsing (its filters are paths on this host)
  'doh.cleanbrowsing.org': ['185.228.168.10', '185.228.168.168'],

  // Mullvad: none (dns), ads, base, extended, family, all
  'dns.mullvad.net': ['194.242.2.2', '2a07:e340::2'],
  'doh.mullvad.net': ['194.242.2.2', '2a07:e340::2'],
  'adblock.dns.mullvad.net': ['194.242.2.3', '2a07:e340::3'],
  'base.dns.mullvad.net': ['194.242.2.4', '2a07:e340::4'],
  'extended.dns.mullvad.net': ['194.242.2.5', '2a07:e340::5'],
  'family.dns.mullvad.net': ['194.242.2.6', '2a07:e340::6'],
  'all.dns.mullvad.net': ['194.242.2.9', '2a07:e340::9'],

  // Control D (its free filters are paths on this host)
  'freedns.controld.com': ['76.76.2.11', '2606:1a40::11'],

  // DNS.SB (doh.dns.sb is geo-steered: not here)
  'doh.sb': ['185.222.222.222', '45.11.45.11', '2a09::', '2a11::'],

  // Yandex: standard, safe, family
  'common.dot.dns.yandex.net': ['77.88.8.8', '77.88.8.1', '2a02:6b8::feed:ff', '2a02:6b8:0:1::feed:ff'],
  'safe.dot.dns.yandex.net': ['77.88.8.88', '77.88.8.2', '2a02:6b8::feed:bad', '2a02:6b8:0:1::feed:bad'],
  'family.dot.dns.yandex.net': ['77.88.8.7', '77.88.8.3', '2a02:6b8::feed:a11', '2a02:6b8:0:1::feed:a11'],

  // Alibaba, Tencent (DNSPod), 360
  'dns.alidns.com': ['223.5.5.5', '223.6.6.6', '2400:3200::1', '2400:3200:baba::1'],
  'doh.pub': ['1.12.12.12', '120.53.53.53'],
  'dns.pub': ['1.12.12.12', '120.53.53.53'],
  'doh.360.cn': ['101.198.192.33', '101.198.193.29'],

  // Others
  'dns.surfsharkdns.com': ['194.169.169.169', '2a09:a707:169::'],
  'dns.twnic.tw': ['101.101.101.101', '2001:de4::101', '2001:de4::102'],
  'public.dns.iij.jp': ['103.2.57.5', '103.2.57.6', '2001:300::5', '2001:300::6'],
  'dns.switch.ch': ['130.59.31.248', '130.59.31.251', '2001:620:0:ff::2', '2001:620:0:ff::3'],
  'dns.digitale-gesellschaft.ch': ['185.95.218.42', '185.95.218.43', '2a05:fc84::42', '2a05:fc84::43'],
  'dns.njal.la': ['95.215.19.53', '2001:67c:2354:2::53'],
  'doh.libredns.gr': ['116.202.176.26', '2a01:4f8:1c0c:8274::1'],
  'doh.applied-privacy.net': ['146.255.56.98', '2a02:1b8:10:234::2'],
  'dns.brahma.world': ['157.90.124.62', '2a01:4f8:1c1c:f5e1::1'],
  'dns.aa.net.uk': ['217.169.20.22', '217.169.20.23', '2001:8b0::2022', '2001:8b0::2023'],
};

/// The host of a DNS server: https://host/dns-query, tcp://host:53, or a bare address.
String dnsHostOf(String server) {
  final uri = Uri.tryParse(server);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) return uri.host;
  return server.split(':').first;
}
