cat > deploy_vnstat_panel.sh << 'EOF'
#!/usr/bin/env bash
set -e

echo
echo "===== vnStat + vnstati + 系统资源监控面板 一键部署 ====="
echo

##################################
# （1）交互输入
##################################

# 域名
DOMAIN=""
while [ -z "$DOMAIN" ]; do
  read -rp "请输入域名（例如 www.china.com）: " DOMAIN
done

# 证书路径
read -rp "请输入 SSL 证书路径 [默认 /root/cert.crt]: " CERT
CERT=${CERT:-/root/cert.crt}

read -rp "请输入 SSL 私钥路径 [默认 /root/private.key]: " PRIV
PRIV=${PRIV:-/root/private.key}

if [ ! -f "$CERT" ] || [ ! -f "$PRIV" ]; then
  echo "❌ 找不到证书或私钥文件，请检查路径："
  echo "  CERT=$CERT"
  echo "  PRIV=$PRIV"
  exit 1
fi

# BasicAuth 用户名 / 密码
read -rp "请输入后台用户名 [默认 admin]: " AUTH_USER
AUTH_USER=${AUTH_USER:-admin}

read -s -rp "请输入后台密码（留空则自动生成随机密码）: " AUTH_PASS
echo
if [ -z "$AUTH_PASS" ]; then
  AUTH_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
  PASS_MODE="已自动生成随机密码"
else
  PASS_MODE="使用你输入的密码"
fi

# 账单重置日（1-28）
RESET_DAY=""
while [ -z "$RESET_DAY" ]; do
  read -rp "请输入每月重置统计的日期（1-28，默认 9）: " RESET_DAY
  RESET_DAY=${RESET_DAY:-9}
  if ! echo "$RESET_DAY" | grep -Eq '^[0-9]+$'; then
    echo "❌ 请输入 1-28 的数字。"
    RESET_DAY=""
    continue
  fi
  if [ "$RESET_DAY" -lt 1 ] || [ "$RESET_DAY" -gt 28 ]; then
    echo "❌ 为避免 30/31 和 2 月问题，请使用 1-28 之间的日期。"
    RESET_DAY=""
    continue
  fi
done

# 自动检测网卡
AUTO_IFACE="$(ls /sys/class/net 2>/dev/null | grep -Ev '^(lo|docker.*|veth.*|br-.*|virbr.*)$' | head -n1 || true)"
[ -z "$AUTO_IFACE" ] && AUTO_IFACE="eth0"

echo
echo "自动检测到的网卡为：${AUTO_IFACE}"
read -rp "如需自定义网卡，请输入网卡名（直接回车使用自动检测值）: " IFACE_INPUT
IFACE="${IFACE_INPUT:-$AUTO_IFACE}"

echo
echo "===== 部署配置如下 ====="
echo "域名:          $DOMAIN"
echo "证书:          $CERT"
echo "私钥:          $PRIV"
echo "BasicAuth 用户: $AUTH_USER"
echo "密码模式:      $PASS_MODE"
echo "监控网卡:      $IFACE"
echo "每月重置日:    每月 ${RESET_DAY} 号 00:05 执行"
echo

##################################
# （2）安装依赖 & 写配置
##################################
apt update
DEBIAN_FRONTEND=noninteractive apt install -y nginx apache2-utils vnstat vnstati lsb-release

# 保存配置供子脚本读取
cat > /etc/vnstat-panel.conf <<EOF_CFG
IFACE="$IFACE"
RESET_DAY="$RESET_DAY"
EOF_CFG

# 启用 vnstat
systemctl enable --now vnstat
vnstat --add -i "$IFACE" >/dev/null 2>&1 || true
systemctl restart vnstat

mkdir -p /var/www/html
chown -R www-data:www-data /var/www/html

