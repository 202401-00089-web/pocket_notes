// Unit tests for the Pocket Notes model code.
// These need no phone or database: they only test plain Dart logic.
// Run with:  flutter test

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_notes/main.dart';

void main() {
  group('FieldSpec.parse', () {
    test('trims text and returns it', () {
      const field = FieldSpec('title', 'Title', FieldKind.text, required: true);
      expect(field.parse('  Rose  '), 'Rose');
    });

    test('empty optional field becomes null', () {
      const field = FieldSpec('artist', 'Artist', FieldKind.text);
      expect(field.parse('   '), isNull);
    });

    test('empty required field throws', () {
      const field = FieldSpec('title', 'Title', FieldKind.text, required: true);
      expect(() => field.parse(''), throwsFormatException);
    });

    test('integer and real fields convert to numbers', () {
      const reps = FieldSpec('reps', 'Reps', FieldKind.integer);
      const amount = FieldSpec('amount', 'Amount', FieldKind.real);
      expect(reps.parse('12'), 12);
      expect(amount.parse('9.5'), 9.5);
      expect(() => reps.parse('abc'), throwsFormatException);
    });

    test('date field keeps only YYYY-MM-DD', () {
      const due = FieldSpec('due_date', 'Due date', FieldKind.date);
      expect(due.parse('2026-11-30'), '2026-11-30');
      expect(() => due.parse('tomorrow'), throwsFormatException);
    });
  });

  group('NoteRecord', () {
    test('toMap leaves out id when it is null (insert)', () {
      const record = NoteRecord(
        type: RecordType.plants,
        values: {'plant_name': 'Fern', 'watering_notes': null},
      );
      final map = record.toMap();
      expect(map.containsKey('id'), isFalse);
      expect(map['plant_name'], 'Fern');
      expect(map['watering_notes'], isNull);
    });

    test('toMap includes id when it exists (update)', () {
      const record = NoteRecord(
        id: 3,
        type: RecordType.plants,
        values: {'plant_name': 'Fern', 'watering_notes': 'Daily'},
      );
      expect(record.toMap()['id'], 3);
    });

    test('toMap throws when a required field is missing', () {
      const record = NoteRecord(
        type: RecordType.plants,
        values: {'plant_name': null, 'watering_notes': 'Daily'},
      );
      expect(record.toMap, throwsArgumentError);
    });

    test('fromMap rebuilds the record, nullable column stays null', () {
      final record = NoteRecord.fromMap(
        RecordType.gymLog,
        {'id': 7, 'exercise': 'Squat', 'reps': null},
      );
      expect(record.id, 7);
      expect(record.values['exercise'], 'Squat');
      expect(record.values['reps'], isNull);
      expect(record.display(1), '');
    });
  });

  group('RecordType', () {
    test('every type has two fields and a table name', () {
      expect(RecordType.values.length, 10);
      for (final type in RecordType.values) {
        expect(type.fields.length, 2);
        expect(type.table, isNotEmpty);
      }
    });
  });
}
