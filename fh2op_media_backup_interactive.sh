#!/usr/bin/env bash
set -Eeuo pipefail

# FlightHub 2 On-Premises Media Backup
# Version 0.3.0
#
# Reconstructs the FlightHub media-folder hierarchy from the media list API and
# downloads original files using the signed original_url returned by FH2.
#
# Confirmed schema expected from FH2 OP:
#   data.pagination.page / page_size / total
#   data.list[]
#   item.id
#   item.p_infos.pid
#   item.file_type        (1 = folder)
#   item.name
#   item.suffix
#   item.size
#   item.original_url
#
# Dependencies: bash, curl, jq, coreutils
#
# Read-only: this script does not modify or delete FlightHub/MinIO data.

VERSION="0.3.0"

BASE_URL="${FH2_URL:-}"
PROJECT_UUID="${FH2_PROJECT_UUID:-}"
TOKEN="${FH2_TOKEN:-}"
OUTPUT_DIR="${FH2_OUTPUT_DIR:-./FH2_media_backup}"
PAGE_SIZE="${FH2_PAGE_SIZE:-200}"

LIST_PATH="/openapi/v2.0/media/api/v1/workspaces/{workspace}/files"

DRY_RUN=0
PROBE_ONLY=0
SCAN_ONLY=0
VERBOSE=0
INSECURE=0
INTERACTIVE=0
SELECTED_PROJECT_NAME=""

declare -a CURL_TLS=()

# Folder metadata indexed by numeric FH2 media ID.
declare -A FOLDER_NAME=()
declare -A FOLDER_PARENT=()
declare -A FOLDER_PATH_CACHE=()

MANIFEST=""
ERROR_LOG=""

usage() {
  cat <<'EOF'
FlightHub 2 On-Premises - Media Backup v0.3.0

Uso:
  ./fh2op_media_backup.sh [opções]

Opções:
  --interactive      Assistente interativo completo
  --url URL          Backend do FH2, ex.: http://200.146.243.105:30812
  --project UUID     UUID do projeto/workspace
  --token TOKEN      x-user-token (prefira FH2_TOKEN ou entrada interativa)
  --output DIR       Diretório de destino
  --page-size N      Itens por página (padrão: 200)
  --probe            Testa a API e mostra um resumo da primeira página
  --scan-only        Varre toda a biblioteca e mostra contagens, sem criar backup
  --dry-run          Reconstrói/lista caminhos, mas não baixa os arquivos
  --insecure         Ignora validação TLS em HTTPS self-signed
  -v, --verbose      Exibe mais detalhes
  -h, --help         Ajuda
  --version          Versão

Modo interativo:
  ./fh2op_media_backup.sh --interactive

Ou simplesmente, sem parâmetros:
  ./fh2op_media_backup.sh

Exemplo não interativo:
  export FH2_TOKEN='SEU_TOKEN'

  ./fh2op_media_backup.sh \
    --url 'http://200.146.243.105:30812' \
    --project '33de6031-5d6a-4322-9e90-913f59f58b76' \
    --probe

Dry-run:
  ./fh2op_media_backup.sh \
    --url 'http://200.146.243.105:30812' \
    --project '33de6031-5d6a-4322-9e90-913f59f58b76' \
    --output '/mnt/g/LOG_PIB_Betim' \
    --dry-run

Backup:
  ./fh2op_media_backup.sh \
    --url 'http://200.146.243.105:30812' \
    --project '33de6031-5d6a-4322-9e90-913f59f58b76' \
    --output '/mnt/g/LOG_PIB_Betim'
EOF
}

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[AVISO] %s\n' "$*" >&2; }
die()  { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"
}

request_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-%s\n' "$(date +%s)" "$RANDOM" "$RANDOM"
  fi
}

render_list_url() {
  local path="${LIST_PATH//\{workspace\}/$PROJECT_UUID}"
  printf '%s%s' "$BASE_URL" "$path"
}

sanitize_name() {
  local s="$1"
  s="${s//\//_}"
  s="${s//$'\n'/_}"
  s="${s//$'\r'/_}"
  s="${s//$'\t'/_}"
  [[ "$s" == "." || "$s" == ".." || -z "$s" ]] && s="_sem_nome_"
  printf '%s' "$s"
}

