# shellcheck shell=bash disable=SC2034
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 装之前要准备（如先配出口代理）：写 before_install。

# 保数据：应用登录被 custom_settings.yml 关掉（见 compose 的 init 服务说明），游客身份没有可写的
# 用户数据——保存到服务器等入口只对登录用户开放，处理的文件也是临时的（about 已如实写明）。
# 没有可写的用户数据，钩子改为核对数据卷里的标记文件（见文末）。

web_assert() { grep -qi 'stirling'; }   # stdin：应用真实页面（SPA 首页，标题带 Stirling）

# 身份：应用登录被 custom_settings.yml 关掉（compose 的 init 服务说明），security profile 恒开、
# 应用 API 对匿名请求一律 401（实测 3.3.0）——应用侧没有可断言的用户身份；主人能打开由 web_assert
# 和网关对匿名请求的 401 证明。
export IDENTITY_NA=1
export SMOKE_NOTE="应用登录被 custom_settings.yml 关掉、应用 API 匿名一律 401，应用侧没有可断言的用户身份；主人会话能打开应用、网关拒绝匿名请求由网页项证明。"

# 保数据：应用登录被 custom_settings.yml 关掉（见 compose 的 init 服务说明），登录接口虽能发令牌，
# 但登录关闭时请求仍是匿名的（实测 3.3.0：Bearer 和会话 Cookie 访问都回 401），应用 API 写不了用户数据。
# 数据卷 `/configs` 里是用户库（H2）、设置和 custom_settings.yml，升级把它弄丢等于把插件设置改回去；
# 这里以应用用户（1000）在 /configs 写一个带随机标记的文件，升级/重装后读回核对。
# 容器按核心打的标签找，不拼名字：data_write 在装旧 tag 的阶段跑，那时主流程还没导出 SMOKE_INSTANCE。
_stirling_container() {
  local inst="${SMOKE_INSTANCE:-}" args=(--filter label=wonton.plugin=com.stirlingtools.stirling-pdf --filter label=wonton.service=app)
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
  docker ps --format '{{.Names}}' "${args[@]}" | head -1
}

marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/stirling-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

data_write() {
  local marker container
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  marker="wonton-smoke-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  container="$(_stirling_container)"
  [[ -n "$container" ]] || { echo "找不到应用容器（wonton.instance 标签）"; return 1; }
  docker exec -u 1000:1000 "$container" sh -c 'printf %s "$1" > "/configs/$2"' sh "$marker" "$marker" ||
    { echo "写不进 /configs（容器 $container）"; return 1; }
  printf '%s' "$marker" >"$(marker_file)"
}

data_check() {
  local marker container out
  marker="$(cat "$(marker_file)")" || { echo "读不到标记文件"; return 1; }
  container="$(_stirling_container)"
  [[ -n "$container" ]] || { echo "找不到应用容器（wonton.instance 标签）"; return 1; }
  out="$(docker exec -u 1000:1000 "$container" sh -c 'cat "/configs/$1" 2>&1' sh "$marker")" ||
    { echo "标记文件读不回来（数据卷丢了？）：$out"; return 1; }
  [[ "$out" == "$marker" ]] || { echo "标记对不上：期待 $marker，看到 $out"; return 1; }
}

# ---------- 邮件（notify）：真发一封带附件的信，核对核心投进私聊（extra_check 由 e2e 冒烟跑） ----------

core_container() { # 核心容器：和插件容器同一个 compose 项目（Mailpit 只在核心的私有网络里）
  local project
  project="$(docker inspect "$(_stirling_container)" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)"
  [[ -n "$project" ]] || { echo "读不到插件容器的 compose 项目"; return 1; }
  docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$project" |
    grep -E -- '--core$' | head -1
}

mailpit_messages() { # 经核心的网络栈读 Mailpit 收件箱 API（SMTP 25/HTTP 8025 都不发布到宿主）。
  # API 要 Basic 认证（core:<密钥>，密钥在核心数据目录，核心的 mailbox 组件生成）。
  local pwd
  pwd="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/mailpit/api-password"')" ||
    { echo "读不到 Mailpit API 密钥"; return 1; }
  docker run --rm --network "container:$(core_container)" curlimages/curl:8.23.0 --noproxy '*' -s \
    -u "core:$pwd" "http://mailpit.wonton.internal:8025/api/v1/messages?limit=50"
}

_ours_in_mailpit() { # <owner 邮箱>：Stirling 发的、还没被核心取走的信
  mailpit_messages | jq -r --arg f "com.stirlingtools.stirling-pdf@plugins.wonton.internal" --arg t "$1" '
    [.messages[] | select((.From.Address == $f) and ([.To[].Address] | index($t)))] | length'
}

wonton_chat_events() { # <条数>：核心投递事件的房间最近消息。核心实测亚秒取走信件（投完即删），
  # 在 Mailpit 里几乎抓不到中间态，投进主人 Wonton 私聊的房间事件才是权威证据。
  local mu room adm
  mu="$(docker exec "$(core_container)" printenv WONTON_MATRIX_URL)"
  room="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-notice-room"')" ||
    { echo "读不到通知房间 id"; return 1; }
  adm="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-admin-token"')" ||
    { echo "读不到 Matrix 管理令牌"; return 1; }
  docker run --rm --network "container:$(core_container)" curlimages/curl:8.23.0 --noproxy '*' -s \
    -H "Authorization: Bearer $adm" "$mu/_matrix/client/v3/rooms/$room/messages?limit=$1&dir=b"
}

