param([string]$SourcePath = (Join-Path $PSScriptRoot '..\src\Agenda_Personalizada.ps1'))
$ErrorActionPreference = 'Stop'

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

$source = [IO.File]::ReadAllText((Resolve-Path $SourcePath), [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
Assert-That ($parseErrors.Count -eq 0) ('PowerShell sem erros de sintaxe: ' + ($parseErrors | Out-String))

# Carrega apenas os tipos, o tema e as funções. Não inicia a agenda nem lê dados reais.
. ([scriptblock]::Create($source.Substring(0, $source.IndexOf('$AppVersion ='))))
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    } elseif ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
              $statement.Left.Extent.Text -eq '$script:Theme') {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ReminderNativeTest {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
}
'@

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('AgendaV8Test_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testDir)
$DataFile = Join-Path $testDir 'agenda_dados.json'
$SettingsFile = Join-Path $testDir 'agenda_config.json'
$script:ListToday = $null
$script:MainForm = $null
$script:OpenReminderIds = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Tasks = @(New-TaskObject 'Teste: continuar digitando em outro programa' (Get-Date).AddMinutes(-1) $true 'Nenhuma')
$task = $script:Tasks[0]
Save-Tasks
$originalData = [IO.File]::ReadAllText($DataFile)

$editor = New-Object System.Windows.Forms.Form
$editor.Text = 'Programa em que a usuária está digitando'
$editor.Size = New-Object System.Drawing.Size(400,200)
$editorText = New-Object System.Windows.Forms.TextBox
$editorText.Multiline = $true
$editorText.AcceptsReturn = $true
$editorText.Dock = 'Fill'
$editor.Controls.Add($editorText)
$editor.Show()
$editor.Activate()
[void]$editorText.Focus()
[System.Windows.Forms.Application]::DoEvents()
$foregroundBefore = [ReminderNativeTest]::GetForegroundWindow()
[System.Windows.Forms.SendKeys]::SendWait('texto antes ')

function Get-ReminderWindow {
    return @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_ -is [AgendaReminderForm] })[0]
}
function Invoke-ReminderMouse($Button, [System.Windows.Forms.MouseButtons]$Which) {
    $method = [System.Windows.Forms.Control].GetMethod('OnMouseClick', [Reflection.BindingFlags]'Instance,NonPublic')
    $event = New-Object System.Windows.Forms.MouseEventArgs($Which,1,10,10,0)
    [void]$method.Invoke($Button, @($event))
    [System.Windows.Forms.Application]::DoEvents()
}

