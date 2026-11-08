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
