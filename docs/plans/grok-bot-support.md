# Grok Bot 対応計画

作成日: 2026-11-19 / 状態: Draft / 調査基準: birdwatch `5b90b59`

## 目的と進め方

Grok Bot の作業完了とユーザーへの質問を、既存エージェントと同じ鳥の鳴き声・dashboard・inbox で確認できるようにする。まずイベント取得と Mac への配送を検証し、成立した方式で小さく実装する。

対象は xAI の **Grok Bot デスクトップアプリと、そのクラウド上の Bot**。Grok Build CLI、通常の Grok チャット、X 上の `@grok` は別対象とする。Grok をモデルとして利用する Hermes / OpenClaw には既存アダプターを使う。

この PR の成果物は計画書のみ。以下のアダプター、MCP ツール名、payload、配送経路は今後の設計案であり、Grok Bot の公式仕様や実装済み機能を表すものではない。

## 確認できたこと

### Grok Bot 側

| 確認事項 | 設計への影響 |
|---|---|
| Bot は持続的なクラウド PC で動く。カスタム MCP は Remote HTTPS / Command を選べ、Command は Bot 側の PC で動く [G1] | Command に Mac の `dispatch.sh` を指定するだけでは接続できない。イベント取得と Mac への配送を分ける |
| 完了・入力待ちのシステム通知はあるが、表示中の Bot などでは抑制される [G2] | OS 通知の読み取りを、全イベントを取得する主経路にはしない |
| Skills は再利用可能な手順を指示できる。Routines の webhook は作業を開始する入口 [G3] | Skill からの通知ツール呼び出しを試作候補にする。起動 webhook を完了 callback として扱わない |
| ローカル PC 上のコマンド実行には独立した設定・承認がある [G4] | 直接実行案は承認負担を測る。通知のために既存の承認設定を緩める前提にしない |
| Enterprise の inference hooks はモデル要求の検査用。返信等は tool-call frame の対象外で、`session_id` はチャットをまたぐ Bot 単位 [G5] | 完了・承認イベントの購読 API として流用しない。会話 ID とも見なさない |

2026-11-19 に確認した下記の公開資料では、外部から完了・質問・承認カードのライフサイクルを購読する汎用 API は確認できていない。API が存在しないと断定せず、利用版での確認を最初の工程に残す。

### birdwatch 側

- [`scripts/dispatch.sh`](../../scripts/dispatch.sh) は `session_id`、`hook_event_name`、`cwd`、`text` / `message` / `tool_name` を受け取る。直接 `text` を渡せるため、Grok の transcript を読む必要はない。
- `Stop` は既存の判定で質問を Tier A、一定長以上の報告を Tier B、短い相づちを無音にする。質問判定はヒューリスティックであり、明示的な質問イベントとは区別する。
- 状態保存先は `BIRDWATCH_STATE_DIR` → `CLAUDE_PLUGIN_DATA` → `~/.claude/state`。複数 harness で共有する場合は `BIRDWATCH_STATE_DIR` を揃える。
- 基準コミットの project は `cwd` の値。workspace の統合や鳥の割当改善を、この計画の前提にしない。
- session ごとの rate limit は queue 追記より前に動くため、完了直後の質問も捨てられる場合がある。dispatcher の成功終了だけでは inbox への保存成功と見なせない。
- [`scripts/ask.sh`](../../scripts/ask.sh) の返信は tmux 前提で、dispatcher の pane 検索も Claude 向け。Grok への返信・承認操作は現状の経路では扱えない。

## 最初の対応範囲

最初の候補は、利用者が明示的に導入する **Skill + カスタム MCP による通知**。Bot が選択した作業の終了時や質問時に通知ツールを呼び、Mac 側の薄いアダプターが既存 dispatcher へ渡す。

これは Bot の協調的な報告であり、モデルの呼び忘れや途中停止を完全には検出できない。最初は experimental として提供し、Grok Bot 本来の承認カード通知は未対応と明記する。公式イベント経路が確認できた場合は、その経路を優先して再設計する。

| 入力の意味（birdwatch 独自案） | dispatcher への変換 | 初期対応 |
|---|---|---|
| `completed`: 最終結果の通知 | `Stop` + 短い `text` | 対応。既存の質問・報告判定に従う |
| `question`: ユーザーの回答が必要 | `Notification` + 短い `message` | 対応。Tier A の質問として表示 |
| Grok Bot が生成した実際の承認カード | `PermissionRequest` + `tool_name` | 取得仕様を確認できるまで保留 |
| streaming、途中経過、空出力、未知の種別 | 呼び出さない | 通知しない |

通常の質問や MCP ツール実行を、実際の承認要求と見なさない。inbox は受信内容の一覧として使い、Grok で解消した待機状態の自動同期は初期対応に含めない。返答と承認は Grok Bot 側で行う。

## 構成案と方式決定

