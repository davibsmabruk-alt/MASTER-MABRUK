<#
.SYNOPSIS
    Agente de Limpeza e Performance do PC (Windows 10/11).

.DESCRIPTION
    Diagnostica, limpa e otimiza o Windows com segurança.
    - Diagnostico : só lê e gera relatório (não altera nada).
    - Limpeza     : remove arquivos temporários, caches e lixo.
    - Otimizacao  : cria ponto de restauração, ajusta energia, TRIM/desfrag etc.
    - Completo    : Diagnostico + Limpeza + Otimizacao.

    Use -Simular para ver o que seria feito sem apagar/alterar nada.

.EXAMPLE
    .\Otimizar-PC.ps1 -Modo Diagnostico
    .\Otimizar-PC.ps1 -Modo Limpeza -Simular
    .\Otimizar-PC.ps1 -Modo Completo
    .\Otimizar-PC.ps1 -Modo Otimizacao -Reparar -EfeitosVisuaisLeves
#>
[CmdletBinding()]
param(
    [ValidateSet('Diagnostico', 'Limpeza', 'Otimizacao', 'Completo')]
    [string]$Modo = 'Diagnostico',

    # Mostra o que seria feito, sem apagar nem alterar nada.
    [switch]$Simular,

    # Roda SFC + DISM para reparar arquivos do sistema (demora 15-40 min).
    [switch]$Reparar,

    # Ajusta efeitos visuais para "melhor desempenho" (visual mais simples).
    [switch]$EfeitosVisuaisLeves,

    # Também limpa a Lixeira (desligado por padrão para você não perder nada sem querer).
    [switch]$EsvaziarLixeira
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- Admin
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Pedindo permissão de administrador...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Modo', $Modo)
    if ($Simular) { $argList += '-Simular' }
    if ($Reparar) { $argList += '-Reparar' }
    if ($EfeitosVisuaisLeves) { $argList += '-EfeitosVisuaisLeves' }
    if ($EsvaziarLixeira) { $argList += '-EsvaziarLixeira' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

# ---------------------------------------------------------------- Relatório
$desktop = [Environment]::GetFolderPath('Desktop')
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$relatorio = Join-Path $desktop "Relatorio-PC_$stamp.txt"
Start-Transcript -Path $relatorio -Force | Out-Null

function Titulo([string]$t) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}
function Info([string]$t) { Write-Host "  $t" }
function Ok([string]$t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Aviso([string]$t) { Write-Host "  [!] $t" -ForegroundColor Yellow }

function Formatar-Tamanho([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N2} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N1} MB' -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return '{0:N0} KB' -f ($bytes / 1KB) }
    return "$bytes B"
}

function Tamanho-Pasta([string]$caminho) {
    if (-not (Test-Path -LiteralPath $caminho)) { return 0 }
    $soma = (Get-ChildItem -LiteralPath $caminho -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $soma) { return 0 }
    return [double]$soma
}

function Espaco-Livre-C {
    return [double](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace
}

# Apaga o CONTEÚDO de uma pasta (nunca a pasta em si). Itens em uso são ignorados.
function Limpar-Pasta([string]$caminho, [string]$descricao) {
    if (-not (Test-Path -LiteralPath $caminho)) { return }
    $antes = Tamanho-Pasta $caminho
    if ($antes -eq 0) { return }
    if ($Simular) {
        Info ("[SIMULAÇÃO] {0,-38} {1,12}" -f $descricao, (Formatar-Tamanho $antes))
        $script:totalSimulado += $antes
        return
    }
    Get-ChildItem -LiteralPath $caminho -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $depois = Tamanho-Pasta $caminho
    Ok ("{0,-38} {1,12} liberados" -f $descricao, (Formatar-Tamanho ($antes - $depois)))
}

$script:totalSimulado = 0

# ================================================================ DIAGNÓSTICO
function Executar-Diagnostico {
    Titulo 'DIAGNÓSTICO DO SISTEMA'

    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $uptime = (Get-Date) - $os.LastBootUpTime

    Info "Sistema      : $($os.Caption) (build $($os.BuildNumber))"
    Info "Processador  : $($cpu.Name.Trim()) - $($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) threads"
    Info ("Uso de CPU   : {0}%" -f $cpu.LoadPercentage)

    $ramTotal = $cs.TotalPhysicalMemory
    $ramLivre = $os.FreePhysicalMemory * 1KB
    $ramUso = [math]::Round((1 - $ramLivre / $ramTotal) * 100)
    Info ("Memória RAM  : {0} total, {1}% em uso" -f (Formatar-Tamanho $ramTotal), $ramUso)
    if ($ramTotal -lt 8GB) { Aviso 'Menos de 8 GB de RAM: um upgrade de memória daria um ganho grande.' }
    if ($ramUso -ge 85) { Aviso 'RAM quase cheia: feche programas pesados ou revise a inicialização.' }

    Info ("Ligado há    : {0} dias, {1} h" -f $uptime.Days, $uptime.Hours)
    if ($uptime.Days -ge 7) { Aviso 'PC sem reiniciar há mais de 7 dias. Reiniciar já ajuda bastante.' }

    $plano = (powercfg /getactivescheme) -replace '.*\((.*)\).*', '$1'
    Info "Plano energia: $plano"

    # Discos
    Titulo 'DISCOS'
    try {
        Get-PhysicalDisk | ForEach-Object {
            $tipo = if ($_.MediaType -eq 'SSD') { 'SSD' } elseif ($_.MediaType -eq 'HDD') { 'HD (mecânico)' } else { "$($_.MediaType)" }
            Info ("{0} | {1} | {2} | saúde: {3}" -f $_.FriendlyName, $tipo, (Formatar-Tamanho $_.Size), $_.HealthStatus)
            if ($_.HealthStatus -ne 'Healthy') { Aviso "Disco '$($_.FriendlyName)' com saúde '$($_.HealthStatus)'. FAÇA BACKUP!" }
            if ($_.MediaType -eq 'HDD') { Aviso 'Você usa HD mecânico. Trocar por SSD é o maior ganho de velocidade possível.' }
        }
    } catch { Aviso 'Não consegui ler os discos físicos.' }

    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $pct = if ($_.Size) { [math]::Round($_.FreeSpace / $_.Size * 100) } else { 0 }
        Info ("Unidade {0}  livre: {1} de {2} ({3}%)" -f $_.DeviceID, (Formatar-Tamanho $_.FreeSpace), (Formatar-Tamanho $_.Size), $pct)
        if ($pct -lt 15) { Aviso "Unidade $($_.DeviceID) com menos de 15% livre: isso deixa o Windows lento." }
    }

    # Processos
    Titulo 'TOP 10 PROCESSOS POR MEMÓRIA'
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 | ForEach-Object {
        Info ("{0,-32} {1,10}" -f $_.ProcessName, (Formatar-Tamanho $_.WorkingSet64))
    }

    # Inicialização
    Titulo 'PROGRAMAS QUE ABREM COM O WINDOWS'
    $startup = Get-CimInstance Win32_StartupCommand | Sort-Object Name
    if ($startup) {
        $startup | ForEach-Object { Info ("{0,-34} ({1})" -f $_.Name, $_.Location) }
        Info ''
        Info "Total: $(@($startup).Count). Desative os desnecessários em:"
        Info 'Gerenciador de Tarefas (Ctrl+Shift+Esc) > Aplicativos de inicialização.'
    } else { Info 'Nenhum encontrado.' }

    # Lixo acumulado
    Titulo 'LIXO ACUMULADO (pode ser limpo)'
    $itens = [ordered]@{
        'Temporários do usuário'       = $env:TEMP
        'Temporários do Windows'       = "$env:WINDIR\Temp"
        'Cache do Windows Update'      = "$env:WINDIR\SoftwareDistribution\Download"
        'Relatórios de erro'           = "$env:ProgramData\Microsoft\Windows\WER"
        'Cache Chrome'                 = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
        'Cache Edge'                   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
    }
    $somaLixo = 0
    foreach ($k in $itens.Keys) {
        $t = Tamanho-Pasta $itens[$k]
        $somaLixo += $t
        Info ("{0,-32} {1,12}" -f $k, (Formatar-Tamanho $t))
    }
    Info ("{0,-32} {1,12}" -f 'TOTAL ESTIMADO', (Formatar-Tamanho $somaLixo))
}

# ================================================================ LIMPEZA
function Executar-Limpeza {
    Titulo $(if ($Simular) { 'LIMPEZA (SIMULAÇÃO - nada será apagado)' } else { 'LIMPEZA' })
    $livreAntes = Espaco-Livre-C

    # Temporários
    Limpar-Pasta $env:TEMP 'Temporários do usuário'
    Limpar-Pasta "$env:WINDIR\Temp" 'Temporários do Windows'
    Limpar-Pasta "$env:ProgramData\Microsoft\Windows\WER" 'Relatórios de erro'
    Limpar-Pasta "$env:LOCALAPPDATA\CrashDumps" 'Crash dumps'
    Limpar-Pasta "$env:LOCALAPPDATA\D3DSCache" 'Cache de shaders DirectX'

    # Cache do Windows Update (precisa parar o serviço)
    $wu = "$env:WINDIR\SoftwareDistribution\Download"
    if ((Tamanho-Pasta $wu) -gt 0) {
        if (-not $Simular) {
            Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
        }
        Limpar-Pasta $wu 'Cache do Windows Update'
        if (-not $Simular) {
            Start-Service bits, wuauserv -ErrorAction SilentlyContinue
        }
    }

    # Caches de navegador (só cache: senhas, histórico e cookies NÃO são tocados)
    $navegadores = @(
        @{ Proc = 'chrome';  Nome = 'Chrome';  Base = "$env:LOCALAPPDATA\Google\Chrome\User Data" },
        @{ Proc = 'msedge';  Nome = 'Edge';    Base = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" },
        @{ Proc = 'brave';   Nome = 'Brave';   Base = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" },
        @{ Proc = 'opera';   Nome = 'Opera';   Base = "$env:APPDATA\Opera Software\Opera Stable" }
    )
    foreach ($n in $navegadores) {
        if (-not (Test-Path -LiteralPath $n.Base)) { continue }
        if (Get-Process -Name $n.Proc -ErrorAction SilentlyContinue) {
            Aviso "$($n.Nome) está aberto - feche-o para limpar o cache dele por completo."
        }
        $perfis = @(Get-ChildItem -LiteralPath $n.Base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
        if ($n.Nome -eq 'Opera') { $perfis = @(Get-Item -LiteralPath $n.Base) }
        foreach ($p in $perfis) {
            foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') {
                Limpar-Pasta (Join-Path $p.FullName $sub) "Cache $($n.Nome) ($($p.Name)) $sub"
            }
        }
    }
    $ff = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ff) {
        Get-ChildItem -LiteralPath $ff -Directory | ForEach-Object {
            Limpar-Pasta (Join-Path $_.FullName 'cache2') "Cache Firefox ($($_.Name))"
        }
    }

    # Cache de miniaturas
    $thumbs = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    $thumbFiles = Get-ChildItem -LiteralPath $thumbs -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue
    if ($thumbFiles) {
        $t = ($thumbFiles | Measure-Object Length -Sum).Sum
        if ($Simular) { Info ("[SIMULAÇÃO] {0,-38} {1,12}" -f 'Cache de miniaturas', (Formatar-Tamanho $t)); $script:totalSimulado += $t }
        else { $thumbFiles | Remove-Item -Force -ErrorAction SilentlyContinue; Ok 'Cache de miniaturas limpo (itens em uso ignorados)' }
    }

    # Otimização de Entrega (Delivery Optimization)
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        if ($Simular) { Info '[SIMULAÇÃO] Cache de Otimização de Entrega seria limpo' }
        else { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue; Ok 'Cache de Otimização de Entrega limpo' }
    }

    # Lixeira
    if ($EsvaziarLixeira) {
        if ($Simular) { Info '[SIMULAÇÃO] Lixeira seria esvaziada' }
        else { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Ok 'Lixeira esvaziada' }
    } else {
        Info 'Lixeira mantida (use -EsvaziarLixeira para esvaziar).'
    }

    # Componentes antigos do Windows (WinSxS) - seguro, recomendado pela Microsoft
    if ($Simular) { Info '[SIMULAÇÃO] DISM /StartComponentCleanup seria executado' }
    else {
        Info 'Limpando componentes antigos do Windows (pode levar alguns minutos)...'
        Dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet /NoRestart | Out-Null
        Ok 'Componentes antigos do Windows limpos'
    }

    # DNS
    if (-not $Simular) { ipconfig /flushdns | Out-Null; Ok 'Cache DNS limpo' }

    if ($Simular) {
        Info ''
        Info ("Total que seria liberado (aprox.): {0}" -f (Formatar-Tamanho $script:totalSimulado))
    } else {
        $ganho = (Espaco-Livre-C) - $livreAntes
        Info ''
        Ok ("ESPAÇO LIBERADO NO C: {0}" -f (Formatar-Tamanho ([math]::Max(0, $ganho))))
    }
}

# ================================================================ OTIMIZAÇÃO
function Executar-Otimizacao {
    Titulo $(if ($Simular) { 'OTIMIZAÇÃO (SIMULAÇÃO - nada será alterado)' } else { 'OTIMIZAÇÃO' })

    # 1. Ponto de restauração (rede de segurança)
    if ($Simular) { Info '[SIMULAÇÃO] Criaria ponto de restauração' }
    else {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description "Agente PC - antes da otimização $stamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Ok 'Ponto de restauração criado (dá para desfazer tudo em "Restauração do Sistema")'
        } catch {
            Aviso "Não criei ponto de restauração: $($_.Exception.Message)"
            Aviso '(O Windows só permite 1 por 24h. Se já criou hoje, tudo bem.)'
        }
    }

    # 2. Plano de energia
    $temBateria = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($temBateria) {
        Info 'Notebook detectado: mantendo plano Equilibrado (melhor para bateria/temperatura).'
        Info 'Dica: conectado na tomada, use o modo "Melhor desempenho" no ícone da bateria.'
    } else {
        if ($Simular) { Info '[SIMULAÇÃO] Ativaria plano "Alto desempenho"' }
        else {
            powercfg /setactive SCHEME_MIN 2>$null
            if ($LASTEXITCODE -eq 0) { Ok 'Plano de energia: Alto desempenho' }
            else { Aviso 'Plano Alto desempenho indisponível neste PC.' }
        }
    }

    # 3. TRIM (SSD) / Desfragmentação (HD)
    Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' } | ForEach-Object {
        $letra = $_.DriveLetter
        $particao = Get-Partition -DriveLetter $letra -ErrorAction SilentlyContinue
        $disco = if ($particao) { Get-PhysicalDisk | Where-Object DeviceId -eq $particao.DiskNumber } else { $null }
        $ehSsd = $disco -and $disco.MediaType -eq 'SSD'
        if ($Simular) {
            Info ("[SIMULAÇÃO] Unidade {0}: {1}" -f $letra, $(if ($ehSsd) { 'TRIM' } else { 'Desfragmentação' }))
        } elseif ($ehSsd) {
            Optimize-Volume -DriveLetter $letra -ReTrim -ErrorAction SilentlyContinue
            Ok "Unidade ${letra}: TRIM executado (SSD)"
        } else {
            Info "Desfragmentando unidade ${letra}: (pode demorar)..."
            Optimize-Volume -DriveLetter $letra -Defrag -ErrorAction SilentlyContinue
            Ok "Unidade ${letra}: desfragmentada"
        }
    }

    # 4. Gravação em segundo plano de jogos (Xbox Game Bar) - consome CPU/GPU à toa
    $gameDvr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    if ($Simular) { Info '[SIMULAÇÃO] Desativaria gravação em segundo plano do Game Bar' }
    else {
        New-Item -Path $gameDvr -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path $gameDvr -Name 'AppCaptureEnabled' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Ok 'Gravação em segundo plano do Game Bar desativada'
    }

    # 5. Efeitos visuais (opcional)
    if ($EfeitosVisuaisLeves) {
        if ($Simular) { Info '[SIMULAÇÃO] Ajustaria efeitos visuais para melhor desempenho' }
        else {
            $vfx = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
            New-Item -Path $vfx -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $vfx -Name 'VisualFXSetting' -Value 2 -Type DWord
            Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'MenuShowDelay' -Value '100'
            Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Ok 'Efeitos visuais em "melhor desempenho" (vale após sair e entrar de novo)'
        }
    }

    # 6. Reparo do sistema (opcional, demorado)
    if ($Reparar) {
        if ($Simular) { Info '[SIMULAÇÃO] Rodaria DISM /RestoreHealth e SFC /scannow' }
        else {
            Info 'Reparando imagem do Windows (DISM) - 10 a 30 min...'
            Dism.exe /Online /Cleanup-Image /RestoreHealth
            Info 'Verificando arquivos do sistema (SFC) - 5 a 15 min...'
            sfc.exe /scannow
            Ok 'Reparo concluído'
        }
    }

    # 7. Recomendações que dependem de você
    Titulo 'RECOMENDAÇÕES MANUAIS'
    Info '1. Desative programas de inicialização desnecessários (Ctrl+Shift+Esc > Inicialização).'
    Info '2. Desinstale programas que não usa (Configurações > Aplicativos).'
    Info '3. Mantenha Windows Update e drivers da placa de vídeo em dia.'
    Info '4. Use só UM antivírus (o Windows Defender já é suficiente para a maioria).'
    Info '5. Reinicie o PC pelo menos 1x por semana.'
}

# ================================================================ EXECUÇÃO
Titulo "AGENTE DE LIMPEZA E PERFORMANCE - modo: $Modo$(if ($Simular) { ' (simulação)' })"
Info "Relatório sendo salvo em: $relatorio"

switch ($Modo) {
    'Diagnostico' { Executar-Diagnostico }
    'Limpeza'     { Executar-Limpeza }
    'Otimizacao'  { Executar-Otimizacao }
    'Completo'    { Executar-Diagnostico; Executar-Limpeza; Executar-Otimizacao }
}

Titulo 'CONCLUÍDO'
Info "Relatório completo: $relatorio"
if (-not $Simular -and $Modo -in 'Limpeza', 'Otimizacao', 'Completo') {
    Aviso 'Reinicie o computador para aplicar tudo.'
}
Stop-Transcript | Out-Null
Write-Host ''
Read-Host 'Pressione ENTER para fechar'
