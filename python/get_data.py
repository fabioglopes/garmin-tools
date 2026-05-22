from garminconnect import Garmin
from dotenv import load_dotenv
import getpass
import json
import os
from datetime import date

load_dotenv()

today = date.today().isoformat()

email = os.getenv("GARMIN_EMAIL") or input("Garmin email: ")
password = os.getenv("GARMIN_PASSWORD") or getpass.getpass("Garmin password: ")

client = Garmin(email, password)
client.login()

sections = {
    "User summary": lambda: client.get_user_summary(today),
    "Body composition": lambda: client.get_body_composition(today, today),
    "Daily weigh-ins": lambda: client.get_daily_weigh_ins(today, today),
    "Sleep": lambda: client.get_sleep_data(today),
    "Heart rate": lambda: client.get_heart_rates(today),
    "Steps": lambda: client.get_steps_data(today),
    "Stress": lambda: client.get_stress_data(today),
    "Body battery": lambda: client.get_body_battery(today, today),
    "HRV": lambda: client.get_hrv_data(today),
    "SpO2": lambda: client.get_spo2_data(today),
    "Last activity": lambda: client.get_last_activity(),
}

for name, fn in sections.items():
    print(f"\n{'='*40}")
    print(f"  {name}")
    print(f"{'='*40}")
    try:
        data = fn()
        print(json.dumps(data, indent=2, default=str))
    except Exception as e:
        print(f"  Error: {e}")
