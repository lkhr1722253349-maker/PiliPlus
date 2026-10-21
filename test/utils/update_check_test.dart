import 'package:PiliPlus/utils/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 2026-10-21T04:13:45Z, the 2.1.7 release that was published later than the
  // commit its tag points at (2026-10-19T06:24:23Z).
  const published = '2026-10-21T04:13:45Z';
  const createdAt = '2026-10-19T06:24:23Z';
  final publishedEpoch = DateTime.parse(published).millisecondsSinceEpoch ~/ 1000;
  final createdEpoch = DateTime.parse(createdAt).millisecondsSinceEpoch ~/ 1000;

  test('a re-published tag is newer even though created_at is older', () {
    // Installed build was made after the tag's commit but before publication.
    final builtAt = createdEpoch + 3600;
    expect(
      Update.isNewer(
        tagName: '2.1.7',
        publishedAt: published,
        createdAt: createdAt,
        installedVersion: '2.1.6-91093ee71',
        installedBuildTime: builtAt,
      ),
      isTrue,
      reason: 'published_at must win over the stale tag commit time',
    );
    expect(
      builtAt < publishedEpoch,
      isTrue,
      reason: 'the scenario relies on the build predating publication',
    );
  });

  test('the installed build of the same release is not newer', () {
    expect(
      Update.isNewer(
        tagName: '2.1.7',
        publishedAt: published,
        createdAt: createdAt,
        installedVersion: '2.1.7-d6a2b33d0',
        installedBuildTime: publishedEpoch + 60,
      ),
      isFalse,
    );
  });

  test('a different version name always offers the update', () {
    // Same timestamps, different version: the name is the stronger signal.
    expect(
      Update.isNewer(
        tagName: '2.1.8',
        publishedAt: published,
        createdAt: createdAt,
        installedVersion: '2.1.7-d6a2b33d0',
        installedBuildTime: publishedEpoch + 60,
      ),
      isTrue,
    );
  });

  test('the v prefix and build suffix do not change the version', () {
    expect(
      Update.isNewer(
        tagName: 'v2.1.7',
        publishedAt: published,
        createdAt: createdAt,
        installedVersion: '2.1.7-d6a2b33d0',
        installedBuildTime: publishedEpoch + 60,
      ),
      isFalse,
    );
    expect(
      Update.isNewer(
        tagName: '2.1.7+5516',
        publishedAt: published,
        createdAt: createdAt,
        installedVersion: '2.1.7-d6a2b33d0',
        installedBuildTime: publishedEpoch + 60,
      ),
      isFalse,
    );
  });

  test('a release published later with the same version is newer', () {
    expect(
      Update.isNewer(
        tagName: '2.1.7',
        publishedAt: published,
        createdAt: createdAt,
        installedVersion: '2.1.7-oldhash',
        installedBuildTime: createdEpoch,
      ),
      isTrue,
      reason: 'a rebuild of the same version is still a newer build',
    );
  });

  test('missing timestamps fall back to the version name only', () {
    expect(
      Update.isNewer(
        tagName: '2.1.7',
        publishedAt: null,
        createdAt: null,
        installedVersion: '2.1.7-abc',
        installedBuildTime: 0,
      ),
      isFalse,
    );
    expect(
      Update.isNewer(
        tagName: '2.1.8',
        publishedAt: null,
        createdAt: null,
        installedVersion: '2.1.7-abc',
        installedBuildTime: 0,
      ),
      isTrue,
    );
  });
}
