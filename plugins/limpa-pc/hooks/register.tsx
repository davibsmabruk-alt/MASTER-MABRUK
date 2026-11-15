import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Tela } from '../types'

const PANE = 'limpa-pc'
const TITULO = 'Limpeza do PC'

const INICIAL: Tela = {
  fase: 'inicio',
  titulo: '',
  mensagem: '',
  linhas: [],
  verTudo: false,
  temMapa: false,
}

// Mude a etiqueta quando os campos de Tela mudarem: o valor antigo é recusado.
const tela = atom({ plugin: 'limpa-pc', key: 'tela' } as const, INICIAL, {
  shape: 'tela-2',
})

// ---------------------------------------------------------------- PowerShell

/** Codifica um comando para `powershell -EncodedCommand` (UTF-16LE em base64). */
function codificar(cmd: string): string {
  let bin = ''
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd.charCodeAt(i)
    bin += String.fromCharCode(c & 0xff, c >> 8)
  }
  return btoa(bin)
}

/** Texto seguro dentro de aspas simples do PowerShell. */
const aspas = (s: string) => `'${s.replace(/'/g, "''")}'`

/** Pasta temporária do Windows; `null` quando não há PowerShell (não é Windows). */
async function pastaTemp($: EngineInterface): Promise<string | null> {
  try {
    const r = await $.process.run(
      ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', '[IO.Path]::GetTempPath()'],
      { timeoutMs: 30_000 },
    )
    const p = r.stdout.trim()
    return r.exitCode === 0 && p ? p : null
  } catch {
    return null
  }
}

/** Roda até o fim, sem limite de tempo; devolve o código de saída e o texto. */
async function rodar($: EngineInterface, argv: string[]) {
  const filho = $.process.spawn({ argv })
  let texto = ''
  for await (const { text } of filho) texto += text
  const fim = await filho.result
  return { code: fim.code, texto }
}

const script = ($: EngineInterface, nome: string) => `${$.plugin.root}\\hooks\\${nome}`

// ---------------------------------------------------------------- Relatório

/** Tira o cabeçalho/rodapé do Start-Transcript e as linhas decorativas. */
function limparRelatorio(bruto: string): string[] {
  const out: string[] = []
  let dentroCabecalho = false
  for (const linha0 of bruto.replace(/^﻿/, '').split(/\r?\n/)) {
    const t = linha0.trim()
    if (/^\*{10,}/.test(t)) {
      dentroCabecalho = !dentroCabecalho
      continue
    }
    if (dentroCabecalho || !t || /^=+$/.test(t)) continue
    if (/^(Transcri|Relatório sendo salvo|Relatório completo|Relatório salvo|Pressione ENTER|Lista para o Claude)/.test(t)) continue
    if (/^AGENTE DE LIMPEZA|^\.\.\. [\d.,]+ arquivos lidos/.test(t)) continue
    out.push(t)
  }
  return out
}

/** Só o que importa para uma pessoa leiga. */
function resumo(linhas: string[]): string[] {
  return linhas.filter(
    l =>
      /^\[(OK|!|VERDE|AMARELO|VERMELHO)\]/.test(l) ||
      /^(Sistema|Processador|Memória RAM|Ligado há|Unidade [A-Z]:  livre|TOTAL ESTIMADO)/.test(l),
  )
}

const ICONES: [RegExp, string, string | undefined][] = [
  [/^\[OK\]\s*/, '✔ ', 'green'],
  [/^\[VERDE\]\s*/, '🟢 ', 'green'],
  [/^\[AMARELO\]\s*/, '🟡 ', 'yellow'],
  [/^\[VERMELHO\]\s*/, '🔴 ', 'red'],
  [/^\[!\]\s*/, '⚠ ', 'yellow'],
]

function enfeitar(l: string): { texto: string; cor?: string } {
  for (const [re, icone, cor] of ICONES) if (re.test(l)) return { texto: l.replace(re, icone), cor }
  return { texto: l }
}

// ---------------------------------------------------------------- Ações

type Tarefa = {
  titulo: string
  espera: string
  arquivo: string
  /** argumentos do script, sem -Relatorio/-SemPausa */
  args: string[]
  /** precisa do "Sim" do Windows */
  admin?: boolean
  marcaMapa?: boolean
}

