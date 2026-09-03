#Requires -Version 5.1
<#
.SYNOPSIS
    修复中转站(Sub2API) Gemini 模型在 SillyTavern 里把思维链写进正文的问题。

.DESCRIPTION
    根因在中转站侧：Sub2API 把 Gemini 的 thought 分段拍平成了普通正文
    （/v1/chat/completions 和 /v1/messages 两条协议都一样），酒馆没有任何
    字段可以识别，于是思维链直接混在对话里。

    但中转站的 Gemini 原生端点 /v1beta 是好的 —— thought 分段带着
    "thought": true 原样返回。所以本脚本让酒馆改走原生端点：

      1. 打一行代码补丁，让中转站的型号能出现在 Google AI Studio 的下拉框里
         （中转站的模型列表不返回 supportedGenerationMethods，会被酒馆滤光）；
      2. 配好反代预设 / 型号 / Show thoughts / 连接档案；
      3. 实打一次中转站做自检。

    改动前所有文件都会备份成 *.before-gemini-thinking-<时间戳>.bak，
    可用 -Revert 一键还原。重复运行安全（幂等），酒馆升级后重跑一次即可。

.EXAMPLE
    .\Fix-GeminiThinking.ps1
    自动找酒馆，交互式问 key，打补丁 + 配置 + 自检。

.EXAMPLE
    .\Fix-GeminiThinking.ps1 -PatchOnly
    只打代码补丁，反代地址和 key 自己在酒馆界面里填。

.EXAMPLE
    .\Fix-GeminiThinking.ps1 -DeepScan
    常规位置找不到酒馆时，全盘深度扫描。

.EXAMPLE
    .\Fix-GeminiThinking.ps1 -Revert
    还原到改动之前。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Path,
    [switch] $All,
    [switch] $DeepScan,
    [string] $ApiKey,
    [string] $RelayUrl = 'https://api.sulianyan.com',
    [string] $Model    = 'gemini-3.8-flash-high',
    [switch] $PatchOnly,
    [switch] $Revert,
    [switch] $NoSelfTest
)

$ErrorActionPreference = 'Stop'

# 预加载，否则首次 Get-CimInstance 触发模块自动加载时，-WhatIf 会把模块里的
# Set-Alias 也一并"演练"出来，刷一屏无关信息。（Import-Module 自己不吃 -WhatIf，
# 只能临时把偏好按下去。）
$script:SavedWhatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module CimCmdlets -ErrorAction SilentlyContinue
$WhatIfPreference = $script:SavedWhatIf

$script:Marker      = 'sub2api-gemini-fix'
$script:BackupTag   = 'before-gemini-thinking'
$script:ProxyName   = 'Sub2API Gemini'
$script:ProfileName = '中转站 Gemini'
$script:Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:RelCode     = 'src\endpoints\backends\chat-completions.js'
$script:RelHtml     = 'public\index.html'

# ============================================================ 输出

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "   [OK] $Text" -ForegroundColor Green }
function Write-Note { param([string]$Text) Write-Host "   $Text" -ForegroundColor Gray }
function Write-Warn2 { param([string]$Text) Write-Host "   [!] $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Text) Write-Host "   [X] $Text" -ForegroundColor Red }

# ============================================================ 酒馆目录校验

function Test-TavernRoot {
    param([string]$Dir)

    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }

    foreach ($rel in @('package.json', 'server.js', $script:RelHtml, $script:RelCode)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $rel) -PathType Leaf)) { return $false }
    }

    try {
        $pkg = Get-Content -LiteralPath (Join-Path $Dir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $false
    }

    return ($pkg.name -eq 'sillytavern')
}

function Get-TavernVersion {
    param([string]$Dir)
    try {
        $pkg = Get-Content -LiteralPath (Join-Path $Dir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pkg.version) { return [string]$pkg.version }
    } catch { }
    return '未知'
}

function Get-TavernPort {
    param([string]$Root)
    $cfg = Join-Path $Root 'config.yaml'
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        try {
            $m = Select-String -LiteralPath $cfg -Pattern '^\s*port:\s*(\d+)' -ErrorAction Stop | Select-Object -First 1
            if ($m) { return [int]$m.Matches[0].Groups[1].Value }
        } catch { }
    }
    return 8000
}

