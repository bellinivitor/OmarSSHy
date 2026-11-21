# OmarSSHy

App macOS para abrir por SSH os projetos do Omarchy. O terminal é integrado à janela.

## Instalação

Baixe `OmarSSHy-macOS.zip` na [página de versões](https://github.com/bellinivitor/OmarSSHy/releases), extraia e abra `OmarSSHy.app`. O download é para Macs com Apple Silicon e macOS 14 ou superior. O aplicativo tem assinatura local.

## Como usar

1. Abra `OmarSSHy.app` e informe seu alias SSH ou o endereço do Omarchy. Usuário e porta são opcionais quando já estiverem no seu `~/.ssh/config`.
2. Clique em **Conectar**. Na primeira conexão, compare a impressão digital exibida com a do servidor antes de aceitá-la. O OmarSSHy reutiliza esse destino ao abrir novamente.
3. Selecione um projeto para abrir o terminal na pasta dele. Projetos com `artisan` na raiz habilitam o menu **Artisan** no cabeçalho.
4. Em **Clonar**, escolha **Conta do GitHub** para navegar pelos repositórios pessoais e das organizações acessíveis pelo GitHub CLI do Omarchy. Escolha **Link público** para colar uma URL Git. **Novo repo** inicia um repositório vazio na pasta de projetos.

O OmarSSHy procura `~/work` e também reconhece `~/Work`. A lista é atualizada automaticamente enquanto a conexão está aberta, incluindo repositórios Git e projetos Laravel em subpastas.

O SSH do macOS usa as credenciais da configuração local. A clonagem usa as credenciais Git disponíveis no Omarchy. Os atalhos Artisan usam o ambiente do shell interativo no Omarchy para encontrar o PHP. O app salva o endereço, o usuário e a porta da última conexão bem-sucedida.

## Compilar o código

Use macOS 14 ou superior com ferramentas de desenvolvimento Swift 6.2 ou superior.

`./Scripts/build-app.sh` gera e assina localmente `dist/OmarSSHy.app`.

`swift test --disable-xctest` executa os testes do núcleo SSH e Git.
