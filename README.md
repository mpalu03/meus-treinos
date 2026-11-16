# ÁXIS · Meus treinos

App de treino para celular (PWA): ficha com os treinos A, B, C e D, registro de carga por série, cronômetro de descanso com aviso, vídeos de execução, calendário, recordes, peso corporal e evolução em PDF.

Acesse: https://mpalu03.github.io/meus-treinos/

## Instalar na tela inicial

- **iPhone (Safari):** abra o link, toque em Compartilhar e depois em "Adicionar à Tela de Início".
- **Android (Chrome):** abra o link, toque no menu ⋮ e depois em "Instalar app" (ou "Adicionar à tela inicial").

Depois da primeira abertura o app funciona sem internet.

## Onde ficam os dados

Os treinos ficam salvos no próprio celular (armazenamento do navegador), nunca neste repositório. Use **Ficha → Backup → Baixar backup** de vez em quando; para trocar de celular, instale o app no aparelho novo e use **Importar backup**.

## Estrutura

| Arquivo | O que é |
| --- | --- |
| `index.html` | O app inteiro (HTML, CSS e JavaScript) |
| `sw.js` | Service worker: guarda o app para uso offline |
| `manifest.webmanifest` | Nome, cores e ícones do app instalado |
| `vendor/jspdf.umd.min.js` | jsPDF 2.5.1, gera os PDFs de evolução |
| `fonts/` | Cormorant Garamond e Jost (SIL Open Font License) |
| `icons/` | Ícones do app |

Ao alterar arquivos fixos (fontes, ícones, jsPDF), troque `VERSION` em `sw.js` para os celulares baixarem a versão nova.
