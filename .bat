u/echo off
title MediaFire Link Grabber
powershell -STA -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText('%~f0'); $i=$s.IndexOf('#PS'+'-START'); Invoke-Expression $s.Substring($i)"
if errorlevel 1 pause
exit /b
#PS-START
# MediaFire folder/file links -> direct download links (copy and paste into any downloader).
# Uses only what ships with Windows: PowerShell + Edge (or Chrome). Nothing to install.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Native -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
'@
[void][Native.Win]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

$global:ws = $null; $global:cid = 0; $global:proc = $null; $global:port = 0
$global:abort = $false; $global:stop = $false; $global:onMF = $false
$global:running = $false; $global:fs = 11
$global:recs = New-Object Collections.Generic.List[object]
$global:srcs = @(); $global:badFolders = New-Object Collections.Generic.List[string]
$BACKUP_DIR = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'MediaFire Link Grabber'

$JS_STATUS = @'
(async()=>{try{const r=await fetch('/api/1.5/folder/get_info.php?response_format=json&folder_key=__KEY__');return (await r.json()).response.result}catch(e){return null}})()
'@

$JS_LIST = @'
(async()=>{
let top='';try{const g=await (await fetch('/api/1.5/folder/get_info.php?response_format=json&folder_key=__KEY__')).json();top=g.response.folder_info.name||''}catch(e){}
async function walk(k,p){let out=[];for(const t of ['files','folders']){let c=1,more=true;while(more){const r=await fetch('/api/1.5/folder/get_content.php?response_format=json&folder_key='+k+'&content_type='+t+'&chunk='+c+'&chunk_size=1000');const j=(await r.json()).response.folder_content;if(t==='files'){(j.files||[]).forEach(f=>{if(f.links&&f.links.normal_download)out.push({u:f.links.normal_download,n:f.filename,s:+f.size||0,h:f.hash||'',p:f.password_protected||'no',d:p})})}else{for(const d of (j.folders||[])){out=out.concat(await walk(d.folderkey,p+'/'+d.name))}}more=j.more_chunks==='yes';c++}}return out}
return JSON.stringify(await walk('__KEY__',top))})()
'@

$JS_DIRECT = @'
(async()=>{try{const url=__URL__;const res=await fetch(url);const html=await res.text();const d=new DOMParser().parseFromString(html,'text/html');const b=d.querySelector('#downloadButton');let link=null;if(b){const s=b.getAttribute('data-scrambled-url');if(s){try{link=atob(s)}catch(e){}}const h=b.getAttribute('href');if(!link&&h&&/^https?:\/\/download/i.test(h))link=h}if(!link){const a=d.querySelector('#download_link a[aria-label="Download file"]');if(a)link=a.href}let st='OK';if(!link){if(res.status===404||/invalid or deleted file|has been (removed|deleted)|key you provided|removed for violation/i.test(html))st='Removed';else if(d.querySelector('input[type=password]'))st='Password-protected';else if(/just a moment|cf-challenge|cf-turnstile/i.test(html))st='Blocked';else st='Unresolved'}return JSON.stringify({d:link,s:st})}catch(e){return JSON.stringify({d:null,s:'Unresolved'})}})()
'@

# ---------------- browser plumbing (Edge/Chrome DevTools protocol) ----------------
function Pump { [Windows.Forms.Application]::DoEvents() }
function Sleep-Pump($ms) { $n = [math]::Ceiling($ms / 50); for ($k = 0; $k -lt $n -and -not $global:stop; $k++) { Pump; Start-Sleep -Milliseconds 50 } }

function Wait-Task($t) {
    while (-not $t.IsCompleted) { Pump; Start-Sleep -Milliseconds 15; if ($global:abort) { throw 'Closed.' } }
    if ($t.IsFaulted) { throw $t.Exception.GetBaseException().Message }
}

