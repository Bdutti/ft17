#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# deploy.sh
# Uso:
#   ./deploy.sh [--git-branch BRANCH] [--dry-run] [--backup-dir DIR] [--no-backup] [--git-remote REMOTE]
# Exemplo:
#   ./deploy.sh --git-branch develop --dry-run

# Defaults
GIT_REMOTE="origin"
GIT_BRANCH="main"
BACKUP_DIR="./backups"
DO_BACKUP=1
DRY_RUN=0

print_help() {
  cat <<EOF
deploy.sh - Deploy seguro do Fight Zone 017

Opções:
  --git-branch BRANCH    Branch git a ser usado para git pull (padrão: main)
  --git-remote REMOTE    Remote git (padrão: origin)
  --backup-dir DIR       Diretório para backups (padrão: ./backups)
  --no-backup            Não executar pg_dump (ignorar backup)
  --dry-run              Mostrar comandos sem executá-los
  -h, --help             Mostrar esta ajuda
EOF
}

# executor que respeita DRY_RUN
run_cmd() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY-RUN] $*"
  else
    echo "[RUN] $*"
    eval "$@"
  fi
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --git-branch)
      shift
      GIT_BRANCH="${1:-}"
      ;;
    --git-remote)
      shift
      GIT_REMOTE="${1:-}"
      ;;
    --backup-dir)
      shift
      BACKUP_DIR="${1:-}"
      ;;
    --no-backup)
      DO_BACKUP=0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Argumento desconhecido: $1"
      print_help
      exit 2
      ;;
  esac
  shift
done

echo "=== Deploy script ==="
echo "Git remote: ${GIT_REMOTE}"
echo "Git branch to pull: ${GIT_BRANCH}"
echo "Backup dir: ${BACKUP_DIR}"
echo "Do backup: ${DO_BACKUP}"
echo "Dry-run: ${DRY_RUN}"
echo "====================="

# Basic sanity checks: estar no diretório do projeto
if [ ! -f "requirements.txt" ] && [ ! -f "run.py" ]; then
  echo "ERRO: Não encontrei requirements.txt nem run.py neste diretório. Execute o script na raiz do projeto."
  exit 3
fi

# Ensure backup dir exists
if [ "${DO_BACKUP}" -eq 1 ]; then
  run_cmd "mkdir -p \"${BACKUP_DIR}\""
  run_cmd "chmod 700 \"${BACKUP_DIR}\""
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.sql"

# Backup DB
if [ "${DO_BACKUP}" -eq 1 ]; then
  echo "📦 Criando backup do banco de dados..."
  # verifica serviço postgresql ativo (não falha em dry-run)
  if [ "${DRY_RUN}" -eq 0 ]; then
    if ! systemctl is-active --quiet postgresql; then
      echo "ATENÇÃO: postgresql não está ativo no host atual. Verifique serviço antes de prosseguir."
    fi
  else
    echo "[DRY-RUN] checando status do postgresql"
  fi

  # pg_dump como usuário postgres
  run_cmd "sudo -u postgres pg_dump fightzone017_db > \"${BACKUP_FILE}\""
  echo "✅ Backup salvo em ${BACKUP_FILE}"
else
  echo "⚠️ Backup pulado (--no-backup)"
fi

# Atualizar código
echo "📥 Atualizando código via git..."
run_cmd "git fetch --all --prune"
# Hard reset to remote branch to ensure deterministic deploy
run_cmd "git checkout \"${GIT_BRANCH}\" || git checkout -b \"${GIT_BRANCH}\""
run_cmd "git reset --hard \"${GIT_REMOTE}/${GIT_BRANCH}\""

# Activate virtualenv or create it
if [ -f "venv/bin/activate" ]; then
  echo "🔁 Ativando virtualenv existente..."
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY-RUN] source venv/bin/activate"
  else
    # shellcheck disable=SC1091
    source venv/bin/activate
  fi
else
  echo "⚠️ Virtualenv não encontrada. Criando venv e instalando dependências..."
  run_cmd "python3 -m venv venv"
  run_cmd "source venv/bin/activate"
  run_cmd "pip install --upgrade pip"
  run_cmd "pip install -r requirements.txt"
fi

# Instalar/atualizar dependências
echo "📚 Instalando/atualizando dependências..."
run_cmd "pip install --upgrade pip"
run_cmd "pip install -r requirements.txt"

# Migrações (opcional)
echo "🗄️ Migrações: verifique se usa Flask-Migrate. Se sim, descomente o bloco de migração no script."
# exemplo (descomentear se aplicável):
# run_cmd "export FLASK_APP=run.py && flask db upgrade"

# Coletar estáticos (opcional)
# run_cmd "python manage.py collectstatic --noinput"

# Reiniciar serviços
echo "🔄 Reiniciando serviços..."
# tenta reiniciar via supervisor; se falhar, força reread/update
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] sudo supervisorctl restart fightzone017 || sudo supervisorctl reread && sudo supervisorctl update && sudo supervisorctl start fightzone017"
else
  if ! sudo supervisorctl restart fightzone017; then
    echo "Supervisor restart falhou, aplicando reread/update e tentando start..."
    sudo supervisorctl reread || true
    sudo supervisorctl update || true
    sudo supervisorctl start fightzone017 || true
  fi
fi

# Reload nginx (não falha o deploy se nginx reload falhar)
run_cmd "sudo systemctl reload nginx || true"

# Status final
echo "✅ Deploy concluído (modo $( [ ${DRY_RUN} -eq 1 ] && echo "DRY-RUN" || echo "EXECUTADO" ) )."
echo "Verifique logs e status:"
echo "  sudo supervisorctl status fightzone017"
echo "  sudo tail -n 200 /var/log/fightzone017.log || true"
echo "  sudo tail -n 200 /var/log/nginx/fightzone017_error.log || true"

exit 0