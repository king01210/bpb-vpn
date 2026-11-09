import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/settings.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Edits the profile's `udpNoises` (or [section]'s: `masque.`, `serverless.`) as cards, like the
/// "v2ray Noise" section of the BPB panel.
class NoisesPage extends StatefulWidget {
  /// Path prefix of the noises edited: '' (the profile's), 'masque.' or 'serverless.'.
  final String section;
  const NoisesPage({super.key, this.section = ''});

  @override
  State<NoisesPage> createState() => _NoisesPageState();
}

class _NoisesPageState extends State<NoisesPage> {
  /// Noise types by stored name, with their labels.
  static final modes = {for (final t in NoiseType.values) t.name: t.label};

  final _formKey = GlobalKey<FormState>();
  late final List<_NoiseDraft> _noises;
  late final TextEditingController _resetMin;
  late final TextEditingController _resetMax;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final state = AppScope.read(context);
    final reset = Range.parse(state.read('${widget.section}udpNoiseReset'), Profile.defaultUdpNoiseReset);
    _resetMin = TextEditingController(text: '${reset.min}');
    _resetMax = TextEditingController(text: '${reset.max}');
    final noises = state.read('${widget.section}udpNoises') as List? ?? const [];
    _noises = noises.whereType<Map>().map(UdpNoise.parse).map(_NoiseDraft.from).toList();
    if (_noises.isEmpty) _noises.add(_NoiseDraft.from(_defaultNoise));
  }

  @override
  void dispose() {
    for (final n in _noises) {
      n.dispose();
    }
    _resetMin.dispose();
    _resetMax.dispose();
    super.dispose();
  }

  static const _defaultNoise = UdpNoise(type: NoiseType.rand, size: Range(50, 100), count: 5);

  void _changed() => setState(() => _dirty = true);

  void _add() {
    setState(() {
      _noises.add(_NoiseDraft.from(_defaultNoise));
      _dirty = true;
    });
  }

  Future<void> _delete(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete UDP noise'),
        content: const Text('Are you sure?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _noises.removeAt(index).dispose();
      _dirty = true;
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final state = AppScope.read(context);
    state.write('${widget.section}udpNoises', _noises.map((n) => n.toJson()).toList());
    state.write('${widget.section}udpNoiseReset', {
      'min': int.parse(_resetMin.text.trim()),
      'max': int.parse(_resetMax.text.trim()),
    });
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('UDP noises saved')));
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your noise changes have not been saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Discard')),
        ],
      ),
    );
    return discard == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard()) {
          _dirty = false;
          navigator.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('UDP noises'),
          actions: [TextButton(onPressed: _dirty ? _save : null, child: const Text('Save'))],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Symbols.add_circle_outline_rounded),
          label: const Text('Add noise'),
        ),
        body: Form(
          key: _formKey,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            // The reset interval first (it applies to all noises), then a card per noise.
            itemCount: _noises.length + 1,
            itemBuilder: (context, i) => i == 0
                ? _ResetCard(min: _resetMin, max: _resetMax, onChanged: _changed)
                : _NoiseCard(
                    key: ObjectKey(_noises[i - 1]),
                    index: i - 1,
                    noise: _noises[i - 1],
                    onChanged: _changed,
                    onDelete: i == 1 ? null : () => _delete(i - 1),
                  ),
          ),
        ),
      ),
    );
  }
}

/// How often the noises are sent again: Xray's noise `reset`, seconds, random within min–max.
class _ResetCard extends StatelessWidget {
  final TextEditingController min;
  final TextEditingController max;
  final VoidCallback onChanged;