try {
    Show-Reminder $task.Id
    [System.Windows.Forms.Application]::DoEvents()
    $reminder = Get-ReminderWindow
    Assert-That ($null -ne $reminder -and $reminder.Visible) 'O aviso abre no Windows'
    Assert-That ($reminder.Width -lt 565 -and $reminder.Height -lt 330) 'O aviso ocupa menos espaço que a v7'
    Assert-That ([ReminderNativeTest]::GetForegroundWindow() -eq $foregroundBefore) 'Abrir o aviso preserva a janela em primeiro plano'
    Assert-That ($editorText.Focused) 'O teclado permanece no campo que já estava em uso'
    [System.Windows.Forms.SendKeys]::SendWait('texto depois{ENTER}')
    Assert-That ($editorText.Text.Contains('texto antes texto depois')) 'A digitação antes e depois do aviso continua no mesmo campo'
    Assert-That ($null -eq $reminder.ActiveControl -and $null -eq $reminder.AcceptButton) 'Nenhum botão é selecionado ou assumido como padrão'

    $buttons = @($reminder.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] })
    Assert-That ($buttons.Count -eq 7) 'Todos os sete comandos permanecem disponíveis'
    $done = $buttons | Where-Object Text -eq 'Concluir'
    Assert-That ($done.BackColor.ToArgb() -eq $script:Theme.SurfaceAlt.ToArgb()) 'Concluir tem visual neutro'
    foreach ($button in $buttons) {
        Assert-That (-not $button.CanSelect -and -not $button.TabStop) ('Sem foco automático em ' + $button.Text)
        Assert-That ($reminder.ClientRectangle.Contains($button.Bounds)) ('Botão inteiramente visível: ' + $button.Text)
        $button.PerformClick()
        foreach ($key in @(13,32)) {
            [void][ReminderNativeTest]::SendMessage($button.Handle,0x0100,[IntPtr]$key,[IntPtr]::Zero)
            [void][ReminderNativeTest]::SendMessage($button.Handle,0x0101,[IntPtr]$key,[IntPtr]::Zero)
        }
    }
    Assert-That ([IO.File]::ReadAllText($DataFile) -eq $originalData) 'Enter, Espaço e Click genérico não alteram os agendamentos'
    $activation = [ReminderNativeTest]::SendMessage($reminder.Handle,0x0021,$editor.Handle,[IntPtr]::Zero)
    Assert-That ($activation.ToInt32() -eq 3) 'O aviso recusa ativação sem descartar o clique do mouse'

    $artifactDir = Join-Path $PSScriptRoot '..\test-results'
    [void](New-Item -ItemType Directory -Path $artifactDir -Force)
    $bitmap = New-Object System.Drawing.Bitmap($reminder.Width,$reminder.Height)
    $reminder.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0,0,$reminder.Width,$reminder.Height)))
    $bitmap.Save((Join-Path $artifactDir 'lembrete_v8.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()

    Invoke-ReminderMouse $done ([System.Windows.Forms.MouseButtons]::Right)
    Assert-That (-not $task.Done) 'Clique direito não conclui o lembrete'
    $reminder.Close()
    Assert-That (-not $task.Done -and -not $script:OpenReminderIds.Contains($task.Id)) 'Fechar o aviso mantém a tarefa pendente e libera novo aviso'
    foreach ($minutes in @(10,30,60,10)) {
        Show-Reminder $task.Id
        $reminder = Get-ReminderWindow
        $text = if ($minutes -eq 60) { '+ 1 hora' } else { '+ ' + $minutes + ' min' }
        $snooze = $reminder.Controls | Where-Object Text -eq $text
        Invoke-ReminderMouse $snooze ([System.Windows.Forms.MouseButtons]::Left)
        $due = Convert-ToDateTime $task.Due
        Assert-That (-not $task.Done -and $due -gt (Get-Date).AddMinutes($minutes-1)) ('Adiamento por clique: ' + $minutes + ' minutos')
        Assert-That (-not $script:OpenReminderIds.Contains($task.Id)) 'O lembrete pode ser exibido novamente após adiar'
    }
    Show-Reminder $task.Id
    $reminder = Get-ReminderWindow
    $tomorrow = $reminder.Controls | Where-Object Text -eq 'Amanhã'
    Invoke-ReminderMouse $tomorrow ([System.Windows.Forms.MouseButtons]::Left)
    Assert-That ((Convert-ToDateTime $task.Due).Date -eq (Get-Date).Date.AddDays(1)) 'Amanhã conserva o reagendamento para o dia seguinte'

    Show-Reminder $task.Id
    $reminder = Get-ReminderWindow
    $done = $reminder.Controls | Where-Object Text -eq 'Concluir'
    Invoke-ReminderMouse $done ([System.Windows.Forms.MouseButtons]::Left)
    Assert-That ($task.Done -and $script:Tasks.Count -eq 1) 'Clique esquerdo conclui e mantém o registro no histórico'
    $persisted = @(Get-Content $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    Assert-That ($persisted.Count -eq 1 -and $persisted[0].Done) 'A conclusão é salva sem excluir o registro'
    Assert-That ($Error.Count -eq 0) ('Sem erros durante os eventos: ' + ($Error | Out-String))
} finally {
    foreach ($window in @([System.Windows.Forms.Application]::OpenForms)) { $window.Close(); $window.Dispose() }
    Remove-Item $testDir -Recurse -Force
}
