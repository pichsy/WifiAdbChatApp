# 移动端协议参考对端与联调工具（mobile/tests）

本目录是「文件互传助手」移动端（Android / iOS）的**协议 QA 工具**：用纯 Python 3 实现一个
「电脑端」参考对端，并配两套自动化测试，用来在没有真机、没有 App 的情况下先把
`docs/LAN-transfer-spec.md` 的契约跑通，再拿去和 Android / iOS App 做联调。

- 协议唯一契约：`docs/LAN-transfer-spec.md`
- 移动端共同约定：`mobile/BRIEF.md`
- 参考行为（macOS）：`macos/Sources/LANTransfer.swift`
- 本目录只写 `mobile/tests/`，不改 App 源码、文档、发布文件，不 commit / push。

## 文件

| 文件 | 作用 |
| --- | --- |
| `reference_peer.py` | 协议库 + CLI：UDP 52730 发现/广播、TCP 随机端口接收、4 字节大端长度 + UTF-8 JSON 帧、hello/hello_ok/pair_required/error/text/file/ok/bye、6 位配对码、文件 256 KiB 收发、重名编号、状态持久化；子命令 serve / discover / pair / send-text / send-file / info |
| `run_reference_peer.py` | 交互式「电脑端模拟器」：常驻发现 + 接收，支持 REPL 命令和 `--script` 脚本模式，可列出设备、配对、发送文字/文件、查看已收内容 |
| `test_protocol.py` | 78 条协议级用例：用原始 socket 逐字节验证帧、握手、配对、文字、文件、发现（不依赖 App） |
| `test_interop.py` | 14 条端到端用例：两台参考对端互发、真实 CLI 子进程、包装器脚本模式（含中文与文件字节一致） |
| `run_tests.sh` | 一键跑上面两组测试 |
| `.gitignore` | 忽略 `.state/`、`received/`、`__pycache__/` 等运行时产物 |

## 环境要求

- Python 3.8+（本机验证用 3.11.7），**只用标准库**，不需要 pip 安装任何东西。
- 能绑定 UDP 52730、能发 UDP 广播；macOS 需要在「系统设置 → 隐私与安全性 → 本地网络」
  允许终端 / Python（首次运行可能弹窗）。
- 联调手机时，电脑与手机必须在同一 Wi-Fi / 局域网，且 AP 未开启客户端隔离。

## 快速自测（不依赖 App）

~~~bash
cd mobile/tests
./run_tests.sh
# 也可以只跑一组：
python3 -m unittest -v test_protocol.py
python3 -m unittest -v test_interop.py
~~~

自测记录（2026-11-04，macOS 26.5.1 arm64 / Python 3.11.7）：

- `test_protocol.py`：78 个用例全部 OK（约 16 秒）
- `test_interop.py`：14 个用例全部 OK（约 15～17 秒）
- 连续跑两轮 `./run_tests.sh` 均输出 `ALL TESTS PASSED`

## 模拟电脑端（手机 App 联调）

### 1. 被手机发现 / 接收手机发来的内容

~~~bash
cd mobile/tests
python3 reference_peer.py serve --name "QA 电脑" --code 123456
~~~

启动后打印：

~~~
READY device=<设备ID> name="QA 电脑" code=123456 tcp=54321 receive=".../received" state=".../.state/..."
HINT 让手机端发现「QA 电脑」，首次发送时输入配对码 123456
~~~

手机端操作：在 App 的「附近设备」里应看到「QA 电脑」→ 首次发送输入配对码 `123456` →
发送文字 / 文件。电脑端会打印事件行（JSON）：

~~~
EVENT {"event":"peer_online","new":true,"id":"...","name":"iPhone","host":"192.168.1.23","port":54322,...}
EVENT {"event":"pair_request","id":"...","name":"iPhone"}
EVENT {"event":"pair_ok","id":"...","name":"iPhone"}
EVENT {"event":"text","peerId":"...","peerName":"iPhone","text":"你好 👋"}
EVENT {"event":"file","peerId":"...","peerName":"iPhone","originalName":"照片.jpg","savedName":"照片.jpg","savedPath":".../received/照片.jpg","size":123456,"sha256":"..."}
~~~

