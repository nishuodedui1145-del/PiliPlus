#!/usr/bin/env python3
"""把 lib/services/btr_proxy/ 的源码镜像到 test/standalone/btr/，供独立端到端测试使用。

为什么需要镜像：PiliPlus 依赖一个**打过补丁的 Flutter SDK**（lib/scripts/patch.ps1 会给
Flutter 框架源码打 30 个补丁，加了 toPlainTextV2/selectable 等 API）。原生 Flutter 编译不了
整个 app，而 test 文件的 import 链会经 accounts.dart → pages/mine/controller.dart → 那些
UI 组件，导致测试无法编译。镜像把 4 个代理文件 + CDNService 枚举复制出来，并把
3 个 app 侧依赖（BrowserUa / HttpString / Accounts）换成最小桩，从而可以独立编译并跑真机级
端到端测试。

用法：python tool/make_btr_mirror.py
"""
import os
import re
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'lib', 'services', 'btr_proxy')
OUT = os.path.join(ROOT, 'test', 'standalone', 'btr')

STUBS = '''// 自动生成的最小桩：替换 PiliPlus app 侧的 BrowserUa / HttpString / Accounts。
// 由 tool/make_btr_mirror.py 生成，不要手改。
import 'dart:io';

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
'''

REWRITES = {
    'package:PiliPlus/http/browser_ua.dart': 'stubs.dart',
    'package:PiliPlus/http/constants.dart': 'stubs.dart',
    'package:PiliPlus/utils/accounts.dart': 'stubs.dart',
    'package:PiliPlus/models/common/video/cdn_type.dart': 'cdn_type.dart',
}


def main():
    os.makedirs(OUT, exist_ok=True)
    shutil.copyfile(
        os.path.join(ROOT, 'lib', 'models', 'common', 'video', 'cdn_type.dart'),
        os.path.join(OUT, 'cdn_type.dart'),
    )
    with open(os.path.join(OUT, 'stubs.dart'), 'w', encoding='utf-8') as f:
        f.write(STUBS)

    names = [f for f in os.listdir(SRC) if f.endswith('.dart')]
    for name in names:
        with open(os.path.join(SRC, name), encoding='utf-8') as f:
            text = f.read()
        for src, dst in REWRITES.items():
            text = text.replace("import '%s';" % src, "import '%s';" % dst)
        text = re.sub(
            r"import 'package:PiliPlus/services/btr_proxy/([^']+)';",
            r"import '\1';",
            text,
        )
        with open(os.path.join(OUT, name), 'w', encoding='utf-8') as f:
            f.write(text)
        print('mirrored', name)

    # 校验：镜像里不应再有 package:PiliPlus 依赖
    for name in os.listdir(OUT):
        with open(os.path.join(OUT, name), encoding='utf-8') as f:
            for i, line in enumerate(f, 1):
                if 'package:PiliPlus' in line:
                    print('!! 残留 app 依赖 %s:%d %s' % (name, i, line.strip()))
    print('done ->', OUT)


if __name__ == '__main__':
    main()
