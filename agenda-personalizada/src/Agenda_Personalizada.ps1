param(
    [switch]$StartHidden
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# O aviso aparece sobre as janelas, sem receber o foco da digitação.
if (-not ('AgendaReminderForm' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing' -TypeDefinition @'
using System;
using System.Windows.Forms;

public sealed class AgendaReminderForm : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            return parameters;
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x0021) // WM_MOUSEACTIVATE, inclusive foco por hover
        {
            message.Result = new IntPtr(3); // MA_NOACTIVATE: preserva o clique
            return;
        }
        base.WndProc(ref message);
    }

    protected override bool ProcessDialogKey(Keys keyData)
    {
        Keys key = keyData & Keys.KeyCode;
        if (key == Keys.Enter || key == Keys.Space) { return true; }
        return base.ProcessDialogKey(keyData);
    }
}

public sealed class AgendaReminderButton : Button
{
    public AgendaReminderButton()
    {
        SetStyle(ControlStyles.Selectable, false);
        TabStop = false;
    }

    public override void NotifyDefault(bool value) { base.NotifyDefault(false); }
}
'@
}

$AppVersion = '8'
$UpdateManifestUrl = 'https://raw.githubusercontent.com/pppaula-dot/ficha-campo-android-updates/main/agenda-personalizada/atualizacao.json'

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = $MyInvocation.MyCommand.Path
$DataFile = Join-Path $AppDir 'agenda_dados.json'
$SettingsFile = Join-Path $AppDir 'agenda_config.json'
$BackupDir = Join-Path $AppDir 'backups'
$OpenSignal = Join-Path $AppDir '.abrir_agenda.sinal'
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

# Impede duas agendas abertas ao mesmo tempo. Se já houver uma, pede para a existente aparecer.
$createdNew = $false
$script:InstanceMutex = New-Object System.Threading.Mutex($true, 'AgendaPersonalizada_UnicaInstancia', [ref]$createdNew)
if (-not $createdNew) {
    try { Set-Content -Path $OpenSignal -Value (Get-Date).ToString('o') -Encoding UTF8 -Force } catch {}
    exit
}

$script:Tasks = @()
$script:MainForm = $null
$script:ListToday = $null
$script:ListUpcoming = $null
$script:ListDone = $null
$script:StatusLabel = $null
$script:TrayIcon = $null
$script:Timer = $null
$script:ExitRequested = $false
$script:HideNoticeShown = $false
$script:OpenReminderIds = New-Object 'System.Collections.Generic.HashSet[string]'
$script:PauseUntil = $null
$script:PauseIndefinitely = $false

$script:Theme = @{
    Background = [System.Drawing.ColorTranslator]::FromHtml('#E8EDF4')
    Surface = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    SurfaceAlt = [System.Drawing.ColorTranslator]::FromHtml('#EEF2F7')
    Text = [System.Drawing.ColorTranslator]::FromHtml('#111827')
    Muted = [System.Drawing.ColorTranslator]::FromHtml('#475467')
    Border = [System.Drawing.ColorTranslator]::FromHtml('#AEB9C7')
    Primary = [System.Drawing.ColorTranslator]::FromHtml('#245BD7')
    PrimaryDark = [System.Drawing.ColorTranslator]::FromHtml('#1847B7')
    PrimarySoft = [System.Drawing.ColorTranslator]::FromHtml('#DDE8FB')
    SuccessSoft = [System.Drawing.ColorTranslator]::FromHtml('#ECFDF3')
    SuccessText = [System.Drawing.ColorTranslator]::FromHtml('#147D4F')
    DangerSoft = [System.Drawing.ColorTranslator]::FromHtml('#FFF2F1')
    DangerText = [System.Drawing.ColorTranslator]::FromHtml('#B42318')
    Shadow = [System.Drawing.ColorTranslator]::FromHtml('#BAC5D3')
}

function Set-RoundedRegion([System.Windows.Forms.Control]$control, [int]$radius = 8) {
    if ($null -eq $control -or $control.Width -le 2 -or $control.Height -le 2) { return }
    try {
        $diameter = $radius * 2
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
        $path.AddArc($control.Width - $diameter - 1, 0, $diameter, $diameter, 270, 90)
        $path.AddArc($control.Width - $diameter - 1, $control.Height - $diameter - 1, $diameter, $diameter, 0, 90)
        $path.AddArc(0, $control.Height - $diameter - 1, $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        if ($null -ne $control.Region) { $control.Region.Dispose() }
        $control.Region = New-Object System.Drawing.Region($path)
        $path.Dispose()
    } catch {}
}

function Set-ModernButton([System.Windows.Forms.Button]$button) {
    if ($null -eq $button) { return }
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 2
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.UseVisualStyleBackColor = $false
    $button.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)

    $text = ([string]$button.Text).Trim()
    if ($text -in @('Novo agendamento','Salvar tarefa','Salvar','Buscar')) {
        $button.BackColor = $script:Theme.Primary
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderColor = $script:Theme.PrimaryDark
        $button.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
        $button.FlatAppearance.MouseOverBackColor = $script:Theme.PrimaryDark
        $button.FlatAppearance.MouseDownBackColor = $script:Theme.PrimaryDark
    } elseif ($text -eq 'Concluir' -and $button -isnot [AgendaReminderButton]) {
        $button.BackColor = $script:Theme.SuccessSoft
        $button.ForeColor = $script:Theme.SuccessText
        $button.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#B7E5CD')
        $button.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#DCF8E9')
    } elseif ($text -eq 'Excluir') {
        $button.BackColor = $script:Theme.DangerSoft
        $button.ForeColor = $script:Theme.DangerText
        $button.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#F5C2BE')
        $button.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFE4E1')
    } else {
        $button.BackColor = $script:Theme.SurfaceAlt
        $button.ForeColor = $script:Theme.Text
        $button.FlatAppearance.BorderColor = $script:Theme.Border
        $button.FlatAppearance.MouseOverBackColor = $script:Theme.PrimarySoft
        $button.FlatAppearance.MouseDownBackColor = [System.Drawing.ColorTranslator]::FromHtml('#DCE8FF')
    }
    Set-RoundedRegion $button 8
    $button.Add_SizeChanged({ param($sender,$e) Set-RoundedRegion $sender 8 })
}

function Apply-ModernFormStyle([System.Windows.Forms.Form]$root) {
    if ($null -eq $root) { return }
    $root.BackColor = $script:Theme.Background
    $root.ForeColor = $script:Theme.Text
    $root.Font = New-Object System.Drawing.Font('Segoe UI',9)

    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $parent = $stack.Pop()
        foreach ($c in $parent.Controls) {
            if ($c -is [System.Windows.Forms.Button]) {
                Set-ModernButton $c
            } elseif ($c -is [System.Windows.Forms.TextBox]) {
                $c.BackColor = $script:Theme.Surface
                $c.ForeColor = $script:Theme.Text
                $c.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            } elseif ($c -is [System.Windows.Forms.ListView]) {
                $c.BackColor = $script:Theme.Surface
                $c.ForeColor = $script:Theme.Text
                $c.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                $c.GridLines = $false
            } elseif ($c -is [System.Windows.Forms.TabPage]) {
                $c.BackColor = $script:Theme.Surface
                $c.ForeColor = $script:Theme.Text
            } elseif ($c -is [System.Windows.Forms.GroupBox]) {
                $c.BackColor = $script:Theme.Surface
                $c.ForeColor = $script:Theme.Text
                $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            } elseif ($c -is [System.Windows.Forms.Panel]) {
                if ($c.Name -ne 'shadow') { $c.BackColor = $script:Theme.Background }
            } elseif ($c -is [System.Windows.Forms.Label]) {
                if ($c.ForeColor -eq [System.Drawing.Color]::ControlText) { $c.ForeColor = $script:Theme.Text }
            }
            if ($c.HasChildren) { $stack.Push($c) }
        }
    }
}