api_get_page() {
  local page="$1"
  local out="$2"
  local url
  url="$(render_list_url)"

  local http
  http="$(
    curl -sS "${CURL_TLS[@]}" \
      --connect-timeout 15 \
      --retry 5 \
      --retry-delay 2 \
      --retry-all-errors \
      -G "$url" \
      --data-urlencode "page=$page" \
      --data-urlencode "page_size=$PAGE_SIZE" \
      -H "x-user-token: $TOKEN" \
      -H "X-Project-Uuid: $PROJECT_UUID" \
      -H "X-Request-Id: $(request_id)" \
      -o "$out" \
      -w '%{http_code}'
  )" || return 1

  [[ "$VERBOSE" -eq 1 ]] && info "GET $url?page=$page&page_size=$PAGE_SIZE -> HTTP $http"

  [[ "$http" == "200" ]] || {
    warn "A API retornou HTTP $http na página $page."
    return 2
  }

  jq -e . "$out" >/dev/null 2>&1 || {
    warn "A resposta da página $page não é JSON válido."
    return 3
  }

  local code
  code="$(jq -r '.code // empty' "$out")"
  [[ "$code" == "0" ]] || {
    warn "FlightHub retornou code=$code: $(jq -r '.message // "sem mensagem"' "$out")"
    return 4
  }
}

page_item_count() {
  jq -r '.data.list | length' "$1"
}

page_total() {
  jq -r '.data.pagination.total // 0' "$1"
}

page_server_size() {
  jq -r '.data.pagination.page_size // 0' "$1"
}

page_items() {
  jq -c '.data.list[]' "$1"
}

