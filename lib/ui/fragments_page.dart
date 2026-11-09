import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/settings.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Edits the fragment cards (profile `fragments`, or [section]'s: `masque.`, `serverless.`). Each
/// card is one Xray finalmask "fragment" entry.
class FragmentsPage extends StatefulWidget {
  /// Path prefix of the fragments edited: '' (the profile's), 'masque.' or 'serverless.'.
  final String section;
  const FragmentsPage({super.key, this.section = ''});

  @override
  State<FragmentsPage> createState() => _FragmentsPageState();
}

class _FragmentsPageState extends State<FragmentsPage> {
  /// Length / delay presets from the panel UI.
  static const presets = {
    'Low': (Range(100, 200), Range.single(1)),
    'Medium': (Range(50, 100), Range(1, 5)),
    'High': (Range(10, 20), Range(10, 20)),
  };

  final _formKey = GlobalKey<FormState>();
  late final List<_FragmentDraft> _fragments;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final fragments = AppScope.read(context).read('${widget.section}fragments') as List? ?? const [];
    _fragments = fragments.whereType<Map>().map(Fragment.parse).map(_FragmentDraft.from).toList();
    if (_fragments.isEmpty) _fragments.add(_FragmentDraft.from(const Fragment()));
  }

  @override
  void dispose() {
    for (final f in _fragments) {
      f.dispose();
    }
    super.dispose();
  }

  void _changed() => setState(() => _dirty = true);

  void _add() {
    setState(() {
      _fragments.add(_FragmentDraft.from(const Fragment()));
      _dirty = true;
    });
  }

  Future<void> _delete(int index) async {
    if (!await _confirm('Delete fragment', 'Are you sure?', 'Delete')) return;
    setState(() {
      _fragments.removeAt(index).dispose();
      _dirty = true;
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    AppScope.read(context)
        .write('${widget.section}fragments', _fragments.map((f) => f.toJson()).toList());
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fragments saved')));
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirm('Discard changes?', 'Your fragment changes have not been saved.', 'Discard')) {
          _dirty = false;
          navigator.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Fragments'),
          actions: [TextButton(onPressed: _dirty ? _save : null, child: const Text('Save'))],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Symbols.add_circle_outline_rounded),
          label: const Text('Add fragment'),
        ),
        body: Form(
          key: _formKey,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            itemCount: _fragments.length,
            itemBuilder: (context, i) => _FragmentCard(
              key: ObjectKey(_fragments[i]),
              index: i,
              fragment: _fragments[i],
              onChanged: _changed,
              onDelete: i == 0 ? null : () => _delete(i),
            ),
          ),
        ),
      ),
    );
  }
}

// region drafts

class _RangeDraft {
  final TextEditingController min;
  final TextEditingController max;

  _RangeDraft(String minValue, String maxValue)
    : min = TextEditingController(text: minValue),
      max = TextEditingController(text: maxValue);

  factory _RangeDraft.of(Range? r) => r == null ? _RangeDraft('', '') : _RangeDraft('${r.min}', '${r.max}');

  bool get isEmpty => min.text.trim().isEmpty && max.text.trim().isEmpty;

  /// The range as stored (the form validates the numbers before saving).
  Map<String, dynamic> toJson() => {'min': int.parse(min.text.trim()), 'max': int.parse(max.text.trim())};

  void set(Range r) {
    min.text = '${r.min}';
    max.text = '${r.max}';
  }

  void dispose() {
    min.dispose();
    max.dispose();
  }
}

class _FragmentDraft {
  FragmentPackets packets;
  final List<_RangeDraft> lengths;
  final List<_RangeDraft> delays;
  final _RangeDraft maxSplit;

  _FragmentDraft(this.packets, this.lengths, this.delays, this.maxSplit);

  factory _FragmentDraft.from(Fragment f) => _FragmentDraft(
    f.packets,
    [
      for (final r in f.lengths.isEmpty ? const [Range(100, 200)] : f.lengths) _RangeDraft.of(r),
    ],
    [
      for (final r in f.delays.isEmpty ? const [Range.single(1)] : f.delays) _RangeDraft.of(r),
    ],
    _RangeDraft.of(f.maxSplit),
  );

  Map<String, dynamic> toJson() => {
    'packets': packets.json,
    'lengths': lengths.map((r) => r.toJson()).toList(),
    'delays': delays.map((r) => r.toJson()).toList(),
    'maxSplit': maxSplit.isEmpty ? null : maxSplit.toJson(),
  };

  void applyPreset(Range length, Range delay) {
    for (final r in [...lengths.skip(1), ...delays.skip(1)]) {
      r.dispose();
    }
    lengths.removeRange(1, lengths.length);
    delays.removeRange(1, delays.length);
    lengths.first.set(length);
    delays.first.set(delay);
  }

  void dispose() {
    maxSplit.dispose();
    for (final r in [...lengths, ...delays]) {
      r.dispose();
    }
  }
}

// endregion

class _FragmentCard extends StatefulWidget {
  final int index;
  final _FragmentDraft fragment;
  final VoidCallback onChanged;
  final VoidCallback? onDelete;

  const _FragmentCard({super.key, required this.index, required this.fragment, required this.onChanged, this.onDelete});

  @override
  State<_FragmentCard> createState() => _FragmentCardState();
}

