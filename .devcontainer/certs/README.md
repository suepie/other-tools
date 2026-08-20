# 社内 CA 証明書の置き場

TLS インスペクション（Netskope など）を挟む社内ネットワークで使う場合、ここに
ルート CA 証明書を置いてください。`.pem` と `.crt` を拾ってコンテナの証明書ストアに
登録します。

```
.devcontainer/certs/rootcaCert.pem
```

- **置かなくてもビルドは通ります。** 社外や自宅から使う場合は空のままで問題ありません。
- **証明書ファイルはコミットされません**（リポジトリルートの `.gitignore` で `*.pem` /
  `*.crt` を除外しています）。環境ごとに各自で配置してください。
- 登録後は `NODE_EXTRA_CA_CERTS` / `AWS_CA_BUNDLE` / `REQUESTS_CA_BUNDLE` が
  システムのバンドルを指すので、Node・AWS CLI・Python から参照されます。