function Show-AboutDialog {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Sobre a Agenda'
    $f.Size = New-Object System.Drawing.Size(500,280)
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Agenda Personalizada'
    $title.Font = New-Object System.Drawing.Font('Segoe UI',18,[System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(28,28); $title.AutoSize = $true
    $f.Controls.Add($title)

    $ver = New-Object System.Windows.Forms.Label
    $ver.Text = "Versão $AppVersion"
    $ver.Location = New-Object System.Drawing.Point(31,70); $ver.AutoSize = $true; $ver.ForeColor = $script:Theme.Muted
    $f.Controls.Add($ver)

    $copy = New-Object System.Windows.Forms.Label
    $copy.Text = '© 2026 @paulapmiranda — Uso restrito. Reprodução e distribuição não autorizadas.'
    $copy.Location = New-Object System.Drawing.Point(31,112); $copy.Size = New-Object System.Drawing.Size(420,55)
    $copy.ForeColor = $script:Theme.Muted
    $f.Controls.Add($copy)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Fechar'; $ok.Location = New-Object System.Drawing.Point(330,185); $ok.Size = New-Object System.Drawing.Size(120,38)
    $ok.Add_Click({ $f.Close() })
    $f.Controls.Add($ok)

    Apply-ModernFormStyle $f
    [void]$f.ShowDialog($script:MainForm)
    $f.Dispose()
}

function Convert-ToDateTime([object]$value) {
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
    try { return [datetime]::Parse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
    catch { try { return [datetime]$value } catch { return $null } }
}

function Try-AutoMigrateData {
    if (Test-Path $DataFile) { return }

    try {
        $roots = New-Object System.Collections.Generic.List[string]
        $parent = Split-Path $AppDir -Parent
        if ($parent) { [void]$roots.Add($parent) }
        $grand = if ($parent) { Split-Path $parent -Parent } else { $null }
        if ($grand) { [void]$roots.Add($grand) }

        $candidates = @()
        foreach ($root in $roots) {
            if (-not (Test-Path $root)) { continue }
            try {
                $candidates += Get-ChildItem -Path $root -Filter 'agenda_dados.json' -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -ne $DataFile -and $_.FullName -notmatch '\\backups\\' }
            } catch {}
        }

        $best = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $best) {
            Copy-Item -Path $best.FullName -Destination $DataFile -Force
            $migrationLog = Join-Path $BackupDir ('migracao_automatica_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
            Set-Content -Path $migrationLog -Value ("Dados migrados automaticamente de: " + $best.FullName) -Encoding UTF8
        }
    } catch {}
}

function Load-Settings {
    $script:PauseUntil = $null
    $script:PauseIndefinitely = $false
    if (-not (Test-Path $SettingsFile)) { return }
    try {
        $raw = Get-Content $SettingsFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $cfg = $raw | ConvertFrom-Json
        if ($null -ne $cfg.PauseIndefinitely) { $script:PauseIndefinitely = [bool]$cfg.PauseIndefinitely }
        if ($null -ne $cfg.PauseUntil -and -not [string]::IsNullOrWhiteSpace([string]$cfg.PauseUntil)) {
            $script:PauseUntil = Convert-ToDateTime $cfg.PauseUntil
        }
    } catch {}
}

function Save-Settings {
    try {
        $cfg = [pscustomobject]@{
            PauseUntil = $(if ($null -ne $script:PauseUntil) { $script:PauseUntil.ToString('o') } else { '' })
            PauseIndefinitely = [bool]$script:PauseIndefinitely
        }
        $cfg | ConvertTo-Json -Depth 3 | Set-Content -Path $SettingsFile -Encoding UTF8
    } catch {}
}

function Test-AlertsPaused {
    if ($script:PauseIndefinitely) { return $true }
    if ($null -ne $script:PauseUntil) {
        if ((Get-Date) -lt $script:PauseUntil) { return $true }
        $script:PauseUntil = $null
        Save-Settings
    }
    return $false
}

function Get-PauseStatusText {
    if ($script:PauseIndefinitely) { return '   •   Avisos pausados até reativar' }
    if ($null -ne $script:PauseUntil -and (Get-Date) -lt $script:PauseUntil) {
        return ('   •   Avisos pausados até ' + $script:PauseUntil.ToString('dd/MM HH:mm'))
    }
    return ''
}

function Reset-DueAlertTimers {
    $now = Get-Date
    $changed = $false
    foreach ($t in @($script:Tasks)) {
        if (-not [bool]$t.Done -and [bool]$t.Alarm) {
            $d = Convert-ToDateTime $t.Due
            if ($d -and $d -le $now -and -not [string]::IsNullOrWhiteSpace([string]$t.LastAlert)) {
                $t.LastAlert = ''
                $changed = $true
            }
        }
    }
    if ($changed) { Save-Tasks }
}

function Set-PauseMinutes([int]$minutes) {
    if ($minutes -lt 1) { return }
    $script:PauseIndefinitely = $false
    $script:PauseUntil = (Get-Date).AddMinutes($minutes)
    Reset-DueAlertTimers
    Save-Settings
    Refresh-All
}

function Set-PauseUntil([datetime]$until) {
    if ($until -le (Get-Date)) { $until = $until.AddDays(1) }
    $script:PauseIndefinitely = $false
    $script:PauseUntil = $until
    Reset-DueAlertTimers
    Save-Settings
    Refresh-All
}

function Set-PauseIndefinitely {
    $script:PauseIndefinitely = $true
    $script:PauseUntil = $null
    Reset-DueAlertTimers
    Save-Settings
    Refresh-All
}

function Resume-Alerts {
    $script:PauseIndefinitely = $false
    $script:PauseUntil = $null
    Save-Settings
    Reset-DueAlertTimers
    Refresh-All
    Check-Reminders
}

function Show-PauseDialog {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Pausar avisos'
    $f.Size = New-Object System.Drawing.Size(430,300)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI',9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Por quanto tempo você quer pausar os lembretes?'
    $lbl.Location = New-Object System.Drawing.Point(20,20); $lbl.AutoSize = $true
    $f.Controls.Add($lbl)

    $b30 = New-Object System.Windows.Forms.Button
    $b30.Text = '30 min'; $b30.Location = New-Object System.Drawing.Point(20,58); $b30.Size = New-Object System.Drawing.Size(110,42)
    $b30.Add_Click({ Set-PauseMinutes 30; $f.Close() })
    $f.Controls.Add($b30)

    $b60 = New-Object System.Windows.Forms.Button
    $b60.Text = '1 hora'; $b60.Location = New-Object System.Drawing.Point(145,58); $b60.Size = New-Object System.Drawing.Size(110,42)
    $b60.Add_Click({ Set-PauseMinutes 60; $f.Close() })
    $f.Controls.Add($b60)

    $b120 = New-Object System.Windows.Forms.Button
    $b120.Text = '2 horas'; $b120.Location = New-Object System.Drawing.Point(270,58); $b120.Size = New-Object System.Drawing.Size(110,42)
    $b120.Add_Click({ Set-PauseMinutes 120; $f.Close() })
    $f.Controls.Add($b120)

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = 'Ou pausar até:'; $timeLabel.Location = New-Object System.Drawing.Point(20,124); $timeLabel.AutoSize = $true
    $f.Controls.Add($timeLabel)

    $time = New-Object System.Windows.Forms.DateTimePicker
    $time.Format = 'Time'; $time.ShowUpDown = $true; $time.Value = (Get-Date).AddHours(1)
    $time.Location = New-Object System.Drawing.Point(120,119); $time.Width = 105
    $f.Controls.Add($time)

    $bUntil = New-Object System.Windows.Forms.Button
    $bUntil.Text = 'Pausar até esse horário'; $bUntil.Location = New-Object System.Drawing.Point(240,113); $bUntil.Size = New-Object System.Drawing.Size(140,38)
    $bUntil.Add_Click({ Set-PauseUntil ((Get-Date).Date.Add($time.Value.TimeOfDay)); $f.Close() })
    $f.Controls.Add($bUntil)

    $bIndef = New-Object System.Windows.Forms.Button
    $bIndef.Text = 'Até eu reativar'; $bIndef.Location = New-Object System.Drawing.Point(20,180); $bIndef.Size = New-Object System.Drawing.Size(165,42)
    $bIndef.Add_Click({ Set-PauseIndefinitely; $f.Close() })
    $f.Controls.Add($bIndef)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancelar'; $cancel.Location = New-Object System.Drawing.Point(215,180); $cancel.Size = New-Object System.Drawing.Size(165,42)
    $cancel.Add_Click({ $f.Close() })
    $f.Controls.Add($cancel)

    Apply-ModernFormStyle $f
    [void]$f.ShowDialog($script:MainForm)
    $f.Dispose()
}

function Load-Tasks {
    $script:Tasks = @()
    if (Test-Path $DataFile) {
        try {
            $raw = Get-Content $DataFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $items = $raw | ConvertFrom-Json
                if ($items -isnot [System.Collections.IEnumerable] -or $items -is [string]) { $items = @($items) }
                $script:Tasks = @($items)
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Não foi possível abrir os dados da agenda.`n$($_.Exception.Message)", 'Agenda Personalizada') | Out-Null
            $script:Tasks = @()
        }
    }
}

function Save-Tasks {
    try {
        $script:Tasks | ConvertTo-Json -Depth 8 | Set-Content -Path $DataFile -Encoding UTF8
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Não foi possível salvar os dados.`n$($_.Exception.Message)", 'Agenda Personalizada') | Out-Null
    }
}

function New-TaskObject([string]$title, [datetime]$due, [bool]$alarm, [string]$recurrence) {
    [pscustomobject]@{
        Id          = [guid]::NewGuid().ToString()
        Title       = $title.Trim()
        Due         = $due.ToString('o')
        Alarm       = $alarm
        Recurrence  = $recurrence
        Done        = $false
        CompletedAt = ''
        LastAlert   = ''
        CreatedAt   = (Get-Date).ToString('o')
    }
}

function Get-NextDue([datetime]$due, [string]$recurrence) {
    switch ($recurrence) {
        'Diária' { return $due.AddDays(1) }
        'Dias úteis' {
            $n = $due.AddDays(1)
            while ($n.DayOfWeek -in @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)) { $n = $n.AddDays(1) }
            return $n
        }
        'Semanal' { return $due.AddDays(7) }
        default { return $null }
    }
}

function Get-NextFutureDue([datetime]$due, [string]$recurrence) {
    $next = Get-NextDue $due $recurrence
    if ($null -eq $next) { return $null }
    $now = Get-Date
    while ($next -le $now) {
        $next = Get-NextDue $next $recurrence
        if ($null -eq $next) { break }
    }
    return $next
}

function Complete-Task([string]$id) {
    $task = $script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($null -eq $task) { return }
    if (-not [bool]$task.Done) {
        $task.Done = $true
        $task.CompletedAt = (Get-Date).ToString('o')
        $due = Convert-ToDateTime $task.Due
        if ($due) {
            $next = Get-NextFutureDue $due ([string]$task.Recurrence)
            if ($null -ne $next) {
                $script:Tasks += New-TaskObject ([string]$task.Title) $next ([bool]$task.Alarm) ([string]$task.Recurrence)
            }
        }
        Save-Tasks
        Refresh-All
    }
}

function Snooze-Task([string]$id, [int]$minutes) {
    $task = $script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($null -eq $task) { return }
    $task.Due = (Get-Date).AddMinutes($minutes).ToString('o')
    $task.LastAlert = ''
    Save-Tasks
    Refresh-All
}

function Get-CustomSnoozeMinutes {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Escolher tempo'
    $f.Size = New-Object System.Drawing.Size(370,235)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI',9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Adiar por:'; $lbl.Location = New-Object System.Drawing.Point(20,25); $lbl.AutoSize = $true
    $f.Controls.Add($lbl)

    $amount = New-Object System.Windows.Forms.NumericUpDown
    $amount.Minimum = 1; $amount.Maximum = 1440; $amount.Value = 45
    $amount.Location = New-Object System.Drawing.Point(20,55); $amount.Width = 110
    $f.Controls.Add($amount)

    $unit = New-Object System.Windows.Forms.ComboBox
    $unit.DropDownStyle = 'DropDownList'; $unit.Location = New-Object System.Drawing.Point(145,55); $unit.Width = 170
    [void]$unit.Items.AddRange(@('minutos','horas')); $unit.SelectedIndex = 0
    $f.Controls.Add($unit)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Adiar'; $ok.Location = New-Object System.Drawing.Point(190,125); $ok.Size = New-Object System.Drawing.Size(125,42)
    $ok.Add_Click({
        $m = [int]$amount.Value
        if ([string]$unit.SelectedItem -eq 'horas') { $m = $m * 60 }
        $f.Tag = $m
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $f.Close()
    })
    $f.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancelar'; $cancel.Location = New-Object System.Drawing.Point(20,125); $cancel.Size = New-Object System.Drawing.Size(125,42)
    $cancel.Add_Click({ $f.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $f.Close() })
    $f.Controls.Add($cancel)

    $result = $null
    Apply-ModernFormStyle $f
    if ($f.ShowDialog($script:MainForm) -eq [System.Windows.Forms.DialogResult]::OK) { $result = [int]$f.Tag }
    $f.Dispose()
    return $result
}

function Move-TaskToTomorrow([string]$id) {
    $task = $script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($null -eq $task -or [bool]$task.Done) { return }
    $oldDue = Convert-ToDateTime $task.Due
    $timeOfDay = if ($oldDue) { $oldDue.TimeOfDay } else { (Get-Date).TimeOfDay }
    $task.Due = ((Get-Date).Date.AddDays(1).Add($timeOfDay)).ToString('o')
    $task.LastAlert = ''
    Save-Tasks
    Refresh-All
}

function Show-SnoozeMenu([string]$id, [System.Windows.Forms.Control]$anchor) {
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $m10 = $menu.Items.Add('10 min')
    $m30 = $menu.Items.Add('30 min')
    $m60 = $menu.Items.Add('1 hora')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mOther = $menu.Items.Add('Escolher tempo...')
    $m10.Add_Click(({ Snooze-Task $id 10 }).GetNewClosure())
    $m30.Add_Click(({ Snooze-Task $id 30 }).GetNewClosure())
    $m60.Add_Click(({ Snooze-Task $id 60 }).GetNewClosure())
    $mOther.Add_Click(({
        $mins = Get-CustomSnoozeMinutes
        if ($null -ne $mins) { Snooze-Task $id $mins }
    }).GetNewClosure())
    $menu.Show($anchor, (New-Object System.Drawing.Point(0,$anchor.Height)))
}

function Delete-Task([string]$id) {
    $task = $script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($null -eq $task) { return }
    $ans = [System.Windows.Forms.MessageBox]::Show("Excluir esta tarefa?`n`n$($task.Title)", 'Agenda Personalizada', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:Tasks = @($script:Tasks | Where-Object { $_.Id -ne $id })
        Save-Tasks
        Refresh-All
    }
}

function Get-SelectedId([System.Windows.Forms.ListView]$list) {
    if ($list.SelectedItems.Count -eq 0) { return $null }
    return [string]$list.SelectedItems[0].Tag
}

function Add-ListItem([System.Windows.Forms.ListView]$list, $task, [string]$status) {
    $due = Convert-ToDateTime $task.Due
    if ($null -eq $due) { return }
    $item = New-Object System.Windows.Forms.ListViewItem($status)
    [void]$item.SubItems.Add($due.ToString('dd/MM/yyyy HH:mm'))
    [void]$item.SubItems.Add([string]$task.Title)
    [void]$item.SubItems.Add($(if ([bool]$task.Alarm) { 'Sim' } else { '' }))
    [void]$item.SubItems.Add([string]$task.Recurrence)
    $item.Tag = [string]$task.Id
    if ($status -like 'PENDENTE*') {
        $item.BackColor = [System.Drawing.Color]::MistyRose
        $item.ForeColor = [System.Drawing.Color]::DarkRed
    }
    [void]$list.Items.Add($item)
}

function Refresh-All {
    if ($null -eq $script:ListToday) { return }
    $script:ListToday.Items.Clear()
    $script:ListUpcoming.Items.Clear()
    $script:ListDone.Items.Clear()

    $now = Get-Date
    $today = $now.Date
    $open = @($script:Tasks | Where-Object { -not [bool]$_.Done } | Sort-Object { Convert-ToDateTime $_.Due })

    foreach ($t in $open) {
        $due = Convert-ToDateTime $t.Due
        if ($null -eq $due) { continue }
        if ($due.Date -lt $today) { Add-ListItem $script:ListToday $t 'PENDENTE' }
        elseif ($due.Date -eq $today) { Add-ListItem $script:ListToday $t 'HOJE' }
        else { Add-ListItem $script:ListUpcoming $t 'AGENDADA' }
    }

    $done = @($script:Tasks | Where-Object { [bool]$_.Done } | Sort-Object { Convert-ToDateTime $_.CompletedAt } -Descending)
    foreach ($t in $done) {
        $due = Convert-ToDateTime $t.Due
        $item = New-Object System.Windows.Forms.ListViewItem('CONCLUÍDA')
        [void]$item.SubItems.Add($(if ($due) { $due.ToString('dd/MM/yyyy HH:mm') } else { '' }))
        [void]$item.SubItems.Add([string]$t.Title)
        [void]$item.SubItems.Add('Sim')
        [void]$item.SubItems.Add([string]$t.Recurrence)
        $item.Tag = [string]$t.Id
        [void]$script:ListDone.Items.Add($item)
    }

    $pending = @($open | Where-Object { $d = Convert-ToDateTime $_.Due; $d -and $d.Date -lt $today }).Count
    $todayCount = @($open | Where-Object { $d = Convert-ToDateTime $_.Due; $d -and $d.Date -eq $today }).Count
    $script:StatusLabel.Text = "Hoje: $todayCount tarefa(s)   •   Pendentes anteriores: $pending" + (Get-PauseStatusText)
}

function Show-TaskEditor([string]$windowTitle, $task = $null) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $windowTitle
    $f.Size = New-Object System.Drawing.Size(500,390)
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI',9)

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Tarefa / compromisso'
    $l1.Location = New-Object System.Drawing.Point(20,20); $l1.AutoSize = $true
    $f.Controls.Add($l1)

    $title = New-Object System.Windows.Forms.TextBox
    $title.Location = New-Object System.Drawing.Point(20,45); $title.Size = New-Object System.Drawing.Size(440,30)
    $title.Font = New-Object System.Drawing.Font('Segoe UI',11)
    if ($task) { $title.Text = [string]$task.Title }
    $f.Controls.Add($title)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'Data'
    $l2.Location = New-Object System.Drawing.Point(20,95); $l2.AutoSize = $true
    $f.Controls.Add($l2)

    $date = New-Object System.Windows.Forms.DateTimePicker
    $date.Format = 'Short'; $date.Location = New-Object System.Drawing.Point(20,120); $date.Width = 180
    $f.Controls.Add($date)

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = 'Horário'
    $l3.Location = New-Object System.Drawing.Point(225,95); $l3.AutoSize = $true
    $f.Controls.Add($l3)

    $time = New-Object System.Windows.Forms.DateTimePicker
    $time.Format = 'Time'; $time.ShowUpDown = $true; $time.Location = New-Object System.Drawing.Point(225,120); $time.Width = 120
    $f.Controls.Add($time)

    $alarm = New-Object System.Windows.Forms.CheckBox
    $alarm.Text = 'Alarme'; $alarm.Location = New-Object System.Drawing.Point(370,120); $alarm.AutoSize = $true
    $alarm.Checked = $true
    $f.Controls.Add($alarm)

    $l4 = New-Object System.Windows.Forms.Label
    $l4.Text = 'Repetir'
    $l4.Location = New-Object System.Drawing.Point(20,175); $l4.AutoSize = $true
    $f.Controls.Add($l4)

    $rec = New-Object System.Windows.Forms.ComboBox
    $rec.DropDownStyle = 'DropDownList'; $rec.Location = New-Object System.Drawing.Point(20,200); $rec.Width = 180
    [void]$rec.Items.AddRange(@('Nenhuma','Diária','Dias úteis','Semanal')); $rec.SelectedIndex = 0
    $f.Controls.Add($rec)

    if ($task) {
        $due = Convert-ToDateTime $task.Due
        if ($due) { $date.Value = $due; $time.Value = $due }
        $alarm.Checked = [bool]$task.Alarm
        $idx = $rec.Items.IndexOf([string]$task.Recurrence)
        if ($idx -ge 0) { $rec.SelectedIndex = $idx }
    } else {
        $d = (Get-Date).AddMinutes(30)
        $date.Value = $d; $time.Value = $d
    }

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancelar'; $cancel.Location = New-Object System.Drawing.Point(20,285); $cancel.Size = New-Object System.Drawing.Size(140,45)
    $cancel.Add_Click({ $f.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $f.Close() })
    $f.Controls.Add($cancel)

    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Salvar'; $save.Location = New-Object System.Drawing.Point(320,285); $save.Size = New-Object System.Drawing.Size(140,45)
    $save.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $save.Add_Click({
        if ([string]::IsNullOrWhiteSpace($title.Text)) {
            [System.Windows.Forms.MessageBox]::Show('Digite o nome da tarefa ou compromisso.', 'Agenda Personalizada') | Out-Null
            $title.Focus(); return
        }
        $f.Tag = [pscustomobject]@{
            Title = $title.Text.Trim()
            Due = $date.Value.Date.Add($time.Value.TimeOfDay)
            Alarm = $alarm.Checked
            Recurrence = [string]$rec.SelectedItem
        }
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $f.Close()
    })
    $f.Controls.Add($save)
    $f.AcceptButton = $save
    $f.CancelButton = $cancel

    $result = $null
    Apply-ModernFormStyle $f
    if ($f.ShowDialog($script:MainForm) -eq [System.Windows.Forms.DialogResult]::OK) { $result = $f.Tag }
    $f.Dispose()
    return $result
}

function Refresh-SearchResults([System.Windows.Forms.TextBox]$queryBox, [System.Windows.Forms.ListView]$results) {
    if ($null -eq $queryBox -or $null -eq $results) { return }
    $results.BeginUpdate()
    try {
        $results.Items.Clear()
        $needle = ([string]$queryBox.Text).Trim()
        $items = @($script:Tasks | Sort-Object { Convert-ToDateTime $_.Due })
        foreach ($t in $items) {
            $title = [string]$t.Title
            if (-not [string]::IsNullOrWhiteSpace($needle) -and $title.IndexOf($needle, [System.StringComparison]::CurrentCultureIgnoreCase) -lt 0) { continue }
            $due = Convert-ToDateTime $t.Due
            $status = if ([bool]$t.Done) { 'CONCLUÍDA' } elseif ($due -and $due -lt (Get-Date)) { 'PENDENTE' } else { 'AGENDADA' }
            $li = New-Object System.Windows.Forms.ListViewItem($status)
            [void]$li.SubItems.Add($(if ($due) { $due.ToString('dd/MM/yyyy HH:mm') } else { '' }))
            [void]$li.SubItems.Add($title)
            $li.Tag = [string]$t.Id
            [void]$results.Items.Add($li)
        }
    } finally {
        $results.EndUpdate()
    }
}

function Edit-SelectedSearchResult([System.Windows.Forms.ListView]$results) {
    if ($null -eq $results -or $results.SelectedItems.Count -eq 0) { return }
    $id = [string]$results.SelectedItems[0].Tag
    $task = $script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($task -and -not [bool]$task.Done) {
        Show-EditDialog $id
        $queryBox = $results.Tag
        if ($queryBox -is [System.Windows.Forms.TextBox]) {
            Refresh-SearchResults $queryBox $results
        }
    }
}

function Show-SearchDialog {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Localizar agendamento'
    $f.Size = New-Object System.Drawing.Size(800,540)
    $f.StartPosition = 'CenterParent'
    $f.MinimumSize = New-Object System.Drawing.Size(700,450)
    $f.Font = New-Object System.Drawing.Font('Segoe UI',9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Digite parte do nome da tarefa:'; $lbl.Location = New-Object System.Drawing.Point(20,18); $lbl.AutoSize = $true
    $f.Controls.Add($lbl)

    $q = New-Object System.Windows.Forms.TextBox
    $q.Location = New-Object System.Drawing.Point(20,43); $q.Size = New-Object System.Drawing.Size(600,30); $q.Anchor = 'Top,Left,Right'
    $q.Font = New-Object System.Drawing.Font('Segoe UI',11)
    $f.Controls.Add($q)

    $search = New-Object System.Windows.Forms.Button
    $search.Text = 'Buscar'; $search.Location = New-Object System.Drawing.Point(635,41); $search.Size = New-Object System.Drawing.Size(125,34); $search.Anchor = 'Top,Right'
    $f.Controls.Add($search)

    $results = New-Object System.Windows.Forms.ListView
    $results.View = 'Details'; $results.FullRowSelect = $true; $results.GridLines = $true; $results.HideSelection = $false
    [void]$results.Columns.Add('Status',95)
    [void]$results.Columns.Add('Data / hora',135)
    [void]$results.Columns.Add('Tarefa',470)
    $results.Location = New-Object System.Drawing.Point(20,85); $results.Size = New-Object System.Drawing.Size(740,340); $results.Anchor = 'Top,Bottom,Left,Right'
    $f.Controls.Add($results)

    $q.Tag = $results
    $results.Tag = $q
    $search.Tag = $q

    $q.Add_TextChanged({
        param($sender,$e)
        $list = $sender.Tag
        if ($list -is [System.Windows.Forms.ListView]) { Refresh-SearchResults $sender $list }
    })

    $q.Add_KeyDown({
        param($sender,$e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $list = $sender.Tag
            if ($list -is [System.Windows.Forms.ListView]) { Refresh-SearchResults $sender $list }
            $e.SuppressKeyPress = $true
            $e.Handled = $true
        }
    })

    $search.Add_Click({
        param($sender,$e)
        $queryBox = $sender.Tag
        if ($queryBox -is [System.Windows.Forms.TextBox] -and $queryBox.Tag -is [System.Windows.Forms.ListView]) {
            Refresh-SearchResults $queryBox $queryBox.Tag
            $queryBox.Focus()
        }
    })

    $results.Add_DoubleClick({
        param($sender,$e)
        Edit-SelectedSearchResult $sender
    })

    $edit = New-Object System.Windows.Forms.Button
    $edit.Text = 'Editar selecionado'; $edit.Location = New-Object System.Drawing.Point(20,440); $edit.Size = New-Object System.Drawing.Size(160,42); $edit.Anchor = 'Bottom,Left'
    $edit.Tag = $results
    $edit.Add_Click({
        param($sender,$e)
        if ($sender.Tag -is [System.Windows.Forms.ListView]) { Edit-SelectedSearchResult $sender.Tag }
    })
    $f.Controls.Add($edit)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Fechar'; $close.Location = New-Object System.Drawing.Point(600,440); $close.Size = New-Object System.Drawing.Size(160,42); $close.Anchor = 'Bottom,Right'
    $close.Add_Click({ param($sender,$e) $sender.FindForm().Close() })
    $f.Controls.Add($close)

    $f.AcceptButton = $search
    Refresh-SearchResults $q $results
    $q.Focus()
    Apply-ModernFormStyle $f
    [void]$f.ShowDialog($script:MainForm)
    $f.Dispose()
}

function Show-NewScheduleDialog {
    $v = Show-TaskEditor 'Novo agendamento'
    if ($null -ne $v) {
        $script:Tasks += New-TaskObject $v.Title $v.Due $v.Alarm $v.Recurrence
        Save-Tasks
        Refresh-All
    }
}

function Show-EditDialog([string]$id) {
    $task = $script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($null -eq $task) { return }
    if ([bool]$task.Done) {
        [System.Windows.Forms.MessageBox]::Show('Esta tarefa já foi concluída. Edite tarefas abertas ou agendadas.', 'Agenda Personalizada') | Out-Null
        return
    }

    $v = Show-TaskEditor 'Editar agendamento' $task
    if ($null -ne $v) {
        $task.Title = $v.Title
        $task.Due = $v.Due.ToString('o')
        $task.Alarm = $v.Alarm
        $task.Recurrence = $v.Recurrence
        $task.LastAlert = ''
        Save-Tasks
        Refresh-All
    }
}

function Show-RescheduleDialog([string]$id) {
    $task = $script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($null -eq $task) { return }
    if ([bool]$task.Done) { return }
    $due = Convert-ToDateTime $task.Due

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Reagendar'
    $f.Size = New-Object System.Drawing.Size(390,220)
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = [string]$task.Title
    $lbl.AutoSize = $false
    $lbl.Size = New-Object System.Drawing.Size(340,45)
    $lbl.Location = New-Object System.Drawing.Point(20,18)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
    $f.Controls.Add($lbl)

    $dp2 = New-Object System.Windows.Forms.DateTimePicker
    $dp2.Format = 'Short'; $dp2.Value = $due
    $dp2.Location = New-Object System.Drawing.Point(20,75); $dp2.Width = 150
    $f.Controls.Add($dp2)

    $tp2 = New-Object System.Windows.Forms.DateTimePicker
    $tp2.Format = 'Time'; $tp2.ShowUpDown = $true; $tp2.Value = $due
    $tp2.Location = New-Object System.Drawing.Point(190,75); $tp2.Width = 150
    $f.Controls.Add($tp2)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Salvar'; $ok.Location = New-Object System.Drawing.Point(190,125); $ok.Size = New-Object System.Drawing.Size(150,42)
    $ok.Add_Click({
        $d = $dp2.Value.Date.Add($tp2.Value.TimeOfDay)
        $task.Due = $d.ToString('o'); $task.LastAlert = ''
        Save-Tasks; Refresh-All; $f.Close()
    })
    $f.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancelar'; $cancel.Location = New-Object System.Drawing.Point(20,125); $cancel.Size = New-Object System.Drawing.Size(150,42)
    $cancel.Add_Click({ $f.Close() })
    $f.Controls.Add($cancel)

    Apply-ModernFormStyle $f
    [void]$f.ShowDialog($script:MainForm)
    $f.Dispose()
}

function Show-Reminder([string]$id) {
    $task = $script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($null -eq $task -or [bool]$task.Done) { return }
    if ($script:OpenReminderIds.Contains($id)) { return }
    [void]$script:OpenReminderIds.Add($id)

    $f = New-Object AgendaReminderForm
    $f.Text = 'Lembrete'
    $f.TopMost = $true
    $f.ShowInTaskbar = $false
    $f.AcceptButton = $null
    $f.CancelButton = $null
    $f.StartPosition = 'Manual'
    $f.ClientSize = New-Object System.Drawing.Size(480,240)
    $f.FormBorderStyle = 'FixedToolWindow'
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Location = New-Object System.Drawing.Point(($wa.Right - $f.Width - 18), ($wa.Bottom - $f.Height - 18))

    $lab1 = New-Object System.Windows.Forms.Label
    $lab1.Text = 'LEMBRETE'
    $lab1.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
    $lab1.Location = New-Object System.Drawing.Point(16,12); $lab1.AutoSize = $true
    $f.Controls.Add($lab1)

    $lab2 = New-Object System.Windows.Forms.Label
    $lab2.Text = [string]$task.Title
    $lab2.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Regular)
    $lab2.Location = New-Object System.Drawing.Point(16,39); $lab2.Size = New-Object System.Drawing.Size(448,58)
    $lab2.AutoEllipsis = $true
    $f.Controls.Add($lab2)

    # MouseClick exige um clique; Enter/Espaço e PerformClick não concluem tarefas.
    $bDone = New-Object AgendaReminderButton
    $bDone.Text = 'Concluir'; $bDone.Location = New-Object System.Drawing.Point(16,108); $bDone.Size = New-Object System.Drawing.Size(104,36)
    $bDone.Add_MouseClick(({
        param($sender,$e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Complete-Task $id; $f.Close() }
    }).GetNewClosure())
    $f.Controls.Add($bDone)

    $b10 = New-Object AgendaReminderButton
    $b10.Text = '+ 10 min'; $b10.Location = New-Object System.Drawing.Point(128,108); $b10.Size = New-Object System.Drawing.Size(104,36)
    $b10.Add_MouseClick(({
        param($sender,$e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Snooze-Task $id 10; $f.Close() }
    }).GetNewClosure())
    $f.Controls.Add($b10)

    $b30 = New-Object AgendaReminderButton
    $b30.Text = '+ 30 min'; $b30.Location = New-Object System.Drawing.Point(240,108); $b30.Size = New-Object System.Drawing.Size(104,36)
    $b30.Add_MouseClick(({
        param($sender,$e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Snooze-Task $id 30; $f.Close() }
    }).GetNewClosure())
    $f.Controls.Add($b30)

    $b60 = New-Object AgendaReminderButton
    $b60.Text = '+ 1 hora'; $b60.Location = New-Object System.Drawing.Point(352,108); $b60.Size = New-Object System.Drawing.Size(112,36)
    $b60.Add_MouseClick(({
        param($sender,$e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Snooze-Task $id 60; $f.Close() }
    }).GetNewClosure())
    $f.Controls.Add($b60)

    $bOther = New-Object AgendaReminderButton
    $bOther.Text = 'Outro tempo...'; $bOther.Location = New-Object System.Drawing.Point(16,154); $bOther.Size = New-Object System.Drawing.Size(144,36)
    $bOther.Add_MouseClick(({
        param($sender,$e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $mins = Get-CustomSnoozeMinutes
        if ($null -ne $mins) { Snooze-Task $id $mins; $f.Close() }
    }).GetNewClosure())
    $f.Controls.Add($bOther)

    $bTomorrow = New-Object AgendaReminderButton
    $bTomorrow.Text = 'Amanhã'; $bTomorrow.Location = New-Object System.Drawing.Point(168,154); $bTomorrow.Size = New-Object System.Drawing.Size(144,36)
    $bTomorrow.Add_MouseClick(({
        param($sender,$e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Move-TaskToTomorrow $id; $f.Close() }
    }).GetNewClosure())
    $f.Controls.Add($bTomorrow)

    $bResched = New-Object AgendaReminderButton
    $bResched.Text = 'Reagendar...'; $bResched.Location = New-Object System.Drawing.Point(320,154); $bResched.Size = New-Object System.Drawing.Size(144,36)
    $bResched.Add_MouseClick(({
        param($sender,$e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $f.Hide(); Show-RescheduleDialog $id; $f.Close() }
    }).GetNewClosure())
    $f.Controls.Add($bResched)

    $lab3 = New-Object System.Windows.Forms.Label
    $lab3.Text = 'Enquanto não concluir, o lembrete continua pendente e volta a avisar.'
    $lab3.Location = New-Object System.Drawing.Point(16,204); $lab3.Size = New-Object System.Drawing.Size(448,30)
    $lab3.ForeColor = [System.Drawing.Color]::DimGray
    $f.Controls.Add($lab3)

    $f.Add_FormClosed(({ [void]$script:OpenReminderIds.Remove($id) }).GetNewClosure())
    Apply-ModernFormStyle $f
    $f.BackColor = $script:Theme.Surface
    $f.ActiveControl = $null
    [void]$f.Show()
}

function Check-Reminders {
    if (Test-AlertsPaused) { return }
    $now = Get-Date
    $dueTasks = @($script:Tasks | Where-Object {
        -not [bool]$_.Done -and [bool]$_.Alarm -and (Convert-ToDateTime $_.Due) -le $now
    } | Sort-Object { Convert-ToDateTime $_.Due })

    foreach ($t in $dueTasks) {
        $last = Convert-ToDateTime $t.LastAlert
        if (($null -eq $last -or $last -le $now.AddMinutes(-30)) -and -not $script:OpenReminderIds.Contains([string]$t.Id)) {
            $t.LastAlert = $now.ToString('o')
            Save-Tasks
            Show-Reminder ([string]$t.Id)
            break
        }
    }
}

function New-ListView {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.HideSelection = $false
    [void]$lv.Columns.Add('Status',95)
    [void]$lv.Columns.Add('Data / hora',135)
    [void]$lv.Columns.Add('Tarefa',430)
    [void]$lv.Columns.Add('Alarme',70)
    [void]$lv.Columns.Add('Repetição',100)
    $lv.Dock = 'Fill'
    return $lv
}

function Ensure-Shortcut([string]$path, [bool]$startHidden) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($path)
        $sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
        if ($startHidden) { $args += ' -StartHidden' }
        $sc.Arguments = $args
        $sc.WorkingDirectory = $AppDir
        $sc.Description = 'Agenda Personalizada'
        $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
        $sc.Save()
        return $true
    } catch { return $false }
}

