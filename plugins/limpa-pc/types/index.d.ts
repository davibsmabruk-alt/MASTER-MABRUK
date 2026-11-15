export type Fase = 'inicio' | 'trabalhando' | 'pronto' | 'erro' | 'semWindows'

export type Tela = {
  fase: Fase
  titulo: string
  mensagem: string
  linhas: string[]
  verTudo: boolean
  /** Já existe um mapa do espaço: mostra os botões de limpeza do verde e da revisão. */
  temMapa: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'limpa-pc': { tela: Shaped<Tela> }
  }
}
