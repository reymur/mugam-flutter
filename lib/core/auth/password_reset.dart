/// Правила экрана сброса пароля (работа 5а).
///
/// Здесь ровно то, что можно проверить возвратом: разбор введённого текста
/// и разбор кода ошибки. Сам `sendPasswordResetEmail` в чистую функцию не
/// заворачивается — это поход в сеть, чистым он не бывает, и оборачивать
/// его ради формы значит писать функцию, которой нечего доказывать.

/// Что делать с введённым адресом: можно ли отправлять и о чём
/// предупредить.
typedef EmailCheck = ({bool canSend, String? warning});

/// Заведомые опечатки в домене верхнего уровня.
///
/// **Не запрет, а вопрос.** Отвергать такой адрес нельзя: `.co` — живая
/// зона, а завтра появится ещё одна, и запрет начнёт врать. Но и молчать
/// нельзя: **это последнее место, где опечатку ещё можно поймать.** После
/// отправки её не поймает никто и никогда — Firebase отвечает успехом на
/// любой синтаксически верный адрес.
///
/// Список короткий и явный, из живых данных: в проде 08.08 нашёлся домен
/// `n.con` — человек набрал `.con` вместо `.com` при регистрации, и это
/// прошло, потому что валидатора в форме нет вовсе (N78).
const _typoTlds = <String, String>{
  'con': 'com',
  'cmo': 'com',
  'ocm': 'com',
  'vom': 'com',
  'xom': 'com',
  'comm': 'com',
  'ru1': 'ru',
  'gmial.com': 'gmail.com',
  'gmai.com': 'gmail.com',
  'gmail.co': 'gmail.com',
};

/// Разбор введённого адреса.
///
/// **`canSend` — это НЕ проверка адреса на существование.** Такой проверки
/// не бывает: единственный способ узнать, живёт ли ящик, — послать письмо
/// и получить ответ от человека. Здесь отсекается только заведомый мусор,
/// чтобы не тратить обращение и не показывать «письмо отправлено» тому,
/// кто не дописал адрес.
EmailCheck checkResetEmail(String raw) {
  final email = raw.trim();
  if (email.isEmpty) return (canSend: false, warning: null);

  final at = email.indexOf('@');
  // Ровно одна собака, и по краям от неё что-то есть.
  if (at <= 0 || at != email.lastIndexOf('@') || at == email.length - 1) {
    return (canSend: false, warning: null);
  }

  final domain = email.substring(at + 1).toLowerCase();
  if (!domain.contains('.') || domain.startsWith('.') || domain.endsWith('.')) {
    return (canSend: false, warning: null);
  }

  // Сперва домен целиком (`gmial.com`), потом только зона (`.con`):
  // «gmial.com» — опечатка в имени, а не в зоне, и подсказка у неё своя.
  final whole = _typoTlds[domain];
  if (whole != null) {
    return (canSend: true, warning: _didYouMean(email, domain, whole));
  }
  final tld = domain.substring(domain.lastIndexOf('.') + 1);
  final fixed = _typoTlds[tld];
  if (fixed != null) {
    final corrected =
        '${domain.substring(0, domain.lastIndexOf('.') + 1)}$fixed';
    return (canSend: true, warning: _didYouMean(email, domain, corrected));
  }

  return (canSend: true, warning: null);
}

String _didYouMean(String email, String domain, String corrected) {
  final local = email.substring(0, email.indexOf('@'));
  return '$local@$corrected?';
}

/// Что сказать человеку при отказе.
///
/// **Разбор N45, применённый заново.** Там ветка ловила `permission-denied`
/// и объясняла его правдоподобной выдумкой — «вас опередила вторая
/// сторона», — причём в Crashlytics не слала ничего. Человек читал
/// уверенную неправду, а следа не оставалось.
///
/// Поэтому здесь названы ровно те коды, причину которых сообщил сам
/// Firebase, а всё остальное получает **осторожную формулировку и
/// признание, что причина неизвестна**. Ветка `default` — не запасной
/// вариант, а главный смысл этой функции.
String resetErrorMessage(String? code) {
  switch (code) {
    case 'invalid-email':
      return 'E-poçt düzgün deyil.';
    case 'too-many-requests':
      return 'Çox cəhd oldu. Bir az gözləyib yenidən yoxlayın.';
    case 'network-request-failed':
      return 'İnternet bağlantısı yoxdur. Bağlantını yoxlayıb yenidən '
          'cəhd edin.';
    default:
      // Ни слова о том, отправлено письмо или нет: мы этого не знаем.
      return 'Göndərilə bilmədi. Bağlantını yoxlayıb yenidən cəhd edin.';
  }
}

/// Ответ при успешной отправке — и он НАМЕРЕННО не утверждает, что письмо
/// ушло именно этому человеку.
///
/// Firebase отвечает успехом на любой синтаксически верный адрес,
/// независимо от того, есть такой аккаунт или нет. Это защита от подбора:
/// иначе форма сброса становится справочником «кто у вас зарегистрирован».
/// Ломать её нельзя — значит и говорить «письмо отправлено» нельзя, потому
/// что это утверждение о том, чего мы не знаем.
const String resetSentMessage =
    'Əgər belə hesab varsa, məktub göndərildi. Poçtunuzu yoxlayın.';
