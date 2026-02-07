# Arquitetura e Funcionamento do Repositório GitOps

Este repositório é a **única fonte da verdade** para o que deve estar rodando no cluster Kubernetes. O conceito principal é **GitOps**: o Argo CD garante que o cluster sempre reflita o estado declarativo definido aqui.

## A Árvore de Diretórios: Visão Geral

```
platform-gitops/
├── argocd/      # O "Cérebro": Define o que o Argo CD deve gerenciar.
├── apps/        # "Nossas Coisas": Manifestos dos seus próprios serviços.
└── infra/       # "Coisas dos Outros": Configuração de ferramentas de terceiros (Grafana, MySQL...).
```

---

### 1. `argocd/` — O Painel de Controle do Argo CD

Pense nos arquivos dentro de `argocd/` como "ponteiros" ou "aplicações" que o Argo CD deve observar e manter sincronizadas no cluster.

*   `argocd/dev/grafana.yaml`: Este arquivo diz ao Argo CD:
    > "Crie uma aplicação chamada `grafana-dev`. Pegue o **Helm Chart** do Grafana que está no repositório `https://grafana.github.io/helm-charts`, mas use as configurações customizadas do arquivo `values.yaml` que está no **nosso repositório Git** em `infra/grafana/dev`. Instale tudo isso no namespace `dev-monitoring`."

*   `argocd/dev/apps.yaml`: Este arquivo diz:
    > "Crie uma aplicação chamada `my-service-dev`. Pegue os manifestos Kubernetes que estão na pasta `apps/my-service/overlays/dev` do **nosso repositório Git**, processe-os com a ferramenta Kustomize e instale no namespace `dev-apps`."

**Em resumo: `argocd/` define o "O QUÊ" e o "ONDE" para o Argo CD.**

---

### 2. `apps/` — Suas Aplicações (Gerenciadas com Kustomize)

Aqui ficam os manifestos Kubernetes dos serviços que **você desenvolve**. Usamos a ferramenta **Kustomize** para evitar copiar e colar configurações entre ambientes.

*   `apps/my-service/base/`: A Base Comum
    *   Contém os manifestos Kubernetes **padrão**, que não mudam entre `dev` e `prod`. Por exemplo, o `service.yaml` (que expõe a porta do seu app) e o `deployment.yaml` (que define a imagem a ser usada, os volumes, etc.).
    *   É o "template" da sua aplicação.

*   `apps/my-service/overlays/`: As Camadas de Customização
    *   Um "overlay" (camada) pega os manifestos da `base` e aplica **pequenas modificações** (patches) para um ambiente específico.
    *   `overlays/dev/`: Contém apenas as **diferenças** para o ambiente `dev`.
        *   `patch-replicas.yaml`: Em vez de copiar o `deployment.yaml` inteiro, temos um arquivo minúsculo que diz: "Naquele deployment da `base`, mude o campo `replicas` para `1`".
        *   `kustomization.yaml`: É o arquivo que orquestra tudo. Ele diz: "Importe tudo da `../../base` e depois aplique os patches que estão nesta pasta."

**Vantagem:** Você não repete código. Se precisar adicionar uma variável de ambiente nova para todos os ambientes, você edita apenas um lugar: o `deployment.yaml` na `base`.

---

### 3. `infra/` — Configuração de Ferramentas de Terceiros (com Helm)

Aqui você customiza os Helm Charts de ferramentas que você não desenvolveu, como Grafana, MySQL, etc.

*   `infra/grafana/dev/values.yaml`:
    *   Helm Charts de terceiros são como "instaladores" com dezenas de opções configuráveis. O arquivo `values.yaml` é onde você **sobrescreve os valores padrão** desse chart.
    *   No nosso `infra/grafana/dev/values.yaml`, nós dizemos, por exemplo: "O datasource padrão do Grafana deve ser o VictoriaMetrics que está neste endereço...".
    *   Você não precisa baixar ou modificar o Helm Chart do Grafana, apenas informa os valores que quer mudar.

### Quem Chama o `values.yaml`?

Esta é a conexão mais importante:

1.  O Argo CD lê o arquivo `platform-gitops/argocd/dev/grafana.yaml`.
2.  Dentro dele, na seção `source:`, o Argo CD vê duas instruções principais:
    *   `repoURL: 'URL_DO_SEU_REPO_GITOPS'` e `path: infra/grafana/dev`: "Vá para o **nosso** repositório Git, na pasta `infra/grafana/dev`."
    *   `helm.repoURL: https://grafana.github.io/helm-charts` e `helm.chart: grafana`: "O Chart que você vai instalar é o `grafana` do repositório **oficial** do Grafana."
    *   `helm.valueFiles: - values.yaml`: "E use o arquivo `values.yaml` que você encontrou no `path` do nosso repositório Git para customizar a instalação."

O Argo CD então junta o Chart oficial com as suas customizações do `values.yaml` e instala o resultado final no cluster.

### Resumo do Fluxo

1.  **Argo CD Application (`argocd/`)**: É o gatilho. Define de onde pegar o código/chart e onde instalar.
2.  **Para seus apps (`apps/`)**: O "ponteiro" aponta para uma pasta de `overlay` do Kustomize.
3.  **Para infra (`infra/`)**: O "ponteiro" aponta para um Helm Chart remoto, mas busca as customizações (`values.yaml`) no seu próprio repositório Git, na pasta `infra/`.