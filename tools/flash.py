# -*- coding: utf-8 -*-
"""
xiaozhi v3 固件烧录脚本
- 自动识别 CH340/CH341 串口（也支持命令行指定端口）
- 调用 esptool 按 build/flash_args 写入 5 个分区
- 成功后打印校验结果

用法：
    python flash_v3.py            # 自动找板子
    python flash_v3.py COM5       # 指定端口
"""
import os
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

VENV_PY = r"C:\Users\carlc\.espressif\python_env\idf6.1_py3.11_env\Scripts\python.exe"
BUILD = r"F:\esp\xiaozhi-build\build"
CH340_IDS = ("1A86", "CH340", "CH341", "CH9102", "CP210", "10C4")


def list_ports():
    from serial.tools import list_ports as lp
    return list(lp.comports())


def pick_port(explicit=None):
    ports = list_ports()
    print("=== 当前串口 ===")
    if not ports:
        print("  （无任何串口）")
    for p in ports:
        tag = ""
        hw = (p.hwid or "").upper()
        desc = (p.description or "")
        if any(k in hw or k in desc.upper() for k in CH340_IDS):
            tag = "  <== 疑似开发板"
        print(f"  {p.device:<8} {desc}{tag}")
        print(f"           hwid={p.hwid}")

    if explicit:
        return explicit

    cands = [p.device for p in ports
             if any(k in (p.hwid or "").upper() or k in (p.description or "").upper()
                    for k in CH340_IDS)]
    if not cands:
        # 蓝牙串口排除后，若只剩一个也用它
        others = [p.device for p in ports if "BTHENUM" not in (p.hwid or "").upper()]
        if len(others) == 1:
            print(f"\n未识别到 CH340，但只有一个非蓝牙串口：{others[0]}，将使用它")
            return others[0]
        print("\n[FAIL] 未找到开发板串口。请确认：")
        print("       1) USB 线已插好（换根线试试，有些线只供电不传数据）")
        print("       2) 设备管理器里出现 'USB-SERIAL CH340 (COMx)'")
        print("       3) 手动指定：python flash_v3.py COM5")
        return None
    if len(cands) > 1:
        print(f"\n[WARN] 检测到多个候选端口 {cands}，使用第一个；不对请手动指定")
    return cands[0]


def main():
    explicit = sys.argv[1] if len(sys.argv) > 1 else None
    port = pick_port(explicit)
    if not port:
        return 2

    args_file = os.path.join(BUILD, "flash_args")
    if not os.path.exists(args_file):
        print(f"[FAIL] 找不到 {args_file}，请先编译")
        return 2
    with open(os.path.join(BUILD, "xiaozhi.bin"), "rb") as f:
        pass

    print(f"\n=== 开始烧录到 {port} ===")
    cmd = [VENV_PY, "-m", "esptool", "--chip", "esp32s3", "-p", port,
           "-b", "460800", "--before", "default-reset", "--after", "hard-reset",
           "write-flash", "@flash_args"]
    print(" ".join(cmd))
    print("-" * 60)
    rc = subprocess.call(cmd, cwd=BUILD)
    print("-" * 60)
    if rc == 0:
        print("[OK] 烧录完成。请按验证清单测试：")
        print("  1) 喊'你好小智' -> 叮 -> 说'今天天气怎么样'，AI 应回答天气而不是'你好呀'")
        print("  2) AI 答完应自动回待机（单次模式）")
        print("  3) 说'切换为连续对话模式' -> 连说几句不用再唤醒")
        print("  4) 说'结束连续对话' -> 必须退出（v3 修复验证点）")
    else:
        print(f"[FAIL] 烧录失败，退出码 {rc}")
        print("       常见原因：串口被占用（关掉串口助手/监视器）、板子没进下载模式、线材问题")
    return rc


if __name__ == "__main__":
    sys.exit(main())