folder_path_by_id() {
  local id="$1"

  [[ -z "$id" || "$id" == "0" ]] && { printf ''; return 0; }

  if [[ -n "${FOLDER_PATH_CACHE[$id]:-}" ]]; then
    printf '%s' "${FOLDER_PATH_CACHE[$id]}"
    return 0
  fi

  local current="$id"
  local -a parts=()
  local guard=0

  while [[ -n "$current" && "$current" != "0" ]]; do
    ((guard+=1))
    if (( guard > 100 )); then
      warn "Loop/profundidade anormal na árvore de pastas a partir do ID $id."
      break
    fi

    if [[ -z "${FOLDER_NAME[$current]:-}" ]]; then
      # Parent not present in the library index. Preserve a deterministic fallback.
      parts+=("_FH2_PARENT_${current}")
      break
    fi

    parts+=("${FOLDER_NAME[$current]}")
    current="${FOLDER_PARENT[$current]:-0}"
  done

  local path=""
  local i
  for (( i=${#parts[@]}-1; i>=0; i-- )); do
    if [[ -z "$path" ]]; then
      path="${parts[$i]}"
    else
      path="${path}/${parts[$i]}"
    fi
  done

  FOLDER_PATH_CACHE[$id]="$path"
  printf '%s' "$path"
}

filename_from_item() {
  local item="$1"
  local name suffix
  name="$(jq -r '.name // .uuid // "arquivo_sem_nome"' <<<"$item")"
  suffix="$(jq -r '.suffix // ""' <<<"$item")"

  name="$(sanitize_name "$name")"

  if [[ -n "$suffix" && "$suffix" != "null" ]]; then
    # FH2 returns suffix such as ".jpeg". Avoid duplicating an existing suffix.
    if [[ "${name,,}" != *"${suffix,,}" ]]; then
      name="${name}${suffix}"
    fi
  fi

  printf '%s' "$name"
}

append_manifest() {
  local kind="$1" id="$2" uuid="$3" rel="$4" size="$5" status="$6"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$id" "$uuid" "$rel" "$size" "$status" >> "$MANIFEST"
}

download_file() {
  local url="$1"
  local dest="$2"
  local expected_size="$3"
  local rel="$4"
  local id="$5"
  local uuid="$6"

  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" && "$expected_size" =~ ^[0-9]+$ && "$expected_size" -gt 0 ]]; then
    local current_size
    current_size="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"

    if [[ "$current_size" -eq "$expected_size" ]]; then
      info "Já concluído: $rel"
      append_manifest "FILE" "$id" "$uuid" "$rel" "$expected_size" "SKIP_COMPLETE"
      return 0
    fi

    if [[ "$current_size" -gt "$expected_size" ]]; then
      warn "Arquivo local maior que o esperado; movendo para conflito: $rel"
      mv -f "$dest" "${dest}.conflict.$(date +%Y%m%d%H%M%S)"
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[DRY-RUN] $rel"
    append_manifest "FILE" "$id" "$uuid" "$rel" "$expected_size" "DRY_RUN"
    return 0
  fi

  if [[ -z "$url" || "$url" == "null" ]]; then
    warn "original_url vazio: $rel"
    append_manifest "FILE" "$id" "$uuid" "$rel" "$expected_size" "NO_URL"
    printf '%s\t%s\t%s\n' "$id" "$uuid" "$rel" >> "$ERROR_LOG"
    return 1
  fi

  info "Baixando: $rel"

  # Presigned MinIO URL. -C - resumes partial files when Range is supported.
  if curl -fL "${CURL_TLS[@]}" \
      --connect-timeout 20 \
      --retry 8 \
      --retry-delay 3 \
      --retry-all-errors \
      --speed-time 120 \
      --speed-limit 1024 \
      -C - \
      --remote-time \
      -o "$dest" \
      "$url"; then

    if [[ "$expected_size" =~ ^[0-9]+$ && "$expected_size" -gt 0 ]]; then
      local final_size
      final_size="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
      if [[ "$final_size" -ne "$expected_size" ]]; then
        warn "Tamanho final diferente do esperado: $rel ($final_size != $expected_size)"
        append_manifest "FILE" "$id" "$uuid" "$rel" "$expected_size" "SIZE_MISMATCH"
        printf '%s\t%s\t%s\n' "$id" "$uuid" "$rel" >> "$ERROR_LOG"
        return 1
      fi
    fi

    append_manifest "FILE" "$id" "$uuid" "$rel" "$expected_size" "OK"
    return 0
  fi

  warn "Falha no download: $rel"
  append_manifest "FILE" "$id" "$uuid" "$rel" "$expected_size" "DOWNLOAD_ERROR"
  printf '%s\t%s\t%s\n' "$id" "$uuid" "$rel" >> "$ERROR_LOG"
  return 1
}

scan_folders() {
  info "Etapa 1/2: indexando estrutura de pastas do FlightHub..."

  local page=1
  local total=0
  local seen=0
  local folders=0
  local files=0
  local bytes=0

  while :; do
    local tmp
    tmp="$(mktemp)"

    if ! api_get_page "$page" "$tmp"; then
      cat "$tmp" >&2 2>/dev/null || true
      rm -f "$tmp"
      die "Não foi possível ler a página $page da biblioteca."
    fi

    local count server_page_size
    count="$(page_item_count "$tmp")"
    total="$(page_total "$tmp")"
    server_page_size="$(page_server_size "$tmp")"
    (( server_page_size > 0 )) && PAGE_SIZE="$server_page_size"

    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      ((seen+=1))

      local id type parent name size
      id="$(jq -r '.id // empty' <<<"$item")"
      type="$(jq -r '.file_type // 0' <<<"$item")"
      parent="$(jq -r '.p_infos.pid // 0' <<<"$item")"
      name="$(jq -r '.name // .uuid // "_sem_nome_"' <<<"$item")"
      size="$(jq -r '.size // 0' <<<"$item")"

      if [[ "$type" == "1" ]]; then
        name="$(sanitize_name "$name")"
        FOLDER_NAME["$id"]="$name"
        FOLDER_PARENT["$id"]="$parent"
        ((folders+=1))
      else
        ((files+=1))
        [[ "$size" =~ ^[0-9]+$ ]] && ((bytes+=size))
      fi
    done < <(page_items "$tmp")

    rm -f "$tmp"

    info "Indexação: página $page | itens $seen/${total:-?} | pastas $folders | arquivos $files"

    (( count == 0 )) && break
    (( total > 0 && seen >= total )) && break
    (( count < PAGE_SIZE )) && break
    ((page+=1))
  done

  SCAN_TOTAL="$seen"
  SCAN_FOLDERS="$folders"
  SCAN_FILES="$files"
  SCAN_BYTES="$bytes"

  ok "Indexação concluída: $folders pastas, $files arquivos."
}

create_folder_tree() {
  local id
  for id in "${!FOLDER_NAME[@]}"; do
    local path
    path="$(folder_path_by_id "$id")"
    [[ -n "$path" ]] || continue
    if [[ "$SCAN_ONLY" -eq 0 ]]; then
      mkdir -p "${OUTPUT_DIR}/${path}"
    fi
  done
}

backup_files() {
  info "Etapa 2/2: lendo URLs atuais e processando arquivos..."

  local page=1
  local seen=0
  local done_files=0
  local failures=0
  local total=0

  while :; do
    local tmp
    tmp="$(mktemp)"

    if ! api_get_page "$page" "$tmp"; then
      cat "$tmp" >&2 2>/dev/null || true
      rm -f "$tmp"
      warn "Falha ao reler página $page."
      ((failures+=1))
      break
    fi

    local count
    count="$(page_item_count "$tmp")"
    total="$(page_total "$tmp")"

    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      ((seen+=1))

      local type
      type="$(jq -r '.file_type // 0' <<<"$item")"
      [[ "$type" == "1" ]] && continue

      local id uuid parent size url filename parent_path rel dest
      id="$(jq -r '.id // empty' <<<"$item")"
      uuid="$(jq -r '.uuid // empty' <<<"$item")"
      parent="$(jq -r '.p_infos.pid // 0' <<<"$item")"
      size="$(jq -r '.size // 0' <<<"$item")"
      url="$(jq -r '.original_url // empty' <<<"$item")"
      filename="$(filename_from_item "$item")"
      parent_path="$(folder_path_by_id "$parent")"

      if [[ -n "$parent_path" ]]; then
        rel="${parent_path}/${filename}"
      else
        rel="$filename"
      fi

      dest="${OUTPUT_DIR}/${rel}"

      if ! download_file "$url" "$dest" "$size" "$rel" "$id" "$uuid"; then
        ((failures+=1))
      fi

      ((done_files+=1))
    done < <(page_items "$tmp")

    rm -f "$tmp"

    info "Progresso da API: página $page | itens lidos $seen/${total:-?} | arquivos processados $done_files | falhas $failures"

    (( count == 0 )) && break
    (( total > 0 && seen >= total )) && break
    (( count < PAGE_SIZE )) && break
    ((page+=1))
  done

  BACKUP_FAILURES="$failures"
  BACKUP_DONE="$done_files"
}

probe() {
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  api_get_page 1 "$tmp" || {
    cat "$tmp" >&2 2>/dev/null || true
    die "Falha no probe da Media API."
  }

  local total count pagesize folders files
  total="$(page_total "$tmp")"
  count="$(page_item_count "$tmp")"
  pagesize="$(page_server_size "$tmp")"
  folders="$(jq '[.data.list[] | select(.file_type == 1)] | length' "$tmp")"
  files="$(jq '[.data.list[] | select(.file_type != 1)] | length' "$tmp")"

  ok "Media API acessível."
  info "Rota: $LIST_PATH"
  info "Primeira página: $count itens"
  info "Page size informado pelo servidor: $pagesize"
  info "Total informado pelo servidor: $total"
  info "Pastas nesta página: $folders"
  info "Arquivos nesta página: $files"

  echo
  info "Exemplo de pasta:"
  jq '.data.list[] | select(.file_type == 1) |
      {id, parent_id: .p_infos.pid, name, file_type, has_child} |
      .' "$tmp" | head -n 12 || true

  echo
  info "Exemplo de arquivo:"
  jq '.data.list[] | select(.file_type != 1) |
      {id, parent_id: .p_infos.pid, uuid, name, suffix, size, file_type, object_key, original_url} |
      .' "$tmp" | head -n 24 || true
}


decode_org_uuid_from_token() {
  local token="$1"
  local payload pad json

  payload="$(printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+')"
  case $((${#payload} % 4)) in
    2) pad="==" ;;
    3) pad="=" ;;
    *) pad="" ;;
  esac

  json="$(printf '%s%s' "$payload" "$pad" | base64 -d 2>/dev/null || true)"
  printf '%s' "$json" | jq -r '.organization_uuid // empty' 2>/dev/null || true
}

list_projects_interactive() {
  local org_uuid="$1"
  local tmp url http
  tmp="$(mktemp)"
  url="${BASE_URL}/openapi/v2.0/manage/api/v1/organizations/${org_uuid}/projects"

  http="$(
    curl -sS "${CURL_TLS[@]}" \
      --connect-timeout 15 \
      --retry 3 \
      --retry-delay 2 \
      -G "$url" \
      --data-urlencode "page=1" \
      --data-urlencode "page_size=100" \
      -H "x-user-token: $TOKEN" \
      -H "X-Request-Id: $(request_id)" \
      -o "$tmp" \
      -w '%{http_code}'
  )" || true

  if [[ "$http" != "200" ]] || ! jq -e '.code == 0 and (.data.list | type == "array")' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  local count
  count="$(jq -r '.data.list | length' "$tmp")"
  if [[ "$count" -eq 0 ]]; then
    rm -f "$tmp"
    return 1
  fi

  echo
  info "Projetos disponíveis na organização:"
  local i=1
  while IFS=$'\t' read -r name uuid; do
    printf '  %2d) %s\n      %s\n' "$i" "$name" "$uuid"
    ((i+=1))
  done < <(jq -r '.data.list[] | [.name, .uuid] | @tsv' "$tmp")

  local choice
  while :; do
    read -rp "Escolha o projeto [1-${count}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      PROJECT_UUID="$(jq -r ".data.list[$((choice-1))].uuid" "$tmp")"
      SELECTED_PROJECT_NAME="$(jq -r ".data.list[$((choice-1))].name" "$tmp")"
      break
    fi
    warn "Opção inválida."
  done

  rm -f "$tmp"
  return 0
}

interactive_wizard() {
  INTERACTIVE=1

  echo
  echo "============================================================"
  echo " FlightHub 2 On-Premises - Backup de Mídia"
  echo " Assistente interativo v${VERSION}"
  echo "============================================================"
  echo

  local default_url="${BASE_URL:-}"
  if [[ -n "$default_url" ]]; then
    read -rp "Backend do FlightHub [${default_url}]: " input_url
    BASE_URL="${input_url:-$default_url}"
  else
    read -rp "Backend do FlightHub (ex.: http://IP:30812): " BASE_URL
  fi
  BASE_URL="${BASE_URL%/}"

  if [[ "$BASE_URL" == https://* ]]; then
    local tls_answer
    read -rp "Usa certificado self-signed/não confiável? [s/N]: " tls_answer
    if [[ "${tls_answer,,}" == "s" || "${tls_answer,,}" == "sim" || "${tls_answer,,}" == "y" || "${tls_answer,,}" == "yes" ]]; then
      INSECURE=1
      CURL_TLS=(-k)
    fi
  fi

  if [[ -z "$TOKEN" ]]; then
    read -rsp "Cole o x-user-token (não será exibido): " TOKEN
    echo
  else
    local keep_token
    read -rp "Usar FH2_TOKEN já carregado (${#TOKEN} caracteres)? [S/n]: " keep_token
    if [[ "${keep_token,,}" == "n" || "${keep_token,,}" == "nao" || "${keep_token,,}" == "não" ]]; then
      read -rsp "Cole o x-user-token: " TOKEN
      echo
    fi
  fi
  TOKEN="$(printf '%s' "$TOKEN" | tr -d '\r\n')"

  local org_uuid
  org_uuid="$(decode_org_uuid_from_token "$TOKEN")"

  if [[ -n "$org_uuid" ]]; then
    info "Organização identificada pelo token: $org_uuid"
    if ! list_projects_interactive "$org_uuid"; then
      warn "Não consegui listar os projetos automaticamente."
      read -rp "UUID do projeto: " PROJECT_UUID
      read -rp "Nome do projeto (opcional): " SELECTED_PROJECT_NAME
    fi
  else
    warn "Não consegui extrair organization_uuid do token."
    read -rp "UUID do projeto: " PROJECT_UUID
    read -rp "Nome do projeto (opcional): " SELECTED_PROJECT_NAME
  fi

  local default_output
  if [[ -n "$SELECTED_PROJECT_NAME" ]]; then
    default_output="./$(sanitize_name "$SELECTED_PROJECT_NAME")"
  else
    default_output="./FH2_media_backup"
  fi

  read -rp "Diretório de destino [${default_output}]: " OUTPUT_DIR
  OUTPUT_DIR="${OUTPUT_DIR:-$default_output}"

  echo
  echo "Modo de execução:"
  echo "  1) Apenas levantamento (scan-only)"
  echo "  2) Simulação completa (dry-run)"
  echo "  3) Backup real"
  local mode
  while :; do
    read -rp "Escolha [1-3]: " mode
    case "$mode" in
      1) SCAN_ONLY=1; DRY_RUN=0; break ;;
      2) SCAN_ONLY=0; DRY_RUN=1; break ;;
      3) SCAN_ONLY=0; DRY_RUN=0; break ;;
      *) warn "Opção inválida." ;;
    esac
  done

  echo
  echo "---------------- RESUMO ----------------"
  printf 'Backend:  %s\n' "$BASE_URL"
  printf 'Projeto:  %s\n' "${SELECTED_PROJECT_NAME:-$PROJECT_UUID}"
  printf 'UUID:     %s\n' "$PROJECT_UUID"
  printf 'Destino:  %s\n' "$OUTPUT_DIR"
  if [[ "$SCAN_ONLY" -eq 1 ]]; then
    echo "Modo:     Scan-only"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Modo:     Dry-run"
  else
    echo "Modo:     BACKUP REAL"
  fi
  echo "-----------------------------------------"
  echo

  local confirm
  read -rp "Continuar? [S/n]: " confirm
  if [[ "${confirm,,}" == "n" || "${confirm,,}" == "nao" || "${confirm,,}" == "não" ]]; then
    info "Operação cancelada."
    exit 0
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive) INTERACTIVE=1; shift ;;
    --url) BASE_URL="${2:-}"; shift 2 ;;
    --project) PROJECT_UUID="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --page-size) PAGE_SIZE="${2:-}"; shift 2 ;;
    --probe) PROBE_ONLY=1; shift ;;
    --scan-only) SCAN_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --insecure) INSECURE=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

