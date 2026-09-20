# Ficha Campo – ACOMPANHAMENTO (Android)

Repositório público de distribuição das atualizações Android.

## Estado atual

- versão publicada: V8.3 / versionCode 23
- APK: `ficha-campo-acompanhamento.apk`
- manifesto consumido pelo app: `atualizacao.json`
- applicationId protegido: `br.com.oam.fichacampolavra.v1`

## Automação

O workflow `.github/workflows/atualizar-manifesto.yml` valida novas Releases antes de atualizar o manifesto:

1. baixa o APK da Release;
2. confirma o applicationId;
3. lê versionCode e versionName;
4. impede regressão de versionCode;
5. verifica a assinatura estrutural do APK quando a ferramenta está disponível;
6. calcula SHA-256;
7. atualiza `atualizacao.json` automaticamente.

O manifesto não deve ser alterado manualmente para uma nova versão antes de o APK correspondente estar publicado e validado.

## Preservação de dados

As atualizações devem manter o mesmo applicationId e a mesma chave de assinatura da V8.3. O app deve ser atualizado por cima, sem desinstalação.

O projeto do iPhone é independente e não faz parte deste fluxo.
