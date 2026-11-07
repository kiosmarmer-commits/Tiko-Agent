# Email gateway

`EmailGateway` berbicara SMTP plain ke relay lokal.

## Produksi (disarankan)

Gunakan **msmtp** / **postfix** / **OpenSMTPD** di `127.0.0.1:25` yang sudah STARTTLS ke provider.

```bash
export EMAIL_FROM=agent@example.com
export EMAIL_TO=you@example.com
export EMAIL_ALLOW=you@example.com
export SMTP_HOST=127.0.0.1
export SMTP_PORT=25
dart run apps/agentd/bin/agentd.dart
```

## STARTTLS langsung

Tidak diimplementasikan di pure Dart (butuh TLS handshake multi-step).
Opsi: stunnel atau relay lokal.
