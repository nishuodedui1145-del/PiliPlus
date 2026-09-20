BTR 多 Range 并发加速（PiliPlus 移植）
======================================

本仓库包含的第三方工作与其许可
--------------------------------

1) PiliPlus —— 本仓库的上游项目
   版权归 bggRGjQaUbCoE/PiliPlus 及其贡献者所有
   许可：GNU General Public License v3.0（见 LICENSE）
   来源：https://github.com/bggRGjQaUbCoE/PiliPlus

   本仓库是它的衍生作品，因此整体同样以 GPL-3.0 发布。
   我们对上游代码的修改、新增内容与日期：
   - 新增 lib/services/btr_proxy/（本地 HTTP 代理 + 多 Range 并发下载 + CDN 候选池 + CDN 竞速）
   - 新增 lib/pages/setting/widgets/btr_quick_setting.dart（播放页 BTR 快设面板）
   - 修改 lib/pages/video/controller.dart、lib/pages/video/widgets/header_control.dart、
     lib/pages/setting/models/video_settings.dart、lib/utils/storage_key.dart、lib/utils/storage_pref.dart
     （接入代理与新增设置项）
   - 新增测试：test/standalone/btr_*_test.dart、tool/make_btr_mirror.py
   （完整逐次改动见本仓库的 git 提交历史）

2) Bilibili-thread-ripper —— 并发下载原理与参数参考（未复制其源码）
   版权归其作者 MrTangLuyao 所有
   许可：MIT License
   来源：
     - 网页版   https://github.com/MrTangLuyao/Bilibili-thread-ripper
     - 桌面版   https://github.com/MrTangLuyao/bilibili-thread-ripper-desktop

   本移植是用 Dart 独立实现的（本地代理架构，与浏览器方案的实现路径不同），
   参考的是其公开文档中的原理与默认参数（并发推荐值、分块大小、hedge 延迟、预读秒数等）。
   MIT 许可允许此等使用，特此署名致谢。

免责声明
--------
本项目仅供个人学习与研究使用，不含破解、绕过付费或去除广告的功能，
也不修改任何服务端行为。请遵守相关服务条款与当地法律，风险自负。
