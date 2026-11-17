// Pocket Notes - lib/main.dart
//
// One file, three jobs:
//   1. Data model + SQLite database (sqflite), opened ONCE (singleton).
//   2. Theme persistence (shared_preferences -> SharedPreferencesAsync).
//   3. A plain UI: one list screen, an add/edit dialog, and a theme switch.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

// ---------------------------------------------------------------------------
// The record type shown when the app opens (last digit of your class number).
// The chips on the screen let you switch between all 10 types.
// ---------------------------------------------------------------------------
const RecordType kActiveType = RecordType.plants;

// ===========================================================================
// 1. RECORD TYPES AND MODEL
// ===========================================================================

/// How a field is stored. Each kind maps to a proper SQLite column type.
enum FieldKind {
  text('TEXT'),
  integer('INTEGER'),
  real('REAL'),
  date('TEXT'); // SQLite has no date type; we store ISO-8601 text (2026-11-30).

  const FieldKind(this.sqlType);
  final String sqlType;
}

/// Describes one column (besides id) of a record type.
class FieldSpec {
  const FieldSpec(this.column, this.label, this.kind, {this.required = false});

  final String column; // SQLite column name
  final String label; // text shown in the UI
  final FieldKind kind;
  final bool required; // required -> NOT NULL, optional -> nullable

  /// Converts what the user typed into the right Dart type.
  /// Returns null for an empty optional field. Throws [FormatException]
  /// with a friendly message when the input is invalid.
  Object? parse(String input) {
    final text = input.trim();
    if (text.isEmpty) {
      if (required) throw FormatException('$label is required');
      return null; // nullable field left blank
    }
    return switch (kind) {
      FieldKind.text => text,
      FieldKind.integer =>
        int.tryParse(text) ?? _invalid('a whole number, e.g. 12'),
      FieldKind.real =>
        double.tryParse(text) ?? _invalid('a number, e.g. 9.5'),
      FieldKind.date => DateTime.tryParse(text)
              ?.toIso8601String()
              .split('T')
              .first ??
          _invalid('a date like 2026-11-30'),
    };
  }

  Never _invalid(String expected) =>
      throw FormatException('$label must be $expected');
}

/// The 10 record types. Each one becomes its own table.
enum RecordType {
  songs('songs', 'Songs', [
    FieldSpec('title', 'Title', FieldKind.text, required: true),
    FieldSpec('artist', 'Artist', FieldKind.text),
  ]),
  expenses('expenses', 'Expenses', [
    FieldSpec('item', 'Item', FieldKind.text, required: true),
    FieldSpec('amount', 'Amount', FieldKind.real, required: true),
  ]),
  tasks('tasks', 'Tasks', [
    FieldSpec('task', 'Task', FieldKind.text, required: true),
    FieldSpec('due_date', 'Due date (YYYY-MM-DD)', FieldKind.date),
  ]),
  plants('plants', 'Plants', [
    FieldSpec('plant_name', 'Plant name', FieldKind.text, required: true),
    FieldSpec('watering_notes', 'Watering notes', FieldKind.text),
  ]),
  contacts('contacts', 'Contacts', [
    FieldSpec('name', 'Name', FieldKind.text, required: true),
    FieldSpec('phone_number', 'Phone number', FieldKind.text), // text keeps +63 and leading 0
  ]),
  gymLog('gym_log', 'Gym Log', [
    FieldSpec('exercise', 'Exercise', FieldKind.text, required: true),
    FieldSpec('reps', 'Reps', FieldKind.integer),
  ]),
  recipes('recipes', 'Recipes', [
    FieldSpec('dish', 'Dish', FieldKind.text, required: true),
    FieldSpec('ingredients', 'Ingredients', FieldKind.text),
  ]),
  books('books', 'Books', [
    FieldSpec('title', 'Title', FieldKind.text, required: true),
    FieldSpec('author', 'Author', FieldKind.text),
  ]),
  movies('movies', 'Movies', [
    FieldSpec('title', 'Title', FieldKind.text, required: true),
    FieldSpec('rating', 'Rating', FieldKind.real),
  ]),
  classSchedule('class_schedule', 'Class Schedule', [
    FieldSpec('subject', 'Subject', FieldKind.text, required: true),
    FieldSpec('room', 'Room', FieldKind.text),
  ]);

  const RecordType(this.table, this.label, this.fields);

  final String table; // table name in SQLite
  final String label; // title shown in the UI
  final List<FieldSpec> fields; // the two fields, besides id
}