const TAREFAS = {
  analisar: {
    titulo: 'Como está o seu PC',
    espera: 'Olhando o seu PC... leva de 30 segundos a 2 minutos.',
    arquivo: 'Otimizar-PC.ps1',
    args: ['-Modo', 'Diagnostico'],
  },
  mapa: {
    titulo: 'O que está ocupando espaço',
    espera:
      'Lendo todos os discos. Isso NÃO apaga nada.\nPode levar de 5 a 30 minutos se os discos forem grandes. Pode continuar usando o PC.',
    arquivo: 'Mapa-Espaco.ps1',
    args: ['-Acao', 'Mapa'],
    marcaMapa: true,
  },
  verde: {
    titulo: 'Lixo verde apagado',
    espera: 'Apagando só o lixo verde (caches que os programas recriam sozinhos)...',
    arquivo: 'Mapa-Espaco.ps1',
    args: ['-Acao', 'LimparVerde'],
    marcaMapa: true,
  },
  agendar: {
    titulo: 'Manutenção semanal ligada',
    espera: 'Criando a manutenção automática de todo domingo...',
    arquivo: 'Mapa-Espaco.ps1',
    args: ['-Acao', 'AgendarManutencao'],
    marcaMapa: true,
  },
  windows: {
    titulo: 'Pronto! O Windows foi limpo e otimizado',
    espera:
      'O Windows vai perguntar "Deseja permitir que este aplicativo faça alterações?". Clique em SIM.\nDepois é só esperar: leva de 5 a 20 minutos.',
    arquivo: 'Otimizar-PC.ps1',
    args: ['-Modo', 'Completo'],
    admin: true,
  },
} satisfies Record<string, Tarefa>

