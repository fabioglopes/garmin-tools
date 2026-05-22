from garminconnect import Garmin
from dotenv import load_dotenv
import getpass
import os

load_dotenv()

email = os.getenv("GARMIN_EMAIL") or input("Garmin email: ")
password = os.getenv("GARMIN_PASSWORD") or getpass.getpass("Garmin password: ")

client = Garmin(email, password)
client.login()

result = client.add_body_composition(
    timestamp="2024-01-01T08:00:00",  # replace with actual timestamp
    weight=80.0,
    percent_fat=20.0,
    percent_hydration=55.0,
    muscle_mass=60.0,
    bone_mass=3.5,
)

print("Result:", result)
