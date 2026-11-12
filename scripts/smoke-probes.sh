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
# 容器名按核心规则拼、标签兜底（见 _stirling_container）。
_stirling_container() { # 应用容器：名字按核心规则拼（wonton-<实例>--<slug 的连字符形>--app）；
  # 实例名未导出时（极早调用）按 SMOKE_BASE 的主机名第一段推，名字查不到再按标签兜底。
  local inst="${SMOKE_INSTANCE:-}"
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  if [[ -n "$inst" ]]; then
    local name="wonton-${inst}--com-stirlingtools-stirling-pdf--app"
    docker inspect "$name" >/dev/null 2>&1 && { printf '%s\n' "$name"; return 0; }
  fi
  local args=(--filter label=wonton.plugin=com.stirlingtools.stirling-pdf --filter label=wonton.service=app)
  [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
  docker ps --format '{{.Names}}' "${args[@]}" | head -1
}

data_write() {
  local marker container
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  marker="wonton-smoke-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  container="$(_stirling_container)"
  [[ -n "$container" ]] || { echo "找不到应用容器（wonton.instance 标签）"; return 1; }
  docker exec -u 1000:1000 "$container" sh -c 'printf %s "$1" > "/configs/$2"' sh "$marker" "$marker" ||
    { echo "写不进 /configs（容器 $container）"; return 1; }
  printf '%s' "$marker" >"$SMOKE_STATE"
}

data_check() {
  local marker container out
  marker="$(cat "$SMOKE_STATE")" || { echo "读不到标记文件"; return 1; }
  container="$(_stirling_container)"
  [[ -n "$container" ]] || { echo "找不到应用容器（wonton.instance 标签）"; return 1; }
  out="$(docker exec -u 1000:1000 "$container" sh -c 'cat "/configs/$1" 2>&1' sh "$marker")" ||
    { echo "标记文件读不回来（数据卷丢了？）：$out"; return 1; }
  [[ "$out" == "$marker" ]] || { echo "标记对不上：期待 $marker，看到 $out"; return 1; }
}

# ---------- 邮件（notify）：真发一封带附件的信，核对核心投进私聊（extra_check 附加检查） ----------

# 经核心容器读 Mailpit 收件箱 API（SMTP 25/HTTP 8025 都不发布到宿主）。不用 `docker run --network
# container:<核心>` 起 curl：那样起的容器拿不到 Docker 内嵌 DNS，解析不了 mailpit.wonton.internal。
# 核心镜像没有 curl，请求用 bash 的 /dev/tcp 发；API 要 Basic 认证（core:<密钥>，密钥在核心数据目录）。
# shellcheck disable=SC2153 # SMOKE_CORE、SMOKE_DATA_DIR 由冒烟套件导出
mailpit_messages() {
  local pwd auth
  pwd="$(docker exec "$SMOKE_CORE" cat "$SMOKE_DATA_DIR/core/mailpit/api-password")" ||
    { echo "读不到 Mailpit API 密钥"; return 1; }
  auth="$(printf 'core:%s' "$pwd" | base64 | tr -d '\n')"
  # shellcheck disable=SC2016 # 单引号里是核心容器里 bash 的变量
  docker exec -e MP_AUTH="$auth" "$SMOKE_CORE" bash -c '
    exec 3<>/dev/tcp/mailpit.wonton.internal/8025 || exit 1
    printf "GET /api/v1/messages?limit=50 HTTP/1.0\r\nHost: mailpit.wonton.internal\r\nAuthorization: Basic %s\r\nConnection: close\r\n\r\n" "$MP_AUTH" >&3
    sed "1,/^\r$/d" <&3
  '
}

_ours_in_mailpit() { # <owner 邮箱>：Stirling 发的、留在 Mailpit 里没被核心取走的信
  mailpit_messages | jq -r --arg f "com.stirlingtools.stirling-pdf@plugins.wonton.internal" --arg t "$1" '
    [.messages[] | select((.From.Address == $f) and ([.To[].Address] | index($t)))] | length'
}

_mailpit_summary() { # 失败取证：列出 Mailpit 里的信
  mailpit_messages | jq -r '.messages[]? | "\(.From.Address) → \(.To | map(.Address) | join(","))｜\(.Subject)"' 2>/dev/null | head -5
}

_send_email() { # <收件人> <主题>：经网关调应用的发信接口，输出响应正文和末行的 HTTP 状态码
  web_get /api/v1/general/send-email \
    -F "fileInput=@$1;filename=wonton-smoke.pdf" -F "to=$2" \
    -F "subject=$3" -F "body=wonton smoke attachment" -w '\n%{http_code}' 2>&1
}

extra_check() { # 邮件专项：用应用的「把文件发到邮箱」接口（POST /api/v1/general/send-email，
  # mail.enabled 才注册）给主人的内部邮箱发一封带附件的信，等核心投进主人私聊、Mailpit 里不留；
  # 发给外部地址应用要报失败。
  # 应用自己的登录被关掉（compose 的 init 服务说明），接口经网关用主人会话调（web_get 带 jar）。
  local owner_email pdf out i code wp subject
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_WEB_URL:-}" && -n "${SMOKE_OWNER:-}" ]] ||
    { echo "缺冒烟变量：需要 SMOKE_JAR/SMOKE_WEB_URL/SMOKE_OWNER" >&2; return 1; }
  # 主人的内部邮箱：规范固定 <用户名>@wonton.internal（应用发不了外部地址的信）。
  owner_email="${SMOKE_OWNER}@wonton.internal"
  pdf="$(mktemp "${TMPDIR:-/tmp}/stirling-smoke-XXXXXX.pdf")"
  printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\ntrailer<</Size 2/Root 1 0 R>>\n%%%%EOF\n' >"$pdf"
  # 主题带随机标记，私聊里按它认这一封。发送是 @Async 的、核心亚秒取走信件，Mailpit 中间态
  # 抓不到；等待先挂后台再发，私聊里的消息才是投递的证据。
  subject="Wonton smoke $(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  probes_owner_room_wait 180 "$subject" & wp=$!
  out="$(_send_email "$pdf" "$owner_email" "$subject")" || true
  code="$(tail -1 <<<"$out")"
  if [[ "$code" != 2* ]] || ! grep -qi 'sent successfully' <<<"$out"; then
    kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
    echo "send-email 没受理（$code）：$(head -c 300 <<<"$out")"; rm -f "$pdf"; return 1
  fi
  echo "send-email 受理（$code），收件人 $owner_email"
  if ! wait "$wp"; then
    echo "信 180 秒没投进主人的 Wonton 私聊；Mailpit 里的信："
    _mailpit_summary || true
    echo "核心日志里 mail 相关的行："
    docker logs "$SMOKE_CORE" 2>&1 | grep -iE "mail|smtp|mailbox" | tail -8 || true
    rm -f "$pdf"; return 1
  fi
  for i in {1..12}; do
    out="$(_ours_in_mailpit "$owner_email")" || { echo "读不了 Mailpit：$out"; rm -f "$pdf"; return 1; }
    [[ "$out" == 0 ]] && break
    [[ "$i" == 12 ]] && { echo "信投进了私聊，但 Mailpit 里还有滞留（核心没删？）"; rm -f "$pdf"; return 1; }
    sleep 5
  done
  echo "信已投进主人的 Wonton 私聊，Mailpit 没有滞留"

  # 外部收件人：核心在 SMTP 阶段 550 拒收，应用报 500 带失败原因
  out="$(_send_email "$pdf" "wonton-smoke-external@example.com" "Wonton smoke external")" || true
  rm -f "$pdf"
  code="$(tail -1 <<<"$out")"
  [[ "$code" == 2* ]] && { echo "发往外部地址竟然成功（$code）：$(head -c 300 <<<"$out")"; return 1; }
  grep -q '550' <<<"$out" || { echo "外部收件人的失败不是 550 拒收（$code）：$(head -c 300 <<<"$out")"; return 1; }
  echo "外部地址应用报失败（$code），核心 550 拒收"
}