function Receive-Msg {
    $buf = [byte[]]::new(65536)
    $seg = [ArraySegment[byte]]::new($buf)
    $sb = New-Object Text.StringBuilder
    do {
        $t = $global:ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        Wait-Task $t
        $r = $t.Result
        [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
    } while (-not $r.EndOfMessage)
    return $sb.ToString()
}

function Send-Cdp($method, $params) {
    $global:cid++; $my = $global:cid
    $msg = @{ id = $my; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress
    $seg = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($msg))
    Wait-Task ($global:ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None))
    while ($true) {
        $o = (Receive-Msg) | ConvertFrom-Json
        if ($o.id -eq $my) { return $o }
    }
}

function Ev($js) {
    $o = Send-Cdp 'Runtime.evaluate' @{ expression = $js; awaitPromise = $true; returnByValue = $true }
    if ($o.error -or $o.result.exceptionDetails) { return $null }
    return $o.result.result.value
}

function Nav($u) { Send-Cdp 'Page.navigate' @{ url = $u } | Out-Null; Sleep-Pump 1500 }

function Open-Browser {
    $exe = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { throw 'Microsoft Edge or Google Chrome was not found.' }
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start()
    $global:port = $l.LocalEndpoint.Port; $l.Stop()
    $prof = Join-Path $env:LOCALAPPDATA 'MediaFireGrabberProfile'
    $global:proc = Start-Process $exe -PassThru -ArgumentList @(
        "--remote-debugging-port=$($global:port)", '--remote-allow-origins=*',
        "--user-data-dir=`"$prof`"", '--no-first-run', '--no-default-browser-check', 'about:blank')
    $url = $null
    for ($i = 0; $i -lt 40 -and -not $url; $i++) {
        Sleep-Pump 500
        try {
            $t = Invoke-RestMethod "http://127.0.0.1:$($global:port)/json" -TimeoutSec 2
            $p = @($t) | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
            if ($p) { $url = $p.webSocketDebuggerUrl }
        } catch {}
    }
    if (-not $url) { throw 'Could not connect to the browser.' }
    $global:ws = New-Object Net.WebSockets.ClientWebSocket
    Wait-Task ($global:ws.ConnectAsync([Uri]$url, [Threading.CancellationToken]::None))
}

function Close-Browser {
    try { $global:ws.Dispose() } catch {}
    try { if ($global:proc -and -not $global:proc.HasExited) { [void]$global:proc.CloseMainWindow() } } catch {}
    $global:ws = $null; $global:proc = $null
}

# ---------------- theme (all text pairs are WCAG AA or better) ----------------
# bg 132440 | field 0B1B30 | text F5F8FA (15:1) | muted C9D6E3 (10:1)
# teal 3B9797: borders (4.5:1) and Start fill with dark text 0A1626 (5.3:1)
# red BF092F + white (6.4:1) | blue 16476A + white (9.8:1) | problem text FF9AA9 (7:1)
function Col($hex) { [Drawing.ColorTranslator]::FromHtml('#' + $hex) }

function New-Btn($text, $name, $bg, $fg) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.AccessibleName = $name; $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false
    $b.BackColor = Col $bg; $b.ForeColor = Col $fg
    $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'
    $b.Padding = New-Object Windows.Forms.Padding(10, 4, 10, 4)
    $b.Margin = New-Object Windows.Forms.Padding(0, 6, 10, 6)
    $b.FlatAppearance.BorderSize = 2; $b.FlatAppearance.BorderColor = Col '3B9797'
    $b.Add_GotFocus({ param($s, $e) $s.FlatAppearance.BorderColor = Col 'FFFFFF' })
    $b.Add_LostFocus({ param($s, $e) $s.FlatAppearance.BorderColor = Col '3B9797' })
    return $b
}

function Style-Btn($b, $on, $bg, $fg) {
    if ($on) { $b.BackColor = Col $bg; $b.ForeColor = Col $fg }
    else { $b.BackColor = Col '1F3A5A'; $b.ForeColor = Col 'B8C7D6' }
}

function New-Frame($child, $name) {
    $p = New-Object Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.BackColor = Col '3B9797'; $p.Padding = New-Object Windows.Forms.Padding(2)
    $p.Margin = New-Object Windows.Forms.Padding(0, 2, 0, 8)
    $child.Dock = 'Fill'; $child.AccessibleName = $name
    $child.BackColor = Col '0B1B30'; $child.ForeColor = Col 'F5F8FA'
    $child.Tag = $p
    $child.Add_GotFocus({ param($s, $e) $s.Tag.BackColor = Col 'FFFFFF' })
    $child.Add_LostFocus({ param($s, $e) $s.Tag.BackColor = Col '3B9797' })
    $p.Controls.Add($child)
    return $p
}

function New-Label($text) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.Dock = 'Fill'
    $l.ForeColor = Col 'C9D6E3'; $l.BackColor = [Drawing.Color]::Transparent
    $l.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 2)
    return $l
}

function Log($m) {
    $global:lbl.Text = $m
    $global:lbl.ForeColor = if ($m -match '^(Error|Gave up|No MediaFire|Nothing)') { Col 'FF9AA9' } else { Col 'F5F8FA' }
    Pump
}

function Set-Run($r) {
    $global:running = $r
    Style-Btn $btnStart (-not $r) '3B9797' '0A1626'
    Style-Btn $btnRetry (-not $r) '16476A' 'FFFFFF'
    Style-Btn $btnStop $r 'BF092F' 'FFFFFF'
}

# ---------------- data helpers ----------------
function Fmt-Size($b) {
    if ($b -le 0) { return '-' }
    $u = 'B', 'KB', 'MB', 'GB', 'TB'; $i = 0; $v = [double]$b
    while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
    return ('{0:N1} {1}' -f $v, $u[$i])
}

function New-Rec($src, $name, $size, $hash, $path) {
    [pscustomobject]@{ Src = $src; Name = $name; Size = [double]$size; Hash = $hash; Path = $path
                       Direct = ''; Status = 'Pending'; Dup = $false; Item = $null }
}

function Update-Item($r) {
    $it = $r.Item
    $it.Text = $r.Status
    $it.SubItems[1].Text = $(if ($r.Dup) { '[duplicate] ' + $r.Name } else { $r.Name })
    $it.SubItems[2].Text = Fmt-Size $r.Size
    $it.SubItems[3].Text = $r.Direct
    $it.ForeColor = if ($r.Status -eq 'OK') { Col 'F5F8FA' } elseif ($r.Status -eq 'Pending') { Col 'C9D6E3' } else { Col 'FF9AA9' }
}

function Add-Rec($r) {
    $it = [Windows.Forms.ListViewItem]::new([string[]]@('', '', '', ''))
    $r.Item = $it
    [void]$lv.Items.Add($it)
    $global:recs.Add($r)
    Update-Item $r
}

function Summary-Text {
    if ($global:recs.Count -eq 0) { return '0 links' }
    $parts = @()
    foreach ($s in 'OK', 'Removed', 'Password-protected', 'Blocked', 'Unresolved', 'Pending') {
        $n = @($global:recs | Where-Object { $_.Status -eq $s }).Count
        if ($n -gt 0) { $parts += "$n $s" }
    }
    $t = $parts -join ', '
    $sz = (@($global:recs | Where-Object { $_.Status -eq 'OK' }) | Measure-Object -Property Size -Sum).Sum
    if ($sz -gt 0) { $t += " - $(Fmt-Size $sz) total" }
    $d = @($global:recs | Where-Object { $_.Dup }).Count
    if ($d -gt 0) { $t += " - $d duplicate(s) by hash" }
    if ($global:badFolders.Count -gt 0) { $t += " - $($global:badFolders.Count) folder(s) failed" }
    return $t
}

function OkLinks { @($global:recs | Where-Object { $_.Status -eq 'OK' } | ForEach-Object { $_.Direct }) }

function Build-Report {
    $n = "`r`n"
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("MediaFire Link Grabber report - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')$n")
    [void]$sb.Append((Summary-Text) + $n + $n)
    [void]$sb.Append("SOURCE LINKS (these stay valid - paste them back into the tool to regenerate everything):$n")
    foreach ($s in $global:srcs) { [void]$sb.Append($s + $n) }
    foreach ($s in $global:badFolders) { [void]$sb.Append("# folder failed: $s$n") }
    [void]$sb.Append($n + "FILES (tab-separated: status, size, name, folder, page link, direct link; direct links expire):$n")
    foreach ($r in $global:recs) {
        [void]$sb.Append((@($r.Status, (Fmt-Size $r.Size), $r.Name, $r.Path, $r.Src, $r.Direct) -join "`t") + $n)
    }
    return $sb.ToString()
}