##################################
# （3）index.html（无侧边栏版本 + 2 列卡片）
##################################
cat > /var/www/html/index.html << EOF_HTML
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<title>流量监控面板</title>
<meta name="viewport" content="width=device-width,initial-scale=1" />
<style>
  :root{
    --bg:#f4f5f7;
    --bg-elevated:#ffffff;
    --text:#111827;
    --muted:#6b7280;
    --border:#e5e7eb;
    --accent:#0ea5e9;
    --shadow:0 12px 30px rgba(15,23,42,.08);
  }
  @media (prefers-color-scheme: dark){
    :root{
      --bg:#020617;
      --bg-elevated:#0f172a;
      --text:#e5e7eb;
      --muted:#9ca3af;
      --border:#1e293b;
      --shadow:0 18px 40px rgba(0,0,0,.6);
    }
  }

  body{
    margin:0;
    font-family:-apple-system,system-ui,BlinkMacSystemFont,"SF Pro Text",Segoe UI,
      Roboto,Helvetica,Arial,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
    background:var(--bg);
    color:var(--text);
    padding:0;
  }

  .container{
    max-width:1100px;
    margin:0 auto;
    padding:24px 16px;
  }

  h1{
    margin:4px 0 12px;
    font-size:26px;
    font-weight:600;
  }
  .subtitle{
    margin:0 0 24px;
    font-size:14px;
    color:var(--muted);
  }

  .section-title{
    display:flex;
    align-items:flex-end;
    justify-content:space-between;
    gap:8px;
  }
  .section-title h2{
    font-size:20px;
    margin:0;
  }
  .section-sub{
    font-size:12px;
    color:var(--muted);
  }

  .card{
    background:var(--bg-elevated);
    border-radius:18px;
    border:1px solid var(--border);
    padding:18px 16px;
    margin-top:14px;
    box-shadow:var(--shadow);
  }

  /* 系统资源内部 2 列布局 */
  .sys-grid{
    display:grid;
    grid-template-columns:repeat(2,minmax(0,1fr));
    gap:18px;
    font-size:14px;
  }
  .sys-item-title{
    font-weight:600;
    margin-bottom:4px;
  }
  .sys-meta{
    font-size:12px;
    color:var(--muted);
    margin-top:6px;
  }

  .meter{
    height:10px;
    background:var(--border);
    border-radius:999px;
    overflow:hidden;
    margin-top:6px;
  }
  .bar{
    height:100%;
    width:0;
    background:linear-gradient(90deg,var(--accent),#7dd3fc);
    transition:width .25s ease;
  }

  /* 流量图片 2 列布局 */
  .grid{
    display:grid;
    gap:18px;
    grid-template-columns:repeat(2,minmax(0,1fr));
    align-items:start;
    margin-top:14px;
  }

  .imgwrap{
    border-radius:14px;
    border:1px dashed var(--border);
    padding:8px;
    background:rgba(15,23,42,.02);
  }
  .imgwrap img{
    max-width:100%;
    display:block;
    border-radius:10px;
  }

  @media (max-width:960px){
    .sys-grid, .grid{
      grid-template-columns:1fr;
    }
  }

</style>
</head>
<body>

<div class="container">

  <h1>VPS 流量与系统监控面板</h1>
  <div class="subtitle">查看当前 VPS 的实时系统资源与 vnstati 流量统计（系统每分钟更新，流量图每 5 分钟更新）。</div>

  <!-- 系统资源 -->
  <section id="system">
    <div class="section-title">
      <h2>系统资源（实时刷新）</h2>
      <div class="section-sub">
        数据文件：metrics.json　
        计费周期：<span id="bill-range">--</span>
      </div>
    </div>

    <div class="card">
      <div style="font-size:12px;color:var(--muted);text-align:right;margin-bottom:10px;">
        上次更新：<span id="ts">--</span>
      </div>
      <div id="sys-card">
        加载中…
      </div>
    </div>
  </section>

  <!-- 流量统计 -->
  <section id="traffic" style="margin-top:30px;">
    <div class="section-title">
      <h2>流量统计（vnStat / vnstati）</h2>
      <div class="section-sub">图片每 5 分钟更新一次</div>
    </div>

    <div class="grid">
      <div class="card"><div class="imgwrap"><img src="summary.png" alt="summary"></div></div>
      <div class="card"><div class="imgwrap"><img src="hourly.png" alt="hourly"></div></div>
      <div class="card"><div class="imgwrap"><img src="daily.png" alt="daily"></div></div>
      <div class="card"><div class="imgwrap"><img src="monthly.png" alt="monthly"></div></div>
      <div class="card"><div class="imgwrap"><img src="traffic.png" alt="traffic"></div></div>
    </div>

  </section>

</div>

<script>
// 将 shell 中的 RESET_DAY 传给前端，供计费周期使用
window.VNSTAT_BILL_DAY = ${RESET_DAY};
</script>

<!-- 系统资源填写逻辑 -->
<script src="metrics.js?v=5"></script>

</body>
</html>
EOF_HTML

##################################
# （4）metrics.js（系统资源 2 列卡片 + 进度条 + 计费周期）
##################################
cat > /var/www/html/metrics.js << 'EOF_JS'
(function(){
  function G(id,v){var el=document.getElementById(id); if(el) el.textContent=v;}
  function clamp(v){
    v=parseFloat(v);
    if(isNaN(v)) return 0;
    if(v<0) return 0;
    if(v>100) return 100;
    return v;
  }
  function setBar(id,p){
    var el=document.getElementById(id);
    if(!el) return;
    var val = clamp(p);
    el.style.width = val + "%";
    // 颜色阈值：>90 红，>80 橙，其余蓝
    if(val > 90){
      el.style.background = "linear-gradient(90deg,#ef4444,#f87171)";
    }else if(val > 80){
      el.style.background = "linear-gradient(90deg,#f59e0b,#fbbf24)";
    }else{
      el.style.background = "linear-gradient(90deg,var(--accent),#7dd3fc)";
    }
  }

  function ensureStructure(){
    var box = document.getElementById("sys-card");
    if(!box) return;
    if(box.dataset.ready) return;
    box.dataset.ready = "1";

    // 使用 .sys-grid 做 2 列布局
    box.innerHTML =
      '<div class="sys-grid">'+
        '<div>'+
          '<div class="sys-item-title">CPU 使用率</div>'+
          '<div><span id="cpu-val">--</span>%</div>'+
          '<div class="meter"><div class="bar" id="bar-cpu"></div></div>'+
        '</div>'+
        '<div>'+
          '<div class="sys-item-title">内存</div>'+
          '<div><span id="mem-used">--</span> / <span id="mem-total">--</span> GB（<span id="mem-pct">--</span>%）</div>'+
          '<div class="meter"><div class="bar" id="bar-mem"></div></div>'+
        '</div>'+
        '<div>'+
          '<div class="sys-item-title">磁盘 /</div>'+
          '<div><span id="disk-used">--</span> / <span id="disk-size">--</span>（<span id="disk-pct">--</span>%） 可用 <span id="disk-avail">--</span></div>'+
          '<div class="meter"><div class="bar" id="bar-disk"></div></div>'+
        '</div>'+
        '<div>'+
          '<div class="sys-item-title">网络 <span id="net-iface-tag">(iface)</span></div>'+
          '<div>⬇︎ <span id="rx">--</span> Mbps&nbsp;&nbsp;⬆︎ <span id="tx">--</span> Mbps</div>'+
        '</div>'+
        '<div>'+
          '<div class="sys-item-title">负载 &amp; 运行时长</div>'+
          '<div>负载：<span id="l1">--</span>, <span id="l5">--</span>, <span id="l15">--</span></div>'+
          '<div class="sys-meta">运行时长：<span id="uptime">--</span></div>'+
        '</div>'+
        '<div>'+
          '<div class="sys-item-title">系统信息</div>'+
          '<div><span id="os">--</span></div>'+
          '<div class="sys-meta">内核：<span id="kernel">--</span> · 时区：<span id="tz">--</span><br>上次启动：<span id="boot">--</span></div>'+
        '</div>'+
      '</div>';
  }

  // 计算计费周期（从 billDay 到下一次 billDay 前一天）
  function computeBillingRange(billDay){
    var now = new Date();
    var y = now.getFullYear();
    var m = now.getMonth(); // 0-based
    var d = now.getDate();
    var start, end;
    if (d >= billDay){
      start = new Date(y, m, billDay);
      end   = new Date(y, m+1, billDay-1);
    }else{
      start = new Date(y, m-1, billDay);
      end   = new Date(y, m,   billDay-1);
    }
    function fmt(dt){
      var yy = dt.getFullYear();
      var mm = (dt.getMonth()+1).toString().padStart(2,"0");
      var dd = dt.getDate().toString().padStart(2,"0");
      return yy + "-" + mm + "-" + dd;
    }
    return fmt(start) + " ～ " + fmt(end);
  }

  async function load(){
    ensureStructure();

    // 计费周期
    var billSpan = document.getElementById("bill-range");
    if(billSpan){
      var billDay = (window.VNSTAT_BILL_DAY && Number(window.VNSTAT_BILL_DAY)) || 9;
      billSpan.textContent = computeBillingRange(billDay);
    }

    try{
      var r = await fetch("metrics.json?"+Date.now(),{
        cache:"no-store",
        credentials:"include"
      });
      if(!r.ok) return;
      var j = await r.json();

      // CPU
      if(j.cpu){
        G("cpu-val", j.cpu.used_percent);
        setBar("bar-cpu", j.cpu.used_percent);
      }

      // 内存
      if(j.memory){
        G("mem-used", j.memory.used_gb);
        G("mem-total", j.memory.total_gb);
        G("mem-pct", j.memory.used_percent);
        setBar("bar-mem", j.memory.used_percent);
      }

      // 磁盘
      if(j.disk){
        G("disk-used", j.disk.used);
        G("disk-size", j.disk.size);
        G("disk-avail", j.disk.avail);
        G("disk-pct", j.disk.used_percent);
        setBar("bar-disk", j.disk.used_percent);
      }

      // 网络
      if(j.net){
        if(j.net.iface) G("net-iface-tag", "(" + j.net.iface + ")");
        G("rx", j.net.rx_mbps);
        G("tx", j.net.tx_mbps);
      }

      // 负载
      if(j.loadavg){
        G("l1", j.loadavg.min1);
        G("l5", j.loadavg.min5);
        G("l15", j.loadavg.min15);
      }

      // 运行时长
      if(j.uptime){
        var upStr = "";
        if(typeof j.uptime.days === "number")   upStr += j.uptime.days   + "天";
        if(typeof j.uptime.hours === "number")  upStr += j.uptime.hours  + "小时";
        if(typeof j.uptime.minutes === "number")upStr += j.uptime.minutes+ "分钟";
        G("uptime", upStr || "--");
      }

      // 系统信息
      if(j.os)      G("os", j.os);
      if(j.kernel)  G("kernel", j.kernel);
      if(j.timezone)G("tz", j.timezone);
      if(j.boot_time)G("boot", j.boot_time);

      // 时间戳显示在卡片右上角（id="ts"）
      if(j.timestamp){
        G("ts", j.timestamp);
      }

    }catch(e){
      // 安静失败即可
    }
  }

  load();
  setInterval(load, 30000);
})();
EOF_JS

##################################
# （5）gen-metrics.sh（每分钟生成 metrics.json）
##################################
cat > /usr/local/sbin/gen-metrics.sh << 'EOF_MET'
#!/usr/bin/env bash
set -e
OUT="/var/www/html/metrics.json"

# 读取配置
IFACE="eth0"
if [ -f /etc/vnstat-panel.conf ]; then
  # shellcheck disable=SC1091
  . /etc/vnstat-panel.conf || true
fi
[ -z "$IFACE" ] && IFACE="eth0"

# CPU
read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
total1=$((user+nice+system+idle+iowait+irq+softirq+steal))
idle1=$idle
sleep 0.5
read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
total2=$((user+nice+system+idle+iowait+irq+softirq+steal))
idle2=$idle
dt=$((total2-total1)); di=$((idle2-idle1))
if [ "$dt" -gt 0 ]; then cpu_used_pct=$((100*(dt-di)/dt)); else cpu_used_pct=0; fi

cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 1)
mhz=$(awk -F": " '/cpu MHz/ {s+=$2;n++} END{if(n)printf"%.0f",s/n;else print 0}' /proc/cpuinfo 2>/dev/null)

