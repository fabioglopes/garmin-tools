from garminconnect import Garmin
from dotenv import load_dotenv
import getpass
import os

load_dotenv()

email = os.getenv("GARMIN_EMAIL") or input("Garmin email: ")
password = os.getenv("GARMIN_PASSWORD") or getpass.getpass("Garmin password: ")

client = Garmin(email, password)
client.login()

try:
    tok = client.garth.oauth2_token
    import datetime
    expires = datetime.datetime.fromtimestamp(tok.expires_at).strftime('%Y-%m-%d %H:%M:%S')
    print("\n" + "=" * 52)
    print("  GARMIN TOKENS — paste into Android app")
    print("=" * 52)
    print(f"Access token:  {tok.access_token}")
    print(f"Refresh token: {tok.refresh_token}")
    print(f"Expires at:    {expires} (local) — ~1 hour")
    print("=" * 52 + "\n")
except Exception as _e:
    print(f"(Could not extract tokens: {_e})")

result = client.add_body_composition(
    timestamp="2024-01-01T08:00:00",  # replace with actual timestamp
    weight=80.0,
    percent_fat=20.0,
    percent_hydration=55.0,
    muscle_mass=60.0,
    bone_mass=3.5,
)

print("Result:", result)
