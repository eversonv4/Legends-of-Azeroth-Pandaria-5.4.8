# Como rodar o servidor e conectar o Client

## Guia rápido: clonar o repositório e jogar do zero

Resumo de ponta a ponta pra quem está clonando este repositório agora e nunca rodou nada dele.
As seções mais abaixo (arquitetura, `docker/README.md`) explicam o "porquê" de cada passo com
mais detalhe — isso aqui é só o caminho direto.

### 0. Pré-requisitos

- **Docker Desktop** instalado e rodando (Windows/Mac/Linux).
- **CPU/RAM alocados ao Docker Desktop**: isso importa de verdade. Rodamos esse projeto com só
  2 CPUs/8GB alocados e tivemos travamentos, picos de CPU e até um crash do core por disputa de
  recursos. Se a sua máquina tiver margem, aloque pelo menos **4 CPUs e 8-12GB** (Docker Desktop
  → Settings → Resources, ou edite `%USERPROFILE%\.wslconfig` no Windows com WSL2 e reinicie o
  Docker Desktop). Funciona com menos, só espere mais lentidão.
- O **client do WoW 5.4.8 build 18414** (link no `README.md` da raiz), instalado em algum lugar
  do seu disco — não precisa estar dentro da pasta do repositório.
- O dump do banco `world` (ver passo 5) — baixe com antecedência, é ~500MB.

### 1. Clonar e configurar

```
git clone <url-deste-repositorio>
cd LoA-Pandaria-5.4.8
cp .env.example .env
```

Edite o `.env` e aponte `CLIENT_DIR` para a pasta onde o client está instalado, por exemplo:

```
CLIENT_DIR=C:/Jogos/World of Warcraft 5.4.8
```

