# iOS 安装指南（PiliPlus BTR）

> ⚠️ **当前状态：可编译、可侧载，但未在真机上验证过。**（开发侧没有 iPhone 设备）
> iOS 包由 GitHub Actions 自动构建（`ios.yml`），产物为**未签名 `.ipa`**，需要用你自己的 Apple ID 重签后安装。
> 仅提供 **arm64**（iPhone 8 及以后基本都满足，最低系统 **iOS 15.0**）。
>
> 📌 **本指南的侧载流程参考 [Kazumi 官方文档「在 iOS 上安装」](https://kazumi.app/docs/misc/how-to-install-in-ios)** —— Sideloadly / LiveContainer+SideStore 两条路的步骤与限制均以该文档为准；本文档的差异部分（方式 C 的 TrollStore、第五节本项目设置建议、第六节已知限制）已单独标注。

---

## 零、先知道两条硬限制（免费 Apple ID）

- **签名有效期 7 天**：到期后 App 打不开，需续签（续签**不会丢** App 内的登录和数据）。
- **单个 Apple ID 最多同时安装 3 个侧载应用**。
  - 想装更多：见方式 B 里"**直接安装文件**"的装法，它走 LiveContainer 容器，**不占这 3 个名额**。

**准备工作**（两种方式都要）：一台 macOS 或 Windows 电脑、iPhone/iPad、一根**稳定的数据线**、一个**用邮箱注册的 Apple ID**。
Windows 用户**必须安装非 Microsoft Store 版 iTunes**（装了商店版要先卸载，再从官网下载）。

---

## 一、方式 A：Sideloadly（最简单，推荐先试）

1. 下载 [Sideloadly](https://sideloadly.io/#download)（Windows 一般选 64 位；不确定就按 `Win + R` → `msinfo32` 看"系统类型"）；
2. 打开 Sideloadly，在 **Apple ID** 栏填入你的 Apple 账号邮箱；
3. 用数据线连上手机 → 手机上弹出「要信任此电脑吗？」→ 点**信任**并输入锁屏密码 → 设备名会出现在 `iDevice` 栏；
4. 点左侧的 **IPA 图标**，选择 `PiliPlus-BTR-ios-<版本>-unsigned.ipa`，然后点 **Start**；
   - 💡 **`Start` 左侧的「刷新图标」请保持开启**（默认就是开着的）：它让设备在**同一 Wi-Fi 环境下每 7 天自动续签**，省得你手动重装。
5. 首次会要求输入 Apple ID 密码；开了双重认证的，在弹窗里填手机收到的 **6 位验证码**；
6. 进度条跑完、显示 `Done.` 即安装成功。

**续签**：开着刷新图标时会自动完成；没开的话 7 天后打不开，重新走一遍第 2~6 步即可（**数据不会丢**）。

---

## 二、方式 B：LiveContainer + SideStore（折腾一次，之后手机自己续签）

> 步骤较多，但配好之后**不用反复连电脑**。

1. **装 iloader**（电脑端）：[iloader releases](https://github.com/nab138/iloader/releases/latest)；
2. **开启开发者模式（iOS 16 及以上必须，否则侧载应用无法运行）**：
   `设置 → 隐私与安全性 →` 拉到底部找到 `开发者模式 →` **开启** → 按提示重启设备并确认；
3. **用 iloader 安装 LiveContainer + SideStore**：
   - 启动 iloader → 用数据线连接设备 → 解锁并选择「信任此电脑」→ 登录 Apple Account → 点安装；
   - 手机上**信任 LiveContainer**：`设置 → 通用 → VPN 与设备管理`（旧版本系统可能显示为 **描述文件与设备管理**）→ 在 `开发者 APP` 下方点你的 Apple ID → **信任 [你的邮箱]** 并确认；
4. **配置 LiveContainer & SideStore**：
   - 下载 [LocalDevVPN](https://apps.apple.com/hk/app/localdevvpn/id6755608044)（⚠️ **需要外区 Apple ID** 才能下载）→ 装好后**全程保持开启**；
   - 打开 **LiveContainer** → 点左上角的 **SideStore 图标**（首次可能闪退，退出重进即可）；
   - 进入 **SideStore** → 切到 **My Apps** 标签页 → 点 **Refresh All** → 输入 Apple Account 账号与密码；
   - 退出 SideStore，再回到 **LiveContainer** → 切到 **设置** 标签页 → 点 **「从 SideStore 导入证书」**；
5. **安装本 App**（二选一）：
   - **直接安装文件（不占 3 个侧载名额）**：把 ipa 传到手机上（AirDrop 或"文件"App）→ 若此时在 SideStore 里就先退出再进 → 点左上角 **「+」** → 选择 ipa 安装；
   - **通过源安装（以后更新更方便）**：若我们提供了 SideStore 源，则在 SideStore 的 **Sources** 标签页 → 右上角 **「+」** → 填入源地址 → 进源点安装。

---

## 三、方式 C：TrollStore（系统在支持范围内时最省事）

> 这一条**不在 Kazumi 文档里**，是针对老系统的补充。

系统为 **iOS 14 ~ 16.x / 17.0** 的设备可用 TrollStore：装完**永久有效、不需要续签**，也不需要电脑。
具体入口随系统版本而异，见 TrollStore 官方说明。**iOS 17.1 及以上不支持。**

---

## 四、出现「不受信任的开发者」怎么办

1. 打开 `设置 → 通用`；
2. 下滑找到 **VPN 与设备管理**（旧版本系统显示为 **描述文件与设备管理**）；
3. 在 `开发者 APP` 下方点你的 Apple ID；
4. 点 **「信任 [你的邮箱]」** 并确认。

---

## 五、装完之后（本 App 专属建议）

1. 打开 App → `我的` → 右上角齿轮 → `音视频设置` → 找到 BTR 那一组；
2. 建议值：
   - **并发上限 = 6**（iPhone 上更省电、发热更低）
   - **缓冲大小 = 32**
   - **缓冲时长 = 60**
   - 改完**退出视频重新进入**才生效；
3. **日志在哪看**：`音视频设置 → BTR 日志` → 页面里可直接「复制全部」发给我们（**iOS 没有 logcat，这是唯一反馈通道**）。

---

## 六、已知限制（务必先看）

- **未在真机验证**：当前只保证"能编译、能侧载、代码确实进了包"，实际播放行为需要你回报；
- **后台行为**：iOS 会挂起后台 App，本 App 已声明 `UIBackgroundModes=audio`（后台音频），所以**后台听声音时**代理一般还能继续；若被系统回收，可能表现为"后台一断一续"，**前台观看不受影响**；
- **耗电发热**：多连接并发比官方播放器更耗电，建议并发 ≤ 6；
- **无法用 adb 抓日志**（iOS 没有 logcat）→ 只能用 App 内「BTR 日志」页复制；
- **4K 源**仍受"海外到 B 站 CDN 单连接限速"的物理天花板影响，靠缓冲抹平，不能凭空变快。

## 七、反馈方式

在 `音视频设置 → BTR 日志` 里「复制全部」，连同**机型 / iOS 版本 / 视频链接 / 现象（卡住？音动画不动？）** 一起发出来即可。