async function executar($: EngineInterface, tarefa: Tarefa) {
  const temMapa = (await read($, tela)).temMapa
  await update($, tela, (): Tela => ({ ...INICIAL, temMapa, fase: 'trabalhando', titulo: tarefa.titulo, mensagem: tarefa.espera }))

  const temp = await pastaTemp($)
  if (!temp) return update($, tela, (t): Tela => ({ ...t, fase: 'semWindows' }))

  const rel = `${temp}limpa-pc-${Date.now()}.txt`
  const caminho = script($, tarefa.arquivo)
  let r: { code: number | null; texto: string }

  if (tarefa.admin) {
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', `"${caminho}"`, ...tarefa.args, '-Relatorio', `"${rel}"`, '-SemPausa']
    const cmd = [
      'try {',
      `  $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @(${args.map(aspas).join(',')})`,
      '  exit $p.ExitCode',
      '} catch { Write-Output "PERMISSAO_NEGADA"; exit 5 }',
    ].join('\n')
    r = await rodar($, ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', codificar(cmd)])
    if (r.texto.includes('PERMISSAO_NEGADA')) {
      return update($, tela, (): Tela => ({
        ...INICIAL,
        temMapa,
        fase: 'erro',
        mensagem:
          'O Windows não recebeu o "Sim". Sem essa permissão eu não consigo limpar o Windows.\n' +
          'Clique no botão de novo e, quando a janela aparecer, clique em SIM.',
      }))
    }
  } else {
    r = await rodar($, [
      'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', caminho,
      ...tarefa.args, '-Relatorio', rel, '-SemPausa',
    ])
  }

  let bruto = ''
  try {
    bruto = await $.fs.read(rel)
  } catch {
    return update($, tela, (): Tela => ({
      ...INICIAL,
      temMapa,
      fase: 'erro',
      mensagem: `Algo deu errado (código ${r.code}). Peça ajuda ao Claude no chat e cole isto:\n${r.texto.slice(-1500)}`,
    }))
  }
  await update($, tela, (): Tela => ({
    ...INICIAL,
    temMapa: temMapa || !!tarefa.marcaMapa,
    fase: 'pronto',
    titulo: tarefa.titulo,
    linhas: limparRelatorio(bruto),
  }))
}

async function revisarAmarelo($: EngineInterface) {
  await $.prompt.submit({
    asUser: true,
    text:
      'Use a skill especialista-armazenamento. Acabei de rodar o Mapa do Espaço pelo painel ' +
      '(a lista está em %TEMP%\\mapa-espaco.json). Me ajude a revisar os itens AMARELOS, ' +
      'um grupo por vez, do maior para o menor. Me explique cada um com calma e só mande ' +
      'para a quarentena o que eu disser que pode.',
  })
}

// ---------------------------------------------------------------- Registro

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({ name: 'limpar-pc', description: 'Abre o painel de limpeza do PC' })
    void $.ui.open({ id: PANE, title: TITULO })
    return started
  })

  on('command.run', { command: 'limpar-pc' }, async $ => {
    await $.ui.open({ id: PANE, title: TITULO })
    return { text: 'Painel "Limpeza do PC" aberto.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const t = await read($, tela)

    const opcao = (key: string, hotkey: string, rotulo: string, ajuda: string, acao: () => unknown, primario = false) => (
      <Box flexDirection="column">
        <Button key={key} hotkey={hotkey} variant={primario ? 'primary' : 'secondary'} onPress={() => void acao()}>
          {rotulo}
        </Button>
        <Text dimColor>{ajuda}</Text>
      </Box>
    )

    const botoes = (
      <Box flexDirection="column" gap={1}>
        {t.temMapa && (
          <Box flexDirection="column" gap={1}>
            <Text bold>Depois do mapa:</Text>
            {opcao('verde', 'v', 'Apagar só o lixo verde', 'Caches e cópias automáticas antigas. Feche o Premiere/After Effects/DaVinci antes.', () => executar($, TAREFAS.verde), true)}
            {opcao('amarelo', 'a', 'Revisar o amarelo com a especialista', 'Ela explica cada item no chat. Nada sai sem o seu "sim", e dá para desfazer.', () => revisarAmarelo($))}
            {opcao('agendar', 'm', 'Ligar manutenção automática', 'Todo domingo apaga caches velhos sozinho. Nunca mexe em projetos.', () => executar($, TAREFAS.agendar))}
          </Box>
        )}
        <Text bold>Começar:</Text>
        {opcao('analisar', '1', '1 · Ver como está meu PC', 'Só olha. Não muda nada.', () => executar($, TAREFAS.analisar))}
        {opcao('mapa', '2', '2 · Ver o que ocupa espaço nos discos', 'Separa tudo em verde, amarelo e vermelho. Não apaga nada.', () => executar($, TAREFAS.mapa), !t.temMapa)}
        {opcao('limpar', '3', '3 · Limpar e acelerar o Windows', 'O Windows vai pedir permissão: clique em SIM.', () => executar($, TAREFAS.windows))}
      </Box>
    )

    if (t.fase === 'semWindows') {
      return (
        <Box flexDirection="column" gap={1}>
          <Text bold>Este painel precisa estar no seu computador Windows.</Text>
          <Text>
            Agora ele está aberto num servidor na nuvem, que não é o seu PC. Abra o app Claude no seu
            computador, na aba Code, escolha rodar no seu computador (não na nuvem) e instale este mod
            lá. Peça ajuda ao Claude no chat se precisar.
          </Text>
          <Button key="voltar" dimColor onPress={() => void update($, tela, () => INICIAL)}>
            Voltar
          </Button>
        </Box>
      )
    }

    if (t.fase === 'trabalhando') {
      return (
        <Box flexDirection="column" gap={1}>
          <Text bold>⏳ {t.titulo}…</Text>
          {t.mensagem.split('\n').map(l => (
            <Text>{l}</Text>
          ))}
          <Text dimColor>Não feche o Claude enquanto isso.</Text>
        </Box>
      )
    }

    if (t.fase === 'erro') {
      return (
        <Box flexDirection="column" gap={1}>
          <Text bold color="yellow">⚠ Não deu certo</Text>
          {t.mensagem.split('\n').map(l => (
            <Text>{l}</Text>
          ))}
          {botoes}
        </Box>
      )
    }

    if (t.fase === 'pronto') {
      const mostrar = t.verTudo ? t.linhas : resumo(t.linhas)
      const reiniciar = t.linhas.some(l => l.includes('Reinicie o computador'))
      return (
        <Box flexDirection="column" gap={1}>
          <Text bold>✅ {t.titulo}</Text>
          <Box flexDirection="column">
            {mostrar.map(l => {
              const { texto, cor } = enfeitar(l)
              return (
                <Text color={cor} bold={/^[A-ZÁÉÍÓÚÇÃÕÂÊ0-9 ()/:.-]{8,}$/.test(l)} wrap="wrap">
                  {texto}
                </Text>
              )
            })}
          </Box>
          {reiniciar && <Text bold>Reinicie o computador para terminar.</Text>}
          <Button key="detalhes" dimColor onPress={() => void update($, tela, (x): Tela => ({ ...x, verTudo: !x.verTudo }))}>
            {t.verTudo ? 'Mostrar só o resumo' : 'Mostrar relatório completo'}
          </Button>
          {botoes}
        </Box>
      )
    }

    return (
      <Box flexDirection="column" gap={1}>
        <Text bold>🧹 Deixe seu PC limpo, rápido e com espaço</Text>
        <Text>Clique em um botão. Nada importante é apagado sem você dizer "sim".</Text>
        <Text dimColor>🟢 verde = lixo seguro · 🟡 amarelo = revisar junto · 🔴 vermelho = não mexer</Text>
        {botoes}
      </Box>
    )
  })
}
