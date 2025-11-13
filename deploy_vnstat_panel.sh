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
  # 必须是整数
  if ! echo "$RESET_DAY" | grep -Eq '^[0-9]+$'; then
    echo "❌ 请输入 1-28 的数字。"
    RESET_DAY=""
    continue
  fi
  if [ "$RESET_DAY" -lt 1 ] || [ "$RESET_DAY" -gt 28 ]; then
    echo "❌ 为避免 30/31 和 2 月天数问题，请使用 1-28 之间的日期。"
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

# 记录配置到文件，供各子脚本使用
cat > /etc/vnstat-panel.conf <<EOF
IFACE="$IFACE"
RESET_DAY="$RESET_DAY"
EOF

# 启用 vnstat
systemctl enable --now vnstat
vnstat --add -i "$IFACE" >/dev/null 2>&1 || true
systemctl restart vnstat

mkdir -p /var/www/html
chown -R www-data:www-data /var/www/html

##################################
# （3）首页 index.html（卡片 + 计费周期）
##################################
cat > /var/www/html/index.html << EOF_HTML
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<title>流量监控面板</title>
<meta name="viewport" content="width=device-width,initial-scale=1" />
<style>
  :root{ --bg:#f7f7f9; --card:#ffffff; --text:#111; --muted:#777; --border:#e0e0e0; --accent:#0ea5e9; }
  body{ margin:0; font-family:-apple-system,Roboto,Helvetica Neue,Arial,PingFang SC; background:var(--bg); }
  .container{ max-width:1100px; margin:24px auto; padding:0 16px; }
  .grid{ display:grid; gap:18px; grid-template-columns: repeat(auto-fit,minmax(450px,1fr)); }
  .card{ background:var(--card); border:1px solid var(--border); border-radius:16px; padding:16px; }
  .imgwrap{ border:1px dashed var(--border); border-radius:12px; padding:8px; }
  .meter{height:10px;border-radius:999px;background:var(--border);overflow:hidden}
  .bar{height:100%;width:0;background:linear-gradient(90deg,var(--accent),#7dd3fc)}
  h2{margin:0 0 6px;}
  .sub{font-size:12px;color:var(--muted);margin-bottom:8px;}
</style>
</head>
<body>
<div class="container">

<h2>系统资源（1 分钟刷新）</h2>
<div class="sub">
  数据文件：metrics.json
  <br>计费周期：<span id="bill-range">计算中…</span>
</div>
<div class="imgwrap" id="sys-card">加载中…</div>

<h2 style="margin-top:26px;">流量统计（vnstati）</h2>
<div class="grid">
  <div class="card"><div class="imgwrap"><img src="summary.png" alt="summary"></div></div>
  <div class="card"><div class="imgwrap"><img src="hourly.png"  alt="hourly"></div></div>
  <div class="card"><div class="imgwrap"><img src="daily.png"   alt="daily"></div></div>
  <div class="card"><div class="imgwrap"><img src="monthly.png" alt="monthly"></div></div>
  <div class="card"><div class="imgwrap"><img src="traffic.png" alt="traffic"></div></div>
</div>

</div>

<script>
// 账单重置日（供 metrics.js 计算计费周期）
window.VNSTAT_BILL_DAY = ${RESET_DAY};
</script>
<script src="metrics.js?v=4"></script>
</body>
</html>
EOF_HTML

##################################
# （4）生成系统指标脚本 gen-metrics.sh
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
# （5）流量图片脚本 gen-traffic-images.sh
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
# （6）每月重置 vnStat（使用 RESET_DAY）
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

# 重置后顺便更新一次图和指标
/usr/local/sbin/gen-traffic-images.sh || true
/usr/local/sbin/gen-metrics.sh || true
EOF_RST

chmod +x /usr/local/sbin/vnstat-reset.sh

cat > /etc/cron.d/vnstat-reset-monthly << EOF_CRONR
5 0 ${RESET_DAY} * * root /usr/local/sbin/vnstat-reset.sh >> /var/log/vnstat-reset.log 2>&1
EOF_CRONR

##################################
# （7）前端 metrics.js（含计费周期显示）
##################################
cat > /var/www/html/metrics.js << 'EOF_JS'
(function(){
  function G(id,v){var el=document.getElementById(id); if(el) el.textContent=v;}
  function clamp(v){v=parseFloat(v); if(isNaN(v)) return 0; return Math.max(0,Math.min(100,v));}
  function setBar(id,p){var el=document.getElementById(id); if(el) el.style.width=clamp(p)+"%";}
  function color(id,v){
    var el=document.getElementById(id); if(!el) return;
    if(v>90) el.style.background="linear-gradient(90deg,#ef4444,#f87171)";
    else if(v>80) el.style.background="linear-gradient(90deg,#f59e0b,#fbbf24)";
    else el.style.background="linear-gradient(90deg,var(--accent),#7dd3fc)";
  }

  // 计算计费周期：从 billDay 当天起到下一个 billDay 前一天
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

  function ensure(){
    var box=document.getElementById("sys-card");
    if(!box) return;
    if(box.dataset.ready) return;
    box.dataset.ready=1;
    box.innerHTML='<div style="line-height:1.6;font-size:14px;">\
      <b>CPU：</b><span id="cpu">--</span>%\
      <div class="meter"><div class="bar" id="b-cpu"></div></div>\
      <br><b>内存：</b><span id="memu">--</span>/<span id="memt">--</span>GB（<span id="memp">--</span>%）\
      <div class="meter"><div class="bar" id="b-mem"></div></div>\
      <br><b>磁盘：</b><span id="du">--</span>/<span id="dt">--</span>（<span id="dp">--</span>%） 可用 <span id="da">--</span>\
      <div class="meter"><div class="bar" id="b-disk"></div></div>\
      <br><b>网络：</b>⬇︎ <span id="rx">--</span> Mbps ⬆︎ <span id="tx">--</span> Mbps\
      <br><b>负载：</b><span id="l1">--</span>, <span id="l5">--</span>, <span id="l15">--</span>\
      <br><b>系统：</b><span id="os">--</span>\
      <br><b>内核：</b><span id="kernel">--</span>\
      <br><b>时区：</b><span id="tz">--</span>\
      <br><b>上次启动：</b><span id="boot">--</span>\
      <br><span style="color:#999;font-size:12px;">更新：<span id="ts">--</span></span>\
    </div>';
  }

  async function load(){
    ensure();

    // 设置计费周期显示
    var billSpan = document.getElementById("bill-range");
    var billDay = (window.VNSTAT_BILL_DAY && Number(window.VNSTAT_BILL_DAY)) || 9;
    if (billSpan){
      billSpan.textContent = computeBillingRange(billDay);
    }

    try{
      var r=await fetch("metrics.json?"+Date.now(),{cache:"no-store"});
      if(!r.ok) return;
      var j=await r.json();
      G("cpu",j.cpu.used_percent);
      G("memu",j.memory.used_gb); G("memt",j.memory.total_gb); G("memp",j.memory.used_percent);
      G("du",j.disk.used); G("dt",j.disk.size); G("dp",j.disk.used_percent); G("da",j.disk.avail);
      if (j.net){
        G("rx",j.net.rx_mbps); G("tx",j.net.tx_mbps);
      }
      G("l1",j.loadavg.min1); G("l5",j.loadavg.min5); G("l15",j.loadavg.min15);
      G("os",j.os); G("kernel",j.kernel); G("tz",j.timezone); G("boot",j.boot_time); G("ts",j.timestamp);
      setBar("b-cpu",j.cpu.used_percent);  color("b-cpu",j.cpu.used_percent);
      setBar("b-mem",j.memory.used_percent); color("b-mem",j.memory.used_percent);
      setBar("b-disk",j.disk.used_percent);  color("b-disk",j.disk.used_percent);
    }catch(e){}
  }

  load();
  setInterval(load,30000);
})();
EOF_JS

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
