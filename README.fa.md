# گیت‌وی خروجی WARP

این پروژه یک Ubuntu را به **Next-Hop شفاف** تبدیل می‌کند. فایروال یا روتر، ترافیک انتخاب‌شده را به کارت Transit سرور می‌دهد و سرور آن را از `warp0` و Cloudflare WARP خارج می‌کند؛ در عین حال Default Route مدیریت Ubuntu روی لینک اصلی باقی می‌ماند.

این Repository دو بخش مستقل Native و Docker دارد و از نسخه `0.3.2` مانیتورینگ و نگهداری لاگ هفت‌روزه را هم به‌صورت پیش‌فرض نصب می‌کند:

| بخش | روش اجرا | کاربرد مناسب |
|---|---|---|
| `native/` | مستقیم روی Ubuntu و systemd | VM اختصاصی Gateway و کمترین پیچیدگی |
| `docker/` | Docker Engine روی Linux | استقرار استاندارد کانتینری و جابه‌جایی ساده‌تر |

این دو روش روی یک Host هم‌زمان اجرا نمی‌شوند؛ برای هر سرور فقط یکی از حالت‌های Native یا Docker را انتخاب کن.

در هر دو روش، نصب معمول فقط دو مقدار اصلی می‌خواهد:

1. IP کارت اصلی که اینترنت و Default Route دارد.
2. IP/CIDR کارت Transit سمت فایروال، معمولاً `/30`.

اسکریپت نام Interfaceها، Default Gateway، IP طرف مقابل `/30`، WARP، NAT، Policy Routing، MSS Clamping، Health Check، نگهداری لاگ هفت‌روزه، مانیتور یک‌دقیقه‌ای و Kill Switch را خودش آماده می‌کند.

از نسخه `0.3.3` پروفایل‌های dual-stack تولیدشده توسط `wgcf` قبل از اجرای `wg-quick` برای مسیر IPv4-only این پروژه نرمال می‌شوند؛ بنابراین خاموش بودن IPv6 روی Host باعث Fail شدن `warp0` نمی‌شود. از نسخه `0.4.0` چرخه رسمی Backup، Upgrade و Rollback نیز برای Native و Docker اضافه شده است.

نسخه `0.4.1` تمام Ruleها و جدول Policy Routing متعلق به پروژه را دقیق بررسی
می‌کند و اگر سرویس شبکه Host آن‌ها را حذف یا تغییر دهد، فقط همان Routing را
بدون Restart غیرضروری WireGuard بازیابی می‌کند. این بازیابی تنها وقتی انجام
می‌شود که Interface مربوط به WARP و Kill Switch مبتنی بر nftables سالم باشند.

> این پروژه وابسته به Cloudflare نیست. ابزار `wgcf` غیررسمی است. قبل از ثبت حساب، شرایط Cloudflare را بررسی کن.

## انتشار از Windows روی GitHub

برای جلوگیری از مشکل Permission و CRLF، فایل `publish-to-github.ps1` همراه پروژه ارائه شده است. این اسکریپت آخرین نسخه Repository را در یک پوشه موقت Clone می‌کند، فایل‌های این بسته را روی آن Sync می‌کند، Line Endingهای Shell را LF نگه می‌دارد، مجوز اجرایی اسکریپت‌ها را داخل Git ثبت می‌کند و سپس Commit و Push انجام می‌دهد.

در PowerShell داخل پوشه Extractشده اجرا کن:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\publish-to-github.ps1 `
  -RepositoryUrl "https://github.com/Alireza-Oliaiy/warp-egress-gateway.git" `
  -CommitMessage "Release v0.4.1: recover policy routing after network reconciliation" `
  -CreateReleaseTag
```

Git Credential Manager ممکن است مرورگر را برای ورود به GitHub باز کند. کلید یا پروفایل WARP داخل Repository کپی نمی‌شود.

## نصب سریع

```bash
git clone https://github.com/Alireza-Oliaiy/warp-egress-gateway.git
cd warp-egress-gateway
sudo bash setup.sh
```

بعد انتخاب می‌کنی:

```text
1) نصب Native روی Ubuntu
2) نصب Docker روی Linux
3) Upgrade نصب موجود
```

سپس IP اصلی و IP Transit را وارد می‌کنی.

## آپگرید نصب موجود

از نسخه `0.4.0` روی نصب Native دستور رسمی Upgrade نصب می‌شود؛ بدون `--ref` بالاترین Release Tag با قالب `vX.Y.Z` انتخاب می‌شود:

```bash
sudo warp-gateway upgrade --ref v0.4.1
```

برای بررسی بدون اعمال تغییر:

```bash
sudo warp-gateway upgrade --dry-run
```

برای نسخه‌های قدیمی `0.3.x`، آخرین Repository را Clone کن و Upgrader عمومی را اجرا کن:

```bash
sudo bash upgrade.sh --mode native
```

در Docker همین Upgrader با `--mode docker` استفاده می‌شود. Upgrade قبل از هر تغییر Backup روت‌فقط می‌سازد، WARP Identity و تنظیمات فعلی را حفظ می‌کند، Kill Switch/Host Guard را فعال نگه می‌دارد، مسیر جدید را تست می‌کند و اگر Validation شکست بخورد Rollback خودکار را تلاش می‌کند. جزئیات: [راهنمای Upgrade](docs/upgrade.md) و [راهنمای Rollback](docs/rollback.md).

### نصب Native بدون پرسش

```bash
sudo bash setup.sh --mode native \
  --uplink-ip 203.0.113.5 \
  --transit-ip 198.51.100.2/30 \
  --accept-tos \
  --non-interactive
```

### نصب Docker بدون پرسش

