import 'dart:async';

import 'package:agent_flutter/data/admin_event_feed.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GUI-P2-06: burst event dikoaleskan menjadi satu refresh', () {
    fakeAsync((async) {
      var refreshes = 0;
      final controller =
          StreamController<Map<String, dynamic>>.broadcast();
      final feed = AdminEventFeed(
        events: controller.stream,
        onRefresh: () async => refreshes++,
      )..start();

      for (var i = 0; i < 5; i++) {
        controller.add({'type': 'job.started', 'id': 'jb_$i'});
        async.elapse(const Duration(milliseconds: 200));
      }
      expect(feed.received, 5);
      expect(feed.pendingRefresh, isTrue);
      expect(refreshes, 0);

      async.elapse(const Duration(seconds: 1));
      expect(refreshes, 1);

      controller.add({'type': 'job.completed', 'id': 'jb_0'});
      async.elapse(const Duration(seconds: 2));
      expect(refreshes, 2);

      feed.dispose();
      controller.close();
    });
  });

  test('GUI-P2-06: koneksi putus diputar ulang dengan backoff berlipat',
      () {
    fakeAsync((async) {
      final controller =
          StreamController<Map<String, dynamic>>.broadcast();
      var refreshes = 0;
      final feed = AdminEventFeed(
        events: controller.stream,
        onRefresh: () async => refreshes++,
      )..start();

      controller.add({'type': 'model.switched'});
      async.elapse(const Duration(milliseconds: 1));
      async.elapse(const Duration(seconds: 2));
      expect(refreshes, 1);
      expect(feed.nextRetryDelay, Duration.zero);

      unawaited(controller.close());
      async.elapse(const Duration(milliseconds: 1));
      expect(feed.nextRetryDelay, const Duration(seconds: 2));

      async.elapse(const Duration(seconds: 2));
      expect(feed.nextRetryDelay, const Duration(seconds: 4));

      async.elapse(const Duration(seconds: 4));
      expect(feed.nextRetryDelay, const Duration(seconds: 8));

      feed.dispose();
      controller.close();
    });
  });

  test('GUI-P2-06: error memicu reconnect dan event lanjutan tetap diproses',
      () {
    fakeAsync((async) {
      final controller =
          StreamController<Map<String, dynamic>>.broadcast();
      var refreshes = 0;
      final feed = AdminEventFeed(
        events: controller.stream,
        onRefresh: () async => refreshes++,
      )..start();

      controller.addError(StateError('boom'));
      async.elapse(const Duration(seconds: 2, milliseconds: 1));
      expect(feed.received, 0);
      expect(refreshes, 0);

      controller
        ..add({'type': 'approval.pending', 'id': 'apr_1'})
        ..add({'type': 'approval.decided', 'id': 'apr_1'});
      async.elapse(const Duration(seconds: 2));
      expect(feed.received, 2);
      expect(refreshes, greaterThanOrEqualTo(1));
      expect(feed.nextRetryDelay, Duration.zero);

      feed.dispose();
      controller.close();
    });
  });

  test('GUI-P2-06: backoff berlipat saat gagal berulang dan dibatasi maxDelay',
      () {
    fakeAsync((async) {
      Stream<Map<String, dynamic>> failing() => Stream.multi(
            (out) => out.addError(StateError('boom')),
          );
      final feed = AdminEventFeed(
        events: failing(),
        onRefresh: () async {},
      )..start();

      async.elapse(const Duration(hours: 6));
      expect(feed.nextRetryDelay, const Duration(seconds: 60));

      feed.dispose();
    });
  });
}