- 接收目录默认 `mobile/tests/received`，可用 `--receive-dir` 改；重名自动编号 ` (2)`。
- 事件里的 `sha256` 可直接和手机端发送的原始文件比对。
- `Ctrl-C` 退出；`--seconds N` 可限时运行（便于脚本）。

### 2. 发现手机、主动配对并发送文字 / 文件

~~~bash
# 列出局域网设备（含手机 App 通告的 IP 与 TCP 端口）
python3 reference_peer.py discover --seconds 5

# 按发现到的设备名/ID 自动解析 IP:端口
python3 reference_peer.py pair      --peer "iPhone 17" --code 654321
python3 reference_peer.py send-text --peer "iPhone 17" --code 654321 --text "你好，手机端 👋 中文 emoji 😀"
python3 reference_peer.py send-file --peer "iPhone 17" --code 654321 --file ./测试文件.bin

# 也可以显式直连（发现被 AP 过滤时）
python3 reference_peer.py send-text --host 192.168.1.23 --port 54322 --code 654321 --text "直连测试"
~~~

- `--code` 是**对方屏幕上显示的 6 位配对码**；已配对成功后后续发送可以不再带 `--code`。
- 退出码：`0` 成功；`1` 失败；`2` 参数错误；`3` 需要配对（收到 `pair_required`）。
- 成功时打印 `RESULT kind=ok message="..."`；配对码错时打印 `RESULT kind=need_pair ...` 且退出码 3。

### 3. 交互式包装器（更像「电脑端 App」）

~~~bash
python3 run_reference_peer.py --name "QA 电脑"
~~~

REPL 命令（也支持从 stdin 管道输入）：

| 命令 | 说明 |
| --- | --- |
| `help` | 命令帮助 |
| `list` / `devices` | 列出发现的设备（带编号） |
| `code` | 打印本机 6 位配对码 |
| `info` / `status` | 本机身份、端口、已配对数量、收发统计 |
| `wait <秒>` | 等待（期间事件照常打印） |
| `wait-peer <名字|ID> [超时]` | 等某台设备出现 |
| `pair <名字|ID|编号> <配对码>` | 主动配对（不发内容） |
| `send-text <名字|ID|编号> <文字>` | 发送文字（需已配对） |
| `send-file <名字|ID|编号> <路径>` | 发送文件（需已配对） |
| `received [条数]` | 打印已收到的文字 / 文件 |
| `quit` / `exit` | 退出 |

脚本模式（自动化用；每行一条命令，空行和 `#` 开头为注释）：

~~~text
# /tmp/reference-script.txt
help
wait-peer "iPhone 17" 20
pair "iPhone 17" 654321
send-text "iPhone 17" 电脑端发来的文字 😀
send-file "iPhone 17" /tmp/测试.bin
list
received
quit
~~~

~~~bash
python3 run_reference_peer.py --name "QA 电脑" --script /tmp/reference-script.txt --seconds 60
~~~

脚本出错默认继续（打印 `ERROR`），`--fail-fast` 可改为立即退出；有错误时进程退出码为 1。

### 4. 身份与状态

- 设备 ID、已配对 ID 存在 `mobile/tests/.state/<name>-<hash>.json`（首次启动自动生成并持久化，
  重启不变，模拟 macOS 端的 `lanDeviceID` / `paired.json`）。
- 接收文件在 `mobile/tests/received`，默认已被 `.gitignore` 忽略。
- `python3 reference_peer.py info` 查看当前身份、已配对数量与默认路径。

## 与手机 App 联调步骤（阶段二）

### A. 手机发现电脑并发送（手机作为发送方）

1. 电脑运行 `python3 reference_peer.py serve --name "QA 电脑" --code 123456`，
   看到 `READY ... code=123456`。
2. 手机 App 打开，附近设备中出现「QA 电脑」；进入聊天，首次发送时输入 `123456`。
3. 发送中文 / emoji 文字和至少 1 个文件（覆盖 0 字节、256 KiB 以上、中文文件名更佳）。
4. 电脑端日志应依次出现 `pair_request`（首次）→ `pair_ok` → `text` → `file`；
   文件 `sha256` 与手机端原始文件一致，接收目录出现文件。
5. 再次发送应不再需要配对码（电脑端已记住手机设备 ID）。

