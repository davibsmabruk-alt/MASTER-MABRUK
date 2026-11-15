# Agente de Limpeza e Performance do PC (Windows 10/11)

## Jeito mais fácil
1. Baixe a pasta `pc-agent` para o seu PC.
2. Dê dois cliques em **`AGENTE-PC.bat`** e aceite o pedido de administrador.
3. Siga esta ordem no menu:
   - **1 – Diagnóstico**: mostra o que está deixando o PC lento (não altera nada).
   - **2 – Simular limpeza**: mostra quanto espaço será liberado.
   - **5 – Completo**: limpa e otimiza de verdade.
4. Reinicie o PC.

O relatório de cada execução fica salvo na sua **Área de Trabalho** (`Relatorio-PC_<data>.txt`).

## O que ele faz
| Etapa | Ações |
|---|---|
| Diagnóstico | CPU, RAM, discos (SSD/HD e saúde), espaço livre, top processos, programas na inicialização, lixo acumulado |
| Limpeza | Temporários, cache do Windows Update, relatórios de erro, caches de navegador (Chrome/Edge/Brave/Opera/Firefox — **sem** apagar senhas, histórico ou cookies), miniaturas, Otimização de Entrega, componentes antigos do Windows (DISM), DNS |
| Otimização | Ponto de restauração, plano de energia Alto desempenho (desktop), TRIM no SSD / desfrag no HD, desliga gravação em 2º plano do Game Bar |
| Opcionais | `-Reparar` (SFC + DISM), `-EfeitosVisuaisLeves`, `-EsvaziarLixeira` |

## Segurança
- Nunca toca em documentos, fotos, downloads ou senhas.
- Cria ponto de restauração antes de mudar configurações (Painel de Controle > Recuperação para desfazer).
- Não desativa antivírus, firewall nem Windows Update.

## Usando com o Claude Code no seu PC
Com o Claude Code instalado no Windows, abra este repositório e peça:
> "use o agente pc-performance para limpar e otimizar meu PC"

O agente (`.claude/agents/pc-performance.md`) roda o diagnóstico, explica os problemas, pede sua confirmação e executa a limpeza.

## Liberar espaço nos discos (SSD / NVMe / HD) — `Mapa-Espaco.ps1`
Feito para PC de edição de vídeo/foto. Clique com o botão direito > **Executar com o PowerShell**, ou use o painel do Claude.

| Cor | O que é | O que acontece |
|---|---|---|
| 🟢 Verde | Caches do Premiere/After Effects/DaVinci/Camera Raw, previews renderizados, cópias automáticas além das 3 mais novas | `-Acao LimparVerde` apaga. Os programas recriam sozinhos |
| 🟡 Amarelo | Projetos parados há 6+ meses, proxies, duplicados, instaladores antigos | Só com um "sim", indo para a **quarentena** (`X:\_QUARENTENA_LIMPEZA`). `-Acao Desfazer` devolve tudo |
| 🔴 Vermelho | Brutos, RAW, arquivos de projeto, vídeos finais, documentos, Windows | Nunca é apagado pela ferramenta |

Também mostra a saúde de cada disco (desgaste, temperatura, erros) e alerta quando um SSD passa de 80% cheio.
`-Acao AgendarManutencao` liga uma limpeza automática de caches velhos todo domingo.
