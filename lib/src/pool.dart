/// An object managed by a [Pool].
mixin Pooled {
  /// Returns the object back to its pool.
  void release();
}

/// A simple pool of objects.
class Pool<T extends Pooled> {
  final List<T> _pool = [];
  final List<T> _inUse = [];
  final T Function() _objFactory;
  int _objectsCreated = 0;

  /// Create a new pool.
  ///
  /// [objectFactory] is the function used to create new objects if
  /// [getObject] is called and the pool is entirely used up. This cannot be
  /// null.
  Pool(T Function() objectFactory) : _objFactory = objectFactory {
    ArgumentError.checkNotNull(_objFactory);
  }

  /// The number of objects created by the pool.
  int get objectsCreated => _objectsCreated;

  /// The number of objects that have not been released back into the pool.
  int get objectsInUse => _inUse.length;

  /// The number of available objects in the pool.
  int get objectsNotInUse => _pool.length;

  /// The number of objects in the pool (both in use and available).
  int get totalObjects => objectsInUse + objectsNotInUse;

  /// Retrieve an object from the pool. If none are available, a new object
  /// is created.
  T getObject() {
    T item;
    if (_pool.isNotEmpty) {
      item = _pool.removeLast();
    } else {
      _objectsCreated++;
      item = _objFactory.call();
    }

    if (_inUse.contains(item)) {
      throw StateError('Duplicate pull from pool: ${item?.runtimeType}');
    }

    _inUse.add(item);
    return item;
  }

  /// Return an object to the pool.
  void putObject(T item) {
    if (_inUse.contains(item)) {
      _inUse.remove(item);
      _pool.add(item);
    }
  }
}