### B. 电脑发现手机并发送（手机作为接收方）

1. 手机 App 保持前台，记下屏幕上显示的 6 位配对码。
2. 电脑运行 `python3 reference_peer.py discover --seconds 5`，确认能看到手机的名称、IP、
   TCP 端口（端口来自 UDP 通告，是 App 的随机监听端口）。
3. 发送文字：
   `python3 reference_peer.py send-text --peer "<手机名>" --code <手机配对码> --text "你好 👋"`
4. 发送文件：
   `python3 reference_peer.py send-file --peer "<手机名>" --code <手机配对码> --file ./测试.bin`
5. 手机端应立即出现消息 / 文件卡片；文件可打开且大小正确。
6. 电脑端打印 `RESULT kind=ok`；再次发送可省略 `--code`。
7. 若发现不到（AP 过滤广播），用 `--host <手机IP> --port <TCP端口>` 直连；
   IP/端口可从手机 App 侧或路由器后台查看。

### C. 双向文件字节一致

~~~bash
shasum -a 256 ./测试.bin
shasum -a 256 mobile/tests/received/测试.bin
# 或直接对比 reference_peer.py 事件里的 sha256
~~~

### D. 重启后配对保持

- 参考对端：重启 `serve`（不同 `--name` 有独立状态；同一 `--name` 复用设备 ID / 配对集合），
  手机再次发送应免配对码。
- 手机 App：杀掉进程后重启，检查设备 ID、配对关系、聊天记录是否恢复（需在 App 侧验证）。

## 协议检查表

状态说明：✅ 已由本目录自动化验证；🟡 参考实现已覆盖但需手机 App / 真机复测；
⚪ 需要人工或环境条件（模拟器 / 真机 / 网络设备）才能验证。

