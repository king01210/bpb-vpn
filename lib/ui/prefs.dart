import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/settings.dart';
import '../state/app_state.dart';
import 'chip_menu.dart';
import 'theme.dart';

typedef Validator = String? Function(String value);

// Setting widgets take a path into the settings: "vless.enableTcpFastOpen" (profile)
// or "device.mtu" (this device), read and written through AppState.read/write.

// region validators

final _domainRegex = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
  caseSensitive: false,
);

bool isDomain(String v) => _domainRegex.hasMatch(v);

// The app sends the proxy login as "user:pass@" in Dart's proxy string, so ':' can't be in
// the username and neither field can contain ';' (the list separator) or outer spaces.
String? validateProxyUsername(String v) {
  if (v.contains(':') || v.contains(';')) return "Can't contain : or ;";
  if (v.trim() != v) return "Can't start or end with a space";
  return null;
}

String? validateProxyPassword(String v) {
  if (v.contains(';')) return "Can't contain ;";
  if (v.trim() != v) return "Can't start or end with a space";
  return null;
}

// IPv6 is written as Xray reads it: bare where there's no port (clean IPs, CDN addresses,
// routing rules, DNS), in brackets where there can be one (WARP endpoints, proxy IPs).

/// A bare IPv4 or IPv6 address (no brackets).
bool isIp(String v) => InternetAddress.tryParse(v) != null;

bool isCidr(String v) {
  final parts = v.split('/');
  if (parts.length != 2) return false;
  final bits = int.tryParse(parts[1]);
  final addr = InternetAddress.tryParse(parts[0]);
  if (addr == null || bits == null) return false;
  return bits >= 0 &&
      bits <= (addr.type == InternetAddressType.IPv4 ? 32 : 128);
}

String? validateHost(String v) =>
    isDomain(v) || isIp(v) ? null : 'Enter a domain or IP';

/// Domain name used in routing rules.
String? validateDomain(String v) => isDomain(v) ? null : 'Enter a domain';

/// A standard DoH URL (BPB's validateDoH): https, with a path ending in /dns-query.
bool _isDoh(Uri? uri) =>
    uri != null &&
    uri.scheme == 'https' &&
    uri.path.endsWith('/dns-query') &&
    !uri.hasQuery &&
    !uri.hasFragment;

/// A DNS server URL with one of [schemes]: a standard DoH (https), or tcp:// / quic:// with no
/// path; the host a domain or IP (IPv6 in brackets), with an optional port.
bool _isDnsUrl(String v, Set<String> schemes) {
  final uri = Uri.tryParse(v);
  if (uri == null || !schemes.contains(uri.scheme) || uri.host.isEmpty) {
    return false;
  }
  if (!isDomain(uri.host) && !isIp(uri.host)) return false;
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return false;
  return uri.scheme == 'https'
      ? _isDoh(uri)
      : uri.path.isEmpty || uri.path == '/';
}

/// A plain IPv4 or IPv6 address (no port, no brackets).
/// Local DNS: "localhost" (the system resolver), an IP (UDP DNS) or tcp://IP, with an optional
/// port (BPB's validateLocalDNS plus TCP; IPs only, so it never needs DNS itself).
String? validateLocalDns(String v) =>
    v == 'localhost' ||
        isIp(v) ||
        _isDnsUrl(v, const {'tcp'}) && isIp(Uri.parse(v).host)
    ? null
    : 'Use an IP, tcp://IP or localhost';

/// ECH DNS (BPB's validateEchDNS, IPv6 allowed too): an IP (IPv4 or bare IPv6), or exactly
/// https://IP/dns-query or https://[IPv6]/dns-query.
String? validateEchDns(String v) {
  if (isIp(v)) return null;
  final uri = Uri.tryParse(v);
  final isDoh =
      _isDoh(uri) &&
      uri!.path == '/dns-query' &&
      !uri.hasPort &&
      isIp(uri.host);
  return isDoh ? null : 'Use an IP or a DoH like https://IP/dns-query';
}

String? validateIp(String v) => InternetAddress.tryParse(v) != null
    ? null
    : 'Enter an IP address, e.g. 8.8.8.8';

/// Routing rules' IPs (BPB: isIPv4CIDR / isIPv6CIDR): an IP, or a CIDR range.
String? validateIpOrCidr(String v) =>
    isIp(v) || isCidr(v) ? null : 'Enter an IP or CIDR';

String? validateBridge(String v) => TorSettings.isBridge(v)
    ? null
    : 'Not a ${TorSettings.transports.join(' / ')} bridge line';