```text
Grok Bot + 通知用 Skill
  → カスタム MCP の通知ツール（仮称 birdwatch_notify）
  → 検証して選ぶ配送経路
  → Mac 上の adapters/grok-bot/
  → scripts/dispatch.sh
  → 既存 state / 音声 / dashboard / inbox
```

cloud PC 上の MCP サーバーと Mac は別ホスト。Mac の `localhost` が cloud PC から届く前提にはしない。既存 dashboard を外部受信用に公開しない。

| 候補 | 検証すること | 採否の条件 |
|---|---|---|
| Bot から Mac の通知コマンドを直接実行 | 対象端末の固定、毎回の承認、実行時間、切断時の動作 | 既存の許可範囲で実行でき、通知自体が作業を止め続けないこと |
| 認証付き中継に送信し、Mac が取得 | ホスト・運用担当、認証、保持期間、順序、再送、費用 | 利用者ごとの配送分離と運用条件を確定できること |
| 公式のイベント連携 | 対象版・契約条件、イベントと ID、接続先 | 必要なイベントを実 payload で確認できること |

中継を選ぶ場合は MCP / 配送プロセスと再接続可能な Mac 側 consumer が必要になる。追加依存、常駐起動・停止・更新方法を方式決定時に確定する。成立する経路がなければ検証結果を残して保留し、対応済みと表記しない。

## アダプターの契約案

以下は **birdwatch 内部の受信形式の例**。Grok Bot がこの形式を自動生成するという意味ではない。

```json
{
  "schema_version": 1,
  "event_id": "example-event-001",
  "kind": "completed",
  "session_key": "example-registered-session",
  "project_key": "grok-bot/example-project",
  "text": "集計を完了し、結果ファイルを保存しました。"
}
```

- 通知先・session / project の対応は接続設定で登録する。任意の Bot 入力から別利用者の配送先やローカルパスを指定させない。
- `session_id` は登録済み installation / account / Bot / chat の識別子から安定した hash を作り、`grok-bot-` を付ける。実際の chat ID が取得できない場合は、明示的な作業セッション登録で区別する。並行チャットを区別できない構成は「1 Bot / 1 登録セッション」に制限して表示する。
- `cwd` は登録した実在 workspace、または `grok-bot/<project-key>` の論理名を使う。同じ project の会話は鳥を共有し、session は分ける。クラウド上のパスを Mac の workspace として解釈しない。
- `event_id` は通知元が再送しても保持する。同じイベントの再受信は dispatcher の前で除外する。既存の音声抑制は queue 重複の除去にはならない。別イベントの質問は、完了直後でも inbox に残すため、queue 記録と音声 rate limit を分ける最小変更を共通 dispatcher に計画する。
- 通知文は既定で内容を含まない定型文にする。完了は「Grok Bot の作業が完了しました。結果は Grok Bot で確認できます。」、質問は「Grok Bot が回答を待っています。Grok Bot を開いて確認してください。」を使う案とし、前者が既存の20文字以上の条件を満たして Tier B になることをテストする。
- 短い要約は利用者が選択した場合だけ送る。全文 transcript、プロンプト、認証情報、添付は転送しない。dispatcher が抜粋を保存する点も導入手順に記載する。
- 形式・文字数・payload サイズを検証し、shell 文字列として評価しない。timeout と再送上限を設定し、配送失敗で元の作業を失敗扱いにしない。接続状態と破棄件数を別途確認できるようにする。
- オフライン時の有効期限を設定し、期限を過ぎたイベントは鳴らさない。再接続時の大量通知を抑え、古い入力待ちが現在も有効か保証できない点を示す。
- `BIRDWATCH_DISPATCH`、`BIRDWATCH_STATE_DIR`、`BIRDWATCH_OFF` と既存の音声 rate limit を再利用する。イベント分類・音声・dashboard の別実装は増やさない。

## 実装順序と成果物

| 工程 | 作業・成果物 | 次へ進む条件 |
|---|---|---|
| 1. 接続検証 | 利用版・接続権限を記録。最小 MCP ツールと Skill、ID 取得、Mac 配送候補を試す。完了・質問・切断の匿名化 fixture と結果を残す | 受信経路とセッションの区別を再現できる。モデル報告に依存する範囲を明記できる |
| 2. 方式決定 | 直接実行 / 中継 / 公式連携を比較し、この文書へ採用方式・依存・起動停止・運用条件を追記 | 実行場所・配送先・認証・承認負担・オフライン動作が確定する |
| 3. アダプター | `adapters/grok-bot/` に受信検証・正規化・重複除去を実装。必要な consumer / MCP server は同ディレクトリへ配置 | fixture で dispatcher 契約を満たし、失敗が Grok の作業へ波及しない |
| 4. 導入・回帰検証 | 導入 README、通知 Skill、fixtures、テスト、CI の対象を追加。macOS で実 Bot を確認 | 下記の受け入れ条件を満たす |
| 5. 実験提供 | root README に対応範囲・制限・解除手順を掲載 | 実行証跡があり、通知欠落の限界と未対応項目が説明されている |