need_cmd curl
need_cmd jq
need_cmd stat
need_cmd mkdir
need_cmd mktemp
need_cmd base64

# Sem parâmetros essenciais, entra automaticamente no assistente interativo.
if [[ "$INTERACTIVE" -eq 1 || ( -z "$BASE_URL" && -z "$PROJECT_UUID" ) ]]; then
  interactive_wizard
else
  [[ -n "$BASE_URL" ]] || read -rp "Backend FH2 (ex.: http://IP:30812): " BASE_URL
  [[ -n "$PROJECT_UUID" ]] || read -rp "UUID do projeto: " PROJECT_UUID

  if [[ -z "$TOKEN" ]]; then
    read -rsp "x-user-token: " TOKEN
    echo
  fi

  BASE_URL="${BASE_URL%/}"

  if [[ "$INSECURE" -eq 1 ]]; then
    CURL_TLS=(-k)
    warn "Validação TLS desativada (--insecure)."
  fi
fi

[[ -n "$BASE_URL" ]] || die "URL vazia."
[[ -n "$PROJECT_UUID" ]] || die "Project UUID vazio."
[[ -n "$TOKEN" ]] || die "Token vazio."
[[ "$PAGE_SIZE" =~ ^[0-9]+$ ]] || die "--page-size precisa ser numérico."