function Write-Text($path, $text) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }

function Save-Backup {
    try {
        New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null
        Write-Text (Join-Path $BACKUP_DIR ("{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))) (Build-Report)
        return $true
    } catch { return $false }
}

function Convert-Rec($r) {
    $js = $JS_DIRECT.Replace('__URL__', (ConvertTo-Json -Compress -InputObject ([string]$r.Src)))
    $o = $null
    for ($a = 0; $a -lt 2 -and -not $global:stop; $a++) {
        $raw = Ev $js
        if ($raw) {
            $o = $raw | ConvertFrom-Json
            if ($o.d -or ($o.s -in 'Removed', 'Password-protected')) { break }
        }
        Sleep-Pump 1000
    }
    if ($o -and $o.d) { $r.Direct = [string]$o.d; $r.Status = 'OK' }
    elseif ($o) { $r.Status = [string]$o.s }
    else { $r.Status = 'Unresolved' }
}

# ---------------- GUI ----------------
$form = New-Object Windows.Forms.Form
$form.Text = 'MediaFire Link Grabber'; $form.Size = New-Object Drawing.Size(1000, 780)
$form.MinimumSize = New-Object Drawing.Size(700, 500)
$form.StartPosition = 'CenterScreen'; $form.BackColor = Col '132440'; $form.ForeColor = Col 'F5F8FA'
$form.Padding = New-Object Windows.Forms.Padding(14); $form.KeyPreview = $true

$lblIn = New-Label 'Paste MediaFire folder and/or file links, one per line:'
$tbIn = New-Object Windows.Forms.TextBox
$tbIn.Multiline = $true; $tbIn.ScrollBars = 'Both'; $tbIn.WordWrap = $false; $tbIn.BorderStyle = 'None'
$pIn = New-Frame $tbIn 'MediaFire links input'

$btnStart = New-Btn '&Start' 'Start' '3B9797' '0A1626'
$btnStop = New-Btn 'S&top' 'Stop' 'BF092F' 'FFFFFF'
$btnRetry = New-Btn '&Retry / resume' 'Retry failed or resume' '16476A' 'FFFFFF'
$btnCopy = New-Btn '&Copy links' 'Copy links' '16476A' 'FFFFFF'
$btnExport = New-Btn '&Export .txt' 'Export to text file' '16476A' 'FFFFFF'
$btnBackups = New-Btn '&Backups' 'Open backups folder' '16476A' 'FFFFFF'
$lblSize = New-Label 'Text size:'; $lblSize.Dock = 'None'; $lblSize.Margin = New-Object Windows.Forms.Padding(14, 12, 6, 0)
$btnMinus = New-Btn 'A-' 'Decrease text size' '16476A' 'FFFFFF'
$btnPlus = New-Btn 'A+' 'Increase text size' '16476A' 'FFFFFF'

$bar = New-Object Windows.Forms.FlowLayoutPanel
$bar.Dock = 'Fill'; $bar.AutoSize = $true; $bar.WrapContents = $true; $bar.BackColor = [Drawing.Color]::Transparent
$bar.Controls.AddRange(@($btnStart, $btnStop, $btnRetry, $btnCopy, $btnExport, $btnBackups, $lblSize, $btnMinus, $btnPlus))

$global:lbl = New-Label 'Ready.'; $global:lbl.ForeColor = Col 'F5F8FA'
$lblOut = New-Label 'Results: 0 links'

$lv = New-Object Windows.Forms.ListView
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.BorderStyle = 'None'
$lv.HeaderStyle = 'Nonclickable'; $lv.MultiSelect = $true; $lv.OwnerDraw = $true
foreach ($c in 'Status', 'Name', 'Size', 'Direct link') { [void]$lv.Columns.Add($c, 100) }
$lv.Add_DrawColumnHeader({
    param($s, $e)
    $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush (Col '16476A')), $e.Bounds)
    $rect = [Drawing.Rectangle]::new($e.Bounds.X + 6, $e.Bounds.Y, [math]::Max(1, $e.Bounds.Width - 6), $e.Bounds.Height)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, $rect, (Col 'FFFFFF'), ([Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis'))
})
$lv.Add_DrawItem({ param($s, $e) })
$lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
$pOut = New-Frame $lv 'Results list'

$tl = New-Object Windows.Forms.TableLayoutPanel
$tl.Dock = 'Fill'; $tl.ColumnCount = 1; $tl.RowCount = 6; $tl.BackColor = [Drawing.Color]::Transparent
[void]$tl.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
foreach ($r in @(@('A', 0), @('P', 28), @('A', 0), @('A', 0), @('A', 0), @('P', 72))) {
    if ($r[0] -eq 'A') { [void]$tl.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) }
    else { [void]$tl.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, $r[1])) }
}
$tl.Controls.Add($lblIn, 0, 0); $tl.Controls.Add($pIn, 0, 1); $tl.Controls.Add($bar, 0, 2)
$tl.Controls.Add($global:lbl, 0, 3); $tl.Controls.Add($lblOut, 0, 4); $tl.Controls.Add($pOut, 0, 5)
$form.Controls.Add($tl)

