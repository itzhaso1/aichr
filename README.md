# كاشير حاسم (Hasim Cashier)

تطبيق Flutter مستقل لتشغيل الكاشير، متصل بـ Laravel عبر:

`/api/cashier/v1`

**منفصل تمامًا عن** تطبيق `apps/hasim` (حاسم شات). لا يحتوي Inbox / Chat / Email / Stories / Channels.

## التشغيل

```bash
cd apps/hasim_cashier
flutter pub get
flutter run \
  --dart-define=CASHIER_API_BASE=https://your-laravel-host
```

## المصادقة

- Login حقيقي عبر Sanctum (نفس مستخدمي Laravel)
- Token في `flutter_secure_storage`
- Workspace عبر header `X-Workspace-Id`
- لا يوجد Demo Login

## Offline

- Hive للكatalog cache + Pending Orders
- Sync Engine: Pending → API (client_reference) → Synced | Failed → Retry
- المدفوعات الإلكترونية **لا** تُعلَن ناجحة Offline

## البنية

- `lib/core` — API, auth, offline, theme
- `lib/features` — login, workspace, home/POS shell
- لا يعتمد على كود حاسم شات
