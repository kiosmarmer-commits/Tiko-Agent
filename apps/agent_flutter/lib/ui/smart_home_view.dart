import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/agent_repository.dart';
import '../data/models.dart';
import '../ui/theme.dart';
import 'page_header.dart';
import 'package:tiko_widgets/tiko_widgets.dart';

/// Smart home (F6, docs/15 §7): perangkat ternormalisasi dari provider
/// Home Assistant / Tuya / eWeLink via REST agentd. Read + execute;
/// eksekusi tetap melewati approval gate runtime (high-risk) di sisi daemon.
/// Tanpa env kredensial lengkap, daemon membalas 501 dan halaman menampilkan
/// panduan setup env.
class SmartHomePage extends StatefulWidget {
  const SmartHomePage({
    super.key,
    required this.repo,
    required this.online,
  });

  final AgentRepository repo;
  final bool online;

  @override
  State<SmartHomePage> createState() => _SmartHomePageState();
}

class _SmartHomePageState extends State<SmartHomePage> {
  SmartHomeSnapshot? _providers;
  List<SmartDeviceInfo> _devices = const [];
  String _providerFilter = '';
  bool _loading = false;
  bool _executing = false;
  String? _error;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final providers = await widget.repo.smartHome();
      final devices = await widget.repo.smartHomeDevices(
        provider: _providerFilter.isEmpty ? null : _providerFilter,
      );
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _devices = devices;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setFilter(String provider) async {
    if (_providerFilter == provider) return;
    setState(() => _providerFilter = provider);
    await _refresh();
  }

  Future<void> _executeDevice(SmartDeviceInfo device) async {
    final command = await _askCommand(device);
    if (command == null || !mounted) return;
    setState(() {
      _executing = true;
      _lastResult = null;
    });
    try {
      final result = await widget.repo.smartHomeExecute(
        device.provider,
        device.id,
        command,
      );
      if (!mounted) return;
      setState(() {
        _lastResult = 'Eksekusi ${device.name}: $result';
      });
      await _refresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _lastResult = null;
          _error = 'Gagal eksekusi: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _executing = false);
    }
  }

  Future<Map<String, dynamic>?> _askCommand(SmartDeviceInfo device) {
    final controller = TextEditingController(
      text: device.capabilities.contains('switch')
          ? '{"action": "on"}'
          : '{"action": "toggle"}',
    );
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Eksekusi: ${device.name}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Perintah (JSON objek)',
            hintText: '{"action": "on"}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              try {
                final decoded = jsonDecode(controller.text);
                if (decoded is Map && decoded.isNotEmpty) {
                  Navigator.pop(
                    dialogContext,
                    {
                      for (final e in decoded.entries)
                        '${e.key}': e.value,
                    },
                  );
                }
              } catch (_) {
                // JSON invalid: dialog tetap terbuka agar user memperbaiki.
              }
            },
            child: const Text('Kirim'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final providers = _providers?.providers ?? const <String>[];
    return Column(
      children: [
        PageHeader(
          title: 'Smart home',
          subtitle: _providers == null
              ? 'Perangkat Home Assistant / Tuya / eWeLink via agentd'
              : '${providers.length} provider \u00b7 ${_devices.length} perangkat'
                  ' \u00b7 eksekusi lewat approval gate',
          online: widget.online,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Muat ulang',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_loading) StatusViews.loadingBanner(context),
        if (_error != null)
          StatusViews.errorBanner(context, _error!, onRetry: _refresh),
        if (providers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final provider in providers)
                  ChoiceChip(
                    key: Key('chip-provider-$provider'),
                    label: Text(provider),
                    selected: _providerFilter == provider,
                    onSelected: (_) => unawaited(_setFilter(
                      _providerFilter == provider ? '' : provider,
                    )),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _devices.isEmpty && !_loading
              ? StatusViews.empty(
                  context,
                  message: _error != null
                      ? 'Smart-home tidak tersedia.'
                      : 'Tidak ada perangkat. Pastikan env provider '
                          '(TIKO_HOME_ASSISTANT_URL/TOKEN, TIKO_TUYA_*, '
                          'TIKO_EWELINK_*) terpasang di daemon.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _devices.length,
                  itemBuilder: (context, i) {
                    final device = _devices[i];
                    return _DeviceCard(
                      device: device,
                      executing: _executing,
                      onExecute: () => unawaited(_executeDevice(device)),
                    );
                  },
                ),
        ),
        if (_lastResult != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              _lastResult!,
              key: const Key('text-smart-home-result'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.executing,
    required this.onExecute,
  });

  final SmartDeviceInfo device;
  final bool executing;
  final VoidCallback onExecute;

  @override
  Widget build(BuildContext context) {
    final online = device.online;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: Key('device-${device.provider}-${device.id}'),
        leading: Icon(
          switch (device.category) {
            'light' => Icons.lightbulb_outline,
            'switch' || 'socket' => Icons.power_outlined,
            'climate' => Icons.thermostat_outlined,
            'cover' => Icons.blinds_outlined,
            _ => Icons.devices_other_outlined,
          },
          color: online == false ? context.simpulMuted : context.simpulAccent,
        ),
        title: Text(device.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${device.provider} \u00b7 ${device.id}'
              '${online == null ? '' : online == true ? ' \u00b7 online' : ' \u00b7 offline'}',
            ),
            if (device.capabilities.isNotEmpty)
              Text('kapabilitas: ${device.capabilities.join(', ')}'),
            if (device.state.isNotEmpty)
              Text(
                'state: ${device.state.entries.take(4).map((e) => '${e.key}=${e.value}').join(', ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: executing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                key: Key('btn-execute-${device.id}'),
                tooltip: 'Kirim perintah',
                onPressed: onExecute,
                icon: const Icon(Icons.bolt_outlined),
              ),
      ),
    );
  }
}
