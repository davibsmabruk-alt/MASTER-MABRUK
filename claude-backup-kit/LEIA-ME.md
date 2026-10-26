# Kit de backup do Claude Code

Leva skills, comandos, subagentes, CLAUDE.md, settings, plugins e MCPs de uma máquina para outra.

## Na máquina ANTIGA (a que tem tudo configurado)

```bash
curl -fsSLO https://raw.githubusercontent.com/davibsmabruk-alt/MASTER-MABRUK/claude/code-environment-backup-30atq2/claude-backup-kit/backup.sh
bash backup.sh
```

O script:
1. Mostra o inventário completo e **pergunta antes de copiar qualquer coisa**.
2. Cria `~/claude-backup/` com:
   - `global/`: skills, comandos, agentes, output styles, hooks, CLAUDE.md e `settings.json` **sem chaves/tokens/senhas** (viram `<PREENCHER>`)
   - `projects/`: `.claude/` e `CLAUDE.md` de cada projeto onde você já usou o Claude Code
   - `plugins.json` e `mcp-servers.json` (segredos removidos)
   - `skills-zip/`: cada skill em um `.zip`, pronto para subir no claude.ai
   - `install.sh` para a máquina nova
   - `README.md` com inventário, resumo do fluxo de trabalho e lista do que precisa de ação manual
3. No final, pergunta se você quer que o próprio Claude leia tudo e escreva um resumo detalhado do seu fluxo no README.

Projetos que nunca foram abertos no Claude Code: passe a pasta como argumento, por exemplo `bash backup.sh ~/meu-projeto`.

## Na máquina NOVA

1. Instale o Claude Code e faça login.
2. Copie a pasta `claude-backup/` (pendrive, Drive etc.).
3. Preencha os `<PREENCHER>` indicados no fim do `README.md`.
4. `cd claude-backup && bash install.sh`

O `install.sh` guarda o que já existia em `~/.claude/antes-do-restore-<data>/` antes de sobrescrever, então pode ser rodado de novo sem perigo.

Requisitos: macOS ou Linux (no Windows, use WSL) e `python3`.
