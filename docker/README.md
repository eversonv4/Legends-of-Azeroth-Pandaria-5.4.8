# Rodando o servidor via Docker

Este projeto não tinha nenhuma configuração Docker. Os arquivos abaixo foram criados para
compilar e rodar o core (authserver + worldserver) e o MySQL inteiramente em containers,
sem precisar instalar toolchain/Boost/MySQL na máquina local.

Arquivos:
- `Dockerfile` — build multi-stage (compila o core, depois monta uma imagem de runtime leve).
- `docker-compose.yml` — serviços `db`, `authserver`, `worldserver` e `tools` (extração de dados).
- `docker/entrypoint.sh` — gera os `.conf` a partir dos `.conf.dist` do próprio projeto na
  primeira execução, já apontando para o container do MySQL.
- `docker/extract-data.sh` — roda mapextractor/vmap4extractor/vmap4assembler/mmaps_generator.

## 1. Build

```
docker compose build
```

A primeira build compila o core inteiro (demora — é C++); builds seguintes usam cache.

Flags de build disponíveis (ver `cmake/options.cmake`), passadas como `args:` no
`docker-compose.yml` ou via `--build-arg`:
- `WITH_TOOLS` (default `1`) — inclui mapextractor/vmap4extractor/vmap4assembler/mmaps_generator.
- `WITH_ELUNA` (default `1`).
- `WITH_PLAYERBOTS` (default `0`) — o próprio `AGENTS.md` do projeto recomenda manter
  desligado quando Eluna está ativo (conflitos/instabilidade).

## 2. Subir o banco e os servidores

```
docker compose up -d db
docker compose up -d authserver worldserver
```

No primeiro start, o `entrypoint.sh`:
1. Copia `authserver.conf.dist`/`worldserver.conf.dist` para `docker/etc/*.conf` (editável no
   host, sobrevive a rebuilds).
2. Ajusta a conexão MySQL para o container `db`.
3. Liga o auto-updater nativo do core (`Updates.EnableDatabases`/`Updates.AutoSetup`), que cria
   e popula os bancos `auth` e `characters` a partir de `sql/base/*.sql` e aplica tudo que tem em
   `sql/updates/`.
4. Liga o Eluna (`Eluna.Enabled = 1`, script path `lua_scripts`).

Acompanhe os logs:
```
docker compose logs -f worldserver
```

## 3. Banco `world` (não vem no repositório)

O dump base do banco `world` **não está no git** (é grande e versionado fora do repo). Se você
tentar sem ele, o worldserver vai logar algo como:

```
File "world_548_20240722.sql" is missing, download it from
"https://github.com/Legends-of-Azeroth/Legends-of-Azeroth-Pandaria-5.4.8/releases" ...
```

Passos:
1. Baixe o dump no link acima (releases do projeto) e descompacte.
2. Coloque o arquivo `.sql` **exatamente** em `docker/data/worldserver/` (é o diretório de
   trabalho do worldserver dentro do container) com o nome que o log pedir, ex.:
   `docker/data/worldserver/world_548_20240722.sql`.
3. Reinicie o worldserver: `docker compose restart worldserver`. O auto-updater importa o dump e
   aplica as migrações de `sql/updates/world/` em seguida.

## 4. Extraindo maps/vmaps/mmaps do cliente

Você precisa do cliente 5.4.8 build 18414 (link no `README.md` da raiz). Copie a instalação
completa do cliente para `docker/client/` no host (precisa existir `docker/client/Data/...`).

```
docker compose run --rm tools extract-data.sh
```

Isso roda mapextractor → vmap4extractor → vmap4assembler → mmaps_generator e copia o resultado
para `docker/data/worldserver/Data/`, que é o `DataDir` do worldserver. Só precisa ser feito uma
vez; `mmaps_generator` pode levar horas. Para extrair/gerar manualmente etapa por etapa:

```
docker compose run --rm tools bash
# dentro do container:
cd /client && mapextractor && vmap4extractor && vmap4assembler
cp -r dbc maps vmaps /data/
cd /data && mmaps_generator
```

## 5. Primeiro login

O `worldserver` do compose roda **sem stdin interativo** de propósito: o auto-updater do core
pergunta "create it? [yes/no]" no stdin na primeira vez que sobe, e um stdin aberto sem ninguém
digitando faz o processo travar nessa pergunta pra sempre (em vez de cair no padrão "yes" que
ocorre quando o stdin está fechado). Então não dá pra usar `docker compose attach` no serviço que
já está no ar.

1. Para criar a primeira conta, pare o worldserver "oficial" por um instante e suba uma instância
   própria interativa (os bancos já existem, então ele não vai cair naquele prompt de novo):
   ```
   docker compose stop worldserver
   docker compose run --rm worldserver
   ```
   No console que abrir:
   ```
   account create meuusuario minhasenha
   account set gmlevel meuusuario 3 -1
   ```
   `Ctrl+C` para sair, depois volte ao normal:
   ```
   docker compose up -d worldserver
   ```
2. No cliente, edite `Config.wtf` apontando para `127.0.0.1` (ou o IP da máquina Docker):
   ```
   SET portal "127.0.0.1"
   ```
3. Conecte e jogue.

## 6. Customizações (Eluna)

`contrib/lua_scripts/` do repositório é montado dentro do container
(`/azerothcore/run/worldserver/lua_scripts`). Edite os `.lua` no host normalmente e, no jogo ou
no console do worldserver, rode:
```
.reload eluna
```

## 7. Abrir para amigos

- Port forward (ou VPS) nas portas `3724` (auth) e `8085` (world), já expostas no
  `docker-compose.yml`.
- Atualize o `realmlist` do banco `auth` para o IP/domínio público:
  ```sql
  UPDATE realmlist SET address = 'SEU_IP_OU_DOMINIO' WHERE id = 1;
  ```
- Para reaproveitar um site Express com cadastro de contas (SRP6 como no MoP), basta esse site
  escrever direto na tabela `account` do banco `auth` (porta `3306` também está exposta no
  compose); não tem API HTTP própria para isso aqui.

## Comandos úteis

```
docker compose build                 # rebuild após mudar código C++
docker compose up -d                 # sobe db + authserver + worldserver
docker compose logs -f worldserver   # acompanhar logs
docker compose restart worldserver   # reiniciar depois de mudar .conf
docker compose down                  # parar tudo (sem apagar volumes/dados)
```

Dados persistentes ficam em `docker/data/` (Logs, Data, dump do world) e `docker/etc/` (os
`.conf`) — fora desses, nada é perdido ao rodar `docker compose down`.
