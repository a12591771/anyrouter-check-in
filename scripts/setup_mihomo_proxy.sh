#!/usr/bin/env bash
# 通过 mihomo 拉取订阅、启动本地代理并探测可用节点。
# 环境变量:
#   PROXY_SUBSCRIPTION_URL  订阅链接（必填才启用）
#   PROXY_TEST_URL          探测目标，默认 https://www.google.com/generate_204
#   PROXY_REQUIRED          true 时探测失败则退出 1
#   PROXY_PORT              本地 mixed-port，默认 7890
#   PROXY_DNS_POLICY        可选，节点域名专用解析器，格式 "域名通配=解析器"，
#                           多条用英文逗号分隔。部分机场使用私有 TLD（如 *.qpon），
#                           公共 DNS 无法解析，需要订阅提供的专用解析器。

set -euo pipefail

if [[ -z "${PROXY_SUBSCRIPTION_URL:-}" ]]; then
	echo "[INFO] PROXY_SUBSCRIPTION_URL not set, skip proxy setup"
	exit 0
fi

PROXY_DIR="${RUNNER_TEMP:-/tmp}/checkin-proxy"
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.google.com/generate_204}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.0}"
PROXY_REQUIRED="${PROXY_REQUIRED:-false}"
PROXY_DNS_POLICY="${PROXY_DNS_POLICY:-}"

mkdir -p "${PROXY_DIR}"
cd "${PROXY_DIR}"

echo "[INFO] Downloading mihomo ${MIHOMO_VERSION}..."
ARCHIVE="mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
if ! curl --retry 3 --retry-delay 5 --retry-all-errors -fsSL -o "${ARCHIVE}" \
	"https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${ARCHIVE}"; then
	echo "[WARN] Failed to download mihomo ${MIHOMO_VERSION}, skip proxy setup"
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi
gunzip -f "${ARCHIVE}"
chmod +x "mihomo-linux-amd64-${MIHOMO_VERSION}"
MIHOMO_BIN="${PROXY_DIR}/mihomo-linux-amd64-${MIHOMO_VERSION}"

# mihomo 只读取主配置的 dns 段，不会继承 proxy-providers 订阅内的 dns 配置。
# 若节点域名使用私有 TLD，需在此显式声明专用解析器，否则节点全部解析失败。
DNS_SECTION=""
if [[ -n "${PROXY_DNS_POLICY}" ]]; then
	DNS_SECTION=$(
		printf 'dns:\n'
		printf '  enable: true\n'
		printf '  nameserver:\n'
		printf '    - 223.5.5.5\n'
		printf '    - 8.8.8.8\n'
		printf '  nameserver-policy:\n'
		while IFS= read -r policy; do
			policy="${policy#"${policy%%[![:space:]]*}"}"
			policy="${policy%"${policy##*[![:space:]]}"}"
			[[ -z "${policy}" ]] && continue
			if [[ "${policy}" != *=* ]]; then
				echo "[WARN] Ignored malformed PROXY_DNS_POLICY entry: ${policy}" >&2
				continue
			fi
			printf '    "%s": %s\n' "${policy%%=*}" "${policy#*=}"
		done <<< "${PROXY_DNS_POLICY//,/$'\n'}"
	)
	echo "[INFO] Custom DNS policy enabled for node resolution"
fi

cat > config.yaml <<EOF
mixed-port: ${PROXY_PORT}
allow-lan: false
ipv6: false
mode: rule
log-level: warning
unified-delay: true
${DNS_SECTION}
proxy-providers:
  subscription:
    type: http
    url: "${PROXY_SUBSCRIPTION_URL}"
    interval: 3600
    path: ./subscription.yaml
    health-check:
      enable: true
      interval: 300
      url: https://www.gstatic.com/generate_204

proxy-groups:
  - name: CHECKIN
    type: url-test
    url: "${PROXY_TEST_URL}"
    interval: 300
    tolerance: 150
    lazy: false
    use:
      - subscription

rules:
  - MATCH,CHECKIN
EOF

echo "[INFO] Starting mihomo on 127.0.0.1:${PROXY_PORT}..."
nohup "${MIHOMO_BIN}" -d "${PROXY_DIR}" -f config.yaml > mihomo.log 2>&1 &
echo $! > mihomo.pid

PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
READY=false
for attempt in $(seq 1 45); do
	if curl -fsS -x "${PROXY_URL}" --max-time 20 "${PROXY_TEST_URL}" -o /dev/null 2>/dev/null; then
		READY=true
		break
	fi
	echo "[INFO] Waiting for proxy health check (${attempt}/45)..."
	sleep 2
done

if [[ "${READY}" != "true" ]]; then
	echo "[FAILED] Proxy health check failed for ${PROXY_TEST_URL}"
	tail -n 30 mihomo.log || true
	if [[ -f mihomo.pid ]]; then
		kill "$(cat mihomo.pid)" 2>/dev/null || true
	fi
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi

echo "[SUCCESS] Proxy is ready: ${PROXY_URL}"

# 探测目标可能本身不经过 WAF 校验，健康检查通过并不代表流量真的走了节点。
# 打印直连与代理出口 IP，便于确认节点是否生效。
DIRECT_IP=$(curl -fsS --max-time 15 https://api.ipify.org 2>/dev/null || echo "unknown")
PROXY_IP=$(curl -fsS -x "${PROXY_URL}" --max-time 20 https://api.ipify.org 2>/dev/null || echo "unknown")
echo "[INFO] Direct egress IP: ${DIRECT_IP}"
echo "[INFO] Proxy egress IP: ${PROXY_IP}"
if [[ "${PROXY_IP}" == "unknown" || "${PROXY_IP}" == "${DIRECT_IP}" ]]; then
	echo "[WARN] Proxy egress IP not confirmed; traffic may bypass the proxy"
fi

echo "[INFO] Proxy is scoped to CHECKIN_PROXY_URL (browser/python only, not global HTTP_PROXY)"
if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "CHECKIN_PROXY_URL=${PROXY_URL}" >> "${GITHUB_ENV}"
fi