# 内存
total_k=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
avail_k=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
used_k=$((total_k-avail_k))
used_pct=$(awk -v a="$total_k" -v b="$used_k" 'BEGIN{if(a>0)printf "%.0f",b/a*100; else print 0}')
tot_g=$(awk -v k="$total_k" 'BEGIN{printf "%.2f",k/1024/1024}')
usd_g=$(awk -v k="$used_k" 'BEGIN{printf "%.2f",k/1024/1024}')

# 磁盘
read fs size used avail usep mount <<< "$(df -h / | awk 'NR==2{print $1,$2,$3,$4,$5,$6}')"
usep=${usep%\%}

# 负载、运行时长
read l1 l5 l15 _ < /proc/loadavg
up_sec=$(awk '{print int($1)}' /proc/uptime)
d=$((up_sec/86400)); h=$((up_sec%86400/3600)); m=$((up_sec%3600/60))

# 网络
rx1=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
tx1=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
sleep 1
rx2=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo "$rx1")
tx2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo "$tx1")
rx=$(awk -v b="$((rx2-rx1))" 'BEGIN{printf "%.2f",(b*8)/1000000}')
tx=$(awk -v b="$((tx2-tx1))" 'BEGIN{printf "%.2f",(b*8)/1000000}')

os=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
kernel=$(uname -r)
tz=$(date +'%Z (UTC%:z)')
boot=$(who -b | awk '{print $3, $4}')