/// One row of any record type.
/// (Named NoteRecord because `Record` is already a built-in Dart 3 class.)
class NoteRecord {
  const NoteRecord({this.id, required this.type, required this.values});

  /// null until the database assigns one (AUTOINCREMENT) on insert.
  final int? id;
  final RecordType type;

  /// column name -> value (String, int, double, or null).
  final Map<String, Object?> values;

  /// Record -> Map that sqflite can write to the database.
  Map<String, Object?> toMap() {
    final map = <String, Object?>{};
    for (final field in type.fields) {
      final value = values[field.column];
      if (field.required && value == null) {
        throw ArgumentError('${field.label} is required');
      }
      map[field.column] = value;
    }
    if (id != null) map['id'] = id; // omit on insert so SQLite creates it
    return map;
  }

  /// Database row -> Record. Nullable columns simply come back as null.
  factory NoteRecord.fromMap(RecordType type, Map<String, Object?> map) {
    return NoteRecord(
      id: map['id'] as int?,
      type: type,
      values: {for (final f in type.fields) f.column: map[f.column]},
    );
  }

  /// Text for a field, or '' when it is null.
  String display(int fieldIndex) =>
      values[type.fields[fieldIndex].column]?.toString() ?? '';
}

// ===========================================================================
// 2. DATABASE HELPER (SINGLETON - opened once, reused everywhere)
// ===========================================================================

class DatabaseHelper {
  // Private constructor: nobody else can create a second helper.
  DatabaseHelper._();

  /// The one and only helper. `static final` is created once per app run.
  static final DatabaseHelper instance = DatabaseHelper._();

  static const _dbName = 'pocket_notes.db';
  static const _dbVersion = 1;

  /// We cache the *Future*, not the finished Database. If two parts of the
  /// app ask for the database at the same moment, both get the same Future,
  /// so the file is never opened twice.
  Future<Database>? _dbFuture;

  /// Always use this getter. `??=` means: "open only if not opened yet".
  Future<Database> get database => _dbFuture ??= _open();

  Future<Database> _open() async {
    try {
      final path = p.join(await getDatabasesPath(), _dbName);
      return await openDatabase(path, version: _dbVersion, onCreate: _onCreate);
    } catch (e) {
      _dbFuture = null; // allow a retry later if opening failed
      debugPrint('Could not open database: $e');
      rethrow;
    }
  }

  /// Runs only the first time the database file is created.
  Future<void> _onCreate(Database db, int version) async {
    for (final type in RecordType.values) {
      final columns = type.fields
          .map((f) => '${f.column} ${f.kind.sqlType}${f.required ? ' NOT NULL' : ''}')
          .join(', ');
      // Table/column names come from our enum constants, never from user input.
      await db.execute(
        'CREATE TABLE ${type.table} '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, $columns)',
      );
    }
  }

  // ---- CREATE ------------------------------------------------------------
  /// Inserts a record and returns its new id.
  Future<int> insertRecord(NoteRecord record) async {
    try {
      final db = await database;
      return await db.insert(record.type.table, record.toMap());
    } on DatabaseException catch (e) {
      debugPrint('Insert failed: $e');
      rethrow;
    }
  }

  // ---- READ --------------------------------------------------------------
  /// Returns every record of one type, oldest first.
  Future<List<NoteRecord>> getRecords(RecordType type) async {
    try {
      final db = await database;
      final rows = await db.query(type.table, orderBy: 'id ASC');
      return rows.map((row) => NoteRecord.fromMap(type, row)).toList();
    } on DatabaseException catch (e) {
      debugPrint('Query failed: $e');
      rethrow;
    }
  }

  // ---- UPDATE ------------------------------------------------------------
  /// Updates the row with the same id. Returns how many rows changed.
  Future<int> updateRecord(NoteRecord record) async {
    final id = record.id;
    if (id == null) throw ArgumentError('Cannot update a record without an id');
    try {
      final db = await database;
      return await db.update(
        record.type.table,
        record.toMap(),
        where: 'id = ?', // `?` is a placeholder...
        whereArgs: [id], // ...filled safely here (no SQL injection)
      );
    } on DatabaseException catch (e) {
      debugPrint('Update failed: $e');
      rethrow;
    }
  }

  // ---- DELETE ------------------------------------------------------------
  /// Deletes the row with this id. Returns how many rows were removed.
  Future<int> deleteRecord(RecordType type, int id) async {
    try {
      final db = await database;
      return await db.delete(
        type.table,
        where: 'id = ?',
        whereArgs: [id],
      );
    } on DatabaseException catch (e) {
      debugPrint('Delete failed: $e');
      rethrow;
    }
  }

  /// Prints raw rows to the console (handy for the "database proof" capture).
  Future<void> debugDumpTable(RecordType type) async {
    final db = await database;
    debugPrint('${type.table}: ${await db.query(type.table)}');
  }
}

