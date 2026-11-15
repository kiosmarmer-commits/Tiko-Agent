import 'dart:io';

import 'package:agent_memory/agent_memory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tiko_runtime/tiko_runtime.dart';

Future<String> _prepare(Directory temp) async {
  final configDir = await Directory(p.join(temp.path, 'config')).create();
  final config = File(p.join(configDir.path, 'agent.yaml'));
  await config.writeAsString(
    TikoConfig.setupYaml(provider: 'mock', workspace: temp.path),
  );
  return config.path;
}

void main() {
  test('/memory menampilkan status memori terkurasi', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_learn_mem_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp);

    final rt = await TikoRuntime.create(configPath: configPath);
    final empty = await rt.chat('/memory');
    expect(empty, contains('Memori terkurasi kosong'));

    rt.curatedMemory.apply(
      CuratedMemoryOps.extract('```memory-ops\nADD MEMORY: deploy port 5433\n```'),
    );
    await rt.curatedMemory.save();

    final filled = await rt.chat('/memory');
    expect(filled, contains('deploy port 5433'));
    expect(filled, contains('/${rt.curatedMemory.charBudget} karakter'));
    await rt.close();
  });

  test('/learn tanpa blok skill-markdown gagap dengan pesan jelas', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_learn_mem_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp);

    final rt = await TikoRuntime.create(configPath: configPath);
    final result = await rt.chatWithStatus('/learn ./docs');
    expect(result.success, isFalse);
    expect(result.text, contains('skill-markdown'));
    await rt.close();
  });

  test('bukan slash command tetap masuk jalur chat normal', () async {
    final temp = await Directory.systemTemp.createTemp('tiko_learn_mem_');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = await _prepare(temp);

    final rt = await TikoRuntime.create(configPath: configPath);
    final answer = await rt.chat('halo');
    expect(answer, isNotEmpty);
    expect(answer, isNot(contains('skill-markdown')));
    await rt.close();
  });
}