# text size (remembered between runs)
$cfg = Join-Path $env:LOCALAPPDATA 'MediaFireGrabber\size.txt'
try { if (Test-Path $cfg) { $global:fs = [math]::Min(22, [math]::Max(9, [int](Get-Content $cfg -TotalCount 1))) } } catch {}
function Apply-Font {
    $form.Font = [Drawing.Font]::new('Segoe UI', [single]$global:fs)
    $tbIn.Font = [Drawing.Font]::new('Consolas', [single]$global:fs)
    $k = $global:fs / 11
    $lv.Columns[0].Width = [int](150 * $k); $lv.Columns[1].Width = [int](340 * $k)
    $lv.Columns[2].Width = [int](100 * $k); $lv.Columns[3].Width = [int](800 * $k)
    try { New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null; Set-Content $cfg $global:fs } catch {}
}
function Change-Size($d) { $global:fs = [math]::Min(22, [math]::Max(9, $global:fs + $d)); Apply-Font }
Apply-Font
Set-Run $false

# ---------------- main job ----------------
function Run-Job($retry) {
    if ($global:running) { return }
    $global:stop = $false; $global:onMF = $false
    if ($retry) {
        $elig = @($global:recs | Where-Object { $_.Status -in 'Pending', 'Unresolved', 'Blocked' })
        if ($elig.Count -eq 0) { Log 'Nothing to retry.'; return }
    } else {
        $urls = @($tbIn.Text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match 'mediafire\.com' } | Select-Object -Unique)
        if ($urls.Count -eq 0) { Log 'No MediaFire links entered.'; return }
    }
    Set-Run $true
    try {
        Log 'Starting browser...'
        Open-Browser
        if (-not $retry) {
            $global:srcs = $urls; $global:recs.Clear(); $global:badFolders.Clear(); $lv.Items.Clear()
            $seenSrc = @{}; $seenHash = @{}
            foreach ($u in $urls) {
                if ($global:stop) { break }
                if ($u -match '/folder/([a-z0-9]+)') {
                    $key = $Matches[1]
                    Log "Opening folder $key ..."
                    Nav $u
                    $waited = 0; $good = $false
                    while ($waited -lt 300 -and -not $global:stop) {
                        if ((Ev ($JS_STATUS.Replace('__KEY__', $key))) -eq 'Success') { $good = $true; break }
                        if ($waited % 10 -eq 0) { Log 'Waiting... if the browser shows a Cloudflare check, complete it there.' }
                        Sleep-Pump 2000; $waited += 2
                    }
                    if (-not $good) { $global:badFolders.Add($u); continue }
                    $global:onMF = $true
                    $raw = Ev ($JS_LIST.Replace('__KEY__', $key))
                    $found = @(); if ($raw) { $parsed = $raw | ConvertFrom-Json; $found = @($parsed | ForEach-Object { $_ }) }
                    Log "Folder $key : $($found.Count) file(s) found."
                    foreach ($o in $found) {
                        if ($seenSrc.ContainsKey($o.u)) { continue }
                        $seenSrc[$o.u] = 1
                        $r = New-Rec $o.u $o.n $o.s $o.h $o.d
                        if ($o.p -eq 'yes') { $r.Status = 'Password-protected' }
                        if ($o.h) { if ($seenHash.ContainsKey($o.h)) { $r.Dup = $true } else { $seenHash[$o.h] = 1 } }
                        Add-Rec $r
                    }
                } else {
                    if ($seenSrc.ContainsKey($u)) { continue }
                    $seenSrc[$u] = 1
                    $nm = $u; if ($u -match '/file/[^/]+/([^/?#]+)') { $nm = [Uri]::UnescapeDataString($Matches[1]) }
                    Add-Rec (New-Rec $u $nm 0 '' '')
                }
            }
            $lblOut.Text = 'Results: ' + (Summary-Text)
        }
        $todo = @($global:recs | Where-Object { $_.Status -in 'Pending', 'Unresolved', 'Blocked' })
        if ($todo.Count -gt 0 -and -not $global:onMF -and -not $global:stop) { Nav 'https://www.mediafire.com/'; Sleep-Pump 4000 }
        $i = 0
        foreach ($r in $todo) {
            if ($global:stop) { break }
            $i++; Log "Converting $i of $($todo.Count) ..."
            Convert-Rec $r
            Update-Item $r
            $lblOut.Text = 'Results: ' + (Summary-Text)
            Sleep-Pump 400
        }
        $saved = ''
        if ($global:recs.Count -gt 0) { if (Save-Backup) { $saved = ' Backup saved.' } }
        $note = if ($global:stop) { 'Stopped. Use Retry / resume to continue.' } else { 'Done.' }
        Log "$note $(Summary-Text).$saved"
    } catch {
        Log "Error: $($_.Exception.Message)"
    } finally {
        Close-Browser
        Set-Run $false
    }
}