function Test-TavernRunning {
    param([string]$Root)

    # 端口在不在听，是最靠谱的信号。酒馆一般是在自己目录里跑 `node server.js`，
    # 命令行里根本不带路径，所以光靠进程命令行匹配会漏判 —— 而漏判的代价是
    # 用户的 settings.json 在酒馆退出时被覆盖回去，改了等于白改。
    $port = Get-TavernPort $Root
    try {
        if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop) { return $true }
    } catch {
        # 老系统没有 Get-NetTCPConnection，或者端口没人听（会抛错）。退回到直接连一下。
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async  = $client.BeginConnect('127.0.0.1', $port, $null, $null)
            $hit    = $async.AsyncWaitHandle.WaitOne(600)
            if ($hit) { $client.EndConnect($async); $client.Close(); return $true }
            $client.Close()
        } catch { }
    }

    # 兜底：有些启动器会把完整路径写进命令行
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop
    } catch {
        return $false
    }
    $needle = $Root.ToLowerInvariant()
    foreach ($p in $procs) {
        $cmd = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        if ($cmd -notmatch 'server\.js') { continue }
        if ($cmd.ToLowerInvariant().Contains($needle)) { return $true }
    }
    return $false
}

# ============================================================ 查找酒馆

function Get-CandidateFromProcesses {
    $found = @()
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop
    } catch {
        return $found
    }
    foreach ($p in $procs) {
        $cmd = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        foreach ($m in [regex]::Matches($cmd, '([A-Za-z]:\\[^"*?<>|]*?server\.js)')) {
            $dir = Split-Path -Parent $m.Groups[1].Value
            if ($dir) { $found += $dir }
        }
    }
    return $found
}

function Get-CandidateFromKnownPaths {
    $found = @()
    $names = @('SillyTavern', 'SillyTavern-Launcher\SillyTavern', 'ST\SillyTavern', '酒馆', '酒馆\SillyTavern')
    $bases = @(
        $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        $env:LOCALAPPDATA,
        'C:\'
    )
    foreach ($b in $bases) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        foreach ($n in $names) { $found += (Join-Path $b $n) }
    }
    return $found
}

function Get-CandidateFromDrives {
    # 每个固定盘符下深度 2：X:\SillyTavern 与 X:\<任意一层>\SillyTavern
    $found = @()
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
              Where-Object { $_.Root -match '^[A-Za-z]:\\$' }
    foreach ($d in $drives) {
        $root = $d.Root
        $found += (Join-Path $root 'SillyTavern')
        $subs = $null
        try {
            $subs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '^(Windows|\$Recycle\.Bin|System Volume Information|PerfLogs|Program Files.*|ProgramData)$' }
        } catch {
            continue
        }
        foreach ($s in $subs) {
            $found += (Join-Path $s.FullName 'SillyTavern')
        }
    }
    return $found
}

