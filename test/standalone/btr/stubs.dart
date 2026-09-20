// 自动生成的最小桩：替换 PiliPlus app 侧的 BrowserUa / HttpString / Accounts。
// 由 tool/make_btr_mirror.py 生成，不要手改。

abstract final class BrowserUa {
  static const pc =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const mob = pc;
}

abstract final class HttpString {
  static const baseUrl = 'https://www.bilibili.com';
}

class _StubCookie {
  _StubCookie(this.name, this.value);
  final String name;
  final String value;
}

class _StubCookieJar {
  Future<List<_StubCookie>> loadForRequest(Uri uri) async => <_StubCookie>[];
}

class _StubAccount {
  const _StubAccount();
  bool get isLogin => false;
  _StubCookieJar get cookieJar => _StubCookieJar();
}

abstract final class Accounts {
  static const main = _StubAccount();
  static const video = _StubAccount();
}
