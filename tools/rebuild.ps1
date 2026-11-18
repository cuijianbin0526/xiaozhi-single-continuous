# rebuild-v3.ps1 -- corrected tool paths for xiaozhi-esp32 v3 firmware
# Fix vs rebuild-nowakeupload.ps1:
#   1) $TOOLS now points to C:\Espressif\tools (tools were one level deeper)
#   2) strips MSYS/MSYSTEM inherited from Git Bash (breaks idf.py reconfigure)
#   3) pre-flight check that cmake/ninja/xtensa-gcc are resolvable

$ErrorActionPreference = "Continue"
# 注：本脚本需在原生 PowerShell 中运行（不要在 Git Bash 里调），
# 否则会继承 MSYSTEM 导致 idf.py 跳过 reconfigure。

$IDF_PATH = "F:\esp\idf\v6.1\esp-idf"
$TOOLS    = "C:\Espressif\tools"
$VENV     = "C:\Users\carlc\.espressif\python_env\idf6.1_py3.11_env"
$XTENSA   = "$TOOLS\xtensa-esp-elf\esp-15.2.0_20251204\xtensa-esp-elf\bin"

$env:IDF_PATH           = $IDF_PATH
$env:IDF_TOOLS_PATH     = "C:\Espressif"
$env:IDF_PYTHON_ENV_PATH= $VENV
$env:ESP_IDF_VERSION    = "6.1.0"
$env:ESP_ROM_ELF_DIR    = "$TOOLS\esp-rom-elfs\20241011"
$env:PATH = "$VENV\Scripts;$XTENSA;$TOOLS\cmake\4.0.3\bin;$TOOLS\ninja\1.12.1;$TOOLS\ccache\4.12.1;$TOOLS\idf-exe\1.0.3;$TOOLS\esp32ulp-elf\2.38_20240113\esp32ulp-elf\bin;$env:PATH"

Write-Output "=== STEP0: toolchain pre-flight ==="
$ok = $true
foreach ($tool in @("cmake", "ninja", "ccache")) {
    $c = Get-Command $tool -ErrorAction SilentlyContinue
    if ($c) { Write-Output ("  OK   {0,-18} {1}" -f $tool, $c.Source) }
    else    { Write-Output ("  FAIL {0,-18} not on PATH" -f $tool); $ok = $false }
}
$gcc = Join-Path $XTENSA "xtensa-esp32s3-elf-gcc.exe"
if (Test-Path $gcc) { Write-Output ("  OK   {0,-18} {1}" -f "xtensa-gcc", $gcc) }
else { Write-Output "  FAIL xtensa-gcc not found: $gcc"; $ok = $false }
if (-not (Test-Path "$VENV\Scripts\python.exe")) { Write-Output "  FAIL idf python env missing"; $ok = $false }
if (-not $ok) { Write-Output "PRE-FLIGHT FAILED"; exit 1 }

Set-Location -LiteralPath "F:\esp\xiaozhi-build"

Write-Output ""
Write-Output "=== STEP1: build.py reconfigure + assets (with wake word) ==="
& "$VENV\Scripts\python.exe" "scripts\build.py" bread-compact-wifi --name bread-compact-wifi --language zh-CN --wake-word wn9_nihaoxiaozhi_tts
if ($LASTEXITCODE -ne 0) { Write-Output "build.py FAILED: $LASTEXITCODE"; exit $LASTEXITCODE }

Write-Output ""
Write-Output "=== STEP2: verify CONFIG_SEND_WAKE_WORD_DATA in sdkconfig ==="
if (Test-Path "sdkconfig") {
    Select-String -Path "sdkconfig" -Pattern "SEND_WAKE_WORD_DATA" | ForEach-Object { "  " + $_.Line }
} else {
    Write-Output "  FAIL: sdkconfig not generated"
    exit 1
}

Write-Output ""
Write-Output "=== STEP3: idf.py build ==="
& "$VENV\Scripts\python.exe" "$IDF_PATH\tools\idf.py" build
if ($LASTEXITCODE -ne 0) { Write-Output "idf.py build FAILED: $LASTEXITCODE"; exit $LASTEXITCODE }

Write-Output ""
Write-Output "=== BUILD ALL OK ==="
Get-ChildItem -LiteralPath "build" -Filter "*.bin" | Select-Object Name, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
Get-ChildItem -LiteralPath "build" -Filter "xiaozhi.bin" | Select-Object Name, LastWriteTime
