<#
.SYNOPSIS
    Mapa do Espaço: descobre o que está lotando os discos (SSD/NVMe/HD) e
    separa tudo em VERDE (lixo seguro), AMARELO (revisar) e VERMELHO (não mexer).

.DESCRIPTION
    Acoes:
      Mapa               : só lê. Gera relatório (.txt) e lista (.json). Não apaga nada.
      LimparVerde        : apaga só o que é VERDE no último mapa (caches que os
                           programas recriam sozinhos e cópias automáticas antigas).
      Quarentena         : MOVE (não apaga) os caminhos de um arquivo -Lista para
                           X:\_QUARENTENA_LIMPEZA\<data>\ no mesmo disco. Dá para desfazer.
      Desfazer           : devolve tudo o que está na quarentena para o lugar original.
      EsvaziarQuarentena : apaga de vez só o que está na quarentena há mais de -DiasQuarentena dias.
      AgendarManutencao  : cria tarefa semanal no Windows (domingo 12h) que apaga caches
                           com mais de 30 dias e esvazia quarentenas antigas.

.EXAMPLE
    .\Mapa-Espaco.ps1                                # mapa de todos os discos
    .\Mapa-Espaco.ps1 -Unidades D,E -MesesParado 12
    .\Mapa-Espaco.ps1 -Acao LimparVerde
    .\Mapa-Espaco.ps1 -Acao Quarentena -Lista .\apagar.txt
    .\Mapa-Espaco.ps1 -Acao Desfazer
#>
[CmdletBinding()]
param(
    [ValidateSet('Mapa', 'LimparVerde', 'Quarentena', 'Desfazer', 'EsvaziarQuarentena', 'AgendarManutencao')]
    [string]$Acao = 'Mapa',

    # Letras das unidades a mapear (padrão: todas as unidades fixas).
    [string[]]$Unidades,

    # Pasta de projeto sem nenhuma alteração há mais de N meses = "projeto parado".
    [int]$MesesParado = 6,

    # LimparVerde: só apaga caches mais velhos que N dias (0 = todos).
    [int]$IdadeMinimaDias = 0,

    # Quarentena: arquivo .txt com um caminho por linha.
    [string]$Lista,

    # EsvaziarQuarentena: só apaga o que está na quarentena há mais de N dias.
    [int]$DiasQuarentena = 14,

    [string]$Relatorio,
    [string]$Json,
    [switch]$SemPausa
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
if (-not $Json) { $Json = Join-Path $env:TEMP 'mapa-espaco.json' }
if (-not $Relatorio) {
    $Relatorio = Join-Path ([Environment]::GetFolderPath('Desktop')) "Mapa-Espaco_$stamp.txt"
}
$PASTA_QUARENTENA = '_QUARENTENA_LIMPEZA'
$PROGRAMAS_EDICAO = 'Adobe Premiere Pro', 'AfterFX', 'Adobe Media Encoder', 'Resolve', 'Photoshop', 'lightroom', 'Lightroom'

Start-Transcript -Path $Relatorio -Force | Out-Null

# ---------------------------------------------------------------- utilitários
function Titulo([string]$t) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
}
function Info([string]$t) { Write-Host "  $t" }
function Ok([string]$t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Aviso([string]$t) { Write-Host "  [!] $t" -ForegroundColor Yellow }
function Verde([string]$t) { Write-Host "  [VERDE] $t" -ForegroundColor Green }
function Amarelo([string]$t) { Write-Host "  [AMARELO] $t" -ForegroundColor Yellow }
function Vermelho([string]$t) { Write-Host "  [VERMELHO] $t" -ForegroundColor Red }

function Tam([double]$b) {
    if ($b -ge 1TB) { return '{0:N2} TB' -f ($b / 1TB) }
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N0} MB' -f ($b / 1MB) }
    return '{0:N0} KB' -f ($b / 1KB)
}

function Programas-De-Edicao-Abertos {
    return @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $n = $_.ProcessName; $PROGRAMAS_EDICAO | Where-Object { $n -like "$_*" } } |
        Select-Object -ExpandProperty ProcessName -Unique)
}

