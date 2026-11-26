enum LibrarySortMode {
  time,
  location,
  people,
}

extension LibrarySortModeX on LibrarySortMode {
  /// AppBar 右上角展示用的中文标题。
  String get label {
    switch (this) {
      case LibrarySortMode.time:
        return '时间';
      case LibrarySortMode.location:
        return '地址';
      case LibrarySortMode.people:
        return '人物';
    }
  }

  /// 传给后端 /api/photos-advanced 的 sort 参数。
  String get apiSortParam {
    switch (this) {
      case LibrarySortMode.time:
        return 'time';
      case LibrarySortMode.location:
        return 'location';
      case LibrarySortMode.people:
        return 'people';
    }
  }
}

