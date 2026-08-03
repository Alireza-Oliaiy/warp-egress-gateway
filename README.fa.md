# گیت‌وی خروجی WARP

این پروژه یک Ubuntu را به **Next-Hop شفاف** تبدیل می‌کند. فایروال یا روتر، ترافیک انتخاب‌شده را به کارت Transit سرور می‌دهد و سرور آن را از `warp0` و Cloudflare WARP خارج می‌کند؛ در عین حال Default Route مدیریت Ubuntu روی لینک اصلی باقی می‌ماند.

این Repository از نسخه `0.3.1` دو بخش مستقل دارد:

| بخش | روش اجرا | کاربرد مناسب |
|---|---|---|
| `native/` | مستقیم روی Ubuntu و systemd | VM اختصاصی Gateway و کمترین پیچیدگی |
| `docker/` | Docker Engine روی Linux | استقرار استاندارد کانتینری و جابه‌جایی ساده‌تر |

این دو روش روی یک Host هم‌زمان اجرا نمی‌شوند؛ برای هر سرور فقط یکی از حالت‌های Native یا Docker را انتخاب کن.

در هر دو روش، نصب معمول فقط دو مقدار اصلی می‌خواهد:

1. IP کارت اصلی که اینترنت و Default Route دارد.
2. IP/CIDR کارت Transit سمت فایروال، معمولاً `/30`.

اسکریپت نام Interfaceها، Default Gateway، IP طرف مقابل `/30`، WARP، NAT، Policy Routing، MSS Clamping، Health Check و Kill Switch را خودش آماده می‌کند.

> این پروژه وابسته به Cloudflare نیست. ابزار `wgcf` غیررسمی است. قبل از ثبت حساب، شرایط Cloudflare را بررسی کن.

## انتشار از Windows روی GitHub

برای جلوگیری از مشکل Permission و CRLF، فایل `publish-to-github.ps1` همراه پروژه ارائه شده است. این اسکریپت آخرین نسخه Repository را در یک پوشه موقت Clone می‌کند، فایل‌های این بسته را روی آن Sync می‌کند، Line Endingهای Shell را LF نگه می‌دارد، مجوز اجرایی اسکریپت‌ها را داخل Git ثبت می‌کند و سپس Commit و Push انجام می‌دهد.

در PowerShell داخل پوشه Extractشده اجرا کن:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\publish-to-github.ps1 `
  -RepositoryUrl "https://github.com/Alireza-Oliaiy/warp-egress-gateway.git" `
  -CommitMessage "Release v0.3.1: harden Windows publishing"
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
```

سپس IP اصلی و IP Transit را وارد می‌کنی.

### نصب Native بدون پرسش

```bash
sudo bash setup.sh --mode native \
  --uplink-ip 172.20.31.5 \
  --transit-ip 10.1.1.230/30 \
  --accept-tos \
  --non-interactive
```

### نصب Docker بدون پرسش

```bash
sudo bash setup.sh --mode docker \
  --uplink-ip 172.20.31.5 \
  --transit-ip 10.1.1.230/30 \
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
sudo warp-gateway restart
sudo warp-gateway lockdown
sudo warp-gateway logs
```

## بخش Docker

در این روش ثبت WARP، ساخت و نگهداری `warp0`، Health Check، Recovery، NAT و Policy Routing داخل Container اجرا می‌شود.

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
