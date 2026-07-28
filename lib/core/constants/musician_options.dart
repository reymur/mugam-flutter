// Option lists for the "Fəaliyyət növü" (ActivityType) bottom sheet, used by
// both EditProfileScreen and RegisterScreen — see
// lib/core/models/activity_type.dart for the structure these feed into.
// Order follows the product spec, not alphabet.
const List<String> kSimliInstruments = [
  'Gitara',
  'Saz',
  'Skripka',
  'Kanun',
  'Tar',
  'Kamança',
  'Ud',
];

const List<String> kGitaraSubOptions = ['Milli', 'Akustik'];
const List<String> kSazSubOptions = ['Milli', 'Türk'];

const List<String> kNefesInstruments = [
  'Klarnet',
  'Balaban',
  'Zurna',
  'Tütək',
  'Saksafon',
  'Qaboy',
];

const List<String> kSintezatorRoles = ['Müşayətçi', 'Solo'];

const List<String> kMuganniRoles = [
  'Muğam ifaçısı',
  'Xanəndə',
  'Şanson',
  'Aparıcı',
  'Digər',
];

const List<String> kSansonSubOptions = ['Rus dilində', 'Digər'];

const List<String> kZerbInstruments = [
  'Udarnik',
  'Nağara',
  'Zərb',
  'Dəf',
  'Davul',
  'Digər',
];

// Full list of Azerbaijan's cities and rayon (district) centers, in
// Azerbaijani-alphabet order — sourced from az.wikipedia.org's city list
// (cross-checked against en.wikipedia.org's "List of cities in Azerbaijan"),
// not the Dec 2024 State Statistics Committee reclassification that narrowed
// formal "şəhər" status to 11 settlements. That narrower list would drop
// well-known towns (e.g. Şamaxı, Quba, Qəbələ) that users still expect to
// find here.
const List<String> kCities = [
  'Ağcabədi',
  'Ağdam',
  'Ağdaş',
  'Ağdərə',
  'Ağstafa',
  'Ağsu',
  'Astara',
  'Babək',
  'Bakı',
  'Balakən',
  'Beyləqan',
  'Bərdə',
  'Biləsuvar',
  'Cəbrayıl',
  'Cəlilabad',
  'Culfa',
  'Daşkəsən',
  'Dəliməmmədli',
  'Füzuli',
  'Gədəbəy',
  'Gəncə',
  'Goranboy',
  'Göyçay',
  'Göygöl',
  'Göytəpə',
  'Hacıqabul',
  'Horadiz',
  'Xaçmaz',
  'Xankəndi',
  'Xızı',
  'Xocalı',
  'Xocavənd',
  'Xırdalan',
  'Xudat',
  'İmişli',
  'İsmayıllı',
  'Kəlbəcər',
  'Kürdəmir',
  'Qax',
  'Qazax',
  'Qəbələ',
  'Qobustan',
  'Qovlar',
  'Quba',
  'Qubadlı',
  'Qusar',
  'Laçın',
  'Lerik',
  'Lənkəran',
  'Liman',
  'Masallı',
  'Mingəçevir',
  'Naftalan',
  'Naxçıvan',
  'Neftçala',
  'Oğuz',
  'Ordubad',
  'Saatlı',
  'Sabirabad',
  'Salyan',
  'Samux',
  'Siyəzən',
  'Sumqayıt',
  'Şabran',
  'Şahbuz',
  'Şamaxı',
  'Şəki',
  'Şəmkir',
  'Şərur',
  'Şirvan',
  'Şuşa',
  'Tərtər',
  'Tovuz',
  'Ucar',
  'Yardımlı',
  'Yevlax',
  'Zaqatala',
  'Zəngilan',
  'Zərdab',
];
