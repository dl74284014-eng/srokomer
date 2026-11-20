import 'package:flutter/material.dart';

class Cat {
  final String k, e, n, ko;
  const Cat(this.k, this.e, this.n, this.ko);
}

const cats = <Cat>[
  Cat('milk', '🥛', 'Молочные', '유제품'),
  Cat('meat', '🥩', 'Мясо и птица', '육류'),
  Cat('fish', '🐟', 'Рыба и морепродукты', '수산'),
  Cat('veg', '🥬', 'Овощи и фрукты', '채소·과일'),
  Cat('kimchi', '🥢', 'Кимчи и панчханы', '김치·반찬'),
  Cat('tofu', '🥚', 'Тофу и яйца', '두부·계란'),
  Cat('noodle', '🍜', 'Рамён и лапша', '라면·면'),
  Cat('ready', '🍱', 'Готовая еда', '간편식'),
  Cat('frozen', '🧊', 'Заморозка', '냉동'),
  Cat('bread', '🍞', 'Хлеб и выпечка', '베이커리'),
  Cat('snack', '🍪', 'Снеки и сладости', '과자'),
  Cat('drink', '🧃', 'Напитки', '음료'),
  Cat('sauce', '🫙', 'Соусы и приправы', '소스·양념'),
  Cat('grocery', '🌾', 'Бакалея', '식품'),
  Cat('other', '📦', 'Другое', '기타'),
];

final Map<String, Cat> catMap = {for (final c in cats) c.k: c};
Cat catOf(String k) => catMap[k] ?? catMap['other']!;

String newId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    (DateTime.now().hashCode % 1000).toString();

class Item {
  String id;
  String name;
  String nameRu;
  String category;
  String barcode;
  String expiry; // YYYY-MM-DD или ''
  String notes;
  int qty;
  String photo; // путь к файлу
  int createdAt;

  Item({
    required this.id,
    this.name = '',
    this.nameRu = '',
    this.category = 'other',
    this.barcode = '',
    this.expiry = '',
    this.notes = '',
    this.qty = 1,
    this.photo = '',
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'nameRu': nameRu,
        'category': category,
        'barcode': barcode,
        'expiry': expiry,
        'notes': notes,
        'qty': qty,
        'photo': photo,
        'createdAt': createdAt,
      };

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: (j['id'] ?? newId()).toString(),
        name: (j['name'] ?? '').toString(),
        nameRu: (j['nameRu'] ?? '').toString(),
        category: (j['category'] ?? 'other').toString(),
        barcode: (j['barcode'] ?? '').toString(),
        expiry: (j['expiry'] ?? '').toString(),
        notes: (j['notes'] ?? '').toString(),
        qty: (j['qty'] is int) ? j['qty'] as int : 1,
        photo: (j['photo'] ?? '').toString(),
        createdAt: (j['createdAt'] is int) ? j['createdAt'] as int : null,
      );
}

class Product {
  String name, nameRu, category, photo;
  Product({this.name = '', this.nameRu = '', this.category = 'other', this.photo = ''});
  Map<String, dynamic> toJson() =>
      {'name': name, 'nameRu': nameRu, 'category': category, 'photo': photo};
  factory Product.fromJson(Map<String, dynamic> j) => Product(
        name: (j['name'] ?? '').toString(),
        nameRu: (j['nameRu'] ?? '').toString(),
        category: (j['category'] ?? 'other').toString(),
        photo: (j['photo'] ?? '').toString(),
      );
}

