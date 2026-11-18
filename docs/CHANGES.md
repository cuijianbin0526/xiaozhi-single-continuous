# 小智AI 单次/连续对话模式切换 —— 改动说明（最终版 v2）

> 项目：xiaozhi-esp32 官方 2.6.0 源码（commit `67ca62d4bb7d`）
> 板子：ESP32-S3 面包板 bread-compact-wifi，Wi-Fi，SSD1306 128×32，无摄像头
> 唤醒词：官方 `你好小智`（保持不变）
> 更新日期：2026-11-18（v3：修复"结束连续对话"被误判成进入连续）

---

## 一、最终实现的功能（纯语音切换，不碰按键）

| 场景 | 你说的话 | 设备行为 |
|---|---|---|
| 开机默认 | —— | **单次模式**：喊一次"你好小智"→ 叮一声 → 你说一句 → AI 答 → 自动回待机 |
| 想连续聊 | "切换为连续对话模式" / "连续对话" | 进入**连续模式**：AI 说完继续听，可以多轮对话，不用反复唤醒 |
| 想停下来 | "停止" / "闭嘴" / "切换为单次模式" / "关闭连续对话"（任意一个） | 立即打断 AI 回答，切回**单次模式** |

识别由云端大模型完成（固件本来就会收到你说的每句话的文字），**不需要重做本地唤醒词模型，不需要自建服务器，不动 API Key**。

---

## 二、两个关键坑（血的教训，务必记住）

### 坑 1：必须用官方 build.py 带 `--wake-word` 编译
直接 `idf.py build` 会导致 `CONFIG_WAKE_WORD_DISABLED=y`、assets 不含唤醒词模型 → 板子变聋子，喊破喉咙没反应。
```bash
python scripts/build.py bread-compact-wifi --name bread-compact-wifi --language zh-CN --wake-word wn9_nihaoxiaozhi_tts
```

### 坑 2：官方默认把"你好小智"当成对话第一句（2026-11-18 发现）
**现象**：喊"你好小智"有"叮"、AI 也回话，但回的是"你好呀，有什么可以帮你的吗"，随后马上待机；你接着说真正想说的话，它已经睡了，没反应。

**根因**：Kconfig 开关 `CONFIG_SEND_WAKE_WORD_DATA=y`（默认开），官方说明原文：
> "Send wake word data to the server as the first message of the conversation and wait for response"

即唤醒词的音频被作为对话第一句发给 AI。串口日志铁证：
```
Wake word detected: 你好小智
>> 你好小智                       ← AI 收到的第一句=唤醒词本身
<< 你好呀，有什么可以帮你的吗？    ← 所以 AI 回打招呼
State: speaking -> idle          ← 单次模式，答完就睡
```

**修复**：关掉该开关，唤醒只负责叫醒 + 播放"叮"，用户接着说的话才是第一句：
- `sdkconfig.defaults` 末尾加 `CONFIG_SEND_WAKE_WORD_DATA=n`
- 当前 `sdkconfig` 第 1155 行改为 `# CONFIG_SEND_WAKE_WORD_DATA is not set`

关闭后走源码 `application.cc` 的 `#else` 分支（第 1061-1066 行），逻辑完备，无崩溃风险。

---

## 三、改了哪些文件（都带 `[峰哥定制]` 标记，方便回退）

### 1. `main/application.h`（第 143-144 行）
```cpp
// [峰哥定制] 对话模式开关：false=单次唤醒（默认），true=连续对话
bool continuous_mode_ = false;
```

### 2. `main/application.cc`（4 处）
- **(a) 第 694-741 行 stt 分支**：云端返回你说的文字后，在主线程（`Schedule`）检测口令。含"连续对话"且不含"关闭"→进连续；含"停止"/"闭嘴"/"单次模式"/"单次唤醒"/("关闭"+"连续")→回单次 + `AbortSpeaking` 打断 + 回待机。同步 `listening_mode_` 是关键（AI 说完话看它决定回待机/继续听）。
- **(b) 第 975 行唤醒词回调**：删掉"按唤醒词内容切模式"逻辑，唤醒词只负责唤醒。
- **(c) 第 990 行连续态同步**：连续对话中被唤醒打断时重新同步 `listening_mode_`。
- **(d) 第 1331-1338 行 GetDefaultListeningMode()**：
```cpp
return continuous_mode_ ? kListeningModeAutoStop : kListeningModeManualStop;
```