| # | 检查项（spec 章节） | 验证方式 | 状态 |
| --- | --- | --- | --- |
| 1 | 发现报文 app/v/id/name/port，app=ADBTypeLink、v=1（§2.1） | `test_protocol.TestDiscovery.test_announcement_payload_matches_spec` | ✅ |
| 2 | UDP 52730 广播 + 127.0.0.1 回环，两台设备互相发现（§2.1） | `test_interop.TestPeerDiscovery.test_two_peers_discover_each_other_on_default_port` | ✅ |
| 3 | 52730 可被多个进程同时绑定（SO_REUSEADDR+SO_REUSEPORT）（§2.2） | 自测时本机同时有 macOS App 与 iOS 模拟器 App 绑定 52730，参考对端可共存并收到其广播 | ✅（本机环境） |
| 4 | 非法通告静默丢弃（app/id/name/port 校验、忽略自己）（§2.2） | `test_invalid_announcements_ignored`、`test_own_id_ignored` | ✅ |
| 5 | peer 的 host 取 UDP 来源 IP，而非 payload 字段（§2.2） | `test_source_ip_is_used_not_payload_host` | ✅ |
| 6 | 8 秒无心跳移除；默认值与清理机制（§2.2） | `TestConstants.test_default_offline_after_is_8_seconds` + `test_peer_pruned_after_offline_timeout`（缩短时值验证） | ✅ |
| 7 | TCP 帧：4 字节大端长度 + UTF-8 JSON（§3） | `TestFrameHelpers.test_frame_roundtrip_with_unicode`、`TestHandshake.test_pair_required_when_no_code`（自证长度与正文一致） | ✅ |
| 8 | 单帧上限 16 MiB，超限断开（§3） | `TestFrameHelpers.test_oversized_length_is_rejected`、`test_oversized_frame_header_closes` | ✅ |
| 9 | 长度/正文循环读满，不假设一次 recv（§3） | `test_split_frame_is_read_completely`、`test_split_hello_bytes_still_handshakes`、`test_file_written_in_small_chunks` | ✅ |
| 10 | hello 校验 app / id 非空且非本机 / name 非空（§4.3） | `TestHandshake` 中 7 个非法 hello 用例 | ✅ |
| 11 | 配对码 6 位、去首尾空白、错误回 pair_required（§4.3） | `test_pair_required_when_no_code`、`test_code_whitespace_is_trimmed`、`test_code_with_inner_space_rejected` | ✅ |
| 12 | 已配对 ID 直接 hello_ok；配对状态持久化（§4.3 / §8） | `test_already_paired_second_connection_needs_no_code`、`TestPairingPersistence.test_pairing_persists_across_restart` | ✅ |
| 13 | hello_ok 带 name/id；pair_required 带 name（§4.3） | `test_pair_ok_with_correct_code`、`test_pair_required_name_uses_server_name` | ✅ |
| 14 | 发送方处理 hello_ok / pair_required / error / 超时（§4.4） | `TestClientProtocol` 5 个假 server 用例 + `test_client_pair_only_wrong_then_right_code` | ✅ |
| 15 | 文字原样收发（中文 / emoji / 多行 / 大帧）（§5） | `TestText.test_chinese_emoji_text_roundtrip`、`test_multiline_text_roundtrip`、`test_large_text_frame` | ✅ |
| 16 | 空文字不建连接（§5） | `test_client_rejects_empty_text_locally`、`test_empty_text_and_zero_byte_file_do_not_connect` | ✅ |
| 17 | file 头 + size 字节原始数据、256 KiB 分块（§6） | `test_file_roundtrip_sha256`、`test_client_streams_exact_file_bytes_and_sends_bye` | ✅ |
| 18 | 接收方接受 size ≥ 0（0 字节文件合法）（§5 / §6） | `test_zero_byte_file_accepted` | ✅ |
| 19 | 发送方要求文件 size > 0，否则「读不到文件」（§5） | `test_client_rejects_zero_byte_file`、`test_client_rejects_missing_file` | ✅ |
| 20 | 文件名只取最后一段，拒绝空名 / `.` / `..`（§6） | `test_path_is_reduced_to_last_component`、`test_invalid_names_get_error`、`TestHelpers.test_sanitize_file_name` | ✅ |
| 21 | 重名 ` (2)`、` (3)` 编号（含点文件 / 多扩展名）（§6） | `test_duplicate_names_numbered`、`test_dotfile_duplicate_numbering`、`test_multi_extension_duplicate_numbering` | ✅ |
| 22 | 接收中断删半截文件、回 error「保存文件失败」（§6） | `test_truncated_file_cleans_partial`、`test_invalid_names_get_error` | ✅ |
| 23 | ok / bye 时序：收到内容回 ok，发送方收到 ok 发 bye 后关闭（§4.1 / §5） | 各 raw 用例 + `test_client_sends_bye_after_text_ack` | ✅ |
| 24 | 未知 type / 无法解析时直接关闭（§5） | `test_unknown_type_closes_connection`、`test_text_without_text_field_closes`、`test_text_with_non_string_text_closes` | ✅ |
| 25 | 每个发送动作新建一条 TCP（多文件逐个连接）（§1 / §6） | `test_multiple_files_use_separate_connections` | ✅ |
| 26 | 连接超时 6 秒、读写超时 30 秒（§7） | 常量断言：`TestConstants.test_frame_and_chunk_limits`；连接拒绝路径 `test_client_connect_failure_message` | 🟡 真实超时需断网/对端卡死复测 |
| 27 | 端口 52730 被占用时提示（§7） | 实现会抛「端口 52730 被占用…」；未自动化模拟独占绑定（REUSEPORT 下很难制造） | ⚪ 手工项 |
| 28 | 8 秒离线 / 单播心跳（macOS 增强，非强制）（§2.2） | 广播与超时机制已验证；`--unicast-to` 可手工验证单播心跳 | 🟡 |
| 29 | Android / iOS App 的发现、配对、文字、文件、持久化、错误提示 | 见下节「阶段二联调记录」 | ⚪ 待 App 就绪 |

## 已知限制与注意事项

- 参考对端只实现**电脑端协议行为**，不含 UI、聊天记录、进度条、取消发送、别名等 macOS 增强。
- 本目录测试会在 52730 上绑定/广播；运行期间局域网内的其他设备可能短暂看到
  「参考接收端」等临时设备，测试结束即停止。测试不会向真实 App 发送数据，只按名字/ID 过滤。
