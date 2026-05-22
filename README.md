# Xiaomi Scale → Garmin Connect

Reads body composition data from a Xiaomi/PICOOC BLE scale and uploads it to Garmin Connect as a `.fit` file. Two implementations: a Python script for always-on devices (Raspberry Pi) and a Flutter Android app for phones.

---

## How it works

1. The scale broadcasts BLE advertisement packets (service UUID `0000181b-0000-1000-8000-00805f9b34fb`) containing weight, impedance, and a timestamp.
2. Weight + bioelectrical impedance are fed into a body composition formula to estimate fat %, muscle mass, hydration, and BMI.
3. The result is encoded as a Garmin `.fit` file (weight-scale message type) and uploaded to `connectapi.garmin.com` via the Garmin mobile API.

The scale broadcasts the same packet repeatedly while you stand on it, so deduplication is done on `(scale_ts, weight, impedance)`.

---

## Python scripts (`python/`)

Designed for a Raspberry Pi or any Linux machine with Bluetooth.

### `xiaomi_scale.py` — main listener

Scans for the scale continuously using `bleak`, computes body composition, and uploads to Garmin Connect.

**Setup**

```bash
pip install bleak python-garminconnect python-dotenv
```

Create a `.env` file (or export env vars):

```
GARMIN_EMAIL=your@email.com
GARMIN_PASSWORD=yourpassword
HEIGHT=175
AGE=30
SEX=male
```

```bash
python3 xiaomi_scale.py
```

Set `DEBUG=true` to print measurements without uploading.

### `upload_body_composition.py` — one-shot upload

Uploads a single hardcoded measurement. Useful for testing the Garmin API connection.

```bash
python3 upload_body_composition.py
```

### `get_data.py` — data inspector

Fetches today's data from Garmin Connect across all health metrics (body composition, sleep, HRV, steps, etc.) and prints it as JSON.

```bash
python3 get_data.py
```

### `garmin-scale.service` — systemd unit

Runs `xiaomi_scale.py` as a background service on a Raspberry Pi.

```bash
# Edit WorkingDirectory, ExecStart, and credentials in the file, then:
sudo cp garmin-scale.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now garmin-scale
sudo journalctl -u garmin-scale -f
```

---

## Flutter app (`scale_app/`)

An Android app that does the same thing from your phone — no Raspberry Pi needed.

### Features

- BLE scan runs as a foreground service (survives screen-off)
- Native email + password login using Android's Cronet (Chrome's TLS stack — same fingerprint as Chrome, bypasses Cloudflare)
- WebView login fallback for accounts with MFA or if native login fails
- Displays last measurement with weight, body fat %, muscle mass, hydration, BMI
- Manual "Sync to Garmin" button plus automatic background sync on each new measurement
- 5-minute cooldown to prevent duplicate uploads

### Build

```bash
cd scale_app
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Requires Android SDK and `adb` in PATH. Set `ANDROID_HOME` if needed:

```bash
ANDROID_HOME=/home/you/Android flutter build apk --release
```

### Setup

1. Open the app → tap the gear icon → **Login (Native, email + password)**
2. Enter your Garmin email and password
3. Fill in Height, Age, Sex under Body Profile → Save
4. Back on the home screen, tap **Start** to begin scanning
5. Step on the scale with bare feet — measurement appears within ~30 seconds

### Auth notes

- Native login uses the Garmin mobile SSO flow: POST JSON credentials to `sso.garmin.com/mobile/api/login` → get a service ticket → exchange at `diauth.garmin.com` for a DI OAuth2 bearer token.
- The bearer token authenticates against `connectapi.garmin.com` (Garmin's mobile API), not `connect.garmin.com` (web, needs browser cookies).
- Accounts with MFA enabled must use the WebView login.

### Body composition formula

Port of the Xiaomi Mi Scale open-source formula:

```
lbm = (height * 9.058 / 100) * (height / 100) + weight * 0.32 + 12.226
lbm -= impedance * 0.0068 + age * 0.0542

fat_pct  = (1 - ((lbm - 0.8 + lbm * coeff * 0.05) / weight)) * 100
muscle   = weight - (weight * fat_pct / 100)
water    = (muscle / weight) * 73.0
bmi      = weight / (height_m ** 2)
```

---

## BLE packet format (Xiaomi scale service UUID `181b`)

| Byte(s) | Field        | Notes                             |
|---------|--------------|-----------------------------------|
| 0       | ctrl0        | Unused in current code            |
| 1       | ctrl1        | Bit 0=lbs, bit 4=jin, bit 5=stable, bit 1=has impedance |
| 2–3     | year         | Little-endian                     |
| 4       | month        |                                   |
| 5       | day          |                                   |
| 6       | hour         |                                   |
| 7       | minute       |                                   |
| 8       | second       |                                   |
| 9–10    | impedance    | Little-endian, ohms               |
| 11–12   | raw weight   | Little-endian; divide by 200 for kg, 100 for lbs/jin |

The scale's built-in clock is unreliable (often broadcasts UTC regardless of Mi Fit timezone settings). The app uses the phone's current time as the measurement timestamp instead; the scale's time is only used for deduplication.
