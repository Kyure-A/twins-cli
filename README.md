# twins-cli

筑波大学の教育情報システム TWINS/CAMPUSSQUARE を端末から操作する、非公式の
OCaml CLI です。TWINS の HTML と Spring Web Flow を解析し、ブラウザで行う主な
照会・履修操作をコマンドとして提供します。

## 対応している操作

- ログイン、ログアウト、セッション確認
- 成績一覧（TSV / JSON）
- 履修時間割（春 A〜C、秋 A〜C、夏休・春休、TSV / JSON）
- 履修登録と削除
- 授業・一般掲示の検索、未読・表題絞り込み、本文表示（TSV / JSON）
- 休講情報の検索
- TWINS の既知メニュー一覧と、任意フローへの低レベルアクセス

TWINS 側の画面変更に追従しやすいよう、HTML の要素 ID だけでなくフォーム名や
見出しも使って解析しています。ただし公式 API ではないため、画面更新後は修正が
必要になる可能性があります。

## ビルド

OCaml 5.1 以上と Dune 3.12 以上が必要です。

```console
opam install . --deps-only --with-test
dune build
dune runtest
dune exec twins -- --help
```

Nix だけで試す場合:

```console
nix-shell -p ocaml dune ocamlPackages.findlib \
  ocamlPackages.cmdliner ocamlPackages.cohttp-lwt-unix \
  ocamlPackages.lambdasoup ocamlPackages.yojson ocamlPackages.alcotest \
  --run 'dune runtest && dune exec twins -- --help'
```

インストールする場合は `dune install` または `opam install .` を使います。

## 認証

```console
twins login
twins status
```

ユーザー名とパスワードは対話入力できます。自動実行では `TWINS_USERNAME` と
`TWINS_PASSWORD` も利用できます。パスワードは保存せず、ログイン後の Cookie
だけを `${XDG_STATE_HOME:-~/.local/state}/twins-cli/session` にモード `0600` で
保存します。保存先は `TWINS_SESSION_FILE` または全コマンド共通の
`--session-file PATH` で変更できます。

セッションを破棄するには次を実行します。

```console
twins logout
```

## 使用例

成績と秋 A の時間割を表示します。

```console
twins grades
twins grades --json
twins timetable --module autumn-a
twins timetable --module autumn-a --json
```

モジュール名は `spring-a`, `spring-b`, `spring-c`, `summer`, `autumn-a`,
`autumn-b`, `autumn-c`, `spring-break` です。

授業掲示を検索します。

```console
twins notices --kind classes --unread --limit 20
twins notices --kind general --title ガイダンス --json
twins notice --kind classes NOTICE_ID
```

当日の履修中科目の休講情報、または指定期間の全休講情報を表示します。

```console
twins cancellations
twins cancellations --from 2026-10-01 --to 2026-10-31 --all
```

## 履修登録・削除

変更系コマンドは、意図しない送信を防ぐため `--yes` がない限り何も変更しません。
曜日は月曜が `1`、時限は `1`〜`9` です。

```console
twins register GE00000 --module autumn-a --day 1 --period 1 --yes
twins unregister GE00000 --module autumn-a --yes
```

TWINS が年間履修上限の確認を表示した場合だけ、規則上その登録が許されていることを
確認したうえで `--force-limit` を追加してください。登録期間、抽選、履修条件などの
判定は TWINS 側の結果をそのまま優先します。

## 低レベル操作

`twins menu` で確認できるメニュー名、または Spring Web Flow ID を `raw` に渡すと、
画面の本文を取得できます。`--event` と `--field NAME=VALUE` を指定すると、最初の
画面にあるフォームへ 1 イベントを送信できます。

```console
twins menu
twins raw graduation-check
twins raw RSW0001300-flow
twins raw notices --form keijiSearchForm --event findSelect \
  --field keijitype=3 --field keijiTitle=奨学金
```

`raw` は TWINS の内部フォームを直接扱う上級者向け機能です。イベント名によっては
状態を変更し得るため、ブラウザの開発者ツール等で送信内容を確認してから使って
ください。

## CI

GitHub Actions の通常 CI は push、pull request、手動実行で起動し、Linux/macOS と
サポート下限・最新の OCaml に対して以下を検証します。

- 依存関係を毎回 opam-repository から解決
- 全 Dune ターゲットのビルドとテスト
- opam パッケージ定義の lint
- CLI のインストールと、インストール済みバイナリのスモークテスト
- 認証がない状態で変更系コマンドが送信を拒否すること

これとは別に、毎日 06:17 JST に TWINS の公開ログイン画面へアクセスし、CLI が
依存するログインフォームの契約を検査します。GitHub Actions 自体は Dependabot の
週次更新対象です。

認証情報を GitHub に預けないため、CI ではログイン後のデータ取得や履修変更を自動
実行しません。また、外部サービスである TWINS の停止や予告なしの画面変更までを
CLI 側だけで防ぐことはできません。公開スモークテストは、その変化を毎日検知する
ためのものです。

## 注意

このソフトウェアは筑波大学の公式ツールではありません。利用者自身のアカウントに
対してのみ使用し、大学の規則、履修登録期間、TWINS の利用条件に従ってください。
大量アクセスを避け、重要な変更後は TWINS の画面でも結果を確認してください。

公式資料: [TWINS 操作マニュアル案内](https://www.tsukuba.ac.jp/campuslife/tool-manual-twins/) /
[TWINS 操作マニュアル PDF](https://www.tsukuba.ac.jp/campuslife/calendar-ceremony/orientation-fall/twins_manual.pdf)