### 3. `sdkconfig.defaults.esp32s3`（第 32-33 行）
停用"监听态唤醒词检测"（stt 方案不需要，开着会在连续对话中误触发唤醒打断）。

### 4. `sdkconfig.defaults`（末尾，2026-11-18 新增）
`CONFIG_SEND_WAKE_WORD_DATA=n` —— 见坑 2。

### 5. `main/audio/wake_words/custom_wake_word.cc`
已恢复原样（之前注入命令词的改动已撤销，WakeNet 用不上）。

---

## 四、编译与烧录（实际环境，可复用脚本）

### 编译（英文路径！中文路径 gcc 会崩）
源码编译副本在 `F:\esp\xiaozhi-build`（纯英文路径），中文路径目录仅存档用。
- 一键脚本：`F:\esp\rebuild-nowakeupload.ps1`（内含全部环境变量 + build.py + idf.py build）
- 执行：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\esp\rebuild-nowakeupload.ps1"`
- 注意：必须有 `IDF_PYTHON_ENV_PATH`；必须在 PowerShell 原生跑（Git Bash 调 cmd 会报 MSys/Mingw 不支持）；输出要重定向到文件防止缓冲卡死误判。

### 烧录（板子接 COM5）
在 `F:\esp\xiaozhi-build\build` 下用 esptool：
```bash
python -m esptool --port COM5 --chip esp32s3 write-flash @flash_args
```
5 个文件（bootloader/partition/ota_data/xiaozhi.bin/assets），出现 `Hash of data verified` 即成功。

### 回退
原固件 `merged-binary.bin` 一直保留在工作区：
```bash
python -m esptool --port COM5 --chip esp32s3 write-flash 0 merged-binary.bin
```

---

## 五、验证清单

1. 开机喊"你好小智" → 叮一声 → 说"今天天气怎么样" → AI 应回答**天气**而不是"你好呀"（坑 2 修复的核心验证点）
2. AI 答完是否**自动回待机**（单次模式生效）
3. 唤醒后说"切换为连续对话模式" → 日志出现 `[峰哥定制] 口令 -> 连续对话模式` → 之后连说几句**不用再唤醒**
4. 连续中说"闭嘴" → 是否**立即停**并回待机

---

## 六、模拟测试（2026-11-18）

编译前在 PC 上把固件口令逻辑 1:1 复现跑了一遍，脚本 `F:\WorkBuddy\项目数据\小智AI\模拟测试-唤醒与模式切换.py`：
- 测试组 A：唤醒词上传开关修复前后对比 ✓
- 测试组 B：单次默认 + 口令进连续/回单次 4 种说法 ✓
- 测试组 C：边界防误判（"关闭连续对话"不误进连续等）✓
- **结果：11 项全 PASS**

---

## 七、注意事项 / 已知边界
- **"停止""闭嘴"是全局关键词**：聊天中提到也会触发切回单次，按需求设定，属预期。
- **stt 依赖联网**：口令识别走云端，断网无法切换（断网本也用不了对话）。
- **唤醒需要较大声**：实测需提高音量喊"你好小智"才稳定触发，属麦克风灵敏度，非 bug。

---

## 八、v3 修复记录（2026-11-18 19:05 编译通过）

### 修了什么

v2 的口令判断有两个缺陷，导致说"结束连续对话"反而**进入**连续模式：

```cpp
// v2（有 bug）
bool enter_continuous = contains("连续对话") && !contains("关闭");
if (enter_continuous) { ... }        // enter 排在前面
else if (exit_single) { ... }
```

1. `enter` 只把"关闭"当否定词，不认"结束/退出/停止"；
2. `enter` 优先于 `exit`，两个都成立时 enter 赢。

### v3 代码（当前源码状态）

```cpp
// [v3] 先判退出：停止类 / 单次类 / 结束·退出·关闭 + 连续
bool exit_single = contains("停止") || contains("闭嘴") ||
                   contains("单次模式") || contains("单次唤醒") ||
                   contains("结束连续") || contains("退出连续") ||
                   (contains("关闭") && contains("连续"));
// [v3] 再判进入：必须含"连续对话"，且不含任何否定词
bool enter_continuous = contains("连续对话") &&
                        !contains("关闭") && !contains("结束") &&
                        !contains("停止") && !contains("退出") &&
                        !contains("单次");

// [v3] exit 优先
if (exit_single) { ...AbortSpeaking + 清队列 + idle... }
else if (enter_continuous) { ...AutoStop... }
```