// ---------- даты ----------
DateTime? parseIso(String s) {
  final p = s.split('-');
  if (p.length != 3) return null;
  final y = int.tryParse(p[0]), m = int.tryParse(p[1]), d = int.tryParse(p[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

String isoOf(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

int? daysLeft(String exp) {
  final e = parseIso(exp);
  if (e == null) return null;
  return (e.difference(today()).inHours / 24).round();
}

String fmtDate(String exp) {
  final e = parseIso(exp);
  if (e == null) return '—';
  return '${e.day.toString().padLeft(2, '0')}.${e.month.toString().padLeft(2, '0')}.${e.year}';
}

String plural(int n, String a, String b, String c) {
  n = n.abs() % 100;
  final n1 = n % 10;
  if (n > 10 && n < 20) return c;
  if (n1 > 1 && n1 < 5) return b;
  if (n1 == 1) return a;
  return c;
}

String leftText(int? dl) {
  if (dl == null) return 'срок не указан';
  if (dl < 0) return 'просрочено ${-dl} ${plural(-dl, 'день', 'дня', 'дней')} назад';
  if (dl == 0) return 'сегодня последний день';
  if (dl == 1) return 'остался 1 день (до завтра)';
  return 'осталось $dl ${plural(dl, 'день', 'дня', 'дней')}';
}

enum Urg { red, orange, yellow, green, none }

Urg urgency(int? dl) {
  if (dl == null) return Urg.none;
  if (dl < 0) return Urg.red;
  if (dl <= 3) return Urg.orange;
  if (dl <= 7) return Urg.yellow;
  return Urg.green;
}

Color urgColor(Urg u) {
  switch (u) {
    case Urg.red:
      return const Color(0xFFD6363B);
    case Urg.orange:
      return const Color(0xFFE5740B);
    case Urg.yellow:
      return const Color(0xFFB88A00);
    case Urg.green:
      return const Color(0xFF2A8A57);
    case Urg.none:
      return const Color(0xFF9E9E9E);
  }
}

Color urgSoft(Urg u) {
  switch (u) {
    case Urg.red:
      return const Color(0xFFFDE8E8);
    case Urg.orange:
      return const Color(0xFFFFF0E0);
    case Urg.yellow:
      return const Color(0xFFFFF7D6);
    case Urg.green:
      return const Color(0xFFE6F4EC);
    case Urg.none:
      return const Color(0xFFEEEEEE);
  }
}

// ---------- угадывание категории по названию ----------
const _catWords = <String, List<String>>{
  'kimchi': ['김치', '반찬', '깍두기', '단무지', '장아찌', '젓갈', 'kimchi'],
  'tofu': ['두부', '계란', '달걀', '메추리', 'egg', 'tofu'],
  'noodle': ['라면', '우동', '국수', '짜파게티', '냉면', '쫄면', '소바', '파스타', 'noodle', 'ramen', 'pasta'],
  'frozen': ['냉동', '아이스', '만두', 'frozen', 'ice cream', 'ice-cream'],
  'milk': ['우유', '요거트', '요구르트', '치즈', '버터', '생크림', '유제품', 'milk', 'yogurt', 'cheese', 'dairies', 'butter'],
  'meat': ['돼지', '소고기', '한우', '닭', '삼겹', '목살', '햄', '소시지', '베이컨', '육포', 'meat', 'sausage', 'ham', 'bacon', 'chicken'],
  'fish': ['생선', '고등어', '연어', '새우', '오징어', '어묵', '수산', '맛살', '멸치', '꽃게', '조개', 'fish', 'seafood', 'shrimp'],
  'sauce': ['소스', '고추장', '된장', '간장', '케첩', '마요', '양념', '식초', '쌈장', '드레싱', 'sauce', 'condiment', 'ketchup'],
  'snack': ['과자', '초콜릿', '초코', '사탕', '젤리', '쿠키', '스낵', '칩', '비스킷', '껌', 'snack', 'chocolate', 'candy', 'biscuit', 'cookie', 'chips'],
  'bread': ['빵', '식빵', '케이크', '베이커리', '베이글', '머핀', 'bread', 'cake', 'bakery'],
  'ready': ['도시락', '김밥', '삼각', '즉석', '컵밥', '샌드위치', '밀키트', 'meal', 'sandwich'],
  'veg': ['사과', '배추', '양파', '감자', '바나나', '채소', '야채', '과일', '샐러드', '버섯', '토마토', 'fruit', 'vegetable', 'salad'],
  'drink': ['음료', '주스', '콜라', '사이다', '커피', '녹차', '홍차', '생수', '맥주', '소주', '막걸리', '탄산', '이온', '우롱', 'juice', 'drink', 'beverage', 'water', 'coffee', 'tea', 'soda', 'beer'],
  'grocery': ['쌀', '밀가루', '설탕', '소금', '식용유', '참기름', '통조림', '참치', '햇반', '시리얼', 'flour', 'oil', 'canned', 'rice', 'cereal'],
};

String guessCategory(String text) {
  final t = text.toLowerCase();
  for (final e in _catWords.entries) {
    for (final w in e.value) {
      if (t.contains(w)) return e.key;
    }
  }
  return 'other';
}
