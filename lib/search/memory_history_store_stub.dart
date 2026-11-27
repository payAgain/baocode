Future<T> runHistoryIndexBuild<T>(T Function() build) async => build();

/// Web has no durable host-side history cache.
final class MemoryHistoryStore {
  MemoryHistoryStore(String? path);

  bool get enabled => false;

  Future<String?> read(String key) async => null;

  Future<void> write(String key, String data) async {}

  Future<void> remove(String key) async {}

  Future<void> removeBot(String key) async {}
}