function Ensure-StartupAndMenuShortcuts {
    try {
        $startup = [Environment]::GetFolderPath('Startup')
        $programs = [Environment]::GetFolderPath('Programs')
        if ($startup) { [void](Ensure-Shortcut (Join-Path $startup 'Agenda Personalizada.lnk') $true) }
        if ($programs) { [void](Ensure-Shortcut (Join-Path $programs 'Agenda Personalizada.lnk') $false) }
    } catch {}
}

function Prepare-TaskbarPin {
    $programs = [Environment]::GetFolderPath('Programs')
    if (-not $programs) { return }
    $lnk = Join-Path $programs 'Agenda Personalizada.lnk'
    [void](Ensure-Shortcut $lnk $false)

    $pinned = $false
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path $lnk -Parent))
        $item = $folder.ParseName((Split-Path $lnk -Leaf))
        foreach ($verb in $item.Verbs()) {
            $name = ([string]$verb.Name).Replace('&','')
            if ($name -match 'Fixar.*barra de tarefas|Pin.*taskbar') {
                $verb.DoIt(); $pinned = $true; break
            }
        }
    } catch {}

    if ($pinned) {
        [System.Windows.Forms.MessageBox]::Show('Atalho fixado na barra de tarefas.', 'Agenda Personalizada') | Out-Null
    } else {
        Start-Process explorer.exe "/select,`"$lnk`""
        [System.Windows.Forms.MessageBox]::Show("O Windows não permitiu fixar automaticamente.`n`nDeixei o atalho selecionado. Clique com o botão direito nele e escolha 'Fixar na barra de tarefas'.", 'Agenda Personalizada') | Out-Null
    }
}

function Export-Agenda {
    Save-Tasks
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Arquivo da Agenda (*.json)|*.json'
    $dlg.FileName = 'Agenda_Personalizada_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.json'
    if ($dlg.ShowDialog($script:MainForm) -eq [System.Windows.Forms.DialogResult]::OK) {
        Copy-Item $DataFile $dlg.FileName -Force
        [System.Windows.Forms.MessageBox]::Show('Agenda exportada com sucesso.', 'Agenda Personalizada') | Out-Null
    }
    $dlg.Dispose()
}

function Import-Agenda {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Arquivo da Agenda (*.json)|*.json|Todos os arquivos (*.*)|*.*'
    if ($dlg.ShowDialog($script:MainForm) -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }
    try {
        $raw = Get-Content $dlg.FileName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Arquivo vazio.' }
        $null = $raw | ConvertFrom-Json
        $ans = [System.Windows.Forms.MessageBox]::Show('Importar esta agenda vai substituir a agenda atual neste computador. Deseja continuar?', 'Agenda Personalizada', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            Save-Tasks
            if (Test-Path $DataFile) {
                $dest = Join-Path $BackupDir ('antes_importacao_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.json')
                Copy-Item $DataFile $dest -Force
            }
            Copy-Item $dlg.FileName $DataFile -Force
            Load-Tasks; Refresh-All
            [System.Windows.Forms.MessageBox]::Show('Agenda importada com sucesso.', 'Agenda Personalizada') | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Este arquivo não pôde ser importado.`n$($_.Exception.Message)", 'Agenda Personalizada') | Out-Null
    }
    $dlg.Dispose()
}

