# ÁXIS · Meus treinos

App de treino para celular (PWA) com dois ambientes:

- **Personal:** lista de alunos, ficha de cada um, treinos registrados, evolução, avaliação física (medidas e fotos), recados e convite por link.
- **Aluno:** ficha montada pelo personal, registro de carga por série, cronômetro de descanso com aviso, vídeos de execução, calendário, recordes, peso corporal, evolução em PDF e comentários nos treinos.

Acesse: https://mpalu03.github.io/meus-treinos/

## Instalar na tela inicial

- **iPhone (Safari):** abra o link, toque em Compartilhar e depois em "Adicionar à Tela de Início".
- **Android (Chrome):** abra o link, toque no menu ⋮ e depois em "Instalar app" (ou "Adicionar à tela inicial").

Depois da primeira abertura o app funciona sem internet.

## Contas e dados

Login e sincronização usam o [Supabase](https://supabase.com) (projeto `qlksntoamjutmycrqidf`). O app funciona sem internet: o que for registrado offline fica numa fila e é enviado quando a conexão volta.

- **Administrador (login mestre):** conta sem treinos que vê todos os personais e os alunos de cada um, cadastra novos personais e bloqueia ou libera o acesso deles. Quem é administrador fica na tabela `admins` (só por SQL).
- **Personal:** o administrador cadastra o nome e o e-mail; a pessoa cria a conta com esse e-mail e já entra como personal (se já tinha conta, vira personal na hora). Personal bloqueado perde o acesso aos alunos, sem apagar nada.
- O personal cadastra o aluno e envia o convite (link ou código). Ao criar a conta pelo link, a conta do aluno já fica ligada à ficha.
- Quem pode ver e alterar o quê é garantido pelas regras do banco (Row Level Security), em `supabase/schema.sql`. O aluno só vê os próprios dados; só o personal dele altera a ficha e as avaliações.
- `config.js` tem só a URL e a chave **publicável** do projeto, feitas para ficar no app. A chave secreta (service_role) nunca entra aqui.
- Sem `config.js`, o app volta ao modo antigo: tudo salvo só no celular.

### Aviso do fim do descanso (notificação)

Com o app fechado ou o celular bloqueado, o celular pausa o app e o cronômetro dele para. Por isso o aviso vem do servidor:

1. Ao começar o descanso, o app agenda um aviso na tabela `avisos` (o horário é calculado pelo relógio do servidor).
2. A cada 2 segundos, um job do banco (`pg_cron`) procura avisos vencidos e chama a função `descanso` (`pg_net`).
3. A função envia a notificação (Web Push) para o celular que agendou.

As mensagens vão no formato Declarative Web Push (iOS 18.4+): o próprio sistema mostra a notificação mesmo se o service worker não rodar, e o service worker confirma o recebimento no log da função. Ao sair do app no meio do descanso, chega também uma notificação silenciosa com a hora em que ele acaba.

Se o app estiver na tela perto do fim, o aviso é cancelado e quem toca é o alarme do próprio app. Ao sair do app durante o descanso, o aviso é reenviado por `sendBeacon`, caso ainda não exista.

- No iPhone, precisa do iOS 16.4 ou mais novo e do app aberto pelo ícone da tela inicial.
- A chave privada de envio (VAPID) foi gerada dentro do Supabase e fica no Vault (`axis_vapid`). No app e na função vai só a chave pública.
- Arquivos: `supabase/avisos.sql` (tabelas, regras e jobs) e `supabase/functions/descanso/` (envio).

Os arquivos SQL rodam nesta ordem: `schema.sql`, `avisos.sql`, `admin.sql`.

Configuração no painel do Supabase: **Authentication → URL Configuration → Site URL** = `https://mpalu03.github.io/meus-treinos/`.

## Estrutura

| Arquivo | O que é |
| --- | --- |
| `index.html` | O app inteiro (HTML, CSS e JavaScript) |
| `sw.js` | Service worker: guarda o app para uso offline |
| `manifest.webmanifest` | Nome, cores e ícones do app instalado |
| `config.js` | Endereço e chave publicável do Supabase |
| `supabase/schema.sql` | Tabelas, regras de acesso (RLS) e funções do banco |
| `supabase/avisos.sql` | Notificação de fim do descanso: inscrições, avisos e jobs |
| `supabase/admin.sql` | Conta de administrador, cadastro e bloqueio de personais |
| `supabase/functions/descanso/` | Função que envia as notificações (Web Push, sem dependências) |
| `vendor/supabase-2.118.0.js` | supabase-js 2.118.0 (login e banco) |
| `vendor/jspdf.umd.min.js` | jsPDF 2.5.1, gera os PDFs de evolução |
| `fonts/` | Cormorant Garamond e Jost (SIL Open Font License) |
| `icons/` | Ícones do app |

Ao alterar arquivos fixos (fontes, ícones, bibliotecas, `config.js`), troque `VERSION` em `sw.js` para os celulares baixarem a versão nova.