function Hash-Amostra([string]$caminho, [long]$tamanho) {
    # Lê 1 MB do início, do meio e do fim: rápido e confiável para vídeos grandes.
    try {
        $fs = [IO.File]::OpenRead($caminho)
        try {
            $md5 = [Security.Cryptography.MD5]::Create()
            $buf = New-Object byte[] 1048576
            $ms = New-Object IO.MemoryStream
            foreach ($pos in @(0, [long]($tamanho / 2), [math]::Max(0, $tamanho - 1048576))) {
                $fs.Position = $pos
                $n = $fs.Read($buf, 0, $buf.Length)
                $ms.Write($buf, 0, $n)
            }
            return [BitConverter]::ToString($md5.ComputeHash($ms.ToArray()))
        } finally { $fs.Dispose() }
    } catch { return $null }
}

# ---------------------------------------------------------------- regras
# VERDE = o programa recria sozinho. Apagar não perde trabalho nenhum.
$REGRAS_VERDE = @(
    @{ Nome = 'Cache de mídia do Adobe (Premiere / After Effects / Media Encoder)'; Re = '^(.*?\\Media Cache Files)\\' },
    @{ Nome = 'Cache de mídia do Adobe (Premiere / After Effects / Media Encoder)'; Re = '^(.*?\\Media Cache)\\' },
    @{ Nome = 'Ondas de áudio do Adobe (Peak Files)'; Re = '^(.*?\\Peak Files)\\' },
    @{ Nome = 'Pré-visualizações renderizadas do Premiere'; Re = '^(.*?\\Adobe Premiere Pro (?:Video|Audio) Previews)\\' },
    @{ Nome = 'Cache de disco do After Effects'; Re = '^(.*?\\After Effects\\Disk Cache[^\\]*)\\' },
    @{ Nome = 'Cache do DaVinci Resolve (CacheClip)'; Re = '^(.*?\\CacheClip)\\' },
    @{ Nome = 'Cache do Camera Raw (Photoshop / Lightroom)'; Re = '^(.*?\\CameraRaw\\Cache)\\' }
)
# Cópias automáticas: mantém as 3 mais recentes de cada pasta, o resto é VERDE.
$RE_AUTOSAVE = '^(.*?\\(?:Adobe Premiere Pro Auto-Save|Adobe After Effects Auto-Save|Auto-Save))\\'
# AMARELO = só se apaga depois de conversar.
$REGRAS_AMARELO = @(
    @{ Nome = 'Proxies (cópias leves dos vídeos)'; Re = '^(.*?\\(?:Proxies|Proxy))\\'
       Motivo = 'Se os brutos originais ainda existem, o proxy é recriável. Se os brutos JÁ FORAM APAGADOS, o proxy pode ser a única cópia do material.' },
    @{ Nome = 'Mídia otimizada do DaVinci Resolve'; Re = '^(.*?\\OptimizedMedia)\\'
       Motivo = 'Recriável a partir dos brutos. Sem os brutos, pode ser a única cópia.' },
    @{ Nome = 'Pré-visualizações de catálogos do Lightroom'; Re = '^(.*?\.lrdata)\\'
       Motivo = 'O Lightroom recria, mas as fotos demoram mais para abrir na primeira vez. Nunca apague o arquivo .lrcat (é o catálogo).' }
)
$EXT_MIDIA = '.mxf', '.r3d', '.braw', '.mov', '.mp4', '.m4v', '.avi', '.mts', '.m2ts', '.mkv', '.wav', '.aif', '.aiff',
             '.arw', '.cr2', '.cr3', '.nef', '.raf', '.dng', '.orf', '.rw2', '.psd', '.psb', '.tif', '.tiff'
$EXT_PROJETO = '.prproj', '.aep', '.drp', '.drt', '.lrcat', '.psd', '.fcpxml', '.aaf', '.xml'
$EXT_INSTALADOR = '.exe', '.msi', '.zip', '.rar', '.7z', '.iso'
$PULAR_RAIZ = 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin', 'System Volume Information',
              'Recovery', 'PerfLogs', '$WinREAgent', 'Windows.old', 'Config.Msi', $PASTA_QUARENTENA, 'OneDriveTemp'

