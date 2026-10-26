typedef Data = Map<String, dynamic>;
List<Data> records(dynamic value) => value is List
    ? value.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
    : [];
List<String> labels(dynamic value) =>
    value is List ? value.map((v) => v.toString()).toList() : [];