// ===========================================================================
// 3. THEME CONTROLLER (saved with SharedPreferencesAsync)
// ===========================================================================

class ThemeController extends ChangeNotifier {
  ThemeController._(this._prefs, this._mode);

  static const _key = 'is_dark_mode';

  final SharedPreferencesAsync _prefs;
  ThemeMode _mode;

  ThemeMode get mode => _mode;
  bool get isDark => _mode == ThemeMode.dark;

  /// Reads the saved choice. Called in main() BEFORE runApp, so the very
  /// first frame already uses the right theme (no wrong-theme flash).
  static Future<ThemeController> load() async {
    final prefs = SharedPreferencesAsync();
    bool isDark = false; // first launch (nothing saved yet) -> light
    try {
      isDark = await prefs.getBool(_key) ?? false;
    } catch (e) {
      debugPrint('Could not read theme: $e');
    }
    return ThemeController._(prefs, isDark ? ThemeMode.dark : ThemeMode.light);
  }

  /// Called when the user flips the switch: update the UI, then save.
  Future<void> setDark(bool value) async {
    _mode = value ? ThemeMode.dark : ThemeMode.light;
    notifyListeners(); // rebuild the app with the new theme immediately
    try {
      await _prefs.setBool(_key, value); // written to disk, survives force-kill
    } catch (e) {
      debugPrint('Could not save theme: $e');
    }
  }
}

// ===========================================================================
// 4. APP + UI  (new look: collapsing header, theme card, cards, bottom sheet)
// ===========================================================================

Future<void> main() async {
  // Needed because we use plugins (platform channels) before runApp().
  WidgetsFlutterBinding.ensureInitialized();

  // Wait for the saved theme first, then draw the first frame.
  final themeController = await ThemeController.load();

  runApp(PocketNotesApp(themeController: themeController));
}

/// Builds one theme (light or dark) so both share the same styling.
ThemeData _buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF7B4FD6), // violet
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  );
}

/// Picks an icon for each record type.
extension RecordTypeIcon on RecordType {
  IconData get icon => switch (this) {
        RecordType.songs => Icons.music_note,
        RecordType.expenses => Icons.payments,
        RecordType.tasks => Icons.task_alt,
        RecordType.plants => Icons.local_florist,
        RecordType.contacts => Icons.contact_phone,
        RecordType.gymLog => Icons.fitness_center,
        RecordType.recipes => Icons.restaurant_menu,
        RecordType.books => Icons.menu_book,
        RecordType.movies => Icons.movie,
        RecordType.classSchedule => Icons.schedule,
      };
}

class PocketNotesApp extends StatelessWidget {
  const PocketNotesApp({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    // Rebuilds MaterialApp whenever the theme changes.
    return ListenableBuilder(
      listenable: themeController,
      builder: (context, _) {
        return MaterialApp(
          title: 'Pocket Notes',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          themeMode: themeController.mode,
          home: HomeScreen(themeController: themeController),
        );
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = DatabaseHelper.instance; // always the same instance
  RecordType _type = kActiveType; // which of the 10 record types is showing
  List<NoteRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords(); // load from SQLite when the screen starts
  }

  Future<void> _loadRecords() async {
    final type = _type; // remember which type we asked for
    try {
      final records = await _db.getRecords(type);
      if (kDebugMode) await _db.debugDumpTable(type);
      // Ignore the result if the screen is gone or the user already
      // switched to another type while we were waiting.
      if (!mounted || type != _type) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('Could not load records.');
    }
  }

  /// Called when the user taps one of the type chips.
  void _changeType(RecordType type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      _records = [];
      _loading = true;
    });
    _loadRecords();
  }

  Future<NoteRecord?> _openSheet({NoteRecord? existing}) {
    return showModalBottomSheet<NoteRecord>(
      context: context,
      isScrollControlled: true, // lets the sheet rise above the keyboard
      showDragHandle: true,
      builder: (_) => _RecordSheet(type: _type, existing: existing),
    );
  }

  Future<void> _addRecord() async {
    final record = await _openSheet();
    if (record == null) return; // user cancelled
    await _runAndReload(() => _db.insertRecord(record), 'add');
  }

  Future<void> _editRecord(NoteRecord existing) async {
    final updated = await _openSheet(existing: existing);
    if (updated == null) return;
    await _runAndReload(() => _db.updateRecord(updated), 'update');
  }

  Future<void> _deleteRecord(NoteRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('Delete this record?'),
        content: Text('"${record.display(0)}" will be removed for good.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runAndReload(
      () => _db.deleteRecord(record.type, record.id!),
      'delete',
    );
  }

  /// Runs a database action, then refreshes the list. Shows a message on error.
  Future<void> _runAndReload(Future<void> Function() action, String verb) async {
    try {
      await action();
      await _loadRecords();
    } catch (e) {
      _showError('Could not $verb the record.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Big header that shrinks as you scroll.
          SliverAppBar.large(
            title: Text('My ${_type.label}'),
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Icon(_type.icon, color: scheme.primary),
            ),
          ),

          // Theme card with the light/dark switch.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ListenableBuilder(
                listenable: widget.themeController,
                builder: (context, _) {
                  final isDark = widget.themeController.isDark;
                  return Card.filled(
                    child: SwitchListTile(
                      secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
                      title: Text(isDark ? 'Dark mode' : 'Light mode'),
                      subtitle: const Text('Remembered next time you open the app'),
                      value: isDark,
                      onChanged: widget.themeController.setDark, // also saves
                    ),
                  );
                },
              ),
            ),
          ),