/// host, host:port, [IPv6] or [IPv6]:port (proxy IPs); with [requirePort] only the forms with a
/// port (WARP endpoints, upstream proxy). IPv6 always in brackets here.
String? validateHostPort(String v, {bool requirePort = false}) {
  final match = RegExp(r'^(?:\[([^\]]+)\]|([^:\[\]]+))(?::(\d{1,5}))?$')
      .firstMatch(v);
  final usage = requirePort
      ? 'Use domain:port, IPv4:port, or [IPv6]:port'
      : 'Use a domain, IPv4 or [IPv6] with or without :port';
  if (match == null) return usage;
  final port = match.group(3);
  if (port == null && requirePort) return usage;
  if (port != null && (int.parse(port) < 1 || int.parse(port) > 65535)) {
    return 'Invalid port';
  }
  final ipv6 = match.group(1);
  if (ipv6 != null) {
    return InternetAddress.tryParse(ipv6)?.type == InternetAddressType.IPv6
        ? null
        : 'Invalid IPv6 address';
  }
  final host = match.group(2)!;
  return isDomain(host) ||
          InternetAddress.tryParse(host)?.type == InternetAddressType.IPv4
      ? null
      : 'Enter a domain or IP';
}

/// WARP endpoints and the upstream proxy: the port is required.
String? validateEndpoint(String v) => validateHostPort(v, requirePort: true);

// DNS validators follow BPB panel's (src/settings/validators.ts); IPv6 bare, as everywhere
// without a port.

/// Cloudflare's DNS: a worker can't reach Cloudflare's own addresses (BPB's list).
const _cloudflareDns = {
  '1.1.1.1', '1.0.0.1', '1.1.1.2', '1.0.0.2', '1.1.1.3', '1.0.0.3', //
  '2606:4700:4700::1111', '2606:4700:4700::1001', '2606:4700:4700::1112', //
  '2606:4700:4700::1002', '2606:4700:4700::1113', '2606:4700:4700::1003', //
  'one.one.one.one',
  '1dot1dot1dot1',
  'cloudflare-dns.com',
  'family.cloudflare-dns.com', //
  'security.cloudflare-dns.com',
};

/// VLESS remote DNS (BPB's validateRemoteDNS, stricter, and without DoT, which Xray's DNS
/// doesn't have): https://host/dns-query or tcp://host, the host a domain or IP (IPv6 in
/// brackets), with an optional port; through the worker, so not Cloudflare's.
String? validateRemoteDns(String v) {
  final uri = Uri.tryParse(v);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    return 'Invalid DoH, Please enter a valid URL.';
  }
  if (!const {'tcp', 'https'}.contains(uri.scheme)) {
    return 'It can be only TCP or DoH servers.';
  }
  if (!isDomain(uri.host) && !isIp(uri.host)) {
    return 'The host should be a domain or IP.';
  }
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    return 'Use https://host/dns-query or tcp://host.';
  }
  if (uri.scheme == 'https' && !_isDoh(uri)) {
    return 'DoH should be like https://dns.example/dns-query';
  }
  if (uri.scheme != 'https' && uri.path.isNotEmpty && uri.path != '/') {
    return 'Use tcp://host, without a path.';
  }
  if (_cloudflareDns.contains(uri.host)) {
    return 'Cloudflare DNS is not allowed for workers. Please use other public DNS servers like Google, Adguard...';
  }
  return null;
}

/// Anti-sanction DNS (used directly): an IP (UDP DNS), tcp://host, quic://host (DoQ) or a
/// standard DoH (https://host/…/dns-query).
String? validateSanctionDns(String v) =>
    isIp(v) || _isDnsUrl(v, const {'https', 'tcp', 'quic'})
    ? null
    : 'Use an IP, tcp://host, quic://host or https://host/dns-query';

/// WARP / MASQUE remote DNS (through the tunnel): an IP (UDP DNS), tcp://host or a standard DoH.
/// No QUIC: Xray only has DoQ in local mode, which wouldn't go through the tunnel.
String? validateTunnelDns(String v) =>
    isIp(v) || _isDnsUrl(v, const {'https', 'tcp'})
    ? null
    : 'Use an IP, tcp://host or https://host/dns-query';

String? validateHttpsUrl(String v) {
  final uri = Uri.tryParse(v);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
      ? null
      : 'Enter an https URL';
}

// endregion

class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 20, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Groups a section's fields in a card, with dividers between them.
class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const SettingsCard({required this.children, super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      shape: roundedShape(
        kCardRadius,
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.75),
          width: 0.75,
        ),
      ),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ListTileTheme.merge(
          contentPadding: const EdgeInsets.symmetric(vertical: 6,horizontal: 12),
          minVerticalPadding: 4,
          child: Column(
            children: [
              for (final (index, child) in children.indexed) ...[
                child,
                if (index < children.length - 1)
                  Divider(
                    height: 1,
                    thickness: 0.75,
                    color: Theme.of(context).colorScheme.outlineVariant
                        .withValues(alpha: 0.75),
                    indent: 16,
                    endIndent: 16,
                  ),
              ],
            ],
          ),
          titleTextStyle: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}