# ================================================================ SAÚDE DOS DISCOS
function Mostrar-Saude {
    Titulo 'SAÚDE DOS DISCOS (SSD / NVMe / HD)'
    $discos = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    $saida = @()
    foreach ($d in $discos) {
        $tipo = if ($d.BusType -eq 'NVMe') { 'NVMe' } elseif ($d.MediaType -eq 'SSD') { 'SSD SATA' } elseif ($d.MediaType -eq 'HDD') { 'HD mecânico' } else { "$($d.MediaType)/$($d.BusType)" }
        Info ("{0}  |  {1}  |  {2}  |  saúde: {3}" -f $d.FriendlyName, $tipo, (Tam $d.Size), $d.HealthStatus)
        $item = [ordered]@{ nome = $d.FriendlyName; tipo = $tipo; bytes = [double]$d.Size; saude = "$($d.HealthStatus)" }
        if ($d.HealthStatus -ne 'Healthy') {
            Vermelho "DISCO COM PROBLEMA. Copie os arquivos importantes para outro lugar HOJE e não faça limpeza nele."
        }
        try {
            $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            $partes = @()
            if ($null -ne $rc.Wear) { $partes += "desgaste $($rc.Wear)%"; $item.desgaste = $rc.Wear }
            if ($rc.Temperature) { $partes += "temperatura $($rc.Temperature) °C"; $item.temperatura = $rc.Temperature }
            if ($rc.PowerOnHours) { $partes += ("ligado {0:N0} h" -f $rc.PowerOnHours) }
            if ($rc.ReadErrorsUncorrected) { $partes += "erros de leitura $($rc.ReadErrorsUncorrected)" }
            if ($partes) { Info ('      ' + ($partes -join '  |  ')) }
            if ($rc.Wear -ge 90) { Vermelho 'SSD no fim da vida útil: planeje trocar e mantenha backup em dia.' }
            elseif ($rc.Wear -ge 70) { Aviso 'SSD já bem gasto (70%+). Mantenha backup e evite enchê-lo.' }
            if ($rc.Temperature -ge 70) { Aviso 'SSD quente demais (70 °C+). Verifique ventilação / dissipador do NVMe.' }
            if ($rc.ReadErrorsUncorrected -gt 0) { Vermelho 'Erros de leitura não corrigidos: faça backup imediatamente.' }
        } catch {
            Info '      (desgaste e temperatura aparecem quando roda como administrador)'
        }
        $saida += $item
    }

    Titulo 'ESPAÇO LIVRE POR UNIDADE'
    Info 'Regra de ouro para SSD/NVMe: manter pelo menos 20% livre.'
    Info 'Abaixo disso ele fica mais lento e se desgasta mais rápido.'
    Info ''
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $pct = if ($_.Size) { [math]::Round($_.FreeSpace / $_.Size * 100) } else { 0 }
        $msg = "Unidade {0}  livre: {1} de {2} ({3}% livre)" -f $_.DeviceID, (Tam $_.FreeSpace), (Tam $_.Size), $pct
        if ($pct -lt 10) { Vermelho "$msg  -> CRÍTICO" }
        elseif ($pct -lt 20) { Amarelo "$msg  -> abaixo do ideal (20%)" }
        else { Ok $msg }
    }
    return $saida
}

