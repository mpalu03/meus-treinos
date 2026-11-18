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

- A **primeira conta criada vira personal**. Outros personais podem ser liberados na tabela `personais` (e-mail).
- O personal cadastra o aluno e envia o convite (link ou código). Ao criar a conta pelo link, a conta do aluno já fica ligada à ficha.
- Quem pode ver e alterar o quê é garantido pelas regras do banco (Row Level Security), em `supabase/schema.sql`. O aluno só vê os próprios dados; só o personal dele altera a ficha e as avaliações.
- `config.js` tem só a URL e a chave **publicável** do projeto, feitas para ficar no app. A chave secreta (service_role) nunca entra aqui.
- Sem `config.js`, o app volta ao modo antigo: tudo salvo só no celular.

Configuração no painel do Supabase: **Authentication → URL Configuration → Site URL** = `https://mpalu03.github.io/meus-treinos/`.

## Estrutura

| Arquivo | O que é |
| --- | --- |
| `index.html` | O app inteiro (HTML, CSS e JavaScript) |
| `sw.js` | Service worker: guarda o app para uso offline |
| `manifest.webmanifest` | Nome, cores e ícones do app instalado |
| `config.js` | Endereço e chave publicável do Supabase |
| `supabase/schema.sql` | Tabelas, regras de acesso (RLS) e funções do banco |
| `vendor/supabase-2.118.0.js` | supabase-js 2.118.0 (login e banco) |
| `vendor/jspdf.umd.min.js` | jsPDF 2.5.1, gera os PDFs de evolução |
| `fonts/` | Cormorant Garamond e Jost (SIL Open Font License) |
| `icons/` | Ícones do app |

Ao alterar arquivos fixos (fontes, ícones, bibliotecas, `config.js`), troque `VERSION` em `sw.js` para os celulares baixarem a versão nova.