Widget? _leading(IconData? icon) => icon == null ? null : Icon(icon);

class SwitchPref extends StatelessWidget {
  final String path;
  final String title;
  final String? subtitle;
  final IconData? icon;
  const SwitchPref(
    this.path,
    this.title, {
    this.subtitle,
    this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return SwitchListTile(
      secondary: _leading(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: state.readBool(path),
      onChanged: (v) => state.write(path, v),
    );
  }
}

class TextPref extends StatelessWidget {
  final String path;
  final String title;
  final String? hint;
  final String? help;
  final Validator? validator;
  final bool allowEmpty;
  final bool multiline;
  final IconData? icon;

  /// Shows dots instead of the value (passwords).
  final bool secret;

  const TextPref(
    this.path,
    this.title, {
    this.hint,
    this.help,
    this.validator,
    this.allowEmpty = false,
    this.multiline = false,
    this.icon,
    this.secret = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final value = state.readString(path);
    final shown = secret ? '•' * value.length.clamp(0, 12) : value;
    return ListTile(
      leading: _leading(icon),
      title: Text(title),
      subtitle: Text(
        value.isEmpty ? 'Not set' : shown,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () async {
        final result = await showTextInputDialog(
          context,
          title: title,
          initial: value,
          hint: hint,
          help: help,
          multiline: multiline,
          secret: secret,
          validator: (v) {
            if (v.isEmpty) return allowEmpty ? null : 'Required';
            return validator?.call(v);
          },
        );
        if (result != null) state.write(path, result);
      },
    );
  }
}

class IntPref extends StatelessWidget {
  final String path;
  final String title;
  final int min;
  final int max;
  final String suffix;
  final IconData? icon;

  /// Shown under the field in the edit dialog, like [TextPref.help].
  final String? help;
  const IntPref(
    this.path,
    this.title, {
    this.min = 0,
    this.max = 1 << 30,
    this.suffix = '',
    this.icon,
    this.help,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final value = state.readInt(path);
    return ListTile(
      leading: _leading(icon),
      title: Text(title),
      subtitle: Text('$value$suffix'),
      onTap: () async {
        final result = await showTextInputDialog(
          context,
          title: title,
          initial: '$value',
          help: help,
          number: true,
          validator: (v) {
            final n = int.tryParse(v);
            if (n == null || n < min || n > max) {
              return 'Enter a number between $min and $max';
            }
            return null;
          },
        );
        if (result != null) state.write(path, int.parse(result));
      },
    );
  }
}

class ChoicePref extends StatelessWidget {
  final String path;
  final String title;
  final Map<String, String> options;
  final void Function(AppState state, String value)? onSelected;
  final IconData? icon;

  /// Optional tags at the right of an option's label (e.g. TCP / UDP), as on the chips.
  final List<String> Function(String value)? badges;
  const ChoicePref(
    this.path,
    this.title,
    this.options, {
    this.onSelected,
    this.icon,
    this.badges,
    super.key,
  });

  /// [label] followed by [value]'s tags.
  Widget _labelled(BuildContext context, String value, Widget label) {
    final tags = badges?.call(value) ?? const <String>[];
    if (tags.isEmpty) return label;
    return Row(
      children: [
        Expanded(child: label),
        for (final (i, tag) in tags.indexed) ...[
          SizedBox(width: i == 0 ? 8 : 4),
          ChipMenu.badge(context, tag),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final value = state.readString(path);
    return ListTile(
      leading: _leading(icon),
      title: Text(title),
      subtitle: _labelled(context, value, Text(options[value] ?? value)),
      onTap: () async {
        final result = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(title),
            children: [
              RadioGroup<String>(
                groupValue: value,
                onChanged: (v) => Navigator.of(context).pop(v),
                child: Column(
                  children: [
                    for (final e in options.entries)
                      RadioListTile<String>(
                        value: e.key,
                        title: _labelled(context, e.key, Text(e.value)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        if (result == null || result == value) return;
        if (onSelected != null) {
          onSelected!(state, result);
        } else {
          state.write(path, result);
        }
      },
    );
  }
}

class MultiIntPref extends StatelessWidget {
  final String path;
  final String title;
  final List<int> options;
  final IconData? icon;
  const MultiIntPref(
    this.path,
    this.title,
    this.options, {
    this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final selected = (state.read(path) as List? ?? const [])
        .whereType<int>()
        .toList();
    return ListTile(
      leading: _leading(icon),
      title: Text(title),
      subtitle: Text(selected.isEmpty ? 'Not set' : selected.join(', ')),
      onTap: () async {
        final result = await showDialog<List<int>>(
          context: context,
          builder: (context) => _MultiSelectDialog(
            title: title,
            options: options,
            selected: selected,
          ),
        );
        if (result != null) state.write(path, result);
      },
    );
  }
}

class _MultiSelectDialog extends StatefulWidget {
  final String title;
  final List<int> options;
  final List<int> selected;
  const _MultiSelectDialog({
    required this.title,
    required this.options,
    required this.selected,
  });

  @override
  State<_MultiSelectDialog> createState() => _MultiSelectDialogState();
}

class _MultiSelectDialogState extends State<_MultiSelectDialog> {
  late final Set<int> _selected = widget.selected.toSet();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in widget.options)
              CheckboxListTile(
                value: _selected.contains(o),
                title: Text('$o'),
                onChanged: (v) => setState(
                  () => v == true ? _selected.add(o) : _selected.remove(o),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () =>
                    Navigator.of(context)
                        .pop(widget.options.where(_selected.contains).toList()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// List of strings edited as one entry per line.
class ListPref extends StatelessWidget {
  final String path;
  final String title;
  final String? hint;
  final String? help;
  final Validator? itemValidator;
  final bool allowEmpty;
  final IconData? icon;

  /// Entries may also be separated by commas; off for entries that contain commas.
  final bool commaSeparated;

  const ListPref(
    this.path,
    this.title, {
    this.hint,
    this.help,
    this.itemValidator,
    this.allowEmpty = true,
    this.icon,
    this.commaSeparated = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final items = state.readList(path);
    return ListTile(
      leading: _leading(icon),
      title: Text(title),
      // The first value, and … when there are more (their count is on the right).
      subtitle: Text(
        items.isEmpty
            ? 'Not set'
            : '${items.first}${items.length > 1 ? '…' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: items.isEmpty ? null : Text('${items.length}'),
      onTap: () async {
        final result = await showTextInputDialog(
          context,
          title: title,
          initial: items.join('\n'),
          hint: hint ?? 'One per line',
          help: help,
          multiline: true,
          validator: (v) {
            final list = _split(v);
            if (list.isEmpty && !allowEmpty) return 'Add at least one entry';
            for (final item in list) {
              final error = itemValidator?.call(item);
              if (error != null) return '$item: $error';
            }
            return null;
          },
        );
        if (result != null) state.write(path, _split(result));
      },
    );
  }

  List<String> _split(String v) => v
      .split(commaSeparated ? RegExp(r'[\n,]') : RegExp(r'\n'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList();
}

Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  String? help,
  bool multiline = false,
  bool number = false,
  bool secret = false,
  Validator? validator,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextInputDialog(
    title: title,
    initial: initial,
    hint: hint,
    help: help,
    multiline: multiline,
    number: number,
    secret: secret,
    validator: validator,
  ),
);

class _TextInputDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String? hint;
  final String? help;
  final bool multiline;
  final bool number;

  /// Password field: hidden text with a show/hide button.
  final bool secret;
  final Validator? validator;

  const _TextInputDialog({
    required this.title,
    required this.initial,
    this.hint,
    this.help,
    this.multiline = false,
    this.number = false,
    this.secret = false,
    this.validator,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  /// Hidden text can't span lines (Flutter), and a single-line field would drop a pasted key's
  /// line breaks: a multiline secret (a private key) is shown here, and only masked in its row.
  late final bool _canObscure = widget.secret && !widget.multiline;
  late bool _obscure = _canObscure;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    final error = widget.validator?.call(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Long help text and a tall multi-line field must scroll above the keyboard.
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.help != null) ...[
              Text(widget.help!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: widget.multiline ? 4 : 1,
              maxLines: widget.multiline ? 10 : 1,
              keyboardType: widget.number
                  ? TextInputType.number
                  : widget.multiline
                  ? TextInputType.multiline
                  : (widget.secret
                        ? TextInputType.visiblePassword
                        : TextInputType.url),
              inputFormatters: widget.number
                  ? [FilteringTextInputFormatter.digitsOnly]
                  : null,
              obscureText: _obscure,
              autocorrect: !widget.secret,
              enableSuggestions: !widget.secret,
              decoration: InputDecoration(
                hintText: widget.hint,
                errorText: _error,
                errorMaxLines: 4,
                suffixIcon: _canObscure
                    ? IconButton(
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Symbols.visibility_rounded
                              : Symbols.visibility_off_rounded,
                        ),
                      )
                    : null,
              ),
              onSubmitted: widget.multiline ? null : (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
