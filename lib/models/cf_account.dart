import 'settings.dart';

/// One deployment of the VPN worker in an account: a Worker or a Pages project, with its own
/// VLESS settings (Settings → VLESS edits the selected one).
class Deployment {
  final WorkerType type;

  /// Worker script / Pages project name (random).
  final String name;

  /// workers.dev / pages.dev address, as Cloudflare reported it at the last deployment.
  final String host;
  final String? customDomain;

  /// The worker script version deployed (see CloudflareApi.workerVersion).
  final int version;

  /// Its ENV (proxy IPs, fallback website) changed but isn't deployed yet.
  final bool pending;
  final VlessSettings vless;

  const Deployment({
    required this.type,
    required this.name,
    required this.host,
    this.customDomain,
    required this.version,
    this.pending = false,
    this.vless = const VlessSettings(),
  });

  Deployment copyWith({String? host, String? Function()? customDomain, int? version, bool? pending, VlessSettings? vless}) =>
      Deployment(
        type: type,
        name: name,
        host: host ?? this.host,
        customDomain: customDomain != null ? customDomain() : this.customDomain,
        version: version ?? this.version,
        pending: pending ?? this.pending,
        vless: vless ?? this.vless,
      );

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'name': name,
    'host': host,
    'customDomain': customDomain,
    'version': version,
    'pending': pending,
    // Sparse, like the profile: a changed default reaches every deployment that never set it.
    'vless': sparseDiff(vless.toJson(), const VlessSettings().toJson()),
  };

  static Deployment? fromJson(Object? v) {
    if (v is! Map) return null;
    final type = WorkerType.values.asNameMap()[v['type']];
    final name = v['name'], host = v['host'];
    if (type == null || name is! String || name.isEmpty || host is! String || host.isEmpty) return null;
    final domain = v['customDomain'];
    return Deployment(
      type: type,
      name: name,
      host: host,
      customDomain: domain is String && domain.isNotEmpty ? domain : null,
      version: v['version'] is num ? (v['version'] as num).toInt() : 0,
      pending: v['pending'] == true,
      vless: VlessSettings.parse(v['vless']),
    );
  }
}

/// A Cloudflare account saved on this device, with the deployments this install made in it
/// (secret: the token and the VLESS UUID; never exported).
class SavedCfAccount {
  final String id;
  final String name;
  final String token;

  /// Email of the token's user (like BPB-Wizard); empty if unknown.
  final String email;

  /// The VLESS UUID, shared by the account's deployments.
  final String uuid;

  /// Workers first, then Pages: both (an account is saved only once both are deployed).
  final List<Deployment> deployments;

  const SavedCfAccount({
    required this.id,
    required this.name,
    required this.token,
    this.email = '',
    required this.uuid,
    required this.deployments,
  });

  /// Email when known, otherwise the account name.
  String get label => email.isNotEmpty ? email : name;

  Deployment? deployment(WorkerType type) => deployments.where((d) => d.type == type).firstOrNull;

  /// Both Workers and Pages are deployed: only then is the account used (Worker mode).
  bool get isComplete => WorkerType.values.every((t) => deployment(t) != null);

  /// [d] added, or replacing the one of its type.
  SavedCfAccount withAdded(Deployment d) => SavedCfAccount(
    id: id,
    name: name,
    token: token,
    email: email,
    uuid: uuid,
    deployments: [...deployments.where((e) => e.type != d.type), d]
      ..sort((a, b) => a.type.index.compareTo(b.type.index)),
  );

  SavedCfAccount withDeployment(Deployment d) => SavedCfAccount(
    id: id,
    name: name,
    token: token,
    email: email,
    uuid: uuid,
    deployments: [for (final e in deployments) e.type == d.type ? d : e],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'apiToken': token,
    'uuid': uuid,
    'deployments': deployments.map((d) => d.toJson()).toList(),
  };

  /// Null for an entry without a UUID or deployments (saved by an older version).
  static SavedCfAccount? fromJson(Map<String, dynamic> json) {
    final deployments = (json['deployments'] as List? ?? const []).map(Deployment.fromJson).whereType<Deployment>();
    final uuid = json['uuid'] as String? ?? '';
    if (uuid.isEmpty || deployments.isEmpty) return null;
    return SavedCfAccount(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      token: json['apiToken'] as String? ?? '',
      email: json['email'] as String? ?? '',
      uuid: uuid,
      deployments: deployments.toList()..sort((a, b) => a.type.index.compareTo(b.type.index)),
    );
  }
}