function Get-CandidateFromShortcuts {
    $found = @()
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Programs'),
        [Environment]::GetFolderPath('CommonPrograms')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    if (-not $dirs) { return $found }

    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { return $found }

    try {
        foreach ($dir in $dirs) {
            $lnks = Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -Recurse -Depth 2 -ErrorAction SilentlyContinue
            foreach ($lnk in $lnks) {
                try {
                    $sc = $shell.CreateShortcut($lnk.FullName)
                    foreach ($cand in @($sc.TargetPath, $sc.WorkingDirectory)) {
                        if ([string]::IsNullOrWhiteSpace($cand)) { continue }
                        if ($cand -notmatch 'SillyTavern|酒馆') { continue }
                        $probe = $cand
                        if (Test-Path -LiteralPath $probe -PathType Leaf) { $probe = Split-Path -Parent $probe }
                        for ($i = 0; $i -lt 3 -and $probe; $i++) {
                            $found += $probe
                            $probe = Split-Path -Parent $probe
                        }
                    }
                } catch { }
            }
        }
    } finally {
        if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    return $found
}

function Get-CandidateFromDeepScan {
    Write-Note '全盘深度扫描中，可能要几分钟...'
    $found = @()
    $skip = '\\(Windows|Program Files|Program Files \(x86\)|ProgramData|node_modules|\$Recycle\.Bin|System Volume Information|Temp|\.git)\\'
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
              Where-Object { $_.Root -match '^[A-Za-z]:\\$' }
    foreach ($d in $drives) {
        $hits = $null
        try {
            $hits = Get-ChildItem -LiteralPath $d.Root -Directory -Recurse -Depth 4 -Filter 'SillyTavern*' -ErrorAction SilentlyContinue
        } catch {
            continue
        }
        foreach ($h in $hits) {
            if ($h.FullName -match $skip) { continue }
            $found += $h.FullName
        }
    }
    return $found
}

function Find-TavernRoots {
    $ordered = New-Object System.Collections.Generic.List[string]
    $seen    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $sources = @(
        @{ Name = '正在运行的 node 进程';   Fn = { Get-CandidateFromProcesses } },
        @{ Name = '常见安装位置';           Fn = { Get-CandidateFromKnownPaths } },
        @{ Name = '各盘符浅层目录';         Fn = { Get-CandidateFromDrives } },
        @{ Name = '桌面/开始菜单快捷方式';  Fn = { Get-CandidateFromShortcuts } }
    )
    if ($DeepScan) {
        $sources += @{ Name = '全盘深度扫描'; Fn = { Get-CandidateFromDeepScan } }
    }

    foreach ($src in $sources) {
        $cands = @()
        try { $cands = & $src.Fn } catch { Write-Warn2 ('{0} 查找出错：{1}' -f $src.Name, $_.Exception.Message) }
        $hitHere = 0
        foreach ($c in $cands) {
            if ([string]::IsNullOrWhiteSpace($c)) { continue }
            $full = $null
            try { $full = (Resolve-Path -LiteralPath $c -ErrorAction Stop).Path } catch { continue }
            if ($seen.Contains($full)) { continue }
            if (Test-TavernRoot $full) {
                [void]$seen.Add($full)
                $ordered.Add($full)
                $hitHere++
            }
        }
        if ($hitHere -gt 0) { Write-Note ('{0}：命中 {1} 个' -f $src.Name, $hitHere) }
    }

    return $ordered
}

function Select-TavernRoot {
    param([System.Collections.Generic.List[string]]$Roots)

    if ($Roots.Count -eq 1) { return @($Roots[0]) }
    if ($All) { return $Roots.ToArray() }

    Write-Host ''
    Write-Host '   找到多个酒馆，请选择要修的那个：' -ForegroundColor Yellow
    for ($i = 0; $i -lt $Roots.Count; $i++) {
        Write-Host ('     [{0}] {1}  (v{2})' -f ($i + 1), $Roots[$i], (Get-TavernVersion $Roots[$i]))
    }
    Write-Host '     [A] 全部'
    $ans = Read-Host '   输入编号'
    if ($ans -match '^[Aa]$') { return $Roots.ToArray() }
    $idx = 0
    if ([int]::TryParse($ans, [ref]$idx) -and $idx -ge 1 -and $idx -le $Roots.Count) {
        return @($Roots[$idx - 1])
    }
    throw '没有选中任何酒馆，已退出。'
}

# ============================================================ 文件读写 / 备份

function Read-TextFile {
    param([string]$FilePath)
    return [System.IO.File]::ReadAllText($FilePath)
}

function Write-TextFile {
    param([string]$FilePath, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)   # 不带 BOM，跟酒馆自己的文件一致
    [System.IO.File]::WriteAllText($FilePath, $Text, $enc)
}

function Backup-TargetFile {
    param([string]$FilePath)
    $bak = '{0}.{1}-{2}.bak' -f $FilePath, $script:BackupTag, $script:Stamp
    Copy-Item -LiteralPath $FilePath -Destination $bak -Force
    Write-Note ('已备份 -> {0}' -f (Split-Path -Leaf $bak))
    return $bak
}

function Get-NewestBackup {
    param([string]$FilePath)
    $dir  = Split-Path -Parent $FilePath
    $leaf = Split-Path -Leaf   $FilePath
    $baks = Get-ChildItem -LiteralPath $dir -Filter ('{0}.{1}-*.bak' -f $leaf, $script:BackupTag) -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
    if ($baks) { return $baks[0].FullName }
    return $null
}

# ============================================================ 代码补丁

# 酒馆拉 Google 模型列表时按 supportedGenerationMethods 过滤；中转站这个字段是
# null，于是所有 gemini 型号被滤光，下拉框里选不到。放行「字段缺失」的情况即可，
# Google 官方返回的是真数组，照旧过滤，两边都不破。
$script:CodePattern = "\?\.filter\(\s*model\s*=>\s*model\.supportedGenerationMethods\?\.includes\(\s*'generateContent'\s*\)\s*\)"
$script:CodeReplace = "?.filter(model => !Array.isArray(model.supportedGenerationMethods) || model.supportedGenerationMethods.includes('generateContent')) /* " + $script:Marker + " */"

function Invoke-CodePatch {
    param([string]$Root)

    $codePath = Join-Path $Root $script:RelCode
    $htmlPath = Join-Path $Root $script:RelHtml

    $html = Read-TextFile $htmlPath
    if ($html -notmatch 'id="google_other_models"') {
        Write-Bad '这个酒馆的 public\index.html 里没有 google_other_models 分组，版本对不上，不动它。'
        Write-Note ('酒馆版本：{0}' -f (Get-TavernVersion $Root))
        return $false
    }

    $code = Read-TextFile $codePath

    if ($code.Contains($script:Marker)) {
        Write-Ok '代码补丁已经打过了，跳过。'
        return $true
    }

    $hits = [regex]::Matches($code, $script:CodePattern)
    if ($hits.Count -ne 1) {
        Write-Bad ('在 {0} 里找到 {1} 处待改代码（预期 1 处），版本对不上，不动它。' -f $script:RelCode, $hits.Count)
        Write-Note ('酒馆版本：{0}（本补丁在 1.18.0 上验证过）' -f (Get-TavernVersion $Root))
        Write-Note '请把这行信息发给作者，不要手动改。'
        return $false
    }

    Write-Note ('待改代码位于第 {0} 行附近' -f (($code.Substring(0, $hits[0].Index) -split "`n").Count))

    if (-not $PSCmdlet.ShouldProcess($codePath, '打补丁')) {
        Write-Note '（-WhatIf：只是演练，没有真改）'
        return $true
    }

    [void](Backup-TargetFile $codePath)
    $patched = $code.Remove($hits[0].Index, $hits[0].Length).Insert($hits[0].Index, $script:CodeReplace)
    Write-TextFile $codePath $patched
    Write-Ok '代码补丁已打上，中转站的型号现在会出现在 Google 下拉框的 Other 分组里。'
    return $true
}

# ============================================================ 配置

function Set-JsonProp {
    param([object]$Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-UserDataDir {
    param([string]$Root)

    $dataDir = Join-Path $Root 'data'
    if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) {
        throw ('找不到 {0}，酒馆可能还没启动过一次。请先跑一次酒馆再来。' -f $dataDir)
    }

    $users = @(Get-ChildItem -LiteralPath $dataDir -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike '_*' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'settings.json')) })

    if ($users.Count -eq 0) { throw ('{0} 下没有找到任何带 settings.json 的用户目录。' -f $dataDir) }
    if ($users.Count -eq 1) { return $users[0].FullName }

    Write-Host ''
    Write-Host '   这个酒馆有多个用户，选一个要配的：' -ForegroundColor Yellow
    for ($i = 0; $i -lt $users.Count; $i++) {
        Write-Host ('     [{0}] {1}' -f ($i + 1), $users[$i].Name)
    }
    $ans = Read-Host '   输入编号'
    $idx = 0
    if ([int]::TryParse($ans, [ref]$idx) -and $idx -ge 1 -and $idx -le $users.Count) {
        return $users[$idx - 1].FullName
    }
    throw '没有选中用户，已退出。'
}

