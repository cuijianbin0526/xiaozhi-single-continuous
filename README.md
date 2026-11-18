# 小智 AI · 可切换单次/连续对话固件

基于 [78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) **v2.6.0**（commit `67ca62d4bb7d`）的定制固件。

解决官方固件的两个体验问题：

1. **唤醒后 AI 必定回一句问候**（"你好呀，我在呢"），用户真正想说的话排在后面，而单次模式在问候说完就睡了，真话永远听不到；
2. **无法用语音切换单次/连续对话**，只能靠按键或在服务端改配置。

本固件的做法：**唤醒只负责叫醒，AI 不插嘴，你直接说要问的事；并用说话本身切换单次/连续模式。**

---

## 功能特性

| 功能 | 操作 | 表现 |
|---|---|---|
| 唤醒 | 喊「你好小智」 | 叮一声，**没有任何问候语** |
| 单次对话 | 唤醒后直接说事 | AI 回答，说完自动待机 |
| 进入连续 | 「切换为连续对话模式」/「开启连续对话」/「连续对话」 | AI 确认，说完继续听 |
| 连续多轮 | 直接追问 | 不用重复唤醒 |
| 退出连续 | 「闭嘴」/「停止」/「切换为单次模式」/「关闭连续对话」/「结束连续对话」/「退出连续对话」 | 立即打断并回待机 |
| 联网搜索 | 问实时信息 | AI 自动调用服务端搜索 |

**默认是单次模式**：喊一次、说一句、答一句、睡下。想连着聊就先说「切换为连续对话模式」。

---

## 硬件

已在 **ESP32-S3 面包板方案（`bread-compact-wifi`）** 上验证：

- ESP32-S3，8MB PSRAM，240MHz
- INMP441 I2S 麦克风 + I2S 功放/喇叭（单工双 I2S 通道）
- SSD1306 128×32 OLED
- Wi-Fi 配网，无摄像头

其他 ESP32-S3 板型理论上可用，但需要自行确认 I2S 引脚与板型配置。

> **麦克风灵敏度提醒**：INMP441 这类裸麦灵敏度偏低，实测音频峰值需达到 15000 以上才能稳定触发唤醒。喊话时请靠近麦克风 5~10cm，音量略大于平时说话，但不要喊到破音（削顶到 32767 反而识别不了）。

---

## 使用

### 烧录

固件以合并 bin 形式提供（从 `0x0` 一次写入）：

```bash
python -m esptool --chip esp32s3 --port COM5 write-flash 0 xiaozhi-single-continuous-v1.0.bin
```

或从源码编译后按分区烧录：

```bash
cd build
python -m esptool --chip esp32s3 --port COM5 -b 460800 write-flash @flash_args
```

### 配网

首次上电进入配网模式，手机连 `Xiaozhi-xxxx` 热点完成 Wi-Fi 配置。设备需联网才能使用（语音识别、大模型、TTS 全在云端）。

### 口令一览

**进入连续对话**
```
切换为连续对话模式 / 开启连续对话 / 打开连续对话模式 / 进入连续对话模式 / 连续对话
```

**退出连续对话，回到单次**
```
闭嘴 / 停止 / 切换为单次模式 / 单次唤醒 / 关闭连续对话 / 结束连续对话 / 退出连续对话 / 结束连续 / 退出连续
```

口令采用**子串匹配**，所以说法可以很随意。代价是聊天中如果恰好提到"停止"也会触发退出——这是刻意的取舍，保证"喊停一定停得住"。

---

## 工作原理：三个坑

这套功能不是改几行配置就能成的，中间踩了三个坑，按顺序记录如下。

### 坑 1：唤醒词被当成对话第一句

官方 Kconfig 里 `CONFIG_SEND_WAKE_WORD_DATA` **默认开启**，它会把唤醒词那几秒音频作为对话的第一条消息发给服务端，官方注释写得很明白：

> "Send wake word data to the server as the first message of the conversation and wait for response"

于是串口日志是这样的：

```
Wake word detected: 你好小智
>> 你好小智                       ← AI 收到的第一句就是唤醒词本身
<< 你好呀，有什么可以帮你的吗？    ← 所以 AI 回招呼
State: speaking -> idle          ← 单次模式，答完就睡
```

**修复**：`CONFIG_SEND_WAKE_WORD_DATA=n`。唤醒只负责叫醒 + 播放提示音。

### 坑 2：关掉开关后，`detect` 协议消息也被一起漏掉了

这是最隐蔽的一处。源码里 `#if CONFIG_SEND_WAKE_WORD_DATA` / `#else` 两个分支，`#else` 分支是这样的：

```cpp
#else
    play_popup_on_listening_ = true;
    SetListeningMode(GetDefaultListeningMode());
#endif
```

而 `#if` 分支除了发音频，还会发一条 **`SendWakeWordDetected`** 协议消息：

```json
{"session_id":"...","type":"listen","state":"detect","text":"你好小智"}
```