- 自测环境里同一台 Mac 还运行着 macOS 版 App 和 iOS 模拟器版 App，它们也绑定 52730 并广播；
  参考对端能收到它们的通告（日志里出现过 `HEQIANQIAN`、`pichs` 等设备），
  因端口使用 REUSEPORT，互不影响。
- 同一台机器多实例时，发往 127.0.0.1 的 UDP 单播只投递给其中一个 socket（spec §2.1 注），
  因此**跨实例发现主要依赖 255.255.255.255 广播**；测试里用「隔离端口 + 单播注入」做确定性校验。
- Windows：SO_REUSEPORT 可能不可用，需要按 spec 用 SO_REUSEADDR；本工具在该平台未做实测。
- 接收目录默认 `mobile/tests/received/`，不是 macOS App 的 `~/Downloads/ADBType 接收`。
- 不涉及加密 / 认证，协议本身是局域网明文（与现有一致）。
- 模拟器限制（Android emulator 的 NAT/广播、iOS 模拟器本地网络权限）需在阶段二按实机情况记录。

## 故障排查

**「端口 52730 被占用，无法启动局域网发现」**
- `lsof -nP -iUDP:52730` 查看占用进程；正常情况 macOS App / 手机 App / 本工具可以共存
  （都设置 SO_REUSEPORT）。若被其它程序独占，关闭它，或换一台机器跑参考对端。
- TCP 端口是随机分配的，不需要固定；手机端使用的 TCP 端口以 UDP 通告为准。

**手机 App 发现不到「QA 电脑」**
- macOS：系统设置 → 隐私与安全性 → 本地网络，允许终端（iTerm / Terminal）或 Python；
  防火墙放行 Python；App 需要允许「本地网络」。
- 确认两端在同一 Wi-Fi / 网段；Wi-Fi AP 的客户端隔离（AP isolation / 访客网络）会拦 UDP 广播，
  换手机热点或直连路由试试。
- Windows / 手机热点环境广播常被过滤：直接用 `--host/--port` 绕过发现。
- `python3 reference_peer.py discover --seconds 5` 确认自己能看到通告（至少能看到其它实例）。

**一直弹配对 / `pair_required`**
- 核对 6 位码（去首尾空白；`123 456` 不等于 `123456`）。
- 手机端的码可能在重启 / 点「换一个」后变化，以对方屏幕当前显示为准。
- 配对成功后双方都会记住设备 ID（参考对端存在 `.state/*.json`）；清掉对应 state 可重置。
- 确认连的是目标设备（名字可能相近，可用 `discover` 看 id / host / port）。

**文件大小或字节不一致**
- 用 `sha256` 比对：事件行里的 `sha256`、`shasum -a 256` 原始文件、接收文件三者应一致。
- 检查磁盘空间；接收中断时按 spec 应删除半截文件并回 `error「保存文件失败」`。
- 发送方要求文件 size > 0；0 字节只能作为接收方合法输入。

**中文 / emoji 乱码**
- 协议要求 UTF-8 JSON；本工具与测试均使用 UTF-8。检查终端 locale（`LANG` 为 UTF-8 更稳妥）。
- 文件名在 macOS / Windows 上的非法字符不同，重名编号规则应保持一致。

**测试偶发失败 / 卡住**
- 所有 socket 操作都有 5 秒左右的测试超时；若相关用例卡在 30 秒级别，通常是防火墙静默丢包。
- 多次运行后仍有旧进程：`pkill -f reference_peer.py`、`pkill -f run_reference_peer.py`。
- 用例使用临时目录，不会污染仓库；`.state/` `received/` 只有手工 CLI 才会写。

## 阶段二参考对端联调记录（内部，非最终验收）

开发期的参考对端互操作观察（Python 参考对端 ↔ Android 真机 / iOS 模拟器）记录在
[«PHASE2-OBSERVATIONS.md»](PHASE2-OBSERVATIONS.md)：已覆盖发现、6 位码配对、中文/emoji 文字、
Python→Android/iOS 文件字节一致、Android 侧收文件落盘；iOS→对端与 Android→对端正文部分受限，
原因与模拟器限制一并记录。

> 按 Lead 要求，**最终验收使用真实 Mac（pichs）、真实 Windows（HEQIANQIAN）与手机 App 完成**，
> 参考对端结果只作为开发期内部回归，不写进最终验收结论。
