#!/usr/bin/env bash
# backup.sh — monta ~/claude-backup/ com todo o seu ambiente do Claude Code.
#
# Uso (na máquina ANTIGA, a que tem tudo configurado):
#   bash backup.sh              # mostra o inventário, pede confirmação e copia
#   bash backup.sh -y           # sem perguntar
#   bash backup.sh ~/proj1 ...  # inclui projetos extras além dos detectados
#
# Variáveis opcionais: CLAUDE_BACKUP_DIR (padrão ~/claude-backup)
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "Erro: precisa do python3 instalado (macOS: xcode-select --install)." >&2
  exit 1
fi

PYCODE=$(cat <<'PYEOF'
import json, os, re, shutil, subprocess, sys, time
from pathlib import Path

HOME = Path.home()
SRC = HOME / ".claude"
OUT = Path(os.environ.get("CLAUDE_BACKUP_DIR", HOME / "claude-backup")).expanduser()
PLACE = "<PREENCHER>"
SKIP_NAMES = {".git", "node_modules", "__pycache__", ".DS_Store", ".venv", "venv"}
SECRET_FILES = re.compile(r"(^\.env(\..*)?$|\.pem$|\.key$|\.p12$|credentials|\.credentials\.json$)", re.I)
SENS_KEY = re.compile(r"(api[_-]?key|apikey|token|secret|passw|pwd|auth|credential|bearer|cookie|private[_-]?key|access[_-]?key|session[_-]?id)", re.I)
SENS_VAL = re.compile(
    r"(sk-[A-Za-z0-9_\-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_\w{20,}|xox[abposr]-[\w\-]{10,}"
    r"|AKIA[0-9A-Z]{16}|AIza[\w\-]{30,}|eyJ[\w\-]{10,}\.[\w\-]{10,}\.[\w\-]+|(?<=Bearer )\S{8,}|ntn_\w{20,}|secret_\w{20,})")

args = [a for a in sys.argv[1:] if not a.startswith("-")]
auto_yes = any(a in ("-y", "--yes") for a in sys.argv[1:])
manual = []        # avisos de ação manual na máquina nova
secret_hits = []   # possíveis segredos dentro de arquivos copiados

# ---------- utilidades ----------
def redact(obj, key=""):
    if isinstance(obj, dict):
        return {k: redact(v, k) for k, v in obj.items()}
    if isinstance(obj, list):
        out, hide_next = [], False
        for x in obj:
            if isinstance(x, str) and hide_next and not x.startswith("-"):
                out.append(PLACE); hide_next = False; continue
            hide_next = isinstance(x, str) and x.startswith("-") and bool(SENS_KEY.search(x)) and "=" not in x
            if isinstance(x, str) and x.startswith("-") and "=" in x and SENS_KEY.search(x.split("=")[0]):
                out.append(x.split("=")[0] + "=" + PLACE); continue
            out.append(redact(x, key))
        return out
    if isinstance(obj, str):
        if key and SENS_KEY.search(key) and obj and not obj.startswith("${") and obj != PLACE:
            return PLACE
        return SENS_VAL.sub(PLACE, obj)
    return obj

def has_placeholder(obj):
    return PLACE in json.dumps(obj)

def load_json(p):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except Exception:
        return None

def frontmatter(md):
    try:
        txt = Path(md).read_text(encoding="utf-8", errors="replace")
    except Exception:
        return {}, ""
    meta, body = {}, txt
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", txt, re.S)
    if m:
        body = m.group(2)
        cur = None
        for line in m.group(1).splitlines():
            mm = re.match(r"^([A-Za-z0-9_\-]+):\s*(.*)$", line)
            if mm:
                cur = mm.group(1); meta[cur] = mm.group(2).strip().strip("\"'")
            elif cur and line.startswith((" ", "\t")):
                meta[cur] = (meta[cur] + " " + line.strip()).strip()
    if not meta.get("description"):
        for line in body.splitlines():
            s = line.strip().lstrip("#").strip()
            if s:
                meta["description"] = s[:200]; break
    return meta, body

def scan_secrets(path):
    for f in ([path] if path.is_file() else path.rglob("*")):
        if f.is_file() and f.stat().st_size < 2_000_000:
            try:
                txt = f.read_text(encoding="utf-8")
                if SENS_VAL.search(txt):
                    f.write_text(SENS_VAL.sub(PLACE, txt), encoding="utf-8")
                    secret_hits.append(str(f))
            except Exception:
                pass

def ignore(dirpath, names):
    out = set()
    for n in names:
        if n in SKIP_NAMES:
            out.add(n)
        elif SECRET_FILES.search(n):
            out.add(n); manual.append(f"Arquivo sensível NÃO copiado: {Path(dirpath)/n} (copie à mão se precisar)")
    return out

def copy(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst, ignore=ignore, dirs_exist_ok=True, symlinks=False)
    else:
        shutil.copy2(src, dst)
    scan_secrets(dst)

def short(s, n=160):
    s = " ".join(str(s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"

def slug(p):
    p = str(p)
    if p.startswith(str(HOME) + os.sep): p = p[len(str(HOME)) + 1:]
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", p.strip("/")) or "raiz"

# ---------- coleta ----------
def skills_in(base):
    res = []
    if base.is_dir():
        for d in sorted(base.iterdir()):
            if d.is_dir() and d.name != "synced" and (d / "SKILL.md").exists():
                meta, _ = frontmatter(d / "SKILL.md")
                res.append({"dir": d, "name": meta.get("name", d.name), "desc": meta.get("description", "")})
    return res

def commands_in(base):
    res = []
    if base.is_dir():
        for f in sorted(base.rglob("*.md")):
            meta, _ = frontmatter(f)
            name = "/" + ":".join(f.relative_to(base).with_suffix("").parts)
            res.append({"file": f, "name": name, "desc": meta.get("description", "")})
    return res

def agents_in(base):
    res = []
    if base.is_dir():
        for f in sorted(base.rglob("*.md")):
            meta, _ = frontmatter(f)
            res.append({"file": f, "name": meta.get("name", f.stem), "desc": meta.get("description", ""),
                        "model": meta.get("model", ""), "tools": meta.get("tools", "")})
    return res

g = {
    "skills": skills_in(SRC / "skills"),
    "commands": commands_in(SRC / "commands"),
    "agents": agents_in(SRC / "agents"),
    "output_styles": sorted((SRC / "output-styles").glob("*.md")) if (SRC / "output-styles").is_dir() else [],
    "claude_md": (SRC / "CLAUDE.md") if (SRC / "CLAUDE.md").exists() else None,
    "settings": load_json(SRC / "settings.json"),
    "extra_files": [p for p in [SRC / "keybindings.json", SRC / "settings.local.json"] if p.exists()],
    "scripts": [p for p in sorted(SRC.iterdir()) if p.is_file() and p.suffix in (".sh", ".py", ".js", ".mjs", ".ts")] if SRC.is_dir() else [],
    "hooks_dir": (SRC / "hooks") if (SRC / "hooks").is_dir() else None,
}

# plugins / marketplaces
km = load_json(SRC / "plugins" / "known_marketplaces.json") or {}
ip = load_json(SRC / "plugins" / "installed_plugins.json") or {}
marketplaces = []
for name, info in (km.items() if isinstance(km, dict) else []):
    s = (info or {}).get("source", {}) if isinstance(info, dict) else {}
    kind = s.get("source")
    arg = s.get("repo") if kind == "github" else s.get("url") if kind in ("git", "url") else s.get("path") if kind in ("directory", "file") else None
    if kind in ("directory", "file"):
        manual.append(f"Marketplace '{name}' é uma pasta local ({arg}): copie essa pasta para a máquina nova antes do install.sh")
    marketplaces.append({"name": name, "kind": kind, "source": arg})
plugins = []
pl = ip.get("plugins", {}) if isinstance(ip, dict) else {}
for pid, entry in pl.items():
    e = entry[0] if isinstance(entry, list) and entry else entry if isinstance(entry, dict) else {}
    plugins.append({"id": pid, "scope": e.get("scope", "user"), "projectPath": e.get("projectPath")})
enabled = (g["settings"] or {}).get("enabledPlugins", {}) or {}
for pid, on in enabled.items():
    if on and not any(p["id"] == pid for p in plugins):
        plugins.append({"id": pid, "scope": "user", "projectPath": None})

# MCPs (~/.claude.json) e projetos conhecidos
cj = load_json(HOME / ".claude.json") or {}
mcp_user = cj.get("mcpServers", {}) or {}
mcp_local, project_paths = {}, set()
for ppath, pinfo in (cj.get("projects", {}) or {}).items():
    if isinstance(pinfo, dict) and pinfo.get("mcpServers"):
        mcp_local[ppath] = pinfo["mcpServers"]
    project_paths.add(ppath)
project_paths |= {str(Path(a).expanduser().resolve()) for a in args}

projects = []
for pp in sorted(project_paths):
    p = Path(pp)
    if not p.is_dir() or p == HOME:
        continue
    item = {"path": p, "skills": skills_in(p / ".claude" / "skills"), "commands": commands_in(p / ".claude" / "commands"),
            "agents": agents_in(p / ".claude" / "agents"),
            "files": [f for f in [p / "CLAUDE.md", p / "CLAUDE.local.md", p / ".claude" / "CLAUDE.md", p / ".mcp.json",
                                   p / ".claude" / "settings.json", p / ".claude" / "settings.local.json"] if f.exists()],
            "dirs": [d for d in [p / ".claude" / "output-styles", p / ".claude" / "hooks"] if d.is_dir()]}
    if item["skills"] or item["commands"] or item["agents"] or item["files"] or item["dirs"]:
        projects.append(item)

# ---------- inventário na tela ----------
def show():
    print("\n================ INVENTÁRIO DO CLAUDE CODE ================\n")
    print(f"Origem: {SRC}\nDestino: {OUT}\n")
    def sec(t, items, fmt):
        print(f"{t} ({len(items)})")
        for i in items: print("   - " + fmt(i))
        if not items: print("   (nenhum)")
    sec("Skills globais", g["skills"], lambda s: f"{s['name']}: {short(s['desc'], 90)}")
    sec("Comandos globais", g["commands"], lambda c: f"{c['name']}: {short(c['desc'], 90)}")
    sec("Subagentes globais", g["agents"], lambda a: f"{a['name']}: {short(a['desc'], 90)}")
    sec("Output styles", g["output_styles"], lambda f: f.stem)
    print(f"CLAUDE.md global: {'sim' if g['claude_md'] else 'não'}")
    s = g["settings"]
    if s:
        print(f"settings.json: modelo={s.get('model', '(padrão)')}, "
              f"permissões allow={len((s.get('permissions') or {}).get('allow', []))} "
              f"deny={len((s.get('permissions') or {}).get('deny', []))}, "
              f"hooks={', '.join((s.get('hooks') or {}).keys()) or 'nenhum'}")
    else:
        print("settings.json: não existe")
    sec("Scripts/arquivos extras em ~/.claude", g["scripts"] + g["extra_files"] + ([g["hooks_dir"]] if g["hooks_dir"] else []), lambda f: f.name)
    sec("Marketplaces", marketplaces, lambda m: f"{m['name']} ({m['kind']}: {m['source']})")
    sec("Plugins", plugins, lambda p: f"{p['id']} [{p['scope']}]")
    sec("MCPs (escopo usuário)", list(mcp_user.items()), lambda kv: f"{kv[0]} ({kv[1].get('type', 'stdio')})")
    sec("MCPs (escopo local, por projeto)", [(k, n) for k, v in mcp_local.items() for n in v], lambda kv: f"{kv[1]} em {kv[0]}")
    print(f"Projetos com configuração própria ({len(projects)})")
    for p in projects:
        bits = [f"{len(p['skills'])} skills", f"{len(p['commands'])} comandos", f"{len(p['agents'])} agentes"] + [f.name for f in p["files"]]
        print(f"   - {p['path']}: " + ", ".join(bits))
    print("\nChaves de API, tokens e senhas serão trocados por " + PLACE + ".\n")

show()
if not auto_yes:
    try:
        ans = input("Copiar tudo isso para " + str(OUT) + "? [s/N] ").strip().lower()
    except EOFError:
        ans = ""
    if ans not in ("s", "sim", "y", "yes"):
        print("Nada foi copiado."); sys.exit(0)

# ---------- cópia ----------
if OUT.exists():
    old = OUT.with_name(OUT.name + ".antigo-" + time.strftime("%Y%m%d-%H%M%S"))
    OUT.rename(old); print(f"Backup anterior movido para {old}")
GL = OUT / "global"
GL.mkdir(parents=True)

for s in g["skills"]: copy(s["dir"], GL / "skills" / s["dir"].name)
if (SRC / "commands").is_dir() and g["commands"]: copy(SRC / "commands", GL / "commands")
if (SRC / "agents").is_dir() and g["agents"]: copy(SRC / "agents", GL / "agents")
if g["output_styles"]: copy(SRC / "output-styles", GL / "output-styles")
if g["hooks_dir"]: copy(g["hooks_dir"], GL / "hooks")
if g["claude_md"]: copy(g["claude_md"], GL / "CLAUDE.md")
for f in g["scripts"] + g["extra_files"]:
    if f.name == "settings.local.json":
        (GL / f.name).write_text(json.dumps(redact(load_json(f) or {}), indent=2, ensure_ascii=False))
    else:
        copy(f, GL / f.name)

def fix_home(obj, key=""):
    if isinstance(obj, dict): return {k: fix_home(v, k) for k, v in obj.items()}
    if isinstance(obj, list): return [fix_home(x, key) for x in obj]
    if isinstance(obj, str) and key in ("command", "statusLine", "apiKeyHelper"): return obj.replace(str(HOME), "$HOME")
    return obj

if g["settings"] is not None:
    clean = fix_home(redact(g["settings"]))
    (GL / "settings.json").write_text(json.dumps(clean, indent=2, ensure_ascii=False) + "\n")
    if has_placeholder(clean):
        manual.append("settings.json tinha segredos (ex.: bloco env): preencha os " + PLACE + " em ~/.claude/settings.json")

for p in projects:
    dst = OUT / "projects" / slug(p["path"])
    dst.mkdir(parents=True, exist_ok=True)
    (dst / "ORIGEM.txt").write_text(str(p["path"]).replace(str(HOME), "~", 1) + "\n")
    for sub in ("skills", "commands", "agents"):
        if p[sub]: copy(p["path"] / ".claude" / sub, dst / ".claude" / sub)
    for d in p["dirs"]: copy(d, dst / d.relative_to(p["path"]))
    for f in p["files"]:
        rel = f.relative_to(p["path"])
        if f.suffix == ".json":
            (dst / rel).parent.mkdir(parents=True, exist_ok=True)
            data = redact(load_json(f) or {})
            (dst / rel).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
            if has_placeholder(data): manual.append(f"{rel} do projeto {p['path'].name}: preencha os {PLACE}")
        else:
            copy(f, dst / rel)

(OUT / "plugins.json").write_text(json.dumps({"marketplaces": marketplaces, "plugins": [
    {**pp, "projectPath": (pp["projectPath"] or "").replace(str(HOME), "~", 1) or None} for pp in plugins]}, indent=2) + "\n")

mcp_out = {"user": redact(mcp_user),
           "local": {k.replace(str(HOME), "~", 1): redact(v) for k, v in mcp_local.items()}}
(OUT / "mcp-servers.json").write_text(json.dumps(mcp_out, indent=2, ensure_ascii=False) + "\n")
all_mcps = list(mcp_out["user"].items()) + [(n, c) for v in mcp_out["local"].values() for n, c in v.items()]
for n, c in all_mcps:
    if has_placeholder(c): manual.append(f"MCP '{n}': chave/token removido — edite mcp-servers.json antes do install.sh (ou rode `claude mcp add` à mão)")
    if c.get("type") in ("http", "sse"): manual.append(f"MCP '{n}' é remoto ({c.get('type')}): depois de instalar, rode /mcp no Claude Code e faça login")

# zips das skills (pasta da skill na raiz do zip, formato aceito pelo claude.ai)
import zipfile
zdir = OUT / "skills-zip"
zl = [(s["name"], GL / "skills" / s["dir"].name) for s in g["skills"]]
zl += [(f"{p['path'].name}--{s['name']}", OUT / "projects" / slug(p["path"]) / ".claude" / "skills" / s["dir"].name) for p in projects for s in p["skills"]]
for zname, d in zl:
    if not d.is_dir(): continue
    zdir.mkdir(exist_ok=True)
    with zipfile.ZipFile(zdir / f"{slug(zname)}.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(d.rglob("*")):
            if f.is_file(): z.write(f, Path(d.name) / f.relative_to(d))

# ---------- install.sh ----------
INSTALL = r'''#!/usr/bin/env bash
# install.sh — restaura este backup em ~/.claude na máquina NOVA.
# Uso: bash install.sh      (rode de dentro da pasta claude-backup)
set -uo pipefail
cd "$(dirname "$0")"
command -v claude >/dev/null || { echo "Instale o Claude Code primeiro: https://code.claude.com"; exit 1; }
command -v python3 >/dev/null || { echo "Precisa do python3."; exit 1; }
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$HOME/.claude"

echo "==> 1/4 Copiando skills, comandos, agentes, CLAUDE.md e settings para ~/.claude"
SAVE="$HOME/.claude/antes-do-restore-$TS"
for item in global/* global/.[!.]*; do
  [ -e "$item" ] || continue
  name=$(basename "$item")
  if [ -e "$HOME/.claude/$name" ]; then mkdir -p "$SAVE"; cp -R "$HOME/.claude/$name" "$SAVE/"; fi
  cp -R "$item" "$HOME/.claude/"
done
[ -d "$SAVE" ] && echo "    (o que já existia foi guardado em $SAVE)"

echo "==> 2/4 Projetos"
for d in projects/*/; do
  [ -d "$d" ] || continue
  dest=$(sed "s|^~|$HOME|" "$d/ORIGEM.txt")
  if [ -d "$dest" ]; then
    (cd "$d" && find . -type f ! -name ORIGEM.txt) | while read -r f; do
      if [ -e "$dest/$f" ]; then cp "$dest/$f" "$dest/$f.antes-$TS"; fi
      mkdir -p "$dest/$(dirname "$f")"; cp "$d/$f" "$dest/$f"
    done
    echo "    ok: $dest"
  else
    echo "    PULADO: $dest não existe. Clone o projeto e copie o conteúdo de $d para dentro dele."
  fi
done

echo "==> 3/4 Marketplaces e plugins"
python3 - <<'PY' | while IFS=$'\t' read -r kind a b; do
import json
d = json.load(open("plugins.json"))
for m in d["marketplaces"]:
    if m.get("source"): print("mkt\t%s\t%s" % (m["name"], m["source"]))
for p in d["plugins"]: print("plg\t%s\t%s" % (p["id"], p.get("scope") or "user"))
PY
  if [ "$kind" = mkt ]; then
    echo "    marketplace $a"; claude plugin marketplace add "$b" </dev/null >/dev/null 2>&1 || echo "      (já existe ou falhou — confira com: claude plugin marketplace list)"
  else
    sc="$b"; [ "$sc" = user ] || sc=user
    echo "    plugin $a"; claude plugin install "$a" --scope "$sc" </dev/null >/dev/null 2>&1 || echo "      (falhou — tente: claude plugin install $a)"
  fi
done

echo "==> 4/4 Servidores MCP"
python3 - <<'PY' | while IFS=$'\t' read -r scope dir name cfg; do
import json, os
d = json.load(open("mcp-servers.json"))
for n, c in d.get("user", {}).items(): print("user\t-\t%s\t%s" % (n, json.dumps(c)))
for p, srv in d.get("local", {}).items():
    for n, c in srv.items(): print("local\t%s\t%s\t%s" % (p.replace("~", os.path.expanduser("~"), 1), n, json.dumps(c)))
PY
  if printf '%s' "$cfg" | grep -q '<PREENCHER>'; then
    echo "    PULADO $name: tem <PREENCHER> — edite mcp-servers.json e rode o install.sh de novo"; continue
  fi
  if [ "$scope" = user ]; then
    claude mcp add-json --scope user "$name" "$cfg" </dev/null >/dev/null 2>&1 && echo "    ok: $name" || echo "    $name: já existe ou falhou"
  elif [ -d "$dir" ]; then
    (cd "$dir" && claude mcp add-json --scope local "$name" "$cfg" </dev/null >/dev/null 2>&1) && echo "    ok: $name ($dir)" || echo "    $name: já existe ou falhou"
  else
    echo "    PULADO $name: pasta $dir não existe nesta máquina"
  fi
done

echo
echo "Pronto. Abra o Claude Code e confira com: claude mcp list / claude plugin list / /skills"
echo "Veja a seção 'Precisa de ação manual' no README.md."
grep -rl '<PREENCHER>' "$HOME/.claude/settings.json" 2>/dev/null && echo "  ^ esse arquivo ainda tem <PREENCHER> para preencher."
exit 0
'''
(OUT / "install.sh").write_text(INSTALL)
os.chmod(OUT / "install.sh", 0o755)

# ---------- README.md ----------
manual = list(dict.fromkeys(manual))
L = []
A = L.append
A("# Backup do meu ambiente Claude Code\n")
A(f"Gerado em {time.strftime('%d/%m/%Y %H:%M')} a partir de `{str(SRC).replace(str(HOME), '~')}`.\n")
A("## Como restaurar na máquina nova\n")
A("1. Instale o Claude Code e faça login (`claude` → `/login`).")
A("2. Copie esta pasta `claude-backup/` para a máquina nova.")
A("3. Preencha os `" + PLACE + "` (veja \"Precisa de ação manual\" abaixo).")
A("4. Rode `bash install.sh` de dentro da pasta.\n")
A("Para enviar uma skill ao claude.ai: Configurações → Capabilities → Skills → Upload, usando os arquivos de `skills-zip/`.\n")
A("## Inventário\n")
def table(title, rows, head):
    A(f"### {title}\n")
    if not rows: A("_(nenhum)_\n"); return
    A("| " + " | ".join(head) + " |"); A("|" + "---|" * len(head))
    for r in rows: A("| " + " | ".join(str(c).replace("|", "\\|") for c in r) + " |")
    A("")
table("Skills globais (`~/.claude/skills/`)", [(f"`{s['name']}`", short(s["desc"], 300)) for s in g["skills"]], ["Skill", "O que faz / quando usar"])
table("Comandos globais (`~/.claude/commands/`)", [(f"`{c['name']}`", short(c["desc"], 300)) for c in g["commands"]], ["Comando", "Descrição"])
table("Subagentes (`~/.claude/agents/`)", [(f"`{a['name']}`", short(a["desc"], 300), a["model"] or "-") for a in g["agents"]], ["Agente", "Descrição", "Modelo"])
table("Plugins", [(f"`{p['id']}`", p["scope"]) for p in plugins], ["Plugin", "Escopo"])
table("Marketplaces", [(f"`{m['name']}`", m["kind"], f"`{m['source']}`") for m in marketplaces], ["Nome", "Tipo", "Origem"])
table("Servidores MCP", [(f"`{n}`", c.get("type", "stdio"), short(c.get("url") or " ".join([c.get("command", "")] + c.get("args", [])), 120)) for n, c in all_mcps], ["Nome", "Tipo", "Comando/URL"])
s = g["settings"] or {}
A("### settings.json\n")
if s:
    perms = s.get("permissions") or {}
    A(f"- Modelo: `{s.get('model', '(padrão)')}`")
    A(f"- Permissões: {len(perms.get('allow', []))} allow, {len(perms.get('deny', []))} deny, {len(perms.get('ask', []))} ask" + (f", modo padrão `{perms['defaultMode']}`" if perms.get("defaultMode") else ""))
    A(f"- Hooks: {', '.join((s.get('hooks') or {}).keys()) or 'nenhum'}")
    if s.get("statusLine"): A("- Status line personalizada: sim")
    if s.get("env"): A(f"- Variáveis de ambiente: {', '.join('`'+k+'`' for k in s['env'])}")
else:
    A("_(não existe)_")
A(f"\n- CLAUDE.md global: {'sim — `global/CLAUDE.md`' if g['claude_md'] else 'não'}\n")
A("### Projetos\n")
if not projects: A("_(nenhum projeto com configuração própria)_\n")
for p in projects:
    A(f"**{p['path'].name}** — `{str(p['path']).replace(str(HOME), '~')}`  ")
    for sk in p["skills"]: A(f"- skill `{sk['name']}`: {short(sk['desc'], 200)}")
    for c in p["commands"]: A(f"- comando `{c['name']}`: {short(c['desc'], 200)}")
    for a in p["agents"]: A(f"- agente `{a['name']}`: {short(a['desc'], 200)}")
    for f in p["files"]: A(f"- `{f.relative_to(p['path'])}`")
    A("")
A("## Resumo do fluxo de trabalho\n")
A("<!-- RESUMO -->")
def headings(md):
    try: return [l.strip("# ").strip() for l in Path(md).read_text(encoding="utf-8").splitlines() if l.startswith("#")][:12]
    except Exception: return []
if g["claude_md"]:
    A("**Regras globais (CLAUDE.md):** " + (", ".join(headings(g["claude_md"])) or "ver `global/CLAUDE.md`") + "\n")
for s_ in g["skills"]: A(f"- **Skill `{s_['name']}`** — {short(s_['desc'], 400)}")
for c in g["commands"]: A(f"- **Comando `{c['name']}`** — {short(c['desc'], 400)}")
for a in g["agents"]: A(f"- **Agente `{a['name']}`** — {short(a['desc'], 400)}")
for p in projects:
    for s_ in p["skills"]: A(f"- **Skill `{s_['name']}`** (projeto {p['path'].name}) — {short(s_['desc'], 400)}")
    for c in p["commands"]: A(f"- **Comando `{c['name']}`** (projeto {p['path'].name}) — {short(c['desc'], 400)}")
A("")
A("## Precisa de ação manual na máquina nova\n")
A("- Fazer login no Claude Code (`/login`). Conectores do claude.ai (Gmail, Notion, Figma…) vêm com a conta; numa conta nova, reconecte em Configurações → Conectores.")
A("- Fazer login de novo em CLIs usados pelos hooks/MCPs (ex.: `gh auth login`, `gcloud auth login`).")
for m in manual: A(f"- {m}")
if secret_hits:
    A("- **Tokens encontrados dentro destes arquivos foram trocados por `" + PLACE + "`** (recoloque à mão se precisar):")
    for h in sorted(set(secret_hits)): A(f"  - `{Path(h).relative_to(OUT)}`")
(OUT / "README.md").write_text("\n".join(L) + "\n", encoding="utf-8")

# ---------- resumo opcional feito pelo próprio Claude ----------
if shutil.which("claude") and not auto_yes and (g["skills"] or g["commands"] or g["agents"] or g["claude_md"] or projects):
    try:
        ans = input("\nQuer que o Claude leia as skills/comandos/CLAUDE.md e escreva um resumo detalhado do seu fluxo? [s/N] ").strip().lower()
    except EOFError:
        ans = ""
    if ans in ("s", "sim", "y", "yes"):
        prompt = ("Leia os arquivos desta pasta (global/CLAUDE.md, global/skills/*/SKILL.md, global/commands, global/agents e projects/). "
                  "Escreva em português, em Markdown sem título, um resumo do fluxo de trabalho do usuário: o que cada skill/comando/agente faz, "
                  "quando ele é usado e como se encaixam. Responda só com o resumo.")
        r = subprocess.run(["claude", "-p", prompt, "--allowedTools", "Read,Glob,Grep"], cwd=OUT, capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            txt = (OUT / "README.md").read_text(encoding="utf-8").replace("<!-- RESUMO -->", r.stdout.strip() + "\n\n**Itens:**\n")
            (OUT / "README.md").write_text(txt, encoding="utf-8"); print("Resumo adicionado ao README.md")
        else:
            print("Não consegui gerar o resumo automático (o README tem a lista básica).")

print(f"\nPronto: {OUT}")
print("  README.md        inventário + resumo + o que fazer à mão")
print("  install.sh       rode na máquina nova")
print("  skills-zip/      uma skill por .zip (para o claude.ai)")
if manual or secret_hits:
    print(f"\nAtenção: {len(manual) + len(set(secret_hits))} item(ns) precisam de ação manual — veja o fim do README.md")
PYEOF
)
exec python3 -c "$PYCODE" "$@"
