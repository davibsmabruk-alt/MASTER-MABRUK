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
}

const tela = atom({ plugin: 'limpa-pc', key: 'tela' } as const, INICIAL, {
  shape: 'tela-1',
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

// ---------------------------------------------------------------- Relatório

/** Tira o cabeçalho/rodapé do Start-Transcript e as linhas decorativas. */
function limparRelatorio(bruto: string): string[] {
  const out: string[] = []
  let dentroCabecalho = false
  for (const linha0 of bruto.replace(/^﻿/, '').split(/\r?\n/)) {
    const linha = linha0.replace(/\s+$/, '')
    if (/^\*{10,}/.test(linha)) {
      dentroCabecalho = !dentroCabecalho
      continue
    }
    if (dentroCabecalho) continue
    const t = linha.trim()
    if (!t || /^=+$/.test(t)) continue
    if (/^(Transcri|Relatório sendo salvo|Relatório completo|Pressione ENTER)/.test(t)) continue
    if (/^AGENTE DE LIMPEZA/.test(t)) continue
    out.push(t)
  }
  return out
}

/** Só o que importa para uma pessoa leiga. */
function resumo(linhas: string[]): string[] {
  return linhas.filter(
    l =>
      l.startsWith('[OK]') ||
      l.startsWith('[!]') ||
      /^(Sistema|Processador|Memória RAM|Ligado há|Unidade [A-Z]:  livre|TOTAL ESTIMADO)/.test(l),
  )
}

// ---------------------------------------------------------------- Ações

async function analisar($: EngineInterface) {
  await update($, tela, (): Tela => ({
    ...INICIAL,
    fase: 'analisando',
    mensagem: 'Olhando o seu PC... leva uns 30 segundos a 2 minutos.',
  }))
  const temp = await pastaTemp($)
  if (!temp) return update($, tela, (t): Tela => ({ ...t, fase: 'semWindows' }))

  const script = `${$.plugin.root}\\hooks\\Otimizar-PC.ps1`
  const rel = `${temp}limpa-pc-analise.txt`
  const r = await rodar($, [
    'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script,
    '-Modo', 'Diagnostico', '-Relatorio', rel, '-SemPausa',
  ])
  await mostrarResultado($, rel, r, 'Como está o seu PC')
}

async function limpar($: EngineInterface) {
  await update($, tela, (): Tela => ({
    ...INICIAL,
    fase: 'limpando',
    mensagem:
      'O Windows vai perguntar "Deseja permitir que este aplicativo faça alterações?". Clique em SIM.\n' +
      'Depois é só esperar: leva de 5 a 20 minutos. Pode continuar usando o PC.',
  }))
  const temp = await pastaTemp($)
  if (!temp) return update($, tela, (t): Tela => ({ ...t, fase: 'semWindows' }))

  const script = `${$.plugin.root}\\hooks\\Otimizar-PC.ps1`
  const rel = `${temp}limpa-pc-limpeza.txt`
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', `"${script}"`,
    '-Modo', 'Completo', '-Relatorio', `"${rel}"`, '-SemPausa',
  ]
  const cmd = [
    'try {',
    `  $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @(${args.map(aspas).join(',')})`,
    '  exit $p.ExitCode',
    '} catch { Write-Output "PERMISSAO_NEGADA"; exit 5 }',
  ].join('\n')
  const r = await rodar($, [
    'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', codificar(cmd),
  ])
  if (r.texto.includes('PERMISSAO_NEGADA')) {
    return update($, tela, (): Tela => ({
      ...INICIAL,
      fase: 'erro',
      mensagem:
        'O Windows não recebeu o "Sim". Sem essa permissão eu não consigo limpar.\n' +
        'Clique em "Limpar e deixar rápido" de novo e, quando a janela aparecer, clique em SIM.',
    }))
  }
  await mostrarResultado($, rel, r, 'Pronto! Seu PC foi limpo e otimizado')
}

async function mostrarResultado(
  $: EngineInterface,
  rel: string,
  r: { code: number | null; texto: string },
  titulo: string,
) {
  let bruto = ''
  try {
    bruto = await $.fs.read(rel)
  } catch {
    return update($, tela, (): Tela => ({
      ...INICIAL,
      fase: 'erro',
      mensagem: `Algo deu errado (código ${r.code}). Peça ajuda ao Claude no chat e cole isto:\n${r.texto.slice(-1500)}`,
    }))
  }
  await update($, tela, (): Tela => ({
    ...INICIAL,
    fase: 'pronto',
    titulo,
    linhas: limparRelatorio(bruto),
  }))
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
    const ocupado = t.fase === 'analisando' || t.fase === 'limpando'

    const botoes = (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="column">
          <Button key="analisar" hotkey="1" variant="secondary" onPress={() => void analisar($)}>
            1 · Ver como está meu PC
          </Button>
          <Text dimColor>Só olha. Não muda nada.</Text>
        </Box>
        <Box flexDirection="column">
          <Button key="limpar" hotkey="2" variant="primary" onPress={() => void limpar($)}>
            2 · Limpar e deixar rápido
          </Button>
          <Text dimColor>O Windows vai pedir permissão: clique em SIM.</Text>
        </Box>
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

    if (ocupado) {
      return (
        <Box flexDirection="column" gap={1}>
          <Text bold>{t.fase === 'analisando' ? '🔍 Analisando…' : '🧹 Limpando…'}</Text>
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
      const foiLimpeza = t.linhas.some(l => l.startsWith('ESPAÇO LIBERADO') || l.includes('ESPAÇO LIBERADO'))
      return (
        <Box flexDirection="column" gap={1}>
          <Text bold>✅ {t.titulo}</Text>
          <Box flexDirection="column">
            {mostrar.map(l => (
              <Text
                color={l.startsWith('[OK]') ? 'green' : l.startsWith('[!]') ? 'yellow' : undefined}
                bold={/^[A-ZÁÉÍÓÚÇÃÕ0-9 ()-]{6,}$/.test(l)}
                wrap="wrap"
              >
                {l.replace(/^\[OK\]/, '✔').replace(/^\[!\]/, '⚠')}
              </Text>
            ))}
          </Box>
          {foiLimpeza && <Text bold>Reinicie o computador para terminar.</Text>}
          <Button
            key="detalhes"
            dimColor
            onPress={() => void update($, tela, x => ({ ...x, verTudo: !x.verTudo }))}
          >
            {t.verTudo ? 'Mostrar só o resumo' : 'Mostrar relatório completo'}
          </Button>
          {botoes}
        </Box>
      )
    }

    return (
      <Box flexDirection="column" gap={1}>
        <Text bold>🧹 Deixe seu PC limpo e rápido</Text>
        <Text>Clique em um botão. Eu faço o resto.</Text>
        {botoes}
      </Box>
    )
  })
}