function Make-LocalBackup {
    Save-Tasks
    if (-not (Test-Path $DataFile)) { return }
    $dest = Join-Path $BackupDir ('agenda_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.json')
    Copy-Item $DataFile $dest -Force
    [System.Windows.Forms.MessageBox]::Show("Backup criado em:`n$dest", 'Agenda Personalizada') | Out-Null
}

function Compare-Version([string]$a, [string]$b) {
    try { return ([version]$a).CompareTo([version]$b) }
    catch { return [string]::Compare($a,$b,$true) }
}

function Start-SelfUpdate($manifest) {
    try {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('AgendaPersonalizadaUpdate_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $zip = Join-Path $tempRoot 'update.zip'
        $extract = Join-Path $tempRoot 'files'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null

        Invoke-WebRequest -Uri ([string]$manifest.url) -OutFile $zip -UseBasicParsing
        if (-not [string]::IsNullOrWhiteSpace([string]$manifest.sha256)) {
            $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw 'A verificação de segurança do arquivo de atualização falhou.' }
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)

        $updater = Join-Path $tempRoot 'aplicar_atualizacao.cmd'
        $pidNow = $PID
        $cmd = @"
@echo off
setlocal
:espera
tasklist /FI "PID eq $pidNow" 2>NUL | find "$pidNow" >NUL
if not errorlevel 1 (
  timeout /t 1 /nobreak >NUL
  goto espera
)
if exist "$DataFile" copy /Y "$DataFile" "$BackupDir\antes_atualizacao_%RANDOM%.json" >NUL
xcopy /E /I /Y "$extract\*" "$AppDir\" >NUL
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath"
endlocal
(goto) 2>NUL & del "%~f0"
"@
        Set-Content -Path $updater -Value $cmd -Encoding ASCII
        Save-Tasks
        Save-Settings
        Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', ('"' + $updater + '"')) -WindowStyle Hidden
        $script:ExitRequested = $true
        try { if ($script:TrayIcon) { $script:TrayIcon.Visible = $false } } catch {}
        try { if ($script:MainForm) { $script:MainForm.Hide() } } catch {}
        [System.Environment]::Exit(0)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Não foi possível aplicar a atualização.`n$($_.Exception.Message)", 'Agenda Personalizada') | Out-Null
    }
}

function Check-ForUpdates([bool]$silent = $true) {
    if ([string]::IsNullOrWhiteSpace($UpdateManifestUrl)) { return }
    try {
        $manifest = Invoke-RestMethod -Uri $UpdateManifestUrl -UseBasicParsing -TimeoutSec 12
        if ((Compare-Version ([string]$manifest.version) $AppVersion) -gt 0) {
            $notes = [string]$manifest.notes
            $msg = "Nova versão disponível: $($manifest.version).`n`n"
            if (-not [string]::IsNullOrWhiteSpace($notes)) { $msg += $notes + "`n`n" }
            $msg += 'Atualizar agora? Seus agendamentos e histórico serão preservados.'
            $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Atualização da Agenda', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { Start-SelfUpdate $manifest }
        } elseif (-not $silent) {
            [System.Windows.Forms.MessageBox]::Show("Sua Agenda já está atualizada. Versão $AppVersion.", 'Agenda Personalizada') | Out-Null
        }
    } catch {
        if (-not $silent) {
            [System.Windows.Forms.MessageBox]::Show('Não foi possível verificar atualizações agora. Sua agenda continua funcionando normalmente.', 'Agenda Personalizada') | Out-Null
        }
    }
}

function Exit-Agenda {
    $script:ExitRequested = $true
    Save-Tasks
    Save-Settings
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $false }
    [System.Windows.Forms.Application]::Exit()
}

function Show-MainForm {
    if ($null -eq $script:MainForm) { return }
    $script:MainForm.ShowInTaskbar = $true
    $script:MainForm.Show()
    $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $script:MainForm.Activate()
    $script:MainForm.BringToFront()
}

function Hide-MainForm {
    if ($null -eq $script:MainForm) { return }
    $script:MainForm.Hide()
    $script:MainForm.ShowInTaskbar = $false
    if (-not $script:HideNoticeShown -and $script:TrayIcon) {
        $script:HideNoticeShown = $true
        $script:TrayIcon.BalloonTipTitle = 'Agenda continua ativa'
        $script:TrayIcon.BalloonTipText = 'Pode deixar a janela fechada. Os alarmes continuam funcionando.'
        $script:TrayIcon.ShowBalloonTip(3500)
    }
}

function Check-OpenSignal {
    if (Test-Path $OpenSignal) {
        try { Remove-Item $OpenSignal -Force -ErrorAction SilentlyContinue } catch {}
        Show-MainForm
    }
}

Try-AutoMigrateData
Load-Settings
Load-Tasks
Ensure-StartupAndMenuShortcuts

$form = New-Object System.Windows.Forms.Form
$script:MainForm = $form
$form.Text = "Agenda Personalizada - v$AppVersion"
$form.Size = New-Object System.Drawing.Size(980,700)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900,620)
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)
$form.BackColor = $script:Theme.Background
$form.Icon = [System.Drawing.SystemIcons]::Application

$header = New-Object System.Windows.Forms.Label
$header.Text = 'Minha Agenda'
$header.Font = New-Object System.Drawing.Font('Segoe UI Semibold',21,[System.Drawing.FontStyle]::Bold)
$header.ForeColor = $script:Theme.Text
$header.Location = New-Object System.Drawing.Point(20,16); $header.AutoSize = $true
$form.Controls.Add($header)

$status = New-Object System.Windows.Forms.Label
$script:StatusLabel = $status
$status.Location = New-Object System.Drawing.Point(23,56); $status.AutoSize = $true; $status.ForeColor = $script:Theme.Muted
$form.Controls.Add($status)
$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = "Versão $AppVersion"
$versionLabel.Location = New-Object System.Drawing.Point(225,25)
$versionLabel.AutoSize = $true
$versionLabel.ForeColor = $script:Theme.Muted
$form.Controls.Add($versionLabel)

$findTop = New-Object System.Windows.Forms.Button
$findTop.Text = 'Localizar'
$findTop.Location = New-Object System.Drawing.Point(625,17); $findTop.Size = New-Object System.Drawing.Size(120,44)
$findTop.Anchor = 'Top,Right'
$findTop.Add_Click({ Show-SearchDialog })
$form.Controls.Add($findTop)

$newScheduleTop = New-Object System.Windows.Forms.Button
$newScheduleTop.Text = 'Novo agendamento'
$newScheduleTop.Location = New-Object System.Drawing.Point(755,17); $newScheduleTop.Size = New-Object System.Drawing.Size(190,44)
$newScheduleTop.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$newScheduleTop.Anchor = 'Top,Right'
$newScheduleTop.Add_Click({ Show-NewScheduleDialog })
$form.Controls.Add($newScheduleTop)

$headerDivider = New-Object System.Windows.Forms.Panel
$headerDivider.Location = New-Object System.Drawing.Point(20,72); $headerDivider.Size = New-Object System.Drawing.Size(925,2); $headerDivider.Anchor = 'Top,Left,Right'
$headerDivider.BackColor = $script:Theme.Border
$form.Controls.Add($headerDivider)

$quickShadow = New-Object System.Windows.Forms.Panel
$quickShadow.Name = 'shadow'
$quickShadow.Location = New-Object System.Drawing.Point(23,87); $quickShadow.Size = New-Object System.Drawing.Size(925,135); $quickShadow.Anchor = 'Top,Left,Right'
$quickShadow.BackColor = $script:Theme.Shadow
$form.Controls.Add($quickShadow)

$quick = New-Object System.Windows.Forms.GroupBox
$quick.Text = 'Lembrete rápido / nova tarefa'
$quick.Location = New-Object System.Drawing.Point(20,83); $quick.Size = New-Object System.Drawing.Size(925,135); $quick.Anchor = 'Top,Left,Right'
$form.Controls.Add($quick)
$quick.BringToFront()

$txt = New-Object System.Windows.Forms.TextBox
$txt.Location = New-Object System.Drawing.Point(16,28); $txt.Size = New-Object System.Drawing.Size(500,28); $txt.Font = New-Object System.Drawing.Font('Segoe UI',11)
$quick.Controls.Add($txt)

$dp = New-Object System.Windows.Forms.DateTimePicker
$dp.Format = 'Short'; $dp.Value = Get-Date; $dp.Location = New-Object System.Drawing.Point(530,28); $dp.Width = 120
$quick.Controls.Add($dp)

$tp = New-Object System.Windows.Forms.DateTimePicker
$tp.Format = 'Time'; $tp.ShowUpDown = $true; $tp.Value = (Get-Date).AddMinutes(30); $tp.Location = New-Object System.Drawing.Point(660,28); $tp.Width = 100
$quick.Controls.Add($tp)

$alarm = New-Object System.Windows.Forms.CheckBox
$alarm.Text = 'Alarme'; $alarm.Checked = $true; $alarm.Location = New-Object System.Drawing.Point(775,29); $alarm.AutoSize = $true
$quick.Controls.Add($alarm)

$recLabel = New-Object System.Windows.Forms.Label
$recLabel.Text = 'Repetir:'; $recLabel.Location = New-Object System.Drawing.Point(16,77); $recLabel.AutoSize = $true
$quick.Controls.Add($recLabel)

$rec = New-Object System.Windows.Forms.ComboBox
$rec.DropDownStyle = 'DropDownList'; $rec.Location = New-Object System.Drawing.Point(75,72); $rec.Width = 145
[void]$rec.Items.AddRange(@('Nenhuma','Diária','Dias úteis','Semanal')); $rec.SelectedIndex = 0
$quick.Controls.Add($rec)

$b1h = New-Object System.Windows.Forms.Button
$b1h.Text = 'Em 1 hora'; $b1h.Location = New-Object System.Drawing.Point(240,69); $b1h.Size = New-Object System.Drawing.Size(100,34)
$b1h.Add_Click({ $d=(Get-Date).AddHours(1); $dp.Value=$d; $tp.Value=$d })
$quick.Controls.Add($b1h)

$bTomorrow = New-Object System.Windows.Forms.Button
$bTomorrow.Text = 'Amanhã 9h'; $bTomorrow.Location = New-Object System.Drawing.Point(350,69); $bTomorrow.Size = New-Object System.Drawing.Size(110,34)
$bTomorrow.Add_Click({ $d=(Get-Date).Date.AddDays(1).AddHours(9); $dp.Value=$d; $tp.Value=$d })
$quick.Controls.Add($bTomorrow)

$minutes = New-Object System.Windows.Forms.NumericUpDown
$minutes.Minimum = 1; $minutes.Maximum = 1440; $minutes.Value = 15
$minutes.Location = New-Object System.Drawing.Point(478,73); $minutes.Size = New-Object System.Drawing.Size(58,28)
$quick.Controls.Add($minutes)

$minutesLabel = New-Object System.Windows.Forms.Label
$minutesLabel.Text = 'min'; $minutesLabel.Location = New-Object System.Drawing.Point(541,77); $minutesLabel.AutoSize = $true
$quick.Controls.Add($minutesLabel)

$bMinutes = New-Object System.Windows.Forms.Button
$bMinutes.Text = 'Em minutos'; $bMinutes.Location = New-Object System.Drawing.Point(573,69); $bMinutes.Size = New-Object System.Drawing.Size(100,34)
$bMinutes.Add_Click({ $d=(Get-Date).AddMinutes([int]$minutes.Value); $dp.Value=$d; $tp.Value=$d })
$quick.Controls.Add($bMinutes)

$save = New-Object System.Windows.Forms.Button
$save.Text = 'Salvar tarefa'; $save.Location = New-Object System.Drawing.Point(735,68); $save.Size = New-Object System.Drawing.Size(165,38)
$save.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$save.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txt.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Digite a tarefa ou lembrete.', 'Agenda Personalizada') | Out-Null
        $txt.Focus(); return
    }
    $due = $dp.Value.Date.Add($tp.Value.TimeOfDay)
    $script:Tasks += New-TaskObject $txt.Text $due $alarm.Checked ([string]$rec.SelectedItem)
    Save-Tasks; Refresh-All
    $txt.Clear(); $txt.Focus()
})
$quick.Controls.Add($save)

$tabsShadow = New-Object System.Windows.Forms.Panel
$tabsShadow.Name = 'shadow'
$tabsShadow.Location = New-Object System.Drawing.Point(23,235); $tabsShadow.Size = New-Object System.Drawing.Size(925,350); $tabsShadow.Anchor = 'Top,Bottom,Left,Right'
$tabsShadow.BackColor = $script:Theme.Shadow
$form.Controls.Add($tabsShadow)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20,232); $tabs.Size = New-Object System.Drawing.Size(925,350); $tabs.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($tabs)
$tabs.BringToFront()

$tToday = New-Object System.Windows.Forms.TabPage; $tToday.Text = 'Hoje e pendências'
$tUpcoming = New-Object System.Windows.Forms.TabPage; $tUpcoming.Text = 'Próximas'
$tDone = New-Object System.Windows.Forms.TabPage; $tDone.Text = 'Concluídas'
[void]$tabs.TabPages.AddRange(@($tToday,$tUpcoming,$tDone))

$script:ListToday = New-ListView; $tToday.Controls.Add($script:ListToday)
$script:ListUpcoming = New-ListView; $tUpcoming.Controls.Add($script:ListUpcoming)
$script:ListDone = New-ListView; $tDone.Controls.Add($script:ListDone)

$actions = New-Object System.Windows.Forms.Panel
$actions.Location = New-Object System.Drawing.Point(20,582); $actions.Size = New-Object System.Drawing.Size(925,70); $actions.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($actions)

function Current-List {
    if ($tabs.SelectedTab -eq $tToday) { return $script:ListToday }
    if ($tabs.SelectedTab -eq $tUpcoming) { return $script:ListUpcoming }
    return $script:ListDone
}

$complete = New-Object System.Windows.Forms.Button
$complete.Text = 'Concluir'; $complete.Location = New-Object System.Drawing.Point(0,5); $complete.Size = New-Object System.Drawing.Size(105,42)
$complete.Add_Click({ $id = Get-SelectedId (Current-List); if ($id) { Complete-Task $id } })
$actions.Controls.Add($complete)

$edit = New-Object System.Windows.Forms.Button
$edit.Text = 'Editar'; $edit.Location = New-Object System.Drawing.Point(115,5); $edit.Size = New-Object System.Drawing.Size(105,42)
$edit.Add_Click({ $id = Get-SelectedId (Current-List); if ($id) { Show-EditDialog $id } })
$actions.Controls.Add($edit)

$snooze = New-Object System.Windows.Forms.Button
$snooze.Text = 'Adiar...'; $snooze.Location = New-Object System.Drawing.Point(230,5); $snooze.Size = New-Object System.Drawing.Size(115,42)
$snooze.Add_Click({ $id = Get-SelectedId (Current-List); if ($id) { Show-SnoozeMenu $id $snooze } })
$actions.Controls.Add($snooze)

$resched = New-Object System.Windows.Forms.Button
$resched.Text = 'Reagendar'; $resched.Location = New-Object System.Drawing.Point(355,5); $resched.Size = New-Object System.Drawing.Size(110,42)
$resched.Add_Click({ $id = Get-SelectedId (Current-List); if ($id) { Show-RescheduleDialog $id } })
$actions.Controls.Add($resched)

$delete = New-Object System.Windows.Forms.Button
$delete.Text = 'Excluir'; $delete.Location = New-Object System.Drawing.Point(475,5); $delete.Size = New-Object System.Drawing.Size(90,42)
$delete.Add_Click({ $id = Get-SelectedId (Current-List); if ($id) { Delete-Task $id } })
$actions.Controls.Add($delete)

$alertsMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miPause = $alertsMenu.Items.Add('Pausar avisos...')
$miResume = $alertsMenu.Items.Add('Retomar avisos')
[void]$alertsMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExitAgenda = $alertsMenu.Items.Add('Sair completamente da Agenda')
$miPause.Add_Click({ Show-PauseDialog })
$miResume.Add_Click({ Resume-Alerts })
$miExitAgenda.Add_Click({ Exit-Agenda })
$alertsMenu.Add_Opening({
    $paused = Test-AlertsPaused
    $miPause.Enabled = -not $paused
    $miResume.Enabled = $paused
})

$alertsButton = New-Object System.Windows.Forms.Button
$alertsButton.Text = 'Avisos'; $alertsButton.Location = New-Object System.Drawing.Point(575,5); $alertsButton.Size = New-Object System.Drawing.Size(105,42)
$alertsButton.Add_Click({ $alertsMenu.Show($alertsButton, (New-Object System.Drawing.Point(0,$alertsButton.Height))) })
$actions.Controls.Add($alertsButton)

$dataMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miBackup = $dataMenu.Items.Add('Fazer backup local')
$miExport = $dataMenu.Items.Add('Exportar agenda para outro PC')
$miImport = $dataMenu.Items.Add('Importar agenda')
[void]$dataMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miUpdate = $dataMenu.Items.Add('Verificar atualizações')
$miFolder = $dataMenu.Items.Add('Abrir pasta da agenda')
[void]$dataMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miAbout = $dataMenu.Items.Add('Sobre a Agenda')
$miBackup.Add_Click({ Make-LocalBackup })
$miExport.Add_Click({ Export-Agenda })
$miImport.Add_Click({ Import-Agenda })
$miUpdate.Add_Click({ Check-ForUpdates $false })
$miFolder.Add_Click({ Start-Process explorer.exe $AppDir })
$miAbout.Add_Click({ Show-AboutDialog })

$dataButton = New-Object System.Windows.Forms.Button
$dataButton.Text = 'Dados'; $dataButton.Location = New-Object System.Drawing.Point(690,5); $dataButton.Size = New-Object System.Drawing.Size(105,42); $dataButton.Anchor = 'Top,Right'
$dataButton.Add_Click({ $dataMenu.Show($dataButton, (New-Object System.Drawing.Point(0,$dataButton.Height))) })
$actions.Controls.Add($dataButton)

$pinButton = New-Object System.Windows.Forms.Button
$pinButton.Text = 'Fixar na barra'; $pinButton.Location = New-Object System.Drawing.Point(805,5); $pinButton.Size = New-Object System.Drawing.Size(120,42); $pinButton.Anchor = 'Top,Right'
$pinButton.Add_Click({ Prepare-TaskbarPin })
$actions.Controls.Add($pinButton)

$copyright = New-Object System.Windows.Forms.Label
$copyright.Text = '© 2026 @paulapmiranda — Uso restrito. Reprodução e distribuição não autorizadas.'
$copyright.Location = New-Object System.Drawing.Point(4,52); $copyright.Size = New-Object System.Drawing.Size(915,16); $copyright.Anchor = 'Bottom,Left,Right'
$copyright.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$copyright.Font = New-Object System.Drawing.Font('Segoe UI',7.5)
$copyright.ForeColor = $script:Theme.Muted
$actions.Controls.Add($copyright)

$script:ListToday.Add_DoubleClick({ $id=Get-SelectedId $script:ListToday; if($id){ Show-EditDialog $id } })
$script:ListUpcoming.Add_DoubleClick({ $id=Get-SelectedId $script:ListUpcoming; if($id){ Show-EditDialog $id } })

Apply-ModernFormStyle $form
$header.Font = New-Object System.Drawing.Font('Segoe UI Semibold',21,[System.Drawing.FontStyle]::Bold)
$header.ForeColor = $script:Theme.Text
$status.ForeColor = $script:Theme.Muted
$versionLabel.ForeColor = $script:Theme.Muted
$headerDivider.BackColor = $script:Theme.Border
$quickShadow.BackColor = $script:Theme.Shadow
$tabsShadow.BackColor = $script:Theme.Shadow
$copyright.ForeColor = $script:Theme.Muted

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayOpen = $trayMenu.Items.Add('Abrir Agenda')
$trayNew = $trayMenu.Items.Add('Novo agendamento')
$trayFind = $trayMenu.Items.Add('Localizar agendamento')
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$trayPause = $trayMenu.Items.Add('Pausar avisos...')
$trayResume = $trayMenu.Items.Add('Retomar avisos')
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$trayExit = $trayMenu.Items.Add('Sair da Agenda')
$trayOpen.Add_Click({ Show-MainForm })
$trayNew.Add_Click({ Show-MainForm; Show-NewScheduleDialog })
$trayFind.Add_Click({ Show-MainForm; Show-SearchDialog })
$trayPause.Add_Click({ Show-PauseDialog })
$trayResume.Add_Click({ Resume-Alerts })
$trayExit.Add_Click({ Exit-Agenda })
$trayMenu.Add_Opening({
    $paused = Test-AlertsPaused
    $trayPause.Enabled = -not $paused
    $trayResume.Enabled = $paused
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon = $tray
$tray.Text = 'Agenda Personalizada'
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.ContextMenuStrip = $trayMenu
$tray.Visible = $true
$tray.Add_DoubleClick({ Show-MainForm })

$timer = New-Object System.Windows.Forms.Timer
$script:Timer = $timer
$timer.Interval = 30000
$timer.Add_Tick({ Check-Reminders; Refresh-All; Check-OpenSignal })
$timer.Start()

$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 21600000
$updateTimer.Add_Tick({ Check-ForUpdates $true })
$updateTimer.Start()

$form.Add_Shown({
    Refresh-All
    Check-Reminders
    if ($StartHidden) { Hide-MainForm } else { $txt.Focus() }
    $script:InitialUpdateTimer = New-Object System.Windows.Forms.Timer
    $script:InitialUpdateTimer.Interval = 2500
    $script:InitialUpdateTimer.Add_Tick({
        try {
            if ($null -ne $script:InitialUpdateTimer) {
                $script:InitialUpdateTimer.Stop()
                $script:InitialUpdateTimer.Dispose()
                $script:InitialUpdateTimer = $null
            }
            Check-ForUpdates $true
        } catch {
            # A verificação automática nunca deve interromper a agenda.
        }
    })
    $script:InitialUpdateTimer.Start()
})

$form.Add_FormClosing({
    param($sender,$e)
    Save-Tasks
    Save-Settings
    if (-not $script:ExitRequested -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Hide-MainForm
        return
    }
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() }
    if ($script:Timer) { $script:Timer.Stop(); $script:Timer.Dispose() }
    try { $updateTimer.Stop(); $updateTimer.Dispose() } catch {}
    try { if ($null -ne $script:InitialUpdateTimer) { $script:InitialUpdateTimer.Stop(); $script:InitialUpdateTimer.Dispose(); $script:InitialUpdateTimer = $null } } catch {}
    try { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose() } catch {}
})

[void][System.Windows.Forms.Application]::Run($form)
