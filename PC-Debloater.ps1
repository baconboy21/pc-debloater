# =====================================================================
#  PC Debloater  -  pick what to remove, keep the rest, get a log file
#  Run it with "Run PC Debloater.bat" (it asks for admin by itself)
#  Free + open source (MIT license). Not affiliated with Microsoft,
#  NVIDIA, AMD or Intel.
# =====================================================================

param([switch]$CheckOnly)

$AppName    = 'PC Debloater'
$AppVersion = '1.1.1'
# Put your GitHub page here before you release it (used by "Report a bug" and the About screen)
$ProjectUrl = 'https://github.com/baconboy21/pc-debloater'
$DataDir    = Join-Path $env:ProgramData 'PC Debloater'
$LogDir     = Join-Path $DataDir 'logs'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
$ErrorActionPreference = 'Continue'

# ---------- Crash log: if anything breaks, save the details so people can send them to you ----------
function Write-CrashLog($err, [string]$where) {
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $os = ''; try { $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $os = "$($o.Caption) (build $($o.BuildNumber), $($o.OSArchitecture))" } catch {}
    $lines = @(
        "$AppName v$AppVersion - ERROR REPORT",
        "Time:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Where:      $where",
        "Windows:    $os",
        "PowerShell: $($PSVersionTable.PSVersion)",
        '',
        "Error:      $($err.Exception.Message)",
        "Type:       $($err.Exception.GetType().FullName)",
        '',
        'Position:', "$($err.InvocationInfo.PositionMessage)",
        '',
        'Stack:', "$($err.ScriptStackTrace)",
        '',
        "Send this file to the developer: $ProjectUrl/issues"
    )
    $desk = Join-Path ([Environment]::GetFolderPath('Desktop')) "PC-Debloater-ERROR_$stamp.txt"
    try { if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }; $lines | Out-File -LiteralPath (Join-Path $LogDir "crash_$stamp.txt") -Encoding UTF8 } catch {}
    try { $lines | Out-File -LiteralPath $desk -Encoding UTF8 } catch {}
    return $desk
}
function Report-Error($err, [string]$where) {
    $p = Write-CrashLog $err $where
    try {
        [System.Windows.MessageBox]::Show("Something went wrong ($where):`n`n$($err.Exception.Message)`n`nAn error report was saved to your Desktop:`n$(Split-Path $p -Leaf)`n`nPlease send it to the developer so it can be fixed.", "$AppName - error", 'OK', 'Error') | Out-Null
    } catch {}
}
trap {
    Report-Error $_ 'main app'
    break
}

# ---------- 1. Ask for admin if we don't have it ----------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    if ($CheckOnly) { $argLine += ' -CheckOnly' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -ErrorAction Stop }
    catch {
        [System.Windows.MessageBox]::Show("$AppName needs admin rights to remove apps and change Windows settings.`n`nRun it again and click YES on the Windows pop-up.", $AppName, 'OK', 'Information') | Out-Null
    }
    exit
}

# hide the black console window behind the app
try {
    Add-Type -Name Win -Namespace Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);'
    [void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)
} catch {}

$IsLaptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)

# Lists that fill up while it runs (these become the log file)
$Removed = New-Object 'System.Collections.Generic.List[string]'
$Added   = New-Object 'System.Collections.Generic.List[string]'
$Failed  = New-Object 'System.Collections.Generic.List[string]'
$Notes   = New-Object 'System.Collections.Generic.List[string]'

# ---------- 2. Little helpers ----------
# Everything the app changes gets written down here, so the Reinstall / Undo button can bring it back
$History  = New-Object System.Collections.ArrayList
$Group    = ''
$RunStamp = ''
$HistFile = Join-Path $DataDir 'history.json'
function Rec([hashtable]$h) { $h['G'] = $script:Group; $h['When'] = $script:RunStamp; [void]$History.Add([pscustomobject]$h) }
function Expand-Items($x) {
    # Windows PowerShell 5.1 gives back a JSON list as ONE object - unpack it (and any list inside a list) into separate items
    foreach ($i in @($x)) {
        if ($null -eq $i) { continue }
        if ($i -is [System.Array]) { Expand-Items $i } else { $i }
    }
}
function Load-History {
    if (-not (Test-Path -LiteralPath $HistFile)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $HistFile -Raw -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return @() }
        $json = ConvertFrom-Json $raw
        return @(Expand-Items $json | Where-Object { $_.T })
    } catch { return @() }
}
function Save-History($arr) {
    $dir = Split-Path $HistFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ConvertTo-Json -InputObject @($arr) -Depth 6 | Set-Content -LiteralPath $HistFile -Encoding UTF8
}

# ---------- Quiet check mode (runs at sign-in if you turned on "Warn me when Windows puts junk back") ----------
function Get-CameBack {
    $h = @(Load-History); $back = @()
    $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageFamilyName })
    foreach ($g in @($h | Where-Object { $_.T -eq 'App' } | Group-Object G)) {
        if (@($g.Group | Where-Object { $installed -contains $_.PFN }).Count) { $back += $g.Name }
    }
    if (@($h | Where-Object { $_.T -eq 'Win32' -and $_.Name -eq 'Microsoft Edge' }).Count -and (Test-Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")) { $back += 'Microsoft Edge' }
    if (@($h | Where-Object { $_.T -eq 'Win32' -and $_.Name -eq 'OneDrive' }).Count -and (Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe")) { $back += 'OneDrive' }
    return @($back | Select-Object -Unique)
}
if ($CheckOnly) {
    $back = @(Get-CameBack)
    if ($back.Count) {
        $ans = [System.Windows.MessageBox]::Show("Heads up! Windows put back stuff you deleted:`n`n  - " + ($back -join "`n  - ") + "`n`nOpen PC Debloater to remove it again?", 'PC Debloater', 'YesNo', 'Warning')
        if ($ans -eq 'Yes') { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"" }
    }
    exit
}

function Get-RegValue([string]$Path, [string]$Name) {
    # reads a value without PowerShell treating [ ] * ? in the name as wildcards
    $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $k) { return @{ Exists = $false } }
    if (@($k.GetValueNames()) -notcontains $Name) { return @{ Exists = $false } }
    $kind = $null; try { $kind = $k.GetValueKind($Name).ToString() } catch {}
    return @{ Exists = $true; Value = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames'); Kind = $kind }
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    $o = Get-RegValue $Path $Name
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    Rec @{ T='Reg'; Path=$Path; Name=$Name; Existed=[bool]$o.Exists; Old=$o.Value; Kind=$o.Kind }
    $old = 'not set'; if ($o.Exists) { $old = $o.Value }
    $Added.Add("      $Path\$Name = $Value   (was: $old)")
}

function Disable-Svc {
    param([string]$Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return }
    $old = $s.StartType
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
    Rec @{ T='Svc'; Name=$Name; Old="$old" }
    $Added.Add("      Service '$Name' startup = Disabled   (was: $old)")
}

function Brush([string]$hex) { return ([System.Windows.Media.BrushConverter]::new()).ConvertFromString($hex) }
function Th($l, $t, $r, $b) { return [System.Windows.Thickness]::new($l, $t, $r, $b) }

$IsWin11 = [Environment]::OSVersion.Version.Build -ge 22000

# ---------- 2b. Keeping the window alive (no more "Not Responding") ----------
$PumpWin = $null
function Pump {
    # lets the window redraw + react while we work
    if ($script:PumpWin) { try { $script:PumpWin.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background) } catch {} }
}
function Invoke-Bg {
    # runs slow stuff on a background thread and keeps the window responsive while it waits
    param([scriptblock]$Code, [object[]]$ArgList = @())
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Code.ToString())
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $h = $ps.BeginInvoke()
    while (-not $h.IsCompleted) { Pump; Start-Sleep -Milliseconds 60 }
    try { $out = $ps.EndInvoke($h) }
    catch {
        $m = $_.Exception.Message
        if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
        $ps.Dispose()
        throw $m
    }
    $ps.Dispose()
    return $out
}
function Wait-Proc($p) {
    # waits for a program (uninstaller, installer...) without freezing the window
    if (-not $p) { return $null }
    $null = $p.Handle   # makes Windows keep the exit code for us
    while (-not $p.HasExited) { Pump; Start-Sleep -Milliseconds 150 }
    $p.WaitForExit()
    return $p.ExitCode
}

$StyleXml = @'
  <Window.Resources>
    <Style TargetType="TabItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="#24242C" CornerRadius="8" Padding="16,8" Margin="0,0,8,10" Cursor="Hand">
              <ContentPresenter ContentSource="Header" TextElement.Foreground="White" TextElement.FontSize="14" TextElement.FontWeight="SemiBold"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#7C5CFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#2E2E38"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollViewer">
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
    </Style>
  </Window.Resources>
'@

function Show-Dialog {
    # one good-looking pop-up used for the welcome screen, safety checks, preview and About
    param([string]$Title, [string]$Heading, [string[]]$Lines, [string[]]$Buttons = @('OK'), [string]$CheckText = $null, $Owner = $null, [string]$Accent = '#7C5CFF')
    $dx = [xml]('<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="640" SizeToContent="Height" WindowStartupLocation="CenterScreen" Background="#16161C" FontFamily="Segoe UI" ResizeMode="NoResize">' + $StyleXml + '<StackPanel x:Name="Root" Margin="22"/></Window>')
    $dw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dw.Title = $Title
    if ($Owner) { $dw.Owner = $Owner; $dw.WindowStartupLocation = 'CenterOwner' }
    $root = $dw.FindName('Root')
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Heading; $h.FontSize = 24; $h.FontWeight = [System.Windows.FontWeights]::Bold; $h.Foreground = Brush '#FFFFFF'; $h.TextWrapping = 'Wrap'; $h.Margin = Th 0 0 0 10
    [void]$root.Children.Add($h)
    $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.MaxHeight = 470; $sv.VerticalScrollBarVisibility = 'Auto'
    $body = New-Object System.Windows.Controls.StackPanel
    foreach ($ln in $Lines) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.TextWrapping = 'Wrap'; $t.FontSize = 14; $t.Foreground = Brush '#D4D4DC'; $t.Margin = Th 0 2 8 2
        if ($ln -like '## *')   { $t.Text = $ln.Substring(3); $t.FontWeight = [System.Windows.FontWeights]::SemiBold; $t.Foreground = Brush '#A78BFA'; $t.Margin = Th 0 10 0 4 }
        elseif ($ln -like '! *') { $t.Text = [string][char]0x26A0 + '  ' + $ln.Substring(2); $t.Foreground = Brush '#FBBF24' }
        elseif ($ln -like 'X *') { $t.Text = [string][char]0x2716 + '  ' + $ln.Substring(2); $t.Foreground = Brush '#F87171' }
        elseif ($ln -like '- *') { $t.Text = [string][char]0x2022 + '  ' + $ln.Substring(2) }
        else { $t.Text = $ln }
        [void]$body.Children.Add($t)
    }
    $sv.Content = $body
    [void]$root.Children.Add($sv)
    $cb = $null
    if ($CheckText) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Margin = Th 0 14 0 0
        $ct = New-Object System.Windows.Controls.TextBlock; $ct.Text = $CheckText; $ct.Foreground = Brush '#FFFFFF'; $ct.FontSize = 14
        $cb.Content = $ct
        [void]$root.Children.Add($cb)
    }
    $bar = New-Object System.Windows.Controls.WrapPanel; $bar.HorizontalAlignment = 'Right'; $bar.Margin = Th 0 16 0 0
    $script:DlgResult = $null; $script:DlgWin = $dw
    for ($i = 0; $i -lt $Buttons.Count; $i++) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $Buttons[$i]; $b.Margin = Th 8 0 0 0; $b.MinWidth = 110
        if ($i -eq $Buttons.Count - 1) { $b.Background = Brush $Accent; $b.FontWeight = [System.Windows.FontWeights]::Bold; $lastBtn = $b }
        $b.Add_Click({ $script:DlgResult = [string]$this.Content; $script:DlgWin.Close() })
        [void]$bar.Children.Add($b)
    }
    if ($cb) {
        $lastBtn.IsEnabled = $false
        $script:DlgLastBtn = $lastBtn
        $cb.Add_Checked({ $script:DlgLastBtn.IsEnabled = $true })
        $cb.Add_Unchecked({ $script:DlgLastBtn.IsEnabled = $false })
    }
    [void]$root.Children.Add($bar)
    [void]$dw.ShowDialog()
    return $script:DlgResult
}

# ---------- 2c. Welcome screen (first time only) ----------
$AcceptFile = Join-Path $DataDir 'accepted.txt'
if (-not (Test-Path -LiteralPath $AcceptFile)) {
    $ans = Show-Dialog -Title "Welcome to $AppName" -Heading "Welcome to $AppName v$AppVersion" -Buttons @('Quit', 'Continue') -CheckText 'I read this and I want to continue' -Lines @(
        '## What this app does',
        '- Removes junk apps, turns off tracking + ads, boosts games and changes the Windows settings YOU pick.',
        '- It makes a restore point (a backup of Windows) before it changes anything.',
        '- Almost everything can be undone later with the Reinstall / Undo button.',
        '## Please read',
        '! Use it at your own risk. Changing Windows can sometimes break things, even with backups.',
        '- Only tick stuff you understand. Green = safe, blue = your call, orange = be careful.',
        '- Save your work first, and keep your important files backed up somewhere.',
        '- Don''t use it on a work or school PC.',
        '## Privacy',
        '- This app does not collect, track or send ANY of your data. Everything stays on your PC.',
        '- It only goes online to check Windows Update for drivers, or to open official pages when you click a button.',
        '## The boring legal part',
        "- $AppName is free and open source (MIT license) and comes with no warranty.",
        '- It is not made by or connected to Microsoft, NVIDIA, AMD, Intel or any other company it mentions.'
    )
    if ($ans -ne 'Continue') { exit }
    try { if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }; "Accepted v$AppVersion on $(Get-Date -Format s)" | Out-File -LiteralPath $AcceptFile -Encoding UTF8 } catch {}
}

# ---------- 2d. Safety checks before we touch anything ----------
function Get-SafetyIssues {
    $out = @()
    if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        $out += 'X Your PowerShell is too old (needs 5.1). Update Windows first.'
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($os -and $os.ProductType -ne 1) { $out += 'X This is Windows Server. This app is only for normal Windows 10 / 11 PCs.' }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) { $out += "! Your Windows is old (build $build). This app is made for Windows 10 version 2004 or newer and Windows 11. Some things might not work." }
    if ($cs -and $cs.PartOfDomain) { $out += '! This PC is part of a work/school network (domain). Debloating it could break stuff your IT people need, or break their rules. Ask them first!' }
    $enrolled = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).UPN })
    if ($enrolled.Count) { $out += '! This PC looks like it is managed by a work or school account. Ask whoever manages it before debloating.' }
    if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        $out += '! Windows is waiting for a restart to finish an update. Best to restart first, then run this app.'
    }
    try {
        $free = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop).Free / 1GB
        if ($free -lt 5) { $out += ("! Your C: drive is almost full ({0:N1} GB free). The restore point (backup) might fail. Free up some space first if you can." -f $free) }
    } catch {}
    if ($PSScriptRoot -match '\\AppData\\Local\\Temp\\|\\Windows\\Temp\\') { $out += '! It looks like you are running this from inside a .zip or a Temp folder. Extract it to a normal folder (like Downloads or Desktop) first.' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $out += '! This is an ARM PC. Most things work, but some game and driver stuff may not apply.' }
    return $out
}
if (-not $CheckOnly) {
    $issues = @(Get-SafetyIssues)
    $blocking = @($issues | Where-Object { $_ -like 'X *' })
    if ($blocking.Count) {
        [void](Show-Dialog -Title $AppName -Heading "Sorry, $AppName can't run here" -Lines $issues -Buttons @('Close') -Accent '#E5484D')
        exit
    } elseif ($issues.Count) {
        $ans = Show-Dialog -Title $AppName -Heading 'Before you start...' -Lines (@('Found a few things you should know:') + $issues) -Buttons @('Quit', 'Continue anyway') -Accent '#F59E0B'
        if ($ans -ne 'Continue anyway') { exit }
    }
}

# ---------- 2e. Loading screen while we scan ----------
$Splash = $null; $SplashText = $null
if (-not $CheckOnly) {
    $sx = [xml]('<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="460" SizeToContent="Height" WindowStartupLocation="CenterScreen" Background="#16161C" FontFamily="Segoe UI" ResizeMode="NoResize" WindowStyle="ToolWindow">' +
                '<StackPanel Margin="24"><TextBlock x:Name="SName" FontSize="24" FontWeight="Bold" Foreground="White"/>' +
                '<TextBlock x:Name="SText" Text="Scanning your PC..." Foreground="#A0A0B0" FontSize="14" Margin="0,8,0,12"/>' +
                '<ProgressBar IsIndeterminate="True" Height="8" Background="#24242C" Foreground="#7C5CFF" BorderThickness="0"/></StackPanel></Window>')
    $Splash = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
    $Splash.Title = $AppName
    $Splash.FindName('SName').Text = "$AppName v$AppVersion"
    $SplashText = $Splash.FindName('SText')
    $Splash.Show()
    $PumpWin = $Splash
    Pump
}
function Splash([string]$t) { if ($script:SplashText) { $script:SplashText.Text = $t }; Pump }

# ---------- 3. The list of stuff ----------
Splash 'Checking your apps and programs...'
$Items = New-Object System.Collections.ArrayList
$CurSection = $null
$Palette = '#3B82F6','#8B5CF6','#EC4899','#F97316','#10B981','#06B6D4','#EAB308','#EF4444'

function A {  # an app to remove
    param($Pattern, $Name, $Desc, $Level = 'Safe')
    [void]$Items.Add([pscustomobject]@{ Kind='App'; Tab='Apps'; Section='Bloat apps'; Pattern=$Pattern; Name=$Name; Desc=$Desc; Level=$Level
        Color=$Palette[$Items.Count % $Palette.Count]; Glyph=$null; Action=$null; Packages=@(); Prov=@(); Icon=$null })
}
function T {  # a setting to change
    param($Tab, $Name, $Desc, $Level, [int]$Glyph, [scriptblock]$Action, $Color = '#7C5CFF')
    [void]$Items.Add([pscustomobject]@{ Kind='Tweak'; Tab=$Tab; Section=$CurSection; Pattern=$null; Name=$Name; Desc=$Desc; Level=$Level
        Color=$Color; Glyph=[string][char]$Glyph; Action=$Action; Packages=@(); Prov=@(); Icon=$null })
}

