# BTR 多 Range 并发加速 · PiliPlus 移植

> 把 [Bilibili-thread-ripper](https://github.com/Neko-77/Bilibili-thread-ripper)（BTR，浏览器扩展/桌面版）的
> **多 Range 并发下载**原理移植到 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)（Flutter 版 B 站客户端）。
>
> 解决场景：**海外**看 B 站冷门视频 / 4K 时，单条连接被 CDN 限速导致「一直转圈、加载卡死」。

## 它怎么工作（一句话）

不碰播放器：在 Flutter 层起一个 **本地 HTTP 代理（127.0.0.1）**，播放器照常请求；
代理把一条请求按字节区间切成多块，**并行从多条 CDN 连接拉取**，按序拼好再写回播放器。

```
mpv ──▶ 127.0.0.1:<随机端口>/media ──▶ BtrProxyServer ──▶ 多 Range 并发 ──▶ 上游 CDN
                     （本地回环，无加密开销）              ├─ 候选池：大陆 / 海外分组
                                                          ├─ 启动探测 + 逐块自适应并发
                                                          ├─ 慢块补救 / 半死节点拉黑
                                                          └─ 单连接↔多连接自动切换 + 降级透传
```

## 功能

| 功能 | 说明 |
|---|---|
| **多 Range 并发** | 按实测每连接速度**反推**并发数（不是"先开满"），带在途连接硬上限 |
| **CDN 候选池** | 大陆 / 海外分组，粘性优选节点，死节点拉黑（strike 计数），坏节点自动剔除 |
| **CDN 自动竞速** | 进视频后**后台**竞速候选节点（6 × 64KB，预算 800ms），结果缓存 5 分钟复用；带 20% 迟滞，全失败则不改动现有状态 |
| **单/多连接自动切换** | 对比式判据（单连接不慢于多连接才切）+ 20 秒最小驻留 + 每分钟 ≤2 次，**杜绝乒乓切换** |
| **起播可靠性** | 上游首块慢时用「1 字节 Range 顶出响应头」+ 精确 `206`/`Content-Range`/`Content-Length`，避免播放器读头超时与 seek 失败 |
| **降级不花屏** | 分块失败**绝不跳块**，降级为单连接顺序透传写完（fMP4 跳块会花屏） |
| **播放器零改动** | 逻辑全在本地代理里；关掉开关即回到原生行为 |

## 使用

1. 编译安装（与上游 PiliPlus 相同，Flutter 3.47.4 + Android SDK）：
   ```bash
   flutter build apk --debug --target-platform android-arm64
   ```
2. `我的 → 右上齿轮 → 音视频设置`：
   - **BTR 多线程加速** —— 总开关（默认关）
   - **BTR 并发上限** —— 4 / 8 / 16 / 32 / 64（默认 8，官方建议 8~32）
   - **BTR 节点分组** —— 自动 / 大陆 / 海外
   - **BTR CDN 自动竞速** —— 进视频后自动选最快节点（默认开）
3. 播放页右上 `⋮ → BTR 快设`：显示当前最优节点、竞速时间与实测速度，可「立即重新竞速」。
4. 建议同时把 `缓冲大小`（默认 4 ≈ 8MiB）调到 **32**、`缓冲时长` 调到 **60** —— 线路抖动时缓冲比并发更能救体感。

## 技术要点（都是真机实测换来的）

| 结论 | 依据 |
|---|---|
| `bw` 参数单位是 **bit/s**，必须 ÷8 | 曾把它当 byte/s 用 → 目标码率虚高 8 倍 → 并发开爆触发节点限流。用 `yt-dlp` 对照（`bw=155643 ↔ 156kbps`）坐实 |
| Dart `HttpServer` **只有写入 ≥1 字节 body 才真正发出响应头** | PC 最小复现：只 `flush()` 一个字节都没发；`add(1字节)+flush()` 才发 |
| 顶头兜底必须回**精确 206** | 回 `200` 无 `Content-Length` → 播放器拿不到总长度 → `Seek failed (size -38)` → 反复小偏移重试 → 更卡 |
| 在途连接数必须**双向**调整 | 曾只增不减 → 配置降到 8 后预算仍是 34 → hedge 撑到 27 条在途 → 自我限流 |
| 模式切换判据必须**互斥** | 两条判据同时成立时每 1~2 秒互切一次，每次掐断流 |
| 并发**不能创造不存在的国际带宽** | 官方原话；实测 4K（20.2Mbps）在差线路上聚合只有 0.5~2 MB/s，而同一线路单连接瞬时能到 2.14 MB/s |

## 测试

```bash
python tool/make_btr_mirror.py           # 把 lib/services/btr_proxy/ 镜像成独立测试台
flutter test --no-pub test/standalone/btr_bitrate_unit_test.dart   # 码率单位与阈值契约
flutter test --no-pub test/standalone/btr_cdn_racer_test.dart      # 竞速：选最快 / 迟滞 / TTL / 样本上限
flutter test --no-pub test/standalone/btr_proxy_e2e_test.dart      # 端到端：字节级一致性（需真实直链，见下）
```

端到端测试需要一个**真实媒体直链**（`test/fixtures/media_url.txt`），仓库里只提供模板：
见 [`test/fixtures/media_url.txt.example`](test/fixtures/media_url.txt.example)（含生成命令）。
真实文件不会提交 —— 它是带签名参数的限时地址。

## 已知局限

- 4K / 高码率在海外线路上的**天花板在带宽**，不在并发策略；本移植只能把"卡"压缩成"偶尔等一下"，治本要换时段/换线路。
- 只作用于**点播**（直播走另一条 CDN 路径，未改动）。
- 节点分类表按实测整理，B 站随时可能调整域名，需要跟着更新。

## 许可与署名

- 本仓库是 **[bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)** 的衍生作品，原项目以 **GPL-3.0** 发布
  → **本仓库同样以 GPL-3.0 发布**，`LICENSE` 保持不变。修改内容：新增本地 HTTP 代理与多 Range 并发下载模块
  （`lib/services/btr_proxy/`）、少量播放页与设置项接线（见提交历史）。
- 并发下载的**原理与参数**参考自 **Bilibili-thread-ripper**（网页版与桌面版，**MIT** 许可）：
  - 网页版：https://github.com/Neko-77/Bilibili-thread-ripper
  - 桌面版：https://github.com/Neko-77/bilibili-thread-ripper-desktop
  - 本移植为**独立实现**（Dart，本地代理架构），未直接复制其 JS 代码；参数默认值（并发 8、分块 64KB、hedge、bufferAhead 等）参照其文档。
- 感谢上游 PiliPlus 作者与 BTR 作者。

## 免责声明

仅供**个人学习与研究**使用。不含任何破解、绕过付费或去除广告的功能，也不修改 B 站服务端行为；
请遵守相关服务条款与当地法律，自行承担使用风险。原作者与本移植作者不对任何账号或数据损失负责。