# ================================================================ MAPA
function Executar-Mapa {
    $programas = Programas-De-Edicao-Abertos
    $letras = if ($Unidades) { $Unidades | ForEach-Object { $_.TrimEnd(':', '\').ToUpper() } }
              else { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID.TrimEnd(':') } }

    $saude = Mostrar-Saude

    $verde = @{}        # raiz -> @{ nome; bytes; antigo (bytes mais velhos que 30 dias) }
    $amarelo = @{}      # raiz -> @{ nome; motivo; bytes }
    $autosaves = @{}    # pasta -> lista de arquivos
    $pastas = @{}       # pasta de projeto -> @{ bytes; ultima; midia; projetos }
    $grandes = @{}      # tamanho -> lista de arquivos (>= 100 MB) para duplicados
    $instaladores = New-Object System.Collections.ArrayList
    $totalMidia = 0.0
    $limite30 = (Get-Date).AddDays(-30)
    $perfil = $env:USERPROFILE.TrimEnd('\')
    $downloads = Join-Path $perfil 'Downloads'

    foreach ($l in $letras) {
        $raiz = "${l}:\"
        if (-not (Test-Path -LiteralPath $raiz)) { continue }
        Titulo "LENDO A UNIDADE ${l}: (pode levar de 2 a 20 minutos, não precisa fazer nada)"
        $topo = Get-ChildItem -LiteralPath $raiz -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $PULAR_RAIZ -notcontains $_.Name }
        $contador = 0
        foreach ($dirTopo in $topo) {
            Get-ChildItem -LiteralPath $dirTopo.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $f = $_
                $p = $f.FullName
                $len = [double]$f.Length
                $contador++
                if ($contador % 50000 -eq 0) { Info ("... {0:N0} arquivos lidos" -f $contador) }

                # pasta de "projeto" para o ranking (2 níveis abaixo da raiz ou do perfil)
                $base = if ($p.StartsWith($perfil + '\', 'OrdinalIgnoreCase')) { $perfil } else { $raiz.TrimEnd('\') }
                $resto = $p.Substring($base.Length + 1).Split('\')
                $chave = if ($resto.Count -gt 2) { $base + '\' + $resto[0] + '\' + $resto[1] } elseif ($resto.Count -gt 1) { $base + '\' + $resto[0] } else { $null }
                if ($chave -and $chave -notmatch '\\AppData(\\|$)') {
                    if (-not $pastas.ContainsKey($chave)) { $pastas[$chave] = @{ bytes = 0.0; ultima = [datetime]::MinValue; midia = 0.0; projetos = 0 } }
                    $pp = $pastas[$chave]
                    $pp.bytes += $len
                    if ($f.LastWriteTime -gt $pp.ultima) { $pp.ultima = $f.LastWriteTime }
                }
                $ext = $f.Extension.ToLowerInvariant()
                $temPasta = $chave -and $pastas.ContainsKey($chave)
                if ($EXT_MIDIA -contains $ext) { $totalMidia += $len; if ($temPasta) { $pastas[$chave].midia += $len } }
                if ($EXT_PROJETO -contains $ext -and $temPasta) { $pastas[$chave].projetos++ }

                # VERDE: caches
                foreach ($r in $REGRAS_VERDE) {
                    if ($p -match $r.Re) {
                        $k = $Matches[1]
                        if (-not $verde.ContainsKey($k)) { $verde[$k] = @{ nome = $r.Nome; bytes = 0.0; antigo = 0.0 } }
                        $verde[$k].bytes += $len
                        if ($f.LastWriteTime -lt $limite30) { $verde[$k].antigo += $len }
                        return
                    }
                }
                # Cópias automáticas
                if ($p -match $RE_AUTOSAVE) {
                    $k = Split-Path $p -Parent
                    if (-not $autosaves.ContainsKey($k)) { $autosaves[$k] = New-Object System.Collections.ArrayList }
                    [void]$autosaves[$k].Add([pscustomobject]@{ caminho = $p; bytes = $len; data = $f.LastWriteTime })
                    return
                }
                # AMARELO
                foreach ($r in $REGRAS_AMARELO) {
                    if ($p -match $r.Re) {
                        $k = $Matches[1]
                        if (-not $amarelo.ContainsKey($k)) { $amarelo[$k] = @{ nome = $r.Nome; motivo = $r.Motivo; bytes = 0.0 } }
                        $amarelo[$k].bytes += $len
                        return
                    }
                }
                if ($p.StartsWith($downloads + '\', 'OrdinalIgnoreCase') -and $EXT_INSTALADOR -contains $ext -and $f.LastWriteTime -lt $limite30) {
                    [void]$instaladores.Add([pscustomobject]@{ caminho = $p; bytes = $len; data = $f.LastWriteTime })
                }
                if ($len -ge 100MB -and $p -notmatch '\\AppData\\') {
                    $kk = [string]$f.Length
                    if (-not $grandes.ContainsKey($kk)) { $grandes[$kk] = New-Object System.Collections.ArrayList }
                    [void]$grandes[$kk].Add([pscustomobject]@{ caminho = $p; bytes = $len; data = $f.LastWriteTime })
                }
            }
        }
        Info ("{0:N0} arquivos lidos na unidade {1}:" -f $contador, $l)
    }

    $json = [ordered]@{ gerado = (Get-Date).ToString('s'); discos = $saude; verde = @(); amarelo = @(); projetos = @() }

    # ------------------------------------------------ VERDE
    Titulo 'VERDE - LIXO SEGURO (os programas recriam sozinhos)'
    $somaVerde = 0.0
    foreach ($k in ($verde.Keys | Sort-Object { -$verde[$_].bytes })) {
        $v = $verde[$k]
        if ($v.bytes -lt 1MB) { continue }
        Verde ("{0,10}  {1}" -f (Tam $v.bytes), $v.nome)
        Info ("            {0}" -f $k)
        $somaVerde += $v.bytes
        $json.verde += [ordered]@{ tipo = 'conteudo-pasta'; nome = $v.nome; caminho = $k; bytes = $v.bytes }
    }
    $somaAuto = 0.0
    foreach ($k in $autosaves.Keys) {
        $lista = @($autosaves[$k] | Sort-Object data -Descending)
        if ($lista.Count -le 3) { continue }
        $velhos = $lista | Select-Object -Skip 3
        $b = ($velhos | Measure-Object bytes -Sum).Sum
        $somaAuto += $b
        foreach ($x in $velhos) { $json.verde += [ordered]@{ tipo = 'arquivo'; nome = 'Cópia automática antiga'; caminho = $x.caminho; bytes = $x.bytes } }
        Verde ("{0,10}  {1} cópias automáticas antigas (mantidas as 3 mais novas)" -f (Tam $b), ($lista.Count - 3))
        Info ("            {0}" -f $k)
    }
    $somaVerde += $somaAuto
    Info ''
    Ok ("TOTAL VERDE (pode apagar sem medo): {0}" -f (Tam $somaVerde))
    if ($programas) { Aviso ("Feche antes de limpar: {0}" -f ($programas -join ', ')) }

    # ------------------------------------------------ AMARELO
    Titulo 'AMARELO - REVISAR JUNTO (pode ser lixo, mas precisa de um "sim")'
    $somaAmarelo = 0.0
    foreach ($k in ($amarelo.Keys | Sort-Object { -$amarelo[$_].bytes })) {
        $a = $amarelo[$k]
        if ($a.bytes -lt 50MB) { continue }
        Amarelo ("{0,10}  {1}" -f (Tam $a.bytes), $a.nome)
        Info ("            {0}" -f $k)
        Info ("            Por quê: {0}" -f $a.motivo)
        $somaAmarelo += $a.bytes
        $json.amarelo += [ordered]@{ categoria = $a.nome; caminho = $k; bytes = $a.bytes; motivo = $a.motivo }
    }

    # duplicados
    $grupos = @($grandes.Values | Where-Object { $_.Count -gt 1 })
    $somaDup = 0.0
    if ($grupos) {
        Info ''
        Info 'Possíveis arquivos DUPLICADOS (mesmo tamanho e mesmo conteúdo):'
        foreach ($g in $grupos) {
            $porHash = @{}
            foreach ($x in $g) {
                $h = Hash-Amostra $x.caminho ([long]$x.bytes)
                if (-not $h) { continue }
                if (-not $porHash.ContainsKey($h)) { $porHash[$h] = New-Object System.Collections.ArrayList }
                [void]$porHash[$h].Add($x)
            }
            foreach ($copias in ($porHash.Values | Where-Object { $_.Count -gt 1 })) {
                $ord = @($copias | Sort-Object data)
                $extra = ($ord.Count - 1) * $ord[0].bytes
                $somaDup += $extra
                Amarelo ("{0,10}  {1} cópias de {2}" -f (Tam $extra), $ord.Count, (Split-Path $ord[0].caminho -Leaf))
                foreach ($x in $ord) { Info ("            {0}  ({1:dd/MM/yyyy})" -f $x.caminho, $x.data) }
                foreach ($x in ($ord | Select-Object -Skip 1)) {
                    $json.amarelo += [ordered]@{ categoria = 'Duplicado'; caminho = $x.caminho; bytes = $x.bytes; motivo = "Cópia igual a $($ord[0].caminho)" }
                }
            }
        }
    }
    $somaAmarelo += $somaDup

    if ($instaladores.Count) {
        $b = ($instaladores | Measure-Object bytes -Sum).Sum
        $somaAmarelo += $b
        Info ''
        Amarelo ("{0,10}  {1} instaladores / zips antigos na pasta Downloads" -f (Tam $b), $instaladores.Count)
        foreach ($x in ($instaladores | Sort-Object bytes -Descending | Select-Object -First 15)) {
            Info ("            {0,10}  {1}" -f (Tam $x.bytes), $x.caminho)
            $json.amarelo += [ordered]@{ categoria = 'Instalador antigo'; caminho = $x.caminho; bytes = $x.bytes; motivo = 'Programas já instalados não precisam do instalador. Dá para baixar de novo.' }
        }
    }

    foreach ($l in $letras) {
        $wo = "${l}:\Windows.old"
        if (Test-Path -LiteralPath $wo) {
            Info ''
            Amarelo "Windows.old em ${l}: (versão antiga do Windows). Remover pela Limpeza de Disco > Limpar arquivos do sistema."
        }
    }
    Info ''
    Ok ("TOTAL AMARELO (revisar): {0}" -f (Tam $somaAmarelo))

    # ------------------------------------------------ PROJETOS
    $limiteParado = (Get-Date).AddMonths(-$MesesParado)
    Titulo "PASTAS QUE MAIS OCUPAM ESPAÇO (parado = sem mexer há mais de $MesesParado meses)"
    $top = $pastas.GetEnumerator() | Where-Object { $_.Value.bytes -ge 1GB } |
        Sort-Object { -$_.Value.bytes } | Select-Object -First 30
    foreach ($e in $top) {
        $v = $e.Value
        $parado = $v.ultima -lt $limiteParado
        $marca = if ($parado) { 'PARADO' } else { 'em uso' }
        $linha = "{0,10}  {1,-7} última alteração {2:dd/MM/yyyy}  {3}" -f (Tam $v.bytes), $marca, $v.ultima, $e.Key
        if ($parado) { Amarelo $linha } else { Info $linha }
        if ($v.midia -gt 0) { Info ("            vídeo/foto/áudio: {0}   arquivos de projeto: {1}" -f (Tam $v.midia), $v.projetos) }
        $json.projetos += [ordered]@{ caminho = $e.Key; bytes = $v.bytes; ultima = $v.ultima.ToString('s'); parado = $parado; midia = $v.midia; arquivosProjeto = $v.projetos }
    }

    # ------------------------------------------------ VERMELHO
    Titulo 'VERMELHO - NUNCA APAGAR SEM A STEPHANIE DECIDIR'
    Vermelho 'Pastas do Windows, Arquivos de Programas e ProgramData (nem foram lidas).'
    Vermelho 'Brutos de câmera, fotos RAW e áudio original (.mxf .r3d .braw .mov .mp4 .arw .cr3 .nef .wav ...).'
    Vermelho 'Arquivos de projeto (.prproj .aep .drp .lrcat .psd) de trabalhos ativos.'
    Vermelho 'Vídeos finais entregues a clientes (exportações).'
    Vermelho 'Documentos, contratos, notas fiscais e qualquer coisa do MEI.'
    Info ("Total de vídeo/foto/áudio encontrado: {0}" -f (Tam $totalMidia))

    $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Json -Encoding UTF8
    Titulo 'RESUMO'
    Ok ("Pode liberar já, sem medo (VERDE): {0}" -f (Tam $somaVerde))
    Info ("Para revisar junto (AMARELO):      {0}" -f (Tam $somaAmarelo))
    Info "Lista para o Claude: $Json"
}

# ================================================================ LIMPAR VERDE
function Executar-LimparVerde {
    Titulo 'APAGANDO SÓ O LIXO VERDE'
    if (-not (Test-Path -LiteralPath $Json)) { Aviso 'Rode o Mapa primeiro.'; return }
    $abertos = Programas-De-Edicao-Abertos
    if ($abertos) {
        Aviso ("Feche estes programas e tente de novo: {0}" -f ($abertos -join ', '))
        Aviso 'Apagar o cache com eles abertos pode travar o projeto.'
        return
    }
    $mapa = Get-Content -LiteralPath $Json -Raw -Encoding UTF8 | ConvertFrom-Json
    $limite = (Get-Date).AddDays(-$IdadeMinimaDias)
    $antes = @{}
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $antes[$_.DeviceID] = [double]$_.FreeSpace }
    foreach ($it in $mapa.verde) {
        # trava de segurança: só caminhos que batem com as regras verdes
        $permitido = ($it.tipo -eq 'arquivo' -and $it.caminho -match $RE_AUTOSAVE) -or
                     ($it.tipo -eq 'conteudo-pasta' -and ($REGRAS_VERDE | Where-Object { ($it.caminho + '\x') -match $_.Re }))
        if (-not $permitido) { Aviso "Ignorado (não é verde): $($it.caminho)"; continue }
        if (-not (Test-Path -LiteralPath $it.caminho)) { continue }
        if ($it.tipo -eq 'arquivo') {
            Remove-Item -LiteralPath $it.caminho -Force -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $it.caminho -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $limite } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $g = [double]$_.FreeSpace - $antes[$_.DeviceID]
        if ($g -gt 1MB) { Ok ("Unidade {0}: {1} liberados" -f $_.DeviceID, (Tam $g)) }
    }
    Ok 'Lixo verde apagado. Na próxima vez que abrir um projeto, o programa recria o que precisar.'
}

# ================================================================ QUARENTENA
function Executar-Quarentena {
    Titulo 'MOVENDO PARA A QUARENTENA (nada é apagado)'
    if (-not $Lista -or -not (Test-Path -LiteralPath $Lista)) { Aviso 'Informe -Lista com um caminho por linha.'; return }
    $hoje = Get-Date -Format 'yyyy-MM-dd'
    foreach ($c in (Get-Content -LiteralPath $Lista -Encoding UTF8 | Where-Object { $_.Trim() })) {
        $c = $c.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $c)) { Aviso "Não existe: $c"; continue }
        $full = (Resolve-Path -LiteralPath $c).ProviderPath
        if ($full -match '^[A-Za-z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\|$)' -or $full -match '^[A-Za-z]:\\?$') {
            Vermelho "Bloqueado por segurança: $full"; continue
        }
        $drive = $full.Substring(0, 3)
        $destBase = Join-Path $drive "$PASTA_QUARENTENA\$hoje"
        $dest = Join-Path $destBase $full.Substring(3)
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        $bytes = if ((Get-Item -LiteralPath $full -Force).PSIsContainer) {
            [double](Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        } else { [double](Get-Item -LiteralPath $full -Force).Length }
        try {
            Move-Item -LiteralPath $full -Destination $dest -Force -ErrorAction Stop
            [pscustomobject]@{ original = $full; destino = $dest; bytes = $bytes; data = (Get-Date).ToString('s') } |
                Export-Csv -LiteralPath (Join-Path $destBase 'manifesto.csv') -Append -NoTypeInformation -Encoding UTF8
            Ok ("{0,10}  {1}" -f (Tam $bytes), $full)
        } catch { Aviso "Não consegui mover (arquivo aberto?): $full" }
    }
    Info ''
    Info "Tudo foi para X:\$PASTA_QUARENTENA\$hoje no mesmo disco."
    Info "Fica lá $DiasQuarentena dias. Se algo fizer falta, use Desfazer."
    Aviso 'O espaço só é liberado quando a quarentena for esvaziada.'
}

function Pastas-Quarentena {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $q = Join-Path ($_.DeviceID + '\') $PASTA_QUARENTENA
        if (Test-Path -LiteralPath $q) { Get-ChildItem -LiteralPath $q -Directory -Force }
    }
}

function Executar-Desfazer {
    Titulo 'DEVOLVENDO ITENS DA QUARENTENA'
    foreach ($d in @(Pastas-Quarentena)) {
        $man = Join-Path $d.FullName 'manifesto.csv'
        if (-not (Test-Path -LiteralPath $man)) { continue }
        foreach ($r in (Import-Csv -LiteralPath $man -Encoding UTF8)) {
            if (-not (Test-Path -LiteralPath $r.destino)) { continue }
            if (Test-Path -LiteralPath $r.original) { Aviso "Já existe no lugar original, deixei na quarentena: $($r.original)"; continue }
            New-Item -ItemType Directory -Path (Split-Path $r.original -Parent) -Force | Out-Null
            Move-Item -LiteralPath $r.destino -Destination $r.original -Force
            Ok "Devolvido: $($r.original)"
        }
    }
}

function Executar-EsvaziarQuarentena {
    Titulo "ESVAZIANDO QUARENTENA (só itens com mais de $DiasQuarentena dias)"
    $limite = (Get-Date).AddDays(-$DiasQuarentena)
    foreach ($d in @(Pastas-Quarentena)) {
        $data = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($d.Name, 'yyyy-MM-dd', $null, 'None', [ref]$data)) { continue }
        if ($data -gt $limite) { Info "Mantido (ainda recente): $($d.FullName)"; continue }
        $b = [double](Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Ok ("{0,10} liberados  ({1})" -f (Tam $b), $d.FullName)
    }
}

# ================================================================ MANUTENÇÃO SEMANAL
function Executar-Agendar {
    Titulo 'MANUTENÇÃO AUTOMÁTICA SEMANAL'
    $s = $PSCommandPath.Replace("'", "''")
    $cmd = @(
        "& '$s' -Acao Mapa -SemPausa -Relatorio (Join-Path `$env:TEMP 'mapa-semanal.txt')"
        "& '$s' -Acao LimparVerde -IdadeMinimaDias 30 -SemPausa -Relatorio (Join-Path `$env:TEMP 'limpeza-semanal.txt')"
        "& '$s' -Acao EsvaziarQuarentena -DiasQuarentena 30 -SemPausa -Relatorio (Join-Path `$env:TEMP 'quarentena-semanal.txt')"
    ) -join '; '
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
    $gatilho = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 12:00
    $config = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    try {
        Register-ScheduledTask -TaskName 'Manutencao PC - Limpeza Semanal' -Action $acao -Trigger $gatilho -Settings $config -Force -ErrorAction Stop | Out-Null
        Ok 'Agendado: todo domingo ao meio-dia (ou assim que o PC ligar depois disso).'
        Info 'Ela apaga só caches com mais de 30 dias e quarentenas com mais de 30 dias.'
        Info 'Nunca toca em projetos, brutos ou documentos.'
        Info 'Para remover: Agendador de Tarefas > "Manutencao PC - Limpeza Semanal" > Excluir.'
    } catch { Aviso "Não consegui agendar: $($_.Exception.Message)" }
}

# ================================================================ EXECUÇÃO
switch ($Acao) {
    'Mapa'               { Executar-Mapa }
    'LimparVerde'        { Executar-LimparVerde }
    'Quarentena'         { Executar-Quarentena }
    'Desfazer'           { Executar-Desfazer }
    'EsvaziarQuarentena' { Executar-EsvaziarQuarentena }
    'AgendarManutencao'  { Executar-Agendar }
}

Info ''
Info "Relatório salvo em: $Relatorio"
Stop-Transcript | Out-Null
if (-not $SemPausa) { Read-Host 'Pressione ENTER para fechar' }