          // Chips for all 10 record types.
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                itemCount: RecordType.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final type = RecordType.values[index];
                  return ChoiceChip(
                    avatar: Icon(type.icon, size: 18),
                    label: Text(type.label),
                    selected: type == _type,
                    onSelected: (_) => _changeType(type),
                  );
                },
              ),
            ),
          ),

          // Loading / empty / list.
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_records.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(type: _type),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(
                  '${_records.length} saved',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              sliver: SliverList.separated(
                itemCount: _records.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final record = _records[index];
                  return _RecordCard(
                    record: record,
                    onEdit: () => _editRecord(record),
                    onDelete: () => _deleteRecord(record),
                  );
                },
              ),
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRecord,
        icon: const Icon(Icons.add),
        label: Text('New ${_type.label}'),
      ),
    );
  }
}

/// Shown when the table has no rows.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.type});

  final RecordType type;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(type.icon, size: 72, color: scheme.primary.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('Nothing here yet', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Tap the button below to add your first one.'),
        ],
      ),
    );
  }
}

/// One record shown as a rounded card with an edit/delete menu.
class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.onEdit,
    required this.onDelete,
  });

  final NoteRecord record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final second = record.display(1);
    return Card.outlined(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onEdit,
        contentPadding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          child: Text('${record.id}'), // the database id, handy for proof shots
        ),
        title: Text(
          record.display(0),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(second.isEmpty ? '-' : second),
        trailing: PopupMenuButton<String>(
          onSelected: (choice) => choice == 'edit' ? onEdit() : onDelete(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }
}

/// Add/edit form shown in a bottom sheet (one text field per record field).
class _RecordSheet extends StatefulWidget {
  const _RecordSheet({required this.type, this.existing});

  final RecordType type;
  final NoteRecord? existing; // null = adding, non-null = editing

  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<_RecordSheet> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final f in widget.type.fields)
        f.column: TextEditingController(
          text: widget.existing?.values[f.column]?.toString() ?? '',
        ),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final values = {
      for (final f in widget.type.fields)
        f.column: f.parse(_controllers[f.column]!.text),
    };
    Navigator.pop(
      context,
      NoteRecord(id: widget.existing?.id, type: widget.type, values: values),
    );
  }

  TextInputType _keyboardFor(FieldKind kind) => switch (kind) {
        FieldKind.integer => TextInputType.number,
        FieldKind.real => const TextInputType.numberWithOptions(decimal: true),
        FieldKind.date => TextInputType.datetime,
        FieldKind.text => TextInputType.text,
      };

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Padding(
      // Keeps the form above the on-screen keyboard.
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isEditing
                    ? 'Edit ${widget.type.label}'
                    : 'New ${widget.type.label}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              for (final f in widget.type.fields) ...[
                TextFormField(
                  controller: _controllers[f.column],
                  decoration: InputDecoration(labelText: f.label),
                  keyboardType: _keyboardFor(f.kind),
                  validator: (text) {
                    try {
                      f.parse(text ?? '');
                      return null; // valid
                    } on FormatException catch (e) {
                      return e.message; // shown under the field
                    }
                  },
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      child: Text(isEditing ? 'Save changes' : 'Add'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