### 行为对照

| 口令 | v2（旧） | v3（现在） |
|---|---|---|
| 结束连续对话 | 进入连续 ❌ | 退出单次 ✓ |
| 退出连续对话 | 进入连续 ❌ | 退出单次 ✓ |
| 停止连续对话 | 进入连续 ❌ | 退出单次 ✓ |
| 结束连续 / 退出连续 | 不动作 | 退出单次 ✓ |
| 单次模式和连续对话模式有什么区别 | 进入连续 ❌ | 退出单次 ✓ |
| 切换为连续对话模式 / 连续对话 / 开启连续对话 | 进入连续 ✓ | 进入连续 ✓ |
| 停止 / 闭嘴 / 切换为单次模式 / 关闭连续对话 | 退出单次 ✓ | 退出单次 ✓ |
| 今天天气怎么样 / 关闭灯 | 不动作 ✓ | 不动作 ✓ |

### 测试

`虚拟板子-完整测试-v3.py`：状态机回归 **27/27 PASS**，指定场景 **6/6 PASS**，v2→v3 判定变化 6 条且全部朝正确方向。
报告：`v3-回归测试报告.md`

### 编译

新脚本 `F:/esp/rebuild-v3.ps1`（旧 `rebuild-nowakeupload.ps1` 里的 `$TOOLS` 少了一层 `tools`，已失效）。

**旧脚本的坑**：`$TOOLS = "C:/Espressif"` → cmake 实际在 `C:/Espressif/tools/cmake/4.0.3/bin`。
另外**不能在 Git Bash 里调**，会继承 `MSYSTEM` 导致 idf.py 打印 `MSys/Mingw is no longer supported` 并跳过 reconfigure，报 `sdkconfig was not generated`。

产物：`build\xiaozhi.bin` 2,499,184 字节，19:05 生成，`CONFIG_SEND_WAKE_WORD_DATA` 确认未设置。

---

## 九、方案B：拦截"唤醒即问候"（2026-11-18 20:45 真机验证通过）

### 问题本质

小智官方服务端把"唤醒"和"用户发言"绑死了：
1. `CONFIG_SEND_WAKE_WORD_DATA=y`（原版）→ 唤醒词音频当对话第一句发给 AI
2. 关掉它（`=n`）后，代码走 `#else` 分支，**连 `SendWakeWordDetected` 协议消息也一起漏掉了**
3. 服务端靠 `{"type":"listen","state":"detect"}` 判定唤醒（见 issue xinnan-tech/xiaozhi-esp32-server#1137），缺了它设备狂发音频服务端一个字不回
4. 补回 detect 后，服务端又把 detect 的 `text` 当成用户说的第一句话 → 回"你好呀，我在呢"→ 待机
5. `text` 传空也没用，服务端会自己补出"小智"

**结论：这条路在服务端层面是死的，只能在固件端把这一轮问候吞掉。**

### 实现（标记 `[方案B]`）

`main/application.h`：
```cpp
bool wakeup_pending_ = false;          // 唤醒后等第一条 stt，用于识别"唤醒回声"
bool suppress_wakeup_reply_ = false;   // 已确认回声轮，丢弃其文本/音频
```

`main/application.cc` 五处：

| 位置 | 动作 |
|---|---|
| `ContinueWakeWordInvoke` 的 `#else` | 发 `SendWakeWordDetected("")` 后设 `wakeup_pending_ = true` |
| stt 分支 | 若 `wakeup_pending_`：清标记、设 `suppress_wakeup_reply_`、**直接 return**（不上屏、不触发口令） |
| `tts start` | 若 suppress：忽略，不进入 speaking |
| `sentence_start` | 若 suppress：不显示文字 |
| `OnIncomingAudio` | 若 suppress：直接丢弃下行音频包，不送解码队列 |
| `tts stop` | 若 suppress：清标记 → **先 `SendStopListening()` 再 `SendStartListening()`** → 重开监听 |

**关键点：只发 `start` 无效**，服务端认为上一轮未结束会忽略；必须先 `stop` 再 `start`。

### 两处保险（防死锁）

1. 收到真实用户 stt 时清 `suppress_wakeup_reply_`——万一 `tts stop` 丢失，避免后续所有回答被静音
2. 每次唤醒都重置 `suppress_wakeup_reply_`——重新唤醒即恢复