class _FragmentCardState extends State<_FragmentCard> {
  _FragmentDraft get f => widget.fragment;

  void _update(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Fragment ${widget.index + 1}', style: theme.textTheme.titleMedium)),
                PopupMenuButton<String>(
                  tooltip: 'Preset',
                  icon: const Icon(Symbols.tune_rounded),
                  onSelected: (name) {
                    final (length, delay) = _FragmentsPageState.presets[name]!;
                    _update(() => f.applyPreset(length, delay));
                  },
                  itemBuilder: (_) => [
                    for (final e in _FragmentsPageState.presets.entries)
                      PopupMenuItem(value: e.key, child: Text('${e.key}  ·  ${e.value.$1} / ${e.value.$2} ms')),
                  ],
                ),
                if (widget.onDelete != null)
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Symbols.delete_outline_rounded),
                    onPressed: widget.onDelete,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Fixed presets: the TLS ClientHello or the first 1, 2, 3 or 5 packets.
                  DropdownButtonFormField<FragmentPackets>(
                    borderRadius: BorderRadius.circular(kMenuRadius),
                    initialValue: f.packets,
                    decoration: const InputDecoration(labelText: 'Packets'),
                    items: [for (final p in FragmentPackets.values) DropdownMenuItem(value: p, child: Text(p.label))],
                    onChanged: (v) => _update(() => f.packets = v ?? FragmentPackets.tlsHello),
                  ),
                  _RangeList(
                    title: 'Lengths',
                    addLabel: 'Add length',
                    itemLabel: 'Length',
                    ranges: f.lengths,
                    minValue: 0,
                    onChanged: () => _update(() {}),
                  ),
                  _RangeList(
                    title: 'Delays (ms)',
                    addLabel: 'Add delay',
                    itemLabel: 'Delay',
                    ranges: f.delays,
                    minValue: 0,
                    onChanged: () => _update(() {}),
                  ),
                  const SizedBox(height: kFieldGap),
                  Text('Max split', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  _RangeRow(
                    range: f.maxSplit,
                    label: 'Max split',
                    minValue: 0,
                    optional: true,
                    onChanged: widget.onChanged,
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

/// A list of min-max rows with an add button; rows after the first can be removed.
class _RangeList extends StatelessWidget {
  final String title;
  final String addLabel;

  /// Each row's field label ("Length" → "Length min" / "Length max"), as on the noise cards.
  final String itemLabel;
  final List<_RangeDraft> ranges;
  final int minValue;
  final VoidCallback onChanged;

  const _RangeList({
    required this.title,
    required this.addLabel,
    required this.itemLabel,
    required this.ranges,
    required this.minValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: kFieldGap),
        Row(
          children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.labelLarge)),
            TextButton.icon(
              onPressed: () {
                final last = ranges.last;
                ranges.add(_RangeDraft(last.min.text, last.max.text));
                onChanged();
              },
              icon: const Icon(Symbols.add_rounded, size: 18),
              label: Text(addLabel),
            ),
          ],
        ),
        for (var i = 0; i < ranges.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 8 : kFieldGap),
            child: _RangeRow(
              key: ObjectKey(ranges[i]),
              range: ranges[i],
              label: itemLabel,
              minValue: minValue,
              onChanged: onChanged,
              onRemove: ranges.length == 1
                  ? null
                  : () {
                      ranges.removeAt(i).dispose();
                      onChanged();
                    },
            ),
          ),
      ],
    );
  }
}

class _RangeRow extends StatelessWidget {
  final _RangeDraft range;
  final String label;
  final int minValue;
  final bool optional;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  const _RangeRow({
    super.key,
    required this.range,
    required this.label,
    required this.minValue,
    required this.onChanged,
    this.optional = false,
    this.onRemove,
  });

  String? _validateMin(String? v) {
    final text = v?.trim() ?? '';
    if (optional && range.isEmpty) return null;
    final n = int.tryParse(text);
    if (n == null) return 'Required';
    if (n < minValue) return 'Min $minValue';
    final max = int.tryParse(range.max.text.trim());
    return max != null && n > max ? 'Min > max' : null;
  }

  String? _validateMax(String? v) {
    if (optional && range.isEmpty) return null;
    final n = int.tryParse(v?.trim() ?? '');
    if (n == null) return 'Required';
    return n < minValue ? 'Min $minValue' : null;
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    InputDecoration deco(String text) => InputDecoration(labelText: text, hintText: optional ? 'None' : null);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            controller: range.min,
            decoration: deco('$label min'),
            keyboardType: TextInputType.number,
            inputFormatters: digits,
            onChanged: (_) => onChanged(),
            validator: _validateMin,
          ),
        ),
        const Padding(padding: EdgeInsets.fromLTRB(kRangeDashGap, 16, kRangeDashGap, 0), child: Text('–')),
        Expanded(
          child: TextFormField(
            controller: range.max,
            decoration: deco('$label max'),
            keyboardType: TextInputType.number,
            inputFormatters: digits,
            onChanged: (_) => onChanged(),
            validator: _validateMax,
          ),
        ),
        if (onRemove != null)
          IconButton(tooltip: 'Remove', icon: const Icon(Symbols.remove_circle_outline_rounded), onPressed: onRemove),
      ],
    );
  }
}