cat > "$OUT".tmp <<JSON
{
  "timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "os": "$os",
  "kernel": "$kernel",
  "timezone": "$tz",
  "boot_time": "$boot",
  "cpu": { "used_percent": $cpu_used_pct, "cores": $cores, "mhz": $mhz },
  "memory": { "total_gb": $tot_g, "used_gb": $usd_g, "used_percent": $used_pct },
  "disk": { "size": "$size", "used": "$used", "avail": "$avail", "used_percent": $usep },
  "loadavg": { "min1": $l1, "min5": $l5, "min15": $l15 },
  "uptime": { "days": $d, "hours": $h, "minutes": $m },
  "net": { "iface": "$IFACE", "rx_mbps": $rx, "tx_mbps": $tx }
}
JSON

mv "$OUT".tmp "$OUT"
chmod 644 "$OUT"
EOF_MET

chmod +x /usr/local/sbin/gen-metrics.sh

cat > /etc/cron.d/gen-metrics << 'EOF_CRONM'
* * * * * root /usr/local/sbin/gen-metrics.sh >> /var/log/gen-metrics.log 2>&1
EOF_CRONM

/usr/local/sbin/gen-metrics.sh

##################################
# （6）gen-traffic-images.sh（每 5 分钟更新 vnstati 图片）
##################################
cat > /usr/local/sbin/gen-traffic-images.sh << 'EOF_VIMG'
#!/usr/bin/env bash
set -e
OUT="/var/www/html"

