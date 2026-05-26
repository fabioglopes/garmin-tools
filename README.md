# Xiaomi Scale → Garmin Connect

Reads body composition data from a Xiaomi/PICOOC BLE scale and uploads it to Garmin Connect as a `.fit` file. Two implementations: a Python script for always-on devices (Raspberry Pi) and a Flutter Android app for phones.

---

## How it works

1. The scale broadcasts BLE advertisement packets (service UUID `0000181b-0000-1000-8000-00805f9b34fb`) containing weight, impedance, and a timestamp.
2. Weight + bioelectrical impedance are fed into a body composition formula to estimate fat %, muscle mass, hydration, and BMI.
3. The result is encoded as a Garmin `.fit` file (weight-scale message type) and uploaded to `connectapi.garmin.com` via the Garmin mobile API.
4. Measurements are deduplicated using a weight + time window so rebroadcasts from the scale don't create duplicate records.

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

- **Multi-profile support** — multiple people can share the same scale; the app auto-detects who stepped on it by comparing the measured weight to each profile's last known weight (±3 kg tolerance)
- **Measurement history** — all measurements are stored locally with full body composition data; tap any entry to open the detail screen
- **BLE foreground service** — scanning runs even with the screen off; a persistent notification keeps it alive
- **5-second capture buffer** — the app waits after the first stable packet before saving, so impedance data (which arrives a second or two after weight stabilises) is always captured
- **Real-time debug screen** — live feed of every BLE packet as it arrives, including unstabilised readings and impedance flag, useful for diagnosing scale reception issues
- **Native Garmin login** — uses Android's Cronet (Chrome's TLS stack) so the login request looks identical to the Garmin mobile app, bypassing Cloudflare protection; token is refreshed automatically on 401
- **Auto token refresh** — if a Garmin token expires mid-upload the app re-authenticates silently using the stored password
- **Calibration / reference values** — each measurement can have reference values entered (e.g. from a Tanita scale); the app computes corrected body composition figures using an additive offset (1–2 reference points) or ordinary least-squares linear regression (3+ points), and can send corrected values to Garmin
- **Sync toggle** — enable or disable Garmin upload per profile without losing credentials
- **Soft delete with tombstoning** — deleted measurements are kept as invisible tombstones so the scale's continued rebroadcasts don't re-create the record; tombstones expire once deleted, so re-weighing after a deletion works correctly

### Build & install

#### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) installed and on your `PATH` (`flutter --version` should work)
- Android phone with **USB debugging** enabled:
  - Settings → About phone → tap **Build number** 7 times to unlock Developer options
  - Settings → Developer options → enable **USB debugging**
- USB cable (or set up wireless ADB — see below)

Verify everything is ready:

```bash
flutter doctor          # should show no errors for Android toolchain
adb devices             # should list your phone (e.g. "R58Mxxxxxx device")
```

If `adb devices` shows `unauthorized`, unlock your phone and tap **Allow** on the USB debugging prompt.

#### Option A — build + install in one step (USB)

```bash
cd scale_app
flutter devices                         # find your device id
flutter run -d <device-id> --release    # builds and installs directly
```

`<device-id>` is the serial from `flutter devices`, e.g. `R58M704XXXX`. You can omit `-d` if only one device is connected.

#### Option B — build APK, then sideload

```bash
cd scale_app
flutter build apk --release
# APK is at:
#   build/app/outputs/flutter-apk/app-release.apk

adb install build/app/outputs/flutter-apk/app-release.apk
```

Replaces any existing install without wiping data.

#### Option C — wireless (no USB after first setup)

On Android 11+:

```bash
# 1. Connect once via USB and pair
adb tcpip 5555
adb connect <phone-ip>:5555   # find phone IP in Settings → About → Status

# 2. Disconnect USB — wireless ADB stays active until reboot
flutter run -d <phone-ip>:5555 --release
```

On Android 11+ you can also use **Developer options → Wireless debugging** and pair with a QR code (`adb pair`).

#### Updating after code changes

Re-run whichever option you used — `flutter run --release` rebuilds only changed files. App data (profiles, measurements, tokens) is preserved across installs.

### Setup

1. Open the app → tap the **people icon** (top-right) → **+** to add a profile
2. Enter name, expected weight, height, birth date, sex
3. Enter your Garmin email and password → tap **Login (Native)**
4. Optionally enable **Sync to Garmin** and **Correct values before upload**
5. Back on the home screen, tap **Start** to begin scanning
6. Step on the scale with bare feet — a pending entry appears immediately, then updates with full body composition after ~5 seconds

### Profile management