  const _ResetCard({required this.min, required this.max, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    // Same layout as the noise cards: a 48 px title row, then the fields.
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 48,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('Reset noise interval (seconds)', style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: min,
                    decoration: const InputDecoration(labelText: 'Min'),
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                    onChanged: (_) => onChanged(),
                    validator: (v) {
                      final lo = int.tryParse(v?.trim() ?? '');
                      if (lo == null || lo < 1) return 'At least 1';
                      final hi = int.tryParse(max.text.trim()) ?? 0;
                      return lo > hi ? 'Min > max' : null;
                    },
                  ),
                ),
                const Padding(padding: EdgeInsets.fromLTRB(kRangeDashGap, 16, kRangeDashGap, 0), child: Text('–')),
                Expanded(
                  child: TextFormField(
                    controller: max,
                    decoration: const InputDecoration(labelText: 'Max'),
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                    onChanged: (_) => onChanged(),
                    validator: (v) => (int.tryParse(v?.trim() ?? '') ?? 0) < 1 ? 'At least 1' : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NoiseDraft {
  String type;
  final TextEditingController packet;
  final TextEditingController count;
  final TextEditingController delayMin;
  final TextEditingController delayMax;

  _NoiseDraft(this.type, String packet, int count, String delayMin, String delayMax)
    : packet = TextEditingController(text: packet),
      count = TextEditingController(text: '$count'),
      delayMin = TextEditingController(text: delayMin),
      delayMax = TextEditingController(text: delayMax);

  /// The packet field shows a random noise's size as "50-100" and an array's bytes as
  /// "1,10,128"; other types are their text as is.
  factory _NoiseDraft.from(UdpNoise n) => _NoiseDraft(
    n.type.name,
    switch (n.type) {
      NoiseType.rand => '${(n.size ?? const Range(50, 100)).min}-${(n.size ?? const Range(50, 100)).max}',
      NoiseType.array => (n.bytes ?? const []).join(','),
      _ => n.packet ?? '',
    },
    n.count,
    '${n.delay.min}',
    '${n.delay.max}',
  );

  /// As stored (the form validates the fields before saving).
  Map<String, dynamic> toJson() {
    final text = packet.text.trim();
    final range = RegExp(r'^(\d+)-(\d+)$').firstMatch(text);
    return {
      'type': type,
      if (type == 'rand') 'size': {'min': int.parse(range!.group(1)!), 'max': int.parse(range.group(2)!)},
      if (type == 'array') 'bytes': text.split(',').map((e) => int.parse(e.trim())).toList(),
      if (type != 'rand' && type != 'array') 'packet': text,
      'count': int.parse(count.text.trim()),
      'delay': {'min': int.parse(delayMin.text.trim()), 'max': int.parse(delayMax.text.trim())},
    };
  }

  void dispose() {
    packet.dispose();
    count.dispose();
    delayMin.dispose();
    delayMax.dispose();
  }
}

class _NoiseCard extends StatelessWidget {
  final int index;
  final _NoiseDraft noise;
  final VoidCallback onChanged;
  final VoidCallback? onDelete;

  const _NoiseCard({super.key, required this.index, required this.noise, required this.onChanged, this.onDelete});

  void _generate() {
    noise.packet.text = generateNoisePacket(noise.type);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final digits = [FilteringTextInputFormatter.digitsOnly];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Noise ${index + 1}', style: theme.textTheme.titleMedium)),
                if (onDelete != null)
                  IconButton(tooltip: 'Delete', icon: const Icon(Symbols.delete_outline_rounded), onPressed: onDelete)
                else
                  const SizedBox(height: 48),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    borderRadius: BorderRadius.circular(kMenuRadius),
                    initialValue: noise.type,
                    decoration: const InputDecoration(labelText: 'Mode'),
                    items: [
                      for (final e in _NoisesPageState.modes.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) {
                      if (v == null || v == noise.type) return;
                      noise.type = v;
                      _generate();
                    },
                  ),
                  const SizedBox(height: kFieldGap),
                  TextFormField(
                    controller: noise.packet,
                    minLines: 1,
                    maxLines: noise.type == 'exp' ? 4 : 1,
                    decoration: InputDecoration(
                      labelText: 'Packet',
                      helperText: noise.type == 'exp'
                          ? '<b 0x…> bytes · <r N> random · <rc N> ASCII · <rd N> digits\n'
                                '<t> timestamp · <c> counter · <n> nonce · N can be a range like 8-16'
                          : null,
                      helperMaxLines: 2,
                      suffixIcon: noise.type == 'exp'
                          ? PopupMenuButton<String>(
                              tooltip: 'Presets',
                              icon: const Icon(Symbols.auto_awesome_rounded),
                              onSelected: (exp) {
                                noise.packet.text = exp;
                                onChanged();
                              },
                              itemBuilder: (_) => [
                                for (final p in noiseExpPresets.entries)
                                  PopupMenuItem(value: p.value, child: Text(p.key)),
                              ],
                            )
                          : IconButton(
                              tooltip: 'Generate',
                              icon: const Icon(Symbols.refresh_rounded),
                              onPressed: _generate,
                            ),
                    ),
                    onChanged: (_) => onChanged(),
                    validator: (v) => validateNoisePacket(noise.type, v?.trim() ?? ''),
                  ),
                  const SizedBox(height: kFieldGap),
                  TextFormField(
                    controller: noise.count,
                    decoration: const InputDecoration(labelText: 'Count'),
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                    onChanged: (_) => onChanged(),
                    validator: (v) => (int.tryParse(v?.trim() ?? '') ?? 0) < 1 ? 'At least 1' : null,
                  ),
                  const SizedBox(height: kFieldGap),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: noise.delayMin,
                          decoration: const InputDecoration(labelText: 'Delay min'),
                          keyboardType: TextInputType.number,
                          inputFormatters: digits,
                          onChanged: (_) => onChanged(),
                          validator: (v) {
                            final min = int.tryParse(v?.trim() ?? '') ?? 0;
                            if (min < 1) return 'At least 1';
                            final max = int.tryParse(noise.delayMax.text.trim()) ?? 0;
                            return min > max ? 'Min > max' : null;
                          },
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(kRangeDashGap, 16, kRangeDashGap, 0),
                        child: Text('–'),
                      ),
                      Expanded(
                        child: TextFormField(
                          controller: noise.delayMax,
                          decoration: const InputDecoration(labelText: 'Delay max'),
                          keyboardType: TextInputType.number,
                          inputFormatters: digits,
                          onChanged: (_) => onChanged(),
                          validator: (v) => (int.tryParse(v?.trim() ?? '') ?? 0) < 1 ? 'At least 1' : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _random = Random.secure();

List<int> _randBytes(int min, int max) =>
    List.generate(min + _random.nextInt(max - min + 1), (_) => _random.nextInt(256));

/// Xray "exp" noise templates that make the first packets look like a common protocol,
/// so DPI may classify the flow before it sees the WireGuard handshake (like AmneziaWG's
/// I1-I5 packets). They're extra packets only; the WARP server ignores them.
const noiseExpPresets = {
  // Long header Initial, version 1, 8-byte DCID, empty SCID and token, ~1200-byte payload.
  'QUIC Initial': '<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x44d0><r 1232>',
  // Standard A query for www.google.com with a random ID.
  'DNS query': '<r 2><b 0x01000001000000000000><b 0x0377777706676f6f676c6503636f6d00><b 0x00010001>',
  // Binding request: type, length 0, magic cookie, random transaction ID.
  'STUN Binding request': '<b 0x000100002112a442><r 12>',
};

/// Random packet for a noise mode, using the panel's sizes (32-64 bytes).
String generateNoisePacket(String mode) {
  switch (mode) {
    case 'exp':
      return noiseExpPresets.values.first;
    case 'base64':
      return base64.encode(_randBytes(32, 64));
    case 'hex':
      return _randBytes(32, 64).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    case 'array':
      return _randBytes(32, 64).join(',');
    case 'str':
      const charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      return _randBytes(32, 64).map((b) => charset[b % charset.length]).join();
    default:
      return '50-100';
  }
}

/// Same rules as BPB's validateXrayNoises.
String? validateNoisePacket(String mode, String packet) {
  if (packet.isEmpty) return 'Required';
  switch (mode) {
    case 'base64':
      try {
        base64.decode(packet);
        return null;
      } on FormatException {
        return 'Not a valid base64 value';
      }
    case 'rand':
      final match = RegExp(r'^(\d+)-(\d+)$').firstMatch(packet);
      if (match == null) return 'Use a range like 10-30';
      return int.parse(match.group(1)!) > int.parse(match.group(2)!) ? 'Min cannot be bigger than max' : null;
    case 'hex':
      return RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(packet) ? null : 'Even-length hex (0-9, a-f)';
    case 'array':
      final ok = packet.split(',').every((n) {
        final v = int.tryParse(n.trim());
        return RegExp(r'^\d+$').hasMatch(n.trim()) && v != null && v <= 255;
      });
      return ok ? null : 'Comma-separated numbers 0-255, like 1,10,128';
    case 'exp':
      return validateNoiseExp(packet);
    default:
      return null;
  }
}

/// Mirrors Xray's parseNoiseExp / buildNoiseSegment (infra/conf/transport_finalmask.go),
/// so a config the app writes is one Xray accepts.
String? validateNoiseExp(String exp) {
  final token = RegExp(r'<\s*([a-z]+)(?:\s+([^>]*?))?\s*>');
  var last = 0;
  var segments = 0;
  for (final m in token.allMatches(exp)) {
    final between = exp.substring(last, m.start).trim();
    if (between.isNotEmpty) return 'Unexpected text: $between';
    last = m.end;
    segments++;
    final key = m.group(1)!;
    final arg = (m.group(2) ?? '').trim();
    switch (key) {
      case 'b':
        var hex = arg.replaceAll(RegExp(r'\s'), '');
        if (hex.startsWith('0x') || hex.startsWith('0X')) hex = hex.substring(2);
        if (!RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(hex)) return '<b> needs even-length hex, like <b 0x1a2b>';
      case 'r' || 'rc' || 'rd':
        final range = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(arg);
        if (range == null) return '<$key> needs a size, like <$key 16> or <$key 8-32>';
        final lo = int.parse(range.group(1)!);
        final hi = int.parse(range.group(2) ?? range.group(1)!);
        if (hi < lo || hi > 65535) return 'Size in <$key> must be 0-65535, low to high';
      case 't' || 'c' || 'n':
        if (arg.isNotEmpty) return '<$key> takes no value';
      default:
        return 'Unknown <$key>; use b, r, rc, rd, t, c or n';
    }
  }
  if (exp.substring(last).trim().isNotEmpty) return 'Unexpected text: ${exp.substring(last).trim()}';
  return segments == 0 ? 'Add at least one <…> part' : null;
}
