<div align="center">
    <img width="180" height="180" src="assets/images/logo/logo.png">
    <h1>PiliPlus + BTR 多线程加速</h1>
    <p>把 <a href="https://github.com/MrTangLuyao/Bilibili-thread-ripper">Bilibili-thread-ripper</a> 的<b>多 Range 并发下载</b>移植进 PiliPlus（Flutter 开发的 B 站第三方客户端）</p>
</div>
> 
> ## ✅ 当前推荐版本：`v2.1.4-btr.15`
> 
> **本仓库推荐使用最新版**（已解决 `btr.13`/`btr.14` 的「开着 BTR 视频开不了」问题）：
> 
> **安卓**：下载 `PiliPlus-BTR-2.1.4-btr.15-arm64.apk`，直接覆盖安装（与本项目历史版本同一签名，无需卸载）。
> **iOS**：`PiliPlus-BTR-ios-2.1.4-btr.15-unsigned.ipa` 为未签名包，需自行侧载，见 `docs/btr/iOS-安装指南.md`。
> 
> 若新版在你的网络下有问题，可回退 `v2.1.4-btr.12`（同签名，可直接覆盖安装）。

> ### ⚠️ 这是个人 fork，不是官方仓库
> 本仓库是 **[bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)** 的个人衍生版，在其基础上**只加了一件事**：
> 用「本地 HTTP 代理 + 多 Range 并发」解决**海外**看 B 站被单连接 CDN 限速导致的「一直转圈、加载卡死」。
> 想要官方版本、官方功能说明与官方更新，请前往 **[上游仓库](https://github.com/bggRGjQaUbCoE/PiliPlus)**。
> 上游的原始 README（含完整功能清单）保留在 **[README-upstream.md](README-upstream.md)**。

<br/>

## 快速导航

| 我想… | 去哪 |
|---|---|
| **下载安装 APK** | **[Releases](../../releases)** —— 下载 `.apk` 直接侧载安装（无需 root） |
| 看这个加速是什么、怎么用 | **[README-BTR.md](README-BTR.md)** |
| 看技术设计（11 条关键决定 + 实测依据） | **[docs/btr/DESIGN.md](docs/btr/DESIGN.md)** |
| 看官方版功能说明 | **[README-upstream.md](README-upstream.md)** ／ [上游仓库](https://github.com/bggRGjQaUbCoE/PiliPlus) |
| 自己编译 / 跑测试 | 见下方「编译与测试」 |

<br/>

## 和官方版的差别（全部改动）

- **新增** `lib/services/btr_proxy/`（5 个文件，约 4.6k 行 Dart）：
  - `proxy_server.dart` —— 本地 HTTP 服务（Range / 206 / HEAD / 1 字节顶头兜底 / 纯数据透传）
  - `cdn_pool.dart` —— CDN 候选池（大陆·海外分组、粘性优选、死节点拉黑、竞速提示）
  - `multi_range_downloader.dart` —— 多 Range 分块调度（并发反推、hedge 抢块、慢块补救、单↔多连接切换、失败降级）
  - `cdn_racer.dart` —— 进视频后**后台**竞速候选节点（TTL 缓存、迟滞、不阻塞起播）
  - `range_core.dart` —— 阈值与契约（码率 `bw` 按 bit/s 解析后 ÷8 等）
- **新增** 播放页「更多」里的 **BTR 快设面板**（`lib/pages/setting/widgets/btr_quick_setting.dart`）。
- **修改** 音视频设置新增 4 项：**BTR 多线程加速 / 并发上限 / 节点分组 / CDN 自动竞速**，以及少量接线
  （`controller.dart`、`header_control.dart`、`video_settings.dart`、`storage_key.dart`、`storage_pref.dart`）。
- 除以上内容外，**其余功能与官方版完全一致**（本 fork 基于官方 2.1.4）。

**播放器零改动**：所有逻辑都在本地代理里，mpv 照常播放；关掉开关即回到原生行为。

<br/>

## 使用要点

1. 装好后：`我的 → 右上齿轮 → 音视频设置`
   - **BTR 多线程加速** —— 总开关（默认关，需要手动打开）
   - **BTR 并发上限** —— 4 / 8 / 16 / 32 / 64（默认 8；BTR 官方建议 8~32）
   - **BTR 节点分组** —— 自动 / 大陆 / 海外
   - **BTR CDN 自动竞速** —— 进视频后自动选出最快节点（默认开）
2. 建议把 **缓冲大小** 从 4 调到 **32**、**缓冲时长** 调到 **60** —— 线路抖动时，缓冲比并发更能救体感。
3. 播放页右上 `⋮ → BTR` 可查看当前最优节点、竞速时间与实测速度。

<br/>

## 编译与测试

与官方版相同（Flutter 3.47.4 + Android SDK）：

```bash
flutter build apk --release --target-platform android-arm64    # 出包
flutter build apk --debug   --target-platform android-arm64    # 调试版
```

```bash
python tool/make_btr_mirror.py                                     # 把代理模块镜像成独立测试台
flutter test --no-pub test/standalone/btr_bitrate_unit_test.dart   # 码率单位与阈值契约
flutter test --no-pub test/standalone/btr_cdn_racer_test.dart      # CDN 竞速（本地假 CDN，全自包含）
flutter test --no-pub test/standalone/btr_proxy_e2e_test.dart      # 端到端字节一致性（需真实直链，见 .example）
```

<br/>

## 许可

- 本仓库是 PiliPlus 的衍生作品，**整体沿用上游的 GPL-3.0**（见 [LICENSE](LICENSE)，未改动）。
- 并发下载的原理与默认参数参考 **Bilibili-thread-ripper**（[网页版](https://github.com/MrTangLuyao/Bilibili-thread-ripper) /
  [桌面版](https://github.com/MrTangLuyao/Bilibili-thread-ripper-desktop)，**MIT**）；本移植为 Dart 独立实现，未复制其 JS 代码。
  逐项改动说明与第三方署名见 **[NOTICE](NOTICE)**。

## 声明（沿用上游）

此项目是个人为了兴趣而开发，仅用于学习和测试，请于下载后 24 小时内删除。
所用 API 皆从官方网站收集，不提供任何破解内容。

致敬原作者：[guozhigq/pilipala](https://github.com/guozhigq/pilipala)、[orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)。