この計画 PR で変更するのは本ファイルのみ。以降の候補ファイルは次のとおり。

- `adapters/grok-bot/README.md`: 必要条件、接続設定、実行場所、対応イベント、制限、停止・解除。
- `adapters/grok-bot/skills/`: Grok Bot 用の通知手順。取得可能な正式形式に合わせ、呼び忘れをゼロと主張しない。
- `adapters/grok-bot/`: 工程 2 で選定した実装と必要な依存定義。ライブラリーを使う場合はバージョンを固定する。
- `test/grok_bot_adapter.bats` / `test/fixtures/grok-bot/`: 正規化と既存 dispatcher への結合テスト。中継を採用した場合は配送・認証・再接続テストも追加する。
- `.github/workflows/ci.yml`: 追加実装の lint / test。現行 shellcheck は `scripts/*.sh` のみなので、shell アダプターを選んだ場合はそのパスも対象にする。
- `README.md`: 実 Bot の検証後に experimental として導入方法を追加する。

共通側では [`scripts/dispatch.sh`](../../scripts/dispatch.sh) の queue 記録と音声 rate limit を分ける変更を行う。加えて、Grok への誤返信を防ぐため通知専用ソースの識別と返信不可表示が必要か検証する。必要な変更は dispatcher / `ask.sh` / dashboard の該当箇所に限定し、既存ソースの回帰テストを付ける。

## 受け入れ条件

- [ ] 匿名化した実 payload と利用版を記録し、合成 fixture と区別できる。
- [ ] 完了は `Stop`、明示的な質問は `Notification` として届く。要約なしの定型完了文が Tier B で保存・発音される。相づち・途中経過・未知種別・壊れた JSON は通知されない。
- [ ] 複数 Bot / 複数セッション / 既存 harness の ID が衝突せず、同一 project の識別と session の pan が安定する。制限構成も明示する。
- [ ] 同じ `event_id` の再送で queue と音が増えない。完了の直後4秒以内に届く別の質問が inbox に残り、音だけが設定どおり抑制される。順序逆転、連続通知、consumer 再起動でも動作が再現できる。
- [ ] Mac のスリープ・切断・復帰で古い通知が大量に鳴らず、未配送・期限切れを判別できる。Mac が停止中の音声通知は保証しない。
- [ ] 未認証・別利用者・不正なサイズや識別子の入力を拒否し、登録外の配送先に流れない。要約なし設定では内容を保存しない。
- [ ] dispatcher / 依存コマンドの欠如、timeout、中継障害で Grok の作業が失敗しない。`BIRDWATCH_OFF=1` と解除手順が機能する。
- [ ] `BIRDWATCH_STATE_DIR` の共有で dashboard / `ask.sh list` に表示される。Grok 項目から別ソースの tmux pane へ送信されない。
- [ ] Grok のネイティブ承認カード取得・回答送信・承認実行・解決状態同期を、対応済みと表示しない。
- [ ] 既存の `bats test/` と CI lint が成功し、実装方式に応じた追加テストも成功する。
- [ ] macOS の実 Bot で完了と質問をそれぞれ再現し、音・dashboard・inbox を確認する。音声確認を stub テストの成功で代用しない。

計画書のみの変更では `git diff --check`、参照先、既存コードとの整合性を確認する。実装・実接続・音声検証の成功とは区別する。

## 残る判断と対象外

最初に確定する項目は、利用する Grok Bot の版、カスタム MCP を追加できる権限、通知対象 Bot、会話 ID の取得可否、Mac への配送方式。これらを確認するまでインストールコマンドや公式 hook 名を確定しない。

初期対応には、Grok への自動返信、承認カードの操作、全会話の収集、OS 通知の監視、常時の完全な状態同期を含めない。モデル呼び出しを伴う通知ツールは既存の CLI hook と性質が異なるため、遅延と追加利用量を実測し、「モデル呼び出し不要」と表記しない。

## 一次情報

確認日はいずれも 2026-11-19。製品の提供範囲や仕様変更時は工程 1 で再確認する。

- [G1: Use the computer and apps](https://docs.x.ai/grok-bot/computer-and-apps) — クラウド PC、custom MCP と実行場所。
- [G2: Settings and notifications](https://docs.x.ai/grok-bot/settings-and-notifications) — 注意状態、通知、端末別の設定。
- [G3: Skills and routines](https://docs.x.ai/grok-bot/skills-routines-and-automations) — Skill と起動用 webhook。
- [G4: Approvals, security, and privacy](https://docs.x.ai/grok-bot/approvals-security-and-privacy) — 承認とローカル実行。
- [G5: Grok Bot inference hooks](https://docs.x.ai/grok-bot/inference-hooks) — 検査対象、除外範囲、Bot 単位の ID。
