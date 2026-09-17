from pathlib import Path

readme = r'''# FlightHub 2 On-Premises Media Backup

Script em Bash para **exportar a biblioteca de mídia de um projeto do DJI FlightHub 2 On-Premises**, preservando a estrutura de pastas e os nomes exibidos no FlightHub.

O objetivo é evitar o download manual pelo MinIO, onde os objetos são armazenados em caminhos internos com UUIDs que dificultam identificar a missão, a pasta e o nome original dos arquivos.

O script consulta a **OpenAPI V2.0 do FlightHub 2 On-Premises**, reconstrói a hierarquia da biblioteca de mídia e baixa os arquivos originais usando as URLs assinadas fornecidas pelo próprio FlightHub.

---

## Objetivo

No MinIO, um arquivo pode estar armazenado em um caminho semelhante a:

```text
91c8e667-b7ff-4461-8347-ee5e18ad1aec/
└── e495423d-05ff-4639-a238-ef299c1cbf3b/
    └── DJI_202608281537_032_e495423d-05ff-4639-a238-ef299c1cbf3b/
        └── DJI_20260828154134_0032_V.jpeg
```

Já no FlightHub 2, esse mesmo conteúdo está organizado de forma amigável, por exemplo:

```text
LOG_PIB_Betim/
├── PIB BETIM 2026-09-17 11:00:04 (UTC-03)/
│   ├── DJI_20260917110001_0001_V.jpeg
│   ├── DJI_20260917110003_0002_V.jpeg
│   └── ...
├── PIB BETIM 2026-09-17 09:30:04 (UTC-03)/
│   └── ...
└── PIB NOTURNO 2026-09-16 04:30:01 (UTC-03)/
    └── ...
```

O script usa os metadados da API para reconstruir essa estrutura automaticamente.

---

## Como funciona

O processo é dividido em duas etapas.

### 1. Indexação da biblioteca

O script consulta:

```text
GET /openapi/v2.0/media/api/v1/workspaces/{PROJECT_UUID}/files
```

e utiliza principalmente os seguintes campos:

```text
id
p_infos.pid
file_type
name
suffix
size
original_url
```

A lógica utilizada é:

```text
file_type = 1
    → pasta

p_infos.pid
    → ID da pasta pai

name
    → nome exibido no FlightHub

suffix
    → extensão do arquivo

original_url
    → URL assinada para download do arquivo original
```

Primeiro todas as pastas são indexadas. Isso permite reconstruir a árvore completa antes de iniciar o download.

### 2. Download dos arquivos

A biblioteca é consultada novamente para obter URLs assinadas atualizadas.

Os arquivos são então baixados diretamente do armazenamento MinIO usando o campo:

```text
original_url
```

Assim, a OpenAPI é utilizada para descobrir a organização lógica dos dados e o MinIO é utilizado somente como origem efetiva dos arquivos.

---

## Requisitos

O script foi desenvolvido para Linux e pode ser utilizado, por exemplo, em:

- Ubuntu Server
- Ubuntu Desktop
- WSL
- outra distribuição Linux compatível com Bash

Dependências obrigatórias:

```text
bash
curl
jq
coreutils
base64
```

Recomendados:

```text
uuid-runtime
tmux
```

### Instalação no Ubuntu/WSL

```bash
sudo apt update
sudo apt install -y curl jq coreutils uuid-runtime tmux
```

---

## Preparação

Dê permissão de execução ao script:

```bash
chmod +x fh2op_media_backup_interactive.sh
```

Execute:

```bash
./fh2op_media_backup_interactive.sh
```

Também é possível renomeá-lo:

```bash
mv fh2op_media_backup_interactive.sh fh2op_media_backup.sh
chmod +x fh2op_media_backup.sh
```

---

# Modo interativo

O modo recomendado é simplesmente executar o script sem parâmetros:

```bash
./fh2op_media_backup_interactive.sh
```

O assistente solicitará as informações necessárias.

## 1. Backend do FlightHub

Informe o endereço do **backend do FlightHub**, e não a porta do frontend.

Exemplo:

```text
http://200.146.243.105:30812
```

Em uma instalação padrão, o frontend pode estar publicado em outra porta, enquanto a OpenAPI é disponibilizada pelo backend.

Para identificar o backend em uma instalação, o código-fonte carregado pelo frontend pode apresentar algo semelhante a:

```javascript
window.CURRENT_FE_ENV_CONFIG = {
    configHost: 'http://IP:30812'
}
```

Nesse caso, deve ser utilizado o valor de `configHost`.

---

## 2. OpenAPI Token

O script solicitará:

```text
x-user-token
```

A entrada não é exibida no terminal.

A chave deve ser obtida nas configurações OpenAPI da organização no FlightHub 2.

O script também aceita o token previamente carregado em uma variável de ambiente:

```bash
export FH2_TOKEN='SEU_TOKEN'
```

Depois:

```bash
./fh2op_media_backup_interactive.sh
```

O token não deve ser compartilhado ou salvo em repositórios públicos.

---

## 3. Seleção do projeto

O script lê o `organization_uuid` contido no token e consulta automaticamente os projetos disponíveis.

Exemplo:

```text
Projetos disponíveis na organização:

   1) Patrulha_UFV RN
      8f5f8440-084f-4b63-8100-bc15b473dfe9

   2) LOG_PIB Betim
      33de6031-5d6a-4322-9e90-913f59f58b76

   3) Teste
      0ed7c99a-4e7d-4c91-9918-3a71367f9baa

Escolha o projeto [1-3]:
```

Não é necessário copiar manualmente o UUID do projeto no modo interativo.

---

## 4. Diretório de destino

O script pergunta onde o backup será armazenado.

Exemplo:

```text
/mnt/g/LOG_PIB_Betim
```

Certifique-se de que o destino possui espaço livre suficiente.

Antes de um backup grande, é recomendado verificar:

```bash
df -h
```

ou:

```bash
df -h /mnt/g
```

---

## 5. Modo de execução

O assistente apresenta três opções:

```text
1) Apenas levantamento (scan-only)
2) Simulação completa (dry-run)
3) Backup real
```

### Scan-only

Percorre toda a biblioteca e informa:

- quantidade total de itens;
- quantidade de pastas;
- quantidade de arquivos;
- volume total dos arquivos.

Nenhum arquivo de mídia é baixado.

Exemplo:

```text
[INFO] Resumo do projeto:
[INFO]   Itens:    27281
[INFO]   Pastas:   620
[INFO]   Arquivos: 26661
[INFO]   Volume:   894GiB
```

É recomendado executar esse modo antes do primeiro backup.

---

### Dry-run

Reconstrói a hierarquia e simula o processamento dos arquivos sem baixar o conteúdo de mídia.

Exemplo:

```text
[INFO] [DRY-RUN] PIB BETIM 2026-09-17 11:00:04 (UTC-03)/DJI_20260917110001_0001_V.jpeg
```

Esse modo deve ser utilizado para confirmar se os nomes e caminhos reconstruídos correspondem à biblioteca exibida no FlightHub.

O diretório de destino, a estrutura de pastas e os arquivos de controle podem ser criados, mas o conteúdo das fotos e vídeos não é baixado.

---

### Backup real

Realiza a indexação e depois baixa os arquivos originais.

Exemplo de resultado:

```text
LOG_PIB_Betim/
├── PIB BETIM 2026-09-17 11:00:04 (UTC-03)/
│   ├── DJI_20260917110001_0001_V.jpeg
│   ├── DJI_20260917110003_0002_V.jpeg
│   └── ...
├── PIB BETIM 2026-09-17 09:30:04 (UTC-03)/
│   └── ...
├── fh2_media_manifest.tsv
└── fh2_media_errors.tsv
```

---

# Uso não interativo

Também é possível fornecer os parâmetros diretamente.

Primeiro, carregue o token:

```bash
export FH2_TOKEN='SEU_TOKEN'
```

## Testar a API

```bash
./fh2op_media_backup_interactive.sh \
  --url 'http://IP_DO_FLIGHTHUB:30812' \
  --project 'UUID_DO_PROJETO' \
  --probe
```

---

## Apenas levantar informações

```bash
./fh2op_media_backup_interactive.sh \
  --url 'http://IP_DO_FLIGHTHUB:30812' \
  --project 'UUID_DO_PROJETO' \
  --scan-only
```

---

## Simular o backup

```bash
./fh2op_media_backup_interactive.sh \
  --url 'http://IP_DO_FLIGHTHUB:30812' \
  --project 'UUID_DO_PROJETO' \
  --output '/caminho/do/backup' \
  --dry-run
```

---

## Executar o backup

```bash
./fh2op_media_backup_interactive.sh \
  --url 'http://IP_DO_FLIGHTHUB:30812' \
  --project 'UUID_DO_PROJETO' \
  --output '/caminho/do/backup'
```

---

# Parâmetros disponíveis

| Parâmetro | Função |
|---|---|
| `--interactive` | Inicia o assistente interativo |
| `--url URL` | Define o endereço do backend do FlightHub |
| `--project UUID` | Define o UUID do projeto |
| `--token TOKEN` | Define diretamente o `x-user-token` |
| `--output DIR` | Define o diretório de destino |
| `--page-size N` | Define a quantidade solicitada de itens por página |
| `--probe` | Testa a Media API e apresenta uma amostra |
| `--scan-only` | Varre toda a biblioteca sem realizar backup |
| `--dry-run` | Simula o backup sem baixar a mídia |
| `--insecure` | Ignora validação TLS de certificado HTTPS |
| `-v`, `--verbose` | Exibe informações adicionais |
| `-h`, `--help` | Exibe a ajuda |
| `--version` | Exibe a versão do script |

---

# Retomada de downloads

O script foi projetado para poder ser executado novamente após uma interrupção.

Antes de baixar um arquivo, ele verifica se o arquivo local já existe.

Se o tamanho local for igual ao tamanho informado pelo FlightHub:

```text
arquivo completo
→ download ignorado
```

Se existir um arquivo parcial:

```text
arquivo parcial
→ curl -C -
→ tentativa de continuar o download
```

Dessa forma, uma interrupção de rede ou encerramento da sessão não exige começar todo o backup novamente.

Para continuar, execute novamente o mesmo comando com o mesmo diretório de destino.

---

# Execuções longas com tmux

Para bibliotecas grandes, recomenda-se executar o backup dentro de uma sessão `tmux`.

Criar sessão:

```bash
tmux new -s fh2backup
```

Execute o script dentro da sessão.

Para sair do terminal sem encerrar o processo:

```text
Ctrl+B
D
```

Para retornar:

```bash
tmux attach -t fh2backup
```

Para listar sessões:

```bash
tmux ls
```

---

# Arquivos de controle

O script cria dois arquivos auxiliares no diretório de destino.

## `fh2_media_manifest.tsv`

Registra os arquivos processados e seus respectivos status.

Campos:

```text
kind
id
uuid
path
size_bytes
status
```

Exemplos de status:

```text
OK
SKIP_COMPLETE
DRY_RUN
NO_URL
SIZE_MISMATCH
DOWNLOAD_ERROR
```

---

## `fh2_media_errors.tsv`

Lista arquivos que apresentaram problema durante o processamento.

Campos:

```text
id
uuid
path
```

Esse arquivo facilita identificar quais itens precisam ser verificados ou baixados novamente.

---

# URLs assinadas do MinIO

O FlightHub retorna no campo:

```text
original_url
```

uma URL assinada para o arquivo original no MinIO.

Ela pode ter validade limitada.

Por esse motivo, o script não salva previamente todas as URLs para utilizá-las horas depois.

O fluxo é:

```text
1. Indexar as pastas
2. Consultar novamente a biblioteca
3. Obter URLs atuais
4. Baixar os arquivos
```

Isso reduz a possibilidade de uma URL expirar antes de ser utilizada.

---

# HTTPS e certificados self-signed

Se o backend do FlightHub estiver configurado com HTTPS e utilizar certificado self-signed, o script pode ser executado com:

```bash
./fh2op_media_backup_interactive.sh \
  --url 'https://IP:PORTA' \
  --project 'UUID' \
  --insecure
```

No modo interativo, o script pergunta se o servidor utiliza certificado não confiável.

> `--insecure` desativa a validação do certificado TLS. Utilize somente em ambientes controlados e conhecidos.

---

# Segurança

O script executa apenas operações de leitura na biblioteca de mídia.

Ele não:

- exclui arquivos;
- altera arquivos do FlightHub;
- altera objetos no MinIO;
- modifica pastas da biblioteca;
- altera projetos;
- altera configurações do FlightHub.

A gravação ocorre somente no diretório local escolhido para o backup.

Mesmo assim, o `x-user-token` deve ser tratado como credencial sensível.

Evite:

```bash
./script.sh --token 'TOKEN'
```

quando não for necessário, pois o valor pode permanecer no histórico do shell.

Prefira o modo interativo ou:

```bash
export FH2_TOKEN='TOKEN'
```

---

# Fluxo recomendado

Para um novo projeto, utilize a seguinte sequência:

```text
1. Executar scan-only
        ↓
2. Conferir número de arquivos e volume
        ↓
3. Executar dry-run
        ↓
4. Conferir a estrutura das pastas
        ↓
5. Confirmar espaço livre no destino
        ↓
6. Abrir uma sessão tmux
        ↓
7. Executar o backup real
        ↓
8. Verificar fh2_media_errors.tsv
```

---

# Exemplo completo

```bash
chmod +x fh2op_media_backup_interactive.sh

tmux new -s fh2backup

./fh2op_media_backup_interactive.sh
```

No assistente:

```text
Backend do FlightHub:
http://IP_DO_SERVIDOR:30812

x-user-token:
********

Projetos disponíveis:
1) Projeto A
2) Projeto B
3) Projeto C

Escolha:
2

Diretório de destino:
/mnt/backup/Projeto_B

Modo:
3) Backup real

Continuar?
S
```

---

# Observações

- O script depende da estrutura da OpenAPI V2.0 do FlightHub 2 On-Premises.
- O endpoint utilizado para a biblioteca de mídia é:

```text
/openapi/v2.0/media/api/v1/workspaces/{workspace_id}/files
```

- A porta do backend não necessariamente é igual à porta utilizada para abrir a interface web do FlightHub.
- O tamanho mostrado pelo script utiliza unidades binárias quando `numfmt` está disponível, portanto valores podem aparecer como `GiB`.
- Para bibliotecas muito grandes, o tempo total dependerá principalmente da velocidade do armazenamento MinIO, rede e disco de destino.

---

## Versão

README criado para:

```text
fh2op_media_backup_interactive.sh
Version 0.3.0
```
'''

path = Path("/mnt/data/README_FH2OP_Media_Backup.md")
path.write_text(readme, encoding="utf-8")
print(f"README criado: {path}")
