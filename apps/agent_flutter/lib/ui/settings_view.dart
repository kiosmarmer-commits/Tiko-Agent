import 'package:flutter/material.dart';

import 'settings_store.dart';
import 'theme.dart';

/// Callback signature mirroring the existing connection update flow.
typedef OnConnect = void Function({required String base, required String tok});

/// Unified settings screen (UI-SET) used by the desktop rail, the mobile
/// "More" page and the web build: appearance, connection, behaviour.
class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.settings,
    required this.baseUrl,
    required this.token,
    required this.online,
    required this.onConnect,
    required this.onSettingsChanged,
    this.daemonCard,
  });

  final AppSettings settings;
  final String baseUrl;
  final String token;
  final bool online;
  final OnConnect onConnect;
  final void Function(AppSettings) onSettingsChanged;
  final Widget? daemonCard;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final _formKey = GlobalKey<FormState>();
  late final baseC = TextEditingController(text: widget.baseUrl);
  late final tokC = TextEditingController(text: widget.token);

  @override
  void dispose() {
    baseC.dispose();
    tokC.dispose();
    super.dispose();
  }

  void _update(AppSettings next) {
    widget.onSettingsChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final settings = widget.settings;
    return ListView(
      padding: const EdgeInsets.all(SimpulTheme.xl),
      children: [
        _sectionTitle(context, 'Tampilan'),
        _panel(
          brightness,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: const Text('Mode tema'),
                trailing: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.settings_suggest_outlined),
                      label: Text('Sistem'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined),
                      label: Text('Gelap'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined),
                      label: Text('Terang'),
                    ),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (selection) => _update(
                    settings.copyWith(themeMode: selection.first),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.color_lens_outlined),
                title: const Text('Warna aksen'),
                subtitle: Wrap(
                  spacing: SimpulTheme.m,
                  children: [
                    for (final accent in AppSettings.accents)
                      _accentDot(settings.accent, accent),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpulTheme.xxl),
        _sectionTitle(context, 'Koneksi'),
        _panel(
          brightness,
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: baseC,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'API base URL',
                    hintText: 'http://127.0.0.1:8787',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final uri = Uri.tryParse((value ?? '').trim());
                    if (uri == null ||
                        !uri.hasAuthority ||
                        uri.host.isEmpty ||
                        !const ['http', 'https'].contains(uri.scheme) ||
                        uri.userInfo.isNotEmpty ||
                        uri.hasQuery ||
                        uri.hasFragment) {
                      return 'Masukkan URL HTTP(S) yang valid.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: SimpulTheme.l),
                TextFormField(
                  controller: tokC,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Bearer token',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Bearer token wajib diisi.'
                      : null,
                ),
                const SizedBox(height: SimpulTheme.l),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (!_formKey.currentState!.validate()) return;
                      widget.onConnect(
                        base: baseC.text.trim().replaceFirst(RegExp(r'/+$'), ''),
                        tok: tokC.text.trim(),
                      );
                    },
                    child: const Text('Simpan & hubungkan'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: SimpulTheme.xxl),
        _sectionTitle(context, 'Perilaku'),
        _panel(
          brightness,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Host Ollama'),
                subtitle: Text(
                  settings.ollamaHost,
                  style: TextStyle(
                    color: SimpulTheme.mutedText(brightness),
                  ),
                ),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editText(
                  title: 'Host Ollama',
                  initial: settings.ollamaHost,
                  onSubmit: (value) => _update(
                    settings.copyWith(ollamaHost: value),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Path vault'),
                subtitle: Text(
                  settings.vaultPath.isEmpty ? '(belum diatur)' : settings.vaultPath,
                  style: TextStyle(
                    color: SimpulTheme.mutedText(brightness),
                  ),
                ),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editText(
                  title: 'Path vault',
                  initial: settings.vaultPath,
                  onSubmit: (value) =>
                      _update(settings.copyWith(vaultPath: value)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.lock_clock_outlined),
                title: const Text('Auto-lock (menit, 0 = mati)'),
                trailing: SizedBox(
                  width: 96,
                  child: TextFormField(
                    initialValue: '${settings.autoLockMinutes}',
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onFieldSubmitted: (value) {
                      final minutes = int.tryParse(value.trim()) ?? 0;
                      _update(
                        settings.copyWith(
                          autoLockMinutes: minutes.clamp(0, 240),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.daemonCard != null) ...[
          const SizedBox(height: SimpulTheme.xxl),
          _sectionTitle(context, 'Daemon'),
          widget.daemonCard!,
        ],
        const SizedBox(height: SimpulTheme.xl),
        Text(
          'Pengaturan tersimpan lokal per perangkat (shared_preferences) dan '
          'dipakai oleh desktop, web, dan Android.',
          style: TextStyle(
            color: SimpulTheme.mutedText(brightness),
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _accentDot(Color current, Color accent) {
    final selected = current.toARGB32() == accent.toARGB32();
    return GestureDetector(
      onTap: () => _update(widget.settings.copyWith(accent: accent)),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: accent,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 3,
          ),
        ),
      ),
    );
  }

  Future<void> _editText({
    required String title,
    required String initial,
    required void Function(String) onSubmit,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final trimmed = value.trim();
    if (trimmed == initial) return;
    onSubmit(trimmed);
  }

  Widget _panel(Brightness brightness, {required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(SimpulTheme.l),
        decoration: SimpulTheme.panelBox(brightness),
        child: Material(
          type: MaterialType.transparency,
          child: child,
        ),
      );

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: SimpulTheme.m),
        child: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      );
}