### 真机验证结果

```
[方案B] 唤醒回声 '小智' 已忽略，开始丢弃问候轮
[方案B] 忽略问候轮 tts start
[方案B] 忽略问候文本: 你好呀，我在呢！
[方案B] 问候轮结束，stop+start 重开监听
```

用户主观反馈：**听不到任何问候**，直接说真话即可。

### 整体功能验收（2026-11-18 20:46）

| 功能 | 状态 | 日志证据 |
|---|---|---|
| 喊一次唤醒、无多余问候 | ✅ | 方案B 四行日志齐 |
| 唤醒后直接说真话被识别 | ✅ | `>> 你的知识库更新到什么时候了？` |
| 连续多轮不重复唤醒 | ✅ | `speaking -> listening` 反复多次 |
| 联网搜索 | ✅ | `<< % web_search...` |
| 语音切回单次 | ✅ | `>> 切换为单次模式。` → `口令 -> 单次唤醒模式` → `idle` |
| 单次模式说完待机 | ✅ | `speaking -> idle` |

### 已知边界

- 语音口令切换依赖云端 STT，断网不可用
- 服务端确认语会播一句（如"好的，连续对话模式已关闭"），属正常应答
- 联网搜索质量受服务端模型与搜索源限制，与固件无关

---

## 十、V1.0 定版（2026-11-18 21:08）

### 定版产物

| 项 | 内容 |
|---|---|
| 固件文件 | `F:\WorkBuddy\项目数据\小智AI\可切换单次-连续对话固件-V1.0.bin` |
| 大小 | 8,949,619 字节 |
| SHA256 | `5a05597cc4c743a936bf85d7083a236e2121bee0823d9262c307c6540b2f3423` |
| 编译目录产物 | `F:\esp\xiaozhi-build\build\merged-binary.bin`（同版本） |
| 源码状态 | `F:\esp\xiaozhi-build` 与固件一致，已验证括号平衡 |

### 功能清单（真机实测通过）

| 功能 | 说/做 | 表现 |
|---|---|---|
| 唤醒 | 喊「你好小智」 | 叮一声，**没有任何问候语** |
| 单次对话 | 唤醒后直接说要问的事 | AI 回答，说完自动待机 |
| 进入连续 | 「切换为连续对话模式」/「开启连续对话」/「连续对话」 | AI 确认，说完继续听 |
| 连续多轮 | 直接追问 | 不用重复唤醒 |
| 退出连续 | 「闭嘴」/「停止」/「切换为单次模式」/「关闭连续对话」/「结束连续对话」/「退出连续对话」 | 立即打断并回待机 |
| 联网搜索 | 问实时信息 | AI 自动调用 `web_search` |

### 重新烧录（换电脑或重装后）

```bash
# 方式一：合并固件，一条命令烧完
python -m esptool --chip esp32s3 --port COM5 write-flash 0 "可切换单次-连续对话固件-V1.0.bin"

# 方式二：从编译目录按分区烧
cd F:\esp\xiaozhi-build\build
python -m esptool --chip esp32s3 --port COM5 -b 460800 write-flash @flash_args
```

一键脚本：`F:\esp\flash_v3.py`（自动识别 CH340 端口）。

### 回退原厂固件

```bash
python -m esptool --chip esp32s3 --port COM5 write-flash 0 "F:\WorkBuddy\项目数据\小智AI\merged-binary.bin"
```

### 重新编译（改代码后）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\esp\rebuild-v3.ps1"
```

**三个必须注意的点**：
1. 必须在**原生 Windows 终端**里跑，不能在 Git Bash 里启动（会继承 MSYSTEM，导致 sdkconfig 生成失败）
2. 脚本里的 `$TOOLS` 必须是 `C:\Espressif\tools`（旧脚本少一层 tools，cmake 找不到）
3. 编译后看 `build\application.cc.obj` 的时间判断是否真编进去了——`app_desc` 里是 ccache 缓存值，不可信

### 已知边界（都是服务端限制，非固件缺陷）

- 语音口令走云端 STT，断网不可用
- 「闭嘴」后服务端可能仍播一句已生成的确认语（如"好的，已切换回单次唤醒模式"），功能上已退出
- 联网搜索质量受服务端模型与搜索源限制
- 唤醒灵敏度受麦克风硬件限制，需靠近说话（实测峰值 15000+ 才稳定触发）