# ---------------- events ----------------
$btnStart.Add_Click({ Run-Job $false })
$btnRetry.Add_Click({ Run-Job $true })
$btnStop.Add_Click({ if ($global:running) { $global:stop = $true; Log 'Stopping...' } })
$btnMinus.Add_Click({ Change-Size -1 })
$btnPlus.Add_Click({ Change-Size 1 })

$btnCopy.Add_Click({
    $l = @(OkLinks)
    if ($l.Count -gt 0) { [Windows.Forms.Clipboard]::SetText(($l -join "`r`n")); Log "Copied $($l.Count) links." }
    else { Log 'Nothing to copy yet.' }
})

$btnExport.Add_Click({
    if ($global:recs.Count -eq 0) { Log 'Nothing to export yet.'; return }
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Links only (*.txt)|*.txt|Full report with source links (*.txt)|*.txt'
    $dlg.FileName = 'mediafire-links.txt'
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            if ($dlg.FilterIndex -eq 1) { Write-Text $dlg.FileName ((@(OkLinks) -join "`r`n")) }
            else { Write-Text $dlg.FileName (Build-Report) }
            Log "Exported to $($dlg.FileName)"
        } catch { Log "Error: could not save the file." }
    }
})

$btnBackups.Add_Click({
    try { New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null; Start-Process explorer.exe $BACKUP_DIR }
    catch { Log 'Error: could not open the backups folder.' }
})

$form.Add_FormClosing({ $global:abort = $true; $global:stop = $true; Close-Browser })
$form.Add_KeyDown({
    param($s, $e)
    if ($e.Control -and $e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; $btnStart.PerformClick() }
    elseif ($e.KeyCode -eq 'Escape' -and $global:running) { $btnStop.PerformClick() }
    elseif ($e.Control -and ($e.KeyCode -eq 'Oemplus' -or $e.KeyCode -eq 'Add')) { Change-Size 1 }
    elseif ($e.Control -and ($e.KeyCode -eq 'OemMinus' -or $e.KeyCode -eq 'Subtract')) { Change-Size -1 }
})
$form.Add_Shown({
    try { $v = 1; [void][Native.Win]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch {}
    $tbIn.Focus() | Out-Null
})

[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)
[void]$form.ShowDialog()