(Windows: use barras `/`, não `\`. Se não tiver o client ainda, pode deixar o valor padrão e
voltar nisso depois — só afeta o passo 6, extração de dados.)

### 2. Compilar as imagens

```
docker compose build
```

Compila o core inteiro em C++ — é a parte mais lenta de tudo (pode levar de ~40min a várias
horas, dependendo da CPU disponível). Só precisa ser feito de novo se o código-fonte mudar;
editar `.conf`, `docker-compose.yml`, scripts Lua etc. não invalida esse cache.

### 3. Subir o banco de dados

```
docker compose up -d db
```

### 4. Subir authserver e worldserver

```
docker compose up -d authserver worldserver
```

Na primeira vez, isso cria e popula automaticamente os bancos `auth` e `characters` (a partir de
`sql/base/*.sql` + `sql/updates/`). Acompanhe com `docker compose logs -f worldserver`.

### 5. Importar o banco `world` (não vem no repositório)

O dump base do `world` é grande e versionado fora do git. Sem ele o worldserver fica reiniciando
em loop com um erro tipo `File "world_XXXXXXXX.sql" is missing...`. Baixe o dump nas releases do
projeto, coloque o arquivo **exatamente** em `docker/data/worldserver/` (com o nome que o próprio
log pedir) e reinicie:

```
docker compose restart worldserver
```

### 6. Extrair maps/vmaps/mmaps do client

O worldserver **não sobe** sem `maps`/`vmaps` extraídos do client (checagem obrigatória no boot).
Com `CLIENT_DIR` já configurado no `.env` (passo 1):

```
docker compose run --rm tools extract-data.sh
```

Isso roda mapextractor → vmap4extractor → vmap4assembler → mmaps_generator e copia o resultado
pra `docker/data/worldserver/Data/`. A etapa final (`mmaps_generator`) é a mais longa — pode levar
horas dependendo da CPU. É normal, e só precisa ser feito uma vez.

### 7. Criar uma conta

O worldserver do dia a dia roda sem console interativo (pra não travar sozinho no primeiro boot).
Pra criar a conta, pare ele e suba uma instância temporária interativa:

```
docker compose stop worldserver
docker compose run --rm worldserver
```

No console que abrir:

```
account create meuusuario minhasenha
account set gmlevel meuusuario 3 -1
```

`Ctrl+C` para sair, depois volte ao modo normal:

```
docker compose up -d worldserver
```

### 8. Apontar o client pro servidor

No client, edite `WTF/Config.wtf`:

```
SET realmlist "127.0.0.1"
SET portal "127.0.0.1"
```

### 9. Jogar

Abra `Wow.exe`, logue com a conta do passo 7, escolha o realm e entre no mundo.

---

## Sobre esse mesmo Server/Client

Este repositório é o **Server** (authserver + worldserver). O **Client** (o jogo em si, `Wow.exe`)
é instalado separadamente na sua máquina e configurado para apontar para este servidor.

## Por que Client e Server são separados

É assim que todo MMO funciona (não é peculiaridade deste fork — o WoW retail da Blizzard é
desenhado da mesma forma):

- **Client** (`Wow.exe`) só sabe **renderizar**: modelos 3D, texturas, terreno, som, UI. Ele não
  sabe as regras do jogo — não sabe se um golpe acertou, quanto de vida um monstro tem, se você
  tem ouro suficiente para comprar algo. Ele só manda "o jogador apertou tal tecla" e desenha o
  que o servidor manda de volta.
- **Server** (este projeto) é quem decide **tudo**: dano, loot, economia, posição dos outros
  jogadores, se você pode entrar numa instância. Isso existe para impedir que alguém hackeie o
  client e dê item/ouro/vida infinita pra si mesmo — o client nunca é confiável.

Por isso o client e o server precisam ser da **mesma build exata** (5.4.8 build 18414): eles
falam um protocolo binário específico daquela versão.

Dentro do server, ainda existe outra divisão, que é a razão de existirem dois binários
(`authserver` e `worldserver`):

| | authserver | worldserver |
|---|---|---|
| Porta | 3724 | 8085 |
| Função | só login/conta (usuário+senha via SRP6) e devolve a lista de "realms" | a simulação do mundo em si (combate, movimento, chat, etc.) |
| Quantos | 1 | 1 por realm |

O client conecta primeiro no **authserver** para logar, recebe a lista de realms (vinda da tabela
`realmlist` do banco `auth`), você escolhe um realm, e aí o client abre uma segunda conexão, agora
para o **worldserver** daquele realm, usando uma chave de sessão que o authserver gerou.

## Passo a passo para conectar

Pré-requisito: Docker instalado e os arquivos de `docker-compose.yml`/`Dockerfile` deste repo
(ver `docker/README.md` para detalhes de cada passo).

### 1. Subir banco + servidores

```
docker compose up -d db authserver worldserver
```

Isso cria e popula automaticamente os bancos `auth` e `characters`. **Falta o banco `world`**
(não vem no repositório): baixe o dump nas releases do projeto, coloque em
`docker/data/worldserver/world_548_20240722.sql` e rode `docker compose restart worldserver`.
Sem isso o worldserver fica reiniciando em loop e não é possível entrar no mundo.

### 2. Extrair dados do cliente (maps/vmaps/mmaps)

O worldserver **não sobe sem `maps` e `vmaps`**: no boot ele checa a existência desses arquivos
para as zonas iniciais de cada raça e chama `exit(1)` se faltar algum
([World.cpp:1773-1790](src/server/game/World/World.cpp#L1773-L1790)) — não tem flag para pular
essa checagem. `mmaps` já é diferente: controla só o pathfinding dos NPCs
(`mmap.enablePathFinding`, ligado por padrão no `worldserver.conf.dist`) e sua ausência não
impede o boot, só deixa o movimento dos NPCs mais "burro".

Esses três diretórios são gerados a partir do seu client (não vêm prontos em lugar nenhum). Copie
o client 5.4.8 build 18414 para `docker/client/` e rode:

```
docker compose run --rm tools extract-data.sh
```

### 3. Criar uma conta

O `worldserver` do compose roda sem stdin interativo (senão o prompt interno de criação de banco
trava no primeiro boot). Para acessar o console e criar a conta:

```
docker compose stop worldserver
docker compose run --rm worldserver
```

No console que abrir:

```
account create meuusuario minhasenha
account set gmlevel meuusuario 3 -1
```

`Ctrl+C` para sair, depois volte ao modo normal:

```
docker compose up -d worldserver
```

### 4. Apontar o Client para o Server

No client, edite `WTF/Config.wtf`:

```
SET portal "127.0.0.1"
```

(`127.0.0.1` porque o Docker Desktop publica as portas 3724 e 8085 no `localhost` da sua máquina
Windows — o client não sabe nem precisa saber que é um container.)

Se for jogar de outra máquina da rede, use o IP da máquina que roda o Docker em vez de
`127.0.0.1`, e atualize também o `realmlist` do banco `auth`:

```sql
UPDATE realmlist SET address = 'IP_DA_MAQUINA_DOCKER' WHERE id = 1;
```

### 5. Jogar

Abra `Wow.exe` → tela de login pede usuário/senha → isso fala com o `authserver:3724` → escolhe o
realm → abre conexão com `worldserver:8085` → você entra no mundo.

## Referência rápida

```
docker compose up -d                 # sobe db + authserver + worldserver
docker compose logs -f worldserver   # acompanhar logs
docker compose restart worldserver   # reiniciar depois de mudar .conf ou importar o dump do world
docker compose down                  # parar tudo (sem apagar volumes/dados)
```

Mais detalhes de cada etapa (build, flags do core, Eluna, abrir para amigos) em
`docker/README.md`.