if [[ "$PROBE_ONLY" -eq 1 ]]; then
  probe
  exit 0
fi

scan_folders

echo
info "Resumo do projeto:"
info "  Itens:    $SCAN_TOTAL"
info "  Pastas:   $SCAN_FOLDERS"
info "  Arquivos: $SCAN_FILES"
if command -v numfmt >/dev/null 2>&1; then
  info "  Volume:   $(numfmt --to=iec-i --suffix=B "$SCAN_BYTES" 2>/dev/null || echo "$SCAN_BYTES bytes")"
else
  info "  Volume:   $SCAN_BYTES bytes"
fi
echo

if [[ "$SCAN_ONLY" -eq 1 ]]; then
  ok "Scan concluído. Nenhum arquivo foi alterado ou baixado."
  exit 0
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

MANIFEST="${OUTPUT_DIR}/fh2_media_manifest.tsv"
ERROR_LOG="${OUTPUT_DIR}/fh2_media_errors.tsv"

if [[ ! -f "$MANIFEST" ]]; then
  printf 'kind\tid\tuuid\tpath\tsize_bytes\tstatus\n' > "$MANIFEST"
fi
if [[ ! -f "$ERROR_LOG" ]]; then
  printf 'id\tuuid\tpath\n' > "$ERROR_LOG"
fi

create_folder_tree

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "Modo DRY-RUN: nenhum conteúdo de mídia será gravado."
fi

backup_files

echo
if (( BACKUP_FAILURES == 0 )); then
  ok "Processamento concluído sem falhas."
else
  warn "Processamento concluído com $BACKUP_FAILURES falha(s)."
fi
info "Arquivos processados: $BACKUP_DONE"
info "Manifest: $MANIFEST"
info "Erros:    $ERROR_LOG"

exit "$(( BACKUP_FAILURES > 0 ? 1 : 0 ))"
