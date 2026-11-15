export type Fase = 'inicio' | 'analisando' | 'limpando' | 'pronto' | 'erro' | 'semWindows'

export type Tela = {
  fase: Fase
  titulo: string
  mensagem: string
  linhas: string[]
  verTudo: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'limpa-pc': { tela: Shaped<Tela> }
  }
}