Each profile stores:
- **Name, expected weight, height, birth date, sex** — used for profile matching and body composition calculation
- **Garmin email + password** — stored in `FlutterSecureStorage` (Android Keystore-backed), never in plaintext
- **Sync to Garmin** — uncheck to pause uploads for this profile without removing credentials
- **Correct values before upload** — when enabled, calibrated body composition values are sent to Garmin instead of the raw scale values

### Calibration

The Xiaomi scale's body composition formulas diverge from clinical-grade devices. The app lets you enter reference values (e.g. from a Tanita) on any measurement's detail screen:

- **1–2 reference points** — applies the mean additive offset to all future measurements for that profile
- **3+ reference points** — fits an ordinary least-squares linear model (`corrected = a × raw + b`) per metric; the model updates automatically as you add more reference points

Both raw and corrected values are shown side by side in the measurement detail screen.

### Measurement detail screen

Tap any measurement to see:
- Full timestamp, weight, and raw impedance in ohms
- Body composition table: raw vs corrected fat %, muscle kg, water %, BMI
- Calibration model info (method, number of reference points)
- Sync status and any upload errors
- Reference value entry fields (fat %, muscle kg, water %) — save to contribute to the calibration model

### Auth notes

- Native login: POST JSON credentials to `sso.garmin.com/mobile/api/login` → service ticket → POST to `diauth.garmin.com` for a DI OAuth2 bearer token
- The bearer token authenticates against `connectapi.garmin.com` (Garmin's mobile API)
- **MFA accounts** have two options:
  - **Login (WebView — MFA)** — opens Garmin's login page in a WebView; complete login + MFA code there; the app exchanges the session cookie for a DI OAuth2 token automatically and closes the screen
  - **Paste token manually** — run `python3 get_data.py` (or `upload_body_composition.py`) on a desktop/Pi; the script prints the access + refresh tokens after login; paste the access token into the app. Token expires in ~1 hour
- Both WebView and manual-paste logins capture the token only (not the password), so auto-refresh on 401 does not work — you will need to re-login when the token expires
- Garmin rate-limits login attempts (HTTP 429, Cloudflare). If this happens, wait 15–30 minutes before retrying. Passwords are saved before the login attempt so the next measurement will trigger an automatic retry

### Body composition formula

Port of the Xiaomi Mi Scale open-source formula:

```
lbm = (height * 9.058 / 100) * (height / 100) + weight * 0.32 + 12.226
lbm -= impedance * 0.0068 + age * 0.0542

fat_pct  = (1 - ((lbm - 0.8 + lbm * coeff * 0.05) / weight)) * 100  # male
         = (1 - ((lbm - 0.8 + lbm * 0.05) / weight)) * 100           # female
muscle   = weight - (weight * fat_pct / 100)
water    = (muscle / weight) * 73.0
bmi      = weight / (height_m ** 2)
```

Age coefficient for males: 0.9462 (≤30), 0.9 (≤45), 1.0 (>45).

### Architecture

| File | Responsibility |
|------|---------------|
| `main.dart` | UI — home screen, measurement list, pending indicator |
| `background_service.dart` | BLE scan loop, packet buffering, dedup, profile matching |
| `profiles_screen.dart` | Profile list + edit screen with Garmin login |
| `measurement_detail_screen.dart` | Full measurement view + reference value entry |
| `debug_screen.dart` | Live BLE packet feed for debugging |
| `models.dart` | Data models (`Profile`, `Measurement`) + dedup logic |
| `store.dart` | JSON file storage + `FlutterSecureStorage` for secrets |
| `uploader.dart` | Garmin upload with calibration and token refresh |
| `garmin_auth.dart` | Garmin SSO login flow |
| `garmin_client.dart` | Garmin API client (FIT upload, token management) |
| `scale_parser.dart` | BLE advertisement parser |
| `body_composition.dart` | Body composition formulas |
| `calibration.dart` | Offset + linear regression calibration model |
| `profile_matcher.dart` | Weight-based profile auto-detection |

---

## BLE packet format (Xiaomi scale service UUID `181b`)

| Byte(s) | Field      | Notes |
|---------|------------|-------|
| 0       | ctrl0      | Unused |
| 1       | ctrl1      | Bit 0 = lbs, bit 4 = jin, bit 5 = stabilised, bit 1 = has impedance |
| 2–3     | year       | Little-endian |
| 4       | month      | |
| 5       | day        | |
| 6       | hour       | |
| 7       | minute     | |
| 8       | second     | |
| 9–10    | impedance  | Little-endian, ohms |
| 11–12   | raw weight | Little-endian; ÷200 for kg, ÷100 for lbs/jin |

The scale's built-in clock is unreliable. The app uses the phone's wall clock as the measurement timestamp; the scale's time is only used for in-session deduplication.