function Invoke-ConfigPatch {
    param([string]$Root, [string]$Key)

    if (Test-TavernRunning $Root) {
        Write-Bad ('酒馆正在运行（端口 {0} 有人在听）。请先完全关掉酒馆再跑本脚本 —— 酒馆退出时会覆写 settings.json，现在改会被冲掉。' -f (Get-TavernPort $Root))
        Write-Note '只想打代码补丁、不动配置的话，可以加 -PatchOnly，那个不受此限制。'
        return $false
    }

    $userDir  = Get-UserDataDir $Root
    $settings = Join-Path $userDir 'settings.json'
    Write-Note ('配置文件：{0}' -f $settings)

    $raw = Read-TextFile $settings
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        Write-Bad ('settings.json 解析失败，不敢动：{0}' -f $_.Exception.Message)
        return $false
    }

    $topCountBefore = @($json.PSObject.Properties).Count

    if (-not $json.PSObject.Properties['oai_settings']) {
        Write-Bad 'settings.json 里没有 oai_settings 段，结构对不上，不动它。'
        return $false
    }
    $oai = $json.oai_settings

    # 已经是目标状态就彻底不动手：既让重复运行真正幂等，也保证 -Revert 拿到的
    # 那份备份始终是"改之前"的样子，而不是上一次跑完的样子。
    $needsChange = $false
    if ($oai.chat_completion_source -ne 'makersuite') { $needsChange = $true }
    if ($oai.google_model           -ne $Model)       { $needsChange = $true }
    if ($oai.show_thoughts          -ne $true)        { $needsChange = $true }
    if ($oai.reverse_proxy          -ne $RelayUrl)    { $needsChange = $true }
    if ($oai.proxy_password         -ne $Key)         { $needsChange = $true }
    # 注意：proxies / selected_proxy 存在 settings.json 的【根节点】，不在 oai_settings 里
    # （public/script.js 保存时是 payload.proxies / payload.selected_proxy，
    #   loadProxyPresets(settings) 读的也是根节点）。写错地方酒馆会读不到，
    #   反代下拉框会一直显示 None。
    if (-not $json.selected_proxy -or $json.selected_proxy.name -ne $script:ProxyName) { $needsChange = $true }

    $curProxy = $null
    if ($json.PSObject.Properties['proxies'] -and $json.proxies) {
        $curProxy = @($json.proxies) | Where-Object { $_ -and $_.name -eq $script:ProxyName } | Select-Object -First 1
    }
    if (-not $curProxy -or $curProxy.url -ne $RelayUrl -or $curProxy.password -ne $Key) { $needsChange = $true }

    $curProfile = $null
    if ($json.PSObject.Properties['extension_settings'] -and
        $json.extension_settings.PSObject.Properties['connectionManager'] -and
        $json.extension_settings.connectionManager -and
        $json.extension_settings.connectionManager.PSObject.Properties['profiles']) {
        $curProfile = @($json.extension_settings.connectionManager.profiles) |
                      Where-Object { $_ -and $_.name -eq $script:ProfileName } | Select-Object -First 1
    }
    if (-not $curProfile -or $curProfile.model -ne $Model -or $curProfile.proxy -ne $script:ProxyName -or $curProfile.api -ne 'google') {
        $needsChange = $true
    }

    if (-not $needsChange) {
        Write-Ok '配置已经是目标状态，无需改动。'
        return $true
    }

    if (-not $PSCmdlet.ShouldProcess($settings, '写入 Gemini 反代配置')) {
        Write-Note '（-WhatIf：只是演练，没有真改）'
        return $true
    }

    $bak = Backup-TargetFile $settings

    # --- 反代预设 -----------------------------------------------------------
    $newProxy = [pscustomobject]@{
        name     = $script:ProxyName
        url      = $RelayUrl
        password = $Key
    }
    $proxyList = New-Object System.Collections.ArrayList
    if ($json.PSObject.Properties['proxies'] -and $json.proxies) {
        foreach ($p in @($json.proxies)) {
            if ($p -and $p.name -ne $script:ProxyName) { [void]$proxyList.Add($p) }
        }
    }
    if (-not ($proxyList | Where-Object { $_.name -eq 'None' })) {
        [void]$proxyList.Insert(0, [pscustomobject]@{ name = 'None'; url = ''; password = '' })
    }
    [void]$proxyList.Add($newProxy)

    Set-JsonProp $json 'proxies'               $proxyList.ToArray()   # 根节点
    Set-JsonProp $json 'selected_proxy'        $newProxy               # 根节点
    Set-JsonProp $oai  'reverse_proxy'         $RelayUrl               # 这两个才在 oai_settings
    Set-JsonProp $oai  'proxy_password'        $Key

    # --- 走 Google AI Studio 源 + 打开思维链 ---------------------------------
    Set-JsonProp $oai 'chat_completion_source' 'makersuite'
    Set-JsonProp $oai 'google_model'           $Model
    Set-JsonProp $oai 'show_thoughts'          $true   # 关着酒馆就不会去要 thought

    # --- 连接档案（不动已有的档案，只加一条） --------------------------------
    if (-not $json.PSObject.Properties['extension_settings']) {
        Set-JsonProp $json 'extension_settings' ([pscustomobject]@{})
    }
    $ext = $json.extension_settings
    if (-not $ext.PSObject.Properties['connectionManager'] -or -not $ext.connectionManager) {
        Set-JsonProp $ext 'connectionManager' ([pscustomobject]@{ selectedProfile = ''; profiles = @() })
    }
    $cm = $ext.connectionManager

    $existing = $null
    if ($cm.PSObject.Properties['profiles'] -and $cm.profiles) {
        $existing = @($cm.profiles) | Where-Object { $_ -and $_.name -eq $script:ProfileName } | Select-Object -First 1
    }

    if ($existing) {
        Set-JsonProp $existing 'api'   'google'
        Set-JsonProp $existing 'model' $Model
        Set-JsonProp $existing 'proxy' $script:ProxyName
        $profileId = $existing.id
        Write-Note ('连接档案「{0}」已存在，就地更新。' -f $script:ProfileName)
    } else {
        $profileId  = [guid]::NewGuid().ToString()
        $cmProfile  = [pscustomobject]@{
            id                       = $profileId
            mode                     = 'cc'
            exclude                  = @()
            api                      = 'google'          # CONNECT_API_MAP 里 Google AI Studio 的键名
            'api-url'                = ''
            model                    = $Model
            proxy                    = $script:ProxyName
            'stop-strings'           = ''
            'start-reply-with'       = ''
            'reasoning-template'     = 'None'
            'prompt-post-processing' = 'none'
            name                     = $script:ProfileName
        }
        $profileList = New-Object System.Collections.ArrayList
        if ($cm.PSObject.Properties['profiles'] -and $cm.profiles) {
            foreach ($p in @($cm.profiles)) { if ($p) { [void]$profileList.Add($p) } }
        }
        [void]$profileList.Add($cmProfile)
        Set-JsonProp $cm 'profiles' $profileList.ToArray()
        Write-Note ('已新增连接档案「{0}」，原有档案一个字没动。' -f $script:ProfileName)
    }
    Set-JsonProp $cm 'selectedProfile' $profileId

    # --- 落盘 + 校验，出问题立刻回滚 ------------------------------------------
    $out = $json | ConvertTo-Json -Depth 100
    Write-TextFile $settings $out

    try {
        $check = (Read-TextFile $settings) | ConvertFrom-Json
    } catch {
        Copy-Item -LiteralPath $bak -Destination $settings -Force
        Write-Bad ('写完的 settings.json 解析不了，已自动回滚。原因：{0}' -f $_.Exception.Message)
        return $false
    }

    $topCountAfter = @($check.PSObject.Properties).Count
    if ($topCountAfter -lt $topCountBefore -or
        $check.oai_settings.google_model -ne $Model -or
        $check.oai_settings.chat_completion_source -ne 'makersuite' -or
        $check.oai_settings.show_thoughts -ne $true -or
        -not $check.selected_proxy -or $check.selected_proxy.name -ne $script:ProxyName -or
        $check.selected_proxy.url -ne $RelayUrl) {
        Copy-Item -LiteralPath $bak -Destination $settings -Force
        Write-Bad ('写完的 settings.json 校验不通过（顶层字段 {0} -> {1}），已自动回滚。' -f $topCountBefore, $topCountAfter)
        Write-Note '原文件已原样放回，酒馆不受影响。'
        return $false
    }

    Write-Ok ('配置完成：Google AI Studio + 反代 {0}，型号 {1}，Show thoughts 已打开。' -f $RelayUrl, $Model)
    return $true
}