_delivered_after() { # <插件 id> <发送时刻毫秒>：发送之后投进主人 Wonton 私聊的新邮件事件数
  wonton_chat_events 30 | jq -r --arg p "$1" --argjson ts "$2" '
    [.chunk[] | select(.origin_server_ts > $ts and .content["app.wonton.plugin_mail"].plugin_id == $p)] | length'
}

extra_check() { # 邮件专项：用应用的「把文件发到邮箱」接口（POST /api/v1/general/send-email，
  # mail.enabled 才注册）给主人的内部邮箱发一封带附件的信，等它进 Mailpit、再等核心投进私聊后
  # 取走；发给外部地址应用要报失败。
  # 应用自己的登录被关掉（compose 的 init 服务说明），接口经网关用主人会话调（web_get 带 jar）。
  local owner_email pdf out seen i code sent_at
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_WEB_URL:-}" && -n "${SMOKE_OWNER:-}" ]] ||
    { echo "缺冒烟变量：需要 SMOKE_JAR/SMOKE_WEB_URL/SMOKE_OWNER" >&2; return 1; }
  # 主人的内部邮箱：规范固定 <用户名>@wonton.internal（冒烟工具按形状拼；应用发不了外部地址的信）。
  # 应用自己的登录被关掉（compose 的 init 服务说明），接口经网关用主人会话调。附加检查跑在
  # 主流程 web_login 之前，jar 是冷的：先自己走一遍核心令牌登录 + 应用网页跳转把会话建起来。
  curl -sS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    --data-urlencode "token=$SMOKE_TOKEN" "$SMOKE_BASE/_wonton/login" ||
    { echo "主人令牌登录不了核心"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' "$SMOKE_WEB_URL/" || { echo "走不通网关到应用的会话"; return 1; }
  owner_email="$SMOKE_OWNER@wonton.internal"
  pdf="$(mktemp /tmp/stirling-smoke-XXXXXX.pdf)"
  printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\ntrailer<</Size 2/Root 1 0 R>>\n%%%%EOF\n' >"$pdf"
  # 发送是 @Async 的；核心亚秒取走信件，Mailpit 中间态抓不到——记发送时刻，直接等主人
  # 私聊里的投递事件（主题是探针定的「Wonton smoke」）。
  sent_at="$(date +%s%3N)"
  out="$(web_get /api/v1/general/send-email \
    -F "fileInput=@$pdf;filename=wonton-smoke.pdf" -F "to=$owner_email" \
    -F "subject=Wonton smoke" -F "body=wonton smoke attachment" -w '\n%{http_code}')" ||
    { echo "send-email 请求失败：$out"; return 1; }
  code="$(tail -1 <<<"$out")"
  [[ "$code" == 2* ]] || { echo "send-email 没受理（$code）：$(head -c 300 <<<"$out")"; return 1; }
  grep -qi 'sent successfully' <<<"$out" || { echo "应用没报发送成功：$(head -c 300 <<<"$out")"; return 1; }
  echo "send-email 受理（$code），收件人 $owner_email"
  seen=0
  for i in {1..60}; do
    sleep 5
    out="$(_delivered_after com.stirlingtools.stirling-pdf "$sent_at")" || { echo "$out"; return 1; }
    if [[ "$out" != 0 ]]; then seen=1; break; fi
  done
  [[ "$seen" == 1 ]] || { echo "等了 5 分钟没看到信投进主人的 Wonton 私聊（异步发送没走到 SMTP？）"; return 1; }
  for i in {1..12}; do
    sleep 5
    out="$(_ours_in_mailpit "$owner_email")" || { echo "$out"; return 1; }
    [[ "$out" == 0 ]] && break
    [[ "$i" == 12 ]] && { echo "信投进了私聊，但 Mailpit 里还有滞留（核心没删？）"; return 1; }
  done
  echo "信已投进主人的 Wonton 私聊，Mailpit 没有滞留"

  # 外部收件人：核心在 SMTP 阶段 550 拒收，应用报 500 带失败原因
  out="$(web_get /api/v1/general/send-email \
    -F "fileInput=@$pdf;filename=wonton-smoke.pdf" -F "to=wonton-smoke-external@example.com" \
    -F "subject=Wonton smoke external" -F "body=wonton smoke external" -w '\n%{http_code}' 2>&1)" || true
  code="$(tail -1 <<<"$out")"
  [[ "$code" == 2* ]] && { echo "发往外部地址竟然成功（$code）：$(head -c 300 <<<"$out")"; return 1; }
  grep -q '550' <<<"$out" || { echo "外部收件人的失败不是 550 拒收（$code）：$(head -c 300 <<<"$out")"; return 1; }
  echo "外部地址应用报失败（$code），核心 550 拒收"
  rm -f "$pdf"
}