# Levels:  Safe = checked by default | Optional = you might use it | Careful = can break stuff
# ---- Microsoft junk ----
A 'Microsoft.BingNews'                      'Microsoft News'            'News app full of headlines nobody asked for'
A 'Microsoft.News'                          'Microsoft Start'           'Another news app'
A 'Microsoft.BingWeather'                   'MSN Weather'               'Weather app (your phone already does this)'
A 'Microsoft.BingSearch'                    'Bing Search'               'Shoves Bing web results into Windows'
A 'Microsoft.BingFinance'                   'MSN Money'                 'Old stocks/money app'
A 'Microsoft.BingSports'                    'MSN Sports'                'Old sports app'
A 'Microsoft.GetHelp'                       'Get Help'                  'Microsoft help app'
A 'Microsoft.Getstarted'                    'Tips'                      'Pop-up "did you know" tips'
A 'Microsoft.MicrosoftSolitaireCollection'  'Solitaire Collection'      'Card games... with ads'
A 'Microsoft.MicrosoftOfficeHub'            'Microsoft 365 hub'         'Basically an ad trying to sell you Office'
A 'Microsoft.People'                        'People'                    'Old contacts app'
A 'Microsoft.WindowsFeedbackHub'            'Feedback Hub'              'For sending feedback to Microsoft'
A 'Microsoft.WindowsMaps'                   'Maps'                      'Maps app (Google Maps is better anyway)'
A 'Microsoft.ZuneVideo'                     'Movies & TV'               'Old video player / movie store'
A 'Microsoft.PowerAutomateDesktop'          'Power Automate'            'Automation tool for office workers'
A 'Clipchamp.Clipchamp'                     'Clipchamp'                 'Microsoft video editor that pushes a subscription'
A 'MicrosoftTeams'                          'Teams (personal)'          'The free chat version of Teams'
A 'Microsoft.549981C3F5F10'                 'Cortana'                   'Old voice assistant, basically dead'
A 'Microsoft.SkypeApp'                      'Skype'                     'Skype is shut down now anyway'
A 'Microsoft.MixedReality.Portal'           'Mixed Reality Portal'      'Only for VR headsets'
A 'Microsoft.Microsoft3DViewer'             '3D Viewer'                 'Looks at 3D models. You never opened it.'
A 'Microsoft.MSPaint'                       'Paint 3D'                  'Not normal Paint - normal Paint stays'
A 'Microsoft.windowscommunicationsapps'     'Mail and Calendar (old)'   'Old mail app Microsoft retired'
A 'Microsoft.Windows.DevHome'               'Dev Home'                  'Tool for programmers, Microsoft is retiring it'
A 'Microsoft.Copilot'                       'Copilot app'               'Microsoft AI chat app'
A 'Microsoft.XboxApp'                       'Xbox Console Companion'    'OLD Xbox app (not the new one)'
A 'Microsoft.YourPhone'                     'Phone Link'                'Connects your phone to the PC'             'Optional'
A 'Microsoft.Todos'                         'Microsoft To Do'           'To-do list app'                            'Optional'
A 'MSTeams'                                 'Teams (new)'               'Keep it if school or work uses Teams'      'Optional'
A 'Microsoft.OutlookForWindows'             'Outlook (new)'             'New mail app'                              'Optional'
A 'Microsoft.WindowsAlarms'                 'Clock and Alarms'          'Timers, alarms, stopwatch'                 'Optional'
A 'Microsoft.WindowsSoundRecorder'          'Sound Recorder'            'Records audio from your mic'               'Optional'
A 'Microsoft.MicrosoftStickyNotes'          'Sticky Notes'              'Little note pads on your screen'           'Optional'
A 'Microsoft.Office.OneNote'                'OneNote'                   'Note-taking app'                           'Optional'
A 'MicrosoftCorporationII.QuickAssist'      'Quick Assist'              'Lets someone remote into your PC (scammers love it)' 'Optional'
A 'MicrosoftCorporationII.MicrosoftFamily'  'Family Safety'             'Parental controls app'                     'Optional'
A 'Microsoft.ZuneMusic'                     'Media Player'              'Plays music and videos'                    'Optional'
A 'Microsoft.WindowsCamera'                 'Camera'                    'Webcam app - keep if you use your webcam'  'Optional'
A 'Microsoft.XboxSpeechToTextOverlay'       'Xbox Speech to Text'       'Voice-to-text in Xbox party chat'          'Optional'
A 'Microsoft.XboxGamingOverlay'             'Xbox Game Bar'             'The Win+G thing. Records clips and shows FPS' 'Careful'
A 'Microsoft.GamingApp'                     'Xbox app'                  'Minecraft launcher and Game Pass games NEED this' 'Careful'
A 'Microsoft.Xbox.TCUI'                     'Xbox TCUI'                 'Xbox sign-in popups inside games (Minecraft uses it)' 'Careful'
# ---- Junk that came pre-installed from other companies ----
A '*CandyCrush*'                            'Candy Crush'               'Came pre-installed. You did not ask for this.'
A '*BubbleWitch*'                           'Bubble Witch'              'Pre-installed game'
A '*MarchofEmpires*'                        'March of Empires'          'Pre-installed game'
A '*HiddenCity*'                            'Hidden City'               'Pre-installed game'
A '*Disney*'                                'Disney+'                   'Pre-installed shortcut app'
A '*Facebook*'                              'Facebook'                  'Pre-installed app'
A '*TikTok*'                                'TikTok'                    'Pre-installed app'
A '*PrimeVideo*'                            'Prime Video'               'Pre-installed app'
A '*LinkedIn*'                              'LinkedIn'                  'Pre-installed app'
A '*Twitter*'                               'X / Twitter'               'Pre-installed app'
A '*Instagram*'                             'Instagram'                 'Pre-installed app'                         'Optional'
A '*Netflix*'                               'Netflix'                   'Keep it if you actually watch on PC'       'Optional'
# ---- even more junk ----
A 'MicrosoftWindows.Client.WebExperience'   'Widgets board'             'The news/weather panel app itself'
A 'Microsoft.BingTranslator'                'Translator'                'Old Bing translate app'
A 'Microsoft.BingFoodAndDrink'              'MSN Food and Drink'        'Old recipe app'
A 'Microsoft.BingHealthAndFitness'          'MSN Health and Fitness'    'Old fitness app'
A 'Microsoft.BingTravel'                    'MSN Travel'                'Old travel app'
A 'Microsoft.Messaging'                     'Messaging'                 'Old SMS app that does nothing on PC'
A 'Microsoft.OneConnect'                    'Mobile Plans'              'Sells you phone data plans'
A 'Microsoft.Print3D'                       'Print 3D'                  'For 3D printers. You do not have one.'
A 'Microsoft.Wallet'                        'Wallet'                    'Old payment app nobody used'
A 'Microsoft.MicrosoftPowerBIForWindows'    'Power BI'                  'Business charts app'
A 'Microsoft.NetworkSpeedTest'              'Network Speed Test'        'Old speed test app'
A 'Microsoft.Office.Sway'                   'Sway'                      'Office presentation thing'
A 'Microsoft.MicrosoftJournal'              'Journal'                   'Pen note-taking app'
A 'Microsoft.MicrosoftLoop'                 'Loop'                      'Office collab app'
A 'Microsoft.Edge.GameAssist'               'Edge Game Assist'          'Edge browser overlay in games'
A 'Microsoft.StartExperiencesApp'           'Start Experiences'         'Puts ads/suggestions in the Start menu'
A 'Microsoft.Whiteboard'                    'Whiteboard'                'Drawing board app'                         'Optional'
A 'Microsoft.RemoteDesktop'                 'Remote Desktop app'        'Control another PC remotely'               'Optional'
A 'MicrosoftWindows.CrossDevice'            'Cross Device'              'Phone-to-PC stuff (Phone Link uses it)'    'Optional'
A 'Microsoft.ScreenSketch'                  'Snipping Tool'             'Win+Shift+S screenshots. Most people KEEP this' 'Optional'
A 'Microsoft.Windows.Photos'                'Photos'                    'Default picture viewer. Keep unless you use another' 'Careful'
A '*AdobePhotoshopExpress*'                 'Photoshop Express'         'Pre-installed app'
A '*Duolingo*'                              'Duolingo'                  'Pre-installed app'
A '*PandoraMediaInc*'                       'Pandora'                   'Pre-installed app'
A '*Shazam*'                                'Shazam'                    'Pre-installed app'
A '*Flipboard*'                             'Flipboard'                 'Pre-installed app'
A '*EclipseManager*'                        'Eclipse Manager'           'Pre-installed app'
A '*ActiproSoftware*'                       'Actipro'                   'Pre-installed junk'
A '*Asphalt8*'                              'Asphalt 8'                 'Pre-installed game'
A '*FarmVille*'                             'FarmVille'                 'Pre-installed game'
A '*RoyalRevolt*'                           'Royal Revolt'              'Pre-installed game'
A '*SimCity*'                               'SimCity BuildIt'           'Pre-installed game'
A '*SlingTV*'                                 'Sling TV'                  'Pre-installed app'
A 'XINGAG.XING'                                  'XING'                      'Pre-installed app'
A '*Viber*'                                 'Viber'                     'Pre-installed app'
A '*AutodeskSketchBook*'                    'SketchBook'                'Pre-installed app'
A '*DrawboardPDF*'                          'Drawboard PDF'             'Pre-installed app'
A '*CyberLinkMediaSuite*'                   'CyberLink Media Suite'     'Pre-installed trial'
A '*Fitbit*'                                'Fitbit'                    'Pre-installed app'
A '*iHeartRadio*'                           'iHeartRadio'               'Pre-installed app'
A '*ESPN*'                                  'ESPN'                      'Pre-installed app'
A 'Amazon.com.Amazon'                       'Amazon'                    'Pre-installed shopping app'
A '*Booking.com*'                               'Booking.com'               'Pre-installed app'
A '*McAfee*'                                'McAfee (store app)'        'Trial antivirus nag app. Windows Defender is free and good'
A '*Hulu*'                                  'Hulu'                      'Pre-installed app'                         'Optional'
A '*.Plex'                                  'Plex'                      'Pre-installed app'                         'Optional'
A '*Picsart*'                               'Picsart'                   'Pre-installed app'                         'Optional'
A '*WhatsApp*'                              'WhatsApp'                  'Keep it if you use it'                     'Optional'
A '*FACEBOOK.317180B0BB486*'                'Messenger'                 'Keep it if you use it'                     'Optional'
A '*DolbyAccess*'                           'Dolby Access'              'Dolby sound app - keep if you use Dolby Atmos' 'Optional'

# ---- OneDrive (normal program, not a store app) ----
$odExe = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe") |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($odExe) {
    [void]$Items.Add([pscustomobject]@{ Kind='Win32'; Tab='Apps'; Section='Programs + trial junk'; Pattern=$null; Name='OneDrive'
        Desc='Cloud sync that nags you. Files already online stay online. Make sure stuff is synced first!'
        Level='Careful'; Color='#0EA5E9'; Glyph=[string][char]0xE753; Packages=@(); Prov=@(); Icon=$null; Exe=$odExe
        Action={
            Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $u = $null
            foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe') {
                $v = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).UninstallString
                if ($v) { $u = $v; break }
            }
            if ($u -and $u -match '^"?([^"]+?\.exe)"?\s*(.*)$') {
                $exe = $matches[1]; $rest = $matches[2]
                if ($rest -notmatch 'uninstall') { $rest = "$rest /uninstall" }
                [void](Wait-Proc (Start-Process -FilePath $exe -ArgumentList $rest -PassThru))
            } else {
                $setup = @("$env:SystemRoot\System32\OneDriveSetup.exe","$env:SystemRoot\SysWOW64\OneDriveSetup.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
                if (-not $setup) { throw "Couldn't find the OneDrive uninstaller" }
                [void](Wait-Proc (Start-Process -FilePath $setup -ArgumentList '/uninstall' -PassThru))
            }
        } })
}


# ---- Microsoft Edge ----
$EdgeDir = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application"
if (Test-Path -LiteralPath "$EdgeDir\msedge.exe") {
    $otherBrowsers = @()
    foreach ($bk in 'HKLM:\SOFTWARE\Clients\StartMenuInternet','HKCU:\SOFTWARE\Clients\StartMenuInternet') {
        $otherBrowsers += @(Get-ChildItem -LiteralPath $bk -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName } | Where-Object { $_ -notmatch 'Edge|IEXPLORE' })
    }
    $otherBrowsers = @($otherBrowsers | Select-Object -Unique)
    if ($otherBrowsers.Count) { $edgeDesc = "Removes Edge for good. You have another browser ($($otherBrowsers[0])) so you're good. Microsoft blocks this on some PCs." }
    else { $edgeDesc = 'WARNING: you have NO other browser! Install Chrome, Firefox, Brave or Opera FIRST or you cannot get on the internet.' }
    [void]$Items.Add([pscustomobject]@{ Kind='Win32'; Tab='Apps'; Section='Programs + trial junk'; Pattern=$null; Name='Microsoft Edge'
        Desc=$edgeDesc; Level='Careful'; Color='#0EA5E9'; Glyph=$null; Packages=@(); Prov=@(); Icon=$null; Exe="$EdgeDir\msedge.exe"
        Action={
            Get-Process -Name msedge, MicrosoftEdgeUpdate -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $setup = Get-ChildItem -Path "$EdgeDir\*\Installer\setup.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $setup) { throw "Couldn't find Edge's uninstaller" }
            # tell Edge it's allowed to be uninstalled
            Set-Reg 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev' 'AllowUninstall' 1
            # old trick: a fake "legacy Edge" file makes the uninstaller stop refusing
            $stub = "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
            $made = $false; $madeDir = -not (Test-Path -LiteralPath $stub)
            try {
                if (-not (Test-Path -LiteralPath "$stub\MicrosoftEdge.exe")) {
                    New-Item -ItemType Directory -Path $stub -Force -ErrorAction Stop | Out-Null
                    New-Item -ItemType File -Path "$stub\MicrosoftEdge.exe" -Force -ErrorAction Stop | Out-Null
                    $made = $true
                }
            } catch {}
            [void](Wait-Proc (Start-Process -FilePath $setup.FullName -ArgumentList '--uninstall --msedge --channel=stable --system-level --verbose-logging --force-uninstall' -PassThru))
            if ($made) { Remove-Item -LiteralPath "$stub\MicrosoftEdge.exe" -Force -ErrorAction SilentlyContinue }
            if ($madeDir) { Remove-Item -LiteralPath $stub -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 3
            if (Test-Path -LiteralPath "$EdgeDir\msedge.exe") { throw 'Microsoft blocked the uninstall on this PC. Edge is still there and nothing broke. Use the "Debloat Microsoft Edge" option in Privacy instead.' }
            # stop it coming back with Windows Update
            Set-Reg 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' 1
            Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 0
            Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            foreach ($lnk in "$env:PUBLIC\Desktop\Microsoft Edge.lnk", "$([Environment]::GetFolderPath('Desktop'))\Microsoft Edge.lnk", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk") {
                Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
            }
            $Added.Add('      (Edge WebView2 was KEPT on purpose - Discord, Widgets, launchers and lots of apps need it to work)')
        } })
}

# ---- Normal programs (trials and junk) ----
$UninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
$AllPrograms = @(Get-ItemProperty -Path $UninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.UninstallString -and -not $_.SystemComponent })
function W {
    param($Regex, $Name, $Desc, $Level = 'Safe', $Url = $null)
    $hits = @($AllPrograms | Where-Object { $_.DisplayName -match $Regex })
    if (-not $hits.Count) { return }
    $exe = $null
    foreach ($h in $hits) { if ($h.DisplayIcon) { $c = ($h.DisplayIcon -split ',')[0].Trim('"'); if (Test-Path -LiteralPath $c -ErrorAction SilentlyContinue) { $exe = $c; break } } }
    [void]$Items.Add([pscustomobject]@{ Kind='Uninstall'; Tab='Apps'; Section='Programs + trial junk'; Pattern=$null; Name=$Name; Desc=$Desc; Level=$Level
        Color='#F97316'; Glyph=$null; Action=$null; Packages=@(); Prov=@(); Icon=$null; Exe=$exe; Entries=$hits; Url=$Url })
}
W '^McAfee'                                 'McAfee'                    'Trial antivirus that nags you to pay. Its uninstaller will pop up - click through it' -Url 'https://www.mcafee.com'
W '^WildTangent'                            'WildTangent Games'         'Pre-installed game ads'
W '^(Dropbox (Promotion|Offer)|Dropbox 25 GB)' 'Dropbox promotion'      'Pre-installed Dropbox ad' -Url 'https://www.dropbox.com/install'
W '^Booking\.com'                           'Booking.com (program)'     'Pre-installed shortcut program' -Url 'https://www.booking.com'
W '^Norton'                                 'Norton'                    'Trial antivirus. Keep if you PAID for it' 'Optional' -Url 'https://us.norton.com'
W '^ExpressVPN'                             'ExpressVPN'                'Pre-installed VPN trial. Keep if you pay for it' 'Optional' -Url 'https://www.expressvpn.com/vpn-download'
W '^Microsoft 365 - |^Microsoft OneNote - ' 'Microsoft 365 / Office (pre-installed)' 'The Office trial. Keep it if you use Word/Excel/PowerPoint' 'Optional' -Url 'https://www.office.com'

# ---- Startup apps (stop them opening when your PC turns on) ----
$StartupSources = @(
    @{ Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Appr='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Key='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Appr='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Key='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Appr='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' })
$StartupList = @()
foreach ($src in $StartupSources) {
    $k = Get-Item -LiteralPath $src.Key -ErrorAction SilentlyContinue
    if (-not $k) { continue }
    foreach ($vn in $k.GetValueNames()) { if ($vn) { $StartupList += [pscustomobject]@{ Name=$vn; Cmd=[string]$k.GetValue($vn); Appr=$src.Appr } } }
}
foreach ($fo in @(@{ Dir="$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"; Appr='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
                 @{ Dir="$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"; Appr='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' })) {
    foreach ($f in @(Get-ChildItem -LiteralPath $fo.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
        $StartupList += [pscustomobject]@{ Name=$f.Name; Cmd=$f.FullName; Appr=$fo.Appr }
    }
}
foreach ($st in $StartupList) {
    if ($st.Name -match 'SecurityHealth|Windows Defender') { continue }   # never touch Windows Security
    $a = (Get-ItemProperty -LiteralPath $st.Appr -Name $st.Name -ErrorAction SilentlyContinue).($st.Name)
    if ($a -and ($a[0] % 2 -eq 1)) { continue }                            # already turned off
    $exe = $null
    $expanded = [Environment]::ExpandEnvironmentVariables($st.Cmd)
    if ($expanded -match '^"([^"]+)"') { $exe = $matches[1] } elseif ($expanded -match '^(.+?\.(exe|lnk))') { $exe = $matches[1] }
    $lvl = 'Optional'
    if ($st.Name + ' ' + $st.Cmd -match 'Realtek|Audio|NVIDIA|AMD|Radeon|Intel|Synaptics|ELAN|Logitech|Razer|Corsair|SteelSeries|HyperX|Dolby|Nahimic|Bluetooth') { $lvl = 'Careful' }
    $shown = [IO.Path]::GetFileNameWithoutExtension($st.Name); if (-not $shown) { $shown = $st.Name }
    $d = $st.Cmd; if ($d.Length -gt 90) { $d = $d.Substring(0, 87) + '...' }
    if ($lvl -eq 'Careful') { $d = "Driver/device helper - keep unless you know. $d" }
    [void]$Items.Add([pscustomobject]@{ Kind='Startup'; Tab='Apps'; Section='Startup apps (stop them opening when your PC turns on)'; Pattern=$null
        Name=$shown; Desc=$d; Level=$lvl; Color='#8B5CF6'; Glyph=$null; Action=$null; Packages=@(); Prov=@(); Icon=$null; Exe=$exe; Startup=$st })
}

# ---- Privacy & ads settings ----
$TabNamePrivacy = 'Privacy & Ads'
T $TabNamePrivacy 'Turn off telemetry (spying)' 'Stops Windows sending usage data to Microsoft all day' 'Safe' 0xE9D9 {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Disable-Svc 'DiagTrack'
    Disable-Svc 'dmwappushservice'
}
T $TabNamePrivacy 'Turn off advertising ID' 'Stops apps tracking you to show "personal" ads' 'Safe' 0xE8EC {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
}
T $TabNamePrivacy 'No Start menu ads + no sneaky app installs' 'Stops Windows secretly installing Candy Crush and friends again' 'Safe' 0xE80F {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','PreInstalledAppsEverEnabled','SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') {
        Set-Reg $cdm $n 0
    }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
}
T $TabNamePrivacy 'No lock screen ads and tips' 'Removes the "fun facts" and ads on your lock screen' 'Safe' 0xE72E {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-Reg $cdm 'RotatingLockScreenOverlayEnabled' 0
    Set-Reg $cdm 'SubscribedContent-338387Enabled' 0
}
T $TabNamePrivacy 'No Bing in Start search' 'Start menu search only searches YOUR PC (way faster)' 'Safe' 0xE721 {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
}
T $TabNamePrivacy 'Turn off Copilot' 'Hides the Copilot AI button and stops it running' 'Safe' 0xE99A {
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
}
T $TabNamePrivacy 'Turn off Recall (AI screenshots)' 'Stops Windows taking snapshots of your screen' 'Safe' 0xE890 {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0
    if ((Disable-WinFeature 'Recall') -eq 'removed') { Rec @{ T='Feature'; Name='Recall' }; $Added.Add('      Windows feature "Recall" = removed   (was: installed)') }
}
T $TabNamePrivacy 'Turn off Widgets / news feed' 'Removes the news and weather panel on the taskbar' 'Safe' 0xE8A9 {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
}
T $TabNamePrivacy 'Turn off activity history' 'Stops Windows keeping a timeline of what you do' 'Safe' 0xE81C {
    $s = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    Set-Reg $s 'EnableActivityFeed' 0
    Set-Reg $s 'PublishUserActivities' 0
    Set-Reg $s 'UploadUserActivities' 0
}
T $TabNamePrivacy 'No "tailored" stuff and feedback nags' 'Stops "How likely are you to recommend Windows?" pop-ups' 'Safe' 0xE8F2 {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
}
T $TabNamePrivacy 'Turn off telemetry scheduled tasks' 'Kills the hidden timers that collect + send data in the background' 'Safe' 0xE823 {
    foreach ($t in @('\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser','\Microsoft\Windows\Application Experience\ProgramDataUpdater',
                     '\Microsoft\Windows\Application Experience\MareBackup','\Microsoft\Windows\Application Experience\StartupAppTask',
                     '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator','\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
                     '\Microsoft\Windows\Autochk\Proxy','\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
                     '\Microsoft\Windows\Feedback\Siuf\DmClient','\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
                     '\Microsoft\Windows\Windows Error Reporting\QueueReporting','\Microsoft\Windows\Maps\MapsUpdateTask','\Microsoft\Windows\Maps\MapsToastTask')) {
        $path = (Split-Path $t -Parent) + '\'; $name = Split-Path $t -Leaf
        $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
        if (-not $task) { continue }
        $old = $task.State
        if ($old -ne 'Disabled') { Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue | Out-Null; Rec @{ T='Task'; Path=$path; Name=$name } }
        $Added.Add("      Task $t = Disabled   (was: $old)")
    }
}
T $TabNamePrivacy 'Turn off error reporting + "improvement program"' 'Stops crash reports and usage reports going to Microsoft' 'Safe' 0xE7BA {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\AppCompat' 'AITEnable' 0
    Disable-Svc 'WerSvc'
}
T $TabNamePrivacy 'Stop sending your typing + handwriting' 'Windows stops collecting what you type to "improve" stuff' 'Safe' 0xE765 {
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
    Set-Reg 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
    Set-Reg 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
}
T $TabNamePrivacy 'No ads in File Explorer + Settings' 'Removes OneDrive/Microsoft 365 ads and the "finish setting up" nags' 'Safe' 0xE8B7 {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
    Set-Reg $cdm 'SubscribedContent-310093Enabled' 0
    Set-Reg $cdm 'SubscribedContent-338393Enabled' 0
    Set-Reg $cdm 'SubscribedContent-353698Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' 'Enabled' 0
}
T $TabNamePrivacy 'Stop tracking which apps you open' 'Windows stops logging your app use for "most used"' 'Safe' 0xE81C {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\EdgeUI' 'DisableMFUTracking' 1
}
T $TabNamePrivacy 'Debloat Microsoft Edge' 'Edge stops running in the background + no shopping/Copilot/ads. Edge may say "managed by your organization" - normal' 'Safe' 0xE774 {
    $e = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $e 'StartupBoostEnabled' 0
    Set-Reg $e 'BackgroundModeEnabled' 0
    Set-Reg $e 'HubsSidebarEnabled' 0
    Set-Reg $e 'EdgeShoppingAssistantEnabled' 0
    Set-Reg $e 'ShowRecommendationsEnabled' 0
    Set-Reg $e 'PersonalizationReportingEnabled' 0
    Set-Reg $e 'DiagnosticData' 0
    Set-Reg $e 'SpotlightExperiencesAndRecommendationsEnabled' 0
    Set-Reg $e 'NewTabPageContentEnabled' 0
    Set-Reg $e 'NewTabPageHideDefaultTopSites' 1
    Set-Reg $e 'EdgeCollectionsEnabled' 0
    Set-Reg $e 'ShowMicrosoftRewards' 0
}
T $TabNamePrivacy 'Turn off location tracking' 'Apps can not see where you are. Weather/maps need you to type a city' 'Optional' 0xE81D {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1
}
T $TabNamePrivacy 'Turn off Find My Device' 'Microsoft stops tracking where your laptop is' 'Optional' 0xE81D {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' 'AllowFindMyDevice' 0
}

# ---- FPS BOOSTER: find your games ----
Splash 'Looking for your games...'
$TabNameFps = 'FPS Booster'
$Tips = New-Object 'System.Collections.Generic.List[string]'

function Get-SteamLibs {
    $libs = @()
    $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $sp) { $sp = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath }
    if ($sp) {
        $sp = $sp -replace '/', '\'
        $libs += $sp
        $vdf = Join-Path $sp 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in (Select-String -LiteralPath $vdf -Pattern '"path"\s+"([^"]+)"')) { $libs += ($m.Matches[0].Groups[1].Value -replace '\\\\', '\') }
        }
    }
    return @($libs | Select-Object -Unique)
}
$SteamLibs = Get-SteamLibs
$EpicGames = @()
foreach ($f in (Get-ChildItem 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item' -ErrorAction SilentlyContinue)) {
    try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; $EpicGames += [pscustomobject]@{ Name = $j.DisplayName; Loc = $j.InstallLocation } } catch {}
}