**服务端靠这条消息判定"设备被唤醒了"**（参见 [xiaozhi-esp32-server#1137](https://github.com/xinnan-tech/xiaozhi-esp32-server/issues/1137) 的讨论）。缺了它，现象是：

- 设备正常进入聆听，麦克风有信号，音频包持续上行（实测 151 包全部发送成功）
- **服务端一个字都不回**

**修复**：即使不上传唤醒词音频，也必须发 `detect` 通知。`text` 传空，只报状态不报内容。

### 坑 3：补了 `detect` 之后，服务端必定回一句问候

服务端把 `detect` 的 `text` 当成用户说的第一句话。传空它甚至会自己补出"小智"，照样回"你好呀，我在呢"。

**这条路在服务端层面是死的**——`detect` 必须发，发了就触发问候。只能在固件端把这一轮吞掉。

**方案：拦截问候轮**（代码中标记 `[方案B]`）

1. 唤醒时置 `wakeup_pending_`
2. 收到第一条 `stt`（就是唤醒回声）时确认："这是回声，不是用户真话"→ 置 `suppress_wakeup_reply_`，**不上屏、不触发口令**
3. 随后的 `tts start` 不进入说话状态；`sentence_start` 不上屏；`OnIncomingAudio` 直接丢弃音频包 → **用户听不到问候**
4. `tts stop` 时：**先 `SendStopListening()` 再 `SendStartListening()`** 重开监听

第 4 步是关键：**只发 `start` 不生效**，服务端认为上一轮尚未结束，会忽略新的 start，于是设备继续上传音频但永远没有识别结果。

### 附：模式切换怎么做的

不做本地命令词（要重训 WakeNet/MultiNet，且两种唤醒词会互相误触发），改为**在云端 STT 文本里匹配口令**——固件本来就会收到用户说的话的文字，免费、准确率由云端保证。

模式对应固件的监听枚举：

- 单次 = `kListeningModeManualStop` → AI 说完回 `idle`
- 连续 = `kListeningModeAutoStop` → AI 说完继续 `listening`

**核心机关**：`continuous_mode_` 与 `listening_mode_` 必须同步改。因为 TTS 播放结束时，固件是看 `listening_mode_` 决定"回待机"还是"继续听"的，只改一个必然出问题。

---

## 自己编译

### 环境

- ESP-IDF **v6.1**
- 唤醒词模型 `wn9_nihaoxiaozhi_tts`（必须用官方脚本打包，否则设备变聋）

### 步骤

```bash
# 1. 克隆官方源码并切到对应版本
git clone https://github.com/78/xiaozhi-esp32.git
cd xiaozhi-esp32
git checkout 67ca62d4bb7d

# 2. 应用补丁
git apply patches/application.cc.patch
git apply patches/application.h.patch

# 3. 追加配置
cat patches/sdkconfig.defaults.append.txt >> sdkconfig.defaults

# 4. 必须用官方 build.py 并指定唤醒词，直接 idf.py build 会丢唤醒模型
python scripts/build.py bread-compact-wifi \
  --name bread-compact-wifi --language zh-CN --wake-word wn9_nihaoxiaozhi_tts

# 5. 烧录
python -m esptool --chip esp32s3 --port COM5 -b 460800 write-flash @build/flash_args
```

### 三个容易踩的编译坑

1. **源码路径不能含中文**，否则 gcc 会崩，请放在纯英文路径下编译
2. **不要在 Git Bash 里启动编译**——会继承 `MSYSTEM` 环境变量，`idf.py` 打印 `MSys/Mingw is no longer supported` 并跳过 reconfigure，最后报 `RuntimeError: sdkconfig was not generated`
3. **`app_desc` 里的编译时间不可信**——ccache 会把 `__DATE__`/`__TIME__` 一起缓存，导致新固件仍显示旧时间。判断是否真编进去，看 `build/.../application.cc.obj` 的时间戳，或直接在固件里搜新加的字符串

---

## 已知限制

- **语音口令依赖云端 STT**，断网不可用（断网本来也用不了对话）
- **「闭嘴」后服务端可能仍播一句已生成的确认语**（如"好的，已切换回单次唤醒模式"）。状态机已经正确退出，只是那句话在口令生效前就生成好了。已知可用多线程同步修正，本版本按使用体验接受现状
- **联网搜索质量受服务端模型与搜索源限制**，与固件无关
- **唤醒灵敏度受麦克风硬件限制**，属硬件范畴
- 仅验证 `bread-compact-wifi` 板型

---

## 致谢与许可

- 上游项目：[78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32)（MIT）
- `detect` 消息机制的确认参考了 [xinnan-tech/xiaozhi-esp32-server](https://github.com/xinnan-tech/xiaozhi-esp32-server) 的 issue 讨论

本项目同样以 **MIT** 许可发布。固件基于官方源码编译，请遵守上游许可。