IFACE="eth0"
if [ -f /etc/vnstat-panel.conf ]; then
  # shellcheck disable=SC1091
  . /etc/vnstat-panel.conf || true
fi
[ -z "$IFACE" ] && IFACE="eth0"

vnstati -i "$IFACE" -s -o "$OUT/summary.png"
vnstati -i "$IFACE" -h -o "$OUT/hourly.png"
vnstati -i "$IFACE" -d -o "$OUT/daily.png"
vnstati -i "$IFACE" -m -o "$OUT/monthly.png"
vnstati -i "$IFACE" -t -o "$OUT/traffic.png"

chmod 644 "$OUT/"*.png 2>/dev/null || true
EOF_VIMG

chmod +x /usr/local/sbin/gen-traffic-images.sh
/usr/local/sbin/gen-traffic-images.sh

cat > /etc/cron.d/gen-traffic-images << 'EOF_CRONV'
*/5 * * * * root /usr/local/sbin/gen-traffic-images.sh >> /var/log/gen-traffic-images.log 2>&1
EOF_CRONV

##################################
# （7）每月重置 vnStat（使用 RESET_DAY）
##################################
cat > /usr/local/sbin/vnstat-reset.sh << 'EOF_RST'
#!/usr/bin/env bash
set -e
IFACE="eth0"
if [ -f /etc/vnstat-panel.conf ]; then
  # shellcheck disable=SC1091
  . /etc/vnstat-panel.conf || true
fi
[ -z "$IFACE" ] && IFACE="eth0"

echo "Resetting vnStat database on interface: $IFACE"
vnstat --remove --force -i "$IFACE" || true
vnstat --add -i "$IFACE"
systemctl restart vnstat || true

/usr/local/sbin/gen-traffic-images.sh || true
/usr/local/sbin/gen-metrics.sh || true
EOF_RST

chmod +x /usr/local/sbin/vnstat-reset.sh

cat > /etc/cron.d/vnstat-reset-monthly << EOF_CRONR
5 0 ${RESET_DAY} * * root /usr/local/sbin/vnstat-reset.sh >> /var/log/vnstat-reset.log 2>&1
EOF_CRONR

##################################
# （8）Nginx + BasicAuth
##################################
htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASS"

cat > "/etc/nginx/sites-available/${DOMAIN}.conf" << EOF_NGX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;

    ssl_certificate     ${CERT};
    ssl_certificate_key ${PRIV};

    root /var/www/html;
    index index.html;

    location = /metrics.json {
        add_header Cache-Control "no-store, no-cache, max-age=0, must-revalidate" always;
        try_files /metrics.json =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF_NGX

ln -sf "/etc/nginx/sites-available/${DOMAIN}.conf" "/etc/nginx/sites-enabled/${DOMAIN}.conf"

nginx -t
systemctl reload nginx

echo
echo "============================ 部署完成 ============================"
echo "访问地址:   https://${DOMAIN}"
echo "用户名:     ${AUTH_USER}"
echo "密码:       ${AUTH_PASS}"
echo "监控网卡:   ${IFACE}"
echo "每月重置日: ${RESET_DAY} 号 00:05"
echo "================================================================="
echo
EOF

chmod +x deploy_vnstat_panel.sh
sudo ./deploy_vnstat_panel.sh