```bash
sudo bash setup.sh --mode docker \
  --uplink-ip 203.0.113.5 \
  --transit-ip 198.51.100.2/30 \
  --accept-tos \
  --non-interactive
```

## بخش Native

در این روش WireGuard، nftables، Policy Routing و سرویس‌های systemd مستقیماً روی Ubuntu نصب می‌شوند.

نصب پیشرفته:

```bash
cp native/config/warp-gateway.env.example native/config/warp-gateway.env
nano native/config/warp-gateway.env
sudo bash native/install.sh --config native/config/warp-gateway.env
```

استفاده از پروفایل فعلی:

```bash
sudo bash native/install.sh \
  --config native/config/warp-gateway.env \
  --profile /etc/wireguard/warp0.conf
```

دستورات مدیریت:

```bash
sudo warp-gateway status
sudo warp-gateway health
sudo warp-gateway monitor
sudo warp-gateway history
sudo warp-gateway failures
sudo warp-gateway restart
sudo warp-gateway lockdown
sudo warp-gateway logs
sudo warp-gateway version
sudo warp-gateway upgrade --ref vX.Y.Z
sudo warp-gateway rollback --backup /var/backups/warp-egress-gateway/upgrade-...
```


## لاگ و مانیتورینگ هفت‌روزه

هر دو روش نصب، `systemd-journald` را Persistent می‌کنند و لاگ‌ها را تا ۷ روز با سقف ۱ گیگابایت نگه می‌دارند. در حالت Native، `warp-monitor.timer` هر ۶۰ ثانیه وضعیت WireGuard، سن Handshake، اینترنت مستقیم، WARP، لینک بالادست، Policy Route و nftables را ثبت می‌کند.

مشاهده کل تاریخچه:

```bash
sudo warp-gateway history
```

فقط خرابی‌ها:

```bash
sudo warp-gateway failures
```

در نسخه `0.3.2` مقدار `AUTO_RECOVER` به‌صورت پیش‌فرض `false` است تا قبل از Restart خودکار، شواهد قطعی برای Root Cause باقی بماند. جزئیات بیشتر در [راهنمای مانیتورینگ](docs/monitoring.md) آمده است.

در نسخه `0.4.1` حتی با `AUTO_RECOVER=false`، بازیابی محدود و قطعی Policy
Routing فعال می‌ماند؛ Restart کامل Tunnel همچنان فقط با
`AUTO_RECOVER=true` و شواهد خرابی خود Tunnel مجاز است.

## بخش Docker

در این روش ثبت WARP، ساخت و نگهداری `warp0`، Health Check، مانیتور یک‌دقیقه‌ای، NAT، Policy Routing و در صورت فعال‌سازی، Recovery داخل Container اجرا می‌شود.

بااین‌حال یک Bootstrap کوچک و اجباری روی Host باقی می‌ماند، چون Transparent Routing باید Network Namespace و nftables خود Linux Host را کنترل کند. این Bootstrap:

- Interfaceها را از روی دو IP پیدا می‌کند.
- در صورت نیاز IP Transit را با Netplan تنظیم می‌کند.
- IPv4 Forwarding را فعال می‌کند.
- یک Kill Switch مستقل روی Host می‌سازد.
- Docker و Compose را نصب و Container را اجرا می‌کند.

نسخه Docker برای **Docker Engine روی Linux** طراحی شده است؛ Docker Desktop ویندوز و macOS برای این سناریوی Layer-3 شفاف مناسب نیست.

مدیریت:

```bash
cd docker
docker compose ps
docker compose logs -f gateway
docker compose exec gateway /app/bin/status.sh
```

توقف Container، درحالی‌که Kill Switch مستقل Host باقی بماند:

```bash
cd docker
docker compose down
```

حذف نسخه Docker:

```bash
sudo bash docker/uninstall.sh
```

## رفتار امنیتی

- ترافیک مدیریت سرور از کارت اصلی خارج می‌شود.
- فقط ترافیک واردشده از کارت Transit به جدول WARP می‌رود.
- فقط Source مشخص‌شده یا IP طرف مقابل `/30` پذیرفته می‌شود.
- اگر WARP قطع شود، ترافیک Transit از لینک عادی نشت نمی‌کند.
- در نسخه Docker، Kill Switch مستقل از Container روی Host باقی می‌ماند.
- کلیدها و WARP Identity داخل Git ذخیره نمی‌شوند.

## مسئولیت FortiGate یا روتر بالادست

- تشخیص سرویس یا مقصد موردنظر
- انتخاب IP Transit Ubuntu به‌عنوان Next-Hop
- ترجیحاً SNAT به IP سمت `/30` فایروال
- مستثناکردن ترافیک خود Ubuntu
- عبور TCP و UDP، مخصوصاً UDP/443 برای QUIC

جزئیات در [راهنمای FortiGate](docs/fortigate.md) آمده است.

## محدودیت‌ها

- فعلاً Transit فقط IPv4 است.
- WARP رایگان IP اختصاصی یا SLA نمی‌دهد.
- کشور خروجی را پروژه انتخاب نمی‌کند.
- جریان ثبت `wgcf` غیررسمی است.
- برای مسیرهای حیاتی، روی FortiGate مسیر Backup نگه دار.
- Docker Edition همچنان نیازمند Bootstrap روی Linux Host است؛ اجرای امن Gateway شفاف فقط با یک Container کاملاً ایزوله ممکن نیست.

## مستندات پروژه

- [فهرست مستندات](docs/README.md)
- [Upgrade](docs/upgrade.md)
- [Rollback](docs/rollback.md)
- [Operations](docs/operations.md)
- [Monitoring](docs/monitoring.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Security](docs/security.md)
- [Release Process](docs/release-process.md)