function Find-Game {
    param([string]$Name, [string[]]$Folders = @(), [string]$Epic = $null, [string[]]$Roots = @(), [string[]]$Exes, [string]$Tip, [int]$Depth = 6,
          [string[]]$ExtraExes = @(), [string[]]$Aumids = @(), [string]$Desc = 'Forces your best graphics card + high CPU priority for this game')
    $search = @()
    foreach ($lib in $SteamLibs) { foreach ($fo in $Folders) { $search += (Join-Path $lib "steamapps\common\$fo") } }
    foreach ($fo in $Folders) { $search += "$env:ProgramFiles\Epic Games\$fo" }
    if ($Epic) { $search += @($EpicGames | Where-Object { $_.Name -like $Epic } | ForEach-Object { $_.Loc }) }
    foreach ($r in $Roots) { $search += @(Resolve-Path -Path $r -ErrorAction SilentlyContinue | ForEach-Object { $_.ProviderPath }) }
    $found = @()
    Pump
    foreach ($s in ($search | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $s)) { continue }
        foreach ($e in $Exes) {
            $found += @(Get-ChildItem -LiteralPath $s -Filter $e -Recurse -Depth $Depth -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
    }
    $found = @(@($found) + @($ExtraExes | Where-Object { $_ }) | Select-Object -Unique)
    if ($found.Count -eq 0 -and $Aumids.Count -eq 0) { return }
    $first = $null; if ($found.Count) { $first = $found[0] }
    [void]$Items.Add([pscustomobject]@{ Kind='Game'; Tab=$TabNameFps; Section='Your games (found on this PC)'; Pattern=$null; Name=$Name
        Desc=$Desc; Level='Safe'; Color='#EF4444'
        Glyph=[string][char]0xE7FC; Action=$null; Packages=@(); Prov=@(); Icon=$null; Exe=$first; Exes=$found; Aumids=$Aumids; Tip=$Tip })
}

Find-Game 'Counter-Strike 2' -Folders 'Counter-Strike Global Offensive' -Exes 'cs2.exe' `
    -Tip 'CS2: In video settings turn NVIDIA Reflex to "On + Boost", turn off V-Sync. Steam > CS2 > Properties > Launch options: -novid +fps_max 0'
Find-Game 'Fortnite' -Folders 'Fortnite' -Epic 'Fortnite' -Exes 'FortniteClient-Win64-Shipping.exe' `
    -Tip 'Fortnite: Settings > Video > Rendering Mode = "Performance - Lower Graphical Fidelity". V-Sync off. Frame limit = your monitor Hz.'
# Minecraft Bedrock: old Store version (UWP) + new version that installs to X:\XboxGames
$bedExes = @(); $bedIds = @()
foreach ($p in @(Get-AppxPackage -AllUsers -Name 'Microsoft.MinecraftUWP' -ErrorAction SilentlyContinue)) {
    $bedIds += "$($p.PackageFamilyName)!App"
    if ($p.InstallLocation) { $bedExes += (Join-Path $p.InstallLocation 'Minecraft.Windows.exe') }
}
foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    $x = Join-Path $d.Root 'XboxGames\Minecraft for Windows\Content\Minecraft.Windows.exe'
    if (Test-Path -LiteralPath $x -ErrorAction SilentlyContinue) { $bedExes += $x }
}
$javaRoots = @("$env:LOCALAPPDATA\Packages\Microsoft.4297127D64EC6_*\LocalCache\Local\runtime",
    "${env:ProgramFiles(x86)}\Minecraft Launcher\runtime", "$env:APPDATA\.minecraft\runtime", "$env:USERPROFILE\.lunarclient\jre")
$javaFound = @(); foreach ($r in $javaRoots) { foreach ($rp in @(Resolve-Path -Path $r -ErrorAction SilentlyContinue)) {
    $javaFound += @(Get-ChildItem -LiteralPath $rp.ProviderPath -Filter 'javaw.exe' -Recurse -Depth 7 -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) } }
$mcHas = @(); if ($javaFound.Count) { $mcHas += 'Java' }; if ($bedExes.Count -or $bedIds.Count) { $mcHas += 'Bedrock' }
if ($mcHas.Count) {
    Find-Game 'Minecraft (Java + Bedrock)' -Exes @() -ExtraExes (@($bedExes) + @($javaFound)) -Aumids $bedIds `
        -Desc ("Boosts both versions - found on your PC: " + ($mcHas -join ' + ')) `
        -Tip 'Minecraft Java: use Sodium (Fabric) or your client''s FPS settings, render distance 8-12, clouds off, give it 4-6 GB RAM (more than 8 can make it WORSE). Minecraft Bedrock: render distance 8-12, Fancy Graphics off, Beautiful Skies off, V-Sync off, turn on "Ray tracing" ONLY if you have an RTX card and want looks over FPS.'
}
Find-Game 'Dead by Daylight' -Folders 'Dead by Daylight' -Epic '*Dead by Daylight*' -Exes 'DeadByDaylight-Win64-Shipping.exe' `
    -Tip 'Dead by Daylight: Graphics quality Low/Medium, resolution 100%, frame rate cap 120. Turn off motion blur if it shows up.'
Find-Game 'Valorant' -Roots 'C:\Riot Games\VALORANT' -Exes 'VALORANT-Win64-Shipping.exe' `
    -Tip 'Valorant: Multithreaded rendering ON, Vignette OFF, V-Sync OFF, NVIDIA Reflex "On + Boost".'
Find-Game 'Apex Legends' -Folders 'Apex Legends' -Epic '*Apex*' -Roots "$env:ProgramFiles\EA Games\Apex" -Exes 'r5apex.exe','r5apex_dx12.exe' `
    -Tip 'Apex: Adaptive resolution FPS target 0, V-Sync off, texture budget lower if you have under 8 GB VRAM.'
Find-Game 'Roblox' -Depth 2 -Roots "$env:LOCALAPPDATA\Roblox\Versions","$env:LOCALAPPDATA\Bloxstrap\Versions" -Exes 'RobloxPlayerBeta.exe' `
    -Tip 'Roblox: Roblox updates move its folder, so run this booster again after big updates. Lower Graphics Quality in the in-game menu.'
Find-Game 'Rocket League' -Folders 'rocketleague' -Epic '*Rocket League*' -Exes 'RocketLeague.exe' `
    -Tip 'Rocket League: Uncapped FPS (or your Hz), V-Sync off, "Weather effects" and "Dynamic shadows" off.'
Find-Game 'Overwatch 2' -Folders 'Overwatch' -Roots "${env:ProgramFiles(x86)}\Overwatch" -Exes 'Overwatch.exe' `
    -Tip 'Overwatch 2: NVIDIA Reflex On + Boost, V-Sync off, Triple buffering off, Dynamic reflections off.'
Find-Game 'GTA V' -Folders 'Grand Theft Auto V','Grand Theft Auto V Enhanced' -Epic '*Grand Theft Auto V*' -Exes 'GTA5.exe','GTA5_Enhanced.exe' `
    -Tip 'GTA V: MSAA off (use FXAA), grass quality Normal, extended distance scaling low.'
Find-Game 'Rust' -Folders 'Rust' -Exes 'RustClient.exe' -Tip 'Rust: Graphics quality 2-3, grass displacement off, shadows low.'
Find-Game 'Marvel Rivals' -Folders 'MarvelRivals' -Exes 'Marvel-Win64-Shipping.exe' -Tip 'Marvel Rivals: Use DLSS/FSR on Performance, global illumination off, V-Sync off.'
Find-Game 'Rainbow Six Siege' -Folders "Tom Clancy's Rainbow Six Siege" -Exes 'RainbowSix.exe','RainbowSix_Vulkan.exe' -Tip 'R6 Siege: Vulkan version often gets more FPS on AMD. Reflex On + Boost.'

# ---- FPS BOOSTER: Windows tweaks for gaming ----
$CurSection = 'Boost Windows for gaming'
T $TabNameFps 'Turn on Game Mode' 'Windows focuses your PC on the game you are playing' 'Safe' 0xE7FC {
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
} '#EF4444'
T $TabNameFps 'Give games more CPU + GPU priority' 'Tells Windows games come first, background stuff second' 'Safe' 0xE9D9 {
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-Reg $mm 'SystemResponsiveness' 10
    Set-Reg "$mm\Tasks\Games" 'GPU Priority' 8
    Set-Reg "$mm\Tasks\Games" 'Priority' 6
    Set-Reg "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'
    Set-Reg "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String'
} '#EF4444'
T $TabNameFps 'Clean junk + temp files' 'Deletes leftover temp files. Frees up space, nothing important' 'Safe' 0xE74D $null '#EF4444'
$Items[$Items.Count - 1].Kind = 'Clean'
T $TabNameFps 'Turn off mouse acceleration' 'Mouse moves the same every time (better aim in games)' 'Optional' 0xE962 {
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
} '#EF4444'
T $TabNameFps 'Stop the Sticky Keys pop-up' 'No more pop-up when you spam Shift in a game' 'Optional' 0xE765 {
    Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
} '#EF4444'
T $TabNameFps 'Turn off background game recording' 'Can give a few more FPS. Game Bar clips stop working' 'Optional' 0xE714 {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
} '#EF4444'
T $TabNameFps 'Hardware GPU scheduling' 'Lets your graphics card manage its own memory. Needs a restart' 'Optional' 0xE7F4 {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
} '#EF4444'
T $TabNameFps 'Optimizations for windowed games' 'Lower input lag in borderless/windowed mode' 'Optional' 0xE737 {
    $k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $old = (Get-ItemProperty -LiteralPath $k -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
    if (-not $old) { $old = '' }
    $new = ($old -replace 'SwapEffectUpgradeEnable=\d;', '') + 'SwapEffectUpgradeEnable=1;'
    Set-Reg $k 'DirectXUserGlobalSettings' $new 'String'
} '#EF4444'
T $TabNameFps 'Stop internet throttling' 'Windows stops slowing your network while games run' 'Optional' 0xE774 {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' -1
} '#EF4444'
T $TabNameFps 'Ultimate Performance power plan' 'Max speed mode. Eats laptop battery faster' 'Optional' 0xE945 {
    $before = ((powercfg /getactivescheme) -join ' ').Trim()
    if ($before -match '([0-9a-fA-F\-]{36})') { Rec @{ T='Power'; Old=$matches[1] } }
    $list = (powercfg /list) -join "`n"
    $guid = $null
    if ($list -match '([0-9a-fA-F\-]{36})\s+\(Ultimate Performance\)') { $guid = $matches[1] }
    else {
        $out = (powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61) -join ' '
        if ($out -match '([0-9a-fA-F\-]{36})') { $guid = $matches[1] } else { throw "Couldn't add the power plan: $out" }
    }
    powercfg /setactive $guid | Out-Null
    $Added.Add("      Power plan 'Ultimate Performance' turned on   (was: $before)")
} '#EF4444'
T $TabNameFps 'Turn off power throttling' 'Stops Windows slowing your CPU to save power (laptops: more heat)' 'Optional' 0xE83F {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
} '#EF4444'
T $TabNameFps 'Visual effects: best performance' 'Turns off fancy animations and see-through windows' 'Optional' 0xE790 {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
} '#EF4444'
T $TabNameFps 'Stop apps running in the background' 'Store apps (like Phone Link) stop running when closed' 'Optional' 0xE769 {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2
} '#EF4444'

# ---- Wi-Fi & Internet ----
Splash 'Checking your Wi-Fi and network cards...'
$TabNameNet = 'Wi-Fi & Ethernet'
$CurSection = 'Works for both Wi-Fi and cable'
$WifiAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11' })
$EthAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { ($_.NdisPhysicalMedium -eq 14 -or $_.InterfaceDescription -match 'Ethernet|GbE|Gigabit|2\.5G|PCIe FE|Killer E') -and $_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless|WLAN|802\.11|Bluetooth' })
$NetUp = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })

function Set-AdapterProp {
    param($Adapter, [string]$NamePattern, [string[]]$ValuePatterns)
    $hit = $false
    foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $Adapter.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $NamePattern })) {
        $target = $null
        foreach ($vp in $ValuePatterns) { $target = @($p.ValidDisplayValues | Where-Object { $_ -match $vp }) | Select-Object -First 1; if ($target) { break } }
        if (-not $target) { continue }
        $hit = $true
        if ($p.DisplayValue -eq $target) { $Added.Add("      $($Adapter.Name): '$($p.DisplayName)' was already '$target'"); continue }
        $old = $p.DisplayValue
        Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName $p.DisplayName -DisplayValue $target -ErrorAction Stop
        Rec @{ T='AdapterProp'; Adapter=$Adapter.Name; Prop=$p.DisplayName; Old=$old }
        $Added.Add("      $($Adapter.Name): '$($p.DisplayName)' = $target   (was: $old)")
    }
    if (-not $hit) { $Added.Add("      $($Adapter.Name): your network card doesn't have '$NamePattern', skipped (that's fine)") }
}

