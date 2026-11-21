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
  String photo; // путь к файлу на этом телефоне
  String photoRemote; // имя фото в облаке (для синхронизации)
  int createdAt;
  int updatedAt;
  bool mute; // не присылать уведомления об этом товаре

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
    this.photoRemote = '',
    this.mute = false,
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? 0;

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
        'photoRemote': photoRemote,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'mute': mute,
      };

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: (j['id'] ?? newId()).toString(),
        name: (j['name'] ?? '').toString(),
        nameRu: (j['nameRu'] ?? '').toString(),
        category: (j['category'] ?? 'other').toString(),
        barcode: (j['barcode'] ?? '').toString(),
        expiry: (j['expiry'] ?? '').toString(),
        notes: (j['notes'] ?? '').toString(),
        qty: (j['qty'] is num) ? (j['qty'] as num).toInt() : 1,
        photo: (j['photo'] ?? '').toString(),
        photoRemote: (j['photoRemote'] ?? '').toString(),
        createdAt: (j['createdAt'] is num) ? (j['createdAt'] as num).toInt() : null,
        updatedAt: (j['updatedAt'] is num) ? (j['updatedAt'] as num).toInt() : 0,
        mute: j['mute'] == true,
      );
}

class Product {
  String name, nameRu, category, photo, photoRemote;
  int updatedAt;
  Product(
      {this.name = '',
      this.nameRu = '',
      this.category = 'other',
      this.photo = '',
      this.photoRemote = '',
      this.updatedAt = 0});
  Map<String, dynamic> toJson() => {
        'name': name,
        'nameRu': nameRu,
        'category': category,
        'photo': photo,
        'photoRemote': photoRemote,
        'updatedAt': updatedAt,
      };
  factory Product.fromJson(Map<String, dynamic> j) => Product(
        name: (j['name'] ?? '').toString(),
        nameRu: (j['nameRu'] ?? '').toString(),
        category: (j['category'] ?? 'other').toString(),
        photo: (j['photo'] ?? '').toString(),
        photoRemote: (j['photoRemote'] ?? '').toString(),
        updatedAt: (j['updatedAt'] is num) ? (j['updatedAt'] as num).toInt() : 0,
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
  return '${e.year}.${e.month.toString().padLeft(2, '0')}.${e.day.toString().padLeft(2, '0')}'; // ГГГГ.ММ.ДД — по-корейски, во всех языках
}

String plural(int n, String a, String b, String c) {
  n = n.abs() % 100;
  final n1 = n % 10;
  if (n > 10 && n < 20) return c;
  if (n1 > 1 && n1 < 5) return b;
  if (n1 == 1) return a;
  return c;
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
  'kimchi': ['포기김치', '열무', '오이소박이', '나물', '무침', '조림', '볶음', '절임', '피클', '김치', '반찬', '깍두기', '단무지', '장아찌', '젓갈', 'kimchi'],
  'tofu': ['유부', '순두부', '구운란', '훈제란', '난류', '두부', '계란', '달걀', '메추리', 'egg', 'tofu'],
  'noodle': ['라볶이', '칼국수', '당면', '스파게티', '짬뽕', '비빔면', '컵라면', '사리', '면류', '라면', '우동', '국수', '짜파게티', '냉면', '쫄면', '소바', '파스타', 'noodle', 'ramen', 'pasta'],
  'frozen': ['아이스크림', '빙과', '돈까스', '너겟', '튀김', '냉동피자', '냉동', '아이스', '만두', 'frozen', 'ice cream', 'ice-cream'],
  'milk': ['두유', '라떼', '요플레', '크림치즈', '연유', '가공유', '발효유', '유가공', '우유', '요거트', '요구르트', '치즈', '버터', '생크림', '유제품', 'milk', 'yogurt', 'cheese', 'dairies', 'butter'],
  'meat': ['소불고기', '불고기', '갈비', '족발', '편육', '닭가슴살', '스팸', '런천미트', '미트볼', '식육', '돼지', '소고기', '한우', '닭', '삼겹', '목살', '햄', '소시지', '베이컨', '육포', 'meat', 'sausage', 'ham', 'bacon', 'chicken'],
  'fish': ['김 ', '조미김', '미역', '다시마', '굴', '전복', '홍합', '낙지', '쭈꾸미', '명태', '황태', '갈치', '꽁치', '참치회', '수산물', '생선', '고등어', '연어', '새우', '오징어', '어묵', '수산', '맛살', '멸치', '꽃게', '조개', 'fish', 'seafood', 'shrimp'],
  'sauce': ['카레', '짜장', '드레싱', '와사비', '머스타드', '물엿', '올리고당', '맛술', '액젓', '육수', '다시다', '스톡', '장류', '조미', '소스', '고추장', '된장', '간장', '케첩', '마요', '양념', '식초', '쌈장', '드레싱', 'sauce', 'condiment', 'ketchup'],
  'snack': ['빼빼로', '초코파이', '새우깡', '포카칩', '감자칩', '팝콘', '아몬드', '견과', '양갱', '약과', '사탕', '마이쮸', '디저트', '과자류', '캔디', '과자', '초콜릿', '초코', '사탕', '젤리', '쿠키', '스낵', '칩', '비스킷', '껌', 'snack', 'chocolate', 'candy', 'biscuit', 'cookie', 'chips'],
  'bread': ['크로와상', '모닝빵', '단팥빵', '카스테라', '롤케이크', '도넛', '와플', '빵류', '빵', '식빵', '케이크', '베이커리', '베이글', '머핀', 'bread', 'cake', 'bakery'],
  'ready': ['핫바', '컵반', '죽', '국밥', '찌개', '곰탕', '삼계탕', '갈비탕', '볶음밥', '주먹밥', '햄버거', '피자', '떡볶이', '순대', '어묵탕', '즉석', '간편조리', '도시락', '김밥', '삼각', '즉석', '컵밥', '샌드위치', '밀키트', 'meal', 'sandwich'],
  'veg': ['딸기', '포도', '귤', '오렌지', '키위', '수박', '참외', '복숭아', '고구마', '당근', '오이', '호박', '상추', '깻잎', '파', '마늘', '고추', '콩나물', '숙주', '사과', '배추', '양파', '감자', '바나나', '채소', '야채', '과일', '샐러드', '버섯', '토마토', 'fruit', 'vegetable', 'salad'],
  'drink': ['에이드', '스무디', '두유음료', '식혜', '수정과', '꿀물', '탄산수', '음료수', '와인', '하이볼', '음료류', '다류', '음료', '주스', '콜라', '사이다', '커피', '녹차', '홍차', '생수', '맥주', '소주', '막걸리', '탄산', '이온', '우롱', 'juice', 'drink', 'beverage', 'water', 'coffee', 'tea', 'soda', 'beer'],
  'grocery': ['라면사리', '부침가루', '튀김가루', '전분', '깨', '후추', '김가루', '누룽지', '잡곡', '현미', '오트밀', '꿀', '잼', '쌀', '밀가루', '설탕', '소금', '식용유', '참기름', '통조림', '참치', '햇반', '시리얼', 'flour', 'oil', 'canned', 'rice', 'cereal'],
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
