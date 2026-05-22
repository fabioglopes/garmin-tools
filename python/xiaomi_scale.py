import asyncio
import logging
import os
import struct
import time
from datetime import datetime
from bleak import BleakScanner, AdvertisementData, BLEDevice
from dotenv import load_dotenv

load_dotenv()

# ── User profile (set via env vars or edit .env) ──────────────────────────
HEIGHT = int(os.getenv("HEIGHT", "175"))   # cm
AGE    = int(os.getenv("AGE", "30"))
SEX    = os.getenv("SEX", "male")          # "male" or "female"

# ── Garmin credentials (or set GARMIN_EMAIL / GARMIN_PASSWORD env vars) ───
GARMIN_EMAIL    = os.getenv("GARMIN_EMAIL", "")
GARMIN_PASSWORD = os.getenv("GARMIN_PASSWORD", "")

# ── Debug mode: print payload without uploading ────────────────────────────
DEBUG = os.getenv("DEBUG", "false").lower() == "true"
# ──────────────────────────────────────────────────────────────────────────

SCALE_SERVICE_UUID = "0000181b-0000-1000-8000-00805f9b34fb"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler("xiaomi_scale.log"),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger(__name__)

# Tracks last seen/uploaded measurement to avoid duplicate logs and uploads
_last_seen:        str | None = None
_last_upload_time: float = 0
UPLOAD_COOLDOWN    = 300  # seconds — ignore new uploads for 5 min after one succeeds


def calculate_body_composition(weight: float, impedance: int, height: int, age: int, sex: str) -> dict:
    h = height / 100
    lbm = (height * 9.058 / 100) * h + weight * 0.32 + 12.226
    lbm -= impedance * 0.0068 + age * 0.0542

    if sex == "male":
        coeff = 0.9462 if age <= 30 else (0.9 if age <= 45 else 1.0)
        fat_pct = (1 - ((lbm - 0.8 + lbm * coeff * 0.05) / weight)) * 100
        fat_pct = max(fat_pct, 5.0)
    else:
        fat_pct = (1 - ((lbm - 0.8 + lbm * 0.05) / weight)) * 100
        fat_pct = max(fat_pct, 10.0)

    muscle_mass = weight - (weight * fat_pct / 100)
    water_pct   = (muscle_mass / weight) * 73.0
    bmi         = weight / (h ** 2)

    return {
        "fat_pct":    round(fat_pct, 1),
        "muscle_kg":  round(muscle_mass, 1),
        "water_pct":  round(water_pct, 1),
        "bmi":        round(bmi, 1),
    }


def parse_mi_scale(data: bytes) -> dict | None:
    if len(data) < 13:
        return None

    ctrl0, ctrl1 = data[0], data[1]
    year          = data[2] | (data[3] << 8)   # little-endian
    month, day    = data[4], data[5]
    hour, minute  = data[6], data[7]
    second        = data[8]
    impedance     = data[9] | (data[10] << 8)  # little-endian
    raw_weight    = data[11] | (data[12] << 8) # little-endian

    if ctrl1 & 0x10:
        weight, unit = raw_weight / 100, "jin"
    elif ctrl1 & 0x01:
        weight, unit = raw_weight / 100, "lbs"
    else:
        weight, unit = raw_weight / 200, "kg"

    return {
        "timestamp":     f"{year}-{month:02d}-{day:02d}T{hour:02d}:{minute:02d}:{second:02d}",
        "weight":        weight,
        "unit":          unit,
        "impedance":     impedance if (ctrl1 & 0x02) else None,
        "stabilized":    bool(ctrl1 & 0x20),
        "has_impedance": bool(ctrl1 & 0x02),
    }


def upload_to_garmin(timestamp: str, weight: float, comp: dict):
    global _last_upload_time
    remaining = UPLOAD_COOLDOWN - (time.time() - _last_upload_time)
    if remaining > 0:
        log.info("Skipping upload — cooldown active (%ds remaining)", int(remaining))
        return

    payload = {
        "timestamp":         timestamp,
        "weight":            weight,
        "percent_fat":       comp["fat_pct"],
        "percent_hydration": comp["water_pct"],
        "muscle_mass":       comp["muscle_kg"],
    }

    if DEBUG:
        log.info("[DEBUG] Would upload to Garmin: %s", payload)
        _last_upload_time = time.time()
        return

    try:
        from garminconnect import Garmin
        client = Garmin(GARMIN_EMAIL, GARMIN_PASSWORD)
        client.login()
        result = client.add_body_composition(**payload)
        log.info("Uploaded to Garmin: %s", result)
        _last_upload_time = time.time()
    except Exception as e:
        log.error("Garmin upload failed: %s", e)


def on_advertisement(device: BLEDevice, adv: AdvertisementData):
    global _last_seen
    svc_data = adv.service_data.get(SCALE_SERVICE_UUID)
    if svc_data is None:
        return

    parsed = parse_mi_scale(svc_data)
    if parsed is None or not parsed["stabilized"]:
        return

    w, u, ts = parsed["weight"], parsed["unit"], parsed["timestamp"]
    seen_key = f"{ts}-{w}-{parsed['impedance']}"
    if seen_key == _last_seen:
        return
    _last_seen = seen_key

    if DEBUG:
        log.info("[DEBUG] raw bytes: %s", svc_data.hex())
    log.info("Measurement: %.2f %s  impedance=%s  ts=%s", w, u, parsed["impedance"], ts)

    if parsed["has_impedance"] and u == "kg":
        comp = calculate_body_composition(w, parsed["impedance"], HEIGHT, AGE, SEX)
        log.info("Body composition: %s", comp)

        if GARMIN_EMAIL and GARMIN_PASSWORD:
            upload_to_garmin(ts, w, comp)
        else:
            log.warning("No Garmin credentials set — skipping upload")
    else:
        log.info("No impedance data (bare feet needed for body composition)")


async def main():
    mode = "DEBUG (no uploads)" if DEBUG else "LIVE (uploading to Garmin)"
    log.info("Starting Xiaomi Scale listener — %s (Ctrl+C to stop)", mode)
    while True:
        try:
            async with BleakScanner(on_advertisement):
                await asyncio.sleep(3600)   # restart scanner every hour
        except Exception as e:
            log.error("Scanner error: %s — restarting in 10s", e)
            await asyncio.sleep(10)


asyncio.run(main())