# ============================================================ 自检

function Invoke-SelfTest {
    param([string]$Key)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $uri = '{0}/v1beta/models/{1}:generateContent' -f $RelayUrl.TrimEnd('/'), $Model
    $prompt = '一个农夫要带狼、羊和白菜过河，船每次只能带一样。请仔细推演每一趟怎么走，最后给出完整的过河顺序。'
    $bodyObj = @{
        contents = @(
            @{ role = 'user'; parts = @(@{ text = $prompt }) }
        )
        generationConfig = @{
            thinkingConfig = @{ includeThoughts = $true }
        }
    }
    $bodyJson  = $bodyObj | ConvertTo-Json -Depth 10
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($bodyJson)

    Write-Note ('正在实打一次：{0}' -f $uri)

    $resp = $null
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri `
                    -Headers @{ 'x-goog-api-key' = $Key } `
                    -ContentType 'application/json; charset=utf-8' `
                    -Body $bodyBytes -TimeoutSec 180
    } catch {
        $code = ''
        try { $code = [string]$_.Exception.Response.StatusCode.value__ } catch { }
        switch ($code) {
            '401' { Write-Bad 'HTTP 401：API Key 不对，或者已经被停用。' }
            '403' { Write-Bad 'HTTP 403：这个 Key 没有权限访问中转站。' }
            '404' { Write-Bad ('HTTP 404：中转站说型号 {0} 不在你这个 Key 的分组里，换一个型号试试。' -f $Model) }
            default { Write-Bad ('请求失败：{0}' -f $_.Exception.Message) }
        }
        return $false
    }

    $parts = @()
    foreach ($c in @($resp.candidates)) {
        foreach ($p in @($c.content.parts)) { $parts += $p }
    }
    $thoughts = @($parts | Where-Object { $_.PSObject.Properties['thought'] -and $_.thought })

    if ($thoughts.Count -gt 0) {
        Write-Ok ('中转站返回了 {0} 个独立思维分段（thought=true），酒馆侧折叠已就绪。' -f $thoughts.Count)
        return $true
    }

    Write-Warn2 ('中转站这次没有返回 thought 分段（共 {0} 个分段）。' -f $parts.Count)
    Write-Note '多半是这个型号本轮没思考。换成带 -high / -medium 后缀的 3.x 型号再试，例如：'
    Write-Note '  -Model gemini-3.8-flash-high    或    -Model gemini-3.1-pro-high'
    return $false
}

# ============================================================ 还原

function Invoke-Revert {
    param([string]$Root)

    $ok = $true
    $targets = @((Join-Path $Root $script:RelCode))
    try {
        $userDir = Get-UserDataDir $Root
        $targets += (Join-Path $userDir 'settings.json')
    } catch {
        Write-Note '（没找到用户目录，只还原代码文件）'
    }

    foreach ($t in $targets) {
        $bak = Get-NewestBackup $t
        if (-not $bak) {
            Write-Warn2 ('{0} 没有找到备份，跳过。' -f (Split-Path -Leaf $t))
            continue
        }
        if ($PSCmdlet.ShouldProcess($t, ('从 {0} 还原' -f (Split-Path -Leaf $bak)))) {
            if ((Split-Path -Leaf $t) -eq 'settings.json' -and (Test-TavernRunning $Root)) {
                Write-Bad '酒馆正在运行，settings.json 不还原。请先关掉酒馆。'
                $ok = $false
                continue
            }
            Copy-Item -LiteralPath $bak -Destination $t -Force
            Write-Ok ('{0} 已还原自 {1}' -f (Split-Path -Leaf $t), (Split-Path -Leaf $bak))
        }
    }
    return $ok
}

# ============================================================ 主流程

Write-Host ''
Write-Host '  酒馆 Gemini 思维链修复工具' -ForegroundColor White
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host '  中转站把 Gemini 的思维链拍进了正文，本工具让酒馆改走原生端点。' -ForegroundColor DarkGray

Write-Step '找酒馆'

$roots = $null
if ($Path) {
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { }
    if (-not $full -or -not (Test-TavernRoot $full)) {
        Write-Bad ('-Path 指定的目录不是酒馆根目录：{0}' -f $Path)
        Write-Note '应该是含有 server.js、public\index.html 的那一层。'
        exit 2
    }
    $roots = @($full)
    Write-Note ('用 -Path 指定：{0}' -f $full)
} else {
    $list = Find-TavernRoots
    if ($list.Count -eq 0) {
        Write-Bad '没找到 SillyTavern。'
        Write-Note '试试 -DeepScan 全盘扫描，或者直接指定路径：'
        Write-Note '  .\Fix-GeminiThinking.ps1 -Path "D:\你的路径\SillyTavern"'
        exit 3
    }
    $roots = Select-TavernRoot $list
}

foreach ($r in $roots) {
    Write-Ok ('{0}   (v{1})' -f $r, (Get-TavernVersion $r))
}

if ($Revert) {
    foreach ($r in $roots) {
        Write-Step ('还原：{0}' -f $r)
        [void](Invoke-Revert $r)
    }
    Write-Host ''
    Write-Host '  已还原。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# key：配置阶段才需要
$key = $ApiKey
if (-not $PatchOnly) {
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Step '中转站 API Key'
        Write-Note ('中转站地址：{0}' -f $RelayUrl)
        Write-Note 'Key 只会写进你本机的 settings.json，不上传任何地方。'
        $key = Read-Host '   请粘贴你的 API Key (sk-...)'
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Bad '没有 Key 就没法配置。想只打代码补丁请加 -PatchOnly。'
        exit 4
    }
}

$allOk = $true
foreach ($r in $roots) {
    Write-Step ('打补丁  {0}' -f $r)
    if (-not (Invoke-CodePatch $r)) { $allOk = $false; continue }

    if ($PatchOnly) {
        Write-Note '（-PatchOnly：跳过自动配置）'
        continue
    }

    Write-Step ('写配置  {0}' -f $r)
    if (-not (Invoke-ConfigPatch $r $key)) { $allOk = $false }
}

if (-not $PatchOnly -and -not $NoSelfTest -and -not $WhatIfPreference) {
    Write-Step '自检（实打一次中转站）'
    [void](Invoke-SelfTest $key)
}

Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
if ($allOk) {
    Write-Host '  完成。接下来：' -ForegroundColor Green
    Write-Host '    1. 启动酒馆，按 Ctrl+F5 强刷一次页面（换了后端代码）'
    if ($PatchOnly) {
        Write-Host '    2. API 面板选 Google AI Studio，反向代理填中转站地址、密码填你的 Key'
        Write-Host '    3. 打开 Show thoughts（不打开酒馆不会去要思维链）'
        Write-Host '    4. 点 Connect，型号在下拉框最底下的 Other 分组里'
        Write-Host '    5. 发一条消息，思维链应该进折叠块，正文干净'
    } else {
        Write-Host ('    2. 右上角连接档案选「{0}」，点 Connect' -f $script:ProfileName)
        Write-Host '    3. 型号在下拉框最底下的 Other 分组里'
        Write-Host '    4. 发一条消息，思维链应该进折叠块，正文干净'
    }
    Write-Host ''
    Write-Host '  酒馆以后升级会覆盖补丁，重跑一次本脚本即可。' -ForegroundColor DarkGray
    Write-Host '  想还原：Fix-GeminiThinking.ps1 -Revert' -ForegroundColor DarkGray
} else {
    Write-Host '  有步骤没做成，往上翻看红色的 [X] 行。' -ForegroundColor Yellow
    Write-Host '  所有改动都有 .bak 备份，可以用 -Revert 还原。' -ForegroundColor Yellow
}
Write-Host ''

if ($allOk) { exit 0 } else { exit 1 }