T $TabNameNet 'Stop Windows using your internet to share updates' 'Windows uploads updates to strangers using YOUR internet. This stops it' 'Safe' 0xE896 {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
} '#06B6D4'
T $TabNameNet 'Refresh network settings' 'Clears old saved internet addresses + fixes a common speed setting' 'Safe' 0xE895 {
    ipconfig /flushdns | Out-Null
    $Added.Add('      Cleared the DNS cache (saved website addresses)')
    $old = (netsh int tcp show global) -match 'Auto-Tuning' | Select-Object -First 1
    netsh int tcp set global autotuninglevel=normal | Out-Null
    $was = 'unknown'; if ($old) { $was = ($old -split ':')[-1].Trim() }
    if ($was -match '^[a-z]+$') { Rec @{ T='Autotune'; Old=$was } }
    $Added.Add("      TCP auto-tuning = normal   (was: $was)")
} '#06B6D4'
T $TabNameNet 'Faster DNS (Cloudflare 1.1.1.1)' 'Websites and game servers get found faster. Does not raise download speed' 'Optional' 0xE774 {
    foreach ($ad in $NetUp) {
        $old = (Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ', '
        if (-not $old) { $old = 'automatic' }
        Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses '1.1.1.1','1.0.0.1' -ErrorAction Stop
        Rec @{ T='Dns'; Index=$ad.ifIndex; Name=$ad.Name }
        $Added.Add("      $($ad.Name): DNS = 1.1.1.1, 1.0.0.1   (was: $old)")
    }
} '#06B6D4'
T $TabNameNet 'Lower ping in games' 'Sends small game packets right away instead of bunching them up (Wi-Fi and cable)' 'Optional' 0xE7FC {
    foreach ($ad in $NetUp) {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($ad.InterfaceGuid)"
        Set-Reg $k 'TcpAckFrequency' 1
        Set-Reg $k 'TCPNoDelay' 1
    }
} '#06B6D4'

if ($WifiAdapters.Count) {
    $CurSection = 'Wi-Fi'
    T $TabNameNet 'Wi-Fi card: no power saving' 'Stops Windows putting your Wi-Fi to sleep (fixes random lag spikes). Wi-Fi blinks off for a sec' 'Safe' 0xE701 {
        foreach ($ad in $WifiAdapters) {
            try { Set-NetAdapterPowerManagement -Name $ad.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop; Rec @{ T='AdapterPower'; Adapter=$ad.Name }
                  $Added.Add("      $($ad.Name): 'Allow the computer to turn off this device' = off") } catch {}
            Set-AdapterProp $ad 'MIMO Power Save|Power Sav' @('No SMPS','Maximum Performance','^Disabled?$','^Off$')
        }
    } '#06B6D4'
    T $TabNameNet 'Prefer 5 GHz Wi-Fi' 'Uses the faster 5 GHz signal when your router has it. Shorter range than 2.4 GHz' 'Optional' 0xE701 {
        foreach ($ad in $WifiAdapters) { Set-AdapterProp $ad 'Preferred Band|Band Preference' @('Prefer 5', '5\s?G') }
    } '#06B6D4'
    T $TabNameNet 'Stop Wi-Fi hopping' 'Stops your PC jumping between routers/extenders. Best for PCs that stay in one spot' 'Optional' 0xE701 {
        foreach ($ad in $WifiAdapters) { Set-AdapterProp $ad 'Roaming Aggressiveness|Roaming Sensitivity' @('Lowest', '^Low$', 'Disable') }
    } '#06B6D4'
}
if ($EthAdapters.Count) {
    $CurSection = 'Ethernet (cable)'
    T $TabNameNet 'Ethernet: no power saving' 'Turns off "green"/energy saving stuff that adds lag and drops the connection' 'Safe' 0xE839 {
        foreach ($ad in $EthAdapters) {
            try { Set-NetAdapterPowerManagement -Name $ad.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop; Rec @{ T='AdapterPower'; Adapter=$ad.Name }
                  $Added.Add("      $($ad.Name): 'Allow the computer to turn off this device' = off") } catch {}
            Set-AdapterProp $ad 'Energy[- ]Efficient Ethernet|Green Ethernet|Advanced EEE|^EEE|Power Saving Mode|Gigabit Lite|Ultra Low Power|Auto Disable Gigabit|Reduce Speed On Power Down|System Idle Power Saver' @('^Disabled?$','^Off$')
        }
    } '#06B6D4'
    T $TabNameNet 'Ethernet: full speed (auto)' 'Fixes cables stuck at slow speed by letting the card pick the fastest speed' 'Safe' 0xE839 {
        foreach ($ad in $EthAdapters) {
            Set-AdapterProp $ad '^Speed.*Duplex' @('Auto', 'Negotiation')
            $Added.Add("      $($ad.Name): current speed = $($ad.LinkSpeed)")
            if ($ad.Status -eq 'Up' -and $ad.LinkSpeed -match '^(10|100) Mbps') {
                $Tips.Add("* Ethernet: '$($ad.Name)' is only running at $($ad.LinkSpeed)! Try a different cable (Cat5e or Cat6) or a different port on the router.")
            }
        }
    } '#06B6D4'
    T $TabNameNet 'Ethernet: lower latency' 'Network card sends data instantly instead of in batches. Uses a tiny bit more CPU' 'Optional' 0xE839 {
        foreach ($ad in $EthAdapters) { Set-AdapterProp $ad '^Interrupt Moderation$' @('^Disabled?$','^Off$') }
    } '#06B6D4'
    if ($WifiAdapters.Count) {
        T $TabNameNet 'Always use the cable when plugged in' 'If Wi-Fi and cable are both on, Windows always picks the cable' 'Optional' 0xE839 {
            foreach ($ad in $EthAdapters) {
                $ip = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction Stop
                $old = $ip.InterfaceMetric
                Set-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -InterfaceMetric 5 -ErrorAction Stop
                Rec @{ T='Metric'; Index=$ad.ifIndex; Auto="$($ip.AutomaticMetric)"; Old=$old }
                $Added.Add("      $($ad.Name): priority (metric) = 5, lower = picked first   (was: $old, automatic=$($ip.AutomaticMetric))")
            }
        } '#06B6D4'
    }
}

# ---- Windows Tweaks ----
$TabNameTweaks = 'Windows Tweaks'
$CurSection = 'Turn off Windows junk'
T $TabNameTweaks 'Turn off useless services' 'Fax, retail demo, remote registry, maps updater and other stuff you never use' 'Safe' 0xE912 {
    foreach ($sv in 'Fax','RetailDemo','RemoteRegistry','MapsBroker','WMPNetworkSvc','diagnosticshub.standardcollector.service') { Disable-Svc $sv }
} '#10B981'
T $TabNameTweaks 'No surprise restarts from Windows Update' 'Windows will not restart your PC while you are using it' 'Safe' 0xE777 {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'IsExpedited' 0
} '#10B981'
T $TabNameTweaks 'Remove old risky features' 'Removes SMB1 + PowerShell 2 (old stuff hackers use). Very old network drives may stop working' 'Safe' 0xEA18 {
    foreach ($fn in 'SMB1Protocol','MicrosoftWindowsPowerShellV2Root','MicrosoftWindowsPowerShellV2') {
        $res = Disable-WinFeature $fn
        if ($res -eq 'removed') { Rec @{ T='Feature'; Name=$fn }; $Added.Add("      Windows feature '$fn' = removed   (was: on)") }
        elseif ($res -eq 'off') { $Added.Add("      Windows feature '$fn' was already off") }
    }
} '#10B981'
T $TabNameTweaks 'Remove old unused features' 'Steps Recorder, Math Input, old IE, WordPad, XPS, Work Folders, fax. Takes a minute' 'Optional' 0xE74D {
    foreach ($fn in 'WorkFolders-Client','Printing-XPSServices-Features','FaxServicesClientPackage') {
        $res = 'failed'; try { $res = Disable-WinFeature $fn } catch { $Added.Add("      Windows feature '$fn': Windows wouldn't remove it (skipped)") }
        if ($res -eq 'removed') { Rec @{ T='Feature'; Name=$fn }; $Added.Add("      Windows feature '$fn' = removed   (was: on)") }
    }
    $caps = @(Invoke-Bg { Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Installed' -and $_.Name -match '^(App\.StepsRecorder|MathRecognizer|Browser\.InternetExplorer|Microsoft\.Windows\.WordPad|Print\.Fax\.Scan)' } | ForEach-Object { $_.Name } })
    foreach ($cap in $caps) {
        try {
            Invoke-Bg { param($n) Remove-WindowsCapability -Online -Name $n -ErrorAction Stop | Out-Null } @($cap) | Out-Null
            Rec @{ T='Cap'; Name=$cap }
            $Removed.Add("[-] Windows extra: $cap")
        } catch { $Added.Add("      Windows extra '$cap': Windows wouldn't remove it (skipped)") }
    }
} '#10B981'
T $TabNameTweaks 'Clean up the taskbar' 'Hides Task View, Chat and Widgets buttons, makes search a small icon' 'Optional' 0xE7C4 {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'ShowTaskViewButton' 0
    Set-Reg $adv 'TaskbarMn' 0
    try { Set-Reg $adv 'TaskbarDa' 0 } catch { $Added.Add('      Widgets button: Windows blocked this one (the Widgets setting in Privacy already handles it)') }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1
} '#10B981'
T $TabNameTweaks 'Remove "Learn about this picture" icon' 'Gets rid of the Spotlight icon on your desktop' 'Optional' 0xE7C5 {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' '{2cc5ca98-6485-489a-920e-b3e88a6ccce3}' 1
} '#10B981'
T $TabNameTweaks 'Turn off search indexing' 'Saves CPU + disk on slow PCs. Start menu file search gets slower' 'Optional' 0xE721 {
    Disable-Svc 'WSearch'
} '#10B981'

$CurSection = 'Free up space'
T $TabNameTweaks 'Turn off hibernation' 'Deletes the hiberfil.sys file - frees as much space as you have RAM (8-32 GB). Sleep still works' 'Optional' 0xE708 {
    $hib = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    $wasOn = (-not $hib.Exists) -or ($hib.Value -ne 0)
    powercfg /h off | Out-Null
    if ($wasOn) { Rec @{ T='Hiber' }; $Added.Add('      Hibernation = off (hiberfil.sys deleted, Fast Startup off too)   (was: on)') }
    else { $Added.Add('      Hibernation was already off') }
} '#10B981'
T $TabNameTweaks 'Deep clean Windows Update leftovers' 'Deletes old update files Windows keeps forever. SLOW - can take 5-15 minutes' 'Optional' 0xE895 {
    $code = Invoke-Bg { Dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart | Out-Null; $LASTEXITCODE } | Select-Object -Last 1
    if ($code -ne 0 -and $code -ne 3010) { throw "Windows' cleanup tool (DISM) stopped with code $code. Try again after a restart." }
    $Removed.Add('[-] Old Windows Update leftovers (DISM component cleanup)')
} '#10B981'
T $TabNameTweaks 'Empty the Recycle Bin' 'Stuff in there is GONE FOREVER. Check it first!' 'Careful' 0xE74D {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    $Removed.Add('[-] Recycle Bin emptied')
} '#10B981'

$CurSection = 'Nice extras'
T $TabNameTweaks 'Warn me when Windows puts junk back' 'Every time you sign in, quietly checks if Windows reinstalled stuff you deleted and tells you' 'Optional' 0xEA8F {
    $dir = Join-Path $env:ProgramData 'PC Debloater'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $dir 'PC-Debloater.ps1') -Force
    $who = "$env:USERDOMAIN\$env:USERNAME"
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$dir\PC-Debloater.ps1`" -CheckOnly"
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $who
    $trg.Delay = 'PT1M'
    $prn = New-ScheduledTaskPrincipal -UserId $who -RunLevel Highest -LogonType Interactive
    Register-ScheduledTask -TaskName 'PC Debloater - junk check' -Action $act -Trigger $trg -Principal $prn -Force -ErrorAction Stop | Out-Null
    Rec @{ T='SchedTask'; Name='PC Debloater - junk check' }
    $Added.Add('      Added a sign-in check: "PC Debloater - junk check" (1 minute after you sign in)')
} '#10B981'
T $TabNameTweaks 'Show file extensions' 'Shows .exe .txt .jar at the end of file names (helps spot fake files)' 'Optional' 0xE8A5 {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
} '#10B981'
if ($IsWin11) {
    T $TabNameTweaks 'Old-school right-click menu' 'Brings back the full right-click menu (no "Show more options")' 'Optional' 0xE700 {
        $p = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
        New-Item -Path $p -Force | Out-Null
        Set-ItemProperty -LiteralPath $p -Name '(default)' -Value ''
        Rec @{ T='RegKey'; Path=(Split-Path $p -Parent) }
        $Added.Add("      $p (Default) = blank   (was: not set)")
    } '#10B981'
}

# ---------- 4. Find out which apps are actually on this PC ----------
function Get-AppxIconPath($pkg) {
    try {
        $loc = $pkg.InstallLocation
        if (-not $loc -or -not (Test-Path -LiteralPath $loc)) { return $null }
        [xml]$m = Get-Content -LiteralPath (Join-Path $loc 'AppxManifest.xml') -Raw -ErrorAction Stop
        $rel = $null
        $ve = $m.SelectSingleNode("//*[local-name()='VisualElements']")
        if ($ve) { $rel = $ve.GetAttribute('Square44x44Logo') }
        if (-not $rel) { $n = $m.SelectSingleNode("//*[local-name()='Properties']/*[local-name()='Logo']"); if ($n) { $rel = $n.InnerText } }
        if (-not $rel) { return $null }
        $full = Join-Path $loc $rel
        if (Test-Path -LiteralPath $full) { return $full }
        $dir = Split-Path $full -Parent
        $base = [IO.Path]::GetFileNameWithoutExtension($full)
        $ext = [IO.Path]::GetExtension($full)
        if (-not (Test-Path -LiteralPath $dir)) { return $null }
        $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$base*$ext" })
        if ($files.Count -eq 0) { return $null }
        $best = $files | Sort-Object @{ Expression = {
                    $n = $_.Name
                    if ($n -match 'contrast') { 5 }
                    elseif ($n -match 'targetsize-48' -and $n -match 'unplated') { 0 }
                    elseif ($n -match 'targetsize-48') { 1 }
                    elseif ($n -match 'scale-200') { 2 }
                    else { 3 } }; Ascending = $true } | Select-Object -First 1
        return $best.FullName
    } catch { return $null }
}

function Load-Image($path) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = [Uri]$path
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.DecodePixelWidth = 64
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    } catch { return $null }
}

Splash 'Finding installed apps (this one takes a few seconds)...'
$allPkgs = @(Invoke-Bg { Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework } })
$allProv = @(Invoke-Bg { Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue })
Splash 'Loading icons...'
$iconCount = 0

$Visible = New-Object System.Collections.ArrayList
foreach ($it in $Items) {
    $iconCount++; if ($iconCount % 8 -eq 0) { Pump }
    if ($it.Kind -eq 'App') {
        $it.Packages = @($allPkgs | Where-Object { $_.Name -like $it.Pattern } | Sort-Object PackageFullName -Unique)
        $it.Prov     = @($allProv | Where-Object { $_.DisplayName -like $it.Pattern })
        if ($it.Packages.Count -eq 0 -and $it.Prov.Count -eq 0) { continue }   # not on this PC, skip it
        foreach ($p in $it.Packages) {
            $ip = Get-AppxIconPath $p
            if ($ip) { $img = Load-Image $ip; if ($img) { $it.Icon = $img; break } }
        }
    }
    elseif ($it.Exe) {
        try {
            $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($it.Exe)
            $it.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ic.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        } catch {}
    }
    [void]$Visible.Add($it)
}

# ---------- 4b. Remember what you already did last time (red DELETED / green TWEAKED tags) ----------
$PastByGroup = @{}
foreach ($e in @(Load-History)) {
    if (-not $e.G) { continue }
    if (-not $PastByGroup.ContainsKey($e.G)) { $PastByGroup[$e.G] = New-Object System.Collections.ArrayList }
    [void]$PastByGroup[$e.G].Add($e)
}
function Get-PastInfo([string]$name) {
    if (-not $PastByGroup.ContainsKey($name)) { return $null }
    $es = @($PastByGroup[$name])
    $types = @($es | ForEach-Object { $_.T })
    $deleted = ($types -contains 'App' -or $types -contains 'Win32' -or $types -contains 'Program')
    $lbl = 'TWEAKED'; if ($deleted) { $lbl = 'DELETED' }
    return [pscustomobject]@{ Label = $lbl; When = ($es | Select-Object -Last 1).When; Types = $types; Deleted = $deleted }
}
$CameBack = @()
$visibleNames = @{}; foreach ($v in $Visible) { $visibleNames[$v.Name] = $true }
foreach ($it in $Items) {
    $past = Get-PastInfo $it.Name
    if (-not $past) { continue }
    if ($visibleNames[$it.Name]) {
        if ($past.Deleted) { $it.Desc = "$($it.Desc)   (you deleted this before - Windows put it back)"; $CameBack += $it.Name }
        else { $it | Add-Member -NotePropertyName Past -NotePropertyValue $past -Force }
    } elseif ($past.Deleted) {
        # it's gone from the PC, so show a faded "DELETED" row for it
        [void]$Visible.Add([pscustomobject]@{ Kind='Ghost'; Tab=$it.Tab; Section=$it.Section; Pattern=$null; Name=$it.Name
            Desc="You deleted this on $($past.When). Want it back? Press Reinstall / Undo."; Level='Done'; Color='#4B4B57'
            Glyph=$null; Action=$null; Packages=@(); Prov=@(); Icon=$null; Exe=$null; Past=$past })
        $visibleNames[$it.Name] = $true
    }
}
# startup apps you turned off (they don't show up in the scan anymore)
foreach ($g in $PastByGroup.Keys) {
    if ($visibleNames[$g]) { continue }
    $past = Get-PastInfo $g
    if ($past.Types -contains 'Startup') {
        [void]$Visible.Add([pscustomobject]@{ Kind='Ghost'; Tab='Apps'; Section='Startup apps (stop them opening when your PC turns on)'; Pattern=$null; Name=$g
            Desc="You stopped this opening with your PC on $($past.When). Want it back? Press Reinstall / Undo."; Level='Done'; Color='#4B4B57'
            Glyph=$null; Action=$null; Packages=@(); Prov=@(); Icon=$null; Exe=$null; Past=$past })
    } elseif ($past.Deleted) {
        $sec = 'Programs + trial junk'; if ($past.Types -contains 'App') { $sec = 'Bloat apps' }
        [void]$Visible.Add([pscustomobject]@{ Kind='Ghost'; Tab='Apps'; Section=$sec; Pattern=$null; Name=$g
            Desc="You deleted this on $($past.When). Want it back? Press Reinstall / Undo."; Level='Done'; Color='#4B4B57'
            Glyph=$null; Action=$null; Packages=@(); Prov=@(); Icon=$null; Exe=$null; Past=$past })
    }
}
# put everything back in the right order (so faded rows sit in their normal section)
$tabRank = @{ 'Apps'=0; 'Privacy & Ads'=1; 'FPS Booster'=2; 'Wi-Fi & Ethernet'=3; 'Windows Tweaks'=4 }
$secRank = @{}; $itemRank = @{}; $n = 0
foreach ($it in $Items) { $k = "$($it.Tab)|$($it.Section)"; if (-not $secRank.ContainsKey($k)) { $secRank[$k] = $n }; if (-not $itemRank.ContainsKey($it.Name)) { $itemRank[$it.Name] = $n }; $n++ }
$i = 0
$sorted = foreach ($v in $Visible) {
    $k = "$($v.Tab)|$($v.Section)"
    $sr = 99999; if ($secRank.ContainsKey($k)) { $sr = $secRank[$k] }
    $ir = 99999 + $i; if ($itemRank.ContainsKey($v.Name)) { $ir = $itemRank[$v.Name] }
    [pscustomobject]@{ V = $v; A = $tabRank[$v.Tab]; B = $sr; C = $ir; D = $i }
    $i++
}
$Visible = New-Object System.Collections.ArrayList
foreach ($x in ($sorted | Sort-Object A, B, C, D)) { [void]$Visible.Add($x.V) }

Splash 'Almost ready...'
# ---------- 5. The window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Debloater" Width="980" Height="840" MinWidth="780" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#16161C" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="TabControl">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <UniformGrid Grid.Row="0" Columns="3" IsItemsHost="True"/>
              <ContentPresenter Grid.Row="1" ContentSource="SelectedContent"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="#24242C" CornerRadius="8" Padding="16,8" Margin="0,0,8,10" Cursor="Hand">
              <ContentPresenter ContentSource="Header" TextElement.Foreground="White" TextElement.FontSize="14" TextElement.FontWeight="SemiBold"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#7C5CFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#2E2E38"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollViewer">
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,14">
      <Grid>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="PC Debloater" FontSize="28" FontWeight="Bold" Foreground="White"/>
          <TextBlock x:Name="VerText" Foreground="#6E6E80" FontSize="13" VerticalAlignment="Bottom" Margin="10,0,0,5"/>
        </StackPanel>
        <Button x:Name="BtnAbout" Content="About / Help" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
      <TextBlock Text="Tick what you want GONE. Untick what you want to keep. Green = safe, blue = your call, orange = be careful."
                 Foreground="#A0A0B0" FontSize="13" TextWrapping="Wrap" Margin="0,4,0,0"/>
      <Border x:Name="Banner" Visibility="Collapsed" Background="#3A2A10" CornerRadius="10" Padding="12,8" Margin="0,10,0,0">
        <TextBlock x:Name="BannerText" Foreground="#FBBF24" FontSize="13" TextWrapping="Wrap"/>
      </Border>
      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="280"/></Grid.ColumnDefinitions>
        <WrapPanel x:Name="PresetBar" VerticalAlignment="Center">
          <TextBlock Text="Quick pick:" Foreground="#C9C9D6" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <Button x:Name="BtnPGamer" Content="Gamer" Background="#B91C1C" Margin="0,0,6,0"/>
          <Button x:Name="BtnPPriv"  Content="Max privacy" Background="#6D28D9" Margin="0,0,6,0"/>
          <Button x:Name="BtnPLight" Content="Light clean" Background="#0E7490" Margin="0,0,6,0"/>
          <Button x:Name="BtnPLast" Content="My last picks" Margin="0,0,6,0" ToolTip="Ticks the same stuff you picked last time you debloated"/>
        </WrapPanel>
        <Grid Grid.Column="1">
          <Border Background="#24242C" CornerRadius="8"/>
          <TextBlock x:Name="SearchHint" Text="Search... (like xbox, edge, fps)" Foreground="#6E6E80" FontSize="13" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
          <TextBox x:Name="Search" Background="Transparent" Foreground="White" BorderThickness="0" FontSize="13" Padding="10,8,34,8" CaretBrush="White" VerticalContentAlignment="Center" ToolTip="Ctrl+F to search, Esc to clear"/>
          <Button x:Name="BtnClearSearch" Visibility="Collapsed" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,4,0" Background="Transparent" Width="30" Height="30" ToolTip="Clear search (Esc)">
            <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#A0A0B0"/>
          </Button>
        </Grid>
      </Grid>
    </StackPanel>

    <TabControl x:Name="Tabs" Grid.Row="1" Background="Transparent" BorderThickness="0" Padding="0">
      <TabItem x:Name="TabApps" Header="Apps">
        <ScrollViewer><StackPanel x:Name="ListApps" Margin="0,0,8,0"/></ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabPrivacy" Header="Privacy &amp; Ads">
        <ScrollViewer><StackPanel x:Name="ListPrivacy" Margin="0,0,8,0"/></ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabFps" Header="FPS Booster">
        <ScrollViewer><StackPanel x:Name="ListFps" Margin="0,0,8,0"/></ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabWifi" Header="Wi-Fi &amp; Ethernet">
        <ScrollViewer><StackPanel x:Name="ListWifi" Margin="0,0,8,0"/></ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabExtras" Header="Windows Tweaks">
        <ScrollViewer><StackPanel x:Name="ListExtras" Margin="0,0,8,0"/></ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabDrivers" Header="My PC and Drivers">
        <ScrollViewer><StackPanel x:Name="ListDrivers" Margin="0,0,8,0"/></ScrollViewer>
      </TabItem>
    </TabControl>

    <StackPanel Grid.Row="2" Margin="0,12,0,0">
      <WrapPanel x:Name="ButtonBar">
        <Button x:Name="BtnRec"  Content="Recommended" Margin="0,0,8,8"/>
        <Button x:Name="BtnAll"  Content="Select all in this tab"  Margin="0,0,8,8"/>
        <Button x:Name="BtnNone" Content="Select none in this tab" Margin="0,0,8,8"/>
        <Button x:Name="BtnAllEvery" Content="Select all (every tab)" Margin="0,0,8,8"/>
        <Button x:Name="BtnNoneEvery" Content="Select none (every tab)" Margin="0,0,8,8"/>
        <Button x:Name="BtnRP" Content="Make restore point now" Background="#1F6F4A" Margin="0,0,8,8"/>
        <Button x:Name="BtnUndo" Content="Reinstall / Undo" Background="#2563EB" Margin="0,0,8,8"/>
        <Button x:Name="BtnPreview" Content="Preview (changes nothing)" Margin="0,0,16,8"/>
        <CheckBox x:Name="ChkRestore" IsChecked="True" VerticalAlignment="Center" Margin="0,0,0,8" Foreground="White">
          <TextBlock x:Name="ChkRestoreText" Text="Make a backup of how my PC is now (only once, the first time)" Foreground="White" FontSize="13" TextWrapping="Wrap" MaxWidth="420"/>
        </CheckBox>
      </WrapPanel>
      <ProgressBar x:Name="Prog" Height="10" Background="#24242C" Foreground="#7C5CFF" BorderThickness="0" Margin="0,6,0,6"/>
      <Grid>
        <TextBlock x:Name="Status" Text="Ready." Foreground="#A0A0B0" FontSize="13" VerticalAlignment="Center"/>
        <Button x:Name="BtnGo" Content="Debloat" HorizontalAlignment="Right" Background="#E5484D" FontSize="16" FontWeight="Bold" MinWidth="200"/>
      </Grid>
    </StackPanel>
  </Grid>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$Window.Height = [Math]::Min(840, [System.Windows.SystemParameters]::WorkArea.Height - 20)   # fit small laptop screens
$Window.Title = "$AppName v$AppVersion"
foreach ($n in 'BtnPLast','BtnClearSearch','BtnAllEvery','BtnNoneEvery','VerText','BtnAbout','BtnPreview','PresetBar','Banner','BannerText','BtnPGamer','BtnPPriv','BtnPLight','Search','SearchHint','TabDrivers','ListDrivers','Tabs','TabApps','TabPrivacy','TabFps','TabWifi','TabExtras','ListApps','ListPrivacy','ListFps','ListWifi','ListExtras','ButtonBar','BtnRec','BtnAll','BtnNone','BtnRP','BtnUndo','ChkRestore','ChkRestoreText','Prog','Status','BtnGo') {
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}

$Rows = New-Object System.Collections.ArrayList
$VerText.Text = "v$AppVersion"
$Busy = $false
function Set-Busy([bool]$on) {
    $script:Busy = $on
    if ($on) { $Status.Text = 'Working... buttons are paused until this finishes so nothing gets mixed up.' }
    foreach ($c in $Tabs, $ButtonBar, $BtnGo, $PresetBar, $Search, $BtnAbout) { if ($c) { $c.IsEnabled = -not $on } }
}
$Window.Add_Closing({
    if ($script:Busy) {
        $_.Cancel = $true
        [System.Windows.MessageBox]::Show("Still working - please wait until it finishes!`n`nClosing now could leave things half done.", $AppName, 'OK', 'Warning') | Out-Null
    }
})

function Update-Count {
    $n = 0
    foreach ($r in $Rows) { if ($r.Check.IsChecked -eq $true -and $r.Check.IsEnabled) { $n++ } }
    $BtnGo.Content = "Debloat ($n picked)"
    if (Get-Command Update-TabHeaders -ErrorAction SilentlyContinue) { [void](Update-TabHeaders) }
}

function New-IconElement($it) {
    $box = New-Object System.Windows.Controls.Border
    $box.Width = 42; $box.Height = 42
    $box.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $box.Margin = Th 0 0 14 0
    $box.VerticalAlignment = 'Center'
    if ($it.Icon) {
        $box.Background = Brush '#2E2E38'
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $it.Icon; $img.Width = 30; $img.Height = 30
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
        $box.Child = $img
    } else {
        $box.Background = Brush $it.Color
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Foreground = Brush '#FFFFFF'
        $tb.HorizontalAlignment = 'Center'; $tb.VerticalAlignment = 'Center'
        if ($it.Glyph) {
            $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
            $tb.FontSize = 20
            $tb.Text = $it.Glyph
        } else {
            $letters = ($it.Name -split '\s+' | Where-Object { $_ -match '^[A-Za-z0-9]' } | Select-Object -First 2 | ForEach-Object { $_.Substring(0,1).ToUpper() }) -join ''
            $tb.FontSize = 16; $tb.FontWeight = [System.Windows.FontWeights]::Bold
            $tb.Text = $letters
        }
        $box.Child = $tb
    }
    return $box
}

function New-Row($it) {
    $card = New-Object System.Windows.Controls.Border
    $card.Background = Brush '#20202A'
    $card.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $card.Padding = Th 12 10 14 10
    $card.Margin = Th 0 0 0 8
    $card.Cursor = [System.Windows.Input.Cursors]::Hand

    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto','Auto','Star','Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($w -eq 'Star') { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') } else { $cd.Width = [System.Windows.GridLength]::Auto }
        $g.ColumnDefinitions.Add($cd)
    }

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.VerticalAlignment = 'Center'
    $cb.Margin = Th 2 0 14 0
    $cb.LayoutTransform = New-Object System.Windows.Media.ScaleTransform 1.35, 1.35
    $cb.IsChecked = ($it.Level -eq 'Safe' -and -not $it.Past)
    [System.Windows.Controls.Grid]::SetColumn($cb, 0)

    $icon = New-IconElement $it
    [System.Windows.Controls.Grid]::SetColumn($icon, 1)

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $it.Name; $t1.Foreground = Brush '#FFFFFF'; $t1.FontSize = 15; $t1.FontWeight = [System.Windows.FontWeights]::SemiBold
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = $it.Desc; $t2.Foreground = Brush '#9A9AAE'; $t2.FontSize = 12; $t2.TextWrapping = 'Wrap'
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
    [System.Windows.Controls.Grid]::SetColumn($sp, 2)

    switch ($it.Level) {
        'Done'     { $pc = '#C9C9D6'; $pt = 'DONE' }
        'Safe'     { $pc = '#22C55E'; $pt = 'SAFE' }
        'Optional' { $pc = '#3B82F6'; $pt = 'YOUR CALL' }
        default    { $pc = '#F59E0B'; $pt = 'CAREFUL' }
    }
    $pill = New-Object System.Windows.Controls.Border
    $pill.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $pill.Padding = Th 8 3 8 3
    $pill.Margin = Th 10 0 0 0
    $pill.VerticalAlignment = 'Center'
    $pill.Background = Brush ('#33' + $pc.Substring(1))
    $pt2 = New-Object System.Windows.Controls.TextBlock
    $pt2.Text = $pt; $pt2.FontSize = 11; $pt2.FontWeight = [System.Windows.FontWeights]::Bold; $pt2.Foreground = Brush $pc
    $pill.Child = $pt2
    [System.Windows.Controls.Grid]::SetColumn($pill, 3)
    if ($it.Past) {
        # gray DELETED / TWEAKED tag
        $pt2.Text = $it.Past.Label
        $pt2.Foreground = Brush '#FFFFFF'
        if ($it.Past.Label -eq 'DELETED') { $pill.Background = Brush '#DC2626' } else { $pill.Background = Brush '#16A34A' }
        if ($it.Kind -eq 'Ghost') {
            $cb.IsEnabled = $false
            $card.Opacity = 0.5
            $card.Cursor = [System.Windows.Input.Cursors]::Arrow
        } else {
            $card.Opacity = 0.75
            $t2.Text = "$($it.Desc)   (already done on $($it.Past.When) - tick it to do it again)"
        }
    }

    foreach ($c in $cb, $icon, $sp, $pill) { [void]$g.Children.Add($c) }
    $card.Child = $g
    $card.Tag = $cb
    $card.Add_MouseLeftButtonUp({ if ($this.Tag.IsEnabled) { $this.Tag.IsChecked = -not [bool]$this.Tag.IsChecked } })
    $card.Add_MouseEnter({ if ($this.Tag.IsEnabled) { $this.Background = Brush '#2A2A38' } })
    $card.Add_MouseLeave({ $this.Background = Brush '#20202A' })
    $cb.Add_Checked({ Update-Count })
    $cb.Add_Unchecked({ Update-Count })

    return [pscustomobject]@{ Item = $it; Check = $cb; Card = $card }
}

$LastSection = @{}
$Headers = New-Object System.Collections.ArrayList
foreach ($it in $Visible) {
    $row = New-Row $it
    [void]$Rows.Add($row)
    switch ($it.Tab) {
        'Apps'          { $list = $ListApps }
        'Privacy & Ads' { $list = $ListPrivacy }
        'FPS Booster'   { $list = $ListFps }
        'Wi-Fi & Ethernet' { $list = $ListWifi }
        default         { $list = $ListExtras }
    }
    if ($it.Section -and $LastSection[$it.Tab] -ne $it.Section) {
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = $it.Section; $h.Foreground = Brush '#C9C9D6'; $h.FontSize = 14; $h.FontWeight = [System.Windows.FontWeights]::SemiBold
        $h.Margin = Th 2 10 0 8
        [void]$list.Children.Add($h)
        [void]$Headers.Add($h)
        $LastSection[$it.Tab] = $it.Section
    }
    [void]$list.Children.Add($row.Card)
}
if (-not @($Visible | Where-Object { $_.Kind -eq 'Game' }).Count) {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = "No games found in Steam / Epic / Riot / Minecraft folders. The Windows boosts below still help every game."
    $h.Foreground = Brush '#A0A0B0'; $h.FontSize = 12; $h.TextWrapping = 'Wrap'; $h.Margin = Th 2 4 0 8
    $ListFps.Children.Insert(0, $h)
}
foreach ($pair in @(@($ListApps,'Apps',$TabApps), @($ListPrivacy,'Privacy & Ads',$TabPrivacy), @($ListFps,'FPS Booster',$TabFps), @($ListWifi,'Wi-Fi & Ethernet',$TabWifi), @($ListExtras,'Windows Tweaks',$TabExtras))) {
    $cnt = @($Rows | Where-Object { $_.Item.Tab -eq $pair[1] }).Count
    $pair[2].Header = "$($pair[1]) ($cnt)"
    if ($cnt -eq 0) {
        $e = New-Object System.Windows.Controls.TextBlock
        $e.Text = 'Nothing to remove here - your PC is already clean!'; $e.Foreground = Brush '#A0A0B0'; $e.FontSize = 14; $e.Margin = Th 4 10 0 0
        [void]$pair[0].Children.Add($e)
    }
}
Update-Count


# ---------- 5b. Banner, presets and search ----------
if ($CameBack.Count) {
    $Banner.Visibility = 'Visible'
    $BannerText.Text = "Heads up! Windows put back $($CameBack.Count) thing(s) you deleted: " + ($CameBack -join ', ') + ". Tick them and hit Debloat to get rid of them again."
}

function Apply-Preset([string]$which) {
    $n = 0
    foreach ($r in $Rows) {
        if (-not $r.Check.IsEnabled) { continue }
        $it = $r.Item
        $fresh = -not $it.Past
        $base = ($it.Level -eq 'Safe' -and $fresh)
        switch ($which) {
            'Gamer' {
                $on = $base -or ($fresh -and $it.Tab -eq 'FPS Booster' -and $it.Level -ne 'Careful') -or
                      ($fresh -and $it.Tab -eq 'Wi-Fi & Ethernet' -and $it.Name -match 'ping|DNS|no power saving|full speed|lower latency')
                if ($IsLaptop -and $it.Name -match 'Ultimate Performance|power throttling') { $on = $false }   # laptops would get hot + lose battery
            }
            'Privacy' { $on = $base -or ($fresh -and $it.Tab -eq 'Privacy & Ads') }
            'Light'   { $on = $fresh -and (($it.Kind -eq 'App' -and $it.Level -eq 'Safe') -or
                        $it.Name -in @('Clean junk + temp files','No Start menu ads + no sneaky app installs','No lock screen ads and tips','No Bing in Start search','Turn off advertising ID')) }
        }
        $r.Check.IsChecked = [bool]$on
        if ($on) { $n++ }
    }
    return $n
}
$BtnPGamer.Add_Click({ $n = Apply-Preset 'Gamer';   $msg = "Gamer pick: $n things ticked (FPS + ping stuff + safe debloat)."; if ($IsLaptop) { $msg += ' Skipped the battery-hungry power stuff since you are on a laptop.' }; Say $msg })
$BtnPPriv.Add_Click({  $n = Apply-Preset 'Privacy'; Say "Max privacy pick: $n things ticked (every privacy switch + safe debloat)." })
$BtnPLight.Add_Click({ $n = Apply-Preset 'Light';   Say "Light clean pick: $n things ticked (just the obvious junk)." })

# which tab is which (by the tab's own name, so it can never get mixed up)
$TabKeys = [ordered]@{ 'TabApps' = 'Apps'; 'TabPrivacy' = 'Privacy & Ads'; 'TabFps' = 'FPS Booster'; 'TabWifi' = 'Wi-Fi & Ethernet'; 'TabExtras' = 'Windows Tweaks' }
function Update-TabHeaders {
    # "Apps (3 of 15)" = 3 picked out of 15 showing. Returns how many rows each tab is showing.
    $counts = @{}
    foreach ($tn in $TabKeys.Keys) {
        $key = $TabKeys[$tn]; $c = 0; $p = 0
        foreach ($r in $Rows) {
            if ($r.Item.Tab -ne $key -or $r.Card.Visibility -ne 'Visible') { continue }
            $c++
            if ($r.Check.IsChecked -eq $true -and $r.Check.IsEnabled) { $p++ }
        }
        $counts[$key] = $c
        $ti = $Window.FindName($tn)
        if ($ti) { if ($p) { $ti.Header = "$key ($p of $c)" } else { $ti.Header = "$key ($c)" } }
    }
    return $counts
}
function Get-CurrentTabKey {
    # returns 'Apps', 'Privacy & Ads', ... or 'Drivers', or $null if it can't tell
    $sel = $Tabs.SelectedItem
    if ($null -eq $sel) { return $null }
    $n = [string]$sel.Name
    if ($n -eq 'TabDrivers') { return 'Drivers' }
    if ($TabKeys.Contains($n)) { return $TabKeys[$n] }
    return $null
}
$Search.Add_TextChanged({
    $q = $Search.Text.Trim()
    if ($q) { $SearchHint.Visibility = 'Collapsed' } else { $SearchHint.Visibility = 'Visible' }
    foreach ($r in $Rows) {
        $hit = (-not $q) -or ($r.Item.Name -like "*$q*") -or ($r.Item.Desc -like "*$q*")
        if ($hit) { $r.Card.Visibility = 'Visible' } else { $r.Card.Visibility = 'Collapsed' }
    }
    foreach ($h in $Headers) { if ($q) { $h.Visibility = 'Collapsed' } else { $h.Visibility = 'Visible' } }
    if ($q) { $BtnClearSearch.Visibility = 'Visible' } else { $BtnClearSearch.Visibility = 'Collapsed' }
    $counts = Update-TabHeaders
    $firstHit = $null
    foreach ($tn in $TabKeys.Keys) { if ($counts[$TabKeys[$tn]] -and -not $firstHit) { $firstHit = $Window.FindName($tn) } }
    $curKey = Get-CurrentTabKey
    if ($q -and $firstHit -and $curKey -and $curKey -ne 'Drivers' -and -not $counts[$curKey]) { $Tabs.SelectedItem = $firstHit }
})

# ---------- 5c. My PC and Drivers tab ----------
$CPU  = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$GPUs = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|Parsec|Citrix|DisplayLink|Mirage|IddCx' })
$RAMgb = [math]::Round(((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory) / 1GB)
function Get-Vendor([string]$n) {
    if ($n -match 'NVIDIA|GeForce|RTX|GTX|Quadro') { return 'NVIDIA' }
    if ($n -match 'AMD|Radeon|Ryzen|Threadripper|Athlon') { return 'AMD' }
    if ($n -match 'Intel|Arc|Iris|UHD|Core') { return 'Intel' }
    return 'Other'
}
$CpuVendor = Get-Vendor ([string]$CPU.Name)
$GpuVendors = @($GPUs | ForEach-Object { Get-Vendor $_.Name } | Select-Object -Unique)
# Each brand's own updater app + what to click in it
$Guides = @{
    'NVIDIA' = @{
        App = 'NVIDIA app'; Match = '^NVIDIA app$|GeForce Experience'
        Exes = @("$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe", "$env:ProgramFiles\NVIDIA Corporation\NVIDIA GeForce Experience\NVIDIA GeForce Experience.exe")
        Page = 'https://www.nvidia.com/en-us/software/nvidia-app/'
        Have = @('The NVIDIA app opens.', 'Click "Drivers" on the left side.', 'If it says a new driver is ready, click "Download".', 'When it finishes, click "Express Installation".', 'Your screen goes black / flickers for a few seconds - totally normal!', 'Done! Restart if it asks.')
        Need = @('Your browser opens the official NVIDIA app download page.', 'Click "Download Now" and open the file you get.', 'Install it (keep clicking Agree / Next).', 'Open the NVIDIA app (you can skip signing in).', 'Click "Drivers" on the left, then "Download", then "Express Installation".', 'Screen flickers for a few seconds - normal. Done!')
    }
    'AMD' = @{
        App = 'AMD Software: Adrenalin Edition'; Match = 'AMD Software|Radeon Software|Adrenalin'
        Exes = @("$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe")
        Page = 'https://www.amd.com/en/support/download/drivers.html'
        Have = @('AMD Software opens.', 'On the Home tab, click "Check for updates" (top right).', 'If a new driver shows up, click "Download & Install".', 'Pick "Full Install" if it asks.', 'Screen flickers for a few seconds - normal!', 'Restart if it asks. Done!')
        Need = @('Your browser opens AMD''s official driver page.', 'Click "Download Windows Drivers" (it''s the auto-detect tool).', 'Open the file - it finds your AMD graphics card AND chipset drivers by itself.', 'Click "Install" on what it finds.', 'Screen flickers for a few seconds - normal.', 'Restart when it asks. Done!')
    }
    'Intel' = @{
        App = 'Intel Driver & Support Assistant'; Match = 'Intel.*Driver.*Support'
        Exes = @()
        Page = 'https://www.intel.com/content/www/us/en/support/detect.html'
        Have = @('Intel Driver & Support Assistant opens (it shows up in your browser).', 'Wait a few seconds for it to scan your PC.', 'Click "Download all" (or "Download" on each one).', 'Click "Install" on each one when it finishes downloading.', 'Restart if it asks. Done!')
        Need = @('Your browser opens Intel''s official driver page.', 'Click "Download now" and install Intel Driver & Support Assistant.', 'It opens in your browser and scans your PC by itself.', 'Click "Download all", then "Install" on each one.', 'Restart if it asks. Done!')
    }
}

function Find-VendorApp($vendor) {
    $g = $Guides[$vendor]
    foreach ($root in "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs") {
        $lnk = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match $g.Match } | Select-Object -First 1
        if ($lnk) { return $lnk.FullName }
    }
    foreach ($x in $g.Exes) { if (Test-Path -LiteralPath $x) { return $x } }
    return $null
}

function Show-DriverGuide($vendor) {
    $g = $Guides[$vendor]
    $appPath = Find-VendorApp $vendor
    $parts = @()
    if (@($GpuVendors) -contains $vendor) { $parts += 'graphics card' }
    if ($CpuVendor -eq $vendor) { $parts += 'CPU / chipset' }
    $what = $parts -join ' + '
    if ($appPath) { $steps = $g.Have; $sub = "Good news: you already have $($g.App). Here's where to click:"; $btnText = "Open $($g.App) for me" }
    else          { $steps = $g.Need; $sub = "You don't have $($g.App) yet - it's $vendor's free official updater. Here's what to do:"; $btnText = 'Open the download page for me' }

    $gx = [xml]@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Update your $vendor driver" Width="600" SizeToContent="Height" WindowStartupLocation="CenterOwner" Background="#16161C" FontFamily="Segoe UI" ResizeMode="NoResize">
  $StyleXml
  <StackPanel Margin="20">
    <TextBlock Text="Update your $vendor driver" FontSize="24" FontWeight="Bold" Foreground="White"/>
    <TextBlock x:Name="GWhat" Foreground="#A78BFA" FontSize="13" Margin="0,2,0,0"/>
    <TextBlock x:Name="GSub" Foreground="#C9C9D6" FontSize="14" TextWrapping="Wrap" Margin="0,12,0,10"/>
    <StackPanel x:Name="GSteps"/>
    <Border x:Name="GNoteBox" Visibility="Collapsed" Background="#3A2A10" CornerRadius="10" Padding="12,8" Margin="0,6,0,0">
      <TextBlock x:Name="GNote" Foreground="#FBBF24" FontSize="12" TextWrapping="Wrap"/>
    </Border>
    <WrapPanel HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="GNo" Content="Not now" Margin="0,0,8,0"/>
      <Button x:Name="GYes" Background="#16A34A" FontWeight="Bold"/>
    </WrapPanel>
  </StackPanel>
</Window>
"@
    $gw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $gx))
    $gw.Owner = $Window
    $gw.FindName('GWhat').Text = "For your: $what"
    $gw.FindName('GSub').Text = $sub
    $gw.FindName('GYes').Content = $btnText
    $panel = $gw.FindName('GSteps')
    $i = 1
    foreach ($st in $steps) {
        $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = Th 0 0 0 8
        $num = New-Object System.Windows.Controls.Border; $num.Width = 26; $num.Height = 26; $num.CornerRadius = [System.Windows.CornerRadius]::new(13); $num.Background = Brush '#7C5CFF'; $num.Margin = Th 0 0 10 0; $num.VerticalAlignment = 'Top'
        $nt = New-Object System.Windows.Controls.TextBlock; $nt.Text = "$i"; $nt.Foreground = Brush '#FFFFFF'; $nt.FontWeight = [System.Windows.FontWeights]::Bold; $nt.HorizontalAlignment = 'Center'; $nt.VerticalAlignment = 'Center'
        $num.Child = $nt
        $tx = New-Object System.Windows.Controls.TextBlock; $tx.Text = $st; $tx.Foreground = Brush '#FFFFFF'; $tx.FontSize = 14; $tx.TextWrapping = 'Wrap'; $tx.MaxWidth = 500; $tx.VerticalAlignment = 'Center'
        [void]$row.Children.Add($num); [void]$row.Children.Add($tx)
        [void]$panel.Children.Add($row)
        $i++
    }
    if ($IsLaptop -and $vendor -eq 'NVIDIA') {
        $gw.FindName('GNoteBox').Visibility = 'Visible'
        $gw.FindName('GNote').Text = "You're on a laptop: this works for most laptops. If NVIDIA says your laptop isn't supported, get the driver from your laptop brand's website (HP, Dell, Lenovo, ASUS, Acer...) instead."
    }
    $script:GuideWin = $gw; $script:GuidePath = $appPath; $script:GuidePage = $g.Page; $script:GuideApp = $g.App
    $gw.FindName('GNo').Add_Click({ $GuideWin.Close() })
    $gw.FindName('GYes').Add_Click({
        try {
            if ($GuidePath) { Start-Process -FilePath $GuidePath; $DrvStatus.Text = "Opened $GuideApp - follow the steps!" }
            else { Start-Process $GuidePage; $DrvStatus.Text = "Opened the $GuideApp download page - follow the steps!" }
        } catch {
            Start-Process $GuidePage; $DrvStatus.Text = "Couldn't open the app, so opened the official page instead."
        }
        $GuideWin.Close()
    })
    [void]$gw.ShowDialog()
}

function New-InfoRow($name, $desc, $glyph, $color, $pillText, $pillColor) {
    $fake = [pscustomobject]@{ Name = $name; Desc = $desc; Level = 'Optional'; Color = $color; Glyph = [string][char]$glyph; Icon = $null }
    $row = New-Row $fake
    $row.Check.Visibility = 'Collapsed'; $row.Check.IsChecked = $false; $row.Check.IsEnabled = $false
    $row.Card.Cursor = [System.Windows.Input.Cursors]::Arrow
    $pb = $row.Card.Child.Children[3]
    $pb.Child.Text = $pillText; $pb.Child.Foreground = Brush $pillColor; $pb.Background = Brush ('#33' + $pillColor.Substring(1))
    return $row
}
function Add-Header($panel, $text) {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $text; $h.Foreground = Brush '#C9C9D6'; $h.FontSize = 14; $h.FontWeight = [System.Windows.FontWeights]::SemiBold; $h.Margin = Th 2 10 0 8
    [void]$panel.Children.Add($h)
}
function New-Btn($text, $bg) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $text; $b.Background = Brush $bg; $b.Margin = Th 0 0 8 8
    return $b
}

Add-Header $ListDrivers 'Your PC'
if ($CPU) {
    $cpuDesc = "$($CPU.NumberOfCores) cores / $($CPU.NumberOfLogicalProcessors) threads, up to $([math]::Round($CPU.MaxClockSpeed / 1000, 1)) GHz   -   $RAMgb GB RAM"
    [void]$ListDrivers.Children.Add((New-InfoRow ($CPU.Name.Trim()) $cpuDesc 0xE950 '#2563EB' "CPU: $CpuVendor" '#60A5FA').Card)
}
foreach ($g in $GPUs) {
    $age = $null; $dateTxt = 'unknown date'
    if ($g.DriverDate) { $age = [int](((Get-Date) - [datetime]$g.DriverDate).TotalDays / 30); $dateTxt = ([datetime]$g.DriverDate).ToString('MMM d, yyyy') }
    $gd = "Driver $($g.DriverVersion) from $dateTxt"
    if ($null -ne $age) { $gd += "  ($age months old)" }
    if ($null -ne $age -and $age -ge 6) { $pt = 'DRIVER IS OLD'; $pcol = '#F59E0B'; $gd += '  -  a newer one is almost for sure out!' } else { $pt = 'GPU'; $pcol = '#A78BFA' }
    [void]$ListDrivers.Children.Add((New-InfoRow $g.Name $gd 0xE7F4 '#7C3AED' $pt $pcol).Card)
}

Add-Header $ListDrivers 'Driver updates'
$DrvBar = New-Object System.Windows.Controls.WrapPanel
$BtnDrvCheck   = New-Btn 'Check for driver updates' '#7C5CFF'
$BtnDrvInstall = New-Btn 'Install selected updates' '#E5484D'; $BtnDrvInstall.IsEnabled = $false
[void]$DrvBar.Children.Add($BtnDrvCheck); [void]$DrvBar.Children.Add($BtnDrvInstall)
foreach ($v in @(@($GpuVendors) + @($CpuVendor) | Select-Object -Unique)) {
    if ($Guides.ContainsKey($v)) {
        $b = New-Btn "Get newest $v driver (step by step)" '#2E2E38'
        $b.Tag = $v
        $b.Add_Click({ try { Show-DriverGuide $this.Tag } catch { Report-Error $_ 'Driver guide' } })
        [void]$DrvBar.Children.Add($b)
    }
}
[void]$ListDrivers.Children.Add($DrvBar)
$DrvStatus = New-Object System.Windows.Controls.TextBlock
$DrvStatus.Text = 'Opening this tab checks Windows Update for driver updates for your CPU, GPU and other parts. Nothing installs without you saying yes TWICE.'
$DrvStatus.Foreground = Brush '#A0A0B0'; $DrvStatus.FontSize = 13; $DrvStatus.TextWrapping = 'Wrap'; $DrvStatus.Margin = Th 2 0 0 10
[void]$ListDrivers.Children.Add($DrvStatus)
$DrvList = New-Object System.Windows.Controls.StackPanel
[void]$ListDrivers.Children.Add($DrvList)
$DrvRows = New-Object System.Collections.ArrayList
$DrvChecked = $false

function Find-DriverUpdates {
    $script:DrvChecked = $true
    $DrvList.Children.Clear(); $DrvRows.Clear(); $BtnDrvInstall.IsEnabled = $false; $BtnDrvCheck.IsEnabled = $false
    # don't let a debloat start while we're checking (you can still look at other tabs)
    $script:Busy = $true; $ButtonBar.IsEnabled = $false; $BtnGo.IsEnabled = $false
    $script:StatusBeforeDrv = $Status.Text
    $Status.Text = 'Checking for driver updates in the background... the bottom buttons + Debloat are paused until it finishes (about a minute).'
    $DrvStatus.Text = 'Checking Windows Update for driver updates... this can take a minute or two.'
    Pump
    try {
        # search on a background thread, bring back plain info (no Windows Update objects across threads)
        $found = @(Invoke-Bg {
            $sess = New-Object -ComObject Microsoft.Update.Session
            $sess.ClientApplicationID = 'PC Debloater'
            $res = $sess.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
            for ($i = 0; $i -lt $res.Updates.Count; $i++) {
                $u = $res.Updates.Item($i)
                $when = ''; try { $when = ([datetime]$u.DriverVerDate).ToString('MMM d, yyyy') } catch {}
                [pscustomobject]@{ Id = [string]$u.Identity.UpdateID; Title = [string]$u.Title; DriverClass = [string]$u.DriverClass
                                   DriverManufacturer = [string]$u.DriverManufacturer; When = $when; MB = [math]::Round($u.MaxDownloadSize / 1MB) }
            }
        })
    } catch {
        $DrvStatus.Text = "Couldn't check Windows Update: $_. Make sure you're online. You can still use the 'Get newest ... driver (step by step)' buttons."
        $BtnDrvCheck.IsEnabled = $true
        $script:Busy = $false; $ButtonBar.IsEnabled = $true; $BtnGo.IsEnabled = $true; $Status.Text = 'Ready.'
        return
    }
    $gpuCount = 0; $cpuCount = 0
    foreach ($u in $found) {
        $cls = $u.DriverClass; $man = $u.DriverManufacturer; $when = $u.When; $mb = $u.MB
        if ($cls -match '^Display') { $tag = 'YOUR GPU'; $col = '#A78BFA'; $on = $true; $gpuCount++ }
        elseif (($cls -match 'System|Processor' -or $u.Title -match 'chipset|processor') -and ($man -match $CpuVendor -or $u.Title -match $CpuVendor)) { $tag = 'YOUR CPU / CHIPSET'; $col = '#60A5FA'; $on = $true; $cpuCount++ }
        else { $tag = 'OTHER PART'; $col = '#9A9AAE'; $on = $false }
        $fake = [pscustomobject]@{ Name = $u.Title; Desc = "$cls  -  $man  -  released $when  -  $mb MB"; Level = 'Optional'; Color = '#2E2E38'; Glyph = [string][char]0xE896; Icon = $null }
        $row = New-Row $fake
        $row.Check.IsChecked = $on
        $pb = $row.Card.Child.Children[3]; $pb.Child.Text = $tag; $pb.Child.Foreground = Brush $col; $pb.Background = Brush ('#33' + $col.Substring(1))
        [void]$DrvList.Children.Add($row.Card)
        [void]$DrvRows.Add([pscustomobject]@{ U = $u; Check = $row.Check; Card = $row.Card; Tag = $tag })
    }
    $BtnDrvCheck.IsEnabled = $true
    $script:Busy = $false; $ButtonBar.IsEnabled = $true; $BtnGo.IsEnabled = $true
    $Status.Text = 'Driver check finished - everything is unlocked again.'
    if ($found.Count -eq 0) {
        $DrvStatus.Text = 'No driver updates waiting in Windows Update right now. Windows Update is often a bit behind for graphics cards though - hit the "Get newest ... driver (step by step)" button - it shows you exactly where to click.'
        $TabDrivers.Header = 'My PC and Drivers'
    } else {
        $BtnDrvInstall.IsEnabled = $true
        $DrvStatus.Text = "Update ready! Found $($found.Count) driver update(s): $gpuCount for your GPU, $cpuCount for your CPU/chipset. Your GPU + CPU ones are ticked. Press 'Install selected updates' - it will ask you first. For the very NEWEST graphics driver, also use the 'Get newest ... driver (step by step)' button."
        $TabDrivers.Header = "My PC and Drivers ($($found.Count) updates!)"
    }
}

function Install-DriverUpdates {
    $sel = @($DrvRows | Where-Object { $_.Check.IsChecked -eq $true -and $_.Check.IsEnabled })
    if (-not $sel.Count) { [System.Windows.MessageBox]::Show('Tick at least one update first!', 'Driver updates') | Out-Null; return }
    $list = ($sel | ForEach-Object { "  - $($_.U.Title)" }) -join "`n"
    # ASK
    $a1 = [System.Windows.MessageBox]::Show("Do you want to install these $($sel.Count) driver update(s)?`n`n$list`n`nIf a graphics driver is in there, your screen may go black or flicker for a few seconds. That's normal.", 'Driver updates - step 1 of 2', 'YesNo', 'Question')
    if ($a1 -ne 'Yes') { $DrvStatus.Text = 'Cancelled. Nothing was installed.'; return }
    # CONFIRM
    $a2 = [System.Windows.MessageBox]::Show("Last check - are you SURE?`n`nSave anything you have open first. The app uses your one original backup (or makes it, if this is the first time), then downloads and installs the update(s) now. You might need to restart after.", 'Driver updates - step 2 of 2: CONFIRM', 'YesNo', 'Warning')
    if ($a2 -ne 'Yes') { $DrvStatus.Text = 'Cancelled. Nothing was installed.'; return }

    $BtnDrvInstall.IsEnabled = $false; $BtnDrvCheck.IsEnabled = $false; Set-Busy $true
    $DrvStatus.Text = 'Checking your backup first...'; Pump
    $rp = Use-OriginalBackup
    Update-BackupLabel
    $ok = New-Object System.Collections.Generic.List[string]; $bad = New-Object System.Collections.Generic.List[string]
    $reboot = $false
    $Prog.Minimum = 0; $Prog.Maximum = $sel.Count; $Prog.Value = 0
    foreach ($r in $sel) {
        $u = $r.U
        try {
            $DrvStatus.Text = "Downloading + installing: $($u.Title)... (screen may flicker)"; Pump
            $ir = Invoke-Bg {
                param($id)
                $sess = New-Object -ComObject Microsoft.Update.Session
                $sess.ClientApplicationID = 'PC Debloater'
                $res = $sess.CreateUpdateSearcher().Search("UpdateID='$id'")
                if ($res.Updates.Count -eq 0) { throw 'Windows Update could not find this update anymore (maybe it already installed)' }
                $up = $res.Updates.Item(0)
                if (-not $up.EulaAccepted) { $up.AcceptEula() }
                $col = New-Object -ComObject Microsoft.Update.UpdateColl
                [void]$col.Add($up)
                $dl = $sess.CreateUpdateDownloader(); $dl.Updates = $col; [void]$dl.Download()
                $inst = $sess.CreateUpdateInstaller(); $inst.Updates = $col
                $r = $inst.Install()
                [pscustomobject]@{ Code = [int]$r.GetUpdateResult(0).ResultCode; Reboot = [bool]$r.RebootRequired }
            } @($u.Id) | Select-Object -Last 1
            $code = $ir.Code
            if ($ir.Reboot) { $reboot = $true }
            if ($code -eq 2 -or $code -eq 3) { $ok.Add("[+] $($u.Title)"); $r.Card.Opacity = 0.5; $r.Check.IsChecked = $false; $r.Check.IsEnabled = $false
                $pb = $r.Card.Child.Children[3]; $pb.Child.Text = 'INSTALLED'; $pb.Child.Foreground = Brush '#FFFFFF'; $pb.Background = Brush '#16A34A' }
            else { $bad.Add("[x] $($u.Title): Windows Update said it failed (code $code)") }
        } catch { $bad.Add("[x] $($u.Title): $($_.Exception.Message)") }
        $Prog.Value++; Pump
    }
    $logPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Driver-Update-Log_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm') + '.txt')
    $L = @('==================================================', '        PC DEBLOATER - DRIVER UPDATE LOG', '==================================================',
           "Date: $(Get-Date -Format 'dddd, MMMM d yyyy  h:mm tt')", "CPU:  $($CPU.Name)") + @($GPUs | ForEach-Object { "GPU:  $($_.Name)  (driver was $($_.DriverVersion))" }) +
         @($rp, '', "---------- INSTALLED ($($ok.Count)) ----------") + $(if ($ok.Count) { @($ok) } else { @('(nothing)') }) +
         @('', "---------- FAILED ($($bad.Count)) ----------") + $(if ($bad.Count) { @($bad) } else { @('(nothing failed, nice)') }) +
         @('', 'If something acts weird after a driver update: Start > type "Create a restore point" > System Restore > pick "Before PC Debloater (original)".')
    $L | Out-File -LiteralPath $logPath -Encoding UTF8
    Start-Process notepad.exe -ArgumentList "`"$logPath`""
    $DrvStatus.Text = "Done! Installed $($ok.Count), failed $($bad.Count). Log saved to your Desktop."
    Notify-Done
    $BtnDrvCheck.IsEnabled = $true; Set-Busy $false
    if (@($DrvRows | Where-Object { $_.Check.IsEnabled }).Count) { $BtnDrvInstall.IsEnabled = $true }
    if ($reboot) {
        if ([System.Windows.MessageBox]::Show("Driver update(s) installed! You need to restart to finish.`n`nRestart now?", 'Driver updates', 'YesNo', 'Information') -eq 'Yes') { Restart-Computer -Force }
    }
}
$BtnDrvCheck.Add_Click({ try { Find-DriverUpdates } catch { Set-Busy $false; $BtnDrvCheck.IsEnabled = $true; Report-Error $_ 'Driver check' } })
$BtnDrvInstall.Add_Click({ try { Install-DriverUpdates } catch { Set-Busy $false; $BtnDrvCheck.IsEnabled = $true; Report-Error $_ 'Driver install' } })
$Tabs.Add_SelectionChanged({
    if ($_.OriginalSource -ne $Tabs) { return }
    if ($Tabs.SelectedItem -eq $TabDrivers -and -not $DrvChecked) {
        $Window.Dispatcher.BeginInvoke([action]{ try { Find-DriverUpdates } catch { Set-Busy $false; $BtnDrvCheck.IsEnabled = $true; Report-Error $_ 'Driver check' } }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    }
})

$BtnRec.Add_Click({  foreach ($r in $Rows) { if ($r.Check.IsEnabled) { $r.Check.IsChecked = ($r.Item.Level -eq 'Safe' -and -not $r.Item.Past) } } })
function Set-TabChecks([bool]$on) {
    # ONLY touches the rows in the tab you're looking at (and only the ones your search shows)
    $key = Get-CurrentTabKey
    if (-not $key) { Say "Couldn't tell which tab you're on - nothing changed."; return }
    $n = 0
    if ($key -eq 'Drivers') {
        foreach ($r in $DrvRows) { if ($r.Check.IsEnabled) { $r.Check.IsChecked = $on; $n++ } }
        $label = 'My PC and Drivers'
    } else {
        foreach ($r in $Rows) {
            if ($r.Item.Tab -ne $key) { continue }               # different tab - leave it alone
            if (-not $r.Check.IsEnabled) { continue }            # already deleted etc.
            if ($r.Card.Visibility -ne 'Visible') { continue }   # hidden by your search
            $r.Check.IsChecked = $on; $n++
        }
        $label = $key
    }
    if ($on) { Say "Ticked $n things in $label. Your other tabs didn't change." }
    else     { Say "Unticked $n things in $label. Your other tabs didn't change." }
}
$BtnAll.Add_Click({ Set-TabChecks $true })
$BtnNone.Add_Click({ Set-TabChecks $false })

function Say($t) { $Status.Text = $t; Pump }

# ---------- 6. Doing the actual removing ----------
function Disable-WinFeature([string]$fn) {
    # returns 'removed', 'off' (already off) or 'missing' (not on this Windows)
    $r = Invoke-Bg {
        param($n)
        $f = Get-WindowsOptionalFeature -Online -FeatureName $n -ErrorAction SilentlyContinue
        if (-not $f) { 'missing' }
        elseif ($f.State -eq 'Enabled') { Disable-WindowsOptionalFeature -Online -FeatureName $n -NoRestart -ErrorAction Stop | Out-Null; 'removed' }
        else { 'off' }
    } @($fn)
    return [string]($r | Select-Object -Last 1)
}

function Remove-AppItem($it) {
    $done = @()
    foreach ($p in $it.Packages) {
        Invoke-Bg {
            param($full)
            try   { Remove-AppxPackage -Package $full -AllUsers -ErrorAction Stop }
            catch { Remove-AppxPackage -Package $full -ErrorAction Stop }
        } @($p.PackageFullName) | Out-Null
        $done += "$($p.Name) v$($p.Version)"
        Rec @{ T='App'; Name=$it.Name; PFN=$p.PackageFamilyName; Manifest=(Join-Path ([string]$p.InstallLocation) 'AppxManifest.xml') }
    }
    $blocked = $false
    foreach ($pp in $it.Prov) {
        try {
            Invoke-Bg { param($n) Remove-AppxProvisionedPackage -Online -PackageName $n -ErrorAction Stop | Out-Null } @($pp.PackageName) | Out-Null; $blocked = $true
            if (-not $it.Packages.Count) { Rec @{ T='App'; Name=$it.Name; PFN="$($pp.DisplayName)_$($pp.PublisherId)"; Manifest='' } }
        } catch {}
    }
    $line = "[-] $($it.Name)"
    if ($done.Count) { $line += "   ($($done -join ', '))" }
    if ($blocked) { $line += "   + blocked from reinstalling for new users" }
    $Removed.Add($line)
}

function Test-ProgramStillThere([string]$displayName) {
    return [bool](@(Get-ItemProperty -Path $UninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $displayName }).Count)
}
function Invoke-Uninstall($it) {
    foreach ($e in $it.Entries) {
        $cmd = [string]$e.QuietUninstallString
        if (-not $cmd) { $cmd = [string]$e.UninstallString }
        $cmd = $cmd.Trim()
        if ($cmd -match 'msiexec') { $cmd = ($cmd -replace '/I\{', '/X{') + ' /qb /norestart' }
        elseif ($cmd -notmatch '^"' -and $cmd -match '^(.+?\.exe)(\s.*)?$' -and $matches[1] -match '\s') { $cmd = '"' + $matches[1] + '"' + $matches[2] }   # put quotes around paths with spaces
        $code = Wait-Proc (Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $cmd + '"') -PassThru -WindowStyle Hidden)
        Start-Sleep -Seconds 2
        $still = Test-ProgramStillThere ([string]$e.DisplayName)
        if (-not $still) {
            $Removed.Add("[-] $($e.DisplayName) $($e.DisplayVersion)   (ran its uninstaller)")
        } elseif ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641) {
            $Removed.Add("[-] $($e.DisplayName) $($e.DisplayVersion)   (uninstaller started - if its window is still open, finish it there. May need a restart.)")
        } else {
            throw "Uninstaller for $($e.DisplayName) stopped with code $code and it's still installed (maybe you hit Cancel?)"
        }
        Rec @{ T='Program'; Name=[string]$e.DisplayName; Url=$it.Url }
    }
}

function Disable-Startup($it) {
    $st = $it.Startup
    if (-not (Test-Path -LiteralPath $st.Appr)) { New-Item -Path $st.Appr -Force | Out-Null }
    New-ItemProperty -LiteralPath $st.Appr -Name $st.Name -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -PropertyType Binary -Force -ErrorAction Stop | Out-Null
    Rec @{ T='Startup'; Appr=$st.Appr; Name=$st.Name }
    $Added.Add("[+] Stopped '$($it.Name)' from opening when your PC turns on   (turn back on: Task Manager > Startup apps)")
}

function Optimize-Game($it) {
    foreach ($exe in $it.Exes) {
        Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $exe 'GpuPreference=2;' 'String'
        $leaf = Split-Path $exe -Leaf
        Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$leaf\PerfOptions" 'CpuPriorityClass' 3
    }
    foreach ($id in @($it.Aumids)) {
        if ($id) { Set-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $id 'GpuPreference=2;' 'String' }
    }
    if ($it.Tip) { $Tips.Add("* $($it.Tip)") }
}

function Clear-Junk {
    $n = 0; $bytes = 0; $c = 0
    $mine = $PSScriptRoot
    foreach ($d in @($env:TEMP, "$env:SystemRoot\Temp", "$env:LOCALAPPDATA\CrashDumps", "$env:SystemRoot\SoftwareDistribution\Download")) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            $c++; if ($c % 150 -eq 0) { Pump }
            if ($mine -and $f.FullName.StartsWith($mine, [StringComparison]::OrdinalIgnoreCase)) { continue }   # never delete this app's own files
            $len = $f.Length
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++; $bytes += $len } catch {}
        }
        foreach ($sub in @(Get-ChildItem -LiteralPath $d -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
            try { [IO.Directory]::Delete($sub.FullName, $false) } catch {}
        }
    }
    $Removed.Add(("[-] Junk + temp files: {0} files deleted, {1:N0} MB freed (files in use were skipped)" -f $n, ($bytes / 1MB)))
}

# ---------- One backup only: "how your PC was before PC Debloater touched it" ----------
$OriginalRPLabel = 'Before PC Debloater (original)'
$OriginalRPFile  = Join-Path $DataDir 'original-restore-point.txt'
function Get-OriginalBackupInfo {
    # returns $null if we never made it, otherwise the date we made it
    if (-not (Test-Path -LiteralPath $OriginalRPFile)) { return $null }
    try { return (Get-Content -LiteralPath $OriginalRPFile -Raw).Trim() } catch { return 'earlier' }
}
function Use-OriginalBackup {
    # Makes the ONE original restore point the first time. After that it never makes another one,
    # unless Windows deleted the original by itself (then you'd have no backup at all).
    $made = Get-OriginalBackupInfo
    if ($made) {
        $still = $false
        try {
            $found = @(Invoke-Bg { param($l) Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object { $_.Description -eq $l } | ForEach-Object { $_.Description } } @($OriginalRPLabel))
            $still = [bool]$found.Count
        } catch { $still = $true }   # if we can't check, assume it's still there (never make extra ones)
        if ($still) { return "Backup: using your original restore point '$OriginalRPLabel' from $made (how your PC was before PC Debloater). No new restore point made." }
        $r = New-RestorePoint $OriginalRPLabel
        if ($r -notlike '*FAILED*') {
            try { (Get-Date -Format 'MMM d, yyyy h:mm tt') | Out-File -LiteralPath $OriginalRPFile -Encoding UTF8 } catch {}
            return "Backup: Windows had deleted your old original restore point by itself, so a new one was made: '$OriginalRPLabel'."
        }
        return $r
    }
    $r = New-RestorePoint $OriginalRPLabel
    if ($r -notlike '*FAILED*') {
        try {
            if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
            (Get-Date -Format 'MMM d, yyyy h:mm tt') | Out-File -LiteralPath $OriginalRPFile -Encoding UTF8
        } catch {}
        return "Backup: made your ONE original restore point '$OriginalRPLabel' (how your PC is right now). It gets reused from now on - no more restore points."
    }
    return $r
}
function Update-BackupLabel {
    $made = Get-OriginalBackupInfo
    if ($made) { $ChkRestoreText.Text = "Use my original backup from $made (no new restore points)" }
    else       { $ChkRestoreText.Text = 'Make a backup of how my PC is now (only once, the first time)' }
}

function New-RestorePoint([string]$Label) {
    try {
        Invoke-Bg {
            param($lbl)
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
            Checkpoint-Computer -Description $lbl -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        } @($Label) | Out-Null
        return "Backup: restore point '$Label' was made."
    } catch {
        return "Backup: FAILED to make a restore point ($_)"
    }
}

$BtnRP.Add_Click({ try {
    Set-Busy $true
    Say 'Making a restore point... this can take a minute.'
    $label = 'PC Debloater backup ' + (Get-Date -Format 'MMM d h-mm tt')
    $r = New-RestorePoint $label
    Set-Busy $false
    if ($r -like '*FAILED*') {
        Say 'Restore point failed.'
        [System.Windows.MessageBox]::Show("Couldn't make a restore point.`n`n$r`n`nTip: Start > type 'Create a restore point' > pick C: > Configure > Turn on system protection.", 'PC Debloater', 'OK', 'Error') | Out-Null
    } else {
        Say "Restore point made: $label"
        [System.Windows.MessageBox]::Show("Restore point made!`n`nName: $label`n`nTo go back to it: Start > type 'Create a restore point' > System Restore.", 'PC Debloater', 'OK', 'Information') | Out-Null
    }
} catch { Set-Busy $false; Report-Error $_ 'Restore point' } })

function Start-Debloat {
    param([switch]$NoAsk)
    $picked = @($Rows | Where-Object { $_.Check.IsChecked -eq $true -and $_.Check.IsEnabled })
    if ($picked.Count -eq 0) { [System.Windows.MessageBox]::Show('Tick at least one thing first!', 'PC Debloater') | Out-Null; return }

    $msg = "About to remove/change $($picked.Count) things."
    $careful = @($picked | Where-Object { $_.Item.Level -eq 'Careful' })
    if ($careful.Count) { $msg += "`n`nHeads up! You picked some CAREFUL ones:`n  - " + (($careful | ForEach-Object { $_.Item.Name }) -join "`n  - ") }
    $msg += "`n`nLet's go?  (Tip: hit No, then 'Preview' to see every detail first)"
    if (-not $NoAsk) { if ([System.Windows.MessageBox]::Show($msg, 'PC Debloater', 'YesNo', 'Warning') -ne 'Yes') { return } }

    Save-LastPicks $picked
    Set-Busy $true
    $Removed.Clear(); $Added.Clear(); $Failed.Clear(); $Notes.Clear(); $Tips.Clear(); $History.Clear()
    $script:RunStamp = Get-Date -Format 'MMM d, yyyy h:mm tt'
    $Prog.Minimum = 0; $Prog.Maximum = $picked.Count + 1; $Prog.Value = 0

    if ($ChkRestore.IsChecked) {
        if (Get-OriginalBackupInfo) { Say 'Checking your original backup is still there...' } else { Say 'Making your one-time backup (restore point)... this can take a minute.' }
        $Notes.Add((Use-OriginalBackup))
        Update-BackupLabel
    } else { $Notes.Add('Backup: you turned the backup off for this run.') }
    $Prog.Value = 1; Pump

    foreach ($r in $picked) {
        $it = $r.Item
        $script:Group = $it.Name
        Say "Working on: $($it.Name)..."
        $idx = -1
        try {
            switch ($it.Kind) {
                'App'   { Remove-AppItem $it }
                'Uninstall' { Invoke-Uninstall $it }
                'Startup' { Disable-Startup $it }
                'Win32' {
                    $idx = $Added.Count; $Added.Add("[+] Settings changed while removing $($it.Name)")
                    & $it.Action
                    if ($Added.Count -eq $idx + 1) { $Added.RemoveAt($idx) }
                    $idx = -1
                    $Removed.Add("[-] $($it.Name)")
                    Rec @{ T='Win32'; Name=$it.Name }
                }
                'Tweak' { $idx = $Added.Count; $Added.Add("[+] $($it.Name)"); & $it.Action }
                'Game'  { $idx = $Added.Count; $Added.Add("[+] FPS boost for $($it.Name)"); Optimize-Game $it }
                'Clean' { Clear-Junk }
            }
            $tag = $null
            if ($it.Kind -in 'App','Win32','Uninstall') { $tag = 'DELETED'; $r.Card.Opacity = 0.5; $r.Check.IsEnabled = $false }
            elseif ($it.Kind -eq 'Startup') { $tag = 'TWEAKED'; $r.Card.Opacity = 0.5; $r.Check.IsEnabled = $false }
            elseif (@($History | Where-Object { $_.G -eq $it.Name }).Count) { $tag = 'TWEAKED'; $r.Card.Opacity = 0.75 }
            if ($tag) {
                $r.Check.IsChecked = $false
                $pillBox = $r.Card.Child.Children[3]
                $pillBox.Child.Text = $tag; $pillBox.Child.Foreground = Brush '#FFFFFF'
                if ($tag -eq 'DELETED') { $pillBox.Background = Brush '#DC2626' } else { $pillBox.Background = Brush '#16A34A' }
            }
        } catch {
            if ($idx -ge 0) { $Added[$idx] = "[!] $($it.Name)   (only partly done - see FAILED)" }
            $Failed.Add("[x] $($it.Name): $($_.Exception.Message)")
        }
        $Prog.Value++; Pump
    }

    # ---------- 7. Write the log file ----------
    Say 'Writing your log file...'
    $kept = @($Rows | Where-Object { $_.Check.IsEnabled -and -not ($picked -contains $_) } | ForEach-Object { "[=] $($_.Item.Name)" })
    $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
    $logPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "Debloat-Log_$stamp.txt"

    $removedCount = $Removed.Count
    $changedCount = @($Added | Where-Object { $_ -match '^\[' }).Count
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('==================================================')
    $L.Add('              PC DEBLOATER - LOG FILE')
    $L.Add('==================================================')
    $L.Add("Date:     $(Get-Date -Format 'dddd, MMMM d yyyy  h:mm tt')")
    $L.Add("PC:       $env:COMPUTERNAME   ($os)")
    $L.Add("App:      $AppName v$AppVersion")
    foreach ($n in $Notes) { $L.Add($n) }
    $L.Add('')
    $L.Add("---------- REMOVED ($removedCount) ----------")
    if ($Removed.Count) { foreach ($x in $Removed) { $L.Add($x) } } else { $L.Add('(nothing)') }
    $L.Add('')
    $L.Add("---------- ADDED / CHANGED SETTINGS ($changedCount) ----------")
    $L.Add('(the "was:" part is what it used to be, in case you want it back)')
    if ($Added.Count) { foreach ($x in $Added) { $L.Add($x) } } else { $L.Add('(nothing)') }
    $L.Add('')
    $L.Add("---------- FAILED ($($Failed.Count)) ----------")
    if ($Failed.Count) { foreach ($x in $Failed) { $L.Add($x) } } else { $L.Add('(nothing failed, nice)') }
    $L.Add('')
    $L.Add("---------- KEPT - you said don't touch these ($($kept.Count)) ----------")
    if ($kept.Count) { foreach ($x in $kept) { $L.Add($x) } } else { $L.Add('(nothing)') }
    $L.Add('')
    if (@($picked | Where-Object { $_.Item.Tab -eq 'Wi-Fi & Ethernet' }).Count) {
        $Tips.Add('* Wi-Fi: the BIGGEST boost is free - get closer to the router, keep it up high and out in the open, restart it every week or two.')
        $Tips.Add('* Wi-Fi: for gaming an ethernet cable beats every Wi-Fi tweak. Even a long cheap one.')
        $Tips.Add('* Ethernet: use a Cat5e or Cat6 cable, plug straight into the router (not a cheap switch or a powerline adapter if you can avoid it).')
        $Tips.Add('* Wi-Fi: undo the DNS change in Settings > Network and internet > your Wi-Fi > DNS server assignment > Automatic.')
    }
    if ($Tips.Count) {
        $L.Add('---------- TIPS FOR YOUR GAMES + INTERNET ----------')
        foreach ($x in $Tips) { $L.Add($x) }
        $L.Add('')
    }
    $L.Add('---------- HOW TO UNDO ----------')
    $L.Add("Everything at once: Start > type 'Create a restore point' > System Restore > pick 'Before PC Debloater (original)'.")
    $L.Add('Want one app back: open the Microsoft Store, search it, install it again.')
    $L.Add('Want OneDrive back: download it from microsoft.com/onedrive.')
    $L.Add('EASIEST: open PC Debloater again and press "Reinstall / Undo" - tick what you want back.')
    $L.Add('Want a startup app back: Ctrl+Shift+Esc > Startup apps > right-click it > Enable.')
    $L.Add('Want a program back (Norton, Office, etc): download it again from their website.')
    $L.Add('Some changes only kick in after you restart your PC.')
    $L | Out-File -LiteralPath $logPath -Encoding UTF8
    try { if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }; Copy-Item -LiteralPath $logPath -Destination $LogDir -Force } catch {}
    try { Save-History (@(Load-History) + @($History)) } catch { $Failed.Add("[x] Couldn't save the undo history: $($_.Exception.Message)") }

    Start-Process notepad.exe -ArgumentList "`"$logPath`""
    Say "Done! Removed $removedCount, changed $changedCount, failed $($Failed.Count). Log saved to your Desktop."
    Set-Busy $false
    Update-Count

    Notify-Done
    $ans = [System.Windows.MessageBox]::Show("All done!`n`nRemoved: $removedCount`nSettings changed: $changedCount`nFailed: $($Failed.Count)`n`nYour log is on the Desktop:`n$([IO.Path]::GetFileName($logPath))`n`nRestart now so everything kicks in?", 'PC Debloater', 'YesNo', 'Information')
    if ($ans -eq 'Yes') { Restart-Computer -Force }
}

$BtnGo.Add_Click({
    try { Start-Debloat }
    catch { Set-Busy $false; Report-Error $_ 'Debloat' }
})


# ---------- 8. Reinstall / Undo window ----------
function Get-Winget {
    $w = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}
function Invoke-Winget([string]$Id) {
    $wg = Get-Winget
    if (-not $wg) { return $false }
    $code = Wait-Proc (Start-Process -FilePath $wg -ArgumentList "install --id $Id -e --silent --accept-package-agreements --accept-source-agreements" -PassThru -WindowStyle Hidden)
    return ($code -eq 0)
}

function Restore-Entry($e) {
    switch ($e.T) {
        'Reg' {
            if ($e.Existed) {
                $kind = $e.Kind; if (-not $kind) { $kind = 'DWord' }
                $v = $e.Old
                if ($kind -eq 'Binary') { $v = [byte[]]@($v) } elseif ($kind -eq 'MultiString') { $v = [string[]]@($v) }
                if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $v -PropertyType $kind -Force -ErrorAction Stop | Out-Null
                return "$($e.Path)\$($e.Name) put back to $($e.Old)"
            } else {
                Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                return "$($e.Path)\$($e.Name) removed (back to Windows default)"
            }
        }
        'RegKey'       { Remove-Item -LiteralPath $e.Path -Recurse -Force -ErrorAction SilentlyContinue; return "Removed key $($e.Path)" }
        'Svc' {
            $t = $e.Old; if ($t -notin 'Automatic','Manual','Disabled') { $t = 'Manual' }
            Set-Service -Name $e.Name -StartupType $t -ErrorAction Stop
            if ($t -eq 'Automatic') { Start-Service -Name $e.Name -ErrorAction SilentlyContinue }
            return "Service $($e.Name) startup = $t"
        }
        'Task'         { Enable-ScheduledTask -TaskPath $e.Path -TaskName $e.Name -ErrorAction Stop | Out-Null; return "Task $($e.Path)$($e.Name) turned back on" }
        'Feature'      { Invoke-Bg { param($n) Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart -ErrorAction Stop | Out-Null } @($e.Name) | Out-Null; return "Windows feature $($e.Name) turned back on" }
        'Cap'          { Invoke-Bg { param($n) Add-WindowsCapability -Online -Name $n -ErrorAction Stop | Out-Null } @($e.Name) | Out-Null; return "Windows extra $($e.Name) installed again" }
        'Power'        { powercfg /setactive $e.Old | Out-Null; return "Power plan switched back" }
        'AdapterProp'  { Set-NetAdapterAdvancedProperty -Name $e.Adapter -DisplayName $e.Prop -DisplayValue $e.Old -ErrorAction Stop; return "$($e.Adapter): '$($e.Prop)' = $($e.Old)" }
        'AdapterPower' { Set-NetAdapterPowerManagement -Name $e.Adapter -AllowComputerToTurnOffDevice Enabled -ErrorAction SilentlyContinue; return "$($e.Adapter): power saving back on" }
        'Autotune'     { netsh int tcp set global "autotuninglevel=$($e.Old)" | Out-Null; return "TCP auto-tuning = $($e.Old)" }
        'Dns'          { Set-DnsClientServerAddress -InterfaceIndex $e.Index -ResetServerAddresses -ErrorAction Stop; return "$($e.Name): DNS back to automatic" }
        'Metric' {
            if ($e.Auto -eq 'Enabled') { Set-NetIPInterface -InterfaceIndex $e.Index -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction Stop }
            else { Set-NetIPInterface -InterfaceIndex $e.Index -AddressFamily IPv4 -InterfaceMetric $e.Old -ErrorAction Stop }
            return "Network priority put back"
        }
        'Hiber'        { powercfg /h on | Out-Null; return "Hibernation back on" }
        'SchedTask'    { Unregister-ScheduledTask -TaskName $e.Name -Confirm:$false -ErrorAction SilentlyContinue; return "Removed the sign-in check" }
        'Startup' {
            if (-not (Test-Path -LiteralPath $e.Appr)) { New-Item -Path $e.Appr -Force | Out-Null }
            New-ItemProperty -LiteralPath $e.Appr -Name $e.Name -Value ([byte[]](2,0,0,0,0,0,0,0,0,0,0,0)) -PropertyType Binary -Force -ErrorAction Stop | Out-Null
            return "Startup app '$($e.Name)' turned back on"
        }
        'App' {
            if ($e.Manifest -and (Test-Path -LiteralPath $e.Manifest)) {
                try { Invoke-Bg { param($m) Add-AppxPackage -DisableDevelopmentMode -Register $m -ErrorAction Stop } @($e.Manifest) | Out-Null; return "$($e.Name) reinstalled" } catch {}
            }
            Start-Process "ms-windows-store://pdp/?PFN=$($e.PFN)"
            return "$($e.Name): opened its Microsoft Store page - click Get / Install"
        }
        'Win32' {
            if ($e.Name -eq 'OneDrive') {
                $setup = @("$env:SystemRoot\System32\OneDriveSetup.exe","$env:SystemRoot\SysWOW64\OneDriveSetup.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($setup) { [void](Wait-Proc (Start-Process -FilePath $setup -PassThru)); return 'OneDrive reinstalled' }
                if (Invoke-Winget 'Microsoft.OneDrive') { return 'OneDrive reinstalled' }
                Start-Process 'https://www.microsoft.com/microsoft-365/onedrive/download'; return 'OneDrive: opened the download page'
            }
            if ($e.Name -eq 'Microsoft Edge') {
                Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -ErrorAction SilentlyContinue
                Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' -Name 'DoNotUpdateToEdgeWithChromium' -ErrorAction SilentlyContinue
                if (Invoke-Winget 'Microsoft.Edge') { return 'Microsoft Edge reinstalled' }
                Start-Process 'https://www.microsoft.com/edge/download'; return 'Microsoft Edge: opened the download page'
            }
            return "$($e.Name): nothing to do"
        }
        'Program' {
            if ($e.Url) { Start-Process $e.Url; return "$($e.Name): opened their website so you can download it" }
            return "$($e.Name): no download link (it was pre-installed junk)"
        }
        default { return "Skipped unknown change type $($e.T)" }
    }
}

function Show-UndoWindow {
    $hist = @(Load-History)
    if ($hist.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Nothing to bring back yet!`n`nOnce you debloat with this app, everything it removes or changes shows up here so you can undo it.", 'Reinstall / Undo', 'OK', 'Information') | Out-Null
        return
    }
    [xml]$ux = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Reinstall / Undo" Width="760" Height="640" WindowStartupLocation="CenterOwner" Background="#16161C" FontFamily="Segoe UI">
  $StyleXml
  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock Text="Reinstall / Undo" FontSize="26" FontWeight="Bold" Foreground="White"/>
      <TextBlock Text="Everything PC Debloater removed or changed. Tick what you want back." Foreground="#A0A0B0" FontSize="13" Margin="0,4,0,0"/>
    </StackPanel>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="UList" Margin="0,0,8,0"/></ScrollViewer>
    <StackPanel Grid.Row="2" Margin="0,12,0,0">
      <WrapPanel x:Name="UBar">
        <Button x:Name="UAll" Content="Select all" Margin="0,0,8,8"/>
        <Button x:Name="UNone" Content="Select none" Margin="0,0,8,8"/>
      </WrapPanel>
      <Grid>
        <TextBlock x:Name="UStatus" Text="Ready." Foreground="#A0A0B0" FontSize="13" VerticalAlignment="Center"/>
        <Button x:Name="UGo" Content="Bring back selected" HorizontalAlignment="Right" Background="#2563EB" FontSize="16" FontWeight="Bold" MinWidth="220"/>
      </Grid>
    </StackPanel>
  </Grid>
</Window>
"@
    $script:uw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $ux))
    $uw.Owner = $Window
    $UList = $uw.FindName('UList'); $script:UStatus = $uw.FindName('UStatus'); $script:UGo = $uw.FindName('UGo')

    # group the history by the thing that caused it
    $groups = @($hist | Group-Object -Property G)
    $cats = [ordered]@{ 'Apps you removed' = @(); 'Programs you removed' = @(); 'Startup apps you turned off' = @(); 'Settings you changed' = @() }
    foreach ($g in $groups) {
        $types = @($g.Group | ForEach-Object { $_.T })
        if ($types -contains 'App') { $c = 'Apps you removed'; $how = 'Comes back from the Microsoft Store'; $pill = 'REINSTALL'; $col = '#3B82F6' }
        elseif ($types -contains 'Win32' -or $types -contains 'Program') { $c = 'Programs you removed'; $how = 'Downloads it again (or opens its website)'; $pill = 'REINSTALL'; $col = '#F97316' }
        elseif ($types -contains 'Startup') { $c = 'Startup apps you turned off'; $how = 'Opens with your PC again'; $pill = 'TURN BACK ON'; $col = '#8B5CF6' }
        else { $c = 'Settings you changed'; $how = "$($g.Count) changes go back to how they were"; $pill = 'UNDO'; $col = '#10B981' }
        $when = ($g.Group | Select-Object -Last 1).When
        $cats[$c] += [pscustomobject]@{ Name = $g.Name; How = "$how  -  changed $when"; Pill = $pill; Color = $col; Entries = @($g.Group) }
    }

    $script:URows = New-Object System.Collections.ArrayList
    foreach ($c in $cats.Keys) {
        if (-not $cats[$c].Count) { continue }
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = $c; $h.Foreground = Brush '#C9C9D6'; $h.FontSize = 14; $h.FontWeight = [System.Windows.FontWeights]::SemiBold; $h.Margin = Th 2 10 0 8
        [void]$UList.Children.Add($h)
        foreach ($u in $cats[$c]) {
            $fake = [pscustomobject]@{ Name = $u.Name; Desc = $u.How; Level = 'Optional'; Color = $u.Color; Glyph = [string][char]0xE7A7; Icon = $null }
            $row = New-Row $fake
            $row.Check.IsChecked = $false
            ($row.Card.Child.Children[3]).Child.Text = $u.Pill
            ($row.Card.Child.Children[3]).Child.Foreground = Brush $u.Color
            ($row.Card.Child.Children[3]).Background = Brush ('#33' + $u.Color.Substring(1))
            [void]$UList.Children.Add($row.Card)
            [void]$URows.Add([pscustomobject]@{ U = $u; Check = $row.Check; Card = $row.Card })
        }
    }
    $uw.FindName('UAll').Add_Click({ foreach ($r in $URows) { if ($r.Check.IsEnabled) { $r.Check.IsChecked = $true } } })
    $uw.FindName('UNone').Add_Click({ foreach ($r in $URows) { $r.Check.IsChecked = $false } })

    $UGo.Add_Click({ try {
        $sel = @($URows | Where-Object { $_.Check.IsChecked -eq $true -and $_.Check.IsEnabled })
        if (-not $sel.Count) { [System.Windows.MessageBox]::Show('Tick something first!', 'Reinstall / Undo') | Out-Null; return }
        if ([System.Windows.MessageBox]::Show("Bring back $($sel.Count) things?`n`nStore apps open their Microsoft Store page - just click Get.", 'Reinstall / Undo', 'YesNo', 'Question') -ne 'Yes') { return }
        $UGo.IsEnabled = $false
        $script:Busy = $true
        $failedRows = 0
        $done = New-Object System.Collections.Generic.List[string]
        $bad  = New-Object System.Collections.Generic.List[string]
        $fixed = New-Object System.Collections.ArrayList
        $seenPfn = @{}
        foreach ($r in $sel) {
            $UStatus.Text = "Bringing back: $($r.U.Name)..."
            Pump
            $done.Add("[+] $($r.U.Name)")
            $ok = $true
            # settings first (newest change first), then reinstall stuff last
            $es = @($r.U.Entries); [array]::Reverse($es)
            $order = @($es | Where-Object { $_.T -notin 'App','Win32','Program' }) + @($es | Where-Object { $_.T -in 'App','Win32','Program' })
            foreach ($e in $order) {
                if ($e.T -eq 'App') { if ($seenPfn[$e.PFN]) { [void]$fixed.Add($e); continue }; $seenPfn[$e.PFN] = $true }
                try { $done.Add("      " + (Restore-Entry $e)); [void]$fixed.Add($e) }
                catch { $ok = $false; $bad.Add("[x] $($r.U.Name): $($_.Exception.Message)") }
            }
            if ($ok) { $r.Card.Opacity = 0.35; $r.Check.IsChecked = $false; $r.Check.IsEnabled = $false } else { $failedRows++ }
        }
        # forget what we fixed, keep the rest
        $left = @(Load-History | Where-Object { $x = $_; -not @($fixed | Where-Object { ($_ | ConvertTo-Json -Compress) -eq ($x | ConvertTo-Json -Compress) }).Count })
        try { Save-History $left } catch {}

        $logPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Reinstall-Log_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm') + '.txt')
        $L = @('==================================================', '        PC DEBLOATER - REINSTALL / UNDO LOG', '==================================================',
               "Date: $(Get-Date -Format 'dddd, MMMM d yyyy  h:mm tt')", '', "---------- BROUGHT BACK ----------") + @($done) +
             @('', "---------- FAILED ($($bad.Count)) ----------") + $(if ($bad.Count) { @($bad) } else { @('(nothing failed, nice)') }) +
             @('', 'Some things only come back fully after you restart your PC.', 'Store apps: if a Store page opened, click Get / Install on it.')
        $L | Out-File -LiteralPath $logPath -Encoding UTF8
        Start-Process notepad.exe -ArgumentList "`"$logPath`""
        $UStatus.Text = "Done! Brought back $($sel.Count - $failedRows), had problems with $failedRows. Log saved to your Desktop."
        $UGo.IsEnabled = $true
        $script:Busy = $false
        [System.Windows.MessageBox]::Show("Done!`n`nRestart your PC so everything comes back properly.`n(Close and reopen PC Debloater to see the brought-back apps in the main list.)", 'Reinstall / Undo', 'OK', 'Information') | Out-Null
    } catch { $script:Busy = $false; $UGo.IsEnabled = $true; Report-Error $_ 'Bring back selected' } })

    $uw.Add_Closing({ if ($script:Busy) { $_.Cancel = $true; [System.Windows.MessageBox]::Show('Still working - please wait until it finishes!', 'Reinstall / Undo', 'OK', 'Warning') | Out-Null } })
    [void]$uw.ShowDialog()
}
$BtnUndo.Add_Click({ try { Show-UndoWindow } catch { Set-Busy $false; Report-Error $_ 'Reinstall / Undo' } })


# ---------- Every-tab buttons ----------
function Set-AllChecks([bool]$on) {
    $vis = @(); foreach ($r in $Rows) { if ($r.Check.IsEnabled -and $r.Card.Visibility -eq 'Visible') { $vis += $r } }
    if ($on) {
        $careful = @($vis | Where-Object { $_.Item.Level -eq 'Careful' })
        if ($careful.Count) {
            $a = [System.Windows.MessageBox]::Show("This ticks EVERYTHING in every tab - including $($careful.Count) orange CAREFUL ones like:`n`n  - " + (($careful | Select-Object -First 8 | ForEach-Object { $_.Item.Name }) -join "`n  - ") + "`n`nYou can untick the ones you want to keep after. Go?", $AppName, 'YesNo', 'Warning')
            if ($a -ne 'Yes') { return }
        }
    }
    foreach ($r in $vis) { $r.Check.IsChecked = $on }
    $extra = ''; if ($Search.Text.Trim()) { $extra = ' (only what your search shows)' }
    if ($on) { Say "Ticked $($vis.Count) things in every tab$extra." } else { Say "Unticked everything in every tab$extra." }
}
$BtnAllEvery.Add_Click({ Set-AllChecks $true })
$BtnNoneEvery.Add_Click({ Set-AllChecks $false })

# ---------- My last picks ----------
$LastPicksFile = Join-Path $DataDir 'last-picks.json'
function Save-LastPicks($picked) {
    try {
        if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        ConvertTo-Json -InputObject @($picked | ForEach-Object { [string]$_.Item.Name }) | Set-Content -LiteralPath $LastPicksFile -Encoding UTF8
    } catch {}
}
$BtnPLast.Add_Click({
    if (-not (Test-Path -LiteralPath $LastPicksFile)) { Say 'No last picks yet - they get saved the first time you hit Debloat.'; return }
    $names = @()
    try { $names = @(Expand-Items (ConvertFrom-Json (Get-Content -LiteralPath $LastPicksFile -Raw)) | ForEach-Object { [string]$_ }) } catch {}
    $n = 0
    foreach ($r in $Rows) {
        if (-not $r.Check.IsEnabled) { continue }
        $on = $names -contains [string]$r.Item.Name
        $r.Check.IsChecked = $on
        if ($on) { $n++ }
    }
    Say "Ticked $n of your last picks (stuff that's already gone or already done was skipped)."
})

# ---------- Clear search ----------
$BtnClearSearch.Add_Click({ $Search.Text = ''; $Search.Focus() | Out-Null })

# ---------- Keyboard shortcuts ----------
$Window.Add_PreviewKeyDown({
    if ($script:Busy) { return }
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $k = $_.Key
    if ($ctrl -and $k -eq 'F') { $Search.Focus() | Out-Null; $Search.SelectAll(); $_.Handled = $true; return }
    if ($k -eq 'Escape' -and $Search.Text) { $Search.Text = ''; $_.Handled = $true; return }
    if ($ctrl) {
        $map = @{ 'D1' = 0; 'D2' = 1; 'D3' = 2; 'D4' = 3; 'D5' = 4; 'D6' = 5; 'NumPad1' = 0; 'NumPad2' = 1; 'NumPad3' = 2; 'NumPad4' = 3; 'NumPad5' = 4; 'NumPad6' = 5 }
        $ks = [string]$k
        if ($map.ContainsKey($ks) -and $map[$ks] -lt $Tabs.Items.Count) { $Tabs.SelectedIndex = $map[$ks]; $_.Handled = $true }
    }
})

# ---------- Remember window size + spot ----------
$WinFile = Join-Path $DataDir 'window.json'
try {
    if (Test-Path -LiteralPath $WinFile) {
        $w = ConvertFrom-Json (Get-Content -LiteralPath $WinFile -Raw)
        $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
        $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($w.Width -ge 780 -and $w.Height -ge 560 -and $w.Left -ge $vl - 50 -and $w.Top -ge $vt - 50 -and ($w.Left + 200) -le ($vl + $vw) -and ($w.Top + 100) -le ($vt + $vh)) {
            $Window.WindowStartupLocation = 'Manual'
            $Window.Left = $w.Left; $Window.Top = $w.Top; $Window.Width = $w.Width; $Window.Height = $w.Height
            if ($w.Max) { $Window.WindowState = 'Maximized' }
        }
    }
} catch {}
$Window.Add_Closed({
    try {
        if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        $b = $Window.RestoreBounds
        [pscustomobject]@{ Left = $b.Left; Top = $b.Top; Width = $b.Width; Height = $b.Height; Max = ($Window.WindowState -eq 'Maximized') } | ConvertTo-Json | Set-Content -LiteralPath $WinFile -Encoding UTF8
    } catch {}
})

# ---------- Pop to the front + ding when a long job finishes ----------
function Notify-Done {
    try {
        if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
        $Window.Activate() | Out-Null
        $Window.Topmost = $true; $Window.Topmost = $false
        [System.Media.SystemSounds]::Asterisk.Play()
    } catch {}
}

# ---------- 9. About / Help + Preview ----------
$BtnAbout.Add_Click({
    try {
        $hasUrl = $ProjectUrl -notmatch 'YOUR-GITHUB-NAME'
        $btns = @('Open logs folder', 'Close'); if ($hasUrl) { $btns = @('Open logs folder', 'Report a bug', 'Close') }
        $a = Show-Dialog -Owner $Window -Title "About $AppName" -Heading "$AppName v$AppVersion" -Buttons $btns -Lines @(
            'Free + open source Windows debloater, FPS booster and privacy tool.',
            '## How to use it',
            '- Tick what you want gone (or hit a Quick pick), then press Debloat.',
            '- Not sure? Press "Preview (changes nothing)" first to see exactly what will happen.',
            '- Changed your mind later? Press "Reinstall / Undo".',
            '## Shortcuts',
            '- Ctrl+F = search, Esc = clear search, Ctrl+1 to Ctrl+6 = jump between tabs.',
            '- "My last picks" ticks the same stuff you picked last time.',
            '## Where your stuff is saved',
            '- Debloat / undo / driver logs: your Desktop.',
            "- History (for Undo) + error reports: $DataDir",
            '## Found a bug?',
            $(if ($hasUrl) { "- Press Report a bug, or go to $ProjectUrl/issues and attach the error report from your Desktop." } else { '- Send the error report (PC-Debloater-ERROR_....txt on your Desktop) to the person who gave you this app.' }),
            '## Legal',
            '- MIT license, no warranty. Use at your own risk.',
            '- Not made by or connected to Microsoft, NVIDIA, AMD, Intel or any other company it mentions.',
            '- Collects no data. Ever.'
        )
        if ($a -eq 'Open logs folder') { if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }; Start-Process explorer.exe -ArgumentList "`"$DataDir`"" }
        elseif ($a -eq 'Report a bug') { Start-Process "$ProjectUrl/issues" }
    } catch { Report-Error $_ 'About screen' }
})

function Show-Preview {
    $picked = @($Rows | Where-Object { $_.Check.IsChecked -eq $true -and $_.Check.IsEnabled })
    if (-not $picked.Count) { [System.Windows.MessageBox]::Show('Tick at least one thing first!', $AppName) | Out-Null; return }
    $groups = [ordered]@{
        'Will be DELETED' = @($picked | Where-Object { $_.Item.Kind -in 'App','Win32','Uninstall' })
        'Will stop opening when your PC turns on' = @($picked | Where-Object { $_.Item.Kind -eq 'Startup' })
        'Games that get boosted' = @($picked | Where-Object { $_.Item.Kind -eq 'Game' })
        'Settings that get changed' = @($picked | Where-Object { $_.Item.Kind -eq 'Tweak' })
        'Files that get cleaned (can NOT be undone)' = @($picked | Where-Object { $_.Item.Kind -eq 'Clean' })
    }
    $lines = @("Nothing has been changed yet. Here is exactly what Debloat would do with your $($picked.Count) picks:")
    $orig = Get-OriginalBackupInfo
    if (-not $ChkRestore.IsChecked) { $lines += '! Backup is OFF for this run.' }
    elseif ($orig) { $lines += "- Backup: your original restore point from $orig is kept. No new one gets made." }
    else { $lines += "- First: make your ONE backup of how your PC is now ('$OriginalRPLabel'). It gets reused from now on." }
    foreach ($k in $groups.Keys) {
        if (-not $groups[$k].Count) { continue }
        $lines += "## $k ($($groups[$k].Count))"
        foreach ($r in $groups[$k]) {
            $pre = '- '; if ($r.Item.Level -eq 'Careful') { $pre = '! ' }
            $lines += "$pre$($r.Item.Name)  -  $($r.Item.Desc)"
        }
    }
    $slow = @($picked | Where-Object { $_.Item.Name -match 'Deep clean|old unused features|old risky features|Recall' })
    if ($slow.Count) { $lines += '## Heads up'; $lines += '! Some picks are slow (Windows features / update cleanup). It can take 5-15 minutes - let it finish.' }
    $lines += '## After'
    $lines += '- You get a log on your Desktop and can undo most of it with Reinstall / Undo.'
    $a = Show-Dialog -Owner $Window -Title 'Preview' -Heading 'Preview - nothing changed yet' -Lines $lines -Buttons @('Go back', 'Looks good - Debloat now') -Accent '#E5484D'
    if ($a -eq 'Looks good - Debloat now') { Start-Debloat -NoAsk }
}
$BtnPreview.Add_Click({ try { Show-Preview } catch { Set-Busy $false; Report-Error $_ 'Preview / Debloat' } })

# ---------- 10. Show the app ----------
Update-BackupLabel
Update-Count
if ($Splash) { $Splash.Close() }
$PumpWin = $Window
[void]$Window.ShowDialog()
