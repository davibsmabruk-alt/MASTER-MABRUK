import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'limpa-pc',
  component: 'Pane',
  requestId: 'limpa-pc',
  props: {
    title: 'Limpeza do PC',
    isFocused: false,
    bodyColumns: 50,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

test('mostra os dois botões e avisa quando não é Windows', async ($, on) => {
  on('process.run', () => {
    throw new Error('powershell.exe not found')
  })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ key: 'analisar' })).toBeTruthy()
    expect(await ui.find({ key: 'limpar' })).toBeTruthy()
    await ui.press({ key: 'analisar' })
    const aviso = await ui.find({ type: 'Text', text: /computador Windows/ })
    expect(aviso).toBeTruthy()
    await ui.press({ key: 'voltar' })
    await ui.unmount()
  }
})

test('no Windows, mostra o resumo do relatório', async ($, on) => {
  on('process.run', () => ({ value: { exitCode: 0, stdout: 'C:\\Temp\\\r\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('process.spawn', async function* () {
    yield { stream: 'stdout' as const, text: 'ok' }
    return { value: { code: 0, signal: null } }
  })
  on('fs.read', () => ({
    value:
      '\uFEFF**********************\r\nTranscrição do Windows PowerShell\r\n**********************\r\n' +
      '  Memória RAM  : 8,00 GB total, 91% em uso\r\n  [!] RAM quase cheia\r\n' +
      '  Top processo  123 MB\r\n**********************\r\nFim\r\n**********************\r\n',
  }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'analisar' })
  expect(await ui.find({ type: 'Text', text: /Memória RAM/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /⚠ RAM quase cheia/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /Top processo/ })).toBeFalsy()
  await ui.press({ key: 'detalhes' })
  expect(await ui.find({ type: 'Text', text: /Top processo/ })).toBeTruthy()
  await ui.unmount()
})

test('depois do mapa aparecem os botões do verde e do amarelo', async ($, on) => {
  on('process.run', () => ({ value: { exitCode: 0, stdout: 'C:\\Temp\\', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('process.spawn', async function* () {
    yield { stream: 'stdout' as const, text: 'ok' }
    return { value: { code: 0, signal: null } }
  })
  on('fs.read', () => ({
    value: '  [VERDE]   12,40 GB  Cache de mídia do Adobe\r\n  [AMARELO]  80,00 GB  PARADO  D:\\Projetos\\Cliente X\r\n',
  }))
  let enviado = ''
  on('prompt.submit', (_, e) => {
    enviado = e.text
    return { text: e.text }
  })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ key: 'verde' })).toBeFalsy()
  await ui.press({ key: 'mapa' })
  expect(await ui.find({ type: 'Text', text: /🟢 +12,40 GB/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /🟡 +80,00 GB/ })).toBeTruthy()
  expect(await ui.find({ key: 'verde' })).toBeTruthy()
  await ui.press({ key: 'amarelo' })
  expect(enviado).toContain('especialista-armazenamento')
  await ui.unmount()
})
